/**
 * 回响 2.0 数据层：月度账的「算」这一层
 *
 * 这一层的职责只有三件事，全部是**纯计算 / 纯读取**，不碰文件、不碰播放器、不产生副作用：
 *   1. 把「本月 / 上月 / 任意偏移月」换算成一个自然月的毫秒范围（{@link monthRangeOf}）；
 *   2. 从 {@link ListenLog} 的流水里聚合出整页要显示的 {@link MonthlyStats}
 *      （{@link buildMonthlyStats}）；
 *   3. 文案助手（时长 / 分钟数，{@link echoDurationText} / {@link echoMinutes}）。
 *
 * **口径以聆听为准，不是派音**（契约 §3.1 / §10）：
 *   - 只算 `playedMs ≥ COUNTED_MS`（30 秒）的那部分记录 —— 这是 ListenLog 既有的
 *     「回响门槛」，不到 30 秒的播放留在播放历史里但不进回响；
 *   - 时长一律用**真实出声时长** `playedMs` 累加，**不用**音源给的标称 `interval`；
 *   - 播放次数是**流水条数**，不是「去重后的歌数」（派音那张表按歌去重，所以它的
 *     「次播放」其实不是次数）；
 *   - 完播率用 ListenLog 真实的「听到总时长 85%」判定，不是派音「播 ≥ 2 次算完播」。
 *
 * 为什么单独成文件：页面（views/EchoView.ets）与视觉组件库（ui/EchoMonthlyKit.ets）
 * 都按 PORT_CONTRACT.md §3 的签名并行引用它，页面只做「整体赋值 + 画」，聚合只在
 * 这里算一遍；月度口径一旦要调，只改这一个文件。
 */
import { EchoAlbum, EchoArtist, EchoCompletion, EchoSong, ListenLog, ListenRecord,
  ListenSong, MonthKey, COUNTED_MS } from './ListenLog';

/** 月份偏移下限：最多回看 11 个月（0=本月，-11=去年同月） */
const MONTH_MIN_OFFSET: number = -11;
/** 单曲榜取前 3（3D 三卡榜台） */
const TOP_SONG_LIMIT: number = 3;
/** 歌手榜取前 4（冠军大图 + 2/3/4 名三行） */
const TOP_ARTIST_LIMIT: number = 4;
/** 专辑榜取前 3（三张平分横排） */
const TOP_ALBUM_LIMIT: number = 3;
/** 「深夜之歌」的最后一个小时（含）：0-5 点 */
const NIGHT_LAST_HOUR: number = 5;
/**
 * ListenLog 里 songKey 的分隔符（见其 `songKeyOf`：`歌名 + \u0001 + 歌手`）
 *
 * `songKeyOf` 是模块私有函数，这里只能按同一约定拼键；两处必须保持一致，
 * 否则 `songByKey()` 取不到 id / musicInfoJson，点歌就退化成「按名字搜索」。
 */
const SONG_KEY_SEP: string = '\u0001';

/** 一个自然月的范围（start/end 为毫秒时间戳，左闭右开） */
export class MonthRange {
  year: number = 0;
  month: number = 1;
  start: number = 0;
  end: number = 0;
  label: string = '';
  yearLabel: string = '';
  days: number = 31;
}

/** 年月下拉的一项 */
export class MonthOption {
  year: number = 0;
  month: number = 1;
  /** 相对本月的偏移：0=本月，-1=上月 */
  offset: number = 0;
  label: string = '';
}

/** 榜单歌曲（比 EchoSong 多 sourceId/musicInfoJson，便于点歌直接播） */
export class MonthlySong {
  name: string = '';
  singer: string = '';
  coverUrl: string = '';
  art: boolean = false;
  source: string = '';
  albumName: string = '';
  plays: number = 0;
  totalMs: number = 0;
  durationMs: number = 0;
  /** ListenSong.id；空串 = 无法直接播 */
  songId: string = '';
  musicInfoJson: string = '';
}

export class MonthlyArtist {
  name: string = '';
  source: string = '';
  coverUrl: string = '';
  art: boolean = false;
  plays: number = 0;
  songCount: number = 0;
  totalMs: number = 0;
}

export class MonthlyAlbum {
  name: string = '';
  singer: string = '';
  coverUrl: string = '';
  art: boolean = false;
  plays: number = 0;
  totalMs: number = 0;
  songCount: number = 0;
  /** 点专辑时播它：这张专辑里当月最常听的那首 */
  topSong: MonthlySong | null = null;
}

