import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenLog';
const FILE_NAME: string = 'listen_log.json';
/** 落盘结构变了就 +1，读到不认识的版本按空流水处理 */
const VERSION: number = 1;
/**
 * 最多留几条流水
 *
 * 一条 ≈ 200 字节，1000 条 ≈ 200KB —— 上限的意义是**别让它无限长**，而不是省空间：
 * 回响看的是月度账，一年也就几千次播放，留满一年足够回看。
 */
export const LISTEN_LOG_MAX: number = 1000;
/**
 * 听够多久才算「听过这一首」
 *
 * 界面上那句「听满 30 秒的歌会出现在这里」就是这个常量：不到 30 秒的这一次
 * 收尾时**直接丢掉、不进流水**，所以统计里的「次播放」也不是「点开过几次」。
 */
export const COUNTED_MS: number = 30000;
/**
 * 界面订阅这个 key 就能跟着流水刷新（@StorageLink）
 *
 * 流水一变（收尾一条 / 播放中每 60 秒落一次盘）就 +1：回响页据此重算当月那几张数。
 */
export const K_ECHO_VERSION: string = 'ps_echo_version';

/** 流水里的一条：一次「听这首歌」的经历 */
export interface ListenRecord {
  /** 这次开播的时刻（毫秒时间戳）：决定它算在哪个月，也是同一个月的排序键 */
  startedAt: number;
  name: string;
  singer: string;
  coverUrl: string;
  /** 没有真实封面时用洛雪那套黑心占位（与队列里的 SongItem 同义） */
  art: boolean;
  /** 平台：kw / kg / … 本地歌与云端歌带自己的 source */
  source: string;
  /** 这一次**实际听了多久**（毫秒）：暂停、缓冲、拖动都不算在里面 */
  playedMs: number;
}

/** 一个月的那几个数（界面上「不到 1 分钟 / 0 次播放 / 0 首歌 / 0 位歌手」那一块） */
export class EchoStats {
  /** 总时长（毫秒） */
  totalMs: number = 0;
  /** 次播放：听满 30 秒的次数，不是「点开过几次」 */
  playCount: number = 0;
  /** 首歌：去重后的歌数 */
  songCount: number = 0;
  /** 位歌手：去重后的歌手数（合唱按「、」这类分隔拆开各算一位） */
  artistCount: number = 0;
}

/** 一个月里的一位歌手：这个月听到过他/她参与的哪些歌 */
export class EchoArtist {
  name: string = '';
  /** 去重后的歌数：这位歌手在这个月出现过几首（合唱各算一次） */
  songCount: number = 0;
  /** 这些歌在这个月一共听了多久（毫秒） */
  totalMs: number = 0;
  /**
   * 从哪首歌记下来的来源平台
   *
   * 点这位歌手要去平台认人（见 core/music/MusicArtist），而这个「歌手」是本地
   * 从歌手串拆出来的，本身不带平台 —— 就用记下他的第一条流水的来源当代表。
   */
  source: string = '';
}

/** 一个月里的一首歌：同一首听了好几次并成一行 */
export class EchoSong {
  name: string = '';
  singer: string = '';
  coverUrl: string = '';
  art: boolean = false;
  source: string = '';
  /** 听满 30 秒的次数 */
  plays: number = 0;
  /** 这首歌在这个月里一共听了多久（毫秒） */
  totalMs: number = 0;
  /** 最后一次听的时刻 */
  lastAt: number = 0;
}

/** 年月选择器里的一档 */
export interface MonthKey {
  year: number;
  month: number;
}

/** 落盘结构（records 存的是普通对象，不是类实例：见下面 toRecord 的说明） */
interface ListenLogData {
  version?: number;
  records?: Array<Record<string, Object>>;
}

