/**
 * 心动模式 · 共享类型与调参常量
 *
 * 算法移植自 heartbeat_ondevice（端侧「心动模式」研究仓库），只保留它**实测有效**的
 * 那条链路：
 *
 *   元数据哈希编码 → 多兴趣表示（K 个长期兴趣 + 1 个短期向量，打分取 max）
 *   → 记账式重排（口味 EMA / 亲和 / 黑名单 / UCB / ε 探索）→ 播放 → 反馈回写
 *
 * 序列模型（GRU4Rec）与 DIN 排序器在该仓库的真实行为上都**负收益**（线上权重置 0），
 * 所以这里不移植，也就不需要任何推理框架。
 *
 * 约束：本目录所有文件**不 import 任何 @kit.\***，因此可以被 `entry/src/test` 下的
 * 主机单测直接跑（项目约定见 docs/UI_REPLICA.md）。
 */

/** 曲目向量维度。128 是仓库实测的饱和点：64→128 只涨 0.6 点，128→256 只涨 0.3 点却翻倍存储 */
export const HEART_DIM: number = 128;
/** 长期兴趣簇数。仓库实测 K=1~2 准确率最好，K 越大只换多样性；取 2 是折中 */
export const HEART_K: number = 2;
/** 短期窗口「最近 M 首」 */
export const HEART_SHORT_M: number = 10;
/** 短期权重衰减：0.5 明显好于等权（1.0）与 0.7/0.9 */
export const HEART_SHORT_DECAY: number = 0.5;
/** 兴趣聚类迭代次数 */
export const HEART_KMEANS_ITERS: number = 10;
/** ε-greedy 探索比例，防止「越听越窄」 */
export const HEART_EPS: number = 0.15;
/** 打分抖动：只用来打散并列，量级必须远小于真实分差 */
export const HEART_NOISE: number = 0.02;
/** 最近 N 个艺人不进候选（去窄化，仓库实测有效） */
export const HEART_EXCLUDE_ARTISTS: number = 3;
/** 最近 N 首不进候选（不连续重复） */
export const HEART_EXCLUDE_RECENT: number = 6;
/** 同一首歌被跳过的次数达到该值就拉黑 */
export const HEART_BLACKLIST_SKIPS: number = 2;
/** 新歌窗口（天）：入库时间在这之内算 fresh，给曝光加成 */
export const HEART_FRESH_DAYS: number = 30;
/** 历史向量的记忆上限：超过就丢最旧的，避免内存无界增长 */
export const HEART_HISTORY_MAX: number = 500;
/** 歌曲时长未知时的兜底值（毫秒），只用于算完播率 */
export const HEART_DEFAULT_DURATION_MS: number = 210000;
/** 计入「一次播放」的最短时长（毫秒），与 ListenLog 的 30 秒口径保持一致 */
export const HEART_PLAY_MS: number = 30000;
/** 完播线：与 ListenLog.COMPLETE_RATIO 同一口径（85%） */
export const HEART_COMPLETE_RATIO: number = 0.85;

/** 反馈分档（数值越小越负） */
export const FB_SKIP: number = 0;
export const FB_PLAY: number = 1;
export const FB_COMPLETE: number = 2;
export const FB_LIKE: number = 3;
export const FB_REPEAT: number = 4;

/** 反馈分档的中文名，调试面板与日志用 */
export function feedbackName(kind: number): string {
  if (kind === FB_SKIP) {
    return '跳过';
  }
  if (kind === FB_PLAY) {
    return '播放';
  }
  if (kind === FB_COMPLETE) {
    return '听完';
  }
  if (kind === FB_LIKE) {
    return '收藏';
  }
  if (kind === FB_REPEAT) {
    return '重复';
  }
  return '未知';
}

/**
 * 曲目元数据（算法侧的输入）
 *
 * 只收「应用里真的拿得到」的字段：本地歌来自 AVMetadataExtractor（name/singer/album/
 * duration），平台歌来自 musicInfo/interval。**没有流派、年份、artistId** —— 整个
 * 项目都不存在这三样，所以内容相似度只能靠歌名 / 歌手 / 专辑字符串。
 */
