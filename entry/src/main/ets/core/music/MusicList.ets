import { LxRequestOptions, lxRequest } from '../source/LxHttp';
import {
  aes128EcbPkcs7EncryptBytes,
  fromBase64,
  md5Hex,
  toBase64,
  utf8Bytes,
} from './LxCrypto';
import { decodeAes128EcbPkcs7Text } from './PlatformCrypto';
import {
  LxMusicInfo,
  LxQualityItem,
  QS_APP_HEADERS,
  appendWyExtendQualities,
  decodeName,
  formatPlayTime,
  formatSingerName,
  mgImageUrl,
  qsCoverOf,
  qsDeviceQuery,
  qsTrackToInfo,
  sizeFormate,
} from './MusicSearch';
import { musicIdOf } from './MusicId';

/**
 * 内置「歌单广场 / 排行榜」（宿主侧）
 *
 * 为什么需要它：与搜索同理，洛雪自定义源的协议里只有 musicUrl / lyric / pic，
 * 歌单与排行榜来自洛雪 App 内置的平台 SDK（src/utils/musicSdk/{kw,kg,tx,wy,mg}/
 * songList.js 与 leaderboard.js），所以这里把那部分逻辑移植到 ArkTS。
 *
 * 与搜索的关系：这边只负责「拿到一份 musicInfo 列表」，播放链接照旧交给导入的源规则解析。
 * 榜单列表（getBoards）在洛雪里就是各平台写死的数组，这里一并照搬（只保留有名字的前若干条）。
 *
 * ⚠️ 网易(wy)：洛雪走 weapi（AES-CBC 双层 + RSA）与 linuxapi，本工程没有移植这套
 * 签名（RSA 未实现），且洛雪那边的 wy 端点已被标记为过期。这里改用网易的明文 web 接口
 * （/api/playlist/list、/api/v6/playlist/detail、/api/song/detail）做「尽力而为」的实现，
 * 可能失效；失效时界面会显示该平台的错误信息，不影响其它来源。
 *
 * 明文接口有两个坑，细节见 WY_HEADERS 与 wyPlaylistDetail 的注释：请求必须带
 * `Cookie: os=pc`，且取歌要以 `trackIds` 为准（`tracks` 会被砍成开头的试听预览）。
 */

// ------------------------------------------------------------------ 类型

/** 歌单页的排序页签（对应洛雪 sortList） */
export interface LxSortItem {
  name: string;
  tid: string;
  id: string;
}

/** 歌单广场/推荐里的一条歌单 */
export interface LxPlaylistItem {
  id: string;
  name: string;
  author: string;
  img: string;
  desc: string;
  playCount: string;
  total: number;
  time: string;
  source: string;
}

/** 排行榜里的一张榜 */
export interface LxBoardItem {
  id: string;
  name: string;
  bangid: string;
  source: string;
}

/** 歌单/榜单的附加信息 */
export interface LxListInfo {
  name: string;
  img: string;
  desc: string;
  author: string;
  playCount: string;
}

/** 歌单/榜单的歌曲页 */
export interface LxListDetail {
  list: LxMusicInfo[];
  total: number;
  info: LxListInfo;
}

/** 「在线歌单 / 在线榜单」详情页的路由参数 */
export interface OnlineRoute {
  /** 'playlist' = 歌单，'board' = 榜单 */
  kind: string;
  source: string;
  id: string;
  name: string;
  cover: string;
}

/** 支持歌单广场与排行榜的平台（与内置搜索保持一致） */
export const LIST_PLATFORMS: string[] = ['kw', 'kg', 'mg', 'tx', 'wy', 'qs'];

export const PLATFORM_NAMES: Record<string, string> = {
  'kw': '酷我',
  'kg': '酷狗',
  'mg': '咪咕',
  'tx': 'QQ',
  'wy': '网易',
  // 汽水音乐：只有内置搜索与播放（见 MusicSearch 的 qs 分支），歌单广场 / 榜单没接
  'qs': '汽水',
};

export function platformName(id: string): string {
  const name: string = PLATFORM_NAMES[id];
  return name !== undefined ? name : id;
}

export function isListSupported(source: string): boolean {
  return LIST_PLATFORMS.includes(source);
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

/**
 * 歌单简介的展示文本
 *
 * 各平台回的简介都是 HTML 片段：酷我直接用 `<br><br>` 分段，酷狗整段带标签，
 * QQ 是 `<br>`，网易偶尔夹实体。直接塞给 Text 会把 `<br>` 当文字画出来，
 * 所以统一在这里洗成纯文本：换行标签还原成真换行、其余标签去掉、实体解码、
 * 连续空行压成一行、行内空白压成单个空格。
 *
 * 顺序是「先剥标签、后解实体」：反过来的话原文里写着的 `&lt;br&gt;`（本意是字面量）
 * 会被解码成 `<br>` 再当成换行，而且解码出的 `<` 与后面的 `>` 会被当成一个标签整段吃掉。
 */
export function descText(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  // 换行标签先还原成真的换行：<br> / <br/> / <br /> 三种写法，外加块级结束标签
  let text: string = raw.replace(/<br\s*\/?>/gi, '\n');
  text = text.replace(/<\/(p|div|li|h[1-6])>/gi, '\n');
  // 剩下的标签整段丢掉，只留标签之间的文字
  let stripped: string = '';
  let depth: number = 0;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (ch === '<') {
      depth++;
      continue;
    }
    if (ch === '>') {
      if (depth > 0) {
        depth--;
      }
      continue;
    }
    if (depth === 0) {
      stripped += ch;
    }
  }
  const kept: string[] = [];
  for (const line of decodeName(stripped).split('\n')) {
    const trimmed: string = line.replace(/\s+/g, ' ').trim();
    // 连续空行只保留一行
    if (trimmed.length === 0 && (kept.length === 0 || kept[kept.length - 1].length === 0)) {
      continue;
    }
    kept.push(trimmed);
  }
  while (kept.length > 0 && kept[kept.length - 1].length === 0) {
    kept.pop();
  }
  return kept.join('\n');
}

