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

import { hilog } from '@kit.PerformanceAnalysisKit';
import { getBoardSongs, getBoards, getPlaylistDetail, getRecommendPlaylists, sortListOf,
  LxBoardItem, LxListDetail, LxPlaylistItem, LxSortItem } from '../music/MusicList';
import { LxMusicInfo } from '../music/MusicSearch';
import { findArtistByName, getArtistSongs } from '../music/MusicArtist';
import { PlaySession, songFromSearch, SongItem } from '../player/PlaySession';
import { HeartDoc } from './HeartTypes';
import { songKeyOfItem } from './HeartIdentity';

/** 榜单入口：挑几张榜、每张多少首 */
const BOARD_COUNT: number = 3;
const BOARD_LIMIT: number = 40;
/** 推荐歌单入口：取几个歌单（每个只取第一页） */
const PLAYLIST_COUNT: number = 2;
/**
 * 艺人作品入口：从画像里取几个高频艺人、每人多少首
 *
 * 从 3 人 × 30 首收紧到 2 人 × 20 首：常听艺人的作品天然是旧歌，人数和首数越大，
 * 老歌越容易把整个池子埋掉（池子上限只有 400 首）。
 */
const ARTIST_COUNT: number = 2;
const ARTIST_LIMIT: number = 20;
/** 池子上限：几百首足够刷一晚上，再大只是白耗内存与打分时间 */
const POOL_LIMIT: number = 400;

/** 日志域沿用工程的 0x0001（ListenLog 同域），不新开 DOMAIN */
const DOMAIN: number = 0x0001;
const TAG: string = 'HeartPool';

// ------------------------------------------------------------------ 新鲜度

/** 榜单名关键词：新歌 / 飙升 / 短视频热歌这类榜整体偏新 */
const FRESH_HIGH: string[] = ['新歌', '飙升', '抖音热歌', '网络歌曲', '抖快', '流行指数'];
/** 次一级：热歌 / 综合大榜，新旧混排 */
const FRESH_MID: string[] = ['热歌', 'TOP500', '音乐风向'];
/** 明确偏旧：经典 / 怀旧 / 金曲 / 老歌类榜，最后才考虑 */
const FRESH_STALE: string[] = ['经典', '怀旧', '金曲', '老歌'];
const FRESH_HIGH_SCORE: number = 0.9;
const FRESH_MID_SCORE: number = 0.65;
const FRESH_STALE_SCORE: number = 0.1;
/** 名字里没有任何线索的榜：给个中间值，不好也不坏 */
const FRESH_UNKNOWN_SCORE: number = 0.3;
/** 歌单 / 艺人作品入口的固定新鲜度：这两条入口本身偏老歌，只给一点曝光补偿 */
const LOW_FRESH: number = 0.15;

/**
 * 歌单名里的「旧」信号
 *
 * 真机实测：歌单入口即使用了「最新」分类，仍然会拿到「豆瓣2018年最高评分专辑Top 10」
 * 这种 **歌单是新的、里面全是老歌** 的专辑盘 —— 分类只描述歌单的建单时间，不描述内容。
 * 拿不到歌曲发行年份，只能再退一步：按歌单**名字**里的年份/关键词把它挑出去。
 * 这是启发式，认不出来的一律当「新」保留（宁可留、不可错杀）。
 */
const OLD_PLAYLIST_WORDS: string[] = ['经典', '怀旧', '老歌', '金曲', '珍藏', '回忆', '年代'];

/** 歌单名是否明显在讲老歌（含旧年份，或含经典/怀旧一类词） */
export function playlistLooksOld(name: string): boolean {
  for (let i = 0; i < OLD_PLAYLIST_WORDS.length; i++) {
    if (name.includes(OLD_PLAYLIST_WORDS[i])) {
      return true;
    }
  }
  // 名字里的四位年份：早于「今年 - 2」就当老内容（2026 年时 2023 及更早）
  const limitYear: number = new Date().getFullYear() - 2;
  const re: RegExp = /(19|20)\d{2}/g;
  let match: RegExpExecArray | null = re.exec(name);
  while (match !== null) {
    const year: number = parseInt(match[0], 10);
    if (year <= limitYear) {
      return true;
    }
    match = re.exec(name);
  }
  return false;
}

