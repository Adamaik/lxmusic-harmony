import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistSummary, SongItem } from '../player/PlaySession';
import { LxMusicInfo, LxQualityItem, mgImageUrl } from '../music/MusicSearch';
import { musicIdOf } from '../music/MusicId';
import { LOCAL_SOURCE } from './LocalMusic';
import { WEBDAV_SOURCE } from '../webdav/WebDavTypes';
import { duplicateKeyOf, AddMusicResult, LocalLibrary } from '../sync/LocalLibrary';
import { fromLxMusicInfo } from '../sync/SyncConvert';
import { LxListData, LxMusicInfoNew } from '../sync/SyncTypes';
import { SyncManager } from '../sync/SyncManager';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlaylistPort';

/** 文件格式标识：只认这个值，避免把别的 JSON 当歌单文件导 */
export const PLAYLIST_FILE_FORMAT: string = 'listen-playlist-export';
/** 当前写出的版本；以后加字段时递增，导入按 <= 本值兼容 */
export const PLAYLIST_FILE_VERSION: number = 1;

/** 文件大小上限：歌单 JSON 再大也就几 MB，超过这个数说明选错文件了 */
const MAX_FILE_BYTES: number = 32 * 1024 * 1024;
/** 音质由高到低（与 SyncConvert.bestQuality 同序） */
const QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k', '128k'];

/**
 * 导出文件里的一首歌
 *
 * 字段只放**库里真实存在**的那些：在线歌在 `musicInfoJson`（洛雪 SDK 形态）里有什么就写什么，
 * 缺的字段不补默认值（补了会在另一台设备上被当成真实信息，比如把咪咕的相对封面写成空串）。
 * name / singer / source / songId 是核心字段，导入端靠 source + songId 认歌；
 * 其余是重建可播放条目所需要的平台参数（酷狗 hash、QQ 的 mediaMid、咪咕 copyrightId 等）。
 */
export interface ExportSong {
  name: string;
  singer: string;
  source: string;
  songId: string;
  /** 当前展示音质（只是提示；重建时以 qualities 为准，没有 qualities 才用它） */
  quality?: string;
  /** mm:ss */
  interval?: string;
  albumName?: string;
  albumId?: string;
  picUrl?: string;
  hash?: string;
  /** QQ 音乐取流用（与 songId 不同，是数字 id） */
  txSongId?: string;
  strMediaMid?: string;
  albumMid?: string;
  copyrightId?: string;
  /** 全部可用音质（type/size/hash），按库里 _types 原样带出 */
  qualities?: ExportQuality[];
}

/** 导出文件里的一条音质 */
export interface ExportQuality {
  type: string;
  size: string;
  hash?: string;
}

/** 导出文件里的一个歌单 */
export interface ExportPlaylist {
  name: string;
  songs: ExportSong[];
}

/**
 * 导出文件的顶层结构（format + version 固定，其余可向后兼容地加字段）
 *
 * 刻意不带歌单 id：id 是本机的 `user_list_<时间戳>`，换设备后没有意义，
 * 带着反而会诱导导入端去覆盖同 id 的歌单。导入端只按名字建新歌单。
 */
export interface ExportFile {
  format: string;
  version: number;
  /** ISO 8601，便于人看 / 排查 */
  exportedAt: string;
  playlists: ExportPlaylist[];
}

/** 导出结果（ok=false 时 message 是给用户看的原因） */
export interface ExportOutcome {
  ok: boolean;
  canceled: boolean;
  /** 成功时是真机上的 uri（file://docs/...），只用于日志，不展示 */
  uri: string;
  playlists: number;
  songs: number;
  /** 本地歌 / 云端歌：文件不在另一台设备上，导出时明确计数并告知 */
  skippedSongs: number;
  message: string;
}

/** 导入结果 */
export interface ImportFileOutcome {
  ok: boolean;
  canceled: boolean;
  /** 真正新建的歌单数 */
  playlists: number;
  /** 真正加进歌单的歌数 */
  songs: number;
  /** 匹配不到 / 格式不支持 / 歌单里一首都没成功而整张跳过 */
  skippedSongs: number;
  /** 因重名被加后缀的歌单数 */
  renamed: number;
  message: string;
}

/** 解析结果：error 非空表示文件格式不对 */
interface ParsedFile {
  error: string;
  playlists: ExportPlaylist[];
}

