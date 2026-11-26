import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenLog';
const FILE_NAME: string = 'listen_log.json';
/**
 * 落盘结构变了就 +1
 *
 * v1 是「一条播放一条扁平记录」；v2 起**播放历史与回响共用这一份流水**：
 * 记录只存「歌名+歌手」这个键和时间/时长，歌曲元数据（封面、专辑、时长、
 * 能否直接续播的 musicInfo）在 songs 字典里**同一首歌只存一份** —— 一首歌听 20 遍
 * 不会把封面和 musicInfo 复制 20 份，文件大小才是可控的。
 */
const VERSION: number = 2;
/**
 * 最多留几条流水
 *
 * 一条记录 ≈ 60 字节，1000 条 ≈ 60KB；歌的元数据按「听过多少首不同的歌」另算。
 * 上限的意义是**别让它无限长**，而不是省空间：回响看的是月度账，一年几千次播放，
 * 留满一年足够回看，播放历史只取最近 100 首。
 */
export const LISTEN_LOG_MAX: number = 1000;
/**
 * 听够多久才算「回响里的一首」
 *
 * 界面上那句「听满 30 秒的歌会出现在回响里」就是这个常量：回响的统计与榜单
 * 只算 playedMs ≥ 这个值的记录。注意它**不再决定记录去留** —— 不到 30 秒的
 * 播放仍然留在流水里（播放历史要显示），只是不进回响。
 */
export const COUNTED_MS: number = 30000;
/**
 * 不到 1 秒的残片连历史都不留
 *
 * 「点开一下就切走 / 解析失败马上停」留下的 0.3 秒记录对播放历史是噪音，
 * 收尾时直接从流水里摘掉；1 秒到 30 秒之间的才是「听过但没听够」，
 * 历史里留一行、回响里不算。
 */
export const ENTERED_MS: number = 1000;
/**
 * 界面订阅这个 key 就能跟着流水刷新（@StorageLink）
 *
 * 回响页、播放历史页、「我的」页的最近播放计数都听它。
 */
export const K_ECHO_VERSION: string = 'ps_echo_version';
/**
 * 完播线：听到歌曲总时长的 85% 就算「完整听完」
 *
 * 不用 100%：结尾几秒淡出 / 播放器提前切下一首 / 系统计时误差都会让实际
 * 出声时长差那么一两秒，按 100% 算的话「完整听完」会永远是 0。
 */
const COMPLETE_RATIO: number = 0.85;
/**
 * 连全库都没有一条已知时长时的估算值（毫秒）
 *
 * 3.5 分钟：流行歌的常见长度。只用在「老流水没有时长、也没有任何已知时长可平均」的
 * 极端情况 —— 目的是让完播率始终算得出来，而不是摆一句「暂时算不出」。
 */
const DEFAULT_SONG_MS: number = 210000;

/**
 * 流水里的一首歌（元数据，同一首歌只存一份）
 *
 * 播放历史要拿它还原成队列条目（直接续播 / 收藏 / 入歌单），回响要拿它出封面、
 * 专辑榜和完播率。注意这是**播放当时的快照**（尤其是 musicInfoJson / 音质）：
 * 平台后来改了封面或链接，历史里这一行也仍是当时听的那一版。
 */
export interface ListenSong {
  /** 队列条目 id（SongItem.id）：历史页多选 / 删除按它认人；v1 迁移来的旧记录为空串 */
  id: string;
  name: string;
  singer: string;
  coverUrl: string;
  /** 没有真实封面时用洛雪那套黑心占位（与队列里的 SongItem 同义） */
  art: boolean;
  /** 平台：kw / kg / … 本地歌与云端歌带自己的 source */
  source: string;
  /** 播放当时的音质（续播时先按它协商，不行再回退） */
  quality: string;
  /** mm:ss，历史行右侧展示的时长 */
  interval: string;
  /** 真实搜索结果的 musicInfo JSON：历史里点一首歌可以**直接续播**，不用再搜一遍 */
  musicInfoJson: string;
  /** 专辑名（回响「最常听的专辑」与完播率都要）；音源没给时为空串 */
  albumName: string;
  /** 歌曲总时长（毫秒）：完播率的分母，从 interval 解析；未知为 0 */
  durationMs: number;
}

/** 流水里的一条：一次「听这首歌」的经历 */
export interface ListenRecord {
  /** 这次开播的时刻（毫秒时间戳）：决定它算在哪个月；v1 迁移来的旧历史没有时间，记 0 */
  startedAt: number;
  /** 这一次**实际听了多久**（毫秒）：暂停、缓冲、拖动都不算在里面 */
  playedMs: number;
  /** 指向 ListenSong 的键（见 songKeyOf） */
  songKey: string;
  /**
   * 这一次播放时 **AVPlayer 报出来的真实歌曲时长**（毫秒）
   *
   * 完播率必须由系统自己记、自己算，不能依赖音源给没给 `interval`：很多音源和本地
   * 文件根本没有时长字段，靠歌曲元数据的话这类播放永远判不了完播（会显示成
   * 「暂时算不出」）。AVPlayer 的 time/duration 回调会给真实时长，
   * {@link ListenTracker} 把它记在正在听的这一条上，收尾时一起落盘。
   * 老记录 / 还没拿到时长时为 0（回退用歌曲元数据里的时长）。
   */
  durationMs: number;
}

/**
 * 听歌流水的导出包（WebDAV 配置同步用）
 *
 * 跨设备只搬「歌名+歌手」这个键、开播时刻与实际时长；歌曲元数据按 key 去重后
 * 单独带一份（同一首歌的封面 / musicInfo 不会在流水里重复 N 份）。
 * records 新的在前（与落盘同序）；songs 只包含被这些 record 引用到的歌。
 * 恢复端拿到后交给 {@link ListenLog.mergeRemote} 合并，最近播放与回响都从流水重建。
 */
export interface ListenHistoryExport {
  songs: ListenSong[];
  records: ListenRecord[];
}

/** 年月选择器里的一档 */
export interface MonthKey {
  year: number;
  month: number;
}

/** 一个月的那几个数（界面上「N 次播放 / N 首歌 / N 位歌手」那一块） */
export class EchoStats {
  /** 总时长（毫秒） */
  totalMs: number = 0;
  /** 次播放：听满 30 秒的次数（播放历史里还会有不到 30 秒的，那些不算进这里） */
  playCount: number = 0;
  /** 首歌：去重后的歌数 */
  songCount: number = 0;
  /** 位歌手：去重后的歌手数（合唱按「、」这类分隔拆开各算一位） */
  artistCount: number = 0;
}

