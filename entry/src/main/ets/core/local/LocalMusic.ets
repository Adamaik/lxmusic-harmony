import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { LxMusicInfo } from '../music/MusicSearch';
import { bytesToUtf8 } from '../music/LxCrypto';
import { SongSideTable } from './SideTable';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalMusic';

const DIR_NAME: string = 'local_music';
const COVER_DIR: string = 'covers';
const INDEX_FILE: string = 'index.json';
const INDEX_VERSION: number = 1;

/**
 * AVPlayer / AVMetadataExtractor 官方列出的音频格式。
 * 不在这个列表里的（ape / wma / dsf / dff 等）导入时要明确告诉用户，不能静默丢掉。
 */
const SUPPORTED_EXTS: string[] = ['.mp3', '.flac', '.m4a', '.aac', '.ogg', '.wav', '.amr'];

/**
 * 明知放不了、但确实是音频的后缀
 *
 * 只有这些才会报「格式不支持」。选文件夹时目录里还躺着一堆 `.lrc`、封面图、
 * `desktop.ini` 之类，它们不是歌曲，报成失败只会让用户莫名其妙 —— 那些静默跳过。
 */
const UNSUPPORTED_AUDIO_EXTS: string[] = ['.ape', '.wma', '.dsf', '.dff', '.opus', '.aiff', '.aif',
  '.m4b', '.mpc', '.tak', '.wv'];

/** 封面落盘尺寸上限：有的内嵌封面是 3000×3000 的图，列表里根本用不上 */
const COVER_QUALITY: number = 80;

/** 歌词文件大小上限（正常 .lrc 只有几 KB，防止把奇怪的大文件整份读进内存） */
const LRC_MAX_BYTES: number = 512 * 1024;

/** 本地音乐库版本号：导入/删除后 +1，界面订阅它重新读列表 */
export const K_LOCAL_VERSION: string = 'local_version';
/** 导入进度（`3/120 歌名`），空闲时是空串 */
export const K_LOCAL_PROGRESS: string = 'local_progress';

/**
 * 本地歌在 SongItem.source / musicInfo.source 里的标记
 *
 * 声明放在类之前：类字段 `source` 的初值直接引用它，写在文件后面时静态检查会
 * 认不出这个字段（`implements SongSideTable` 就会报「缺少 source」）。
 */
export const LOCAL_SOURCE: string = 'local';
/** 本地歌的条目 id 前缀（洛雪也用 'local' 表示本地歌曲） */
export const LOCAL_ID_PREFIX: string = 'local_';

/** 一条本地歌曲（落盘索引里的一行） */
export interface LocalSong {
  /** 稳定标识（不含 local_ 前缀），同时作为 musicInfo.songmid */
  key: string;
  /** 沙箱里的文件名（含后缀） */
  file: string;
  /** 封面文件名（covers/ 下），没有内嵌封面时为空串 */
  cover: string;
  /**
   * 一起导入的同名歌词文件名（`.lrc`），没有就是空串
   *
   * 同一个目录里的歌词是**精确匹配**：不联网、不会配错，所以播放时优先用它。
   */
  lrc: string;
  /** 在线匹配到的平台歌曲（LxMusicInfo 的 JSON），空串 = 还没匹配到 */
  matchJson: string;
  /** 匹配结果来自哪个平台（kw / kg / tx / mg / wy） */
  matchSource: string;
  /**
   * 上次自动匹配的时刻（0 = 从没试过）
   *
   * 用来避免「每放一次就搜一次、每次都搜不到」：搜过一次（哪怕是没搜到）就记下来，
   * 之后只有用户手动纠正时才会再搜。
   */
  matchAt: number;
  name: string;
  singer: string;
  album: string;
  /** 毫秒；读不到标签时为 0（播放时以播放器报的时长为准） */
  durationMs: number;
  sizeBytes: number;
  addedAt: number;
  /** 去重指纹：大小 + 文件名（小写）。同一份文件重复导入时命中 */
  fingerprint: string;
}

/** 导入结果统计 */
export interface ImportResult {
  added: number;
  /** 已经导入过（指纹命中） */
  skipped: number;
  /** 格式不支持 */
  unsupported: number;
  /** 打开/拷贝/读标签失败 */
  failed: number;
}

interface LocalIndex {
  version: number;
  songs: LocalSong[];
  /** 非同步侧表：歌单 id -> 该歌单里的本地歌 key 列表（love 也用这个键） */
  lists: Record<string, string[]>;
}

