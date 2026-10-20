import { audio } from '@kit.AudioKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioRecorder';

/** 采集源采样率：设备麦克风普遍支持 48k，采集后自己降到 16k（识曲接口只吃 8k/16k） */
const SOURCE_SAMPLE_RATE = 48000;
const TARGET_SAMPLE_RATE = 16000;
/** 录多久：12 秒是「够识别、又不至于让用户等太久」的折中（与派音一致） */
const TARGET_SECONDS = 12;
const TARGET_SAMPLES = TARGET_SECONDS * TARGET_SAMPLE_RATE;
/** 抽点降采样的步长：48000 / 16000 = 3 */
const DOWNSAMPLE_STEP = SOURCE_SAMPLE_RATE / TARGET_SAMPLE_RATE;
/** 起播看门狗：这么久还没吐过一个字节，说明采集根本没跑起来，别让用户干等 12 秒 */
const WATCHDOG_MS = 4000;
/** `playbackCaptureMode` 是 API 26 才有的字段，早于它的版本上内录这条路是关着的 */
const PLAYBACK_MIN_API = 26;

/**
 * 采集来源
 *
 *   - {@link CaptureSource.MIC}：**外录** —— 麦克风录周围的声音（听音箱外放、线下随手听）；
 *   - {@link CaptureSource.PLAYBACK}：**内录** —— 直接抓本机正在播放的媒体音频
 *     （抖音 / 视频号 / 别的播放器），不挑环境、不用把手机凑近音源。
 *
 * 两者拿到的是同一种东西（16k 单声道 PCM），后面的识别链路完全共用。
 */
export enum CaptureSource {
  MIC = 0,
  PLAYBACK = 1,
}

/** 用户主动停止采集（不是错误，界面按「回到待机」处理） */
export class CaptureCancelledError extends Error {
  constructor() {
    super('audio capture cancelled');
    this.name = 'CaptureCancelledError';
  }
}

/** 系统没放行这次采集：麦克风权限没给，或者内录被拒 */
export class CapturePermissionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CapturePermissionError';
  }
}

/**
 * 音频采集（外录 / 内录）
 *
 * 链路：48kHz S16LE 单声道 → 抽点降到 16kHz → Float32 累积 → 输出 Int16 PCM。
 *
 * 输出 16k/单声道/16bit 是因为两个引擎都以此为准：酷狗那边再自己对点平均降到 8k，
 * 网易云的 AFP 指纹也按 8k 重采样（见 KugouRecognizer / NeteaseRecognizer）。
 * 在采集端就统一成 16k，两个引擎拿到的是同一份音频，结果才有可比性。
 */
export class AudioRecorder {
  private capturer: audio.AudioCapturer | undefined = undefined;
  /** 已降采样的浮点样本（-1 ~ 1） */
  private chunks: Array<number> = [];
  private cancelled: boolean = false;
  private targetReached: boolean = false;
  /** 这次采的是哪一路：只用来写日志与报错文案 */
  private source: CaptureSource = CaptureSource.MIC;
  private onProgressCb: ((progress: number) => void) | undefined = undefined;
  private finishResolve: ((samples: Int16Array) => void) | undefined = undefined;
  private finishReject: ((reason: Object) => void) | undefined = undefined;
  private watchdogTimer: number = -1;

