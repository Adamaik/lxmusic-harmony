/**
 * 心动模式 · 数据门面（画像来自本地，候选来自全网，带缓存）
 *
 * 分工是硬边界：
 *   画像（本地）  ListenLog 播放历史 + 收藏 + 本地曲库元数据 → 编码成「当前兴趣」
 *   候选（全网）  HeartPool 的目录层入口 → 候选池 → 池内打分
 *
 * 进页面不用等：上次拉到的候选池落盘（HeartCache），`prepareCached()` 同步读出来
 * 立刻出歌，`refresh()` 在后台再拉一批新的替换。第一次没缓存时才需要等。
 *
 * 歌曲身份统一用「歌名 + 歌手」（HeartIdentity）：同一首不同音源视为同一首，
 * 候选池去重、收藏状态、已推荐排除都按它走。
 */

import { PlaySession, SongItem } from '../player/PlaySession';
import { LocalMusic } from '../local/LocalMusic';
import { ListenLog, ListenSong } from '../history/ListenLog';
import { RecommendSettings } from '../settings/RecommendSettings';
import {
  FB_COMPLETE,
  FB_LIKE,
  FB_PLAY,
  FB_SKIP,
  HeartDoc,
  HeartOptions,
  HeartPick
} from './HeartTypes';
import { HeartEngine } from './HeartEngine';
import { HeartPool, HeartPoolResult } from './HeartPool';
import { HeartCache } from './HeartCache';
import { songKeyOf, songKeyOfItem } from './HeartIdentity';

/** 一次从历史里取多少首建画像 */
const INTEREST_HISTORY: number = 200;
/** 最近听过的这几首不放进候选 */
const EXCLUDE_RECENT: number = 6;
/** 种子（锚点）最多几个 */
const SEED_MAX: number = 8;
/**
 * 缓存命中时的近似新鲜度：缓存不落盘 freshBoost（HeartCache 的格式不在这次改动范围内），
 * 但缓存里存的是上次**按新鲜度排好序**的池子，所以用位次还原相对新旧：池子前 25%
 * 从 CACHE_FRESH_TOP 线性衰减到 0，之后的都当不新。
 */
const CACHE_FRESH_TOP: number = 0.9;
const CACHE_FRESH_SPAN: number = 0.25;

/** 缓存池里第 index 首的近似新鲜度（见 CACHE_FRESH_TOP 的注释） */
function cacheFreshOfRank(index: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  const span: number = Math.max(1, Math.floor(total * CACHE_FRESH_SPAN));
  if (index >= span) {
    return 0;
  }
  return CACHE_FRESH_TOP * (1 - index / span);
}

/** Map 取值带缺省（ArkTS 里 Map.get 是 T | undefined，这里收口一次） */
function boostOf(map: Map<string, number>, key: string): number {
  const value: number | undefined = map.get(key);
  return value === undefined ? 0 : value;
}

/** 探索页一张卡：歌 + 推荐理由（分项来自引擎真实打分） */
export class ExploreCard {
  item: SongItem;
  pick: HeartPick;

  constructor(item: SongItem, pick: HeartPick) {
    this.item = item;
    this.pick = pick;
  }

  /** 推荐依据：给卡片底部那行小字用 */
  reason(): string {
    const parts: string[] = [];
    if (this.pick.dot > 0.5) {
      parts.push('和你常听的很像');
    }
    if (this.pick.taste > 0.5) {
      parts.push('合你的口味');
    }
    if (this.pick.affinity > 0) {
      parts.push('熟悉的艺人/专辑');
    }
    if (this.pick.explore) {
      parts.push('换个口味试试');
    }
    if (parts.length === 0) {
      parts.push('你可能没听过');
    }
    return parts.join(' · ');
  }
}

/** "mm:ss" → 毫秒；解析不了给 0（不编造） */
export function intervalToMs(interval: string): number {
  if (interval.length === 0) {
    return 0;
  }
  const parts: string[] = interval.split(':');
  if (parts.length !== 2) {
    return 0;
  }
  const min: number = parseInt(parts[0], 10);
  const sec: number = parseInt(parts[1], 10);
  if (Number.isNaN(min) || Number.isNaN(sec)) {
    return 0;
  }
  return (min * 60 + sec) * 1000;
}

/** 从 musicInfoJson 里尽量取专辑名：取不到就是空串（不编造） */
function albumOf(item: SongItem): string {
  if (item.musicInfoJson.length === 0) {
    return '';
  }
  try {
    const parsed: Record<string, Object> = JSON.parse(item.musicInfoJson) as Record<string, Object>;
    const value: Object | undefined = parsed.albumName;
    return typeof value === 'string' ? value as string : '';
  } catch (e) {
    return '';
  }
}

