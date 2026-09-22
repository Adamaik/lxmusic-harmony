import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackService } from './PlaybackService';
import { PlaySettings } from '../settings/PlaySettings';

const DOMAIN: number = 0x0001;
const TAG: string = 'LxPlayer';

export type LxPlayerStatus = 'idle' | 'loading' | 'playing' | 'paused' | 'stopped' | 'error';

/** 播放状态变化（error 时 message 是失败原因） */
export type LxPlayerStateListener = (status: LxPlayerStatus, message: string) => void;
/** 播放进度（毫秒），由 AVPlayer 的 timeUpdate / durationUpdate 驱动 */
export type LxPlayerTimeListener = (currentMs: number, durationMs: number) => void;
/** 一首播完 */
export type LxPlayerCompletionListener = () => void;
/**
 * 缓冲状态变化
 *
 * buffering = 播放器正在等数据（此刻声音是断的）；
 * bufferedEndMs = 已缓冲到的位置（能播到哪儿），见 getBufferedEndMs。
 */
export type LxPlayerBufferListener = (buffering: boolean, bufferedEndMs: number) => void;

/**
 * 缓冲时长（秒）
 *
 * 单位是秒、官方取值范围 [1, 20]，所以 20 就是平台硬上限。
 * （官方《在线视频播放卡顿优化》里那句「缓冲区大小 = preferredBufferDuration × 1MB」
 * 是视频场景按码率折成字节的启发式换算，对音频不成立，别当 MB 读。）
 * 取满 20：这首 20 秒的余量吃满之后基本不用再盯网络，网络时好时坏也不会一卡一卡。
 */
const BUFFER_SECONDS: number = 20;
/**
 * 起播 / 卡顿后恢复播放的水位线（秒）
 *
 * 缓冲区里攒够这么多秒才出声/恢复。默认那条水位线在弱网下只有约 1 秒的量，
 * 结果是「响一下、卡一下、再响一下」；攒到 8 秒再恢复，代价是起播/恢复时多等一会儿，
 * 换来的是恢复之后能连续播下去（带宽够时攒 8 秒只要一两秒）。
 */
const RESUME_WATERLINE_SECONDS: number = 8;
/**
 * 「卡住了」的判定：正在播、但进度这么久没往前走（毫秒）
 *
 * 用它当缓存让路的依据之一：bufferingUpdate 那套事件在真机上只在上手阶段来一批
 * （见 docs/PLAYBACK_BUFFER.md），指望不上；进度停住是**自己就能测到**的饥饿信号。
 */
const STALL_MS: number = 3000;

/**
 * 多久问一次播放器「已经加载到哪儿」（毫秒）
 *
 * 这是进度条上那条灰段的**正路**：`getLoadedTimeRanges()` 返回播放器本地已加载的时间区间
 * （`[min, max]` 毫秒），等价于 iOS 的 `loadedTimeRanges`、web 的 `buffered`、
 * ExoPlayer 的 `getBufferedPosition()` —— 各家进度条上那条浅色段画的就是它。
 * 一秒问一次足够（进度本身也是每秒刷一次），别问太勤。
 */
const LOADED_PROBE_MS: number = 1000;

/**
 * 播放器封装（AVPlayer）
 *
 * 播放链路：内置搜索得到 musicInfo -> 导入的源规则解析出播放链接 -> 这里播放。
 * 播放的是网络音频，因此同样依赖 ohos.permission.INTERNET。
 *
 * 状态与进度的唯一来源是 AVPlayer 自己：调用方（PlaySession）不再自己造
 * 「正在播放」和假进度，否则界面会在没有声音的时候也一路走进度条。
 */
export class LxPlayer {
  private static instance: LxPlayer | null = null;

  static getInstance(): LxPlayer {
    if (LxPlayer.instance === null) {
      LxPlayer.instance = new LxPlayer();
    }
    return LxPlayer.instance;
  }

  private avPlayer: media.AVPlayer | null = null;
  /** 播放本地缓存文件时打开的句柄：release 时一定要关掉，否则 fd 会泄漏 */
  private fdHandle: fs.File | null = null;
  private status: LxPlayerStatus = 'idle';
  private message: string = '';
  private durationMs: number = 0;
  private currentMs: number = 0;

