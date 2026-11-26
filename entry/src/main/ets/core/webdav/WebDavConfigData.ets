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
import {
  AddMusicResult,
  duplicateKeyOf,
  LocalLibrary,
  normalizeDislikeRules,
} from '../sync/LocalLibrary';
import {
  ListenHistoryExport,
  ListenLog,
  ListenRecord,
  ListenSong,
  intervalMs,
  listenItemId,
} from '../history/ListenLog';
import { fromLxMusicInfo } from '../sync/SyncConvert';
import { LxListData, LxMusicInfoNew } from '../sync/SyncTypes';
import { toMD5 } from '../sync/SyncCrypto';
import { CONFIG_SYNC_DEFAULT_DIR, WEBDAV_SOURCE } from './WebDavTypes';
import {
  AudioEffectSettings,
  EQ_GAIN_MAX,
  EQ_GAIN_MIN,
  EQ_PRESETS,
} from '../settings/AudioEffectSettings';
import { AppearanceSettings } from '../settings/AppearanceSettings';
import { ListenSettings } from '../settings/ListenSettings';
import { RecommendSettings } from '../settings/RecommendSettings';
import { BookPlaySettings } from '../book/BookPlaySettings';
import {
  DOWNLOAD_QUALITY_VALUES,
  DownloadSettings,
  NAME_FORMATS,
} from '../download/DownloadSettings';
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
/**
 * 当前写出的格式版本；以后加字段递增，读取端按 <= 本值兼容。
 *
 * v2（2026-11-27）：同步范围从「歌单 + 播放设置」扩到「个性化数据」——
 * 收藏、听歌流水（播放历史 / 最近播放 / 回响都由它重建）、不感兴趣名单，
 * 以及外观 / 听书 / 推荐 / 下载 / 音效等设置。新增字段全部可选：
 * v1 老文件照样能读（缺的字段保持本机值），旧版本 App 读到 v2 会提示先升级，
 * 这是有意的 —— 旧版本不认识这些字段，恢复后再上传会把它们丢掉。
 */
export const CONFIG_SYNC_VERSION: number = 2;
/** 网盘目录下的固定文件名（两台设备约定同一个名字才能互相找到） */
export const CONFIG_SYNC_FILE_NAME: string = 'listen-config.json';

/** 收藏最多搬多少首（配置文件要保持「几十 KB 级」，超出的截断） */
const CONFIG_SYNC_FAVORITES_MAX: number = 2000;
/** 听歌流水最多搬多少条（一条 ≈ 几十字节；回响只回看最近一年，够用） */
const CONFIG_SYNC_HISTORY_MAX: number = 300;
/** 不感兴趣规则最多搬多少条 */
const CONFIG_SYNC_DISLIKE_MAX: number = 500;

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
 * 用户设置（音质 / 播放偏好 / 外观 / 听书 / 推荐 / 下载 / 音效）
 *
 * 每一项都可缺省：缺省 = 这一项不参与同步（恢复时保持本机值）。这样以后删掉某一项
 * 也不会让老文件失效；v1 老文件里只有前 17 项，新字段缺省即可。
 *
 * 有意不同步的：WebDAV 账号 / 密码（安全）、QQ 音乐登录态（凭据）、下载目录 URI
 * （本机路径）、深浅模式 colorMode（跟随系统，且应用需要 context）、听歌识曲来源
 * （设备能力）。这些在 SyncSettingsView 的说明里也写清楚。
 */
export interface ConfigSyncSettings {
  // ---- 播放（v1 既有） ----
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
  // ---- 外观（v2 新增；colorMode 不同步，理由见上） ----
  materialLevel?: number;
  coverRadius?: number;
  followHand?: boolean;
  // ---- 听书（v2 新增） ----
  hideListenTab?: boolean;
  bookSpeed?: number;
  bookSkipIntroSec?: number;
  bookSkipOutroSec?: number;
  // ---- 推荐 / 下载（v2 新增） ----
  recommendSource?: string;
  downloadQuality?: string;
  downloadNameFormat?: string;
  downloadMarkQuality?: boolean;
  // ---- 音效 EQ（v2 新增，用户明确要求纳入同步） ----
  eqEnabled?: boolean;
  eqPreset?: string;
  eqGains?: number[];
}

