import { LxPlayer, LxPlayerStateListener, LxPlayerTimeListener, LxPlayerCompletionListener,
  LxPlayerStatus } from './LxPlayer';
import { PlaybackCommand, PlaybackMediaInfo, PlaybackService } from './PlaybackService';
import { SourceEngine } from '../source/SourceEngine';
import { LxMusicInfo, isSearchSupported, searchMusic } from '../music/MusicSearch';
import { CoverStore } from '../music/CoverStore';
import { AudioCache } from '../music/AudioCache';
import { CachedLyricInfo, MediaCache, mediaKeyOf } from '../music/MediaCache';
import { LyricLine, parseLyric } from '../music/Lyric';
import { musicIdOf } from '../music/MusicId';
import { PlatformLyric, fetchPlatformLyric } from '../music/PlatformLyric';
import { BridgeResult, LxQuality, SupportedSource } from '../source/LxTypes';
import { PlayStateStore } from './PlayStateStore';
import { PlaySettings } from '../settings/PlaySettings';
import { fallbackQuality, pickQuality } from '../music/Quality';
import { downloadedFile } from '../download/DownloadIndex';
import { publishFavoriteIds } from './FavoriteIndex';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlaySession';

/**
 * 播放会话 / 播放队列 / 播放历史
 *
 * 界面层（各视图）通过 AppStorage 里的这几个 key 订阅「当前播放」的状态，
 * 这样底部导航、迷你播放器、全屏播放器不用互相传参就能保持一致。
 *
 * 播放链路：条目里的 musicInfo（内置搜索得到）-> 导入的音源解析出播放链接 -> AVPlayer。
 * 洛雪的演示歌单/推荐/历史都只有歌名，没有 musicInfo，所以这里补了一步：
 * 遇到没有 musicInfo 的条目，先按「歌名 + 歌手」在当前音源支持的平台上搜一次，
 * 拿到真实 musicInfo 再走源规则解析。少了这一步，界面会在「演示模式」下假装播放，
 * 表现出来就是「点了播放没有声音」。
 */

export const K_QUEUE_COUNT: string = 'ps_queue_count';
export const K_CURRENT_ID: string = 'ps_current_id';
export const K_CURRENT_NAME: string = 'ps_current_name';
export const K_CURRENT_SINGER: string = 'ps_current_singer';
export const K_CURRENT_COVER: string = 'ps_current_cover';
export const K_CURRENT_ART: string = 'ps_current_art';
export const K_CURRENT_QUALITY: string = 'ps_current_quality';
export const K_PLAYER_STATUS: string = 'ps_player_status';
export const K_PROGRESS: string = 'ps_progress';
export const K_DURATION: string = 'ps_duration';
export const K_PLAY_MODE: string = 'ps_play_mode';
export const K_STATUS_TEXT: string = 'ps_status_text';
export const K_HISTORY_VERSION: string = 'ps_history_version';
/**
 * 底部迷你栏是展开还是折叠。
 * HdsTabs 的 MiniBar 由 HDS 自己管宽度与动效，内容只能通过它给的
 * onBarStyleChange 回调知道当前是哪种形态，所以把结果放到 AppStorage 里，
 * 让 MiniBar 的内容组件自己订阅（不依赖 builder 是否被重新调用）。
 */
export const K_MINI_EXPANDED: string = 'ps_mini_expanded';
/** 当前这首歌的歌词（LyricLine[]，由源的 lyric action 解析而来） */
export const K_LYRIC_LINES: string = 'ps_lyric_lines';
/** 歌词状态：none（没有/音源不支持）/ loading / ready */
export const K_LYRIC_STATUS: string = 'ps_lyric_status';
/**
 * 音乐库版本号
 *
 * 歌单/收藏/播放队列被同步服务端改动后，会把队列、收藏、歌单整个换掉（见
 * adoptLibraryState），此时订阅这个 key 的列表页需要重新读一次数据。
 */
export const K_LIBRARY_VERSION: string = 'ps_library_version';

/**
 * 音乐库变更的接收方
 *
 * 同步模块（LocalLibrary）实现它：界面上对歌单/收藏/播放队列的本地改动会经由它
 * 转成洛雪的同步动作上行到服务端。PlaySession 本身不依赖同步模块，避免循环引用。
 */
export interface LibrarySink {
  onLocalListsChanged(): void;
}

/** 队列 / 列表里的一首歌 */
export interface SongItem {
  id: string;
  name: string;
  singer: string;
  coverUrl: string;
  /** 无真实封面时是否使用洛雪内置的黑心占位封面 */
  art: boolean;
  /** 平台：kw / kg / mg / tx / wy；演示数据为空 */
  source: string;
  quality: string;
  /** mm:ss，用于展示与模拟进度 */
  interval: string;
  /** 真实搜索结果的 musicInfo JSON；演示数据为空串 */
  musicInfoJson: string;
}

/** 歌单列表项 */
export interface PlaylistSummary {
  id: string;
  name: string;
  count: number;
}

/** 音质协商与下载链路共用一份实现，见 core/music/Quality.ets */

/** 落盘的播放现场；字段/含义变了就改版本号，读到不认识的版本当没有 */
interface PersistedPlayState {
  version: number;
  /** 退出时正在播放的那首歌（整条存下来，队列里找不到也能显示/播放） */
  current?: SongItem | null;
  /** 退出时的播放进度（秒） */
  position?: number;
  playMode?: string;
  history?: SongItem[];
}

const PLAY_STATE_VERSION: number = 1;

/** 系统媒体卡用的歌曲标识：有条目 id 就用 id，演示数据退回「歌名 + 歌手」 */
function assetIdOf(item: SongItem): string {
  return item.id.length > 0 ? item.id : `${item.name}\u0001${item.singer}`;
}

function parseDuration(interval: string): number {
  const parts: string[] = interval.split(':');
  if (parts.length !== 2) {
    return 0;
  }
  const minutes: number = parseInt(parts[0], 10);
  const seconds: number = parseInt(parts[1], 10);
  if (isNaN(minutes) || isNaN(seconds)) {
    return 0;
  }
  return minutes * 60 + seconds;
}

function formatTime(seconds: number): string {
  const total: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
}

/** 歌词是否带时间轴（`[00:12.34]`）：没有时间轴就没法跟着进度滚 */
function hasTimeTag(lyric: string): boolean {
  return /\[\d{1,2}:.*\d{1,4}\]/.test(lyric);
}

/** 歌名归一化：去掉空白与括号类修饰，只用于「哪条搜索结果更像这首歌」的判断 */
function normalizeName(name: string): string {  let out: string = '';
  for (let i = 0; i < name.length; i++) {
    const ch: string = name.charAt(i).toLowerCase();
    if (ch === ' ' || ch === '\t' || ch === '（' || ch === '）' || ch === '(' || ch === ')') {
      continue;
    }
    out += ch;
  }
  return out;
}

let demoSeq: number = 0;

/**
 * 两条记录是不是同一首歌
 *
 * 不能用 id 直接比：队列落库再读回来时，条目 id 会变成洛雪新格式的
 * `${source}_${songmid}`（见 SyncConvert.fromLxMusicInfo），跟界面上的 `search_12` 对不上。
 * 所以按 musicInfo 里的「平台 + 歌曲 id（+ 酷狗的 hash）」比，这才是一首歌的真正身份；
 * 演示条目没有 musicInfo，退回「歌名 + 歌手」。
 */
function sameSong(a: SongItem, b: SongItem): boolean {
  const keyA: string = mediaKeyOf(a.musicInfoJson);
  const keyB: string = mediaKeyOf(b.musicInfoJson);
  if (keyA.length > 0 && keyB.length > 0) {
    return keyA === keyB;
  }
  return a.name.length > 0 && a.name === b.name && a.singer === b.singer;
}

