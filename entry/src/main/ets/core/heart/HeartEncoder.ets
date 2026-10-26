/**
 * 心动模式 · 曲目编码器（元数据 → 向量）
 *
 * 为什么不用预训练模型：
 *   1. 应用里拿不到音频 PCM（音源是加密/流式链接，AVPlayer 不吐原始采样），
 *      音频塔这条路物理上走不通；仓库实测音频嵌入单独用 R@10 也只有 0.12%。
 *   2. 元数据上做「哈希技巧 + IDF」就够用：仓库里同艺人召回@10 = 0.84，是最强的信号；
 *      训练出来的文本塔相比未训练只多约 5 个点（52.41% vs 47.38%），不值得为它
 *      背一个模型文件与推理链路。
 *
 * 做法：标题（CJK 单字 + 相邻 bigram、拉丁词）+ 艺人整体（权重 3）+ 专辑整体（权重 2），
 * signed hashing 落到 dim 维，乘 IDF，最后 L2 归一 —— 之后相似度就是纯点积。
 *
 * 注意：哈希技巧的「不变量」只要求**同一份代码算同一个字符串得到同一个桶**，
 * 不需要与 Python 端逐位一致（仓库的 blake2b 我们换成 FNV-1a，零依赖且更快）。
 */

import { HeartDoc, HEART_DIM } from './HeartTypes';

/** 一个分词结果：文本 + 权重（同一文本出现多次就累加） */
export class HeartToken {
  text: string = '';
  weight: number = 1;

  constructor(text: string, weight: number) {
    this.text = text;
    this.weight = weight;
  }
}

/** CJK 统一表意文字（含扩展 A） */
function isCjk(code: number): boolean {
  return (code >= 0x3400 && code <= 0x4DBF) || (code >= 0x4E00 && code <= 0x9FFF);
}

function isAsciiDigit(code: number): boolean {
  return code >= 48 && code <= 57;
}

function isAsciiLetter(code: number): boolean {
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isAsciiAlnum(code: number): boolean {
  return isAsciiDigit(code) || isAsciiLetter(code);
}

/**
 * 归一化：小写、标点/括号/符号统一变空格、压缩连续空格
 *
 * 不做「去掉括号内容」之类的花活：现场演出版、remix 版的括号里往往正是区分度最高的词
 * （比如 (Live) / (伴奏)），去掉反而把不同版本混成一类。
 */
export function normalizeText(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  let spaced: string = '';
  for (let i = 0; i < raw.length; i++) {
    const code: number = raw.charCodeAt(i);
    if (isCjk(code) || isAsciiAlnum(code)) {
      spaced += raw.charAt(i).toLowerCase();
    } else {
      spaced += ' ';
    }
  }
  let out: string = '';
  let prevSpace: boolean = true;
  for (let i = 0; i < spaced.length; i++) {
    const ch: string = spaced.charAt(i);
    if (ch === ' ') {
      if (!prevSpace) {
        out += ' ';
      }
      prevSpace = true;
    } else {
      out += ch;
      prevSpace = false;
    }
  }
  return out.trim();
}

/** FNV-1a 32 位：零依赖、确定、够散（ArkTS 没有内置哈希，crypto 又要 import @kit.*） */
export function fnv1a(text: string): number {
  let h: number = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  }
  return h >>> 0;
}

/** 把一个字段的文本切成 token：拉丁词整体、CJK 单字 + 相邻 bigram */
function pushFieldTokens(out: HeartToken[], text: string, baseWeight: number, prefix: string): void {
  const norm: string = normalizeText(text);
  if (norm.length === 0) {
    return;
  }
  const segments: string[] = norm.split(' ');
  for (let s = 0; s < segments.length; s++) {
    const seg: string = segments[s];
    if (seg.length === 0) {
      continue;
    }
    const firstCode: number = seg.charCodeAt(0);
    if (isAsciiAlnum(firstCode)) {
      // 拉丁词 / 数字：整词算一个 token（英文歌名词数不多，不用再切）
      out.push(new HeartToken(prefix + seg, baseWeight));
      continue;
    }
    // CJK：单字 + 相邻 bigram。bigram 能抓住「情歌」「夜曲」这类词感，单字保证召回
    for (let i = 0; i < seg.length; i++) {
      out.push(new HeartToken(prefix + seg.charAt(i), baseWeight));
      if (i + 1 < seg.length) {
        out.push(new HeartToken(prefix + seg.substring(i, i + 2), baseWeight));
      }
    }
  }
}

/**
 * 曲目 → token 列表
 *
 * 权重：标题 1、艺��� 3、专辑 2。艺人是仓库里最强的信号（同艺人召回 0.84），
 * 但也正因为强，**只看艺人会退化成「单曲循环」** —— 所以它只是三个证据之一，
 * 剩下的靠多兴趣、口味 EMA 与 ε 探索平衡。
 */
