/**
 * 心动模式 · 记账层（运行时画像）
 *
 * 这里**没有任何梯度**：全部是加法、指数滑动平均和计数。这也是仓库的结论 ——
 * 端侧全参微调会灾难性遗忘（59.68% → 53.69%），从零训练在几百~几千样本上长不起来
 * （参数比数据多 20~200 倍）。所以端上做的是「记账」，不是「学习」。
 *
 * 四样东西：
 *   taste        口味向量（指数滑动平均，并固定保留一半种子锚点，防止被几条反馈带跑）
 *   affinity     艺人 / 专辑亲和计数（喜欢加分、跳过减分）
 *   blacklist    连续跳过的歌拉黑，不再出现
 *   exposure     曝光计数，给没怎么推过的歌一点 UCB 补偿
 *
 * 状态全部可序列化（P2 的 HeartStore 负责落盘），这里只管算。
 */

import {
  HEART_BLACKLIST_SKIPS,
  FB_COMPLETE,
  FB_LIKE,
  FB_PLAY,
  FB_REPEAT,
  FB_SKIP,
  HeartDoc
} from './HeartTypes';
import { cosine, l2normalize, normalizeText } from './HeartEncoder';

/** 反馈对「口味向量」的学习率 */
const TASTE_ALPHA: number = 0.1;
/** 种子锚点比例：每次更新后把口味往种子均值拽回这么多，避免冷启动后立刻跑偏 */
const ANCHOR_BLEND: number = 0.5;
/** 跳过时口味反向推的量（仓库同款：不是「不学」，而是「往反方向轻推」） */
const SKIP_PUSH: number = 0.08;
/** 亲和的上下限，防止长会话里无限累积 */
const AFFINITY_CAP: number = 3.0;

/** 拷贝向量（不用 Float32Array.slice，避免不同 ArkTS 版本支持差异） */
function copyVec(src: Float32Array): Float32Array {
  const out: Float32Array = new Float32Array(src.length);
  for (let i = 0; i < src.length; i++) {
    out[i] = src[i];
  }
  return out;
}

/** 反馈 → 亲和增量 */
export function affinityDelta(kind: number): number {
  if (kind === FB_REPEAT) {
    return 1.0;
  }
  if (kind === FB_LIKE) {
    return 0.8;
  }
  if (kind === FB_COMPLETE) {
    return 0.3;
  }
  if (kind === FB_PLAY) {
    return 0.1;
  }
  if (kind === FB_SKIP) {
    return -0.6;
  }
  return 0;
}

/** 反馈 → 口味向量是否更新（弱反馈不动向量，否则噪声会把兴趣抹平） */
export function movesTaste(kind: number): boolean {
  return kind === FB_REPEAT || kind === FB_LIKE || kind === FB_COMPLETE || kind === FB_SKIP;
}

export class HeartProfile {
  private dim: number;
  private taste: Float32Array;
  private hasTaste: boolean = false;
  /** 种子均值：锚点 */
  private anchor: Float32Array | null = null;
  private artistAff: Map<string, number> = new Map<string, number>();
  private albumAff: Map<string, number> = new Map<string, number>();
  private blacklist: Set<string> = new Set<string>();
  private skips: Map<string, number> = new Map<string, number>();
  private exposure: Map<string, number> = new Map<string, number>();
  private steps: number = 0;

  private blacklistSkips: number;

  constructor(dim: number, blacklistSkips: number = HEART_BLACKLIST_SKIPS) {
    this.blacklistSkips = blacklistSkips;
    this.dim = dim;
    this.taste = new Float32Array(dim);
  }

  /** 用种子曲目的均值做锚点（只在启动/换种子时调一次） */
  seed(seedVectors: Float32Array[]): void {
    if (seedVectors.length === 0) {
      return;
    }
    const sum: Float32Array = new Float32Array(this.dim);
    for (let i = 0; i < seedVectors.length; i++) {
      const v: Float32Array = seedVectors[i];
      for (let d = 0; d < this.dim && d < v.length; d++) {
        sum[d] += v[d];
      }
    }
    this.anchor = l2normalize(sum);
    if (!this.hasTaste) {
      this.taste = l2normalize(copyVec(sum));
      this.hasTaste = true;
    }
  }

  get step(): number {
    return this.steps;
  }

  get has(): boolean {
    return this.hasTaste;
  }

  /** 原始口味向量（未混锚点）；没有就是 null */
  rawTaste(): Float32Array | null {
    return this.hasTaste ? this.taste : null;
  }

  /**
   * 有效口味 = 0.5 × 口味 EMA + 0.5 × 种子锚点
   *
   * 没有锚点时（比如用户根本没给种子、全靠历史）就返回原始 EMA。
   */
  effectiveTaste(): Float32Array | null {
    if (!this.hasTaste) {
      return null;
    }
    if (this.anchor === null) {
      return this.taste;
    }
    const out: Float32Array = new Float32Array(this.dim);
    for (let d = 0; d < this.dim; d++) {
      out[d] = (1 - ANCHOR_BLEND) * this.taste[d] + ANCHOR_BLEND * this.anchor[d];
    }
    return l2normalize(out);
  }

  tasteSimilarity(vec: Float32Array | null): number {
    if (vec === null) {
      return 0;
    }
    const eff: Float32Array | null = this.effectiveTaste();
    if (eff === null) {
      return 0;
    }
    return cosine(eff, vec);
  }

