import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxPlayer } from '../player/LxPlayer';

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioCache';

/**
 * 播放缓存（对应洛雪的「播放缓存大小」+ 资源缓存里的播放器缓存部分）
 *
 * 洛雪靠 react-native-track-player 自带的边播边缓存，用一个 maxCacheSize 限制总量。
 * HarmonyOS 的 AVPlayer 没有把流式数据落盘的接口，所以这里做等价的事：**边播边把整首
 * 下到沙箱**，下完下次播放直接读本地文件（不联网、不看源脸色），并用一个上限做 LRU 淘汰。
 *
 * 只在「缓存大小 > 0」时生效；上限设 0 就是关掉。文件都落在
 * files/lx_media_audio/，索引（大小 + 最近使用时间）存在同目录 index.json。
 * 没用 cacheDir：那个目录会被系统回收，文件无声消失的话索引就对不上了。
 *
 * ## 下载方式：分块 + 可续传 + 给播放让路
 *
 * 缓存和播放走的是同一段网络，弱网下两边一起抢的结果就是正在听的这首卡顿 ——
 * 而这恰好是用户最在意的事。所以这里做了三点（见 LxPlayer.canUseBandwidthForCache）：
 *
 *   1. **一次只下一首**，按优先级排队：正在播的那首 > 预取的下一首；
 *   2. **块状下载**（每块 CHUNK_BYTES，用 Range 请求）：每块之间检查一次「现在能不能用带宽」，
 *      播放器在等数据就停下，等缓冲缓过来再接着下；
 *   3. **可续传**：没下完的部分留在同名 `.part` 里，下次接着下（Range 从已下字节数开始）。
 *      服务器不认 Range（返回 200 整份）时也能正常收尾，只是失去暂停能力。
 *
 * 块状而不是一路流式下到底，就是为了能在中途停下来让路：`requestInStream` 一旦开闸
 * 只能整个掐断，掐断就白下；分块之后「暂停」= 不再发下一块，进度都留着。
 */

/** 缓存索引变化时递增，设置页订阅它刷新占用显示 */
export const K_CACHE_VERSION: string = 'audio_cache_version';
/** 「缓存时自动下载」开关（AppStorage 键，设置页的开关订阅它） */
export const K_CACHE_AUTO_DOWNLOAD: string = 'cfg_cache_auto_download';

const DIR_NAME: string = 'lx_media_audio';
const INDEX_FILE: string = 'index.json';
const PART_SUFFIX: string = '.part';
const SAVE_DELAY_MS: number = 2000;
/** 默认上限 512MB（与洛雪一样默认开启边播边缓存） */
const DEFAULT_LIMIT_MB: number = 512;
const AUDIO_EXTS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma'];
/**
 * 每块的字节数
 *
 * 取 64KB：128kbps 的歌大约 4 秒音频，进度条上那条灰段能一格一格往前长
 * （一首 3~4MB 的歌约 50 格），而不是「停一下突然跳满」。
 * 再小就只剩请求开销了（同一条连接上几十次请求，得不偿失）。
 */
const CHUNK_BYTES: number = 64 * 1024;
/** 一块都没下成（网络断了 / 超时）之后隔多久再试 */
const RETRY_DELAY_MS: number = 5000;
/** 当前没轮到（播放器在抢带宽）时隔多久再看一次 */
const WAIT_DELAY_MS: number = 4000;
/** 单块请求的超时：够慢网下 256KB 用 */
const CHUNK_CONNECT_TIMEOUT_MS: number = 15000;
const CHUNK_READ_TIMEOUT_MS: number = 30000;

interface AudioCacheEntry {
  size: number;
  usedAt: number;
}

interface AudioCacheIndex {
  limitMb: number;
  /** 「缓存时自动下载」：老索引文件里没有这个键，缺省按关处理 */
  autoDownload?: boolean;
  entries: Record<string, AudioCacheEntry>;
}

interface DownloadTask {
  key: string;
  quality: string;
  url: string;
  /**
   * 附加请求头（WebDAV 的 `Authorization` 之类）
   *
   * 只有需要认证的源才用得上：AVPlayer 那边能靠 `setMediaSource` 带头，
   * 而缓存是我们自己发 HTTP，头要自己带上，否则下回来的是 401 的页面。
   */
  headers: Record<string, string>;
  /** 上次尝试开始的时间：失败后要隔一会儿再试，别死循环打接口 */
  attemptedAt: number;
}

/** 一首歌的下载进度（字节）：给进度条上那条「已缓存到这儿」用 */
interface DownloadProgress {
  bytes: number;
  /** 文件总大小，从 Content-Range / Content-Length 拿；拿不到就是 0（进度按未知处理） */
  total: number;
}