/** 整页统计（一次性构建、整体替换，页面只整体赋值） */
export class MonthlyStats {
  totalMs: number = 0;
  playCount: number = 0;
  songCount: number = 0;
  artistCount: number = 0;
  prevTotalMs: number = 0;
  /** "是上个月的 1.8 倍" / "上个月还没有听歌记录" / "" */
  ratioText: string = '';
  topSongs: MonthlySong[] = [];
  topArtists: MonthlyArtist[] = [];
  topAlbums: MonthlyAlbum[] = [];
  /** 定长 24 */
  hourBuckets: number[] = [];
  /** 定长 = 当月天数，下标 0 = 1 号 */
  dayBuckets: number[] = [];
  listenDays: number = 0;
  /** 最长连续有听歌的天数 */
  longestStreak: number = 0;
  /** 1..31，0 = 无 */
  bestDay: number = 0;
  bestDayCount: number = 0;
  bestDayLabel: string = '';
  /** 0..100 整数 */
  completionRate: number = 0;
  completeCount: number = 0;
  skippedCount: number = 0;
  /** 每个听歌日的平均分钟（整数） */
  avgMinutesPerDay: number = 0;
  loopKing: MonthlySong | null = null;
  loopKingCount: number = 0;
  nightSong: MonthlySong | null = null;
  nightCount: number = 0;
  /** 本月第一次听到的歌数 */
  newSongCount: number = 0;
  newSongTotal: number = 0;
  hasData: boolean = false;
}

/**
 * 「深夜之歌」的两个返回值
 *
 * ArkTS 没有元组，返回两个值时用一个只在本文件用的容器类（不导出，不进契约）。
 */
class NightResult {
  song: MonthlySong | null = null;
  count: number = 0;
}

/** 当月有多少天（同 ListenLog 里那个私有 daysInMonth 的口径） */
function daysOfMonth(year: number, month: number): number {
  // new Date(year, month, 0) = 「month 这个月的第 0 天」= 上个月最后一天，
  // 传 1-based 的 month 正好拿到当月天数
  return new Date(year, month, 0).getDate();
}

/** 按 ListenLog 的约定拼 songKey（歌名 + 分隔符 + 歌手） */
function songKeyOfNameSinger(name: string, singer: string): string {
  return `${name}${SONG_KEY_SEP}${singer}`;
}

/** EchoSong（月度聚合行）→ MonthlySong（榜单行），用 songByKey 补可直接播的 id / musicInfo */
function monthlyOfEcho(log: ListenLog, song: EchoSong): MonthlySong {
  const item: MonthlySong = new MonthlySong();
  item.name = song.name;
  item.singer = song.singer;
  item.coverUrl = song.coverUrl;
  item.art = song.art;
  item.source = song.source;
  item.albumName = song.albumName;
  item.plays = song.plays;
  item.totalMs = song.totalMs;
  item.durationMs = song.durationMs;
  const meta: ListenSong | undefined = log.songByKey(songKeyOfNameSinger(song.name, song.singer));
  if (meta !== undefined) {
    item.songId = meta.id;
    item.musicInfoJson = meta.musicInfoJson;
  }
  return item;
}

/** ListenSong（元数据）+ 本次统计出来的次数/时长 → MonthlySong */
function monthlyOfListenSong(song: ListenSong, plays: number, totalMs: number): MonthlySong {
  const item: MonthlySong = new MonthlySong();
  item.name = song.name;
  item.singer = song.singer;
  item.coverUrl = song.coverUrl;
  item.art = song.art;
  item.source = song.source;
  item.albumName = song.albumName;
  item.plays = plays;
  item.totalMs = totalMs;
  item.durationMs = song.durationMs;
  item.songId = song.id;
  item.musicInfoJson = song.musicInfoJson;
  return item;
}

/** EchoArtist → MonthlyArtist */
function monthlyOfArtist(artist: EchoArtist): MonthlyArtist {
  const item: MonthlyArtist = new MonthlyArtist();
  item.name = artist.name;
  item.source = artist.source;
  item.coverUrl = artist.coverUrl;
  item.art = artist.art;
  item.plays = artist.plays;
  item.songCount = artist.songCount;
  item.totalMs = artist.totalMs;
  return item;
}

/** EchoAlbum → MonthlyAlbum（topSong 由调用方补） */
function monthlyOfAlbum(album: EchoAlbum): MonthlyAlbum {
  const item: MonthlyAlbum = new MonthlyAlbum();
  item.name = album.name;
  item.singer = album.singer;
  item.coverUrl = album.coverUrl;
  item.art = album.art;
  item.plays = album.plays;
  item.totalMs = album.totalMs;
  item.songCount = album.songCount;
  return item;
}