/**
 * 文件里的一条听歌流水（一次「听这首歌」的经历）
 *
 * 只搬「歌 + 时间 + 时长」：ListenLog 的记录按「歌名 + 歌手」认歌（songKey），
 * 不带设备侧 id。这样两台设备的同一首歌会正确合并成一条流水，回响与最近播放
 * 都由它重建。
 */
export interface ConfigSyncHistoryRecord {
  name: string;
  singer: string;
  /** 开播时刻（毫秒时间戳）；0 = 旧版历史（无时间） */
  startedAt: number;
  /** 实际听了多久（毫秒） */
  playedMs: number;
  /** 播放时 AVPlayer 报的真实总时长（毫秒，0 = 未知） */
  durationMs: number;
}

/** 听歌流水：歌曲元数据去重（同 ListenLog 的 songs 字典），records 新的在前 */
export interface ConfigSyncHistory {
  songs: ConfigSyncSong[];
  records: ConfigSyncHistoryRecord[];
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
  /**
   * 收藏（只含在线歌，与歌单同一口径：本地歌 / 云端歌跨设备不成立，跳过）。
   * v2 新增；v1 文件没有这一项 → 恢复时保持本机收藏不动。
   */
  favorites?: ConfigSyncSong[];
  /** 听歌流水（v2 新增）：播放历史 / 最近播放 / 回响都从它重建 */
  history?: ConfigSyncHistory;
  /** 「不感兴趣」名单（v2 新增，规则串与洛雪 dislike 同格式：name@singer） */
  dislikes?: string[];
}

/** 本地快照（文件 + 界面上要报的计数） */
export interface ConfigSnapshot {
  file: ConfigSyncFile;
  playlists: number;
  songs: number;
  favorites: number;
  history: number;
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
  /** 并入收藏的新歌数 */
  favorites: number;
  /** 并入的听歌流水条数 */
  history: number;
  /** 并入的「不感兴趣」规则数 */
  dislikes: number;
}

// ---------------------------------------------------------------- 本地 -> 文件

/**
 * 把本机歌单 + 收藏 + 听歌流水 + 不感兴趣 + 个性化设置打成一个配置快照
 *
 * 跨设备只搬「在线歌 + 与设备无关的数据」：
 *   - 歌单 / 收藏里属于本地歌（本机 URI）或云端歌（自己服务器路径）的条目跳过，计数如实报；
 *   - 听歌流水只搬歌名+歌手+时间+时长；播放历史 / 最近播放 / 回响都由它重建；
 *   - 设置里有意的例外：WebDAV 账号密码、QQ 登录态、下载目录、深浅模式、听歌识曲来源
 *     —— 都是凭据 / 本机路径 / 系统级能力，换了设备不该照搬。
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
  // 收藏：与歌单同一口径，只搬在线歌（本地歌 / 云端歌跨设备不成立）
  const favorites: ConfigSyncSong[] = [];
  for (const item of library.favoriteSongs()) {
    if (favorites.length >= CONFIG_SYNC_FAVORITES_MAX) {
      break;
    }
    const song: ConfigSyncSong | null = configSongOf(item);
    if (song !== null) {
      favorites.push(song);
    }
  }
  /**
   * 听歌流水：播放历史 / 最近播放 / 回响三处都由 ListenLog 这一份流水重建，
   * 所以跨设备搬它就够了（不需要另存「最近播放」列表）。
   */
  const history: ConfigSyncHistory = historyOf(ListenLog.getInstance().exportHistory(CONFIG_SYNC_HISTORY_MAX));
  // 「不感兴趣」名单：规则串（name@singer，与洛雪 dislike 同格式）
  const dislikes: string[] = [];
  for (const rule of library.dislikeRuleList()) {
    if (dislikes.length >= CONFIG_SYNC_DISLIKE_MAX) {
      break;
    }
    const trimmed: string = rule.trim();
    if (trimmed.length > 0) {
      dislikes.push(trimmed);
    }
  }
  const file: ConfigSyncFile = {
    format: CONFIG_SYNC_FORMAT,
    version: CONFIG_SYNC_VERSION,
    exportedAt: new Date().toISOString(),
    sourceDevice: deviceName,
    playlists: playlists,
    settings: captureSettings(),
    favorites: favorites,
    history: history,
    dislikes: dislikes,
  };
  return {
    file: file,
    playlists: playlists.length,
    songs: songs,
    favorites: favorites.length,
    history: history.records.length,
    skippedSongs: skipped,
  };
}

