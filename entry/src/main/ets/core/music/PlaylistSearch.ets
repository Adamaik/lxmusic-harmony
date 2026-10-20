import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
import { LxPlaylistItem, descText } from './MusicList';
import { MG_DEVICE_ID, QS_APP_HEADERS, createMgSignature, decodeName, qsCoverOf,
  qsDeviceQuery, similar } from './MusicSearch';

/**
 * 内置「歌单搜索」（宿主侧）
 *
 * 为什么单独一个文件：搜索页原来只有「歌曲 / 歌手」两维，歌单只在推荐页的歌单广场
 * 与分类页里出现，想按关键词找一张歌单没有入口。洛雪那边其实有这一维
 * （`src/core/search/songlist.ts` + 各平台 `songList.js` 的 `search()`），
 * 这里照着五个平台移植成 ArkTS，界面仍然是「一次搜全部平台、合起来排」的那一套。
 *
 * 与歌曲搜索的关系：只负责拿到歌单卡片（`LxPlaylistItem`），点开之后的歌单详情
 * 照旧走 `MusicList.getPlaylistDetailAll`（那条链路早就有了，D-002 修过 QQ 的新版接口）。
 *
 * 各平台接口（2026-10-20 宿主机实测均可用）：
 *   kw  `search.kuwo.cn/r.s?...&ft=playlist`（响应是**单引号**的 JS 对象，要自己转 JSON）
 *   kg  `msearchretry.kugou.com/api/v3/search/special`
 *   mg  `jadeite.migu.cn/music_search/v3/search/searchAll`，`searchSwitch.songlist=1`
 *   tx  `c.y.qq.com/soso/fcgi-bin/client_music_search_songlist`（要带 UA / Referer）
 *   wy  明文 GET `music.163.com/api/search/get/web?type=1000`（与歌单广场同一条明文接口）
 *   qs  汽水 App 侧 POST `beta-luna.douyin.com/luna/search/playlist`（与单曲搜索同主机，免登录）
 */

/** 支持歌单搜索的平台（与内置歌曲搜索、歌单广场一致） */
export const PLAYLIST_SEARCH_PLATFORMS: string[] = ['kw', 'kg', 'mg', 'tx', 'wy', 'qs'];

/** 单个平台一页歌单的搜索结果 */
export interface LxPlaylistPlatformResult {
  source: string;
  items: LxPlaylistItem[];
  /** 该平台报的命中总数；接口没给就是 0 */
  total: number;
  /** 总页数（永远 >= page） */
  allPage: number;
  /** 接口不通时的原因（成功为空串；有值时 items 一定是空的） */
  error: string;
}

/** 一次聚合搜索的结果：合并后的列表 + 逐平台明细（状态行与翻页用） */
export interface LxPlaylistOutcome {
  items: LxPlaylistItem[];
  platforms: LxPlaylistPlatformResult[];
  page: number;
  maxPage: number;
  total: number;
}

/** 按相似度排时用的一条中间记录 */
interface ScoredPlaylist {
  item: LxPlaylistItem;
  score: number;
}

// ------------------------------------------------------------------ 取值工具

