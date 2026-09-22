import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { LxMusicInfo } from '../music/MusicSearch';
import { SongSideTable } from '../local/SideTable';
import { titleFromFileName, singerFromFileName, isSupportedAudioFile,
  isUnsupportedAudioFile } from '../local/LocalMusic';
import { WebDavClient, WebDavCollectResult } from './WebDavClient';
import { WebDavSettings } from './WebDavSettings';
import { WebDavConfig, WebDavEntry, WebDavTags, WEBDAV_ID_PREFIX, WEBDAV_QUALITY,
  WEBDAV_SOURCE } from './WebDavTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavLibrary';

const DIR_NAME: string = 'webdav_music';
const COVER_DIR: string = 'covers';
const INDEX_FILE: string = 'index.json';
const INDEX_VERSION: number = 1;

/**
 * 扫描时往下走几层
 *
 * 音乐库的组织方式基本都是 `歌手/专辑/歌`（3 层）或 `类型/歌手/专辑/歌`（4 层），
 * 给到 5 层足够，再深多半是网盘里乱七八糟的目录，扫下去只会又慢又乱。
 * 与上限配套的还有 WebDavClient 里的「最多 300 个目录 / 5000 首」硬上限。
 */
const SCAN_DEPTH: number = 5;

/** 读远端标签的并发度：串行太慢，并发太高容易被服务器限流 */
const TAG_CONCURRENCY: number = 3;

/** 云端曲库版本号：扫描 / 补信息后 +1，界面订阅它重新读列表 */
export const K_WEBDAV_VERSION: string = 'webdav_version';
/** 扫描与补信息的进度文案，空闲时是空串 */
export const K_WEBDAV_PROGRESS: string = 'webdav_progress';

/** 一条云端歌曲（= 服务器上的一个音频文件，外加它在本地的缓存状态） */
export interface WebDavSong {
  /**
   * 稳定标识（不含 webdav_ 前缀），同时作为 musicInfo.songmid
   *
   * 由 URL 派生的哈希（见 stableKeyOf），所以**重新扫描后不会变** ——
   * 歌单 / 收藏里的引用、播放缓存的键都靠它保持有效。
   */
  key: string;
  /** 服务器上的绝对 URL（播放、取歌词、取封面都用它） */
  url: string;
  /** 父目录 URL（找同目录的歌词与封面用） */
  folder: string;
  /** 文件名（含后缀） */
  file: string;
  /** 同目录封面下载到沙箱后的文件名（整目录共用一张），没有就是空串 */
  cover: string;
  /** 平台匹配到的封面 URL（没有同目录封面时用它，在线图），没有就是空串 */
  remoteCover: string;
  /** 一起取回来的同名歌词文件名（`<key>.lrc`），没有就是空串 */
  lrc: string;
  /** 在线匹配到的平台歌曲（LxMusicInfo 的 JSON），空串 = 还没匹配到 */
  matchJson: string;
  matchSource: string;
  /** 上次自动匹配的时刻（0 = 从没试过） */
  matchAt: number;
  name: string;
  singer: string;
  album: string;
  /** 毫秒；读不到远端标签时为 0（播放时以播放器报的时长为准） */
  durationMs: number;
  sizeBytes: number;
  /** 最近一次扫描见到它的时刻 */
  seenAt: number;
  /**
   * 最近一次扫描有没有见到它
   *
   * 列表只显示「这次见到了」的歌（服务器上真删掉的就不该留在列表里），
   * 但索引里会**多留一段**还被歌单 / 收藏引用的那些 —— 一次扫描不全
   * （触到上限、某个目录暂时读不到）不该把用户的歌单掏空，见 pruneUnseen。
   */
  seen: boolean;
  /** 远端标签读过了（读不到也算读过），避免每次扫描都重问一遍 */
  tagsDone: boolean;
}

interface WebDavIndex {
  version: number;
  /** 上次扫描的根地址（换了服务器地址就要重扫） */
  root: string;
  scannedAt: number;
  /** 上次扫描是否被上限截断 */
  truncated: boolean;
  songs: WebDavSong[];
  /** 非同步侧表：歌单 id -> 云端歌 key 列表（love 也用这个键） */
  lists: Record<string, string[]>;
}

/** 一次扫描的结果（界面据此说明这次扫到了什么） */
export interface WebDavScanResult {
  /** 扫描后列表里的条数 */
  total: number;
  /** 这次新见到的 */
  added: number;
  /** 这次没见到、且没有任何歌单引用、被清掉的 */
  dropped: number;
  /** 因为超过上限提前停了（界面要说明「只扫了一部分」） */
  truncated: boolean;
  /** 没读成功的目录（权限不够 / 超时） */
  failedFolders: number;
  /** 扫到但格式不支持（ape / wma 之类），报出来才不会被当成「少了歌」 */
  unsupported: number;
}

