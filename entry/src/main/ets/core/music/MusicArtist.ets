import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
import { asNumber, asObjectArray, asRecord, asString } from './PlatformHttp';
import { md5Hex } from './LxCrypto';
import { LxMusicInfo, LxQualityItem, LxSearchPage, SINGER_SEPARATORS, appendWyExtendQualities,
  formatPlayTime, mgImageUrl, sizeFormate } from './MusicSearch';

/**
 * 内置歌手接口（宿主侧）—— 「按歌手聚合」的那一半
 *
 * 移植自派音（RzdMusic，洛雪音乐的鸿蒙版）的 `features/player/src/main/ets/geuz/`：
 * 歌手搜索（`SearchDispatch` + 各平台 `searchSinger`）、歌手详情与歌手全部歌曲
 * （`DetailDispatch` + 各平台 `getArtistDetail/getArtistSongs`），
 * 以及歌手页 `ArtistDetailPage` 背后的那套数据。
 *
 * 为什么要有它：洛雪的搜索页只有「歌曲 / 歌单」两种（`src/config/constant.ts` 的
 * searchType = 'music' | 'songlist'），没有歌手这一维；「想看某个歌手的全部歌」
 * 只能拿歌手名当关键词搜歌，靠相似度把贴题的顶上来 —— 那既搜不全（一个平台一页
 * 30 条），也认不出「这条是不是这个人唱的」。派音补的正是这一块：按歌手聚合。
 *
 * 数据形状与 `MusicSearch.ets` 保持一致：歌手歌曲最终仍产出 `LxMusicInfo`，
 * 于是歌手页可以直接复用 `songFromSearch` + `SongListPane` + 播放链路，
 * 不必再造一套「歌手页专用的歌」。
 *
 * 平台可用性（2026-10 实测，五个平台都能通）：
 *   kw  搜索/歌曲走 www.kuwo.cn 的 www api（要 Hm_Iuvt_ token + Secret，见下），
 *       歌手简介与两个计数走免鉴权的 search.kuwo.cn/r.s
 *   kg  全部走 gateway.kugou.com，**必须算 md5 签名**（只带 key 参数会被回 20006）
 *   mg  走 app.c.nf.migu.cn 的 bmw 接口，只要 UA
 *   tx  走 musicu.fcg（不带签名的老入口即可，与 `MusicSearch` 里走 musics.fcg + zzcSign 的搜歌不同）
 *   wy  走 music.163.com 的老 api（/api/search/get/web 与 /api/v1/artist/...）——
 *       `MusicSearch` 里那条 eapi 链路（/api/search/song/list/page）确实已经 404，见该文件顶部说明
 */

/**
 * 参与歌手聚合的平台与顺序
 *
 * 与 `SEARCH_PLATFORMS`（酷我打头）保持同一顺序：跨平台去重时「先问的平台留下」，
 * 两个入口的顺序要是一致，用户从搜歌切到搜歌手才不会看到「同一个人换了平台」。
 */
export const ARTIST_PLATFORMS: string[] = ['kw', 'kg', 'mg', 'tx', 'wy'];

/** 歌手排序：「最热」还是「最新」（各平台接口的 sort 参数含义不一样，这里收口成一个词） */
export type LxArtistOrder = 'hot' | 'new';

/**
 * 「点歌手名」时要挑的一位候选
 *
 * 两处入口共用一个形状：一首歌可能挂着几位歌手（播放页那行「周杰伦、方文山」），
 * 回响那边则是整月听过的歌手列表（`note` 带「听了 N 首」）。
 */
export interface ArtistCandidate {
  /** 用来去哪个平台认人：歌的来源平台，或回响里这几位歌的来源 */
  source: string;
  name: string;
  /** 行尾那行小字的附加说明（'' = 不显示） */
  note: string;
  /**
   * 已知的歌手照片
   *
   * 手里有就给（省掉一次联网认人），没有就留空 —— 歌手列表页会自己按名字解析一张
   * （见 views/ArtistPickerView.ets）。
   */
  picUrl?: string;
}

/** 一个歌手（搜索结果 / 歌手页头部要显示的那几项） */
export interface LxArtist {
  /** 平台：kw / kg / mg / tx / wy */
  source: string;
  /** 该平台内的歌手 id（tx 用 singerMID，其余用数字 id） */
  id: string;
  /**
   * tx 的歌手详情接口只认 singerMID
   *
   * 其余平台留空 —— 与 `DetailDispatch` 里 `mid.length > 0 ? mid : id` 的写法一个意思：
   * 有 mid 就用 mid，没有就用 id。
   */
  mid: string;
  name: string;
  /** 别名（酷我的 AARTIST、网易的 alias[0]），没有就是空串 */
  alias: string;
  picUrl: string;
  songNum: number;
  albumSize: number;
}

/** 歌手页头部用的详情（简介 + 计数） */
export interface LxArtistDetail {
  name: string;
  picUrl: string;
  desc: string;
  songNum: number;
  albumSize: number;
}

/** 单平台一页歌手结果 */
export interface LxArtistPage {
  list: LxArtist[];
  /** 该平台报的命中总数；接口没给就是 0 */
  total: number;
  /** 总页数（永远 >= page） */
  allPage: number;
}

/** 单平台歌手搜索的结果（失败也返回，不抛，供聚合用） */
export interface LxArtistPlatformResult {
  source: string;
  items: LxArtist[];
  /** 空串 = 这个平台搜成功 */
  error: string;
  allPage: number;
  total: number;
}

/** 聚合歌手搜索一页的结果 */
export interface LxArtistOutcome {
  keyword: string;
  page: number;
  /** 逐平台一份（界面拿它做状态行 / 平台筛选） */
  platforms: LxArtistPlatformResult[];
  /** 聚合列表：按名字去过重（同一个人只留先问到的那个平台那份） */
  items: LxArtist[];
  /** 各平台里最大的总页数：> page 表示还能继续翻 */
  maxPage: number;
}

// ------------------------------------------------------------------ 公共小工具

/** 歌手的稳定标识（列表 key / 进歌手页时带过去的身份） */
export function artistKeyOf(artist: LxArtist): string {
  return `${artist.source}_${artist.id}`;
}

/**
 * 歌手名的归一化键（跨平台去重）
 *
 * 同一个人在不同平台的写法会差一点：网易给「周杰伦」，酷我给「周杰伦」，
 * 但别名、全角空格、书名号（「G.E.M.邓紫棋」对「邓紫棋」）都会变。
 * 这里只做「大小写一致 + 去掉空白与常见连接符」，**不做**别名归并 ——
 * 把「G.E.M.邓紫棋」并到「邓紫棋」需要一张别名表，拍脑袋并错比不并更糟
 * （搜出来的人和点进去看到的人对不上）。
 */
export function artistNameKey(name: string): string {
  let out: string = '';
  for (let i = 0; i < name.length; i++) {
    const ch: string = name.charAt(i);
    if (ch === ' ' || ch === '\u3000' || ch === '\t' || ch === '·' || ch === '-' || ch === '_') {
      continue;
    }
    out += ch.toLowerCase();
  }
  return out;
}

/**
 * 按总数算总页数；总数拿不到就按「这一页满没满」推。
 *
 * 与 `MusicSearch.pagesOf` 同一套规则（那边是模块私有的，这里照抄一份；
 * 两处的语义必须一致，否则同一个平台的歌与歌手会一个能翻、一个不能）。
 */
function artistPagesOf(total: number, page: number, got: number, limit: number): number {
  if (got === 0 && page > 1) {
    return page;
  }
  if (total > 0) {
    const pages: number = Math.ceil(total / limit);
    return pages > page ? pages : page;
  }
  return got >= limit ? page + 1 : page;
}

function artistPageOf(list: LxArtist[], total: number, page: number, limit: number): LxArtistPage {
  return { list: list, total: total, allPage: artistPagesOf(total, page, list.length, limit) };
}

function songPageOf(list: LxMusicInfo[], total: number, page: number, limit: number): LxSearchPage {
  return { list: list, total: total, allPage: artistPagesOf(total, page, list.length, limit), limit: limit };
}

