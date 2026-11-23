import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
// 跟随短链要带**桌面浏览器**的 UA：移动 UA 会被 QQ 音乐的分享链跳到下载页（群里小冰的原话，
// 2026-11-23 本机复核见 SHORT_LINK_HEADERS 的说明）。UA 常量复用登录页那一份，不再维护第二份。
import { TX_UA } from './MusicAccount';
import { platformName } from './MusicList';

/**
 * 歌单分享链接解析（对齐洛雪各平台 songList 的 listDetailLink 规则）
 *
 * 洛雪的做法是把「歌单 id」和「分享链接」当成同一个参数传给平台 SDK：各平台先拿
 * listDetailLink 正则从链接里抠出 id，抠不出来就发一次请求跟随重定向，再从最终地址
 * 里抠（wy/mg/kg/tx 都有这一步 handleParseId，见 lx-music-mobile/src/utils/musicSdk/
 * {wy,mg,kw,kg,tx}/songList.js）。这里分同样的两步：先本地正则（离线、瞬时），
 * 失败再跟随短链（163cn.tv、c.migu.cn、t1.kugou.com 这类）。
 *
 * 解析出来的东西就是洛雪列表标识 `${source}__${id}` 的两个组成部分：
 * 拿到之后交给内置平台接口取歌单歌曲（core/music/MusicList 的 getPlaylistDetailAll），
 * 再落成本地歌单（core/sync/LocalLibrary 的 importPlaylist）。
 */

/** 一次解析的结果 */
export interface PlaylistLink {
  /** 平台：kw / kg / mg / tx / wy */
  source: string;
  /** 平台侧的歌单 id */
  id: string;
  /** 洛雪的列表标识 `${source}__${id}`，导入后原样写进歌单的 sourceListId */
  listId: string;
  /** 命中的链接（跟随短链后是最终地址）；只给了 id 时是空串 */
  url: string;
}

/** 平台域名（按后缀匹配，所以 i.y.qq.com 这种子域也算 y.qq.com） */
const PLATFORM_DOMAINS: string[][] = [
  ['wy', 'music.163.com'],
  ['wy', '163cn.tv'],
  ['tx', 'y.qq.com'],
  ['kg', 'kugou.com'],
  ['kw', 'kuwo.cn'],
  ['mg', 'migu.cn'],
];

/**
 * 各平台从链接里抠歌单 id 的正则，照抄洛雪（顺序也照抄：先平台自己的形式，再通用的 id=）：
 *   wy  listDetailLink  /^.+(?:\?|&)id=(\d+)(?:&.*$|#.*$|$)/
 *       listDetailLink2 /^.+\/playlist\/(\d+)\/\d+\/.+$/
 *   mg  listDetailLink  /^.+\/playlist\/(\d+)(?:\?.*|&.*$|#.*$|$)/（外加 playlistId=id）
 *   kw  listDetailLink  /^.+\/playlist(?:_detail)?\/(\d+)(?:\?.*|&.*$|#.*$|$)/
 *   kg  listDetailLink  /^.+\/(\d+)\.html(?:\?.*|&.*$|#.*$|$)/
 *   tx  listDetailLink  /\/playlist\/(\d+)/ + listDetailLink2 /id=(\d+)/
 *
 * 酷狗还有一类洛雪没管、用户分享出来却最常见的：用户歌单（gcid 全局集合 id），
 * 形如 m.kugou.com/songlist/gcid_3z18r5q99zaz0b6/?src_cid=...&uid=...。
 * 它既不是 /<id>.html、也没有 specialid=，照洛雪那两条正则永远抠不出来，
 * 老版本直接报「没能从酷狗链接里找到歌单 id」。这里单独认一下：id 原样保留成
 * gcid_xxx，由 MusicList 的 kgPlaylistDetail 再用歌单页换出 specialid。
 */
const KG_GCID_PATH: RegExp = /\/(gcid_[0-9A-Za-z]+)/i;
const KG_GCID_PARAM: RegExp = /[?&](?:src_cid|gcid|global_collection_id)=([0-9A-Za-z]+)/;