/**
 * ListenLog 的导出包 -> 文件里的听歌流水
 *
 * 歌曲元数据单独去重放（与 ListenLog 的 songs 字典同构），记录只引用「歌名 + 歌手」。
 * 记录里的名字 / 歌手直接从 songKey 拆（songKey = name + \u0001 + singer）——
 * 不依赖歌曲字典顺序，坏 key 直接跳过。
 */
function historyOf(exported: ListenHistoryExport): ConfigSyncHistory {
  const songs: ConfigSyncSong[] = [];
  // 留下的歌才允许留记录：本地歌 / 云端歌的记录会随歌曲一起被剔除（见 configHistorySongOf）
  const kept: Set<string> = new Set<string>();
  for (const song of exported.songs) {
    const one: ConfigSyncSong | null = configHistorySongOf(song);
    if (one !== null) {
      songs.push(one);
      kept.add(`${one.name}\u0001${one.singer}`);
    }
  }
  const records: ConfigSyncHistoryRecord[] = [];
  for (const record of exported.records) {
    const at: number = record.songKey.indexOf('\u0001');
    if (at <= 0) {
      continue;
    }
    const name: string = record.songKey.substring(0, at);
    const singer: string = record.songKey.substring(at + 1);
    if (name.length === 0 || !kept.has(record.songKey)) {
      continue;
    }
    records.push({
      name: name,
      singer: singer,
      startedAt: record.startedAt,
      playedMs: record.playedMs,
      durationMs: record.durationMs,
    });
  }
  return { songs: songs, records: records };
}

/**
 * ListenLog 的一首歌 -> 文件条目
 *
 * ListenSong 本来就是「播放当时的快照」，字段够重建；没有平台 songmid 时用
 * listenItemId 的兜底 id（source + 歌名 + 歌手），保证 sanitize 的「songId 非空」成立。
 * 流水恢复不需要 musicInfoJson（它只影响「历史里一键续播」要不要重新搜一次）。
 */
function configHistorySongOf(song: ListenSong): ConfigSyncSong | null {
  if (song.name.length === 0 || song.source.length === 0) {
    return null;
  }
  // 与歌单同一口径：本地歌（本机 URI）/ 云端歌（自己服务器路径）换设备不成立。
  // 不滤的话，另一台设备的「最近播放」里会多出一堆点不开的幽灵记录。
  if (song.source === LOCAL_SOURCE || song.source === WEBDAV_SOURCE) {
    return null;
  }
  const out: ConfigSyncSong = {
    name: song.name,
    singer: song.singer,
    source: song.source,
    songId: song.id.length > 0 ? song.id : listenItemId(song),
  };
  if (song.quality.length > 0) {
    out.quality = song.quality;
  }
  if (song.interval.length > 0) {
    out.interval = song.interval;
  }
  if (song.albumName.length > 0) {
    out.albumName = song.albumName;
  }
  if (song.coverUrl.length > 0) {
    out.picUrl = song.coverUrl;
  }
  return out;
}

