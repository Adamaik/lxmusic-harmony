import { describe, it, expect } from '@ohos/hypium';
import { ParsedResponse, buildEntries, encodeHref, localName, nameOfHref, originOf, parsePropfind,
  pathOfHref, resolveHref, samePath, withTrailingSlash } from '../main/ets/core/webdav/WebDavXml';
import { WebDavEntry, WEBDAV_ID_PREFIX, WEBDAV_QUALITY, WEBDAV_SOURCE } from '../main/ets/core/webdav/WebDavTypes';
import { findFolderCover, findSiblingLrc, folderCoverName, groupByFolder, isWebDavSong, shortHash,
  sortByLocation, stableKeyOf, WebDavSong } from '../main/ets/core/webdav/WebDavLibrary';
import { normalizeServerUrl } from '../main/ets/core/webdav/WebDavSettings';
import { mediaKeyOf } from '../main/ets/core/music/MediaCache';
import { isSyncable } from '../main/ets/core/sync/SyncConvert';
import { SongItem } from '../main/ets/core/player/PlaySession';
import { LxMusicInfo } from '../main/ets/core/music/MusicSearch';

/**
 * WebDAV 云端音乐（core/webdav）的契约
 *
 * 联网那部分（PROPFIND / 取标签 / 下载）要真实服务器，跑不了本地单测；能被测、
 * 且值得钉住的是**协议解析与曲库和现有链路接的那几个接口** —— 它们错了都不会报错，
 * 只会静默出怪事：
 *   1. PROPFIND 的 XML 解析：命名空间前缀、`<collection/>`、href 的三种写法、
 *      「服务器把被请求目录自己也列出来」这条惯例；
 *   2. mediaKeyOf(musicInfoJson) 必须等于条目 id（`webdav_<key>`）—— 播放缓存
 *      与下载索引都按它找文件；
 *   3. isSyncable 必须是 false —— 用户明确要的行为：云端歌在同步时被直接抛弃；
 *   4. 同目录封面 / 歌词的挑选规则 —— 挑错了就是「配了一张别的专辑的图」；
 *   5. 服务器地址的规范化 —— 少补一个 `http://` 用户就怎么也连不上，还看不出原因。
 */

/** 一份典型的 PROPFIND 响应（D: 前缀 + 目录自己 + 一个目录 + 两个文件 + 缺属性的 propstat） */
const PROPFIND_XML: string = '<?xml version="1.0" encoding="utf-8"?>'
  + '<D:multistatus xmlns:D="DAV:">'
  + '<D:response><D:href>/dav/music/</D:href>'
  + '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
  + '<D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified></D:prop>'
  + '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
  + '<D:propstat><D:prop><D:getcontentlength/></D:prop>'
  + '<D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>'
  + '<D:response><D:href>/dav/music/%E5%91%A8%E6%9D%B0%E4%BC%A6/</D:href>'
  + '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
  + '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
  + '<D:response><D:href>/dav/music/a.mp3</D:href>'
  + '<D:propstat><D:prop><D:getcontentlength>5242880</D:getcontentlength>'
  + '<D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified></D:prop>'
  + '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
  + '<D:response><D:href>http://host:5006/dav/music/b.flac</D:href>'
  + '<D:propstat><D:prop><D:getcontentlength>10485760</D:getcontentlength></D:prop>'
  + '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
  + '</D:multistatus>';

/** 一条云端歌的索引行（只给分组用得上的字段填值） */
function song(file: string, folder: string): WebDavSong {
  return {
    key: stableKeyOf(`${folder}${file}`),
    url: `${folder}${file}`,
    folder: folder,
    file: file,
    cover: '',
    remoteCover: '',
    lrc: '',
    matchJson: '',
    matchSource: '',
    matchAt: 0,
    name: file,
    singer: '',
    album: '',
    durationMs: 0,
    sizeBytes: 0,
    seenAt: 0,
    seen: true,
    tagsDone: false,
  };
}

function entry(name: string, isCollection: boolean, size: number = -1): WebDavEntry {
  return {
    url: `http://host/dav/${name}`,
    name: name,
    folder: 'http://host/dav/',
    isCollection: isCollection,
    size: size,
    modifiedMs: -1,
  };
}

