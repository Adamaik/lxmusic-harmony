import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'MediaCache';

/**
 * 元数据缓存（对应洛雪 utils/data.ts 里的 musicUrl / lyric / lyric_edited 三项）
 *
 * 洛雪把这几样塞进 AsyncStorage，键为：
 *   @music_url__<id>_<quality>  ->  播放地址字符串
 *   @lyric__<id>                ->  { lyric, tlyric, rlyric, lxlyric }
 *   @lyric__<id>_edited         ->  用户改过的歌词
 * 播放前先查地址、取词前先查歌词，命中就不再请求平台 / 源脚本（源脚本请求既慢又容易触发风控）。
 *
 * HarmonyOS 的 preferences 对单条字符串长度有限制（源脚本能有几 MB），所以还是落沙箱文件：
 *   files/lx_media_cache/music_url.json      —— 一张 id -> 地址 的表（地址很短，整体几百 KB）
 *   files/lx_media_cache/lyric/<key>.json    —— 一首一个文件（歌词动辄几 KB，分文件才好单独清）
 *   files/lx_media_cache/lyric_edited/<key>.json
 */

/** 带时间轴的歌词才值得缓存（与洛雪 existTimeExp 一致）：纯文本词缓存下来也不会滚 */
const TIME_TAG: RegExp = /\[\d{1,2}:.*\d{1,4}\]/;

const DIR_NAME: string = 'lx_media_cache';
const URL_FILE: string = 'music_url.json';
const PIC_FILE: string = 'music_pic.json';
const LYRIC_DIR: string = 'lyric';
const EDITED_DIR: string = 'lyric_edited';
/** 地址表的落盘节流：连着播几首时不用每首都重写一遍索引 */
const URL_SAVE_DELAY_MS: number = 1000;

/** 缓存的歌词（洛雪只用到 lyric / tlyric 两个字段） */
export interface CachedLyricInfo {
  lyric: string;
  tlyric: string;
}

function emptyLyric(): CachedLyricInfo {
  return { lyric: '', tlyric: '' };
}

/**
 * 一首歌的缓存 key：`<平台>_<songmid>`
 *
 * 与洛雪的 `musicInfo.id` 等价（kg 的 id 是 `songmid_hash`，这里把 hash 一并带上，
 * 保证同平台不同 hash 的条目不会串）。quality 只对播放地址有意义，单独拼。
 */
export function mediaKeyOf(musicInfoJson: string): string {
  if (musicInfoJson.length === 0) {
    return '';
  }
  try {
    const info = JSON.parse(musicInfoJson) as Record<string, Object>;
    const source: string = typeof info.source === 'string' ? info.source as string : '';
    const songmid: string = info.songmid !== undefined && info.songmid !== null ? String(info.songmid) : '';
    const hash: string = typeof info.hash === 'string' ? info.hash as string : '';
    if (source.length === 0 || songmid.length === 0) {
      return '';
    }
    return hash.length > 0 ? `${source}_${songmid}_${hash}` : `${source}_${songmid}`;
  } catch (e) {
    return '';
  }
}

/** 文件名不能带路径分隔符之类的字符，统一洗一遍 */
function safeName(key: string): string {
  const encoder = new util.TextEncoder();
  const bytes = encoder.encodeInto(key);
  let out: string = '';
  const chars: string = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_';
  for (let i = 0; i < bytes.length; i++) {
    const c: string = String.fromCharCode(bytes[i]);
    out += chars.includes(c) ? c : '_';
  }
  return out.length > 0 ? out : 'unknown';
}

export class MediaCache {
  private static instance: MediaCache | null = null;

  static getInstance(): MediaCache {
    if (MediaCache.instance === null) {
      MediaCache.instance = new MediaCache();
    }
    return MediaCache.instance;
  }

  private dir: string = '';
  private lyricDir: string = '';
  private editedDir: string = '';
  private ready: boolean = false;

  private urls: Record<string, string> = {};
  private pics: Record<string, string> = {};
  private urlsDirty: boolean = false;
  private picsDirty: boolean = false;
  private saveTimer: number = 0;