/** 造一条演示歌曲（与截图里的歌单/历史保持一致） */
function demo(name: string, singer: string, interval: string, art: boolean = true): SongItem {
  demoSeq++;
  return {
    id: `demo_${demoSeq}`,
    name: name,
    singer: singer,
    coverUrl: '',
    art: art,
    source: '',
    quality: '128k',
    interval: interval,
    musicInfoJson: '',
  };
}

/** 由真实搜索结果转成队列条目 */
export function songFromSearch(info: LxMusicInfo, quality: string): SongItem {
  const json: string = JSON.stringify(info);
  // id 用「平台 + songmid（+ 酷狗 hash）」这种稳定标识，不用序号：
  // 收藏 / 歌单里的歌是从同步结构还原出来的，那边就是按这个规则算 id 的
  // （见 core/music/MusicId），两边不一致会出现「收藏了却查不到」（爱心不亮、重复收藏）。
  const songmid: string =
    info.songmid !== undefined && info.songmid !== null ? String(info.songmid) : '';
  if (songmid.length === 0) {
    // 缺 songmid 的条目同步不出去（SyncConvert 判它不可同步），也就不会出现在
    // 收藏/歌单里，这里退回序号保证列表里的 key 仍然唯一
    demoSeq++;
  }
  return {
    id: songmid.length > 0 ? musicIdOf(info) : `search_${demoSeq}`,
    name: info.name,
    singer: info.singer,
    coverUrl: info.img,
    art: false,
    source: info.source,
    quality: quality,
    interval: info.interval,
    musicInfoJson: json,
  };
}

export class PlaySession {
  private static instance: PlaySession | null = null;

  static getInstance(): PlaySession {
    if (PlaySession.instance === null) {
      PlaySession.instance = new PlaySession();
    }
    return PlaySession.instance;
  }

  /** 播放队列（对应洛雪的「播放列表」） */
  queue: SongItem[] = [];
  currentIndex: number = -1;
  /** 播放历史（我的 -> 播放历史） */
  history: SongItem[] = [];
  /** 收藏（我的 -> 收藏） */
  favorites: SongItem[] = [];
  /** 歌单 */
  playlists: PlaylistSummary[] = [];
  /**
   * 当前选中的音质
   *
   * 读写都转给 PlaySettings（设置 - 播放设置里的「播放音质」）：搜索页选音质、
   * 在线歌单往条目里塞音质，用的都应该是同一份用户设置，不能各存一个默认值。
   */
  get quality(): string {
    return PlaySettings.getInstance().getQuality();
  }

  set quality(value: string) {
    PlaySettings.getInstance().setQuality(value);
  }
  /**
   * 播放模式，四种：
   *   list    列表循环（放完最后一首回到第一首）
   *   order   顺序播放（放完最后一首就停）
   *   single  单曲循环（一首反复放；手动按上一首/下一首仍然换歌）
   *   shuffle 随机播放
   */
  playMode: string = 'list';

  private seeded: boolean = false;
  private playerWired: boolean = false;
  /** 歌名 -> 已经解析出真实 musicInfo 的条目，避免每次播放都重新搜索 */
  private resolveCache: Map<string, SongItem> = new Map();
  /** 正在等歌词的那首歌（切歌后旧歌词回来要丢掉） */
  private lyricToken: string = '';
  /** 切歌序号：只在最后一次切歌的链路里继续往下走 */
  private playToken: number = 0;
  /**
   * 队列版本号：整体换队列 / 增删歌都 +1。
   * 随机播放的一轮记录挂在它上面 —— 队列一换，之前的「放过哪些」就作废。
   */
  private queueVersion: number = 0;
  /** 随机播放：本轮已经放过的下标 */
  private shufflePlayed: Set<number> = new Set<number>();
  /** 随机播放：这一轮走过的顺序（「上一首」按它往回退） */
  private shuffleHistory: number[] = [];
  private shuffleVersion: number = -1;
  /** 界面提示（播放失败、缺音源等），由 UI 层挂一个 toast */
  private noticeListener: ((text: string) => void) | null = null;
  /** 同步模块挂上来的音乐库出口（未启用同步时为 null） */
  private librarySink: LibrarySink | null = null;
  /** 正在接受同步模块写入数据：此时不把自己的改动当作「本地改动」回传 */
  private adoptingLibrary: boolean = false;
  /** 音乐库是否已经把真实数据镜像进来（有则 seed() 不能再铺演示数据） */
  private libraryLoaded: boolean = false;
  /**
   * 这一轮播放的缓存现场
   *
   * 平台给的播放地址带时效，缓存里的地址可能已经过期。命中缓存却放不出来时，
   * 丢掉这条缓存重新解析一次（洛雪 isRefresh 的等价做法），别让用户干看着失败。
   */
  private currentCacheKey: string = '';
  private currentCacheQuality: string = '';
  private currentUrlFromCache: boolean = false;
  /** 这一轮是读本地缓存文件播的（文件坏了要删掉重来，别一直卡在这首） */
  private currentLocalPath: string = '';
  private urlRetried: boolean = false;
  /** 播放现场落盘 */
  private stateStore: PlayStateStore = new PlayStateStore();
  private stateInited: boolean = false;
  /**
   * 已经读过上次的播放现场。
   * 读之前一律不许回写：启动过程中音乐库镜像、seed() 都会调 pushQueueState，
   * 那时 currentIndex 还是 -1，回写就把存着的「正在播放」冲成空的了。
   */
  private stateRestored: boolean = false;
  private lastPersistAt: number = 0;
  /** 恢复现场后要接着放的位置（秒）+ 对应下标：等真正出声时再 seek */
  private resumePosition: number = 0;
  private resumeIndex: number = -1;

  /**
   * 绑定沙箱目录（播放现场落盘用）。
   * EntryAbility.onCreate 里调一次，必须早于 seed()（seed 末尾会读现场）。
   */
  init(context: common.Context): void {
    if (this.stateInited) {
      return;
    }
    this.stateInited = true;
    this.stateStore.init(context);
  }

  /**
   * 把播放现场落盘
   *
   * 触发点都是低频的（切歌、增删队列、换播放模式、播放历史变化、退到后台），
   * 再加 2 秒节流：pushQueueState 在一次切歌里会被调用好几次，不节流就是反复写文件。
   */
  persistPlayState(force: boolean = false): void {
    if (!this.stateInited || !this.stateRestored) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastPersistAt < 2000) {
      return;
    }
    this.lastPersistAt = now;
    const state: PersistedPlayState = {
      version: PLAY_STATE_VERSION,
      current: this.current,
      position: AppStorage.get<number>(K_PROGRESS) ?? 0,
      playMode: this.playMode,
      history: this.history.slice(0, 100),
    };
    try {
      this.stateStore.write(JSON.stringify(state));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to persist play state: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 恢复上次的播放现场（seed() 末尾调用一次）
   *
   * 不自动出声：只把「正在播的这首歌」摆回队列的当前项、进度条停在退出时的位置，
   * 用户按播放时再从那里接着放（见 applyResumeSeek）。
   */
  private restorePlayState(): void {
    if (this.stateInited) {
      const text: string = this.stateStore.read();
      if (text.length > 0) {
        try {
          this.applyPersistedState(text);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'failed to restore play state: %{public}s', JSON.stringify(e));
        }
      }
    }
    // 从这里开始才允许回写
    this.stateRestored = true;
    this.pushQueueState();
    this.pushHistoryState();
  }

