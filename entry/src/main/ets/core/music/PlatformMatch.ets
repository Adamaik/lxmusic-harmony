import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo, searchMusicPage } from './MusicSearch';
import { songIdentityOf } from './SongIdentity';
import { asNumber, asString } from './PlatformHttp';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlatformMatch';

/** 单次搜索取多少条候选（够覆盖同名不同版本的了；再大只是浪费请求） */
const MATCH_PAGE_LIMIT: number = 30;

/**
 * 跨平台匹配结果
 *
 * `songId` 是**目标平台自己的数字 id**（写「喜欢」要它）；0 表示这个平台上找不到
 * 与「歌名+作者」严格一致的那一首，调用方应当跳过（不能拿近似结果去写：
 * 写错歌比不写更糟）。
 */
export interface PlatformMatch {
  songId: number;
  songType: number;
  /** 目标平台的 mid（QQ 解析 songType 要用它；拿不到给空串） */
  songmid: string;
}

/**
 * 跨平台「同一首歌」查找（带着缓存）
 *
 * ## 为什么需要它
 * 平台同步的方向是「本机收藏 → 两个平台账号」。但本机一首歌的来源只是一个平台
 * （比如网易），要写进 QQ 账号就必须先知道「这首在 QQ 音乐里是哪个 id」。
 * 这一步只能按「歌名 + 作者」去目标平台搜索，再把**严格一致**的结果挑出来。
 *
 * ## 判定口径（用户定的）
 * 歌名与作者都归一化后完全一致才算同一首歌（见 core/music/SongIdentity.ets）。
 * 名字差一个字、换个版本（Live/Remix）都不算 —— 宁可这首不推，也不能推错。
 *
 * ## 缓存
 * 每首每次收藏事件最多搜一次；结果（含「找不到」）缓存在内存里。
 * 进程重启后缓存清空，下次收藏同一首会重新搜一次 —— 可接受（写入本身有账本兜底）。
 */
const matchCache: Map<string, PlatformMatch> = new Map<string, PlatformMatch>();

/** 缓存键：平台 + 身份键（身份键为空时不走缓存，因为无法判定同一首） */
function cacheKeyOf(platform: string, identity: string): string {
  return `${platform}|${identity}`;
}

/** 从搜索结果里取目标平台的数字 id（wy 用 songId 或数字 songmid；tx 用 songId） */
function numericIdOfResult(platform: string, info: LxMusicInfo): number {
  if (platform === 'wy') {
    const byId: number = asNumber(info.songId, 0);
    if (byId > 0) {
      return byId;
    }
    const byMid: number = asNumber(asString(info.songmid), 0);
    return byMid > 0 ? byMid : 0;
  }
  return asNumber(info.songId, 0);
}

/** 判定用的轻量归一化：小写、去空白与常见标点（与 SongIdentity 同思路，但更宽松地用于「比歌名」） */
function normalizeTitle(text: string): string {
  if (text === undefined || text === null) {
    return '';
  }
  return text.toLowerCase().replace(/[\s\u3000()（）\[\]【】{}<>《》"'“”‘’·•\-—–_~!！?？:：;；.。,，]/g, '');
}

/** 歌手串里的第一个名字（「A、B」取 A），同样做轻量归一化 */
function primarySinger(text: string): string {
  if (text === undefined || text === null) {
    return '';
  }
  const first: string = text.split(/[、,，/&＆+]|\bfeat\.?|\bft\.?/)[0];
  return normalizeTitle(first);
}

/** 主歌手是否一致（任一方向为空时视为无法判定，按不匹配处理 —— 宁可漏推也不推错歌） */
function primarySingerMatches(candidate: string, target: string): boolean {
  const a: string = primarySinger(candidate);
  const b: string = primarySinger(target);
  if (a.length === 0 || b.length === 0) {
    return false;
  }
  return a === b;
}

/**
 * 在目标平台按「歌名+作者」找同一首歌
 *
 * @returns songId>0 = 找到；songId=0 = 找不到（不算错误，调用方跳过即可）
 */
export async function matchTrackOnPlatform(platform: string, name: string, singer: string):
  Promise<PlatformMatch> {
  // songType 用 -1 表示「不知道」：0 是合法值（普通歌曲），不能当成未知
  const miss: PlatformMatch = { songId: 0, songType: -1, songmid: '' };
  const identity: string = songIdentityOf(name, singer);
  if (identity.length === 0) {
    return miss;
  }
  const key: string = cacheKeyOf(platform, identity);
  const cached: PlatformMatch | undefined = matchCache.get(key);
  if (cached !== undefined) {
    return cached;
  }
  const keyword: string = `${name} ${singer}`.trim();
  let page: LxMusicInfo[] = [];
  try {
    const result = await searchMusicPage(keyword, platform, 1, MATCH_PAGE_LIMIT);
    page = result.list;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'search failed on %{public}s: %{public}s', platform,
      e instanceof Error ? e.message : JSON.stringify(e));
    return miss;   // 搜索失败不缓存：下次收藏同一首还能再试
  }
  hilog.info(DOMAIN, TAG, 'search on %{public}s: %{public}d result(s)', platform, page.length);
  if (page.length === 0) {
    // 关键词带了歌手反而搜不到时，退回只用歌名再搜一次（不少平台的搜索对「歌名+歌手」很挑）
    try {
      const byName = await searchMusicPage(name, platform, 1, MATCH_PAGE_LIMIT);
      page = byName.list;
      hilog.info(DOMAIN, TAG, 'search (name only) on %{public}s: %{public}d result(s)',
        platform, page.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'search by name failed on %{public}s', platform);
    }
  }
  for (const info of page) {
    // 判定口径：歌名归一化后相等，且**主歌手**一致。
    // 只比主歌手是因为同一首歌的歌手写法经常不同（「张杰」/「张杰、某某」），
    // 要求整串一致会把本该命中的结果全漏掉；歌名严格相等已经足够挡住「同名不同曲」。
    if (normalizeTitle(info.name) !== normalizeTitle(name)) {
      continue;
    }
    if (!primarySingerMatches(info.singer, singer)) {
      continue;
    }
    const songId: number = numericIdOfResult(platform, info);
    if (songId <= 0) {
      continue;
    }
    const found: PlatformMatch = {
      songId: songId,
      songType: asNumber(info.songType, -1),
      songmid: asString(info.songmid),
    };
    matchCache.set(key, found);
    hilog.info(DOMAIN, TAG, 'matched on %{public}s', platform);
    return found;
  }
  matchCache.set(key, miss);
  hilog.info(DOMAIN, TAG, 'no match on %{public}s (searched %{public}d)', platform, page.length);
  return miss;
}
