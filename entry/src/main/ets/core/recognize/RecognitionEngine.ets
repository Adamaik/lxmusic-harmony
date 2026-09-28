import { RecognitionResult, EngineReport, EngineResultGroup } from './RecognitionTypes';
import { recognizeKugou } from './KugouRecognizer';
import { NeteaseRecognizer } from './NeteaseRecognizer';

/** 一次多引擎识别的总产出 */
export class MultiEngineOutput {
  /** 主结果（两个引擎归并排序后的第一名），没有任何候选时为 undefined */
  match: RecognitionResult | undefined = undefined;
  /** 逐引擎的候选列表（含失败原因），界面按引擎分组展示 */
  groups: Array<EngineResultGroup> = [];
  /** 逐引擎的一句话回执（命中 / 未匹配 / 出错） */
  engineReports: Array<EngineReport> = [];

  static create(match: RecognitionResult | undefined, groups: Array<EngineResultGroup>,
    engineReports: Array<EngineReport>): MultiEngineOutput {
    const output = new MultiEngineOutput();
    output.match = match;
    output.groups = groups;
    output.engineReports = engineReports;
    return output;
  }
}

const describeError = (reason: Object): string => {
  const record: Record<string, Object> = reason as Record<string, Object>;
  const message: Object = record['message'];
  if (typeof message === 'string') {
    return message;
  }
  return String(reason);
};

/**
 * 歌名归一化：小写、去掉括号里的修饰、只留字母数字
 *
 * 用来判断「两个引擎说的是不是同一首歌」——酷狗报「晴天 (Live)」、网易云报
 * 「晴天（现场版）」，归一化之后都能对上，才不会把同一首当成两首重复展示。
 */
const normalizeTitle = (value: string): string => {
  const bracketPattern: RegExp = new RegExp('[（(【[].*?[）)】\\]]', 'g');
  const nonWordPattern: RegExp = new RegExp('[^\\p{L}\\p{N}]', 'gu');
  return value.toLowerCase()
    .replace(bracketPattern, '')
    .replace(nonWordPattern, '');
};

/**
 * 合并两个引擎的结果并共同排名：
 *   1. 两个引擎都识别出的同一首歌（归一化标题相同）排最前 —— 共同确认，可信度最高；
 *   2. 酷狗独有的结果；
 *   3. 网易云独有的结果。
 * 每组内保持引擎自身返回顺序，同歌去重（优先保留酷狗条目）。
 */
const rankResults = (kgResults: Array<RecognitionResult>,
  wyResults: Array<RecognitionResult>): Array<RecognitionResult> => {
  const ranked: Array<RecognitionResult> = [];
  const seen: Set<string> = new Set();
  const wyByTitle: Map<string, RecognitionResult> = new Map();
  for (const item of wyResults) {
    const key: string = normalizeTitle(item.title);
    if (!wyByTitle.has(key)) {
      wyByTitle.set(key, item);
    }
  }
  // 第一轮：两边都有的，用酷狗那条当代表
  for (const item of kgResults) {
    const key: string = normalizeTitle(item.title);
    if (wyByTitle.has(key) && !seen.has(key)) {
      ranked.push(item);
      seen.add(key);
    }
  }
  // 第二轮：酷狗独有
  for (const item of kgResults) {
    const key: string = normalizeTitle(item.title);
    if (!seen.has(key)) {
      ranked.push(item);
      seen.add(key);
    }
  }
  // 第三轮：网易云独有
  for (const item of wyResults) {
    const key: string = normalizeTitle(item.title);
    if (!seen.has(key)) {
      ranked.push(item);
      seen.add(key);
    }
  }
  return ranked;
};

/**
 * 多引擎识别：酷狗与网易云并发执行，各自返回完整结果列表，
 * 归并后第一条作为主结果，两个引擎的列表均保留展示。
 *
 * 一个引擎失败不影响另一个：失败的原因记在它自己的 group / report 里，
 * 只要还有一个引擎给出候选，主结果就有值。
 */
export const recognizeAll = async(pcm: Int16Array,
  netease: NeteaseRecognizer): Promise<MultiEngineOutput> => {
  let kgError: string | undefined = undefined;
  let wyError: string | undefined = undefined;
  const kgPromise: Promise<Array<RecognitionResult> | undefined> = recognizeKugou(pcm)
    .then((results: Array<RecognitionResult>): Array<RecognitionResult> | undefined => results)
    .catch((reason: Object): Array<RecognitionResult> | undefined => {
      kgError = describeError(reason);
      return undefined;
    });
  const wyPromise: Promise<Array<RecognitionResult> | undefined> = netease.recognize(pcm)
    .then((results: Array<RecognitionResult>): Array<RecognitionResult> | undefined => results)
    .catch((reason: Object): Array<RecognitionResult> | undefined => {
      wyError = describeError(reason);
      return undefined;
    });

  const kgResults: Array<RecognitionResult> | undefined = await kgPromise;
  const wyResults: Array<RecognitionResult> | undefined = await wyPromise;

  let match: RecognitionResult | undefined = undefined;
  if (kgResults !== undefined || wyResults !== undefined) {
    const ranked: Array<RecognitionResult> = rankResults(kgResults ?? [], wyResults ?? []);
    if (ranked.length > 0) {
      match = ranked[0];
    }
  }

  const groups: Array<EngineResultGroup> = [];
  if (kgError !== undefined) {
    groups.push(EngineResultGroup.create('kg', [], kgError));
  } else if (kgResults !== undefined) {
    groups.push(EngineResultGroup.create('kg', kgResults, ''));
  }
  if (wyError !== undefined) {
    groups.push(EngineResultGroup.create('wy', [], wyError));
  } else if (wyResults !== undefined) {
    groups.push(EngineResultGroup.create('wy', wyResults, ''));
  }

  const engineReports: Array<EngineReport> = [];
  if (kgError !== undefined) {
    engineReports.push(EngineReport.create('kg', 'error'));
  } else {
    engineReports.push(EngineReport.create('kg',
      kgResults !== undefined && kgResults.length > 0 ? 'matched' : 'notMatched'));
  }
  if (wyError !== undefined) {
    engineReports.push(EngineReport.create('wy', 'error'));
  } else {
    engineReports.push(EngineReport.create('wy',
      wyResults !== undefined && wyResults.length > 0 ? 'matched' : 'notMatched'));
  }
  return MultiEngineOutput.create(match, groups, engineReports);
};