/**
 * 这张专辑里当月最常听的那首
 *
 * `songs` 必须是 `log.songsOf()` 的**榜单序**（次数 → 时长 → 最近）：第一个
 * `albumName` 对上的就是这张专辑里最常听的那首，不用再排一次。
 */
function topSongOfAlbum(log: ListenLog, songs: EchoSong[], albumName: string): MonthlySong | null {
  for (const song of songs) {
    if (song.albumName === albumName) {
      return monthlyOfEcho(log, song);
    }
  }
  return null;
}

/** 这个范围是不是「当前月」（用来决定连续性统计是否只算到今天） */
function isCurrentMonth(range: MonthRange): boolean {
  return range.start === monthRangeOf(0).start;
}

/**
 * 「深夜之歌」：当月 counted 流水里 0-5 点播得最多的那首
 *
 * 按 `songKey` 逐条计数（同一首歌播 3 次就是 3 次），取最多的那首；
 * 次数相同取**先遇到的**（流水新在前，即「最近听的那首」优先）。
 */
function nightSongOf(log: ListenLog, range: MonthRange): NightResult {
  const out: NightResult = new NightResult();
  const counts: Map<string, number> = new Map();
  const totals: Map<string, number> = new Map();
  const order: string[] = [];
  const records: ListenRecord[] = log.countedRecordsOf(range.year, range.month);
  for (const record of records) {
    const hour: number = new Date(record.startedAt).getHours();
    if (hour < 0 || hour > NIGHT_LAST_HOUR) {
      continue;
    }
    const existing: number | undefined = counts.get(record.songKey);
    if (existing === undefined) {
      counts.set(record.songKey, 1);
      totals.set(record.songKey, record.playedMs);
      order.push(record.songKey);
      continue;
    }
    counts.set(record.songKey, existing + 1);
    const sum: number = totals.get(record.songKey) ?? 0;
    totals.set(record.songKey, sum + record.playedMs);
  }
  let bestKey: string = '';
  let bestCount: number = 0;
  for (const key of order) {
    const count: number = counts.get(key) ?? 0;
    if (count > bestCount) {
      bestKey = key;
      bestCount = count;
    }
  }
  if (bestCount <= 0 || bestKey.length === 0) {
    return out;
  }
  const song: ListenSong | undefined = log.songByKey(bestKey);
  if (song === undefined) {
    return out;
  }
  out.song = monthlyOfListenSong(song, bestCount, totals.get(bestKey) ?? 0);
  out.count = bestCount;
  return out;
}

/**
 * 「新发现」：本月 counted 的歌里，本月之前从未听过的歌数
 *
 * 「听过」的判据是**当月之前、听满 30 秒、且有真实开播时刻**的流水：
 *   - 只看 `playedMs ≥ COUNTED_MS`，与回响其它段同一门槛；
 *   - `startedAt > 0` 必须成立 —— v1 迁移来的老历史 `startedAt=0` 只知道「听过」
 *     而不知道「什么时候听的」，若把它们算成「听过」，一首真新歌会因为老历史里有
 *     同名歌而被判成老歌（契约 §3.1 明确这种记录**不计入「听过」**）。
 */
function newSongCountOf(log: ListenLog, range: MonthRange): number {
  const currentKeys: string[] = [];
  const currentSeen: Set<string> = new Set();
  const monthRecords: ListenRecord[] = log.countedRecordsOf(range.year, range.month);
  for (const record of monthRecords) {
    if (currentSeen.has(record.songKey)) {
      continue;
    }
    currentSeen.add(record.songKey);
    currentKeys.push(record.songKey);
  }
  if (currentKeys.length === 0) {
    return 0;
  }
  const heardBefore: Set<string> = new Set();
  for (const record of log.allRecords()) {
    if (record.startedAt <= 0 || record.startedAt >= range.start) {
      continue;
    }
    if (record.playedMs < COUNTED_MS) {
      continue;
    }
    heardBefore.add(record.songKey);
  }
  let fresh: number = 0;
  for (const key of currentKeys) {
    if (!heardBefore.has(key)) {
      fresh += 1;
    }
  }
  return fresh;
}