/** 构建结果：文件内容 + 被丢掉的本地/云端歌曲数（不进 JSON，只用于提示） */
interface BuildResult {
  file: ExportFile;
  skippedSongs: number;
}

/**
 * 歌单导出 / 导入（换设备迁移，不经过任何服务器）
 *
 * 背景：群反馈（2026-11-21/22）问「不同设备之间怎么导入聆听歌单」。现有同步要洛雪服务端
 * 或电脑端，普通用户没有服务器。这里走系统文件对话框：导出一个 JSON，用户自己传到新设备，
 * 再从文件导入。全程不联网、不碰同步协议。
 *
 * 与同步模块的分工：数据仍由 LocalLibrary 持有，本模块只做「读成 JSON / 从 JSON 建歌单」，
 * 所以导出不会改动任何歌单，导入复用 createPlaylist + addMusicToPlaylist（判重、上行走同一条路）。
 */
export class PlaylistPort {
  private static instance: PlaylistPort | null = null;

  static getInstance(): PlaylistPort {
    if (PlaylistPort.instance === null) {
      PlaylistPort.instance = new PlaylistPort();
    }
    return PlaylistPort.instance;
  }

  private library(): LocalLibrary {
    return SyncManager.getInstance().getLibrary();
  }

  // ------------------------------------------------------------ 导出

  /**
   * 把选中的歌单打包成可落盘的 JSON 文本（纯函数，不弹对话框）
   *
   * 只导出**在线歌**：本地歌记的是本机文件 URI、云端歌记的是自己服务器上的路径，
   * 换设备后都不成立，写进文件只会让新设备上多出一堆打不开的条目。跳过的条数如实计数，
   * 由界面告知用户（「N 首本地/云端歌曲不会导出」）。
   */
  buildExport(ids: string[]): ExportFile {
    return this.buildExportWithStats(ids).file;
  }

  /** 导出数据 + 跳过计数（界面提示要用后者，但计数不能写进文件格式） */
  private buildExportWithStats(ids: string[]): BuildResult {
    const library: LocalLibrary = this.library();
    const summaries: PlaylistSummary[] = library.playlistSummaries();
    const playlists: ExportPlaylist[] = [];
    const seen: Set<string> = new Set<string>();
    let skipped: number = 0;
    for (const id of ids) {
      if (seen.has(id)) {
        continue;
      }
      seen.add(id);
      const builtin: boolean = library.isBuiltinPlaylist(id);
      let name: string = '';
      if (builtin) {
        name = library.favoritePlaylistSummary().name;
      } else {
        for (const summary of summaries) {
          if (summary.id === id) {
            name = summary.name;
            break;
          }
        }
      }
      if (name.length === 0) {
        continue;
      }
      const all: SongItem[] = library.playlistSongs(id);
      const songs: ExportSong[] = [];
      for (const item of all) {
        const song: ExportSong | null = exportSongOf(item);
        if (song !== null) {
          songs.push(song);
        }
      }
      skipped += all.length - songs.length;
      playlists.push({ name: name, songs: songs });
    }
    const file: ExportFile = {
      format: PLAYLIST_FILE_FORMAT,
      version: PLAYLIST_FILE_VERSION,
      exportedAt: new Date().toISOString(),
      playlists: playlists,
    };
    return { file: file, skippedSongs: skipped };
  }

