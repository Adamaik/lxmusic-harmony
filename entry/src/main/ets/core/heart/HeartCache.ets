/**
 * 心动模式 · 候选池缓存
 *
 * 目的：进「探索」页不要每次都先等几秒拉全网。上次拉到的那批候选落盘，下次进来先
 * 用缓存立刻出歌、立刻自动播，随后后台再拉一批新的替换（用户完全无感）。
 *
 * 只缓存**候选池**，不缓存画像：画像来自本地历史/收藏，读一次只要几毫秒，
 * 缓存它反而容易和真实数据不一致（收藏改了、历史删了都会不同步）。
 *
 * 落盘位置：应用沙箱 filesDir/heart_cache.json，与 listen_log.json 同一层。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { SongItem } from '../player/PlaySession';

const FILE_NAME: string = 'heart_cache.json';
/** 结构变了就 +1，读到不认识的版本当没有缓存（不硬扛） */
const CACHE_VERSION: number = 1;

/** 落盘的一条歌：只存播放/展示/编码都需要的字段（SongItem 的完整形状） */
interface CachedSong {
  id: string;
  name: string;
  singer: string;
  coverUrl: string;
  art: boolean;
  source: string;
  quality: string;
  interval: string;
  musicInfoJson: string;
}

interface CachedPool {
  version: number;
  savedAt: number;
  /** 这批候选来自哪个平台（换平台后缓存可能不适用，但先出歌总比干等好） */
  source: string;
  songs: CachedSong[];
}

function toCached(item: SongItem): CachedSong {
  const song: CachedSong = {
    id: item.id,
    name: item.name,
    singer: item.singer,
    coverUrl: item.coverUrl,
    art: item.art,
    source: item.source,
    quality: item.quality,
    interval: item.interval,
    musicInfoJson: item.musicInfoJson,
  };
  return song;
}

function toSongItem(song: CachedSong): SongItem {
  const item: SongItem = {
    id: song.id,
    name: song.name,
    singer: song.singer,
    coverUrl: song.coverUrl,
    art: song.art,
    source: song.source,
    quality: song.quality,
    interval: song.interval,
    musicInfoJson: song.musicInfoJson,
  };
  return item;
}

export class HeartCache {
  private static instance: HeartCache | null = null;

  static getInstance(): HeartCache {
    if (HeartCache.instance === null) {
      HeartCache.instance = new HeartCache();
    }
    return HeartCache.instance;
  }

  private file: string = '';

  /** EntryAbility.onCreate 里调一次（要 filesDir） */
  init(context: common.Context): void {
    this.file = `${context.filesDir}/${FILE_NAME}`;
  }

  /** 读缓存；没有/损坏/版本不对都返回空数组，不抛 */
  load(): SongItem[] {
    if (this.file.length === 0) {
      return [];
    }
    try {
      if (!fs.accessSync(this.file)) {
        return [];
      }
      const text: string = fs.readTextSync(this.file);
      const data: CachedPool = JSON.parse(text) as CachedPool;
      if (data.version !== CACHE_VERSION || data.songs === undefined) {
        return [];
      }
      const out: SongItem[] = [];
      for (let i = 0; i < data.songs.length; i++) {
        out.push(toSongItem(data.songs[i]));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 写缓存：失败只记日志不抛（缓存坏了不该影响推荐） */
  save(source: string, songs: SongItem[]): void {
    if (this.file.length === 0) {
      return;
    }
    const payload: CachedPool = {
      version: CACHE_VERSION,
      savedAt: Date.now(),
      source: source,
      songs: songs.map((item: SongItem) => toCached(item)),
    };
    try {
      const handle = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      // 缓存写失败不影响主流程
    }
  }

  /** 缓存时间（毫秒时间戳，0 = 没有） */
  savedAt(): number {
    if (this.file.length === 0) {
      return 0;
    }
    try {
      if (!fs.accessSync(this.file)) {
        return 0;
      }
      const data: CachedPool = JSON.parse(fs.readTextSync(this.file)) as CachedPool;
      return data.savedAt;
    } catch (e) {
      return 0;
    }
  }
}