/** 一个月里的一首歌：同一首听了好几次并成一行（回响的榜单单位） */
export class EchoSong {
  name: string = '';
  singer: string = '';
  coverUrl: string = '';
  art: boolean = false;
  source: string = '';
  /** 专辑名：「最常听的专辑」里点一张要找回它的歌，页面按它匹配 */
  albumName: string = '';
  /** 听满 30 秒的次数：榜单「N 次」和占比都按它算 */
  plays: number = 0;
  /** 这首歌在这个月里一共听了多久（毫秒） */
  totalMs: number = 0;
  /** 最后一次听的时刻（同一首歌的行里展示「哪天听的」） */
  lastAt: number = 0;
  /** 歌曲总时长（毫秒）：完播率用；未知为 0 */
  durationMs: number = 0;
}

/** 一个月里的一位歌手：回响「最常听的歌手」的一块 */
export class EchoArtist {
  name: string = '';
  /** 从哪首歌记下来的来源平台（点这位歌手要去平台认人，见 core/music/MusicArtist） */
  source: string = '';
  /**
   * 这位歌手在这个月最常听的那首歌的封面
   *
   * 我们没有歌手写真（那要走平台接口、还可能没有），冠军歌手卡用他/她最常听的
   * 那首歌的封面当大图 —— 这是月报里最接近「歌手本人」的一张图。
   */
  coverUrl: string = '';
  art: boolean = false;
  /** 这位歌手参与的播放次数（合唱时每位歌手各算一次，所以全月歌手次数之和会大于总次数） */
  plays: number = 0;
  /** 去重后的歌数：这位歌手在这个月出现过几首（合唱各算一次） */
  songCount: number = 0;
  /** 这些歌在这个月一共听了多久（毫秒） */
  totalMs: number = 0;
}

/** 一个月里的一张专辑 */
export class EchoAlbum {
  name: string = '';
  /** 专辑里第一首歌的歌手（同专辑合辑时只是代表） */
  singer: string = '';
  coverUrl: string = '';
  art: boolean = false;
  /** 这张专辑里的歌一共播了几次 */
  plays: number = 0;
  /** 这张专辑里的歌一共听了多久（毫秒） */
  totalMs: number = 0;
  /** 这个月听过的这张专辑里的歌数 */
  songCount: number = 0;
}

/** 这个月的完播情况：完播率卡片的那几个数 */
export class EchoCompletion {
  /** 时长已知、能判完播的播放次数（音源没给时长的播放不计入分母） */
  judged: number = 0;
  /** 听到 ≥ COMPLETE_RATIO 的次数 */
  complete: number = 0;
  /** 没听完的次数（judged - complete） */
  skipped: number = 0;
  /** 当月有听歌的天数（「平均每个听歌日」的分母，也是日历卡片的那个数） */
  days: number = 0;
  /** 当月总时长（毫秒）：页面用它算「平均每个听歌日 N 分钟」 */
  totalMs: number = 0;
}

/** 落盘结构（records 存的是普通对象，不是类实例：见下面 toRecord 的说明） */
interface ListenLogData {
  version?: number;
  songs?: Array<Record<string, Object>>;
  records?: Array<Record<string, Object>>;
}

/** 同一首歌的判据：歌名 + 歌手（与播放历史、回响的聚合口径一致） */
function songKeyOf(song: ListenSong): string {
  return `${song.name}\u0001${song.singer}`;
}

/**
 * 歌手串拆成一位位歌手
 *
 * 各家给的合唱串各不相同（「霓虹兔、苏也莉」/「A/B」/「A & B」），
 * 「位歌手」要按人数算就得拆开。拆不出分隔符时整串算一位。
 */
const SINGER_SPLIT: RegExp = new RegExp('[、/&,，;；]');

function artistKeysOf(singer: string): string[] {
  const keys: string[] = [];
  for (const part of singer.split(SINGER_SPLIT)) {
    const name: string = part.trim();
    if (name.length > 0 && !keys.includes(name)) {
      keys.push(name);
    }
  }
  return keys;
}

/**
 * 历史行的稳定 id
 *
 * 优先用队列条目自己的 id（收藏 / 歌单 / 同步都按它认歌）；v1 迁移来的旧记录没有
 * id，就按「来源 + 歌名 + 歌手」拼一个 —— 和 SearchView 里那些兜底 id 同一个思路，
 * 只要求同一首歌每次都算出同一个值（多选 / 删除按它匹配）。
 */
export function listenItemId(song: ListenSong): string {
  if (song.id.length > 0) {
    return song.id;
  }
  return `${song.source}\u0001${song.name}\u0001${song.singer}`;
}

/** 「mm:ss」→ 毫秒；解析不出来返回 0（历史里那些没有时长的条目） */
export function intervalMs(interval: string): number {
  const parts: string[] = interval.split(':');
  if (parts.length !== 2) {
    return 0;
  }
  const minutes: number = parseInt(parts[0], 10);
  const seconds: number = parseInt(parts[1], 10);
  if (isNaN(minutes) || isNaN(seconds)) {
    return 0;
  }
  return (minutes * 60 + seconds) * 1000;
}

/** 当月有多少天 */
function daysInMonth(year: number, month: number): number {
  // new Date(year, month, 0) 是「month 这个月的第 0 天」= 上个月最后一天，
  // 所以传 1-based 的 month 正好拿到当月天数
  return new Date(year, month, 0).getDate();
}

/** 榜单排序：播放次数多在前；次数一样比总时长；再一样比最近一次听；最后按名字保证确定性 */
function compareEchoSongs(left: EchoSong, right: EchoSong): number {
  if (right.plays !== left.plays) {
    return right.plays - left.plays;
  }
  if (right.totalMs !== left.totalMs) {
    return right.totalMs - left.totalMs;
  }
  if (right.lastAt !== left.lastAt) {
    return right.lastAt - left.lastAt;
  }
  return left.name.localeCompare(right.name);
}

// ------------------------------------------------ 配置同步（导出 / 合并）

/** songKey 里的分隔符：歌名 + \u0001 + 歌手（与 songKeyOf 同口径，不显示到界面上） */
const KEY_SEP: string = '\u0001';

/** 数值字段是否合法：必须是**有限非负数**（远端 JSON 里可能有字符串 / NaN / 负数） */
function isNonNegativeNumber(value: number): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

/** 导出用的记录副本：同步流程里排序 / 裁剪都改不到流水内部的那条对象 */
function copyRecord(record: ListenRecord): ListenRecord {
  return {
    startedAt: record.startedAt,
    playedMs: record.playedMs,
    songKey: record.songKey,
    durationMs: record.durationMs,
  };
}

/** 导出用的歌曲副本：同上，避免调用方改到流水里的元数据 */
function copySong(song: ListenSong): ListenSong {
  return {
    id: song.id,
    name: song.name,
    singer: song.singer,
    coverUrl: song.coverUrl,
    art: song.art,
    source: song.source,
    quality: song.quality,
    interval: song.interval,
    musicInfoJson: song.musicInfoJson,
    albumName: song.albumName,
    durationMs: song.durationMs,
  };
}