/** 同一首歌的判据（与播放历史一致：歌名 + 歌手） */
function songKeyOf(record: ListenRecord): string {
  return `${record.name}\u0001${record.singer}`;
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
 * 收听流水（回响的数据源）
 *
 * 与识别历史（core/recognize/RecognitionHistory）同一套存法：一份 JSON 落在应用沙箱
 * （filesDir/listen_log.json），新的在前，超过 {@link LISTEN_LOG_MAX} 条从尾巴上丢。
 *
 * **流水记的是「一次播放」而不是「一首歌」**：同一首歌听了三遍就是三条，统计里的
 * 「次播放」算得出来、列表里的「×3」也画得出来；而「首歌 / 位歌手」在聚合时去重。
 * 播放历史（PlaySession.history）是另一回事 —— 那是「最近听过哪些歌」的**去重**列表，
 * 每首只留一条、没有时间与时长，回响要的月度账从它身上算不出来（这是新开一份流水的原因）。
 *
 * 谁往里写：只有 {@link ListenTracker} —— 它盯着播放器，一首唱完（或切歌 / 退到后台）
 * 就把这一条的时长结清。所以这个类本身不认识播放器，只负责「存 + 聚合」，
 * 测试与迁移都不会牵动播放链路。
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
  /** 内存里的那份（新的在前）；init 时从文件读回来 */
  private records: ListenRecord[] = [];

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
      if (data.version !== VERSION) {
        return;
      }
      const records: Array<Record<string, Object>> | undefined = data.records;
      if (records === undefined || records === null) {
        return;
      }
      for (const one of records) {
        const restored: ListenRecord = fromRecord(one);
        // 老文件里可能混进字段不全的条目（没歌名 / 没时长的都没法算），顺手滤掉
        if (restored.name.length > 0 && restored.startedAt > 0 && restored.playedMs > 0) {
          this.records.push(restored);
        }
      }
      hilog.info(DOMAIN, TAG, 'listen log ready, %{public}d record(s)', this.records.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse listen log failed: %{public}s', JSON.stringify(e));
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
    const records: Array<Record<string, Object>> = [];
    for (const one of this.records) {
      records.push(toRecord(one));
    }
    const data: ListenLogData = {
      version: VERSION,
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
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时回响页进来读一次也能看到
      hilog.warn(DOMAIN, TAG, 'failed to publish listen log version: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 写入

  /**
   * 开一条「正在听后」的记录（新的在最前）
   *
   * 传进来的对象**就是**流水里那一条（不是副本）：播放中每 60 秒要把时长往上加、
   * 就地落一次盘（见 {@link checkpoint}），持有同一个对象最省事，也不会写出两条。
   */
  begin(record: ListenRecord): void {
    this.records.unshift(record);
    if (this.records.length > LISTEN_LOG_MAX) {
      this.records = this.records.slice(0, LISTEN_LOG_MAX);
    }
    this.write();
    this.publish();
  }

  /** 播放中定时落盘：时长了，先把文件写对，免得进程被系统杀掉丢一整首 */
  checkpoint(): void {
    this.write();
    this.publish();
  }

  /**
   * 收尾一条：听满 30 秒的留下，不到的直接从流水里摘掉
   *
   * 「不到 30 秒不算听过」这条规则放在这里执行（而不是聚合时过滤），
   * 好处是文件里不留一堆永远不显示、也永远不会变长的碎条目。
   */
  close(record: ListenRecord): void {
    if (record.playedMs >= COUNTED_MS) {
      this.write();
      this.publish();
      return;
    }
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
    this.write();
    this.publish();
  }

  /** 清空全部流水（回响页顶栏的「清空」） */
  clear(): void {
    if (this.records.length === 0) {
      return;
    }
    this.records = [];
    this.write();
    this.publish();
  }

  // ---------------------------------------------------------------- 聚合

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
      songs.add(songKeyOf(record));
      for (const artist of artistKeysOf(record.singer)) {
        artists.add(artist);
      }
    }
    stats.songCount = songs.size;
    stats.artistCount = artists.size;
    return stats;
  }

  /** 某年某月的歌（同一首并成一行，最近在前） */
  songsOf(year: number, month: number): EchoSong[] {
    const order: string[] = [];
    const byKey: Map<string, EchoSong> = new Map();
    // 流水是新的在前：第一次遇到某首歌时它的封面 / 歌手就是最近一次那条的
    for (const record of this.countedOf(year, month)) {
      const key: string = songKeyOf(record);
      const existing: EchoSong | undefined = byKey.get(key);
      if (existing === undefined) {
        const song = new EchoSong();
        song.name = record.name;
        song.singer = record.singer;
        song.coverUrl = record.coverUrl;
        song.art = record.art;
        song.source = record.source;
        song.plays = 1;
        song.totalMs = record.playedMs;
        song.lastAt = record.startedAt;
        byKey.set(key, song);
        order.push(key);
      } else {
        existing.plays += 1;
        existing.totalMs += record.playedMs;
      }
    }
    const out: EchoSong[] = [];
    for (const key of order) {
      const song: EchoSong | undefined = byKey.get(key);
      if (song !== undefined) {
        out.push(song);
      }
    }
    return out;
  }

  /**
   * 某年某月听过的歌手（听得多在前）
   *
   * 数的是**去重后的歌**（`songsOf`），不是流水条数：同一首歌这个月听了三遍，
   * 在这位歌手名下也只该算「1 首」（界面上那行小字写的就是「N 首」）。
   * 时长则照样累加 —— 听三遍就是三段时长，这是真的听了这么久。
   */
  artistsOf(year: number, month: number): EchoArtist[] {
    const byKey: Map<string, EchoArtist> = new Map();
    for (const song of this.songsOf(year, month)) {
      for (const name of artistKeysOf(song.singer)) {
        const existing: EchoArtist | undefined = byKey.get(name);
        if (existing === undefined) {
          const artist = new EchoArtist();
          artist.name = name;
          artist.songCount = 1;
          artist.totalMs = song.totalMs;
          artist.source = song.source;
          byKey.set(name, artist);
          continue;
        }
        existing.songCount += 1;
        existing.totalMs += song.totalMs;
      }
    }
    const out: EchoArtist[] = [];
    for (const name of byKey.keys()) {
      const artist: EchoArtist | undefined = byKey.get(name);
      if (artist !== undefined) {
        out.push(artist);
      }
    }
    // 听得多在前；时长一样时按歌数，再一样按名字（排序必须是确定性的：
    // 同一个月的歌手名单每次刷新出来的顺序要一致，否则界面上会整片重排）
    out.sort((left: EchoArtist, right: EchoArtist): number => {
      if (right.totalMs !== left.totalMs) {
        return right.totalMs - left.totalMs;
      }
      if (right.songCount !== left.songCount) {
        return right.songCount - left.songCount;
      }
      return left.name.localeCompare(right.name);
    });
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
}

/**
 * 落盘用的普通对象
 *
 * 直接把接口数组 `JSON.stringify` 也能写出去，但读回来时类型上会与流水对不上
 * （JSON.parse 的结果里没有接口的类型信息），显式转一道最清楚 —— 与识别历史同一套写法。
 */
function toRecord(record: ListenRecord): Record<string, Object> {
  return {
    'startedAt': record.startedAt,
    'name': record.name,
    'singer': record.singer,
    'coverUrl': record.coverUrl,
    'art': record.art,
    'source': record.source,
    'playedMs': record.playedMs,
  };
}

function fromRecord(record: Record<string, Object>): ListenRecord {
  // 老文件可能缺字段（字段是后来加的），所以每个字段都按「类型对上才认」取一次默认值，
  // 免得 `as` 出来是 undefined 后一路把 NaN 带进统计
  const startedAt: Object = record['startedAt'];
  const name: Object = record['name'];
  const singer: Object = record['singer'];
  const coverUrl: Object = record['coverUrl'];
  const art: Object = record['art'];
  const source: Object = record['source'];
  const playedMs: Object = record['playedMs'];
  const restored: ListenRecord = {
    startedAt: typeof startedAt === 'number' ? startedAt : 0,
    name: typeof name === 'string' ? name : '',
    singer: typeof singer === 'string' ? singer : '',
    coverUrl: typeof coverUrl === 'string' ? coverUrl : '',
    art: typeof art === 'boolean' ? art : false,
    source: typeof source === 'string' ? source : '',
    playedMs: typeof playedMs === 'number' ? playedMs : 0,
  };
  return restored;
}