  /**
   * 本机是否支持内录（抓其它应用正在播放的媒体音频）
   *
   * 两个条件缺一不可：
   *   1. 设备能力集里得有 SystemCapability.Multimedia.Audio.PlaybackCapture（真机 / 平板都有）；
   *   2. 系统得给得出 `playbackCaptureMode` —— 见 {@link PLAYBACK_MIN_API}。
   * 缺任一条就老老实实走麦克风，界面也不再显示来源切换（只有一路可选就没必要摆出来）。
   *
   * `canIUse` 外面包一层 try：能力集查询本身在极端情况下也会抛，别让它带崩识别页。
   */
  static isPlaybackSupported(): boolean {
    try {
      return deviceInfo.sdkApiVersion >= PLAYBACK_MIN_API &&
        canIUse('SystemCapability.Multimedia.Audio.PlaybackCapture');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'query playback capture capability failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 录满 12 秒（或中途 stop()）后 resolve 出 PCM；出错则 reject。
   * `onProgress` 每收一批数据回调一次（0~1），界面拿它画进度条。
   */
  async capture(onProgress: (progress: number) => void,
    source: CaptureSource = CaptureSource.MIC): Promise<Int16Array> {
    this.chunks = [];
    this.cancelled = false;
    this.targetReached = false;
    this.source = source;
    this.onProgressCb = onProgress;
    this.finishResolve = undefined;
    this.finishReject = undefined;
    const playback: boolean = source === CaptureSource.PLAYBACK;

    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        // 内录走回放采集音源：抓到的是「系统正在播给扬声器的那份」数字音频，
        // 而不是麦克风听见的，所以抖音在放什么，这里就拿到什么
        source: playback ? audio.SourceType.SOURCE_TYPE_PLAYBACK_CAPTURE : audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };
    if (playback && deviceInfo.sdkApiVersion >= PLAYBACK_MIN_API) {
      // MODE_MEDIA：只要媒体流（音乐 / 短视频里放的正是媒体流），提示音、隐私音不要。
      // 想连本应用自己放的声音也一起排除，可以再按位或上 MODE_EXCLUDING_SELF，
      // 但那样「本应用正在播放时」会录成一片静音，更难判断，这里不取。
      options.playbackCaptureMode = audio.AudioPlaybackCaptureMode.MODE_MEDIA;
    }

    let capturer: audio.AudioCapturer;
    try {
      capturer = await audio.createAudioCapturer(options);
    } catch (err) {
      const businessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'createAudioCapturer failed, source=%{public}d code=%{public}d',
        source, businessError.code);
      // 201 = 权限校验失败，单独成一类：麦克风那一路要提示「去设置里开权限」，
      // 内录那一路本应用没有任何可申请的权限，只能说明是系统没放行
      if (businessError.code === 201) {
        throw new CapturePermissionError(playback
          ? '系统没有放行本机播放声音的采集'
          : '未获得麦克风权限');
      }
      throw new Error(playback
        ? `本机声音采集不可用（${businessError.code}）`
        : `麦克风不可用（${businessError.code}）`);
    }
    this.capturer = capturer;
    hilog.info(DOMAIN, TAG, 'capturer created, source=%{public}d state=%{public}d', source, capturer.state);

    return new Promise<Int16Array>((resolve: (value: Int16Array) => void,
      reject: (reason: Object) => void): void => {
      this.finishResolve = resolve;
      this.finishReject = reject;
      capturer.on('readData', (buffer: ArrayBuffer): void => {
        this.handleBuffer(buffer);
      });
      capturer.start().then((): void => {
        hilog.info(DOMAIN, TAG, 'capturer started, source=%{public}d state=%{public}d', source, capturer.state);
        this.watchdogTimer = setTimeout((): void => {
          if (!this.targetReached && !this.cancelled && this.chunks.length === 0) {
            hilog.warn(DOMAIN, TAG, 'no audio data within watchdog window, source=%{public}d', source);
            this.forceFinishWithError(playback
              ? '本机这会儿没有在播放声音，先让应用把歌放起来再试'
              : '麦克风未产生音频数据，请检查设备麦克风是否可用');
          }
        }, WATCHDOG_MS);
      }).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'capturer start failed, source=%{public}d code=%{public}d', source, err.code);
        reject(new Error(playback ? '本机声音采集启动失败' : '麦克风启动失败'));
      });
    });
  }

  /** 停止采集（界面上的「停止」按钮 / 离开页面时调）；会以 CaptureCancelledError 收尾 */
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
   * 用来判断「有没有听到声音」：环境噪音的 RMS 极低，低于阈值就直接提示
   * 「未检测到声音」，不必白跑一次网络识别（还省一次误报）。
   * 内录那一路同理：没有任何流在播时读到的基本是静音。
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
      hilog.info(DOMAIN, TAG, '采集完成 来源=%{public}d 样本数=%{public}d（目标%{public}d）',
        this.source, this.chunks.length, TARGET_SAMPLES);
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
   * 停与释放都吞异常：这时候音频通路可能已经被系统收走了（来电、其它应用抢占），
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
        reject(new CaptureCancelledError());
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
    hilog.info(DOMAIN, TAG, '输出PCM 来源=%{public}d 样本数=%{public}d 时长=%{public}fs',
      this.source, out.length, out.length / TARGET_SAMPLE_RATE);
    return out;
  }
}
