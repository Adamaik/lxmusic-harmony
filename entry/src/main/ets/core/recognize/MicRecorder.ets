import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'MicRecorder';

/** 采集源采样率：设备麦克风普遍支持 48k，采集后自己降到 16k（识曲接口只吃 8k/16k） */
const SOURCE_SAMPLE_RATE = 48000;
const TARGET_SAMPLE_RATE = 16000;
/** 录多久：12 秒是「够识别、又不至于让用户等太久」的折中（与派音一致） */
const TARGET_SECONDS = 12;
const TARGET_SAMPLES = TARGET_SECONDS * TARGET_SAMPLE_RATE;
/** 抽点降采样的步长：48000 / 16000 = 3 */
const DOWNSAMPLE_STEP = SOURCE_SAMPLE_RATE / TARGET_SAMPLE_RATE;
/** 起播看门狗：这么久还没吐过一个字节，说明麦克风根本没用起来，别让用户干等 12 秒 */
const WATCHDOG_MS = 4000;

/** 用户主动停止采集（不是错误，界面按「回到待机」处理） */
export class MicCancelledError extends Error {
  constructor() {
    super('mic capture cancelled');
    this.name = 'MicCancelledError';
  }
}

/** 没有麦克风权限 */
export class MicPermissionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MicPermissionError';
  }
}

/**
 * 麦克风采集
 *
 * 链路：48kHz S16LE 单声道 → 抽点降到 16kHz → Float32 累积 → 输出 Int16 PCM。
 *
 * 输出 16k/单声道/16bit 是因为两个引擎都以此为准：酷狗那边再自己对点平均降到 8k，
 * 网易云的 AFP 指纹也按 8k 重采样（见 KugouRecognizer / NeteaseRecognizer）。
 * 在采集端就统一成 16k，两个引擎拿到的是同一份音频，结果才有可比性。
 */
export class MicRecorder {
  private capturer: audio.AudioCapturer | undefined = undefined;
  /** 已降采样的浮点样本（-1 ~ 1） */
  private chunks: Array<number> = [];
  private cancelled: boolean = false;
  private targetReached: boolean = false;
  private onProgressCb: ((progress: number) => void) | undefined = undefined;
  private finishResolve: ((samples: Int16Array) => void) | undefined = undefined;
  private finishReject: ((reason: Object) => void) | undefined = undefined;
  private watchdogTimer: number = -1;

  /**
   * 录满 12 秒（或中途 stop()）后 resolve 出 PCM；出错则 reject。
   * `onProgress` 每收一批数据回调一次（0~1），界面拿它画进度条。
   */
  async capture(onProgress: (progress: number) => void): Promise<Int16Array> {
    this.chunks = [];
    this.cancelled = false;
    this.targetReached = false;
    this.onProgressCb = onProgress;
    this.finishResolve = undefined;
    this.finishReject = undefined;

    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };

