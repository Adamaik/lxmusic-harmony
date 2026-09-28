import { hilog } from '@kit.PerformanceAnalysisKit';
import { asObjectArray, asRecord, asString, httpGetJson, httpPostJson } from './PlatformHttp';

const DOMAIN: number = 0x0001;
const TAG: string = 'MusicSuggest';

/**
 * 搜索联想词 + 热门搜索（照洛雪）
 *
 * 洛雪把这两件事按平台拆成 `{kw,kg,tx,wy,mg}/tipSearch.js`（输入时的联想）与
 * `hotSearch.js`（空搜索框时的热搜词），界面侧是 `SearchTipList` / `BlankView`。
 * 这里把「搜索框输入歌名时给出不同歌手、不同版本」那条链路移植过来 ——
 * 联想词里最有用的正是 `歌名 - 歌手` 这种（QQ / 咪咕给的就是这种），
 * 打「晴天」时能一眼看到《晴天 - 周杰伦》《晴天 - Lucky小爱》……，点一下就直接搜。
 *
 * 覆盖情况（2026-09-29 实测）：
 *   - 联想：酷我 ✓（RELWORD，含「晴天伴奏」这类版本词）、酷狗 ✓、QQ ✓
 *   - 热搜：酷我 ✓、酷狗 ✓（`hot_tab`，签名还是老的但实测能用）、QQ ✓
 *   - 咪咕：suggest 接口已下线（返回前端页面 HTML），热搜域名也变了 —— 不接
 *   - 网易：联想要走 weapi 加密，而它的搜索链路本身就 404（见 DEFECTS D-001）—— 不接
 *
 * 失败一律静默（联想词是「锦上添花」，接口挂了不该在输入框下面报错），只写日志。
 *
 * 合并口径见 mergeLists：多平台**轮流取一条**，不是一家接一家拼。
 */

/** 有联想的平台，顺序即合并顺序 */
export const SUGGEST_PLATFORMS: string[] = ['kw', 'kg', 'tx'];
/** 有热搜词的平台 */
export const HOT_PLATFORMS: string[] = ['kw', 'kg', 'tx'];

/** 每个平台最多取几条联想词 */
const PER_PLATFORM_SUGGEST: number = 6;
/** 联想词总数上限（太长的列表会把结果区顶满） */
const MAX_SUGGEST: number = 12;
/** 每个平台最多取几条热搜词 */
const PER_PLATFORM_HOT: number = 4;
/** 热搜词总数上限 */
const MAX_HOT: number = 12;

const KW_UA: string = 'Dalvik/2.1.0 (Linux; U; Android 9;)';

/**
 * 热搜词缓存（本次会话）
 *
 * 热搜词是「打开搜索页看一眼」的东西，一次就够；每次进页面都打三个接口是白费流量。
 * 只放内存：重启进程重新取（那时词也多半变了）。
 */
let hotCache: string[] = [];

/**
 * 去重用的归一化键：忽略空格、连字符与大小写
 *
 * 同一个词各平台写法不一样：酷我「晴天 DJ」/ 酷狗「晴天 dj」、酷我「晴天周杰伦」/
 * 酷狗「晴天 周杰伦」、酷我「夜曲 周杰伦」/ QQ「夜曲 - 周杰伦」。按原样去重的话
 * 这些会各占一行 —— 列表只有十来行，每一行都该是能点出不同结果的词。
 * 词序不同不算同一个（「夜曲 周杰伦」与「周杰伦 夜曲」照旧各留一条）。
 */
function wordKey(word: string): string {
  return word.replace(/[\s\-—–/／]/g, '').toLowerCase();
}

/** 把词加进结果（去重、去空白、到上限就停） */
function pushWord(out: string[], seen: Set<string>, word: string, limit: number): void {
  if (out.length >= limit) {
    return;
  }
  const trimmed: string = word.trim();
  if (trimmed.length === 0) {
    return;
  }
  const key: string = wordKey(trimmed);
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  out.push(trimmed);
}

/**
 * 各平台的结果按「轮流取一条」交错合并
 *
 * 不能一个平台接一个平台地拼：酷我一家就能回 6 条关键词补全（「晴天」「晴天伴奏」…），
 * 排完就到上限了，而「同一首歌有哪些歌手唱过」这种最有用的信息恰恰在 QQ 那几条
 * （`歌名 - 歌手`）里 —— 轮到它的时候列表已经满了。轮流取一条，每家最像的那条都能露脸。
 */