const ID_REGEXPS: Record<string, RegExp[]> = {
  'wy': [/[?&]id=(\d+)/, /\/playlist\/(\d+)\/\d+/, /\/playlist\/(\d+)/],
  'mg': [/\/playlist\/(\d+)/, /[?&](?:playlistId|id)=(\d+)/],
  'kw': [/\/playlist(?:_detail)?\/(\d+)/, /[?&](?:pid|id)=(\d+)/],
  'kg': [/\/(\d+)\.html/, /[?&](?:specialid|id)=(\d+)/],
  'tx': [/\/playlist\/(\d+)/, /[?&](?:disstid|id)=(\d+)/],
};

/**
 * 单曲 / 专辑 / MV 链接的样子
 *
 * 只在「认出了平台却抠不到歌单 id」时用来给一句人话。分享文本里最常见的错法就是
 * 把单曲分享当成歌单分享，直接报「接口返回异常」用户看不懂。
 */
const NON_LIST_PATTERNS: RegExp[] = [
  /\/song[/?#]/, /songDetail/, /\/play_detail\//, /\/album[/?#]/, /\/mv[/?#]/, /\/singer[/?#]/,
];

/**
 * 分享文本里的一条链接
 *
 * 到空白或标点为止。注意排除的只有**全角**中文标点与引号括号：半角的 `?` `!` `&`
 * 都是 URL 自己的字符（`playlist?id=` 全靠它），一起排除掉的话查询串会被砍掉，
 * 链接就解析不出歌单 id 了。
 */
const URL_PATTERN: RegExp = /https?:\/\/[^\s"'<>，。、；：！？（）【】《》「」『』,;()\[\]{}]+/;

/** 直接给「平台__id」的形式（洛雪的 listId），方便老用户按 id 导入 */
const SOURCE_ID_PATTERN: RegExp = /^(kw|kg|mg|tx|wy)__([0-9A-Za-z_-]+)$/;

/** 短链最多跟几跳 */
const MAX_REDIRECT_HOP: number = 4;

/** 跟随短链时单个请求的超时（短链服务器不该慢，慢了就当解析不出来） */
const REDIRECT_TIMEOUT: number = 8000;

/**
 * 跟随短链时的一组请求头
 *
 * **UA 必须是桌面浏览器**：QQ 音乐客户端分享出来的
 * `https://c6.y.qq.com/base/fcgi-bin/u?__=xxxxxxxx` 会按 UA 分流 —— 移动 UA 有机会被
 * 跳到「下载客户端」页，桌面 UA 才是歌单页（群里小冰给的现象）。
 *
 * 2026-11-23 本机复核（Chrome 120 桌面 UA，带 `--max-redirs 0` 直连）：
 *   302 → `https://i2.y.qq.com/n3/other/pages/details/playlist.html?ADTAG=cbshare
 *          &appshare=ohqm&...&id=2480744845&...`
 * 也就是说**歌单 id 直接躺在 Location 的 `id=` 里**，根本不必等落地页渲染；
 * 而落地页正文（50KB 的 HTML）里也有 `/playlist/2480744845` 两处 —— 两条路都能抠到 id，
 * 所以下面「读 Location」与「从正文抠」两条兜底都保留（后者覆盖系统自动跟完 302 的情况）。
 *
 * 另外要 Accept: text/html：这些是网页跳转接口，不是 JSON API，声明要 HTML 更接近真实浏览器。
 */
const SHORT_LINK_HEADERS: Record<string, string> = {
  'User-Agent': TX_UA,
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9',
};

/** 一次短链跟随的收获 */
interface ShortLinkOutcome {
  /** 最后一跳的地址（可能仍是短链本身） */
  url: string;
  /** 沿途任何一跳认出来的歌单；认不出是 null */
  link: PlaylistLink | null;
  /** 是否遇到过网络错误（只用来换一句更好懂的提示，不参与判断） */
  networkFailed: boolean;
}

/** 一次响应解释出来的「下一步」：要么有下一跳地址，要么直接认出歌单 */
interface HopResult {
  next: string;
  link: PlaylistLink | null;
}

// ------------------------------------------------------------------ 取值工具

function asText(v: Object | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return JSON.stringify(v);
  }
  return '';
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch (e) {
    // 分享文本里的 % 不一定是转义（比如歌名里的百分号），解不开就按原文用
    return value;
  }
}

function makeLink(source: string, id: string, url: string): PlaylistLink {
  return { source: source, id: id, listId: `${source}__${id}`, url: url };
}

/** 分享文本里的第一条链接；没有返回空串 */
export function firstUrl(text: string): string {
  const matched: RegExpMatchArray | null = text.match(URL_PATTERN);
  return matched === null ? '' : matched[0];
}

/** 链接的域名（小写，不含协议与路径） */
function hostOf(url: string): string {
  const matched: RegExpMatchArray | null = url.match(/^https?:\/\/([^/?#]+)/);
  return matched === null ? '' : matched[1].toLowerCase();
}

/** 只按域名认平台；认不出返回空串 */
export function platformOfUrl(url: string): string {
  const host: string = hostOf(url);
  if (host.length === 0) {
    return '';
  }
  for (const pair of PLATFORM_DOMAINS) {
    const source: string = pair[0];
    const domain: string = pair[1];
    if (host === domain || host.endsWith(`.${domain}`)) {
      return source;
    }
  }
  return '';
}

/** 按平台的正则从链接里抠歌单 id；抠不到返回空串 */
function extractId(source: string, url: string): string {
  // 酷狗用户歌单先单独认：gcid 既可能在路径里（/songlist/gcid_xxx/），也可能是
  // src_cid 参数（分享链里两种都出现过），参数里那个不带前缀，补上才是完整 id
  if (source === 'kg') {
    const byPath: RegExpMatchArray | null = url.match(KG_GCID_PATH);
    if (byPath !== null && byPath[1] !== undefined) {
      return byPath[1];
    }
    const byParam: RegExpMatchArray | null = url.match(KG_GCID_PARAM);
    if (byParam !== null && byParam[1] !== undefined && byParam[1].length > 0) {
      return 'gcid_' + byParam[1];
    }
  }
  const patterns: RegExp[] = ID_REGEXPS[source];
  if (patterns === undefined) {
    return '';
  }
  for (const pattern of patterns) {
    const matched: RegExpMatchArray | null = url.match(pattern);
    if (matched !== null && matched[1] !== undefined && matched[1].length > 0) {
      return matched[1];
    }
  }
  return '';
}

/** 链接看起来像单曲 / 专辑而不是歌单 */
function looksLikeSongLink(url: string): boolean {
  for (const pattern of NON_LIST_PATTERNS) {
    if (pattern.test(url)) {
      return true;
    }
  }
  return false;
}

/** 域名与歌单 id 都命中才算解析成功；单曲 / 专辑链接一律不算 */
function matchUrl(url: string): PlaylistLink | null {
  const source: string = platformOfUrl(url);
  if (source.length === 0) {
    return null;
  }
  if (looksLikeSongLink(url)) {
    return null;
  }
  const id: string = extractId(source, url);
  return id.length > 0 ? makeLink(source, id, url) : null;
}

/**
 * 把「平台 + 目标」收成一条解析结果
 *
 * target 要么是 id，要么是链接。深链里的 source 是权威的，所以链接域名认不出来时
 * 也按调用方给的 source 抠 id（洛雪深链里 source 与 id 是两个独立字段）。
 */
function linkFromTarget(source: string, target: string): PlaylistLink | null {
  if (target.length === 0) {
    return null;
  }
  if (/^https?:\/\//.test(target)) {
    if (looksLikeSongLink(target)) {
      return null;
    }
    const byUrl: PlaylistLink | null = matchUrl(target);
    if (byUrl !== null) {
      return byUrl;
    }
    const id: string = extractId(source, target);
    return id.length > 0 ? makeLink(source, id, target) : null;
  }
  // 酷狗用户歌单的 id 是 gcid_xxx（不是纯数字），深链里也会这么给
  return (/^\d+$/.test(target) || /^gcid_[0-9A-Za-z]+$/i.test(target))
    ? makeLink(source, target, '') : null;
}

/** 直接由「平台 + 歌单 id」造一条链接（从在线歌单详情页导入时用，不需要解析） */
export function linkOf(source: string, id: string): PlaylistLink {
  return makeLink(source, id, '');
}

/**
 * 由「平台 + 歌单 id」拼一条**规范长链接**（不联网、不猜 id）
 *
 * 用途：从在线歌单详情页直接导入时（ImportPlaylistSheet 的 presetSource/presetId），
 * 用户根本没粘贴过链接 —— 但需求要求「通过链接导入的歌单」都记下当时的链接，
 * 「我的 - 歌单」长按才有「更新导入歌单」。这里按平台拼一条规范地址存进侧表。
 *
 * **拼出来的链接必须能被 parseShareText 反解回同一个 id**：更新时会先拿它重新解析
 * 平台与 id，解析不出来才退回歌单里存的 sourceListId。所以每种形态都对照过
 * 上面的 ID_REGEXPS 与 KG_GCID_PATH（酷狗的用户歌单 id 是 `gcid_xxx`，走 /songlist/）。
 */
export function listUrlOf(source: string, id: string): string {
  if (id.length === 0) {
    return '';
  }
  if (source === 'tx') {
    return `https://y.qq.com/n/ryqq/playlist/${id}`;
  }
  if (source === 'wy') {
    return `https://music.163.com/#/playlist?id=${id}`;
  }
  if (source === 'kw') {
    return `https://www.kuwo.cn/playlist_detail/${id}`;
  }
  if (source === 'kg') {
    // 酷狗的用户歌单（gcid_xxx）与精选集（纯数字）是两种链接形态
    return id.startsWith('gcid_')
      ? `https://m.kugou.com/songlist/${id}/`
      : `https://www.kugou.com/yy/special/single/${id}.html`;
  }
  if (source === 'mg') {
    return `https://music.migu.cn/v3/music/playlist/${id}`;
  }
  return '';
}

/**
 * 一条解析结果该把**哪条链接**存进歌单的导入来源（「更新导入歌单」以后按它回源）
 *
 * 平时就存解析时用的那条（用户粘贴的链接 / 短链跟出来的落地页地址），保留「当时的导入链接」
 * 这个语义。但有一种情况存了也没用：系统自动跟随 302 时我们读不到最终地址，此时
 * `link.url` 还是短链本身，`parseShareText` 反解不出 id —— 那就换成本平台规范长链接
 * （listUrlOf），保证侧表里那条链接自己就能反解出平台与 id。
 */
export function linkUrlOf(link: PlaylistLink): string {
  const parsed: PlaylistLink | null = parseShareText(link.url);
  if (parsed !== null && parsed.listId === link.listId) {
    return link.url;
  }
  return listUrlOf(link.source, link.id);
}

// ------------------------------------------------------------------ 深链

function parseQuery(query: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (query.length === 0) {
    return out;
  }
  for (const part of query.split('&')) {
    const at: number = part.indexOf('=');
    if (at <= 0) {
      continue;
    }
    out[part.substring(0, at)] = part.substring(at + 1);
  }
  return out;
}

/**
 * 洛雪自己的分享链接：lxmusic://songlist/open/<source>/<id|链接>
 *
 * 官方客户端在「分享」里给的就是这个（桌面版还有 play 动作，格式一致）。
 * 也支持带 `?data=<JSON>` 的形式，那里 source / id / url 是三个独立字段。
 */
function parseLxDeepLink(text: string): PlaylistLink | null {
  if (!text.startsWith('lxmusic://')) {
    return null;
  }
  const queryAt: number = text.indexOf('?');
  const head: string = queryAt >= 0 ? text.substring(0, queryAt) : text;
  const query: string = queryAt >= 0 ? text.substring(queryAt + 1) : '';
  const data: string | undefined = parseQuery(query)['data'];
  if (data !== undefined) {
    try {
      const parsed: Record<string, Object> = JSON.parse(safeDecode(data)) as Record<string, Object>;
      const source: string = asText(parsed['source']);
      const id: string = asText(parsed['id']);
      const url: string = asText(parsed['url']);
      const fromData: PlaylistLink | null = linkFromTarget(source, id.length > 0 ? id : url);
      if (fromData !== null) {
        return fromData;
      }
    } catch (e) {
      // JSON 坏了就退回按路径解析
    }
  }
  const segments: string[] = head.replace('lxmusic://', '').split('/');
  // songlist / <action> / <source> / <id|链接> [/ <index>]
  if (segments.length < 4 || segments[0] !== 'songlist') {
    return null;
  }
  return linkFromTarget(safeDecode(segments[2]), safeDecode(segments[3]));
}

// ------------------------------------------------------------------ 对外 API

/**
 * 从分享文本里解析歌单（纯本地，不联网）
 *
 * 认不出来返回 null；认出来了但链接是单曲的，同样返回 null（由 resolveShareText
 * 统一给出人话解释）。分享文本可以是整段（「分享歌单《xxx》https://...」），
 * 也可以是光秃秃一条链接。
 */
export function parseShareText(text: string): PlaylistLink | null {
  const raw: string = text.trim();
  if (raw.length === 0) {
    return null;
  }
  const deepLink: PlaylistLink | null = parseLxDeepLink(raw);
  if (deepLink !== null) {
    return deepLink;
  }
  const sourceId: RegExpMatchArray | null = raw.match(SOURCE_ID_PATTERN);
  if (sourceId !== null) {
    return makeLink(sourceId[1], sourceId[2], '');
  }
  const url: string = firstUrl(raw);
  if (url.length === 0) {
    return null;
  }
  return matchUrl(url);
}

// ------------------------------------------------------------------ 短链

/**
 * 发一次 GET（短链跟随专用）
 *
 * @param maxRedirects 0 = 关掉自动重定向、由调用方自己从 Location 里读下一跳；
 *   不传 = 交给系统自动跟（跟完拿到的是落地页正文）。
 *
 * **两种都要能走**：`maxRedirects` 是 HarmonyOS API 23 才有的字段（见官方
 * HttpRequestOptions 文档：默认 30、取值 [0, 2147483647]、0 即关闭重定向），
 * 低版本设备上该字段会被忽略、系统自己把 302 跟掉 —— 那时响应里没有 Location，
 * 只能从落地页正文里抠 id。所以调用方对这两种情况都有兜底，不把成败押在系统版本上。
 */
function httpGet(url: string, maxRedirects?: number): Promise<LxResponse> {
  return new Promise<LxResponse>((resolve: (resp: LxResponse) => void,
    reject: (err: Error) => void) => {
    const options: LxRequestOptions = {
      rawText: true,
      timeout: REDIRECT_TIMEOUT,
      headers: SHORT_LINK_HEADERS,
    };
    if (maxRedirects !== undefined) {
      options.maxRedirects = maxRedirects;
    }
    lxRequest(url, options,
      (resp: LxResponse) => {
        resolve(resp);
      },
      (message: string) => {
        reject(new Error(message));
      });
  });
}

function isRedirect(statusCode: number): boolean {
  return statusCode >= 300 && statusCode < 400;
}

/** 响应头里的 Location（大小写不定，逐个比） */
function locationOf(resp: LxResponse): string {
  for (const key of Object.keys(resp.headers)) {
    if (key.toLowerCase() === 'location') {
      return resp.headers[key];
    }
  }
  return '';
}

/** 相对 Location 补成绝对地址 */
function absoluteUrl(base: string, location: string): string {
  if (/^https?:\/\//i.test(location)) {
    return location;
  }
  const matched: RegExpMatchArray | null = base.match(/^(https?:\/\/[^/?#]+)/);
  const origin: string = matched === null ? '' : matched[1];
  if (location.startsWith('//')) {
    return `https:${location}`;
  }
  if (location.startsWith('/')) {
    return `${origin}${location}`;
  }
  return location;
}

/**
 * 有些短链不做 3xx，而是在 HTML 里跳（meta refresh 或 location.replace）
 *
 * 网易/咪咕的分享短链两种都有，所以 200 响应也要捞一次。
 */
function htmlJumpTarget(resp: LxResponse): string {
  const body: string = typeof resp.body === 'string' ? resp.body as string : '';
  if (body.length === 0) {
    return '';
  }
  const meta: RegExpMatchArray | null =
    body.match(/http-equiv=["']?refresh["']?[^>]*content=["']?[^"'>]*url=([^"';\s>]+)/i);
  if (meta !== null && meta[1] !== undefined) {
    return meta[1];
  }
  const script: RegExpMatchArray | null =
    body.match(/(?:location\.(?:replace|href)\s*\(?\s*=?\s*)["']([^"']+)["']/i);
  if (script !== null && script[1] !== undefined) {
    return script[1];
  }
  return '';
}

/**
 * 从落地页正文里找「页面自己声明的正规地址」（canonical / og:url / JSON 里的 url）
 *
 * 用途：系统自动跟完 302 后，我们拿不到最终地址（响应里的 url 只是请求地址），
 * 而落地页可能在正文里声明自己的规范地址 —— 从那里又能读出平台与 id。
 * 只有前三步都抠不到 id 时才轮到它，所以宁可写得宽一点，也不能让它抢先误判。
 */
function canonicalUrlFromBody(body: string): string {
  if (body.length === 0) {
    return '';
  }
  const patterns: RegExp[] = [
    /<link[^>]+rel=["']canonical["'][^>]*href=["']([^"']+)["']/i,
    /<meta[^>]+property=["']og:url["'][^>]*content=["']([^"']+)["']/i,
    /"url"\s*:\s*"(https?:\\?\/\\?\/[^"]+)"/i,
  ];
  for (const pattern of patterns) {
    const matched: RegExpMatchArray | null = body.match(pattern);
    if (matched !== null && matched[1] !== undefined && matched[1].length > 0) {
      // JSON 里的地址是 `https:\/\/y.qq.com\/...` 这种转义形态，还原成正常 URL
      return matched[1].replace(/\\\//g, '/');
    }
  }
  return '';
}

/**
 * 从一次响应（200 的落地页）里认出歌单
 *
 * 顺序：正文里的歌单 id → 正文里声明的规范地址。平台优先按落地页域名认，
 * 落地页域名认不出来时用调用方给的（比如短链本身已经认出了 tx）。
 */
function linkFromBody(resp: LxResponse, base: string, fallbackSource: string): PlaylistLink | null {
  const body: string = typeof resp.body === 'string' ? resp.body as string : '';
  if (body.length === 0) {
    return null;
  }
  const source: string = platformOfUrl(base).length > 0 ? platformOfUrl(base) : fallbackSource;
  const id: string = playlistIdFromHtml(body);
  if (id.length > 0 && source.length > 0) {
    return makeLink(source, id, base);
  }
  const declared: string = canonicalUrlFromBody(body);
  return declared.length > 0 ? matchUrl(declared) : null;
}

/**
 * 解释一次响应：要么给出「下一跳地址」，要么直接给出歌单
 *
 * 3xx 时**先看 Location 本身**：QQ 分享链的 Location 里就带 `&id=2480744845`，
 * 认出来就直接收工，不必再请求落地页（少一次请求、也躲开落地页的 UA 分流）。
 */
function hopOf(resp: LxResponse, base: string, fallbackSource: string): HopResult {
  if (isRedirect(resp.statusCode)) {
    const location: string = locationOf(resp);
    if (location.length === 0) {
      return { next: '', link: null };
    }
    const next: string = absoluteUrl(base, location);
    return { next: next, link: matchUrl(next) };
  }
  const jumped: string = htmlJumpTarget(resp);
  if (jumped.length > 0) {
    const next: string = absoluteUrl(base, jumped);
    return { next: next, link: matchUrl(next) };
  }
  return { next: '', link: linkFromBody(resp, base, fallbackSource) };
}

/**
 * 跟随短链，顺便把歌单认出来（洛雪各平台 handleParseId 的那一步）
 *
 * 为什么不用系统自动重定向：跟完读不到最终地址（LxResponse.url 只是请求地址），
 * 也读不到中间每一跳的 Location —— 而 QQ 的 id 恰好就在第一跳的 Location 里。
 * 所以默认关掉自动重定向自己跟；万一设备/系统不认 `maxRedirects: 0`
 * （API 23 以下的字段会被忽略），再退回自动跟随、从落地页正文抠 id。
 *
 * @param fallbackSource 短链本身已经认出来的平台（落地页域名认不出时用它兜底）
 */
async function followShortLink(url: string, fallbackSource: string): Promise<ShortLinkOutcome> {
  let current: string = url;
  let networkFailed: boolean = false;
  for (let hop = 0; hop < MAX_REDIRECT_HOP; hop++) {
    // 每一跳的地址本身先认一次：Location 里带 id 的情况走这里
    const here: PlaylistLink | null = matchUrl(current);
    if (here !== null) {
      return { url: current, link: here, networkFailed: networkFailed };
    }
    let resp: LxResponse | null = null;
    try {
      resp = await httpGet(current, 0);
    } catch (e) {
      /**
       * 手动模式失败：可能是系统不认 maxRedirects（API 23 以下），也可能是短链服务
       * 只接受自动跟随。换「让系统自己跟」再试一次，落地页正文里照样有 id。
       */
      networkFailed = true;
      try {
        resp = await httpGet(current);
      } catch (retryFailure) {
        return { url: current, link: null, networkFailed: true };
      }
    }
    if (resp === null) {
      return { url: current, link: null, networkFailed: true };
    }
    let step: HopResult = hopOf(resp, current, fallbackSource);
    if (step.link === null && step.next.length === 0 && isRedirect(resp.statusCode)) {
      // 3xx 但没给 Location：让系统自己跟一次，再看落地页（QQ 偶尔只回一个空 302）
      try {
        const auto: LxResponse = await httpGet(current);
        step = hopOf(auto, current, fallbackSource);
      } catch (e) {
        networkFailed = true;
      }
    }
    if (step.link !== null) {
      return { url: step.next.length > 0 ? step.next : current, link: step.link, networkFailed: networkFailed };
    }
    if (step.next.length === 0) {
      return { url: current, link: null, networkFailed: networkFailed };
    }
    current = step.next;
  }
  return { url: current, link: matchUrl(current), networkFailed: networkFailed };
}

/**
 * 跟随短链拿到最终地址（老接口，保留给「只想看最终地址」的调用方）
 *
 * 解析歌单请直接用 resolveShareText：它走的是 followShortLink，能在**第一跳**就
 * 从 Location 里认出 id，不必等落地页。
 */
export async function followRedirect(url: string): Promise<string> {
  const outcome: ShortLinkOutcome = await followShortLink(url, platformOfUrl(url));
  return outcome.url;
}

/**
 * 解析分享文本（失败时抛出可直接展示给用户的说明）
 *
 * 本地正则解析不出来、但文本里有链接时，跟随短链再试 —— 这是洛雪遇到
 * 163cn.tv / c.migu.cn / t1.kugou.com 这类分享短链时的做法。
 *
 * **QQ 音乐客户端分享出来的短链**（`c6.y.qq.com/base/fcgi-bin/u?__=xxx`）是群反馈里
 * 最容易失败的一类：2026-11-19 用户截图「没能从QQ链接里找到歌单 id」。现在的口径是：
 *   1. 带桌面 UA 请求短链，自己跟 302（`maxRedirects: 0`），**每一跳的 Location 都先认 id**；
 *   2. 认不出就退到「系统自动跟随 + 从落地页正文抠 id / 规范地址」；
 *   3. 仍然不行时给一句能照着做的提示（换成歌单页长链接，附长链例子），
 *      不再甩一句「请确认是歌单的分享链接」让用户自己猜。
 */
export async function resolveShareText(text: string): Promise<PlaylistLink> {
  const raw: string = text.trim();
  if (raw.length === 0) {
    throw new Error('请先粘贴歌单分享链接');
  }
  const local: PlaylistLink | null = parseShareText(raw);
  if (local !== null) {
    return local;
  }
  const url: string = firstUrl(raw);
  if (url.length === 0) {
    throw new Error('没找到链接。请把歌单分享内容整段粘贴进来（例如「分享歌单《xxx》https://...」）');
  }
  // 单曲 / 专辑链接先直接说清楚，不必为它白跑一次短链请求
  const known: string = platformOfUrl(url);
  if (known.length > 0 && looksLikeSongLink(url)) {
    throw new Error(`这是${platformName(known)}的单曲链接，不是歌单链接。请在歌单页面右上角「分享」里复制链接`);
  }
  const outcome: ShortLinkOutcome = await followShortLink(url, known);
  if (outcome.link !== null) {
    return outcome.link;
  }
  const finalUrl: string = outcome.url.length > 0 ? outcome.url : url;
  const finalSource: string = platformOfUrl(finalUrl);
  const source: string = finalSource.length > 0 ? finalSource : known;
  if (source.length === 0) {
    throw new Error('暂不支持这个平台，目前支持网易云 / QQ / 酷狗 / 酷我 / 咪咕的歌单链接');
  }
  if (looksLikeSongLink(finalUrl)) {
    throw new Error(`这是${platformName(source)}的单曲链接，不是歌单链接。请在歌单页右上角「分享」里复制链接`);
  }
  if (source === 'tx' && isQqShortLink(url)) {
    throw new Error(qqShortLinkMessage(outcome.networkFailed));
  }
  throw new Error(`没能从${platformName(source)}链接里找到歌单 id。`
    + `短链可能已经失效，或者跳到了一个不含歌单 id 的页面；请换成歌单页的长链接再试`
    + `${longListLinkExample(source)}`);
}

/** QQ 音乐客户端分享出来的短链（`c6.y.qq.com/base/fcgi-bin/u?__=` 这种） */
function isQqShortLink(url: string): boolean {
  const lower: string = url.toLowerCase();
  return lower.indexOf('c6.y.qq.com/base/fcgi-bin/u') >= 0
    || lower.indexOf('c.y.qq.com/base/fcgi-bin/u') >= 0
    || lower.indexOf('i.y.qq.com/base/fcgi-bin/u') >= 0;
}

/**
 * QQ 短链跟完还是没 id 时的提示
 *
 * @param networkFailed true = 请求本身就失败了（断网 / 被拒），提示先检查网络；
 *                      false = 请求成功但落地页里没有 id（多半被跳到了下载页），
 *                      提示换长链接。两种原因给用户的动作不一样，别混成一句。
 */
function qqShortLinkMessage(networkFailed: boolean): string {
  if (networkFailed) {
    return '这条 QQ 音乐分享短链没能打开（网络不通或被服务器拒绝）。请检查网络后重试；'
      + '也可以让朋友在电脑上打开这个链接，把跳转后地址栏里的歌单页地址发给你'
      + '（形如 https://y.qq.com/n/ryqq/playlist/7525892127）。';
  }
  return '这条 QQ 音乐客户端分享的短链跳到了一个不含歌单 id 的页面（常见是被跳到了「下载客户端」页）。'
    + '请在电脑浏览器里打开这个链接，等它跳到歌单页后把地址栏里的地址复制过来'
    + '（形如 https://y.qq.com/n/ryqq/playlist/7525892127）；'
    + '或者把歌单转发到微信，再从微信里复制链接（群友验证过那样拿到的是长链接）。';
}

/** 给「换成什么长链接」一个能照着抄的例子 */
function longListLinkExample(source: string): string {
  switch (source) {
    case 'tx':
      return '（QQ 音乐的长链接形如 https://y.qq.com/n/ryqq/playlist/7525892127）';
    case 'wy':
      return '（网易云的长链接形如 https://music.163.com/#/playlist?id=2102211118）';
    case 'kw':
      return '（酷我的长链接形如 https://www.kuwo.cn/playlist_detail/123456789）';
    case 'kg':
      return '（酷狗的长链接形如 https://www.kugou.com/yy/special/single/123456789.html）';
    case 'mg':
      return '（咪咕的长链接形如 https://music.migu.cn/v3/music/playlist/123456789）';
    default:
      return '';
  }
}

/**
 * 从落地页正文里找歌单 id
 *
 * 常见写法：`"disstid":123456`、`disstid=123456`、`/playlist/123456`，
 * 还有 URL 编码过的一份（`%22dissid%22%3A%22123456%22`，分享页把 JSON 塞进参数时会出现）。
 * 只收 5 位以上纯数字：歌单 id 都是这个量级，短数字多半是别的参数（页码、版本号）。
 *
 * `id=` / `pid=` / `specialid=` 放在最后：它最宽松，前面几条能认出来就不该轮到它。
 */
function playlistIdFromHtml(body: string): string {
  if (body.length === 0) {
    return '';
  }
  const patterns: RegExp[] = [
    /(?:disstid|dissid|diss_id)["']?\s*[:=]\s*["']?(\d{5,})/i,
    /playlist\/(\d{5,})/i,
    /%22(?:dissid|disstid)%22%3A%22(\d{5,})%22/i,
    /[?&](?:id|pid|specialid)=(\d{5,})/i,
  ];
  for (const pattern of patterns) {
    const matched: RegExpMatchArray | null = body.match(pattern);
    if (matched !== null && matched[1] !== undefined) {
      return matched[1];
    }
  }
  return '';
}
