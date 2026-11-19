/**
 * 心动模式 · 推荐引擎
 *
 * 一条闭环：
 *
 *   全库编码 → 组装查询（K 个长期兴趣 + 1 个短期向量）→ 对每首候选取 max 余弦
 *   → 加记账分（口味 / 亲和 / 新歌 / UCB）→ ε 探索 → 播出
 *   → observe() 用 ListenLog 的真实时长回写画像 → 下一首
 *
 * 刻意**没有**的东西（都是 heartbeat_ondevice 实测否决的）：
 *   - 序列模型（GRU4Rec）：真实行为上负收益，权重置 0；
 *   - DIN 排序器：与零成本「最近一首余弦」打平，端到端 R@10 还被召回上限压住；
 *   - 端侧梯度更新：全参微调灾难性遗忘，从零训练长不起来。
 * 于是整条链路是纯算术，没有推理框架、没有模型文件、没有 NAPI。
 */

import {
  FB_PLAY,
  FB_SKIP,
  HeartDoc,
  HeartItem,
  HeartOptions,
  HeartPick,
  HeartWeights,
  HEART_DIM
} from './HeartTypes';
import { cosine, HeartEncoder, normalizeText } from './HeartEncoder';
import { HeartProfile } from './HeartProfile';
import {
  bestCosine,
  bestQueryIndex,
  buildQueries,
  HeartQueries,
  seedQueries
} from './HeartInterest';

const MS_PER_DAY: number = 86400000;
/** recentIds 的记忆长度：只用来做「最近 N 首 / N 个艺人」的排除，不需要很长 */
const RECENT_MAX: number = 200;
/** 粗筛窗口：候选数超过它就先按多兴趣余弦筛一遍，再只对这批精排 */
const SHORTLIST: number = 400;

/** 粗筛中间结果（ArkTS 的对象字面量要显式类，不能用匿名结构） */
class DotPair {
  item: HeartItem;
  dot: number;

  constructor(item: HeartItem, dot: number) {
    this.item = item;
    this.dot = dot;
  }
}

export class HeartEngine {
  private options: HeartOptions;
  private encoder: HeartEncoder;
  private profile: HeartProfile;
  private weights: HeartWeights;
  private items: HeartItem[] = [];
  private byId: Map<string, HeartItem> = new Map<string, HeartItem>();
  /** 会话历史向量（只进不打分的「听过的」；跳过的歌不进，免得污染兴趣） */
  private history: Float32Array[] = [];
  private historyIds: string[] = [];
  /** 最近的条目 id（新 → 旧方向追加） */
  private recentIds: string[] = [];
  /** 冷启动种子向量 */
  private seedVectors: Float32Array[] = [];
  private rngState: number = 20261026;

  constructor(options?: HeartOptions) {
    this.options = options === undefined ? new HeartOptions() : options;
    this.encoder = new HeartEncoder(this.options.dim);
    this.profile = new HeartProfile(this.options.dim, this.options.blacklistSkips);
    this.weights = new HeartWeights();
    this.weights.eps = this.options.eps;
    this.rngState = this.options.seed >>> 0;
  }

  // ------------------------------------------------------------------ 装载

  get librarySize(): number {
    return this.items.length;
  }

  get historyLength(): number {
    return this.history.length;
  }

  get seedSize(): number {
    return this.seedVectors.length;
  }

  /** 换权重（调试面板 / 单测用；线上权重暂时固定） */
  weightsRef(): HeartWeights {
    return this.weights;
  }

  profileRef(): HeartProfile {
    return this.profile;
  }

  dimension(): number {
    return this.options.dim;
  }

  /** 装载全库：一次 fit IDF + 逐曲编码。库里几千首时整体 < 100ms */
  setLibrary(docs: HeartDoc[]): void {
    this.encoder.fit(docs);
    const items: HeartItem[] = [];
    const map: Map<string, HeartItem> = new Map<string, HeartItem>();
    for (let i = 0; i < docs.length; i++) {
      const doc: HeartDoc = docs[i];
      const item: HeartItem = new HeartItem(doc, this.encoder.encode(doc));
      items.push(item);
      map.set(doc.id, item);
    }
    this.items = items;
    this.byId = map;
    // 种子如果正好在库里，用新编码覆盖旧向量
    if (this.seedVectors.length > 0 && this.seedDocs.length > 0) {
      this.encodeSeeds(this.seedDocs);
    }
  }

  /** 冷启动种子（收藏前 N 首 / 最近听过的几首 / 用户手选） */
  private seedDocs: HeartDoc[] = [];

  setSeeds(docs: HeartDoc[]): void {
    this.seedDocs = docs;
    this.encodeSeeds(docs);
  }