/**
 * SongItem → 算法侧的 HeartDoc
 *
 * freshBoost 必须由调用方给：平台歌没有 addedAt，新鲜度只能来自候选来源与榜内位置
 * （见 HeartPool）。画像侧的本地歌不属于候选，传 0 即可。
 */
function docOfItem(item: SongItem, liked: boolean, freshBoost: number): HeartDoc {
  const doc: HeartDoc = new HeartDoc();
  doc.id = item.id;
  doc.name = item.name;
  doc.singer = item.singer;
  doc.album = albumOf(item);
  doc.durationMs = intervalToMs(item.interval);
  doc.addedAt = 0;
  doc.freshBoost = freshBoost;
  doc.liked = liked;
  return doc;
}

function docOfListen(song: ListenSong, liked: boolean): HeartDoc {
  const doc: HeartDoc = new HeartDoc();
  doc.id = song.id;
  doc.name = song.name;
  doc.singer = song.singer;
  doc.album = song.albumName;
  doc.durationMs = song.durationMs;
  doc.liked = liked;
  return doc;
}

/**
 * 探索页的数据门面
 *
 * 使用顺序：`prepareCached()`（同步，能有多快有多快）→ `batch(n)`；
 * 同时 `refresh()` 在后台更新候选池与缓存。用户动作走 like/unlike/dislike/played。
 */
export class HeartRadio {
  private engine: HeartEngine = new HeartEngine(new HeartOptions());
  private docsById: Map<string, HeartDoc> = new Map<string, HeartDoc>();
  private docsByKey: Map<string, HeartDoc> = new Map<string, HeartDoc>();
  private songs: Map<string, SongItem> = new Map<string, SongItem>();
  private interestDocs: HeartDoc[] = [];
  private seeds: HeartDoc[] = [];
  /** 本会话已给过的卡（id 给引擎做排除，key 做跨音源去重） */
  private shownIds: Set<string> = new Set<string>();
  private shownKeys: Set<string> = new Set<string>();
  /** 本会话里标过喜欢的身份键（与真实收藏对账） */
  private likedKeys: Set<string> = new Set<string>();
  private ready: boolean = false;
  private poolSize: number = 0;

  get interestSize(): number {
    return this.interestDocs.length;
  }

  get librarySize(): number {
    return this.poolSize;
  }

  get isReady(): boolean {
    return this.ready;
  }

  get exhausted(): boolean {
    return this.shownKeys.size >= this.poolSize;
  }

  get shownCount(): number {
    return this.shownKeys.size;
  }

  /**
   * 同步出缓存：有缓存就立刻能出歌（返回候选数，0 = 没缓存）
   *
   * 这里只做「读本地画像 + 读缓存 + 建索引」，不联网，毫秒级。
   */
  prepareCached(): number {
    this.collectInterest();
    const cached: SongItem[] = HeartCache.getInstance().load();
    if (cached.length === 0) {
      return 0;
    }
    this.applyLibrary(cached);
    return cached.length;
  }

  /**
   * 后台刷新：重新拉全网候选，成功就替换池子并落盘
   *
   * 失败（没网/接口挂）返回 0，调用方保持现有缓存继续用。
   */
  async refresh(): Promise<number> {
    if (this.interestDocs.length === 0) {
      this.collectInterest();
    }
    const source: string = RecommendSettings.getInstance().getSource();
    const result: HeartPoolResult = await HeartPool.build(source, this.interestDocs,
      this.recentKeys(), this.recentIds());
    if (result.songs.length === 0) {
      return 0;
    }
    // 落盘只存 SongItem（缓存格式不动），新鲜度只在内存里带到 HeartDoc 上
    HeartCache.getInstance().save(source, result.songs);
    this.applyLibrary(result.songs, result.fresh);
    return result.songs.length;
  }