function emptyScan(): WebDavScanResult {
  return { total: 0, added: 0, dropped: 0, truncated: false, failedFolders: 0, unsupported: 0 };
}

/** 同一个目录下的一批云端歌（封面整目录共用一张，所以按目录分组处理） */
export interface FolderGroup {
  folder: string;
  songs: WebDavSong[];
}

/**
 * 云端音乐库（自己 WebDAV 服务器上的音乐）
 *
 * **没有「导入」这一步**：连上服务器之后，把配置里那个目录（含子目录）扫一遍，
 * 扫到的音频就是这个曲库 —— 点一下就能放，用户不需要先「添加」什么。
 * 扫描结果与它派生出来的本地缓存（封面 / 歌词 / 标签 / 匹配记录）落在沙箱里，
 * 所以下次进应用列表是现成的，只有服务器上真的变了才需要重扫。
 *
 * 与「本地音乐」（LocalMusic）的关系：
 *   - 相同：都往歌单 / 收藏里走**非同步侧表**（SongSideTable），都不参与洛雪同步；
 *     元数据、封面、歌词的取法思路一致（同目录的封面与 `.lrc` 优先，其次平台匹配）。
 *   - 不同：本地音乐是「导入式」（Picker 的 URI 只有临时权限，必须拷进沙箱），
 *     云端音乐**不落音频副本** —— 服务器随时可请求，播放时带 Authorization 头直接流播，
 *     「边听边下」交给播放缓存（AudioCache），最多算一份缓存。
 */
export class WebDavLibrary implements SongSideTable {
  private static instance: WebDavLibrary | null = null;

  static getInstance(): WebDavLibrary {
    if (WebDavLibrary.instance === null) {
      WebDavLibrary.instance = new WebDavLibrary();
    }
    return WebDavLibrary.instance;
  }

  /** 这张侧表持有的条目标记（见 core/local/SideTable） */
  source: string = WEBDAV_SOURCE;

  private dir: string = '';
  private coverDir: string = '';
  private ready: boolean = false;
  private songs: WebDavSong[] = [];
  /** 歌单 id -> 云端歌 key 列表。用 Map 而不是 Record：ArkTS 不允许 delete 运算符 */
  private lists: Map<string, string[]> = new Map<string, string[]>();
  private byKey: Map<string, WebDavSong> = new Map();
  /** url -> song（重扫时按 URL 认出「还是同一首」，把缓存字段接过去） */
  private byUrl: Map<string, WebDavSong> = new Map();
  private root: string = '';
  private scannedAt: number = 0;
  private truncated: boolean = false;
  /** 用户点了取消：扫描 / 补信息的循环在下一步前退出 */
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

  /** 界面用：这次扫描见到的歌，按「目录 + 文件名」排（同一张专辑的歌挨在一起） */
  songsForUi(): SongItem[] {
    const out: SongItem[] = [];
    for (const song of this.songs) {
      if (song.seen) {
        out.push(this.songOf(song));
      }
    }
    return out;
  }

  count(): number {
    return this.songsForUi().length;
  }

  /** 列表里那些歌一共多大（服务器上的大小，不是本地占用） */
  totalBytes(): number {
    let sum: number = 0;
    for (const song of this.songs) {
      if (song.seen) {
        sum += song.sizeBytes;
      }
    }
    return sum;
  }

  /** 上次扫描的根地址（与配置里的地址不一致就说明该重扫了） */
  scanRoot(): string {
    return this.root;
  }

  scanTime(): number {
    return this.scannedAt;
  }

  lastScanTruncated(): boolean {
    return this.truncated;
  }

  /** 服务器上的绝对 URL；条目不在库里返回空串 */
  urlOf(key: string): string {
    const song: WebDavSong | undefined = this.byKey.get(key);
    return song === undefined ? '' : song.url;
  }

  hasKey(key: string): boolean {
    return this.byKey.has(key);
  }

  /** 条目 id（`webdav_<key>`）是否在库里（界面按它隐藏音质 / 下载入口） */
  hasId(id: string): boolean {
    const key: string = this.keyOfId(id);
    return key.length > 0 && this.byKey.has(key);
  }

  songsByKeys(keys: string[]): SongItem[] {
    const out: SongItem[] = [];
    for (const key of keys) {
      const song: WebDavSong | undefined = this.byKey.get(key);
      if (song !== undefined) {
        out.push(this.songOf(song));
      }
    }
    return out;
  }

  keyOfId(id: string): string {
    return id.startsWith(WEBDAV_ID_PREFIX) ? id.substring(WEBDAV_ID_PREFIX.length) : '';
  }

