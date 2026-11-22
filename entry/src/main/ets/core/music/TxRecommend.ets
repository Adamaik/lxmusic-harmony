/**
 * QQ 音乐 · 账号私人推荐
 *
 * 为什么单独一个文件：这些接口都要**登录态**（Cookie / uin / 票据）才给真正的私人结果，
 * 与公开的榜单 / 歌单 / 搜索不是一条链路，混进 MusicList 会把「公开接口」与「账号接口」
 * 搅在一起（那边的每个函数都假定匿名可用）。
 *
 * 网关与鉴权（2026-11-19 实测）：
 *   POST https://u.y.qq.com/cgi-bin/musicu.fcg
 *   信封：{ comm: { ct, cv, platform, uin, authst, ... }, req_0: { module, method, param } }
 *   uin 是数字 QQ 号（Cookie 里的 `uin` 常带 `o` 前缀，要去掉），authst 是 `qm_keyst` 票据。
 *   未登录（uin:"0"）时：私人雷达与猜你喜欢**仍然返回结果**（只是偏向大众口味），
 *   每日推荐只回一层空壳卡片、最近收听直接 code 1000 —— 所以这两个必须登录才调。
 *
 * 已验证的返回结构（匿名实测 2026-11-19）：
 *   - 私人雷达 `music.recommend.TrackRelationServer / GetRadarSong`
 *       param { Page }，data.VecSongs[] 每项是 `{ Track: {...} }`，data.HasMore 表示还有下一页；
 *       每页 10 首，Page 增大时会有重复（首曲常与上一页相同），调用方必须按 mid 去重。
 *   - 猜你喜欢 `music.radioProxy.MbTrackRadioSvr / get_radio_track`
 *       param { Page, vSeed: [] }，data.tracks[] 是**扁平**的 Track（与搜索同形状），一次只有几首。
 *   - 每日推荐 `music.recommend.RecommendFeed / get_recommend_feed`
 *       param { direction: 0, page: 1, v_cache: [], v_uniq: [], s_num: 0 }，返回一堆卡片；
 *       其中 **subtype = 510** 的那张是「每日 30 首」动态歌单（`time` 是当天 unix 秒），
 *       `id` 是该歌单的 disstid。拿到 id 再走 `music.srfDissInfo.DissInfo / CgiGetDiss`
 *       读 `data.songlist`（完整 Track，与歌单详情同形状），才是真正的每日 30 首。
 *
 * 解析复用 MusicSearch.parseTxSongs（与搜索同一条映射，字段口径不会分叉）。
 * 注意：parseTxSongs 要求每首带 `file.media_mid`，所以「只给歌名 + 封面的卡片」
 * （推荐 feed 里的运营卡）解析不出来 —— 每日推荐必须走上面那条两跳链，不能直接啃卡片。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

import { asNumber, asObjectArray, asRecord, asString, httpPostJson } from './PlatformHttp';
import { LxMusicInfo, parseTxSongs } from './MusicSearch';
import { musicAccount, txMusicKeyOf, txUinOf } from './MusicAccount';

const DOMAIN: number = 0x0001;
const TAG: string = 'TxRecommend';
const GATEWAY: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
const TX_UA: string = 'QQMusic 14090508(android 12)';
/** 雷达最多翻几页（真机实测每页 10 首、Page 到 3 之后基本重复；4 页够凑 30+ 首） */
const RADAR_MAX_PAGE: number = 4;
/** 猜你喜欢最多翻几页（一次只回几首，Page 变大后重复变多；4 页凑一行够用） */
const GUESS_MAX_PAGE: number = 4;
/** 每日推荐卡片在 feed 里的 subtype 标记（510 = 「每日 30 首」动态歌单） */
const DAILY_SUBTYPE: number = 510;
/** 每日推荐歌单一次读多少首（QQ 每日 30 首，留点余量；不要拉整张） */
const DAILY_SONG_NUM: number = 60;

