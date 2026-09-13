import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioCache';

/**
 * 播放缓存（对应洛雪的「播放缓存大小」+ 资源缓存里的播放器缓存部分）
 *
 * 洛雪靠 react-native-track-player 自带的边播边缓存，用一个 maxCacheSize 限制总量。
 * HarmonyOS 的 AVPlayer 没有流式缓存，所以这里做等价的事：**边播边把整首下到沙箱**，
 * 下完下次播放直接读本地文件（不联网、不看源脸色），并用一个上限做 LRU 淘汰。
 *
 * 只在「缓存大小 > 0」时生效；上限设 0 就是关掉。文件都落在
 * files/lx_media_audio/，索引（大小 + 最近使用时间）存在同目录 index.json。
 * 没用 cacheDir：那个目录会被系统回收，文件无声消失的话索引就对不上了。
 */

/** 缓存索引变化时递增，设置页订阅它刷新占用显示 */
export const K_CACHE_VERSION: string = 'audio_cache_version';

const DIR_NAME: string = 'lx_media_audio';
const INDEX_FILE: string = 'index.json';
const PART_SUFFIX: string = '.part';
const SAVE_DELAY_MS: number = 2000;
/** 默认上限 512MB（与洛雪一样默认开启边播边缓存） */
const DEFAULT_LIMIT_MB: number = 512;
const AUDIO_EXTS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'ape', 'wma'];

interface AudioCacheEntry {
  size: number;
  usedAt: number;
}

interface AudioCacheIndex {
  limitMb: number;
  entries: Record<string, AudioCacheEntry>;
}

interface DownloadTask {
  key: string;
  quality: string;
  url: string;
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
  private entries: Record<string, AudioCacheEntry> = {};

  /** 正在下载的 key（同一首不重复下） */
  private activeKey: string = '';
  /** 等着的下一首：只留最后一首，切歌时旧任务直接丢掉 */
  private queued: DownloadTask | null = null;
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
    hilog.info(DOMAIN, TAG, 'audio cache ready, %{public}d files, limit %{public}dMB',
      Object.keys(this.entries).length, this.limitMb);
  }

  isReady(): boolean {
    return this.ready;
  }

  isEnabled(): boolean {
    return this.ready && this.limitMb > 0;
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

  /** 边播边缓存：把这首歌下到本地，下完下次就直接读本地 */
  cacheSong(key: string, quality: string, url: string): void {
    if (!this.isEnabled() || key.length === 0 || url.length === 0) {
      return;
    }
    const name: string = this.fileName(key, quality, url);
    if (this.entries[name] !== undefined || this.activeKey === name) {
      return;
    }
    if (this.activeKey.length > 0) {
      // 上一次还没下完：换成最新的这首（旧的那首下次播到再下）
      this.queued = { key: key, quality: quality, url: url };
      return;
    }
    this.startDownload(name, url);
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
    this.entries = {};
    this.totalBytes = 0;
    this.scheduleSaveIndex();
    this.bumpVersion();
  }

  // ------------------------------------------------------------ 下载

  private startDownload(name: string, url: string): void {
    const target: string = `${this.dir}/${name}`;
    const part: string = `${target}${PART_SUFFIX}`;
    unlinkQuietly(part);
    this.activeKey = name;

    let handle: fs.File | null = null;
    try {
      handle = fs.openSync(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open cache file failed: %{public}s', JSON.stringify(e));
      this.activeKey = '';
      this.pumpQueue();
      return;
    }

    const file = handle;
    const request = http.createHttp();
    let received: number = 0;
    let tooBig: boolean = false;
    // 单首上限就按总上限来：比上限还大的文件缓存下来也会立刻被淘汰
    const singleLimit: number = this.limitMb * 1024 * 1024;

    request.on('dataReceive', (data: ArrayBuffer) => {
      if (tooBig) {
        return;
      }
      received += data.byteLength;
      if (received > singleLimit) {
        tooBig = true;
        hilog.warn(DOMAIN, TAG, 'cache file exceeds limit, abort');
        return;
      }
      try {
        fs.writeSync(file.fd, data);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'write cache chunk failed: %{public}s', JSON.stringify(e));
      }
    });

    request.requestInStream(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 20000,
      readTimeout: 120000,
    }).then((code: number) => {
      closeQuietly(file);
      this.activeKey = '';
      if (code === 200 && !tooBig && received > 0) {
        // 下完才改名：.part 永远不会被当成可播放的缓存
        unlinkQuietly(target);
        try {
          fs.renameSync(part, target);
          this.entries[name] = { size: received, usedAt: Date.now() };
          this.totalBytes += received;
          this.enforceLimit();
          this.scheduleSaveIndex();
          this.bumpVersion();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'commit cache file failed: %{public}s', JSON.stringify(e));
          unlinkQuietly(part);
        }
      } else {
        hilog.info(DOMAIN, TAG, 'cache aborted, code=%{public}d size=%{public}d', code, received);
        unlinkQuietly(part);
      }
      request.destroy();
      this.pumpQueue();
    }).catch((err: Error) => {
      closeQuietly(file);
      unlinkQuietly(part);
      this.activeKey = '';
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}s', err.message);
      request.destroy();
      this.pumpQueue();
    });
  }

  private pumpQueue(): void {
    const task = this.queued;
    if (task === null || this.activeKey.length > 0) {
      return;
    }
    this.queued = null;
    this.cacheSong(task.key, task.quality, task.url);
  }

  // ------------------------------------------------------------ 淘汰 / 索引

  private enforceLimit(): void {
    if (!this.ready) {
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
    const index: AudioCacheIndex = { limitMb: this.limitMb, entries: this.entries };
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

function closeQuietly(file: fs.File): void {
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