    let capturer: audio.AudioCapturer;
    try {
      capturer = await audio.createAudioCapturer(options);
    } catch (err) {
      const businessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'createAudioCapturer failed, code=%{public}d', businessError.code);
      // 201 = 权限校验失败，单独成一类，界面要提示「去设置里开权限」
      if (businessError.code === 201) {
        throw new MicPermissionError('未获得麦克风权限');
      }
      throw new Error(`麦克风不可用（${businessError.code}）`);
    }
    this.capturer = capturer;
    hilog.info(DOMAIN, TAG, 'capturer created, state=%{public}d', capturer.state);

    return new Promise<Int16Array>((resolve: (value: Int16Array) => void,
      reject: (reason: Object) => void): void => {
      this.finishResolve = resolve;
      this.finishReject = reject;
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        this.handleBuffer(buffer);
      });
      capturer.start().then((): void => {
        hilog.info(DOMAIN, TAG, 'capturer started, state=%{public}d', capturer.state);
        this.watchdogTimer = setTimeout((): void => {
          if (!this.targetReached && !this.cancelled && this.chunks.length === 0) {
            hilog.warn(DOMAIN, TAG, 'no audio data within watchdog window');
            this.forceFinishWithError('麦克风未产生音频数据，请检查设备麦克风是否可用');
          }
        }, WATCHDOG_MS);
      }).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'capturer start failed, code=%{public}d', err.code);
        reject(new Error('麦克风启动失败'));
      });
    });
  }

  /** 停止采集（界面上的「停止」按钮 / 离开页面时调）；会以 MicCancelledError 收尾 */
  stop(): void {
    this.cancelled = true;
    clearTimeout(this.watchdogTimer);
    const capturer = this.capturer;
    if (capturer !== undefined) {
      try {
        capturer.off('readData');
      } catch (err) {
      }
      void capturer.stop().catch(() => {
      });
    }
    void this.finish();
  }

  /**
   * 一段 PCM 的均方根（0~1）
   *
   * 用来判断「有没有录到人声」：环境噪音的 RMS 极低，低于阈值就直接提示
   * 「未检测到声音」，不必白跑一次网络识别（还省一次误报）。
   */
  static computeRms(samples: Int16Array): number {
    if (samples.length === 0) {
      return 0;
    }
    let sum = 0;
    for (let i = 0; i < samples.length; i++) {
      const v: number = samples[i] / 32768;
      sum += v * v;
    }
    return Math.sqrt(sum / samples.length);
  }

  /**
   * 收到一批原始数据：按步长抽点转成 16k 的浮点样本
   *
   * 抽点（每 3 个取 1 个）而不是取平均：这一步只是为了把采样率对上，
   * 后面的引擎各自还会再做一次按点平均的降采样，这里没必要先滤一道。
   */
  private handleBuffer(buffer: ArrayBuffer): void {
    if (this.targetReached || this.cancelled) {
      return;
    }
    const dataView = new DataView(buffer);
    const sampleCount: number = buffer.byteLength / 2;
    for (let i = 0; i < sampleCount; i += DOWNSAMPLE_STEP) {
      this.chunks.push(dataView.getInt16(i * 2, true) / 32768);
    }
    if (this.onProgressCb !== undefined) {
      this.onProgressCb(Math.min(this.chunks.length / TARGET_SAMPLES, 1));
    }
    if (this.chunks.length >= TARGET_SAMPLES) {
      this.targetReached = true;
      hilog.info(DOMAIN, TAG, '采集完成 样本数=%{public}d（目标%{public}d）',
        this.chunks.length, TARGET_SAMPLES);
      void this.finish();
    }
  }

  private forceFinishWithError(message: string): void {
    clearTimeout(this.watchdogTimer);
    const reject = this.finishReject;
    this.finishReject = undefined;
    this.finishResolve = undefined;
    if (reject !== undefined) {
      reject(new Error(message));
    }
    this.cancelled = true;
    void this.finish();
  }

  /**
   * 收尾：摘监听、停并释放采集器，然后按「取消 / 正常录满」二选一回调
   *
   * 停与释放都吞异常：这时候麦克风可能已经被系统收走了（来电、其它应用抢占），
   * 报错也没意义，重要的是把 Promise 结了、别把界面吊在「正在聆听」上。
   */
  private async finish(): Promise<void> {
    clearTimeout(this.watchdogTimer);
    const capturer = this.capturer;
    if (capturer !== undefined) {
      try {
        capturer.off('readData');
      } catch (err) {
      }
      try {
        await capturer.stop();
      } catch (err) {
      }
      try {
        await capturer.release();
      } catch (err) {
      }
      this.capturer = undefined;
    }
    const resolve = this.finishResolve;
    const reject = this.finishReject;
    if (this.cancelled) {
      if (reject !== undefined) {
        reject(new MicCancelledError());
      }
      return;
    }
    if (resolve !== undefined) {
      resolve(this.buildSamples());
    }
  }

  /** 浮点样本 → s16le 整型（截到 [-32768, 32767]，四舍五入） */
  private buildSamples(): Int16Array {
    const total: number = Math.min(this.chunks.length, TARGET_SAMPLES);
    const out = new Int16Array(total);
    for (let i = 0; i < total; i++) {
      const value: number = this.chunks[i] * 32768;
      out[i] = Math.max(-32768, Math.min(32767, Math.round(value)));
    }
    hilog.info(DOMAIN, TAG, '输出PCM 样本数=%{public}d 时长=%{public}fs', out.length, out.length / TARGET_SAMPLE_RATE);
    return out;
  }
}
