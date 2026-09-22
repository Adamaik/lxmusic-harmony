import { LxMusicInfo, LxQualityItem, mgImageUrl } from '../music/MusicSearch';
import { musicIdOf } from '../music/MusicId';
import { SongItem } from '../player/PlaySession';
import { LOCAL_SOURCE } from '../local/LocalMusic';
import { WEBDAV_SOURCE } from '../webdav/WebDavTypes';
import { LxMusicInfoNew, LxMusicMeta, LxQualitySize } from './SyncTypes';

/**
 * 内部歌曲（SongItem，musicInfoJson 里是洛雪「内置 SDK 形态」的 LxMusicInfo）
 * 与同步用歌曲（LxMusicInfoNew，洛雪 MusicInfoOnline 的 id/name/singer/source/interval/meta）
 * 之间的转换。
 *
 * 这份映射不是自己编的，是照抄洛雪官方的两个函数：
 *   - toNewMusicInfo（lx-music-mobile/src/utils/index.ts）：SDK 结果 -> 同步用结构
 *   - toOldMusicInfo（同文件）：同步用结构 -> SDK 结果
 * 字段顺序也照着它们摆：服务端的快照 key 是「列表数据的 JSON 字符串的 md5」，
 * 顺序一致时，同一份数据算出来的 md5 才和别人一致，重连才会被判定为「已是最新」。
 */

/** 音质从高到低，用来给同步回来的歌曲挑一个默认音质 */
const QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k', '128k'];

/** 这条内部歌曲能不能参与同步：必须有真实的平台 musicInfo（演示数据没有） */
export function isSyncable(item: SongItem): boolean {
  return parseOldMusicInfo(item) !== null;
}

function parseOldMusicInfo(item: SongItem): LxMusicInfo | null {
  if (item.musicInfoJson === undefined || item.musicInfoJson.length === 0) {
    return null;
  }
  let info: LxMusicInfo;
  try {
    info = JSON.parse(item.musicInfoJson) as LxMusicInfo;
  } catch (e) {
    return null;
  }
  if (info === null || info === undefined) {
    return null;
  }
  if (typeof info.source !== 'string' || info.source.length === 0) {
    return null;
  }
  // 本地文件与云端（WebDAV）文件都不在同步范围内（洛雪也只同步在线歌曲）：
  // 这两种条目的 musicInfo 是我们自己造的「壳」，服务端不认识，
  // 上行只会往别人的列表里塞一堆打不开的东西。
  if (info.source === LOCAL_SOURCE || info.source === WEBDAV_SOURCE) {
    return null;
  }
  if (info.songmid === undefined || info.songmid === null || String(info.songmid).length === 0) {
    return null;
  }
  return info;
}

/** `_types`（{type,size,hash}）-> `_qualitys`（{size,hash}，洛雪没有 type 字段） */
function toQualitySizes(input: Record<string, LxQualityItem> | undefined): Record<string, LxQualitySize> {
  const out: Record<string, LxQualitySize> = {};
  if (input === undefined || input === null) {
    return out;
  }
  const keys: string[] = Object.keys(input);
  for (const key of keys) {
    const item: LxQualityItem = input[key];
    if (item === undefined || item === null) {
      continue;
    }
    const entry: LxQualitySize = { size: item.size !== undefined ? item.size : null };
    if (item.hash !== undefined && item.hash.length > 0) {
      entry.hash = item.hash;
    }
    out[key] = entry;
  }
  return out;
}

/** `_qualitys`（{size,hash}）-> `_types`（{type,size,hash}） */
function toQualityItems(input: Record<string, LxQualitySize> | undefined): Record<string, LxQualityItem> {
  const out: Record<string, LxQualityItem> = {};
  if (input === undefined || input === null) {
    return out;
  }
  const keys: string[] = Object.keys(input);
  for (const key of keys) {
    const item: LxQualitySize = input[key];
    if (item === undefined || item === null) {
      continue;
    }
    const entry: LxQualityItem = {
      type: key,
      size: item.size !== undefined && item.size !== null ? item.size : '',
    };
    if (item.hash !== undefined && item.hash.length > 0) {
      entry.hash = item.hash;
    }
    out[key] = entry;
  }
  return out;
}