function asString(v: Object | undefined): string {
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

function asNumber(v: Object | undefined): number {
  if (typeof v === 'number') {
    return v as number;
  }
  const n: number = Number.parseInt(asString(v), 10);
  return Number.isNaN(n) ? 0 : n;
}

function asObjectArray(v: Object | undefined): Object[] {
  return Array.isArray(v) ? v as Object[] : [];
}

function asRecord(v: Object | undefined): Record<string, Object> {
  if (v === undefined || v === null) {
    return {};
  }
  if (typeof v === 'object' && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  return {};
}

/** 播放量 -> 「1.2万 / 3.4亿」（与歌单广场的显示口径一致） */
function formatPlayCount(num: number): string {
  if (num <= 0) {
    return '';
  }
  if (num > 100000000) {
    return `${Math.trunc(num / 10000000) / 10}亿`;
  }
  if (num > 10000) {
    return `${Math.trunc(num / 1000) / 10}万`;
  }
  return `${num}`;
}

/** 按总数算总页数；总数拿不到就按「这一页满没满」推（与 MusicSearch.pagesOf 同口径） */
function pagesOf(total: number, page: number, got: number, limit: number): number {
  if (got === 0 && page > 1) {
    return Math.max(1, page);
  }
  if (total > 0) {
    return Math.max(page, Math.ceil(total / limit));
  }
  return got >= limit ? page + 1 : page;
}

/** 发一个 GET，按纯文本拿响应体（酷我那家的响应不是严格 JSON） */
function requestText(url: string, headers?: Record<string, string>, timeout: number = 15000): Promise<string> {
  return new Promise<string>((resolve: (value: string) => void, reject: (reason: Error) => void) => {
    const options: LxRequestOptions = { method: 'get', timeout: timeout, rawText: true };
    if (headers !== undefined) {
      options.headers = headers;
    }
    lxRequest(url, options, (resp: LxResponse) => {
      const body = resp.body;
      if (typeof body === 'string') {
        resolve(body as string);
        return;
      }
      resolve(JSON.stringify(body));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

function parseRecord(text: string, label: string): Record<string, Object> {
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, Object>;
    }
  } catch (e) {
    // 落到下面统一报错
  }
  throw new Error(`${label}接口返回格式异常`);
}

/**
 * 酷我那个「单引号 JS 对象」-> 标准 JSON
 *
 * `r.s?rformat=json` 回的是 `{'TOTAL':'143','abslist':[...]}` 这种 JS 对象字面量，
 * 直接 JSON.parse 会炸。逐字符扫一遍：字符串里（单引号包着）的双引号转义成 \"，
 * 单引号本身换成双引号，其余原样 —— 比洛雪那条正则（用了 lookbehind）更好读，
 * 也不依赖 ArkTS 对正则后行断言的支持。
 */
function kwObjectTextToJson(text: string): string {
  let out: string = '';
  let inString: boolean = false;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (!inString) {
      if (ch === "'") {
        inString = true;
        out += '"';
        continue;
      }
      out += ch;
      continue;
    }
    if (ch === '\\') {
      const next: string = i + 1 < text.length ? text.charAt(i + 1) : '';
      if (next === "'") {
        // 单引号字符串里的 \' ：JSON 里写成裸的 '
        out += "'";
        i++;
        continue;
      }
      if (next === '"') {
        out += '\\"';
        i++;
        continue;
      }
      // 其余转义（\n、\uXXXX、\\…）两者写法一致，原样留着
      out += ch;
      continue;
    }
    if (ch === "'") {
      inString = false;
      out += '"';
      continue;
    }
    if (ch === '"') {
      out += '\\"';
      continue;
    }
    out += ch;
  }
  return out;
}

// ------------------------------------------------------------------ 酷我 kw

async function searchKwPlaylists(keyword: string, page: number, limit: number): Promise<LxPlaylistPlatformResult> {
  const url: string =
    `http://search.kuwo.cn/r.s?all=${encodeURIComponent(keyword)}&pn=${page - 1}&rn=${limit}` +
    '&rformat=json&encoding=utf8&ver=mbox&vipver=MUSIC_8.7.7.0_BCS37&plat=pc&devid=28156413' +
    '&ft=playlist&pay=0&needliveshow=0';
  const text: string = await requestText(url);
  const body: Record<string, Object> = parseRecord(kwObjectTextToJson(text), '酷我');
  const items: LxPlaylistItem[] = [];
  for (const raw of asObjectArray(body['abslist'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['playlistid']);
    if (id.length === 0) {
      continue;
    }
    items.push({
      id: id,
      name: decodeName(asString(item['name'])),
      author: decodeName(asString(item['nickname'])),
      img: asString(item['pic']),
      desc: descText(asString(item['intro'])),
      playCount: formatPlayCount(asNumber(item['playcnt'])),
      total: asNumber(item['songnum']),
      time: '',
      source: 'kw',
    });
  }
  const total: number = asNumber(body['TOTAL']);
  return { source: 'kw', items: items, total: total,
    allPage: pagesOf(total, page, items.length, limit), error: '' };
}

// ------------------------------------------------------------------ 酷狗 kg

async function searchKgPlaylists(keyword: string, page: number, limit: number): Promise<LxPlaylistPlatformResult> {
  const url: string =
    `http://msearchretry.kugou.com/api/v3/search/special?keyword=${encodeURIComponent(keyword)}` +
    `&page=${page}&pagesize=${limit}&showtype=10&filter=0&version=7910&sver=2`;
  const body: Record<string, Object> = parseRecord(await requestText(url), '酷狗');
  if (asNumber(body['errcode']) !== 0) {
    throw new Error(`酷狗接口返回 errcode ${asNumber(body['errcode'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const items: LxPlaylistItem[] = [];
  for (const raw of asObjectArray(data['info'])) {
    const item: Record<string, Object> = asRecord(raw);
    const specialId: string = asString(item['specialid']);
    if (specialId.length === 0) {
      continue;
    }
    // 与歌单详情约定的 id 形式一致（kgPlaylistDetail 会剥掉 id_ 前缀）
    items.push({
      id: `id_${specialId}`,
      name: asString(item['specialname']),
      author: asString(item['nickname']),
      img: asString(item['imgurl']),
      desc: descText(asString(item['intro'])),
      playCount: formatPlayCount(asNumber(item['playcount'])),
      total: asNumber(item['songcount']),
      time: '',
      source: 'kg',
    });
  }
  const total: number = asNumber(data['total']);
  return { source: 'kg', items: items, total: total,
    allPage: pagesOf(total, page, items.length, limit), error: '' };
}

// ------------------------------------------------------------------ 咪咕 mg

async function searchMgPlaylists(keyword: string, page: number, limit: number): Promise<LxPlaylistPlatformResult> {
  const time: string = Date.now().toString();
  const sign: string = createMgSignature(keyword, time);
  // searchSwitch 只开 songlist：这一路只要歌单（歌曲 / 歌手由歌曲搜索那一维去做）
  const url: string =
    'https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1' +
    '&searchSwitch=%7B%22song%22%3A0%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A0' +
    '%2C%22mvSong%22%3A0%2C%22bestShow%22%3A0%2C%22songlist%22%3A1%2C%22lyricSong%22%3A0%7D' +
    `&pageSize=${limit}&text=${encodeURIComponent(keyword)}&pageNo=${page}&sort=0&sid=USS`;
  const headers: Record<string, string> = {
    'uiVersion': 'A_music_3.6.1',
    'deviceId': MG_DEVICE_ID,
    'timestamp': time,
    'sign': sign,
    'channel': '0146921',
    'User-Agent': 'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
  };
  const body: Record<string, Object> = parseRecord(await requestText(url, headers), '咪咕');
  if (asString(body['code']) !== '000000') {
    throw new Error(asString(body['info']).length > 0 ? asString(body['info']) : '咪咕歌单搜索失败');
  }
  const songListData: Record<string, Object> = asRecord(body['songListResultData']);
  const items: LxPlaylistItem[] = [];
  for (const raw of asObjectArray(songListData['result'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['id']);
    if (id.length === 0) {
      continue;
    }
    let img: string = asString(item['musicListPicUrl']);
    if (img.length > 0 && !/^https?:\/\//i.test(img)) {
      img = `https://d.musicapp.migu.cn${img}`;
    }
    items.push({
      id: id,
      name: asString(item['name']),
      author: asString(item['userName']),
      img: img,
      desc: descText(asString(item['intro'])),
      playCount: formatPlayCount(asNumber(item['playNum'])),
      total: asNumber(item['musicNum']),
      time: '',
      source: 'mg',
    });
  }
  const total: number = asNumber(songListData['totalCount']);
  return { source: 'mg', items: items, total: total,
    allPage: pagesOf(total, page, items.length, limit), error: '' };
}

// ------------------------------------------------------------------ QQ tx

async function searchTxPlaylists(keyword: string, page: number, limit: number): Promise<LxPlaylistPlatformResult> {
  const url: string =
    'http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist' +
    `?page_no=${page - 1}&num_per_page=${limit}&format=json&query=${encodeURIComponent(keyword)}` +
    '&remoteplace=txt.yqq.playlist&inCharset=utf8&outCharset=utf-8';
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
    'Referer': 'http://y.qq.com/portal/search.html',
  };
  const body: Record<string, Object> = parseRecord(await requestText(url, headers), 'QQ');
  if (asNumber(body['code']) !== 0) {
    throw new Error(`QQ 接口返回 code ${asNumber(body['code'])}`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  const items: LxPlaylistItem[] = [];
  for (const raw of asObjectArray(data['list'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['dissid']);
    if (id.length === 0) {
      continue;
    }
    items.push({
      id: id,
      name: decodeName(asString(item['dissname'])),
      author: decodeName(asString(asRecord(item['creator'])['name'])),
      img: asString(item['imgurl']),
      desc: descText(asString(item['introduction'])),
      playCount: formatPlayCount(asNumber(item['listennum'])),
      total: asNumber(item['song_count']),
      time: '',
      source: 'tx',
    });
  }
  const total: number = asNumber(data['sum']);
  return { source: 'tx', items: items, total: total,
    allPage: pagesOf(total, page, items.length, limit), error: '' };
}

// ------------------------------------------------------------------ 网易 wy

/**
 * 网易的歌单搜索走**明文** GET（与歌单广场同一套思路，见 MusicList 顶部说明）：
 * `/api/search/get/web?type=1000` 不用 eapi 加密、不要登录，带 `Cookie: os=pc` 即可。
 * 歌曲搜索那条 eapi 链路仍是不通的（D-001），但这条是另一条接口，实测能回结果。
 */
const WY_SEARCH_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    + 'Chrome/60.0.3112.90 Safari/537.36',
  'Referer': 'https://music.163.com/',
  'Cookie': 'os=pc',
};

async function searchWyPlaylists(keyword: string, page: number, limit: number): Promise<LxPlaylistPlatformResult> {
  const offset: number = limit * (page - 1);
  const url: string =
    'https://music.163.com/api/search/get/web?csrf_token=' +
    `&s=${encodeURIComponent(keyword)}&type=1000&offset=${offset}&total=true&limit=${limit}`;
  const body: Record<string, Object> = parseRecord(await requestText(url, WY_SEARCH_HEADERS), '网易');
  const code: number = asNumber(body['code']);
  if (code !== 0 && code !== 200) {
    throw new Error(`网易接口返回 code ${code}`);
  }
  const result: Record<string, Object> = asRecord(body['result']);
  const items: LxPlaylistItem[] = [];
  for (const raw of asObjectArray(result['playlists'])) {
    const item: Record<string, Object> = asRecord(raw);
    const id: string = asString(item['id']);
    if (id.length === 0) {
      continue;
    }
    items.push({
      id: id,
      name: asString(item['name']),
      author: asString(asRecord(item['creator'])['nickname']),
      img: asString(item['coverImgUrl']),
      desc: descText(asString(item['description'])),
      playCount: formatPlayCount(asNumber(item['playCount'])),
      total: asNumber(item['trackCount']),
      time: '',
      source: 'wy',
    });
  }
  const total: number = asNumber(result['playlistCount']);
  return { source: 'wy', items: items, total: total,
    allPage: pagesOf(total, page, items.length, limit), error: '' };
}

// ------------------------------------------------------------------ 汽水 qs

/** 汽水 App 侧「歌单搜索」：与单曲搜索同一个主机、同一组设备参数，只是路径换成 playlist */
const QS_PLAYLIST_SEARCH_URL: string = 'https://beta-luna.douyin.com/luna/search/playlist';
const QS_PLAYLIST_PAGE_SIZE: number = 20;

/** 汽水歌单搜索的请求体（ArkTS 不允许无类型对象字面量） */
interface QsPlaylistSearchPayload {
  q: string;
  cursor: string;
  count: string;
  search_method: string;
}

/** 发一个 POST（JSON 体），按纯文本拿响应体 */
function requestJsonPost(url: string, headers: Record<string, string>,
  body: Object, timeout: number = 15000): Promise<string> {
  return new Promise<string>((resolve: (value: string) => void, reject: (reason: Error) => void) => {
    const options: LxRequestOptions = {
      method: 'post',
      timeout: timeout,
      headers: headers,
      body: body,
      rawText: true,
    };
    lxRequest(url, options, (resp: LxResponse) => {
      const respBody = resp.body;
      if (typeof respBody === 'string') {
        resolve(respBody as string);
        return;
      }
      resolve(JSON.stringify(respBody));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/** 汽水歌单的作者（发现式返回里多数不带，带的时候是 nickname / name） */
function qsPlaylistAuthor(pl: Record<string, Object>): string {
  const owner: Record<string, Object> = asRecord(pl['owner']);
  let name: string = asString(owner['nickname']);
  if (name.length === 0) {
    name = asString(owner['name']);
  }
  return name;
}

async function searchQsPlaylists(keyword: string, page: number,
  limit: number): Promise<LxPlaylistPlatformResult> {
  const cursor: number = (page - 1) * QS_PLAYLIST_PAGE_SIZE;
  const url: string = `${QS_PLAYLIST_SEARCH_URL}?${qsDeviceQuery()}`;
  const payload: QsPlaylistSearchPayload = {
    q: keyword,
    cursor: `${cursor}`,
    count: `${QS_PLAYLIST_PAGE_SIZE}`,
    search_method: 'input',
  };
  const body: Record<string, Object> =
    parseRecord(await requestJsonPost(url, QS_APP_HEADERS, payload), '汽水');
  const items: LxPlaylistItem[] = [];
  let hasMore: boolean = false;
  for (const groupRaw of asObjectArray(body['result_groups'])) {
    const group: Record<string, Object> = asRecord(groupRaw);
    if (group['has_more'] === true) {
      hasMore = true;
    }
    for (const rowRaw of asObjectArray(group['data'])) {
      const entity: Record<string, Object> = asRecord(asRecord(rowRaw)['entity']);
      const pl: Record<string, Object> = asRecord(entity['playlist']);
      const id: string = asString(pl['id']);
      if (id.length === 0) {
        continue;
      }
      items.push({
        id: id,
        name: asString(pl['title']),
        author: qsPlaylistAuthor(pl),
        img: qsCoverOf(asRecord(pl['url_cover'])),
        desc: descText(asString(pl['desc'])),
        // 汽水给的是收藏数，不是播放量：不冒充，卡片退成显示作者
        playCount: '',
        total: asNumber(pl['count_tracks']),
        time: '',
        source: 'qs',
      });
    }
  }
  const list: LxPlaylistItem[] = items.slice(0, limit);
  const allPage: number = hasMore ? page + 1 : page;
  return { source: 'qs', items: list, total: 0, allPage: allPage, error: '' };
}

// ------------------------------------------------------------------ 聚合

/** 搜单个平台的一页歌单；接口不通一律抛错（界面据此如实说「某某平台失败」） */
export async function searchPlaylistPage(
  keyword: string,
  source: string,
  page: number = 1,
  limit: number = 30,
): Promise<LxPlaylistPlatformResult> {
  const text: string = keyword.trim();
  if (text.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  if (source === 'kw') {
    return await searchKwPlaylists(text, page, limit);
  }
  if (source === 'kg') {
    return await searchKgPlaylists(text, page, limit);
  }
  if (source === 'mg') {
    return await searchMgPlaylists(text, page, limit);
  }
  if (source === 'tx') {
    return await searchTxPlaylists(text, page, limit);
  }
  if (source === 'wy') {
    return await searchWyPlaylists(text, page, limit);
  }
  if (source === 'qs') {
    return await searchQsPlaylists(text, page, limit);
  }
  throw new Error(`这个平台不支持歌单搜索：${source}`);
}

/** 歌单列表去重：同一张歌单在翻页时可能重复出现，键用「平台 + 歌单 id」 */
export function dedupePlaylists(items: LxPlaylistItem[]): LxPlaylistItem[] {
  const out: LxPlaylistItem[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of items) {
    const key: string = `${item.source}_${item.id}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(item);
  }
  return out;
}

/**
 * 按与关键词的相似度排：与歌曲搜索同一套 `similar`（歌单名 + 作者）。
 * 歌单名里命中关键词的排前面；相似度相同就保持平台顺序（稳定）。
 */
export function sortPlaylistsByRelevance(items: LxPlaylistItem[], keyword: string): LxPlaylistItem[] {
  const scored: ScoredPlaylist[] = [];
  for (const item of items) {
    scored.push({ item: item, score: similar(keyword, `${item.name} ${item.author}`) });
  }
  // 插入排序：列表长度只有几百条，稳定排序比 Array.sort 更适合「同分保持原顺序」
  for (let i = 1; i < scored.length; i++) {
    const current: ScoredPlaylist = scored[i];
    let j: number = i - 1;
    while (j >= 0 && scored[j].score < current.score) {
      scored[j + 1] = scored[j];
      j--;
    }
    scored[j + 1] = current;
  }
  const out: LxPlaylistItem[] = [];
  for (const one of scored) {
    out.push(one.item);
  }
  return out;
}

/**
 * 一次问所有平台的歌单（与 searchMusicAll 同构）
 *
 * 单个平台失败不影响其它平台：失败原因收在 platforms[].error 里，界面照旧在状态行
 * 写「某某平台失败」，不会把「接口挂了」伪装成「没有歌单」。
 */
export async function searchPlaylistsAll(
  keyword: string,
  platforms: string[],
  page: number = 1,
  limit: number = 30,
): Promise<LxPlaylistOutcome> {
  const text: string = keyword.trim();
  if (text.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  const tasks: Promise<LxPlaylistPlatformResult>[] = [];
  for (const source of platforms) {
    tasks.push(searchPlaylistPage(text, source, page, limit).catch((e: Error) => {
      const failed: LxPlaylistPlatformResult = {
        source: source,
        items: [],
        total: 0,
        allPage: page,
        error: e.message,
      };
      return failed;
    }));
  }
  const settled: LxPlaylistPlatformResult[] = await Promise.all(tasks);
  let merged: LxPlaylistItem[] = [];
  let maxPage: number = page;
  let total: number = 0;
  for (const result of settled) {
    if (result.error.length === 0) {
      merged = merged.concat(result.items);
    }
    if (result.allPage > maxPage) {
      maxPage = result.allPage;
    }
    total += result.total;
  }
  return {
    items: sortPlaylistsByRelevance(dedupePlaylists(merged), text),
    platforms: settled,
    page: page,
    maxPage: maxPage,
    total: total,
  };
}