function mergeLists(lists: string[][], limit: number): string[] {
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  let depth: number = 0;
  let more: boolean = true;
  while (more && out.length < limit) {
    more = false;
    for (let i = 0; i < lists.length; i++) {
      if (depth >= lists[i].length) {
        continue;
      }
      more = true;
      pushWord(out, seen, lists[i][depth], limit);
    }
    depth++;
  }
  return out;
}

// ------------------------------------------------------------------ 酷我 kw

async function suggestKw(str: string): Promise<string[]> {
  const url: string =
    'https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox' +
    `&w=${encodeURIComponent(str)}&encoding=utf8&rformat=json`;
  const body: Record<string, Object> =
    await httpGetJson(url, { 'Referer': 'http://www.kuwo.cn/' }, '酷我联想');
  const items: Object[] = asObjectArray(body['WORDITEMS']);
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const raw of items) {
    pushWord(out, seen, asString(asRecord(raw)['RELWORD']), PER_PLATFORM_SUGGEST);
  }
  return out;
}

async function hotKw(): Promise<string[]> {
  const url: string =
    'http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2' +
    '&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0' +
    '&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1';
  const body: Record<string, Object> =
    await httpGetJson(url, { 'User-Agent': KW_UA }, '酷我热搜');
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const raw of asObjectArray(body['tagvalue'])) {
    pushWord(out, seen, asString(asRecord(raw)['key']), PER_PLATFORM_HOT);
  }
  return out;
}

// ------------------------------------------------------------------ 酷狗 kg

async function suggestKg(str: string): Promise<string[]> {
  const url: string =
    `https://searchtip.kugou.com/getSearchTip?MusicTipCount=${PER_PLATFORM_SUGGEST}` +
    `&keyword=${encodeURIComponent(str)}`;
  const body: Record<string, Object> =
    await httpGetJson(url, { 'referer': 'https://www.kugou.com/' }, '酷狗联想');
  // 结构是 { status, data: [{ RecordDatas: [{ HintInfo }] }] }（洛雪的 createHttpFetch
  // 会先把 body.data 取出来，所以它那边看着像顶层数组 —— 这里要自己下到 data）
  const groups: Object[] = asObjectArray(body['data']);
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  if (groups.length > 0) {
    for (const raw of asObjectArray(asRecord(groups[0])['RecordDatas'])) {
      pushWord(out, seen, asString(asRecord(raw)['HintInfo']), PER_PLATFORM_SUGGEST);
    }
  }
  return out;
}

async function hotKg(): Promise<string[]> {
  const url: string =
    'http://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd' +
    '&appid=1005&clientver=10026&plat=0';
  const headers: Record<string, string> = {
    'dfid': '1ssiv93oVqMp27cirf2CvoF1',
    'mid': '156798703528610303473757548878786007104',
    'clienttime': '1584257267',
    'x-router': 'msearch.kugou.com',
    'user-agent': 'Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi',
    'kg-rc': '1',
  };
  const body: Record<string, Object> = await httpGetJson(url, headers, '酷狗热搜');
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  // 「热搜榜」这一组的 keywords 就是词；后面还有别的榜，按顺序取到上限为止
  for (const group of asObjectArray(asRecord(body['data'])['list'])) {
    for (const raw of asObjectArray(asRecord(group)['keywords'])) {
      pushWord(out, seen, asString(asRecord(raw)['keyword']), PER_PLATFORM_HOT);
      if (out.length >= PER_PLATFORM_HOT) {
        break;
      }
    }
    if (out.length >= PER_PLATFORM_HOT) {
      break;
    }
  }
  return out;
}

// ------------------------------------------------------------------ QQ tx