/**
 * 榜单名 → 基础新鲜度权重（0~1，纯函数，便于单测）
 *
 * 洛雪给各平台的榜单顺序是写死的，也不保证「越靠前的榜越新」（酷我第一张是飙升榜，
 * 酷狗第一张是 TOP500，咪咕第一张才是新歌榜），所以先按名字打分再挑榜。
 * 判定顺序必须高优先在前：「抖音热歌榜」同时含「热歌」，但它属于短视频热歌，
 * 明显比普通热歌榜新。
 */
export function boardFreshness(name: string): number {
  const text: string = name.toUpperCase();
  for (let i = 0; i < FRESH_HIGH.length; i++) {
    if (text.includes(FRESH_HIGH[i])) {
      return FRESH_HIGH_SCORE;
    }
  }
  for (let i = 0; i < FRESH_MID.length; i++) {
    if (text.includes(FRESH_MID[i])) {
      return FRESH_MID_SCORE;
    }
  }
  for (let i = 0; i < FRESH_STALE.length; i++) {
    if (text.includes(FRESH_STALE[i])) {
      return FRESH_STALE_SCORE;
    }
  }
  return FRESH_UNKNOWN_SCORE;
}

/**
 * 榜内排名 → 新鲜度：freshBoost = boardWeight * (1 - rank / total)
 *
 * rank 从 1 开始，整体单调递减：榜首 ≈ boardWeight，榜尾 ≈ 0。拿不到发行时间时，
 * 「新歌榜第 10 首比第 30 首新」是唯一稳定成立的假设，所以用它替代发行日期。
 */
export function freshOfRank(boardWeight: number, rank: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  const decay: number = 1 - rank / total;
  if (decay <= 0) {
    return 0;
  }
  return boardWeight * decay;
}

/** 带权重与原始下标的榜单：排序用，ArkTS 不允许匿名结构 */
class BoardWeight {
  board: LxBoardItem;
  weight: number;
  /** 平台原有顺序，同权重时靠它保持稳定 */
  index: number;

  constructor(board: LxBoardItem, weight: number, index: number) {
    this.board = board;
    this.weight = weight;
    this.index = index;
  }
}

/**
 * 从平台榜单目录里挑出最像「新歌」的 count 张（纯函数，便于单测）
 *
 * 权重降序、同权保持原有顺序。这样酷我/网易会挑到「飙升榜 + 新歌榜 + 抖音热歌榜」，
 * 而不是原来那三张不知道含义的榜。
 */
export function pickBoards(boards: LxBoardItem[], count: number): LxBoardItem[] {
  const weighted: BoardWeight[] = [];
  for (let i = 0; i < boards.length; i++) {
    weighted.push(new BoardWeight(boards[i], boardFreshness(boards[i].name), i));
  }
  weighted.sort((a: BoardWeight, b: BoardWeight) => {
    if (b.weight !== a.weight) {
      return b.weight - a.weight;
    }
    return a.index - b.index;
  });
  const out: LxBoardItem[] = [];
  const limit: number = Math.min(count, weighted.length);
  for (let i = 0; i < limit; i++) {
    out.push(weighted[i].board);
  }
  return out;
}

/** 歌单分类里挑最像「新歌」的一个：最新 → 新歌 → 热歌，都没有才退回第一个 */
function pickSortIndex(sorts: LxSortItem[]): number {
  const wants: string[] = ['最新', '新歌', '热歌'];
  for (let w = 0; w < wants.length; w++) {
    for (let i = 0; i < sorts.length; i++) {
      if (sorts[i].name.includes(wants[w])) {
        return i;
      }
    }
  }
  return sorts.length > 0 ? 0 : -1;
}

/**
 * 建池结果
 *
 * 新鲜度挂不到 SongItem 上（那是播放队列的形状接口，动它会波及播放与落盘），
 * 所以随结果一起带出来，由 HeartRadio 生成 HeartDoc 时写进 doc.freshBoost。
 */
export class HeartPoolResult {
  /** 候选歌，已按新鲜度稳定排序（同分保持入口原有顺序） */
  songs: SongItem[];
  /** 身份键（歌名+歌手）→ 新鲜度 */
  fresh: Map<string, number>;

