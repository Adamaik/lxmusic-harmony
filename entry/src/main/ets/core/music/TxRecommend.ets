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
 *
 * 解析复用 MusicSearch.parseTxSongs（与搜索同一条映射，字段口径不会分叉）。
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

/** 猜你喜欢（一次只有几首，适合当「换一批」的补充，不单独成页） */
export async function fetchTxGuess(): Promise<LxMusicInfo[]> {
  const req: TxGuessReq = new TxGuessReq();
  req.param.Page = 1;
  const body: TxGuessBody = new TxGuessBody(buildComm(), req);
  try {
    const resp: Record<string, Object> = await httpPostJson(GATEWAY, body, txHeaders(), 'QQ音乐猜你喜欢');
    const data: Record<string, Object> | null = blockOf(resp);
    if (data === null) {
      return [];
    }
    const list: LxMusicInfo[] = parseTxSongs(asObjectArray(data['tracks']));
    hilog.info(DOMAIN, TAG, 'guess: %{public}d 首', list.length);
    return list;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'guess failed: %{public}s', (e as Error).message);
    return [];
  }
}
