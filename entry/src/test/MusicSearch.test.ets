import { describe, it, expect } from '@ohos/hypium';
import { md5Hex } from '../main/ets/core/music/LxCrypto';
import {
  LxMusicInfo,
  createMgSignature,
  decodeName,
  formatPlayTime,
  formatSingerName,
  hasQuality,
  parseKgResult,
  parseKwResult,
  parseMgResult,
  pickQuality,
  sizeFormate,
} from '../main/ets/core/music/MusicSearch';

/** 酷我搜索响应片段 */
const KW_BODY: string = `{
  "TOTAL": "1", "SHOW": "1",
  "abslist": [{
    "MUSICRID": "MUSIC_228908",
    "SONGNAME": "晴天 &amp; 测试",
    "ARTIST": "周杰伦&方文山",
    "ALBUM": "叶惠美",
    "ALBUMID": "12345",
    "DURATION": "269",
    "N_MINFO": "level:ff,bitrate:128,format:mp3,size:3.50M;level:p,bitrate:320,format:mp3,size:8.20M;level:z,bitrate:2000,format:flac,size:27.56M"
  }]
}`;

/** 酷狗搜索响应片段（含一个 Grp 子项） */
const KG_BODY: string = `{
  "error_code": 0,
  "data": {
    "total": 1,
    "lists": [{
      "Audioid": "7654321",
      "FileHash": "HASH128",
      "FileSize": 4390000,
      "HQFileHash": "HASH320",
      "HQFileSize": 10200000,
      "SQFileHash": "",
      "SQFileSize": 0,
      "ResFileHash": "",
      "ResFileSize": 0,
      "Duration": 269,
      "OriSongName": "晴天",
      "Suffix": "Live",
      "AlbumName": "叶惠美",
      "AlbumID": "998",
      "Singers": [{ "name": "周杰伦" }, { "name": "方文山" }],
      "Grp": [{
        "Audioid": "7654321",
        "FileHash": "HASH128",
        "FileSize": 4390000,
        "HQFileHash": "",
        "HQFileSize": 0,
        "SQFileHash": "",
        "SQFileSize": 0,
        "ResFileHash": "",
        "ResFileSize": 0,
        "Duration": 269,
        "OriSongName": "晴天",
        "Suffix": "",
        "AlbumName": "叶惠美",
        "AlbumID": "998",
        "Singers": [{ "name": "周杰伦" }],
        "Grp": []
      }]
    }]
  }
}`;

/** 咪咕搜索响应片段（结果项带重复 copyrightId 以验证去重） */
const MG_BODY: string = `{
  "code": "000000",
  "songResultData": {
    "totalCount": 2,
    "resultList": [[
      {
        "songId": "6009",
        "copyrightId": "CP001",
        "name": "晴天",
        "album": "叶惠美",
        "albumId": "A1",
        "duration": 269,
        "singerList": [{ "name": "周杰伦" }],
        "audioFormats": [{ "formatType": "PQ", "asize": 4390000 }, { "formatType": "SQ", "isize": 28900000 }],
        "img1": "/img/cover.jpg"
      },
      {
        "songId": "6009",
        "copyrightId": "CP001",
        "name": "晴天",
        "duration": 269,
        "singerList": [{ "name": "周杰伦" }],
        "audioFormats": []
      }
    ]]
  }
}`;