  private applyPersistedState(text: string): void {
    const state: PersistedPlayState = JSON.parse(text) as PersistedPlayState;
    const current: SongItem | null | undefined = state.current;
    if (state.version !== PLAY_STATE_VERSION || current === undefined || current === null
      || current.id.length === 0) {
      return;
    }
    if (state.history !== undefined && state.history.length > 0) {
      this.history = state.history;
    }
    if (state.playMode !== undefined && state.playMode.length > 0) {
      this.playMode = state.playMode;
    }
    let index: number = -1;
    for (let i = 0; i < this.queue.length; i++) {
      if (sameSong(current, this.queue[i])) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      // 队列里没有这首（没配同步 / 队列被清过）：放回队首，保证「继续播放」有歌可放
      this.queue = [current].concat(this.queue);
      index = 0;
      this.bumpQueueVersion();
    }
    this.currentIndex = index;
    const position: number = state.position !== undefined ? state.position : 0;
    if (position > 0) {
      this.resumePosition = position;
      this.resumeIndex = index;
      AppStorage.setOrCreate(K_PROGRESS, position);
    }
  }

  /**
   * 恢复现场后第一次真正出声时跳到退出时的位置。
   * 不能在 playAt 里直接 seek：那时 AVPlayer 还在 prepare，seek 会被丢掉。
   */
  private applyResumeSeek(): void {
    if (this.resumePosition <= 0 || this.resumeIndex !== this.currentIndex) {
      return;
    }
    const position: number = this.resumePosition;
    this.resumePosition = 0;
    this.resumeIndex = -1;
    hilog.info(DOMAIN, TAG, 'resume playback at %{public}d s', position);
    LxPlayer.getInstance().seek(position * 1000);
  }

  setNoticeListener(listener: ((text: string) => void) | null): void {
    this.noticeListener = listener;
  }

  setLibrarySink(sink: LibrarySink | null): void {
    this.librarySink = sink;
  }

  /** 通知同步模块「歌单/收藏/播放队列有本地改动」（需要上行到服务端） */
  private notifyLibrary(): void {
    if (this.librarySink !== null && !this.adoptingLibrary) {
      this.librarySink.onLocalListsChanged();
    }
  }

  /**
   * 用同步模块的数据整体替换界面状态（服务端推来 list_data_overwrite 或刚完成合并时）
   *
   * 走这里而不是直接赋值，是为了：1) 抑制上行（这些数据本来就来自服务端）；
   * 2) 一并更新队列状态与版本号，让各列表页刷新。
   */
  adoptLibraryState(queue: SongItem[], favorites: SongItem[], playlists: PlaylistSummary[]): void {
    // 正在播的那首如果还在新队列里就保持「当前」指向它，否则清掉当前项：
    // 队列被换掉后还指着一首没在播的歌，迷你播放器显示的歌名会跟实际出声的对不上。
    let nextIndex: number = -1;
    const current: SongItem | null = this.current;
    if (current !== null) {
      for (let i = 0; i < queue.length; i++) {
        if (queue[i].id === current.id) {
          nextIndex = i;
          break;
        }
      }
    }
    this.adoptingLibrary = true;
    this.libraryLoaded = true;
    try {
      this.queue = queue;
      this.favorites = favorites;
      this.playlists = playlists;
      this.currentIndex = nextIndex;
      this.bumpQueueVersion();
      this.pushQueueState();
      this.publishFavorites();
    } finally {
      this.adoptingLibrary = false;
    }
    const version: number = AppStorage.get<number>(K_LIBRARY_VERSION) ?? 0;
    AppStorage.setOrCreate(K_LIBRARY_VERSION, version + 1);
  }

  private notify(text: string): void {
    const listener = this.noticeListener;
    if (listener !== null && text.length > 0) {
      listener(text);
    }
  }

  /**
   * 首次进入界面时铺一套与洛雪移动端一致的演示数据
   *
   * 只有「音乐库里没有真实数据」时才铺：SyncManager 在 EntryAbility.onCreate 里
   * 就会把落过盘的库镜像进来（真实队列 / 收藏 / 歌单），Index 的 aboutToAppear
   * 比它晚，如果这里再把演示数据写回队列和收藏，就把真实数据冲掉了 ——
   * 而且下一次本地改动会把这个空收藏当成本地改动上行，等于把云端收藏也清空。
   */
  seed(): void {
    if (this.seeded) {
      return;
    }
    this.seeded = true;
    this.wirePlayer();

    // 播放历史不铺演示数据：它是真实的使用记录，混进几条假歌会让用户
    // 以为「我的 - 播放历史」里真播过这些歌
    this.history = [];

    // 推荐位与排行榜不再需要演示数据：推荐页直接读平台接口
    // （core/music/MusicList.ets），有网就有内容，没网就显示重试。

    if (this.libraryLoaded) {
      // 队列 / 收藏 / 歌单已经是音乐库里的真实数据，保持原样；
      // 末尾会把上次退出时的播放现场（正在播放的那首 + 进度）恢复回来
      this.restorePlayState();
      return;
    }

    // 收藏不铺演示数据：收藏是参与同步的真实数据（洛雪的 loveList），
    // 里面混进几条没有 musicInfo 的假歌既播不了、又会被当成「已经有了」影响收藏判断
    this.favorites = [];
    this.publishFavorites();

    this.playlists = [
      { id: 'pl_default', name: '茗秋瞳喜欢的音乐', count: 530 },
    ];

    this.queue = [
      demo('听', '张杰', '04:31'),
      demo('剑心', '张杰', '04:12'),
      demo('你曾是少年', '焦迈奇', '04:24'),
      demo('passion', 'silent anthem / heart embrace', '03:11'),
      demo('夜、萤火虫和你', 'AniFace', '03:37'),
      demo('金榜题名', '王朝1982 / 朱旭BooBoo / 刘书含Rose', '03:45'),
    ];

    this.restorePlayState();
  }

  // ------------------------------------------------------------ 播放器接线

  /**
   * 播放状态与进度的唯一来源是 AVPlayer：
   * 界面上的「正在播放」、进度条、播完自动下一首，都从这里回写，不再自己造。
   */
  private wirePlayer(): void {
    if (this.playerWired) {
      return;
    }
    this.playerWired = true;
    const player = LxPlayer.getInstance();

    const onState: LxPlayerStateListener = (status: LxPlayerStatus, message: string) => {
      this.onPlayerState(status, message);
    };
    const onTime: LxPlayerTimeListener = (currentMs: number, durationMs: number) => {
      AppStorage.setOrCreate(K_PROGRESS, Math.floor(currentMs / 1000));
      if (durationMs > 0) {
        AppStorage.setOrCreate(K_DURATION, Math.floor(durationMs / 1000));
      }
    };
    const onCompleted: LxPlayerCompletionListener = () => {
      this.onTrackCompleted();
    };
    player.addStateListener(onState);
    player.addTimeListener(onTime);
    player.addCompletionListener(onCompleted);

    // 系统媒体控制（锁屏 / 控制中心 / 耳机）的指令回到这里，走的还是本会话自己的那套操作
    const service = PlaybackService.getInstance();
    service.setCommandListener((command: PlaybackCommand, positionMs: number) => {
      this.onSystemCommand(command, positionMs);
    });
    // 播控中心的「收藏」与「循环模式」带参数，各自走一个监听
    service.setFavoriteListener((assetId: string) => {
      this.toggleFavoriteByAssetId(assetId);
    });
    service.setLoopModeListener((mode: string) => {
      this.applyLoopMode(mode);
    });
  }

  /**
   * 播控中心点了「收藏」：按 assetId 找到那首歌，切换收藏状态
   *
   * assetId 是推给系统时的标识（见 assetIdOf），队列里没有（队列被换过、系统还拿着
   * 旧的 assetId）就到收藏里找；两边都没有就忽略，不做无中生有的收藏。
   * 收藏本身是参与同步的数据，所以这里走 addFavorite/removeFavorite，
   * 改动会照常上行到同步服务端。
   */
  private toggleFavoriteByAssetId(assetId: string): void {
    const item: SongItem | null = this.findByAssetId(assetId);
    if (item === null) {
      return;
    }
    if (this.isFavorite(item.id)) {
      this.removeFavorite(item.id);
      return;
    }
    this.addFavorite(item);
  }