  /**
   * 弹出系统保存对话框，把歌单写成 JSON
   *
   * `suggestedName` 只是默认文件名（单个歌单 = 歌单名，多选 = 「聆听歌单-时间」），
   * 用户可以改路径与名字。取消保存返回 canceled=true，不当作错误弹提示。
   */
  async exportToFile(context: common.Context, ids: string[],
    suggestedName: string): Promise<ExportOutcome> {
    const built: BuildResult = this.buildExportWithStats(ids);
    const payload: ExportFile = built.file;
    let songs: number = 0;
    for (const playlist of payload.playlists) {
      songs += playlist.songs.length;
    }
    const skipped: number = built.skippedSongs;
    if (payload.playlists.length === 0) {
      return this.exportFail('没有可导出的歌单', skipped);
    }
    if (songs === 0) {
      return this.exportFail('选中的歌单里没有可导出的在线歌曲\n（本地音乐和云端音乐不能跨设备迁移）', skipped);
    }
    // 不缩进：歌单动辄上千首，缩进会把文件放大一倍多；格式本身已经是可读的键值结构
    const text: string = JSON.stringify(payload);
    const fileName: string = `${safeFileStem(suggestedName)}.json`;
    let uri: string = '';
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
      if (uris.length === 0) {
        return this.exportCanceled(skipped);
      }
      uri = uris[0];
    } catch (e) {
      const error = e as BusinessError;
      if (isCancel(error)) {
        return this.exportCanceled(skipped);
      }
      hilog.warn(DOMAIN, TAG, 'save dialog failed: %{public}s', JSON.stringify(e));
      return this.exportFail(`打不开系统保存对话框（${error.code} ${error.message}）`, skipped);
    }
    try {
      writeText(uri, text);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'write export failed: %{public}s', JSON.stringify(e));
      return this.exportFail('写入文件失败，请换个位置再试', skipped);
    }
    let message: string = `已导出 ${payload.playlists.length} 个歌单、共 ${songs} 首歌曲`;
    if (skipped > 0) {
      message += `\n${skipped} 首本地/云端歌曲（或缺少歌曲信息）没有导出`;
    }
    return {
      ok: true,
      canceled: false,
      uri: uri,
      playlists: payload.playlists.length,
      songs: songs,
      skippedSongs: skipped,
      message: message,
    };
  }

  private exportFail(message: string, skipped: number): ExportOutcome {
    return {
      ok: false,
      canceled: false,
      uri: '',
      playlists: 0,
      songs: 0,
      skippedSongs: skipped,
      message: message,
    };
  }

  private exportCanceled(skipped: number): ExportOutcome {
    return {
      ok: false,
      canceled: true,
      uri: '',
      playlists: 0,
      songs: 0,
      skippedSongs: skipped,
      message: '已取消导出',
    };
  }

  // ------------------------------------------------------------ 导入

  /** 选择 JSON 文件并导入 */
  async importFromFile(context: common.Context): Promise<ImportFileOutcome> {
    let uri: string = '';
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) {
        return this.importCanceled();
      }
      uri = uris[0];
    } catch (e) {
      const error = e as BusinessError;
      if (isCancel(error)) {
        return this.importCanceled();
      }
      hilog.warn(DOMAIN, TAG, 'select dialog failed: %{public}s', JSON.stringify(e));
      return this.importFail(`打不开系统文件选择器（${error.code} ${error.message}）`);
    }
    return this.importFromUri(uri);
  }

  /**
   * 从文件 uri 导入（picker 给的 `file://docs/...`）
   *
   * 读取用 openSync + stat + readSync + TextDecoder：`readTextSync` 只认沙箱路径，
   * 不认 picker 的 uri（同一个坑见 core/book/BookEngine.importFromUri）。
   */
  importFromUri(uri: string): ImportFileOutcome {
    let text: string = '';
    try {
      text = readText(uri);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read import failed: %{public}s', JSON.stringify(e));
      return this.importFail(`读不了这个文件：${(e as Error).message}`);
    }
    const parsed: ParsedFile = parseFile(text);
    if (parsed.error.length > 0) {
      return this.importFail(parsed.error);
    }
    return this.applyImport(parsed.playlists);
  }

  /**
   * 把解析出来的歌单建进本地库
   *
   * 三条策略（都对应群反馈里最容易被问的点）：
   *   1. **重名不覆盖**：已有同名歌单就加「 (2)」「 (3)」，绝不把用户原来的歌单清掉；
   *   2. 认歌先按 `source + songId`，再按「歌名 + 歌手」（`duplicateKeyOf`，与歌单判重同一口径）；
   *      都认不到时才用文件里带的元数据重建——这样本机已有的歌会沿用本机的封面 / 音质；
   *   3. 一首都认不出来的歌单整张不建，避免留下空歌单；计数如实返回。
   */
  private applyImport(playlists: ExportPlaylist[]): ImportFileOutcome {
    const library: LocalLibrary = this.library();
    const index: Map<string, SongItem> = buildMatchIndex(library);
    const names: Set<string> = new Set<string>();
    for (const summary of library.playlistSummaries()) {
      names.add(normalizeName(summary.name));
    }
    names.add(normalizeName(library.favoritePlaylistSummary().name));

    let created: number = 0;
    let added: number = 0;
    /** 文件里有、但本机曲库里认不出来（也没法用文件元数据重建）的条目 */
    let unmatched: number = 0;
    /** 因为「这首歌已经在歌单里」被跳过的条目（keepDuplicates 后只剩侧表那一类） */
    let duplicated: number = 0;
    let renamed: number = 0;
    let emptyPlaylists: number = 0;
    for (const playlist of playlists) {
      const baseName: string = playlist.name.trim().length > 0 ? playlist.name.trim() : '导入的歌单';
      const resolved: SongItem[] = [];
      for (const raw of playlist.songs) {
        const song: SongItem | null = resolveSong(raw, index);
        if (song === null) {
          unmatched++;
          continue;
        }
        resolved.push(song);
      }
      if (resolved.length === 0) {
        emptyPlaylists++;
        continue;
      }
      const unique: string = uniqueName(baseName, names);
      if (unique !== baseName) {
        renamed++;
      }
      names.add(normalizeName(unique));
      const id: string = library.createPlaylist(unique);
      /**
       * keepDuplicates = true：导出刻意保留了歌单里的重复条目，导入必须原样还原。
       * 走默认的「按 id + 歌名判重」会把它们静默吃掉（换机迁移就少歌），
       * 而且还会混进「重复跳过」的计数里，用户根本查不出来。
       */
      const result: AddMusicResult = library.addMusicToPlaylist(id, resolved, true);
      added += result.added;
      duplicated += result.skipped;
      created++;
    }

    if (created === 0) {
      const hint: string = emptyPlaylists > 0 ? '（歌曲都没能匹配上）' : '';
      return {
        ok: false,
        canceled: false,
        playlists: 0,
        songs: 0,
        skippedSongs: unmatched + duplicated,
        renamed: renamed,
        message: `这个文件里没有可导入的歌曲${hint}`,
      };
    }
    let message: string = `已导入 ${created} 个歌单、共 ${added} 首歌曲`;
    // 「没匹配上」与「重复跳过」分开说：以前合成一句「未匹配或重复」，用户看不出到底哪边出了问题
    if (unmatched > 0) {
      message += `\n${unmatched} 首没能导入（本机曲库里没匹配到这首歌）`;
    }
    if (duplicated > 0) {
      message += `\n${duplicated} 首重复已跳过`;
    }
    if (renamed > 0) {
      message += `\n${renamed} 个同名歌单已自动改名（原歌单没有动）`;
    }
    if (emptyPlaylists > 0) {
      message += `\n${emptyPlaylists} 个空歌单已忽略`;
    }
    return {
      ok: true,
      canceled: false,
      playlists: created,
      songs: added,
      skippedSongs: unmatched + duplicated,
      renamed: renamed,
      message: message,
    };
  }

  private importFail(message: string): ImportFileOutcome {
    return {
      ok: false,
      canceled: false,
      playlists: 0,
      songs: 0,
      skippedSongs: 0,
      renamed: 0,
      message: message,
    };
  }

  private importCanceled(): ImportFileOutcome {
    return {
      ok: false,
      canceled: true,
      playlists: 0,
      songs: 0,
      skippedSongs: 0,
      renamed: 0,
      message: '已取消导入',
    };
  }
}