/** 洛雪的 formatPlayCount：播放量 -> 「1.2万 / 3.4亿」 */
function formatPlayCount(num: number): string {
  if (!num) {
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

/** 毫秒时间戳 -> YYYY-MM-DD（洛雪的 dateFormat(x, 'Y-M-D')） */
function dateFormat(ms: number): string {
  if (!ms || ms <= 0) {
    return '';
  }
  const date = new Date(ms);
  const year: number = date.getFullYear();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  return `${year}-${month < 10 ? '0' : ''}${month}-${day < 10 ? '0' : ''}${day}`;
}

/**
 * 歌手数组按字段名拼接（洛雪的 formatSingerName(singers, key)）。
 * 内置搜索里的 formatSingerName 固定取 name 字段，酷狗榜单的字段叫 author_name，
 * 所以这里单独来一个带字段名的版本。
 */
function joinSingerField(list: Object | undefined, key: string): string {
  if (Array.isArray(list)) {
    const names: string[] = [];
    for (const raw of list as Object[]) {
      if (typeof raw === 'string') {
        const text: string = raw as string;
        if (text.length > 0) {
          names.push(text);
        }
        continue;
      }
      const name: string = asString(asRecord(raw)[key]);
      if (name.length > 0) {
        names.push(name);
      }
    }
    return decodeName(names.join('、'));
  }
  return decodeName(asString(list));
}

// ------------------------------------------------------------------ HTTP

interface FetchOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: Object;
  form?: Record<string, string>;
  rawText?: boolean;
  timeout?: number;
}

interface FetchResult {
  status: number;
  body: Object | string;
}

/** 发起一次请求；响应可 JSON 解析时 body 是对象，否则是原始文本 */
function httpFetch(url: string, options?: FetchOptions): Promise<FetchResult> {
  return new Promise<FetchResult>((resolve, reject) => {
    const opts: LxRequestOptions = {
      method: options !== undefined && options.method !== undefined ? options.method : 'get',
      timeout: options !== undefined && options.timeout !== undefined ? options.timeout : 15000,
    };
    if (options !== undefined) {
      if (options.headers !== undefined) {
        opts.headers = options.headers;
      }
      if (options.body !== undefined) {
        opts.body = options.body;
      }
      if (options.form !== undefined) {
        opts.form = options.form;
      }
      if (options.rawText !== undefined) {
        opts.rawText = options.rawText;
      }
    }
    lxRequest(url, opts, (resp) => {
      resolve({ status: resp.statusCode, body: resp.body });
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/** 要求响应是 JSON 对象 */
function resultRecord(result: FetchResult, label: string): Record<string, Object> {
  const body = result.body;
  if (body !== null && typeof body === 'object' && !Array.isArray(body)) {
    return body as Record<string, Object>;
  }
  if (typeof body === 'string') {
    // 少数接口返回非标准 JSON，再兜底解析一次
    try {
      const parsed = JSON.parse(body as string) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      // fallthrough
    }
  }
  throw new Error(`${label}返回格式异常（HTTP ${result.status}）`);
}

/** 要求响应是文本 */
function resultText(result: FetchResult, label: string): string {
  const body = result.body;
  if (typeof body === 'string') {
    return body as string;
  }
  throw new Error(`${label}返回格式异常（HTTP ${result.status}）`);
}

async function fetchRecord(url: string, options: FetchOptions | undefined, label: string,
  ): Promise<Record<string, Object>> {
  return resultRecord(await httpFetch(url, options), label);
}

// ------------------------------------------------------------------ 歌曲构造

/** 构造一首歌需要的字段（各平台解析函数填这个，由 createSong 统一产出 LxMusicInfo） */
interface SongSeed {
  singer: string;
  name: string;
  albumName: string;
  albumId: string;
  songmid: string;
  source: string;
  interval: string;
  img: string;
  types: LxQualityItem[];
  _types: Record<string, LxQualityItem>;
  hash?: string;
  songId?: string;
  albumMid?: string;
  strMediaMid?: string;
  copyrightId?: string;
}

function createSong(seed: SongSeed): LxMusicInfo {
  const info: LxMusicInfo = {
    name: seed.name,
    singer: seed.singer,
    source: seed.source,
    songmid: seed.songmid,
    albumName: seed.albumName,
    albumId: seed.albumId,
    interval: seed.interval,
    img: seed.img,
    types: seed.types,
    _types: seed._types,
    typeUrl: {},
    lrc: null,
    otherSource: null,
  };
  // 这些字段各平台不一样，为空的必须「不写」：源脚本普遍写 `musicInfo.hash ?? musicInfo.songmid`，
  // 写空串会让 ?? 不回退，取流参数就变成空的了。
  if (seed.hash !== undefined && seed.hash.length > 0) {
    info.hash = seed.hash;
  }
  if (seed.songId !== undefined && seed.songId.length > 0) {
    info.songId = seed.songId;
  }
  if (seed.albumMid !== undefined && seed.albumMid.length > 0) {
    info.albumMid = seed.albumMid;
  }
  if (seed.strMediaMid !== undefined && seed.strMediaMid.length > 0) {
    info.strMediaMid = seed.strMediaMid;
  }
  if (seed.copyrightId !== undefined && seed.copyrightId.length > 0) {
    info.copyrightId = seed.copyrightId;
  }
  return info;
}

/** 追加一档音质（同音质只留第一条） */
function addType(types: LxQualityItem[], map: Record<string, LxQualityItem>,
  quality: string, size: string, hash: string): void {
  if (Object.keys(map).includes(quality)) {
    return;
  }
  const item: LxQualityItem = { type: quality, size: size };
  if (hash.length > 0) {
    item.hash = hash;
  }
  types.push(item);
  map[quality] = item;
}

/** 空的歌词/额外信息占位 */
function emptyListInfo(name: string): LxListInfo {
  return { name: name, img: '', desc: '', author: '', playCount: '' };
}

// ------------------------------------------------------------------ 分派

export function sortListOf(source: string): LxSortItem[] {
  if (source === 'kw') {
    return KW_SORTS;
  }
  if (source === 'kg') {
    return KG_SORTS;
  }
  if (source === 'mg') {
    return MG_SORTS;
  }
  if (source === 'tx') {
    return TX_SORTS;
  }
  if (source === 'wy') {
    return WY_SORTS;
  }
  if (source === 'qs') {
    // 汽水只有一条「推荐」流（发现页），没有分类页签
    return QS_SORTS;
  }
  return [];
}

/** 歌单广场/推荐歌单 */
export async function getRecommendPlaylists(source: string, sortId: string, page: number,
  ): Promise<LxPlaylistItem[]> {
  if (source === 'kw') {
    return await kwPlaylists(sortId, page);
  }
  if (source === 'kg') {
    return await kgPlaylists(sortId, page);
  }
  if (source === 'mg') {
    return await mgPlaylists(sortId, page);
  }
  if (source === 'tx') {
    return await txPlaylists(sortId, page);
  }
  if (source === 'wy') {
    return await wyPlaylists(page);
  }
  if (source === 'qs') {
    return await qsPlaylists(page);
  }
  throw new Error(`暂不支持该平台的推荐歌单：${source}`);
}

/** 歌单里的歌曲 */
export async function getPlaylistDetail(source: string, id: string, page: number,
  ): Promise<LxListDetail> {
  if (source === 'kw') {
    return await kwPlaylistDetail(id, page);
  }
  if (source === 'kg') {
    return await kgPlaylistDetail(id);
  }
  if (source === 'mg') {
    return await mgPlaylistDetail(id, page);
  }
  if (source === 'tx') {
    return await txPlaylistDetail(id, page);
  }
  if (source === 'wy') {
    return await wyPlaylistDetail(id, page, '');
  }
  if (source === 'qs') {
    return await qsPlaylistDetail(id, page);
  }
  throw new Error(`暂不支持该平台的歌单：${source}`);
}

/** 拉全量歌单时的进度（导入面板用来显示「正在获取 x/y」） */
export interface PlaylistDetailProgress {
  page: number;
  loaded: number;
  total: number;
}

/** 翻页上限：咪咕一页 30 首，40 页 ≈ 1200 首，够覆盖常见歌单又不会无限翻 */
const MAX_DETAIL_PAGES: number = 40;

/**
 * 歌单的全部歌曲（对应洛雪的 getListDetailAll）
 *
 * 各平台一页给多少差别很大：酷我一次 1000 首、网易一次最多 1000 首、酷狗与 QQ
 * 不分页（一次给全），只有咪咕是一页 30 首。所以这里统一翻页，并且以
 * 「这一页没带来新歌」作为终止条件 —— 不分页的平台第二页会原样再给一份，
 * 靠这个判断停住，不会空转。
 */
export async function getPlaylistDetailAll(source: string, id: string,
  onProgress?: (progress: PlaylistDetailProgress) => void): Promise<LxListDetail> {
  const merged: LxMusicInfo[] = [];
  const seen: Set<string> = new Set<string>();
  let info: LxListInfo = emptyListInfo('');
  let total: number = 0;
  let page: number = 1;
  while (page <= MAX_DETAIL_PAGES) {
    const detail: LxListDetail = await getPlaylistDetail(source, id, page);
    if (detail.info.name.length > 0 && info.name.length === 0) {
      info = detail.info;
    } else if (info.name.length > 0 && info.img.length === 0 && detail.info.img.length > 0) {
      // 咪咕的歌曲列表接口不带封面，歌单信息接口才带；第一页没补上就在这里补
      info = detail.info;
    }
    if (detail.total > total) {
      total = detail.total;
    }
    let added: number = 0;
    for (const song of detail.list) {
      const key: string = musicIdOf(song);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(song);
      added++;
    }
    if (onProgress !== undefined) {
      onProgress({ page: page, loaded: merged.length, total: total });
    }
    if (added === 0 || detail.list.length === 0) {
      break;
    }
    if (total > 0 && merged.length >= total) {
      break;
    }
    page++;
  }
  return {
    list: merged,
    total: total > merged.length ? total : merged.length,
    info: info,
  };
}

/** 排行榜列表 */
export function getBoards(source: string): LxBoardItem[] {  if (source === 'kw') {
    return KW_BOARDS;
  }
  if (source === 'kg') {
    return KG_BOARDS;
  }
  if (source === 'mg') {
    return MG_BOARDS;
  }
  if (source === 'tx') {
    return TX_BOARDS;
  }
  if (source === 'wy') {
    return WY_BOARDS;
  }
  if (source === 'qs') {
    return QS_BOARDS;
  }
  return [];
}

/**
 * 榜单里的歌曲
 *
 * `limit > 0` 时**只取前 limit 首**（首页那几行只要前几首）：各平台的榜单接口一次回的
 * 量差得很远 —— 酷我 rn=100（实测 35 万字符加密响应 / 25 万字节 JSON）、酷狗 100、
 * QQ 300、**网易 n=1000**，首页为了三行歌把整张榜拉回来既慢又占内存。
 * `limit = 0`（默认）就是整页，给「榜单页」用。
 */
export async function getBoardSongs(source: string, bangid: string, page: number, name: string,
  limit: number = 0): Promise<LxListDetail> {
  if (source === 'kw') {
    return await kwBoardSongs(bangid, page, name, limit);
  }
  if (source === 'kg') {
    return await kgBoardSongs(bangid, page, name, limit);
  }
  if (source === 'mg') {
    // 咪咕这个接口没有每页条数参数（needAll=0 已经是不取全量），忽略 limit
    return await mgBoardSongs(bangid, name);
  }
  if (source === 'tx') {
    return await txBoardSongs(bangid, name, limit);
  }
  if (source === 'wy') {
    return await wyPlaylistDetail(bangid, page, name, limit);
  }
  if (source === 'qs') {
    return await qsBoardSongs(bangid, page, name, limit);
  }
  throw new Error(`暂不支持该平台的排行榜：${source}`);
}

// ================================================================== 汽水 qs

/** 汽水 App 侧 Luna 主机（搜索 / 发现页 / 歌单详情 / 评论都在它下面，见 MusicSearch 顶部说明） */
const QS_LUNA: string = 'https://beta-luna.douyin.com';
const QS_SORTS: LxSortItem[] = [{ name: '推荐', tid: 'recommend', id: 'recommend' }];
/**
 * 汽水的三张榜（都在发现页的 discover_top_song_list 块里，各 50 首，每周四更新）
 *
 * bangid 用我们自己的短标识（hot/new/west），取歌时按它对到块的标题 —— 不写死
 * inner_block_id：那是服务端下发的，换版本 / 换区域可能变。
 */
const QS_BOARDS: LxBoardItem[] = [
  { id: 'qs_hot', name: '热歌榜', bangid: 'hot', source: 'qs' },
  { id: 'qs_new', name: '新歌榜', bangid: 'new', source: 'qs' },
  { id: 'qs_west', name: '欧美榜', bangid: 'west', source: 'qs' },
];

/** 汽水各接口的请求体（ArkTS 不允许「无类型对象字面量」，所以逐个声明） */
interface QsMixPayload {
  count: number;
}

interface QsDetailPayload {
  playlist_id: string;
  count: number;
  cursor?: string;
  session_id?: string;
}

interface QsDiscoverPayload {
  first_request?: boolean;
}

async function qsPost(path: string, payload: Object,
  label: string): Promise<Record<string, Object>> {
  return await fetchRecord(`${QS_LUNA}${path}?${qsDeviceQuery()}`, {
    method: 'post',
    headers: QS_APP_HEADERS,
    body: payload,
  }, label);
}

/** 汽水歌单的作者（发现页多数歌单不带 owner，带的时候是 nickname / name） */
function qsOwnerName(pl: Record<string, Object>): string {
  const owner: Record<string, Object> = asRecord(pl['owner']);
  let name: string = asString(owner['nickname']);
  if (name.length === 0) {
    name = asString(owner['name']);
  }
  if (name.length === 0) {
    name = asString(asRecord(pl['owner_info'])['nickname']);
  }
  return name;
}

function qsPlaylistTitle(pl: Record<string, Object>): string {
  const title: string = asString(pl['title']);
  return title.length > 0 ? title : asString(pl['name']);
}

/** 汽水歌单 -> 歌单卡（发现页的一批与歌单搜索共用这一个映射） */
function qsPlaylistItemOf(pl: Record<string, Object>): LxPlaylistItem | null {
  const id: string = asString(pl['id']);
  if (id.length === 0) {
    return null;
  }
  return {
    id: id,
    name: qsPlaylistTitle(pl),
    author: qsOwnerName(pl),
    img: qsCoverOf(asRecord(pl['url_cover'])),
    desc: descText(asString(pl['desc'])),
    // 汽水给的是收藏数（stats.count_collected），不是播放量：不拿它冒充播放量，卡片退成显示作者
    playCount: '',
    total: asNumber(pl['count_tracks']),
    time: '',
    source: 'qs',
  };
}

function qsListInfoOf(pl: Record<string, Object>): LxListInfo {
  return {
    name: qsPlaylistTitle(pl),
    img: qsCoverOf(asRecord(pl['url_cover'])),
    desc: descText(asString(pl['desc'])),
    author: qsOwnerName(pl),
    playCount: '',
  };
}

/**
 * 汽水的推荐歌单（广场）
 *
 * 走 `/luna/discover/mix`：一次 count=30 能回 30 张左右的歌单块。它虽然报 has_more，
 * 但**顶层没有可用的 next_cursor / session_id**（实测都是空），所以只出第一页；
 * 广场滚到底就自然停住，不装作还能翻。
 */
async function qsPlaylists(page: number): Promise<LxPlaylistItem[]> {
  if (page > 1) {
    return [];
  }
  const mixPayload: QsMixPayload = { count: 30 };
  const body: Record<string, Object> = await qsPost('/luna/discover/mix', mixPayload, '汽水推荐歌单');
  const out: LxPlaylistItem[] = [];
  const seen: Set<string> = new Set<string>();
  for (const blockRaw of asObjectArray(body['inner_block'])) {
    for (const resRaw of asObjectArray(asRecord(blockRaw)['resources'])) {
      const entity: Record<string, Object> = asRecord(asRecord(resRaw)['entity']);
      const item: LxPlaylistItem | null = qsPlaylistItemOf(asRecord(entity['playlist']));
      if (item !== null && !seen.has(item.id)) {
        seen.add(item.id);
        out.push(item);
      }
    }
  }
  return out;
}

/** 歌单详情的翻页现场：cursor / session_id 都由上一页的响应带出来（汽水是游标分页） */
let qsDetailKey: string = '';
let qsDetailCursor: string = '';
let qsDetailSession: string = '';

/**
 * 汽水歌单详情（`/luna/playlist/detail`）
 *
 * 分页是「响应给下一跳的 cursor + session_id」，不是页码：第一页拿到的 next_cursor
 * 就是第二页的入参。游标按歌单 id 记在模块里（getPlaylistDetailAll 是顺序翻页的）；
 * 换了歌单或回到第一页就重置。
 */
async function qsPlaylistDetail(id: string, page: number): Promise<LxListDetail> {
  if (page <= 1 || id !== qsDetailKey) {
    qsDetailKey = id;
    qsDetailCursor = '';
    qsDetailSession = '';
  }
  const payload: QsDetailPayload = {
    playlist_id: id,
    count: 50,
  };
  if (qsDetailCursor.length > 0) {
    payload.cursor = qsDetailCursor;
  }
  if (qsDetailSession.length > 0) {
    payload.session_id = qsDetailSession;
  }
  const body: Record<string, Object> = await qsPost('/luna/playlist/detail', payload, '汽水歌单详情');
  const pl: Record<string, Object> = asRecord(body['playlist']);
  qsDetailCursor = asString(body['next_cursor']);
  qsDetailSession = asString(body['session_id']);
  const songs: LxMusicInfo[] = [];
  for (const resRaw of asObjectArray(body['media_resources'])) {
    const entity: Record<string, Object> = asRecord(asRecord(resRaw)['entity']);
    const info: LxMusicInfo | null = qsTrackToInfo(asRecord(entity['track']));
    if (info !== null) {
      songs.push(info);
    }
  }
  const total: number = asNumber(pl['count_tracks']);
  return { list: songs, total: total > 0 ? total : songs.length, info: qsListInfoOf(pl) };
}

function qsBoardTitle(bangid: string): string {
  if (bangid === 'hot') {
    return '热歌榜';
  }
  if (bangid === 'new') {
    return '新歌榜';
  }
  if (bangid === 'west') {
    return '欧美榜';
  }
  return '';
}

/** 从发现页响应里取出全部榜单块（discover_top_song_list 的 inner_block） */
function qsChartBlocks(body: Record<string, Object>): Object[] {
  const out: Object[] = [];
  for (const blockRaw of asObjectArray(body['blocks'])) {
    const block: Record<string, Object> = asRecord(blockRaw);
    if (asString(block['type']) !== 'discover_top_song_list') {
      continue;
    }
    for (const chartRaw of asObjectArray(block['inner_block'])) {
      out.push(chartRaw);
    }
  }
  return out;
}

/**
 * 汽水榜单里的歌
 *
 * 汽水没有「按榜取歌」的独立接口：三张榜整块塞在发现页的 discover_top_song_list 里，
 * 每张 50 首一次给全。所以这里拉一次发现页、按标题挑出那张榜；page>1 直接空（没有下一页）。
 */
/**
 * 发现页响应的短缓存
 *
 * 汽水三张榜整块塞在同一个发现页响应里（约 1.6MB），推荐页是「一栏一栏懒加载」的，
 * 不缓存就会为三张榜连拉三次；缓存 60 秒足够一次进页面的三栏共用，也不至于让榜单太旧。
 */
let qsDiscoverCacheAt: number = 0;
let qsDiscoverCache: Record<string, Object> = {};

async function qsDiscoverBody(label: string): Promise<Record<string, Object>> {
  const now: number = Date.now();
  if (qsDiscoverCacheAt > 0 && now - qsDiscoverCacheAt < 60000
    && Object.keys(qsDiscoverCache).length > 0) {
    return qsDiscoverCache;
  }
  const firstPayload: QsDiscoverPayload = { first_request: true };
  let body: Record<string, Object> = await qsPost('/luna/discover', firstPayload, label);
  if (qsChartBlocks(body).length === 0) {
    // 发现页偶发空响应（限流）：再问一次，别让榜单页直接报错
    const retryPayload: QsDiscoverPayload = {};
    body = await qsPost('/luna/discover', retryPayload, label);
  }
  if (Object.keys(body).length > 0) {
    qsDiscoverCache = body;
    qsDiscoverCacheAt = now;
  }
  return body;
}

async function qsBoardSongs(bangid: string, page: number, name: string,
  limit: number): Promise<LxListDetail> {
  if (page > 1) {
    return { list: [], total: 0, info: emptyListInfo(name) };
  }
  const body: Record<string, Object> = await qsDiscoverBody('汽水榜单');
  const charts: Object[] = qsChartBlocks(body);
  const wanted: string = qsBoardTitle(bangid);
  let chart: Record<string, Object> = {};
  for (const chartRaw of charts) {
    const one: Record<string, Object> = asRecord(chartRaw);
    const title: string = asString(one['title']);
    if ((wanted.length > 0 && title === wanted)
      || (wanted.length === 0 && name.length > 0 && title === name)) {
      chart = one;
      break;
    }
  }
  if (Object.keys(chart).length === 0) {
    throw new Error('汽水榜单没有这张榜了（接口可能改版）');
  }
  const songs: LxMusicInfo[] = [];
  for (const resRaw of asObjectArray(chart['resources'])) {
    const ranked: Record<string, Object> = asRecord(asRecord(asRecord(resRaw)['entity'])['ranked_track']);
    const info: LxMusicInfo | null = qsTrackToInfo(asRecord(ranked['track']));
    if (info !== null) {
      songs.push(info);
    }
  }
  const list: LxMusicInfo[] = limit > 0 && songs.length > limit ? songs.slice(0, limit) : songs;
  const info: LxListInfo = {
    name: asString(chart['title']),
    img: '',
    desc: descText(asString(chart['desc'])),
    author: '',
    playCount: '',
  };
  return { list: list, total: songs.length, info: info };
}

// ================================================================== 酷我 kw

const KW_SORTS: LxSortItem[] = [
  { name: '最新', tid: 'new', id: 'new' },
  { name: '最热', tid: 'hot', id: 'hot' },
];
const KW_MINFO = /level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)/;
/** 酷我榜单接口的 AES-ECB 密钥（base64，16 字节）与 appId，照抄 kw/util.js 的 wbdCrypto */
const KW_WBD_KEY: string = 'cFcnPcf6Kb85RC1y3V6M5A==';
const KW_WBD_APP_ID: string = 'y67sprxhhpws';

async function kwPlaylists(sortId: string, page: number): Promise<LxPlaylistItem[]> {
  const url: string = 'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList' +
    `?loginUid=0&loginSid=0&appUid=76039576&pn=${page}&rn=36&order=${encodeURIComponent(sortId)}`;
  const body: Record<string, Object> = await fetchRecord(url, undefined, '酷我歌单');
  if (asNumber(body['code']) !== 200) {
    throw new Error('酷我歌单接口返回异常');
  }
  return kwFilterPlaylists(asObjectArray(asRecord(body['data'])['data']));
}

function kwFilterPlaylists(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const playlist: LxPlaylistItem = {
      id: `digest-${asString(item['digest'])}__${asString(item['id'])}`,
      name: asString(item['name']),
      author: asString(item['uname']),
      img: asString(item['img']),
      desc: descText(asString(item['desc'])),
      playCount: formatPlayCount(asNumber(item['listencnt'])),
      total: asNumber(item['total']),
      time: '',
      source: 'kw',
    };
    list.push(playlist);
  }
  return list;
}

async function kwPlaylistDetail(id: string, page: number): Promise<LxListDetail> {
  let digest: string = '';
  let pid: string = id;
  if (id.startsWith('digest-')) {
    const parts: string[] = id.split('__');
    digest = parts[0].substring('digest-'.length);
    pid = parts.length > 1 ? parts[1] : '';
  }
  if (digest === '5') {
    // digest 5 是「歌单」，先拿它的 sourceid 再取歌曲
    const resolved: string = await kwResolveDigest5(pid);
    if (resolved.length > 0) {
      pid = resolved;
    }
  }
  const url: string = 'http://nplserver.kuwo.cn/pl.svc?op=getlistinfo' +
    `&pid=${encodeURIComponent(pid)}&pn=${page - 1}&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo` +
    '&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1';
  const body: Record<string, Object> = await fetchRecord(url, undefined, '酷我歌单详情');
  if (asString(body['result']) !== 'ok') {
    throw new Error('酷我歌单详情接口返回异常');
  }
  const info: LxListInfo = {
    name: asString(body['title']),
    img: asString(body['pic']),
    desc: descText(asString(body['info'])),
    author: asString(body['uname']),
    playCount: formatPlayCount(asNumber(body['playnum'])),
  };
  return {
    list: kwFilterSongs(asObjectArray(body['musiclist'])),
    total: asNumber(body['total']),
    info: info,
  };
}

async function kwResolveDigest5(id: string): Promise<string> {
  const url: string = 'http://qukudata.kuwo.cn/q.k?op=query&cont=ninfo' +
    `&node=${encodeURIComponent(id)}&pn=0&rn=1&fmt=json&src=mbox&level=2`;
  const body: Record<string, Object> = await fetchRecord(url, undefined, '酷我歌单信息');
  const children: Object[] = asObjectArray(body['child']);
  if (children.length === 0) {
    return '';
  }
  return asString(asRecord(children[0])['sourceid']);
}

/** 酷我歌曲（歌单详情与榜单共用；字段来源分别是 musiclist / bang 的 musiclist） */
function kwFilterSongs(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    // 音质列表字段各接口不一样：榜单/歌单详情页叫 minfo / MINFO，
    // 另有 n_minfo / N_MINFO 一路（里面是 mmp4 / mgg 这些本站放不了的封装格式），
    // 所以必须优先取 minfo / MINFO，否则会解析不出一档音质。
    let minfo: string = asString(item['minfo']);
    if (minfo.length === 0) {
      minfo = asString(item['MINFO']);
    }
    if (minfo.length === 0) {
      minfo = asString(item['n_minfo']);
    }
    if (minfo.length === 0) {
      minfo = asString(item['N_MINFO']);
    }
    const segments: string[] = minfo.split(';');
    for (const segment of segments) {
      const matched: RegExpMatchArray | null = segment.match(KW_MINFO);
      if (matched === null) {
        continue;
      }
      const size: string = matched[4].toUpperCase();
      // 4000 / 2000 / 320 / 128 对应 flac24bit / flac / 320k / 128k，
      // 按下标从高到低追加，顺序天然就是「从高音质到低音质」
      if (matched[2] === '4000') {
        addType(types, map, 'flac24bit', size, '');
      } else if (matched[2] === '2000') {
        addType(types, map, 'flac', size, '');
      } else if (matched[2] === '320') {
        addType(types, map, '320k', size, '');
      } else if (matched[2] === '128') {
        addType(types, map, '128k', size, '');
      }
    }
    const seed: SongSeed = {
      singer: joinSingerField(item['artist'], 'name').split('&').join('、'),
      name: decodeName(asString(item['name'])),
      albumName: decodeName(asString(item['album'])),
      albumId: asString(item['albumid'] !== undefined ? item['albumid'] : item['albumId']),
      songmid: asString(item['id']),
      source: 'kw',
      interval: formatPlayTime(Number.parseInt(asString(item['duration']), 10)),
      img: asString(item['pic']),
      types: types,
      _types: map,
    };
    list.push(createSong(seed));
  }
  return list;
}

/** 酷我榜单：请求体按 wbdCrypto 的规则加密（JSON 原文 -> AES-128-ECB -> base64 + md5 签名） */
function kwBuildWbdParam(requestBody: Record<string, Object>): string {
  const keyBytes: number[] = fromBase64(KW_WBD_KEY);
  // 明文必须是 JSON 原文字节。洛雪那行 `Buffer.from(JSON.stringify(x)).toString('base64')`
  // 看着是先把 JSON 变成 base64 再加密，但它的 aesEncryptSync 入参本身按 base64 解码，
  // 两步抵消后加密的就是 JSON 原文；照字面喂 base64 文本，服务端会回 DECRYPT_ERROR。
  const plainBytes: number[] = utf8Bytes(JSON.stringify(requestBody));
  const cipher: string = toBase64(aes128EcbPkcs7EncryptBytes(keyBytes, plainBytes));
  const time: number = Date.now();
  const sign: string = md5Hex(`${KW_WBD_APP_ID}${cipher}${time}`).toUpperCase();
  return `data=${encodeURIComponent(cipher)}&time=${time}&appId=${KW_WBD_APP_ID}&sign=${sign}`;
}

/**
 * 解出榜单响应（服务端回的是加密过的 base64 文本）
 *
 * **解密走 `PlatformCrypto` 的原生实现**：这份响应实测 35 万字符、解出 25 万字节 JSON，
 * 纯 ArkTS 手写 AES 要跑一万多个块、主线程卡好几秒（2026-10-13 实机反馈）。
 * 请求侧那几个字节的加密（`kwBuildWbdParam`）留在 `LxCrypto` 的纯实现里，
 * 由主机单测跟 node:crypto 的向量对齐。
 */
function kwDecodeWbd(text: string): Record<string, Object> {
  const keyBytes: number[] = fromBase64(KW_WBD_KEY);
  const plain: string = decodeAes128EcbPkcs7Text(keyBytes, decodeURIComponent(text.trim()));
  return JSON.parse(plain) as Record<string, Object>;
}

async function kwBoardSongs(bangid: string, page: number, name: string,
  limit: number = 0): Promise<LxListDetail> {
  const requestBody: Record<string, Object> = {
    'uid': '',
    'devId': '',
    'sFrom': 'kuwo_sdk',
    'user_type': 'AP',
    'carSource': 'kwplayercar_ar_6.0.1.0_apk_keluze.apk',
    'id': bangid,
    'pn': page - 1,
    'rn': limit > 0 ? limit : 100,
  };
  const url: string = `https://wbd.kuwo.cn/api/bd/bang/bang_info?${kwBuildWbdParam(requestBody)}`;
  const result: FetchResult = await httpFetch(url, undefined);
  // 正常时响应体是加密过的 base64 文本；参数不对时（如签名过期）回的是明文 JSON
  const decoded: Record<string, Object> = typeof result.body === 'string'
    ? kwDecodeWbd(result.body as string)
    : asRecord(result.body);
  const code: number = asNumber(decoded['code']);
  if (code !== 200) {
    const message: string = asString(decoded['msg']);
    throw new Error(message.length > 0 ? `酷我榜单：${message}` : '酷我榜单接口返回异常');
  }
  const data: Record<string, Object> = asRecord(decoded['data']);
  if (data['musiclist'] === undefined) {
    throw new Error('酷我榜单接口返回异常');
  }
  const apiName: string = asString(data['name']);
  const info: LxListInfo = {
    name: apiName.length > 0 ? apiName : name,
    img: asString(data['pic']),
    desc: descText(asString(data['info'])),
    author: '',
    playCount: '',
  };
  return {
    list: kwFilterSongs(asObjectArray(data['musiclist'])),
    total: asNumber(data['total']),
    info: info,
  };
}

// ================================================================== 酷狗 kg

const KG_SORTS: LxSortItem[] = [
  { name: '推荐', tid: 'recommend', id: '5' },
  { name: '最热', tid: 'hot', id: '6' },
  { name: '最新', tid: 'new', id: '7' },
  { name: '热藏', tid: 'hot_collect', id: '3' },
  { name: '飙升', tid: 'rise', id: '8' },
];
const KG_SPECIAL_LIST = /global\.data = (\[.+\]);/;
const KG_SPECIAL_INFO = /global = {[\s\S]+?name: "(.+)"[\s\S]+?pic: "(.+)"[\s\S]+?};/;
const KG_DESC = /id="specailIntroduceWrap">([\s\S]*?)<\/div>/;
/** 酷狗 gateway 的固定 key（照抄 kg/songList.js 的 createTask） */
const KG_GATEWAY_KEY: string = 'OIlwieks28dk2k092lksi2UIkp';
/**
 * 酷狗 App 的 UA
 *
 * 歌单页（/songlist/gcid_xxx/）按 UA 给两套完全不同的页面：桌面 UA 给的是老的
 * 服务端渲染页（里面没有 window.$output），移动/App UA 才是那套带 $output 的 H5。
 * 所以取用户歌单信息时必须带上它 —— 不然后果就是「页面里找不到歌单数据」。
 */
const KG_APP_UA: string = 'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi';

async function kgPlaylists(sortId: string, page: number): Promise<LxPlaylistItem[]> {
  const url: string = 'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial' +
    `?is_ajax=1&cdn=cdn&t=${encodeURIComponent(sortId)}&c=&p=${page}`;
  const body: Record<string, Object> = await fetchRecord(url, undefined, '酷狗歌单');
  if (asNumber(body['status']) !== 1) {
    throw new Error('酷狗歌单接口返回异常');
  }
  return kgFilterPlaylists(asObjectArray(body['special_db']));
}

function kgFilterPlaylists(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const totalPlay: string = asString(item['total_play_count']);
    // publish_time 有时是 '2020-12-07' 这样的字符串，有时是毫秒时间戳
    const publishRaw: Object | undefined =
      item['publish_time'] !== undefined ? item['publish_time'] : item['publishtime'];
    const time: string = typeof publishRaw === 'string'
      ? publishRaw as string : dateFormat(asNumber(publishRaw));
    const img: string = asString(item['img']).length > 0 ? asString(item['img']) : asString(item['imgurl']);
    const playlist: LxPlaylistItem = {
      id: `id_${asString(item['specialid'])}`,
      name: asString(item['specialname']),
      author: asString(item['nickname']),
      img: img,
      desc: descText(asString(item['intro'])),
      playCount: totalPlay.length > 0 ? totalPlay : formatPlayCount(asNumber(item['play_count'])),
      total: asNumber(item['song_count']),
      time: time,
      source: 'kg',
    };
    list.push(playlist);
  }
  return list;
}

/** 酷狗用户歌单（gcid）解析出来的东西：specialid + 歌单页上那份元信息 */
interface KgGcidInfo {
  specialId: string;
  name: string;
  img: string;
  desc: string;
  author: string;
}

/**
 * 酷狗用户歌单（gcid_xxx）-> 精选集 specialid
 *
 * 酷狗有两套歌单：精选集（specialid，网页 /yy/special/single/<id>.html 那条路）与
 * **用户歌单**（global_collection_id，即 gcid_xxx，App 里「我的歌单」分享出来的就是它）。
 * 用户歌单没有直接的歌曲接口，但它的歌单页里藏着 window.$output：
 *   info.listinfo = { name, pic, intro, count, specialid }
 * 也就是说每张用户歌单背后都对应一个 specialid，拿到它就能回到精选集那条路取全部歌
 * （实测 52 首的用户歌单：specialid 页面 52/52，名字封面也都在）。
 *
 * 页面里的 $output.songs 只有前 10 首（那是给首屏用的预览），不能当全量用。
 */
async function kgGcidInfo(gcid: string): Promise<KgGcidInfo> {
  const url: string = `https://m.kugou.com/songlist/${encodeURIComponent(gcid)}/`;
  const headers: Record<string, string> = { 'User-Agent': KG_APP_UA };
  const result: FetchResult = await httpFetch(url, { rawText: true, headers: headers });
  const html: string = resultText(result, '酷狗歌单页');
  const output: Record<string, Object> | null = kgPageOutput(html);
  if (output === null) {
    throw new Error('酷狗用户歌单解析失败（页面结构可能已变）');
  }
  const listinfo: Record<string, Object> = asRecord(asRecord(output['info'])['listinfo']);
  // 封面地址里带 {size} 占位符，必须换掉才是个能用的 URL
  const pic: string = asString(listinfo['pic']).split('{size}').join('400');
  return {
    specialId: asString(listinfo['specialid']),
    name: decodeName(asString(listinfo['name'])),
    img: pic,
    desc: descText(asString(listinfo['intro'])),
    author: decodeName(asString(listinfo['list_create_username'])),
  };
}

/** 从歌单页 HTML 里取出 window.$output 那段 JSON；取不到返回 null */
function kgPageOutput(html: string): Record<string, Object> | null {
  const marker: string = 'window.$output = ';
  const at: number = html.indexOf(marker);
  if (at < 0) {
    return null;
  }
  const start: number = at + marker.length;
  const end: number = html.indexOf('</script>', start);
  if (end < 0) {
    return null;
  }
  let json: string = html.substring(start, end).trim();
  if (json.endsWith(';')) {
    json = json.substring(0, json.length - 1).trim();
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    const record: Record<string, Object> = asRecord(parsed);
    return Object.keys(record).length > 0 ? record : null;
  } catch (e) {
    return null;
  }
}

async function kgPlaylistDetail(rawId: string): Promise<LxListDetail> {
  let id: string = rawId;
  if (id.startsWith('id_')) {
    id = id.substring('id_'.length);
  }
  // 用户歌单先换成 specialid；顺手把歌单页上的元信息留作兜底（精选集页面有时缺名字/简介）
  let gcid: KgGcidInfo | null = null;
  if (id.startsWith('gcid_')) {
    gcid = await kgGcidInfo(id);
    if (gcid.specialId.length === 0) {
      throw new Error('酷狗用户歌单解析失败：可能是私密歌单，或歌单页结构已变');
    }
    id = gcid.specialId;
  }
  const url: string = `http://www2.kugou.kugou.com/yueku/v9/special/single/${encodeURIComponent(id)}-5-9999.html`;
  const result: FetchResult = await httpFetch(url, undefined);
  const html: string = resultText(result, '酷狗歌单详情');
  const dataMatch: RegExpMatchArray | null = html.match(KG_SPECIAL_LIST);
  if (dataMatch === null) {
    throw new Error('酷狗歌单详情解析失败（页面结构可能已变）');
  }
  const hashes: Object[] = JSON.parse(dataMatch[1]) as Object[];
  const songs: LxMusicInfo[] = await kgSongsByHash(hashes);
  const infoMatch: RegExpMatchArray | null = html.match(KG_SPECIAL_INFO);
  const descMatch: RegExpMatchArray | null = html.match(KG_DESC);
  let fallbackName: string = '';
  let fallbackImg: string = '';
  let fallbackDesc: string = '';
  let fallbackAuthor: string = '';
  if (gcid !== null) {
    fallbackName = gcid.name;
    fallbackImg = gcid.img;
    fallbackDesc = gcid.desc;
    fallbackAuthor = gcid.author;
  }
  const info: LxListInfo = {
    name: infoMatch !== null && infoMatch[1].length > 0 ? infoMatch[1] : fallbackName,
    img: infoMatch !== null && infoMatch[2].length > 0 ? infoMatch[2] : fallbackImg,
    desc: descMatch !== null ? descText(descMatch[1]) : fallbackDesc,
    author: fallbackAuthor,
    playCount: '',
  };
  return { list: songs, total: songs.length, info: info };
}

/** 用 hash 批量换歌曲信息：gateway 一次最多 100 条 */
async function kgSongsByHash(hashes: Object[]): Promise<LxMusicInfo[]> {
  const unique: string[] = [];
  const seen: string[] = [];
  for (const raw of hashes) {
    const hash: string = asString(asRecord(raw)['hash']);
    if (hash.length === 0 || seen.includes(hash)) {
      continue;
    }
    seen.push(hash);
    unique.push(hash);
  }
  if (unique.length === 0) {
    return [];
  }
  const records: Object[] = [];
  let offset: number = 0;
  while (offset < unique.length) {
    const batch: Record<string, Object>[] = [];
    const end: number = Math.min(offset + 100, unique.length);
    for (let i = offset; i < end; i++) {
      batch.push({ 'hash': unique[i] });
    }
    const body: Record<string, Object> = {
      'data': batch,
      'area_code': '1',
      'show_privilege': 1,
      'show_album_info': '1',
      'is_publish': '',
      'appid': 1005,
      'clientver': 11451,
      'mid': '1',
      'dfid': '-',
      'clienttime': Date.now(),
      'key': KG_GATEWAY_KEY,
      'fields': 'album_info,author_name,audio_info,ori_audio_name,base,songname',
    };
    const headers: Record<string, string> = {
      'KG-THash': '13a3164',
      'KG-RC': '1',
      'KG-Fake': '0',
      'KG-RF': '00869891',
      'User-Agent': KG_APP_UA,
      'x-router': 'kmr.service.kugou.com',
    };
    const resp: Record<string, Object> = await fetchRecord(
      'http://gateway.kugou.com/v2/album_audio/audio',
      { method: 'post', headers: headers, body: body }, '酷狗歌曲信息');
    // 响应是 data: [ [ {歌曲} ], ... ]，每项取第 0 个
    for (const outer of asObjectArray(resp['data'])) {
      const group: Object[] = asObjectArray(outer);
      if (group.length > 0) {
        records.push(group[0]);
      }
    }
    offset = end;
  }
  return kgFilterGatewaySongs(records);
}

function kgFilterGatewaySongs(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  const seen: string[] = [];
  for (const raw of rawList) {
    if (raw === null || raw === undefined) {
      continue;
    }
    const item: Record<string, Object> = asRecord(raw);
    const audio: Record<string, Object> = asRecord(item['audio_info']);
    const audioId: string = asString(audio['audio_id']);
    if (audioId.length === 0 || seen.includes(audioId)) {
      continue;
    }
    seen.push(audioId);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const hash: string = asString(audio['hash']);
    const size128: string = asString(audio['filesize']);
    if (size128 !== '0' && size128.length > 0) {
      addType(types, map, '128k', sizeFormate(Number.parseInt(size128, 10)), hash);
    }
    const size320: string = asString(audio['filesize_320']);
    if (size320 !== '0' && size320.length > 0) {
      addType(types, map, '320k', sizeFormate(Number.parseInt(size320, 10)),
        asString(audio['hash_320']));
    }
    const sizeFlac: string = asString(audio['filesize_flac']);
    if (sizeFlac !== '0' && sizeFlac.length > 0) {
      addType(types, map, 'flac', sizeFormate(Number.parseInt(sizeFlac, 10)),
        asString(audio['hash_flac']));
    }
    const sizeHigh: string = asString(audio['filesize_high']);
    if (sizeHigh !== '0' && sizeHigh.length > 0) {
      addType(types, map, 'flac24bit', sizeFormate(Number.parseInt(sizeHigh, 10)),
        asString(audio['hash_high']));
    }
    const album: Record<string, Object> = asRecord(item['album_info']);
    const seed: SongSeed = {
      singer: decodeName(asString(item['author_name'])),
      name: decodeName(asString(item['songname'])),
      albumName: decodeName(asString(album['album_name'])),
      albumId: asString(album['album_id']),
      songmid: audioId,
      source: 'kg',
      interval: formatPlayTime(Number.parseInt(asString(audio['timelength']), 10) / 1000),
      img: '',
      types: types,
      _types: map,
      hash: hash,
    };
    list.push(createSong(seed));
  }
  return list;
}

async function kgBoardSongs(bangid: string, page: number, name: string,
  limit: number = 0): Promise<LxListDetail> {
  const url: string = 'http://mobilecdnbj.kugou.com/api/v3/rank/song' +
    `?version=9108&ranktype=1&plat=0&pagesize=${limit > 0 ? limit : 100}&area_code=1&page=${page}` +
    `&rankid=${encodeURIComponent(bangid)}&with_res_tag=0&show_portrait_mv=1`;
  const body: Record<string, Object> = await fetchRecord(url, undefined, '酷狗榜单');
  if (asNumber(body['errcode']) !== 0) {
    throw new Error('酷狗榜单接口返回异常');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  return {
    list: kgFilterBoardSongs(asObjectArray(data['info'])),
    total: asNumber(data['total']),
    info: emptyListInfo(name),
  };
}

function kgFilterBoardSongs(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const hash: string = asString(item['hash']);
    const size128: number = asNumber(item['filesize']);
    if (size128 !== 0) {
      addType(types, map, '128k', sizeFormate(size128), hash);
    }
    const size320: number = asNumber(item['320filesize']);
    if (size320 !== 0) {
      addType(types, map, '320k', sizeFormate(size320), asString(item['320hash']));
    }
    const sizeFlac: number = asNumber(item['sqfilesize']);
    if (sizeFlac !== 0) {
      addType(types, map, 'flac', sizeFormate(sizeFlac), asString(item['sqhash']));
    }
    const sizeHigh: number = asNumber(item['filesize_high']);
    if (sizeHigh !== 0) {
      addType(types, map, 'flac24bit', sizeFormate(sizeHigh), asString(item['hash_high']));
    }
    const seed: SongSeed = {
      singer: joinSingerField(item['authors'], 'author_name'),
      name: decodeName(asString(item['songname'])),
      albumName: decodeName(asString(item['remark'])),
      albumId: asString(item['album_id']),
      songmid: asString(item['audio_id']),
      source: 'kg',
      interval: formatPlayTime(asNumber(item['duration'])),
      img: '',
      types: types,
      _types: map,
      hash: hash,
    };
    list.push(createSong(seed));
  }
  return list;
}

// ================================================================== 咪咕 mg

const MG_SORTS: LxSortItem[] = [
  { name: '推荐', tid: 'recommend', id: '15127315' },
];
const MG_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 ' +
    '(KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
  'Referer': 'https://m.music.migu.cn/',
};
const MG_SUCCESS: string = '000000';

async function mgPlaylists(sortId: string, page: number): Promise<LxPlaylistItem[]> {
  // 咪咕目前只有「推荐」一个页签，sortId 留着是为了和其它平台保持同一个调用形状
  void sortId;
  const url: string = 'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0' +
    `?templateVersion=2&pageNo=${page}`;
  const body: Record<string, Object> = await fetchRecord(url, { headers: MG_HEADERS }, '咪咕歌单');
  if (asString(body['code']) !== MG_SUCCESS) {
    throw new Error('咪咕歌单接口返回异常');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  if (data['contents'] !== undefined) {
    return mgFilterPlaylistsByContents(asObjectArray(data['contents']));
  }
  const groups: Object[] = asObjectArray(data['contentItemList']);
  if (groups.length > 1) {
    return mgFilterPlaylists(asObjectArray(asRecord(groups[1])['itemList']));
  }
  return [];
}

/** 推荐位的数据是嵌套的 contents，只有 resType=2021 才是歌单 */
function mgFilterPlaylistsByContents(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  const seen: string[] = [];
  const stack: Object[] = rawList.slice();
  while (stack.length > 0) {
    const raw: Object | undefined = stack.shift();
    if (raw === undefined) {
      break;
    }
    const item: Record<string, Object> = asRecord(raw);
    const children: Object[] = asObjectArray(item['contents']);
    if (children.length > 0) {
      for (const child of children) {
        stack.push(child);
      }
      continue;
    }
    const resId: string = asString(item['resId']);
    if (asString(item['resType']) !== '2021' || resId.length === 0 || seen.includes(resId)) {
      continue;
    }
    seen.push(resId);
    const playlist: LxPlaylistItem = {
      id: resId,
      name: asString(item['txt']),
      author: '',
      img: asString(item['img']),
      desc: descText(asString(item['txt2'])),
      playCount: '',
      total: 0,
      time: '',
      source: 'mg',
    };
    list.push(playlist);
  }
  return list;
}

function mgFilterPlaylists(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const bars: Object[] = asObjectArray(item['barList']);
    const playlist: LxPlaylistItem = {
      id: asString(asRecord(item['logEvent'])['contentId']),
      name: asString(item['title']),
      author: '',
      img: asString(item['imageUrl']),
      desc: '',
      playCount: bars.length > 0 ? asString(asRecord(bars[0])['title']) : '',
      total: 0,
      time: '',
      source: 'mg',
    };
    list.push(playlist);
  }
  return list;
}

async function mgPlaylistDetail(id: string, page: number): Promise<LxListDetail> {
  const listUrl: string = `https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0` +
    `?pageNo=${page}&pageSize=30&playlistId=${encodeURIComponent(id)}`;
  const infoUrl: string = `https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0` +
    `?playlistId=${encodeURIComponent(id)}`;
  const body: Record<string, Object> = await fetchRecord(listUrl, { headers: MG_HEADERS }, '咪咕歌单详情');
  if (asString(body['code']) !== MG_SUCCESS) {
    throw new Error('咪咕歌单详情接口返回异常');
  }
  const data: Record<string, Object> = asRecord(body['data']);
  let info: LxListInfo = emptyListInfo('');
  try {
    const infoBody: Record<string, Object> =
      await fetchRecord(infoUrl, { headers: MG_HEADERS }, '咪咕歌单信息');
    const infoData: Record<string, Object> = asRecord(infoBody['data']);
    info = {
      name: asString(infoData['title']),
      img: asString(asRecord(infoData['imgItem'])['img']),
      desc: descText(asString(infoData['summary'])),
      author: asString(infoData['ownerName']),
      playCount: formatPlayCount(asNumber(asRecord(infoData['opNumItem'])['playNum'])),
    };
  } catch (e) {
    // 歌单信息拿不到不影响听歌，歌曲列表照常返回
  }
  return {
    list: mgFilterSongsV5(asObjectArray(data['songList'])),
    total: asNumber(data['totalCount']),
    info: info,
  };
}

/**
 * 咪咕的格式代号 -> 本工程的音质档位
 *
 * **24bit 的代号是 `ZQ24`，不是 `ZQ`**（接口实测：`PQ` / `HQ` / `SQ` / `ZQ24`）。
 * 这里原先只认 `ZQ`，于是在线歌单 / 榜单 / 歌单导入这些走 MusicList 的路径全都拿不到
 * `flac24bit` 这一档（搜索结果与歌手页走的是 MusicSearch / MusicArtist，那边是对的）。
 * `ZQ` 一并留着只是兜底，防止哪天接口真的改回这个写法。
 */
function mgFormatToQuality(formatType: string): string {
  if (formatType === 'PQ') {
    return '128k';
  }
  if (formatType === 'HQ') {
    return '320k';
  }
  if (formatType === 'SQ') {
    return 'flac';
  }
  if (formatType === 'ZQ24' || formatType === 'ZQ') {
    return 'flac24bit';
  }
  // AV3A 是咪咕自己的环绕声封装，本站放不了，不当成一档音质
  return '';
}

/**
 * 咪咕的音质条目里，文件大小字段名有两套：
 * 详情接口（audioFormats）用 isize/asize，榜单接口（newRateFormats）用 size，
 * 洛雪那边只写 size/androidSize，实际会取到 0，界面上显示成 0 B。
 */
function mgSizeOf(format: Record<string, Object>): string {
  const candidates: string[] = ['size', 'androidSize', 'isize', 'asize'];
  for (const key of candidates) {
    const size: number = asNumber(format[key]);
    if (size > 0) {
      return sizeFormate(size);
    }
  }
  return '';
}

/** V5 结构的歌曲（歌单详情）：audioFormats / singerList / img3 */
function mgFilterSongsV5(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  const seen: string[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const songId: string = asString(item['songId']);
    if (songId.length === 0 || seen.includes(songId)) {
      continue;
    }
    seen.push(songId);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    for (const formatRaw of asObjectArray(item['audioFormats'])) {
      const format: Record<string, Object> = asRecord(formatRaw);
      const quality: string = mgFormatToQuality(asString(format['formatType']));
      if (quality.length === 0) {
        continue;
      }
      addType(types, map, quality, mgSizeOf(format), '');
    }
    // img1/img2/img3 是相对路径（/data/oss/...），要补上宿主才能当封面用
    const img: string = mgImageUrl(asString(item['img3']).length > 0 ? asString(item['img3'])
      : (asString(item['img2']).length > 0 ? asString(item['img2']) : asString(item['img1'])));
    const seed: SongSeed = {
      singer: formatSingerName(item['singerList']),
      name: asString(item['songName']),
      albumName: asString(item['album']),
      albumId: asString(item['albumId']),
      songmid: songId,
      source: 'mg',
      interval: formatPlayTime(asNumber(item['duration'])),
      img: img,
      types: types,
      _types: map,
      copyrightId: asString(item['copyrightId']),
    };
    list.push(createSong(seed));
  }
  return list;
}

/** 旧结构的歌曲（榜单）：newRateFormats / artists / albumImgs / length(mm:ss) */
function mgFilterSongs(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  const seen: string[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const songId: string = asString(item['songId']);
    if (songId.length === 0 || seen.includes(songId)) {
      continue;
    }
    seen.push(songId);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const formats: Object[] = asObjectArray(item['newRateFormats']).length > 0
      ? asObjectArray(item['newRateFormats']) : asObjectArray(item['audioFormats']);
    for (const formatRaw of formats) {
      const format: Record<string, Object> = asRecord(formatRaw);
      const quality: string = mgFormatToQuality(asString(format['formatType']));
      if (quality.length === 0) {
        continue;
      }
      addType(types, map, quality, mgSizeOf(format), '');
    }
    const length: string = asString(item['length']);
    const lengthMatch: RegExpMatchArray | null = length.match(/(\d\d:\d\d)$/);
    const albums: Object[] = asObjectArray(item['albumImgs']);
    // 同 V5：榜单给的也是相对路径，补上宿主
    const img: string = mgImageUrl(albums.length > 0 ? asString(asRecord(albums[0])['img']) : '');
    const seed: SongSeed = {
      singer: formatSingerName(item['artists']),
      name: asString(item['songName']),
      albumName: asString(item['album']),
      albumId: asString(item['albumId']),
      songmid: songId,
      source: 'mg',
      interval: lengthMatch !== null ? lengthMatch[1] : '',
      img: img,
      types: types,
      _types: map,
      copyrightId: asString(item['copyrightId']),
    };
    list.push(createSong(seed));
  }
  return list;
}

async function mgBoardSongs(bangid: string, name: string): Promise<LxListDetail> {
  const url: string = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do' +
    `?columnId=${encodeURIComponent(bangid)}&needAll=0`;
  const body: Record<string, Object> = await fetchRecord(url, { headers: MG_HEADERS }, '咪咕榜单');
  if (asString(body['code']) !== MG_SUCCESS) {
    throw new Error('咪咕榜单接口返回异常');
  }
  const contents: Object[] = asObjectArray(asRecord(body['columnInfo'])['contents']);
  const objects: Object[] = [];
  for (const raw of contents) {
    objects.push(asRecord(raw)['objectInfo']);
  }
  const songs: LxMusicInfo[] = mgFilterSongs(objects);
  return { list: songs, total: songs.length, info: emptyListInfo(name) };
}

// ================================================================== QQ 音乐 tx

const TX_SORTS: LxSortItem[] = [
  { name: '最热', tid: 'hot', id: '5' },
  { name: '最新', tid: 'new', id: '2' },
];
const TX_MUSICU: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg' +
  '?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0' +
  '&platform=wk_v15.json&needNewCode=0';
/** POST 用的 musicu 端点：新版歌单详情把参数放在请求体里，query 那些参数不需要 */
const TX_MUSICU_BARE: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
/** 新版歌单详情一次取多少首（洛雪 getListDetail2 的 song_num） */
const TX_DISS_SONG_NUM: number = 1000;

/** 新版歌单详情（musicu）的请求体，字段照抄洛雪 tx/songList.js 的 getListDetail2 */
interface TxDissInfoParam {
  disstid: number;
  userinfo: number;
  tag: number;
  orderlist: number;
  song_begin: number;
  song_num: number;
  onlysonglist: number;
  enc_host_uin: string;
}

interface TxDissInfoModule {
  module: string;
  method: string;
  param: TxDissInfoParam;
}

interface TxDissInfoComm {
  cv: number;
  ct: number;
  format: string;
  inCharset: string;
  outCharset: string;
  platform: string;
  needNewCode: number;
  uin: number;
}

interface TxDissInfoPayload {
  comm: TxDissInfoComm;
  req_1: TxDissInfoModule;
}
/** 榜单页里每一行的原始片段（只用来切分） */
const TX_PERIOD_LIST = /data-listname="(.+?)" data-tid=".*?\/(.+?)" data-date="(.+?)" .+?<\/i>/g;
/** 从单行里取出「榜单 id -> 周期」；不能带 g，需要分组 */
const TX_PERIOD_ROW = /data-listname="(.+?)" data-tid=".*?\/(.+?)" data-date="(.+?)" .+?<\/i>/;

/** QQ 音乐请求体的固定结构（musicu.fcg 的 data 字段） */
interface TxComm {
  cv: number;
  ct: number;
}

interface TxPlaylistParam {
  id: number;
  sin: number;
  size: number;
  order: number;
  cur_page: number;
}

interface TxPlaylistModule {
  method: string;
  param: TxPlaylistParam;
  module: string;
}

interface TxPlaylistPayload {
  comm: TxComm;
  playlist: TxPlaylistModule;
}

interface TxToplistParam {
  topid: number;
  num: number;
  period?: string;
}

interface TxBoardComm {
  uin: number;
  format: string;
  ct: number;
  cv: number;
}

interface TxToplistModule {
  module: string;
  method: string;
  param: TxToplistParam;
}

interface TxBoardPayload {
  toplist: TxToplistModule;
  comm: TxBoardComm;
}

async function txPlaylists(sortId: string, page: number): Promise<LxPlaylistItem[]> {
  const param: TxPlaylistParam = {
    id: 10000000,
    sin: 36 * (page - 1),
    size: 36,
    order: Number.parseInt(sortId, 10),
    cur_page: page,
  };
  const module: TxPlaylistModule = {
    method: 'get_playlist_by_tag',
    param: param,
    module: 'playlist.PlayListPlazaServer',
  };
  const comm: TxComm = { cv: 1602, ct: 20 };
  const payload: TxPlaylistPayload = { comm: comm, playlist: module };
  const url: string = `${TX_MUSICU}&data=${encodeURIComponent(JSON.stringify(payload))}`;
  const body: Record<string, Object> = await fetchRecord(url, undefined, 'QQ 歌单');
  if (asNumber(body['code']) !== 0) {
    throw new Error('QQ 歌单接口返回异常');
  }
  const data: Record<string, Object> = asRecord(asRecord(body['playlist'])['data']);
  return txFilterPlaylists(asObjectArray(data['v_playlist']));
}

function txFilterPlaylists(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const ids: Object[] = asObjectArray(item['song_ids']);
    const modify: number = asNumber(item['modify_time']);
    const playlist: LxPlaylistItem = {
      id: asString(item['tid']),
      name: asString(item['title']),
      author: asString(asRecord(item['creator_info'])['nick']),
      img: asString(item['cover_url_medium']),
      desc: descText(asString(item['desc'])),
      playCount: formatPlayCount(asNumber(item['access_num'])),
      total: ids.length,
      time: modify > 0 ? dateFormat(modify * 1000) : '',
      source: 'tx',
    };
    list.push(playlist);
  }
  return list;
}