/**
 * 本地音乐库（设备里的音频文件，导入进沙箱的那一份）
 *
 * 为什么是「导入」而不是「记住文件路径」：Picker 返回的 URI 只有临时权限，
 * 官方文档写明「待退出应用后台后，获取的临时权限就会失效」；要跨重启就得
 * fileShare.persistPermission，那需要受限 ACL 权限（ohos.permission.FILE_ACCESS_PERSIST），
 * 而受限权限只批给「克隆 / 备份 / 同步」场景，音乐播放器申请不下来（详见 docs/LOCAL_MUSIC.md）。
 * 所以选中即拷贝一份到 files/local_music/：零权限、退后台不掉、重启还在。
 *
 * 本模块不依赖播放与同步模块（只借它们的类型），是本地歌的唯一持有者：
 *   - 音频副本与索引：files/local_music/index.json
 *   - 封面：files/local_music/covers/
 *   - 非同步侧表：index.json 的 lists（本地歌进了哪些歌单 / 收藏）
 *
 * 侧表单独存的原因：参与同步的那份数据要按 listData() 的 JSON 算 md5 和服务端比对，
 * 往里塞任何字段都会改掉 md5。侧表在另一个文件里，同步链路完全看不见它。
 */
export class LocalMusic implements SongSideTable {
  private static instance: LocalMusic | null = null;

  static getInstance(): LocalMusic {
    if (LocalMusic.instance === null) {
      LocalMusic.instance = new LocalMusic();
    }
    return LocalMusic.instance;
  }

  /**
   * 这张侧表持有的条目标记
   *
   * 实现了 `SongSideTable`（见 core/local/SideTable），所以 LocalLibrary 能把
   * 「本地音乐」与「云端（WebDAV）音乐」两张侧表放在一个数组里统一读写：
   * 加歌单 / 收藏、算曲目数、合并列表、删歌单清引用都不必各写一遍。
   */
  source: string = LOCAL_SOURCE;

  private dir: string = '';
  private coverDir: string = '';
  private ready: boolean = false;
  private songs: LocalSong[] = [];
  /** 歌单 id -> 本地歌 key 列表。用 Map 而不是 Record：ArkTS 不允许 delete 运算符 */
  private lists: Map<string, string[]> = new Map<string, string[]>();
  private byKey: Map<string, LocalSong> = new Map();
  private byFingerprint: Set<string> = new Set();
  private seq: number = 0;
  /** 用户点了取消：导入循环在下一个文件前退出 */
  private cancelled: boolean = false;

