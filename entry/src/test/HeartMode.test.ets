import { describe, it, expect } from '@ohos/hypium';
import {
  FB_COMPLETE,
  FB_LIKE,
  FB_PLAY,
  FB_REPEAT,
  FB_SKIP,
  HeartDoc,
  HeartOptions
} from '../main/ets/core/heart/HeartTypes';
import {
  cosine,
  HeartEncoder,
  l2normalize,
  normalizeText,
  tokenize,
  HeartToken
} from '../main/ets/core/heart/HeartEncoder';
import {
  bestCosine,
  bestQueryIndex,
  buildQueries,
  HeartQueries,
  shortTermVector,
  sphericalKmeans
} from '../main/ets/core/heart/HeartInterest';
import { HeartProfile } from '../main/ets/core/heart/HeartProfile';
import { completionRatio, feedbackOf, feedbackWithContext } from '../main/ets/core/heart/HeartFeedback';
import { HeartEngine } from '../main/ets/core/heart/HeartEngine';

/**
 * 心动模式内核（core/heart）
 *
 * 这里测的都是「会静默出错」的地方：归一化没做、K 大于样本数时补零、池化方式写反、
 * 反馈分档边界、以及整条链路的可复现性。心跳模式里这些错都不会报错，只会推得不对。
 */

function doc(id: string, name: string, singer: string, album: string): HeartDoc {
  const d: HeartDoc = new HeartDoc();
  d.id = id;
  d.name = name;
  d.singer = singer;
  d.album = album;
  d.durationMs = 200000;
  return d;
}

function norm(vec: Float32Array): number {
  let sum: number = 0;
  for (let i = 0; i < vec.length; i++) {
    sum += vec[i] * vec[i];
  }
  return Math.sqrt(sum);
}

function near(actual: number, wanted: number, tol: number): boolean {
  return Math.abs(actual - wanted) <= tol;
}

/** 造一个 60 首的合成库：6 位艺人 × 10 首，歌名带中文与英文混排 */
function syntheticLibrary(): HeartDoc[] {
  const artists: string[] = ['张杰', '孙燕姿', '陈奕迅', '周杰伦', 'Taylor Swift', 'Coldplay'];
  const words: string[] = ['夜曲', '情歌', '晴天', '小幸运', 'Love Story', 'Yellow',
    '后来', '遇见', '浮夸', '安静'];
  const docs: HeartDoc[] = [];
  for (let a = 0; a < artists.length; a++) {
    for (let w = 0; w < words.length; w++) {
      const id: string = `d${a * words.length + w}`;
      docs.push(doc(id, `${words[w]} ${w + 1}`, artists[a], `专辑${a}`));
    }
  }
  return docs;
}