// ---------------------------------------------------------------- 纯函数

/**
 * 一条 SongItem -> 导出条目；不能迁移的返回 null
 *
 * 判据与同步一致（SyncConvert.parseOldMusicInfo）：必须有真实 musicInfoJson、
 * 有平台 source、有 songmid，并且不是本地 / 云端歌。
 */
function exportSongOf(item: SongItem): ExportSong | null {
  if (item.source === LOCAL_SOURCE || item.source === WEBDAV_SOURCE) {
    return null;
  }
  if (item.musicInfoJson === undefined || item.musicInfoJson.length === 0) {
    return null;
  }
  let old: LxMusicInfo;
  try {
    old = JSON.parse(item.musicInfoJson) as LxMusicInfo;
  } catch (e) {
    return null;
  }
  if (old === null || old === undefined) {
    return null;
  }
  const source: string = typeof old.source === 'string' && old.source.length > 0 ? old.source : item.source;
  const songId: string = old.songmid !== undefined && old.songmid !== null ? String(old.songmid) : '';
  if (source.length === 0 || songId.length === 0) {
    return null;
  }
  const song: ExportSong = {
    name: old.name !== undefined && old.name !== null ? old.name : item.name,
    singer: old.singer !== undefined && old.singer !== null ? old.singer : item.singer,
    source: source,
    songId: songId,
  };
  if (item.quality.length > 0) {
    song.quality = item.quality;
  }
  if (old.interval !== undefined && old.interval !== null && old.interval.length > 0) {
    song.interval = old.interval;
  }
  if (old.albumName !== undefined && old.albumName !== null && old.albumName.length > 0) {
    song.albumName = old.albumName;
  }
  if (old.albumId !== undefined && old.albumId !== null && old.albumId.length > 0) {
    song.albumId = old.albumId;
  }
  if (old.img !== undefined && old.img !== null && old.img.length > 0) {
    song.picUrl = old.img;
  }
  if (old.hash !== undefined && old.hash.length > 0) {
    song.hash = old.hash;
  }
  if (old.songId !== undefined && old.songId !== null && String(old.songId).length > 0) {
    song.txSongId = String(old.songId);
  }
  if (old.strMediaMid !== undefined && old.strMediaMid.length > 0) {
    song.strMediaMid = old.strMediaMid;
  }
  if (old.albumMid !== undefined && old.albumMid.length > 0) {
    song.albumMid = old.albumMid;
  }
  if (old.copyrightId !== undefined && old.copyrightId.length > 0) {
    song.copyrightId = old.copyrightId;
  }
  const qualities: ExportQuality[] = [];
  if (old._types !== undefined && old._types !== null) {
    for (const key of Object.keys(old._types)) {
      const entry: LxQualityItem = old._types[key];
      if (entry === null || entry === undefined) {
        continue;
      }
      const quality: ExportQuality = { type: key, size: entry.size !== undefined ? entry.size : '' };
      if (entry.hash !== undefined && entry.hash.length > 0) {
        quality.hash = entry.hash;
      }
      qualities.push(quality);
    }
  }
  if (qualities.length > 0) {
    song.qualities = qualities;
  }
  return song;
}

