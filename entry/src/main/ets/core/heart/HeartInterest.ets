/**
 * 心动模式 · 多兴趣用户表示
 *
 * 核心判断（也是用户明确要的）：**用户的兴趣不是一簇，不能求平均抹平。**
 *   「张杰的抒情」和「孙燕姿的克制」和「古风」是三簇不同的东西；平均之后得到一个
 *   对哪一簇都「有点像、又都不像」的向量，区分度趋近 0。
 *
 * 所以这里把用户表示成：
 *   K 个长期兴趣质心（球面 K-means，余弦距离）
 *   + 1 个短期向量（最近 M 首，时间衰减加权）
 * 打分时对这 K+1 个查询向量取 **max**，即「这次像你哪一类兴趣」。
 *
 * 仓库实测：max 池化比 mean 高 4~11 倍（标签表示上）；但换歌词/音频表示后 mean 反超 ——
 * 说明 max 的收益依赖表示真的有簇结构，这一点在移植时要知道：**如果以后换成更强的
 * 表示（比如音频嵌入），池化方式要重新验证，不能无条件抄 max。**
 */

import {
  HEART_K,
  HEART_KMEANS_ITERS,
  HEART_SHORT_DECAY,
  HEART_SHORT_M
} from './HeartTypes';
import { cosine, l2normalize, meanVector } from './HeartEncoder';

/** 一批查询向量 + 标签（标签给「为什么推这首」用） */
export class HeartQueries {
  queries: Float32Array[] = [];
  labels: string[] = [];

  get size(): number {
    return this.queries.length;
  }

  isEmpty(): boolean {
    return this.queries.length === 0;
  }
}

/** 拷贝一个向量（避免后续归一化改到调用方的数组） */
function copyOf(vec: Float32Array): Float32Array {
  const out: Float32Array = new Float32Array(vec.length);
  for (let i = 0; i < vec.length; i++) {
    out[i] = vec[i];
  }
  return out;
}

/** 向量是否接近零向量（全零 / 归一化失败） */
function isZero(vec: Float32Array): boolean {
  for (let i = 0; i < vec.length; i++) {
    if (vec[i] !== 0) {
      return false;
    }
  }
  return true;
}

/**
 * 球面 K-means（余弦）
 *
 * 两个必须遵守的细节，都是仓库踩过的静默 bug：
 *   1. **n <= K 时不许补零行**。零向量的余弦是 0，在 max 池化下会和真实低分并列，
 *      曾算出「K=∞ 上界 R@10 = 0.00%」这种假结果。这里直接返回 n 个中心。
 *   2. **空簇不许变成零向量**。迭代中某个簇没有点就保留上一轮中心（不重置）。
 *
 * 初始化用确定性「最远点」而不是 k-means++ 抽样：同输入同输出，单测与线上可复现。
 */