/**
 * QQ 歌单详情
 *
 * 两条路都留着，但顺序与洛雪相反：洛雪先打老的 fcg_ucc_getcdinfo_byids_cp、
 * 失败再走新版 musicu；实测老接口已经下线（code=-1，见 tools/live_list_probe.js），
 * 所以这里新版优先、老接口兜底。两条路的 songlist 是同一套字段，共用 txFilterSongs。
 *
 * **必须真翻页**：新版接口一次最多给 song_num 首（实测传 1000 只回 999 首），而 QQ 上
 * 上千首的歌单并不少见（实测过一张 1919 首的）。早先这里把整张歌单当成一页取、
 * page 参数直接丢掉，getPlaylistDetailAll 第二页拿到的还是同一批歌，判定「没有新歌」
 * 就停了 —— 于是超过 1000 首的部分被**静默丢掉**（不报错、歌单名也对，只是少了）。
 * 现在按 song_begin = (page-1) * 每页条数 真翻页。
 */
async function txPlaylistDetail(id: string, page: number): Promise<LxListDetail> {
  // 老接口不分页（一次给全），只有第一页才值得退回它：后面的页退回会把整张歌单再给一遍
  if (page > 1) {
    return await txPlaylistDetailMusicu(id, page);
  }
  try {
    return await txPlaylistDetailMusicu(id, page);
  } catch (e) {
    return await txPlaylistDetailLegacy(id);
  }
}

