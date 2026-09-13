import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileShare, picker } from '@kit.CoreFileKit';
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

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadManager';

/** 下载列表 / 进度变化时递增，界面订阅它刷新 */
export const K_DOWNLOAD_VERSION: string = 'download_version';

/** 应用内的下载目录（不需要任何权限，卸载应用才会删） */
const DIR_NAME: string = 'Download';
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
  /** 非致命提示（例如自定义目录写不了、已改存到应用目录） */
  note: string;
  createdAt: number;
}

/** 选下载目录的结果 */
export interface PickDirResult {
  /** 用户取消了选择 */
  cancel: boolean;
  /** 目录短名 */
  label: string;
  /** 现在能不能往这个目录写 */
  usable: boolean;
  /** 诊断细节：哪一步成功/失败（失败时带系统错误码） */
  detail: string;
}

/** 一次下载要写的位置 */
interface WriteTarget {
  /** 最终路径 / uri（记进索引，也用来播放） */
  path: string;
  /** 边下边写的临时文件；空串表示直接写 path（系统保存给的 uri） */
  part: string;
  handle: fs.File;
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
   * 手动目录的授权策略
   *
   * 关键点：OperationMode 是按位分开的 —— READ / WRITE / **CREATE** / DELETE / RENAME。
   * 只申请 READ|WRITE 的话，改已有文件可以，**在目录里新建文件不行**（探针就是在建文件，
   * 所以之前必然失败）。下载要新建文件、失败时还要删掉半截文件，四个位都申请。
   */
  private manualPolicy(uri: string): fileShare.PolicyInfo {
    return {
      uri: uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
        | fileShare.OperationMode.CREATE_MODE | fileShare.OperationMode.DELETE_MODE,
    };
  }

  /** 手动选择的目录当前能不能写（启动时验证一次；失败会让设置页提示重选） */
  private manualDirUsable: boolean = false;
  /** 这个目录的授权是不是「长期」的（false = 只有本次会话有效，重启要重选） */
  private manualDirPersistent: boolean = false;

