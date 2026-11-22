/**
 * 网盘配置同步的「文件格式」与「本地数据转换」
 *
 * 背景（群反馈 2026-11-22，邦邦不吃香菜 + 小冰）：现有同步要洛雪服务端 / 洛雪电脑端，
 * 普通用户没有服务器，两台手机又不能直连。小冰建议「看看『阅读』的 webdav，网盘传配置
 * 文件」——配置本身只有几十 KB，网盘就够。本文件定义那个文件的格式，以及
 * 「本地库 ↔ 文件」的转换；网络、时机、界面在 WebDavConfigSync 里。
 *
 * 与 core/local/PlaylistPort.ets 的关系：
 *   - 文件里的歌曲字段与它**完全同构**（name / singer / source / songId / qualities…），
 *     这样两份文件在语义上可互相看懂；
 *   - 转换逻辑是照着它的 exportSongOf / sanitizeSong / resolveSong / rebuildInfo / uniqueName
 *     **重写的一份**，不是不想复用：PlaylistPort 依赖 SyncManager，而本模块是被
 *     SyncManager 引用的（见 WebDavConfigSync.init），直接 import 会形成
 *     SyncManager → WebDavConfigSync → PlaylistPort → SyncManager 的循环依赖。
 *     纯函数层面能共用的（duplicateKeyOf / fromLxMusicInfo / musicIdOf / mgImageUrl）都共用了。
 *   - 口径保持一致：只搬在线歌（本地歌记本机 URI、云端歌记自己服务器路径，换设备不成立），
 *     重名歌单加「 (2)」不覆盖，歌先按 source+songId 认、再按歌名+歌手认。
 */

import { PlaylistSummary, SongItem } from '../player/PlaySession';
import { LxMusicInfo, LxQualityItem, mgImageUrl } from '../music/MusicSearch';
import { musicIdOf } from '../music/MusicId';
import { LOCAL_SOURCE } from '../local/LocalMusic';
import { AddMusicResult, duplicateKeyOf, LocalLibrary } from '../sync/LocalLibrary';
import { fromLxMusicInfo } from '../sync/SyncConvert';
import { LxListData, LxMusicInfoNew } from '../sync/SyncTypes';
import { toMD5 } from '../sync/SyncCrypto';
import { CONFIG_SYNC_DEFAULT_DIR, WEBDAV_SOURCE } from './WebDavTypes';
import {
  DEFAULT_SOURCE_VALUES,
  EXTEND_QUALITYS,
  MAIN_QUALITY_LABELS,
  MAIN_QUALITYS,
  PLAYER_MOTION_LABELS,
  PLAYER_MOTION_LEVELS,
  PlaySettings,
} from '../settings/PlaySettings';

/** 文件格式标识：只认这个值，避免把别的 JSON 当成聆听的配置 */
export const CONFIG_SYNC_FORMAT: string = 'listen-config-sync';
/** 当前写出的格式版本；以后加字段递增，读取端按 <= 本值兼容 */
export const CONFIG_SYNC_VERSION: number = 1;
/** 网盘目录下的固定文件名（两台设备约定同一个名字才能互相找到） */
export const CONFIG_SYNC_FILE_NAME: string = 'listen-config.json';

/** 音质由高到低（与 PlaylistPort / SyncConvert 同序） */
const QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k', '128k'];

/** 文件里的一首歌（字段与 PlaylistPort.ExportSong 同构） */
export interface ConfigSyncSong {
  name: string;
  singer: string;
  source: string;
  songId: string;
  /** 当前展示音质（只是提示；重建时以 qualities 为准） */
  quality?: string;
  /** mm:ss */
  interval?: string;
  albumName?: string;
  albumId?: string;
  picUrl?: string;
  hash?: string;
  /** QQ 音乐取流用（数字 id，与 songId 不同） */
  txSongId?: string;
  strMediaMid?: string;
  albumMid?: string;
  copyrightId?: string;
  /** 全部可用音质（type/size/hash） */
  qualities?: ConfigSyncQuality[];
}

