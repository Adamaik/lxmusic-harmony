/**
 * 心动模式 · 全网候选池
 *
 * 分工（这是整个设计的关键）：
 *   **画像只用本地**：播放历史 / 收藏 / 本地曲库的元数据，见 HeartRadio.collectInterest
 *   **候选池来自全网**：这里的目录层四入口（榜单 / 推荐歌单 / 艺人作品 / 搜索），
 *   与 heartbeat_ondevice 的 pool.py 是同一套结构 —— 全量曲库只当目录，推荐只在
 *   这个几百首的池子里做。
 *
 * 为什么不能只用本地：本地曲库是用户「已经有的」，推荐本来就该推他没有的；
 * 只从本地挑，本质是个本地随机播放器，不叫心动模式。
 *
 * 所有入口都各自 try/catch：某一个平台接口挂了不影响其它入口，能拿多少算多少。
 */

import { getBoardSongs, getBoards, getPlaylistDetail, getRecommendPlaylists, sortListOf,
  LxListDetail, LxPlaylistItem } from '../music/MusicList';
import { LxMusicInfo } from '../music/MusicSearch';
import { findArtistByName, getArtistSongs } from '../music/MusicArtist';
import { PlaySession, songFromSearch, SongItem } from '../player/PlaySession';
import { HeartDoc } from './HeartTypes';
import { songKeyOfItem } from './HeartIdentity';

/** 榜单入口：取几张榜、每张多少首 */
const BOARD_COUNT: number = 3;
const BOARD_LIMIT: number = 40;
/** 推荐歌单入口：取几个歌单（每个只取第一页） */
const PLAYLIST_COUNT: number = 2;
/** 艺人作品入口：从画像里取几个高频艺人、每人多少首 */
const ARTIST_COUNT: number = 3;
const ARTIST_LIMIT: number = 30;
/** 池子上限：几百首足够刷一晚上，再大只是白耗内存与打分时间 */
const POOL_LIMIT: number = 400;

/** Map 取值带缺省（ArkTS 里 Map.get 是 T | undefined，这里收口一次） */
function countOf(map: Map<string, number>, key: string): number {
  const value: number | undefined = map.get(key);
  return value === undefined ? 0 : value;
}

export class HeartPool {
  /**
   * 建池子
   *
   * @param source 平台（kw / kg / mg / tx / wy / qs）
   * @param interest 本地画像（只用其中的歌手名做「艺人作品」入口）
   * @param excludeIds 最近听过的 id：候选里剔掉，免得「推荐」= 刚听过的
   */
  static async build(source: string, interest: HeartDoc[], excludeKeys: Set<string>,
    excludeIds: Set<string>): Promise<SongItem[]> {
    const quality: string = PlaySession.getInstance().quality;
    const out: SongItem[] = [];
    // 按「歌名+歌手」去重：同一首歌从不同音源回来只留第一条
    const seen: Set<string> = new Set<string>();
    const add = (info: LxMusicInfo): void => {
      const item: SongItem = songFromSearch(info, quality);
      const key: string = songKeyOfItem(item);
      if (item.id.length === 0 || seen.has(key) || excludeKeys.has(key) || excludeIds.has(item.id)) {
        return;
      }
      seen.add(key);
      out.push(item);
    };

    // 入口 1：榜单（不需要登录，最稳的一条）
    const boards = getBoards(source);
    const boardCount: number = Math.min(BOARD_COUNT, boards.length);
    for (let i = 0; i < boardCount && out.length < POOL_LIMIT; i++) {
      try {
        const detail: LxListDetail = await getBoardSongs(source, boards[i].bangid, 1,
          boards[i].name, BOARD_LIMIT);
        for (let j = 0; j < detail.list.length; j++) {
          add(detail.list[j]);
        }
      } catch (e) {
        // 这张榜没取到就算了
      }
    }

    // 入口 2：推荐歌单（歌单广场里按当前平台第一个分类）
    try {
      const sorts = sortListOf(source);
      const sortId: string = sorts.length > 0 ? sorts[0].id : '';
      const playlists: LxPlaylistItem[] = await getRecommendPlaylists(source, sortId, 1);
      const playlistCount: number = Math.min(PLAYLIST_COUNT, playlists.length);
      for (let i = 0; i < playlistCount && out.length < POOL_LIMIT; i++) {
        try {
          const detail: LxListDetail = await getPlaylistDetail(source, playlists[i].id, 1);
          for (let j = 0; j < detail.list.length; j++) {
            add(detail.list[j]);
          }
        } catch (e) {
          // 这张歌单没取到就算了
        }
      }
    } catch (e) {
      // 推荐歌单整块失败（未登录/平台不支持）：榜单已经够用
    }

    // 入口 3：艺人作品（画像里最常听的几个艺人 → 平台上认人 → 拿他的歌）
    const artists: string[] = HeartPool.topArtists(interest, ARTIST_COUNT);
    for (let i = 0; i < artists.length && out.length < POOL_LIMIT; i++) {
      try {
        const artist = await findArtistByName(source, artists[i]);
        if (artist === null) {
          continue;
        }
        const page = await getArtistSongs(artist, 1, ARTIST_LIMIT);
        for (let j = 0; j < page.list.length; j++) {
          add(page.list[j]);
        }
      } catch (e) {
        // 这位艺人没认出来/没取到就算了
      }
    }

    return out;
  }

  /** 画像里出现次数最多的艺人（去重后按次数降序） */
  static topArtists(interest: HeartDoc[], count: number): string[] {
    const tally: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < interest.length; i++) {
      const name: string = interest[i].singer.trim();
      if (name.length === 0) {
        continue;
      }
      tally.set(name, countOf(tally, name) + 1);
    }
    const names: string[] = [];
    tally.forEach((value: number, key: string) => {
      names.push(key);
    });
    names.sort((a: string, b: string) => countOf(tally, b) - countOf(tally, a));
    return names.slice(0, count);
  }
}