  /**
   * 启动时把「上次选的目录」的长期授权启回来
   *
   * persistPermission 记住的是授权本身，新进程里要 activatePermission 才能真正生效；
   * 再用探针确认真的可写，写在内存里给设置页和下载用。
   */
  initManualDir(context: common.Context): void {
    const settings = DownloadSettings.getInstance();
    const uri: string = settings.getSaveDirUri();
    if (uri.length === 0) {
      this.manualDirUsable = false;
      return;
    }
    this.context = context;
    const policy: fileShare.PolicyInfo = this.manualPolicy(uri);
    fileShare.activatePermission([policy]).then(() => {
      this.manualDirUsable = this.probeWritable(uri).length === 0;
      this.manualDirPersistent = this.manualDirUsable;
      if (!this.manualDirUsable) {
        hilog.warn(DOMAIN, TAG, 'manual dir not writable after activate: %{public}s', uri);
      }
    }).catch((err: BusinessError) => {
      this.manualDirUsable = false;
      hilog.warn(DOMAIN, TAG, 'activatePermission failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 手动选的目录是否可用（设置页据此提示） */
  isManualDirUsable(): boolean {
    return this.manualDirUsable;
  }

  /** 这个目录的授权是否长期有效（false 表示只有本次会话有效） */
  isManualDirPersistent(): boolean {
    return this.manualDirPersistent;
  }

  /** 切回系统的 Download 目录（选过的目录 uri 留着，方便再切回手动） */
  useAppDir(): void {
    DownloadSettings.getInstance().setSaveMode('app');
    this.bump();
  }

  /**
   * 让用户选一个「长期下载目录」
   *
   * 依次做：picker 选文件夹 -> persistPermission 持久化 -> checkPersistentPermission 确认
   * -> activatePermission 启用 -> 探针建文件。每一步的结果都记进 detail：
   * 真机上没法看 hilog，失败时只能靠提示语定位，所以宁可比一句话详细。
   *
   * 探针失败**不当成致命错误**：目录照样记下（用户能看到选的是哪儿），
   * 但标记为不可写，下载时自动改为弹系统保存对话框（见 openTarget），设置页也会如实说明。
   */
  async pickSaveDir(context: common.Context): Promise<PickDirResult> {
    if (!canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')) {
      return { cancel: false, label: '', usable: false, detail: '这台设备不支持选择文件夹' };
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
    if (uris.length === 0) {
      return { cancel: true, label: '', usable: false, detail: '' };
    }
    const uri: string = uris[0];
    const policy: fileShare.PolicyInfo = this.manualPolicy(uri);
    const steps: string[] = [];

    let persistent: boolean = false;
    try {
      await fileShare.persistPermission([policy]);
      steps.push('授权持久化：成功');
    } catch (err) {
      steps.push(`授权持久化失败（${(err as BusinessError).code} ${(err as BusinessError).message}）`);
      hilog.warn(DOMAIN, TAG, 'persistPermission failed: %{public}s', JSON.stringify(err));
    }
    try {
      const checked: boolean[] = await fileShare.checkPersistentPermission([policy]);
      persistent = checked.length > 0 && checked[0];
      steps.push(`系统确认长期权限：${persistent ? '有' : '没有'}`);
    } catch (err) {
      steps.push(`查长期权限失败（${(err as BusinessError).code}）`);
    }
    try {
      await fileShare.activatePermission([policy]);
      steps.push('启用授权：成功');
    } catch (err) {
      steps.push(`启用授权失败（${(err as BusinessError).code} ${(err as BusinessError).message}）`);
    }

    // 探针只在「直接往目录里写」这条路上有意义；手机上本来就是走系统保存对话框，
    // 所以探针结果只作诊断记录，不当作能否使用的判据。
    const probeError: string = this.probeWritable(uri);
    steps.push(probeError.length === 0 ? '直接写入探针：成功' : `直接写入探针：不支持（${probeError}）`);

    const label: string = this.labelOf(uri);
    this.context = context;
    this.manualDirUsable = true;
    this.manualDirPersistent = persistent;
    DownloadSettings.getInstance().setSaveDir(uri, label);
    this.bump();
    hilog.info(DOMAIN, TAG, 'manual download dir set: %{public}s', uri);
    return { cancel: false, label: label, usable: true, detail: steps.join('；') };
  }

  private labelOf(uri: string): string {
    const cut: number = uri.lastIndexOf('/');
    const raw: string = cut >= 0 ? uri.substring(cut + 1) : uri;
    try {
      const decoded: string = decodeURIComponent(raw);
      return decoded.length > 0 ? decoded : uri;
    } catch (e) {
      return raw;
    }
  }

  /**
   * 往目标目录写一个探针文件再删掉，确认可写
   * @returns 空串表示可写；否则是失败原因（带系统错误码，方便定位）
   */
  private probeWritable(uri: string): string {
    const probe: string = `${uri}/lx_download_probe.tmp`;
    try {
      const handle = fs.openSync(probe, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.closeSync(handle);
      this.unlinkQuietly(probe);
      return '';
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'probe dir failed: %{public}s', JSON.stringify(e));
      return `${err.code} ${err.message}`;
    }
  }

  /**
   * 打开这次下载要写的位置
   *
   * 关键限制（踩过一次）：`file://docs/...` 这类用户目录 uri **不能**用 openSync + CREATE
   * 直接新建文件（报 13900002 No such file or directory），所以往用户目录写只有一条
   * 官方通路 —— 系统保存对话框（DocumentViewPicker.save），由系统创建文件并返回可写 uri。
   *
   *   Download目录 -> save(pickerMode = DOWNLOAD)：不弹界面，系统直接建在
   *                   Download/<应用名>/ 下并返回可写 uri
   *   手动选择     -> save(defaultFilePathUri = 用户选的目录)：对话框已定位到那个目录、
   *                   文件名也填好了，确认一下就写进去
   *
   * 两条都拿不到（设备不支持 / 没有 context）时退回应用内 files/Download。
   * 返回 null 表示用户在对话框里取消了（当作取消，不算失败）。
   */
  private async openTarget(fileName: string): Promise<WriteTarget | null> {
    const settings = DownloadSettings.getInstance();
    const manualDir: string = settings.getSaveDirUri();
    const manual: boolean = settings.getSaveMode() === 'manual' && manualDir.length > 0;
    const context = this.context;
    if (context !== null) {
      try {
        const options = new picker.DocumentSaveOptions();
        options.newFileNames = [fileName];
        if (manual) {
          // 定位到用户选的那个目录：对话框打开时就在那儿，文件名已填好
          options.defaultFilePathUri = manualDir;
        } else {
          // 直接落到系统的 Download/<应用名>/，跳过选择界面
          options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
        }
        const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
        if (uris.length === 0) {
          return null;
        }
        const uri: string = uris[0];
        // 文件是系统建好的，这里只负责打开（不带 CREATE：uri 上不支持创建）
        const handle: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        return { path: uri, part: '', handle: handle };
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'open save target failed: %{public}s', JSON.stringify(e));
        if (manual) {
          // 手动模式失败就如实报错，别偷偷换个地方存
          throw e as Error;
        }
      }
    }
    if (manual) {
      throw new Error('保存对话框不可用，请在「下载设置」里重新选一次目录');
    }
    // Download目录模式拿不到系统目录：退回应用内目录，别让这次下载白跑
    const target: string = this.uniquePath(this.dir, fileName);
    const handle: fs.File | null = this.openPart(target);
    if (handle === null) {
      return null;
    }
    return { path: target, part: `${target}${PART_SUFFIX}`, handle: handle };
  }

  /** 目标目录里同名文件已存在就加 (1)(2)…（uri 场景没有目录列举能力，用存在性判断） */
  private uniqueUriPath(dir: string, fileName: string): string {
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

    // 2) 打开保存位置（Download目录走系统 Download，手动选择弹保存对话框）
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
        this.cleanupFailed(item, part, target);
        return;
      }
      if (code !== 200 || item.received === 0) {
        this.cleanupFailed(item, part, target);
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
        this.cleanupFailed(item, part, target);
        this.fail(item, `写入文件失败：${(e as BusinessError).message}`);
      }
    } catch (e) {
      this.closeQuietly(file);
      this.cleanupFailed(item, part, target);
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
  private cleanupFailed(item: DownloadItem, part: string, target: string): void {
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