/** 新版：music.srfDissInfo.aiDissInfo / uniform_get_Dissinfo（洛雪 tx/songList.js 的 getListDetail2） */
async function txPlaylistDetailMusicu(id: string, page: number): Promise<LxListDetail> {
  const param: TxDissInfoParam = {
    disstid: asNumber(id),
    userinfo: 1,
    tag: 1,
    orderlist: 1,
    song_begin: (page > 0 ? page - 1 : 0) * TX_DISS_SONG_NUM,
    song_num: TX_DISS_SONG_NUM,
    onlysonglist: 0,
    enc_host_uin: '',
  };
  const module: TxDissInfoModule = {
    module: 'music.srfDissInfo.aiDissInfo',
    method: 'uniform_get_Dissinfo',
    param: param,
  };
  const comm: TxDissInfoComm = {
    cv: 4747474,
    ct: 24,
    format: 'json',
    inCharset: 'utf-8',
    outCharset: 'utf-8',
    platform: 'yqq.json',
    needNewCode: 1,
    uin: 0,
  };
  const payload: TxDissInfoPayload = { comm: comm, req_1: module };
  const headers: Record<string, string> = {
    'Origin': 'https://y.qq.com',
    'Referer': `https://y.qq.com/n/yqq/playsquare/${id}.html`,
  };
  const body: Record<string, Object> =
    await fetchRecord(TX_MUSICU_BARE, { method: 'post', headers: headers, body: payload },
      'QQ 歌单详情');
  if (asNumber(body['code']) !== 0) {
    throw new Error(`QQ 歌单详情接口返回异常（code=${asString(body['code'])}）`);
  }
  const req: Record<string, Object> = asRecord(body['req_1']);
  const data: Record<string, Object> = asRecord(req['data']);
  const songs: Object[] = asObjectArray(data['songlist']);
  if (asNumber(req['code']) !== 0) {
    throw new Error('QQ 歌单详情接口没取到歌曲');
  }
  if (songs.length === 0 && page <= 1) {
    throw new Error('QQ 歌单详情接口没取到歌曲');
  }
  // 翻到最后一页之后（歌单被改短、或 total 与页数对不齐时）接口仍回 code=0、songlist 为空：
  // 这是「没有下一页」，不是失败 —— 交给 getPlaylistDetailAll 的「没有新歌」判定收尾
  const dir: Record<string, Object> = asRecord(data['dirinfo']);
  const total: number = asNumber(data['total_song_num']);
  const info: LxListInfo = {
    name: asString(dir['title']),
    img: asString(dir['picurl']),
    desc: descText(asString(dir['desc'])),
    author: asString(dir['host_nick']),
    playCount: formatPlayCount(asNumber(dir['listennum'])),
  };
  return { list: txFilterSongs(songs), total: total > 0 ? total : songs.length, info: info };
}