function bodyOf(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function arrayOf(v: Object | undefined): Object[] {
  return Array.isArray(v) ? v as Object[] : [];
}

function recordOf(v: Object | undefined): Record<string, Object> {
  return (v !== null && v !== undefined && typeof v === 'object') ? v as Record<string, Object> : {};
}

export default function musicSearchTest() {
  describe('musicSearchTest', () => {
    it('md5MatchesKnownVectors', 0, () => {
      expect(md5Hex('')).assertEqual('d41d8cd98f00b204e9800998ecf8427e');
      expect(md5Hex('abc')).assertEqual('900150983cd24fb0d6963f7d28e17f72');
      expect(md5Hex('hello world')).assertEqual('5eb63bbbe01eeed093cb22bb8f5acdc3');
      expect(md5Hex('中文')).assertEqual('a7bac2239fcdcb3a067903d8077c4a07');
      expect(md5Hex('A')).assertEqual('7fc56270e7a70fa81a5935b72eacbe29');
    });

    it('mgSignatureIsStable', 0, () => {
      // 与 node:crypto 手算结果一致
      expect(createMgSignature('周杰伦', '1700000000000')).assertEqual('32a64a14bc877d1521fae7854288cc94');
    });

    it('formatsTimeAndSize', 0, () => {
      expect(formatPlayTime(269)).assertEqual('04:29');
      expect(formatPlayTime(65)).assertEqual('01:05');
      expect(formatPlayTime(0)).assertEqual('--/--');
      expect(sizeFormate(4390000)).assertEqual('4.19 MiB');
      expect(sizeFormate(28900000)).assertEqual('27.56 MiB');
      expect(sizeFormate(0)).assertEqual('0 B');
    });

    it('decodesHtmlEntities', 0, () => {
      expect(decodeName('晴天 &amp; 测试')).assertEqual('晴天 & 测试');
      expect(decodeName('&#x5468;&#26480;&#20262;')).assertEqual('周杰伦');
      expect(decodeName('&lt;a&gt;')).assertEqual('<a>');
      expect(decodeName('无实体')).assertEqual('无实体');
    });

    it('formatsSingerArray', 0, () => {
      const singers = JSON.parse('[{"name":"周杰伦"},{"name":"方文山"}]') as Object[];
      expect(formatSingerName(singers)).assertEqual('周杰伦、方文山');
    });

    it('parsesKuwoResult', 0, () => {
      const list: LxMusicInfo[] = parseKwResult(arrayOf(bodyOf(KW_BODY)['abslist']));
      expect(list.length).assertEqual(1);
      const info: LxMusicInfo = list[0];
      expect(info.source).assertEqual('kw');
      expect(info.name).assertEqual('晴天 & 测试');
      expect(info.singer).assertEqual('周杰伦、方文山');
      expect(info.songmid).assertEqual('228908');
      expect(info.albumName).assertEqual('叶惠美');
      expect(info.interval).assertEqual('04:29');
      expect(info.types.length).assertEqual(3);
      expect(hasQuality(info, '128k')).assertTrue();
      expect(hasQuality(info, '320k')).assertTrue();
      expect(hasQuality(info, 'flac')).assertTrue();
      expect(hasQuality(info, 'flac24bit')).assertFalse();
      // kw 没有 hash 字段：源脚本用 `hash ?? songmid` 取值，写成空串会让 ?? 不回退
      expect(JSON.stringify(info).includes('"hash"')).assertFalse();
    });

    it('parsesKugouResultWithDedupe', 0, () => {
      const data: Record<string, Object> = recordOf(bodyOf(KG_BODY)['data']);
      const list: LxMusicInfo[] = parseKgResult(arrayOf(data['lists']));
      // Grp 子项与父项 Audioid+FileHash 相同，应被去重
      expect(list.length).assertEqual(1);
      const info: LxMusicInfo = list[0];
      expect(info.source).assertEqual('kg');
      expect(info.name).assertEqual('晴天 Live');
      expect(info.singer).assertEqual('周杰伦、方文山');
      expect(info.songmid).assertEqual('7654321');
      expect(info.hash).assertEqual('HASH128');
      expect(info.interval).assertEqual('04:29');
      expect(hasQuality(info, '128k')).assertTrue();
      expect(hasQuality(info, '320k')).assertTrue();
      expect(hasQuality(info, 'flac')).assertFalse();
      expect(info._types['320k'].hash).assertEqual('HASH320');
      expect(info._types['128k'].size).assertEqual('4.19 MiB');
      // kg 是唯一真的带 hash 的平台，必须序列化出来
      expect(JSON.stringify(info).includes('"hash":"HASH128"')).assertTrue();
    });

    it('parsesMiguResultWithDedupeAndImgPrefix', 0, () => {
      const data: Record<string, Object> = recordOf(bodyOf(MG_BODY)['songResultData']);
      const list: LxMusicInfo[] = parseMgResult(arrayOf(data['resultList']));
      expect(list.length).assertEqual(1);
      const info: LxMusicInfo = list[0];
      expect(info.source).assertEqual('mg');
      expect(info.name).assertEqual('晴天');
      expect(info.singer).assertEqual('周杰伦');
      expect(info.songmid).assertEqual('6009');
      expect(info.img).assertEqual('http://d.musicapp.migu.cn/img/cover.jpg');
      expect(hasQuality(info, '128k')).assertTrue();
      expect(hasQuality(info, 'flac')).assertTrue();
      expect(hasQuality(info, '320k')).assertFalse();
      expect(JSON.stringify(info).includes('"hash"')).assertFalse();
    });

    it('picksQualityLikeLxMusic', 0, () => {
      const list: LxMusicInfo[] = parseKwResult(arrayOf(bodyOf(KW_BODY)['abslist']));
      const info: LxMusicInfo = list[0];
      const supported: string[] = ['128k', '320k', 'flac', 'flac24bit'];
      // 期望 320k 且曲目/音源都支持 -> 320k
      expect(pickQuality('320k', supported, info)).assertEqual('320k');
      // 期望 flac 且支持 -> flac
      expect(pickQuality('flac', supported, info)).assertEqual('flac');
      // 期望 flac24bit，曲目没有该音质 -> 按 flac -> 320k 顺序回落，命中 flac
      expect(pickQuality('flac24bit', supported, info)).assertEqual('flac');
      // 期望 flac24bit，但音源只声明 128k -> 回落 128k
      expect(pickQuality('flac24bit', ['128k'], info)).assertEqual('128k');
      // 期望 128k -> 128k
      expect(pickQuality('128k', supported, info)).assertEqual('128k');
    });
  });
}
