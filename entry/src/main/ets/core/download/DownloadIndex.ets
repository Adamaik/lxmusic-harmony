/**
 * 已下载文件的索引（纯内存，无依赖）
 *
 * 播放层要知道「这首歌是不是已经下载到本地、文件在哪」，而下载层要用到播放层的
 * SongItem 类型。如果两边互相 import 就绕成环了，所以把这张表单独放一个叶子模块：
 * 下载完成后写进来，播放前查一下。
 */

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
