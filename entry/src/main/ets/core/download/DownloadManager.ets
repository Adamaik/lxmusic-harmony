import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { LxPlayer } from '../player/LxPlayer';
import { mediaKeyOf } from '../music/MediaCache';
import { fallbackQuality, pickQuality } from '../music/Quality';
import { SourceEngine } from '../source/SourceEngine';
import { LxQuality } from '../source/LxTypes';
import { DownloadSettings } from './DownloadSettings';
import { DownloadTagData, collectDownloadTags, tagSummary } from './DownloadTags';
import { AutoDownloadSong, clearDownloadedFiles, downloadedFile, removeDownloadedFile,
  setAutoDownloadHandler, setDownloadedFile } from './DownloadIndex';
import { TagSink } from './TagWriter';
import { isLocalSong } from '../local/LocalMusic';
import { isWebDavSong } from '../webdav/WebDavLibrary';
import { BookEngine } from '../book/BookEngine';
import { BOOK_SOURCE, BookAudio, BookPlayPayload, parseBookPayload } from '../book/BookTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadManager';

/** 下载列表 / 进度变化时递增，界面订阅它刷新 */
export const K_DOWNLOAD_VERSION: string = 'download_version';

/** 应用内的下载目录（系统的公共目录拿不到时的兜底；卸载应用才会删） */
const DIR_NAME: string = 'Download';
/** 公共目录 uri 的前缀：据此把「文件管理里能看到的文件」与沙箱兜底文件区分开 */
const PUBLIC_URI_PREFIX: string = 'file://docs';
const INDEX_FILE: string = 'downloads.json';
const PART_SUFFIX: string = '.part';
/** 同时下载数：跟着洛雪的 download.maxDownloadNum 取 2，少占带宽也少被平台限流 */
const MAX_ACTIVE: number = 2;
/** 文件名长度上限（含扩展名），太长的名字部分文件系统会写失败 */
const MAX_NAME_LEN: number = 90;
/** 进度刷新节流：每收一块数据都重绘列表太浪费 */
const PROGRESS_THROTTLE_MS: number = 400;
/**
 * 自动下载（「缓存时自动下载」排进来的）在播放挨饿时隔多久回来看一眼
 *
 * 与播放缓存那边的 WAIT_DELAY_MS 一个量级：只是回来看一眼，不占网络。
 */
const AUTO_WAIT_MS: number = 4000;
/**
 * 有声书：同一时间只跑一集，集与集之间再留这么久
 *
 * 下**一集**要先把这一集的页面抓回来、跑一遍书源规则（可能有多次网络往返），
 * 比下一首歌贵得多；整本几十上百集连着跑，站点那边就是一波扫描。所以有声书不按
 * MAX_ACTIVE 并发，而是串行 + 间隔（见 nextWaiting 与 runTask）。
 */
const BOOK_TASK_GAP_MS: number = 1000;
/**
 * 等系统保存对话框（拿保存位置）最多等这么久
 *
 * 这一步以前没有超时：`DocumentViewPicker.save()` 万一不返回（后台、系统忙），
 * 这个任务就永远不结束、**一直占着一个并发位**，两个位都卡住之后后面所有下载都停在
 * 「排队中…」再也不动 —— 看起来就是「听了两三首之后不再下载」。
 * 超时就退回应用内目录（歌照样下得来、能播，只是文件管理里看不到）。
 */
const PICKER_TIMEOUT_MS: number = 8000;
/**
 * 下载途中「多久没收到数据就认定卡死」
 *
 * `requestInStream` 的 readTimeout 是 300 秒，靠它兜底意味着一首卡住的歌能霸占一个
 * 并发位 5 分钟（两首就是 10 分钟，期间其它自动下载全在排队）。这里自己看数据心跳：
 * 超过这个时间一个字节都没来，就掐断这次请求按失败处理（可以重试）。
 */
const STALL_LIMIT_MS: number = 30000;
/** 检查数据心跳的间隔 */
const STALL_CHECK_MS: number = 5000;
/**
 * 失败后自动重试几次
 *
 * 只对「重试有可能变好」的失败（超时、5xx、连接被断、下载停滞）重试；4xx 这类
 * 明确被拒的（链接过期也会给 403/404）不重试 —— 那只会白跑一遍。
 */
const MAX_RETRY: number = 1;

/** 音质 -> 扩展名（拿不到链接后缀时用） */
const EXT_BY_QUALITY: Record<string, string> = {
  '128k': 'mp3',
  '320k': 'mp3',
  'flac': 'flac',
  'flac24bit': 'flac',
  'hires': 'flac',
  'atmos': 'm4a',
  'atmos_plus': 'm4a',
  'master': 'flac',
  // 有声书占一个固定档位（BOOK_QUALITY）；真去问站点要的是 m4a / mp3，
  // 认不出链接后缀时按 m4a（比 mp3 更常见）
  'book': 'm4a',
};
const KNOWN_EXTS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma'];

/**
 * 有声书空标签
 *
 * ID3 / flac 元数据那套是给音乐写的；有声书的文件名已经说明是哪本书哪一集，
 * 再塞「歌手/专辑/歌词」没有意义（m4a 写标签在 `docs/DOWNLOAD_TAGS.md` 里记为暂不做）。
 */
const NO_TAGS: DownloadTagData = {
  title: '',
  artist: '',
  album: '',
  lyric: '',
  cover: null,
  coverMime: '',
  coverWidth: 0,
  coverHeight: 0,
};

/** 下载状态 */
export type DownloadStatus = 'waiting' | 'downloading' | 'done' | 'error';

/** 一条下载记录 */
export interface DownloadItem {
  /** 唯一键：mediaKeyOf 的结果；没有 musicInfo 的条目退回条目 id */
  key: string;
  name: string;
  singer: string;
  source: string;
  quality: string;
  interval: string;
  coverUrl: string;
  art: boolean;
  musicInfoJson: string;
  /** 落盘文件名（含扩展名） */
  fileName: string;
  /** 完整落盘路径 / uri */
  uri: string;
  received: number;
  total: number;
  status: DownloadStatus;
  /** 失败原因（status = error 时有值） */
  error: string;
  /** 非致命提示（例如系统下载目录不可用、已改存到应用内目录），列表里跟在状态后面显示 */
  note: string;
  /** 标签（封面 / 歌词）嵌入结果：嵌进去了就写「已嵌入封面与歌词」，容器不支持就如实说明 */
  tagNote: string;
  /**
   * 是不是「缓存时自动下载」排进来的（不是用户点的那一下）
   *
   * 只影响调度：自动排进来的在播放挨饿时不抢网络（见 pump），用户点的立即开工。
   */
  auto: boolean;
  /** 已经自动重试过几次（见 MAX_RETRY）：到上限就不再自动重试，等用户手点 */
  retries: number;
  createdAt: number;
}