/**
 * 内部歌曲 -> 同步用歌曲（对应洛雪 toNewMusicInfo）。
 * 顺序不能动：id / name / singer / source / interval / meta。
 */
export function toLxMusicInfo(item: SongItem): LxMusicInfoNew | null {
  const old: LxMusicInfo | null = parseOldMusicInfo(item);
  if (old === null) {
    return null;
  }
  let qualitys: Object[] = old.types !== undefined ? old.types : [];
  let qualitySizes: Record<string, LxQualitySize> = toQualitySizes(old._types);
  // 洛雪的兼容修正：老数据里的 flac32bit 统一成 flac24bit。
  // 官方用的是 delete + 赋值（flac24bit 会落到末尾），这里用重建对象保持同样的键顺序；
  // ArkTS 不支持 delete 运算符，所以不能用官方的写法。
  if (qualitySizes['flac32bit'] !== undefined && qualitySizes['flac24bit'] === undefined) {
    const legacy: LxQualitySize = qualitySizes['flac32bit'];
    const rebuilt: Record<string, LxQualitySize> = {};
    for (const key of Object.keys(qualitySizes)) {
      if (key === 'flac32bit') {
        continue;
      }
      rebuilt[key] = qualitySizes[key];
    }
    rebuilt['flac24bit'] = legacy;
    qualitySizes = rebuilt;
    const fixedQualitys: Object[] = [];
    for (const entry of qualitys) {
      const quality = entry as LxQualityItem;
      if (quality !== null && quality !== undefined && quality.type === 'flac32bit') {
        const next: LxQualityItem = { type: 'flac24bit', size: quality.size };
        if (quality.hash !== undefined) {
          next.hash = quality.hash;
        }
        fixedQualitys.push(next);
      } else {
        fixedQualitys.push(entry);
      }
    }
    qualitys = fixedQualitys;
  }
  const albumName: string = old.albumName !== undefined && old.albumName !== null ? old.albumName : '';
  const picUrl: string = old.img !== undefined && old.img !== null ? old.img : '';
  const albumId: string = old.albumId !== undefined && old.albumId !== null ? old.albumId : '';
  const songmid: string = String(old.songmid);

  if (old.source === 'kg') {
    const hash: string = old.hash !== undefined ? old.hash : '';
    const meta: LxMusicMeta = {
      songId: songmid,
      albumName: albumName,
      picUrl: picUrl,
      qualitys: qualitys,
      _qualitys: qualitySizes,
      albumId: albumId,
      hash: hash,
    };
    return {
      id: musicIdOf(old),
      name: old.name,
      singer: old.singer,
      source: 'kg',
      interval: old.interval,
      meta: meta,
    };
  }

  if (old.source === 'tx') {
    const meta: LxMusicMeta = {
      songId: songmid,
      albumName: albumName,
      picUrl: picUrl,
      qualitys: qualitys,
      _qualitys: qualitySizes,
      albumId: albumId,
      strMediaMid: old.strMediaMid !== undefined ? old.strMediaMid : '',
      albumMid: old.albumMid !== undefined ? old.albumMid : '',
    };
    if (old.songId !== undefined) {
      meta.id = old.songId;
    }
    return {
      id: musicIdOf(old),
      name: old.name,
      singer: old.singer,
      source: 'tx',
      interval: old.interval,
      meta: meta,
    };
  }

  if (old.source === 'mg') {
    const meta: LxMusicMeta = {
      songId: songmid,
      albumName: albumName,
      picUrl: picUrl,
      qualitys: qualitys,
      _qualitys: qualitySizes,
      albumId: albumId,
    };
    if (old.copyrightId !== undefined) {
      meta.copyrightId = old.copyrightId;
    }
    return {
      id: musicIdOf(old),
      name: old.name,
      singer: old.singer,
      source: 'mg',
      interval: old.interval,
      meta: meta,
    };
  }

  const meta: LxMusicMeta = {
    songId: songmid,
    albumName: albumName,
    picUrl: picUrl,
    qualitys: qualitys,
    _qualitys: qualitySizes,
    albumId: albumId,
  };
  return {
    id: musicIdOf(old),
    name: old.name,
    singer: old.singer,
    source: old.source,
    interval: old.interval,
    meta: meta,
  };
}