export function sphericalKmeans(vectors: Float32Array[], k: number, iters: number): Float32Array[] {
  const n: number = vectors.length;
  const out: Float32Array[] = [];
  if (n === 0 || k <= 0 || iters <= 0) {
    return out;
  }
  const kk: number = Math.min(k, n);
  out.push(copyOf(vectors[0]));
  while (out.length < kk) {
    let bestIdx: number = 0;
    let bestDist: number = -1;
    for (let i = 0; i < n; i++) {
      let maxSim: number = -2;
      for (let j = 0; j < out.length; j++) {
        const sim: number = cosine(vectors[i], out[j]);
        if (sim > maxSim) {
          maxSim = sim;
        }
      }
      const dist: number = 1 - maxSim;
      if (dist > bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }
    out.push(copyOf(vectors[bestIdx]));
  }
  const assign: Int32Array = new Int32Array(n);
  for (let iter = 0; iter < iters; iter++) {
    // E 步：每个点归到最近的（余弦最大的）中心
    for (let i = 0; i < n; i++) {
      let best: number = 0;
      let bestSim: number = -2;
      for (let j = 0; j < out.length; j++) {
        const sim: number = cosine(vectors[i], out[j]);
        if (sim > bestSim) {
          bestSim = sim;
          best = j;
        }
      }
      assign[i] = best;
    }
    // M 步：簇内求和再归一（球面质心）
    const sums: Float32Array[] = [];
    for (let j = 0; j < out.length; j++) {
      sums.push(new Float32Array(out[j].length));
    }
    for (let i = 0; i < n; i++) {
      const sum: Float32Array = sums[assign[i]];
      const vec: Float32Array = vectors[i];
      for (let d = 0; d < vec.length && d < sum.length; d++) {
        sum[d] += vec[d];
      }
    }
    for (let j = 0; j < out.length; j++) {
      const center: Float32Array = l2normalize(sums[j]);
      if (!isZero(center)) {
        out[j] = center;
      }
    }
  }
  return out;
}

/**
 * 短期向量：最近 M 首，权重 decay^(M-1-i)（越靠近现在越大）
 *
 * 仓库实测：短期必须有（去掉 M 掉一半以上），且必须强烈偏向最近（decay=0.5 最好，
 * 等权 1.0 最差）。
 */
export function shortTermVector(vectors: Float32Array[], window: number, decay: number,
  dim: number): Float32Array | null {
  if (vectors.length === 0 || window <= 0) {
    return null;
  }
  const start: number = Math.max(0, vectors.length - window);
  const count: number = vectors.length - start;
  const sum: Float32Array = new Float32Array(dim);
  for (let i = 0; i < count; i++) {
    const src: Float32Array = vectors[start + i];
    // i = 0 是最旧的一个，权重最小
    const weight: number = Math.pow(decay, count - 1 - i);
    for (let d = 0; d < dim && d < src.length; d++) {
      sum[d] += src[d] * weight;
    }
  }
  const norm: Float32Array = l2normalize(sum);
  if (isZero(norm)) {
    return null;
  }
  return norm;
}

/**
 * 组装查询矩阵：K 个长期兴趣 + 1 个短期向量
 *
 * 历史不足 K 点时 sphericalKmeans 返回 n 个中心（不补零），所以查询数可能小于 K+1。
 */
export function buildQueries(history: Float32Array[], dim: number, k: number = HEART_K,
  shortWindow: number = HEART_SHORT_M, shortDecay: number = HEART_SHORT_DECAY): HeartQueries {
  const out: HeartQueries = new HeartQueries();
  if (history.length === 0) {
    return out;
  }
  const centers: Float32Array[] = sphericalKmeans(history, k, HEART_KMEANS_ITERS);
  for (let i = 0; i < centers.length; i++) {
    out.queries.push(centers[i]);
    out.labels.push(`长期兴趣${i}`);
  }
  const shortVec: Float32Array | null = shortTermVector(history, shortWindow, shortDecay, dim);
  if (shortVec !== null) {
    out.queries.push(shortVec);
    out.labels.push('最近在听');
  }
  return out;
}

/** 对一批查询取最大余弦，返回命中下标；空查询返回 -1 */
export function bestQueryIndex(queries: Float32Array[], vec: Float32Array): number {
  let best: number = -1;
  let bestSim: number = -2;
  for (let i = 0; i < queries.length; i++) {
    const sim: number = cosine(queries[i], vec);
    if (sim > bestSim) {
      bestSim = sim;
      best = i;
    }
  }
  return best;
}

/** 对一批查询取最大余弦值（空查询返回 -2，调用方要判） */
export function bestCosine(queries: Float32Array[], vec: Float32Array): number {
  let bestSim: number = -2;
  for (let i = 0; i < queries.length; i++) {
    const sim: number = cosine(queries[i], vec);
    if (sim > bestSim) {
      bestSim = sim;
    }
  }
  return bestSim;
}

/** 冷启动：把几首种子直接当长期兴趣池（K 簇），不是求平均 */
export function seedQueries(seedVectors: Float32Array[], dim: number, k: number = HEART_K): HeartQueries {
  const out: HeartQueries = new HeartQueries();
  if (seedVectors.length === 0) {
    return out;
  }
  const centers: Float32Array[] = sphericalKmeans(seedVectors, k, HEART_KMEANS_ITERS);
  for (let i = 0; i < centers.length; i++) {
    out.queries.push(centers[i]);
    out.labels.push(`种子兴趣${i}`);
  }
  return out;
}

/** 供测试/调试：一组向量的平均（只在无历史时当兜底，不参与正常链路） */
export function fallbackMean(vectors: Float32Array[], dim: number): Float32Array | null {
  return meanVector(vectors, dim);
}