/** 本机已有歌曲的匹配索引：source+songId 与 歌名+歌手 两套键 */
function buildMatchIndex(library: LocalLibrary): Map<string, SongItem> {
  const index: Map<string, SongItem> = new Map<string, SongItem>();
  const data: LxListData = library.listData();
  const online: LxMusicInfoNew[] = [];
  for (const info of data.loveList) {
    online.push(info);
  }
  for (const info of data.defaultList) {
    online.push(info);
  }
  for (const item of data.userList) {
    for (const info of item.list) {
      online.push(info);
    }
  }
  for (const info of online) {
    const item: SongItem = fromLxMusicInfo(info);
    putIndex(index, item);
  }
  return index;
}

function putIndex(index: Map<string, SongItem>, item: SongItem): void {
  const songId: string = songIdOf(item);
  if (songId.length > 0) {
    const key: string = sourceKey(item.source, songId);
    if (!index.has(key)) {
      index.set(key, item);
    }
  }
  const nameKey: string = nameKeyOf(item.name, item.singer);
  if (nameKey.length > 0 && !index.has(nameKey)) {
    index.set(nameKey, item);
  }
}

/** 从 musicInfoJson 里取平台 songmid（本地/云端歌的 songmid 是本地 key，不参与匹配） */
function songIdOf(item: SongItem): string {
  if (item.source === LOCAL_SOURCE || item.source === WEBDAV_SOURCE) {
    return '';
  }
  if (item.musicInfoJson === undefined || item.musicInfoJson.length === 0) {
    return '';
  }
  try {
    const old = JSON.parse(item.musicInfoJson) as LxMusicInfo;
    return old.songmid !== undefined && old.songmid !== null ? String(old.songmid) : '';
  } catch (e) {
    return '';
  }
}

function sourceKey(source: string, songId: string): string {
  return `id\u0001${source.toLowerCase()}\u0001${songId}`;
}

function nameKeyOf(name: string, singer: string): string {
  const key: string = duplicateKeyOf(name, singer);
  return key.length > 0 ? `name\u0001${key}` : '';
}

/**
 * 导出条目 -> 可加入歌单的 SongItem
 *
 * 顺序：本机已有（source+songId）→ 本机已有（歌名+歌手）→ 用文件里的元数据重建。
 * 只有「本地/云端 source」或「没有 songId 也没匹配上」时才返回 null（计入跳过）。
 */