  private encodeSeeds(docs: HeartDoc[]): void {
    const vecs: Float32Array[] = [];
    for (let i = 0; i < docs.length; i++) {
      const item: HeartItem | undefined = this.byId.get(docs[i].id);
      vecs.push(item === undefined ? this.encoder.encode(docs[i]) : item.vec);
    }
    this.seedVectors = vecs;
    this.profile.seed(vecs);
  }

  /**
   * 用本地历史初始化「当前兴趣」
   *
   * 这是画像的唯一入口：ListenLog 的最近播放 / 收藏 / 本地曲库元数据，编码成向量后
   * 直接构成会话历史，供多兴趣（K 类 + 短期）使用。候选池里的歌不参与画像 ——
   * 候选池只用来打分。
   */
  setHistory(docs: HeartDoc[]): void {
    this.history = [];
    this.historyIds = [];
    for (let i = 0; i < docs.length; i++) {
      const doc: HeartDoc = docs[i];
      const item: HeartItem | undefined = this.byId.get(doc.id);
      const vec: Float32Array = item === undefined ? this.encoder.encode(doc) : item.vec;
      this.history.push(vec);
      this.historyIds.push(doc.id);
    }
    if (this.history.length > this.options.historyMax) {
      this.history = this.history.slice(this.history.length - this.options.historyMax);
      this.historyIds = this.historyIds.slice(this.historyIds.length - this.options.historyMax);
    }
  }

  // ------------------------------------------------------------------ 推荐

  /** 下一首；库里没有可推的就返回 null（调用方决定兜底） */
  nextTrack(excludeIds?: Set<string>, excludeArtists?: Set<string>): HeartPick | null {
    if (this.items.length === 0) {
      return null;
    }
    const queries: HeartQueries = this.buildUserQueries();
    if (queries.isEmpty()) {
      return this.popularityPick(excludeIds, excludeArtists);
    }
    const board: HeartPick[] = this.scoreBoard(queries, excludeIds, excludeArtists);
    if (board.length === 0) {
      return this.popularityPick(excludeIds, excludeArtists);
    }
    let pick: HeartPick = board[0];
    // ε-greedy：给一点随机，防止越听越窄。只在榜单靠前的几十首里挑，
    // 不是全库乱抽 —— 随机也要有点道理。
    if (this.nextRandom() < this.weights.eps) {
      const idx: number = Math.floor(this.nextRandom() * Math.min(board.length, 30));
      pick = board[idx];
      pick.explore = true;
    }
    if (pick.item !== null) {
    }
    return pick;
  }

  /**
   * 打分榜：候选 → 分项 → 按总分降序
   *
   * 两段式（与研究仓库同构）：候选超过 {@link SHORTLIST} 时先用「多兴趣最大余弦」
   * 粗筛，再只对粗筛出来的这批复算全部特征。5,000 首库里这一下把单次推荐从
   * ~13ms 压到 ~2ms（Node 基准），代价是粗筛外的歌这一轮不会被选 —— 粗筛窗口
   * 400 首远大于一屏 20 首，实际影响可以忽略。
   */
  private scoreBoard(queries: HeartQueries, excludeIds?: Set<string>,
    excludeArtists?: Set<string>): HeartPick[] {
    let pool: HeartItem[] = this.candidates(excludeIds, excludeArtists);
    if (pool.length === 0) {
      return [];
    }
    if (pool.length > SHORTLIST) {
      const coarse: DotPair[] = [];
      for (let i = 0; i < pool.length; i++) {
        coarse.push(new DotPair(pool[i], bestCosine(queries.queries, pool[i].vec)));
      }
      coarse.sort((a: DotPair, b: DotPair) => b.dot - a.dot);
      pool = [];
      for (let i = 0; i < coarse.length && i < SHORTLIST; i++) {
        pool.push(coarse[i].item);
      }
    }
    // 有效口味向量整轮只算一次（混锚点 + 归一化，逐候选重算就是几千次分配）
    const tasteVec: Float32Array | null = this.profile.effectiveTaste();
    const board: HeartPick[] = [];
    for (let i = 0; i < pool.length; i++) {
      board.push(this.scoreOf(pool[i], queries, false, tasteVec));
    }
    board.sort((a: HeartPick, b: HeartPick) => b.score - a.score);
    return board;
  }

  /** 用户表示：有历史就用历史；没有就用种子分簇；再没有返回空（走热度兜底） */
  private buildUserQueries(): HeartQueries {
    if (this.history.length > 0) {
      return buildQueries(this.history, this.options.dim, this.options.k,
        this.options.shortWindow, this.options.shortDecay);
    }
    if (this.seedVectors.length > 0) {
      return seedQueries(this.seedVectors, this.options.dim, this.options.k);
    }
    return new HeartQueries();
  }