  /** 反馈回写：口味、亲和、黑名单、计数 */
  update(doc: HeartDoc, kind: number, vec: Float32Array | null): void {    this.steps += 1;
    // 1. 黑名单：跳过次数到阈值就拉黑（只拉黑这一首，不是整个艺人）
    if (kind === FB_SKIP) {
      const key: string = doc.id;
      const cur: number | undefined = this.skips.get(key);
      const next: number = (cur === undefined ? 0 : cur) + 1;
      this.skips.set(key, next);
    }
    // 2. 亲和：艺人 / 专辑各记一笔
    const delta: number = affinityDelta(kind);
    if (delta !== 0) {
      this.bump(this.artistAff, normalizeText(doc.singer), delta);
      this.bump(this.albumAff, normalizeText(doc.album), delta);
    }
    // 3. 口味 EMA（只有较强反馈动向量）
    if (vec !== null && movesTaste(kind)) {
      this.updateTaste(vec, kind);
    }
  }

  /**
   * 取消喜欢
   *
   * 用户在播放器里取消了收藏，画像不能还留着这一笔正反馈：把当时加给艺人/专辑的
   * 亲和扣回去。**不加 skip 计数**（取消收藏不是「不想听」，别把它拉黑）。
   */
  unlike(doc: HeartDoc): void {
    this.bump(this.artistAff, normalizeText(doc.singer), -0.8);
    this.bump(this.albumAff, normalizeText(doc.album), -0.8);
  }

  private bump(map: Map<string, number>, key: string, delta: number): void {
    if (key.length === 0) {
      return;
    }
    const cur: number | undefined = map.get(key);
    let next: number = (cur === undefined ? 0 : cur) + delta;
    if (next > AFFINITY_CAP) {
      next = AFFINITY_CAP;
    }
    if (next < -AFFINITY_CAP) {
      next = -AFFINITY_CAP;
    }
    map.set(key, next);
  }

  private updateTaste(vec: Float32Array, kind: number): void {
    if (!this.hasTaste) {
      if (kind === FB_SKIP) {
        return;
      }
      this.taste = l2normalize(copyVec(vec));
      this.hasTaste = true;
      return;
    }
    if (kind === FB_SKIP) {
      // 跳过：往反方向轻推（不是「不学」）
      for (let d = 0; d < this.dim && d < vec.length; d++) {
        this.taste[d] -= SKIP_PUSH * vec[d];
      }
    } else {
      // 完播用半学习率，收藏/重复用满学习率
      const alpha: number = kind === FB_COMPLETE ? TASTE_ALPHA * 0.5 : TASTE_ALPHA;
      for (let d = 0; d < this.dim && d < vec.length; d++) {
        this.taste[d] = (1 - alpha) * this.taste[d] + alpha * vec[d];
      }
    }
    this.taste = l2normalize(this.taste);
  }

  /** 艺人 / 专辑亲和加成：艺人权重 1，专辑权重 0.5，截断到 [0, 1] */
  affinityBonus(doc: HeartDoc): number {
    const artist: number = this.lookup(this.artistAff, normalizeText(doc.singer));
    const album: number = this.lookup(this.albumAff, normalizeText(doc.album));
    let raw: number = artist + album * 0.5;
    if (raw > 1) {
      raw = 1;
    }
    if (raw < 0) {
      raw = 0;
    }
    return raw;
  }

  private lookup(map: Map<string, number>, key: string): number {
    if (key.length === 0) {
      return 0;
    }
    const v: number | undefined = map.get(key);
    return v === undefined ? 0 : v;
  }

  isBlacklisted(id: string): boolean {
    if (this.blacklist.has(id)) {
      return true;
    }
    const cur: number | undefined = this.skips.get(id);
    return cur !== undefined && cur >= this.blacklistSkips;
  }

  /** 已拉黑的 id 列表（持久化用） */
  blacklistIds(): string[] {
    const out: string[] = [];
    this.blacklist.forEach((id: string) => {
      out.push(id);
    });
    this.skips.forEach((count: number, id: string) => {
      if (count >= this.blacklistSkips && !this.blacklist.has(id)) {
        out.push(id);
      }
    });
    return out;
  }

  /** 曝光 +1（每次真正推出去就记一次） */
  recordExposure(id: string): void {
    const cur: number | undefined = this.exposure.get(id);
    this.exposure.set(id, (cur === undefined ? 0 : cur) + 1);
  }

  /**
   * UCB 探索补偿：曝光越少给得越多
   *
   * 这是「非参数」的：不需要知道分数分布，只按 ln(总步数)/该曲曝光数 走。
   */
  ucbBonus(id: string): number {
    const count: number | undefined = this.exposure.get(id);
    const n: number = count === undefined ? 0 : count;
    const bonus: number = Math.sqrt((2 * Math.log(this.steps + 2)) / (n + 1));
    // 归一化到 0~1，避免盖过相似度这种 1 分量级的主信号
    const scaled: number = bonus / Math.sqrt(2 * Math.log(this.steps + 2));
    return scaled;
  }

  /** 清空所有运行时状态（换种子 / 用户点「重新开始」时用） */
  reset(): void {
    this.taste = new Float32Array(this.dim);
    this.hasTaste = false;
    this.anchor = null;
    this.artistAff = new Map<string, number>();
    this.albumAff = new Map<string, number>();
    this.blacklist = new Set<string>();
    this.skips = new Map<string, number>();
    this.exposure = new Map<string, number>();
    this.steps = 0;
  }
}
