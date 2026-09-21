import { LxResponse, lxRequest } from '../source/LxHttp';
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
 */
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
  return /^\d+$/.test(target) ? makeLink(source, target, '') : null;
}

/** 直接由「平台 + 歌单 id」造一条链接（从在线歌单详情页导入时用，不需要解析） */
export function linkOf(source: string, id: string): PlaylistLink {
  return makeLink(source, id, '');
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

function httpGet(url: string, maxRedirects: number): Promise<LxResponse> {
  return new Promise<LxResponse>((resolve: (resp: LxResponse) => void,
    reject: (err: Error) => void) => {
    lxRequest(url, { maxRedirects: maxRedirects, rawText: true, timeout: REDIRECT_TIMEOUT },
      (resp: LxResponse) => {
        resolve(resp);
      },
      (message: string) => {
        reject(new Error(message));
      });
  });
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
 * 跟随短链拿到最终地址（洛雪各平台 handleParseId 的那一步）
 *
 * 这里不用系统的自动重定向：跟完了读不到最终地址（响应里的 url 只是请求地址），
 * 所以关掉自动跳转（maxRedirects: 0），自己从 Location / HTML 里取下一跳。
 */
export async function followRedirect(url: string): Promise<string> {
  let current: string = url;
  for (let hop = 0; hop < MAX_REDIRECT_HOP; hop++) {
    const resp: LxResponse = await httpGet(current, 0);
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      const location: string = locationOf(resp);
      if (location.length === 0) {
        return current;
      }
      current = absoluteUrl(current, location);
      continue;
    }
    const jumped: string = htmlJumpTarget(resp);
    if (jumped.length === 0) {
      return current;
    }
    current = absoluteUrl(current, jumped);
  }
  return current;
}

/**
 * 解析分享文本（失败时抛出可直接展示给用户的说明）
 *
 * 本地正则解析不出来、但文本里有链接时，跟一次短链再试 —— 这是洛雪遇到
 * 163cn.tv / c.migu.cn / t1.kugou.com 这类分享短链时的做法。
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
  let finalUrl: string = '';
  try {
    finalUrl = await followRedirect(url);
  } catch (e) {
    // 短链服务器不通不该盖住真正的原因，往下按「认不出平台」给提示
    finalUrl = '';
  }
  if (finalUrl.length > 0 && finalUrl !== url) {
    const retried: PlaylistLink | null = parseShareText(finalUrl);
    if (retried !== null) {
      return retried;
    }
  }
  const source: string = platformOfUrl(finalUrl.length > 0 ? finalUrl : url);
  if (source.length === 0) {
    throw new Error('暂不支持这个平台，目前支持网易云 / QQ / 酷狗 / 酷我 / 咪咕的歌单链接');
  }
  if (looksLikeSongLink(finalUrl.length > 0 ? finalUrl : url)) {
    throw new Error(`这是${platformName(source)}的单曲链接，不是歌单链接。请在歌单页右上角「分享」里复制链接`);
  }
  throw new Error(`没能从${platformName(source)}链接里找到歌单 id，请确认是歌单的分享链接`);
}