/** 当前播放设置 -> 文件里的设置项（全部显式写出，方便对端判断「这一项要恢复」） */
export function captureSettings(): ConfigSyncSettings {
  const settings = PlaySettings.getInstance();
  const appearance = AppearanceSettings.getInstance();
  const book = BookPlaySettings.getInstance();
  const download = DownloadSettings.getInstance();
  const effect = AudioEffectSettings.getInstance();
  const out: ConfigSyncSettings = {
    // 播放
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
    // 外观（colorMode 不同步：跟随系统，且应用需要 context）
    materialLevel: appearance.getMaterialLevel(),
    coverRadius: appearance.getCoverRadius(),
    followHand: appearance.isFollowHand(),
    // 听书页签
    hideListenTab: ListenSettings.getInstance().isHideTab(),
    // 推荐 / 下载
    recommendSource: RecommendSettings.getInstance().getSource(),
    downloadQuality: download.getQuality(),
    downloadNameFormat: download.getNameFormat(),
    downloadMarkQuality: download.isMarkQuality(),
    // 音效（EQ）
    eqEnabled: effect.isEnabled(),
    eqPreset: effect.getPreset(),
    eqGains: effect.getGains().slice(),
  };
  /**
   * 听书的三个值只在 BookPlaySettings 初始化之后才导出。
   *
   * 它不像其它设置那样在 EntryAbility.onCreate 里 init —— 要等听书沙箱挂载时
   * （BookSandboxHost.aboutToAppear → BookEngine.prepare）才读盘。启动瞬间的自动同步
   * 如果早于这一刻，getter 会返回默认值（1x / 0 / 0），等于把用户的 1.5 倍速当成 1x 传上去。
   * 没初始化就不带这三项：缺省 = 对端保持本机值，宁可少同步一次也不错传。
   */
  if (book.isInited()) {
    out.bookSpeed = book.getSpeed();
    out.bookSkipIntroSec = book.getSkipIntroSec();
    out.bookSkipOutroSec = book.getSkipOutroSec();
  }
  return out;
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
  // ---- v2 新增：收藏 / 听歌流水 / 不感兴趣（老文件没有这些字段，保持缺省） ----
  if (Array.isArray(data.favorites)) {
    const list: ConfigSyncSong[] = data.favorites;
    const favorites: ConfigSyncSong[] = [];
    for (const song of list) {
      if (favorites.length >= CONFIG_SYNC_FAVORITES_MAX) {
        break;
      }
      const clean: ConfigSyncSong | null = sanitizeSong(song);
      if (clean !== null) {
        favorites.push(clean);
      }
    }
    file.favorites = favorites;
  }
  if (data.history !== undefined && data.history !== null) {
    const history: ConfigSyncHistory = sanitizeHistory(data.history);
    if (history.songs.length > 0 || history.records.length > 0) {
      file.history = history;
    }
  }
  if (Array.isArray(data.dislikes)) {
    const list: string[] = data.dislikes;
    const rules: string[] = [];
    for (const raw of list) {
      if (rules.length >= CONFIG_SYNC_DISLIKE_MAX) {
        break;
      }
      if (typeof raw === 'string') {
        const rule: string = raw.trim();
        if (rule.length > 0) {
          rules.push(rule);
        }
      }
    }
    if (rules.length > 0) {
      file.dislikes = rules;
    }
  }
  return { error: '', file: file };
}

/**
 * 收一份听歌流水
 *
 * 与歌曲、设置同样的口径：类型不对、数值不合法、缺少歌名/歌手的条目直接丢，
 * 绝不让一个坏字段把恢复弄崩。记录数按 CONFIG_SYNC_HISTORY_MAX 截断（文件来自别处，
 * 上限在解析端也要守一次）。
 */
function sanitizeHistory(input: ConfigSyncHistory): ConfigSyncHistory {
  const songs: ConfigSyncSong[] = [];
  if (input.songs !== undefined && input.songs !== null && Array.isArray(input.songs)) {
    for (const raw of input.songs) {
      if (songs.length >= CONFIG_SYNC_HISTORY_MAX) {
        break;
      }
      const song: ConfigSyncSong | null = sanitizeSong(raw);
      if (song !== null) {
        songs.push(song);
      }
    }
  }
  const records: ConfigSyncHistoryRecord[] = [];
  if (input.records !== undefined && input.records !== null && Array.isArray(input.records)) {
    for (const raw of input.records) {
      if (records.length >= CONFIG_SYNC_HISTORY_MAX) {
        break;
      }
      if (raw === null || raw === undefined) {
        continue;
      }
      const name: string = typeof raw.name === 'string' ? raw.name.trim() : '';
      const singer: string = typeof raw.singer === 'string' ? raw.singer.trim() : '';
      if (name.length === 0) {
        continue;
      }
      const startedAt: number = sanitizeMs(raw.startedAt);
      const playedMs: number = sanitizeMs(raw.playedMs);
      const durationMs: number = sanitizeMs(raw.durationMs);
      records.push({
        name: name,
        singer: singer,
        startedAt: startedAt,
        playedMs: playedMs,
        durationMs: durationMs,
      });
    }
  }
  return { songs: songs, records: records };
}

