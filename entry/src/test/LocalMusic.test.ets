import { describe, it, expect } from '@ohos/hypium';
import { LocalMusic, LocalSong, LOCAL_SOURCE, isIgnorableFile, isLocalSong, isSupportedAudioFile,
  isUnsupportedAudioFile, singerFromFileName, titleFromFileName } from '../main/ets/core/local/LocalMusic';
import { mediaKeyOf } from '../main/ets/core/music/MediaCache';
import { isSyncable } from '../main/ets/core/sync/SyncConvert';
import { pickQuality } from '../main/ets/core/music/Quality';
import { SongItem } from '../main/ets/core/player/PlaySession';

/**
 * 本地音乐的契约（core/local/LocalMusic）
 *
 * 导入 / 落盘那部分要沙箱与真实音频文件，跑不了本地单测；能被测、且值得钉住的是
 * **本地歌和现有链路接的那几个接口**，它们错了都不会报错，只会静默出怪事：
 *   1. mediaKeyOf(musicInfoJson) 必须等于条目 id —— 播放缓存与下载索引都按它找文件；
 *   2. isSyncable 必须是 false —— 用户明确要的行为：本地歌在同步时被直接抛弃；
 *   3. pickQuality 要原样返回 —— 本地歌没有音质档，不能去做音质协商；
 *   4. 后缀过滤 —— 不支持的格式要报出来，不能静默当成导入成功。
 */
function sample(): LocalSong {
  return {
    key: 'abc123',
    file: 'abc123.mp3',
    cover: '',
    lrc: '',
    matchJson: '',
    matchSource: '',
    matchAt: 0,
    name: '普通朋友',
    singer: '陶喆',
    album: 'I\'m OK',
    durationMs: 264000,
    sizeBytes: 4194304,
    addedAt: 1,
    fingerprint: '4194304_普通朋友.mp3',
  };
}

function song(): SongItem {
  return LocalMusic.getInstance().songOf(sample());
}

export default function localMusicTest() {
  describe('localMusicTest', () => {
    it('mapsToSongItem', 0, () => {
      const item: SongItem = song();
      expect(item.id).assertEqual('local_abc123');
      expect(item.source).assertEqual(LOCAL_SOURCE);
      expect(isLocalSong(item)).assertTrue();
      expect(item.name).assertEqual('普通朋友');
      expect(item.singer).assertEqual('陶喆');
      // interval 的口径与在线歌一致（mm:ss），播放页与播控中心都按它算时长
      expect(item.interval).assertEqual('04:24');
      expect(item.quality).assertEqual('local');
      // 没有内嵌封面时用洛雪那套占位封面，而不是留一个空图
      expect(item.art).assertTrue();
      expect(item.coverUrl).assertEqual('');
    });

    it('cacheKeyMatchesId', 0, () => {
      const item: SongItem = song();
      // 播放缓存 / 下载索引都按 mediaKeyOf 找文件。这两个值不相等的话，
      // 「本地歌」和「同名缓存」会被当成两首歌各走一条路。
      expect(mediaKeyOf(item.musicInfoJson)).assertEqual(item.id);
    });

    it('staysOutOfSync', 0, () => {
      // 同步时被直接抛弃（同步设置页也这么写给用户看），不能悄悄上行
      expect(isSyncable(song())).assertFalse();
    });

    it('keepsQualityFallback', 0, () => {
      const item: SongItem = song();
      expect(pickQuality(item.musicInfoJson, item.source, item.quality)).assertEqual('local');
    });

    it('filtersByExtension', 0, () => {
      expect(isSupportedAudioFile('a.mp3')).assertTrue();
      expect(isSupportedAudioFile('A.FLAC')).assertTrue();
      expect(isSupportedAudioFile('b.m4a')).assertTrue();
      // AVPlayer 官方支持的格式里没有这两个，要报「格式不支持」
      expect(isSupportedAudioFile('c.ape')).assertFalse();
      expect(isSupportedAudioFile('d.wma')).assertFalse();
      expect(isSupportedAudioFile('没有后缀')).assertFalse();
      // 但「不支持」和「根本不该导入」要分开：目录里的歌词 / 封面图不该报成失败
      expect(isUnsupportedAudioFile('c.ape')).assertTrue();
      expect(isUnsupportedAudioFile('b.wma')).assertTrue();
      expect(isIgnorableFile('song.lrc')).assertTrue();
      expect(isIgnorableFile('cover.jpg')).assertTrue();
      expect(isIgnorableFile('desktop.ini')).assertTrue();
      expect(isIgnorableFile('a.mp3')).assertFalse();
      expect(isIgnorableFile('c.ape')).assertFalse();
    });

    it('parsesArtistTitleFileName', 0, () => {
      // 没有内嵌标签时退回文件名：`歌手 - 歌名` 是最常见的命名（下载设置里也有这个格式）
      expect(titleFromFileName('陶喆 - 普通朋友.mp3')).assertEqual('普通朋友');
      expect(singerFromFileName('陶喆 - 普通朋友.mp3')).assertEqual('陶喆');
      // 没有分隔符就整段当歌名，歌手留空
      expect(titleFromFileName('普通朋友.mp3')).assertEqual('普通朋友');
      expect(singerFromFileName('普通朋友.mp3')).assertEqual('');
    });

    it('fallsBackToFileName', 0, () => {
      const entry: LocalSong = sample();
      entry.name = '';
      entry.file = 'abc123.mp3';
      // 标签与文件名都没给出名字时才用文件名（去掉后缀）
      expect(LocalMusic.getInstance().songOf(entry).name).assertEqual('abc123');
    });
  });
}