/** 第 2 条写路径（系统保存对话框）的结果 */
interface PickerAttempt {
  /** 成功时的写目标 */
  target: WriteTarget | null;
  /** 失败原因（target 为空时有值，会展示给用户） */
  reason: string;
}

/** 一次下载要写的位置 */
interface WriteTarget {
  /** 最终路径 / uri（记进索引，也用来播放） */
  path: string;
  /** 边下边写的临时文件；空串表示直接写 path（系统保存给的 uri） */
  part: string;
  handle: fs.File;
  /** 没写进系统公共下载目录（写进了应用内目录）：列表里要如实说明，不然用户找不到文件 */
  fallback: boolean;
  /** 退回应用内目录的原因（fallback 为真时给用户看） */
  reason: string;
}

/**
 * 解析出来的下载地址
 *
 * 与链接一起把请求头带出来：普通歌走音源不需要头，有声书的音频 CDN 常常校验
 * Referer（六月、悦听这类站都如此），缺了就是 403/404。
 */
interface ResolvedAudio {
  url: string;
  headers: Record<string, string>;
}

/** 落盘结构（字段可选：老文件可能缺） */
interface DownloadIndexData {
  version?: number;
  items?: DownloadItem[];
}

const INDEX_VERSION: number = 1;

/**
 * 下载记录的唯一键
 *
 * mediaKey（平台_歌曲id_哈希）优先：同一首歌在不同列表里 id 可能不同，
 * 但 musicInfo 是一样的；没有 musicInfo 的条目退回条目 id —— 有声书就走这一条：
 * 它的载荷是 BookPlayPayload（算不出 mediaKey），条目 id 形如 `book_<书id>_<集号>`，
 * 本身稳定唯一，而且与播放链路用的是同一个 id（`downloadedFile(item.id)` 才对得上）。
 */
export function downloadKeyOf(song: SongItem): string {
  const media: string = mediaKeyOf(song.musicInfoJson);
  return media.length > 0 ? media : song.id;
}

function asNumber(value: Object | undefined): number {
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/**
 * 解析播放链接失败时，值不值得再试一次
 *
 * 「音源没加载 / 不支持这个平台 / 这条记录缺歌曲信息 / 书源被删了」这类是**配置问题**，
 * 重试一百次也是同一个结果，只会白占队列；超时、被限流、脚本报错这些是网络或服务端的
 * 临时状态，重试有意义。
 */
function retryableResolveFailure(message: string): boolean {
  const permanent: string[] = [
    '音源没有加载',
    '音源未加载',
    '不支持平台',
    '未实现 musicUrl',
    '没有可解析的歌曲信息',
    '缺书籍信息',
    '书源已经被删掉',
    '书源规则可能已失效',
    '这一集需要登录',
  ];
  for (const one of permanent) {
    if (message.includes(one)) {
      return false;
    }
  }
  return true;
}

/**
 * 下载请求本身抛出来的错误值不值得重试
 *
 * 错误消息里出现 4xx（多是被拒、链接过期）就不重试；其余（连接被断、超时、被掐断）
 * 当作网络抖动，重试一次。用词边界匹配，免得把「2300499」这类端口/错误码里的数字
 * 当成 HTTP 404。
 */
function retryableNetworkFailure(message: string): boolean {
  return !/\b4\d{2}\b/.test(message);
}

/**
 * 老索引文件里没有的字段补成空串
 *
 * 下载记录是 JSON 落盘的，加了新字段（如 tagNote）之后，升级前写下的文件里
 * 没有这个键，读出来就是 undefined —— 界面上一取 .length 就崩。
 */
function orEmpty(value: string | undefined): string {
  return value !== undefined && value !== null ? value : '';
}

/**
 * 给一个 Promise 加超时（超时就 reject）
 *
 * 与 DownloadTags 里那个同名函数不一样：那个超时返回兜底值（标签没有就算了），
 * 这里的超时必须走**失败**分支 —— 调用方据此退回应用内目录。若把超时当成正常结果，
 * 会拿到一个没有句柄的「保存位置」。
 */
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void) => {
    let settled: boolean = false;
    const timer: number = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      reject(new Error(`等待超过 ${Math.round(ms / 1000)} 秒`));
    }, ms);
    promise.then((value: T) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }, (err: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(err);
    });
  });
}

/** 文件名不能带路径分隔符与系统保留字符，统一洗一遍 */
function sanitizeFileName(name: string): string {
  let out: string = '';
  for (let i = 0; i < name.length; i++) {
    const ch: string = name.charAt(i);
    if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' || ch === '"'
      || ch === '<' || ch === '>' || ch === '|' || ch.charCodeAt(0) < 32) {
      out += '_';
      continue;
    }
    out += ch;
  }
  const trimmed: string = out.trim().replace(/^\.+/, '');
  return trimmed.length > 0 ? trimmed : '未命名';
}

export class DownloadManager {
  private static instance: DownloadManager | null = null;

