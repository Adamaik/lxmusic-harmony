/**
 * 已下载文件的索引 + 「排自动下载」的入口（纯内存，无依赖）
 *
 * 播放层要知道「这首歌是不是已经下载到本地、文件在哪」，而下载层要用到播放层的
 * SongItem 类型。如果两边互相 import 就绕成环了，所以把这张表单独放一个叶子模块：
 * 下载完成后写进来，播放前查一下。
 *
 * 同一个理由，「缓存时自动下载」要排队时播放层也不直接 import 下载器：下载器在
 * 启动时把自己的入口注册进来（setAutoDownloadHandler），播放层只按这里的窄接口
 * （AutoDownloadSong）说话。因此**这个模块不许 import 任何东西**，一 import 叶子就没了。
 */

/**
 * 排一首自动下载要交给下载层的字段
 *
 * 与播放层的 SongItem 同形，但刻意在这里重新声明一份：这个模块不能 import
 * SongItem，否则上面那条「叶子」就破了。
 */
export interface AutoDownloadSong {
  id: string;
  name: string;
  singer: string;
  coverUrl: string;
  art: boolean;
  source: string;
  /** 按播放用的那一档音质下，别让听的和存的不是同一个东西 */
  quality: string;
  interval: string;
  musicInfoJson: string;
}

/** 下载器的入口：收下这首歌返回 true，不收（本地歌 / 云端歌 / 没有 musicInfo 等）返回 false */
export type AutoDownloadHandler = (song: AutoDownloadSong) => boolean;

let autoHandler: AutoDownloadHandler | null = null;

/** 下载器 init 时把自己注册进来 */
export function setAutoDownloadHandler(handler: AutoDownloadHandler): void {
  autoHandler = handler;
}

/**
 * 请下载器排一首歌（「缓存时自动下载」用）
 *
 * 返回 false 表示下载器不收 —— 调用方必须照旧走播放缓存，不能让这首歌
 * 既下不了又缓不上。没注册（下载器还没 init）时同样返回 false。
 */
export function requestAutoDownload(song: AutoDownloadSong): boolean {
  return autoHandler !== null ? autoHandler(song) : false;
}

const files: Map<string, string> = new Map();

/** key：媒体的唯一标识（mediaKeyOf 的结果；没有 musicInfo 的条目用条目 id） */
export function setDownloadedFile(key: string, uri: string): void {
  if (key.length === 0 || uri.length === 0) {
    return;
  }
  files.set(key, uri);
}

export function removeDownloadedFile(key: string): void {
  files.delete(key);
}

export function clearDownloadedFiles(): void {
  files.clear();
}

/** 命中返回本地文件（沙箱路径或文档 uri），否则空串 */
export function downloadedFile(key: string): string {
  if (key.length === 0) {
    return '';
  }
  const uri: string | undefined = files.get(key);
  return uri === undefined ? '' : uri;
}