/** QQ 的联想给的是 `歌名 - 歌手`，正是「同一首歌有哪些歌手唱过」最直接的来源 */
async function suggestTx(str: string): Promise<string[]> {
  const url: string =
    'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json' +
    `&key=${encodeURIComponent(str)}&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8` +
    '&notice=0&platform=yqq&needNewCode=0';
  const body: Record<string, Object> =
    await httpGetJson(url, { 'Referer': 'https://y.qq.com/portal/player.html' }, 'QQ联想');
  if (asString(body['code']) !== '0') {
    throw new Error(`QQ 联想接口返回 code ${asString(body['code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const song: Record<string, Object> = asRecord(data['song']);
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const raw of asObjectArray(song['itemlist'])) {
    const item: Record<string, Object> = asRecord(raw);
    const name: string = asString(item['name']);
    const singer: string = asString(item['singer']);
    // 只留「歌名 - 歌手」；歌手缺失时退回歌名（总比丢掉这条强）
    pushWord(out, seen, singer.length > 0 ? `${name} - ${singer}` : name, PER_PLATFORM_SUGGEST);
  }
  return out;
}

async function hotTx(): Promise<string[]> {
  const comm: Record<string, Object> = {
    'ct': '19',
    'cv': '1803',
    'guid': '0',
    'patch': '118',
    'psrf_access_token_expiresAt': 0,
    'psrf_qqaccess_token': '',
    'psrf_qqopenid': '',
    'psrf_qqunionid': '',
    'tmeAppID': 'qqmusic',
    'tmeLoginType': 0,
    'uin': '0',
    'wid': '0',
  };
  // 嵌套的对象字面量要先单独声明（ArkTS 不收没声明类型的字面量）
  const param: Record<string, Object> = { 'search_id': '', 'uin': 0 };
  const hotkey: Record<string, Object> = {
    'method': 'GetHotkeyForQQMusicPC',
    'module': 'tencent_musicsoso_hotkey.HotkeyService',
    'param': param,
  };
  const body: Record<string, Object> = {};
  body['comm'] = comm;
  body['hotkey'] = hotkey;
  const resp: Record<string, Object> = await httpPostJson(
    'https://u.y.qq.com/cgi-bin/musicu.fcg', body,
    { 'Referer': 'https://y.qq.com/portal/player.html' }, 'QQ热搜');
  if (asString(resp['code']) !== '0') {
    throw new Error(`QQ 热搜接口返回 code ${asString(resp['code'])}`);
  }
  const data: Record<string, Object> = asRecord(asRecord(resp['hotkey'])['data']);
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const raw of asObjectArray(data['vec_hotkey'])) {
    pushWord(out, seen, asString(asRecord(raw)['query']), PER_PLATFORM_HOT);
  }
  return out;
}

// ------------------------------------------------------------------ 入口

/** 单个平台的联想（失败返回空数组，不抛） */
async function suggestOne(keyword: string, source: string): Promise<string[]> {
  try {
    if (source === 'kw') {
      return await suggestKw(keyword);
    }
    if (source === 'kg') {
      return await suggestKg(keyword);
    }
    if (source === 'tx') {
      return await suggestTx(keyword);
    }
    return [];
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '%{public}s suggest failed: %{public}s', source, (e as Error).message);
    return [];
  }
}

/** 单个平台的热搜（失败返回空数组，不抛） */
async function hotOne(source: string): Promise<string[]> {
  try {
    if (source === 'kw') {
      return await hotKw();
    }
    if (source === 'kg') {
      return await hotKg();
    }
    if (source === 'tx') {
      return await hotTx();
    }
    return [];
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '%{public}s hot search failed: %{public}s', source, (e as Error).message);
    return [];
  }
}

/**
 * 输入关键词时的联想词（多平台交错合并、去重）
 *
 * 返回的每一行都可以直接当搜索关键词用（`歌名 - 歌手` 也是）—— 点了就照它搜。
 * 一个平台都没有结果时返回空数组，界面据此显示「回车直接搜」。
 */
export async function suggestMusic(
  keyword: string,
  sources: string[] = SUGGEST_PLATFORMS,
): Promise<string[]> {
  const str: string = keyword.trim();
  if (str.length === 0) {
    return [];
  }
  const tasks: Promise<string[]>[] = [];
  for (let i = 0; i < sources.length; i++) {
    tasks.push(suggestOne(str, sources[i]));
  }
  const settled: PromiseSettledResult<string[]>[] = await Promise.allSettled(tasks);
  const lists: string[][] = [];
  for (const result of settled) {
    lists.push(result.status === 'fulfilled' ? result.value : []);
  }
  return mergeLists(lists, MAX_SUGGEST);
}

/** 热门搜索词（多平台交错合并、去重；本次会话只取一次） */
export async function hotSearchWords(
  sources: string[] = HOT_PLATFORMS,
): Promise<string[]> {
  if (hotCache.length > 0) {
    return hotCache;
  }
  const tasks: Promise<string[]>[] = [];
  for (let i = 0; i < sources.length; i++) {
    tasks.push(hotOne(sources[i]));
  }
  const settled: PromiseSettledResult<string[]>[] = await Promise.allSettled(tasks);
  const lists: string[][] = [];
  for (const result of settled) {
    lists.push(result.status === 'fulfilled' ? result.value : []);
  }
  const out: string[] = mergeLists(lists, MAX_HOT);
  // 全部平台都没拿到就别缓存了：下次进页面再试一次（网络恢复后还能补上）
  if (out.length > 0) {
    hotCache = out;
  }
  return out;
}