export class AudioCache {
  private static instance: AudioCache | null = null;

  static getInstance(): AudioCache {
    if (AudioCache.instance === null) {
      AudioCache.instance = new AudioCache();
    }
    return AudioCache.instance;
  }

  private dir: string = '';
  private ready: boolean = false;
  private limitMb: number = DEFAULT_LIMIT_MB;
  /**
   * 「缓存时自动下载」
   *
   * 开着的时候，边听边存这件事改由下载器做（文件进下载文件夹、出现在「我的 - 下载管理」），
   * 于是这里的三件事跟着变：
   *   1. 缓存的上限不再生效（见 enforceLimit / isEnabled）—— 那份占用从此由用户自己在
   *      下载管理里管，再设一个上限只会让人以为文件被删了；
   *   2. 上限设成 0 也不清空缓存（否则「开着自动下载」和「上限为 0」一起用会把沙箱清空）；
   *   3. 单首不再有「比上限大就不下」的约束。
   * 缓存本身没被废掉：下载器不收的（WebDAV 云端歌、没有 musicInfo 的条目）照旧走缓存。
   */
  private autoDownload: boolean = false;
  private entries: Record<string, AudioCacheEntry> = {};

  /** 正在下的任务（同一时刻只有一个） */
  private active: DownloadTask | null = null;
  /** 排队：正在播的那首（优先）与预取的下一首 */
  private pendingPlaying: DownloadTask | null = null;
  private pendingNext: DownloadTask | null = null;
  /** 排队/续传的唤醒定时器（单次，只在有活儿时挂） */
  private pumpTimer: number = 0;
  /**
   * 半截文件（`.part`）是哪个地址下的
   *
   * 续传只在「同一首歌 + 同一档音质 + 同一地址」下成立：同一个文件名可能来自另一个
   * 地址（音源刷新后换了链接），把两段拼起来是坏文件，所以换地址就从头下。
   * 只记在内存里：进程重启后残留的 .part 一律当废料删掉（见 reconcile）。
   */
  private partUrls: Record<string, string> = {};
  /**
   * 正在下的那些歌下到哪儿了（键是文件名前缀 `<key>_<音质>`）
   *
   * 只记本次会话、只记没下完的：下完了就进索引（那时「已在本地」= 100%），
   * 所以这个表只服务于「正在下」的那一两首的进度显示。
   */
  private progress: Record<string, DownloadProgress> = {};
  /** 正在播的本地文件：淘汰时避开它，免得把正在读的文件删了 */
  private playingPath: string = '';
  private totalBytes: number = 0;

  private indexDirty: boolean = false;
  private indexTimer: number = 0;

