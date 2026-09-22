import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { PlaySettings } from '../settings/PlaySettings';
import { LyricLine, activeLyricIndex, parseLyric } from '../music/Lyric';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlaybackService';

/** 会话标签：系统里标识本应用的媒体会话 */
const SESSION_TAG: string = 'lx_music';
/** 媒体卡 / 长时任务点回本应用时打开的 ability */
const BUNDLE_NAME: string = 'com.example.listen';
const ABILITY_NAME: string = 'EntryAbility';
/** 进度回写节流：AVPlayer 的 timeUpdate 是 100ms 一次，锁屏进度条用不到这么密 */
const POSITION_INTERVAL_MS: number = 1000;
/** 锁屏封面的解码尺寸（媒体卡上的小图，不用原图尺寸） */
const COVER_SIZE: number = 300;
const COVER_TIMEOUT_MS: number = 8000;
/** 没有封面时的兜底图：应用自己的启动图标（媒体卡上就这么点大，几十 KB 的图足够） */
const FALLBACK_COVER_RES: string = 'startIcon';

/** 系统媒体控制（锁屏 / 控制中心 / 耳机按键）发来的指令 */
export type PlaybackCommand = 'play' | 'pause' | 'next' | 'prev' | 'seek' | 'stop';

/** 系统媒体控制（锁屏 / 控制中心 / 耳机按键）发来的指令回调 */
export type PlaybackCommandListener = (command: PlaybackCommand, positionMs: number) => void;

/**
 * 播控中心点「收藏」：参数是当前条目的 assetId
 *
 * 播控中心的控制元素对 audio 会话是固定的：收藏、上一首、播放/暂停、下一首、循环模式。
 * 「收藏」与「循环模式」这两个带参数，所以各自走一个监听，不塞进 PlaybackCommand。
 */
export type PlaybackFavoriteListener = (assetId: string) => void;

/** 播控中心改循环模式：list（列表循环）/ single（单曲循环）/ shuffle（随机） */
export type PlaybackLoopModeListener = (mode: string) => void;

/** 推给系统媒体卡的当前歌曲信息 */
export interface PlaybackMediaInfo {
  /** 唯一标识一首歌，系统按它区分「换歌」与「同一首更新」 */
  assetId: string;
  title: string;
  artist: string;
  album: string;
  durationMs: number;
  coverUrl: string;
  /** 上一首 / 下一首的 assetId：告诉系统两边还有歌可播，媒体卡的上一首/下一首按钮才会亮 */
  previousAssetId: string;
  nextAssetId: string;
  /** 是否已收藏：播控中心的收藏按钮据此显示实心/空心 */
  isFavorite: boolean;
}

/**
 * 系统音乐服务接入（AVSession + AUDIO_PLAYBACK 长时任务）
 *
 * 为什么必须有这两样：
 *  - 没有长时任务时，应用一退到后台（息屏、切走）就会被系统冻结，
 *    AVPlayer 也就跟着停了 —— 表现就是「一息屏就暂停」。
 *    `backgroundTaskManager.startBackgroundRunning(AUDIO_PLAYBACK)` 声明
 *    「我在后台放音频」，系统才允许进程继续跑。
 *  - 没有 AVSession 时，锁屏 / 控制中心没有媒体卡，耳机按键也没人接管。
 *    AVSession 提供标题、封面、播放状态与进度，并把系统发来的
 *    play / pause / 上一首 / 下一首 / 拖动进度 回调转给我们。
 *    按官方说明，接上 AVSession 之后通知由 AVSession 发，
 *    长时任务自己不再弹通知，所以不会多出一条常驻通知。
 *
 * 这个类刻意不依赖 LxPlayer / PlaySession：指令通过 PlaybackCommandListener 回调出去，
 * 状态与歌曲信息由它们推进来，避免三方互相 import 成环。
 *
 * 播控中心（媒体中心）除了标题/封面/进度，还能吃三样额外能力，这里都接上了：
 *  - 歌词：AVMetadata.lyric 传**标准 LRC**（带时间标签），系统自己按时间轴滚动显示；
 *    同一份数据也是系统「桌面歌词」悬浮窗的来源，见 setupDesktopLyric。
 *  - 收藏：注册 toggleFavorite 指令 + 回写 AVPlaybackState.isFavorite，
 *    播控中心那颗心就是本应用的收藏（对应洛雪的「我的收藏」）。
 *  - 循环模式：注册 setLoopMode 指令 + 回写 AVPlaybackState.loopMode。
 *
 * 另外还给**蓝牙设备**（车机、蓝牙音箱）供了一份歌词：AVMetadata.singleLyricText
 * 传「当前这一句」，系统蓝牙模块读它并下发给已连接的蓝牙设备。这份数据只走蓝牙，
 * 不影响播控中心，见 refreshBluetoothLyric。
 */
export class PlaybackService {
  private static instance: PlaybackService | null = null;

  static getInstance(): PlaybackService {
    if (PlaybackService.instance === null) {
      PlaybackService.instance = new PlaybackService();
    }
    return PlaybackService.instance;
  }

  private context: common.Context | null = null;
  private session: avSession.AVSession | null = null;
  private sessionCreating: boolean = false;
  /** 建会话失败（例如不支持 AVSession 的环境）后不再反复重试 */
  private sessionFailed: boolean = false;
  private listener: PlaybackCommandListener | null = null;
  private favoriteListener: PlaybackFavoriteListener | null = null;
  private loopModeListener: PlaybackLoopModeListener | null = null;

