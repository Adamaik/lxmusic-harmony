import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { mediaKeyOf } from '../music/MediaCache';
import { fallbackQuality, pickQuality } from '../music/Quality';
import { SourceEngine } from '../source/SourceEngine';
import { LxQuality } from '../source/LxTypes';
import { DownloadSettings } from './DownloadSettings';
import { clearDownloadedFiles, removeDownloadedFile, setDownloadedFile } from './DownloadIndex';
import { isLocalSong } from '../local/LocalMusic';

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
};
const KNOWN_EXTS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma'];

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
 * 但 musicInfo 是一样的；没有 musicInfo 的条目（演示数据）退回条目 id。
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
  /** 正在下载的请求句柄：删除 / 取消时要 destroy 掉 */
  private requests: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();
  private lastBumpAt: number = 0;
  private persistTimer: number = 0;

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
    this.bump();
    hilog.info(DOMAIN, TAG, 'download manager ready, %{public}d record(s)', this.items.length);
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
   * 下载一首歌
   *
   * 已经下过 / 正在下的直接返回已有记录（不重复下）；失败过的重新排一次队。
   * 返回 null 表示当前状态没法下（没有音源、条目没有 musicInfo 等）。
   */
  enqueue(song: SongItem): DownloadItem | null {
    if (!this.inited) {
      return null;
    }
    // 本地歌（从设备导入进来的音频）已经在本机了，没有下载的意义：
    // 在这里拦一道，任何入口都不会把它排进下载队列
    if (isLocalSong(song)) {
      return null;
    }
    const key: string = downloadKeyOf(song);
    if (key.length === 0) {
      return null;
    }
    const existed: DownloadItem | null = this.stateOf(key);
    if (existed !== null) {
      if (existed.status === 'error') {
        existed.status = 'waiting';
        existed.error = '';
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
    item.received = 0;
    item.total = 0;
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
      const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
      if (uris.length === 0) {
        return { target: null, reason: '系统保存对话框没有返回可用地址' };
      }
      // 返回的是**目录** uri（Download/包名/），不是文件 uri —— 官方 save-user-file 的
      // DOWNLOAD 模式示例就是这么用的：拼上文件名 -> 转成路径 -> CREATE 建文件。
      // 之前把它当文件 uri 打开、还带 TRUNC（目录打不开），这条路径其实一直是失败的，
      // 只是失败被静默吞掉、直接落到了应用内目录。
      const dirUri: string = uris[0];
      const path: string = new fileUri.FileUri(`${dirUri}/${fileName}`).path;
      const handle: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
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
      this.active++;
      void this.startTask(next);
    }
  }

  private nextWaiting(): DownloadItem | null {
    for (const item of this.items) {
      if (item.status === 'waiting') {
        return item;
      }
    }
    return null;
  }

  /**
   * 跑一个下载任务
   *
   * 外面这层只管「一个任务占一个并发位、结束时一定还回去」：不管中途成功、失败、
   * 被取消，还是抛了没预料到的异常，finally 里统一收尾。真正的下载逻辑在 runTask，
   * 里面所有分支都只是 return —— 不再各自去动 active，避免漏减或重复减。
   */
  private async startTask(item: DownloadItem): Promise<void> {
    try {
      await this.runTask(item);
    } catch (e) {
      this.fail(item, (e as Error).message);
    } finally {
      this.active--;
      this.persist();
      this.bump();
      this.pump();
    }
  }

  private async runTask(item: DownloadItem): Promise<void> {
    item.status = 'downloading';
    item.error = '';
    item.received = 0;
    item.total = 0;
    this.bump();

    // 1) 解析播放链接（要几秒，期间可能被删掉）
    let url: string = '';
    try {
      url = await this.resolveUrl(item);
    } catch (e) {
      this.fail(item, (e as Error).message);
      return;
    }
    if (item.status !== 'downloading') {
      return;
    }

    // 2) 打开保存位置（固定存进应用自己的下载目录，见 openTarget）
    const fileName: string = this.buildFileName(item, url);
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

    request.on('headersReceive', (header: Object) => {
      const length: number = asNumber((header as Record<string, Object>)['content-length']);
      if (length > 0) {
        item.total = length;
        this.bump();
      }
    });
    request.on('dataReceive', (data: ArrayBuffer) => {
      try {
        fs.writeSync(file.fd, data);
        item.received += data.byteLength;
        this.throttledBump();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write chunk failed: %{public}s', JSON.stringify(e));
      }
    });

    try {
      const code: number = await request.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 20000,
        readTimeout: 300000,
      });
      this.closeQuietly(file);
      this.requests.delete(item.key);
      if (item.status !== 'downloading') {
        // 期间被取消：丢掉半截文件
        this.cleanupFailed(part, target);
        return;
      }
      if (code !== 200 || item.received === 0) {
        this.cleanupFailed(part, target);
        this.fail(item, `下载失败（HTTP ${code}）`);
        return;
      }
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
      this.closeQuietly(file);
      this.cleanupFailed(part, target);
      this.requests.delete(item.key);
      if (item.status === 'downloading') {
        this.fail(item, (e as BusinessError).message);
      }
    } finally {
      try {
        request.destroy();
      } catch (e) {
        // 已销毁
      }
    }
  }

  /** 按设置里选的音质协商出链接；拓展音质失败自动退回普通音质 */
  private async resolveUrl(item: DownloadItem): Promise<string> {
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
      return await engine.getMusicUrl(item.musicInfoJson, quality as LxQuality, item.source);
    } catch (err) {
      const retry: string = fallbackQuality(item.musicInfoJson, item.source, quality);
      if (retry.length === 0) {
        throw err as Error;
      }
      hilog.warn(DOMAIN, TAG, 'resolve %{public}s failed, retry with %{public}s', quality, retry);
      item.quality = retry;
      return await engine.getMusicUrl(item.musicInfoJson, retry as LxQuality, item.source);
    }
  }

  /** 标记失败（只管状态，并发位的收尾在 startTask 的 finally 里） */
  private fail(item: DownloadItem, message: string): void {
    item.status = 'error';
    item.error = message;
    item.received = 0;
    item.total = 0;
  }

  // ---------------------------------------------------------------- 文件名

  /**
   * 文件名按「设置 - 下载设置」拼
   *   格式：歌曲名 / 艺术家-标题 / 标题-艺术家（参考图里的三种）
   *   标注音质：开就把音质缀在名字后面，例如 `夜、萤火虫和你-128k.mp3`
   * 扩展名先从链接里认（很多平台会给 .mp3/.flac），认不出按音质推。
   */
  private buildFileName(item: DownloadItem, url: string): string {
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
    const ext: string = this.extOf(url, item.quality);
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
        // 重启时正在下的那些没法接着下（链接带时效），标成可重试
        if (item.status === 'downloading' || item.status === 'waiting') {
          item.status = 'error';
          item.error = '上次没下完（应用重启过），可以重新下载';
          item.received = 0;
        }
        if (item.status === 'done') {
          // 文件被用户删了 / 目录不可访问就当作没下过
          if (item.uri.length === 0 || !this.exists(item.uri)) {
            item.status = 'error';
            item.error = '文件找不到了（可能被清理过）';
          } else {
            setDownloadedFile(item.key, item.uri);
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