/**
 * 远端歌曲元数据清洗
 *
 * 跨设备来的包可能是旧版本写的、也可能被手工改过：只有歌名是硬要求（songKey 靠它），
 * 其余字段类型不对就给默认值 —— 与 fromSong 的容错口径一致，绝不让 undefined / NaN
 * 流进统计（回响的完播率对 NaN 很敏感）。
 */
function sanitizeRemoteSong(raw: ListenSong): ListenSong | null {
  const name: string = typeof raw.name === 'string' ? raw.name : '';
  if (name.length === 0) {
    return null;
  }
  const song: ListenSong = {
    id: typeof raw.id === 'string' ? raw.id : '',
    name: name,
    singer: typeof raw.singer === 'string' ? raw.singer : '',
    coverUrl: typeof raw.coverUrl === 'string' ? raw.coverUrl : '',
    art: typeof raw.art === 'boolean' ? raw.art : false,
    source: typeof raw.source === 'string' ? raw.source : '',
    quality: typeof raw.quality === 'string' ? raw.quality : '',
    interval: typeof raw.interval === 'string' ? raw.interval : '',
    musicInfoJson: typeof raw.musicInfoJson === 'string' ? raw.musicInfoJson : '',
    albumName: typeof raw.albumName === 'string' ? raw.albumName : '',
    durationMs: isNonNegativeNumber(raw.durationMs) ? raw.durationMs : 0,
  };
  return song;
}

/**
 * 把远端歌曲元数据补进本机同 key 的那一份，返回有没有变化
 *
 * 判据（任务里「保留更完整/更新的那份」的落地方式）：
 *   - **逐字段补全，本机非空字段永远保留**：本机这份是当前设备最近一次播放的快照，
 *     id / musicInfoJson / quality 更能直接续播，而恢复端这些字段常常为空；
 *   - 只有本机是空串 / 0 时才用远端补（远端也可能为空，那就等于没变）；
 *   - durationMs 取两边较大的：真实时长只会越记越准，0 表示未知；
 *   - art 只是「没有封面时用占位图」的派生标记：补到封面就以封面为准清掉。
 * 不做整份替换，是因为两端可能各缺不同字段，替换会把本机已有的信息丢掉。
 */
function mergeSongInto(local: ListenSong, remote: ListenSong): boolean {
  let changed: boolean = false;
  if (local.id.length === 0 && remote.id.length > 0) {
    local.id = remote.id;
    changed = true;
  }
  if (local.singer.length === 0 && remote.singer.length > 0) {
    local.singer = remote.singer;
    changed = true;
  }
  if (local.coverUrl.length === 0 && remote.coverUrl.length > 0) {
    local.coverUrl = remote.coverUrl;
    changed = true;
  }
  if (local.source.length === 0 && remote.source.length > 0) {
    local.source = remote.source;
    changed = true;
  }
  if (local.quality.length === 0 && remote.quality.length > 0) {
    local.quality = remote.quality;
    changed = true;
  }
  if (local.interval.length === 0 && remote.interval.length > 0) {
    local.interval = remote.interval;
    changed = true;
  }
  if (local.musicInfoJson.length === 0 && remote.musicInfoJson.length > 0) {
    local.musicInfoJson = remote.musicInfoJson;
    changed = true;
  }
  if (local.albumName.length === 0 && remote.albumName.length > 0) {
    local.albumName = remote.albumName;
    changed = true;
  }
  if (remote.durationMs > local.durationMs) {
    local.durationMs = remote.durationMs;
    changed = true;
  }
  // 有封面了就不该再用占位图（art 只是「没有封面」的兜底标记）
  if (local.coverUrl.length > 0 && local.art) {
    local.art = false;
    changed = true;
  }
  return changed;
}

/**
 * 解析远端记录的 songKey
 *
 * 正常路径：exportHistory 导出的键就是 songKeyOf 的结果，合并完 songs 后字典里必然找得到。
 * 兼容路径：键里没有分隔符（旧包 / 被截断 / 手写配置）时，把它当歌名按 song.name + singer
 * 重建一次（重建键与 songKeyOf 同口径）；同名多首时无法确定是哪一首，**宁可丢弃也不猜**。
 * 两条路都走不通就说明远端只带了 records、没带这首歌的元数据：恢复出来点不开也显示不了，
 * 只能丢弃。
 */
function resolveRecordSongKey(raw: ListenRecord, songs: Map<string, ListenSong>): string {
  const key: string = typeof raw.songKey === 'string' ? raw.songKey : '';
  if (key.length === 0) {
    return '';
  }
  if (songs.get(key) !== undefined) {
    return key;
  }
  if (key.indexOf(KEY_SEP) >= 0) {
    return '';
  }
  let rebuilt: string = '';
  for (const songKey of songs.keys()) {
    const song: ListenSong | undefined = songs.get(songKey);
    if (song === undefined || song.name !== key) {
      continue;
    }
    if (rebuilt.length > 0) {
      // 同名不止一首：歌手对不上就分不清，宁可丢掉
      return '';
    }
    rebuilt = songKey;
  }
  return rebuilt;
}

/**
 * 远端记录清洗：键要能解析出来，时间 / 时长必须是非负有限数，否则丢弃
 *
 * playedMs=0 且 startedAt>0 是对端「进程被杀时还没结清的正在听」快照：按约定它仍是
 * 合法值（非负），照收；本端下次 loadV2 会按同一口径把它丢掉，不会污染统计。
 */
function sanitizeRemoteRecord(raw: ListenRecord, songs: Map<string, ListenSong>): ListenRecord | null {
  const startedAt: number = raw.startedAt;
  const playedMs: number = raw.playedMs;
  const durationMs: number = raw.durationMs;
  if (!isNonNegativeNumber(startedAt) || !isNonNegativeNumber(playedMs) ||
    !isNonNegativeNumber(durationMs)) {
    return null;
  }
  const songKey: string = resolveRecordSongKey(raw, songs);
  if (songKey.length === 0) {
    return null;
  }
  const record: ListenRecord = {
    startedAt: startedAt,
    playedMs: playedMs,
    songKey: songKey,
    durationMs: durationMs,
  };
  return record;
}

/**
 * 一条流水的去重键
 *
 * startedAt>0：`songKey + 分隔符 + startedAt`（同一首歌同一次开播只算一条）；
 * startedAt=0：只有歌（v1 迁移来的旧记录没有时间，同一首歌按「有没有」去重）。
 */
function recordDedupeKey(songKey: string, startedAt: number): string {
  if (startedAt <= 0) {
    return songKey;
  }
  return `${songKey}${KEY_SEP}${startedAt}`;
}

/** 流水排序：开播时刻新的在前；startedAt=0 的旧迁移记录算最旧、排在最后（同刻保持原有先后） */
function compareListenRecords(left: ListenRecord, right: ListenRecord): number {
  const leftLegacy: boolean = left.startedAt <= 0;
  const rightLegacy: boolean = right.startedAt <= 0;
  if (leftLegacy !== rightLegacy) {
    return leftLegacy ? 1 : -1;
  }
  if (leftLegacy) {
    return 0;
  }
  return right.startedAt - left.startedAt;
}