/** 老接口（cdlist）：QQ 已下线，只作为兜底留着 */
async function txPlaylistDetailLegacy(id: string): Promise<LxListDetail> {
  const url: string = 'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg' +
    `?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=${encodeURIComponent(id)}` +
    '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0' +
    '&platform=yqq.json&needNewCode=0';
  const headers: Record<string, string> = {
    'Origin': 'https://y.qq.com',
    'Referer': `https://y.qq.com/n/yqq/playsquare/${id}.html`,
  };
  const body: Record<string, Object> = await fetchRecord(url, { headers: headers }, 'QQ 歌单详情');
  const cdlist: Object[] = asObjectArray(body['cdlist']);
  if (asNumber(body['code']) !== 0 || cdlist.length === 0) {
    throw new Error('QQ 歌单详情接口返回异常');
  }
  const cd: Record<string, Object> = asRecord(cdlist[0]);
  const songs: Object[] = asObjectArray(cd['songlist']);
  const info: LxListInfo = {
    name: asString(cd['dissname']),
    img: asString(cd['logo']),
    desc: descText(asString(cd['desc'])),
    author: asString(cd['nickname']),
    playCount: formatPlayCount(asNumber(cd['visitnum'])),
  };
  return { list: txFilterSongs(songs), total: songs.length, info: info };
}