/** 拼一个 LxMusicInfo（字段语义与 `MusicSearch.createInfo` 完全一致） */
function buildSong(
  name: string,
  singer: string,
  source: string,
  songmid: string,
  albumName: string,
  albumId: string,
  seconds: number,
  img: string,
  hash: string,
  types: LxQualityItem[],
  qualityMap: Record<string, LxQualityItem>,
): LxMusicInfo {
  const info: LxMusicInfo = {
    name: name,
    singer: singer,
    source: source,
    songmid: songmid,
    albumName: albumName,
    albumId: albumId,
    interval: formatPlayTime(seconds),
    img: img,
    types: types,
    _types: qualityMap,
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
  // hash 为空表示该平台没有 hash，不能写成空串，否则源脚本的 `hash ?? songmid` 不会回退
  if (hash.length > 0) {
    info.hash = hash;
  }
  return info;
}

/** 加一档音质（size 为 0 的不加：界面上「0 B 的 FLAC」没有意义） */
function addArtistQuality(
  types: LxQualityItem[],
  map: Record<string, LxQualityItem>,
  quality: string,
  size: number,
  hash: string,
): void {
  if (size <= 0) {
    return;
  }
  const item: LxQualityItem = { type: quality, size: sizeFormate(size) };
  if (hash.length > 0) {
    item.hash = hash;
  }
  types.push(item);
  map[quality] = item;
}

function httpGet(url: string, headers: Record<string, string>, what: string,
  rawText: boolean = false): Promise<LxResponse> {
  return new Promise<LxResponse>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: 15000, headers: headers, rawText: rawText };
    lxRequest(url, options, (resp: LxResponse) => {
      resolve(resp);
    }, (message: string) => {
      reject(new Error(`${what}请求失败：${message}`));
    });
  });
}

function httpPost(url: string, body: string, headers: Record<string, string>,
  what: string): Promise<LxResponse> {
  return new Promise<LxResponse>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, body: body };
    lxRequest(url, options, (resp: LxResponse) => {
      resolve(resp);
    }, (message: string) => {
      reject(new Error(`${what}请求失败：${message}`));
    });
  });
}

/** 响应体 -> Record（HTTP 层多半已经解析过，这里再兜一层） */
function bodyRecord(resp: LxResponse, what: string): Record<string, Object> {
  const body = resp.body;
  if (body !== null && typeof body === 'object' && !Array.isArray(body)) {
    return body as Record<string, Object>;
  }
  if (typeof body === 'string') {
    try {
      const parsed: Object = JSON.parse(body) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      // fallthrough
    }
  }
  throw new Error(`${what}接口返回格式异常（HTTP ${resp.statusCode}）`);
}

/** 读响应头（大小写不敏感：鸿蒙给的键名不保证与请求时一致） */
function headerOf(headers: Record<string, string>, name: string): string {
  const keys: string[] = Object.keys(headers);
  const lower: string = name.toLowerCase();
  for (const key of keys) {
    if (key.toLowerCase() === lower) {
      return headers[key];
    }
  }
  return '';
}

// ================================================================== 酷我 kw

const KW_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.77 Safari/537.36';

interface KwToken {
  name: string;
  value: string;
  ts: number;
}

let kwTokenCache: KwToken | null = null;
let kwTokenTask: Promise<KwToken> | null = null;

/**
 * 酷我 www api 的 Secret 头：从 token 名与值算出来的一串 hex
 *
 * 照抄派音 `geuz/service/KwRequest.ets` 的 `signSecret`（更早的出处是酷我网页端的
 * `kw_sc` 混淆代码）。里面那步 `Math.random()` 不是随手加的 —— 算法把随机数掺进
 * 了迭代初值，所以**同一个 token 每次算出来的 Secret 都不一样**，但服务端都认。
 * 别「优化」成缓存结果。
 */
function kwSignSecret(value: string, name: string): string {
  let n: string = '';
  for (let i = 0; i < name.length; i++) {
    n = n + name.charCodeAt(i).toString();
  }
  const r: number = Math.floor(n.length / 5);
  const o: number = parseInt(n.charAt(r) + n.charAt(2 * r) + n.charAt(3 * r) + n.charAt(4 * r) + n.charAt(5 * r));
  const l: number = Math.ceil(name.length / 2);
  const c: number = Math.pow(2, 31) - 1;
  const d: number = Math.round(1e9 * Math.random()) % 1e8;
  n = n + d.toString();
  while (n.length > 10) {
    n = (parseInt(n.substring(0, 10)) + parseInt(n.substring(10, n.length))).toString();
  }
  let nn: number = (o * parseInt(n) + l) % c;
  let out: string = '';
  for (let i = 0; i < value.length; i++) {
    const hh: number = value.charCodeAt(i) ^ Math.floor((nn / c) * 255);
    out = out + (hh < 16 ? '0' + hh.toString(16) : hh.toString(16));
    nn = (o * nn + l) % c;
  }
  let ds: string = d.toString(16);
  while (ds.length < 8) {
    ds = '0' + ds;
  }
  return out + ds;
}

/** 从 Set-Cookie 里抠出 `Hm_Iuvt_xxxx=yyyy`（酷我 www api 的鉴权票据） */
function kwTokenFromCookies(cookieStr: string): KwToken | null {
  const match: RegExpMatchArray | null = cookieStr.match(/(Hm_Iuvt_[a-z0-9]+)=([^;]+)/);
  if (match === null || match.length < 3) {
    return null;
  }
  return { name: match[1], value: match[2], ts: Date.now() };
}

/**
 * 取酷我 token
 *
 * www api 不带它一律 403（不是限流，是根本没有入口），而它只挂在首页的 Set-Cookie 上，
 * 所以得先访问一次首页。两个入口都试：首页与搜索页 —— 派音也是这么干的（首页偶尔
 * 只回 30x 不带 cookie）。
 */
async function fetchKwToken(): Promise<KwToken> {
  const entries: string[] = ['https://www.kuwo.cn/', 'https://www.kuwo.cn/search/list?key=1'];
  for (const entry of entries) {
    const resp: LxResponse = await httpGet(entry, { 'User-Agent': KW_UA }, '酷我', true);
    const fromHeader: string = headerOf(resp.headers, 'set-cookie');
    let token: KwToken | null = kwTokenFromCookies(fromHeader);
    if (token === null) {
      // 头里可能只剩最后一条，或整个头没透出来：再把 body 也扫一遍（有些网关把 cookie 塞在 30x 页里）
      const text: string = typeof resp.body === 'string' ? resp.body as string : '';
      token = kwTokenFromCookies(text);
    }
    if (token !== null) {
      return token;
    }
  }
  throw new Error('酷我 token 取不到（首页没有回 Set-Cookie）');
}

/** token 缓存 1 小时，并发时只发一次请求（与派音 `ensureToken` 一致） */
async function ensureKwToken(): Promise<KwToken> {
  if (kwTokenCache !== null && Date.now() - kwTokenCache.ts < 3600000) {
    return kwTokenCache;
  }
  if (kwTokenTask !== null) {
    return kwTokenTask;
  }
  kwTokenTask = fetchKwToken();
  try {
    const token: KwToken = await kwTokenTask;
    kwTokenCache = token;
    return token;
  } finally {
    kwTokenTask = null;
  }
}

/** 带 token + Secret 请求一次酷我 www api */
async function kwRequestOnce(url: string, referer: string, token: KwToken): Promise<Record<string, Object>> {
  const reqId: string = String(Date.now()) + Math.random().toString(16).slice(2);
  const headers: Record<string, string> = {
    'cookie': token.name + '=' + token.value,
    'Secret': kwSignSecret(token.value, token.name),
    'Referer': referer,
    'User-Agent': KW_UA,
  };
  const resp: LxResponse = await httpGet(`${url}&reqId=${reqId}`, headers, '酷我');
  return bodyRecord(resp, '酷我');
}

/** token 失效（success=false / message 带 illegal）时换一个再试一次 —— 与派音 `kwGet` 一致 */
async function kwGet(url: string, referer: string = 'https://www.kuwo.cn/'): Promise<Record<string, Object>> {
  const token: KwToken = await ensureKwToken();
  let body: Record<string, Object> = await kwRequestOnce(url, referer, token);
  const success: Object | undefined = body['success'];
  const message: string = asString(body['message']);
  if (success === false || message.indexOf('illegal') >= 0) {
    kwTokenCache = null;
    const fresh: KwToken = await ensureKwToken();
    body = await kwRequestOnce(url, referer, fresh);
  }
  return body;
}

