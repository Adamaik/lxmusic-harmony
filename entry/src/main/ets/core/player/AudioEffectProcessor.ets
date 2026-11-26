import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cancel, processAudio, processAudioFd, processAudioUrl, version, ProcessAudioResult } from 'libaudioeffect.so';
import { AudioEffectSettings } from '../settings/AudioEffectSettings';
import { LocalStreamProxy } from './LocalStreamProxy';

/**
 * 排查用开关：把本来可以直连的 URL 也强行绕一遍本地代理。
 *
 * 正常逻辑只有「需要请求头」的源才走代理（见 processByProxy），而这类源（WebDAV）
 * 不好随手造，所以留一个开关来验证回环链路本身通不通。**发版保持 false。**
 */
const FORCE_PROXY_FOR_TEST: boolean = false;

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioEffectProcessor';
const EQ_DIR: string = 'eq_cache';

/** 分块下载：netstack 的 http.request 内存模式有大文件上限（2300023），
 *  整包下 20MB+ 的歌必炸；照 AudioCache 的验证方案用 Range 分块。 */
const EQ_CHUNK_BYTES: number = 64 * 1024;
const EQ_CHUNK_CONNECT_MS: number = 15000;
const EQ_CHUNK_READ_MS: number = 30000;
/** 单块失败重试次数：CDN 偶发停顿很常见，重试同一块接着往下走，不要整首报废 */
const EQ_CHUNK_RETRY: number = 3;

/** 起播前至少要有这么多 WAV 数据（约 3 秒 44.1k/16bit 立体声） */
const PREBUFFER_SECONDS: number = 3;
/** 预缓冲下限：极低采样率 / 单声道也不至于一有数据就起播 */
const PREBUFFER_MIN_BYTES: number = 256 * 1024;
/** 等预缓冲的上限；超时就先起播（反正后面还在继续产出） */
const PREBUFFER_TIMEOUT_MS: number = 20000;

/**
 * 「续播」时等整首处理完的上限
 *
 * 边处理边播的数据源是**顺序读、不能定位**的（见 LxPlayer.playEqStream），所以想让
 * 起播就落在原来的位置，只能等 WAV 落全再走普通文件播放。真机实测处理速度约 32 倍速
 * （4 分钟的曲子约 7 秒），这个上限够覆盖绝大多数歌曲；超出就放弃等待、退回从头流式
 * 起播 —— 宁可回到老行为，也不能让用户对着转圈等到天荒地老。
 */
const RESUME_WAIT_MS: number = 9000;

/** 等上一趟 Native 处理真正退出的上限。超时就不再等，硬着头皮开始新的一趟 */
const SETTLE_TIMEOUT_MS: number = 3000;

/**
 * 一次 EQ 处理的运行状态。WAV 是边解码边写的，所以文件会在处理过程中不断变长；
 * 播放器可以在这期间就开始读（见 LxPlayer.playEqStream）。
 */
export interface EqRunState {
  taskId: number;
  wavPath: string;
  rawPath: string;
  /** 整首处理完成 */
  done: boolean;
  /** 处理失败（此时 wav 已被删掉） */
  failed: boolean;
  error: string;
}

/** 交给播放器的流式会话 */
export class EqStreamSession {
  readonly wavPath: string;
  private readonly state: EqRunState;

  constructor(path: string, state: EqRunState) {
    this.wavPath = path;
    this.state = state;
  }

  isDone(): boolean {
    return this.state.done;
  }

  isFailed(): boolean {
    return this.state.failed;
  }

  error(): string {
    return this.state.error;
  }
}