  init(context: common.Context): void {
    if (this.ready) {
      return;
    }
    this.dir = `${context.filesDir}/${DIR_NAME}`;
    this.coverDir = `${this.dir}/${COVER_DIR}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      if (!fs.accessSync(this.coverDir)) {
        fs.mkdirSync(this.coverDir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create dir failed: %{public}s', JSON.stringify(e));
      this.ready = false;
      return;
    }
    this.load();
  }

  isReady(): boolean {
    return this.ready;
  }

  // ------------------------------------------------------------ 读取

  /** 界面用：按导入时间倒序（新导入的在最上面） */
  songsForUi(): SongItem[] {
    const out: SongItem[] = [];
    for (let i = this.songs.length - 1; i >= 0; i--) {
      out.push(this.songOf(this.songs[i]));
    }
    return out;
  }

  count(): number {
    return this.songs.length;
  }

  totalBytes(): number {
    let sum: number = 0;
    for (const song of this.songs) {
      sum += song.sizeBytes;
    }
    return sum;
  }

  /** 沙箱里的绝对路径；文件不在了返回空串（用户清过数据 / 文件被误删） */
  pathOf(key: string): string {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined) {
      return '';
    }
    const path: string = `${this.dir}/${song.file}`;
    try {
      return fs.accessSync(path) ? path : '';
    } catch (e) {
      return '';
    }
  }

  hasKey(key: string): boolean {
    return this.byKey.has(key);
  }

  /** 条目 id（`local_<key>`）是否还在库里（界面按它隐藏音质 / 下载入口） */
  hasId(id: string): boolean {
    const key: string = this.keyOfId(id);
    return key.length > 0 && this.byKey.has(key);
  }

  /** 一批 key 对应的条目（按传入顺序，跳过已经不存在的） */
  songsByKeys(keys: string[]): SongItem[] {
    const out: SongItem[] = [];
    for (const key of keys) {
      const song: LocalSong | undefined = this.byKey.get(key);
      if (song !== undefined) {
        out.push(this.songOf(song));
      }
    }
    return out;
  }

  /** 从条目 id（`local_<key>`）取 key */
  keyOfId(id: string): string {
    return id.startsWith(LOCAL_ID_PREFIX) ? id.substring(LOCAL_ID_PREFIX.length) : '';
  }

  /** 一条本地歌的展示条目 */
  songOf(song: LocalSong): SongItem {
    const name: string = song.name.length > 0 ? song.name : stripExt(song.file);
    const info: LxMusicInfo = {
      name: name,
      singer: song.singer,
      source: LOCAL_SOURCE,
      songmid: song.key,
      albumName: song.album,
      albumId: '',
      interval: formatInterval(song.durationMs),
      img: song.cover.length > 0 ? this.coverUri(song.cover) : '',
      types: [],
      _types: {},
      typeUrl: {},
      lrc: null,
      otherSource: null,
    };
    const item: SongItem = {
      id: `${LOCAL_ID_PREFIX}${song.key}`,
      name: name,
      singer: song.singer,
      coverUrl: info.img,
      art: info.img.length === 0,
      source: LOCAL_SOURCE,
      // 本地歌没有音质协商；界面把 'local' 显示成「本地」
      quality: 'local',
      interval: info.interval,
      musicInfoJson: JSON.stringify(info),
    };
    return item;
  }

  private coverUri(coverFile: string): string {
    try {
      return fileUri.getUriFromPath(`${this.coverDir}/${coverFile}`);
    } catch (e) {
      // 取不到 URI 就不给封面（列表退回占位图），不要让一行图把整页带崩
      hilog.warn(DOMAIN, TAG, 'cover uri failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  // ------------------------------------------------------------ 歌词

  /** 这条本地歌有没有一起导入的 `.lrc` */
  hasLocalLyric(key: string): boolean {
    const song: LocalSong | undefined = this.byKey.get(key);
    return song !== undefined && song.lrc.length > 0;
  }

  /**
   * 读同名 `.lrc` 的文本；没有或读不出来返回空串
   *
   * 中文歌词文件有相当一部分是 GBK 编码，而 `fs.readTextSync` 只支持 utf-8，
   * 所以这里读原始字节：先用 UTF-8 解，解出替换字符（U+FFFD）说明编码不对，
   * 再用 GBK 解一遍。
   */
  lrcTextOf(key: string): string {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined || song.lrc.length === 0) {
      return '';
    }
    const bytes: Uint8Array | null = readBytes(`${this.dir}/${song.lrc}`);
    if (bytes === null || bytes.length === 0) {
      return '';
    }
    const utf8: string = bytesToUtf8(toNumberArray(bytes));
    if (utf8.indexOf('\uFFFD') < 0) {
      return utf8;
    }
    const gbk: string = decodeGbk(bytes);
    if (gbk.length > 0 && gbk.indexOf('\uFFFD') < 0) {
      return gbk;
    }
    return utf8;
  }

  /** 匹配到的平台歌曲（没匹配到返回 null） */
  matchOf(key: string): LxMusicInfo | null {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined || song.matchJson.length === 0) {
      return null;
    }
    try {
      return JSON.parse(song.matchJson) as LxMusicInfo;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse match failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** 记下匹配结果（自动匹配成功，或用户手动选的那一条） */
  saveMatch(key: string, source: string, infoJson: string): void {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined || infoJson.length === 0) {
      return;
    }
    song.matchSource = source;
    song.matchJson = infoJson;
    song.matchAt = Date.now();
    this.persist();
    this.bumpVersion();
  }

  /** 清掉匹配结果（用户想重新匹配时用） */
  clearMatch(key: string): void {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined) {
      return;
    }
    song.matchJson = '';
    song.matchSource = '';
    // 留着 matchAt：自动匹配不会再自己重试，只有用户手动匹配才会
    this.persist();
    this.bumpVersion();
  }

  /** 自动匹配是不是已经试过了（成功与否都算试过） */
  matchTried(key: string): boolean {
    const song: LocalSong | undefined = this.byKey.get(key);
    return song !== undefined && song.matchAt > 0;
  }

  /** 记下「自动匹配试过一次了」，避免每放一次就联网搜一次 */
  markMatchTried(key: string): void {
    const song: LocalSong | undefined = this.byKey.get(key);
    if (song === undefined || song.matchAt > 0) {
      return;
    }
    song.matchAt = Date.now();
    this.persist();
  }

  /** 标签里的时长（毫秒，0 = 没读到）；匹配时用它排除同名不同版本 */
  durationMsOf(key: string): number {
    const song: LocalSong | undefined = this.byKey.get(key);
    return song === undefined ? 0 : song.durationMs;
  }

  // ------------------------------------------------------------ 导入

  /**
   * 导入一批 Picker 选中的音频文件
   *
   * 逐个串行处理（拷贝是同步的，中间要让出事件循环，否则大库导入会把界面卡住），
   * 每个文件的进度写进 AppStorage，界面据此显示「正在导入 x/y」。
   */
  async importUris(uris: string[]): Promise<ImportResult> {
    const result: ImportResult = { added: 0, skipped: 0, unsupported: 0, failed: 0 };
    if (!this.ready || uris.length === 0) {
      return result;
    }
    // 先摘掉「不是歌曲」的文件（.lrc / 封面图 / 说明文本…）：选文件夹时目录里全是这些，
    // 把它们算进「格式不支持」或者让进度条念一遍它们的名字都只会让人困惑
    const candidates: string[] = [];
    for (const uri of uris) {
      if (!isIgnorableFile(fileNameOf(uri))) {
        candidates.push(uri);
      }
    }
    this.cancelled = false;
    const total: number = candidates.length;
    for (let i = 0; i < total; i++) {
      if (this.cancelled) {
        hilog.info(DOMAIN, TAG, 'import cancelled at %{public}d/%{public}d', i, total);
        break;
      }
      const uri: string = candidates[i];
      const label: string = fileNameOf(uri);
      AppStorage.setOrCreate(K_LOCAL_PROGRESS, `${i + 1}/${total} ${label}`);
      const outcome: string = await this.importOne(uri, label);
      if (outcome === 'added') {
        result.added++;
      } else if (outcome === 'skipped') {
        result.skipped++;
      } else if (outcome === 'unsupported') {
        result.unsupported++;
      } else {
        result.failed++;
      }
    }
    AppStorage.setOrCreate(K_LOCAL_PROGRESS, '');
    if (result.added > 0) {
      this.persist();
      this.bumpVersion();
    }
    return result;
  }

  /** 用户取消导入（当前这个文件会做完，从下一个开始停） */
  cancelImport(): void {
    this.cancelled = true;
  }

  isImporting(): boolean {
    const text = AppStorage.get<string>(K_LOCAL_PROGRESS);
    return text !== undefined && text.length > 0;
  }

  /** @returns added / skipped / unsupported / failed */
  private async importOne(uri: string, label: string): Promise<string> {
    const ext: string = extOf(label);
    if (!isSupportedAudioFile(label)) {
      hilog.info(DOMAIN, TAG, 'skip unsupported file: %{public}s', label);
      return 'unsupported';
    }
    let src: fs.File | null = null;
    try {
      src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(src.fd);
      const size: number = stat.size;
      if (size <= 0) {
        return 'failed';
      }
      const fingerprint: string = `${size}_${label.toLowerCase()}`;
      if (this.byFingerprint.has(fingerprint)) {
        return 'skipped';
      }
      const key: string = this.nextKey();
      const file: string = `${key}${ext}`;
      const dest: string = `${this.dir}/${file}`;
      fs.copyFileSync(src.fd, dest);
      closeQuietly(src);
      src = null;

      // 读标签要用**另一个**句柄：官方文档明确说同一个 fd 同时给播放器和提取器
      // 会「存在竞争关系，将导致音视频元数据获取异常」
      const meta: LocalMeta = await this.readMetadata(dest, size, key);
      // 同目录下的同名 .lrc 一并拷进来：这是**精确匹配**的歌词，播放时优先用它。
      // 「选文件夹」这条路一定拿得到；「选文件」那条路只授权了选中的文件，
      // 兄弟文件多半读不到 —— 读不到就算了，之后还有在线匹配兜底。
      const lrc: string = this.copySiblingLrc(uri, key);
      const song: LocalSong = {
        key: key,
        file: file,
        cover: meta.coverFile,
        lrc: lrc,
        matchJson: '',
        matchSource: '',
        matchAt: 0,
        name: meta.name.length > 0 ? meta.name : titleFromFileName(label),
        singer: meta.singer.length > 0 ? meta.singer : singerFromFileName(label),
        album: meta.album,
        durationMs: meta.durationMs,
        sizeBytes: size,
        addedAt: Date.now(),
        fingerprint: fingerprint,
      };
      this.songs.push(song);
      this.byKey.set(key, song);
      this.byFingerprint.add(fingerprint);
      return 'added';
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'import failed (%{public}s): %{public}s', label, JSON.stringify(e));
      return 'failed';
    } finally {
      closeQuietly(src);
    }
  }

  /**
   * 把同名 `.lrc` 一起拷进来（没有就返回空串）
   *
   * 只在音频文件旁边找一个同名歌词：`song.mp3` → `song.lrc` / `song.LRC`。
   * 读不到是常态（用户是用「选文件」进来的，只授权了那一个文件），所以这里不报错。
   */
  private copySiblingLrc(audioUri: string, key: string): string {
    const bases: string[] = siblingLrcBases(audioUri);
    for (const base of bases) {
      let src: fs.File | null = null;
      try {
        src = fs.openSync(base, fs.OpenMode.READ_ONLY);
        const file: string = `${key}.lrc`;
        fs.copyFileSync(src.fd, `${this.dir}/${file}`);
        return file;
      } catch (e) {
        // 没有同名词就试下一个写法
      } finally {
        closeQuietly(src);
      }
    }
    return '';
  }

  /** 读元数据与内嵌封面；失败不抛错，退回文件名（标签不是必需的） */
  private async readMetadata(path: string, size: number, key: string): Promise<LocalMeta> {    const out: LocalMeta = { name: '', singer: '', album: '', durationMs: 0, coverFile: '' };
    let file: fs.File | null = null;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      const source: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
      extractor.fdSrc = source;
      const meta: media.AVMetadata = await extractor.fetchMetadata();
      out.name = asText(meta.title);
      out.singer = asText(meta.artist);
      out.album = asText(meta.album);
      out.durationMs = asNumber(meta.duration);
      out.coverFile = await this.saveCover(extractor, key);
    } catch (e) {
      // 不支持的编码 / 没有标签都会走到这里，属于常态，不报错只记日志
      hilog.info(DOMAIN, TAG, 'read metadata failed: %{public}s', JSON.stringify(e));
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'release extractor failed: %{public}s', JSON.stringify(e));
        }
      }
      closeQuietly(file);
    }
    return out;
  }

  /** 内嵌封面 -> JPEG 落盘；没有封面返回空串 */
  private async saveCover(extractor: media.AVMetadataExtractor, key: string): Promise<string> {
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      pixelMap = await extractor.fetchAlbumCover();
      packer = image.createImagePacker();
      const option: image.PackingOption = { format: 'image/jpeg', quality: COVER_QUALITY };
      const buffer: ArrayBuffer = await packer.packToData(pixelMap, option);
      const file: string = `${key}.jpg`;
      const handle: fs.File = fs.openSync(`${this.coverDir}/${file}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, buffer);
      } finally {
        fs.closeSync(handle);
      }
      return file;
    } catch (e) {
      // 大多数没有内嵌封面的文件会走到这里
      return '';
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'release packer failed: %{public}s', JSON.stringify(e));
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'release pixelmap failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  private nextKey(): string {
    this.seq = (this.seq + 1) % 1296;
    return `${Date.now().toString(36)}${this.seq.toString(36)}`;
  }

  // ------------------------------------------------------------ 删除

  /**
   * 删掉一批本地歌（只删沙箱里的副本，用户原文件不动）
   * 同时把它们从所有歌单 / 收藏的侧表里摘掉 —— 文件没了，引用必须一起清，
   * 否则歌单里会留下打不开的条目。
   */
  removeKeys(keys: string[]): number {
    if (keys.length === 0) {
      return 0;
    }
    const remains: LocalSong[] = [];
    let removed: number = 0;
    for (const song of this.songs) {
      if (keys.includes(song.key)) {
        unlinkQuietly(`${this.dir}/${song.file}`);
        if (song.cover.length > 0) {
          unlinkQuietly(`${this.coverDir}/${song.cover}`);
        }
        if (song.lrc.length > 0) {
          unlinkQuietly(`${this.dir}/${song.lrc}`);
        }
        this.byKey.delete(song.key);
        this.byFingerprint.delete(song.fingerprint);
        removed++;
        continue;
      }
      remains.push(song);
    }
    if (removed === 0) {
      return 0;
    }
    this.songs = remains;
    for (const listId of Array.from(this.lists.keys())) {
      const kept: string[] = this.listKeys(listId).filter((key: string) => !keys.includes(key));
      if (kept.length === 0) {
        this.lists.delete(listId);
      } else {
        this.lists.set(listId, kept);
      }
    }
    this.persist();
    this.bumpVersion();
    return removed;
  }

  /** 清空全部（歌单侧表一起清） */
  clear(): void {
    const keys: string[] = [];
    for (const song of this.songs) {
      keys.push(song.key);
    }
    this.removeKeys(keys);
  }

  // ------------------------------------------------------------ 歌单 / 收藏侧表

  /** 某个歌单里的本地歌 key（按加入顺序，最新的在最前） */
  listKeys(listId: string): string[] {
    const keys: string[] | undefined = this.lists.get(listId);
    return keys === undefined ? [] : keys;
  }

  listCount(listId: string): number {
    return this.listKeys(listId).length;
  }

  /** 写入某个歌单的本地歌 key（顺序即展示顺序） */
  setListKeys(listId: string, keys: string[]): void {
    const current: string[] = this.listKeys(listId);
    if (current.length === keys.length && current.every((key: string, i: number) => key === keys[i])) {
      return;
    }
    if (keys.length === 0) {
      this.lists.delete(listId);
    } else {
      this.lists.set(listId, keys.slice());
    }
    this.persist();
    this.bumpVersion();
  }

  /** 往歌单里加（新的排最前，与在线歌曲「新加的排最前」一致）；返回真正加进去的数量 */
  addToList(listId: string, keys: string[]): number {
    const fresh: string[] = [];
    const current: string[] = this.listKeys(listId);
    for (const key of keys) {
      if (current.includes(key) || fresh.includes(key)) {
        continue;
      }
      fresh.push(key);
    }
    if (fresh.length === 0) {
      return 0;
    }
    this.setListKeys(listId, fresh.concat(current));
    return fresh.length;
  }

  /** @returns 真正被摘掉的条数 */
  removeFromList(listId: string, keys: string[]): number {
    if (keys.length === 0) {
      return 0;
    }
    const current: string[] = this.listKeys(listId);
    const kept: string[] = current.filter((key: string) => !keys.includes(key));
    if (kept.length === current.length) {
      return 0;
    }
    this.setListKeys(listId, kept);
    return current.length - kept.length;
  }

  /** 歌单被删掉了：侧表一起清 */
  dropLists(listIds: string[]): void {
    let changed: boolean = false;
    for (const listId of listIds) {
      if (this.lists.has(listId)) {
        this.lists.delete(listId);
        changed = true;
      }
    }
    if (changed) {
      this.persist();
      this.bumpVersion();
    }
  }

  // ------------------------------------------------------------ 落盘

  private load(): void {
    this.songs = [];
    this.lists = new Map<string, string[]>();
    this.byKey.clear();
    this.byFingerprint.clear();
    const text: string | null = this.readText(`${this.dir}/${INDEX_FILE}`);
    if (text !== null) {
      try {
        const raw = JSON.parse(text) as LocalIndex;
        this.songs = normalizeSongs(raw.songs);
        this.lists = toMap(raw.lists);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'parse index failed: %{public}s', JSON.stringify(e));
      }
    }
    for (const song of this.songs) {
      this.byKey.set(song.key, song);
      this.byFingerprint.add(song.fingerprint);
    }
    this.sweepOrphans();
  }

  /**
   * 清掉索引里没有的文件
   *
   * 导入是「先拷文件、后写索引」：中途被杀进程（或取消）会留下没有索引的副本，
   * 这些文件谁也播不了、还白占空间。反过来索引里有、文件不在的条目也顺手清掉
   * （用户在文件管理器里删过、或者清了应用数据）。
   */
  private sweepOrphans(): void {
    if (!this.ready) {
      return;
    }
    const known: Set<string> = new Set<string>();
    const missing: string[] = [];
    for (const song of this.songs) {
      known.add(song.file);
      if (song.cover.length > 0) {
        known.add(`${COVER_DIR}/${song.cover}`);
      }
      if (song.lrc.length > 0) {
        known.add(song.lrc);
      }
      try {
        if (!fs.accessSync(`${this.dir}/${song.file}`)) {
          missing.push(song.key);
        }
      } catch (e) {
        missing.push(song.key);
      }
    }
    let changed: boolean = missing.length > 0;
    if (missing.length > 0) {
      hilog.warn(DOMAIN, TAG, 'drop %{public}d missing local songs', missing.length);
      this.songs = this.songs.filter((song: LocalSong) => !missing.includes(song.key));
      for (const key of missing) {
        const song: LocalSong | undefined = this.byKey.get(key);
        if (song !== undefined) {
          this.byFingerprint.delete(song.fingerprint);
        }
        this.byKey.delete(key);
      }
      for (const listId of Array.from(this.lists.keys())) {
        const kept: string[] = this.listKeys(listId).filter((key: string) => !missing.includes(key));
        if (kept.length === 0) {
          this.lists.delete(listId);
        } else {
          this.lists.set(listId, kept);
        }
      }
    }
    try {
      for (const name of fs.listFileSync(this.dir)) {
        if (name === INDEX_FILE || name === COVER_DIR || known.has(name)) {
          continue;
        }
        // 导入是「先拷文件、后写索引」：这里剩下的都是没有索引的副本（拷到一半被杀进程），
        // 谁也播不了，清掉。这个目录只有本模块在写，所以不在索引里就是垃圾。
        hilog.warn(DOMAIN, TAG, 'remove orphan file: %{public}s', name);
        unlinkQuietly(`${this.dir}/${name}`);
        changed = true;
      }
      for (const name of fs.listFileSync(this.coverDir)) {
        if (known.has(`${COVER_DIR}/${name}`)) {
          continue;
        }
        unlinkQuietly(`${this.coverDir}/${name}`);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sweep dir failed: %{public}s', JSON.stringify(e));
    }
    if (changed) {
      this.persist();
    }
  }

  private persist(): void {
    if (!this.ready) {
      return;
    }
    const index: LocalIndex = {
      version: INDEX_VERSION,
      songs: this.songs,
      lists: toRecord(this.lists),
    };
    try {
      const handle: fs.File = fs.openSync(`${this.dir}/${INDEX_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(index));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save index failed: %{public}s', JSON.stringify(e));
    }
  }

  private readText(path: string): string | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      return fs.readTextSync(path);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'readText failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  private bumpVersion(): void {
    const version: number = AppStorage.get<number>(K_LOCAL_VERSION) ?? 0;
    AppStorage.setOrCreate(K_LOCAL_VERSION, version + 1);
  }
}

// ------------------------------------------------------------ 工具

/**
 * 这条是不是本地歌（设备里导入进来的音频）
 *
 * 界面上要按它来隐藏「下载 / 音质」这些对本地文件没有意义的入口。
 * 放成函数而不是各处写 `source === 'local'`：拼错字符串是静默失效，很难查。
 */
export function isLocalSong(item: SongItem): boolean {
  return item.source === LOCAL_SOURCE;
}

/**
 * 这个文件名的后缀是不是 AVPlayer 能播的音频格式
 *
 * 不在列表里的（ape / wma / dsf / dff…）导入时要明确告诉用户「格式不支持」，
 * 不能静默跳过 —— 用户会以为导入成功了。
 */
export function isSupportedAudioFile(name: string): boolean {
  return SUPPORTED_EXTS.includes(extOf(name));
}

/** 明知放不了、但确实是音频的后缀（只有这些才报「格式不支持」） */
export function isUnsupportedAudioFile(name: string): boolean {
  return UNSUPPORTED_AUDIO_EXTS.includes(extOf(name));
}

/**
 * 完全不该参与导入的文件：歌词、封面图、说明文本等等
 *
 * 选文件夹时它们会一起进来（`listFileSync` 返回目录下的所有名字），
 * 静默跳过即可，既不算失败也不出现在进度里。
 */
export function isIgnorableFile(name: string): boolean {
  return !isSupportedAudioFile(name) && !isUnsupportedAudioFile(name);
}

interface LocalMeta {
  name: string;
  singer: string;
  album: string;
  durationMs: number;
  coverFile: string;
}

function asText(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

/** AVMetadata 的 duration 是字符串（毫秒） */
function asNumber(value: string | undefined): number {
  if (typeof value !== 'string') {
    return 0;
  }
  const parsed: number = Number.parseInt(value, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** 从 URI 里取出文件名（Picker 会把中文与特殊字符编码进 URI） */
function fileNameOf(uri: string): string {
  const cut: number = uri.lastIndexOf('/');
  const raw: string = cut >= 0 ? uri.substring(cut + 1) : uri;
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}

function extOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

/**
 * 音频 URI -> 可能的同名歌词 URI（大小写两种写法）
 *
 * URI 里的中文与特殊字符是百分号编码的，所以只做后缀替换、不碰文件名本身。
 */
function siblingLrcBases(audioUri: string): string[] {
  const slash: number = audioUri.lastIndexOf('/');
  const dot: number = audioUri.lastIndexOf('.');
  // 点在最后一段里才算后缀（否则可能是目录名里的点）
  if (dot <= slash + 1) {
    return [];
  }
  const base: string = audioUri.substring(0, dot);
  return [`${base}.lrc`, `${base}.LRC`];
}

function stripExt(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/**
 * 没有标签时用文件名兜底
 * 常见命名是「歌手 - 歌名」（下载设置里也有这个格式），只在文件名单一时才拆。
 */
export function titleFromFileName(label: string): string {
  const base: string = stripExt(label);
  const sep: number = base.indexOf(' - ');
  if (sep <= 0 || sep >= base.length - 3) {
    return base;
  }
  return base.substring(sep + 3);
}

/** 文件名的「歌手」那一半（与 titleFromFileName 配套） */
export function singerFromFileName(label: string): string {
  const base: string = stripExt(label);
  const sep: number = base.indexOf(' - ');
  return sep > 0 ? base.substring(0, sep) : '';
}

/** 毫秒 -> mm:ss（SongItem.interval 的口径，与在线歌曲一致） */
function formatInterval(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const total: number = Math.floor(ms / 1000);
  const minutes: number = Math.floor(total / 60);
  const seconds: number = total % 60;
  return `${minutes < 10 ? '0' : ''}${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
}

function normalizeSongs(input: LocalSong[] | undefined): LocalSong[] {
  if (!Array.isArray(input)) {
    return [];
  }
  const out: LocalSong[] = [];
  for (const item of input) {
    if (item === null || item === undefined) {
      continue;
    }
    if (typeof item.key !== 'string' || item.key.length === 0) {
      continue;
    }
    if (typeof item.file !== 'string' || item.file.length === 0) {
      continue;
    }
    out.push({
      key: item.key,
      file: item.file,
      cover: typeof item.cover === 'string' ? item.cover : '',
      lrc: typeof item.lrc === 'string' ? item.lrc : '',
      matchJson: typeof item.matchJson === 'string' ? item.matchJson : '',
      matchSource: typeof item.matchSource === 'string' ? item.matchSource : '',
      matchAt: typeof item.matchAt === 'number' ? item.matchAt : 0,
      name: typeof item.name === 'string' ? item.name : '',
      singer: typeof item.singer === 'string' ? item.singer : '',
      album: typeof item.album === 'string' ? item.album : '',
      durationMs: typeof item.durationMs === 'number' ? item.durationMs : 0,
      sizeBytes: typeof item.sizeBytes === 'number' ? item.sizeBytes : 0,
      addedAt: typeof item.addedAt === 'number' ? item.addedAt : 0,
      fingerprint: typeof item.fingerprint === 'string' ? item.fingerprint : '',
    });
  }
  return out;
}

function normalizeLists(input: Record<string, string[]> | undefined): Map<string, string[]> {
  const out: Map<string, string[]> = new Map<string, string[]>();
  if (input === undefined || input === null) {
    return out;
  }
  for (const listId of Object.keys(input)) {
    const keys: string[] = input[listId];
    if (!Array.isArray(keys)) {
      continue;
    }
    const kept: string[] = [];
    for (const key of keys) {
      if (typeof key === 'string' && key.length > 0 && !kept.includes(key)) {
        kept.push(key);
      }
    }
    if (kept.length > 0) {
      out.set(listId, kept);
    }
  }
  return out;
}

/** 落盘形态（Record）-> 内存形态（Map）：ArkTS 不允许 delete，所以内部一律用 Map */
function toMap(input: Record<string, string[]> | undefined): Map<string, string[]> {
  return normalizeLists(input);
}

function toRecord(input: Map<string, string[]>): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const listId of Array.from(input.keys())) {
    out[listId] = input.get(listId) ?? [];
  }
  return out;
}

/** 整份读出一个小文件（歌词用）；读不到或超过上限返回 null */
function readBytes(path: string): Uint8Array | null {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const size: number = fs.statSync(file.fd).size;
    if (size <= 0 || size > LRC_MAX_BYTES) {
      return null;
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const read: number = fs.readSync(file.fd, buffer);
    return new Uint8Array(buffer, 0, read);
  } catch (e) {
    return null;
  } finally {
    closeQuietly(file);
  }
}

function toNumberArray(bytes: Uint8Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    out.push(bytes[i]);
  }
  return out;
}

/** GBK 解码（中文 .lrc 常见编码）；不支持就返回空串，调用方退回 UTF-8 的结果 */
function decodeGbk(bytes: Uint8Array): string {
  try {
    const decoder: util.TextDecoder = util.TextDecoder.create('gbk');
    return decoder.decodeToString(bytes);
  } catch (e) {
    return '';
  }
}

function closeQuietly(file: fs.File | null): void {
  if (file === null) {
    return;
  }
  try {
    fs.closeSync(file);
  } catch (e) {
    // 已经关掉了，不处理
  }
}

function unlinkQuietly(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (e) {
    // 文件不在了就当删好了
  }
}