/** 毫秒时间/时长：非有限数或负数一律归 0（坏记录不该让整个恢复失败） */
function sanitizeMs(value: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
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
  // ---- v2：外观 ----
  // colorMode 不同步（跟随系统 + 应用需 context），这里没有对应字段
  if (typeof input.materialLevel === 'number' && Number.isFinite(input.materialLevel)) {
    const level: number = Math.round(input.materialLevel);
    // MATERIAL_LEVEL_MAX = 3（0 跟随系统 / 1 弱 / 2 均衡 / 3 强）
    if (level >= 0 && level <= 3) {
      out.materialLevel = level;
    }
  }
  if (typeof input.coverRadius === 'number' && Number.isFinite(input.coverRadius)) {
    const radius: number = Math.round(input.coverRadius);
    // COVER_RADIUS_MIN/MAX = 0..40 vp
    if (radius >= 0 && radius <= 40) {
      out.coverRadius = radius;
    }
  }
  if (typeof input.followHand === 'boolean') {
    out.followHand = input.followHand;
  }
  // ---- v2：听书 ----
  if (typeof input.hideListenTab === 'boolean') {
    out.hideListenTab = input.hideListenTab;
  }
  if (typeof input.bookSpeed === 'number' && Number.isFinite(input.bookSpeed)) {
    // BOOK_SPEED_CHOICES：0.5 / 0.75 / 1 / 1.25 / 1.5 / 2，只认这几档
    const choices: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];
    if (choices.includes(input.bookSpeed)) {
      out.bookSpeed = input.bookSpeed;
    }
  }
  if (typeof input.bookSkipIntroSec === 'number' && Number.isFinite(input.bookSkipIntroSec)) {
    const sec: number = Math.floor(input.bookSkipIntroSec);
    if (sec >= 0 && sec <= 600) {
      out.bookSkipIntroSec = sec;
    }
  }
  if (typeof input.bookSkipOutroSec === 'number' && Number.isFinite(input.bookSkipOutroSec)) {
    const sec: number = Math.floor(input.bookSkipOutroSec);
    if (sec >= 0 && sec <= 600) {
      out.bookSkipOutroSec = sec;
    }
  }
  // ---- v2：推荐 / 下载 ----
  if (typeof input.recommendSource === 'string' && input.recommendSource.length > 0) {
    out.recommendSource = input.recommendSource;
  }
  if (typeof input.downloadQuality === 'string' && DOWNLOAD_QUALITY_VALUES.includes(input.downloadQuality)) {
    out.downloadQuality = input.downloadQuality;
  }
  if (typeof input.downloadNameFormat === 'string' && NAME_FORMATS.includes(input.downloadNameFormat)) {
    out.downloadNameFormat = input.downloadNameFormat;
  }
  if (typeof input.downloadMarkQuality === 'boolean') {
    out.downloadMarkQuality = input.downloadMarkQuality;
  }
  // ---- v2：音效（EQ） ----
  if (typeof input.eqEnabled === 'boolean') {
    out.eqEnabled = input.eqEnabled;
  }
  if (typeof input.eqPreset === 'string' && isKnownEqPreset(input.eqPreset)) {
    out.eqPreset = input.eqPreset;
  }
  if (Array.isArray(input.eqGains)) {
    const list: number[] = input.eqGains;
    if (list.length === 10) {
      const gains: number[] = [];
      let valid: boolean = true;
      for (const raw of list) {
        if (typeof raw !== 'number' || !Number.isFinite(raw)) {
          valid = false;
          break;
        }
        gains.push(Math.min(EQ_GAIN_MAX, Math.max(EQ_GAIN_MIN, raw)));
      }
      if (valid) {
        out.eqGains = gains;
      }
    }
  }
  return out;
}