/** 同步回来的歌曲里可用的音质，挑一个默认值（与 PlaySession 的排序一致） */
export function bestQuality(info: LxMusicInfoNew): string {
  const qualitys: Record<string, LxQualitySize> | undefined =
    info.meta !== undefined ? info.meta._qualitys : undefined;
  if (qualitys !== undefined && qualitys !== null) {
    for (const quality of QUALITY_ORDER) {
      if (qualitys[quality] !== undefined) {
        return quality;
      }
    }
  }
  return '128k';
}

/**
 * 同步用歌曲 -> 内部歌曲（对应洛雪 toOldMusicInfo）。
 * musicInfoJson 就是内置搜索/源脚本使用的旧形态，播放链路直接吃它。
 */
export function fromLxMusicInfo(info: LxMusicInfoNew): SongItem {
  const meta: LxMusicMeta = info.meta;
  const picUrl: string = (meta.picUrl !== undefined && meta.picUrl !== null) ? meta.picUrl : '';
  /**
   * 展示 / 播放用的封面地址：咪咕的封面是相对路径（`/data/oss/...`），直接拿去加载
   * 谁也用不了（列表只剩占位图，播控中心会把它当成不存在的本地文件）。
   * 老数据（收藏 / 歌单 / 同步回来的）里存的就是这种相对路径，所以在还原成内部条目
   * 这一层补一次宿主，见 MusicSearch.mgImageUrl。
   *
   * 只补 coverUrl，不动下面 SDK 形态里的 img：那份是「与洛雪一致的数据」，同步快照
   * 按它的 JSON 算 md5，本地擅自改值会让同一份列表在两端算出的 key 对不上。
   */
  const coverUrl: string = info.source === 'mg' ? mgImageUrl(picUrl) : picUrl;
  const types: LxQualityItem[] = [];
  const qualitySizes: Record<string, LxQualitySize> | undefined = meta._qualitys;
  if (meta.qualitys !== undefined && meta.qualitys !== null && Array.isArray(meta.qualitys)) {
    const list = meta.qualitys as LxQualityItem[];
    for (const item of list) {
      if (item !== null && item !== undefined) {
        types.push(item);
      }
    }
  }
  const old: LxMusicInfo = {
    name: info.name,
    singer: info.singer,
    source: info.source,
    songmid: meta.songId !== undefined && meta.songId !== null ? String(meta.songId) : '',
    albumName: meta.albumName !== undefined && meta.albumName !== null ? meta.albumName : '',
    albumId: meta.albumId !== undefined && meta.albumId !== null ? String(meta.albumId) : '',
    interval: info.interval !== undefined && info.interval !== null ? info.interval : '',
    img: picUrl,
    types: types,
    _types: toQualityItems(qualitySizes),
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
  if (info.source === 'kg' && meta.hash !== undefined) {
    old.hash = meta.hash;
  }
  if (info.source === 'tx') {
    if (meta.strMediaMid !== undefined) {
      old.strMediaMid = meta.strMediaMid;
    }
    if (meta.albumMid !== undefined) {
      old.albumMid = meta.albumMid;
    }
    if (meta.id !== undefined) {
      old.songId = String(meta.id);
    }
  }
  if (info.source === 'mg' && meta.copyrightId !== undefined) {
    old.copyrightId = meta.copyrightId;
  }

  return {
    id: info.id,
    name: info.name,
    singer: info.singer,
    coverUrl: coverUrl,
    art: coverUrl.length === 0,
    source: info.source,
    quality: bestQuality(info),
    interval: old.interval,
    musicInfoJson: JSON.stringify(old),
  };
}