function kwArtistPic(pic: string): string {
  // 240 是列表用的缩略图，1080 是详情页要的大图（同一张图的两种尺寸）
  return pic.replace('/starheads/240/', '/starheads/1080/').replace('http://', 'https://');
}

async function searchArtistKw(keyword: string, page: number, limit: number): Promise<LxArtistPage> {
  const url: string = 'https://www.kuwo.cn/api/www/search/searchArtistBykeyWord' +
    `?key=${encodeURIComponent(keyword)}&pn=${page}&rn=${limit}&httpsStatus=1`;
  const body: Record<string, Object> = await kwGet(url);
  if (asNumber(body['code']) !== 200) {
    throw new Error(`酷我歌手搜索返回 code ${asNumber(body['code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const rawList: Object[] = asObjectArray(data['list']);
  const list: LxArtist[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['id']);
    if (id.length === 0) {
      continue;
    }
    list.push({
      source: 'kw',
      id: id,
      mid: '',
      name: asString(item['name']),
      alias: asString(item['aartist']),
      picUrl: kwArtistPic(asString(item['pic'])),
      songNum: asNumber(item['musicNum']),
      albumSize: 0,
    });
  }
  return artistPageOf(list, asNumber(data['total']), page, limit);
}

/**
 * 酷我歌手简介与两个计数
 *
 * 走免鉴权的 `search.kuwo.cn/r.s?ft=artist`：那一条响应里 desc / SONGNUM / ALBUMNUM
 * 都有，一次请求就够 —— 不必像派音那样再拿 www api 问两遍计数（那两遍还要 token）。
 * 注意这个接口回的是**单引号 JSON**，得先转一道（`kwToStandardJson`）。
 */
function kwToStandardJson(text: string): string {
  let out: string = '';
  let i: number = 0;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '\\' && i + 1 < text.length && text.charAt(i + 1) === '\'') {
      out = out + '"';
      i = i + 2;
      continue;
    }
    out = out + (ch === '\'' ? '"' : ch);
    i = i + 1;
  }
  return out;
}

async function kwArtistInfo(artistId: string): Promise<Record<string, Object>> {
  const url: string = 'http://search.kuwo.cn/r.s?ft=artist' +
    `&artistid=${encodeURIComponent(artistId)}&pn=0&rn=1&rformat=json&encoding=utf8` +
    '&vipver=MUSIC_8.7.7.0_BCS37&plat=pc&devid=28156413&pay=0&needliveshow=0';
  const resp: LxResponse = await httpGet(url, { 'User-Agent': KW_UA }, '酷我歌手信息', true);
  const text: string = typeof resp.body === 'string' ? resp.body as string : JSON.stringify(resp.body);
  const parsed: Record<string, Object> = JSON.parse(kwToStandardJson(text)) as Record<string, Object>;
  const list: Object[] = asObjectArray(parsed['abslist']);
  return list.length > 0 ? asRecord(list[0]) : {};
}

async function artistDetailKw(artist: LxArtist): Promise<LxArtistDetail> {
  let desc: string = '';
  let songNum: number = artist.songNum;
  let albumSize: number = 0;
  try {
    const info: Record<string, Object> = await kwArtistInfo(artist.id);
    desc = asString(info['desc']).split('&nbsp;').join(' ').split('<br>').join('\n');
    const songs: number = asNumber(info['SONGNUM']);
    if (songs > 0) {
      songNum = songs;
    }
    albumSize = asNumber(info['ALBUMNUM']);
  } catch (e) {
    // 简介是「有则更好」的一项：取不到就只显示名字与头像，不该让整页失败
  }
  return { name: artist.name, picUrl: artist.picUrl, desc: desc, songNum: songNum, albumSize: albumSize };
}

/**
 * 酷我歌手全部歌曲
 *
 * 用 www api 的 artistMusic（实测「周杰伦」报名 1708 首），而不是
 * `search.kuwo.cn/r.s?ft=music&artistid=` —— 后者是酷我自己的老索引，
 * 同一个人只回 26 首，拿来当「全部歌曲」名不副实。
 *
 * 代价：这条响应里没有 MINFO，所以 types 是空的，播放音质直接沿用设置里那一档
 * （`Quality.pickQuality` 在 `available` 为空时返回 fallback，本来就容许这种歌）。
 */
async function artistSongsKw(artist: LxArtist, page: number, limit: number): Promise<LxSearchPage> {
  const url: string = 'https://www.kuwo.cn/api/www/artist/artistMusic' +
    `?artistid=${encodeURIComponent(artist.id)}&pn=${page}&rn=${limit}&httpsStatus=1`;
  const referer: string = `https://www.kuwo.cn/singer_detail/${encodeURIComponent(artist.id)}`;
  const body: Record<string, Object> = await kwGet(url, referer);
  if (asNumber(body['code']) !== 200) {
    throw new Error(`酷我歌手歌曲返回 code ${asNumber(body['code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const rawList: Object[] = asObjectArray(data['list']);
  const list: LxMusicInfo[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    // musicrid 是 'MUSIC_228908' 这种形式，与搜歌时 songmid 的口径一致（去掉前缀的数字）
    const rid: string = asString(item['rid']).length > 0
      ? asString(item['rid'])
      : asString(item['musicrid']).split('MUSIC_').join('');
    if (rid.length === 0) {
      continue;
    }
    const img: string = asString(item['pic']).replace('http://', 'https://');
    list.push(buildSong(
      asString(item['name']),
      asString(item['artist']).split('&').join('、'),
      'kw',
      rid,
      asString(item['album']),
      asString(item['albumid']),
      asNumber(item['duration']),
      img.length > 0 ? img : asString(item['albumpic']).replace('http://', 'https://'),
      '',
      [],
      {},
    ));
  }
  return songPageOf(list, asNumber(data['total']), page, limit);
}

// ================================================================== 酷狗 kg

/**
 * 酷狗 gateway 的固定参数
 *
 * 与 `MusicList.ets` 里那条 `key = KG_GATEWAY_KEY` 的走法**不是**一回事：
 * 那些走 kmr.service 的接口认 key 参数，而歌手这几个（complexsearch / openapi）
 * 必须算 md5 签名 —— 只带 key 会被回 `status:0, error_code:20006`（实测）。
 * 所以这里有自己的一套常量与签名函数，照抄派音 `geuz/service/KgGateway.ets`。
 */
const KG_GATEWAY_SALT: string = 'OIlwieks28dk2k092lksi2UIkp';
const KG_GATEWAY_APPID: number = 1005;
const KG_GATEWAY_CLIENTVER: number = 20489;
const KG_GATEWAY_MID: string = '150330140572226157714874292511398898608';
const KG_GATEWAY_UA: string = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';
const KG_GATEWAY_RF: string = 'B9EDA08A64250DEFFBCADDEE00F8F25F';

/**
 * 酷狗 gateway 请求
 *
 * 签名 = md5(salt + 排序后的 "k=v" 串 + body + salt)，其中对象值按 JSON 串参与拼接
 * （`paramValueToString`）。键必须**排序**后拼接，否则签名对不上。
 *
 * @param method GET / POST
 * @param path   gateway 上的路径（x-router 决定它落到哪个服务）
 */
async function kgGateway(
  method: string,
  path: string,
  body: Record<string, Object> | null,
  extraParams: Record<string, Object>,
  extraHeaders: Record<string, string>,
  what: string,
): Promise<Record<string, Object>> {
  const clienttime: string = String(Math.floor(Date.now() / 1000));
  const params: Record<string, Object> = {
    'dfid': '-',
    'mid': KG_GATEWAY_MID,
    'uuid': '-',
    'appid': KG_GATEWAY_APPID,
    'clientver': KG_GATEWAY_CLIENTVER,
    'clienttime': clienttime,
  };
  for (const key of Object.keys(extraParams)) {
    params[key] = extraParams[key];
  }
  let joined: string = '';
  const sorted: string[] = Object.keys(params).sort();
  for (const key of sorted) {
    const value: Object = params[key];
    joined += `${key}=${typeof value === 'object' ? JSON.stringify(value) : String(value)}`;
  }
  const dataStr: string = body !== null ? JSON.stringify(body) : '';
  params['signature'] = md5Hex(KG_GATEWAY_SALT + joined + dataStr + KG_GATEWAY_SALT);

  const headers: Record<string, string> = {
    'User-Agent': KG_GATEWAY_UA,
    'dfid': '-',
    'clienttime': clienttime,
    'mid': KG_GATEWAY_MID,
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': KG_GATEWAY_RF,
    'Content-Type': 'application/json',
  };
  for (const key of Object.keys(extraHeaders)) {
    headers[key] = extraHeaders[key];
  }

  const parts: string[] = [];
  for (const key of Object.keys(params)) {
    const value: Object = params[key];
    const text: string = typeof value === 'object' ? JSON.stringify(value) : String(value);
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(text)}`);
  }
  const url: string = `https://gateway.kugou.com${path}?${parts.join('&')}`;
  const resp: LxResponse = method === 'POST'
    ? await httpPost(url, dataStr, headers, what)
    : await httpGet(url, headers, what);
  return bodyRecord(resp, what);
}

async function searchArtistKg(keyword: string, page: number, limit: number): Promise<LxArtistPage> {
  const body: Record<string, Object> = await kgGateway('GET', '/v1/search/author', null, {
    'keyword': keyword,
    'page': page,
    'pagesize': limit,
    'platform': 'AndroidFilter',
  }, { 'x-router': 'complexsearch.kugou.com' }, '酷狗');
  if (asNumber(body['status']) !== 1 || asNumber(body['error_code']) !== 0) {
    throw new Error(`酷狗歌手搜索返回 error_code ${asNumber(body['error_code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const rawList: Object[] = asObjectArray(data['lists']);
  const list: LxArtist[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['AuthorId']);
    if (id.length === 0 || id === '0') {
      continue;
    }
    const pic: string = asString(item['Avatar'])
      .replace('/softhead/240/', '/softhead/1080/')
      .replace('http://', 'https://');
    list.push({
      source: 'kg',
      id: id,
      mid: '',
      name: asString(item['AuthorName']),
      alias: '',
      picUrl: pic,
      songNum: asNumber(item['AudioCount']),
      albumSize: asNumber(item['AlbumCount']),
    });
  }
  const total: number = asNumber(data['total']);
  return artistPageOf(list, total > 0 ? total : list.length, page, limit);
}

async function artistDetailKg(artist: LxArtist): Promise<LxArtistDetail> {
  const body: Record<string, Object> = await kgGateway('POST', '/kmr/v3/author',
    { 'author_id': artist.id }, {},
    { 'x-router': 'openapi.kugou.com', 'kg-tid': '36' }, '酷狗');
  if (asNumber(body['status']) !== 1 || asNumber(body['error_code']) !== 0) {
    throw new Error(`酷狗歌手信息返回 error_code ${asNumber(body['error_code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const avatar: string = asString(data['sizable_avatar'])
    .replace('{size}', '1080')
    .replace('http://', 'https://');
  // 长简介（long_intro[0].content）比短简介全；没有才退回 intro
  const longIntro: Object[] = asObjectArray(data['long_intro']);
  let desc: string = longIntro.length > 0 ? asString(asRecord(longIntro[0])['content']) : '';
  if (desc.length === 0) {
    desc = asString(data['intro']);
  }
  const songCount: number = asNumber(data['song_count']);
  return {
    name: asString(data['author_name']).length > 0 ? asString(data['author_name']) : artist.name,
    picUrl: avatar.length > 0 ? avatar : artist.picUrl,
    desc: desc,
    songNum: songCount > 0 ? songCount : artist.songNum,
    albumSize: asNumber(data['album_count']),
  };
}

/**
 * 酷狗歌手全部歌曲
 *
 * 走的 `/openapi/kmr/v2/audio_group/author` 每首歌带全了 audio_info：
 * 128k / 320k / flac / flac24bit 四档各自的 hash 与 filesize 都有，
 * 所以 types 能按搜歌那套口径补齐（听歌时该给哪一档就哪一档）。
 */
async function artistSongsKg(artist: LxArtist, order: LxArtistOrder, page: number,
  limit: number): Promise<LxSearchPage> {
  const body: Record<string, Object> = await kgGateway('GET', '/openapi/kmr/v2/audio_group/author', null, {
    'author_id': artist.id,
    'area_code': 'all',
    // 1 = 最热，2 = 最新（酷狗这边的口径）
    'sort': order === 'hot' ? 1 : 2,
    'page': page,
    'pagesize': limit,
    'replace_api_version': 1,
    'mvdata_need': 1,
    'show_audio_honor': 1,
    'show_audio_tag': 1,
    'replace_need': 1,
  }, { 'kg-tid': '36' }, '酷狗');
  if (asNumber(body['status']) !== 1 || asNumber(body['error_code']) !== 0) {
    throw new Error(`酷狗歌手歌曲返回 error_code ${asNumber(body['error_code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const rawList: Object[] = asObjectArray(data['songs']);
  const list: LxMusicInfo[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const audio: Record<string, Object> = asRecord(item['audio_info']);
    const hash: string = asString(audio['hash']);
    if (hash.length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    addArtistQuality(types, map, '128k', asNumber(audio['filesize']), hash);
    addArtistQuality(types, map, '320k', asNumber(audio['filesize_320']), asString(audio['hash_320']));
    addArtistQuality(types, map, 'flac', asNumber(audio['filesize_flac']), asString(audio['hash_flac']));
    addArtistQuality(types, map, 'flac24bit', asNumber(audio['filesize_high']), asString(audio['hash_high']));
    types.reverse();

    const album: Record<string, Object> = asRecord(item['album_info']);
    const albumName: string = asString(item['album_name']).length > 0
      ? asString(item['album_name'])
      : asString(album['album_name']);
    const cover: string = asString(album['sizable_cover']).length > 0
      ? asString(album['sizable_cover'])
      : asString(album['cover']);
    let audioId: string = asString(item['audio_id']);
    if (audioId.length === 0) {
      audioId = asString(asRecord(item['base'])['audio_id']);
    }
    let author: string = asString(item['author_name']);
    if (author.length === 0) {
      author = asString(asRecord(item['base'])['author_name']);
    }
    // timelength 是毫秒；取不到再退回 seconds 口径的 duration
    let ms: number = asNumber(audio['timelength']);
    if (ms <= 0) {
      ms = asNumber(audio['duration']);
    }
    list.push(buildSong(
      asString(item['audio_name']),
      author,
      'kg',
      audioId.length > 0 ? audioId : hash,
      albumName,
      asString(item['album_id']),
      Math.floor(ms / 1000),
      cover.replace('{size}', '480').replace('http://', 'https://'),
      hash,
      types,
      map,
    ));
  }
  return songPageOf(list, asNumber(data['total']), page, limit);
}

// ================================================================== 咪咕 mg

const MG_UA: string =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ' +
  'Version/17.0 Mobile/15E148 Safari/604.1';

/** 咪咕的图片挑一张最大的（imgSizeType '03' 是原图，没有就退回最后一张） */
function mgFirstImg(imgs: Object[]): string {
  if (imgs.length === 0) {
    return '';
  }
  for (const raw of imgs) {
    const item: Record<string, Object> = asRecord(raw);
    if (asString(item['imgSizeType']) === '03') {
      return asString(item['img']);
    }
  }
  return asString(asRecord(imgs[imgs.length - 1])['img']);
}

function mgFormatQuality(formatType: string): string {
  if (formatType === 'PQ') {
    return '128k';
  }
  if (formatType === 'HQ') {
    return '320k';
  }
  if (formatType === 'SQ') {
    return 'flac';
  }
  if (formatType === 'ZQ24') {
    return 'flac24bit';
  }
  // AV3A 是咪咕自己的环绕声封装，本站放不了，不当成一档音质
  return '';
}

async function searchArtistMg(keyword: string, page: number, limit: number): Promise<LxArtistPage> {
  const url: string = 'https://app.c.nf.migu.cn/bmw/search/singer/v2.0' +
    `?pageNo=${page}&text=${encodeURIComponent(keyword)}`;
  const resp: LxResponse = await httpGet(url, { 'User-Agent': MG_UA }, '咪咕');
  const body: Record<string, Object> = bodyRecord(resp, '咪咕');
  if (asString(body['code']) !== '000000') {
    throw new Error('咪咕歌手搜索失败');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const rawList: Object[] = asObjectArray(data['items']);
  const list: LxArtist[] = [];
  for (const raw of rawList) {
    const singer: Record<string, Object> = asRecord(asRecord(raw)['singer']);
    const id: string = asString(singer['singerId']);
    if (id.length === 0) {
      continue;
    }
    list.push({
      source: 'mg',
      id: id,
      mid: '',
      name: asString(singer['singer']),
      alias: '',
      picUrl: mgFirstImg(asObjectArray(singer['imgs'])).replace('http://', 'https://'),
      songNum: asNumber(singer['songNum']),
      albumSize: asNumber(singer['albumNum']),
    });
  }
  // 咪咕只给「还有没有下一页」，不给总数：拿 hasNext 当总页数（和 `MusicSearch` 里搜歌同一处理）
  const hasNext: boolean = data['hasNext'] === true;
  return artistPageOf(list, 0, page, hasNext ? limit : list.length);
}

/** 在咪咕的内容块树里找某个 view 的第一层子块 */
function mgFindBlock(contents: Object[], view: string): Record<string, Object> {
  for (const raw of contents) {
    const block: Record<string, Object> = asRecord(raw);
    if (asString(block['view']) === view) {
      return block;
    }
  }
  return {};
}

function mapMgArtistSong(item: Record<string, Object>): LxMusicInfo | null {
  const songId: string = asString(item['songId']);
  const copyrightId: string = asString(item['copyrightId']);
  if (songId.length === 0) {
    return null;
  }
  const types: LxQualityItem[] = [];
  const map: Record<string, LxQualityItem> = {};
  for (const rawFormat of asObjectArray(item['audioFormats'])) {
    const format: Record<string, Object> = asRecord(rawFormat);
    const quality: string = mgFormatQuality(asString(format['formatType']));
    if (quality.length === 0 || map[quality] !== undefined) {
      continue;
    }
    let size: number = asNumber(format['asize']);
    if (size === 0) {
      size = asNumber(format['isize']);
    }
    addArtistQuality(types, map, quality, size, '');
  }
  types.reverse();

  let img: string = asString(item['img3']);
  if (img.length === 0) {
    img = asString(item['img2']);
  }
  if (img.length === 0) {
    img = asString(item['img1']);
  }
  const singers: Object[] = asObjectArray(item['singerList']);
  const singer: string = singers.length > 0 ? asString(asRecord(singers[0])['name']) : '';
  const info: LxMusicInfo = buildSong(
    asString(item['songName']),
    singer,
    'mg',
    songId,
    asString(item['album']),
    asString(item['albumId']),
    asNumber(item['duration']),
    mgImageUrl(img),
    '',
    types,
    map,
  );
  // 咪咕取流用 copyrightId（与 `MusicSearch.parseMgResult` 一致）
  if (copyrightId.length > 0) {
    info.copyrightId = copyrightId;
  }
  return info;
}

async function artistDetailMg(artist: LxArtist): Promise<LxArtistDetail> {
  const url: string = `https://app.c.nf.migu.cn/bmw/singer/index/v1.0?singerId=${encodeURIComponent(artist.id)}`;
  const resp: LxResponse = await httpGet(url, { 'User-Agent': MG_UA }, '咪咕');
  const body: Record<string, Object> = bodyRecord(resp, '咪咕');
  if (asString(body['code']) !== '000000') {
    throw new Error('咪咕歌手信息失败');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const block: Record<string, Object> = mgFindBlock(asObjectArray(data['contents']), 'ZJ-Singer-Intro-Scroll');
  let desc: string = '';
  for (const raw of asObjectArray(block['contents'])) {
    const item: Record<string, Object> = asRecord(raw);
    if (asString(item['view']) === 'ZJ-Singer-Intro-Item') {
      desc = asString(item['txt2']);
      break;
    }
  }
  return { name: artist.name, picUrl: artist.picUrl, desc: desc, songNum: artist.songNum, albumSize: artist.albumSize };
}

async function artistSongsMg(artist: LxArtist, page: number, limit: number): Promise<LxSearchPage> {
  const url: string = 'https://app.c.nf.migu.cn/bmw/singer/song/v1.0' +
    `?pageNo=${page}&singerId=${encodeURIComponent(artist.id)}&type=1`;
  const resp: LxResponse = await httpGet(url, { 'User-Agent': MG_UA }, '咪咕');
  const body: Record<string, Object> = bodyRecord(resp, '咪咕');
  if (asString(body['code']) !== '000000') {
    throw new Error('咪咕歌手歌曲失败');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const scroll: Record<string, Object> = mgFindBlock(asObjectArray(data['contents']), 'ZJ-Singer-Song-Scroll');
  const list: LxMusicInfo[] = [];
  for (const raw of asObjectArray(scroll['contents'])) {
    const item: Record<string, Object> = asRecord(asRecord(raw)['songItem']);
    const song: LxMusicInfo | null = mapMgArtistSong(item);
    if (song !== null) {
      list.push(song);
    }
  }
  // 咪咕不给总数：用 header.nextPageUrl 判有没有下一页（有就当作还有一页）
  const header: Record<string, Object> = asRecord(data['header']);
  const hasMore: boolean = asString(header['nextPageUrl']).length > 0;
  return songPageOf(list, 0, page, hasMore ? limit : list.length);
}

// ================================================================== QQ 音乐 tx

const TX_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

const TX_HEADERS: Record<string, string> = {
  'Content-Type': 'application/json;charset=utf-8',
  'User-Agent': TX_UA,
  'Referer': 'https://y.qq.com/',
};

/**
 * musicu.fcg 请求体的形状
 *
 * 这些必须声明成接口：ArkTS 不允许「没有对应类型的对象字面量」
 * （arkts-no-untyped-obj-literals），嵌套的那几层尤其会报。
 * ct / cv 在歌手详情那侧是数字、在搜索那侧是字符串，所以写成联合类型。
 */
interface TxComm {
  ct: string | number;
  cv: string | number;
  uin?: string;
}

interface TxSingerParam {
  /** 5 = 最热，2 = 最新 */
  sort: number;
  singermid: string;
  sin: number;
  num: number;
}

interface TxSingerReq {
  method: string;
  param: TxSingerParam;
  module: string;
}

interface TxSearchParam {
  grp: number;
  num_per_page: number;
  page_num: number;
  query: string;
  /** 1 = 歌手（0 是歌曲，见 `MusicSearch.createTxRequestBody`） */
  search_type: number;
}

interface TxSearchReq {
  module: string;
  method: string;
  param: TxSearchParam;
}

/** musicu.fcg 的通用入口（听歌搜歌走的是带签名的 musics.fcg；歌手这几个老服务不校验签名） */
async function txMusicu(payload: Record<string, Object>, what: string): Promise<Record<string, Object>> {
  const resp: LxResponse = await httpPost('https://u.y.qq.com/cgi-bin/musicu.fcg',
    JSON.stringify(payload), TX_HEADERS, what);
  const body: Record<string, Object> = bodyRecord(resp, what);
  if (asNumber(body['code']) !== 0) {
    throw new Error(`${what}接口返回 code ${asNumber(body['code'])}`);
  }
  return body;
}

/**
 * 歌手详情与歌手歌曲共用的一次请求
 *
 * `music.web_singer_info_svr / get_singer_detail_info` 一次既回歌手信息
 * （名字 / 简介 / 两个计数）又回那一页歌曲（songlist），差别只在
 * sort（5 = 最热，2 = 最新）与 sin / num（从第几首开始、要几首）。
 */
async function txSingerDetail(mid: string, order: LxArtistOrder, page: number,
  limit: number): Promise<Record<string, Object>> {
  const comm: TxComm = { ct: 24, cv: 0 };
  const singer: TxSingerReq = {
    method: 'get_singer_detail_info',
    param: {
      sort: order === 'hot' ? 5 : 2,
      singermid: mid,
      sin: limit * (page - 1),
      num: limit,
    },
    module: 'music.web_singer_info_svr',
  };
  const payload: Record<string, Object> = {};
  payload['comm'] = comm;
  payload['singer'] = singer;
  const body: Record<string, Object> = await txMusicu(payload, 'QQ 音乐');
  const result: Record<string, Object> = asRecord(body['singer']);
  if (asNumber(result['code']) !== 0) {
    throw new Error(`QQ 音乐歌手接口返回 code ${asNumber(result['code'])}`);
  }
  return asRecord(result['data']);
}

/** tx 只认 singerMID；调用方给的是哪个就用哪个 */
function txArtistMid(artist: LxArtist): string {
  return artist.mid.length > 0 ? artist.mid : artist.id;
}

async function searchArtistTx(keyword: string, page: number, limit: number): Promise<LxArtistPage> {
  const comm: TxComm = { ct: '19', cv: '1859', uin: '0' };
  const search: TxSearchReq = {
    module: 'music.search.SearchCgiService',
    method: 'DoSearchForQQMusicDesktop',
    param: { grp: 1, num_per_page: limit, page_num: page, query: keyword, search_type: 1 },
  };
  const payload: Record<string, Object> = {};
  payload['comm'] = comm;
  payload['req'] = search;
  const body: Record<string, Object> = await txMusicu(payload, 'QQ 音乐');
  const req: Record<string, Object> = asRecord(body['req']);
  if (asNumber(req['code']) !== 0) {
    throw new Error(`QQ 音乐歌手搜索返回 code ${asNumber(req['code'])}`);
  }
  const data: Record<string, Object> = asRecord(req['data']);
  const singer: Record<string, Object> = asRecord(asRecord(data['body'])['singer']);
  const list: LxArtist[] = [];
  for (const raw of asObjectArray(singer['list'])) {
    const item: Record<string, Object> = asRecord(raw);
    const mid: string = asString(item['singerMID']);
    if (mid.length === 0) {
      continue;
    }
    // 缩略图是 R300x300 这种尺寸，换成 800 才够详情页当大图用
    const pic: string = asString(item['singerPic']).replace(/R\d+x\d+M000/, 'R800x800M000');
    list.push({
      source: 'tx',
      id: mid,
      mid: mid,
      name: asString(item['singerName']),
      alias: '',
      picUrl: pic,
      songNum: asNumber(item['songNum']),
      albumSize: asNumber(item['albumNum']),
    });
  }
  // 命中总数在 meta.estimate_sum（与搜歌同一处，见 `MusicSearch.searchTx`）
  const total: number = asNumber(asRecord(data['meta'])['estimate_sum']);
  return artistPageOf(list, total, page, limit);
}

async function artistDetailTx(artist: LxArtist): Promise<LxArtistDetail> {
  const mid: string = txArtistMid(artist);
  const data: Record<string, Object> = await txSingerDetail(mid, 'hot', 1, 1);
  return {
    name: asString(asRecord(data['singer_info'])['name']).length > 0
      ? asString(asRecord(data['singer_info'])['name'])
      : artist.name,
    // QQ 歌手头像的地址是按 mid 拼出来的，接口里没有这个字段
    picUrl: `https://y.gtimg.cn/music/photo_new/T001R800x800M000${mid}.jpg`,
    desc: asString(data['singer_brief']),
    songNum: asNumber(data['total_song']),
    albumSize: asNumber(data['total_album']),
  };
}

async function artistSongsTx(artist: LxArtist, order: LxArtistOrder, page: number,
  limit: number): Promise<LxSearchPage> {
  const data: Record<string, Object> = await txSingerDetail(txArtistMid(artist), order, page, limit);
  const list: LxMusicInfo[] = [];
  for (const raw of asObjectArray(data['songlist'])) {
    const item: Record<string, Object> = asRecord(raw);
    const mid: string = asString(item['mid']);
    if (mid.length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const file: Record<string, Object> = asRecord(item['file']);
    addArtistQuality(types, map, '128k', asNumber(file['size_128mp3']), '');
    addArtistQuality(types, map, '320k', asNumber(file['size_320mp3']), '');
    addArtistQuality(types, map, 'flac', asNumber(file['size_flac']), '');
    addArtistQuality(types, map, 'flac24bit', asNumber(file['size_hires']), '');
    types.reverse();

    const album: Record<string, Object> = asRecord(item['album']);
    const albumMid: string = asString(album['mid']);
    const img: string = albumMid.length > 0
      ? `https://y.gtimg.cn/music/photo_new/T002R500x500M000${albumMid}.jpg`
      : '';
    const info: LxMusicInfo = buildSong(
      asString(item['name']).length > 0 ? asString(item['name']) : asString(item['title']),
      txSingerNames(asObjectArray(item['singer'])),
      'tx',
      mid,
      asString(album['name']),
      albumMid,
      asNumber(item['interval']),
      img,
      '',
      types,
      map,
    );
    // 源脚本（自定义源）取 QQ 播放链接需要这几个字段，与 `MusicSearch.parseTxSongs` 一致
    info.songId = asString(item['id']);
    info.albumMid = albumMid;
    info.strMediaMid = asString(file['media_mid']);
    list.push(info);
  }
  return songPageOf(list, asNumber(data['total_song']), page, limit);
}

function txSingerNames(singers: Object[]): string {
  const names: string[] = [];
  for (const raw of singers) {
    const name: string = asString(asRecord(raw)['name']);
    if (name.length > 0) {
      names.push(name);
    }
  }
  return names.join('、');
}

// ================================================================== 网易 wy

const WY_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36';

const WY_HEADERS: Record<string, string> = {
  'User-Agent': WY_UA,
  'Referer': 'https://music.163.com/',
  // appver 是这几个老 api 的「最低门槛」：不带会被当成过期的网页端直接回空
  'Cookie': 'appver=2.0.2',
};

async function wyGet(url: string, what: string): Promise<Record<string, Object>> {
  const resp: LxResponse = await httpGet(url, WY_HEADERS, what);
  const body: Record<string, Object> = bodyRecord(resp, what);
  if (asNumber(body['code']) !== 200) {
    throw new Error(`${what}接口返回 code ${asNumber(body['code'])}`);
  }
  return body;
}

async function searchArtistWy(keyword: string, page: number, limit: number): Promise<LxArtistPage> {
  const url: string = 'https://music.163.com/api/search/get/web' +
    `?s=${encodeURIComponent(keyword)}&type=100&limit=${limit}&offset=${limit * (page - 1)}`;
  const body: Record<string, Object> = await wyGet(url, '网易');
  const result: Record<string, Object> = asRecord(body['result']);
  const list: LxArtist[] = [];
  for (const raw of asObjectArray(result['artists'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['id']);
    if (id.length === 0) {
      continue;
    }
    // alias 是数组，列表里只放第一个（网易给的多是英文名，如「Jay Chou」）
    const aliasList: Object[] = asObjectArray(item['alias']);
    list.push({
      source: 'wy',
      id: id,
      mid: '',
      name: asString(item['name']),
      alias: aliasList.length > 0 ? asString(aliasList[0]) : '',
      picUrl: asString(item['picUrl']).replace('http://', 'https://'),
      songNum: asNumber(item['musicSize']),
      albumSize: asNumber(item['albumSize']),
    });
  }
  return artistPageOf(list, asNumber(result['artistCount']), page, limit);
}

async function artistDetailWy(artist: LxArtist): Promise<LxArtistDetail> {
  const body: Record<string, Object> = await wyGet(
    `https://music.163.com/api/v1/artist/${encodeURIComponent(artist.id)}`, '网易');
  const info: Record<string, Object> = asRecord(body['artist']);
  const songNum: number = asNumber(info['musicSize']);
  return {
    name: asString(info['name']).length > 0 ? asString(info['name']) : artist.name,
    picUrl: asString(info['picUrl']).replace('http://', 'https://'),
    desc: asString(info['briefDesc']),
    songNum: songNum > 0 ? songNum : artist.songNum,
    albumSize: asNumber(info['albumSize']),
  };
}

/**
 * 网易歌手全部歌曲
 *
 * 用老接口 `/api/v1/artist/songs`（实测「周杰伦」报名 566 首、带 total 与 more），
 * 不是 eapi —— `MusicSearch` 顶部已经记着那条 eapi 链路（/api/search/song/list/page）
 * 返 404。响应里的歌是**老格式**（ar / al / dt），与搜歌时解析的
 * `resources[].baseInfo.simpleSongData` 不同，所以这里自己解一份。
 */
async function artistSongsWy(artist: LxArtist, order: LxArtistOrder, page: number,
  limit: number): Promise<LxSearchPage> {
  const url: string = 'https://music.163.com/api/v1/artist/songs' +
    `?id=${encodeURIComponent(artist.id)}&offset=${limit * (page - 1)}&limit=${limit}` +
    `&order=${order === 'hot' ? 'hot' : 'time'}&private_cloud=true&work_type=1`;
  const body: Record<string, Object> = await wyGet(url, '网易');
  const list: LxMusicInfo[] = [];
  for (const raw of asObjectArray(body['songs'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['id']);
    if (id.length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    addArtistQuality(types, map, '128k', asNumber(asRecord(item['l'])['size']), '');
    addArtistQuality(types, map, '320k', asNumber(asRecord(item['h'])['size']), '');
    addArtistQuality(types, map, 'flac', asNumber(asRecord(item['sq'])['size']), '');
    addArtistQuality(types, map, 'flac24bit', asNumber(asRecord(item['hr'])['size']), '');
    // 拓展档（母带 / 沉浸声 / 杜比全景声）：这个接口把 maxBrLevel 放在每首歌的 privilege 里，
    // 规则与搜索 / 歌单共用一份（见 MusicSearch.appendWyExtendQualities）
    appendWyExtendQualities(asRecord(item['privilege']), item, types, map);
    types.reverse();

    const album: Record<string, Object> = asRecord(item['al']);
    list.push(buildSong(
      asString(item['name']),
      txSingerNames(asObjectArray(item['ar'])),
      'wy',
      id,
      asString(album['name']),
      asString(album['id']),
      // dt 是毫秒
      Math.floor(asNumber(item['dt']) / 1000),
      asString(album['picUrl']).replace('http://', 'https://'),
      '',
      types,
      map,
    ));
  }
  return songPageOf(list, asNumber(body['total']), page, limit);
}

// ================================================================== 认过的歌手（落盘缓存）

const DOMAIN: number = 0x0001;
const TAG: string = 'MusicArtist';
const ARTIST_CACHE_FILE: string = 'artist_cache.json';
/** 落盘结构变了就 +1，读到不认识的版本按空缓存处理 */
const ARTIST_CACHE_VERSION: number = 1;
/**
 * 最多记多少位认过的歌手
 *
 * 一条 ≈ 300 字节，200 条 ≈ 60KB —— 上限的意义是别让它无限长。认过的歌手本来也不会
 * 太多（一个人常听的也就几十位），而且满了丢的是**最早认的**那批，常用的自然留在里面。
 */
const ARTIST_CACHE_MAX: number = 200;

interface ArtistCacheData {
  version?: number;
  items?: LxArtist[];
}

/**
 * 认过的歌手缓存（名字 -> 歌手，含头像地址）
 *
 * 为什么必须有这一层：把「名字」认成「平台 + id」要联网搜一次，而同一批歌手会被反复认 ——
 * 歌手列表页一进去要给每位解析一张头像，点进歌手页还要再认一次，下次打开这一页又是同一批人。
 * 不缓存的话，每开一次列表页就是十几个请求，表现就是「每次都转半天」。
 *
 * 存法与项目里其它小 store 一致（`SearchHistory` / `ListenLog` / `MediaCache`）：一份 JSON
 * 落在应用沙箱（filesDir/artist_cache.json），`EntryAbility.onCreate` 里 init 一次。
 * 没 init 时（预览器、单测这种环境）读写都当空 —— 不抛错，只是退化成每次都联网认。
 *
 * 只缓存**认到了的**：认不到的（平台没这个人、当时网络不通）一律不记 —— 否则一次偶发失败
 * 会被记成「这个人不存在」，那位歌手就再也点不进去了。
 */
class ArtistStore {
  private static instance: ArtistStore | null = null;

  static getInstance(): ArtistStore {
    if (ArtistStore.instance === null) {
      ArtistStore.instance = new ArtistStore();
    }
    return ArtistStore.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 认到的先后（新的在后），满了从最旧的开始丢 */
  private order: string[] = [];
  private byKey: Map<string, LxArtist> = new Map();

  /** 绑定沙箱目录并读回缓存。EntryAbility.onCreate 里调一次 */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${ARTIST_CACHE_FILE}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length === 0) {
      return;
    }
    try {
      const data: ArtistCacheData = JSON.parse(text) as ArtistCacheData;
      if (data.version !== ARTIST_CACHE_VERSION) {
        return;
      }
      const items: LxArtist[] | undefined = data.items;
      if (items === undefined || items === null) {
        return;
      }
      for (const item of items) {
        const key: string = this.keyOf(item.name);
        if (key.length === 0 || this.byKey.has(key)) {
          continue;
        }
        this.order.push(key);
        this.byKey.set(key, item);
      }
      hilog.info(DOMAIN, TAG, 'artist cache ready, %{public}d artist(s)', this.byKey.size);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse artist cache failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 缓存键：归一化后的名字
   *
   * **不带平台**：认人的结果本身就是「这个人最终落在哪个平台」，而下次再认同一个名字时
   * 优先平台可能已经变了（歌从别的站搜来的）。按名字存，认过一次就一直是同一个人。
   */
  private keyOf(name: string): string {
    return artistNameKey(name);
  }

  get(name: string): LxArtist | null {
    if (!this.inited) {
      return null;
    }
    const hit: LxArtist | undefined = this.byKey.get(this.keyOf(name));
    return hit !== undefined ? hit : null;
  }

  put(artist: LxArtist): void {
    if (!this.inited || artist.name.length === 0) {
      return;
    }
    const key: string = this.keyOf(artist.name);
    if (key.length === 0) {
      return;
    }
    if (!this.byKey.has(key)) {
      this.order.push(key);
    }
    this.byKey.set(key, artist);
    while (this.order.length > ARTIST_CACHE_MAX) {
      const oldest: string | undefined = this.order.shift();
      if (oldest !== undefined) {
        this.byKey.delete(oldest);
      }
    }
    this.write();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read artist cache failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    const items: LxArtist[] = [];
    for (const key of this.order) {
      const artist: LxArtist | undefined = this.byKey.get(key);
      if (artist !== undefined) {
        items.push(artist);
      }
    }
    const data: ArtistCacheData = { version: ARTIST_CACHE_VERSION, items: items };
    try {
      const handle = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write artist cache failed: %{public}s', JSON.stringify(e));
    }
  }
}

/** 绑定沙箱目录（`EntryAbility.onCreate` 里调一次），之后认过的歌手就有缓存可用 */
export function initArtistCache(context: common.Context): void {
  ArtistStore.getInstance().init(context);
}

/**
 * 已经认过的歌手（同步，不联网）
 *
 * 给「点了歌手名要开歌手页」那条路用：命中的话连那句「正在查找歌手…」都不必闪，
 * 直接开页 —— 从歌手列表页点进来时几乎总是命中（那一页进去时已经挨个认过一遍）。
 */
export function cachedArtistOf(name: string): LxArtist | null {
  return ArtistStore.getInstance().get(name);
}

// ================================================================== 入口

/** 搜单个平台的一页歌手；接口不通一律抛错，不返回空数组（与 `searchMusicPage` 同一约定） */
export function searchArtistPage(keyword: string, source: string, page: number = 1,
  limit: number = 30): Promise<LxArtistPage> {
  const text: string = keyword.trim();
  if (text.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  if (source === 'kw') {
    return searchArtistKw(text, page, limit);
  }
  if (source === 'kg') {
    return searchArtistKg(text, page, limit);
  }
  if (source === 'mg') {
    return searchArtistMg(text, page, limit);
  }
  if (source === 'tx') {
    return searchArtistTx(text, page, limit);
  }
  if (source === 'wy') {
    return searchArtistWy(text, page, limit);
  }
  return Promise.reject(new Error(`${source} 暂无内置歌手搜索实现（当前支持：${ARTIST_PLATFORMS.join(' / ')}）`));
}

/** 单平台歌手搜索，失败也返回（不抛），供聚合用 */
async function collectArtistPlatform(keyword: string, source: string, page: number,
  limit: number): Promise<LxArtistPlatformResult> {
  try {
    const result: LxArtistPage = await searchArtistPage(keyword, source, page, limit);
    return {
      source: source,
      items: result.list,
      error: '',
      allPage: result.allPage,
      total: result.total,
    };
  } catch (e) {
    return { source: source, items: [], error: (e as Error).message, allPage: page, total: 0 };
  }
}

/**
 * 聚合搜歌手：一次问所有平台，合起来按名字去一次重。
 *
 * 「按歌手聚合」的关键一步就在这里：同一个人五个平台都返回一条，不合并的话
 * 列表里就是连着五行「周杰伦」（与搜歌时不按歌手去重会「同一首歌连着出现五遍」
 * 是同一类毛病）。留下的是**先问的平台**那一份 —— 与 `searchMusicAll` 里
 * 「先问的平台留下」同一规则，读代码的人在两个入口看到的是同一句话。
 *
 * 单个平台失败（超时、接口改了）不该让整次搜索失败，所以逐平台各自 try 一遍，
 * 失败的把原因带回去给状态行显示。
 */
export async function searchArtistsAll(
  keyword: string,
  sources: string[] = ARTIST_PLATFORMS,
  page: number = 1,
  limit: number = 30,
): Promise<LxArtistOutcome> {
  const text: string = keyword.trim();
  if (text.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  const tasks: Promise<LxArtistPlatformResult>[] = [];
  for (const source of sources) {
    tasks.push(collectArtistPlatform(text, source, page, limit));
  }
  const settled: PromiseSettledResult<LxArtistPlatformResult>[] = await Promise.allSettled(tasks);
  const platforms: LxArtistPlatformResult[] = [];
  const flat: LxArtist[] = [];
  let maxPage: number = page;
  for (let i = 0; i < settled.length; i++) {
    const r: PromiseSettledResult<LxArtistPlatformResult> = settled[i];
    const one: LxArtistPlatformResult = r.status === 'fulfilled'
      ? r.value
      : { source: sources[i], items: [], error: '搜索失败', allPage: page, total: 0 };
    platforms.push(one);
    if (one.allPage > maxPage) {
      maxPage = one.allPage;
    }
    for (const artist of one.items) {
      flat.push(artist);
    }
  }
  return {
    keyword: text,
    page: page,
    platforms: platforms,
    items: dedupeArtists(flat),
    maxPage: maxPage,
  };
}

/**
 * 歌手列表去重（同一人只留一条，先来的那条留下）
 *
 * 与 `MusicSearch.dedupeSongs` 同一个位置上的作用：翻页时同一个人可能在两页都出现，
 * 「这一页的结果」和「已翻过的页」拼起来必须按同一套规则去掉重复，否则列表里会冒出
 * 两行一模一样的「周杰伦」。
 */
export function dedupeArtists(items: LxArtist[]): LxArtist[] {
  const out: LxArtist[] = [];
  const seen: string[] = [];
  for (const artist of items) {
    const key: string = artistNameKey(artist.name);
    // 名字为空的没法当去重键：留着（丢弃整条更糟），但不参与去重
    if (key.length > 0) {
      if (seen.includes(key)) {
        continue;
      }
      seen.push(key);
    }
    out.push(artist);
  }
  return out;
}

/** 歌手详情（简介 + 两个计数）；取不到就退回搜索结果里带的那几项 */
export async function getArtistDetail(artist: LxArtist): Promise<LxArtistDetail> {
  try {
    if (artist.source === 'kw') {
      return await artistDetailKw(artist);
    }
    if (artist.source === 'kg') {
      return await artistDetailKg(artist);
    }
    if (artist.source === 'mg') {
      return await artistDetailMg(artist);
    }
    if (artist.source === 'tx') {
      return await artistDetailTx(artist);
    }
    if (artist.source === 'wy') {
      return await artistDetailWy(artist);
    }
  } catch (e) {
    // 简介与计数都是「有则更好」：接口不通不该让歌手页整页打不开
  }
  return {
    name: artist.name,
    picUrl: artist.picUrl,
    desc: '',
    songNum: artist.songNum,
    albumSize: artist.albumSize,
  };
}

/**
 * 按歌手聚合歌曲：这个歌手在该平台上的全部歌，一页一页地拿。
 *
 * @param order 'hot' = 最热在前（默认），'new' = 最新在前
 */
export async function getArtistSongs(artist: LxArtist, page: number = 1, limit: number = 30,
  order: LxArtistOrder = 'hot'): Promise<LxSearchPage> {
  if (artist.source === 'kw') {
    return artistSongsKw(artist, page, limit);
  }
  if (artist.source === 'kg') {
    return artistSongsKg(artist, order, page, limit);
  }
  if (artist.source === 'mg') {
    return artistSongsMg(artist, page, limit);
  }
  if (artist.source === 'tx') {
    return artistSongsTx(artist, order, page, limit);
  }
  if (artist.source === 'wy') {
    return artistSongsWy(artist, order, page, limit);
  }
  throw new Error(`${artist.source} 暂无内置歌手歌曲实现`);
}

/**
 * 拿名字去某个平台认一个歌手
 *
 * 给「只有歌手名、没有 id」的入口用（歌曲列表里的歌手名、搜索历史里的名字）。
 * 只在那一个平台上搜一次，取**名字完全一致**的第一条；对不上就返回 null ——
 * 宁可不给入口，也别把用户带到同名的另一个人那里。
 */
export async function findArtistByName(source: string, name: string): Promise<LxArtist | null> {
  const text: string = name.trim();
  if (text.length === 0) {
    return null;
  }
  const page: LxArtistPage = await searchArtistPage(text, source, 1, 20);
  const key: string = artistNameKey(text);
  for (const artist of page.list) {
    if (artistNameKey(artist.name) === key) {
      return artist;
    }
  }
  return null;
}

/**
 * 把歌曲里那行歌手拆成一位一位
 *
 * 「周杰伦、方文山」/「方文山/周杰伦」/「A & B」都要拆开 —— 分隔符直接用搜歌那边
 * 的 `SINGER_SEPARATORS`（见 `MusicSearch`），保证「界面上拆出来的」与
 * 「去重时算的」是同一套拆分。拆完去空白、去重、保序。
 */
export function splitSingerNames(singer: string): string[] {
  const out: string[] = [];
  const parts: string[] = singer.split(SINGER_SEPARATORS);
  for (const part of parts) {
    const one: string = part.trim();
    if (one.length === 0 || out.includes(one)) {
      continue;
    }
    out.push(one);
  }
  return out;
}

/**
 * 一首歌 ->「点歌手名」那一步要挑的候选
 *
 * 只有一位歌手时返回一条（壳层直接开歌手页，不弹选择）；多位时由壳层把整个列表
 * 交给歌手列表页。
 */
export function artistCandidatesOf(source: string, singer: string): ArtistCandidate[] {
  const out: ArtistCandidate[] = [];
  for (const name of splitSingerNames(singer)) {
    out.push({ source: source, name: name, note: '' });
  }
  return out;
}

/**
 * 拿名字认一位歌手：先问这首歌自己那个平台，认不到再按 `ARTIST_PLATFORMS` 的顺序问其余的
 *
 * 为什么不止问一个平台：歌曲来源是「这首歌从哪搜到的」，不一定等于「这位歌手
 * 在那个平台能被搜到」—— 一首从酷我听来的歌，歌手页却可能只有酷狗认（酷我的
 * 歌手搜索接口挂了、或那位歌手在酷我上没有独立条目）。认到就开，认不到才作罢。
 *
 * 只认**名字完全一致**的（同一套 `artistNameKey` 归一化）：宁可告诉用户
 * 「没找到这位歌手」，也别把他带到同名的另一个人那里。
 *
 * 认过一次就落盘（见上面的 ArtistStore）：同一个名字再来问，直接拿缓存、不联网。
 */
export async function resolveArtistByName(name: string, preferredSource: string = ''): Promise<LxArtist | null> {
  const text: string = name.trim();
  if (text.length === 0) {
    return null;
  }
  // 1) 认过的直接给（含头像地址）：列表页一进去要给每位解析头像，这一层命中就完全不用联网
  const cached: LxArtist | null = ArtistStore.getInstance().get(text);
  if (cached !== null) {
    return cached;
  }
  // 2) 没认过：按「这首歌的平台 -> 其余平台」的顺序问一遍
  const order: string[] = [];
  if (preferredSource.length > 0) {
    order.push(preferredSource);
  }
  for (const source of ARTIST_PLATFORMS) {
    if (!order.includes(source)) {
      order.push(source);
    }
  }
  for (const source of order) {
    try {
      const found: LxArtist | null = await findArtistByName(source, text);
      if (found !== null) {
        ArtistStore.getInstance().put(found);
        return found;
      }
    } catch (e) {
      // 这个平台没通就换下一个（歌手页的入口不该因为某一个平台的接口挂了就整条断掉）
    }
  }
  return null;
}