  init(context: common.Context): void {
    this.dir = `${context.filesDir}/${DIR_NAME}`;
    this.lyricDir = `${this.dir}/${LYRIC_DIR}`;
    this.editedDir = `${this.dir}/${EDITED_DIR}`;
    try {
      ensureDir(this.dir);
      ensureDir(this.lyricDir);
      ensureDir(this.editedDir);
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create cache dir failed: %{public}s', JSON.stringify(e));
      this.ready = false;
      return;
    }
    this.urls = this.loadMap(URL_FILE);
    this.pics = this.loadMap(PIC_FILE);
    hilog.info(DOMAIN, TAG, 'media cache ready, %{public}d url / %{public}d pic entries',
      Object.keys(this.urls).length, Object.keys(this.pics).length);
  }

  isReady(): boolean {
    return this.ready;
  }

  private loadMap(file: string): Record<string, string> {
    const out: Record<string, string> = {};
    const text: string = readText(`${this.dir}/${file}`);
    if (text.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(text) as Record<string, string>;
      for (const key of Object.keys(parsed)) {
        const value = parsed[key];
        if (typeof value === 'string' && value.length > 0) {
          out[key] = value;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse %{public}s failed: %{public}s', file, JSON.stringify(e));
    }
    return out;
  }

  private scheduleSave(isPic: boolean): void {
    if (isPic) {
      this.picsDirty = true;
    } else {
      this.urlsDirty = true;
    }
    if (this.saveTimer !== 0) {
      return;
    }
    this.saveTimer = setTimeout(() => {
      this.saveTimer = 0;
      this.flush();
    }, URL_SAVE_DELAY_MS);
  }

  /** 立刻把索引落盘（退出前 / 清理时用） */
  flush(): void {
    if (!this.ready) {
      return;
    }
    if (this.urlsDirty) {
      this.urlsDirty = false;
      try {
        writeText(`${this.dir}/${URL_FILE}`, JSON.stringify(this.urls));
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'save %{public}s failed: %{public}s', URL_FILE, JSON.stringify(e));
      }
    }
    if (this.picsDirty) {
      this.picsDirty = false;
      try {
        writeText(`${this.dir}/${PIC_FILE}`, JSON.stringify(this.pics));
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'save %{public}s failed: %{public}s', PIC_FILE, JSON.stringify(e));
      }
    }
  }

  // ------------------------------------------------------------ 播放地址

  private urlKey(key: string, quality: string): string {
    return `${key}_${quality}`;
  }

  getMusicUrl(key: string, quality: string): string {
    if (key.length === 0) {
      return '';
    }
    const value = this.urls[this.urlKey(key, quality)];
    return value !== undefined ? value : '';
  }

  saveMusicUrl(key: string, quality: string, url: string): void {
    if (!this.ready || key.length === 0 || url.length === 0) {
      return;
    }
    const id: string = this.urlKey(key, quality);
    if (this.urls[id] === url) {
      return;
    }
    this.urls[id] = url;
    this.scheduleSave(false);
  }

  /** 地址失效（播放失败了）：丢掉这条，让下一次重新解析 */
  dropMusicUrl(key: string, quality: string): void {
    const id: string = this.urlKey(key, quality);
    if (this.urls[id] === undefined) {
      return;
    }
    const next: Record<string, string> = {};
    for (const k of Object.keys(this.urls)) {
      if (k !== id) {
        next[k] = this.urls[k];
      }
    }
    this.urls = next;
    this.scheduleSave(false);
  }

  musicUrlCount(): number {
    return Object.keys(this.urls).length;
  }

  clearMusicUrls(): void {
    this.urls = {};
    this.urlsDirty = false;
    this.removeFile(URL_FILE);
    this.stopTimerIfIdle();
  }

  // ------------------------------------------------------------ 封面地址

  /**
   * 封面地址缓存
   *
   * 封面地址是「按平台接口现查」的（kw / kg 的搜索结果不带封面），列表里几百行
   * 每次启动都要重新查一遍。洛雪是把 picUrl 写回 musicInfo（跟着同步走），
   * 这里单独缓存一份，效果相同但不污染同步数据。
   */
  getPic(key: string): string {
    if (!this.ready || key.length === 0) {
      return '';
    }
    const value = this.pics[key];
    return value !== undefined ? value : '';
  }