  static getInstance(): DownloadManager {
    if (DownloadManager.instance === null) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  /** 应用内的下载目录（系统公共目录不可用时的兜底） */
  private dir: string = '';
  /** 保存对话框要用 */
  private context: common.Context | null = null;
  private inited: boolean = false;
  private items: DownloadItem[] = [];
  private active: number = 0;
  /** 正在跑的有声书任务数（有声书串行，见 nextWaiting） */
  private activeBook: number = 0;
  /** 上一集有声书开工的时刻（用来算集间间隔，见 bookPace） */
  private bookPacedAt: number = 0;
  /** 正在下载的请求句柄：删除 / 取消时要 destroy 掉 */
  private requests: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();
  private lastBumpAt: number = 0;
  private persistTimer: number = 0;
  /** 自动下载等播放缓过来时的复查定时器 */
  private pumpTimer: number = 0;

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.context = context;
    this.dir = `${context.filesDir}/${DIR_NAME}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create download dir failed: %{public}s', JSON.stringify(e));
      return;
    }
    this.inited = true;
    this.loadIndex();
    // 「缓存时自动下载」的入口注册在这里：播放层不 import 下载器，只按
    // DownloadIndex 里的窄接口说话（那个模块是叶子，见它的说明）
    setAutoDownloadHandler((song: AutoDownloadSong): boolean => {
      return this.enqueueAuto(song) !== null;
    });
    this.bump();
    hilog.info(DOMAIN, TAG, 'download manager ready, %{public}d record(s)', this.items.length);
  }

  /**
   * 「缓存时自动下载」排进来的一首：与用户点的下载同一条队列
   *
   * 只把字段搬过来（DownloadIndex 里那份声明是为了不 import SongItem）。
   * 音质用播放用的那一档，别让听的和存下来的不是一个东西。
   */
  private enqueueAuto(song: AutoDownloadSong): DownloadItem | null {
    const item: SongItem = {
      id: song.id,
      name: song.name,
      singer: song.singer,
      coverUrl: song.coverUrl,
      art: song.art,
      source: song.source,
      quality: song.quality,
      interval: song.interval,
      musicInfoJson: song.musicInfoJson,
    };
    return this.enqueue(item, true);
  }

  isReady(): boolean {
    return this.inited;
  }

  /** 应用内下载目录（设置页显示用） */
  appDir(): string {
    return this.dir;
  }

  /** 下载列表：新的在前 */
  list(): DownloadItem[] {
    const out: DownloadItem[] = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      out.push(this.items[i]);
    }
    return out;
  }

  count(): number {
    return this.items.length;
  }

  /** 正在下载 / 排队中的条数（列表页的副标题用） */
  activeCount(): number {
    let n: number = 0;
    for (const item of this.items) {
      if (item.status === 'downloading' || item.status === 'waiting') {
        n++;
      }
    }
    return n;
  }

  stateOf(key: string): DownloadItem | null {
    for (const item of this.items) {
      if (item.key === key) {
        return item;
      }
    }
    return null;
  }

  isDownloaded(key: string): boolean {
    const item: DownloadItem | null = this.stateOf(key);
    return item !== null && item.status === 'done';
  }


  /** 下载记录 -> 可播放条目（下载管理页点一下就能放） */
  toSong(item: DownloadItem): SongItem {
    return {
      id: item.key,
      name: item.name,
      singer: item.singer,
      coverUrl: item.coverUrl,
      art: item.art,
      source: item.source,
      quality: item.quality,
      interval: item.interval,
      musicInfoJson: item.musicInfoJson,
    };
  }

  // ---------------------------------------------------------------- 入队

  /**
   * 下载一首歌 / 一集有声书
   *
   * 已经下过 / 正在下的直接返回已有记录（不重复下）；失败过的重新排一次队。
   * 返回 null 表示当前状态没法下（没有音源、条目没有 musicInfo 等）。
   *
   * @param auto 「缓存时自动下载」排进来的（见 pump 里的让路规则），用户点的下载传 false
   */
  enqueue(song: SongItem, auto: boolean = false): DownloadItem | null {
    if (!this.inited) {
      return null;
    }
    // 本地歌（从设备导入进来的音频）已经在本机了，没有下载的意义：
    // 在这里拦一道，任何入口都不会把它排进下载队列
    if (isLocalSong(song)) {
      return null;
    }
    // 云端歌（WebDAV）也不走这条队列：它没有音源链接，而是由播放缓存的
    // 「边听边下」自己带认证头下载（见 AudioCache / PlaySession.playWebDavItem）
    if (isWebDavSong(song)) {
      return null;
    }
    // 有声书不参与「缓存时自动下载」：那条设置是给播放缓存配套的（听过的落盘、别再问平台），
    // 而有声书没有播放缓存；真按它自动排，就是听一集偷偷下一集，还每集都要跑一遍书源规则。
    // 手动点「下载」（auto = false）照常收。
    if (auto && song.source === BOOK_SOURCE) {
      return null;
    }
    const key: string = downloadKeyOf(song);
    if (key.length === 0) {
      return null;
    }
    const existed: DownloadItem | null = this.stateOf(key);
    if (existed !== null) {
      // 用户点的那一下比自动排的更急：本来是自动排的，现在就当成手动下载（立即开工）
      existed.auto = existed.auto && auto;
      // 「已下载，但这次启动读不到」：公共下载目录给的是会话级授权（见 loadIndex），
      // 重启后系统就收了回去。再走一遍保存对话框会重新拿到授权，文件重写一遍就能读了 ——
      // 这是唯一能让它自己好起来的办法，不然「下载过 = 离线能放」在重启后永远不成立。
      const unreadable: boolean = existed.status === 'done'
        && existed.uri.startsWith(PUBLIC_URI_PREFIX)
        && downloadedFile(existed.key).length === 0;
      if (unreadable) {
        hilog.info(DOMAIN, TAG, 're-download to renew dir grant: %{public}s', existed.name);
      }
      if (existed.status === 'error' || unreadable) {
        existed.status = 'waiting';
        existed.error = '';
        existed.tagNote = '';
        existed.retries = 0;
        existed.received = 0;
        existed.total = 0;
        this.persist();
        this.pump();
      }
      return existed;
    }
    const item: DownloadItem = {
      key: key,
      name: song.name,
      singer: song.singer,
      source: song.source,
      quality: song.quality,
      interval: song.interval,
      coverUrl: song.coverUrl,
      art: song.art,
      musicInfoJson: song.musicInfoJson,
      fileName: '',
      uri: '',
      received: 0,
      total: 0,
      status: 'waiting',
      error: '',
      note: '',
      tagNote: '',
      auto: auto,
      retries: 0,
      createdAt: Date.now(),
    };
    this.items.push(item);
    this.persist();
    this.pump();
    return item;
  }

  /** 批量下载，返回真正排进队列的条数（已在列表里的不重复排） */
  enqueueMany(songs: SongItem[]): number {
    let added: number = 0;
    for (const song of songs) {
      const existed: DownloadItem | null = this.stateOf(downloadKeyOf(song));
      if (existed !== null && existed.status !== 'error') {
        continue;
      }
      if (this.enqueue(song) !== null) {
        added++;
      }
    }
    return added;
  }

  retry(key: string): void {
    const item: DownloadItem | null = this.stateOf(key);
    if (item === null || item.status === 'downloading' || item.status === 'waiting') {
      return;
    }
    item.status = 'waiting';
    item.error = '';
    item.note = '';
    item.tagNote = '';
    // 用户点的「重新下载」就按手动下载走：立即开工，不再等播放缓过来
    item.auto = false;
    item.received = 0;
    item.total = 0;
    // 用户主动重来一次：自动重试的次数也归零
    item.retries = 0;
    this.persist();
    this.pump();
  }

  /** 删除记录（正在下的先取消）；已下载的文件也一并删掉 */
  remove(key: string): void {
    const item: DownloadItem | null = this.stateOf(key);
    if (item === null) {
      return;
    }
    const request: http.HttpRequest | undefined = this.requests.get(key);
    if (request !== undefined) {
      // 先改状态再销毁请求：下载协程收尾时会看到「已不是 downloading」，
      // 直接丢掉 .part，不会去 rename 或往列表里写一条已经删掉的记录
      item.status = 'error';
      item.error = '已取消';
      this.requests.delete(key);
      try {
        request.destroy();
      } catch (e) {
        // 已经结束的请求 destroy 报错无所谓
      }
    }
    if (item.uri.length > 0) {
      this.unlinkQuietly(item.uri);
      this.unlinkQuietly(`${item.uri}${PART_SUFFIX}`);
    }
    removeDownloadedFile(item.key);
    const next: DownloadItem[] = [];
    for (const one of this.items) {
      if (one.key !== key) {
        next.push(one);
      }
    }
    this.items = next;
    this.persist();
    this.bump();
  }

  /** 清空已完成 / 失败的记录（正在下的留着） */
  clearFinished(): number {
    const kept: DownloadItem[] = [];
    let removed: number = 0;
    for (const item of this.items) {
      if (item.status === 'done' || item.status === 'error') {
        if (item.uri.length > 0) {
          this.unlinkQuietly(item.uri);
        }
        removeDownloadedFile(item.key);
        removed++;
        continue;
      }
      kept.push(item);
    }
    if (removed > 0) {
      this.items = kept;
      this.persist();
      this.bump();
    }
    return removed;
  }

  // ---------------------------------------------------------------- 保存位置

  /**
   * 下载目录的展示名（设置页 / 下载管理里显示 / 提示用户去哪找）
   *
   * 目录是系统给的，这里把它裁成用户认得的写法：
   *   `file://docs/storage/Users/currentUser/Download/com.example.listen` -> `下载/聆听`
   * 两处「翻译」的理由：
   *   1. 路径里的 `Download` 显示成「下载」——「文件管理」中文界面里那一条就叫「下载」，
   *      显示英文名用户会以为不是一个地方；
   *   2. DOWNLOAD 模式建的目录用的是**包名**（官方文档：自动创建在 `Download/包名/` 目录），
   *      而「文件管理」界面里把它显示成应用名（「聆听」）—— 用户看到的是后者，
   *      所以末段等于自己的包名时换成应用名（见 displayDirName）。
   * 一次都没写进公共目录（保存对话框失败、全落在应用内目录）时如实说明。
   */
  folderLabel(): string {
    const uri: string = this.publicDirUri();
    if (uri.length === 0) {
      return '应用内目录（文件管理里看不到）';
    }
    let decoded: string = uri;
    try {
      decoded = decodeURIComponent(uri);
    } catch (e) {
      // uri 里的 % 解不开就按原文显示
    }
    const at: number = decoded.lastIndexOf('/Download/');
    if (at >= 0) {
      const tail: string = decoded.substring(at + '/Download/'.length);
      return `下载/${this.displayDirName(tail)}`;
    }
    const cut: number = decoded.lastIndexOf('/');
    const tail: string = cut >= 0 ? decoded.substring(cut + 1) : decoded;
    return tail.length > 0 ? this.displayDirName(tail) : decoded;
  }

  /**
   * 目录末段换成用户认得的名字
   *
   * 末段等于自己的包名（`com.example.listen`）时换成应用名（`聆听`）：物理目录用的是包名，
   * 但用户在「文件管理」里看到的是应用名，显示 `下载/com.example.listen` 会让人以为
   * 跟文件管理里那个「聆听」不是一个地方。不是包名（别的机型/版本可能直接用应用名建目录）
   * 就原样返回 —— 这里不猜、也不写死任何名字。
   */
  private displayDirName(name: string): string {
    const context = this.context;
    if (context === null) {
      return name;
    }
    let bundle: string = '';
    try {
      bundle = context.applicationInfo.name;
    } catch (e) {
      return name;
    }
    if (name !== bundle) {
      return name;
    }
    const label: string = this.appLabel();
    return label.length > 0 ? label : name;
  }

  /**
   * 应用名（`app_name` 资源，与「文件管理」里显示的一致）
   *
   * 三条路依次试，哪条先拿到用哪条 —— 这里取不到就得把包名亮给用户看，所以宁可多试：
   *   1. `applicationInfo.labelId`（app.json5 里 label 指向的那个字符串资源，编译器算好的 id）；
   *   2. 按资源名找 `app_name`（工程里这个 key 就是应用名，不依赖 id 怎么生成）；
   *   3. 按 `$r('app.string.app_name')` 的 id 找（老写法，兜底）。
   * `applicationInfo.label` 不用：它可能是 `$string:xxx` 这样的描述符原文，显示出来更糟。
   */
  private appLabel(): string {
    const context = this.context;
    if (context === null) {
      return '';
    }
    try {
      const labelId: number = context.applicationInfo.labelId;
      if (labelId > 0) {
        const byLabelId: string = context.resourceManager.getStringSync(labelId);
        if (byLabelId.length > 0) {
          return byLabelId;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'app label by labelId failed: %{public}s', JSON.stringify(e));
    }
    try {
      const byName: string = context.resourceManager.getStringByNameSync('app_name');
      if (byName.length > 0) {
        return byName;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'app label by name failed: %{public}s', JSON.stringify(e));
    }
    try {
      return context.resourceManager.getStringSync($r('app.string.app_name').id);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'app label by resource id failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * 下载目录的 uri（公共目录）
   *
   * 首选设置里记下的（保存成功过一次就有）；没有就从下载记录里挑一条公共目录的文件
   * uri 现算。都没有说明还没写进过公共目录 —— 返回空串，不去猜一个目录名字出来：
   * 猜错了会把用户指到一个不存在的地方。
   */
  private publicDirUri(): string {
    const learned: string = DownloadSettings.getInstance().getDownloadDirUri();
    if (learned.length > 0) {
      return learned;
    }
    for (let i = this.items.length - 1; i >= 0; i--) {
      const uri: string = this.items[i].uri;
      if (!uri.startsWith(PUBLIC_URI_PREFIX)) {
        continue;
      }
      const cut: number = uri.lastIndexOf('/');
      if (cut > PUBLIC_URI_PREFIX.length) {
        return uri.substring(0, cut);
      }
    }
    return '';
  }

  /**
   * 打开这次下载要写的位置
   *
   * 目标固定是**应用自己的下载目录**（用户不再选保存位置），按两条路试：
   *
   *   1. 系统保存对话框的 DOWNLOAD 模式（`save(pickerMode = DOWNLOAD)`）：不弹界面，
   *      系统返回 Download/<包名>/ 这个**目录** uri（带持久化权限），我们拼上文件名
   *      自己建文件。这是手机上把文件写进「文件管理」能看到的目录的**唯一**官方通路 ——
   *      `Environment.getUserDownloadDir()` 那条路依赖 syscap
   *      `File.Environment.FolderObtain`，手机不具备（编译器直接报 28005）。
   *   2. 应用内 files/Download。第 1 条失败时的兜底：歌下得来、也能播，
   *      但在「文件管理」里看不到，所以把失败原因写进 note，列表里如实显示。
   *
   * 返回 null 表示这次下载没法开始（拿不到可写句柄）。
   */
  private async openTarget(fileName: string): Promise<WriteTarget | null> {
    const attempt: PickerAttempt = await this.openViaPicker(fileName);
    if (attempt.target !== null) {
      return attempt.target;
    }
    const target: string = this.uniquePath(this.dir, fileName);
    const handle: fs.File | null = this.openPart(target);
    if (handle === null) {
      return null;
    }
    return {
      path: target,
      part: `${target}${PART_SUFFIX}`,
      handle: handle,
      fallback: true,
      reason: attempt.reason,
    };
  }

  /** 记下这条路的目录 uri（设置页「下载目录」显示的就是它） */
  private learnDirOf(dirUri: string): void {
    DownloadSettings.getInstance().learnDownloadDir(dirUri);
  }

  /** 第 2 条路（系统保存对话框）的结果：target 非空=成功，否则 reason 是失败原因 */
  private async openViaPicker(fileName: string): Promise<PickerAttempt> {
    const context = this.context;
    if (context === null) {
      return { target: null, reason: '应用上下文还没准备好' };
    }
    try {
      const options = new picker.DocumentSaveOptions();
      // DOWNLOAD 模式下只认 pickerMode，别的选项（含 newFileNames）都不生效，
      // 所以文件名不在这里给：拿到目录之后自己拼。
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      // 加超时：这一步不返回的话这个任务会永远占着一个并发位（见 PICKER_TIMEOUT_MS），
      // 超时按失败走 -> 调用方退回应用内目录，歌照样下得来
      const uris: string[] = await withTimeout(
        new picker.DocumentViewPicker(context).save(options), PICKER_TIMEOUT_MS);
      if (uris.length === 0) {
        return { target: null, reason: '系统保存对话框没有返回可用地址' };
      }
      // 返回的是**目录** uri（Download/包名/），不是文件 uri —— 官方 save-user-file 的
      // DOWNLOAD 模式示例就是这么用的：拼上文件名 -> 转成路径 -> CREATE 建文件。
      // 之前把它当文件 uri 打开、还带 TRUNC（目录打不开），这条路径其实一直是失败的，
      // 只是失败被静默吞掉、直接落到了应用内目录。
      const dirUri: string = uris[0];
      const path: string = new fileUri.FileUri(`${dirUri}/${fileName}`).path;
      // TRUNC：同名文件（重下同一首、或两首歌撞了同一个文件名）要从头写。不截断的话
      // 新内容比旧文件短时，尾巴上会留着上一次的字节，拼出一个坏文件。
      const handle: fs.File = fs.openSync(path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      this.learnDirOf(dirUri);
      return { target: { path: path, part: '', handle: handle, fallback: false, reason: '' },
        reason: '' };
    } catch (e) {
      const error = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'save dialog failed: %{public}s', JSON.stringify(e));
      return { target: null, reason: `系统保存目录没能用上（${error.code} ${error.message}）` };
    }
  }

  // ---------------------------------------------------------------- 队列

  private pump(): void {
    if (!this.inited) {
      return;
    }
    while (this.active < MAX_ACTIVE) {
      const next: DownloadItem | null = this.nextWaiting();
      if (next === null) {
        return;
      }
      // 自动排进来的给播放让路：播放器正等着数据（起播 / 卡顿 / 缓冲不够）就先不开工，
      // 过几秒回来看一眼。用户自己点的下载不受这条约束 —— 那是用户正在等的活儿
      // （同一套判断见 LxPlayer.canUseBandwidthForCache 与 AudioCache 的让路调度）。
      //
      // 这条日志是排查「边听边下不下了」的关键：它说明歌**已经排在队列里**、只是没轮到
      // 开工。如果连这条都没有，问题在播放层（没排进来），不在这里。
      if (next.auto && !LxPlayer.getInstance().canUseBandwidthForCache()) {
        const player = LxPlayer.getInstance();
        hilog.info(DOMAIN, TAG,
          'auto task defers (playback busy): %{public}s, player %{public}s buffering=%{public}s active=%{public}d',
          next.name, player.getStatus(), player.isBuffering() ? 'yes' : 'no', this.active);
        this.schedulePump();
        return;
      }
      this.active++;
      hilog.info(DOMAIN, TAG, 'task start: %{public}s (%{public}s, auto=%{public}s, active=%{public}d)',
        next.name, next.source, next.auto ? 'yes' : 'no', this.active);
      void this.startTask(next);
    }
  }

  /**
   * 下一个该开工的：用户点的下载排在自动下载前面
   *
   * 自动排进来的可以等（就是「边听边下」那批），别让它们把用户正在等的下载堵在后面。
   *
   * 有声书另外受一条限制：一次只跑一集。下一集要抓页面 + 跑规则（多次网络往返），
   * 并发几集就是对站点的并发扫描，整本一起下更甚；串行 + 集间间隔（bookPace）就够了。
   * 串行只挡有声书自己，歌照旧按 MAX_ACTIVE 跑。
   */
  private nextWaiting(): DownloadItem | null {
    const bookBusy: boolean = this.activeBook > 0;
    let auto: DownloadItem | null = null;
    for (const item of this.items) {
      if (item.status !== 'waiting') {
        continue;
      }
      if (bookBusy && item.source === BOOK_SOURCE) {
        continue;
      }
      if (!item.auto) {
        return item;
      }
      if (auto === null) {
        auto = item;
      }
    }
    return auto;
  }

  /** 自动下载等播放缓过来时的复查（不占网络，只是过一会儿回来看一眼） */
  private schedulePump(): void {
    if (this.pumpTimer !== 0) {
      return;
    }
    this.pumpTimer = setTimeout(() => {
      this.pumpTimer = 0;
      this.pump();
    }, AUTO_WAIT_MS);
  }

  /**
   * 跑一个下载任务
   *
   * 外面这层只管「一个任务占一个并发位、结束时一定还回去」：不管中途成功、失败、
   * 被取消，还是抛了没预料到的异常，finally 里统一收尾。真正的下载逻辑在 runTask，
   * 里面所有分支都只是 return —— 不再各自去动 active，避免漏减或重复减。
   *
   * 失败会在这里决定要不要自动重试：可重试的（超时 / 5xx / 停滞）放回 waiting，
   * 由 finally 里的 pump 再排一次（retries 记账，到 MAX_RETRY 为止）。这样
   * 「网络抖一下就永久变成失败、要用户手点」这件事不会发生。
   */
  private async startTask(item: DownloadItem): Promise<void> {
    const isBook: boolean = item.source === BOOK_SOURCE;
    const startedAt: number = Date.now();
    if (isBook) {
      this.activeBook++;
    }
    try {
      await this.runTask(item);
    } catch (e) {
      this.failOrRetry(item, (e as Error).message, true);
    } finally {
      this.active--;
      if (isBook) {
        this.activeBook--;
      }
      hilog.info(DOMAIN, TAG, 'task end: %{public}s -> %{public}s (%{public}dms, active=%{public}d)',
        item.name, item.status, Date.now() - startedAt, this.active);
      this.persist();
      this.bump();
      this.pump();
    }
  }

  /**
   * 有声书的集间间隔
   *
   * 只在有声书任务开头调；因为有声书是串行的（nextWaiting），这里等的就是
   * 「上一集结束到现在」的时间 —— 连着下整本时每集之间留 BOOK_TASK_GAP_MS，
   * 免得规则解析把站点连着打一遍。
   */
  private async bookPace(): Promise<void> {
    const elapsed: number = Date.now() - this.bookPacedAt;
    const wait: number = BOOK_TASK_GAP_MS - elapsed;
    if (this.bookPacedAt > 0 && wait > 0) {
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), wait);
      });
    }
    this.bookPacedAt = Date.now();
  }