function txFilterSongs(rawList: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const file: Record<string, Object> = asRecord(item['file']);
    const album: Record<string, Object> = asRecord(item['album']);
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const size128: number = asNumber(file['size_128mp3']);
    if (size128 !== 0) {
      addType(types, map, '128k', sizeFormate(size128), '');
    }
    const size320: number = asNumber(file['size_320mp3']);
    if (size320 !== 0) {
      addType(types, map, '320k', sizeFormate(size320), '');
    }
    const sizeFlac: number = asNumber(file['size_flac']);
    if (sizeFlac !== 0) {
      addType(types, map, 'flac', sizeFormate(sizeFlac), '');
    }
    const sizeHires: number = asNumber(file['size_hires']);
    if (sizeHires !== 0) {
      addType(types, map, 'flac24bit', sizeFormate(sizeHires), '');
    }
    const albumName: string = asString(album['name']);
    const albumMid: string = asString(album['mid']);
    const singers: Object[] = asObjectArray(item['singer']);
    let img: string = '';
    if (albumName.length === 0 || albumName === '空') {
      if (singers.length > 0) {
        img = `https://y.gtimg.cn/music/photo_new/T001R500x500M000${asString(asRecord(singers[0])['mid'])}.jpg`;
      }
    } else {
      img = `https://y.gtimg.cn/music/photo_new/T002R500x500M000${albumMid}.jpg`;
    }
    const seed: SongSeed = {
      singer: formatSingerName(item['singer']),
      name: asString(item['title']),
      albumName: albumName,
      albumId: albumMid,
      songmid: asString(item['mid']),
      source: 'tx',
      interval: formatPlayTime(asNumber(item['interval'])),
      img: img,
      types: types,
      _types: map,
      songId: asString(item['id']),
      albumMid: albumMid,
      strMediaMid: asString(file['media_mid']),
    };
    list.push(createSong(seed));
  }
  return list;
}