  private stateListeners: LxPlayerStateListener[] = [];
  private timeListeners: LxPlayerTimeListener[] = [];
  private completionListeners: LxPlayerCompletionListener[] = [];
  private bufferListeners: LxPlayerBufferListener[] = [];
  /** 播放器此刻是不是在等数据（AVPlayer 的 BUFFERING_START/END） */
  private buffering: boolean = false;
  /** 缓冲区余量（ms）：已缓冲数据还能播多久（CACHED_DURATION 的原值） */
  private cachedMs: number = 0;
  /**
   * 已缓冲到的位置（ms），本首歌内只增不减
   *
   * 算法照抄官方实践样例（媒体开发实践 - 基于AVPlayer播放网络视频实践）：
   *   bufferedEnd = max(bufferedEnd, 当前进度 + CACHED_DURATION)
   * CACHED_DURATION 是「已缓冲数据还能播多久」（前量），加上当前进度才是「能播到哪儿」；
   * 而它是个预估值、会来回波动，缓冲终点在实心上却只会往前 —— 所以取 max。
   * 不取 max 的后果是实打实的：事件一停（比如播放器下够了就不再上报），
   * 拿旧的前量跟着播放头一路加，进度条上那条灰段就会永远比已播长「固定一截」，是假的。
   */
  private bufferedEndMs: number = 0;
  /**
   * 播放器**本地已加载到**哪儿（ms）：`getLoadedTimeRanges()` 里最远那段区间的右端
   *
   * 和 bufferedEndMs 的区别：那个是事件上报推出来的（会漏、会停），这个是主动问来的，
   * 而且正是业界进度条上那条灰段的数据源。
   */
  private loadedEndMs: number = 0;
  /** 上一次问「加载到哪儿」的时刻（节流） */
  private loadedProbeAt: number = 0;
  /** 这台设备/版本还能不能问 getLoadedTimeRanges（API 26 起；不支持就不再问） */
  private loadedProbeOk: boolean = true;
  /** 最近一次播放进度往前走的时刻：判断「卡住」用（见 STALL_MS） */
  private lastProgressAt: number = 0;

  // ------------------------------------------------------------ 订阅

  addStateListener(listener: LxPlayerStateListener): void {
    if (!this.stateListeners.includes(listener)) {
      this.stateListeners.push(listener);
    }
  }

