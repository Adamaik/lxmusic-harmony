import { describe, it, expect } from '@ohos/hypium';
import { descText } from '../main/ets/core/music/MusicList';

/**
 * 歌单简介的清洗（core/music/MusicList.descText）
 *
 * 用例里的原文都是各平台真回过的写法：酷我用 `<br><br>` 分段（真机上曾把 `<br>`
 * 当文字画在界面上），酷狗整段带标签，QQ 是单 `<br>`，网易偶尔夹实体。
 */
export default function listDescTest() {
  describe('listDescTest', () => {
    it('rendersKuwoBrAsNewline', 0, () => {
      const out: string = descText('情话好听<br><br>情歌动听<br><br>皆因听懂人<br><br>往往就伤过人！！');
      expect(out).assertEqual('情话好听\n\n情歌动听\n\n皆因听懂人\n\n往往就伤过人！！');
      expect(out.includes('<br')).assertFalse();
    });

    it('handlesEveryBrSpelling', 0, () => {
      expect(descText('一<br>二')).assertEqual('一\n二');
      expect(descText('一<br/>二')).assertEqual('一\n二');
      expect(descText('一<br />二')).assertEqual('一\n二');
      expect(descText('一<BR>二')).assertEqual('一\n二');
    });

    it('stripsOtherTags', 0, () => {
      expect(descText('<p>第一段</p><p>第二段</p>')).assertEqual('第一段\n第二段');
      expect(descText('听<a href="https://x.com/a">这里</a>')).assertEqual('听这里');
    });

    it('decodesEntitiesAfterStrippingTags', 0, () => {
      expect(descText('民谣 &amp; 摇滚')).assertEqual('民谣 & 摇滚');
      // 原文里写着的字面量 &lt;br&gt; 不该变成换行
      expect(descText('就是 &lt;br&gt; 这个写法')).assertEqual('就是 <br> 这个写法');
    });

    it('collapsesBlankLinesAndSpaces', 0, () => {
      expect(descText('一<br><br><br><br>二')).assertEqual('一\n\n二');
      expect(descText('  多   空格  ')).assertEqual('多 空格');
      expect(descText('<br><br>开头空行')).assertEqual('开头空行');
      expect(descText('结尾空行<br><br>')).assertEqual('结尾空行');
    });

    it('returnsEmptyForEmptyInput', 0, () => {
      expect(descText('')).assertEqual('');
      expect(descText('<br>')).assertEqual('');
    });
  });
}
