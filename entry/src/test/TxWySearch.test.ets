import { describe, it, expect } from '@ohos/hypium';
import {
  LxMusicInfo,
  createEapiParams,
  createTxRequestBody,
  createZzcSign,
  hasQuality,
  parseTxSongs,
  parseWySongs,
} from '../main/ets/core/music/MusicSearch';
import { aes128EcbPkcs7HexUpper, sha1Hex, toBase64, utf8Bytes } from '../main/ets/core/music/LxCrypto';

/** 与 node:crypto 手算对齐的向量 */
const TX_SIGN_INPUT: string = 'lx-music-harmony';
const TX_SIGN_EXPECT: string = 'zzc1ed574512mcqtio5hniyxlkn7bf8hh1k7w7e9d5601';
const WY_EAPI_DATA: string =
  '{"keyword":"晴天","needCorrect":"1","channel":"typing","offset":0,"scene":"normal","total":true,"limit":30}';
const WY_EAPI_EXPECT: string =
  '74A595527B7A1647174ADDB4F261E92F180F42F921F98E9D338C60DB20AF499CEA90E95FB2FDA117A0B5D8175C2F21E5C1BD8D67F61C04584AFD482A98F5A4265ECCD6FB95592FA5280348236698BCBBAB8645D8F534488F2E7F9D639BF8146E070B45B5889004E0CC502E9F96CD56ED8E8FB700977800E5C616368B3C31571F7130F5BA92FF81EF767FE901A4783B3A87BCACA418296D0FF073E900D40B535AFF6EBDF07837FC2199D0D5B92265EBF3CAB368793ED567887FC8D96C60888F27A6073F78C543B0A89158359B0E15B6F6';
const AES_ECB_EXPECT: string = '4B95C15C6593762ABC831FCFE105028C38E606B48C400F1A711F9F8B3DDF020E';

/** QQ 搜索响应片段 */
const TX_BODY: string = `{"code":0,"music.search.SearchCgiService":{"code":0,"data":{"body":{"song":{"list":[
{"id":123456,"mid":"001Qu4I30eVFYb","title":"晴天","interval":269,
 "singer":[{"name":"周杰伦","mid":"0025NhlN2yWrP4"}],
 "album":{"mid":"002fRO0N4FftzY","name":"叶惠美"},
 "file":{"media_mid":"0039MnYb0qxYhV","size_128mp3":4390000,"size_320mp3":10200000,"size_flac":28900000,"size_hires":0}}
]}},"meta":{"sum":1}}}}`;

/** 网易搜索响应片段（maxbr=999000 会同时给出 flac/320k/128k，验证穿透行为） */
const WY_BODY: string = `{"code":200,"data":{"totalCount":1,"resources":[{"baseInfo":{"simpleSongData":{
"name":"晴天","id":186016,"dt":269000,
"ar":[{"name":"周杰伦"}],
"al":{"id":123,"name":"叶惠美","picUrl":"https://p1.music.126.net/x.jpg"},
"privilege":{"maxbr":999000,"maxBrLevel":"hires"},
"hr":{"size":30000000},"sq":{"size":28900000},"h":{"size":10200000},"l":{"size":4390000}
}}}]}}`;

