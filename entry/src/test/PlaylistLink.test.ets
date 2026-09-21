import { describe, it, expect } from '@ohos/hypium';
import { firstUrl, linkOf, parseShareText, platformOfUrl, PlaylistLink } from
  '../main/ets/core/music/PlaylistLink';

/** 一条分享文本应当解析出的结果 */
interface LinkCase {
  text: string;
  source: string;
  id: string;
}

/**
 * 真实分享文本（各平台「分享」里复制出来的样子）
 *
 * 期望值来自洛雪各平台 songList 的 listDetailLink 正则，不是照着本实现的输出反填的：
 *   wy  /^.+(?:\?|&)id=(\d+)/ 与 /^.+\/playlist\/(\d+)\/\d+\/.+$/
 *   mg  /^.+\/playlist\/(\d+)/ 与 playlistId=id
 *   kw  /^.+\/playlist(?:_detail)?\/(\d+)/
 *   kg  /^.+\/(\d+)\.html/
 *   tx  /\/playlist\/(\d+)/ 与 /id=(\d+)/
 */
const CASES: LinkCase[] = [
  {
    text: '分享歌单《周杰伦》https://music.163.com/#/playlist?id=2892110024 快来听',
    source: 'wy',
    id: '2892110024',
  },
  { text: 'https://music.163.com/playlist?id=123456&userid=99', source: 'wy', id: '123456' },
  { text: 'https://music.163.com/playlist/123456/1/2', source: 'wy', id: '123456' },
  {
    text: 'https://i.y.qq.com/n2/m/share/details/taoge.html?id=7381274237&hosteuin=xxx',
    source: 'tx',
    id: '7381274237',
  },
  { text: 'https://y.qq.com/n/ryqq/playlist/7823431554', source: 'tx', id: '7823431554' },
  { text: 'https://www.kugou.com/yy/special/single/1067062.html', source: 'kg', id: '1067062' },
  { text: 'https://www.kuwo.cn/playlist_detail/2892110024', source: 'kw', id: '2892110024' },
  { text: 'https://m.kuwo.cn/h5app/playlist/123456?from=share', source: 'kw', id: '123456' },
  {
    text: 'https://music.migu.cn/v5/#/playlist?playlistId=221573417',
    source: 'mg',
    id: '221573417',
  },
  {
    text: 'https://h5.nf.migu.cn/app/v4/p/share/playlist/index.html?id=184187437&channel=0146921',
    source: 'mg',
    id: '184187437',
  },
  { text: 'https://music.migu.cn/v3/music/playlist/221573417', source: 'mg', id: '221573417' },
  // 链接后面跟着中文标点（分享文案里很常见）也要能截干净
  { text: '分享歌单《测试》https://music.163.com/#/playlist?id=998877，快来听', source: 'wy', id: '998877' },
  // 洛雪自己的分享链接（songlist/open 与 songlist/play 同一套参数）
  { text: 'lxmusic://songlist/open/wy/2892110024', source: 'wy', id: '2892110024' },
  { text: 'lxmusic://songlist/play/kw/2892110024/3', source: 'kw', id: '2892110024' },
  {
    text: 'lxmusic://songlist/open/kg/https%3A%2F%2Fwww.kugou.com%2Fyy%2Fspecial%2Fsingle%2F1067062.html',
    source: 'kg',
    id: '1067062',
  },
  // 直接给「平台__歌单id」（洛雪的列表标识）
  { text: 'wy__2892110024', source: 'wy', id: '2892110024' },
];

/** 不该被当成歌单的输入 */
const REJECTS: string[] = [
  // 单曲 / 专辑 / 歌手链接：都带 id=，不挡住就会拿单曲 id 去当歌单 id
  'https://music.163.com/#/song?id=186016',
  'https://music.163.com/#/album?id=32311',
  'https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV',
  'https://www.kuwo.cn/play_detail/123456',
  // 没有链接、认不出平台、空文本
  '分享歌单《周杰伦》',
  'https://example.com/playlist?id=1',
  '',
];

export default function playlistLinkTest() {
  describe('playlistLinkTest', () => {
    it('parsesShareTextOfEveryPlatform', 0, () => {
      for (const item of CASES) {
        const link: PlaylistLink | null = parseShareText(item.text);
        expect(link === null).assertFalse();
        if (link === null) {
          continue;
        }
        expect(link.source).assertEqual(item.source);
        expect(link.id).assertEqual(item.id);
        // listId 是导入时写进歌单 sourceListId 的标识，必须是「平台__歌单id」
        expect(link.listId).assertEqual(`${item.source}__${item.id}`);
      }
    });

    it('rejectsSongLinksAndUnknownInput', 0, () => {
      for (const text of REJECTS) {
        expect(parseShareText(text) === null).assertTrue();
      }
    });

    it('takesFirstUrlOutOfShareText', 0, () => {
      expect(firstUrl('分享 https://music.163.com/#/playlist?id=1，后面还有字'))
        .assertEqual('https://music.163.com/#/playlist?id=1');
      expect(firstUrl('没有链接的一段话')).assertEqual('');
    });

    it('detectsPlatformByHostSuffix', 0, () => {
      expect(platformOfUrl('https://i.y.qq.com/n2/m/x')).assertEqual('tx');
      expect(platformOfUrl('https://t1.kugou.com/abc')).assertEqual('kg');
      expect(platformOfUrl('https://h5.nf.migu.cn/x')).assertEqual('mg');
      expect(platformOfUrl('https://example.com/x')).assertEqual('');
    });

    it('buildsLinkFromSourceAndId', 0, () => {
      const link: PlaylistLink = linkOf('wy', '2892110024');
      expect(link.source).assertEqual('wy');
      expect(link.id).assertEqual('2892110024');
      expect(link.listId).assertEqual('wy__2892110024');
      expect(link.url).assertEqual('');
    });
  });
}