  /** 一条云端歌的展示条目 */
  songOf(song: WebDavSong): SongItem {
    const name: string = song.name.length > 0 ? song.name : stripExt(song.file);
    const img: string = this.coverUrlOf(song);
    const info: LxMusicInfo = {
      name: name,
      singer: song.singer,
      source: WEBDAV_SOURCE,
      songmid: song.key,
      albumName: song.album,
      albumId: '',
      interval: formatInterval(song.durationMs),
      img: img,
      types: [],
      _types: {},
      typeUrl: {},
      lrc: null,
      otherSource: null,
    };
    const item: SongItem = {
      id: `${WEBDAV_ID_PREFIX}${song.key}`,
      name: name,
      singer: song.singer,
      coverUrl: img,
      art: img.length === 0,
      source: WEBDAV_SOURCE,
      // 云端歌没有音质协商；界面把 'webdav' 显示成「云端」
      quality: WEBDAV_QUALITY,
      interval: info.interval,
      musicInfoJson: JSON.stringify(info),
    };
    return item;
  }

  /**
   * 封面地址：同目录下载下来的图优先（精确、离线可看），否则用平台匹配到的在线图
   *
   * 与本地音乐的口径一致（本地歌用内嵌封面），只是云端读不到内嵌封面
   * （官方写明 AVMetadataExtractor 的网络源只能读 metadata），所以退一步用同目录的图片。
   */
  coverUrlOf(song: WebDavSong): string {
    if (song.cover.length > 0) {
      try {
        return fileUri.getUriFromPath(`${this.coverDir}/${song.cover}`);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'cover uri failed: %{public}s', JSON.stringify(e));
      }
    }
    return song.remoteCover;
  }

  /** 库里这条歌已经有的封面地址（匹配时用来判断「还要不要去平台取」） */
  coverUrlOfKey(key: string): string {
    const song: WebDavSong | undefined = this.byKey.get(key);
    return song === undefined ? '' : this.coverUrlOf(song);
  }

  // ------------------------------------------------------------ 歌词与匹配

  /**
   * 读服务器上一起取回来的同名 `.lrc`
   *
   * 落盘时已经统一转成 UTF-8（远端可能是 GBK，在下载那一步就解掉了，见
   * WebDavClient.decodeText），所以这里直接按 UTF-8 读即可。
   */
  lrcTextOf(key: string): string {
    const song: WebDavSong | undefined = this.byKey.get(key);
    if (song === undefined || song.lrc.length === 0) {
      return '';
    }
    try {
      const path: string = `${this.dir}/${song.lrc}`;
      return fs.accessSync(path) ? fs.readTextSync(path) : '';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read lrc failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  matchOf(key: string): LxMusicInfo | null {
    const song: WebDavSong | undefined = this.byKey.get(key);
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
    const song: WebDavSong | undefined = this.byKey.get(key);
    if (song === undefined || infoJson.length === 0) {
      return;
    }
    song.matchSource = source;
    song.matchJson = infoJson;
    song.matchAt = Date.now();
    this.persist();
    this.bumpVersion();
  }

  /** 记下平台匹配到的封面地址（在线图；同目录封面存在时不会用到它） */
  saveRemoteCover(key: string, url: string): void {
    const song: WebDavSong | undefined = this.byKey.get(key);
    if (song === undefined || url.length === 0 || song.remoteCover === url) {
      return;
    }
    song.remoteCover = url;
    this.persist();
    this.bumpVersion();
  }

  /** 自动匹配是不是已经试过了（成功与否都算试过） */
  matchTried(key: string): boolean {
    const song: WebDavSong | undefined = this.byKey.get(key);
    return song !== undefined && song.matchAt > 0;
  }

  /** 记下「自动匹配试过一次了」，避免每放一次就联网搜一次 */
  markMatchTried(key: string): void {
    const song: WebDavSong | undefined = this.byKey.get(key);
    if (song === undefined || song.matchAt > 0) {
      return;
    }
    song.matchAt = Date.now();
    this.persist();
  }

  /** 远端标签里的时长（毫秒，0 = 没读到）；匹配时用它排除同名不同版本 */
  durationMsOf(key: string): number {
    const song: WebDavSong | undefined = this.byKey.get(key);
    return song === undefined ? 0 : song.durationMs;
  }

  // ------------------------------------------------------------ 扫描（这就是「连上就能放」）

  /**
   * 扫描配置里那个目录，把结果变成曲库
   *
   * 两步，先快后慢：
   *   1. **列目录**（递归到 SCAN_DEPTH 层）：拿到全部音频，按 URL 与已有条目对齐 ——
   *      还是同一首就把它的封面 / 歌词 / 标签 / 匹配记录接过去，新的一首也不问任何东西，
   *      所以列表**立刻就能用**（歌名先按 `歌手 - 歌名` 的文件名惯例拆）；
   *   2. **补缓存**（逐目录）：同目录的封面图（整目录共用一张，只下一次）、同名 `.lrc`、
   *      以及远端标签（歌名 / 歌手 / 专辑 / 时长，让平台匹配准很多）。
   *      每补完一批就落盘，中途取消 / 失败都留下已完成的部分。
   */
  async refresh(config: WebDavConfig, onProgress: (text: string) => void): Promise<WebDavScanResult> {
    const result: WebDavScanResult = emptyScan();
    if (!this.ready || config.url.length === 0) {
      return result;
    }
    this.cancelled = false;
    const collected: WebDavCollectResult = await WebDavClient.getInstance()
      .collectAudio(config, config.url, SCAN_DEPTH, onProgress);
    if (this.cancelled) {
      AppStorage.setOrCreate(K_WEBDAV_PROGRESS, '');
      return result;
    }
    result.truncated = collected.truncated;
    result.failedFolders = collected.failedFolders;

    // 1) 对齐已有条目：按 URL 认出「还是同一首」，把本地缓存接过去
    const previous: WebDavSong[] = this.songs;
    const seenUrls: Set<string> = new Set<string>();
    const usedKeys: Set<string> = new Set<string>();
    const next: WebDavSong[] = [];
    const pending: WebDavSong[] = [];
    for (const entry of sortEntriesByUrl(collected.entries)) {
      if (!isSupportedAudioFile(entry.name)) {
        // ape / wma / dsf 这些 AVPlayer 放不了，要报出来（否则看起来像「少了几首」）
        if (isUnsupportedAudioFile(entry.name)) {
          result.unsupported++;
        }
        continue;
      }
      if (seenUrls.has(entry.url)) {
        continue;
      }
      seenUrls.add(entry.url);
      const old: WebDavSong | undefined = this.byUrl.get(entry.url);
      if (old !== undefined) {
        usedKeys.add(old.key);
        old.seen = true;
        old.seenAt = Date.now();
        old.folder = entry.folder;
        old.file = entry.name;
        if (entry.size > 0) {
          old.sizeBytes = entry.size;
        }
        next.push(old);
        if (old.cover.length === 0 || old.lrc.length === 0 || !old.tagsDone) {
          pending.push(old);
        }
        continue;
      }
      const key: string = this.freeKey(entry.url, usedKeys);
      usedKeys.add(key);
      const song: WebDavSong = {
        key: key,
        url: entry.url,
        folder: entry.folder,
        file: entry.name,
        cover: '',
        remoteCover: '',
        lrc: '',
        matchJson: '',
        matchSource: '',
        matchAt: 0,
        name: titleFromFileName(entry.name),
        singer: singerFromFileName(entry.name),
        album: '',
        durationMs: 0,
        sizeBytes: entry.size > 0 ? entry.size : 0,
        seenAt: Date.now(),
        seen: true,
        tagsDone: false,
      };
      next.push(song);
      pending.push(song);
      result.added++;
    }
    // 这次没见到的先标记出来（留不留由 pruneUnseen 决定）
    for (const song of previous) {
      if (!seenUrls.has(song.url)) {
        song.seen = false;
      }
    }
    this.root = config.url;
    this.scannedAt = Date.now();
    this.truncated = collected.truncated;
    this.replaceAll(sortByLocation(next));
    this.persist();
    this.bumpVersion();

    // 2) 补缓存：只对「还没有封面 / 歌词 / 标签」的歌做
    if (pending.length > 0) {
      await this.enrich(config, sortByLocation(pending), onProgress);
    }
    // 3) 清掉「没扫到、也没有任何歌单 / 收藏引用」的条目
    result.dropped = this.pruneUnseen();
    AppStorage.setOrCreate(K_WEBDAV_PROGRESS, '');
    this.persist();
    this.bumpVersion();
    result.total = this.count();
    return result;
  }

  /** 用户取消扫描 / 补信息（当前这一批会做完，从下一批开始停） */
  cancelScan(): void {
    this.cancelled = true;
  }

  isScanning(): boolean {
    const text = AppStorage.get<string>(K_WEBDAV_PROGRESS);
    return text !== undefined && text.length > 0;
  }

  /** 逐目录补封面 / 歌词 / 远端标签 */
  private async enrich(config: WebDavConfig, pending: WebDavSong[],
    onProgress: (text: string) => void): Promise<void> {
    const readTags: boolean = WebDavSettings.getInstance().getReadTags();
    const groups: FolderGroup[] = groupByFolder(pending);
    const total: number = pending.length;
    let done: number = 0;
    for (const group of groups) {
      if (this.cancelled) {
        break;
      }
      let listing: WebDavEntry[] = [];
      try {
        listing = await WebDavClient.getInstance().list(config, group.folder);
      } catch (e) {
        // 目录读不到（权限 / 网络）：这批歌保留文件名形态，不影响播放
        hilog.warn(DOMAIN, TAG, 'list for enrichment failed: %{public}s', (e as Error).message);
        done += group.songs.length;
        continue;
      }
      if (!this.cancelled) {
        await this.attachFolderCover(config, group, listing);
      }
      for (let at = 0; at < group.songs.length; at += TAG_CONCURRENCY) {
        if (this.cancelled) {
          break;
        }
        const chunk: WebDavSong[] = group.songs.slice(at, at + TAG_CONCURRENCY);
        const tasks: Promise<void>[] = [];
        for (const song of chunk) {
          tasks.push(this.enrichOne(config, song, listing, readTags));
        }
        await Promise.all(tasks);
        done += chunk.length;
        const last: WebDavSong = chunk[chunk.length - 1];
        const text: string = `正在读取云端信息 ${done}/${total} `
          + `${last.name.length > 0 ? last.name : last.file}`;
        onProgress(text);
        AppStorage.setOrCreate(K_WEBDAV_PROGRESS, text);
      }
      this.persist();
      this.bumpVersion();
    }
  }

  /**
   * 给一整个目录挂上封面
   *
   * 音乐库的组织方式基本都是「一个专辑一个目录 + 一张 cover.jpg」，所以封面按目录取、
   * 一整个目录共用一张（同一个 URL 只下载一次）。文件名用目录 URL 的短哈希，
   * 这样同一目录里的歌天然共享，删掉其中一首也不会把别人的封面删掉
   * （不再被引用的封面由 sweepOrphans 统一清）。
   */
  private async attachFolderCover(config: WebDavConfig, group: FolderGroup,
    listing: WebDavEntry[]): Promise<void> {
    if (group.songs[0].cover.length > 0) {
      // 这个目录里的歌都已经有封面了（上一次扫描留下的）
      return;
    }
    const coverEntry: WebDavEntry | null = findFolderCover(listing, group.songs[0].file);
    if (coverEntry === null) {
      return;
    }
    const name: string = folderCoverName(group.folder);
    const path: string = `${this.coverDir}/${name}`;
    let present: boolean = false;
    try {
      present = fs.accessSync(path);
    } catch (e) {
      present = false;
    }
    if (!present) {
      try {
        const bytes: ArrayBuffer | null = await WebDavClient.getInstance().fetchBytes(config, coverEntry.url);
        if (bytes === null || bytes.byteLength === 0) {
          return;
        }
        writeBytes(path, bytes);
      } catch (e) {
        hilog.info(DOMAIN, TAG, 'fetch folder cover failed: %{public}s', (e as Error).message);
        return;
      }
    }
    for (const song of group.songs) {
      song.cover = name;
    }
  }

  /**
   * 补一首歌的两样东西：同目录的同名 `.lrc` 与远端标签
   *
   * 两样都是「有更好、没有也能用」，所以任何一步失败都只是记日志，不影响播放。
   */
  private async enrichOne(config: WebDavConfig, song: WebDavSong, listing: WebDavEntry[],
    readTags: boolean): Promise<void> {
    if (song.lrc.length === 0) {
      const lrcEntry: WebDavEntry | null = findSiblingLrc(listing, song.file);
      if (lrcEntry !== null) {
        try {
          const text: string = await WebDavClient.getInstance().fetchText(config, lrcEntry.url);
          if (text.length > 0) {
            const file: string = `${song.key}.lrc`;
            writeText(`${this.dir}/${file}`, text);
            song.lrc = file;
          }
        } catch (e) {
          hilog.info(DOMAIN, TAG, 'fetch lrc failed for %{public}s: %{public}s',
            song.file, (e as Error).message);
        }
      }
    }
    if (!readTags || song.tagsDone) {
      return;
    }
    // 先记「问过了」再发请求：读不到标签的服务器（或格式）不该每次扫描都重问一遍
    song.tagsDone = true;
    const tags: WebDavTags = await WebDavClient.getInstance().readTags(config, song.url);
    if (tags.title.length > 0) {
      song.name = tags.title;
    }
    if (tags.artist.length > 0) {
      song.singer = tags.artist;
    }
    if (tags.album.length > 0) {
      song.album = tags.album;
    }
    if (tags.durationMs > 0) {
      song.durationMs = tags.durationMs;
    }
  }

  /** 取一个没被占用的 key（同一份数据每次扫出来的结果都一样） */
  private freeKey(url: string, used: Set<string>): string {
    const base: string = stableKeyOf(url);
    if (!used.has(base)) {
      return base;
    }
    let seq: number = 2;
    while (used.has(`${base}_${seq}`)) {
      seq++;
    }
    return `${base}_${seq}`;
  }

  // ------------------------------------------------------------ 增删（只动索引，不动服务器）

  /**
   * 清掉「这次没扫到、而且没有被任何歌单 / 收藏引用」的条目
   *
   * 为什么留那些**被引用**的：一次扫描可能不全（触到上限、某个目录超时、网络抖），
   * 顺手把它们连同歌单引用一起清掉，用户会莫名其妙地丢歌。留着的话最坏情况是
   * 歌单里有一条点开报「已经不在云端」—— 服务器恢复了下次扫描就正常了。
   * 而没有引用又没扫到的（服务器上真删了、或改名了）留着只是垃圾，清掉。
   * @returns 被清掉的条数
   */
  private pruneUnseen(): number {
    const referenced: Set<string> = new Set<string>();
    for (const listId of Array.from(this.lists.keys())) {
      for (const key of this.listKeys(listId)) {
        referenced.add(key);
      }
    }
    const remains: WebDavSong[] = [];
    let dropped: number = 0;
    for (const song of this.songs) {
      if (song.seen || referenced.has(song.key)) {
        remains.push(song);
        continue;
      }
      if (song.lrc.length > 0) {
        unlinkQuietly(`${this.dir}/${song.lrc}`);
      }
      dropped++;
    }
    if (dropped > 0) {
      hilog.info(DOMAIN, TAG, 'drop %{public}d unseen cloud songs', dropped);
      this.replaceAll(remains);
      this.sweepOrphans();
    }
    return dropped;
  }

  /** 重建索引里的三张表（songs / byKey / byUrl） */
  private replaceAll(songs: WebDavSong[]): void {
    this.songs = songs;
    this.byKey.clear();
    this.byUrl.clear();
    for (const song of songs) {
      this.byKey.set(song.key, song);
      this.byUrl.set(song.url, song);
    }
  }

  /**
   * 只清「可再生的缓存」（封面 / 歌词 / 标签 / 匹配记录），保留曲库条目
   *
   * 用于「缓存占太多了」：下次扫描 / 播放会重新取歌词、重新匹配封面，
   * 列表本身不受影响，歌单 / 收藏也不用重扫。
   */
  clearCaches(): void {
    for (const song of this.songs) {
      if (song.lrc.length > 0) {
        unlinkQuietly(`${this.dir}/${song.lrc}`);
        song.lrc = '';
      }
      song.cover = '';
      song.remoteCover = '';
      song.matchJson = '';
      song.matchSource = '';
      song.matchAt = 0;
      song.tagsDone = false;
    }
    this.removeCacheFiles();
    this.persist();
    this.bumpVersion();
  }

  private removeCacheFiles(): void {
    try {
      for (const name of fs.listFileSync(this.coverDir)) {
        unlinkQuietly(`${this.coverDir}/${name}`);
      }
      for (const name of fs.listFileSync(this.dir)) {
        if (name.endsWith('.lrc')) {
          unlinkQuietly(`${this.dir}/${name}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clear cache files failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 本地缓存占了多少（封面 + 歌词，设置页展示用） */
  cacheBytes(): number {
    let sum: number = 0;
    try {
      for (const name of fs.listFileSync(this.coverDir)) {
        sum += fileSizeOf(`${this.coverDir}/${name}`);
      }
      for (const name of fs.listFileSync(this.dir)) {
        if (name.endsWith('.lrc')) {
          sum += fileSizeOf(`${this.dir}/${name}`);
        }
      }
    } catch (e) {
      return sum;
    }
    return sum;
  }

  // ------------------------------------------------------------ 歌单 / 收藏侧表

  listKeys(listId: string): string[] {
    const keys: string[] | undefined = this.lists.get(listId);
    return keys === undefined ? [] : keys;
  }

  listCount(listId: string): number {
    return this.listKeys(listId).length;
  }

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
    const text: string | null = this.readText(`${this.dir}/${INDEX_FILE}`);
    if (text !== null) {
      try {
        const raw = JSON.parse(text) as WebDavIndex;
        this.root = typeof raw.root === 'string' ? raw.root : '';
        this.scannedAt = typeof raw.scannedAt === 'number' ? raw.scannedAt : 0;
        this.truncated = raw.truncated === true;
        this.replaceAll(sortByLocation(normalizeSongs(raw.songs)));
        this.lists = normalizeLists(raw.lists);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'parse index failed: %{public}s', JSON.stringify(e));
      }
    }
    this.sweepOrphans();
  }

  /**
   * 清掉没被任何歌引用的封面与歌词
   *
   * 与本地音乐的 sweepOrphans 不同，这里**不检查音频文件**：音频在服务器上，
   * 本地根本没有副本可检查。这里只负责回收封面 / 歌词（目录封面是整目录共用的，
   * 删歌时不能顺手删它，所以统一在这里按「还有没有人引用」来清）。
   */
  private sweepOrphans(): void {
    if (!this.ready) {
      return;
    }
    const known: Set<string> = new Set<string>();
    for (const song of this.songs) {
      if (song.cover.length > 0) {
        known.add(song.cover);
      }
      if (song.lrc.length > 0) {
        known.add(song.lrc);
      }
    }
    try {
      for (const name of fs.listFileSync(this.coverDir)) {
        if (!known.has(name)) {
          unlinkQuietly(`${this.coverDir}/${name}`);
        }
      }
      for (const name of fs.listFileSync(this.dir)) {
        if (name === INDEX_FILE || name === COVER_DIR || known.has(name)) {
          continue;
        }
        if (name.endsWith('.lrc')) {
          unlinkQuietly(`${this.dir}/${name}`);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'sweep dir failed: %{public}s', JSON.stringify(e));
    }
  }

  private persist(): void {
    if (!this.ready) {
      return;
    }
    const index: WebDavIndex = {
      version: INDEX_VERSION,
      root: this.root,
      scannedAt: this.scannedAt,
      truncated: this.truncated,
      songs: this.songs,
      lists: toRecord(this.lists),
    };
    writeText(`${this.dir}/${INDEX_FILE}`, JSON.stringify(index));
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
    const version: number = AppStorage.get<number>(K_WEBDAV_VERSION) ?? 0;
    AppStorage.setOrCreate(K_WEBDAV_VERSION, version + 1);
  }
}

// ------------------------------------------------------------ 判定

/** 这条是不是云端（WebDAV）歌 */
export function isWebDavSong(item: SongItem): boolean {
  return item.source === WEBDAV_SOURCE;
}

// ------------------------------------------------------------ 纯工具

/**
 * 由 URL 派生稳定 key
 *
 * 关键性质是**同一个 URL 永远得到同一个 key**：歌单 / 收藏里存的就是它，
 * 播放缓存的文件名也按它算。重新扫描时只要 URL 没变，引用就一直有效。
 *
 * 用两个 FNV-1a（不同种子）拼起来，凑到 64 位量级 —— 单个 32 位哈希在几千首规模上
 * 撞车概率已经不能忽略（千分之几），而 key 撞车意味着两首歌在歌单里互相认错，
 * 属于「不报错但很怪」的故障。真撞了还有 freeKey 兜底加后缀。
 */
export function stableKeyOf(url: string): string {
  return `${shortHash(url)}${shortHash(`\u0001${url}`)}`;
}

/** 一条歌的展示顺序：先按目录、再按文件名（同一张专辑的歌挨在一起） */
export function sortByLocation(songs: WebDavSong[]): WebDavSong[] {
  const out: WebDavSong[] = songs.slice();
  out.sort(byLocation);
  return out;
}

function byLocation(a: WebDavSong, b: WebDavSong): number {
  const left: string = `${a.folder}\u0000${a.file}`.toLowerCase();
  const right: string = `${b.folder}\u0000${b.file}`.toLowerCase();
  if (left < right) {
    return -1;
  }
  return left > right ? 1 : 0;
}

/** 扫描结果按 URL 排（保证 key 冲突时的后缀是确定的，两次扫出来一样） */
function sortEntriesByUrl(entries: WebDavEntry[]): WebDavEntry[] {
  const out: WebDavEntry[] = entries.slice();
  out.sort((a: WebDavEntry, b: WebDavEntry) => {
    if (a.url < b.url) {
      return -1;
    }
    return a.url > b.url ? 1 : 0;
  });
  return out;
}

/** 按父目录把一批歌分组（封面整目录共用，所以要按目录处理） */
export function groupByFolder(songs: WebDavSong[]): FolderGroup[] {
  const out: FolderGroup[] = [];
  for (const song of songs) {
    let hit: FolderGroup | null = null;
    for (const group of out) {
      if (group.folder === song.folder) {
        hit = group;
        break;
      }
    }
    if (hit === null) {
      out.push({ folder: song.folder, songs: [song] });
    } else {
      hit.songs.push(song);
    }
  }
  return out;
}

/** 目录里的惯例封面文件名（不含后缀），按优先级排 */
const COVER_BASES: string[] = ['cover', 'folder', 'front', 'album', 'albumart', 'artwork', 'thumb'];
const IMAGE_EXTS: string[] = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];

/**
 * 在一个目录的条目里找封面图
 *
 * 先认惯例名（各播放器 / 抓取工具的约定），再认「和某首歌同名的图」
 * （`a.mp3` 旁边放 `a.jpg`）。
 */
export function findFolderCover(listing: WebDavEntry[], anyAudioFile: string): WebDavEntry | null {
  for (const base of COVER_BASES) {
    for (const entry of listing) {
      if (entry.isCollection) {
        continue;
      }
      if (stripExt(entry.name).toLowerCase() === base && IMAGE_EXTS.includes(extOf(entry.name))) {
        return entry;
      }
    }
  }
  const audioBase: string = stripExt(anyAudioFile).toLowerCase();
  for (const entry of listing) {
    if (entry.isCollection) {
      continue;
    }
    if (stripExt(entry.name).toLowerCase() === audioBase && IMAGE_EXTS.includes(extOf(entry.name))) {
      return entry;
    }
  }
  return null;
}

/**
 * 在一个目录的条目里找某首歌的同名歌词
 *
 * 两种写法都认：`song.lrc`（标准）与 `song.mp3.lrc`（有些抓词工具会这么存）。
 */
export function findSiblingLrc(listing: WebDavEntry[], audioFile: string): WebDavEntry | null {
  const audioBase: string = stripExt(audioFile).toLowerCase();
  const full: string = audioFile.toLowerCase();
  for (const entry of listing) {
    if (entry.isCollection || extOf(entry.name) !== '.lrc') {
      continue;
    }
    const base: string = stripExt(entry.name).toLowerCase();
    if (base === audioBase || base === full) {
      return entry;
    }
  }
  return null;
}

/**
 * 目录封面的落盘文件名：目录 URL 的短哈希
 *
 * 同一个目录里的所有歌共用这个名字，所以只下载一次；不同目录（哪怕是不同服务器）
 * 撞名的概率由哈希兜住。
 */
export function folderCoverName(folderUrl: string): string {
  return `f${shortHash(folderUrl)}.jpg`;
}

/** FNV-1a 32 位，输出 base36（够短、够稳，只用来当文件名 / key 的一半） */
export function shortHash(text: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash = hash ^ text.charCodeAt(i);
    // 用 Math.imul 做 32 位乘法：直接乘会超出 2^53 丢精度
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(36);
}

function extOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

function stripExt(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
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

function normalizeSongs(input: WebDavSong[] | undefined): WebDavSong[] {
  if (!Array.isArray(input)) {
    return [];
  }
  const out: WebDavSong[] = [];
  for (const item of input) {
    if (item === null || item === undefined) {
      continue;
    }
    if (typeof item.url !== 'string' || item.url.length === 0) {
      continue;
    }
    // key 缺失 / 空白的旧数据：按 URL 重算一个（稳定 key 是后加的）
    const key: string = typeof item.key === 'string' && item.key.length > 0
      ? item.key : stableKeyOf(item.url);
    out.push({
      key: key,
      url: item.url,
      folder: typeof item.folder === 'string' ? item.folder : '',
      file: typeof item.file === 'string' ? item.file : item.url,
      cover: typeof item.cover === 'string' ? item.cover : '',
      remoteCover: typeof item.remoteCover === 'string' ? item.remoteCover : '',
      lrc: typeof item.lrc === 'string' ? item.lrc : '',
      matchJson: typeof item.matchJson === 'string' ? item.matchJson : '',
      matchSource: typeof item.matchSource === 'string' ? item.matchSource : '',
      matchAt: typeof item.matchAt === 'number' ? item.matchAt : 0,
      name: typeof item.name === 'string' ? item.name : '',
      singer: typeof item.singer === 'string' ? item.singer : '',
      album: typeof item.album === 'string' ? item.album : '',
      durationMs: typeof item.durationMs === 'number' ? item.durationMs : 0,
      sizeBytes: typeof item.sizeBytes === 'number' ? item.sizeBytes : 0,
      seenAt: typeof item.seenAt === 'number' ? item.seenAt : 0,
      // 没扫过就当作「还没见过」：列表先空着，等一次扫描把它点亮
      seen: item.seen === true,
      tagsDone: item.tagsDone === true,
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
function toRecord(input: Map<string, string[]>): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const listId of Array.from(input.keys())) {
    out[listId] = input.get(listId) ?? [];
  }
  return out;
}

function writeText(path: string, text: string): void {
  try {
    const handle: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(handle.fd, text);
    } finally {
      fs.closeSync(handle);
    }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'write text failed: %{public}s', JSON.stringify(e));
  }
}

function writeBytes(path: string, bytes: ArrayBuffer): void {
  const handle: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(handle.fd, bytes);
  } finally {
    fs.closeSync(handle);
  }
}

function fileSizeOf(path: string): number {
  try {
    return fs.statSync(path).size;
  } catch (e) {
    return 0;
  }
}

function unlinkQuietly(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (e) {
    // 文件不在了就当删好了
  }
}