/** musicu.fcg 的 comm 信封（ArkTS 不允许匿名对象字面量当类型，显式建类） */
class TxComm {
  ct: number = 24;
  cv: number = 4747474;
  platform: string = 'yqq.json';
  uin: string = '0';
  g_tk: number = 5381;
  g_tk_new_20200303: number = 5381;
  format: string = 'json';
  inCharset: string = 'utf-8';
  outCharset: string = 'utf-8';
  notice: number = 0;
  need_new_code: number = 1;
  /** 登录票据（qm_keyst）；未登录为空串，字段本身不能出现空值，见 buildComm */
  authst: string = '';
}

/** 雷达参数 */
class TxRadarParam {
  Page: number = 1;
}

/** 猜你喜欢参数 */
class TxGuessParam {
  Page: number = 1;
  vSeed: number[] = [];
}

class TxReq {
  module: string = '';
  method: string = '';
}

/** 一个通用请求体：req_0 的 param 用具体参数类（不同接口字段不同） */
class TxEnvelope {
  comm: TxComm;
  req_0: TxReq;

  constructor(comm: TxComm, req: TxReq) {
    this.comm = comm;
    this.req_0 = req;
  }
}

/** 带参请求（param 单独挂，避免给每种参数都写一个信封类） */
class TxRadarBody {
  comm: TxComm;
  req_0: TxRadarReq;

  constructor(comm: TxComm, req: TxRadarReq) {
    this.comm = comm;
    this.req_0 = req;
  }
}

class TxRadarReq {
  module: string = 'music.recommend.TrackRelationServer';
  method: string = 'GetRadarSong';
  param: TxRadarParam = new TxRadarParam();
}

class TxGuessReq {
  module: string = 'music.radioProxy.MbTrackRadioSvr';
  method: string = 'get_radio_track';
  param: TxGuessParam = new TxGuessParam();
}

class TxGuessBody {
  comm: TxComm;
  req_0: TxGuessReq;

  constructor(comm: TxComm, req: TxGuessReq) {
    this.comm = comm;
    this.req_0 = req;
  }
}

/** 每日推荐 feed 参数（字段照 QQ 官网推荐页：direction 0 = 下拉首屏） */
class TxDailyParam {
  direction: number = 0;
  page: number = 1;
  v_cache: number[] = [];
  v_uniq: string[] = [];
  s_num: number = 0;
}

class TxDailyReq {
  module: string = 'music.recommend.RecommendFeed';
  method: string = 'get_recommend_feed';
  param: TxDailyParam = new TxDailyParam();
}

class TxDailyBody {
  comm: TxComm;
  req_0: TxDailyReq;

  constructor(comm: TxComm, req: TxDailyReq) {
    this.comm = comm;
    this.req_0 = req;
  }
}

/**
 * 每日推荐歌单（CgiGetDiss）参数
 *
 * `dirid` 用 0（按 disstid 取），`tag` / `userinfo` / `orderlist` 照官网歌单详情带全：
 * 每日 30 首是**账号私有**的动态歌单，少带一个标记可能只回歌单外壳、`songlist` 为空。
 */
class TxDissParam {
  disstid: number = 0;
  dirid: number = 0;
  tag: boolean = true;
  song_begin: number = 0;
  song_num: number = DAILY_SONG_NUM;
  userinfo: boolean = true;
  orderlist: boolean = true;
}

class TxDissReq {
  module: string = 'music.srfDissInfo.DissInfo';
  method: string = 'CgiGetDiss';
  param: TxDissParam = new TxDissParam();
}

class TxDissBody {
  comm: TxComm;
  req_0: TxDissReq;

  constructor(comm: TxComm, req: TxDissReq) {
    this.comm = comm;
    this.req_0 = req;
  }
}

/** 当前账号的 comm：登录了就把 uin / authst 换成真实账号，否则保持匿名 */
function buildComm(): TxComm {
  const comm: TxComm = new TxComm();
  const cookie: string = musicAccount().cookieOf('tx');
  if (cookie.length === 0) {
    comm.uin = '0';
    comm.authst = '';
    return comm;
  }
  const uin: string = txUinOf(cookie);
  const key: string = txMusicKeyOf(cookie);
  comm.uin = uin.length > 0 ? uin : '0';
  comm.authst = key;
  return comm;
}

function txHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    'User-Agent': TX_UA,
    'Referer': 'https://y.qq.com/',
  };
  const cookie: string = musicAccount().cookieOf('tx');
  if (cookie.length > 0) {
    headers['Cookie'] = cookie;
  }
  return headers;
}

/** 接口是否真的给了这一块（外层 code 与业务块 code 都要是 0） */
function blockOf(resp: Record<string, Object>): Record<string, Object> | null {
  const outer: number = asNumber(resp['code']);
  const req: Record<string, Object> = asRecord(resp['req_0']);
  const inner: number = asNumber(req['code']);
  if (outer !== 0 || inner !== 0) {
    hilog.warn(DOMAIN, TAG, 'tx recommend code outer=%{public}d inner=%{public}d', outer, inner);
    return null;
  }
  return asRecord(req['data']);
}

/** 登录态（私人推荐要有账号才有意义；未登录也能调，但会退回大众口味） */
export function isTxLoggedIn(): boolean {
  return musicAccount().isLoggedIn('tx');
}

/**
 * 私人雷达
 *
 * 从第 1 页翻到第 4 页，按 mid 去重（实测相邻页首曲会重复），返回去重后的曲目。
 * 每页失败不影响其它页：能拿多少算多少。
 */
export async function fetchTxRadar(): Promise<LxMusicInfo[]> {
  const seen: Set<string> = new Set<string>();
  const tracks: Object[] = [];
  for (let page = 1; page <= RADAR_MAX_PAGE; page++) {
    const req: TxRadarReq = new TxRadarReq();
    req.param.Page = page;
    const body: TxRadarBody = new TxRadarBody(buildComm(), req);
    try {
      const resp: Record<string, Object> = await httpPostJson(GATEWAY, body, txHeaders(),
        `QQ音乐私人雷达(第${page}页)`);
      const data: Record<string, Object> | null = blockOf(resp);
      if (data === null) {
        continue;
      }
      const vec: Object[] = asObjectArray(data['VecSongs']);
      let added: number = 0;
      for (let i = 0; i < vec.length; i++) {
        // 实测形状：每一项是 { Track: {...} }（不是扁平的 Track）
        const track: Record<string, Object> = asRecord(asRecord(vec[i])['Track']);
        const mid: string = asString(track['mid']);
        if (mid.length === 0 || seen.has(mid)) {
          continue;
        }
        seen.add(mid);
        tracks.push(track);
        added += 1;
      }
      hilog.info(DOMAIN, TAG, 'radar page %{public}d: %{public}d 首，新增 %{public}d 首，hasMore=%{public}s',
        page, vec.length, added, String(data['HasMore']));
      // 没有更多就别再翻了（匿名时也可能一直 true，靠去重兜住）
      if (asObjectArray(data['VecSongs']).length === 0) {
        break;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'radar page %{public}d failed: %{public}s', page, (e as Error).message);
    }
  }
  return parseTxSongs(tracks);
}

/**
 * 猜你喜欢
 *
 * 一次只回几首（实测 3 首左右），所以翻 `GUESS_MAX_PAGE` 页按 mid 去重凑成一行：
 * Page 变大后重复会变多，一整页都是旧歌就提前收工，不再白发请求。
 */