/** 月份范围：offset 0=本月，-1=上月（上限 -11） */
export function monthRangeOf(offset: number): MonthRange {
  // 越界钳一下：页面手势 / Select 下标算错时不至于翻到未来月份或无限往回翻
  const bounded: number = offset > 0 ? 0 : (offset < MONTH_MIN_OFFSET ? MONTH_MIN_OFFSET : offset);
  const now: Date = new Date();
  const first: Date = new Date(now.getFullYear(), now.getMonth() + bounded, 1, 0, 0, 0, 0);
  const range: MonthRange = new MonthRange();
  range.year = first.getFullYear();
  range.month = first.getMonth() + 1;
  range.start = first.getTime();
  // 下个月 1 号 0 点 = 本月末（左闭右开）
  range.end = new Date(range.year, range.month, 1, 0, 0, 0, 0).getTime();
  range.label = `${range.month} 月`;
  range.yearLabel = `${range.year} 年`;
  range.days = daysOfMonth(range.year, range.month);
  return range;
}

/** 年月下拉可选月份（来自 ListenLog.months()，降序；不含当月时补一项 offset 0） */
export function buildMonthOptions(months: MonthKey[], range: MonthRange, offset: number): MonthOption[] {
  const now: Date = new Date();
  const currentYear: number = now.getFullYear();
  const currentMonth: number = now.getMonth() + 1;
  const options: MonthOption[] = [];
  const seen: Set<string> = new Set();
  const pushOption = (year: number, month: number): void => {
    const id: string = `${year}-${month}`;
    if (seen.has(id)) {
      return;
    }
    const off: number = (year - currentYear) * 12 + (month - currentMonth);
    // 未来月份没有账可看，不进下拉
    if (off > 0) {
      return;
    }
    seen.add(id);
    const option: MonthOption = new MonthOption();
    option.year = year;
    option.month = month;
    option.offset = off;
    option.label = `${month} 月`;
    options.push(option);
  };
  for (const key of months) {
    pushOption(key.year, key.month);
  }
  // 当前选中的月必须在下拉里，否则选进一个空月份后无法再选回来（派音同样有这个兜底）
  const fallback: MonthRange = monthRangeOf(offset);
  pushOption(range.year > 0 ? range.year : fallback.year,
    range.month > 0 ? range.month : fallback.month);
  // 本月永远在最后兜底：本月还没听歌时 months() 里没有它
  pushOption(currentYear, currentMonth);
  // offset 大的在前（本月 → 上月 → …）
  options.sort((left: MonthOption, right: MonthOption): number => right.offset - left.offset);
  return options;
}