  init(context: common.Context): void {
    this.dir = `${context.filesDir}/${DIR_NAME}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create audio cache dir failed: %{public}s', JSON.stringify(e));
      this.ready = false;
      return;
    }
    this.loadIndex();
    this.reconcile();
    AppStorage.setOrCreate(K_CACHE_AUTO_DOWNLOAD, this.autoDownload);
    hilog.info(DOMAIN, TAG, 'audio cache ready, %{public}d files, limit %{public}dMB, autoDownload %{public}s',
      Object.keys(this.entries).length, this.limitMb, this.autoDownload ? 'on' : 'off');
  }

  isReady(): boolean {
    return this.ready;
  }

  isEnabled(): boolean {
    // 开着「缓存时自动下载」就算缓存开着：上限为 0 也不影响（上限这时本来就不生效）
    return this.ready && (this.limitMb > 0 || this.autoDownload);
  }

  /** 「缓存时自动下载」开着没有？ */
  isAutoDownload(): boolean {
    return this.autoDownload;
  }

  /**
   * 开 / 关「缓存时自动下载」（弹窗确认之后才调这里，代价见字段上的说明）
   *
   * 关掉时按现有上限先淘汰一轮：开着的时候没淘汰过，关掉就该立刻回到有上限的状态，
   * 否则那堆文件会一直留在沙箱里没人管。
   */
  setAutoDownload(value: boolean): void {
    if (value === this.autoDownload) {
      return;
    }
    this.autoDownload = value;
    AppStorage.setOrCreate(K_CACHE_AUTO_DOWNLOAD, value);
    this.scheduleSaveIndex();
    this.enforceLimit();
    this.pump();
    this.bumpVersion();
    hilog.info(DOMAIN, TAG, 'auto download %{public}s', value ? 'on' : 'off');
  }

  getLimitMb(): number {
    return this.limitMb;
  }

  setLimitMb(mb: number): void {
    const next: number = mb < 0 || Number.isNaN(mb) ? 0 : Math.floor(mb);
    if (next === this.limitMb) {
      return;
    }
    this.limitMb = next;
    this.scheduleSaveIndex();
    // 调小上限立刻按新上限淘汰；设 0 就是把缓存清空并停用
    this.enforceLimit();
    // 停用时把排队中的任务丢掉（pump 里会判断）
    this.pump();
    this.bumpVersion();
  }

  // ------------------------------------------------------------ 查询 / 播放入口

  /** 命中返回本地文件路径，否则空串 */
  localPath(key: string, quality: string): string {
    if (!this.isEnabled() || key.length === 0) {
      return '';
    }
    const name: string = this.findName(key, quality);
    if (name.length === 0) {
      return '';
    }
    const entry = this.entries[name];
    const path: string = `${this.dir}/${name}`;
    if (entry === undefined || !fs.accessSync(path)) {
      // 文件被外部删了（清理工具 / 手滑）：把索引里这条也去掉
      this.removeEntry(name);
      return '';
    }
    // 用一次算一次「最近使用」，LRU 才不会把常听的歌淘汰掉
    entry.usedAt = Date.now();
    this.scheduleSaveIndex();
    return path;
  }

  /** 播放器当前读的是哪个本地文件（淘汰时避开） */
  setPlayingPath(path: string): void {
    this.playingPath = path;
  }

  /**
   * 丢掉某个本地文件对应的缓存（文件本身 + 索引条目）
   *
   * 缓存文件理论上都是「下完才改名」的完整文件，但万一遇到截断 / 内容不对，
   * 播放会一直失败。调用方（PlaySession）在本地文件播不出来时调它删掉，
   * 下一次播放就会重新联网取，不会永久卡在一首坏缓存上。
   */
  dropPath(path: string): void {
    if (path.length === 0 || !this.ready) {
      return;
    }
    const prefix: string = `${this.dir}/`;
    if (!path.startsWith(prefix)) {
      return;
    }
    const name: string = path.substring(prefix.length);
    unlinkQuietly(path);
    this.removeEntry(name);
    if (this.playingPath === path) {
      this.playingPath = '';
    }
    this.scheduleSaveIndex();
    this.bumpVersion();
  }

  /**
   * 丢掉某首歌的缓存（不分音质）
   *
   * 「缓存时自动下载」把这首歌交给下载器之后调用，两个理由：
   *   1. 同一首歌别占两处地方 —— 文件马上要落到下载文件夹，沙箱里再留一份是白占空间，
   *      而开着这个开关时缓存本来就不淘汰（没有上限），留着就永远留着；
   *   2. 用户把下载删掉时「本地这份就没了」这条承诺才成立：缓存里留一份的话照样能离线放。
   *
   * 正在播的那一份不删（文件一删播放就断），等切歌后再收；正在下的那个任务一并作废 ——
   * 它写的正是马上要删掉的 `.part`，接着下只会拼出一个坏文件。
   */
  dropKey(key: string): void {
    if (!this.ready || key.length === 0) {
      return;
    }
    if (this.active !== null && this.active.key === key) {
      this.active = null;
    }
    if (this.pendingPlaying !== null && this.pendingPlaying.key === key) {
      this.pendingPlaying = null;
    }
    if (this.pendingNext !== null && this.pendingNext.key === key) {
      this.pendingNext = null;
    }
    const prefix: string = `${key}_`;
    let removed: number = 0;
    for (const name of Object.keys(this.entries)) {
      if (!name.startsWith(prefix)) {
        continue;
      }
      const path: string = `${this.dir}/${name}`;
      if (path === this.playingPath) {
        continue;
      }
      unlinkQuietly(path);
      this.removeEntry(name);
      removed++;
    }
    // 没下完的半截也扫掉：没人会再接着下它，留着只是占地方
    try {
      for (const name of fs.listFileSync(this.dir)) {
        if (name.startsWith(prefix) && name.endsWith(PART_SUFFIX)) {
          unlinkQuietly(`${this.dir}/${name}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'scan cache dir failed: %{public}s', JSON.stringify(e));
    }
    this.dropProgressOf(prefix);
    if (removed > 0) {
      hilog.info(DOMAIN, TAG, 'dropped %{public}d cache file(s) of %{public}s', removed, key);
      this.bumpVersion();
    }
  }

  /**
   * 边播边缓存：把这首歌下到本地，下完下次就直接读本地
   *
   * 优先级最高的一类任务（正在听的就是它），会顶掉排在前面的同类任务。
   * 注意「缓存时自动下载」开着时这条链路不走这里 —— 播放层会把它交给下载器
   * （文件进下载文件夹），见 PlaySession.autoDownload。
   */
  cacheSong(key: string, quality: string, url: string, headers?: Record<string, string>): void {
    this.enqueue(key, quality, url, false, headers);
  }

  /**
   * 预取下一首
   *
   * 切歌卡顿多半来自「切的那一刻才开始取数据」：地址要解析、首屏要缓冲。
   * 上一首还在播的时候把下一首先下下来，切过去就是直接读本地文件 —— 不联网、
   * 不缓冲，网络再差也是瞬间出声。同类的旧任务直接顶掉（只预取一首）。
   *
   * 注意它同样受「播放优先」约束：正在听的这首缓冲不够时，预取会一直排队等着。
   */
  prefetchSong(key: string, quality: string, url: string, headers?: Record<string, string>): void {
    this.enqueue(key, quality, url, true, headers);
  }

  private enqueue(key: string, quality: string, url: string, prefetch: boolean,
    headers?: Record<string, string>): void {
    if (!this.isEnabled() || key.length === 0 || url.length === 0) {
      return;
    }
    const name: string = this.fileName(key, quality, url);
    if (this.entries[name] !== undefined) {
      return;
    }
    if (this.active !== null && this.active.key === key && this.active.quality === quality) {
      return;
    }
    if (this.pendingPlaying !== null && this.pendingPlaying.key === key
      && this.pendingPlaying.quality === quality) {
      return;
    }
    if (this.pendingNext !== null && this.pendingNext.key === key
      && this.pendingNext.quality === quality) {
      return;
    }
    const task: DownloadTask = {
      key: key,
      quality: quality,
      url: url,
      headers: headers !== undefined ? headers : {},
      attemptedAt: 0,
    };
    if (prefetch) {
      this.pendingNext = task;
    } else {
      this.pendingPlaying = task;
    }
    this.pump();
  }

  /**
   * 这首歌在本地已经拿到多少（0~1）
   *
   * 三种情况：
   *   - 已经下完（进了索引）→ 1；
   *   - 正在下 → 已下字节数 / 文件总大小；
   *   - 没下过 / 没开缓存 / 总大小还没问到 → 0（调用方按「没有进度信息」处理）。
   *
   * 用途只有一个：播放页进度条上那条灰色的「已缓存到这儿」。
   * 为什么不让播放器自己报：实测 AVPlayer 的 bufferingUpdate 只在上手阶段来一批
   * （见 docs/PLAYBACK_BUFFER.md），之后不再上报，单靠它那条灰段涨不到结尾。
   */
  cachedFraction(key: string, quality: string): number {
    if (!this.isEnabled() || key.length === 0) {
      return 0;
    }
    if (this.findName(key, quality).length > 0) {
      return 1;
    }
    const record = this.progress[this.baseName(key, quality)];
    if (record === undefined || record.total <= 0) {
      return 0;
    }
    const fraction: number = record.bytes / record.total;
    if (fraction <= 0) {
      return 0;
    }
    return fraction > 1 ? 1 : fraction;
  }

  /**
   * 播放缓过来了（或在做别的不占带宽的事）：排队等着的缓存可以试着开工了
   *
   * 由播放侧在「缓冲结束」这类时刻叫一下，省得靠定时器反复轮询。
   */
  resumeWaiting(): void {
    this.pump();
  }

  sizeBytes(): number {
    return this.totalBytes;
  }

  fileCount(): number {
    return Object.keys(this.entries).length;
  }

  clear(): void {
    if (!this.ready) {
      return;
    }
    // 正在下 / 排队中的都作废：文件马上要被删掉，接着下没有意义
    this.active = null;
    this.pendingPlaying = null;
    this.pendingNext = null;
    const names: string[] = Object.keys(this.entries);
    for (const name of names) {
      unlinkQuietly(`${this.dir}/${name}`);
    }
    // 没进索引的残留（下载中断的 .part）也一起扫掉
    try {
      for (const name of fs.listFileSync(this.dir)) {
        if (name.endsWith(PART_SUFFIX)) {
          unlinkQuietly(`${this.dir}/${name}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'scan cache dir failed: %{public}s', JSON.stringify(e));
    }
    this.partUrls = {};
    this.progress = {};
    this.entries = {};
    this.totalBytes = 0;
    this.scheduleSaveIndex();
    this.bumpVersion();
  }

  // ------------------------------------------------------------ 下载调度

  /**
   * 调度一次：有活儿就开一个任务，没轮到就挂个定时器再看
   *
   * 优先级：正在播的那首 > 预取的下一首。让路（播放器在抢带宽）或刚失败过就先等着 ——
   * 等的时候不占网络，只是隔几秒回来看一眼（缓存是要紧但不急的事）。
   */
  private pump(): void {
    if (!this.ready || !this.isEnabled()) {
      this.pendingPlaying = null;
      this.pendingNext = null;
      return;
    }
    if (this.active !== null) {
      return;
    }
    const task: DownloadTask | null = this.takePending();
    if (task === null) {
      return;
    }
    const now: number = Date.now();
    const cooled: boolean = now - task.attemptedAt >= RETRY_DELAY_MS;
    if (!cooled || !LxPlayer.getInstance().canUseBandwidthForCache()) {
      this.putBack(task);
      this.schedulePump();
      return;
    }
    task.attemptedAt = now;
    this.active = task;
    void this.runTask(task, this.fileName(task.key, task.quality, task.url));
  }

  /** 取优先级最高的待办 */
  private takePending(): DownloadTask | null {
    const playing: DownloadTask | null = this.pendingPlaying;
    if (playing !== null) {
      this.pendingPlaying = null;
      return playing;
    }
    const next: DownloadTask | null = this.pendingNext;
    if (next !== null) {
      this.pendingNext = null;
      return next;
    }
    return null;
  }

  /** 这块地儿还没轮到它，放回原来的优先级槽里（取任务时至少腾空了一个槽，放得下） */
  private putBack(task: DownloadTask): void {
    if (this.pendingPlaying === null) {
      this.pendingPlaying = task;
      return;
    }
    this.pendingNext = task;
  }

  private schedulePump(): void {
    if (this.pumpTimer !== 0) {
      return;
    }
    this.pumpTimer = setTimeout(() => {
      this.pumpTimer = 0;
      this.pump();
    }, WAIT_DELAY_MS);
  }

  /**
   * 下一首歌（按块下，可续传）
   *
   * 每块之间做三件事：看还轮不轮得到自己（播放优先）、看有没有下到头、看有没有超上限。
   * 没下完就退出时 `.part` 留着，字节数就是下次的续传起点。
   */
  private async runTask(task: DownloadTask, name: string): Promise<void> {
    const target: string = `${this.dir}/${name}`;
    const part: string = `${target}${PART_SUFFIX}`;
    // 进度表的键：文件名去掉后缀（同一首歌换地址也共用一条进度）
    const progressKey: string = this.baseName(task.key, task.quality);
    // 单首上限就按总上限来：比上限还大的文件缓存下来也会立刻被淘汰。
    // 开着「缓存时自动下载」时没有上限（上限不生效），单首也就不设限。
    const singleLimit: number = this.autoDownload
      ? Number.MAX_SAFE_INTEGER
      : this.limitMb * 1024 * 1024;
    const request = http.createHttp();
    let offset: number = fileSizeOf(part);
    let started: boolean = offset === 0;
    const known = this.progress[progressKey];
    // 只有「同一个地址下的半截」才能接着下：同名文件可能来自另一个地址
    // （音源刷新后同一首歌换了链接），拼在一起就是坏文件 —— 而坏文件不一定会立刻报错，
    // 可能只是听感不对，所以这里宁可从头下。
    if (offset > 0 && this.partUrls[name] !== task.url) {
      hilog.info(DOMAIN, TAG, 'drop stale part of %{public}s (%{public}d bytes)', name, offset);
      unlinkQuietly(part);
      offset = 0;
      started = true;
    }
    this.partUrls[name] = task.url;
    this.progress[progressKey] = {
      bytes: offset,
      total: known === undefined ? 0 : known.total,
    };
    let handle: fs.File | null = null;
    try {
      for (;;) {
        if (this.active !== task) {
          // 被顶掉了（切歌/关闭缓存）：已下的部分留着，同名任务再回来时接着下
          hilog.info(DOMAIN, TAG, 'cache task replaced at %{public}d bytes', offset);
          return;
        }
        if (offset > 0 && !LxPlayer.getInstance().canUseBandwidthForCache()) {
          // 让路：这块不发出去，剩下的等播放缓过来再说
          this.requeue(task);
          hilog.info(DOMAIN, TAG, 'cache yields to playback at %{public}d bytes', offset);
          return;
        }
        if (handle !== null) {
          closeQuietly(handle);
          handle = null;
        }
        const file: fs.File = fs.openSync(part, started
          ? fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
          : fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
        handle = file;
        // 每块都带 Range（含第一块）：不带的话服务器会把**整个文件**一次性返回，
        // 进度就只有 0% 和 100% 两个状态，进度条上那条灰段会「停一下然后跳满」。
        // 区间一定写成 `bytes=a-b` 的闭区间形式（开区间的那种写法部分服务器处理不稳妥）。
        const headers: Record<string, string> = {
          'Range': `bytes=${offset}-${offset + CHUNK_BYTES - 1}`,
        };
        // 需要认证的源（WebDAV）在这里补上自己的头：不带就是 401，下回来一页 HTML
        for (const name of Object.keys(task.headers)) {
          headers[name] = task.headers[name];
        }
        const response: http.HttpResponse = await request.request(task.url, {
          method: http.RequestMethod.GET,
          header: headers,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false,
          connectTimeout: CHUNK_CONNECT_TIMEOUT_MS,
          readTimeout: CHUNK_READ_TIMEOUT_MS,
        });
        const code: number = response.responseCode;
        // 文件总大小（进度条要用）：Content-Range 的 `/total`，或 Content-Length + 已下偏移
        const total: number = totalBytesOf(response, offset);
        const known0 = this.progress[progressKey];
        const had: number = known0 === undefined ? 0 : known0.total;
        if (total > 0 && (had === 0 || offset === 0)) {
          hilog.info(DOMAIN, TAG, 'cache file total: %{public}d bytes (%{public}s)',
            total, name);
        }
        if (total > 0) {
          this.progress[progressKey] = { bytes: offset, total: total };
        } else if (offset === 0) {
          hilog.warn(DOMAIN, TAG, 'cache file total unknown, code=%{public}d headers=%{public}s',
            code, JSON.stringify(response.header));
        }
        if (code === 416 && offset > 0) {
          // 要的区间已经在文件尾之外：说明整个文件都拿到了
          this.commit(name, target, part, offset);
          return;
        }
        if (code === 200) {
          // 服务器不认 Range，这一份就是整个文件：从头写一遍收尾
          const data: ArrayBuffer = response.result as ArrayBuffer;
          if (data === undefined || data.byteLength === 0) {
            throw new Error('服务器返回了空内容');
          }
          fs.truncateSync(part, 0);
          fs.writeSync(file.fd, data);
          this.commit(name, target, part, data.byteLength);
          return;
        }
        if (code !== 206) {
          throw new Error(`HTTP ${code}`);
        }
        const chunk: ArrayBuffer = response.result as ArrayBuffer;
        if (chunk === undefined || chunk.byteLength === 0) {
          throw new Error('这一块没有拿到数据');
        }
        fs.writeSync(file.fd, chunk);
        offset += chunk.byteLength;
        started = false;
        const record = this.progress[progressKey];
        if (record !== undefined) {
          record.bytes = offset;
        }
        if (offset > singleLimit) {
          hilog.warn(DOMAIN, TAG, 'cache file exceeds limit, abort');
          unlinkQuietly(part);
          return;
        }
        if (chunk.byteLength < CHUNK_BYTES) {
          // 不足一块 = 已经是文件尾
          this.commit(name, target, part, offset);
          return;
        }
      }
    } catch (e) {
      // 失败：.part 留着（字节数就是续传起点），等一会儿再接着试同一首。
      // attemptedAt 刷新成「现在」，pump 里那条冷却判断据此生效（网络断了别死循环重试）。
      hilog.warn(DOMAIN, TAG, 'cache chunk failed at %{public}d bytes: %{public}s',
        offset, (e as Error).message);
      task.attemptedAt = Date.now();
      this.requeue(task);
    } finally {
      closeQuietly(handle);
      request.destroy();
      if (this.active === task) {
        this.active = null;
      }
      this.pump();
    }
  }

  /** 任务没做完：放回队列（保持它的优先级），等下一轮调度 */
  private requeue(task: DownloadTask): void {
    this.putBack(task);
    this.schedulePump();
  }

  /** 下完了：.part 改名落索引（改名才算数，.part 永远不会被当成可播放的缓存） */
  private commit(name: string, target: string, part: string, size: number): void {
    unlinkQuietly(target);
    try {
      fs.renameSync(part, target);
      this.entries[name] = { size: size, usedAt: Date.now() };
      this.totalBytes += size;
      this.enforceLimit();
      this.scheduleSaveIndex();
      this.bumpVersion();
      hilog.info(DOMAIN, TAG, 'cached %{public}s, %{public}d bytes', name, size);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'commit cache file failed: %{public}s', JSON.stringify(e));
      unlinkQuietly(part);
    }
    // 进索引了，「在本地拿到多少」由 cachedFraction 直接给 1，这条进度记录不用留
    this.dropProgressOf(name);
  }

  /** 去掉一条下载进度记录（键是文件名前缀） */
  private dropProgressOf(name: string): void {
    const next: Record<string, DownloadProgress> = {};
    let changed: boolean = false;
    for (const key of Object.keys(this.progress)) {
      if (name.startsWith(`${key}.`)) {
        changed = true;
        continue;
      }
      next[key] = this.progress[key];
    }
    if (changed) {
      this.progress = next;
    }
  }

  // ------------------------------------------------------------ 淘汰 / 索引

  private enforceLimit(): void {
    if (!this.ready) {
      return;
    }
    if (this.autoDownload) {
      // 「缓存时自动下载」开着就没有上限这回事：不淘汰，也不因为上限是 0 而清空
      return;
    }
    if (this.limitMb <= 0) {
      // 关掉缓存：清空
      const names: string[] = Object.keys(this.entries);
      for (const name of names) {
        unlinkQuietly(`${this.dir}/${name}`);
      }
      this.entries = {};
      this.totalBytes = 0;
      this.scheduleSaveIndex();
      return;
    }
    const limit: number = this.limitMb * 1024 * 1024;
    if (this.totalBytes <= limit) {
      return;
    }
    // 最近最少使用的排在前面，从它开始删
    const names: string[] = Object.keys(this.entries);
    names.sort((a: string, b: string) => usedAtOf(this.entries, a) - usedAtOf(this.entries, b));
    for (const name of names) {
      if (this.totalBytes <= limit) {
        break;
      }
      const path: string = `${this.dir}/${name}`;
      if (path === this.playingPath) {
        continue;
      }
      unlinkQuietly(path);
      this.removeEntry(name);
    }
    this.scheduleSaveIndex();
  }

  private removeEntry(name: string): void {
    const entry = this.entries[name];
    if (entry === undefined) {
      return;
    }
    this.totalBytes -= entry.size;
    if (this.totalBytes < 0) {
      this.totalBytes = 0;
    }
    this.dropNames([name]);
    this.scheduleSaveIndex();
  }

  /** ArkTS 不支持 delete 运算符，去掉若干条目只能重建一遍（条目数量级很小） */
  private dropNames(names: string[]): void {
    const next: Record<string, AudioCacheEntry> = {};
    for (const key of Object.keys(this.entries)) {
      if (!names.includes(key)) {
        next[key] = this.entries[key];
      }
    }
    this.entries = next;
  }

  private loadIndex(): void {
    const text: string = readText(`${this.dir}/${INDEX_FILE}`);
    if (text.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(text) as AudioCacheIndex;
      if (parsed.limitMb !== undefined && parsed.limitMb !== null && !Number.isNaN(parsed.limitMb)) {
        this.limitMb = parsed.limitMb;
      }
      this.autoDownload = parsed.autoDownload === true;
      const entries = parsed.entries;
      if (entries !== undefined && entries !== null) {
        for (const name of Object.keys(entries)) {
          const entry = entries[name];
          if (entry !== undefined && entry !== null) {
            this.entries[name] = {
              size: entry.size !== undefined ? entry.size : 0,
              usedAt: entry.usedAt !== undefined ? entry.usedAt : 0,
            };
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse index failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 与磁盘对账：补上索引里没有的文件，去掉文件已不在的条目，清掉残留的 .part */
  private reconcile(): void {
    let total: number = 0;
    const seen: Set<string> = new Set<string>();
    try {
      for (const name of fs.listFileSync(this.dir)) {
        if (name === INDEX_FILE) {
          continue;
        }
        const path: string = `${this.dir}/${name}`;
        if (name.endsWith(PART_SUFFIX)) {
          unlinkQuietly(path);
          continue;
        }
        let size: number = 0;
        try {
          size = fs.statSync(path).size;
        } catch (e) {
          continue;
        }
        const entry = this.entries[name];
        if (entry === undefined) {
          this.entries[name] = { size: size, usedAt: Date.now() };
        } else {
          entry.size = size;
        }
        total += size;
        seen.add(name);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'reconcile failed: %{public}s', JSON.stringify(e));
    }
    const missing: string[] = [];
    for (const name of Object.keys(this.entries)) {
      if (!seen.has(name)) {
        missing.push(name);
      }
    }
    if (missing.length > 0) {
      this.dropNames(missing);
    }
    this.totalBytes = total;
    this.enforceLimit();
    this.scheduleSaveIndex();
  }

  private scheduleSaveIndex(): void {
    this.indexDirty = true;
    if (this.indexTimer !== 0) {
      return;
    }
    this.indexTimer = setTimeout(() => {
      this.indexTimer = 0;
      this.flushIndex();
    }, SAVE_DELAY_MS);
  }

  flushIndex(): void {
    if (!this.ready || !this.indexDirty) {
      return;
    }
    this.indexDirty = false;
    const index: AudioCacheIndex = {
      limitMb: this.limitMb,
      autoDownload: this.autoDownload,
      entries: this.entries,
    };
    try {
      writeText(`${this.dir}/${INDEX_FILE}`, JSON.stringify(index));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save index failed: %{public}s', JSON.stringify(e));
    }
  }

  private bumpVersion(): void {
    try {
      const version: number = AppStorage.get<number>(K_CACHE_VERSION) ?? 0;
      AppStorage.setOrCreate(K_CACHE_VERSION, version + 1);
    } catch (e) {
      // 设置页没打开时 AppStorage 也可能没这个键，忽略
    }
  }

  // ------------------------------------------------------------ 命名

  /** 文件名：`<key>_<音质>.<后缀>`（后缀从地址取，取不到按 mp3 记） */
  private fileName(key: string, quality: string, url: string): string {
    return `${this.baseName(key, quality)}.${extensionOfUrl(url)}`;
  }

  /** 按 key + 音质找已有的缓存文件（后缀是下载时才定的，所以用前缀匹配） */
  private findName(key: string, quality: string): string {
    const prefix: string = `${this.baseName(key, quality)}.`;
    for (const name of Object.keys(this.entries)) {
      if (name.startsWith(prefix)) {
        return name;
      }
    }
    return '';
  }

  private baseName(key: string, quality: string): string {
    return `${safeKey(key)}_${safeKey(quality)}`;
  }
}

// ------------------------------------------------------------------ 工具

function usedAtOf(entries: Record<string, AudioCacheEntry>, name: string): number {
  const entry = entries[name];
  return entry !== undefined ? entry.usedAt : 0;
}

/** 从播放地址里取音频后缀，取不到就用 mp3 兜底（fdSrc 解码靠内容嗅探，后缀只影响可读性） */
function extensionOfUrl(url: string): string {
  const clean: string = url.split('?')[0];
  const at: number = clean.lastIndexOf('.');
  if (at < 0) {
    return 'mp3';
  }
  const ext: string = clean.substring(at + 1).toLowerCase();
  return AUDIO_EXTS.includes(ext) ? ext : 'mp3';
}

function safeKey(key: string): string {
  let out: string = '';
  const chars: string = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_';
  for (let i = 0; i < key.length; i++) {
    const c: string = key.charAt(i);
    out += chars.includes(c) ? c : '_';
  }
  return out.length > 0 ? out : 'unknown';
}

function unlinkQuietly(path: string): void {
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (e) {
    // 删不掉就算了，下次对账还会再试
  }
}

/** 文件有多大（不存在算 0）：半截文件的大小就是续传起点 */
function fileSizeOf(path: string): number {
  try {
    if (!fs.accessSync(path)) {
      return 0;
    }
    return fs.statSync(path).size;
  } catch (e) {
    return 0;
  }
}

/**
 * 取一个响应头
 *
 * 名字大小写不定（`Content-Range` / `content-range` 都见过），所以按小写比对；
 * 值是字符串或字符串数组，两种都认。
 */
function headerValue(header: Object | undefined, name: string): string {
  if (header === undefined || header === null) {
    return '';
  }
  const record = header as Record<string, Object>;
  const wanted: string = name.toLowerCase();
  for (const key of Object.keys(record)) {
    if (key.toLowerCase() !== wanted) {
      continue;
    }
    const raw: Object | undefined = record[key];
    if (typeof raw === 'string') {
      return raw as string;
    }
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      if (list.length > 0 && typeof list[0] === 'string') {
        return list[0] as string;
      }
    }
    return '';
  }
  return '';
}

/**
 * 这个文件总共有多少字节
 *
 * 206 的 `Content-Range: bytes 0-262143/10485760` 里斜杠后面就是总大小；
 * 服务器不认 Range（200）时用 `Content-Length` 加上本次的起点。
 * 都拿不到就返回 0：进度条那边当作「还不知道」处理，不去猜。
 */
function totalBytesOf(response: http.HttpResponse, offset: number): number {
  const range: string = headerValue(response.header, 'content-range');
  const slash: number = range.lastIndexOf('/');
  if (slash >= 0) {
    const total: number = Number.parseInt(range.substring(slash + 1), 10);
    if (!Number.isNaN(total) && total > 0) {
      return total;
    }
  }
  const length: number = Number.parseInt(headerValue(response.header, 'content-length'), 10);
  if (!Number.isNaN(length) && length > 0) {
    return offset + length;
  }
  return 0;
}

function closeQuietly(file: fs.File | null): void {  if (file === null) {
    return;
  }
  try {
    fs.closeSync(file);
  } catch (e) {
    // 忽略
  }
}

function readText(path: string): string {
  try {
    if (!fs.accessSync(path)) {
      return '';
    }
    return fs.readTextSync(path);
  } catch (e) {
    return '';
  }
}

function writeText(path: string, text: string): void {
  const handle = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(handle.fd, text);
  } finally {
    fs.closeSync(handle);
  }
}