/** 预设键：内置九套 + 「自定义」（与 AudioEffectSettings 的判定一致） */
function isKnownEqPreset(key: string): boolean {
  if (key === 'custom') {
    return true;
  }
  for (const preset of EQ_PRESETS) {
    if (preset.key === key) {
      return true;
    }
  }
  return false;
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
  // ---- v2：外观（setter 自己会落盘 + 刷 AppStorage） ----
  const appearance = AppearanceSettings.getInstance();
  if (settings.materialLevel !== undefined) {
    appearance.setMaterialLevel(settings.materialLevel);
    applied++;
  }
  if (settings.coverRadius !== undefined) {
    appearance.setCoverRadius(settings.coverRadius, true);
    applied++;
  }
  if (settings.followHand !== undefined) {
    appearance.setFollowHand(settings.followHand);
    applied++;
  }
  // ---- v2：听书 ----
  if (settings.hideListenTab !== undefined) {
    ListenSettings.getInstance().setHideTab(settings.hideListenTab);
    applied++;
  }
  const book = BookPlaySettings.getInstance();
  if (settings.bookSpeed !== undefined) {
    book.setSpeed(settings.bookSpeed);
    applied++;
  }
  if (settings.bookSkipIntroSec !== undefined) {
    book.setSkipIntroSec(settings.bookSkipIntroSec);
    applied++;
  }
  if (settings.bookSkipOutroSec !== undefined) {
    book.setSkipOutroSec(settings.bookSkipOutroSec);
    applied++;
  }
  // ---- v2：推荐 / 下载 ----
  if (settings.recommendSource !== undefined) {
    RecommendSettings.getInstance().setSource(settings.recommendSource);
    applied++;
  }
  const download = DownloadSettings.getInstance();
  if (settings.downloadQuality !== undefined) {
    download.setQuality(settings.downloadQuality);
    applied++;
  }
  if (settings.downloadNameFormat !== undefined) {
    download.setNameFormat(settings.downloadNameFormat);
    applied++;
  }
  if (settings.downloadMarkQuality !== undefined) {
    download.setMarkQuality(settings.downloadMarkQuality);
    applied++;
  }
  // ---- v2：音效（EQ，用户明确要求纳入同步） ----
  if (settings.eqEnabled !== undefined || settings.eqPreset !== undefined || settings.eqGains !== undefined) {
    const effect = AudioEffectSettings.getInstance();
    // 走 applySynced：落盘 + 刷 AppStorage，但**不触发重播**（同步恢复不该打断正在播的歌）
    effect.applySynced(
      settings.eqEnabled !== undefined ? settings.eqEnabled : effect.isEnabled(),
      settings.eqPreset !== undefined ? settings.eqPreset : effect.getPreset(),
      settings.eqGains !== undefined ? settings.eqGains : effect.getGains());
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
    // 收藏 / 流水 / 不感兴趣由 mergeFavorites / mergeHistory / mergeDislikes 单独合，不在这里
    favorites: 0,
    history: 0,
    dislikes: 0,
  };
}

/**
 * 把文件里的收藏并入本机收藏（合并，不是替换）
 *
 * 认歌口径与歌单完全一致（先 source+songId，再歌名+歌手，都没有才按文件元数据重建）；
 * addFavorites 自己按 id 去重，所以恢复两次也不会重复收藏。
 * @returns 真正新增的首数
 */
export function mergeFavorites(songs: ConfigSyncSong[]): number {
  if (songs.length === 0) {
    return 0;
  }
  const library: LocalLibrary = LocalLibrary.getInstance();
  const index: Map<string, SongItem> = buildMatchIndex(library);
  const resolved: SongItem[] = [];
  for (const raw of songs) {
    const song: SongItem | null = resolveSong(raw, index);
    if (song !== null) {
      resolved.push(song);
    }
  }
  if (resolved.length === 0) {
    return 0;
  }
  return library.addFavorites(resolved);
}

/**
 * 把文件里的听歌流水并进本机
 *
 * 去重（同一首歌同一开播时刻只算一次）、排序与条数上限都在 ListenLog.mergeRemote 里做；
 * 这里只负责把文件结构还原成 ListenLog 的 songs/records。
 * @returns 真正新增的流水条数
 */
export function mergeHistory(history: ConfigSyncHistory | undefined): number {
  if (history === undefined) {
    return 0;
  }
  const songs: ListenSong[] = [];
  for (const raw of history.songs) {
    const song: ListenSong | null = listenSongOf(raw);
    if (song !== null) {
      songs.push(song);
    }
  }
  const records: ListenRecord[] = [];
  for (const one of history.records) {
    if (one.name.length === 0) {
      continue;
    }
    records.push({
      startedAt: one.startedAt,
      playedMs: one.playedMs,
      songKey: `${one.name}\u0001${one.singer}`,
      durationMs: one.durationMs,
    });
  }
  if (songs.length === 0 || records.length === 0) {
    return 0;
  }
  return ListenLog.getInstance().mergeRemote({ songs: songs, records: records });
}