/**
 * 音效预处理服务：把音频变成「过了 EQ 的 WAV」，交给 AVPlayer 播。
 *
 * 为什么需要这一步：AVPlayer 不接受 PCM 数据流，只认 URL / fd / 自定义数据源；
 * 而 HarmonyOS 的 10 段 EQ（AudioSuite）只能处理喂给它的 PCM。所以链路只能是：
 *   原始音频 -> Native 解码成 PCM -> AudioSuite 过 EQ -> 写成 WAV -> AVPlayer 播
 *
 * 三条输入路径（产物都写到同一个临时 WAV）：
 * - **URL 直连**（默认）：Native 用系统解封装器直接拉网络流，边下边解码边写 WAV。
 *   没有「先整份下载」的等待，也不需要额外的磁盘中转。
 * - **需要请求头的源**（WebDAV 认证、防盗链 Referer 等）：起一个本机回环代理把请求头代加上，
 *   Native 依旧走 URL 直连拉流（见 LocalStreamProxy）—— 起播只等几秒数据。
 *   代理起不来或链路不通时回退到「整份下载再处理」（老行为，慢但不丢功能）。
 * - **本地文件**（AudioCache 已缓存的整首 / 沙箱里的音频）：Native 只读打开，输出到临时 WAV。
 *
 * 关键约束：
 * - 只有用户主动打开音效、且增益非全 0 时才走这条链路；否则返回 null，
 *   调用方照旧用原始音源播放，零开销。
 * - 每次处理有独立 taskId；切歌时 cancel 掉旧的，Native 侧尽快停下并回收资源。
 * - **产物是临时文件，不是缓存**：文件名带 taskId、每次播放重新生成，播放结束（或切歌）就删。
 *   这样既不额外占一份长期磁盘（一首 5 分钟的歌，16bit WAV 约 50MB），也绝不碰原始音源
 *   —— 原文件始终只读打开，AudioCache 的缓存也不会被替换或改写。
 *   代价是同一首歌第二次播放要再处理一次（起播约 0.4s，实测可接受）。
 */
export class AudioEffectProcessor {
  private static instance: AudioEffectProcessor = new AudioEffectProcessor();
  static getInstance(): AudioEffectProcessor {
    return AudioEffectProcessor.instance;
  }

  private dir: string = '';
  private ready: boolean = false;
  private nextTaskId: number = 1;
  /** 正在处理的 taskId（同一时刻只服务当前播放这一首） */
  private activeTaskId: number = 0;
  private activeRequest: http.HttpRequest | null = null;
  /** 当前这次处理在用的回环代理（只有需要请求头的源才有）；切歌时立刻关掉 */
  private activeProxy: LocalStreamProxy | null = null;
  /** 当前这次处理的状态；切歌时置 null 让在途任务作废 */
  private current: EqRunState | null = null;
  /**
   * 在途 Native 任务的完成 Promise。
   *
   * 为什么必须留着它：AudioSuite 的 10 段 EQ 算法在进程里是**单例**
   * （真机日志里每次建/毁管线都是 `AudioSuiteEqAlgoInterfaceImpl` 的 Deinit/Init）。
   * 上一首刚 cancel、还没退干净就开始下一首时，新管线的 Init 会把旧管线正在用的算法
   * 重新初始化，旧任务当场报「音频解码失败或超时」，两边的输出也都不可信。
   * 所以新任务开始前要等这一趟真正结束（见 settleActive）。
   */
  private activeRun: Promise<void> | null = null;

  /** 产物临时文件前缀：init 时按它清理上次崩溃/被杀留下的残留 */
  private static readonly TMP_PREFIX: string = 'tmp_';