  private async runTask(item: DownloadItem): Promise<void> {
    item.status = 'downloading';
    item.error = '';
    item.tagNote = '';
    item.received = 0;
    item.total = 0;
    this.bump();

    // 0) 有声书串行 + 集间间隔：下一集要抓页面 + 跑规则，整本连着下就是对站点的扫描
    if (item.source === BOOK_SOURCE) {
      await this.bookPace();
      if (item.status !== 'downloading') {
        return;
      }
    }

    // 1) 解析播放链接（要几秒，期间可能被删掉）
    //    封面与歌词同时开跑：标签必须赶在音频数据落盘之前凑齐（见 TagSink）。
    //    有声书不凑标签：那是音乐那套（歌名/歌手/歌词），书这边没有可凑的东西，
    //    硬凑还会拿书名去平台搜一轮，纯属白跑。
    const tagsTask: Promise<DownloadTagData> = item.source === BOOK_SOURCE
      ? Promise.resolve(NO_TAGS)
      : collectDownloadTags(item.name, item.singer, item.musicInfoJson, item.coverUrl);
    let resolved: ResolvedAudio;
    try {
      resolved = await this.resolveUrl(item);
    } catch (e) {
      this.failOrRetry(item, (e as Error).message, retryableResolveFailure((e as Error).message));
      return;
    }
    if (item.status !== 'downloading') {
      return;
    }
    const url: string = resolved.url;
    const tags: DownloadTagData = await tagsTask;

    // 2) 打开保存位置（固定存进应用自己的下载目录，见 openTarget）
    const ext: string = this.extOf(url, item.quality);
    const fileName: string = this.buildFileName(item, ext);
    item.fileName = fileName;
    let write: WriteTarget | null = null;
    try {
      write = await this.openTarget(fileName);
    } catch (e) {
      this.fail(item, `保存位置不可用：${(e as Error).message}`);
      return;
    }
    if (write === null) {
      this.fail(item, '已取消（没有选择保存位置）');
      return;
    }
    item.note = write.fallback
      ? `已存到应用内目录（「文件管理」看不到）：${write.reason}`
      : '';
    if (item.status !== 'downloading') {
      this.closeQuietly(write.handle);
      return;
    }
    const target: string = write.path;
    const part: string = write.part;

    // 3) 边收边写：沙箱路径先写 .part、下完改名；系统保存给的 uri 直接写
    const file: fs.File = write.handle;
    const request: http.HttpRequest = http.createHttp();
    this.requests.set(item.key, request);
    // 封面 / 歌词跟着音频一起写进文件：mp3 写 ID3v2、flac 写元数据块（见 TagSink）
    const sink: TagSink = new TagSink(file.fd, tags);
    // 数据心跳：每收到一块就记一下，看门狗据此判断这次连接是不是已经死了
    let lastDataAt: number = Date.now();
    let stalled: boolean = false;

    request.on('headersReceive', (header: Object) => {
      const length: number = asNumber((header as Record<string, Object>)['content-length']);
      if (length > 0) {
        item.total = length;
        this.bump();
      }
    });
    request.on('dataReceive', (data: ArrayBuffer) => {
      lastDataAt = Date.now();
      try {
        sink.write(data);
        item.received += data.byteLength;
        this.throttledBump();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write chunk failed: %{public}s', JSON.stringify(e));
      }
    });

    // 看门狗：readTimeout 是 5 分钟，靠它兜底等于让一首卡死的歌霸占一个并发位 5 分钟
    //（两个位都这样就是 10 分钟不下任何东西）。这里自己盯着数据心跳，卡死就掐断，
    // 让这次任务尽快收尾（还能自动重试一次）。
    const watchdog: number = setInterval(() => {
      if (Date.now() - lastDataAt < STALL_LIMIT_MS) {
        return;
      }
      stalled = true;
      hilog.warn(DOMAIN, TAG, 'download stalled, aborting: %{public}s (%{public}d bytes)',
        item.name, item.received);
      try {
        request.destroy();
      } catch (e) {
        // 已经结束
      }
    }, STALL_CHECK_MS);

    try {
      const code: number = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 300000,
        // 有声书的音频 CDN 常校验 Referer（六月、悦听这类站都如此）：书源里
        // 声明的请求头要跟着这一跳带过去，否则直链能解析出来但下不动（403/404）
        header: resolved.headers,
      });
      clearInterval(watchdog);
      // 收尾：开头还攒着的（下载太短、没认出来）补写出去
      sink.finish();
      this.closeQuietly(file);
      this.requests.delete(item.key);
      if (item.status !== 'downloading') {
        // 期间被取消：丢掉半截文件
        this.cleanupFailed(part, target);
        return;
      }
      if (stalled) {
        this.failOrRetry(item, `下载停滞（${Math.round(STALL_LIMIT_MS / 1000)} 秒没有数据）`, true);
        return;
      }
      if (code !== 200) {
        // 4xx 多半是链接过期 / 被拒（重试没用），5xx 与 0 是服务端或连接问题（值得再来一次）
        this.cleanupFailed(part, target);
        this.failOrRetry(item, `下载失败（HTTP ${code}）`, code >= 500 || code === 0);
        return;
      }
      if (item.received === 0) {
        this.cleanupFailed(part, target);
        this.failOrRetry(item, '下载失败（没收到数据）', true);
        return;
      }
      item.tagNote = this.tagNoteOf(sink, tags, ext);
      try {
        if (part.length > 0) {
          // 沙箱路径：写完才改名（.part 不会被当成正式文件）
          this.unlinkQuietly(target);
          fs.renameSync(part, target);
        }
        item.uri = target;
        item.status = 'done';
        setDownloadedFile(item.key, target);
        hilog.info(DOMAIN, TAG, 'download done: %{public}s -> %{public}s', item.name, item.fileName);
      } catch (e) {
        this.cleanupFailed(part, target);
        this.fail(item, `写入文件失败：${(e as BusinessError).message}`);
      }
    } catch (e) {
      clearInterval(watchdog);
      this.closeQuietly(file);
      this.cleanupFailed(part, target);
      this.requests.delete(item.key);
      if (item.status === 'downloading') {
        // 看门狗掐断的那次：错误消息是「请求被中止」这类，按可重试处理（本来也是网络问题）
        const message: string = (e as BusinessError).message;
        this.failOrRetry(item, stalled ? `下载停滞（${Math.round(STALL_LIMIT_MS / 1000)} 秒没有数据）` : message,
          stalled || retryableNetworkFailure(message));
      }
    } finally {
      clearInterval(watchdog);
      try {
        request.destroy();
      } catch (e) {
        // 已销毁
      }
    }
  }

  /**
   * 解析出可下载的地址（连带请求头）
   *
   * 分两条链路：平台歌 / 洛雪音源走音质协商；有声书走书源规则（见 resolveBookUrl）。
   */
  private async resolveUrl(item: DownloadItem): Promise<ResolvedAudio> {
    if (item.source === BOOK_SOURCE) {
      return await this.resolveBookUrl(item);
    }
    const engine = SourceEngine.getInstance();
    if (!engine.isInited()) {
      throw new Error('音源没有加载，先去「设置 - 音源设置」加载一个音源');
    }
    if (item.musicInfoJson.length === 0) {
      throw new Error('这首歌没有可解析的歌曲信息（不是平台搜索结果）');
    }
    const quality: string = pickQuality(item.musicInfoJson, item.source, item.quality);
    item.quality = quality;
    try {
      return { url: await engine.getMusicUrl(item.musicInfoJson, quality as LxQuality, item.source), headers: {} };
    } catch (err) {
      const retry: string = fallbackQuality(item.musicInfoJson, item.source, quality);
      if (retry.length === 0) {
        throw err as Error;
      }
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed, retry with %{public}s', quality, retry);
      item.quality = retry;
      return { url: await engine.getMusicUrl(item.musicInfoJson, retry as LxQuality, item.source), headers: {} };
    }
  }

  /**
   * 有声书：跑这一集的书源规则解析音频直链
   *
   * 与播放链路（PlaySession.playBookItem）走的是同一套 `resolveAudioOf`，
   * 所以「能放的一定能下、能下的一定能放」；请求头也从书源里取（`audioHeaders`），
   * 音频 CDN 校验 Referer 时靠它。
   *
   * 载荷里带的就是「哪个书源、哪本书、哪一集」（BookPlayPayload），够解析用了 ——
   * 不需要用户此刻正在看那本书，也不需要那个书源在界面上被选中。
   */
  private async resolveBookUrl(item: DownloadItem): Promise<ResolvedAudio> {
    const payload: BookPlayPayload | null = parseBookPayload(item.musicInfoJson);
    if (payload === null) {
      throw new Error('这条听书记录缺书籍信息（可能是旧版本排进来的），请回到书籍页重新下载');
    }
    const engine = BookEngine.getInstance();
    if (engine.getSource(payload.sourceId) === null) {
      throw new Error('这本书用的书源已经被删掉了，请重新导入后再下载');
    }
    const audio: BookAudio = await engine.resolveAudioOf(
      payload.sourceId,
      payload.bookUrl,
      payload.bookName,
      payload.chapterUrl,
      payload.chapterName,
      payload.chapterIndex
    );
    if (audio.url.length === 0) {
      throw new Error('这一集没解析出音频地址（书源规则可能已失效，或这一集需要登录）');
    }
    return { url: audio.url, headers: engine.audioHeaders(payload.sourceId) };
  }

  /** 标记失败（只管状态，并发位的收尾在 startTask 的 finally 里） */
  private fail(item: DownloadItem, message: string): void {
    item.status = 'error';
    item.error = message;
    item.received = 0;
    item.total = 0;
  }

  /**
   * 失败收尾：能重试的放回队列再排一次（最多 MAX_RETRY 次），否则如实标成失败
   *
   * 为什么要自动重试一次：解析链接（音源沙箱）和下载都走网络，快速切歌时音源沙箱
   * 容易被抢、CDN 也会抖一下。以前这类失败直接变成「下载失败」，用户得手点重试 ——
   * 表现就是「听着听着就不下了，列表里一串失败」。重试只是把同一件事再试一次，
   * 真到上限时显示的是最后一次的真实原因。
   *
   * 放回 waiting 之后由 startTask 的 finally 里那次 pump 接着排；自动排进来的那批
   * 仍然要过「给播放让路」那道闸，所以不会和播放抢网络。
   */
  private failOrRetry(item: DownloadItem, message: string, retryable: boolean): void {
    if (item.status !== 'downloading') {
      // 期间被取消 / 从列表里删掉了：调用方已经收过尾，别再动它
      return;
    }
    if (retryable && item.retries < MAX_RETRY) {
      item.retries++;
      item.status = 'waiting';
      item.error = '';
      item.received = 0;
      item.total = 0;
      hilog.info(DOMAIN, TAG, 'retry %{public}d/%{public}d: %{public}s (%{public}s)',
        item.retries, MAX_RETRY, item.name, message);
      return;
    }
    this.fail(item, retryable ? `${message}（已自动重试 ${item.retries} 次）` : message);
  }

  /**
   * 标签嵌入结果（列表里跟「已下载」一起显示）
   *
   * 三种情况分开说：真嵌进去了就说嵌了什么；容器是我们写不了标签的（m4a 等）
   * 如实说明，免得用户以为「封面歌词没嵌进去」是下载出了问题；其余（这首歌
   * 本来就取不到封面 / 歌词）不写，那不是异常。
   */
  private tagNoteOf(sink: TagSink, tags: DownloadTagData, ext: string): string {
    if (sink.embedded()) {
      return tagSummary(tags);
    }
    return sink.knownFormat() === 'other' ? `${ext} 暂不支持写入标签` : '';
  }

  // ---------------------------------------------------------------- 文件名

  /**
   * 文件名按「设置 - 下载设置」拼
   *   格式：歌曲名 / 艺术家-标题 / 标题-艺术家（参考图里的三种）
   *   标注音质：开就把音质缀在名字后面，例如 `夜、萤火虫和你-128k.mp3`
   * 扩展名先从链接里认（很多平台会给 .mp3/.flac），认不出按音质推。
   *
   * 有声书不套这套：那三种格式是「歌名 / 艺术家」的组合，书上对应的是
   * 「书名 / 章节名」，固定按 `书名-章节名` 拼 —— 一集一个文件，整本下完在
   * 文件管理里按名字就是有序的一摞；也不缀音质（`-book` 没有意义）。
   */
  private buildFileName(item: DownloadItem, ext: string): string {
    const book: string = this.bookFileBase(item);
    if (book.length > 0) {
      return this.clampName(book, ext);
    }
    const settings = DownloadSettings.getInstance();
    const format: string = settings.getNameFormat();
    let base: string = item.name;
    if (format === 'artist-title' && item.singer.length > 0) {
      base = `${item.singer}-${item.name}`;
    } else if (format === 'title-artist' && item.singer.length > 0) {
      base = `${item.name}-${item.singer}`;
    }
    if (settings.isMarkQuality() && item.quality.length > 0) {
      base = `${base}-${item.quality}`;
    }
    return this.clampName(base, ext);
  }

  /** 有声书的文件名主体（`书名-章节名`）；不是有声书返回空串 */
  private bookFileBase(item: DownloadItem): string {
    if (item.source !== BOOK_SOURCE) {
      return '';
    }
    const payload: BookPlayPayload | null = parseBookPayload(item.musicInfoJson);
    // item.singer 装的就是书名（见 BookDetailView.toSongItem），载荷缺了也能拼出来
    const bookName: string = payload !== null && payload.bookName.length > 0
      ? payload.bookName
      : item.singer;
    if (bookName.length === 0) {
      return item.name;
    }
    return `${bookName}-${item.name}`;
  }

  /** 洗一遍文件名 + 截到长度上限，再缀扩展名 */
  private clampName(base: string, ext: string): string {
    let name: string = `${sanitizeFileName(base)}.${ext}`;
    if (name.length > MAX_NAME_LEN) {
      const keep: number = MAX_NAME_LEN - ext.length - 1;
      name = `${sanitizeFileName(base).substring(0, keep > 0 ? keep : 1)}.${ext}`;
    }
    return name;
  }

  private extOf(url: string, quality: string): string {
    const queryCut: number = url.indexOf('?');
    const path: string = queryCut >= 0 ? url.substring(0, queryCut) : url;
    const dot: number = path.lastIndexOf('.');
    if (dot > 0) {
      const ext: string = path.substring(dot + 1).toLowerCase();
      if (KNOWN_EXTS.includes(ext)) {
        return ext;
      }
    }
    return EXT_BY_QUALITY[quality] !== undefined ? EXT_BY_QUALITY[quality] : 'mp3';
  }

  /** 同名文件已存在就加 (1)(2)…，不覆盖用户已有的文件 */
  private uniquePath(dir: string, fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const stem: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    const ext: string = dot > 0 ? fileName.substring(dot) : '';
    let candidate: string = `${dir}/${fileName}`;
    let index: number = 1;
    while (this.exists(candidate) && index < 100) {
      candidate = `${dir}/${stem} (${index})${ext}`;
      index++;
    }
    return candidate;
  }

  private exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private openPart(target: string): fs.File | null {
    try {
      return fs.openSync(`${target}${PART_SUFFIX}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open part file failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** 失败 / 取消时清掉半截文件（uri 场景删掉那个空文件） */
  private cleanupFailed(part: string, target: string): void {
    if (part.length > 0) {
      this.unlinkQuietly(part);
      return;
    }
    this.unlinkQuietly(target);
  }

  private closeQuietly(file: fs.File | null): void {
    if (file === null) {
      return;
    }
    try {
      fs.closeSync(file);
    } catch (e) {
      // 关不上就算了
    }
  }

  private unlinkQuietly(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // 不存在或没权限，忽略
    }
  }

  // ---------------------------------------------------------------- 落盘 / 通知

  private loadIndex(): void {
    clearDownloadedFiles();
    let text: string = '';
    try {
      const path: string = `${this.dir}/${INDEX_FILE}`;
      if (fs.accessSync(path)) {
        text = fs.readTextSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read download index failed: %{public}s', JSON.stringify(e));
    }
    if (text.length === 0) {
      return;
    }
    try {
      const data: DownloadIndexData = JSON.parse(text) as DownloadIndexData;
      if (data.version !== INDEX_VERSION || data.items === undefined) {
        return;
      }
      const kept: DownloadItem[] = [];
      for (const raw of data.items) {
        const item: DownloadItem = raw;
        // 老文件可能没有这几个字段（tagNote / auto / retries 都是后加的）
        item.note = orEmpty(item.note);
        item.tagNote = orEmpty(item.tagNote);
        item.auto = item.auto === true;
        item.retries = asNumber(item.retries);
        // 重启时正在下的那些没法接着下（链接带时效），标成可重试
        if (item.status === 'downloading' || item.status === 'waiting') {
          item.status = 'error';
          item.error = '上次没下完（应用重启过），可以重新下载';
          item.received = 0;
        }
        if (item.status === 'done') {
          if (item.uri.length === 0) {
            item.status = 'error';
            item.error = '这条下载记录没有文件路径（可能是很旧的版本留下的），可以重新下载';
          } else if (this.exists(item.uri)) {
            setDownloadedFile(item.key, item.uri);
          } else if (item.uri.startsWith(PUBLIC_URI_PREFIX)) {
            // 公共下载目录里的文件：系统保存对话框给的是**会话级**授权（module.json5 里
            // 特意没声明 FILE_ACCESS_PERSIST 那个受限权限），重启后 App 就读不到它了。
            // 这跟「被清理工具删了」是两回事：文件还在「文件管理」里，只是这次启动没权限，
            // 所以留着 done、把情况写进 note，别标成失败冤枉用户（也免得他重复下载）。
            item.note = '文件在下载目录里，但本次启动系统没给读取授权（重启后要重新联网播）';
            hilog.info(DOMAIN, TAG, 'downloaded file not readable this session: %{public}s', item.uri);
          } else {
            // 应用内目录那份：读不到就是真没了
            item.status = 'error';
            item.error = '文件找不到了（可能被清理过）';
          }
        }
        kept.push(item);
      }
      this.items = kept;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse download index failed: %{public}s', JSON.stringify(e));
    }
  }

  private persist(): void {
    if (!this.inited) {
      return;
    }
    if (this.persistTimer !== 0) {
      return;
    }
    // 合并短时间内的多次写（批量下载时会连续变状态）
    this.persistTimer = setTimeout(() => {
      this.persistTimer = 0;
      this.writeIndex();
    }, 500);
  }

  private writeIndex(): void {
    const data: DownloadIndexData = { version: INDEX_VERSION, items: this.items };
    try {
      const path: string = `${this.dir}/${INDEX_FILE}`;
      const handle = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write download index failed: %{public}s', JSON.stringify(e));
    }
  }

  private bump(): void {
    this.lastBumpAt = Date.now();
    AppStorage.setOrCreate(K_DOWNLOAD_VERSION, this.lastBumpAt);
  }

  private throttledBump(): void {
    const now: number = Date.now();
    if (now - this.lastBumpAt < PROGRESS_THROTTLE_MS) {
      return;
    }
    this.bump();
  }
}