  // ------------------------------------------------------------ 当前歌曲
  private assetId: string = '';
  private title: string = '';
  private artist: string = '';
  private album: string = '';
  private coverUrl: string = '';
  private durationMs: number = 0;
  private previousAssetId: string = '';
  private nextAssetId: string = '';
  private hasMedia: boolean = false;
  /** 当前歌曲是否已收藏（播控中心的心） */
  private favorite: boolean = false;
  /** 歌词原文（标准 LRC；空串表示这首歌没有可用歌词） */
  private lyric: string = '';
  /** 歌词原文解析出来的行：蓝牙歌词要按「当前唱到哪句」推，播控中心那边由系统自己解析 */
  private lyricLines: LyricLine[] = [];
  /** 已经推给系统的「当前这一句」；没变就不重推，换一句才推一次 */
  private btLyricText: string = '';

  // ------------------------------------------------------------ 播放状态
  private state: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_IDLE;
  private positionMs: number = 0;
  private lastPushMs: number = 0;
  /** 循环模式（播控中心的循环按钮） */
  private loopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_LIST;

  // ------------------------------------------------------------ 桌面歌词
  /** 系统是否支持歌词组件（isDesktopLyricSupported） */
  private lyricSupported: boolean = false;
  /** lyricSupported 是否已经问过系统（没问过时不能拿 false 当「不支持」） */
  private lyricSupportKnown: boolean = false;
  private lyricEnabled: boolean = false;
  /** 当前是否让歌词悬浮窗显示着（避免重复调用 setDesktopLyricVisible） */
  private lyricVisible: boolean = false;

  // ------------------------------------------------------------ 长时任务
  private taskRunning: boolean = false;
  private taskStarting: boolean = false;

  // ------------------------------------------------------------ 锁屏封面
  /** 已经处理过的封面地址（成功或失败都记下来，避免反复解码） */
  private coverKey: string = '';
  private coverPixel: image.PixelMap | null = null;
  /** 这首歌没有封面时的兜底图，解一次缓存住；fallbackFailed 记「解不出来」不再重试 */
  private fallbackPixel: image.PixelMap | null = null;
  private fallbackFailed: boolean = false;

  // ------------------------------------------------------------ 生命周期

  /** 在 EntryAbility.onCreate 里调用，拿一个 Ability 的 Context */
  init(context: common.Context): void {
    this.context = context;
  }

  setCommandListener(listener: PlaybackCommandListener | null): void {
    this.listener = listener;
  }

  /** 播控中心「收藏」按钮（参数为 assetId） */
  setFavoriteListener(listener: PlaybackFavoriteListener | null): void {
    this.favoriteListener = listener;
  }

  /** 播控中心「循环模式」按钮 */
  setLoopModeListener(listener: PlaybackLoopModeListener | null): void {
    this.loopModeListener = listener;
  }

