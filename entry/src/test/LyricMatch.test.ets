import { describe, it, expect } from '@ohos/hypium';
import { LyricCandidate, normalizeForMatch, parseIntervalMs, pickAutoMatch, scoreCandidate, singerTokens } from
  '../main/ets/core/local/LyricMatch';
import { LxMusicInfo } from '../main/ets/core/music/MusicSearch';

/**
 * 本地歌的在线歌词匹配（core/local/LyricMatch）
 *
 * 打分函数是纯的，正好是这块最该被测的部分：它的策略是**宁缺勿错** ——
 * 配错的歌词比没有歌词更难解释。所以这里重点钉两件事：
 *   1. 该自动采用的时候要采用（歌名一致 + 歌手或时长有一个对上）；
 *   2. 拿不准的时候一定要拒绝（歌名对但什么都不能佐证、时长差太多的另一个版本）。
 */
function info(name: string, singer: string, interval: string): LxMusicInfo {
  return {
    name: name,
    singer: singer,
    source: 'kw',
    songmid: 'm1',
    albumName: '',
    albumId: '',
    interval: interval,
    img: '',
    types: [],
    _types: {},
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
}

/** 本地歌：普通朋友 / 陶喆 / 4:24 */
function candidate(remote: LxMusicInfo): LyricCandidate {
  return scoreCandidate(remote, '普通朋友', '陶喆', 264000);
}

export default function lyricMatchTest() {
  describe('lyricMatchTest', () => {
    it('parsesInterval', 0, () => {
      expect(parseIntervalMs('04:24')).assertEqual(264000);
      expect(parseIntervalMs('4:24')).assertEqual(264000);
      expect(parseIntervalMs('')).assertEqual(0);
      expect(parseIntervalMs('不是时长')).assertEqual(0);
    });

    it('splitsSingerNames', 0, () => {
      expect(singerTokens('周杰伦/袁咏琳').length).assertEqual(2);
      expect(singerTokens('周杰伦、袁咏琳').length).assertEqual(2);
      expect(singerTokens('陶喆').length).assertEqual(1);
    });

    it('normalizesNameAndDropsBrackets', 0, () => {
      // 与 PlaySession.normalizeName 同一套口径：小写 + 去空白 + 去括号字符
      expect(normalizeForMatch('普通朋友 (Live)')).assertEqual('普通朋友live');
    });

    it('autoMatchesSameNameSameSinger', 0, () => {
      // 歌名一致 + 歌手命中 + 时长 4:24 完全一致 -> 该采用
      const scored: LyricCandidate = candidate(info('普通朋友', '陶喆', '04:24'));
      expect(scored.nameExact).assertTrue();
      expect(scored.singerHit).assertTrue();
      expect(scored.autoOk).assertTrue();
      expect(pickAutoMatch([scored]) !== null).assertTrue();
    });

    it('autoMatchesCoverWithSameDuration', 0, () => {
      // 翻唱：歌手对不上，但时长几乎一致 —— 同一首歌的歌词是一样的，可以采用
      const scored: LyricCandidate = candidate(info('普通朋友', '某翻唱歌手', '04:26'));
      expect(scored.singerHit).assertFalse();
      expect(scored.durationDiffMs).assertEqual(2000);
      expect(scored.autoOk).assertTrue();
    });

    it('rejectsWhenNothingCorroborates', 0, () => {
      // 歌名一致，但本地没歌手也没时长（标签全缺）-> 拒绝。
      // 这一条就是「宁可没有歌词」：同名歌太多，只靠歌名挑第一条迟早配错。
      const scored: LyricCandidate = scoreCandidate(info('普通朋友', '陶喆', '04:24'), '普通朋友', '', 0);
      expect(scored.nameExact).assertTrue();
      expect(scored.autoOk).assertFalse();
      expect(pickAutoMatch([scored])).assertNull();
    });

    it('rejectsDifferentVersionByDuration', 0, () => {
      // 歌名歌手都对，但时长差 5 分钟（现场版 / 串烧）-> 拒绝
      const scored: LyricCandidate = candidate(info('普通朋友', '陶喆', '09:30'));
      expect(scored.autoOk).assertFalse();
      expect(scored.score).assertEqual(0);
    });

    it('rejectsDifferentSong', 0, () => {
      // 歌名都对不上：哪怕歌手一样也不能用
      const scored: LyricCandidate = candidate(info('爱很简单', '陶喆', '04:24'));
      expect(scored.nameExact).assertFalse();
      expect(scored.nameClose).assertFalse();
      expect(scored.autoOk).assertFalse();
    });

    it('acceptsBracketedNameOnlyWithBothSignals', 0, () => {
      // 歌名只是包含关系（本地 `普通朋友(live)` vs 平台 `普通朋友`）：歌手与时长都要对上才采用
      const both: LyricCandidate = scoreCandidate(info('普通朋友', '陶喆', '04:25'), '普通朋友(live)', '陶喆', 264000);
      expect(both.nameClose).assertTrue();
      expect(both.autoOk).assertTrue();

      const singerOnly: LyricCandidate = scoreCandidate(info('普通朋友', '陶喆', '02:10'), '普通朋友(live)', '陶喆', 264000);
      expect(singerOnly.autoOk).assertFalse();
    });

    it('picksClosestDuration', 0, () => {
      const far: LyricCandidate = candidate(info('普通朋友', '陶喆', '04:29'));
      const near: LyricCandidate = candidate(info('普通朋友', '陶喆', '04:25'));
      const picked: LxMusicInfo | null = pickAutoMatch([far, near]);
      expect(picked !== null).assertTrue();
      expect(picked?.interval).assertEqual('04:25');
    });
  });
}