  /** 读本地画像：播放历史 + 收藏 + 本地曲库（去重） */
  private collectInterest(): void {
    const docs: HeartDoc[] = [];
    const seen: Set<string> = new Set<string>();
    const favKeys: Set<string> = this.favoriteKeys();
    const push = (doc: HeartDoc): void => {
      if (doc.id.length === 0 || seen.has(doc.id)) {
        return;
      }
      seen.add(doc.id);
      docs.push(doc);
    };
    const recent: ListenSong[] = ListenLog.getInstance().recentSongs(INTEREST_HISTORY);
    for (let i = 0; i < recent.length; i++) {
      const song: ListenSong = recent[i];
      push(docOfListen(song, favKeys.has(songKeyOf(song.name, song.singer))));
    }
    const favs: SongItem[] = PlaySession.getInstance().favorites;
    for (let i = 0; i < favs.length; i++) {
      // 画像不是候选池，新鲜度无意义，传 0
      push(docOfItem(favs[i], true, 0));
    }
    const locals: SongItem[] = LocalMusic.getInstance().songsForUi();
    for (let i = 0; i < locals.length; i++) {
      push(docOfItem(locals[i], favKeys.has(songKeyOfItem(locals[i])), 0));
    }
    this.interestDocs = docs;
    this.seeds = this.pickSeeds(favKeys);
    // 收藏本身也进喜欢的账（跨音源按 key）
    this.likedKeys = new Set<string>();
    favKeys.forEach((key: string) => {
      this.likedKeys.add(key);
    });
  }

  /** 种子（口味锚点）：优先收藏；不足 3 个用最近的补 */
  private pickSeeds(favKeys: Set<string>): HeartDoc[] {
    const seeds: HeartDoc[] = [];
    for (let i = 0; i < this.interestDocs.length && seeds.length < SEED_MAX; i++) {
      if (favKeys.has(songKeyOf(this.interestDocs[i].name, this.interestDocs[i].singer))) {
        seeds.push(this.interestDocs[i]);
      }
    }
    if (seeds.length < 3) {
      for (let i = 0; i < this.interestDocs.length && seeds.length < SEED_MAX; i++) {
        if (!seeds.includes(this.interestDocs[i])) {
          seeds.push(this.interestDocs[i]);
        }
      }
    }
    return seeds;
  }

  /** 收藏的身份键集合（唯一事实源：PlaySession 的收藏） */
  private favoriteKeys(): Set<string> {
    const out: Set<string> = new Set<string>();
    const favs: SongItem[] = PlaySession.getInstance().favorites;
    for (let i = 0; i < favs.length; i++) {
      out.add(songKeyOfItem(favs[i]));
    }
    return out;
  }

  /** 最近听过的 id（不放进候选池） */
  private recentIds(): Set<string> {
    const out: Set<string> = new Set<string>();
    const recent: ListenSong[] = ListenLog.getInstance().recentSongs(EXCLUDE_RECENT);
    for (let i = 0; i < recent.length; i++) {
      if (recent[i].id.length > 0) {
        out.add(recent[i].id);
      }
    }
    return out;
  }

  /** 最近听过的身份键（跨音源也不推荐刚听过的） */
  private recentKeys(): Set<string> {
    const out: Set<string> = new Set<string>();
    const recent: ListenSong[] = ListenLog.getInstance().recentSongs(EXCLUDE_RECENT);
    for (let i = 0; i < recent.length; i++) {
      out.add(songKeyOf(recent[i].name, recent[i].singer));
    }
    return out;
  }

  /**
   * 候选池 → 引擎全库（候选只用来打分，不参与画像）
   *
   * @param fresh 身份键 → 新鲜度（来自 HeartPool）；不传表示这是缓存池，
   *              按池内位次近似还原（缓存存的是上次按新鲜度排好的顺序）
   */
  private applyLibrary(items: SongItem[], fresh?: Map<string, number>): void {
    this.docsById = new Map<string, HeartDoc>();
    this.docsByKey = new Map<string, HeartDoc>();
    this.songs = new Map<string, SongItem>();
    if (items.length === 0) {
      return;
    }
    const favKeys: Set<string> = this.favoriteKeys();
    const docs: HeartDoc[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: SongItem = items[i];
      const key: string = songKeyOfItem(item);
      const boost: number = fresh === undefined
        ? cacheFreshOfRank(i, items.length)
        : boostOf(fresh, key);
      const doc: HeartDoc = docOfItem(item, favKeys.has(key), boost);
      docs.push(doc);
      this.docsById.set(doc.id, doc);
      this.docsByKey.set(key, doc);
      this.songs.set(item.id, item);
    }
    this.engine.setLibrary(docs);
    this.engine.setHistory(this.interestDocs);
    if (this.seeds.length > 0) {
      this.engine.setSeeds(this.seeds);
    }
    this.poolSize = items.length;
    this.ready = true;
  }