/** 聚合（纯函数，入参为单例 log；内部只读 API） */
export function buildMonthlyStats(log: ListenLog, range: MonthRange, prev: MonthRange): MonthlyStats {
  const stats: MonthlyStats = new MonthlyStats();

  // ---- 三格统计 + 环比（直接取 ListenLog 的月度账，口径完全一致，不重算）
  const monthStats = log.statsOf(range.year, range.month);
  stats.totalMs = monthStats.totalMs;
  stats.playCount = monthStats.playCount;
  stats.songCount = monthStats.songCount;
  stats.artistCount = monthStats.artistCount;

  const prevStats = log.statsOf(prev.year, prev.month);
  stats.prevTotalMs = prevStats.totalMs;
  if (stats.playCount <= 0) {
    // 本月没量：整页走空态，页头只留空文案。这里必须给 ''，否则「上月有量、本月无」
    // 会算出「是上个月的 0.0 倍」这种 0 值垃圾（验收第 7 条）。
    stats.ratioText = '';
  } else if (stats.prevTotalMs <= 0) {
    // 上月没账：给一句「上个月还没有听歌记录」代替倍数
    stats.ratioText = '上个月还没有听歌记录';
  } else {
    stats.ratioText = `是上个月的 ${(stats.totalMs / stats.prevTotalMs).toFixed(1)} 倍`;
  }

  // ---- 歌曲榜 / 歌手榜 / 专辑榜（songsOf 已经是榜单序：次数 → 时长 → 最近 → 名字）
  const songs: EchoSong[] = log.songsOf(range.year, range.month);
  const topSongs: MonthlySong[] = [];
  for (let i = 0; i < songs.length && i < TOP_SONG_LIMIT; i++) {
    topSongs.push(monthlyOfEcho(log, songs[i]));
  }
  stats.topSongs = topSongs;

  const artists: EchoArtist[] = log.artistsOf(range.year, range.month);
  const topArtists: MonthlyArtist[] = [];
  for (let i = 0; i < artists.length && i < TOP_ARTIST_LIMIT; i++) {
    topArtists.push(monthlyOfArtist(artists[i]));
  }
  stats.topArtists = topArtists;

  const albums: EchoAlbum[] = log.albumsOf(range.year, range.month);
  const topAlbums: MonthlyAlbum[] = [];
  for (let i = 0; i < albums.length && i < TOP_ALBUM_LIMIT; i++) {
    const album: MonthlyAlbum = monthlyOfAlbum(albums[i]);
    album.topSong = topSongOfAlbum(log, songs, albums[i].name);
    topAlbums.push(album);
  }
  stats.topAlbums = topAlbums;

  // ---- 时段 / 日历
  stats.hourBuckets = log.hoursOf(range.year, range.month);
  const dayBuckets: number[] = log.daysOf(range.year, range.month);
  stats.dayBuckets = dayBuckets;

  let listenDays: number = 0;
  for (const count of dayBuckets) {
    if (count > 0) {
      listenDays += 1;
    }
  }
  stats.listenDays = listenDays;

  // ---- 最长连续听歌天数
  // 本月只算到今天（未来日期在日历上是空格，不能把它们算成「中断」也不能算成听歌日）
  let streakLimit: number = dayBuckets.length;
  if (isCurrentMonth(range)) {
    const today: number = new Date().getDate();
    if (today < streakLimit) {
      streakLimit = today;
    }
  }
  let streak: number = 0;
  let longest: number = 0;
  for (let i = 0; i < streakLimit; i++) {
    if (dayBuckets[i] > 0) {
      streak += 1;
      if (streak > longest) {
        longest = streak;
      }
    } else {
      streak = 0;
    }
  }
  stats.longestStreak = longest;

  // ---- 听得最多的那一天（并列取靠前的那天）
  let bestDay: number = 0;
  let bestCount: number = 0;
  for (let i = 0; i < dayBuckets.length; i++) {
    if (dayBuckets[i] > bestCount) {
      bestCount = dayBuckets[i];
      bestDay = i + 1;
    }
  }
  if (bestCount > 0) {
    stats.bestDay = bestDay;
    stats.bestDayCount = bestCount;
    stats.bestDayLabel = `${range.month} 月 ${bestDay} 日`;
  } else {
    stats.bestDay = 0;
    stats.bestDayCount = 0;
    stats.bestDayLabel = '';
  }

  // ---- 完播率（分母 judged = 时长已知、能判完播的次数；0 次则整卡 0）
  const completion: EchoCompletion = log.completionOf(range.year, range.month);
  stats.completeCount = completion.complete;
  stats.skippedCount = completion.skipped;
  stats.completionRate = completion.judged > 0
    ? Math.round(completion.complete * 100 / completion.judged)
    : 0;

  // ---- 平均每个听歌日多少分钟（整数分钟；0 个听歌日不会除零）
  stats.avgMinutesPerDay = listenDays > 0 ? Math.round(stats.totalMs / listenDays / 60000) : 0;

  // ---- 单曲循环之王：榜首且这个月至少播了 2 次（只播 1 次谈不上「循环」）
  if (topSongs.length > 0 && topSongs[0].plays >= 2) {
    stats.loopKing = topSongs[0];
    stats.loopKingCount = topSongs[0].plays;
  } else {
    stats.loopKing = null;
    stats.loopKingCount = 0;
  }

  // ---- 深夜之歌（0-5 点，当月 counted 流水逐条计时）
  const night: NightResult = nightSongOf(log, range);
  stats.nightSong = night.song;
  stats.nightCount = night.count;

  // ---- 新发现（本月头一次听到的歌）
  stats.newSongCount = newSongCountOf(log, range);
  stats.newSongTotal = stats.songCount;
  stats.hasData = stats.playCount > 0;
  return stats;
}

/** "不到 1 分钟" / "N 分钟"（派音口径：<1 分钟说「不到 1 分钟」） */
export function echoDurationText(ms: number): string {
  // 判定用**原始毫秒**而不是四舍五入后的分钟数：59.9 秒必须说「不到 1 分钟」，
  // 先 round 再判会把 59999ms 显示成「1 分钟」。
  if (isNaN(ms) || ms < 60000) {
    return '不到 1 分钟';
  }
  return `${echoMinutes(ms)} 分钟`;
}

/** 时长 → 分钟整数（四舍五入） */
export function echoMinutes(ms: number): number {
  // NaN / 0 / 负数一律 0（与 ListenLog 里 intervalMs 的「解析不出来就是 0，不猜」同口径）
  if (isNaN(ms) || ms <= 0) {
    return 0;
  }
  return Math.round(ms / 60000);
}