/** 文件里的一条音质 */
export interface ConfigSyncQuality {
  type: string;
  size: string;
  hash?: string;
}

/** 文件里的一个歌单（不带本地 id：id 是本机的 user_list_<时间戳>，换设备没意义） */
export interface ConfigSyncPlaylist {
  name: string;
  songs: ConfigSyncSong[];
}

/**
 * 用户设置（音质 / 播放偏好）
 *
 * 每一项都可缺省：缺省 = 这一项不参与同步（恢复时保持本机值）。这样以后删掉某一项
 * 也不会让老文件失效。
 */
export interface ConfigSyncSettings {
  quality?: string;
  extendQuality?: boolean;
  extendQualityType?: string;
  playWithOthers?: boolean;
  showMiniLyric?: boolean;
  lyricBlur?: boolean;
  lyricCentered?: boolean;
  lyricFontSize?: number;
  lyricKeepScreenOn?: boolean;
  desktopLyric?: boolean;
  bluetoothLyric?: boolean;
  autoMatchLyric?: boolean;
  autoResumeAfterInterrupt?: boolean;
  autoPauseHeadsetOff?: boolean;
  playerMotion?: string;
  defaultSource?: string;
  autoSourceSwitch?: boolean;
}

/** 文件顶层结构 */
export interface ConfigSyncFile {
  format: string;
  version: number;
  /** ISO 8601：冲突判断就以它为准（谁更新谁算「新」） */
  exportedAt: string;
  /** 导出设备名（只用于提示与排查，不参与任何判断） */
  sourceDevice?: string;
  playlists: ConfigSyncPlaylist[];
  settings?: ConfigSyncSettings;
}

/** 本地快照（文件 + 界面上要报的计数） */
export interface ConfigSnapshot {
  file: ConfigSyncFile;
  playlists: number;
  songs: number;
  /** 本地歌 / 云端歌 / 缺元数据的歌：不会进文件，恢复端要能说明 */
  skippedSongs: number;
}

/** 解析结果：error 非空表示不能用于恢复 */
export interface ConfigParseResult {
  error: string;
  file: ConfigSyncFile | null;
}

/** 恢复（合并）的结果；歌单与歌曲数都是「真正写进本地库」的数量 */
export interface ConfigMergeOutcome {
  playlists: number;
  songs: number;
  skippedSongs: number;
  renamed: number;
  emptyPlaylists: number;
}

// ---------------------------------------------------------------- 本地 -> 文件

/**
 * 把本机歌单 + 播放设置打成一个配置快照
 *
 * 只导出**用户歌单**：内置的「我的收藏」在协议上是 loveList，LocalLibrary 没有对外的
 * 「往收藏里加一首」入口（addMusicToPlaylist 只认 userList），硬塞会写坏收藏的覆盖语义，
 * 所以这一版不碰它 —— 界面文案里写清楚（收藏 / 试听列表仍走洛雪同步或歌单导出）。
 */
export function buildConfigSnapshot(deviceName: string): ConfigSnapshot {
  const library: LocalLibrary = LocalLibrary.getInstance();
  const summaries: PlaylistSummary[] = library.playlistSummaries();
  const playlists: ConfigSyncPlaylist[] = [];
  let songs: number = 0;
  let skipped: number = 0;
  for (const summary of summaries) {
    const name: string = summary.name.trim();
    if (name.length === 0) {
      continue;
    }
    const all: SongItem[] = library.playlistSongs(summary.id);
    const kept: ConfigSyncSong[] = [];
    for (const item of all) {
      const song: ConfigSyncSong | null = configSongOf(item);
      if (song !== null) {
        kept.push(song);
      }
    }
    skipped += all.length - kept.length;
    // 一首都搬不了的歌单也写进去：它是「这张歌单存在过」的证据，恢复端会忽略空歌单
    playlists.push({ name: name, songs: kept });
    songs += kept.length;
  }
  const file: ConfigSyncFile = {
    format: CONFIG_SYNC_FORMAT,
    version: CONFIG_SYNC_VERSION,
    exportedAt: new Date().toISOString(),
    sourceDevice: deviceName,
    playlists: playlists,
    settings: captureSettings(),
  };
  return { file: file, playlists: playlists.length, songs: songs, skippedSongs: skipped };
}