function resolveSong(raw: ExportSong, index: Map<string, SongItem>): SongItem | null {
  const source: string = raw.source !== undefined && raw.source !== null ? raw.source : '';
  const songId: string = raw.songId !== undefined && raw.songId !== null ? String(raw.songId) : '';
  if (source === LOCAL_SOURCE || source === WEBDAV_SOURCE) {
    return null;
  }
  const name: string = raw.name !== undefined && raw.name !== null ? raw.name : '';
  const singer: string = raw.singer !== undefined && raw.singer !== null ? raw.singer : '';
  if (source.length > 0 && songId.length > 0) {
    const hit: SongItem | undefined = index.get(sourceKey(source, songId));
    if (hit !== undefined) {
      return hit;
    }
  }
  const byName: string = nameKeyOf(name, singer);
  if (byName.length > 0) {
    const hit: SongItem | undefined = index.get(byName);
    if (hit !== undefined) {
      return hit;
    }
  }
  const old: LxMusicInfo | null = rebuildInfo(raw);
  return old === null ? null : songItemOf(old, raw.quality);
}

/** 用导出字段重建洛雪 SDK 形态的 musicInfo（播放链路直接吃它） */
function rebuildInfo(raw: ExportSong): LxMusicInfo | null {
  const source: string = raw.source !== undefined ? raw.source : '';
  const songmid: string = raw.songId !== undefined ? String(raw.songId) : '';
  const name: string = raw.name !== undefined ? raw.name : '';
  if (source.length === 0 || songmid.length === 0 || name.length === 0) {
    return null;
  }
  const types: LxQualityItem[] = [];
  const typeMap: Record<string, LxQualityItem> = {};
  if (raw.qualities !== undefined && raw.qualities !== null) {
    const qualityList: ExportQuality[] = raw.qualities;
    for (const quality of qualityList) {
      if (quality === null || quality === undefined || quality.type.length === 0) {
        continue;
      }
      const item: LxQualityItem = { type: quality.type, size: quality.size };
      if (quality.hash !== undefined && quality.hash.length > 0) {
        item.hash = quality.hash;
      }
      types.push(item);
      typeMap[item.type] = item;
    }
  }
  // 文件里只有 quality（没有 qualities）时按一条音质处理；两者都没有就给 128k，
  // 与「同步回来的歌默认 128k」一致（见 SyncConvert.bestQuality）。
  if (types.length === 0) {
    const fallback: string = raw.quality !== undefined && raw.quality.length > 0 ? raw.quality : '128k';
    const item: LxQualityItem = { type: fallback, size: '' };
    types.push(item);
    typeMap[fallback] = item;
  }
  const old: LxMusicInfo = {
    name: name,
    singer: raw.singer !== undefined ? raw.singer : '',
    source: source,
    songmid: songmid,
    albumName: raw.albumName !== undefined ? raw.albumName : '',
    albumId: raw.albumId !== undefined ? raw.albumId : '',
    interval: raw.interval !== undefined ? raw.interval : '',
    img: raw.picUrl !== undefined ? raw.picUrl : '',
    types: types,
    _types: typeMap,
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
  // 平台必需字段：缺了就别硬写空串 —— 源脚本普遍用 `?? songmid` 回退，
  // 空串会让回退失效（同一处坑见 MusicSearch.LxMusicInfo.hash 的注释）
  if (source === 'kg' && raw.hash !== undefined && raw.hash.length > 0) {
    old.hash = raw.hash;
  }
  if (source === 'tx') {
    if (raw.txSongId !== undefined && raw.txSongId.length > 0) {
      old.songId = raw.txSongId;
    }
    if (raw.strMediaMid !== undefined && raw.strMediaMid.length > 0) {
      old.strMediaMid = raw.strMediaMid;
    }
    if (raw.albumMid !== undefined && raw.albumMid.length > 0) {
      old.albumMid = raw.albumMid;
    }
  }
  if (source === 'mg' && raw.copyrightId !== undefined && raw.copyrightId.length > 0) {
    old.copyrightId = raw.copyrightId;
  }
  return old;
}

/** 重建出来的条目：id / 封面 / 音质与库里的口径保持一致 */
function songItemOf(old: LxMusicInfo, displayQuality?: string): SongItem {
  const picUrl: string = old.img !== undefined && old.img !== null ? old.img : '';
  const coverUrl: string = old.source === 'mg' ? mgImageUrl(picUrl) : picUrl;
  return {
    id: musicIdOf(old),
    name: old.name,
    singer: old.singer,
    coverUrl: coverUrl,
    art: coverUrl.length === 0,
    source: old.source,
    quality: pickQuality(old, displayQuality),
    interval: old.interval !== undefined && old.interval !== null ? old.interval : '',
    musicInfoJson: JSON.stringify(old),
  };
}

function pickQuality(old: LxMusicInfo, displayQuality?: string): string {
  if (displayQuality !== undefined) {
    const wanted: string = displayQuality;
    if (wanted.length > 0 && old._types[wanted] !== undefined) {
      return wanted;
    }
  }
  for (const quality of QUALITY_ORDER) {
    if (old._types[quality] !== undefined) {
      return quality;
    }
  }
  const keys: string[] = Object.keys(old._types);
  return keys.length > 0 ? keys[0] : '128k';
}

/** 解析并校验文件；任何格式问题都转成一句用户能看懂的话 */
function parseFile(text: string): ParsedFile {
  const raw: string = text.trim();
  if (raw.length === 0) {
    return { error: '文件是空的', playlists: [] };
  }
  let data: ExportFile;
  try {
    data = JSON.parse(raw) as ExportFile;
  } catch (e) {
    return { error: '不是有效的 JSON 文件', playlists: [] };
  }
  if (data === null || data === undefined) {
    return { error: '不是有效的歌单文件', playlists: [] };
  }
  if (data.format !== PLAYLIST_FILE_FORMAT) {
    return { error: '这不是「聆听」导出的歌单文件', playlists: [] };
  }
  if (typeof data.version !== 'number' || data.version <= 0) {
    return { error: '歌单文件缺少版本号，无法导入', playlists: [] };
  }
  if (data.version > PLAYLIST_FILE_VERSION) {
    return {
      error: `这个文件来自更新版本的聆听（文件版本 ${data.version}），请先升级应用`,
      playlists: [],
    };
  }
  if (!Array.isArray(data.playlists)) {
    return { error: '歌单文件里没有歌单列表', playlists: [] };
  }
  const entries: ExportPlaylist[] = data.playlists;
  const playlists: ExportPlaylist[] = [];
  for (const entry of entries) {
    if (entry === null || entry === undefined) {
      continue;
    }
    const name: string = typeof entry.name === 'string' ? entry.name : '';
    const songs: ExportSong[] = [];
    /**
     * `songs` 必须是数组：手改过的文件里写成 `"songs": 123` 时，直接 `for...of` 会抛
     * TypeError（`is not iterable`），绕过下面那些「人话错误」，用户只看到一句系统报错。
     * 这里当空处理 —— 整张歌单没歌就按「空歌单已忽略」计数，行为与「songs: []」一致。
     */
    if (Array.isArray(entry.songs)) {
      const songList: ExportSong[] = entry.songs;
      for (const song of songList) {
        const clean: ExportSong | null = sanitizeSong(song);
        if (clean !== null) {
          songs.push(clean);
        }
      }
    }
    playlists.push({ name: name, songs: songs });
  }
  if (playlists.length === 0) {
    return { error: '文件里没有可导入的歌单', playlists: [] };
  }
  return { error: '', playlists: playlists };
}

/**
 * 把 JSON 里的一条歌洗成可信结构
 *
 * 文件是用户自己传过来的，可能被手改过、也可能来自更早/更晚的版本，字段类型不能信：
 * 这里只认字符串、只留已知字段，`qualities` 里缺 type 的条目直接丢。这样后面的
 * 重建逻辑（读 `_types`、拼 musicInfo）不会因为一个数字类型的字段在真机上抛异常。
 */
function sanitizeSong(input: ExportSong): ExportSong | null {
  if (input === null || input === undefined) {
    return null;
  }
  if (typeof input.name !== 'string' || input.name.length === 0) {
    return null;
  }
  if (typeof input.source !== 'string' || input.source.length === 0) {
    return null;
  }
  if (typeof input.songId !== 'string' || input.songId.length === 0) {
    return null;
  }
  const song: ExportSong = {
    name: input.name,
    singer: typeof input.singer === 'string' ? input.singer : '',
    source: input.source,
    songId: input.songId,
  };
  if (typeof input.quality === 'string' && input.quality.length > 0) {
    song.quality = input.quality;
  }
  if (typeof input.interval === 'string' && input.interval.length > 0) {
    song.interval = input.interval;
  }
  if (typeof input.albumName === 'string' && input.albumName.length > 0) {
    song.albumName = input.albumName;
  }
  if (typeof input.albumId === 'string' && input.albumId.length > 0) {
    song.albumId = input.albumId;
  }
  if (typeof input.picUrl === 'string' && input.picUrl.length > 0) {
    song.picUrl = input.picUrl;
  }
  if (typeof input.hash === 'string' && input.hash.length > 0) {
    song.hash = input.hash;
  }
  if (typeof input.txSongId === 'string' && input.txSongId.length > 0) {
    song.txSongId = input.txSongId;
  }
  if (typeof input.strMediaMid === 'string' && input.strMediaMid.length > 0) {
    song.strMediaMid = input.strMediaMid;
  }
  if (typeof input.albumMid === 'string' && input.albumMid.length > 0) {
    song.albumMid = input.albumMid;
  }
  if (typeof input.copyrightId === 'string' && input.copyrightId.length > 0) {
    song.copyrightId = input.copyrightId;
  }
  if (input.qualities !== undefined && input.qualities !== null && Array.isArray(input.qualities)) {
    const list: ExportQuality[] = input.qualities;
    const qualities: ExportQuality[] = [];
    for (const entry of list) {
      if (entry === null || entry === undefined) {
        continue;
      }
      if (typeof entry.type !== 'string' || entry.type.length === 0) {
        continue;
      }
      const quality: ExportQuality = {
        type: entry.type,
        size: typeof entry.size === 'string' ? entry.size : '',
      };
      if (typeof entry.hash === 'string' && entry.hash.length > 0) {
        quality.hash = entry.hash;
      }
      qualities.push(quality);
    }
    if (qualities.length > 0) {
      song.qualities = qualities;
    }
  }
  return song;
}

// ---------------------------------------------------------------- 文件与文本

/** 读出 picker uri 的全文（UTF-8，去掉 BOM） */
function readText(uri: string): string {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const size: number = fs.statSync(file.fd).size;
    if (size <= 0) {
      throw new Error('文件是空的');
    }
    if (size > MAX_FILE_BYTES) {
      throw new Error(`文件太大（${Math.round(size / 1024 / 1024)} MB）`);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    /**
     * `readSync` 不保证一次读满：picker 给的 uri 走的是沙箱外的 provider（可能是网盘 /
     * 文档服务的流式实现），大文件被截在半路只读到一部分时，JSON.parse 会报
     * 「不是有效的 JSON 文件」，用户换台手机导入就无解。这里循环读到 size 为止。
     *
     * 注意 readSync 没有「写进 buffer 的哪个位置」这个参数，只能每次读进临时 buffer
     * 再拼到尾部 —— 直接用 options.offset 会变成「跳过文件前 N 字节」，越读越错。
     */
    let read: number = fs.readSync(file.fd, buffer);
    while (read > 0 && read < size) {
      const rest: ArrayBuffer = new ArrayBuffer(size - read);
      const got: number = fs.readSync(file.fd, rest);
      if (got <= 0) {
        break;
      }
      new Uint8Array(buffer).set(new Uint8Array(rest, 0, got), read);
      read += got;
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const text: string = decoder.decodeToString(new Uint8Array(buffer, 0, read));
    return text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close file failed: %{public}s', JSON.stringify(e));
      }
    }
  }
}