/**
 * 文件条目 -> ListenSong（流水恢复用）
 *
 * id / musicInfoJson 是设备侧的播放快照：远端带来的 id 在本机没有意义，留空即可
 * （历史行删除按 listenItemId 兜底认人；一键续播会重新搜一次）。
 */
function listenSongOf(raw: ConfigSyncSong): ListenSong | null {
  if (raw.name.length === 0 || raw.source.length === 0) {
    return null;
  }
  const interval: string = raw.interval !== undefined ? raw.interval : '';
  return {
    id: '',
    name: raw.name,
    singer: raw.singer !== undefined ? raw.singer : '',
    coverUrl: raw.picUrl !== undefined ? raw.picUrl : '',
    art: false,
    source: raw.source,
    quality: raw.quality !== undefined ? raw.quality : '',
    interval: interval,
    musicInfoJson: '',
    albumName: raw.albumName !== undefined ? raw.albumName : '',
    durationMs: intervalMs(interval),
  };
}

/**
 * 把文件里的「不感兴趣」规则并进本机（并集）
 *
 * 规则串格式与洛雪 dislike 完全一致（name@singer、每行一条、normalize 会小写去重）。
 * 落盘时 emitRemote=false：这是配置同步，不再向洛雪服务端上行一次。
 * @returns 真正新增的规则数
 */
export function mergeDislikes(rules: string[]): number {
  if (rules.length === 0) {
    return 0;
  }
  const library: LocalLibrary = LocalLibrary.getInstance();
  const current: string = library.dislikeRules();
  const merged: string = normalizeDislikeRules(`${current}\n${rules.join('\n')}`);
  if (merged === current) {
    return 0;
  }
  const before: number = splitDislikeRules(current).length;
  const after: number = splitDislikeRules(merged).length;
  library.setDislikeRules(merged, false);
  return Math.max(0, after - before);
}

