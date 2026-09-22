/**
 * WebDAV 云端音乐的类型与常量
 *
 * 这一层刻意不 import 任何东西（连 SongItem 都不引），这样协议解析、曲库、界面
 * 都能安全地引它而不会绕出循环依赖；「这条是不是云端歌」的判断放在 WebDavLibrary
 * （与 LocalMusic.isLocalSong 的位置对应）。
 */

/** WebDAV 音频在 SongItem.source / musicInfo.source 里的标记 */
export const WEBDAV_SOURCE: string = 'webdav';

/**
 * 云端歌的条目 id 前缀
 *
 * 与本地歌的 `local_` 同构：`webdav_<key>`。mediaKeyOf(musicInfoJson) 算出来正好
 * 也是 `webdav_<key>`（见 core/music/MediaCache.mediaKeyOf），所以条目 id、
 * AudioCache 的键、下载索引的键天然自洽（本地歌也有同样的不变式）。
 */
export const WEBDAV_ID_PREFIX: string = 'webdav_';

/**
 * 云端歌的「音质」标记
 *
 * WebDAV 没有音质协商（服务器上是什么就是什么），界面按它显示「云端」，
 * 也用它当 AudioCache 的 quality 段。
 */
export const WEBDAV_QUALITY: string = 'webdav';

/**
 * 连接配置
 *
 * url 是一个**目录**地址（可以是服务器根，也可以直接指到音乐目录，
 * 例如 `https://dav.example.com/remote.php/dav/files/me/Music`），末尾斜杠可有可无。
 */
export interface WebDavConfig {
  url: string;
  username: string;
  password: string;
}

/** 一个 PROPFIND 响应（服务器上的一个条目） */
export interface WebDavEntry {
  /**
   * 绝对 URL（服务器返回的 href 已按配置里的 origin 补全、特殊字符已转义）
   *
   * 播放、取歌词、下载封面都用它，所以它必须是一个能直接请求的完整地址。
   */
  url: string;
  /** 解码后的显示名（路径最后一段） */
  name: string;
  /** 父目录 URL（以 `/` 结尾）；根目录的条目就是配置里那个地址 */
  folder: string;
  /** 是不是目录（resourcetype 里有 collection） */
  isCollection: boolean;
  /** 字节数（-1 = 服务器没给 getcontentlength，目录一般不给） */
  size: number;
  /** 最后修改时间（毫秒；-1 = 没给或解析不了） */
  modifiedMs: number;
}

/** 从远端音频文件里读出来的标签（AVMetadataExtractor 的网络源模式） */
export interface WebDavTags {
  title: string;
  artist: string;
  album: string;
  durationMs: number;
}

export function emptyTags(): WebDavTags {
  return { title: '', artist: '', album: '', durationMs: 0 };
}

/** 连接自检结果 */
export interface WebDavProbeResult {
  ok: boolean;
  /** 一句话结论（成功是「连上了，根目录下有 N 个条目」，失败是原因） */
  message: string;
  /** 根目录下的条目数（失败时为 0） */
  entryCount: number;
}