export function tokenize(doc: HeartDoc): HeartToken[] {
  const out: HeartToken[] = [];
  pushFieldTokens(out, doc.name, 1.0, 't:');
  const artist: string = normalizeText(doc.singer);
  if (artist.length > 0) {
    out.push(new HeartToken('a:' + artist, 3.0));
  }
  const album: string = normalizeText(doc.album);
  if (album.length > 0) {
    out.push(new HeartToken('b:' + album, 2.0));
  }
  return out;
}

/** L2 归一（原地）；零向量原样返回，调用方要自己判 0 */
export function l2normalize(vec: Float32Array): Float32Array {
  let sum: number = 0;
  for (let i = 0; i < vec.length; i++) {
    sum += vec[i] * vec[i];
  }
  if (sum <= 1e-12) {
    return vec;
  }
  const inv: number = 1 / Math.sqrt(sum);
  for (let i = 0; i < vec.length; i++) {
    vec[i] = vec[i] * inv;
  }
  return vec;
}

/** 余弦（两个向量都已 L2 归一，就是点积；这里仍做除数保护） */
export function cosine(a: Float32Array, b: Float32Array): number {
  const n: number = Math.min(a.length, b.length);
  let dot: number = 0;
  let na: number = 0;
  let nb: number = 0;
  for (let i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  const denom: number = Math.sqrt(na) * Math.sqrt(nb);
  if (denom <= 1e-12) {
    return 0;
  }
  return dot / denom;
}

/** 均值向量（自动归一），空输入返回 null */
export function meanVector(vecs: Float32Array[], dim: number): Float32Array | null {
  if (vecs.length === 0) {
    return null;
  }
  const sum: Float32Array = new Float32Array(dim);
  for (let i = 0; i < vecs.length; i++) {
    const v: Float32Array = vecs[i];
    for (let d = 0; d < dim && d < v.length; d++) {
      sum[d] += v[d];
    }
  }
  return l2normalize(sum);
}

/**
 * 编码器：先 `fit(全库)` 统计 IDF，再逐曲 `encode` 出向量
 *
 * IDF 在**本地库**上现算，因此不依赖任何离线训练产物：
 * 库里人人都有的词（比如某个高频流派词、或"精选"这种专辑词）权重自动压低。
 */
export class HeartEncoder {
  private dim: number;
  private idf: Map<string, number> = new Map<string, number>();
  private fitted: boolean = false;

  constructor(dim: number = HEART_DIM) {
    this.dim = dim;
  }

  get dimension(): number {
    return this.dim;
  }

  get isFitted(): boolean {
    return this.fitted;
  }

  /** 统计文档频率；同一首歌里重复出现的 token 只算一次 */
  fit(docs: HeartDoc[]): void {
    this.idf = new Map<string, number>();
    const df: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < docs.length; i++) {
      const seen: Set<string> = new Set<string>();
      const tokens: HeartToken[] = tokenize(docs[i]);
      for (let t = 0; t < tokens.length; t++) {
        const key: string = tokens[t].text;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const cur: number | undefined = df.get(key);
        df.set(key, (cur === undefined ? 0 : cur) + 1);
      }
    }
    const total: number = docs.length;
    df.forEach((count: number, key: string) => {
      // 平滑 IDF，并截断到 [0.2, 3]：极端稀有词（某首歌独有的词）不该压过艺人
      const raw: number = Math.log((total + 1) / (count + 0.5));
      let value: number = raw;
      if (value < 0.2) {
        value = 0.2;
      }
      if (value > 3) {
        value = 3;
      }
      this.idf.set(key, value);
    });
    this.fitted = true;
  }

  /** 单曲编码：signed hashing → IDF 加权 → L2 归一 */
  encode(doc: HeartDoc): Float32Array {
    const vec: Float32Array = new Float32Array(this.dim);
    const tokens: HeartToken[] = tokenize(doc);
    for (let i = 0; i < tokens.length; i++) {
      const token: HeartToken = tokens[i];
      const h: number = fnv1a(token.text);
      const idx: number = h % this.dim;
      const idf: number | undefined = this.idf.get(token.text);
      const weight: number = token.weight * (this.fitted && idf !== undefined ? idf : 1);
      // 符号位取哈希的另一半：让「哈希冲突」互相抵消而不是单向累加（仓库同款做法）
      const sign: number = ((h >>> 16) & 1) === 0 ? 1 : -1;
      vec[idx] += sign * weight;
    }
    return l2normalize(vec);
  }

  /** 批量编码（全库一次，调用方负责缓存） */
  encodeAll(docs: HeartDoc[]): Float32Array[] {
    const out: Float32Array[] = [];
    for (let i = 0; i < docs.length; i++) {
      out.push(this.encode(docs[i]));
    }
    return out;
  }
}