  /** Ability 销毁：收掉长时任务与会话 */
  close(): void {
    this.listener = null;
    this.favoriteListener = null;
    this.loopModeListener = null;
    this.stopBackgroundTask();
    const session = this.session;
    this.session = null;
    if (session !== null) {
      if (this.lyricEnabled) {
        // 会话销毁前先把歌词悬浮窗收掉，免得桌面上留一个没人管的窗口
        session.setDesktopLyricVisible(false).catch(() => {
        });
      }
      session.destroy().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'destroy session failed: %{public}s', JSON.stringify(err));
      });
    }
    // 会话没了，封面缓存也一起丢掉。coverKey 必须重置：不重置的话下次建会话再放到
    // 同一首歌时，resolveCover 会以为「这首已经解过」而直接返回空，封面永远上不来
    this.releaseCover();
    this.coverKey = '';
    this.releaseFallback();
  }

  // ------------------------------------------------------------ 对外：推歌曲信息

  /**
   * 更新当前歌曲（切歌、以及封面异步解析出来后都要调一次）
   *
   * 会话是懒建的：第一次有歌时才创建，避免应用启动就占一个媒体会话。
   */
  updateMedia(info: PlaybackMediaInfo): void {
    const changed: boolean = info.assetId !== this.assetId;
    this.assetId = info.assetId;
    this.title = info.title;
    this.artist = info.artist;
    this.album = info.album;
    this.coverUrl = info.coverUrl;
    this.previousAssetId = info.previousAssetId;
    this.nextAssetId = info.nextAssetId;
    this.favorite = info.isFavorite;
    if (info.durationMs > 0) {
      this.durationMs = info.durationMs;
    }
    this.hasMedia = info.assetId.length > 0 && info.title.length > 0;
    if (!this.hasMedia) {
      return;
    }
    if (changed) {
      this.positionMs = 0;
      this.lastPushMs = 0;
      // 换歌了：上一首的歌词不能留在播控中心 / 桌面歌词 / 蓝牙设备上，等新歌词推上来再显示
      this.lyric = '';
      this.lyricLines = [];
      this.btLyricText = '';
      this.syncDesktopLyric();
    }
    this.applyMetadata();
  }

  /**
   * 更新当前歌曲的歌词
   *
   * 必须是**标准 LRC**（带 [mm:ss.xx] 时间标签）：系统靠时间标签自己滚动，
   * 没有时间标签的纯文本系统解析不了，会显示异常。没有可用歌词时传空串清掉。
   */
  updateLyric(lrc: string): void {
    if (lrc === this.lyric) {
      return;
    }
    this.lyric = lrc;
    /**
     * 蓝牙歌词是按「当前这一句」推的，所以这里顺手把新歌词解析成行、并先定位到当前句，
     * 让它跟着全量歌词**一次**推出去（换歌时就不会把上一首的句子留在车机上）。
     * 之后再按播放进度逐句更新，见 refreshBluetoothLyric。
     */
    this.lyricLines = lrc.length > 0 ? parseLyric(lrc) : [];
    this.btLyricText = this.currentBluetoothLine();
    const session = this.session;
    if (session !== null && this.hasMedia) {
      // 只刷新元数据里的歌词字段（其余字段照旧带上，避免被清空）
      this.pushMetadata(this.coverForPush()).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'push lyric failed: %{public}s', JSON.stringify(err));
      });
    }
    this.syncDesktopLyric();
  }

  /**
   * 车载蓝牙歌词：把「当前这一句」重推一次（变了才推）
   *
   * 由两个地方驱动：播放进度（updatePosition，逐句换）与设置开关（PlaySession.setBluetoothLyric）。
   * 关掉开关时 currentBluetoothLine 返回空串，于是这里推一次把字段清掉，
   * 蓝牙设备随即回到只显示歌名。
   */
  refreshBluetoothLyric(): void {
    const next: string = this.currentBluetoothLine();
    if (next === this.btLyricText) {
      return;
    }
    this.btLyricText = next;
    const session = this.session;
    if (session === null || !this.hasMedia) {
      return;
    }
    this.pushMetadata(this.coverForPush()).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'push bluetooth lyric failed: %{public}s', JSON.stringify(err));
    });
  }

  /**
   * 当前该出现在蓝牙设备上的那一句
   *
   * 开关关着、没有带时间轴的歌词、或还没唱到第一句时返回空串 —— 空串表示不下发这个字段。
   *
   * 只取原文那一句，不拼译文：车机与蓝牙音箱的歌词区通常只有窄窄一行，
   * 原文加译文会被截断，反而不如只给原文清楚。
   */
  private currentBluetoothLine(): string {
    if (!PlaySettings.getInstance().isBluetoothLyric()) {
      return '';
    }
    const index: number = activeLyricIndex(this.lyricLines, this.positionMs / 1000);
    if (index < 0) {
      return '';
    }
    return this.lyricLines[index].text;
  }

  /** 更新当前歌曲的收藏状态（播控中心的心：实心/空心） */
  updateFavorite(isFavorite: boolean): void {
    if (isFavorite === this.favorite) {
      return;
    }
    this.favorite = isFavorite;
    this.pushPlaybackState(true);
  }

  /**
   * 更新循环模式（播控中心的循环按钮：列表循环 / 单曲循环 / 随机）
   *
   * 应用内自己切了模式也要推一次，否则播控中心显示的图标跟实际播放行为对不上。
   */
  updateLoopMode(mode: string): void {
    const next: avSession.LoopMode = mapLoopMode(mode);
    if (next === this.loopMode) {
      return;
    }
    this.loopMode = next;
    hilog.info(DOMAIN, TAG, 'push loop mode: %{public}s', mode);
    this.pushPlaybackState(true);
  }

  // ------------------------------------------------------------ 对外：推播放状态

  /**
   * 播放状态变化（由 LxPlayer 的状态回调驱动）
   *
   * status 与 LxPlayer 的状态同名：idle / loading / playing / paused / stopped / error。
   */
  updateState(status: string, positionMs: number, durationMs: number): void {
    const next: avSession.PlaybackState = mapPlaybackState(status);
    if (durationMs > 0) {
      this.durationMs = durationMs;
    }
    if (positionMs >= 0) {
      this.positionMs = positionMs;
    }
    this.state = next;
    if (next === avSession.PlaybackState.PLAYBACK_STATE_PLAY ||
      next === avSession.PlaybackState.PLAYBACK_STATE_PREPARE) {
      // 一开始播就要把后台任务立起来（必须在应用还处于前台时申请）
      this.startBackgroundTask();
    } else if (next === avSession.PlaybackState.PLAYBACK_STATE_ERROR) {
      // 出错了就不该继续占着后台任务
      this.stopBackgroundTask();
    }
    this.ensureSession();
    this.pushPlaybackState(true);
    // 播放/暂停会影响桌面歌词悬浮窗的显隐（只在播的时候跟着滚）
    this.syncDesktopLyric();
  }

  /**
   * 进度（由 AVPlayer 的 timeUpdate 驱动，节流后回写）
   *
   * 蓝牙歌词的逐句判断放在节流**之前**：它只是一次二分查找加字符串比较，很便宜，
   * 而回写播放状态（进度条）没必要跟着每 100ms 一次，两者节奏不一样。
   */
  updatePosition(positionMs: number): void {
    if (positionMs < 0) {
      return;
    }
    this.positionMs = positionMs;
    this.refreshBluetoothLyric();
    const now: number = Date.now();
    if (now - this.lastPushMs < POSITION_INTERVAL_MS) {
      return;
    }
    this.pushPlaybackState(false);
  }

  /**
   * 停止播放（清空队列 / 用户主动停止）：收长时任务。
   *
   * 暂停**不**收任务：暂停后还要能被锁屏、车机、耳机按键唤起继续播，
   * 而进程一旦被冻结就收不到这些指令了。
   */
  stopPlayback(): void {
    this.state = avSession.PlaybackState.PLAYBACK_STATE_STOP;
    this.positionMs = 0;
    this.pushPlaybackState(true);
    this.stopBackgroundTask();
    // 停播后不会再有进度回调，车机／蓝牙音箱那头得主动撤掉最后一句歌词，
    // 否则它会一直停在停播前的那句话上
    if (this.btLyricText.length > 0 && this.session !== null) {
      this.btLyricText = '';
      this.pushMetadata(this.coverForPush()).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'clear bluetooth lyric failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  // ------------------------------------------------------------ 会话

  private ensureSession(): void {
    if (this.session !== null || this.sessionCreating || this.sessionFailed) {
      return;
    }
    const context = this.context;
    if (context === null) {
      hilog.warn(DOMAIN, TAG, 'no context, skip AVSession');
      this.sessionFailed = true;
      return;
    }
    this.sessionCreating = true;
    avSession.createAVSession(context, SESSION_TAG, 'audio').then((session: avSession.AVSession) => {
      this.sessionCreating = false;
      this.session = session;
      this.registerCommands(session);
      // 顺序按官方示例：先元数据、再播放态，最后 activate
      return this.applyMetadata().then(() => {
        return this.pushPlaybackState(true);
      }).then(() => {
        return session.activate();
      }).then(() => {
        // 会话激活后再声明能力：没激活时播控中心相关的声明可能被会话服务拒掉
        // （声明哪些控制元素、支持哪几种循环模式、开歌词组件）
        this.declareMediaCenterControls(session);
        this.declareLoopModes(session);
        return this.setupDesktopLyric(session);
      });
    }).then(() => {
      hilog.info(DOMAIN, TAG, 'AVSession ready');
    }).catch((err: BusinessError) => {
      this.sessionCreating = false;
      this.sessionFailed = true;
      hilog.error(DOMAIN, TAG, 'create AVSession failed: %{public}s', JSON.stringify(err));
    });
  }

  /**
   * 把系统发来的控制指令转给播放会话
   *
   * 每条命令单独注册、单独兜异常：之前是一整段 try 包住所有注册，
   * 中间任何一条抛异常（会话服务偶发问题、个别机型不支持某个命令），
   * 后面的命令就全都注册不上 —— 播控中心那颗「循环」按钮点了没反应就是这么来的。
   */
  private registerCommands(session: avSession.AVSession): void {
    this.tryRegister('play', () => {
      session.on('play', () => {
        this.dispatch('play', this.positionMs);
      });
    });
    this.tryRegister('pause', () => {
      session.on('pause', () => {
        this.dispatch('pause', this.positionMs);
      });
    });
    this.tryRegister('stop', () => {
      session.on('stop', () => {
        this.dispatch('stop', this.positionMs);
      });
    });
    this.tryRegister('playNext', () => {
      session.on('playNext', () => {
        this.dispatch('next', 0);
      });
    });
    this.tryRegister('playPrevious', () => {
      session.on('playPrevious', () => {
        this.dispatch('prev', 0);
      });
    });
    this.tryRegister('seek', () => {
      session.on('seek', (time: number) => {
        this.dispatch('seek', time);
      });
    });
    // 快进/快退给的是「跳过多少毫秒」（可缺省），换算成绝对位置再走 seek
    this.tryRegister('fastForward', () => {
      session.on('fastForward', (time?: number) => {
        this.dispatch('seek', this.positionMs + fastSeekStep(time));
      });
    });
    this.tryRegister('rewind', () => {
      session.on('rewind', (time?: number) => {
        const target: number = this.positionMs - fastSeekStep(time);
        this.dispatch('seek', target > 0 ? target : 0);
      });
    });
    // 播控中心的「收藏」：系统给出要切换收藏状态的那个 assetId
    this.tryRegister('toggleFavorite', () => {
      session.on('toggleFavorite', (assetId: string) => {
        const favoriteListener = this.favoriteListener;
        hilog.info(DOMAIN, TAG, 'system toggleFavorite: %{public}s', assetId);
        if (favoriteListener !== null) {
          favoriteListener(assetId);
        }
      });
    });
    // 播控中心的「循环模式」：系统发来的事件名有两个版本 ——
    //   setLoopMode（API 10）
    //   setTargetLoopMode（API 18，文档明确写着「应用应切换到请求的模式」）
    // 新系统发的是后者；只注册前者的话，点播控中心那颗按钮什么回调都收不到，
    // 表现就是「怎么点都没反应、图标也不变」。
    this.tryRegister('setLoopMode', () => {
      session.on('setLoopMode', (mode: avSession.LoopMode) => {
        this.handleLoopMode(mode);
      });
    });
    if (apiAtLeast(18)) {
      this.tryRegister('setTargetLoopMode', () => {
        session.on('setTargetLoopMode', (mode: avSession.LoopMode) => {
          this.handleLoopMode(mode);
        });
      });
    }
  }

  /** 单条控制命令的注册：失败只影响它自己，并留下日志便于排查 */
  private tryRegister(name: string, action: () => void): void {
    try {
      action();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'register %{public}s failed: %{public}s', name, JSON.stringify(err));
    }
  }

  /** 播控中心要求切循环模式：翻成应用内的模式名后转给监听方 */
  private handleLoopMode(mode: avSession.LoopMode): void {
    const loopModeListener = this.loopModeListener;
    const name: string = loopModeName(mode);
    hilog.info(DOMAIN, TAG, 'system loop mode change: %{public}s', name);
    if (loopModeListener !== null) {
      loopModeListener(name);
    }
  }

  /** 声明播控中心要显示哪些控制元素（声明什么，播控中心就亮什么） */
  private declareMediaCenterControls(session: avSession.AVSession): void {
    // setMediaCenterControlType 是 API 26 才有的接口；低版本上不声明，
    // 播控中心按我们注册过的指令自己决定显示哪些按钮，功能不受影响。
    if (!apiAtLeast(26)) {
      return;
    }
    const types: Array<avSession.AVMediaCenterControlType> =
      ['playPrevious', 'playNext', 'setLoopMode', 'toggleFavorite'];
    try {
      session.setMediaCenterControlType(types).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setMediaCenterControlType failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setMediaCenterControlType not available: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 声明本应用支持的循环模式（四种：顺序 / 单曲 / 列表 / 随机）
   *
   * 播控中心的循环按钮就在声明的这几种之间轮换；不声明的话系统只知道一部分，
   * 应用里的四种模式在播控中心就切不全。setSupportedLoopModes 是 API 26 的接口，
   * 低版本跳过（那时播控中心按 AVPlaybackState.loopMode 显示，功能仍可用）。
   */
  private declareLoopModes(session: avSession.AVSession): void {
    if (!apiAtLeast(26)) {
      return;
    }
    const modes: Array<avSession.LoopMode> = [
      avSession.LoopMode.LOOP_MODE_SEQUENCE,
      avSession.LoopMode.LOOP_MODE_SINGLE,
      avSession.LoopMode.LOOP_MODE_LIST,
      avSession.LoopMode.LOOP_MODE_SHUFFLE,
    ];
    try {
      session.setSupportedLoopModes(modes).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setSupportedLoopModes failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setSupportedLoopModes not available: %{public}s', JSON.stringify(err));
    }
  }

  // ------------------------------------------------------------ 桌面歌词（系统歌词悬浮窗）

  /**
   * 打开系统的歌词组件
   *
   * 歌词内容来自 AVMetadata.lyric（标准 LRC），系统自己按时间轴滚动，
   * 这里只负责「打开组件」这一件事；真正的显隐交给 syncDesktopLyric。
   * 设备/系统不支持（isDesktopLyricSupported 为假）或调用失败时静默跳过，
   * 播控中心里的歌词显示不受影响。
   *
   * 「设置 - 播放设置 - 桌面歌词」关着时不去 enableDesktopLyric：那一步在部分机型上
   * 会顺带要悬浮窗授权，用户既然关了这个功能就不该被打扰；之后他在设置里打开时，
   * 由 refreshDesktopLyric 补上这一步。
   */
  private setupDesktopLyric(session: avSession.AVSession): Promise<void> {
    return avSession.isDesktopLyricSupported().then((supported: boolean) => {
      this.lyricSupported = supported;
      this.lyricSupportKnown = true;
      if (!supported || !PlaySettings.getInstance().isDesktopLyric()) {
        return;
      }
      return session.enableDesktopLyric(true).then(() => {
        this.lyricEnabled = true;
        hilog.info(DOMAIN, TAG, 'desktop lyric enabled');
      });
    }).then(() => {
      this.syncDesktopLyric();
    }).catch((err: BusinessError) => {
      // 6600110/6600111：没开启或系统不支持，忽略即可
      hilog.warn(DOMAIN, TAG, 'setup desktop lyric failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 设备/系统是否支持桌面歌词（设置页据此提示：不支持时那个开关不会有实际效果） */
  isDesktopLyricSupported(): boolean {
    return this.lyricSupported;
  }

  /** 支持与否是否已经问过系统 */
  isDesktopLyricSupportKnown(): boolean {
    return this.lyricSupportKnown;
  }

  /**
   * 主动问一次系统是否支持桌面歌词
   *
   * 会话是在第一次推歌曲信息时才建的，所以「没播过歌就打开设置页」时
   * lyricSupported 还是初始的 false——直接拿它当「不支持」会误导用户。
   * 这个查询本身不依赖会话，设置页打开时问一次即可。
   */
  probeDesktopLyricSupport(): Promise<boolean> {
    return avSession.isDesktopLyricSupported().then((supported: boolean) => {
      this.lyricSupported = supported;
      this.lyricSupportKnown = true;
      return supported;
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'probe desktop lyric support failed: %{public}s', JSON.stringify(err));
      this.lyricSupportKnown = true;
      this.lyricSupported = false;
      return false;
    });
  }

  /**
   * 用户改了「桌面歌词」开关后重新同步
   *
   * 关掉 -> 收起悬浮窗；打开 -> 组件还没启用就先启用，再按播放状态决定显隐。
   * 这个类仍然不依赖 PlaySession，只读一下设置单例，指令与状态照旧从外面推进来。
   */
  refreshDesktopLyric(): void {
    const session = this.session;
    const want: boolean = PlaySettings.getInstance().isDesktopLyric();
    if (session !== null && want && this.lyricSupported && !this.lyricEnabled) {
      session.enableDesktopLyric(true).then(() => {
        this.lyricEnabled = true;
        this.syncDesktopLyric();
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'enable desktop lyric failed: %{public}s', JSON.stringify(err));
      });
      return;
    }
    this.syncDesktopLyric();
  }

  /**
   * 同步桌面歌词悬浮窗的显隐
   *
   * 有带时间轴的歌词、没被用户关掉、并且不是在「停播 / 出错」状态时显示，其余情况收起来。
   * 暂停时**不**收起：一会儿就续播了，窗口跟着一显一隐会闪；
   * 换歌、停止、没有词、用户关掉开关才收。
   */
  private syncDesktopLyric(): void {
    if (!this.lyricSupported || !this.lyricEnabled) {
      return;
    }
    const session = this.session;
    if (session === null) {
      return;
    }
    const dead: boolean = this.state === avSession.PlaybackState.PLAYBACK_STATE_STOP
      || this.state === avSession.PlaybackState.PLAYBACK_STATE_IDLE
      || this.state === avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    const want: boolean = PlaySettings.getInstance().isDesktopLyric() && this.lyric.length > 0 && !dead;
    if (want === this.lyricVisible) {
      return;
    }
    this.lyricVisible = want;
    session.setDesktopLyricVisible(want).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setDesktopLyricVisible failed: %{public}s', JSON.stringify(err));
    });
  }

  private dispatch(command: PlaybackCommand, positionMs: number): void {
    const listener = this.listener;
    hilog.info(DOMAIN, TAG, 'system command: %{public}s', command);
    if (listener === null) {
      return;
    }
    listener(command, positionMs > 0 ? positionMs : 0);
  }

  /** 推送播放状态与进度；AVPlaybackState.position 带时间戳，系统会自己外推进度 */
  private pushPlaybackState(force: boolean): Promise<void> {
    const session = this.session;
    if (session === null) {
      return Promise.resolve();
    }
    if (!force && this.state !== avSession.PlaybackState.PLAYBACK_STATE_PLAY) {
      // 非播放态不用刷进度
      return Promise.resolve();
    }
    const position: avSession.PlaybackPosition = {
      elapsedTime: this.positionMs,
      updateTime: Date.now(),
    };
    const state: avSession.AVPlaybackState = {
      state: this.state,
      speed: 1,
      position: position,
      // 播控中心的循环按钮与收藏按钮读这两个字段
      loopMode: this.loopMode,
      isFavorite: this.favorite,
    };
    if (this.durationMs > 0) {
      state.duration = this.durationMs;
    }
    this.lastPushMs = Date.now();
    return session.setAVPlaybackState(state).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', JSON.stringify(err));
    });
  }

  /**
   * 推送歌曲信息
   *
   * 分两步：先把文本信息写进去（会话才能尽快 activate），封面再异步补一次 ——
   * 封面要下载 + 解码，可能要好几秒，把 activate 卡在后面会让媒体卡迟迟不出现。
   *
   * 两次都拿 coverForPush() 现算该带哪张图：刚切歌时它先不带（等真封面解出来），
   * 解完（含失败）再带上该带的那张。所以**解析失败也要走第二次推送** ——
   * 那一次带的是兜底图，专门用来把上一首留在媒体卡上的封面顶掉。
   */
  private applyMetadata(): Promise<void> {
    const session = this.session;
    if (session === null || !this.hasMedia) {
      return Promise.resolve();
    }
    const assetId: string = this.assetId;
    const written: Promise<void> = this.pushMetadata(this.coverForPush());
    this.resolveCover().then((): Promise<void> => {
      // 解封面期间可能已经切歌，迟到的结果不要再写上去
      if (this.assetId !== assetId) {
        return Promise.resolve();
      }
      return this.pushMetadata(this.coverForPush());
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'push cover metadata failed: %{public}s', JSON.stringify(err));
    });
    return written;
  }

  /**
   * 真正写元数据
   *
   * cover 由 coverForPush() 决定：null 表示「这一轮先不带图」（封面还在路上），
   * 带兜底图表示「这首歌确实没有封面」。见 coverForPush 的说明。
   */
  private pushMetadata(cover: image.PixelMap | null): Promise<void> {
    const session = this.session;
    if (session === null) {
      return Promise.resolve();
    }
    const metadata: avSession.AVMetadata = {
      assetId: this.assetId,
      title: this.title,
      artist: this.artist,
      duration: this.durationMs,
    };
    if (this.album.length > 0) {
      metadata.album = this.album;
    }
    if (this.previousAssetId.length > 0) {
      metadata.previousAssetId = this.previousAssetId;
    }
    if (this.nextAssetId.length > 0) {
      metadata.nextAssetId = this.nextAssetId;
    }
    if (cover !== null) {
      metadata.mediaImage = cover;
    }
    /**
     * 封面还没解好时**不能**退回网络地址。
     *
     * mediaImage 的字符串形式只接受 uri（本地文件），塞 http 地址违反参数约定，
     * setAVMetadata 会整条被打回 —— 连同一批写进去的歌名、歌手一起丢了，
     * 表现就是投播面板 / 媒体卡「既没有封面也没有歌名」。宁可这一轮先不给图，
     * 等 resolveCover 解好了再推一次（见 applyMetadata）。
     */
    // 歌词：标准 LRC（带时间标签），系统按时间轴滚动显示
    if (this.lyric.length > 0) {
      metadata.lyric = this.lyric;
    }
    /**
     * 车载蓝牙歌词：当前这一句，纯文本、不带时间标签。
     *
     * singleLyricText 是系统为蓝牙歌词专设的字段（OpenHarmony 的对应需求就叫
     * 「蓝牙歌词增加 singleLyricText 字段」，API 17 起可用）：系统蓝牙模块读它，
     * 送到已连接的蓝牙设备（车机、蓝牙音箱）上显示。
     *
     * 它跟播控中心互不干扰 —— 那边歌名读 title、滚动歌词读 lyric，所以开这个功能
     * 不会让播控中心显示错乱（这一点跟 Android 上「把歌词写进标题」的做法完全不同，
     * 那种做法会污染通知栏与锁屏）。
     *
     * 空串也照写：这是「当前没有该显示的句子」（开关关着、还没唱到第一句、换歌途中），
     * 显式写空串而不是省略字段，免得系统按合并处理时把上一句留在车机上。
     */
    if (apiAtLeast(17)) {
      metadata.singleLyricText = this.btLyricText;
    }
    return session.setAVMetadata(metadata).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 当前这首歌已经解好的封面（不是这首歌的封面就返回 null） */
  private currentCover(): image.PixelMap | null {
    return this.coverKey === this.coverUrl ? this.coverPixel : null;
  }

  /**
   * 这一轮元数据该带哪张封面
   *
   * 系统只在这次带了 mediaImage 时才换图，不带就**沿用上一次的**。所以：
   *  - 已经解好 → 用解好的那张；
   *  - 还在解（刚切歌、或正在下载/解码）→ 返回 null，这一轮先不带图。媒体卡这时会
   *    继续显示上一张，等 resolveCover 回来立刻补推；先塞一张兜底图上去反而会闪一下；
   *  - 解过了、确实没有（coverUrl 为空，或本地/网络都取不到）→ 用兜底图。
   *    这一步不能省：不给图的话上一首的封面会一直留在播控中心，看着就是「封面串台」。
   */
  private coverForPush(): image.PixelMap | null {
    const current: image.PixelMap | null = this.currentCover();
    if (current !== null) {
      return current;
    }
    // coverKey 是「已经解过的那张的地址」：跟当前地址不一致说明还没解（或正在解）
    if (this.coverKey !== this.coverUrl) {
      return null;
    }
    return this.fallbackCover();
  }

  /**
   * 兜底封面：本应用的启动图标
   *
   * 没有封面的歌（本地歌里没内嵌图、平台也补不到图）也得给系统一张图，
   * 否则播控中心会一直留着上一首的封面 —— 那比空着更容易让人误解。
   * 用应用图标是因为「不给 mediaImage 时系统本来也是退回这个观感」，
   * 所以这么做不会比系统默认的行为更难看。
   *
   * 解一次就缓存住，失败也只试一次（不然每首歌都要白解一遍）。
   * 这里是同步解：图只有几十 KB，一次性、且只做一次，不值得为它把整条推送链改成异步。
   */
  private fallbackCover(): image.PixelMap | null {
    if (this.fallbackPixel !== null || this.fallbackFailed) {
      return this.fallbackPixel;
    }
    const context = this.context;
    if (context === null) {
      return null;
    }
    let source: image.ImageSource | null = null;
    try {
      const bytes: Uint8Array = context.resourceManager.getMediaByNameSync(FALLBACK_COVER_RES);
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const options: image.DecodingOptions = {
        desiredSize: { width: COVER_SIZE, height: COVER_SIZE },
      };
      const pixel: image.PixelMap = source.createPixelMapSync(options);
      this.fallbackPixel = pixel;
      return pixel;
    } catch (err) {
      this.fallbackFailed = true;
      hilog.warn(DOMAIN, TAG, 'decode fallback cover failed: %{public}s', JSON.stringify(err));
      return null;
    } finally {
      if (source !== null) {
        source.release().catch(() => {
        });
      }
    }
  }

  // ------------------------------------------------------------ 锁屏封面

  /**
   * 把封面地址解成 PixelMap
   *
   * AVSession 的 mediaImage 只吃 PixelMap（或系统读得到的本地 uri），网络地址系统不会
   * 自己去下，所以这里自己把图解出来：网络封面走网络下，本地封面读沙箱文件（decodeCover）。
   * 同一张封面只解一次，结果（含失败）缓存到 coverKey；解不出来返回 null，
   * 由 coverForPush 决定这一轮带不带图、要不要用兜底图。
   */
  private resolveCover(): Promise<image.PixelMap | null> {
    const url: string = this.coverUrl;
    if (url.length === 0) {
      this.releaseCover();
      this.coverKey = '';
      return Promise.resolve(null);
    }
    if (url === this.coverKey) {
      return Promise.resolve(this.coverPixel);
    }
    this.releaseCover();
    this.coverKey = url;
    return this.decodeCover(url).then((pixel: image.PixelMap | null) => {
      // 下载期间可能已经切歌，迟到的结果丢掉
      if (url !== this.coverKey) {
        if (pixel !== null) {
          pixel.release();
        }
        return null;
      }
      this.coverPixel = pixel;
      return pixel;
    });
  }

  private decodeCover(url: string): Promise<image.PixelMap | null> {
    // 本地封面（本地歌 / 云端歌的内嵌图）走文件通道，见 decodeLocalCover：
    // http 的 request 只支持 http/https，拿 file:// 地址去请求会直接报
    // 2300001 Unsupported protocol
    if (!isRemoteUrl(url)) {
      return this.decodeLocalCover(url);
    }
    return this.decodeRemoteCover(url);
  }

  /** 网络封面：自己下下来再解（网络地址系统不会替应用去下） */
  private async decodeRemoteCover(url: string): Promise<image.PixelMap | null> {
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: COVER_TIMEOUT_MS,
        readTimeout: COVER_TIMEOUT_MS,
      });
      if (response.responseCode !== http.ResponseCode.OK || !(response.result instanceof ArrayBuffer)) {
        hilog.warn(DOMAIN, TAG, 'cover http failed: %{public}d', response.responseCode);
        return null;
      }
      const source: image.ImageSource = image.createImageSource(response.result);
      const options: image.DecodingOptions = {
        desiredSize: { width: COVER_SIZE, height: COVER_SIZE },
      };
      const pixel: image.PixelMap = await source.createPixelMap(options);
      source.release();
      return pixel;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'decode cover failed: %{public}s', JSON.stringify(err));
      return null;
    } finally {
      if (request !== null) {
        request.destroy();
      }
    }
  }

  private releaseCover(): void {
    const pixel = this.coverPixel;
    this.coverPixel = null;
    if (pixel !== null) {
      pixel.release();
    }
  }

  /**
   * 本地封面：把沙箱里的图片文件解成 PixelMap
   *
   * 地址形如 `file://<bundleName>/data/storage/el2/...`（由 LocalMusic.coverUri /
   * WebDavLibrary.coverUrlOf 生成），http 通道读不了，但 image 能直接按沙箱路径读文件。
   * 之前只有网络那一条通道，本地歌的封面就永远解不出来 —— 播控中心要么空着，
   * 要么一直显示上一首的封面，正是「本地歌的封面到不了播控中心」的根因。
   */
  private async decodeLocalCover(uri: string): Promise<image.PixelMap | null> {
    try {
      // file://<bundleName>/<沙箱路径> 要先还原成沙箱路径；万一来源直接给的绝对路径就照用
      const path: string = uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri;
      // 文件可能已经不在了（导入之后用户清过数据），先探一下，
      // 免得 createImageSource 返回空后在下一步抛一个看不懂的错
      if (!fs.accessSync(path)) {
        hilog.warn(DOMAIN, TAG, 'local cover missing: %{public}s', path);
        return null;
      }
      const source: image.ImageSource = image.createImageSource(path);
      const options: image.DecodingOptions = {
        desiredSize: { width: COVER_SIZE, height: COVER_SIZE },
      };
      const pixel: image.PixelMap = await source.createPixelMap(options);
      source.release().catch(() => {
      });
      return pixel;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'decode local cover failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }

  private releaseFallback(): void {
    const pixel = this.fallbackPixel;
    this.fallbackPixel = null;
    if (pixel !== null) {
      pixel.release();
    }
  }

  // ------------------------------------------------------------ 长时任务

  /** 申请 AUDIO_PLAYBACK 长时任务（重复调用无害） */
  private async startBackgroundTask(): Promise<void> {
    if (this.taskRunning || this.taskStarting) {
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    this.taskStarting = true;
    try {
      const agent: WantAgent | null = await this.buildWantAgent();
      if (agent === null) {
        return;
      }
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.taskRunning = true;
      hilog.info(DOMAIN, TAG, 'background task (audioPlayback) started');
    } catch (err) {
      // 起不来也不影响前台播放，只是退到后台会被冻结
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}s', JSON.stringify(err));
    } finally {
      this.taskStarting = false;
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.taskRunning) {
      return;
    }
    const context = this.context;
    this.taskRunning = false;
    if (context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      hilog.info(DOMAIN, TAG, 'background task stopped');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 媒体卡 / 长时任务点回来的落点：本应用的入口 ability */
  private async buildWantAgent(): Promise<WantAgent | null> {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: BUNDLE_NAME,
          abilityName: ABILITY_NAME,
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    try {
      return await wantAgent.getWantAgent(info);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getWantAgent failed: %{public}s', JSON.stringify(err));
      return null;
    }
  }
}

/** 系统 API 等级是否达到某个版本（部分播控能力是 API 26 才有的） */
function apiAtLeast(level: number): boolean {
  try {
    return deviceInfo.sdkApiVersion >= level;
  } catch (e) {
    return false;
  }
}

/** 快进/快退步长：系统没给具体毫秒数时按 15 秒算 */
function fastSeekStep(time?: number): number {
  const DEFAULT_STEP: number = 15000;
  if (time === undefined || time <= 0) {
    return DEFAULT_STEP;
  }
  return time;
}

/**
 * 封面地址是不是要从网络取
 *
 * http 的 request 只吃 http/https；其余（file:// 沙箱 uri、绝对路径）都是本地文件，
 * 必须走 image 的文件解码那条路，否则本地歌的封面永远解不出来。
 */
function isRemoteUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

/** LxPlayer 的状态 -> 系统的播放状态 */
function mapPlaybackState(status: string): avSession.PlaybackState {
  if (status === 'playing') {
    return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
  }
  if (status === 'paused') {
    return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
  }
  if (status === 'loading') {
    return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
  }
  if (status === 'stopped') {
    return avSession.PlaybackState.PLAYBACK_STATE_STOP;
  }
  if (status === 'error') {
    return avSession.PlaybackState.PLAYBACK_STATE_ERROR;
  }
  return avSession.PlaybackState.PLAYBACK_STATE_IDLE;
}

/** 应用内的播放模式（list / order / single / shuffle）-> 系统的循环模式 */
function mapLoopMode(mode: string): avSession.LoopMode {
  if (mode === 'order') {
    return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }
  if (mode === 'single') {
    return avSession.LoopMode.LOOP_MODE_SINGLE;
  }
  if (mode === 'shuffle') {
    return avSession.LoopMode.LOOP_MODE_SHUFFLE;
  }
  return avSession.LoopMode.LOOP_MODE_LIST;
}

/** 系统的循环模式 -> 应用内的播放模式 */
function loopModeName(mode: avSession.LoopMode): string {
  if (mode === avSession.LoopMode.LOOP_MODE_SEQUENCE) {
    return 'order';
  }
  if (mode === avSession.LoopMode.LOOP_MODE_SINGLE) {
    return 'single';
  }
  if (mode === avSession.LoopMode.LOOP_MODE_SHUFFLE) {
    return 'shuffle';
  }
  return 'list';
}