  removeStateListener(listener: LxPlayerStateListener): void {
    const next: LxPlayerStateListener[] = [];
    for (const item of this.stateListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.stateListeners = next;
  }

  addTimeListener(listener: LxPlayerTimeListener): void {
    if (!this.timeListeners.includes(listener)) {
      this.timeListeners.push(listener);
    }
  }

  removeTimeListener(listener: LxPlayerTimeListener): void {
    const next: LxPlayerTimeListener[] = [];
    for (const item of this.timeListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.timeListeners = next;
  }

  addCompletionListener(listener: LxPlayerCompletionListener): void {
    if (!this.completionListeners.includes(listener)) {
      this.completionListeners.push(listener);
    }
  }

  removeCompletionListener(listener: LxPlayerCompletionListener): void {
    const next: LxPlayerCompletionListener[] = [];
    for (const item of this.completionListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.completionListeners = next;
  }

  addBufferListener(listener: LxPlayerBufferListener): void {
    if (!this.bufferListeners.includes(listener)) {
      this.bufferListeners.push(listener);
    }
  }

  removeBufferListener(listener: LxPlayerBufferListener): void {
    const next: LxPlayerBufferListener[] = [];
    for (const item of this.bufferListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.bufferListeners = next;
  }

  // ------------------------------------------------------------ 查询

  getStatus(): LxPlayerStatus {
    return this.status;
  }

  getMessage(): string {
    return this.message;
  }

  getDurationMs(): number {
    return this.durationMs;
  }

  getCurrentMs(): number {
    return this.currentMs;
  }

  isPlaying(): boolean {
    return this.status === 'playing';
  }

  /** 播放器此刻是不是在等数据（声音是断的） */
  isBuffering(): boolean {
    return this.buffering;
  }

  /** 缓冲区余量（ms）：已缓冲的数据还能连续播多久 */
  getCachedMs(): number {
    return this.cachedMs;
  }

  /**
   * 已缓冲到的位置（ms）：进度条上那条灰段该画到哪儿
   *
   * 取三者最靠前：播放器已加载区间（正路，见 loadedEndMs）、事件上报推出来的位置、
   * 以及当前播放进度（缓冲终点不可能落在播放头后面，灰段短于白段没法看）。
   * 本地播放没有加载区间也不会变，调用方按整首处理，不走这里。
   */
  getBufferedEndMs(): number {
    let end: number = this.loadedEndMs > this.bufferedEndMs ? this.loadedEndMs : this.bufferedEndMs;
    return end > this.currentMs ? end : this.currentMs;
  }

  /**
   * 问一下播放器「本地加载到哪儿了」
   *
   * 每秒一次（跟进度同一个节奏），只取区间里最远的那个右端；只增不减（回退 seek 时
   * 已加载的数据仍然在本地，不该往回收）。失败一次就关掉这条路退回事件那套 ——
   * 这台设备是 API 26 支持，但低版本设备上这个方法是空的。
   */
  private probeLoadedRange(): void {
    if (!this.loadedProbeOk) {
      return;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || (this.status !== 'playing' && this.status !== 'paused')) {
      return;
    }
    const now: number = Date.now();
    if (now - this.loadedProbeAt < LOADED_PROBE_MS) {
      return;
    }
    this.loadedProbeAt = now;
    try {
      player.getLoadedTimeRanges().then((ranges: Array<media.Range>) => {
        if (this.avPlayer !== player) {
          return;
        }
        let end: number = 0;
        for (const range of ranges) {
          if (range.max > end) {
            end = range.max;
          }
        }
        if (end > this.loadedEndMs) {
          this.loadedEndMs = end;
          this.emitBufferState();
        }
      }).catch((err: BusinessError) => {
        this.loadedProbeOk = false;
        hilog.warn(DOMAIN, TAG, 'getLoadedTimeRanges failed, fallback to events: %{public}s',
          `${err.code} ${err.message}`);
      });
    } catch (err) {
      this.loadedProbeOk = false;
      hilog.warn(DOMAIN, TAG, 'getLoadedTimeRanges unavailable on this device');
    }
  }

  /** 把当前缓冲状态再播一遍给订阅方（加载区间变了，但 buffering / 事件值没变时用） */
  private emitBufferState(): void {
    const listeners: LxPlayerBufferListener[] = this.bufferListeners.slice();
    for (const listener of listeners) {
      listener(this.buffering, this.getBufferedEndMs());
    }
  }

  /**
   * 现在能不能把带宽让给后台的播放缓存下载
   *
   * 顺序上「播放优先」，但只看**真的**说明播放器在挨饿的信号，不设固定门槛：
   *   - 播放器正在等数据（`buffering`，声音是断的）→ 不让；
   *   - 正在起播 / 切歌（`loading`）→ 不让，它要抢首屏缓冲；
   *   - 正在播、但进度已经 STALL_MS 没动 → 不让（自己测出来的卡顿）；
   *   - 其余（正常播 / 暂停 / 停止 / 空闲 / 出错）→ 让，缓存按网络能给的速度下。
   *
   * 曾经这里有过两版"人工节奏"，都删了：一是「缓冲区余量 ≥ 30 秒才让」——
   * 真机只报到 13 秒，那条线永远不成立，结果是整首都不下缓存；二是「起播后先让 4 秒」——
   * 表现为进度条那条灰段开头干等几秒，像坏了。缓存该多快就多快，只在播放挨饿时让路。
   */
  canUseBandwidthForCache(): boolean {
    if (this.buffering || this.status === 'loading') {
      return false;
    }
    if (this.status === 'playing' && this.lastProgressAt !== 0
      && Date.now() - this.lastProgressAt >= STALL_MS) {
      return false;
    }
    return true;
  }

  private update(status: LxPlayerStatus, message: string): void {
    this.status = status;
    this.message = message;
    // 同步给系统媒体卡（锁屏 / 控制中心）：状态一变就刷，同时顺带把后台播放任务立起来
    PlaybackService.getInstance().updateState(status, this.currentMs, this.durationMs);
    const listeners: LxPlayerStateListener[] = this.stateListeners.slice();
    for (const listener of listeners) {
      listener(status, message);
    }
  }

  /**
   * 缓冲状态变了：通知订阅方（界面转圈、进度条灰段、缓存调度让路都看它）
   *
   * cachedMs > 0 时顺手把「缓冲终点」往前推（只增不减，见 bufferedEndMs）。
   * START/END 事件带的是上一次的前量，算出来的终点不会超过已记录的，所以不会虚增。
   */
  private updateBuffer(buffering: boolean, cachedMs: number): void {
    if (this.buffering === buffering && this.cachedMs === cachedMs) {
      return;
    }
    this.buffering = buffering;
    this.cachedMs = cachedMs;
    if (cachedMs > 0) {
      const candidate: number = this.currentMs + cachedMs;
      if (candidate > this.bufferedEndMs) {
        this.bufferedEndMs = candidate;
      }
    }
    const listeners: LxPlayerBufferListener[] = this.bufferListeners.slice();
    for (const listener of listeners) {
      listener(this.buffering, this.getBufferedEndMs());
    }
  }

  /**
   * 记一条缓冲水位的日志（只记「往前长了 1 秒以上」的）
   *
   * 上手那一下会连着来几十条 500ms 级的事件（真机实测 120ms 内来了 25 条），
   * 全记会把日志冲爆、还可能触发 hilog 流控把别的日志丢掉，所以只记有意义的增量。
   */
  private logBufferGrowth(cachedMs: number): void {
    const end: number = this.currentMs + cachedMs;
    if (end < this.bufferedEndMs + 1000) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'bufferingUpdate: cached %{public}dms, at %{public}dms -> end %{public}dms',
      cachedMs, this.currentMs, end);
  }

  private emitTime(currentMs: number, durationMs: number): void {
    if (currentMs !== this.currentMs) {
      // 进度真的往前走了：记一下，缓存让路靠它判断「有没有卡住」
      this.lastProgressAt = Date.now();
    }
    this.currentMs = currentMs;
    if (durationMs > 0) {
      this.durationMs = durationMs;
    }
    // 进度按秒节流回写，锁屏进度条靠 AVPlaybackState 自带的时间戳自行外推
    PlaybackService.getInstance().updatePosition(currentMs);
    // 顺带问一下播放器本地加载到哪儿了（进度条那条灰段的真实来源）
    this.probeLoadedRange();
    const listeners: LxPlayerTimeListener[] = this.timeListeners.slice();
    for (const listener of listeners) {
      listener(currentMs, this.durationMs);
    }
  }

  private emitCompleted(): void {
    const listeners: LxPlayerCompletionListener[] = this.completionListeners.slice();
    for (const listener of listeners) {
      listener();
    }
  }

  // ------------------------------------------------------------ 播放控制

  /** 播放一个网络音频地址（先释放上一个实例） */
  async playUrl(url: string): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    // state 为 idle 时设置 url 会进入 initialized，随后由 stateChange 驱动 prepare/play
    player.url = url;
  }

  /**
   * 播放一个**需要请求头**的网络音频地址（WebDAV 这类要 Basic 认证的源）
   *
   * 为什么不用 `player.url`：url 是裸字符串，没有任何地方能挂 `Authorization`，
   * 而 WebDAV 服务器一定要求认证。官方给的带请求头的形态是
   * `media.createMediaSourceWithUrl(url, headers)` + `setMediaSource(src, strategy)`，
   * 而且它允许**设源的同时把播放策略一起给**（缓冲水位那两项），所以我们不必再走
   * 「initialized 态里补 setPlaybackStrategy」那一步（见 prepareWithStrategy）。
   *
   * 失败时不阻断：退回不带头的 `player.url`（匿名可读的服务器照样能放），
   * 真的放不出来由播放器的错误回调报上去。
   */
  async playUrlWithHeaders(url: string, headers: Record<string, string>): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    try {
      const source: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
      await player.setMediaSource(source, this.playbackStrategy());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setMediaSource with headers failed, fallback to url: %{public}s',
        JSON.stringify(err));
      if (this.avPlayer !== player) {
        return;
      }
      try {
        player.url = url;
      } catch (e) {
        this.update('error', `播放失败：${(e as BusinessError).message}`);
      }
    }
  }