function recordOf(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function arrayOf(v: Object | undefined): Object[] {
  return Array.isArray(v) ? v as Object[] : [];
}

export default function txWySearchTest() {
  describe('txWySearchTest', () => {
    it('sha1MatchesKnownVectors', 0, () => {
      expect(sha1Hex('')).assertEqual('da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(sha1Hex('abc')).assertEqual('a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(sha1Hex('晴天')).assertEqual('5656dc6e7521f9c72681404886da76c6c4c6e6bf');
      expect(sha1Hex(TX_SIGN_INPUT)).assertEqual('8e4e31d4087adce57955c8b14ff62d7797d4520f');
    });

    it('base64MatchesReference', 0, () => {
      expect(toBase64(utf8Bytes('abc'))).assertEqual('YWJj');
      expect(toBase64([0, 0, 0])).assertEqual('AAAA');
      expect(toBase64([])).assertEqual('');
      expect(toBase64(utf8Bytes('中文'))).assertEqual('5Lit5paH');
    });

    it('aesEcbPkcs7MatchesNodeCrypto', 0, () => {
      const got: string = aes128EcbPkcs7HexUpper(
        utf8Bytes('e82ckenh8dichen8'),
        utf8Bytes('hello-lx-ecb-test'),
      );
      expect(got).assertEqual(AES_ECB_EXPECT);
    });

    it('zzcSignMatchesReference', 0, () => {
      expect(createZzcSign(TX_SIGN_INPUT)).assertEqual(TX_SIGN_EXPECT);
      // 洛雪 PART_1_INDEXES 含越界下标 40，原版靠 join 把 undefined 变空串 => part1 只有 7 位
      const sign: string = createZzcSign(TX_SIGN_INPUT);
      expect(sign.startsWith('zzc')).assertTrue();
      expect(sign.length < 3 + 8 + 32 + 8).assertTrue();
    });

    it('buildsTxRequestBodyLikeLxMusic', 0, () => {
      const body: string = createTxRequestBody('晴天', 1, 30);
      const root: Record<string, Object> = recordOf(body);
      const comm: Record<string, Object> = root['comm'] as Record<string, Object>;
      const service: Record<string, Object> = root['music.search.SearchCgiService'] as Record<string, Object>;
      const param: Record<string, Object> = service['param'] as Record<string, Object>;
      expect(comm['ct'] as string).assertEqual('19');
      expect(comm['tmeAppID'] as string).assertEqual('qqmusic');
      expect(service['method'] as string).assertEqual('DoSearchForQQMusicDesktop');
      expect(param['query'] as string).assertEqual('晴天');
      expect(param['num_per_page'] as number).assertEqual(30);
      // searchid = 32 位大写 hex + 5 位数字
      const searchId: string = param['searchid'] as string;
      expect(searchId.length).assertEqual(37);
      // 键顺序必须与洛雪一致（签名是对这个 JSON 串算的）
      expect(body.startsWith('{"comm":')).assertTrue();
      expect(body.indexOf('"music.search.SearchCgiService"') > body.indexOf('"wid"')).assertTrue();
    });

    it('eapiParamsMatchReference', 0, () => {
      expect(createEapiParams('/api/search/song/list/page', WY_EAPI_DATA)).assertEqual(WY_EAPI_EXPECT);
    });

    it('parsesTxSearchResult', 0, () => {
      const root: Record<string, Object> = recordOf(TX_BODY);
      const service: Record<string, Object> = root['music.search.SearchCgiService'] as Record<string, Object>;
      const data: Record<string, Object> = service['data'] as Record<string, Object>;
      const body: Record<string, Object> = data['body'] as Record<string, Object>;
      const song: Record<string, Object> = body['song'] as Record<string, Object>;
      const list: LxMusicInfo[] = parseTxSongs(arrayOf(song['list']));
      expect(list.length).assertEqual(1);
      const info: LxMusicInfo = list[0];
      expect(info.source).assertEqual('tx');
      expect(info.name).assertEqual('晴天');
      expect(info.singer).assertEqual('周杰伦');
      expect(info.albumName).assertEqual('叶惠美');
      expect(info.songmid).assertEqual('001Qu4I30eVFYb');
      expect(info.songId).assertEqual('123456');
      expect(info.strMediaMid).assertEqual('0039MnYb0qxYhV');
      expect(info.albumMid).assertEqual('002fRO0N4FftzY');
      expect(info.interval).assertEqual('04:29');
      expect(info.img).assertEqual('https://y.gtimg.cn/music/photo_new/T002R500x500M000002fRO0N4FftzY.jpg');
      expect(hasQuality(info, '128k')).assertTrue();
      expect(hasQuality(info, '320k')).assertTrue();
      expect(hasQuality(info, 'flac')).assertTrue();
      expect(hasQuality(info, 'flac24bit')).assertFalse();
      // tx 没有 hash：源脚本 `hash ?? songmid` 必须回退到 songmid
      expect(JSON.stringify(info).includes('"hash"')).assertFalse();
    });

    it('parsesWySearchResultWithFallthrough', 0, () => {
      const root: Record<string, Object> = recordOf(WY_BODY);
      const data: Record<string, Object> = root['data'] as Record<string, Object>;
      const list: LxMusicInfo[] = parseWySongs(arrayOf(data['resources']));
      expect(list.length).assertEqual(1);
      const info: LxMusicInfo = list[0];
      expect(info.source).assertEqual('wy');
      expect(info.name).assertEqual('晴天');
      expect(info.singer).assertEqual('周杰伦');
      expect(info.albumName).assertEqual('叶惠美');
      expect(info.songmid).assertEqual('186016');
      expect(info.interval).assertEqual('04:29');
      expect(info.img).assertEqual('https://p1.music.126.net/x.jpg');
      // maxBrLevel=hires 且 maxbr=999000：洛雪 switch 穿透 => flac/320k/128k 全给
      expect(hasQuality(info, 'flac24bit')).assertTrue();
      expect(hasQuality(info, 'flac')).assertTrue();
      expect(hasQuality(info, '320k')).assertTrue();
      expect(hasQuality(info, '128k')).assertTrue();
      expect(info.types.length).assertEqual(4);
      // reverse 之后顺序为 128k -> flac24bit
      expect(info.types[0].type).assertEqual('128k');
      expect(info.types[3].type).assertEqual('flac24bit');
      expect(JSON.stringify(info).includes('"hash"')).assertFalse();
    });
  });
}