/** 一条云端歌的展示条目（与 WebDavLibrary.songOf 同构），用来验 id / 同步排除 */
function songItem(): SongItem {
  const info: LxMusicInfo = {
    name: '普通朋友',
    singer: '陶喆',
    source: WEBDAV_SOURCE,
    songmid: 'k1',
    albumName: '',
    albumId: '',
    interval: '04:15',
    img: '',
    types: [],
    _types: {},
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
  return {
    id: `${WEBDAV_ID_PREFIX}k1`,
    name: '普通朋友',
    singer: '陶喆',
    coverUrl: '',
    art: true,
    source: WEBDAV_SOURCE,
    quality: WEBDAV_QUALITY,
    interval: '04:15',
    musicInfoJson: JSON.stringify(info),
  };
}

export default function webDavTest() {
  describe('WebDavXml', () => {
    it('parses_propfind_response', 0, () => {
      const parsed: ParsedResponse[] = parsePropfind(PROPFIND_XML);
      expect(parsed.length).assertEqual(4);
      // 目录自己那条：是 collection、没有大小
      expect(parsed[0].href).assertEqual('/dav/music/');
      expect(parsed[0].isCollection).assertTrue();
      expect(parsed[0].size).assertEqual(-1);
      // 中文目录名（百分号编码，不在这里解码）
      expect(parsed[1].isCollection).assertTrue();
      // 文件：有大小、有时间
      expect(parsed[2].href).assertEqual('/dav/music/a.mp3');
      expect(parsed[2].isCollection).assertFalse();
      expect(parsed[2].size).assertEqual(5242880);
      expect(parsed[2].modifiedMs > 0).assertTrue();
      // 服务器直接给了完整 URL 的那种写法也要能解析
      expect(parsed[3].href).assertEqual('http://host:5006/dav/music/b.flac');
    });

    it('skips_self_entry_and_resolves_href', 0, () => {
      const entries: WebDavEntry[] = buildEntries('http://host:5006/dav/music',
        'http://host:5006/dav/music', parsePropfind(PROPFIND_XML));
      // 目录自己那条被摘掉了
      expect(entries.length).assertEqual(3);
      expect(entries[0].url).assertEqual('http://host:5006/dav/music/%E5%91%A8%E6%9D%B0%E4%BC%A6/');
      expect(entries[0].name).assertEqual('周杰伦');
      expect(entries[0].isCollection).assertTrue();
      expect(entries[1].url).assertEqual('http://host:5006/dav/music/a.mp3');
      // 完整 URL 原样保留（只做转义，不改 origin）
      expect(entries[2].url).assertEqual('http://host:5006/dav/music/b.flac');
      // folder 是这次 PROPFIND 的目录（带尾斜杠）
      expect(entries[0].folder).assertEqual('http://host:5006/dav/music/');
    });

    it('tolerates_garbage', 0, () => {
      // 认证失败时服务器常返回一张 HTML 登录页：要当成「一个条目都没有」，而不是抛错
      expect(parsePropfind('<html><body>Unauthorized</body></html>').length).assertEqual(0);
      expect(parsePropfind('').length).assertEqual(0);
    });

    it('strips_namespace_prefix', 0, () => {
      expect(localName('D:href')).assertEqual('href');
      expect(localName('ns0:getcontentlength')).assertEqual('getcontentlength');
      expect(localName('href')).assertEqual('href');
    });

    it('resolves_relative_href', 0, () => {
      expect(resolveHref('http://host/dav/music', 'a.mp3')).assertEqual('http://host/dav/music/a.mp3');
      expect(resolveHref('http://host/dav/music/', '/dav/other/b.mp3'))
        .assertEqual('http://host/dav/other/b.mp3');
      expect(originOf('https://host:5006/dav/music/')).assertEqual('https://host:5006');
      expect(originOf('https://host/dav')).assertEqual('https://host');
    });

    it('encodes_unsafe_href_chars', 0, () => {
      // 中文要转义；已经转义过的不再转第二遍（% 在安全集里）
      const encoded: string = encodeHref('http://host/dav/周杰伦/a b.mp3');
      expect(encoded).assertEqual('http://host/dav/%E5%91%A8%E6%9D%B0%E4%BC%A6/a%20b.mp3');
      expect(encodeHref('http://host/dav/%E5%91%A8/')).assertEqual('http://host/dav/%E5%91%A8/');
    });

    it('compares_paths_ignoring_encoding', 0, () => {
      expect(samePath('http://host/dav/music/', 'http://other/dav/music')).assertTrue();
      expect(samePath('http://host/dav/music/a.mp3', 'http://host/dav/music')).assertFalse();
      // 文件名可能带 ?query，比路径时要去掉
      expect(pathOfHref('/dav/a.mp3?x=1')).assertEqual('/dav/a.mp3');
      expect(nameOfHref('/dav/%E5%91%A8%E6%9D%B0%E4%BC%A6/')).assertEqual('周杰伦');
      expect(withTrailingSlash('http://host/dav')).assertEqual('http://host/dav/');
      expect(withTrailingSlash('http://host/dav/')).assertEqual('http://host/dav/');
    });
  });

  describe('WebDavLibrary', () => {
    it('id_matches_media_key', 0, () => {
      const item: SongItem = songItem();
      // 播放缓存 / 下载索引都按 mediaKeyOf 找文件，它必须等于条目 id
      expect(mediaKeyOf(item.musicInfoJson)).assertEqual(item.id);
      expect(item.id).assertEqual('webdav_k1');
      expect(item.quality).assertEqual('webdav');
    });

    it('is_not_syncable', 0, () => {
      // 用户明确要的行为：云端歌在同步时被直接抛弃（与本地音乐一致）
      expect(isSyncable(songItem())).assertFalse();
      expect(isWebDavSong(songItem())).assertTrue();
    });

    it('picks_sibling_lrc', 0, () => {
      const listing: WebDavEntry[] = [
        entry('a.mp3', false),
        entry('a.lrc', false),
        entry('b.mp3', false),
        entry('b.mp3.lrc', false),
        entry('c.mp3', false),
      ];
      expect(findSiblingLrc(listing, 'a.mp3')?.name).assertEqual('a.lrc');
      // 有些抓词工具存成 `song.mp3.lrc`，也要认
      expect(findSiblingLrc(listing, 'b.mp3')?.name).assertEqual('b.mp3.lrc');
      // 没有就是没有，不能捞一个别的歌词回来
      expect(findSiblingLrc(listing, 'c.mp3')).assertNull();
    });

    it('picks_folder_cover_before_same_name', 0, () => {
      const listing: WebDavEntry[] = [
        entry('a.mp3', false),
        entry('a.jpg', false),
        entry('cover.jpg', false),
        entry('notes.txt', false),
        entry('sub', true),
      ];
      // 惯例名（cover/folder/front…）优先，其次才是同名的图
      expect(findFolderCover(listing, 'a.mp3')?.name).assertEqual('cover.jpg');
      const noConvention: WebDavEntry[] = [entry('a.mp3', false), entry('a.png', false)];
      expect(findFolderCover(noConvention, 'a.mp3')?.name).assertEqual('a.png');
      expect(findFolderCover([entry('a.mp3', false)], 'a.mp3')).assertNull();
    });

    it('groups_by_folder_and_names_cover', 0, () => {
      const groups = groupByFolder([
        song('a.mp3', 'http://host/dav/A/'),
        song('b.mp3', 'http://host/dav/B/'),
        song('c.mp3', 'http://host/dav/A/'),
      ]);
      expect(groups.length).assertEqual(2);
      expect(groups[0].folder).assertEqual('http://host/dav/A/');
      expect(groups[0].songs.length).assertEqual(2);
      expect(groups[1].songs.length).assertEqual(1);
      // 同一目录的封面名必须一样（整目录共用一张），不同目录必须不一样
      expect(folderCoverName('http://host/dav/A/')).assertEqual(folderCoverName('http://host/dav/A/'));
      expect(folderCoverName('http://host/dav/A/') === folderCoverName('http://host/dav/B/')).assertFalse();
      expect(shortHash('http://host/dav/A/').length > 0).assertTrue();
    });
  });

  describe('WebDavLibraryScan', () => {
    it('derives_stable_key_from_url', 0, () => {
      // 关键性质：同一个 URL 永远得到同一个 key —— 重新扫描后歌单 / 收藏里的引用
      // 才不会失效（这功能早期版本用随机 key，一重扫就把歌单里的歌全弄丢了）
      const url: string = 'http://host/dav/%E5%91%A8%E6%9D%B0%E4%BC%A6/a.mp3';
      expect(stableKeyOf(url)).assertEqual(stableKeyOf(url));
      expect(stableKeyOf(url) === stableKeyOf('http://host/dav/b.mp3')).assertFalse();
      // 与目录封面的短哈希是两回事（一个 32 位、一个 64 位量级）
      expect(stableKeyOf(url).length > shortHash(url).length).assertTrue();
    });

    it('sorts_by_folder_then_file', 0, () => {
      const sorted: WebDavSong[] = sortByLocation([
        song('b.mp3', 'http://host/dav/B/'),
        song('b.mp3', 'http://host/dav/A/'),
        song('a.mp3', 'http://host/dav/A/'),
      ]);
      // 同一张专辑的歌要挨在一起（先目录、再文件名）
      expect(sorted[0].url).assertEqual('http://host/dav/A/a.mp3');
      expect(sorted[1].url).assertEqual('http://host/dav/A/b.mp3');
      expect(sorted[2].url).assertEqual('http://host/dav/B/b.mp3');
    });
  });

  describe('WebDavSettings', () => {
    it('normalizes_server_url', 0, () => {
      // 手机键盘上没人打 http://，要替他补上；末尾斜杠统一去掉
      expect(normalizeServerUrl('192.168.1.10:5006/dav')).assertEqual('http://192.168.1.10:5006/dav');
      expect(normalizeServerUrl('https://cloud.example.com/remote.php/dav/files/me/Music/'))
        .assertEqual('https://cloud.example.com/remote.php/dav/files/me/Music');
      expect(normalizeServerUrl('  http://host/dav//  ')).assertEqual('http://host/dav');
      expect(normalizeServerUrl('')).assertEqual('');
    });
  });

}