  savePic(key: string, url: string): void {
    if (!this.ready || key.length === 0 || url.length === 0) {
      return;
    }
    if (this.pics[key] === url) {
      return;
    }
    this.pics[key] = url;
    this.scheduleSave(true);
  }

  picCount(): number {
    return Object.keys(this.pics).length;
  }

  clearPics(): void {
    this.pics = {};
    this.picsDirty = false;
    this.removeFile(PIC_FILE);
    this.stopTimerIfIdle();
  }

  private removeFile(file: string): void {
    if (!this.ready) {
      return;
    }
    try {
      const target: string = `${this.dir}/${file}`;
      if (fs.accessSync(target)) {
        fs.unlinkSync(target);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove %{public}s failed: %{public}s', file, JSON.stringify(e));
    }
  }

  private stopTimerIfIdle(): void {
    if (this.urlsDirty || this.picsDirty) {
      return;
    }
    if (this.saveTimer !== 0) {
      clearTimeout(this.saveTimer);
      this.saveTimer = 0;
    }
  }

  // ------------------------------------------------------------ 歌词

  private lyricPath(key: string, edited: boolean): string {
    const dir: string = edited ? this.editedDir : this.lyricDir;
    return `${dir}/${safeName(key)}.json`;
  }

  /**
   * 取缓存的歌词；没有 / 不带时间轴都返回 null（与洛雪 getCachedLyricInfo 的校验一致）
   */
  getLyric(key: string): CachedLyricInfo | null {
    if (!this.ready || key.length === 0) {
      return null;
    }
    const edited: CachedLyricInfo | null = this.readLyricFile(this.lyricPath(key, true));
    if (edited !== null) {
      return edited;
    }
    return this.readLyricFile(this.lyricPath(key, false));
  }

  private readLyricFile(path: string): CachedLyricInfo | null {
    const text: string = readText(path);
    if (text.length === 0) {
      return null;
    }
    try {
      const parsed = JSON.parse(text) as CachedLyricInfo;
      const lyric: string = parsed.lyric !== undefined && parsed.lyric !== null ? parsed.lyric : '';
      const tlyric: string = parsed.tlyric !== undefined && parsed.tlyric !== null ? parsed.tlyric : '';
      if (lyric.length === 0 || !TIME_TAG.test(lyric)) {
        return null;
      }
      return { lyric: lyric, tlyric: tlyric };
    } catch (e) {
      return null;
    }
  }

  saveLyric(key: string, info: CachedLyricInfo): void {
    this.writeLyricFile(key, info, false);
  }

  saveEditedLyric(key: string, info: CachedLyricInfo): void {
    this.writeLyricFile(key, info, true);
  }

  private writeLyricFile(key: string, info: CachedLyricInfo, edited: boolean): void {
    if (!this.ready || key.length === 0 || info.lyric.length === 0) {
      return;
    }
    if (!TIME_TAG.test(info.lyric)) {
      // 没有时间轴的词不缓存：下次还是要重新取，留着只会占地方
      return;
    }
    try {
      writeText(this.lyricPath(key, edited), JSON.stringify(info));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save lyric failed: %{public}s', JSON.stringify(e));
    }
  }

  lyricCount(): number {
    return this.countFiles(this.lyricDir) + this.countFiles(this.editedDir);
  }

  clearLyrics(): void {
    this.clearDir(this.lyricDir);
    this.clearDir(this.editedDir);
  }

  private countFiles(dir: string): number {
    if (!this.ready) {
      return 0;
    }
    try {
      return fs.listFileSync(dir).length;
    } catch (e) {
      return 0;
    }
  }

  private clearDir(dir: string): void {
    if (!this.ready) {
      return;
    }
    try {
      for (const name of fs.listFileSync(dir)) {
        try {
          fs.unlinkSync(`${dir}/${name}`);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'unlink %{public}s failed', name);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clear dir failed: %{public}s', JSON.stringify(e));
    }
  }
}

// ------------------------------------------------------------------ 文件工具

function ensureDir(path: string): void {
  if (!fs.accessSync(path)) {
    fs.mkdirSync(path);
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