  /** 成批出歌（同一池子里换一批；按身份跨音源去重） */
  batch(count: number): ExploreCard[] {
    if (!this.ready) {
      return [];
    }
    const picks: HeartPick[] = this.engine.nextBatch(count, this.shownIds);
    const out: ExploreCard[] = [];
    for (let i = 0; i < picks.length; i++) {
      const pick: HeartPick = picks[i];
      if (pick.item === null) {
        continue;
      }
      const song: SongItem | undefined = this.songs.get(pick.item.doc.id);
      if (song === undefined) {
        continue;
      }
      const key: string = songKeyOfItem(song);
      if (this.shownKeys.has(key)) {
        continue;
      }
      this.shownIds.add(song.id);
      this.shownKeys.add(key);
      out.push(new ExploreCard(song, pick));
    }
    return out;
  }

  /** 这首是否已收藏（按歌名+歌手，不分音源） */
  isLiked(item: SongItem): boolean {
    const key: string = songKeyOfItem(item);
    const favs: SongItem[] = PlaySession.getInstance().favorites;
    for (let i = 0; i < favs.length; i++) {
      if (songKeyOfItem(favs[i]) === key) {
        return true;
      }
    }
    return false;
  }

  /** 喜欢：收藏（已在别的音源收藏过就不重复加）+ 回写正反馈 */
  like(item: SongItem): void {
    const key: string = songKeyOfItem(item);
    if (!this.isLiked(item)) {
      PlaySession.getInstance().addFavorite(item);
    }
    this.likedKeys.add(key);
    const doc: HeartDoc | undefined = this.docsByKey.get(key);
    if (doc !== undefined) {
      doc.liked = true;
      this.engine.observe(doc, FB_LIKE);
    }
  }

  /** 取消喜欢：把同一身份的所有收藏都摘掉 + 扣回画像那一笔 */
  unlike(item: SongItem): void {
    const key: string = songKeyOfItem(item);
    const favs: SongItem[] = PlaySession.getInstance().favorites;
    const ids: string[] = [];
    for (let i = 0; i < favs.length; i++) {
      if (songKeyOfItem(favs[i]) === key) {
        ids.push(favs[i].id);
      }
    }
    for (let i = 0; i < ids.length; i++) {
      PlaySession.getInstance().removeFavorite(ids[i]);
    }
    this.likedKeys.delete(key);
    const doc: HeartDoc | undefined = this.docsByKey.get(key);
    if (doc !== undefined) {
      doc.liked = false;
      this.engine.unlike(doc);
    }
  }

  /**
   * 和真实收藏对账（播放器里收藏/取消收藏都会走到这里）
   *
   * 事实源是 PlaySession 的收藏；这里只同步画像，不改收藏本身。
   */
  syncLikes(): void {
    const favKeys: Set<string> = this.favoriteKeys();
    const removed: string[] = [];
    this.likedKeys.forEach((key: string) => {
      if (!favKeys.has(key)) {
        removed.push(key);
      }
    });
    for (let i = 0; i < removed.length; i++) {
      const key: string = removed[i];
      this.likedKeys.delete(key);
      const doc: HeartDoc | undefined = this.docsByKey.get(key);
      if (doc !== undefined) {
        doc.liked = false;
        this.engine.unlike(doc);
      }
    }
    favKeys.forEach((key: string) => {
      if (this.likedKeys.has(key)) {
        return;
      }
      const doc: HeartDoc | undefined = this.docsByKey.get(key);
      if (doc !== undefined && !doc.liked) {
        doc.liked = true;
        this.likedKeys.add(key);
        this.engine.observe(doc, FB_LIKE);
      }
    });
  }

  /** 用户点了「不想听」/ 下滑跳过 */
  dislike(id: string): void {
    const doc: HeartDoc | undefined = this.docsById.get(id);
    if (doc !== undefined) {
      this.engine.observe(doc, FB_SKIP);
    }
  }

  /** 用户真的把这首播了 */
  played(id: string): void {
    const doc: HeartDoc | undefined = this.docsById.get(id);
    if (doc !== undefined) {
      this.engine.observe(doc, FB_PLAY);
    }
  }

  /** 这首自然播完了（不算跳过，中等正反馈） */
  completed(id: string): void {
    const doc: HeartDoc | undefined = this.docsById.get(id);
    if (doc !== undefined) {
      this.engine.observe(doc, FB_COMPLETE);
    }
  }

  /** 清空运行时状态 */
  reset(): void {
    this.engine.reset();
    this.shownIds = new Set<string>();
    this.shownKeys = new Set<string>();
  }
}