export async function fetchTxGuess(): Promise<LxMusicInfo[]> {
  const seen: Set<string> = new Set<string>();
  const tracks: Object[] = [];
  for (let page = 1; page <= GUESS_MAX_PAGE; page++) {
    const req: TxGuessReq = new TxGuessReq();
    req.param.Page = page;
    const body: TxGuessBody = new TxGuessBody(buildComm(), req);
    try {
      const resp: Record<string, Object> = await httpPostJson(GATEWAY, body, txHeaders(),
        `QQ音乐猜你喜欢(第${page}页)`);
      const data: Record<string, Object> | null = blockOf(resp);
      if (data === null) {
        continue;
      }
      const list: Object[] = asObjectArray(data['tracks']);
      let added: number = 0;
      for (const raw of list) {
        // 这一条是**扁平** Track（不是雷达那种 { Track: {...} }）
        const track: Record<string, Object> = asRecord(raw);
        const mid: string = asString(track['mid']);
        if (mid.length === 0 || seen.has(mid)) {
          continue;
        }
        seen.add(mid);
        tracks.push(track);
        added += 1;
      }
      hilog.info(DOMAIN, TAG, 'guess page %{public}d: %{public}d 首，新增 %{public}d 首',
        page, list.length, added);
      if (added === 0) {
        break;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'guess page %{public}d failed: %{public}s', page, (e as Error).message);
    }
  }
  const songs: LxMusicInfo[] = parseTxSongs(tracks);
  hilog.info(DOMAIN, TAG, 'guess: %{public}d 首', songs.length);
  return songs;
}

// ------------------------------------------------------------ 每日推荐

/** 上海时区「哪一天」（每日推荐按上海当天算，跨日就要换一批，见 isTodayShanghai） */
function shanghaiDayOf(ms: number): string {
  return new Date(ms + 8 * 3600 * 1000).toISOString().substring(0, 10);
}

/**
 * 卡片的 `time` 是不是「今天」（上海）
 *
 * QQ 的每日推荐是**按天**下发的动态歌单：卡片时间不是今天，说明拿到的是昨天/缓存的
 * 那一批，不能再当「今日推荐」显示。接口没给时间（0）就不拦 —— 宁可多显示一块，
 * 也别因为一个可选字段整块消失。
 */
function isTodayShanghai(stamp: number): boolean {
  if (stamp <= 0) {
    return true;
  }
  const ms: number = stamp > 100000000000 ? stamp : stamp * 1000;
  return shanghaiDayOf(ms) === shanghaiDayOf(Date.now());
}

/** 卡片上的歌单 id（不同卡片把 id 放在不同字段里，都是纯数字串） */
function cardIdOf(card: Record<string, Object>): string {
  const keys: string[] = ['id', 'tid', 'disstid', 'dissid', 'playlist_id'];
  for (const key of keys) {
    const digits: string = asString(card[key]).replace(/[^0-9]/g, '');
    // 动态歌单 id 是长数字；太短的多半是 type / 位置编号，不能当 disstid
    if (digits.length >= 6) {
      return digits;
    }
  }
  return '';
}

/** 把一个容器上的 v_card 收进 cards（容器不存在时 asObjectArray 给空数组，不报错） */
function pushCards(container: Record<string, Object>, cards: Object[]): void {
  const list: Object[] = asObjectArray(container['v_card']);
  for (const card of list) {
    cards.push(card);
  }
}

/**
 * 推荐 feed 里的卡片摊平
 *
 * **实测（2026-11-23 匿名请求 musicu.fcg）**：卡片不在 `data.v_shelf[].v_card` 上，而是在
 * `data.v_shelf[].v_niche[].v_card[]`（shelf 是「板块」，niche 是板块里的一格，卡片在格子里）。
 * 匿名时每个 shelf 的 niche 只有 1 张 `type=500` 的歌单卡（`id` 就是 disstid、`time` 是歌单
 * 创建时间），每日推荐那张 `subtype=510` 的卡只有登录后才会出现。
 * 老版本 / 其它入口也见过 `v_card` 直接挂在 shelf 或 data 上，所以这几层都收一遍。
 */
function dailyCardsOf(data: Record<string, Object>): Object[] {
  const cards: Object[] = [];
  pushCards(data, cards);
  const shelves: Object[] = asObjectArray(data['v_shelf']);
  for (const shelf of shelves) {
    const record: Record<string, Object> = asRecord(shelf);
    pushCards(record, cards);
    const niches: Object[] = asObjectArray(record['v_niche']);
    for (const niche of niches) {
      pushCards(asRecord(niche), cards);
    }
  }
  const list: Object[] = asObjectArray(data['list']);
  for (const item of list) {
    pushCards(asRecord(item), cards);
  }
  return cards;
}