  private findByAssetId(assetId: string): SongItem | null {
    for (const item of this.queue) {
      if (assetIdOf(item) === assetId) {
        return item;
      }
    }
    for (const item of this.favorites) {
      if (assetIdOf(item) === assetId) {
        return item;
      }
    }
    return null;
  }

  /**
   * 播控中心要求切循环模式
   *
   * 系统给的可能是「目标模式」（setTargetLoopMode，文档语义就是切到它），
   * 也可能是「当前模式」——官方 FAQ 说这种情况下由应用自己决定下一个模式。
   * 两种语义都照顾到：给的模式跟当前不同就直接切，相同就当成「按了一下」往下轮一个。
   * 无论如何都要把结果回推给播控中心，那颗按钮的图标就靠这个确认。
   */
  private applyLoopMode(mode: string): void {
    if (mode !== 'list' && mode !== 'order' && mode !== 'single' && mode !== 'shuffle') {
      return;
    }
    if (mode === this.playMode) {
      this.cyclePlayMode();
      return;
    }
    this.playMode = mode;
    AppStorage.setOrCreate(K_PLAY_MODE, this.playMode);
    PlaybackService.getInstance().updateLoopMode(this.playMode);
    this.persistPlayState(true);
  }

  /** 把「当前这首歌是否收藏」推给播控中心（心形实心/空心） */
  private pushFavoriteStateToSystem(): void {
    const item: SongItem | null = this.current;
    PlaybackService.getInstance().updateFavorite(item !== null && this.isFavorite(item.id));
  }