  /**
   * 成批出歌（探索页一屏一批用）
   *
   * 一次性给 N 首，批内不重复、不连推同一艺人。「批」本身不写画像 ——
   * 只有真正播过（observe）才算一次收听，否则刷几下就把历史污染了。
   */
  nextBatch(count: number, excludeIds?: Set<string>): HeartPick[] {
    const picks: HeartPick[] = [];
    if (this.items.length === 0) {
      return picks;
    }
    // 用户表示与打分榜一整个批次只算一次：一批里画像不变，逐首重算是纯浪费
    const queries: HeartQueries = this.buildUserQueries();
    if (queries.isEmpty()) {
      // 没有任何用户表示（连种子都没有）：按热度兜底，但同样要保证批内不重复
      const usedIds: Set<string> = new Set<string>();
      const usedArtists: Set<string> = new Set<string>();
      for (let i = 0; i < count; i++) {
        const pick: HeartPick | null = this.popularityPick(usedIds, usedArtists);
        if (pick === null || pick.item === null) {
          break;
        }
        picks.push(pick);
        usedIds.add(pick.item.doc.id);
        usedArtists.add(normalizeText(pick.item.doc.singer));
      }
      return picks;
    }
    const board: HeartPick[] = this.scoreBoard(queries);
    const used: Set<string> = new Set<string>();
    const usedArtists: Set<string> = new Set<string>();
    if (excludeIds !== undefined) {
      excludeIds.forEach((id: string) => {
        used.add(id);
      });
    }
    for (let i = 0; i < board.length && picks.length < count; i++) {
      const pick: HeartPick = board[i];
      if (pick.item === null) {
        continue;
      }
      const id: string = pick.item.doc.id;
      const artist: string = normalizeText(pick.item.doc.singer);
      if (used.has(id) || usedArtists.has(artist)) {
        continue;
      }
      picks.push(pick);
      used.add(id);
      usedArtists.add(artist);
    }
    return picks;
  }

