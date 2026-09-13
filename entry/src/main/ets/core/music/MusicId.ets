import { LxMusicInfo } from './MusicSearch';

/**
 * 歌曲条目在界面上的稳定 id
 *
 * 规则必须与同步结构里的 id 完全一致（core/sync/SyncConvert.toLxMusicInfo）：
 *   酷狗：`${songmid}_${hash}`（hash 可能为空串，下划线仍在）
 *   其它：`${source}_${songmid}`
 *
 * 界面上的条目有两个来源：
 *   - 排行榜 / 搜索结果：接口结果直接造成 SongItem（songFromSearch）；
 *   - 收藏 / 歌单：从同步结构还原出来（SyncConvert.fromLxMusicInfo），id 就是这个规则算的。
 * 两边的 id 规则不一致时，同一首歌在两个列表里会是两个 key —— 表现就是
 * 「在排行榜收藏了，进收藏歌单却看不到红心」，重复收藏也去不掉重。
 */
export function musicIdOf(info: LxMusicInfo): string {
  const songmid: string =
    info.songmid !== undefined && info.songmid !== null ? String(info.songmid) : '';
  if (info.source === 'kg') {
    const hash: string = info.hash !== undefined ? info.hash : '';
    return `${songmid}_${hash}`;
  }
  return `${info.source}_${songmid}`;
}