  /** 系统音乐服务的控制指令 -> 本会话的操作 */
  private onSystemCommand(command: PlaybackCommand, positionMs: number): void {
    if (command === 'play') {
      this.systemPlay();
      return;
    }
    if (command === 'pause') {
      LxPlayer.getInstance().pause().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'system pause failed: %{public}s', err.message);
      });
      return;
    }
    if (command === 'next') {
      this.next();
      return;
    }
    if (command === 'prev') {
      this.prev();
      return;
    }
    if (command === 'seek') {
      this.seek(positionMs / 1000);
      return;
    }
    // stop：暂停并把长时任务收掉（锁屏的停止键 / 耳机长按）
    LxPlayer.getInstance().pause().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'system stop failed: %{public}s', err.message);
    });
    PlaybackService.getInstance().stopPlayback();
  }

  /** 系统「播放」：暂停态直接续播（不重新解析链接），否则按当前条目重新加载 */
  private async systemPlay(): Promise<void> {
    const player = LxPlayer.getInstance();
    const status: string = AppStorage.get<string>(K_PLAYER_STATUS) ?? 'idle';
    if (status === 'loading' || status === 'playing') {
      return;
    }
    if (status === 'paused' && player.getStatus() === 'paused') {
      await player.resume();
      return;
    }
    if (this.currentIndex >= 0) {
      await this.playAt(this.currentIndex);
      return;
    }
    if (this.queue.length > 0) {
      await this.playAt(0);
    }
  }

  private onPlayerState(status: LxPlayerStatus, message: string): void {
    if (status === 'playing') {
      this.setStatus('playing', '正在播放');
      // 重启恢复后第一次出声：跳到退出时的位置接着放
      this.applyResumeSeek();
      return;
    }
    if (status === 'paused') {
      this.setStatus('paused', '已暂停');
      // 主动暂停往往就是「要离开了」：把现场连同当前进度一起落盘
      this.persistPlayState(true);
      return;
    }
    if (status === 'loading') {
      this.setStatus('loading', message);
      return;
    }
    if (status === 'error') {
      this.setStatus('error', message);
      this.notify(message);
      // 缓存出了问题才重试一次（源本身有问题时来回重试没有意义）：
      //   - 本地缓存文件放不出来（截断 / 内容不对）：删掉它，改成联网播；
      //   - 缓存的播放地址过期了：丢掉这条地址，重新解析。
      if (!this.urlRetried) {
        if (this.currentLocalPath.length > 0) {
          this.urlRetried = true;
          hilog.warn(DOMAIN, TAG, 'cached file failed, drop it: %{public}s', message);
          AudioCache.getInstance().dropPath(this.currentLocalPath);
          this.currentLocalPath = '';
          void this.playAt(this.currentIndex);
          return;
        }
        if (this.currentUrlFromCache && this.currentCacheKey.length > 0) {
          this.urlRetried = true;
          MediaCache.getInstance().dropMusicUrl(this.currentCacheKey, this.currentCacheQuality);
          hilog.warn(DOMAIN, TAG, 'cached url failed, refresh: %{public}s', message);
          void this.playAt(this.currentIndex);
          return;
        }
      }
      return;
    }
    // idle / stopped 由会话自己管（切歌、清空队列），这里不覆盖
  }

  // ------------------------------------------------------------ 状态同步

  private pushQueueState(): void {
    AppStorage.setOrCreate(K_QUEUE_COUNT, this.queue.length);
    AppStorage.setOrCreate(K_PLAY_MODE, this.playMode);
    if (this.currentIndex >= 0 && this.currentIndex < this.queue.length) {
      const item: SongItem = this.queue[this.currentIndex];
      AppStorage.setOrCreate(K_CURRENT_ID, item.id);
      AppStorage.setOrCreate(K_CURRENT_NAME, item.name);
      AppStorage.setOrCreate(K_CURRENT_SINGER, item.singer);
      AppStorage.setOrCreate(K_CURRENT_COVER, item.coverUrl);
      AppStorage.setOrCreate(K_CURRENT_ART, item.art);
      AppStorage.setOrCreate(K_CURRENT_QUALITY, item.quality);
      AppStorage.setOrCreate(K_DURATION, parseDuration(item.interval));
      this.syncMediaInfo(item);
    } else {
      AppStorage.setOrCreate(K_CURRENT_ID, '');
      AppStorage.setOrCreate(K_CURRENT_NAME, '');
      AppStorage.setOrCreate(K_CURRENT_SINGER, '');
      AppStorage.setOrCreate(K_CURRENT_COVER, '');
      AppStorage.setOrCreate(K_CURRENT_ART, false);
      AppStorage.setOrCreate(K_CURRENT_QUALITY, '128k');
      AppStorage.setOrCreate(K_DURATION, 0);
      AppStorage.setOrCreate(K_PROGRESS, 0);
    }
    // 队列 / 当前曲目 / 播放模式都变了，顺手把播放现场落盘（内部有节流）
    this.persistPlayState();
  }

  /**
   * 把当前歌曲推给系统媒体卡（锁屏 / 控制中心 / 车机）
   *
   * assetId 必须唯一标识一首歌：系统靠它判断是「换歌」还是「同一首更新信息」。
   * 上一首 / 下一首按队列给（列表循环，所以首尾相接），系统的媒体卡据此
   * 决定上一首/下一首按钮是否可用。
   * 封面是异步解析的，解析出来后 pushQueueState/loadCover 会再调一次这里。
   */
  private syncMediaInfo(item: SongItem): void {
    const count: number = this.queue.length;
    const index: number = this.currentIndex;
    let previousAssetId: string = '';
    let nextAssetId: string = '';
    if (count > 1 && index >= 0 && index < count) {
      previousAssetId = assetIdOf(this.queue[index === 0 ? count - 1 : index - 1]);
      nextAssetId = assetIdOf(this.queue[index === count - 1 ? 0 : index + 1]);
      // 顺序播放的两个头尾没有「上一首 / 下一首」，别让播控中心那两颗按钮亮着
      if (this.playMode === 'order') {
        if (index === 0) {
          previousAssetId = '';
        }
        if (index === count - 1) {
          nextAssetId = '';
        }
      }
    }
    const info: PlaybackMediaInfo = {
      assetId: assetIdOf(item),
      title: item.name,
      artist: item.singer,
      album: '',
      durationMs: parseDuration(item.interval) * 1000,
      coverUrl: item.coverUrl,
      previousAssetId: previousAssetId,
      nextAssetId: nextAssetId,
      isFavorite: this.isFavorite(item.id),
    };
    PlaybackService.getInstance().updateMedia(info);
  }

  private pushHistoryState(): void {
    const version: number = AppStorage.get<number>(K_HISTORY_VERSION) ?? 0;
    AppStorage.setOrCreate(K_HISTORY_VERSION, version + 1);
  }

  private setStatus(status: string, text: string = ''): void {
    AppStorage.setOrCreate(K_PLAYER_STATUS, status);
    AppStorage.setOrCreate(K_STATUS_TEXT, text);
  }

  // ------------------------------------------------------------ 解析真实播放条目

  /** 从当前音源声明的平台里挑一个「既能搜、又能取播放链接」的 */
  private pickSearchPlatform(): string {
    const map: Record<string, SupportedSource> = SourceEngine.getInstance().getSupportedSources();
    for (const key of Object.keys(map)) {
      const source: SupportedSource = map[key];
      if (isSearchSupported(key) && source.actions.includes('musicUrl')) {
        return key;
      }
    }
    return '';
  }

  private bestMatch(results: LxMusicInfo[], item: SongItem): LxMusicInfo {
    const target: string = normalizeName(item.name);
    for (const info of results) {
      if (normalizeName(info.name) === target) {
        return info;
      }
    }
    for (const info of results) {
      const name: string = normalizeName(info.name);
      if (name.includes(target) || target.includes(name)) {
        return info;
      }
    }
    return results[0];
  }

  /** 给没有 musicInfo 的条目（演示歌单/推荐/历史）搜一个真实 musicInfo */
  private async resolveItem(item: SongItem): Promise<SongItem> {
    const key: string = `${item.name}\u0001${item.singer}`;
    const cached: SongItem | undefined = this.resolveCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const engine = SourceEngine.getInstance();
    const platform: string = this.pickSearchPlatform();
    if (platform.length === 0) {
      throw new Error('当前音源没有可搜索的平台，无法为这首歌找资源');
    }
    const keyword: string = item.singer.length > 0 ? `${item.name} ${item.singer}` : item.name;
    const results: LxMusicInfo[] = await searchMusic(keyword, platform, 1, 15);
    if (results.length === 0) {
      throw new Error(`没有搜到「${item.name}」的可播放资源`);
    }
    const info: LxMusicInfo = this.bestMatch(results, item);
    const resolved: SongItem = songFromSearch(info, item.quality);
    // 展示层字段沿用原条目，避免列表里的封面/歌名跳来跳去
    resolved.id = item.id;
    resolved.name = item.name.length > 0 ? item.name : resolved.name;
    resolved.singer = item.singer.length > 0 ? item.singer : resolved.singer;
    if (resolved.coverUrl.length === 0) {
      resolved.art = item.art;
    }
    if (engine.isInited()) {
      resolved.quality = pickQuality(resolved.musicInfoJson, resolved.source, resolved.quality);
    }
    this.resolveCache.set(key, resolved);
    return resolved;
  }

  /** 条目要么带上源支持的 musicInfo，要么能被搜出来；两者都没有就抛错 */
  private async ensurePlayable(item: SongItem): Promise<SongItem> {
    const map: Record<string, SupportedSource> = SourceEngine.getInstance().getSupportedSources();
    if (item.musicInfoJson.length > 0) {
      const source: SupportedSource | undefined = map[item.source];
      if (source !== undefined && source.actions.includes('musicUrl')) {
        return item;
      }
    }
    return await this.resolveItem(item);
  }

  // 音质协商见 core/music/Quality.ets：播放与下载共用同一套规则（pickQuality /
  // fallbackQuality），这里不再重复实现，免得两边挑出的档不一致。

  // ------------------------------------------------------------ 播放控制

  get current(): SongItem | null {
    if (this.currentIndex < 0 || this.currentIndex >= this.queue.length) {
      return null;
    }
    return this.queue[this.currentIndex];
  }

  /** 用一批歌曲替换播放队列并从 startIndex 开始播 */
  async setQueueAndPlay(items: SongItem[], startIndex: number): Promise<void> {
    this.queue = items.slice();
    this.currentIndex = -1;
    this.bumpQueueVersion();
    this.pushQueueState();
    // 播放队列即洛雪的「试听列表」，换队列要同步出去
    this.notifyLibrary();
    await this.playAt(startIndex);
  }

  async playAt(index: number): Promise<void> {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    // 每次切歌领一个号：解析/取链接要几秒，期间用户又点了别的歌的话，
    // 旧的那次必须丢掉，不能等它回来把新歌覆盖掉
    const token: number = ++this.playToken;
    // 放的是另一首歌：上次退出时记下的续播位置作废
    if (index !== this.resumeIndex) {
      this.resumePosition = 0;
      this.resumeIndex = -1;
    }
    this.currentIndex = index;
    this.urlRetried = false;
    this.currentLocalPath = '';
    this.pushQueueState();

    // 先把上一首停掉再解析：解析要几秒，期间旧歌还在响的话，界面上的进度条
    // 会先走一段再被新歌重置回去——「先变后执行」就是这么来的。
    await LxPlayer.getInstance().release();
    if (this.playToken !== token) {
      return;
    }
    AppStorage.setOrCreate(K_PROGRESS, 0);
    this.clearLyric();

    const engine = SourceEngine.getInstance();
    if (!engine.isInited()) {
      const message: string = '请先在「设置 - 音源设置」导入并加载一个音源，才可以播放';
      this.setStatus('error', message);
      this.notify(message);
      return;
    }

    let item: SongItem = this.queue[index];
    this.recordHistory(item);
    this.setStatus('loading', `正在解析「${item.name}」…`);
    try {
      const resolved: SongItem = await this.ensurePlayable(item);
      if (this.playToken !== token) {
        return;
      }
      if (resolved !== item) {
        // 原地补齐 musicInfo/封面/时长：队列是列表数组的浅拷贝，同一个对象
        // 也躺在推荐/历史/收藏里，原地改它们才会一起显示封面与真实时长
        this.applyResolved(item, resolved);
        this.pushQueueState();
      }
      // 封面与歌词都不挡住出声：解析好了再各自回填
      this.loadCover(item);
      this.loadLyric(item);

      let quality: string = pickQuality(item.musicInfoJson, item.source, item.quality);
      item.quality = quality;
      AppStorage.setOrCreate(K_CURRENT_QUALITY, quality);

      // ---------------------------------------------------------- 缓存 / 本地文件
      const cacheKey: string = mediaKeyOf(item.musicInfoJson);
      const audioCache = AudioCache.getInstance();
      // 这一轮的缓存状态：出错时据此决定要不要丢掉缓存重来
      this.currentCacheKey = cacheKey;
      this.currentCacheQuality = quality;
      this.currentUrlFromCache = false;
      this.currentLocalPath = '';

      // 0) 用户主动下载到本地的：优先放它。
      // 下载是明确的用户意图、文件是长期保留的，比 LRU 播放缓存更该被优先使用：
      // 离线能放、也不看音源脸色（音源失效时下载过的歌照样能听）。
      const downloaded: string = downloadedFile(cacheKey.length > 0 ? cacheKey : item.id);
      if (downloaded.length > 0) {
        audioCache.setPlayingPath('');
        this.currentLocalPath = downloaded;
        this.setStatus('loading', '正在读取已下载文件…');
        await LxPlayer.getInstance().playLocal(downloaded);
        return;
      }

      // 1) 本地音频缓存命中：直接读沙箱文件，不联网、也不看源脚本的脸色
      const local: string = audioCache.localPath(cacheKey, quality);
      if (local.length > 0) {
        audioCache.setPlayingPath(local);
        this.currentLocalPath = local;
        this.setStatus('loading', '正在读取缓存…');
        await LxPlayer.getInstance().playLocal(local);
        return;
      }
      audioCache.setPlayingPath('');

      // 2) 播放地址缓存（洛雪的 @music_url__<id>_<quality>）
      const mediaCacheRef = MediaCache.getInstance();
      let url: string = mediaCacheRef.getMusicUrl(cacheKey, quality);
      const fromCache: boolean = url.length > 0;
      if (!fromCache) {
        // 刚启动时音源可能还在自动恢复（见 SourceEngine.restoreLastSource）：
        // 等它一下再解析，别让「开了应用马上点播放」直接报「音源未加载」。
        if (engine.isRestoring() && !engine.isInited()) {
          this.setStatus('loading', '正在准备音源…');
          await engine.whenInited(10000);
          if (this.playToken !== token) {
            return;
          }
        }
        try {
          url = await engine.getMusicUrl(item.musicInfoJson, quality as LxQuality, item.source);
        } catch (err) {
          // 拓展音质（母带 / 全景声…）多半要会员，拿不到链接是常态：
          // 退回普通音质再试一次，别让「开了拓展音质」变成有些歌直接放不了。
          const retry: string = fallbackQuality(item.musicInfoJson, item.source, quality);
          if (retry.length === 0) {
            throw err as Error;
          }
          hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed, retry with %{public}s',
            quality, retry);
          quality = retry;
          item.quality = retry;
          // 缓存现场也要跟着改：这条链接真放不出来时要按「实际用的那一档」丢缓存
          this.currentCacheQuality = retry;
          AppStorage.setOrCreate(K_CURRENT_QUALITY, retry);
          url = await engine.getMusicUrl(item.musicInfoJson, retry as LxQuality, item.source);
        }
        if (this.playToken !== token) {
          return;
        }
        if (cacheKey.length > 0) {
          mediaCacheRef.saveMusicUrl(cacheKey, quality, url);
        }
      }
      this.currentUrlFromCache = fromCache;
      this.setStatus('loading', '正在缓冲…');
      // 真正的「正在播放」由 AVPlayer 的 stateChange 决定（见 onPlayerState），
      // 这里不提前改状态，避免没出声界面就先显示播放中
      await LxPlayer.getInstance().playUrl(url);
      // 3) 边播边缓存：下完整首，下次播放就走上面的本地分支
      audioCache.cacheSong(cacheKey, quality, url);
    } catch (e) {
      if (this.playToken !== token) {
        return;
      }
      const message: string = `播放「${item.name}」失败：${(e as Error).message}`;
      this.setStatus('error', message);
      this.notify(message);
    }
  }

  /** 把解析出来的真实字段写回原条目（原对象被歌单/推荐/历史共用） */
  private applyResolved(target: SongItem, resolved: SongItem): void {
    target.musicInfoJson = resolved.musicInfoJson;
    target.source = resolved.source;
    target.quality = resolved.quality;
    if (resolved.interval.length > 0) {
      target.interval = resolved.interval;
    }
    if (target.coverUrl.length === 0) {
      target.coverUrl = resolved.coverUrl;
    }
    if (target.coverUrl.length > 0) {
      target.art = false;
    }
  }

  /** 当前这首歌的封面：搜索结果没有就按平台接口 / 源的 pic 解析，好了回填队列与播放栏 */
  private loadCover(item: SongItem): void {
    if (item.coverUrl.length > 0 || item.musicInfoJson.length === 0) {
      return;
    }
    CoverStore.getInstance().request(item.musicInfoJson, (url: string) => {
      if (url.length === 0) {
        return;
      }
      item.coverUrl = url;
      item.art = false;
      if (this.current === item) {
        AppStorage.setOrCreate(K_CURRENT_COVER, url);
        AppStorage.setOrCreate(K_CURRENT_ART, false);
        // 封面到了再推一次，锁屏媒体卡才有图
        this.syncMediaInfo(item);
      }
    });
  }

  /**
   * 歌词：源脚本声明了 lyric 就先问源，拿不到（或没有时间轴）就用内置平台歌词。
   * 加载是异步的，用 lyricToken 挡住「切歌后旧歌词才回来」的情况。
   */
  private loadLyric(item: SongItem): void {
    this.lyricToken = item.id;
    if (item.musicInfoJson.length === 0) {
      AppStorage.setOrCreate(K_LYRIC_STATUS, 'none');
      return;
    }
    AppStorage.setOrCreate(K_LYRIC_STATUS, 'loading');
    const token: string = item.id;
    this.fetchLyric(item).then((result: PlatformLyric) => {
      if (this.lyricToken !== token) {
        return;
      }
      const lines: LyricLine[] = parseLyric(result.lyric, result.tlyric);
      AppStorage.setOrCreate(K_LYRIC_LINES, lines);
      AppStorage.setOrCreate(K_LYRIC_STATUS, lines.length > 0 ? 'ready' : 'none');
      // 同一份歌词也上推系统：播控中心按时间轴滚动显示，桌面歌词悬浮窗也用它
      this.pushLyricToSystem(result.lyric, result.tlyric);
    }).catch(() => {
      if (this.lyricToken === token) {
        AppStorage.setOrCreate(K_LYRIC_STATUS, 'none');
        this.pushLyricToSystem('', '');
      }
    });
  }

  /**
   * 取词：平台源的 source 协议里本来就没有歌词能力（action 白名单只有 musicUrl），
   * 所以内置平台歌词才是主力（kw/kg/tx，与洛雪一致）；源自带 lyric 时优先用源的。
   *
   * 取词前先查缓存（洛雪的 @lyric__<id>）：歌词是逐字不变的，没必要每次播放都重新请求、
   * 也不会因为源脚本抽风导致「上次有词这次没词」。
   */
  private async fetchLyric(item: SongItem): Promise<PlatformLyric> {
    const key: string = mediaKeyOf(item.musicInfoJson);
    const cache = MediaCache.getInstance();
    const cached: CachedLyricInfo | null = cache.getLyric(key);
    if (cached !== null) {
      return { lyric: cached.lyric, tlyric: cached.tlyric };
    }
    const result: PlatformLyric = await this.fetchLyricRemote(item);
    if (key.length > 0 && result.lyric.length > 0 && hasTimeTag(result.lyric)) {
      cache.saveLyric(key, { lyric: result.lyric, tlyric: result.tlyric });
    }
    return result;
  }

  private async fetchLyricRemote(item: SongItem): Promise<PlatformLyric> {
    const engine = SourceEngine.getInstance();
    if (engine.supportsAction(item.source, 'lyric')) {
      try {
        const json: string = await engine.getLyric(item.musicInfoJson, item.source);
        const result = JSON.parse(json) as BridgeResult;
        const lyric: string = result.data.lyric !== undefined ? result.data.lyric : '';
        const tlyric: string = result.data.tlyric !== undefined ? result.data.tlyric : '';
        // 源给了词但没有时间轴（只有纯文本）时继续走内置，否则歌词不会跟着滚
        if (hasTimeTag(lyric)) {
          return { lyric: lyric, tlyric: tlyric };
        }
        hilog.info(DOMAIN, TAG, 'source lyric for %{public}s has no time tag, use built-in',
          item.source);
      } catch (e) {
        // 源取词失败（音源失效、源不支持等）就落到内置：歌词不该被音源死活绑架
        hilog.warn(DOMAIN, TAG, 'source lyric failed for %{public}s: %{public}s',
          item.source, (e as Error).message);
      }
    }
    try {
      const info: LxMusicInfo = JSON.parse(item.musicInfoJson) as LxMusicInfo;
      const result: PlatformLyric = await fetchPlatformLyric(info);
      if (result.lyric.length === 0) {
        hilog.info(DOMAIN, TAG, 'no lyric for %{public}s %{public}s', item.source, item.name);
      }
      return result;
    } catch (e) {
      return { lyric: '', tlyric: '' };
    }
  }

  /** 切歌时先把上一首的歌词清掉，别让新歌配旧词 */
  private clearLyric(): void {
    this.lyricToken = '';
    AppStorage.setOrCreate(K_LYRIC_LINES, []);
    AppStorage.setOrCreate(K_LYRIC_STATUS, 'none');
    // 播控中心 / 桌面歌词那边也一起清掉，免得停留在上一首的词上
    PlaybackService.getInstance().updateLyric('');
  }

  /**
   * 歌词上推系统（播控中心滚动歌词 + 桌面歌词悬浮窗）
   *
   * 只认带时间标签的歌词（LRC）：系统靠 [mm:ss.xx] 自己滚动，
   * 没有时间标签的纯文本系统解析不了，会显示异常 — 这种就当作没有歌词。
   * 原文没有时间轴但译文有时，用译文兜底。
   */
  private pushLyricToSystem(lyric: string, tlyric: string): void {
    let lrc: string = '';
    if (hasTimeTag(lyric)) {
      lrc = lyric;
    } else if (hasTimeTag(tlyric)) {
      lrc = tlyric;
    }
    PlaybackService.getInstance().updateLyric(lrc);
  }

  async toggle(): Promise<void> {
    const player = LxPlayer.getInstance();
    const status: string = AppStorage.get<string>(K_PLAYER_STATUS) ?? 'idle';
    // 正在解析/缓冲时按键无效，等这次操作有结果（状态由 AVPlayer 回调驱动）
    if (status === 'loading') {
      return;
    }
    if (status === 'playing') {
      // 暂停/播放态都由 AVPlayer 的 stateChange 回写，这里不提前改状态
      await player.pause();
      return;
    }
    if (status === 'paused' && this.currentIndex >= 0 && player.getStatus() === 'paused') {
      await player.resume();
      return;
    }
    if (this.currentIndex >= 0) {
      await this.playAt(this.currentIndex);
    } else if (this.queue.length > 0) {
      await this.playAt(0);
    }
  }

  /** 拖动播放页进度条（秒） */
  seek(seconds: number): void {
    const value: number = seconds > 0 ? seconds : 0;
    LxPlayer.getInstance().seek(value * 1000);
    AppStorage.setOrCreate(K_PROGRESS, value);
  }

  async next(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (this.playMode === 'shuffle') {
      const index: number = this.nextShuffleIndex();
      if (index < 0) {
        return;
      }
      this.shuffleHistory.push(this.currentIndex);
      await this.playAt(index);
      return;
    }
    const candidate: number = this.currentIndex + 1;
    if (candidate >= this.queue.length) {
      // 顺序播放：最后一首到头了就不动；列表循环 / 单曲循环绕回第一首
      if (this.playMode === 'order') {
        return;
      }
      await this.playAt(0);
      return;
    }
    await this.playAt(candidate);
  }

  async prev(): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (this.playMode === 'shuffle') {
      await this.playAt(this.prevShuffleIndex());
      return;
    }
    const candidate: number = this.currentIndex - 1;
    if (candidate < 0) {
      // 顺序播放：第一首之前没有了；其余模式绕回最后一首
      if (this.playMode === 'order') {
        return;
      }
      await this.playAt(this.queue.length - 1);
      return;
    }
    await this.playAt(candidate);
  }

  /** 队列内容变了：随机播放的一轮记录作废，下一轮重新算 */
  private bumpQueueVersion(): void {
    this.queueVersion++;
    this.shuffleVersion = -1;
  }

  /**
   * 随机播放的下一首：**一轮之内不重复**
   *
   * 把队列里的下标当成一个池子，本轮放过的从池子里划掉，随机只从剩下的里挑；
   * 池子空了（整条队列都放完一轮）再重开一轮。队列被换过（queueVersion 变了）
   * 就作废重来 —— 也就是「除非换了播放列表，否则不重复」。
   */
  private nextShuffleIndex(): number {
    const total: number = this.queue.length;
    if (total === 0) {
      return -1;
    }
    if (this.shuffleVersion !== this.queueVersion) {
      this.shufflePlayed.clear();
      this.shuffleHistory = [];
      this.shuffleVersion = this.queueVersion;
    }
    // 正在播的这首算已放，免得随机到它自己
    if (this.currentIndex >= 0 && this.currentIndex < total) {
      this.shufflePlayed.add(this.currentIndex);
    }
    if (this.shufflePlayed.size >= total) {
      // 一轮放完了：重开一轮，但第一首不能又是刚放完的这首
      this.shufflePlayed.clear();
      if (this.currentIndex >= 0) {
        this.shufflePlayed.add(this.currentIndex);
      }
    }
    const pool: number[] = [];
    for (let i = 0; i < total; i++) {
      if (!this.shufflePlayed.has(i)) {
        pool.push(i);
      }
    }
    if (pool.length === 0) {
      return this.currentIndex;
    }
    const pick: number = pool[Math.floor(Math.random() * pool.length)];
    this.shufflePlayed.add(pick);
    return pick;
  }

  /** 随机播放的上一首：先按本轮走过的记录往回退，没记录了就再随机一首没放过的 */
  private prevShuffleIndex(): number {
    if (this.shuffleVersion !== this.queueVersion) {
      this.shuffleVersion = this.queueVersion;
      this.shufflePlayed.clear();
      this.shuffleHistory = [];
    }
    while (this.shuffleHistory.length > 0) {
      const back: number | undefined = this.shuffleHistory.pop();
      if (back !== undefined && back >= 0 && back < this.queue.length && back !== this.currentIndex) {
        this.shufflePlayed.add(back);
        return back;
      }
    }
    return this.nextShuffleIndex();
  }

  /**
   * 一首放完了，按播放模式决定下一步
   *
   *   单曲循环：重放这一首（手动按上一首/下一首才是换歌）
   *   顺序播放：最后一首放完就停住（队列和当前曲目留着，可以重新点播放）
   *   列表循环 / 随机播放：交给 next()
   */
  private onTrackCompleted(): void {
    if (this.playMode === 'single' && this.currentIndex >= 0) {
      void this.playAt(this.currentIndex);
      return;
    }
    if (this.playMode === 'order' && this.currentIndex >= this.queue.length - 1) {
      this.finishQueue();
      return;
    }
    void this.next();
  }

  /** 顺序播放到底：停住，别继续出声也不占后台任务，队列留着让用户重播 */
  private finishQueue(): void {
    LxPlayer.getInstance().release();
    PlaybackService.getInstance().stopPlayback();
    this.clearLyric();
    this.setStatus('stopped', '播放完毕');
    AppStorage.setOrCreate(K_PROGRESS, 0);
  }

  /**
   * 播放模式：列表循环 -> 顺序播放 -> 单曲循环 -> 随机播放 -> 列表循环
   *
   * 改完要推给播控中心，否则那边显示的循环图标跟实际播放行为对不上。
   */
  cyclePlayMode(): string {
    if (this.playMode === 'list') {
      this.playMode = 'order';
    } else if (this.playMode === 'order') {
      this.playMode = 'single';
    } else if (this.playMode === 'single') {
      this.playMode = 'shuffle';
    } else {
      this.playMode = 'list';
    }
    AppStorage.setOrCreate(K_PLAY_MODE, this.playMode);
    PlaybackService.getInstance().updateLoopMode(this.playMode);
    this.persistPlayState(true);
    return this.playMode;
  }

  /** 播放模式的中文名（界面提示用） */
  playModeLabel(): string {
    if (this.playMode === 'order') {
      return '顺序播放';
    }
    if (this.playMode === 'single') {
      return '单曲循环';
    }
    if (this.playMode === 'shuffle') {
      return '随机播放';
    }
    return '列表循环';
  }

  /**
   * 「设置 - 播放设置 - 与其他应用同时播放」
   *
   * 设置项由 PlaySettings 落盘；这里额外把新值作用到当前播放器上，用户改完不用
   * 切歌就能生效（下一首本来也会带上新值，见 LxPlayer.preparePlayer）。
   */
  setPlayWithOthers(value: boolean): void {
    PlaySettings.getInstance().setPlayWithOthers(value);
    LxPlayer.getInstance().setPlayWithOthers(value);
  }

  /**
   * 「设置 - 播放设置 - 桌面歌词」（系统的歌词悬浮窗）
   *
   * 设置项由 PlaySettings 落盘；这里让播控服务立刻重新同步显隐，用户改完就见效，
   * 不必等下一首或重启。
   */
  setDesktopLyric(value: boolean): void {
    PlaySettings.getInstance().setDesktopLyric(value);
    PlaybackService.getInstance().refreshDesktopLyric();
  }

  /**
   * 当前这首歌解析出来的播放链接（分享用）
   *
   * 优先拿这一轮已经在用的地址（播放时写进了元数据缓存），没有就按当前音质现解析一次。
   * 拿不到（音源失效、这首歌没有 musicInfo 等）返回空串，调用方分享时不带链接即可。
   *
   * 注意：平台给的播放地址大多带时效，分享出去的链接过一阵会失效——这是平台侧的规则，
   * 我们只能分享「当前解析出来的这一条」。
   */
  async currentMusicUrl(): Promise<string> {
    const item: SongItem | null = this.current;
    if (item === null || item.musicInfoJson.length === 0) {
      return '';
    }
    const key: string = mediaKeyOf(item.musicInfoJson);
    if (key.length > 0) {
      const cached: string = MediaCache.getInstance().getMusicUrl(key, item.quality);
      if (cached.length > 0) {
        return cached;
      }
    }
    const engine = SourceEngine.getInstance();
    if (!engine.isInited()) {
      return '';
    }
    try {
      return await engine.getMusicUrl(item.musicInfoJson, item.quality as LxQuality, item.source);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolve url for share failed: %{public}s', (e as Error).message);
      return '';
    }
  }

  /** 把一首歌插到当前播放的下一首 */
  addToQueue(item: SongItem, asNext: boolean = false): void {
    if (asNext && this.currentIndex >= 0 && this.currentIndex < this.queue.length) {
      this.queue.splice(this.currentIndex + 1, 0, item);
    } else {
      this.queue.push(item);
    }
    this.bumpQueueVersion();
    this.pushQueueState();
    this.notifyLibrary();
  }

  removeAt(index: number): void {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    const wasCurrent: boolean = index === this.currentIndex;
    this.queue.splice(index, 1);
    if (index < this.currentIndex) {
      this.currentIndex--;
    } else if (wasCurrent) {
      this.currentIndex = Math.min(this.currentIndex, this.queue.length - 1);
    }
    this.bumpQueueVersion();
    this.pushQueueState();
    this.notifyLibrary();
  }

  clearQueue(): void {
    this.queue = [];
    this.currentIndex = -1;
    this.bumpQueueVersion();
    LxPlayer.getInstance().release();
    // 没歌了就别再占着后台播放长时任务
    PlaybackService.getInstance().stopPlayback();
    this.clearLyric();
    this.setStatus('idle');
    this.pushQueueState();
    this.notifyLibrary();
  }

  // ------------------------------------------------------------ 收藏（我的 -> 收藏）

  /** 收藏这首歌（重复收藏会被忽略） */
  addFavorite(item: SongItem): boolean {
    for (const entry of this.favorites) {
      if (entry.id === item.id) {
        return false;
      }
    }
    this.favorites.unshift(item);
    this.publishFavorites();
    this.pushHistoryState();
    this.notifyLibrary();
    this.pushFavoriteStateToSystem();
    return true;
  }

  /**
   * 把收藏名单发布到 AppStorage
   *
   * 歌曲行上的爱心用 @StorageLink 直接读这份名单：它自己判断实心/空心，不依赖
   * 宿主把状态传下去（懒加载列表不会因为宿主重绘就重跑已有的行）。
   */
  private publishFavorites(): void {
    const list: string[] = [];
    for (const entry of this.favorites) {
      list.push(entry.id);
    }
    publishFavoriteIds(list);
  }

  /**
   * 批量收藏：把一批歌加进收藏（已经在收藏里的跳过），返回实际加进去的数量
   *
   * 逐首调 addFavorite 的话每首都上行一次同步（整份 love 列表覆盖），
   * 一张几百首的歌单就是几百次；所以这里一次性改完，只通知一次。
   * 新收藏的排在最前面、并保持传入顺序（与单首收藏一致：最近收藏的在最上面）。
   */
  addFavorites(items: SongItem[]): number {
    const fresh: SongItem[] = [];
    for (const item of items) {
      let exists: boolean = false;
      // 同一批里也可能有重复 id，边收边比
      for (const entry of this.favorites) {
        if (entry.id === item.id) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        for (const entry of fresh) {
          if (entry.id === item.id) {
            exists = true;
            break;
          }
        }
      }
      if (exists) {
        continue;
      }
      fresh.push(item);
    }
    if (fresh.length === 0) {
      return 0;
    }
    this.favorites = fresh.concat(this.favorites);
    const added: number = fresh.length;
    this.publishFavorites();
    this.pushHistoryState();
    this.notifyLibrary();
    this.pushFavoriteStateToSystem();
    return added;
  }

  /** 取消收藏 */
  removeFavorite(id: string): boolean {
    const remains: SongItem[] = [];
    for (const entry of this.favorites) {
      if (entry.id !== id) {
        remains.push(entry);
      }
    }
    if (remains.length === this.favorites.length) {
      return false;
    }
    this.favorites = remains;
    this.publishFavorites();
    this.pushHistoryState();
    this.notifyLibrary();
    this.pushFavoriteStateToSystem();
    return true;
  }

  clearFavorites(): void {
    if (this.favorites.length === 0) {
      return;
    }
    this.favorites = [];
    this.publishFavorites();
    this.pushHistoryState();
    this.notifyLibrary();
    this.pushFavoriteStateToSystem();
  }

  isFavorite(id: string): boolean {
    for (const entry of this.favorites) {
      if (entry.id === id) {
        return true;
      }
    }
    return false;
  }

  recordHistory(item: SongItem): void {
    const rest: SongItem[] = [];
    for (const entry of this.history) {
      if (entry.name !== item.name || entry.singer !== item.singer) {
        rest.push(entry);
      }
    }
    rest.unshift(item);
    this.history = rest.slice(0, 100);
    this.pushHistoryState();
    // 播放历史也是「现场」的一部分，切歌时一起落盘
    this.persistPlayState(true);
  }

  clearHistory(): void {
    this.history = [];
    this.pushHistoryState();
    this.persistPlayState(true);
  }

  formatProgress(seconds: number): string {
    return formatTime(seconds);
  }

  formatDuration(seconds: number): string {
    return formatTime(seconds);
  }
}