  /**
   * 候选过滤：最近听过的、拉黑的、最近几个艺人的都不进
   *
   * 分「严格」和「放宽」两档：如果严格档被筛空了（比如库里只有 5 个艺人），
   * 退回只排除最近艺人的一档；再空就只排除拉黑 —— 保证永远有得推。
   */
  private candidates(excludeIds?: Set<string>, excludeArtists?: Set<string>): HeartItem[] {
    const recent: Set<string> = new Set<string>();
    const recentStart: number = Math.max(0, this.recentIds.length - this.options.excludeRecent);
    for (let i = recentStart; i < this.recentIds.length; i++) {
      recent.add(this.recentIds[i]);
    }
    const artists: Set<string> = new Set<string>();
    const artistStart: number = Math.max(0, this.recentIds.length - this.options.excludeArtists);
    for (let i = artistStart; i < this.recentIds.length; i++) {
      const item: HeartItem | undefined = this.byId.get(this.recentIds[i]);
      if (item !== undefined) {
        artists.add(normalizeText(item.doc.singer));
      }
    }
    if (excludeIds !== undefined) {
      excludeIds.forEach((id: string) => {
        recent.add(id);
      });
    }
    if (excludeArtists !== undefined) {
      excludeArtists.forEach((artist: string) => {
        artists.add(artist);
      });
    }
    const strict: HeartItem[] = [];
    const relaxed: HeartItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item: HeartItem = this.items[i];
      if (recent.has(item.doc.id)) {
        continue;
      }
      if (this.profile.isBlacklisted(item.doc.id)) {
        continue;
      }
      if (artists.has(normalizeText(item.doc.singer))) {
        relaxed.push(item);
        continue;
      }
      strict.push(item);
    }
    if (strict.length > 0) {
      return strict;
    }
    if (relaxed.length > 0) {
      return relaxed;
    }
    const all: HeartItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item: HeartItem = this.items[i];
      if (!this.profile.isBlacklisted(item.doc.id)) {
        all.push(item);
      }
    }
    if (all.length > 0) {
      return all;
    }
    // 全被拉黑：宁可推重复也不返回 null（心跳模式不能停）
    return this.items;
  }

  /** 单曲打分明细（每一项都真的参与求和，不存在「算了没用」的静默项） */
  private scoreOf(item: HeartItem, queries: HeartQueries, explore: boolean,
    tasteVec: Float32Array | null): HeartPick {
    const pick: HeartPick = new HeartPick();
    pick.item = item;
    pick.explore = explore;
    pick.dot = bestCosine(queries.queries, item.vec);
    pick.interest = bestQueryIndex(queries.queries, item.vec);
    pick.taste = tasteVec === null ? 0 : cosine(tasteVec, item.vec);
    pick.affinity = this.profile.affinityBonus(item.doc);
    // 新歌曝光：真实入库时间命中窗口就记满 1，否则用候选来源/榜内位次推断的
    // freshBoost 兜底。平台歌 addedAt 恒为 0，没有这层兜底时整项恒为 0，
    // weights.fresh 对全网候选等于白给。
    pick.fresh = Math.max(this.isFresh(item.doc) ? 1 : 0, item.doc.freshBoost);
    pick.ucb = this.profile.ucbBonus(item.doc.id);
    pick.noise = (this.nextRandom() * 2 - 1) * this.weights.noise;
    pick.score = this.weights.dot * pick.dot
      + this.weights.taste * pick.taste
      + this.weights.affinity * pick.affinity
      + this.weights.fresh * pick.fresh
      + this.weights.ucb * pick.ucb
      + pick.noise;
    return pick;
  }

  /** 新歌：入库时间在窗口内。拿不到入库时间（0）的一律不算新歌，不编造 */
  private isFresh(doc: HeartDoc): boolean {
    if (doc.addedAt <= 0) {
      return false;
    }
    const age: number = Date.now() - doc.addedAt;
    return age >= 0 && age <= this.options.freshDays * MS_PER_DAY;
  }

  /** 无历史 / 无种子时的兜底：按本地播放次数取最热的一首（排除最近与拉黑） */
  private popularityPick(excludeIds?: Set<string>, excludeArtists?: Set<string>): HeartPick | null {
    if (this.items.length === 0) {
      return null;
    }
    const candidates: HeartItem[] = this.candidates(excludeIds, excludeArtists);
    let best: HeartItem = candidates.length > 0 ? candidates[0] : this.items[0];
    for (let i = 1; i < candidates.length; i++) {
      if (candidates[i].doc.plays > best.doc.plays) {
        best = candidates[i];
      }
    }
    const pick: HeartPick = new HeartPick();
    pick.item = best;
    pick.score = 0;
    pick.explore = false;
    return pick;
  }

  // ------------------------------------------------------------------ 反馈

  /**
   * 回写一次播放的反馈
   *
   * 调用点：ListenTracker 收尾（切歌 / 退后台 / 销毁前）拿到这首歌的 playedMs 与
   * durationMs 之后调一次。**不改 ListenLog 现有口径**，只是旁挂订阅。
   */
  observe(doc: HeartDoc, kind: number): void {
    if (kind === FB_PLAY) {
      this.profile.recordExposure(doc.id);
    }
    const item: HeartItem | undefined = this.byId.get(doc.id);
    const vec: Float32Array | null = item === undefined ? null : item.vec;
    // 跳过的歌不进历史：否则「我不想听」会被当成「我在听这一类」
    if (vec !== null && kind !== FB_SKIP) {
      this.history.push(vec);
      this.historyIds.push(doc.id);
      if (this.history.length > this.options.historyMax) {
        this.history.shift();
        this.historyIds.shift();
      }
      if (item !== undefined) {
        item.doc.plays += 1;
      }
    }
    this.profile.update(doc, kind, vec);
    this.recentIds.push(doc.id);
    if (this.recentIds.length > RECENT_MAX) {
      this.recentIds.shift();
    }
  }

  /** 取消喜欢（播放器里取消收藏时同步回写，不拉黑、不算跳过） */
  unlike(doc: HeartDoc): void {
    this.profile.unlike(doc);
  }

  /** 清空一切运行时状态（换种子 / 用户点「重来」） */
  reset(): void {
    this.history = [];
    this.historyIds = [];
    this.recentIds = [];
    this.profile.reset();
    this.rngState = this.options.seed >>> 0;
  }

  // ------------------------------------------------------------------ 工具

  /** 线性同余随机：固定种子后整条链路可复现（单测依赖它，不用 Math.random） */
  private nextRandom(): number {
    this.rngState = (Math.imul(this.rngState, 1664525) + 1013904223) >>> 0;
    return this.rngState / 4294967296;
  }

  /** 供调试：当前历史里各曲 id */
  historyIdList(): string[] {
    return this.historyIds.slice();
  }

  /** 供调试：某首歌的向量（不存在返回 null） */
  vectorOf(id: string): Float32Array | null {
    const item: HeartItem | undefined = this.byId.get(id);
    return item === undefined ? null : item.vec;
  }

  /** 默认维度（供界面显示） */
  static defaultDim(): number {
    return HEART_DIM;
  }
}