/** 当前播放设置 -> 文件里的设置项（全部显式写出，方便对端判断「这一项要恢复」） */
export function captureSettings(): ConfigSyncSettings {
  const settings = PlaySettings.getInstance();
  return {
    quality: settings.getQuality(),
    extendQuality: settings.isExtendQuality(),
    extendQualityType: settings.getExtendQualityType(),
    playWithOthers: settings.isPlayWithOthers(),
    showMiniLyric: settings.isShowMiniLyric(),
    lyricBlur: settings.isLyricBlur(),
    lyricCentered: settings.isLyricCentered(),
    lyricFontSize: settings.getLyricFontSize(),
    lyricKeepScreenOn: settings.isLyricKeepScreenOn(),
    desktopLyric: settings.isDesktopLyric(),
    bluetoothLyric: settings.isBluetoothLyric(),
    autoMatchLyric: settings.getAutoMatchLyric(),
    autoResumeAfterInterrupt: settings.isAutoResumeAfterInterrupt(),
    autoPauseHeadsetOff: settings.isAutoPauseHeadsetOff(),
    playerMotion: settings.getPlayerMotionLevel(),
    defaultSource: settings.getDefaultSource(),
    autoSourceSwitch: settings.isAutoSourceSwitch(),
  };
}

/** 一条 SongItem -> 文件条目；不能跨设备迁移的返回 null（判据同 PlaylistPort.exportSongOf） */
function configSongOf(item: SongItem): ConfigSyncSong | null {
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
  const song: ConfigSyncSong = {
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
  const qualities: ConfigSyncQuality[] = [];
  if (old._types !== undefined && old._types !== null) {
    for (const key of Object.keys(old._types)) {
      const entry: LxQualityItem = old._types[key];
      if (entry === null || entry === undefined) {
        continue;
      }
      const quality: ConfigSyncQuality = { type: key, size: entry.size !== undefined ? entry.size : '' };
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

// ---------------------------------------------------------------- 文件 -> 本地

/**
 * 解析并校验网盘上的文件
 *
 * 文件是另一台设备（或用户手改过）写来的，字段类型一律不信：只认已知的键、只收正确类型，
 * 认不出的东西丢掉而不是抛异常 —— 同步失败要能说清原因，不能让一个坏字段把应用弄崩。
 */
export function parseConfigFile(text: string): ConfigParseResult {
  const raw: string = text.trim();
  if (raw.length === 0) {
    return { error: '网盘上的配置文件是空的', file: null };
  }
  let data: ConfigSyncFile;
  try {
    data = JSON.parse(raw) as ConfigSyncFile;
  } catch (e) {
    return { error: '网盘上的配置不是有效的 JSON', file: null };
  }
  if (data === null || data === undefined) {
    return { error: '网盘上的配置内容为空', file: null };
  }
  if (data.format !== CONFIG_SYNC_FORMAT) {
    return { error: `网盘上的 ${CONFIG_SYNC_FILE_NAME} 不是「聆听」的配置文件`, file: null };
  }
  if (typeof data.version !== 'number' || data.version <= 0) {
    return { error: '配置文件缺少版本号，无法恢复', file: null };
  }
  if (data.version > CONFIG_SYNC_VERSION) {
    return { error: `这个配置来自更新版本的聆听（版本 ${data.version}），请先升级应用`, file: null };
  }
  if (!Array.isArray(data.playlists)) {
    return { error: '配置文件里没有歌单列表', file: null };
  }
  const entries: ConfigSyncPlaylist[] = data.playlists;
  const playlists: ConfigSyncPlaylist[] = [];
  for (const entry of entries) {
    if (entry === null || entry === undefined) {
      continue;
    }
    const name: string = typeof entry.name === 'string' ? entry.name : '';
    const songs: ConfigSyncSong[] = [];
    if (entry.songs !== undefined && entry.songs !== null && Array.isArray(entry.songs)) {
      const list: ConfigSyncSong[] = entry.songs;
      for (const song of list) {
        const clean: ConfigSyncSong | null = sanitizeSong(song);
        if (clean !== null) {
          songs.push(clean);
        }
      }
    }
    playlists.push({ name: name, songs: songs });
  }
  const file: ConfigSyncFile = {
    format: CONFIG_SYNC_FORMAT,
    version: data.version,
    exportedAt: typeof data.exportedAt === 'string' ? data.exportedAt : '',
    sourceDevice: typeof data.sourceDevice === 'string' ? data.sourceDevice : '',
    playlists: playlists,
  };
  if (data.settings !== undefined && data.settings !== null) {
    file.settings = sanitizeSettings(data.settings);
  }
  return { error: '', file: file };
}

/** 把一条歌洗成可信结构（同 PlaylistPort.sanitizeSong） */
function sanitizeSong(input: ConfigSyncSong): ConfigSyncSong | null {
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
  const song: ConfigSyncSong = {
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
    const list: ConfigSyncQuality[] = input.qualities;
    const qualities: ConfigSyncQuality[] = [];
    for (const entry of list) {
      if (entry === null || entry === undefined) {
        continue;
      }
      if (typeof entry.type !== 'string' || entry.type.length === 0) {
        continue;
      }
      const quality: ConfigSyncQuality = {
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

/** 设置项逐个按类型收；取值不在白名单里的直接丢（PlaySettings 的 setter 也会再挡一次） */
function sanitizeSettings(input: ConfigSyncSettings): ConfigSyncSettings {
  const out: ConfigSyncSettings = {};
  if (typeof input.quality === 'string' && MAIN_QUALITYS.includes(input.quality)) {
    out.quality = input.quality;
  }
  if (typeof input.extendQuality === 'boolean') {
    out.extendQuality = input.extendQuality;
  }
  if (typeof input.extendQualityType === 'string' && EXTEND_QUALITYS.includes(input.extendQualityType)) {
    out.extendQualityType = input.extendQualityType;
  }
  if (typeof input.playWithOthers === 'boolean') {
    out.playWithOthers = input.playWithOthers;
  }
  if (typeof input.showMiniLyric === 'boolean') {
    out.showMiniLyric = input.showMiniLyric;
  }
  if (typeof input.lyricBlur === 'boolean') {
    out.lyricBlur = input.lyricBlur;
  }
  if (typeof input.lyricCentered === 'boolean') {
    out.lyricCentered = input.lyricCentered;
  }
  if (typeof input.lyricFontSize === 'number' && Number.isFinite(input.lyricFontSize)) {
    out.lyricFontSize = input.lyricFontSize;
  }
  if (typeof input.lyricKeepScreenOn === 'boolean') {
    out.lyricKeepScreenOn = input.lyricKeepScreenOn;
  }
  if (typeof input.desktopLyric === 'boolean') {
    out.desktopLyric = input.desktopLyric;
  }
  if (typeof input.bluetoothLyric === 'boolean') {
    out.bluetoothLyric = input.bluetoothLyric;
  }
  if (typeof input.autoMatchLyric === 'boolean') {
    out.autoMatchLyric = input.autoMatchLyric;
  }
  if (typeof input.autoResumeAfterInterrupt === 'boolean') {
    out.autoResumeAfterInterrupt = input.autoResumeAfterInterrupt;
  }
  if (typeof input.autoPauseHeadsetOff === 'boolean') {
    out.autoPauseHeadsetOff = input.autoPauseHeadsetOff;
  }
  if (typeof input.playerMotion === 'string' && PLAYER_MOTION_LEVELS.includes(input.playerMotion)) {
    out.playerMotion = input.playerMotion;
  }
  if (typeof input.defaultSource === 'string' && DEFAULT_SOURCE_VALUES.includes(input.defaultSource)) {
    out.defaultSource = input.defaultSource;
  }
  if (typeof input.autoSourceSwitch === 'boolean') {
    out.autoSourceSwitch = input.autoSourceSwitch;
  }
  return out;
}

/**
 * 把文件里的设置写进 PlaySettings（每个 setter 自己会落盘并刷 AppStorage）
 *
 * 只写文件里带了的项：缺省的项保持本机值，所以老文件 / 部分字段的文件都能恢复。
 * 返回真正尝试写入的项数（用于提示文案）。
 */
export function applySettings(settings: ConfigSyncSettings): number {
  const target = PlaySettings.getInstance();
  let applied: number = 0;
  if (settings.quality !== undefined) {
    target.setQuality(settings.quality);
    applied++;
  }
  if (settings.extendQuality !== undefined) {
    target.setExtendQuality(settings.extendQuality);
    applied++;
  }
  if (settings.extendQualityType !== undefined) {
    target.setExtendQualityType(settings.extendQualityType);
    applied++;
  }
  if (settings.playWithOthers !== undefined) {
    target.setPlayWithOthers(settings.playWithOthers);
    applied++;
  }
  if (settings.showMiniLyric !== undefined) {
    target.setShowMiniLyric(settings.showMiniLyric);
    applied++;
  }
  if (settings.lyricBlur !== undefined) {
    target.setLyricBlur(settings.lyricBlur);
    applied++;
  }
  if (settings.lyricCentered !== undefined) {
    target.setLyricCentered(settings.lyricCentered);
    applied++;
  }
  if (settings.lyricFontSize !== undefined) {
    target.setLyricFontSize(settings.lyricFontSize);
    applied++;
  }
  if (settings.lyricKeepScreenOn !== undefined) {
    target.setLyricKeepScreenOn(settings.lyricKeepScreenOn);
    applied++;
  }
  if (settings.desktopLyric !== undefined) {
    target.setDesktopLyric(settings.desktopLyric);
    applied++;
  }
  if (settings.bluetoothLyric !== undefined) {
    target.setBluetoothLyric(settings.bluetoothLyric);
    applied++;
  }
  if (settings.autoMatchLyric !== undefined) {
    target.setAutoMatchLyric(settings.autoMatchLyric);
    applied++;
  }
  if (settings.autoResumeAfterInterrupt !== undefined) {
    target.setAutoResumeAfterInterrupt(settings.autoResumeAfterInterrupt);
    applied++;
  }
  if (settings.autoPauseHeadsetOff !== undefined) {
    target.setAutoPauseHeadsetOff(settings.autoPauseHeadsetOff);
    applied++;
  }
  if (settings.playerMotion !== undefined) {
    target.setPlayerMotionLevel(settings.playerMotion);
    applied++;
  }
  if (settings.defaultSource !== undefined) {
    target.setDefaultSource(settings.defaultSource);
    applied++;
  }
  if (settings.autoSourceSwitch !== undefined) {
    target.setAutoSourceSwitch(settings.autoSourceSwitch);
    applied++;
  }
  return applied;
}

/**
 * 把文件里的歌单合并进本地库
 *
 * 三条策略与 PlaylistPort.applyImport 一致（群反馈里最容易被问的点）：
 *   1. **重名不覆盖**：已有同名歌单就加「 (2)」「 (3)」，本机原来的歌单一个字都不动；
 *   2. 认歌先按 source+songId，再按「歌名 + 歌手」（duplicateKeyOf，与歌单判重同一口径），
 *      都认不到时才用文件里的元数据重建 —— 本机已有的歌会沿用本机的封面 / 音质；
 *   3. 一首都认不出来的歌单整张不建，避免留下一堆空歌单；计数如实返回。
 *
 * 恢复是「加」不是「替换」：本功能不做静默双写，也就不能删本地的东西。
 */
export function mergePlaylists(playlists: ConfigSyncPlaylist[]): ConfigMergeOutcome {
  const library: LocalLibrary = LocalLibrary.getInstance();
  const index: Map<string, SongItem> = buildMatchIndex(library);
  const names: Set<string> = new Set<string>();
  for (const summary of library.playlistSummaries()) {
    names.add(normalizeName(summary.name));
  }
  names.add(normalizeName(library.favoritePlaylistSummary().name));

  let created: number = 0;
  let added: number = 0;
  let skipped: number = 0;
  let renamed: number = 0;
  let empty: number = 0;
  for (const playlist of playlists) {
    const baseName: string = playlist.name.trim().length > 0 ? playlist.name.trim() : '网盘上的歌单';
    const resolved: SongItem[] = [];
    for (const raw of playlist.songs) {
      const song: SongItem | null = resolveSong(raw, index);
      if (song === null) {
        skipped++;
        continue;
      }
      resolved.push(song);
    }
    if (resolved.length === 0) {
      empty++;
      continue;
    }
    const unique: string = uniqueName(baseName, names);
    if (unique !== baseName) {
      renamed++;
    }
    names.add(normalizeName(unique));
    const id: string = library.createPlaylist(unique);
    // addMusicToPlaylist 自己会按 id + 歌名·歌手判重，返回的 skipped 是「歌单里已经有了」
    const result: AddMusicResult = library.addMusicToPlaylist(id, resolved);
    added += result.added;
    skipped += result.skipped;
    created++;
  }
  return {
    playlists: created,
    songs: added,
    skippedSongs: skipped,
    renamed: renamed,
    emptyPlaylists: empty,
  };
}

/** 本机已有歌曲的匹配索引：source+songId 与 歌名+歌手 两套键（同 PlaylistPort.buildMatchIndex） */
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

function sourceKey(source: string, songId: string): string {
  return `id\u0001${source.toLowerCase()}\u0001${songId}`;
}

function nameKeyOf(name: string, singer: string): string {
  const key: string = duplicateKeyOf(name, singer);
  return key.length > 0 ? `name\u0001${key}` : '';
}

/** 从 musicInfoJson 里取平台 songmid（本地 / 云端歌不参与匹配） */
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

/** 文件条目 -> 可加入歌单的 SongItem（顺序同 PlaylistPort.resolveSong） */
function resolveSong(raw: ConfigSyncSong, index: Map<string, SongItem>): SongItem | null {
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

/** 用文件字段重建洛雪 SDK 形态的 musicInfo（播放链路直接吃它，同 PlaylistPort.rebuildInfo） */
function rebuildInfo(raw: ConfigSyncSong): LxMusicInfo | null {
  const source: string = raw.source !== undefined ? raw.source : '';
  const songmid: string = raw.songId !== undefined ? String(raw.songId) : '';
  const name: string = raw.name !== undefined ? raw.name : '';
  if (source.length === 0 || songmid.length === 0 || name.length === 0) {
    return null;
  }
  const types: LxQualityItem[] = [];
  const typeMap: Record<string, LxQualityItem> = {};
  if (raw.qualities !== undefined && raw.qualities !== null) {
    const qualityList: ConfigSyncQuality[] = raw.qualities;
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
  // 平台必需字段：缺了就别硬写空串（源脚本普遍用 `?? songmid` 回退，空串会让回退失效）
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

/** 重建出来的条目：id / 封面 / 音质与库里的口径一致（同 PlaylistPort.songItemOf） */
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

function normalizeName(name: string): string {
  return name.trim().toLowerCase();
}

/** 重名加「 (2)」「 (3)」；绝不覆盖已有歌单 */
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

// ---------------------------------------------------------------- 判断与展示

/** 文件里一共多少首歌 */
export function countSongs(file: ConfigSyncFile): number {
  let total: number = 0;
  for (const playlist of file.playlists) {
    total += playlist.songs.length;
  }
  return total;
}

/**
 * 内容指纹（不含 exportedAt / sourceDevice）
 *
 * 用途：判断「本机内容」与「网盘内容」是不是同一份，避免每次启动都白传一遍。
 * 不走 JSON.stringify 的哈希 —— 两端的对象字段插入顺序不一定一致（本地快照与解析出来的
 * 对象由不同的赋值顺序构造），顺序一变哈希就变，会误判成「有改动」。这里按固定字段、
 * 固定顺序拼一份规范文本再哈希。
 */
export function fingerprintOf(file: ConfigSyncFile): string {
  const parts: string[] = [];
  for (const playlist of file.playlists) {
    parts.push(`P\u0001${playlist.name}`);
    for (const song of playlist.songs) {
      parts.push(`S\u0001${song.source}\u0001${song.songId}\u0001${song.name}\u0001${song.singer}`);
    }
  }
  let settings: ConfigSyncSettings = {};
  if (file.settings !== undefined) {
    settings = file.settings;
  }
  parts.push('C\u0001' + settingText(settings));
  return toMD5(parts.join('\n'));
}

/** 设置项的规范文本（顺序固定，未设置的项写空） */
function settingText(settings: ConfigSyncSettings): string {
  const cells: string[] = [];
  cells.push(textOf(settings.quality));
  cells.push(boolOf(settings.extendQuality));
  cells.push(textOf(settings.extendQualityType));
  cells.push(boolOf(settings.playWithOthers));
  cells.push(boolOf(settings.showMiniLyric));
  cells.push(boolOf(settings.lyricBlur));
  cells.push(boolOf(settings.lyricCentered));
  cells.push(settings.lyricFontSize === undefined ? '' : `${settings.lyricFontSize}`);
  cells.push(boolOf(settings.lyricKeepScreenOn));
  cells.push(boolOf(settings.desktopLyric));
  cells.push(boolOf(settings.bluetoothLyric));
  cells.push(boolOf(settings.autoMatchLyric));
  cells.push(boolOf(settings.autoResumeAfterInterrupt));
  cells.push(boolOf(settings.autoPauseHeadsetOff));
  cells.push(textOf(settings.playerMotion));
  cells.push(textOf(settings.defaultSource));
  cells.push(boolOf(settings.autoSourceSwitch));
  return cells.join('\u0001');
}

function textOf(value: string | undefined): string {
  return value === undefined ? '' : value;
}

function boolOf(value: boolean | undefined): string {
  return value === undefined ? '' : (value ? '1' : '0');
}

/**
 * 网盘上的配置是不是比本机「上次同步过的」更新
 *
 * 冲突策略就用这一条：谁新听谁的 —— 但**只提示，不自动覆盖**。本机 lastSyncedAt 是
 * 上一次成功上传 / 恢复时的 exportedAt；网盘的 exportedAt 比它大 = 另一台设备在这之后
 * 又写过一次。本机没有同步戳（新设备第一次开自动同步）时，网盘上已有的那份一律算「更新」，
 * 免得拿本机的初始空配置把另一台设备的歌单覆盖掉。
 */
export function isRemoteNewer(file: ConfigSyncFile | null, lastSyncedAt: string): boolean {
  if (file === null) {
    return false;
  }
  const remote: number = Date.parse(file.exportedAt);
  if (Number.isNaN(remote)) {
    return false;
  }
  const local: number = Date.parse(lastSyncedAt);
  if (Number.isNaN(local)) {
    // 本机还没跟网盘对齐过（新设备第一次开自动同步 / 清过同步戳）：
    // 网盘上已有的那份一律按「更新」处理 —— 宁可让用户点一次恢复，也不能拿本机
    // 初始的空配置把另一台设备的歌单覆盖掉。
    return true;
  }
  return remote > local + 1000;
}

/** 设置项的一句话摘要（恢复预览用；太长的列表截断） */
export function describeSettings(settings: ConfigSyncSettings | undefined): string {
  if (settings === undefined) {
    return '文件里没有带设置';
  }
  const parts: string[] = [];
  if (settings.quality !== undefined) {
    parts.push(`音质 ${qualityLabel(settings.quality)}`);
  }
  if (settings.extendQuality !== undefined) {
    parts.push(`拓展音质${settings.extendQuality ? '开' : '关'}`);
  }
  if (settings.playerMotion !== undefined) {
    parts.push(`播放页动效 ${motionLabel(settings.playerMotion)}`);
  }
  if (settings.playWithOthers !== undefined) {
    parts.push(`同时播放${settings.playWithOthers ? '开' : '关'}`);
  }
  if (settings.desktopLyric !== undefined) {
    parts.push(`桌面歌词${settings.desktopLyric ? '开' : '关'}`);
  }
  if (parts.length === 0) {
    return '文件里没有带设置';
  }
  return parts.join(' · ');
}

function qualityLabel(value: string): string {
  const at: number = MAIN_QUALITYS.indexOf(value);
  return at >= 0 && at < MAIN_QUALITY_LABELS.length ? MAIN_QUALITY_LABELS[at] : value;
}

function motionLabel(value: string): string {
  const at: number = PLAYER_MOTION_LEVELS.indexOf(value);
  return at >= 0 && at < PLAYER_MOTION_LABELS.length ? PLAYER_MOTION_LABELS[at] : value;
}

/**
 * 服务器地址 + 目录 -> 目录的完整 URL
 *
 * 目录可以是相对服务器地址的子目录（默认 `listen-config`），也可以是绝对路径
 * （`/dav/config`），甚至整条 URL（从别处拷来的）。三种写法都有人用，别让用户猜。
 * 每段做一次 encodeURIComponent：中文 / 空格目录名在 WebDAV 上必须转义。
 */
export function buildFolderUrl(base: string, dir: string): string {
  const trimmedBase: string = stripTrailingSlashes(base.trim());
  const trimmedDir: string = dir.trim();
  if (trimmedDir.length === 0) {
    return `${trimmedBase}/${CONFIG_SYNC_DEFAULT_DIR}`;
  }
  const lower: string = trimmedDir.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return stripTrailingSlashes(trimmedDir);
  }
  if (trimmedDir.startsWith('/')) {
    return `${trimmedBase}${encodePath(trimmedDir)}`;
  }
  return `${trimmedBase}/${encodePath(trimmedDir)}`;
}

/** 目录 + 固定文件名 -> 文件 URL */
export function configFileUrl(folderUrl: string): string {
  return `${stripTrailingSlashes(folderUrl)}/${CONFIG_SYNC_FILE_NAME}`;
}

function stripTrailingSlashes(value: string): string {
  let text: string = value;
  while (text.length > 1 && text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/** 逐段转义（已转义的 %xx 不要二次转义：先解一次再转） */
function encodePath(path: string): string {
  const segments: string[] = path.split('/');
  const out: string[] = [];
  for (const segment of segments) {
    if (segment.length === 0) {
      continue;
    }
    let plain: string = segment;
    try {
      plain = decodeURIComponent(segment);
    } catch (e) {
      plain = segment;
    }
    out.push(encodeURIComponent(plain));
  }
  return out.length === 0 ? '' : `/${out.join('/')}`;
}