  constructor(songs: SongItem[], fresh: Map<string, number>) {
    this.songs = songs;
    this.fresh = fresh;
  }
}

/** Map 取值带缺省（ArkTS 里 Map.get 是 T | undefined，这里收口一次） */
function countOf(map: Map<string, number>, key: string): number {
  const value: number | undefined = map.get(key);
  return value === undefined ? 0 : value;
}

/** 同上，新鲜度表用 */
function boostOf(map: Map<string, number>, key: string): number {
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
    excludeIds: Set<string>): Promise<HeartPoolResult> {
    const quality: string = PlaySession.getInstance().quality;
    const out: SongItem[] = [];
    const fresh: Map<string, number> = new Map<string, number>();
    // 按「歌名+歌手」去重：同一首歌从不同音源回来只留第一条；但新鲜度取各入口的
    // 最大值 —— 同一首歌既在飙升榜又在艺人作品里时，该按「它确实新」算，而不是先到先得
    const seen: Set<string> = new Set<string>();
    const add = (info: LxMusicInfo, boost: number): boolean => {
      const item: SongItem = songFromSearch(info, quality);
      const key: string = songKeyOfItem(item);
      if (item.id.length === 0 || excludeKeys.has(key) || excludeIds.has(item.id)) {
        return false;
      }
      if (seen.has(key)) {
        if (boost > boostOf(fresh, key)) {
          fresh.set(key, boost);
        }
        return false;
      }
      seen.add(key);
      fresh.set(key, boost);
      out.push(item);
      return true;
    };

    // 入口 1：榜单（不需要登录，最稳的一条）。不再盲取前 N 张：先按榜名挑「新」的
    const boards: LxBoardItem[] = getBoards(source);
    const picked: LxBoardItem[] = pickBoards(boards, BOARD_COUNT);
    let boardAdded: number = 0;
    if (picked.length === 0) {
      hilog.warn(DOMAIN, TAG, '榜单入口：平台 %{public}s 没有可用榜（共 %{public}d 张）',
        source, boards.length);
    }
    for (let i = 0; i < picked.length && out.length < POOL_LIMIT; i++) {
      const board: LxBoardItem = picked[i];
      const weight: number = boardFreshness(board.name);
      try {
        const detail: LxListDetail = await getBoardSongs(source, board.bangid, 1,
          board.name, BOARD_LIMIT);
        let added: number = 0;
        for (let j = 0; j < detail.list.length; j++) {
          // 榜内位置决定同一张榜内部的先后：第 1 首 ≈ weight，越靠后越接近 0
          if (add(detail.list[j], freshOfRank(weight, j + 1, detail.list.length))) {
            added += 1;
          }
        }
        boardAdded += added;
        hilog.info(DOMAIN, TAG,
          '榜单入口「%{public}s」取到 %{public}d 首，新增 %{public}d 首，榜名权重 %{public}s',
          board.name, detail.list.length, added, weight.toFixed(2));
      } catch (e) {
        // 这张榜没取到不影响其它入口，但必须留痕：真机上原来完全看不到失败
        hilog.warn(DOMAIN, TAG, '榜单入口「%{public}s」失败：%{public}s',
          board.name, JSON.stringify(e));
      }
    }

    // 入口 2：推荐歌单（歌单广场里挑最像「新歌」的分类，而不是写死的第一个）
    let playlistAdded: number = 0;
    try {
      const sorts: LxSortItem[] = sortListOf(source);
      const sortIndex: number = pickSortIndex(sorts);
      if (sortIndex < 0) {
        hilog.warn(DOMAIN, TAG, '歌单入口：平台 %{public}s 没有歌单分类，跳过', source);
      } else {
        const sort: LxSortItem = sorts[sortIndex];
        const playlists: LxPlaylistItem[] = await getRecommendPlaylists(source, sort.id, 1);
        // 先按名字筛掉「专辑盘」式的老歌单（见 playlistLooksOld 的注释）：
        // 分类只说明歌单什么时候建的，不说明里面的歌是什么年代
        const picked: LxPlaylistItem[] = [];
        for (let i = 0; i < playlists.length && picked.length < PLAYLIST_COUNT; i++) {
          if (playlistLooksOld(playlists[i].name)) {
            hilog.info(DOMAIN, TAG, '歌单入口跳过疑似老歌专辑盘「%{public}s」', playlists[i].name);
            continue;
          }
          picked.push(playlists[i]);
        }
        // 全被判老：宁可只留第一张（它的歌仍只拿 LOW_FRESH，排不进前排），也不要整块灌老歌
        if (picked.length === 0 && playlists.length > 0) {
          picked.push(playlists[0]);
        }
        const playlistCount: number = picked.length;
        for (let i = 0; i < playlistCount && out.length < POOL_LIMIT; i++) {
          const playlist: LxPlaylistItem = picked[i];
          try {
            const detail: LxListDetail = await getPlaylistDetail(source, playlist.id, 1);
            let added: number = 0;
            for (let j = 0; j < detail.list.length; j++) {
              // 歌单只能从分类判断「整体偏新」，逐首无从推断，统一给低值
              if (add(detail.list[j], LOW_FRESH)) {
                added += 1;
              }
            }
            playlistAdded += added;
            hilog.info(DOMAIN, TAG, '歌单入口「%{public}s」取到 %{public}d 首，新增 %{public}d 首',
              playlist.name, detail.list.length, added);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, '歌单入口「%{public}s」失败：%{public}s',
              playlist.name, JSON.stringify(e));
          }
        }
        hilog.info(DOMAIN, TAG, '歌单入口分类「%{public}s」共 %{public}d 个歌单，新增 %{public}d 首',
          sort.name, playlistCount, playlistAdded);
      }
    } catch (e) {
      // 推荐歌单整块失败（未登录/平台不支持）：榜单已经够用，但原因要打出来
      hilog.warn(DOMAIN, TAG, '歌单入口整体失败：%{public}s', JSON.stringify(e));
    }

    // 入口 3：艺人作品（画像里最常听的几位 → 平台上认人 → 拿他的歌）
    // 常听艺人天然是旧歌，所以人数/首数都收紧，且只给低新鲜度，避免老歌淹没池子
    const artists: string[] = HeartPool.topArtists(interest, ARTIST_COUNT);
    let artistAdded: number = 0;
    for (let i = 0; i < artists.length && out.length < POOL_LIMIT; i++) {
      const name: string = artists[i];
      try {
        const artist = await findArtistByName(source, name);
        if (artist === null) {
          hilog.warn(DOMAIN, TAG, '艺人入口「%{public}s」没认出来，跳过', name);
          continue;
        }
        const page = await getArtistSongs(artist, 1, ARTIST_LIMIT);
        let added: number = 0;
        for (let j = 0; j < page.list.length; j++) {
          if (add(page.list[j], LOW_FRESH)) {
            added += 1;
          }
        }
        artistAdded += added;
        hilog.info(DOMAIN, TAG, '艺人入口「%{public}s」取到 %{public}d 首，新增 %{public}d 首',
          name, page.list.length, added);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '艺人入口「%{public}s」失败：%{public}s', name, JSON.stringify(e));
      }
    }

    // 池子整体按新鲜度稳定排序：引擎精排前还有一层粗筛（只留余弦前 400），
    // 顺序在这里稳住，前几张卡就一定是新的；同分保持入口原有顺序（下标兜底）
    const order: number[] = [];
    for (let i = 0; i < out.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number) => {
      const diff: number = boostOf(fresh, songKeyOfItem(out[b])) -
        boostOf(fresh, songKeyOfItem(out[a]));
      if (diff !== 0) {
        return diff;
      }
      return a - b;
    });
    const songs: SongItem[] = [];
    let sum: number = 0;
    for (let i = 0; i < order.length; i++) {
      const song: SongItem = out[order[i]];
      songs.push(song);
      sum += boostOf(fresh, songKeyOfItem(song));
    }
    const avg: number = songs.length === 0 ? 0 : sum / songs.length;
    // 汇总一行，真机上直接看这一条就能判断池子是不是"全是老歌"
    hilog.info(DOMAIN, TAG,
      '池子 %{public}d 首｜榜单 %{public}d 首｜歌单 %{public}d 首｜艺人 %{public}d 首｜平均新鲜度 %{public}s',
      songs.length, boardAdded, playlistAdded, artistAdded, avg.toFixed(2));
    return new HeartPoolResult(songs, fresh);
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