/** 往 picker 返回的文件 uri 里写文本（先截断，避免旧内容留在尾部） */
function writeText(uri: string, text: string): void {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close export file failed: %{public}s', JSON.stringify(e));
      }
    }
  }
}

/** 用户取消：不同系统版本有的给空数组、有的抛 BusinessError */
function isCancel(error: BusinessError): boolean {
  if (error === null || error === undefined) {
    return false;
  }
  const message: string = error.message !== undefined ? error.message.toLowerCase() : '';
  return error.code === 13900042 || message.includes('cancel') || message.includes('取消');
}

/** 文件名去掉路径非法字符并限长（系统对话框里用户还能改） */
function safeFileStem(name: string): string {
  const cleaned: string = name.replace(/[\\/:*?"<>|\n\r\t]/g, ' ').trim();
  const stem: string = cleaned.length > 0 ? cleaned : '聆听歌单';
  return stem.length > 40 ? stem.substring(0, 40) : stem;
}

function normalizeName(name: string): string {
  return name.trim().toLowerCase();
}

/** 重名加「 (2)」「 (3)」；不覆盖已有歌单 */
function uniqueName(base: string, taken: Set<string>): string {
  if (!taken.has(normalizeName(base))) {
    return base;
  }
  let seq: number = 2;
  while (seq < 1000) {
    const candidate: string = `${base} (${seq})`;
    if (!taken.has(normalizeName(candidate))) {
      return candidate;
    }
    seq++;
  }
  return `${base} (${Date.now()})`;
}
