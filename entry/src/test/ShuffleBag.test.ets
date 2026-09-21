import { describe, it, expect } from '@ohos/hypium';
import { ShuffleBag } from '../main/ets/core/player/ShuffleBag';

/**
 * 随机播放的「一轮之内不重复」（core/player/ShuffleBag）
 *
 * 这条规则是用户能听出来的（一轮里不该有歌重复，也不该有歌被跳过），而且它和预取
 * 的「抽签不占名额」是两套语义，容易写错 —— 所以单独测。
 * 用例里的 total = 队列长度、version = PlaySession 的 queueVersion、current = 当前下标。
 */
const TOTAL: number = 5;

/** 从 start 出发连着播 n 次「下一首」，返回走过的下标（含起点） */
function walk(bag: ShuffleBag, version: number, start: number, n: number): number[] {
  const path: number[] = [start];
  let current: number = start;
  for (let i = 0; i < n; i++) {
    const next: number = bag.pick(TOTAL, version, current, true);
    path.push(next);
    current = next;
  }
  return path;
}

function indexSet(values: number[]): Set<number> {
  const set: Set<number> = new Set<number>();
  for (const value of values) {
    set.add(value);
  }
  return set;
}

export default function shuffleBagTest() {
  describe('shuffleBagTest', () => {
    it('coversEveryTrackExactlyOncePerRound', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      const path: number[] = walk(bag, 0, 0, TOTAL - 1);
      // 起点 + 后面 4 签 = 队列里 5 首各一次，不重复也不漏
      expect(indexSet(path).size).assertEqual(TOTAL);
      expect(path.length).assertEqual(TOTAL);
      for (const index of path) {
        expect(index >= 0 && index < TOTAL).assertTrue();
      }
    });

    it('neverPicksTheTrackPlayingNow', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      let current: number = 0;
      for (let i = 0; i < 20; i++) {
        const next: number = bag.pick(TOTAL, 0, current, true);
        expect(next === current).assertFalse();
        current = next;
      }
    });

    it('startsNewRoundAfterAllPlayed', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      // 先走完一轮
      const first: number[] = walk(bag, 0, 0, TOTAL - 1);
      const last: number = first[first.length - 1];
      // 再往下：进入新一轮，第一签不能又是刚放完的这首
      const next: number = bag.pick(TOTAL, 0, last, true);
      expect(next === last).assertFalse();
      expect(next >= 0 && next < TOTAL).assertTrue();
      // 新一轮里剩下的 3 首还能各抽到一次（连同刚才那一签共 4 个不同下标）
      const seen: Set<number> = new Set<number>();
      seen.add(next);
      let current: number = next;
      for (let i = 0; i < TOTAL - 2; i++) {
        current = bag.pick(TOTAL, 0, current, true);
        seen.add(current);
      }
      expect(seen.size).assertEqual(TOTAL - 1);
    });

    it('peekDoesNotConsumeTheRound', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      // 预取抽签（mark=false）：连抽多次不影响本轮名额
      for (let i = 0; i < 10; i++) {
        const peek: number = bag.pick(TOTAL, 0, 0, false);
        expect(peek !== 0).assertTrue();
      }
      // 之后仍然能完整走完一轮：5 首各一次
      const path: number[] = walk(bag, 0, 0, TOTAL - 1);
      expect(indexSet(path).size).assertEqual(TOTAL);
    });

    it('peekMayRepeatItself', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      // 不记名额 => 抽到同一首是允许的（预取本来就可能抽到刚才预取过的那首）
      let repeated: boolean = false;
      let previous: number = bag.pick(TOTAL, 0, 0, false);
      for (let i = 0; i < 40; i++) {
        const pick: number = bag.pick(TOTAL, 0, 0, false);
        if (pick === previous) {
          repeated = true;
        }
        previous = pick;
      }
      expect(repeated).assertTrue();
    });

    it('newQueueVersionRestartsTheRound', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      walk(bag, 0, 0, TOTAL - 1);
      // 队列换过（version 变）：之前「放过」的记录作废，可以再抽到第一轮的第一首
      const path: number[] = walk(bag, 1, 0, TOTAL - 2);
      expect(path.length).assertEqual(TOTAL - 1);
      expect(indexSet(path).size).assertEqual(TOTAL - 1);
    });

    it('marksTracksPlayedByHand', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      // 先抽一签让袋子与队列对齐（真实流程也是这样：上一首/预取已经动过袋子），
      // 再手动记一首「已放」—— 「上一首」退回的那首马上要播，走的就是这条路
      bag.pick(TOTAL, 0, 0, false);
      bag.markPlayed(3);
      let current: number = 0;
      for (let i = 0; i < TOTAL - 2; i++) {
        current = bag.pick(TOTAL, 0, current, true);
        // 3 已经记过，本轮剩下的名额里不该再有它
        expect(current === 3).assertFalse();
      }
    });

    it('handlesSingleTrackQueue', 0, () => {
      const bag: ShuffleBag = new ShuffleBag();
      expect(bag.pick(1, 0, 0, true)).assertEqual(0);
      expect(bag.pick(0, 0, -1, true)).assertEqual(-1);
    });
  });
}