export class HeartDoc {
  /** 稳定 id（与播放队列的条目 id 同一口径） */
  id: string = '';
  name: string = '';
  singer: string = '';
  /** 专辑名；平台歌可能为空串 */
  album: string = '';
  /** 毫秒；未知为 0 */
  durationMs: number = 0;
  /** 入库时刻（毫秒）；平台歌可为 0（拿不到发行/入库时间时不算新歌） */
  addedAt: number = 0;
  /** 本地累计播放次数（热度兜底与 UCB 初值用） */
  plays: number = 0;
  /** 是否已收藏 */
  liked: boolean = false;
}

/** 曲目 + 向量：引擎内部用，构造后向量不变 */
export class HeartItem {
  doc: HeartDoc;
  vec: Float32Array;

  constructor(doc: HeartDoc, vec: Float32Array) {
    this.doc = doc;
    this.vec = vec;
  }
}

/** 权重表：与仓库 DEFAULT_WEIGHTS 对齐（seq/din 权重恒为 0，不设） */
export class HeartWeights {
  /** 多兴趣最大余弦（召回分 / 主信号） */
  dot: number = 1.0;
  /** 与口味 EMA 的余弦 */
  taste: number = 0.6;
  /** 艺人 / 专辑亲和计数 */
  affinity: number = 0.3;
  /** 新歌曝光 */
  fresh: number = 0.3;
  /** 非参数探索（曝光少的给一点补偿） */
  ucb: number = 0.05;
  /** ε-greedy 比例 */
  eps: number = HEART_EPS;
  /** 打散并列的抖动 */
  noise: number = HEART_NOISE;

  copy(): HeartWeights {
    const w = new HeartWeights();
    w.dot = this.dot;
    w.taste = this.taste;
    w.affinity = this.affinity;
    w.fresh = this.fresh;
    w.ucb = this.ucb;
    w.eps = this.eps;
    w.noise = this.noise;
    return w;
  }
}

/**
 * 一次推荐的结果
 *
 * components 是**真实打分明细**（不是事后解释）：界面上的「为什么推这首」直接读它，
 * 调试时也能一眼看出是哪个信号在起作用 —— 这是仓库里反复强调的「不许静默降级」。
 */
export class HeartPick {
  item: HeartItem | null = null;
  /** 总分（含抖动） */
  score: number = 0;
  /** 分项得分 */
  dot: number = 0;
  taste: number = 0;
  affinity: number = 0;
  fresh: number = 0;
  ucb: number = 0;
  noise: number = 0;
  /** 命中的兴趣簇下标（queries 的下标） */
  interest: number = 0;
  /** 本首是否走了 ε 探索 */
  explore: boolean = false;

  /** 给人看的分项文本，界面/日志直接用 */
  explain(): string {
    const name: string = this.item === null ? '空' : `${this.item.doc.name} - ${this.item.doc.singer}`;
    const parts: string[] = [
      `相似 ${this.dot.toFixed(3)}`,
      `口味 ${this.taste.toFixed(3)}`,
      `亲和 ${this.affinity.toFixed(3)}`,
      `新歌 ${this.fresh.toFixed(3)}`,
      `探索 ${this.ucb.toFixed(3)}`
    ];
    const tag: string = this.explore ? '（ε 探索）' : `（兴趣 ${this.interest}）`;
    return `${name}${tag}：${parts.join(' / ')} = ${this.score.toFixed(3)}`;
  }
}

/** 引擎可调的参数集合（构造时传一次） */
export class HeartOptions {
  dim: number = HEART_DIM;
  k: number = HEART_K;
  shortWindow: number = HEART_SHORT_M;
  shortDecay: number = HEART_SHORT_DECAY;
  excludeArtists: number = HEART_EXCLUDE_ARTISTS;
  excludeRecent: number = HEART_EXCLUDE_RECENT;
  blacklistSkips: number = HEART_BLACKLIST_SKIPS;
  freshDays: number = HEART_FRESH_DAYS;
  historyMax: number = HEART_HISTORY_MAX;
  /** 随机种子：固定后整条链路可复现（单测依赖这一点） */
  seed: number = 20261026;
  /** ε-greedy 比例（关掉探索传 0，单测靠它做确定性断言） */
  eps: number = HEART_EPS;
}