function splitDislikeRules(raw: string): string[] {
  const out: string[] = [];
  for (const line of raw.split('\n')) {
    if (line.trim().length > 0) {
      out.push(line.trim());
    }
  }
  return out;
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

/** 文件里一共多少首歌（歌单里的，不含收藏与流水） */
export function countSongs(file: ConfigSyncFile): number {
  let total: number = 0;
  for (const playlist of file.playlists) {
    total += playlist.songs.length;
  }
  return total;
}

/** 文件里带了多少首收藏（v1 老文件没有这一项 → 0） */
export function countFavorites(file: ConfigSyncFile): number {
  return file.favorites === undefined ? 0 : file.favorites.length;
}

/** 文件里带了多少条听歌流水（v1 老文件没有这一项 → 0） */
export function countHistory(file: ConfigSyncFile): number {
  return file.history === undefined ? 0 : file.history.records.length;
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
  // v2：收藏 / 流水 / 不感兴趣也要进指纹 —— 否则「只改了收藏」会被判成没变化，永远不上传
  if (file.favorites !== undefined) {
    for (const song of file.favorites) {
      parts.push(`F\u0001${song.source}\u0001${song.songId}\u0001${song.name}\u0001${song.singer}`);
    }
  }
  if (file.history !== undefined) {
    for (const record of file.history.records) {
      parts.push(`H\u0001${record.name}\u0001${record.singer}\u0001${record.startedAt}\u0001${record.playedMs}`);
    }
  }
  if (file.dislikes !== undefined) {
    for (const rule of file.dislikes) {
      parts.push(`D\u0001${rule}`);
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
  // v2 新增项（未设置的写空，保持指纹稳定）
  cells.push(numOf(settings.materialLevel));
  cells.push(numOf(settings.coverRadius));
  cells.push(boolOf(settings.followHand));
  cells.push(boolOf(settings.hideListenTab));
  cells.push(numOf(settings.bookSpeed));
  cells.push(numOf(settings.bookSkipIntroSec));
  cells.push(numOf(settings.bookSkipOutroSec));
  cells.push(textOf(settings.recommendSource));
  cells.push(textOf(settings.downloadQuality));
  cells.push(textOf(settings.downloadNameFormat));
  cells.push(boolOf(settings.downloadMarkQuality));
  cells.push(boolOf(settings.eqEnabled));
  cells.push(textOf(settings.eqPreset));
  cells.push(settings.eqGains === undefined ? '' : settings.eqGains.join(','));
  return cells.join('\u0001');
}

function numOf(value: number | undefined): string {
  return value === undefined ? '' : `${value}`;
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
  // v2 新增项：只在文件带了的时候提一句，避免摘要过长
  if (settings.eqEnabled !== undefined) {
    parts.push(`音效${settings.eqEnabled ? '开' : '关'}${eqLabel(settings.eqPreset)}`);
  }
  if (settings.materialLevel !== undefined || settings.coverRadius !== undefined) {
    parts.push('外观设置');
  }
  if (settings.hideListenTab !== undefined) {
    parts.push(`听书页签${settings.hideListenTab ? '隐藏' : '显示'}`);
  }
  if (settings.bookSpeed !== undefined) {
    parts.push(`听书倍速 ${settings.bookSpeed}x`);
  }
  if (settings.downloadQuality !== undefined) {
    parts.push(`下载音质 ${
      settings.downloadQuality.length > 0 ? qualityLabel(settings.downloadQuality) : '跟随播放'}`);
  }
  if (settings.recommendSource !== undefined) {
    parts.push('推荐来源');
  }
  if (parts.length === 0) {
    return '文件里没有带设置';
  }
  return parts.join(' · ');
}

/** EQ 预设名（自定义 / 原声 / 预设标签；未知就只写「音效开」） */
function eqLabel(preset: string | undefined): string {
  if (preset === undefined) {
    return '';
  }
  if (preset === 'custom') {
    return '（自定义）';
  }
  for (const one of EQ_PRESETS) {
    if (one.key === preset) {
      return `（${one.label}）`;
    }
  }
  return '';
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
    // 默认目录这一支也要折叠斜杠：服务器地址里手打了 //（历史配置里很常见）时，
    // 否则 MKCOL 会打到 /dav//listen-config，坚果云回 409 —— 另两支都过了这个收口。
    return collapseSlashes(`${trimmedBase}/${CONFIG_SYNC_DEFAULT_DIR}`);
  }
  const lower: string = trimmedDir.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return collapseSlashes(stripTrailingSlashes(trimmedDir));
  }
  // encodePath 一定返回以 / 开头的路径（输入有没有前导 / 都一样），
  // 所以这里只能拼一次。写成 `${base}/${encodePath(dir)}` 会得到 /dav//listen-config，
  // 坚果云不会替你折叠 //：目录建在 /dav/listen-config，PUT 却打到 /dav//listen-config，
  // 服务端回 409，而测试连接因为建目录走的是去掉空段的路径，还显示成功。
  return collapseSlashes(`${trimmedBase}${encodePath(trimmedDir)}`);
}

/** 目录 + 固定文件名 -> 文件 URL */
export function configFileUrl(folderUrl: string): string {
  return collapseSlashes(`${stripTrailingSlashes(folderUrl)}/${CONFIG_SYNC_FILE_NAME}`);
}

/**
 * 折叠 URL 路径里重复的 /（保留 scheme 的 ://）
 *
 * 用户可能从别处拷贝带 // 的整条目录 URL，历史配置里也可能已经存了这种写法。
 * 这里统一收口，保证建目录和写文件走的是同一个路径。
 */
function collapseSlashes(url: string): string {
  const schemeEnd: number = url.indexOf('://');
  const head: string = schemeEnd >= 0 ? url.substring(0, schemeEnd + 3) : '';
  const path: string = schemeEnd >= 0 ? url.substring(schemeEnd + 3) : url;
  const out: string[] = [];
  let lastWasSlash: boolean = false;
  for (let i: number = 0; i < path.length; i++) {
    const ch: string = path.charAt(i);
    if (ch === '/') {
      if (lastWasSlash) {
        continue;
      }
      lastWasSlash = true;
    } else {
      lastWasSlash = false;
    }
    out.push(ch);
  }
  return `${head}${out.join('')}`;
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