export default function heartModeTest() {
  describe('heartModeTest', () => {
    it('encoder_同一首歌余弦为1且已归一化', 0, () => {
      const enc: HeartEncoder = new HeartEncoder(128);
      const docs: HeartDoc[] = syntheticLibrary();
      enc.fit(docs);
      const a: Float32Array = enc.encode(docs[0]);
      const b: Float32Array = enc.encode(docs[0]);
      expect(near(norm(a), 1, 1e-5)).assertTrue();
      expect(near(cosine(a, b), 1, 1e-6)).assertTrue();
    });

    it('encoder_同艺人比跨艺人更相近', 0, () => {
      const enc: HeartEncoder = new HeartEncoder(128);
      const docs: HeartDoc[] = syntheticLibrary();
      enc.fit(docs);
      // 同一个艺人（张杰）的两首不同歌 vs 跨艺人的两首
      const x1: Float32Array = enc.encode(doc('x1', '夜曲 1', '张杰', '专辑0'));
      const x2: Float32Array = enc.encode(doc('x2', '晴天 3', '张杰', '专辑0'));
      const y: Float32Array = enc.encode(doc('y1', 'Love Story 5', 'Taylor Swift', '专辑4'));
      expect(cosine(x1, x2) > cosine(x1, y)).assertTrue();
    });

    it('tokenizer_中文出单字与相邻bigram', 0, () => {
      const tokens: HeartToken[] = tokenize(doc('t1', '夜曲', '张杰', ''));
      let hasSingle: boolean = false;
      let hasBi: boolean = false;
      for (let i = 0; i < tokens.length; i++) {
        const text: string = tokens[i].text;
        if (text === 't:夜') {
          hasSingle = true;
        }
        if (text === 't:夜曲') {
          hasBi = true;
        }
      }
      expect(hasSingle).assertTrue();
      expect(hasBi).assertTrue();
    });

    it('normalize_标点变空格且小写', 0, () => {
      expect(normalizeText('Hello, World!（Live）')).assertEqual('hello world live');
    });

    it('feedback_边界分档符合口径', 0, () => {
      // 10 秒 / 200 秒：跳过
      expect(feedbackOf(10000, 200000)).assertEqual(FB_SKIP);
      // 90 秒 / 200 秒 = 45%：播放
      expect(feedbackOf(90000, 200000)).assertEqual(FB_PLAY);
      // 180 秒 / 200 秒 = 90%：听完
      expect(feedbackOf(180000, 200000)).assertEqual(FB_COMPLETE);
      // 时长未知：20 秒按兜底 210 秒算，仍算跳过
      expect(feedbackOf(20000, 0)).assertEqual(FB_SKIP);
      // 显式信号优先
      expect(feedbackWithContext(0, 0, true, 0)).assertEqual(FB_LIKE);
      expect(feedbackWithContext(190000, 200000, false, 3)).assertEqual(FB_REPEAT);
      expect(near(completionRatio(100000, 200000), 0.5, 1e-9)).assertTrue();
    });

    it('kmeans_样本数小于K时不补零行', 0, () => {
      const a: Float32Array = l2normalize(new Float32Array([1, 0, 0, 0]));
      const b: Float32Array = l2normalize(new Float32Array([0, 1, 0, 0]));
      const centers: Float32Array[] = sphericalKmeans([a, b], 4, 8);
      expect(centers.length).assertEqual(2);
      for (let i = 0; i < centers.length; i++) {
        expect(norm(centers[i]) > 0.9).assertTrue();
      }
    });

    it('kmeans_两簇能被分开', 0, () => {
      const a1: Float32Array = l2normalize(new Float32Array([1, 0.1, 0, 0]));
      const a2: Float32Array = l2normalize(new Float32Array([1, 0, 0.1, 0]));
      const b1: Float32Array = l2normalize(new Float32Array([0, 0, 0.1, 1]));
      const b2: Float32Array = l2normalize(new Float32Array([0.1, 0, 0, 1]));
      const centers: Float32Array[] = sphericalKmeans([a1, a2, b1, b2], 2, 10);
      expect(centers.length).assertEqual(2);
      expect(cosine(centers[0], centers[1]) < 0.5).assertTrue();
    });

    it('多兴趣_查询取max而不是平均', 0, () => {
      const a1: Float32Array = l2normalize(new Float32Array([1, 0, 0, 0]));
      const a2: Float32Array = l2normalize(new Float32Array([0.95, 0.05, 0, 0]));
      const b1: Float32Array = l2normalize(new Float32Array([0, 0, 0, 1]));
      const b2: Float32Array = l2normalize(new Float32Array([0, 0, 0.05, 0.95]));
      const queries: HeartQueries = buildQueries([a1, a2, b1, b2], 4, 2, 10, 0.5);
      expect(queries.isEmpty()).assertFalse();
      // 一首明显属于 B 簇的候选：max 余弦应该很高；平均向量只有约 0.7
      const cand: Float32Array = l2normalize(new Float32Array([0, 0, 0, 1]));
      const maxSim: number = bestCosine(queries.queries, cand);
      expect(maxSim > 0.95).assertTrue();
      const idx: number = bestQueryIndex(queries.queries, cand);
      expect(idx >= 0).assertTrue();
    });

    it('短期向量_越近权重越大', 0, () => {
      const oldVec: Float32Array = l2normalize(new Float32Array([1, 0]));
      const newVec: Float32Array = l2normalize(new Float32Array([0, 1]));
      const short: Float32Array | null = shortTermVector([oldVec, newVec], 2, 0.5, 2);
      expect(short === null).assertFalse();
      if (short !== null) {
        // 最近一首（newVec）权重 1，旧的一首权重 0.5 → 更靠近 newVec
        expect(cosine(short, newVec) > cosine(short, oldVec)).assertTrue();
      }
    });

    it('profile_跳一次拉黑且口味会动', 0, () => {
      const profile: HeartProfile = new HeartProfile(4);
      const seedVec: Float32Array = l2normalize(new Float32Array([1, 0, 0, 0]));
      profile.seed([seedVec]);
      const d: HeartDoc = doc('k1', '某首歌', '某艺人', '某专辑');
      const other: Float32Array = l2normalize(new Float32Array([0, 1, 0, 0]));
      profile.update(d, FB_LIKE, other);
      expect(profile.isBlacklisted('k1')).assertFalse();
      expect(profile.affinityBonus(d) > 0).assertTrue();
      profile.update(d, FB_SKIP, other);
      expect(profile.isBlacklisted('k1')).assertTrue();
    });

    it('engine_端到端能出歌且分项不含NaN', 0, () => {
      const docs: HeartDoc[] = syntheticLibrary();
      const options: HeartOptions = new HeartOptions();
      options.eps = 0; // 关探索，结果可断言
      const engine: HeartEngine = new HeartEngine(options);
      engine.setLibrary(docs);
      engine.setSeeds([docs[0], docs[10], docs[20]]);
      const pick = engine.nextTrack();
      expect(pick === null).assertFalse();
      if (pick !== null && pick.item !== null) {
        expect(pick.item.doc.id.length > 0).assertTrue();
        expect(Number.isNaN(pick.score)).assertFalse();
        expect(pick.dot >= -1 && pick.dot <= 1).assertTrue();
        expect(pick.explain().length > 0).assertTrue();
      }
      expect(engine.librarySize).assertEqual(60);
    });

    it('engine_观察后不进最近队列且能继续推', 0, () => {
      const docs: HeartDoc[] = syntheticLibrary();
      const options: HeartOptions = new HeartOptions();
      options.eps = 0;
      const engine: HeartEngine = new HeartEngine(options);
      engine.setLibrary(docs);
      engine.setSeeds([docs[0], docs[10]]);
      let lastId: string = '';
      for (let i = 0; i < 5; i++) {
        const pick = engine.nextTrack();
        if (pick === null || pick.item === null) {
          break;
        }
        lastId = pick.item.doc.id;
        engine.observe(pick.item.doc, FB_COMPLETE);
        // 刚听过的不该立刻被再次推荐
        const again = engine.nextTrack();
        if (again !== null && again.item !== null) {
          expect(again.item.doc.id === lastId).assertFalse();
        }
      }
      expect(engine.historyLength > 0).assertTrue();
    });

    it('engine_成批出歌批内不重复', 0, () => {
      const docs: HeartDoc[] = syntheticLibrary();
      const options: HeartOptions = new HeartOptions();
      options.eps = 0;
      const engine: HeartEngine = new HeartEngine(options);
      engine.setLibrary(docs);
      engine.setSeeds([docs[0]]);
      const picks = engine.nextBatch(10);
      expect(picks.length).assertEqual(10);
      const ids: Set<string> = new Set<string>();
      const artists: Set<string> = new Set<string>();
      for (let i = 0; i < picks.length; i++) {
        const pick = picks[i];
        if (pick.item !== null) {
          ids.add(pick.item.doc.id);
          artists.add(pick.item.doc.singer);
        }
      }
      expect(ids.size).assertEqual(10);
      expect(artists.size >= 5).assertTrue();
    });

    it('engine_固定种子可复现', 0, () => {
      const docs: HeartDoc[] = syntheticLibrary();
      const a: HeartEngine = new HeartEngine(new HeartOptions());
      a.setLibrary(docs);
      a.setSeeds([docs[3], docs[7]]);
      const b: HeartEngine = new HeartEngine(new HeartOptions());
      b.setLibrary(docs);
      b.setSeeds([docs[3], docs[7]]);
      const pa = a.nextTrack();
      const pb = b.nextTrack();
      expect(pa !== null && pb !== null).assertTrue();
      if (pa !== null && pb !== null && pa.item !== null && pb.item !== null) {
        expect(pa.item.doc.id).assertEqual(pb.item.doc.id);
      }
    });
  });
}