/** 榜单的周期（period）要从榜单页抓，抓不到就留空让服务端用当前周期 */
async function txBoardPeriod(bangid: string): Promise<string> {
  try {
    const result: FetchResult = await httpFetch('https://c.y.qq.com/node/pc/wk_v15/top.html',
      { rawText: true, timeout: 12000 });
    const html: string = resultText(result, 'QQ 榜单页');
    const rows: RegExpMatchArray | null = html.match(TX_PERIOD_LIST);
    if (rows === null) {
      return '';
    }
    for (const row of rows) {
      const matched: RegExpMatchArray | null = row.match(TX_PERIOD_ROW);
      if (matched === null) {
        continue;
      }
      if (matched[2] === bangid) {
        return matched[3];
      }
    }
    return '';
  } catch (e) {
    return '';
  }
}

async function txBoardSongs(bangid: string, name: string,
  limit: number = 0): Promise<LxListDetail> {
  const period: string = await txBoardPeriod(bangid);
  const param: TxToplistParam = {
    topid: Number.parseInt(bangid, 10),
    num: limit > 0 ? limit : 300,
  };
  if (period.length > 0) {
    param.period = period;
  }
  const module: TxToplistModule = {
    module: 'musicToplist.ToplistInfoServer',
    method: 'GetDetail',
    param: param,
  };
  const comm: TxBoardComm = { uin: 0, format: 'json', ct: 20, cv: 1859 };
  const payload: TxBoardPayload = { toplist: module, comm: comm };
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
  };
  const body: Record<string, Object> = await fetchRecord(TX_MUSICU,
    { method: 'post', headers: headers, body: payload }, 'QQ 榜单');
  if (asNumber(body['code']) !== 0) {
    throw new Error('QQ 榜单接口返回异常');
  }
  const songs: Object[] = asObjectArray(asRecord(asRecord(body['toplist'])['data'])['songInfoList']);
  return { list: txFilterSongs(songs), total: songs.length, info: emptyListInfo(name) };
}

// ================================================================== 网易 wy

const WY_SORTS: LxSortItem[] = [
  { name: '最热', tid: 'hot', id: 'hot' },
];
/**
 * 网易明文接口（歌单广场 /api/playlist/list、歌单详情 /api/v6/playlist/detail、
 * 歌曲详情 /api/song/detail）的公共请求头。
 *
 * `Cookie: os=pc` 这一行是必需的，不是可有可无的装饰：不带它，歌单详情返回的
 * `playlist.tracks` 会被砍成开头若干首的「试听预览」——实测普通用户歌单恒 10 首、
 * 「我喜欢的音乐」6 首（同一次请求里 `playlist.trackIds` 却是完整的一整份）。
 * 这个 cookie 只声明客户端形态，不需要登录态（把 `MUSIC_U` 写空串没有用）。
 */
const WY_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/60.0.3112.90 Safari/537.36',
  'Referer': 'https://music.163.com/',
  'Origin': 'https://music.163.com',
  'Cookie': 'os=pc',
};

/**
 * 网易推荐歌单。
 * 洛雪走 weapi 加密，这里用明文 /api 接口（不加密、不登录），能通就通，不通会抛错。
 */
async function wyPlaylists(page: number): Promise<LxPlaylistItem[]> {
  const offset: number = 30 * (page - 1);
  const form: Record<string, string> = {
    'cat': '全部',
    'order': 'hot',
    'limit': '30',
    'offset': `${offset}`,
    'total': 'true',
  };
  const body: Record<string, Object> = await fetchRecord('https://music.163.com/api/playlist/list',
    { method: 'post', headers: WY_HEADERS, form: form }, '网易歌单');
  if (asNumber(body['code']) !== 200) {
    throw new Error('网易歌单接口返回异常');
  }
  return wyFilterPlaylists(asObjectArray(body['playlists']));
}

function wyFilterPlaylists(rawList: Object[]): LxPlaylistItem[] {
  const list: LxPlaylistItem[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const createTime: number = asNumber(item['createTime']);
    const playlist: LxPlaylistItem = {
      id: asString(item['id']),
      name: asString(item['name']),
      author: asString(asRecord(item['creator'])['nickname']),
      img: asString(item['coverImgUrl']),
      desc: descText(asString(item['description'])),
      playCount: formatPlayCount(asNumber(item['playCount'])),
      total: asNumber(item['trackCount']),
      time: createTime > 0 ? dateFormat(createTime) : '',
      source: 'wy',
    };
    list.push(playlist);
  }
  return list;
}

/** 网易歌曲详情（/api/song/detail）一批最多塞多少 id（照洛雪与同工作区 RzdMusic 的做法按 100 批） */
const WY_SONG_BATCH: number = 100;

/**
 * 网易歌单/榜单歌曲：明文 /api/v6/playlist/detail（榜单就是一个特殊歌单）。
 * 响应里有 playlist.tracks 与顶层 privileges，正好配成一份带音质的歌曲列表。
 *
 * ⚠️ 这里必须按 `trackIds` 取歌，不能只信 `tracks`：网易对「非官方歌单」会把
 * `tracks` 砍成开头若干首（带 `Cookie: os=pc` 之后实测才是全量，见 WY_HEADERS；
 * 万一 cookie 那条路又被封，缺的那批就在这里按 id 补回来）。完整曲目 id 一直在
 * 同响应的 `playlist.trackIds` 里 —— 原实现只拿它算了 `total`，于是出现
 * 「共 27 首」却只有 10 行、导入只落 10 首这种事。
 */
async function wyPlaylistDetail(id: string, page: number, name: string,
  limit: number = 0): Promise<LxListDetail> {
  // 这个接口一次最多给 1000 首，够一屏歌单用，不做分页
  void page;
  const size: number = limit > 0 ? limit : 1000;
  const url: string =
    `https://music.163.com/api/v6/playlist/detail?id=${encodeURIComponent(id)}&n=${size}&s=8`;
  const body: Record<string, Object> = await fetchRecord(url, { headers: WY_HEADERS }, '网易歌单详情');
  if (asNumber(body['code']) !== 200) {
    throw new Error('网易歌单详情接口返回异常');
  }
  const playlist: Record<string, Object> = asRecord(body['playlist']);
  const songs: LxMusicInfo[] = wyFilterSongs(asObjectArray(playlist['tracks']),
    asObjectArray(body['privileges']));
  const trackIds: string[] = wyTrackIdsOf(playlist['trackIds']);
  /**
   * 限量取（首页那几行）时**不要按 trackIds 补齐**：榜单的 trackIds 是完整的几百首，
   * 补齐会把整张榜用 `/api/song/detail` 一批批拉回来 —— 越限越慢。
   */
  const missing: string[] = limit > 0 ? [] : wyMissingTrackIds(trackIds, songs);
  if (missing.length > 0) {
    const rest: LxMusicInfo[] = await wySongsByIds(missing);
    for (const song of rest) {
      songs.push(song);
    }
  }
  let infoName: string = asString(playlist['name']);
  if (infoName.length === 0) {
    infoName = name;
  }
  const info: LxListInfo = {
    name: infoName,
    img: asString(playlist['coverImgUrl']),
    desc: descText(asString(playlist['description'])),
    author: asString(asRecord(playlist['creator'])['nickname']),
    playCount: formatPlayCount(asNumber(playlist['playCount'])),
  };
  const total: number = trackIds.length > 0 ? trackIds.length : songs.length;
  return { list: songs, total: total, info: info };
}