  init(context: common.Context): void {
    if (this.ready) return;
    this.dir = `${context.filesDir}/${EQ_DIR}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create eq work dir failed: %{public}s', JSON.stringify(e));
      this.ready = false;
    }
    if (this.ready) {
      // 产物是临时文件，进程退出时不会有人来收：启动清一次，免得闪退留下几十 MB 的大文件
      this.purgeTmpFiles('startup');
    }
    // Native 版本自检：加载失败时打一条日志，方便定位 so 没打进包的情况
    try {
      hilog.info(DOMAIN, TAG, 'audio effect native v%{public}s', version());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'audio effect native module not loaded: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 开始一次 EQ 处理，等到「可以起播」就返回会话。
   *
   * 返回时机不是「整首处理完」，而是 WAV 已经有约 3 秒数据（或处理已结束/超时）。
   * 之后播放器一边播、Native 一边继续往后写，用户不用等整首。
   *
   * @param resumeMs 这次起播想落到的位置（0 = 从头）。>0 时会**额外等整首处理完**
   *   （有上限，见 RESUME_WAIT_MS）：只有落全的 WAV 才能用普通 fd 播放定位。
   * @returns null 表示不该走 EQ（未开启 / 未初始化 / 全 0 增益）
   * @throws 处理失败或已被切歌时抛出，调用方回退原始音源
   */
  async startStream(url: string, headers: Record<string, string>,
    resumeMs: number = 0): Promise<EqStreamSession | null> {
    return this.startTask('', url, headers, resumeMs);
  }

  /**
   * 同一个处理链路，输入换成**本地音频**（AudioCache 缓存的整首、沙箱里的音频、
   * 文件选择器导入的 `file://docs/...` 原文件）。
   *
   * 原文件只读打开，产物另写到临时 WAV，所以既不会改动原文件，也不会动 AudioCache 的缓存。
   *
   * @param path 沙箱绝对路径，或 Picker 给的 `file://docs/...` URI。两种都由本侧用
   *   `fs.openSync` 打开、把 fd 交给 Native —— URI 的读权限挂在 ArkTS 的持久化授权上
   *   （见 LocalAccess），原生按字符串是打不开的，传 fd 才是同一条读取通道。
   * @param resumeMs 同 startStream：>0 时额外等整首落全，保证返回的会话可定位
   */
  async startStreamForFile(filePath: string, resumeMs: number = 0): Promise<EqStreamSession | null> {
    return this.startTask(filePath, '', {}, resumeMs);
  }

  private async startTask(filePath: string, url: string,
    headers: Record<string, string>, resumeMs: number): Promise<EqStreamSession | null> {
    const settings: AudioEffectSettings = AudioEffectSettings.getInstance();
    if (!settings.shouldProcess() || !this.ready) {
      return null;
    }

    // 取消上一首还没处理完的任务，并等它真的退出（音频算法是进程级单例，不能并行）
    await this.settleActive();

    const taskId: number = this.nextTaskId++;
    this.activeTaskId = taskId;

    const gains: number[] = settings.getGains();
    // 产物按 taskId 命名：每次播放都是一份新的临时文件，不跨曲复用（见类注释）
    const wavPath: string = `${this.dir}/${AudioEffectProcessor.TMP_PREFIX}${taskId}.wav`;
    const rawPath: string = `${this.dir}/${AudioEffectProcessor.TMP_PREFIX}${taskId}.raw`;

    const run: EqRunState = {
      taskId: taskId,
      wavPath: wavPath,
      rawPath: rawPath,
      done: false,
      failed: false,
      error: '',
    };

    this.current = run;
    // 后台跑，不阻塞这里等整首；同时把 Promise 挂起来，下一首开始前要等它退干净
    const runPromise: Promise<void> = this.execute(run, filePath, url, headers, gains);
    this.activeRun = runPromise;
    void runPromise.then(() => {
      if (this.activeRun === runPromise) {
        this.activeRun = null;
      }
    });

    // 等预缓冲（或处理结束/失败/超时）
    await this.waitPrebuffer(run);
    if (this.current !== run) {
      throw new Error('eq cancelled');
    }
    if (run.failed) {
      throw new Error(run.error);
    }
    // 要续播：顺序数据源不能定位，必须等整首落全（有上限，超时就用流式从头起）
    if (resumeMs > 0 && !run.done) {
      await this.waitProcessed(run, resumeMs);
      if (this.current !== run) {
        throw new Error('eq cancelled');
      }
      if (run.failed) {
        throw new Error(run.error);
      }
    }
    return new EqStreamSession(wavPath, run);
  }

  /**
   * 等整首处理完（给「续播」用，有硬上限）
   *
   * 只等 done/failed，不关心进度：Native 侧一旦开始写就基本能跑完，
   * 中途卡住的情况由它的 20s 无数据超时兜底。
   */
  private async waitProcessed(run: EqRunState, resumeMs: number): Promise<void> {
    const start: number = Date.now();
    while (Date.now() - start < RESUME_WAIT_MS) {
      if (this.current !== run || run.failed || run.done) {
        return;
      }
      await this.sleep(100);
    }
    hilog.warn(DOMAIN, TAG,
      'eq resume wait timeout (%{public}dms) for %{public}dms position, stream from head instead',
      RESUME_WAIT_MS, resumeMs);
  }

  /**
   * 丢掉一份产物临时文件。播放端在一个播放现场结束时调用（见 LxPlayer.release）。
   *
   * 只删 tmp_ 前缀的文件：这里绝不能误删别的东西（比如 AudioCache 的缓存）。
   */
  discardArtifact(path: string): void {
    if (!this.isArtifact(path)) {
      return;
    }
    this.unlinkQuietly(path);
  }

  /** 这个路径是不是本服务产出的临时 WAV */
  isArtifact(path: string): boolean {
    return path.indexOf(`/${EQ_DIR}/${AudioEffectProcessor.TMP_PREFIX}`) >= 0;
  }

  /**
   * 取消上一趟，并等它真正退出。
   *
   * cancel 只是往 Native 置一个标志：解码线程可能还压在网络读上、管线还要 stop/destroy。
   * 而 AudioSuite 的 EQ 算法是进程级单例，两趟重叠会互相把对方的算法状态清掉，
   * 所以这里必须等到 execute() 的 Promise 结算，不能只发个 cancel 就走。
   * 等有上限：真等到天荒地老会直接毁掉这次起播体验，超时就放手（Native 侧仍会自己收尾）。
   */
  private async settleActive(): Promise<void> {
    this.cancelActive();
    const run: Promise<void> | null = this.activeRun;
    if (run === null) {
      return;
    }
    await Promise.race([run, this.sleep(SETTLE_TIMEOUT_MS)]);
    if (this.activeRun === run) {
      hilog.warn(DOMAIN, TAG, 'previous eq task still running after %{public}dms, start anyway',
        SETTLE_TIMEOUT_MS);
      this.activeRun = null;
    }
  }

  /** 切歌时调用：取消当前下载 + 通知 Native 停处理 */
  cancelActive(): void {
    const run: EqRunState | null = this.current;
    this.current = null;
    if (this.activeTaskId !== 0) {
      cancel(this.activeTaskId);
      this.activeTaskId = 0;
    }
    const req: http.HttpRequest | null = this.activeRequest;
    this.activeRequest = null;
    if (req !== null) {
      try {
        req.destroy();
      } catch (e) {
        // 已结束的请求 destroy 会报错，忽略
      }
    }
    // 关掉代理：Native 正卡在读它的时候会立刻拿到 EOF，从而快速退出
    const proxy: LocalStreamProxy | null = this.activeProxy;
    this.activeProxy = null;
    if (proxy !== null) {
      void proxy.stop();
    }
    if (run !== null && !run.done) {
      // 没跑完的产物是半截文件，挪走免得下次被当成缓存命中
      this.unlinkQuietly(run.wavPath);
    }
  }

  /** 删掉所有临时产物（设置页「清理」/ 启动自检用） */
  clearCache(): void {
    this.purgeTmpFiles('manual');
  }

  // ------------------------------------------------------------ 内部

  /** 清掉工作目录下的临时产物（只认 tmp_ 前缀，不碰任何别的文件） */
  private purgeTmpFiles(reason: string): void {
    let removed: number = 0;
    try {
      const files: string[] = fs.listFileSync(this.dir);
      for (const f of files) {
        if (f.startsWith(AudioEffectProcessor.TMP_PREFIX)) {
          this.unlinkQuietly(`${this.dir}/${f}`);
          removed++;
        }
      }
    } catch (e) {
      // 目录不存在：没有残留，正常
    }
    if (removed > 0) {
      hilog.info(DOMAIN, TAG, 'purged %{public}d eq tmp file(s) (%{public}s)', removed, reason);
    }
  }

  /** 真正干活：本地文件直读 / URL 直连 Native / 需要请求头时走本机代理（失败才整份下载） */
  private async execute(run: EqRunState, filePath: string, url: string,
    headers: Record<string, string>, gains: number[]): Promise<void> {
    const needProxy: boolean = Object.keys(headers).length > 0 || FORCE_PROXY_FOR_TEST;
    try {
      let result: ProcessAudioResult;
      if (filePath.length > 0) {
        // 本地音频（含 Picker 给的 file:// URI）：本侧开 fd 交给 Native，原文件只读
        result = await this.processLocal(filePath, run, gains);
      } else if (needProxy) {
        result = await this.processByProxy(url, headers, run, gains);
      } else {
        // URL 直连：系统解封装器自己拉流，省掉整份下载
        result = await processAudioUrl(url, run.wavPath, gains, run.taskId);
      }
      if (this.current !== run) {
        // 切歌了：产物作废
        this.unlinkQuietly(run.wavPath);
        return;
      }
      if (!result.ok) {
        this.unlinkQuietly(run.wavPath);
        run.failed = true;
        run.error = `eq process failed: code=${result.code} ${result.message}`;
        hilog.warn(DOMAIN, TAG, 'eq failed: %{public}s', run.error);
        return;
      }
      run.done = true;
      hilog.info(DOMAIN, TAG,
        'eq processed: task %{public}d -> %{public}d bytes, delta=%{public}s, container=%{public}dms (%{public}s), decoded=%{public}d frames @%{public}dHz/%{public}dch',
        run.taskId, result.outBytes, result.delta.toFixed(3), Math.round(result.durationUs / 1000),
        result.message, result.outFrames, result.sampleRate, result.channels);
      if (result.delta > 0.98 && result.delta < 1.02) {
        hilog.warn(DOMAIN, TAG,
          'eq selfcheck: delta≈1.0, EQ likely did NOT alter spectrum (gains all zero or effect chain inert)');
      }
    } catch (e) {
      if (this.current === run) {
        this.unlinkQuietly(run.wavPath);
        run.failed = true;
        run.error = JSON.stringify(e);
        hilog.warn(DOMAIN, TAG, 'eq preprocess failed: %{public}s', run.error);
      }
    } finally {
      // 中转的原始文件只在下载路径下存在
      this.unlinkQuietly(run.rawPath);
      if (this.current === run && this.activeTaskId === run.taskId) {
        this.activeTaskId = 0;
      }
    }
  }

  /**
   * 本地音频过一遍 EQ：由本侧打开文件、把 fd 交给 Native。
   *
   * 为什么传 fd 而不是路径：文件选择器导入的音乐存的是 `file://docs/...` URI，
   * 能不能读取决于 ArkTS 侧的持久化授权（见 LocalAccess），原生 `fopen` 按这个串打不开。
   * fd 在整趟处理期间必须保持有效（系统解封装器一直在读数据），所以在这里开着、结算后关。
   */
  private async processLocal(path: string, run: EqRunState, gains: number[]): Promise<ProcessAudioResult> {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      return await processAudioFd(file.fd, run.wavPath, gains, run.taskId);
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 已关闭 / 进程退出中：忽略
      }
    }
  }

  /**
   * 需要请求头的源：走本机回环代理，让 Native 依旧「URL 直连」拉流。
   *
   * 为什么不能把头直接交给 Native：`OH_AVSource` 只吃一个 URI，没有任何入口加请求头。
   * 原来的替代方案是整份下载后再处理，起播时间 = 下载全曲（大文件直接撞上 20s 预缓冲上限、
   * 回退原声）。代理把这件事变成「Native 拉 127.0.0.1，我们替它带上认证头转发到真源」，
   * 于是解码可以边下边进行，起播只等几秒数据。
   *
   * 回退策略（保证不比改动前差）：
   * - 端口起不来 / 回环不通 / 上游不支持 Range → 回退「整份下载再处理」。
   * - 但若**已经产出过数据**（WAV 里已有样本），说明播放器可能正在读这份文件，
   *   这时不重试、不删文件，直接让这次失败上抛（调用方回退原声并提示）。
   */
  private async processByProxy(url: string, headers: Record<string, string>, run: EqRunState,
    gains: number[]): Promise<ProcessAudioResult> {
    let proxy: LocalStreamProxy | null = null;
    try {
      proxy = new LocalStreamProxy();
      this.activeProxy = proxy;
      const localUrl: string = await proxy.start(url, headers);
      if (this.current !== run) {
        throw new Error('eq cancelled');
      }
      hilog.info(DOMAIN, TAG, 'eq via local proxy: %{public}s', localUrl);
      const result: ProcessAudioResult =
        await processAudioUrl(localUrl, run.wavPath, gains, run.taskId);
      if (result.ok || this.current !== run) {
        return result;
      }
      if (this.hasOutput(run.wavPath)) {
        return result;
      }
      hilog.warn(DOMAIN, TAG,
        'eq proxy stream failed (code=%{public}d %{public}s), fall back to full download',
        result.code, result.message);
    } catch (e) {
      if (this.current !== run) {
        throw new Error('eq cancelled');
      }
      hilog.warn(DOMAIN, TAG, 'eq proxy unavailable: %{public}s, fall back to full download',
        JSON.stringify(e));
    } finally {
      if (this.activeProxy === proxy) {
        this.activeProxy = null;
      }
      if (proxy !== null) {
        await proxy.stop();
      }
    }
    // 回退：分块下到本地再处理（改动前的老路径）
    this.unlinkQuietly(run.wavPath);
    await this.download(url, headers, run.rawPath, run.taskId);
    if (this.current !== run) {
      throw new Error('eq cancelled');
    }
    return await processAudio(run.rawPath, run.wavPath, gains, run.taskId);
  }

  /** 产物里是否已经有真数据（不能只看文件存在：可能只写了 44 字节的 WAV 头） */
  private hasOutput(path: string): boolean {
    try {
      if (!fs.accessSync(path)) {
        return false;
      }
      return fs.statSync(path).size > 44;
    } catch (e) {
      return false;
    }
  }

  /**
   * 等到 WAV 够播（或处理结束/失败/超时）
   *
   * 「够播」的字节数按**实际采样率**折算，不能写死：原来是固定 512KB，
   * 44.1k 下约 2.9 秒，96k 立体声只剩 1.3 秒 —— 高采样率音源刚起播就容易饿死
   * （见 LxPlayer.playEqStream 里 starve 那条回退）。采样率从 WAV 头里读，
   * 头是 Native 第一个写下去的（且在写数据前就 flush 过），读到就说明可以用了。
   */
  private async waitPrebuffer(run: EqRunState): Promise<void> {
    const start: number = Date.now();
    let target: number = 0;
    while (Date.now() - start < PREBUFFER_TIMEOUT_MS) {
      if (this.current !== run || run.failed) return;
      if (run.done) return;
      try {
        if (fs.accessSync(run.wavPath)) {
          const st: fs.Stat = fs.statSync(run.wavPath);
          if (target <= 0) {
            target = this.prebufferTarget(run.wavPath);
          }
          // 头还没写好（target 仍为 0）：先按下限放行，下一轮再探一次
          const need: number = target > 0 ? target : PREBUFFER_MIN_BYTES;
          if (st.size >= need) {
            hilog.info(DOMAIN, TAG, 'eq prebuffer ready: %{public}d bytes in %{public}dms',
              st.size, Date.now() - start);
            return;
          }
        }
      } catch (e) {
        // 文件还没创建，继续等
      }
      await this.sleep(80);
    }
    hilog.warn(DOMAIN, TAG, 'eq prebuffer timeout after %{public}dms, start anyway', PREBUFFER_TIMEOUT_MS);
  }

  /**
   * 起播所需字节数 = 采样率 × 声道 × 2 字节 × PREBUFFER_SECONDS
   *
   * 读不出头（还没写 / 不是我们的 WAV）返回 0，由调用方按下限处理 ——
   * 绝不能因为解析失败就让起播卡住。
   * WAV 头布局：22 = 声道数(2B)，24 = 采样率(4B)，34 = 位深(2B)。
   */
  private prebufferTarget(path: string): number {
    try {
      const head: ArrayBuffer = new ArrayBuffer(44);
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let read: number = 0;
      try {
        read = fs.readSync(file.fd, head, { offset: 0, length: 44 });
      } finally {
        fs.closeSync(file);
      }
      if (read < 44) {
        return 0;
      }
      const view: DataView = new DataView(head);
      const sampleRate: number = view.getUint32(24, true);
      const channels: number = view.getUint16(22, true);
      if (sampleRate < 8000 || sampleRate > 384000 || channels < 1 || channels > 8) {
        return 0;
      }
      const bytes: number = sampleRate * channels * 2 * PREBUFFER_SECONDS;
      return Math.max(PREBUFFER_MIN_BYTES, bytes);
    } catch (e) {
      return 0;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }

  /**
   * Range 分块下载（与 AudioCache 同款验证过的模式），每块之间检查取消。
   * 单块失败会重试同一块（从已落盘的 offset 续），不会因为一次 CDN 抖动整首报废。
   */
  private async download(url: string, headers: Record<string, string>, target: string,
    taskId: number): Promise<void> {
    const request: http.HttpRequest = http.createHttp();
    this.activeRequest = request;
    let handle: fs.File | null = null;
    let offset: number = 0;
    try {
      handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      for (;;) {
        if (this.activeTaskId !== taskId) {
          throw new Error('eq cancelled');
        }
        const chunk: ArrayBuffer = await this.readChunk(request, url, headers, offset, taskId);
        if (chunk.byteLength === 0) {
          throw new Error('eq download failed: empty chunk');
        }
        fs.writeSync(handle.fd, chunk);
        offset += chunk.byteLength;
        if (chunk.byteLength < EQ_CHUNK_BYTES) {
          break;   // 不足一块 = 到文件尾
        }
      }
    } finally {
      if (handle !== null) {
        fs.closeSync(handle);
      }
      if (this.activeRequest === request) {
        this.activeRequest = null;
      }
      try {
        request.destroy();
      } catch (e) {
        // 忽略
      }
    }
    if (this.activeTaskId !== taskId) {
      throw new Error('eq cancelled');
    }
    hilog.info(DOMAIN, TAG, 'eq raw downloaded: %{public}d bytes', offset);
  }

  /** 读一块；失败重试同一位置（CDN 停顿 / 连接被掐都很常见） */
  private async readChunk(request: http.HttpRequest, url: string, headers: Record<string, string>,
    offset: number, taskId: number): Promise<ArrayBuffer> {
    let lastError: string = '';
    for (let attempt = 0; attempt < EQ_CHUNK_RETRY; attempt++) {
      if (this.activeTaskId !== taskId) {
        throw new Error('eq cancelled');
      }
      const chunkHeaders: Record<string, string> = {
        'Range': `bytes=${offset}-${offset + EQ_CHUNK_BYTES - 1}`,
      };
      for (const h of Object.keys(headers)) {
        chunkHeaders[h] = headers[h];
      }
      try {
        const response: http.HttpResponse = await request.request(url, {
          method: http.RequestMethod.GET,
          header: chunkHeaders,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false,
          connectTimeout: EQ_CHUNK_CONNECT_MS,
          readTimeout: EQ_CHUNK_READ_MS,
        });
        const code: number = response.responseCode;
        if (code !== 206 && code !== 200) {
          throw new Error(`http ${code}`);
        }
        if (code === 200) {
          // 服务器不认 Range：这份就是整个文件，只会出现在第一块
          if (offset > 0) {
            throw new Error('mixed 200/206 response');
          }
        }
        const chunk: ArrayBuffer = response.result as ArrayBuffer;
        if (chunk === undefined || chunk.byteLength === 0) {
          throw new Error('empty chunk');
        }
        return chunk;
      } catch (e) {
        lastError = JSON.stringify(e);
        hilog.warn(DOMAIN, TAG, 'eq chunk at %{public}d failed (try %{public}d/%{public}d): %{public}s',
          offset, attempt + 1, EQ_CHUNK_RETRY, lastError);
        await this.sleep(300 * (attempt + 1));
      }
    }
    throw new Error(`eq download failed at ${offset}: ${lastError}`);
  }

  private unlinkQuietly(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // 忽略
    }
  }
}