/**
 * 从推荐 feed 里挑出「每日推荐」那张卡片（找不到给 null）
 *
 * 只认 `subtype / type = 510` 的卡片：其它卡片是普通歌单（`type=500`，`id` 是歌单 id、
 * `title` 是运营取的歌单名），按标题找「每日」会挑错成别人的歌单，所以不做标题兜底。
 * `time` 是今天（上海）的优先；时间对不上的 510 卡留着兜底 —— 字段口径若变，
 * 至少还能把日推显示出来，而不是整块消失。
 */
function findDailyCard(data: Record<string, Object>): Record<string, Object> | null {
  const cards: Object[] = dailyCardsOf(data);
  let fallback: Record<string, Object> | null = null;
  for (const raw of cards) {
    const card: Record<string, Object> = asRecord(raw);
    if (asNumber(card['subtype']) !== DAILY_SUBTYPE && asNumber(card['type']) !== DAILY_SUBTYPE) {
      continue;
    }
    if (cardIdOf(card).length === 0) {
      continue;
    }
    if (isTodayShanghai(asNumber(card['time']))) {
      return card;
    }
    if (fallback === null) {
      fallback = card;
    }
  }
  return fallback;
}

/**
 * 每日推荐（每日 30 首）
 *
 * 两跳：推荐 feed 拿当天动态歌单 id → `CgiGetDiss` 读那 30 首完整曲目。
 * **必须登录**：未登录时 feed 只回普通歌单卡（没有 subtype 510），
 * 所以找不到卡片时直接抛错，让界面把这一块标成「取不到」，不静默显示空块。
 * 歌单详情取不到时还有一层兜底：卡片自带的 `card_extra_info.SongList / Tracks`
 * 若本来就是完整 Track（带 file.media_mid），照样能播，不至于整块空掉。
 */
export async function fetchTxDaily(): Promise<LxMusicInfo[]> {
  const feedReq: TxDailyReq = new TxDailyReq();
  const feedBody: TxDailyBody = new TxDailyBody(buildComm(), feedReq);
  const feedResp: Record<string, Object> =
    await httpPostJson(GATEWAY, feedBody, txHeaders(), 'QQ音乐每日推荐');
  const feedData: Record<string, Object> | null = blockOf(feedResp);
  if (feedData === null) {
    throw new Error('QQ 音乐每日推荐接口返回异常');
  }
  const card: Record<string, Object> | null = findDailyCard(feedData);
  if (card === null) {
    throw new Error('QQ 音乐每日推荐里没找到今日歌单（登录可能已过期）');
  }
  const dissId: string = cardIdOf(card);
  const dissReq: TxDissReq = new TxDissReq();
  dissReq.param.disstid = asNumber(dissId);
  const dissBody: TxDissBody = new TxDissBody(buildComm(), dissReq);
  const resp: Record<string, Object> =
    await httpPostJson(GATEWAY, dissBody, txHeaders(), 'QQ音乐每日推荐歌单');
  const data: Record<string, Object> | null = blockOf(resp);
  if (data !== null) {
    const songs: LxMusicInfo[] = parseTxSongs(asObjectArray(data['songlist']));
    if (songs.length > 0) {
      hilog.info(DOMAIN, TAG, 'daily: disstid=%{public}s, %{public}d 首', dissId, songs.length);
      return songs;
    }
  }
  // 兜底：卡片自己带的曲目（有的版本 510 卡直接把 30 首塞在 card_extra_info 里）
  const extra: Record<string, Object> = asRecord(card['card_extra_info']);
  const inline: Object[] = [];
  for (const raw of asObjectArray(extra['SongList'])) {
    inline.push(raw);
  }
  for (const raw of asObjectArray(extra['Tracks'])) {
    inline.push(raw);
  }
  const fallbackSongs: LxMusicInfo[] = parseTxSongs(inline);
  hilog.info(DOMAIN, TAG, 'daily fallback: disstid=%{public}s, %{public}d 首',
    dissId, fallbackSongs.length);
  return fallbackSongs;
}