/** `trackIds` 是一串 `{id}`，按原顺序取出字符串 id（丢空、去重） */
function wyTrackIdsOf(raw: Object | undefined): string[] {
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of asObjectArray(raw)) {
    const id: string = asString(asRecord(item)['id']);
    if (id.length > 0 && !seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * `trackIds` 里还没出现在 `songs` 里的那些 id —— 接口截断时就是要补的这批。
 *
 * 补回来的歌是接在 `songs` 后面的，顺序正好对：`tracks` 就是 `trackIds` 的前缀
 * （网易按歌单顺序回前若干首），接上剩下的就是完整歌单顺序。
 */
function wyMissingTrackIds(trackIds: string[], songs: LxMusicInfo[]): string[] {
  if (trackIds.length <= songs.length) {
    return [];
  }
  const have: Set<string> = new Set<string>();
  for (const song of songs) {
    have.add(song.songmid);
  }
  const missing: string[] = [];
  for (const id of trackIds) {
    if (!have.has(id)) {
      missing.push(id);
    }
  }
  return missing;
}

/**
 * 老格式歌曲折成 v6 详情那套字段名。
 *
 * 同一首歌，两颗接口给的字段名不一样：
 *   /api/v6/playlist/detail 的 tracks：`ar` / `al` / `dt` / `l` / `m` / `h` / `sq` / `hr`
 *   /api/song/detail 的 songs ：`artists` / `album` / `duration` / `lMusic` / `mMusic` / `hMusic` / `sqMusic` / `hrMusic`
 * 折过去之后就能跟 tracks 一样丢给 wyFilterSongs，不必再维护第二套组歌逻辑。
 * 两边字段都在时以 v6 的写法为准，那时这层等于透明（接口哪天统一了也不用改这里）。
 */
function wyNormalizeSong(raw: Object): Record<string, Object> {
  const item: Record<string, Object> = asRecord(raw);
  const out: Record<string, Object> = {};
  for (const key of Object.keys(item)) {
    out[key] = item[key];
  }
  const aliases: string[][] = [
    ['ar', 'artists'], ['al', 'album'], ['dt', 'duration'],
    ['l', 'lMusic'], ['m', 'mMusic'], ['h', 'hMusic'], ['sq', 'sqMusic'], ['hr', 'hrMusic'],
  ];
  for (const pair of aliases) {
    if (out[pair[0]] === undefined && item[pair[1]] !== undefined) {
      out[pair[0]] = item[pair[1]];
    }
  }
  return out;
}

/**
 * 由老格式的 lMusic/mMusic/hMusic/sqMusic/hrMusic 反推一个 v6 那样的 privilege（音质档位）。
 *
 * `/api/song/detail` 不返回 privileges，而 wyFilterSongs 是靠 privilege 决定列哪几档音质的，
 * 不给的话补回来的歌会缺音质标记（能播，但列表上看不出有 320k / 无损）。
 * 有哪一档就报到哪一档；这只是一个上限，真正能不能放还是播放时由源规则按 id 去问。
 */
function wyPrivilegeOf(song: Record<string, Object>): Record<string, Object> {
  const hires: number = wyBitrateOf(song, 'hr');
  const lossless: number = wyBitrateOf(song, 'sq');
  let maxbr: number = 0;
  if (hires > 0 || lossless > 0) {
    maxbr = 999000;
  } else if (wyBitrateOf(song, 'h') > 0) {
    maxbr = 320000;
  } else if (wyBitrateOf(song, 'm') > 0) {
    maxbr = 192000;
  } else if (wyBitrateOf(song, 'l') > 0) {
    maxbr = 128000;
  }
  return {
    'id': asString(song['id']),
    'maxbr': maxbr,
    'maxBrLevel': hires > 0 ? 'hires' : '',
  };
}

/** 某一档音频对象的码率（0 = 这档没有） */
function wyBitrateOf(song: Record<string, Object>, key: string): number {
  return asNumber(asRecord(song[key])['bitrate']);
}

/**
 * 按 id 批量取歌（明文 /api/song/detail），补 tracks 被截断时缺的那些。
 *
 * 这个接口回的是老 schema（见 wyNormalizeSong），且不带 privileges（音质档位自己推）。
 * 单批失败只跳过这一批：能补多少补多少，不因为补歌失败把整张歌单变成错误。
 */
async function wySongsByIds(ids: string[]): Promise<LxMusicInfo[]> {
  const out: LxMusicInfo[] = [];
  for (let start = 0; start < ids.length; start += WY_SONG_BATCH) {
    const batch: string[] = ids.slice(start, start + WY_SONG_BATCH);
    const queries: string[] = [];
    for (const id of batch) {
      queries.push(`{"id":${id}}`);
    }
    const url: string = `https://music.163.com/api/song/detail?ids=` +
      `${encodeURIComponent(JSON.stringify(batch))}&c=${encodeURIComponent(`[${queries.join(',')}]`)}`;
    try {
      const body: Record<string, Object> = await fetchRecord(url, { headers: WY_HEADERS }, '网易歌曲详情');
      const songs: Object[] = [];
      const privileges: Object[] = [];
      const given: Object[] = asObjectArray(body['privileges']);
      for (const one of asObjectArray(body['songs'])) {
        const song: Record<string, Object> = wyNormalizeSong(one);
        songs.push(song);
        privileges.push(given.length > 0 ? wyFindPrivilege(given, asString(song['id'])) : wyPrivilegeOf(song));
      }
      for (const song of wyFilterSongs(songs, privileges)) {
        out.push(song);
      }
    } catch (e) {
      // 这一批没补到就算了，剩下的还能用
    }
  }
  return out;
}

function wyFilterSongs(rawList: Object[], privileges: Object[]): LxMusicInfo[] {
  const list: LxMusicInfo[] = [];
  for (let index = 0; index < rawList.length; index++) {
    const item: Record<string, Object> = asRecord(rawList[index]);
    const songId: string = asString(item['id']);
    const privilege: Record<string, Object> = wyFindPrivilege(privileges, songId);
    // 没有对应权限信息时也照样列出来（音质未知，播放时按源声明的音质协商）
    const types: LxQualityItem[] = [];
    const map: Record<string, LxQualityItem> = {};
    const maxBr: number = asNumber(privilege['maxbr']);
    if (asString(privilege['maxBrLevel']) === 'hires') {
      addType(types, map, 'flac24bit',
        asString(privilege['maxBrLevel']).length > 0 ? wySizeOf(item, 'hr') : '', '');
    }
    if (maxBr === 999000) {
      addType(types, map, 'flac', wySizeOf(item, 'sq'), '');
    }
    if (maxBr === 999000 || maxBr === 320000) {
      addType(types, map, '320k', wySizeOf(item, 'h'), '');
    }
    if (maxBr === 999000 || maxBr === 320000 || maxBr === 192000 || maxBr === 128000) {
      addType(types, map, '128k', wySizeOf(item, 'l'), '');
    }
    // 拓展档（母带 / 沉浸声 / 杜比全景声）与搜索那条路用同一套规则补进 _types：
    // 设置里没开「拓展音质」时它们不参与协商，开了才会出现在播放页的音质面板里
    appendWyExtendQualities(privilege, item, types, map);
    const album: Record<string, Object> = asRecord(item['al']);
    const pc: Record<string, Object> = asRecord(item['pc']);
    const hasPc: boolean = Object.keys(pc).length > 0;
    const seed: SongSeed = {
      singer: hasPc ? asString(pc['ar']) : formatSingerName(item['ar']),
      name: hasPc ? asString(pc['sn']) : asString(item['name']),
      albumName: hasPc ? asString(pc['alb']) : asString(album['name']),
      albumId: asString(album['id']),
      songmid: songId,
      source: 'wy',
      interval: formatPlayTime(asNumber(item['dt']) / 1000),
      img: asString(album['picUrl']),
      types: types,
      _types: map,
    };
    list.push(createSong(seed));
  }
  return list;
}

function wyFindPrivilege(privileges: Object[], songId: string): Record<string, Object> {
  for (const raw of privileges) {
    const privilege: Record<string, Object> = asRecord(raw);
    if (asString(privilege['id']) === songId) {
      return privilege;
    }
  }
  return {};
}

/** 取某档音质的文件大小（item.h / item.l / item.sq / item.hr 的 size） */
function wySizeOf(item: Record<string, Object>, key: string): string {
  const detail: Record<string, Object> = asRecord(item[key]);
  const size: number = asNumber(detail['size']);
  return size > 0 ? sizeFormate(size) : '';
}

// ================================================================== 榜单数据
//
// 洛雪各平台的榜单列表就是写死的数组（上游的 getBoards 也是返回这个数组），
// 这里只保留有名字的前若干张榜 —— 排在后面的多是「XX 地区榜 / 语种榜」这类长尾。

function boardsOf(source: string, pairs: string[][]): LxBoardItem[] {
  const list: LxBoardItem[] = [];
  for (const pair of pairs) {
    const board: LxBoardItem = {
      id: `${source}__${pair[0]}`,
      name: pair[1],
      bangid: pair[0],
      source: source,
    };
    list.push(board);
  }
  return list;
}

const KW_BOARDS: LxBoardItem[] = boardsOf('kw', [
  ['93', '飙升榜'], ['17', '新歌榜'], ['16', '热歌榜'], ['158', '抖音热歌榜'],
  ['292', '铃声榜'], ['284', '热评榜'], ['290', 'ACG新歌榜'], ['286', '台湾KKBOX榜'],
  ['279', '冬日暖心榜'], ['281', '巴士随身听榜'], ['255', 'KTV点唱榜'], ['280', '家务进行曲榜'],
  ['282', '熬夜修仙榜'], ['283', '枕边轻音乐榜'], ['278', '古风音乐榜'], ['264', '华语榜'],
]);

const KG_BOARDS: LxBoardItem[] = boardsOf('kg', [
  ['8888', 'TOP500'], ['6666', '飙升榜'], ['59703', '蜂鸟流行音乐榜'], ['52144', '抖音热歌榜'],
  ['52767', '快手热歌榜'], ['24971', 'DJ热歌榜'], ['23784', '网络红歌榜'], ['44412', '说唱先锋榜'],
  ['31308', '内地榜'], ['33160', '电音榜'], ['31313', '香港地区榜'], ['51341', '民谣榜'],
  ['54848', '台湾地区榜'], ['31310', '欧美榜'], ['33162', 'ACG新歌榜'], ['31311', '韩国榜'],
]);

const MG_BOARDS: LxBoardItem[] = boardsOf('mg', [
  ['27553319', '新歌榜'], ['27186466', '热歌榜'], ['27553408', '原创榜'],
  ['75959118', '音乐风向榜'], ['76557036', '彩铃分贝榜'], ['76557745', '会员臻爱榜'],
  ['23189800', '港台榜'], ['23189399', '内地榜'], ['19190036', '欧美榜'], ['83176390', '国风金曲榜'],
]);

const TX_BOARDS: LxBoardItem[] = boardsOf('tx', [
  ['4', '流行指数榜'], ['26', '热歌榜'], ['27', '新歌榜'], ['62', '飙升榜'],
  ['58', '说唱榜'], ['57', '喜力电音榜'], ['28', '网络歌曲榜'], ['5', '内地榜'],
  ['3', '欧美榜'], ['59', '香港地区榜'], ['16', '韩国榜'], ['60', '抖快榜'],
  ['29', '影视金曲榜'], ['17', '日本榜'], ['52', '腾讯音乐人原创榜'], ['36', 'K歌金曲榜'],
]);

const WY_BOARDS: LxBoardItem[] = boardsOf('wy', [
  ['19723756', '飙升榜'], ['3779629', '新歌榜'], ['2884035', '原创榜'], ['3778678', '热歌榜'],
  ['991319590', '说唱榜'], ['71384707', '古典榜'], ['1978921795', '电音榜'], ['5453912201', '黑胶VIP爱听榜'],
  ['71385702', 'ACG榜'], ['745956260', '韩语榜'], ['10520166', '国电榜'], ['180106', 'UK排行榜周榜'],
  ['60198', '美国Billboard榜'], ['3812895', 'Beatport全球电子舞曲榜'], ['21845217', 'KTV唛榜'],
  ['60131', '日本Oricon榜'],
]);