/**
 * 收听流水（**回响与播放历史共用的唯一底层数据**）
 *
 * 一份 JSON 落在应用沙箱（filesDir/listen_log.json）：songs 是歌曲元数据字典、
 * records 是新的在前的流水。播放历史从它身上按「歌名 + 歌手」去重取最近 100 首；
 * 回响从它身上筛 playedMs ≥ {@link COUNTED_MS} 的记录做月度聚合。
 *
 * **为什么合并**：原来 PlaySession 另存一份 history（去重、无时长、只留 100 条），
 * 回响又存一份带时长的流水 —— 同一件事写两遍、落两处盘，还会出现「历史里有、
 * 回响里没有」或反过来的对不上。现在只有这一份：
 *   - 播放历史 = 所有记录去重（含不到 30 秒的）；
 *   - 回响 = 同一份记录里听满 30 秒的那部分。
 * 差别就只有这一条 30 秒门槛，不再有两套数据。
 *
 * 谁往里写：只有 {@link ListenTracker} —— 它盯着播放器，一首开始出声就 begin、
 * 播放中每 60 秒 checkpoint、切歌 / 停止 / 退到后台就 close 结清。所以这个类本身
 * 不认识播放器，只负责「存 + 聚合」，测试与迁移都不会牵动播放链路。
 */
export class ListenLog {
  private static instance: ListenLog | null = null;