  /**
   * 播放本地缓存文件（AudioCache 下好的整首）
   *
   * 用 fdSrc 而不是 file:// 路径：沙箱文件的绝对路径在不同版本上对 AVPlayer 的
   * 可见性不一样，fd 是明确支持的形态。句柄存起来，release 时释放播放器后再关。
   */
  async playLocal(path: string): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    this.fdHandle = file;
    const source: media.AVFileDescriptor = { fd: file.fd };
    player.fdSrc = source;
  }

  /** 建实例、挂监听；url / fdSrc 由调用方在这一步之后设置 */
  private async preparePlayer(): Promise<media.AVPlayer> {
    await this.release();
    this.update('loading', '正在加载音频…');
    this.durationMs = 0;
    this.currentMs = 0;
    // 换了实例：缓冲水位从零开始（上一次的转圈状态也要收掉、灰段也要从头长）
    this.bufferedEndMs = 0;
    this.updateBuffer(false, 0);

    const player: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = player;
    try {
      // 不设的话部分设备会落到提示音/系统音通道上，听感上就是「没声音」。
      // 这个属性只能在 idle 态设置，而且必须在 prepare 之前。
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0,
      };
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set audioRendererInfo failed: %{public}s', JSON.stringify(err));
    }

    player.on('stateChange', (state: media.AVPlayerState) => {
      // 已被新实例替换或已释放的旧回调直接忽略
      if (this.avPlayer !== player) {
        return;
      }
      switch (state) {
        case 'initialized':
          // 播放策略只能在 initialized 态设、且必须在 prepare 之前，
          // 所以这里先把 prepare 往后放一拍（见 applyPlaybackStrategy）
          void this.prepareWithStrategy(player);
          break;
        case 'prepared':
          // 音频焦点模式要在首次 play() 之前设，prepared 正好是唯一能设又还没出声的时机
          this.applyInterruptMode(player, PlaySettings.getInstance().isPlayWithOthers());
          player.play().catch((err: BusinessError) => {
            this.update('error', `播放失败：${err.message}`);
          });
          break;
        case 'playing':
          this.update('playing', '正在播放');
          break;
        case 'paused':
          this.update('paused', '已暂停');
          break;
        case 'completed':
          this.update('stopped', '播放完成');
          this.emitCompleted();
          break;
        case 'stopped':
          this.update('stopped', '已停止');
          break;
        case 'error':
          this.update('error', '播放器进入错误状态');
          break;
        default:
          break;
      }
    });
    // 缓冲水位：只在网络播放时有回调。BUFFERING_START/END 是「声音断了 / 续上了」，
    // CACHED_DURATION 是余量还能播多久 —— 界面转圈和后台缓存让路都靠这几个值。
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      switch (infoType) {
        case media.BufferingInfoType.BUFFERING_START:
          this.updateBuffer(true, this.cachedMs);
          break;
        case media.BufferingInfoType.BUFFERING_END:
          this.updateBuffer(false, this.cachedMs);
          break;
        case media.BufferingInfoType.CACHED_DURATION:
          // 官方实践样例也是这么打的：缓冲条不对时，先看这几个数
          this.logBufferGrowth(value);
          this.updateBuffer(this.buffering, value);
          break;
        default:
          break;
      }
    });
    player.on('durationUpdate', (duration: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      if (duration > 0) {
        this.emitTime(this.currentMs, duration);
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      this.emitTime(time, this.durationMs);
    });
    player.on('error', (err: BusinessError) => {
      if (this.avPlayer !== player) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'playback error: %{public}s', `${err.code} ${err.message}`);
      this.update('error', `播放错误：${err.message}`);
    });
    return player;
  }

  /**
   * 播放策略（缓冲水位）
   *
   * 抽出来是因为有两个设置点：走 `player.url` 时只能在 initialized 态用
   * `setPlaybackStrategy` 补（见 prepareWithStrategy），走 `setMediaSource` 时
   * 可以随源一起给（见 playUrlWithHeaders）。两处的值必须一致，所以只有这一份。
   */
  private playbackStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: BUFFER_SECONDS,
      preferredBufferDurationForPlaying: RESUME_WATERLINE_SECONDS,
    };
  }

  /**
   * 设好播放策略再 prepare
   *
   * `setPlaybackStrategy` 只能在 initialized 态调用，而 prepare 会把它推离这个状态，
   * 所以两件事必须按顺序来（setMediaSource 那条路虽然也能带策略，但它要求源与策略同时给，
   * 而我们走的是 player.url，策略只能这样补上）。
   * 设策略失败不阻断播放：个别设备/版本不支持时退回系统默认，别让用户直接听不成。
   */
  private async prepareWithStrategy(player: media.AVPlayer): Promise<void> {
    const strategy: media.PlaybackStrategy = this.playbackStrategy();
    try {
      await player.setPlaybackStrategy(strategy);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setPlaybackStrategy failed, use default: %{public}s',
        JSON.stringify(err));
    }
    if (this.avPlayer !== player) {
      return;
    }
    try {
      await player.prepare();
    } catch (err) {
      this.update('error', `准备音频失败：${(err as BusinessError).message}`);
    }
  }

  async pause(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null && this.status === 'playing') {
      await player.pause();
    }
  }

  /**
   * 「与其他应用同时播放」——对应 AVPlayer 的音频焦点模式
   *
   * 系统默认是 SHARE_MODE（0）：几个流共享一个中断单元，别的应用一出声就把我们打断。
   * 允许同时播放就是 INDEPENDENT_MODE（1）：各自的流互不打断，混在一起响，
   * 这也是导航类应用要「压着音乐播」时用的模式。
   * 属性只能在 prepared/playing/paused/completed 态设置，且首次 play() 之后才设就不算数，
   * 所以真正生效点是 preparePlayer 的 prepared 回调（见 applyInterruptMode）。
   */
  setPlayWithOthers(value: boolean): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status !== 'playing' && this.status !== 'paused') {
      return;
    }
    this.applyInterruptMode(player, value);
  }

  private applyInterruptMode(player: media.AVPlayer, withOthers: boolean): void {
    try {
      player.audioInterruptMode = withOthers
        ? audio.InterruptMode.INDEPENDENT_MODE
        : audio.InterruptMode.SHARE_MODE;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set audioInterruptMode failed: %{public}s', JSON.stringify(err));
    }
  }

  async resume(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null && this.status === 'paused') {
      await player.play();
    }
  }

  /** 拖动进度条：毫秒（AVPlayer.seek 返回 void，只在 prepared/playing/paused/completed 态可用） */
  seek(ms: number): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status !== 'playing' && this.status !== 'paused') {
      return;
    }
    const target: number = ms > 0 ? Math.floor(ms) : 0;
    try {
      player.seek(target);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', JSON.stringify(err));
    }
  }

  async stop(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null) {
      await player.stop();
    }
  }

  async release(): Promise<void> {
    const player = this.avPlayer;
    this.avPlayer = null;
    if (player !== null) {
      try {
        player.off('stateChange');
        player.off('durationUpdate');
        player.off('timeUpdate');
        player.off('bufferingUpdate');
        player.off('error');
        await player.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'release failed: %{public}s', JSON.stringify(err));
      }
    }
    // 播放器先释放，再关本地文件句柄：反过来可能让播放器读到一个已关闭的 fd
    const handle = this.fdHandle;
    this.fdHandle = null;
    if (handle !== null) {
      try {
        fs.closeSync(handle);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'close fd failed: %{public}s', JSON.stringify(err));
      }
    }
    this.status = 'idle';
    this.message = '';
    this.durationMs = 0;
    this.currentMs = 0;
    this.bufferedEndMs = 0;
    this.loadedEndMs = 0;
    this.loadedProbeAt = 0;
    this.lastProgressAt = 0;
    // 释放不经过 stateChange：在这里把缓冲状态收掉，界面才不会一直转圈
    this.updateBuffer(false, 0);
  }
}
