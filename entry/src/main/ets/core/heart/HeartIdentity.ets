/**
 * 心动模式 · 歌曲身份
 *
 * 同一首歌可能从不同平台被推荐（酷我一条、网易一条），id 不同但是同一首歌。
 * 这里统一用「归一化后的歌名 + 歌手」当身份：
 *   - 候选池按它去重（不会同一首出现两次）
 *   - 收藏状态按它判断（在别的音源收藏过，这里也算已收藏）
 *   - 本会话已推荐过的歌按它排除（换音源不会重复推）
 */

import { SongItem } from '../player/PlaySession';
import { normalizeText } from './HeartEncoder';

/** 身份键：`歌名\u0001歌手`（都归一化：小写、标点变空格、压缩空白） */
export function songKeyOf(name: string, singer: string): string {
  return `${normalizeText(name)}\u0001${normalizeText(singer)}`;
}

export function songKeyOfItem(item: SongItem): string {
  return songKeyOf(item.name, item.singer);
}