  static getInstance(): ListenLog {
    if (ListenLog.instance === null) {
      ListenLog.instance = new ListenLog();
    }
    return ListenLog.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 内存里的流水（新的在前）；init 时从文件读回来 */
  private records: ListenRecord[] = [];
  /** 歌名+歌手 → 元数据；同一首歌只存一份 */
  private songs: Map<string, ListenSong> = new Map();

  /** 绑定沙箱目录并读回流水。EntryAbility.onCreate 里调一次 */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length === 0) {
      return;
    }
    try {
      const data: ListenLogData = JSON.parse(text) as ListenLogData;
      if (data.version === VERSION) {
        this.loadV2(data);
      } else if (data.version === 1) {
        this.loadV1(data.records);
        // 迁移结果立刻按 v2 落盘：下次启动就不必再迁一遍，也不会反复读旧结构
        this.write();
      }
      hilog.info(DOMAIN, TAG, 'listen log ready, %{public}d record(s), %{public}d song(s)',
        this.records.length, this.songs.size);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse listen log failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 读 v2：songs 先建字典，records 再按键挂回去（键对不上的记录直接丢） */
  private loadV2(data: ListenLogData): void {
    const songs: Array<Record<string, Object>> | undefined = data.songs;
    if (songs !== undefined && songs !== null) {
      for (const one of songs) {
        const song: ListenSong = fromSong(one);
        if (song.name.length > 0) {
          this.songs.set(songKeyOf(song), song);
        }
      }
    }
    const records: Array<Record<string, Object>> | undefined = data.records;
    if (records === undefined || records === null) {
      return;
    }
    for (const one of records) {
      const record: ListenRecord = fromRecord(one);
      if (this.songs.get(record.songKey) === undefined) {
        continue;
      }
      // playedMs=0 且 startedAt>0 的是进程被杀时没结清的「正在听」那一条：丢掉；
      // startedAt=0 的是从 v1 旧历史迁移来的（没有时间也没有时长），要留着给历史页
      if (record.playedMs > 0 || record.startedAt === 0) {
        this.records.push(record);
      }
    }
  }

  /**
   * 读 v1（扁平记录：一条一次播放、元数据直接写在记录上）
   *
   * 迁移成 v2 的「歌曲字典 + 键」：v1 没有专辑 / 时长 / musicInfo / 稳定 id，
   * 这些字段留空 —— 历史里那些旧歌点播放时会退回「按名字搜索」（见 EchoView 的
   * playSong 与 HistoryView 的兜底），新记录的字段都是全的。
   */
  private loadV1(records: Array<Record<string, Object>> | undefined): void {
    if (records === undefined || records === null) {
      return;
    }
    for (const one of records) {
      const name: Object = one['name'];
      const singer: Object = one['singer'];
      const coverUrl: Object = one['coverUrl'];
      const art: Object = one['art'];
      const source: Object = one['source'];
      const startedAt: Object = one['startedAt'];
      const playedMs: Object = one['playedMs'];
      if (typeof name !== 'string' || name.length === 0) {
        continue;
      }
      const song: ListenSong = {
        id: '',
        name: name,
        singer: typeof singer === 'string' ? singer : '',
        coverUrl: typeof coverUrl === 'string' ? coverUrl : '',
        art: typeof art === 'boolean' ? art : false,
        source: typeof source === 'string' ? source : '',
        quality: '',
        interval: '',
        musicInfoJson: '',
        albumName: '',
        durationMs: 0,
      };
      const startedAtMs: number = typeof startedAt === 'number' ? startedAt : 0;
      const played: number = typeof playedMs === 'number' ? playedMs : 0;
      if (startedAtMs <= 0 || played <= 0) {
        continue;
      }
      const key: string = songKeyOf(song);
      this.songs.set(key, song);
      const record: ListenRecord = {
        startedAt: startedAtMs,
        playedMs: played,
        songKey: key,
        durationMs: 0,
      };
      this.records.push(record);
      if (this.records.length >= LISTEN_LOG_MAX) {
        break;
      }
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read listen log failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const used: Set<string> = new Set();
    const records: Array<Record<string, Object>> = [];
    for (const one of this.records) {
      used.add(one.songKey);
      records.push(toRecord(one));
    }
    // 没有任何记录指向的歌曲元数据（收尾时被当残片摘掉的那一条）顺手清掉，
    // 免得文件里越攒越多永远不会再被读到的歌
    const orphans: string[] = [];
    for (const key of this.songs.keys()) {
      if (!used.has(key)) {
        orphans.push(key);
      }
    }
    for (const key of orphans) {
      this.songs.delete(key);
    }
    const songs: Array<Record<string, Object>> = [];
    for (const key of this.songs.keys()) {
      const song: ListenSong | undefined = this.songs.get(key);
      if (song !== undefined) {
        songs.push(toSong(song));
      }
    }
    const data: ListenLogData = {
      version: VERSION,
      songs: songs,
      records: records,
    };
    try {
      const handle = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write listen log failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 流水变了：通知订阅它的界面重算（见 K_ECHO_VERSION） */
  private publish(): void {
    try {
      const version: number = AppStorage.get<number>(K_ECHO_VERSION) ?? 0;
      AppStorage.setOrCreate(K_ECHO_VERSION, version + 1);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时页面进来读一次也能看到
      hilog.warn(DOMAIN, TAG, 'failed to publish listen log version: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 写入

  /**
   * 开一条「正在听后」的记录（新的在最前）
   *
   * 返回的这条对象**就是**流水里那一条（不是副本）：播放中每 60 秒要把时长往上加、
   * 就地落一次盘（见 {@link checkpoint}），持有同一个对象最省事，也不会写出两条。
   * 歌曲元数据在这里注册（同一首歌以这次播放的快照为准）。
   */
  begin(song: ListenSong): ListenRecord {
    const key: string = songKeyOf(song);
    this.songs.set(key, song);
    const record: ListenRecord = {
      startedAt: Date.now(),
      playedMs: 0,
      songKey: key,
      durationMs: 0,
    };
    this.records.unshift(record);
    if (this.records.length > LISTEN_LOG_MAX) {
      this.records = this.records.slice(0, LISTEN_LOG_MAX);
    }
    this.write();
    this.publish();
    return record;
  }

  /** 播放中定时落盘：时长了，先把文件写对，免得进程被系统杀掉丢一整首 */
  checkpoint(): void {
    this.write();
    this.publish();
  }

  /**
   * 收尾一条：不到 1 秒的残片摘掉，其余**全部留下**
   *
   * 与 v1 最大的区别：v1 在这里把不到 30 秒的记录直接删掉，所以回响和播放历史
   * 只能各存一套；现在历史要显示「听过但没听够」的歌，记录就不能删 ——
   * 30 秒门槛只留在回响的聚合里（见 countedOf）。
   */
  close(record: ListenRecord): void {
    // 这次播放拿到了真实时长 → 回填到歌曲元数据：以后同一首歌（音源没给 interval、
    // 或者下一次播放还没拿到时长）也能用它算完播 —— 兜底链的第二级
    if (record.durationMs > 0) {
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      if (song !== undefined && record.durationMs > song.durationMs) {
        song.durationMs = record.durationMs;
      }
    }
    if (record.playedMs < ENTERED_MS) {
      const kept: ListenRecord[] = [];
      for (const one of this.records) {
        if (one !== record) {
          kept.push(one);
        }
      }
      if (kept.length === this.records.length) {
        return;
      }
      this.records = kept;
    }
    this.write();
    this.publish();
  }

  /** 清空全部流水（回响页顶栏的「清空」= 回响与播放历史一起清） */
  clear(): void {
    if (this.records.length === 0 && this.songs.size === 0) {
      return;
    }
    this.records = [];
    this.songs.clear();
    this.write();
    this.publish();
  }

  /**
   * 批量迁移旧版播放历史（v1 时代存在播放现场里的那 100 首）
   *
   * 旧历史没有时间也没有时长，所以这些记录 playedMs=0、startedAt=0：
   * 播放历史里能看到、回响里永远不算（回响只看 playedMs ≥ 30 秒的记录）。
   * 已经在流水里的歌跳过（流水里的记录更新、信息更全）。
   */
  adoptLegacySongs(songs: ListenSong[]): void {
    if (songs.length === 0) {
      return;
    }
    let added: number = 0;
    for (const song of songs) {
      const key: string = songKeyOf(song);
      if (this.songs.get(key) !== undefined) {
        continue;
      }
      this.songs.set(key, song);
      const record: ListenRecord = { startedAt: 0, playedMs: 0, songKey: key, durationMs: 0 };
      this.records.push(record);
      added += 1;
    }
    if (added === 0) {
      return;
    }
    if (this.records.length > LISTEN_LOG_MAX) {
      this.records = this.records.slice(0, LISTEN_LOG_MAX);
    }
    this.write();
    this.publish();
  }

  // ------------------------------------------------ 配置同步（导出 / 合并）

  /**
   * 导出一条条**原始流水**（最多 limit 条，新的在前），只带被这些记录引用到的歌曲元数据
   *
   * WebDAV 配置同步把这份包搬到其它设备：最近播放与回响都从流水重建，所以搬的必须是
   * 原始记录（开播时刻 / 实际时长 / 歌曲键），而不是聚合后的榜单。limit 非法（0 / 负数 /
   * NaN）时导空包 —— 调用方不想要就别搬。返回的都是**副本**，同步流程里再排序 / 裁剪
   * 都改不到本机流水。
   */
  exportHistory(limit: number): ListenHistoryExport {
    // ArkTS 对对象字面量里的空数组要求有明确类型：先建好两个空数组再装包
    const noSongs: ListenSong[] = [];
    const noRecords: ListenRecord[] = [];
    const out: ListenHistoryExport = { songs: noSongs, records: noRecords };
    if (!this.inited) {
      return out;
    }
    const count: number = limit > 0 ? Math.min(Math.floor(limit), this.records.length) : 0;
    const seen: Set<string> = new Set();
    for (let i = 0; i < count; i++) {
      const record: ListenRecord = this.records[i];
      out.records.push(copyRecord(record));
      // 歌曲元数据按 key 去重：同一首歌听了很多遍也只在包里带一份
      if (seen.has(record.songKey)) {
        continue;
      }
      seen.add(record.songKey);
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      if (song !== undefined) {
        out.songs.push(copySong(song));
      }
    }
    return out;
  }

  /**
   * 合并远端流水（跨设备）：返回**真正新增、且留在最终流水里**的 record 条数
   *
   * 语义是「加法」不是「用远端覆盖本机」：远端包里没有的本机记录一条都不删。
   * 步骤：
   *   1) 远端歌曲元数据**先**并进 songs 字典：记录校验要靠它认歌（不能依赖设备侧
   *      id / musicInfoJson，恢复端这些字段常为空）；
   *   2) 按本机现有流水建去重索引；
   *   3) 逐条校验 + 去重：startedAt>0 用 `songKey + 分隔符 + startedAt`；startedAt=0 的
   *      v1 旧迁移记录按 songKey（本机已有同一首歌的任何记录就跳过 —— 它没有新信息）；
   *   4) 合并后按 startedAt 降序（0 视为最旧、排最后），超过 LISTEN_LOG_MAX 截掉最旧的；
   *      截断只按时间丢最旧的那几条（容量上限的常规语义，可能是本机最旧的一条），
   *      「不删本机」指**不因为远端包里没有它就删它**；
   *   5) 真有变化（新增记录 / 元数据被补全）才 write() + publish()；K_ECHO_VERSION 由
   *      publish 处理，这里不再多写一次。
   */
  mergeRemote(exported: ListenHistoryExport): number {
    if (!this.inited) {
      return 0;
    }
    if (exported === undefined || exported === null) {
      return 0;
    }
    let changed: boolean = false;

    // 1) 歌曲元数据先合并：先有字典才能校验下面的记录
    const remoteSongs: ListenSong[] = exported.songs;
    if (Array.isArray(remoteSongs)) {
      for (const one of remoteSongs) {
        const remote: ListenSong | null = sanitizeRemoteSong(one);
        if (remote === null) {
          continue;
        }
        const key: string = songKeyOf(remote);
        const local: ListenSong | undefined = this.songs.get(key);
        if (local === undefined) {
          // 本机没有这首歌：整份收下（远端可能缺 id / musicInfoJson，点播时会退回按名搜索）
          this.songs.set(key, remote);
          changed = true;
          continue;
        }
        if (mergeSongInto(local, remote)) {
          changed = true;
        }
      }
    }

    // 2) 去重索引：startedAt>0 按「歌 + 时刻」，旧迁移记录只按歌
    const existingByStart: Set<string> = new Set();
    const existingSongKeys: Set<string> = new Set();
    for (const record of this.records) {
      existingSongKeys.add(record.songKey);
      if (record.startedAt > 0) {
        existingByStart.add(recordDedupeKey(record.songKey, record.startedAt));
      }
    }

    // 3) 逐条校验 + 去重（远端包里自己重复的记录也一并去掉）
    const added: ListenRecord[] = [];
    // 新增记录的去重键：后面判断「哪些新增真的留在最终流水里」用它，不依赖对象引用
    const addedKeys: Set<string> = new Set();
    const remoteRecords: ListenRecord[] = exported.records;
    if (Array.isArray(remoteRecords)) {
      for (const one of remoteRecords) {
        const record: ListenRecord | null = sanitizeRemoteRecord(one, this.songs);
        if (record === null) {
          continue;
        }
        if (record.startedAt <= 0) {
          if (existingSongKeys.has(record.songKey)) {
            continue;
          }
        } else if (existingByStart.has(recordDedupeKey(record.songKey, record.startedAt))) {
          continue;
        }
        existingSongKeys.add(record.songKey);
        if (record.startedAt > 0) {
          existingByStart.add(recordDedupeKey(record.songKey, record.startedAt));
        }
        addedKeys.add(recordDedupeKey(record.songKey, record.startedAt));
        added.push(record);
      }
    }

    // 4)+5) 合并、排序、截断；有变化才落盘 + 通知
    let addedCount: number = 0;
    if (added.length > 0) {
      const merged: ListenRecord[] = this.records.slice();
      for (const one of added) {
        merged.push(one);
      }
      merged.sort(compareListenRecords);
      const kept: ListenRecord[] = merged.length > LISTEN_LOG_MAX
        ? merged.slice(0, LISTEN_LOG_MAX)
        : merged;
      // 「真正新增」只算进了最终流水的：被容量上限截掉的不能算新增。
      // 按去重键字符串认（去重后每条键唯一，不会和本机记录撞上），不依赖对象引用。
      for (const one of kept) {
        if (addedKeys.has(recordDedupeKey(one.songKey, one.startedAt))) {
          addedCount += 1;
        }
      }
      this.records = kept;
      changed = true;
    }
    if (changed) {
      this.write();
      this.publish();
    }
    return addedCount;
  }

  // ---------------------------------------------------------------- 播放历史

  /**
   * 播放历史：按「歌名 + 歌手」去重后的最近 N 首（新的在前）
   *
   * 与回响的区别就是这里**不过滤时长** —— 听 5 秒的歌也算听过，会出现在最近播放里。
   */
  recentSongs(limit: number): ListenSong[] {
    const out: ListenSong[] = [];
    const seen: Set<string> = new Set();
    for (const record of this.records) {
      if (seen.has(record.songKey)) {
        continue;
      }
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      if (song === undefined) {
        continue;
      }
      seen.add(record.songKey);
      out.push(song);
      if (out.length >= limit) {
        break;
      }
    }
    return out;
  }

  /**
   * 从播放历史里删掉几首（删除该首歌的**全部**流水，否则去重后还会冒出来）
   *
   * 两个匹配口径都要给：
   *   - `ids` 是历史行 id（见 listenItemId）—— 当前版本写入的记录都有稳定 id；
   *   - `songKeys`（歌名+歌手）是给 v1 迁移来的旧记录兜底的：那些记录没有 id，
   *     只带歌名与歌手。本地音乐被删掉时（PlaySession.dropLocalSongs），旧流水里的
   *     同一首歌不带本地 id 也要一起摘掉，否则「最近播放」里会留一条点不开的幽灵。
   *
   * @returns 实际删掉的歌曲行数（不是流水条数）
   */
  removeSongs(ids: string[], songKeys: string[] = []): number {
    if (ids.length === 0 && songKeys.length === 0) {
      return 0;
    }
    const wanted: Set<string> = new Set();
    for (const id of ids) {
      wanted.add(id);
    }
    const wantedKeys: Set<string> = new Set();
    for (const key of songKeys) {
      wantedKeys.add(key);
    }
    const removedKeys: Set<string> = new Set();
    const kept: ListenRecord[] = [];
    for (const record of this.records) {
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      const byId: boolean = song !== undefined && wanted.has(listenItemId(song));
      if (byId || wantedKeys.has(record.songKey)) {
        removedKeys.add(record.songKey);
        continue;
      }
      kept.push(record);
    }
    if (removedKeys.size === 0) {
      return 0;
    }
    this.records = kept;
    for (const key of removedKeys) {
      this.songs.delete(key);
    }
    this.write();
    this.publish();
    return removedKeys.size;
  }

  // ---------------------------------------------------------------- 聚合（回响）

  /** 听满 30 秒、且落在某年某月的那几条（新的在前，与流水同序） */
  private countedOf(year: number, month: number): ListenRecord[] {
    const out: ListenRecord[] = [];
    for (const record of this.records) {
      if (record.playedMs < COUNTED_MS) {
        continue;
      }
      const at = new Date(record.startedAt);
      if (at.getFullYear() === year && at.getMonth() + 1 === month) {
        out.push(record);
      }
    }
    return out;
  }

  /** 某年某月的那几个数 */
  statsOf(year: number, month: number): EchoStats {
    const stats = new EchoStats();
    const songs: Set<string> = new Set();
    const artists: Set<string> = new Set();
    for (const record of this.countedOf(year, month)) {
      stats.totalMs += record.playedMs;
      stats.playCount += 1;
      songs.add(record.songKey);
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      if (song !== undefined) {
        for (const artist of artistKeysOf(song.singer)) {
          artists.add(artist);
        }
      }
    }
    stats.songCount = songs.size;
    stats.artistCount = artists.size;
    return stats;
  }

  /**
   * 某年某月的歌（同一首并成一行）
   *
   * 排序是**榜单序**（播放次数 → 时长 → 最近），不是「最近听过」的顺序：
   * 回响页的 Top3 领奖台和 4 名以后的榜单都直接用这个顺序，页面不再自己排。
   */
  songsOf(year: number, month: number): EchoSong[] {
    const byKey: Map<string, EchoSong> = new Map();
    for (const record of this.countedOf(year, month)) {
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      if (song === undefined) {
        continue;
      }
      const existing: EchoSong | undefined = byKey.get(record.songKey);
      if (existing === undefined) {
        const item = new EchoSong();
        item.name = song.name;
        item.singer = song.singer;
        item.coverUrl = song.coverUrl;
        item.art = song.art;
        item.source = song.source;
        item.albumName = song.albumName;
        item.durationMs = song.durationMs;
        item.plays = 1;
        item.totalMs = record.playedMs;
        item.lastAt = record.startedAt;
        byKey.set(record.songKey, item);
        continue;
      }
      existing.plays += 1;
      existing.totalMs += record.playedMs;
      if (record.startedAt > existing.lastAt) {
        existing.lastAt = record.startedAt;
      }
    }
    const out: EchoSong[] = [];
    for (const key of byKey.keys()) {
      const song: EchoSong | undefined = byKey.get(key);
      if (song !== undefined) {
        out.push(song);
      }
    }
    out.sort(compareEchoSongs);
    return out;
  }

  /**
   * 某年某月听过的歌手（冠军在前）
   *
   * `plays` 是这位歌手参与的播放次数（合唱各算一次），页面上的「N 次播放 · 占了你
   * X% 的播放」按它算；`songCount` 是去重后的歌数，名单副标题的「N 首」是它。
   */
  artistsOf(year: number, month: number): EchoArtist[] {
    const byKey: Map<string, EchoArtist> = new Map();
    for (const song of this.songsOf(year, month)) {
      for (const name of artistKeysOf(song.singer)) {
        const existing: EchoArtist | undefined = byKey.get(name);
        if (existing === undefined) {
          const artist = new EchoArtist();
          artist.name = name;
          artist.source = song.source;
          artist.coverUrl = song.coverUrl;
          artist.art = song.art;
          artist.plays = song.plays;
          artist.songCount = 1;
          artist.totalMs = song.totalMs;
          byKey.set(name, artist);
          continue;
        }
        existing.plays += song.plays;
        existing.songCount += 1;
        existing.totalMs += song.totalMs;
        // 冠军卡的大图用「这位歌手最常听的那首歌」的封面：songsOf 已按榜单排过，
        // 第一次遇到时还没有封面的话（那首没图）就用后面有图的那首补上
        if (existing.coverUrl.length === 0 && song.coverUrl.length > 0) {
          existing.coverUrl = song.coverUrl;
          existing.art = song.art;
        }
      }
    }
    const out: EchoArtist[] = [];
    for (const name of byKey.keys()) {
      const artist: EchoArtist | undefined = byKey.get(name);
      if (artist !== undefined) {
        out.push(artist);
      }
    }
    // 次数多在前；一样比时长；再一样按名字（排序必须确定性，否则界面整片重排）
    out.sort((left: EchoArtist, right: EchoArtist): number => {
      if (right.plays !== left.plays) {
        return right.plays - left.plays;
      }
      if (right.totalMs !== left.totalMs) {
        return right.totalMs - left.totalMs;
      }
      return left.name.localeCompare(right.name);
    });
    return out;
  }

  /**
   * 某年某月听过的专辑（最常听的在前）
   *
   * 专辑名是空的记录（音源没给专辑、或本地文件没标签）**不进专辑榜** ——
   * 没有名字的专辑摆出来只会是一排「未知专辑」；这种歌仍然出现在歌曲榜里。
   */
  albumsOf(year: number, month: number): EchoAlbum[] {
    const byKey: Map<string, EchoAlbum> = new Map();
    for (const song of this.songsOf(year, month)) {
      if (song.albumName.length === 0) {
        continue;
      }
      const existing: EchoAlbum | undefined = byKey.get(song.albumName);
      if (existing === undefined) {
        const album = new EchoAlbum();
        album.name = song.albumName;
        album.singer = song.singer;
        album.coverUrl = song.coverUrl;
        album.art = song.art;
        album.plays = song.plays;
        album.totalMs = song.totalMs;
        album.songCount = 1;
        byKey.set(song.albumName, album);
        continue;
      }
      existing.plays += song.plays;
      existing.totalMs += song.totalMs;
      existing.songCount += 1;
      if (existing.coverUrl.length === 0 && song.coverUrl.length > 0) {
        existing.coverUrl = song.coverUrl;
        existing.art = song.art;
      }
    }
    const out: EchoAlbum[] = [];
    for (const key of byKey.keys()) {
      const album: EchoAlbum | undefined = byKey.get(key);
      if (album !== undefined) {
        out.push(album);
      }
    }
    out.sort((left: EchoAlbum, right: EchoAlbum): number => {
      if (right.plays !== left.plays) {
        return right.plays - left.plays;
      }
      if (right.totalMs !== left.totalMs) {
        return right.totalMs - left.totalMs;
      }
      return left.name.localeCompare(right.name);
    });
    return out;
  }

  /**
   * 听歌时段：24 个格子，每个格子是这个小时里「听满 30 秒」的次数
   *
   * 按**开播时刻**归格（与「算在哪个月」同一个口径）：一首 23:58 开播、听完跨到
   * 次日的歌，整首算 23 点这一格。
   */
  hoursOf(year: number, month: number): number[] {
    const hours: number[] = [];
    for (let i = 0; i < 24; i++) {
      hours.push(0);
    }
    for (const record of this.countedOf(year, month)) {
      const hour: number = new Date(record.startedAt).getHours();
      if (hour >= 0 && hour < 24) {
        hours[hour] += 1;
      }
    }
    return hours;
  }

  /**
   * 听歌日历：当月每天「听满 30 秒」的次数（下标 0 = 1 号）
   *
   * 长度按当月天数给（31 天就是 31 格），日历卡片直接按 7 列铺。
   */
  daysOf(year: number, month: number): number[] {
    const days: number[] = [];
    const total: number = daysInMonth(year, month);
    for (let i = 0; i < total; i++) {
      days.push(0);
    }
    for (const record of this.countedOf(year, month)) {
      const day: number = new Date(record.startedAt).getDate();
      if (day >= 1 && day <= total) {
        days[day - 1] += 1;
      }
    }
    return days;
  }

  /**
   * 完播率：时长已知的播放里，有多少听到了最后
   *
   * 时长口径是「系统自己记」：每条流水上的 `durationMs` 由 {@link ListenTracker} 从
   * AVPlayer 的 time / duration 回调里抄下来，**不依赖音源给没给 interval**。
   * 但老数据（加这个字段之前写的流水）没有时长，不能因此就让整张卡片显示「算不出」，
   * 所以按三级兜底：
   *   1. 这条流水自己记的真实时长；
   *   2. 歌曲元数据里的时长（v2 起就存了，来自音源 interval / 本地文件标签）；
   *   3. 全库已知时长的平均值（再没有就按 3.5 分钟估算）。
   * 有了真实时长的播放永远用真实值算，兜底只影响没有时长的老记录。
   */
  completionOf(year: number, month: number): EchoCompletion {
    const out = new EchoCompletion();
    const days: Set<number> = new Set();
    const counted: ListenRecord[] = this.countedOf(year, month);

    // 兜底用的「全库平均时长」：先扫一遍所有记录里能拿到时长的那些
    let knownSum: number = 0;
    let knownCount: number = 0;
    for (const record of this.records) {
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      const duration: number = record.durationMs > 0
        ? record.durationMs
        : (song !== undefined ? song.durationMs : 0);
      if (duration > 0) {
        knownSum += duration;
        knownCount += 1;
      }
    }
    const fallback: number = knownCount > 0 ? knownSum / knownCount : DEFAULT_SONG_MS;

    for (const record of counted) {
      out.totalMs += record.playedMs;
      days.add(new Date(record.startedAt).getDate());
      const song: ListenSong | undefined = this.songs.get(record.songKey);
      // 1) 这条流水记的真实时长 → 2) 歌曲元数据 → 3) 全库平均（老数据）
      let duration: number = record.durationMs;
      if (duration <= 0 && song !== undefined) {
        duration = song.durationMs;
      }
      if (duration <= 0) {
        duration = fallback;
      }
      out.judged += 1;
      // 时长可能短于 30 秒（试听片段）：playedMs ≥ 85% 就算听完
      if (record.playedMs >= duration * COMPLETE_RATIO) {
        out.complete += 1;
      }
    }
    out.skipped = out.judged - out.complete;
    out.days = days.size;
    return out;
  }

  /** 有记录的月份（新的在前）—— 年月选择器里给这些月份加一个「听过」的点 */
  months(): MonthKey[] {
    const out: MonthKey[] = [];
    const seen: Set<string> = new Set();
    for (const record of this.records) {
      if (record.playedMs < COUNTED_MS) {
        continue;
      }
      const at = new Date(record.startedAt);
      const year: number = at.getFullYear();
      const month: number = at.getMonth() + 1;
      const key: string = `${year}-${month}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push({ year: year, month: month });
    }
    return out;
  }

  /** 某个年月有没有听过歌（回响页在没有记录的月份上给一句引导） */
  hasData(year: number, month: number): boolean {
    return this.countedOf(year, month).length > 0;
  }

  // ------------------------------------------------ 回响 2.0 移植新增（只读）

  /**
   * 某月的 counted 流水快照（playedMs ≥ COUNTED_MS 且 startedAt 属于该年月），新在前
   *
   * 回响 2.0 的「深夜之歌」要按每首歌逐条计时、「新发现」要看跨月的原始流水，
   * 只拿 songsOf 的月度合计不够；而 records 是 private，页面与 EchoMonthly 都读不到。
   * 返回的是**副本**：调用方随便排序 / 筛选都改不到流水本身。
   */
  countedRecordsOf(year: number, month: number): ListenRecord[] {
    return this.countedOf(year, month).slice();
  }

  /**
   * 全量流水只读快照（新在前）
   *
   * 「新发现」要回答「这首歌在本月之前出现过没有」，必须跨月看全部流水；
   * 同样是副本，不会让外部有机会改到内部状态。
   */
  allRecords(): ListenRecord[] {
    return this.records.slice();
  }

  /**
   * 按 songKey 取歌曲元数据
   *
   * 键的约定见上面的 songKeyOf（歌名 + 分隔符 + 歌手）。回响点歌要用到
   * `id` 与 `musicInfoJson`（能直接续播，不用再搜一遍），而榜单行 EchoSong
   * 只带歌名 / 歌手，所以要按这个键换回完整元数据。取不到返回 undefined。
   */
  songByKey(key: string): ListenSong | undefined {
    return this.songs.get(key);
  }
}

/**
 * 落盘用的普通对象
 *
 * 直接把接口数组 `JSON.stringify` 也能写出去，但读回来时类型上会与流水对不上
 * （JSON.parse 的结果里没有接口的类型信息），显式转一道最清楚 —— 与识别历史同一套写法。
 */
function toSong(song: ListenSong): Record<string, Object> {
  return {
    'id': song.id,
    'name': song.name,
    'singer': song.singer,
    'coverUrl': song.coverUrl,
    'art': song.art,
    'source': song.source,
    'quality': song.quality,
    'interval': song.interval,
    'musicInfoJson': song.musicInfoJson,
    'albumName': song.albumName,
    'durationMs': song.durationMs,
  };
}

function fromSong(record: Record<string, Object>): ListenSong {
  // 老文件可能缺字段（字段是后来加的），每个字段都按「类型对上才认」取默认值，
  // 免得 `as` 出来是 undefined 后一路把 NaN 带进统计
  const id: Object = record['id'];
  const name: Object = record['name'];
  const singer: Object = record['singer'];
  const coverUrl: Object = record['coverUrl'];
  const art: Object = record['art'];
  const source: Object = record['source'];
  const quality: Object = record['quality'];
  const interval: Object = record['interval'];
  const musicInfoJson: Object = record['musicInfoJson'];
  const albumName: Object = record['albumName'];
  const durationMs: Object = record['durationMs'];
  const restored: ListenSong = {
    id: typeof id === 'string' ? id : '',
    name: typeof name === 'string' ? name : '',
    singer: typeof singer === 'string' ? singer : '',
    coverUrl: typeof coverUrl === 'string' ? coverUrl : '',
    art: typeof art === 'boolean' ? art : false,
    source: typeof source === 'string' ? source : '',
    quality: typeof quality === 'string' ? quality : '',
    interval: typeof interval === 'string' ? interval : '',
    musicInfoJson: typeof musicInfoJson === 'string' ? musicInfoJson : '',
    albumName: typeof albumName === 'string' ? albumName : '',
    durationMs: typeof durationMs === 'number' ? durationMs : 0,
  };
  return restored;
}

function toRecord(record: ListenRecord): Record<string, Object> {
  return {
    'startedAt': record.startedAt,
    'playedMs': record.playedMs,
    'songKey': record.songKey,
    'durationMs': record.durationMs,
  };
}

function fromRecord(record: Record<string, Object>): ListenRecord {
  const startedAt: Object = record['startedAt'];
  const playedMs: Object = record['playedMs'];
  const songKey: Object = record['songKey'];
  const durationMs: Object = record['durationMs'];
  const restored: ListenRecord = {
    startedAt: typeof startedAt === 'number' ? startedAt : 0,
    playedMs: typeof playedMs === 'number' ? playedMs : 0,
    songKey: typeof songKey === 'string' ? songKey : '',
    // 老文件（加这个字段之前写的流水）没有 durationMs，按 0 读 —— 完播率会回退到
    // 歌曲元数据里的时长，不会因为升级把老账算错
    durationMs: typeof durationMs === 'number' ? durationMs : 0,
  };
  return restored;
}
