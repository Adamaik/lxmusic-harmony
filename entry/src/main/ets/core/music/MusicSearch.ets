import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
import { aes128EcbPkcs7HexUpper, md5Hex, sha1Hex, toBase64, utf8Bytes } from './LxCrypto';

/**
 * 内置音乐搜索（宿主侧）
 *
 * 为什么需要它：洛雪的自定义源（源规则）只负责「给定 musicInfo -> 播放链接」，
 * 协议里没有搜索能力（见 user-api-preload.js 的 supportActions：只有 musicUrl/lyric/pic）。
 * 洛雪 App 里搜索来自内置的平台 SDK（src/utils/musicSdk/{kw,kg,tx,wy,mg}/musicSearch.js），
 * 所以这里把同样的搜索逻辑移植到 ArkTS，搜索出 musicInfo 后再交给导入的源规则解析播放链接。
 *
 * 已移植：酷我(kw)、酷狗(kg)、咪咕(mg)、QQ(tx)、网易(wy)。
 * 未移植：喜马拉雅(xm) —— 洛雪里整块被注释掉的死代码。
 *
 * 聚合搜索（searchMusicAll）也照洛雪 store/search/music/action.js 的 setLists：
 * 把各平台这一页的结果合起来 → 去重（dedupeSongs）→ 按与关键词的相似度重排
 * （sortByRelevance），再配合 total/allPage 翻页。以前是「每个平台轮流取一条」交错拼接、
 * 不排序也不去重、且只取第一页，表现出来就是「按歌手搜索时重复一大堆、同时还少一大堆」。
 *
 * ⚠️ wy 待复核：2026-09 直接请求网易 eapi 端点（搜索 /api/search/song/list/page 与
 * 歌词 /api/song/lyric/v1）都返回 code:404，本条链路很可能已经不通。
 */

export interface LxQualityItem {
  type: string;
  size: string;
  /** 酷狗的播放链接需要 hash */
  hash?: string;
}

/** 洛雪旧版 musicInfo，与源脚本 request.info.musicInfo 结构一致 */
export interface LxMusicInfo {
  name: string;
  singer: string;
  source: string;
  songmid: string;
  albumName: string;
  albumId: string;
  interval: string;
  img: string;
  /**
   * 酷狗用 hash 取流；kw/mg/tx/wy 在洛雪里根本没有这个字段。
   * 源脚本普遍写 `musicInfo.hash ?? musicInfo.songmid`，所以这类平台必须「不写这个字段」，
   * 写空串会让 ?? 不回退，导致 songId 变成空串。
   */
  hash?: string;
  /** QQ 音乐取流需要 */
  songId?: string;
  albumMid?: string;
  strMediaMid?: string;
  /** 咪咕用 */
  copyrightId?: string;
  types: LxQualityItem[];
  _types: Record<string, LxQualityItem>;
  typeUrl: Record<string, string>;
  lrc: string | null;
  otherSource: string | null;
}

/** 已实现内置搜索的平台 */
export const SEARCH_PLATFORMS: string[] = ['kw', 'kg', 'mg', 'tx', 'wy'];

export function isSearchSupported(source: string): boolean {
  return SEARCH_PLATFORMS.includes(source);
}

/**
 * 单个平台一页的搜索结果
 *
 * total / allPage 是**翻页**的依据：以前只往回带 list，界面就永远只能看到第一页，
 * 搜一个歌手只能拿到 30 首（酷我给「周杰伦」报的 TOTAL 是 3295）—— 这正是
 * 「按歌手搜歌，歌少了一大半」的原因，见 docs/DEFECTS.md D-008。
 */
export interface LxSearchPage {
  list: LxMusicInfo[];
  /** 该平台报的命中总数；接口没给就是 0 */
  total: number;
  /** 总页数（永远 >= page，见 pagesOf） */
  allPage: number;
  limit: number;
}

/**
 * 按总数算总页数；总数拿不到就按「这一页满没满」推。
 *
 * 一页返回 0 条 = 这个平台到底了（接口报错在各自的 search* 里抛错，不会走到这），
 * 把 allPage 钉在 page 上，界面就不会再对着空页反复「上拉加载更多」。
 */
function pagesOf(total: number, page: number, got: number, limit: number): number {
  if (got === 0 && page > 1) {
    return page;
  }
  if (total > 0) {
    const pages: number = Math.ceil(total / limit);
    return pages > page ? pages : page;
  }
  return got >= limit ? page + 1 : page;
}

function pageOf(list: LxMusicInfo[], total: number, page: number, limit: number): LxSearchPage {
  return { list: list, total: total, allPage: pagesOf(total, page, list.length, limit), limit: limit };
}

// ------------------------------------------------------------------ 基础工具

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

/** 洛雪的 formatPlayTime：秒 -> mm:ss，0 显示 --/-- */
export function formatPlayTime(seconds: number): string {
  const m: number = Math.trunc(seconds / 60);
  const s: number = Math.trunc(seconds % 60);
  if (m === 0 && s === 0) {
    return '--/--';
  }
  return `${m < 10 ? '0' + m : m}:${s < 10 ? '0' + s : s}`;
}

/** 洛雪的 sizeFormate：字节 -> 可读大小 */
export function sizeFormate(size: number): string {
  if (!size) {
    return '0 B';
  }
  const units: string[] = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  const power: number = Math.floor(Math.log(size) / Math.log(1024));
  const index: number = power < 0 ? 0 : (power > 4 ? 4 : power);
  return `${(size / Math.pow(1024, index)).toFixed(2)} ${units[index]}`;
}

function decodeEntity(entity: string): string | null {
  if (entity === 'amp') {
    return '&';
  }
  if (entity === 'lt') {
    return '<';
  }
  if (entity === 'gt') {
    return '>';
  }
  if (entity === 'quot') {
    return '"';
  }
  if (entity === 'apos') {
    return '\'';
  }
  if (entity === 'nbsp') {
    return ' ';
  }
  if (entity.startsWith('#x') || entity.startsWith('#X')) {
    const code: number = Number.parseInt(entity.substring(2), 16);
    return Number.isNaN(code) ? null : String.fromCharCode(code);
  }
  if (entity.startsWith('#')) {
    const code: number = Number.parseInt(entity.substring(1), 10);
    return Number.isNaN(code) ? null : String.fromCharCode(code);
  }
  return null;
}

/** 洛雪的 decodeName：解 HTML 实体（等价于 he.decode 的常见子集） */
export function decodeName(str: string): string {
  if (str.length === 0) {
    return '';
  }
  let out: string = '';
  let i: number = 0;
  while (i < str.length) {
    const ch: string = str.charAt(i);
    if (ch === '&') {
      const semi: number = str.indexOf(';', i + 1);
      if (semi > i && semi - i <= 10) {
        const decoded: string | null = decodeEntity(str.substring(i + 1, semi));
        if (decoded !== null) {
          out += decoded;
          i = semi + 1;
          continue;
        }
      }
    }
    out += ch;
    i++;
  }
  return out;
}

/** 洛雪的 formatSingerName：歌手数组 -> "、" 连接 */
export function formatSingerName(singers: Object | undefined): string {
  if (Array.isArray(singers)) {
    const names: string[] = [];
    for (const singer of singers as Object[]) {
      if (typeof singer === 'string') {
        const name: string = singer as string;
        if (name.length > 0) {
          names.push(name);
        }
        continue;
      }
      const name: string = asString(asRecord(singer)['name']);
      if (name.length > 0) {
        names.push(name);
      }
    }
    return decodeName(names.join('、'));
  }
  const raw: string = asString(singers);
  // 少数接口把歌手数组当 JSON 字符串返回
  if (raw.startsWith('[')) {
    try {
      return formatSingerName(JSON.parse(raw) as Object[]);
    } catch (e) {
      return decodeName(raw);
    }
  }
  return decodeName(raw);
}

function createInfo(
  name: string,
  singer: string,
  source: string,
  songmid: string,
  albumName: string,
  albumId: string,
  interval: string,
  img: string,
  hash: string,
  types: LxQualityItem[],
  qualityMap: Record<string, LxQualityItem>,
): LxMusicInfo {
  const typeUrl: Record<string, string> = {};
  const info: LxMusicInfo = {
    name: name,
    singer: singer,
    source: source,
    songmid: songmid,
    albumName: albumName,
    albumId: albumId,
    interval: interval,
    img: img,
    types: types,
    _types: qualityMap,
    typeUrl: typeUrl,
    lrc: null,
    otherSource: null,
  };
  // hash 为空表示该平台没有 hash（kw/mg/tx/wy），不能写成空串，
  // 否则源脚本的 `hash ?? songmid` 不会回退到 songmid。
  if (hash.length > 0) {
    info.hash = hash;
  }
  return info;
}

/** 该曲目是否提供指定音质 */
export function hasQuality(info: LxMusicInfo, quality: string): boolean {
  return Object.keys(info._types).includes(quality);
}

const QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k'];

/**
 * 选音质：与洛雪的 getPlayQuality 一致 —— 从期望音质往下找，
 * 必须同时被「源脚本声明的音质」和「该曲目提供的音质」支持，否则回落 128k。
 */
export function pickQuality(preferred: string, supported: string[], info: LxMusicInfo): string {
  let type: string = '128k';
  const start: number = QUALITY_ORDER.indexOf(preferred);
  if (start >= 0) {
    for (let i = start; i < QUALITY_ORDER.length; i++) {
      const quality: string = QUALITY_ORDER[i];
      if (hasQuality(info, quality) && supported.includes(quality)) {
        type = quality;
        break;
      }
    }
  }
  return type;
}

// ------------------------------------------------------------------ 酷我 kw

interface KwMinfo {
  bitrate: string;
  size: string;
}

function parseKwMinfo(segment: string): KwMinfo | null {
  let bitrate: string = '';
  let size: string = '';
  const parts: string[] = segment.split(',');
  for (const part of parts) {
    const idx: number = part.indexOf(':');
    if (idx < 0) {
      continue;
    }
    const key: string = part.substring(0, idx).trim();
    const value: string = part.substring(idx + 1).trim();
    if (key === 'bitrate') {
      bitrate = value;
    } else if (key === 'size') {
      size = value;
    }
  }
  if (bitrate.length === 0) {
    return null;
  }
  const result: KwMinfo = { bitrate: bitrate, size: size };
  return result;
}

function kwBitrateToQuality(bitrate: string): string {
  if (bitrate === '4000') {
    return 'flac24bit';
  }
  if (bitrate === '2000') {
    return 'flac';
  }
  if (bitrate === '320') {
    return '320k';
  }
  if (bitrate === '128') {
    return '128k';
  }
  return '';
}

/** 解析酷我搜索结果的 abslist */
export function parseKwResult(abslist: Object[]): LxMusicInfo[] {
  const result: LxMusicInfo[] = [];
  for (const raw of abslist) {
    const info: Record<string, Object> = asRecord(raw);
    const musicrid: string = asString(info['MUSICRID']);
    if (musicrid.length === 0) {
      continue;
    }
    const songmid: string = musicrid.split('MUSIC_').join('');
    const nminfo: string = asString(info['N_MINFO']);
    if (nminfo.length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const qualityMap: Record<string, LxQualityItem> = {};
    const segments: string[] = nminfo.split(';');
    for (const segment of segments) {
      const parsed: KwMinfo | null = parseKwMinfo(segment);
      if (parsed === null) {
        continue;
      }
      const quality: string = kwBitrateToQuality(parsed.bitrate);
      if (quality.length === 0 || hasQualityEntry(qualityMap, quality)) {
        continue;
      }
      const item: LxQualityItem = { type: quality, size: parsed.size };
      types.push(item);
      qualityMap[quality] = item;
    }
    types.reverse();
    const artist: string = asString(info['ARTIST']).split('&').join('、');
    result.push(createInfo(
      decodeName(asString(info['SONGNAME'])),
      decodeName(artist),
      'kw',
      songmid,
      decodeName(asString(info['ALBUM'])),
      decodeName(asString(info['ALBUMID'])),
      formatPlayTime(asNumber(info['DURATION'])),
      '',
      '',
      types,
      qualityMap,
    ));
  }
  return result;
}

function hasQualityEntry(map: Record<string, LxQualityItem>, key: string): boolean {
  return Object.keys(map).includes(key);
}

async function searchKw(str: string, page: number, limit: number): Promise<LxSearchPage> {
  const url: string =
    `http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(str)}&pn=${page - 1}&rn=${limit}` +
    '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music' +
    '&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
  let list: LxMusicInfo[] = [];
  let total: number = 0;
  // 酷我偶发返回 SHOW=0 的空结果，重试一次
  for (let attempt = 0; attempt < 2; attempt++) {
    const body: Record<string, Object> = await httpGetJson(url);
    total = asNumber(body['TOTAL']);
    list = parseKwResult(asObjectArray(body['abslist']));
    if (list.length > 0) {
      break;
    }
  }
  return pageOf(list, total, page, limit);
}

// ------------------------------------------------------------------ 酷狗 kg

function addKgQuality(
  item: Record<string, Object>,
  sizeKey: string,
  hashKey: string,
  quality: string,
  types: LxQualityItem[],
  qualityMap: Record<string, LxQualityItem>,
): void {
  const size: number = asNumber(item[sizeKey]);
  if (size === 0) {
    return;
  }
  const qualityItem: LxQualityItem = {
    type: quality,
    size: sizeFormate(size),
    hash: asString(item[hashKey]),
  };
  types.push(qualityItem);
  qualityMap[quality] = qualityItem;
}

function pushKgItem(raw: Object, out: LxMusicInfo[], seen: string[]): void {
  const item: Record<string, Object> = asRecord(raw);
  const audioId: string = asString(item['Audioid']);
  const fileHash: string = asString(item['FileHash']);
  const key: string = audioId + fileHash;
  if (audioId.length === 0 || seen.includes(key)) {
    return;
  }
  seen.push(key);

  const types: LxQualityItem[] = [];
  const qualityMap: Record<string, LxQualityItem> = {};
  addKgQuality(item, 'FileSize', 'FileHash', '128k', types, qualityMap);
  addKgQuality(item, 'HQFileSize', 'HQFileHash', '320k', types, qualityMap);
  addKgQuality(item, 'SQFileSize', 'SQFileHash', 'flac', types, qualityMap);
  addKgQuality(item, 'ResFileSize', 'ResFileHash', 'flac24bit', types, qualityMap);

  const suffix: string = asString(item['Suffix']);
  const name: string = decodeName(asString(item['OriSongName']) + (suffix.length > 0 ? ` ${suffix}` : ''));
  out.push(createInfo(
    name,
    formatSingerName(item['Singers']),
    'kg',
    audioId,
    decodeName(asString(item['AlbumName'])),
    asString(item['AlbumID']),
    formatPlayTime(asNumber(item['Duration'])),
    '',
    fileHash,
    types,
    qualityMap,
  ));
}

/** 解析酷狗搜索结果的 lists（含 Grp 子项） */
export function parseKgResult(lists: Object[]): LxMusicInfo[] {
  const out: LxMusicInfo[] = [];
  const seen: string[] = [];
  for (const raw of lists) {
    const item: Record<string, Object> = asRecord(raw);
    pushKgItem(item, out, seen);
    for (const child of asObjectArray(item['Grp'])) {
      pushKgItem(child, out, seen);
    }
  }
  return out;
}

async function searchKg(str: string, page: number, limit: number): Promise<LxSearchPage> {
  const url: string =
    `https://songsearch.kugou.com/song_search_v2?keyword=${encodeURIComponent(str)}&page=${page}&pagesize=${limit}` +
    '&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
  let lastError: number = 0;
  let list: LxMusicInfo[] = [];
  let total: number = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    const body: Record<string, Object> = await httpGetJson(url);
    lastError = asNumber(body['error_code']);
    if (lastError !== 0) {
      continue;
    }
    const data: Record<string, Object> = asRecord(body['data']);
    total = asNumber(data['total']);
    list = parseKgResult(asObjectArray(data['lists']));
    if (list.length > 0) {
      break;
    }
  }
  // 接口报错不能当成「没搜到」：聚合搜索要按平台说清楚谁没通
  if (lastError !== 0) {
    throw new Error(`酷狗接口返回 error_code ${lastError}`);
  }
  return pageOf(list, total, page, limit);
}

// ------------------------------------------------------------------ 咪咕 mg

const MG_DEVICE_ID: string = '963B7AA0D21511ED807EE5846EC87D20';
const MG_SIGNATURE_MD5: string = '6cdc72a439cef99a3418d2a78aa28c73';
const MG_SIGNATURE_SALT: string = 'yyapp2d16148780a1dcc7408e06336b98cfd50';

/** 咪咕接口签名：md5(关键词 + 固定串 + deviceId + 时间戳)，与洛雪 createSignature 一致 */
export function createMgSignature(keyword: string, time: string): string {
  return md5Hex(`${keyword}${MG_SIGNATURE_MD5}${MG_SIGNATURE_SALT}${MG_DEVICE_ID}${time}`);
}

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
  if (formatType === 'ZQ24') {
    return 'flac24bit';
  }
  return '';
}

/**
 * 把咪咕给的图片地址补成绝对地址
 *
 * 咪咕的 img1 / img2 / img3 基本都是**相对路径**（`/data/oss/resource/...`），搜索、歌单、
 * 榜单三个接口都一样（实测搜索结果：img1/img2/img3 全是 `/data/oss/...`）。原样当 url 用的话
 * 谁也加载不出来：列表里只剩占位图，播控中心那边还会被当成一个不存在的本地文件
 * （PlaybackService 打出 "local cover missing" 后兜底成图标）。
 * 宿主是 d.musicapp.migu.cn —— 咪咕自己的绝对地址就是 `https://d.musicapp.migu.cn/data/oss/...`，
 * 洛雪 `mg/musicSearch.js` 里写的是 http 前缀，两种都实测能出图，这里跟接口保持一致用 https。
 *
 * 已经是 http(s) 的地址原样返回；空串也原样返回（调用方据此判断「这首歌没有封面」）。
 */
export function mgImageUrl(img: string): string {
  if (img.length === 0 || /^https?:\/\//i.test(img)) {
    return img;
  }
  return `https://d.musicapp.migu.cn${img}`;
}

/** 解析咪咕搜索结果的 songResultData.resultList（数组的数组） */
export function parseMgResult(resultList: Object[]): LxMusicInfo[] {
  const out: LxMusicInfo[] = [];
  const seen: string[] = [];
  for (const group of resultList) {
    for (const raw of asObjectArray(group)) {
      const data: Record<string, Object> = asRecord(raw);
      const songId: string = asString(data['songId']);
      const copyrightId: string = asString(data['copyrightId']);
      if (songId.length === 0 || copyrightId.length === 0 || seen.includes(copyrightId)) {
        continue;
      }
      seen.push(copyrightId);

      const types: LxQualityItem[] = [];
      const qualityMap: Record<string, LxQualityItem> = {};
      for (const formatRaw of asObjectArray(data['audioFormats'])) {
        const format: Record<string, Object> = asRecord(formatRaw);
        const quality: string = mgFormatToQuality(asString(format['formatType']));
        if (quality.length === 0 || hasQualityEntry(qualityMap, quality)) {
          continue;
        }
        let size: number = asNumber(format['asize']);
        if (size === 0) {
          size = asNumber(format['isize']);
        }
        const qualityItem: LxQualityItem = { type: quality, size: sizeFormate(size) };
        types.push(qualityItem);
        qualityMap[quality] = qualityItem;
      }

      let img: string = asString(data['img3']);
      if (img.length === 0) {
        img = asString(data['img2']);
      }
      if (img.length === 0) {
        img = asString(data['img1']);
      }

      out.push(createInfo(
        asString(data['name']),
        formatSingerName(data['singerList']),
        'mg',
        songId,
        asString(data['album']),
        asString(data['albumId']),
        formatPlayTime(asNumber(data['duration'])),
        mgImageUrl(img),
        '',
        types,
        qualityMap,
      ));
    }
  }
  return out;
}

async function searchMg(str: string, page: number, limit: number): Promise<LxSearchPage> {
  const time: string = Date.now().toString();
  const sign: string = createMgSignature(str, time);
  const url: string =
    'https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1' +
    '&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1' +
    '%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D' +
    `&pageSize=${limit}&text=${encodeURIComponent(str)}&pageNo=${page}&sort=0&sid=USS`;
  const headers: Record<string, string> = {
    'uiVersion': 'A_music_3.6.1',
    'deviceId': MG_DEVICE_ID,
    'timestamp': time,
    'sign': sign,
    'channel': '0146921',
    'User-Agent': 'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
  };
  const body: Record<string, Object> = await httpGetJson(url, headers);
  if (asString(body['code']) !== '000000') {
    throw new Error(asString(body['info']).length > 0 ? asString(body['info']) : '咪咕搜索失败');
  }
  const songResultData: Record<string, Object> = asRecord(body['songResultData']);
  const list: LxMusicInfo[] = parseMgResult(asObjectArray(songResultData['resultList']));
  return pageOf(list, asNumber(songResultData['totalCount']), page, limit);
}

// ------------------------------------------------------------------ 封面

/** 取纯文本响应（酷我的封面接口直接返回图片地址文本，不是 JSON） */
function httpGetText(url: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    lxRequest(url, { method: 'get', timeout: 12000, rawText: true }, (resp: LxResponse) => {
      const body = resp.body;
      resolve(typeof body === 'string' ? body : JSON.stringify(body));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/** 酷我封面：pic.web 直接回一个图片地址（照抄 LX 的 kw/pic.js） */
async function fetchKwPic(songmid: string): Promise<string> {
  if (songmid.length === 0) {
    return '';
  }
  const url: string =
    'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=' +
    encodeURIComponent(songmid);
  const text: string = (await httpGetText(url)).trim();
  return /^https?:\/\//.test(text) ? text : '';
}

/**
 * 酷狗封面：get_res_privilege 返回 info.image，
 * image 里的 `{size}` 要替换成 imgsize[0]（照抄 LX 的 kg/pic.js）。
 * KG-RC / KG-THash 两个头缺了会被拒。
 */
async function fetchKgPic(info: LxMusicInfo): Promise<string> {
  const hash: string = info.hash !== undefined ? info.hash : '';
  const resource: Record<string, Object>[] = [{
    'album_audio_id': info.songmid,
    'album_id': info.albumId,
    'hash': hash,
    'id': 0,
    'name': `${info.singer} - ${info.name}.mp3`,
    'type': 'audio',
  }];
  const body: Record<string, Object> = {
    'appid': 1001,
    'area_code': '1',
    'behavior': 'play',
    'clientver': '9020',
    'need_hash_offset': 1,
    'relate': 1,
    'resource': resource,
    'token': '',
    'userid': 2626431536,
    'vip': 1,
  };
  const headers: Record<string, string> = {
    'KG-RC': '1',
    'KG-THash': 'expand_search_manager.cpp:852736169:451',
    'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
  };
  const resp: Record<string, Object> =
    await httpPostJson('http://media.store.kugou.com/v1/get_res_privilege', JSON.stringify(body), headers);
  if (asNumber(resp['error_code']) !== 0) {
    return '';
  }
  const list: Object[] = asObjectArray(resp['data']);
  if (list.length === 0) {
    return '';
  }
  const detail: Record<string, Object> = asRecord(asRecord(list[0])['info']);
  let image: string = asString(detail['image']);
  if (image.length === 0) {
    return '';
  }
  const sizes: Object[] = asObjectArray(detail['imgsize']);
  if (sizes.length > 0) {
    image = image.replace('{size}', asString(sizes[0]));
  }
  return /^https?:\/\//.test(image) ? image : '';
}

/**
 * 取封面地址。
 *
 * 搜索结果自带 img 的平台（tx / wy / mg）直接用；
 * kw / kg 的搜索响应里没有封面字段（LX 自己也置成 null），所以按平台接口现取：
 * kw 走 pic.web，kg 走 get_res_privilege —— 与 LX 的 `kw/pic.js`、`kg/pic.js` 一致。
 * 取不到就返回空串，界面继续用占位封面。
 */
export async function fetchMusicPic(info: LxMusicInfo): Promise<string> {
  if (info.img.length > 0) {
    return info.img;
  }
  if (info.source === 'kw') {
    return await fetchKwPic(info.songmid);
  }
  if (info.source === 'kg') {
    return await fetchKgPic(info);
  }
  return '';
}

// ------------------------------------------------------------------ 入口

function httpGetJson(
  url: string,
  headers?: Record<string, string>,
  timeout: number = 15000,
): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: timeout };
    if (headers !== undefined) {
      options.headers = headers;
    }
    lxRequest(url, options, (resp: LxResponse) => {
      const body = resp.body;
      if (body !== null && typeof body === 'object' && !Array.isArray(body)) {
        resolve(body as Record<string, Object>);
        return;
      }
      if (typeof body === 'string') {
        // 少数接口返回非标准 JSON，这里再兜底解析一次
        try {
          const parsed: Object = JSON.parse(body) as Object;
          if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
            resolve(parsed as Record<string, Object>);
            return;
          }
        } catch (e) {
          // fallthrough
        }
      }
      reject(new Error(`接口返回格式异常（HTTP ${resp.statusCode}）`));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/**
 * 搜单个平台的一页，连 total / allPage 一起返回（翻页要用）。
 *
 * 返回空列表 = 这个平台确实没搜到；接口不通（非 200 / error_code / code != 0）
 * 一律抛错，不返回空数组 —— 否则界面会把「接口挂了」显示成「没有搜索结果」。
 *
 * @param keyword 关键词
 * @param source  平台：kw / kg / mg / tx / wy
 * @param page    页码，从 1 开始
 * @param limit   每页数量
 */
export async function searchMusicPage(
  keyword: string,
  source: string,
  page: number = 1,
  limit: number = 30,
): Promise<LxSearchPage> {
  const str: string = keyword.trim();
  if (str.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  if (source === 'kw') {
    return searchKw(str, page, limit);
  }
  if (source === 'kg') {
    return searchKg(str, page, limit);
  }
  if (source === 'mg') {
    return searchMg(str, page, limit);
  }
  if (source === 'tx') {
    return searchTx(str, page, limit);
  }
  if (source === 'wy') {
    return searchWy(str, page, limit);
  }
  // xm（喜马拉雅）在洛雪里整块是注释掉的死代码，没有可移植的实现
  throw new Error(`${source} 暂无内置搜索实现（当前支持：${SEARCH_PLATFORMS.join(' / ')}）`);
}

/** 只要结果列表时用这个（换源 / 歌词匹配等只关心歌本身，不翻页） */
export async function searchMusic(
  keyword: string,
  source: string,
  page: number = 1,
  limit: number = 30,
): Promise<LxMusicInfo[]> {
  return (await searchMusicPage(keyword, source, page, limit)).list;
}

// ------------------------------------------------------------------ 排序与去重（照洛雪）

/**
 * 两个字符串的相似度（0~1，越大越像）
 *
 * 照抄洛雪 utils/common.js 的 similar：以短串为基准算编辑距离（Levenshtein），
 * 再用 `1 - 距离 / 长串长度` 归一化。搜索页用它给「关键词 vs 歌名 + 歌手」打分 ——
 * 洛雪搜歌手名时靠的就是它把最贴题的那些顶到前面，不然各平台返回顺序一混，
 * 该排第一的几首全被埋在后头。
 */
export function similar(a: string, b: string): number {
  if (a.length === 0 || b.length === 0) {
    return 0;
  }
  let s: string = a;
  let l: string = b;
  if (s.length > l.length) {
    const swap: string = s;
    s = l;
    l = swap;
  }
  const sl: number = s.length;
  const ll: number = l.length;
  // mp[j] = 「s 的前 i 个字符」与「l 的前 j 个字符」的编辑距离（滚动数组）
  const mp: number[] = [];
  for (let j = 0; j <= ll; j++) {
    mp.push(j);
  }
  for (let i = 1; i <= sl; i++) {
    const ai: string = s.charAt(i - 1);
    let lt: number = mp[0];
    mp[0] = mp[0] + 1;
    for (let j = 1; j <= ll; j++) {
      const cost: number = ai === l.charAt(j - 1) ? 0 : 1;
      const tmp: number = Math.min(mp[j] + 1, mp[j - 1] + 1, lt + cost);
      lt = mp[j];
      mp[j] = tmp;
    }
  }
  return 1 - (mp[ll] / ll);
}

/** 排序用的一条：相似度 + 结果本身 */
interface ScoredMusic {
  num: number;
  data: LxMusicInfo;
}

/**
 * 二分插入（同分插在已有的同分条目左侧，保持插入的先后）
 *
 * 照抄洛雪 utils/common.js 的 sortInsert：用二分找到位置再 splice，比每次整表
 * sort 稳定 —— 同分的条目不会互相换位，列表翻页时看着不跳。
 */
function sortInsert(arr: ScoredMusic[], data: ScoredMusic): void {
  const key: number = data.num;
  let left: number = 0;
  let right: number = arr.length - 1;
  while (left <= right) {
    const middle: number = Math.trunc((left + right) / 2);
    if (key === arr[middle].num) {
      left = middle;
      break;
    }
    if (key < arr[middle].num) {
      right = middle - 1;
    } else {
      left = middle + 1;
    }
  }
  while (left > 0) {
    if (arr[left - 1].num !== key) {
      break;
    }
    left--;
  }
  arr.splice(left, 0, data);
}

/**
 * 按与关键词的相似度重排一页结果（降序）
 *
 * 洛雪 store/search/music/action.js 的 handleSortList：逐条打分二分插入，
 * 再整表反转成「最像的在最前」。
 */
export function sortByRelevance(items: LxMusicInfo[], keyword: string): LxMusicInfo[] {
  const scored: ScoredMusic[] = [];
  for (const item of items) {
    sortInsert(scored, { num: similar(keyword, `${item.name} ${item.singer}`), data: item });
  }
  const out: LxMusicInfo[] = [];
  for (let i = scored.length - 1; i >= 0; i--) {
    out.push(scored[i].data);
  }
  return out;
}

/**
 * 条目的稳定标识：`${platform}_${songmid}`，酷狗多带一节 hash
 *
 * 与 MusicId.musicIdOf / core/sync/SyncConvert 是同一套规则（那边直接转调这里，
 * 免得三处各写一份慢慢走样）。聚合搜索按它去掉「同一个平台重复返回的同一条」。
 */
export function searchIdOf(info: LxMusicInfo): string {
  const songmid: string =
    info.songmid !== undefined && info.songmid !== null ? String(info.songmid) : '';
  if (info.source === 'kg') {
    const hash: string = info.hash !== undefined ? info.hash : '';
    return `${songmid}_${hash}`;
  }
  return `${info.source}_${songmid}`;
}

/** 歌手分隔符（洛雪的 singersRxp）："周杰伦、方文山" 与 "方文山/周杰伦" 要认成同一组 */
const SINGER_SEPARATORS: RegExp = /、|&|;|；|\/|,|，|\|/;

/**
 * 归一化时丢掉的字符（洛雪 findMusic 的 filterStr）
 *
 * 注意「（Live）」里的括号去掉后 Live 还在，所以「晴天(Live)」不会和「晴天」撞上 ——
 * 去重的粒度宁可保守。
 */
const FILTER_CHARS: RegExp = /\s|'|\.|,|，|&|"|、|\(|\)|（|）|`|~|-|<|>|\||\/|\]|\[|!|！/g;

function normalizeText(text: string): string {
  return text.replace(FILTER_CHARS, '').toLowerCase();
}

/** 歌手集合归一化：拆开、排序后再拼，避免「A、B」与「B/A」被当成两组人 */
function normalizeSingers(singer: string): string {
  if (singer.length === 0) {
    return '';
  }
  if (!SINGER_SEPARATORS.test(singer)) {
    return normalizeText(singer);
  }
  const parts: string[] = singer.split(SINGER_SEPARATORS);
  const cleaned: string[] = [];
  for (const part of parts) {
    const one: string = normalizeText(part);
    if (one.length > 0) {
      cleaned.push(one);
    }
  }
  cleaned.sort((a: string, b: string) => a.localeCompare(b));
  return cleaned.join('、');
}

/** 「mm:ss」-> 秒；洛雪 findMusic 的 getIntv（认不出来就是 0） */
function intervalSeconds(interval: string): number {
  if (interval.length === 0 || interval === '--/--') {
    return 0;
  }
  const parts: string[] = interval.split(':');
  let total: number = 0;
  let unit: number = 1;
  for (let i = parts.length - 1; i >= 0; i--) {
    const value: number = Number.parseInt(parts[i], 10);
    total += (Number.isNaN(value) ? 0 : value) * unit;
    unit *= 60;
  }
  return total;
}

/**
 * 「看起来是同一首歌」的键：歌名 + 歌手集合（不含时长）
 *
 * 时长不放进键里，是因为要按 ±5 秒容差比对（见 sameInterval）：各平台报的时长
 * 常常差一两秒，放进键里两边就永远不在同一个格子里，容差也就无从谈起。
 */
function songKeyOf(info: LxMusicInfo): string {
  const name: string = normalizeText(info.name);
  if (name.length === 0) {
    // 连歌名都没有，没法判断是不是同一首：交给 id 去重，别乱并
    return '';
  }
  return `${name}\u0001${normalizeSingers(info.singer)}`;
}

/** 时长差在 ±5 秒内算同一条录音 */
function sameInterval(a: string, b: string): boolean {
  const one: number = intervalSeconds(a);
  const other: number = intervalSeconds(b);
  if (one === 0 || other === 0) {
    return true;
  }
  return Math.abs(one - other) <= 5;
}

/**
 * 去重：先按稳定 id（同一平台重复返回的同一条），再按「看起来是同一首歌」。
 *
 * 洛雪只按「平台 + 歌曲 id」去重（`deduplicationList`），所以它的聚合列表里同一首歌
 * 在几个平台就是几条。聆听这边**播放链路会自动换源解析**（PlaySession.ensurePlayable：
 * 条目所在平台解析不了就按歌名 + 歌手在音源支持且有内置搜索的平台上重搜），
 * 留一条就够用，多留的几条只会把列表塞满重复行、把真正没听过的歌挤到后面去 ——
 * 按歌手搜索时最明显：五个平台各回 30 条，去重前 150 行里同一首歌能占五遍。
 *
 * live / remix 这类版本靠时长区分：名字对不上、或者时长差超过 5 秒，就不并。
 * 界面翻页时也是拿它把「上一页 + 这一页」拼起来，规则只写在这一处。
 */
export function dedupeSongs(items: LxMusicInfo[]): LxMusicInfo[] {
  const ids: Set<string> = new Set<string>();
  const songs: Map<string, LxMusicInfo[]> = new Map<string, LxMusicInfo[]>();
  const out: LxMusicInfo[] = [];
  for (const item of items) {
    const id: string = searchIdOf(item);
    if (ids.has(id)) {
      continue;
    }
    ids.add(id);
    const key: string = songKeyOf(item);
    if (key.length === 0) {
      out.push(item);
      continue;
    }
    // 同一个「歌名 + 歌手 + 时长」的格子只留时长真对得上的那条
    const kept: LxMusicInfo[] | undefined = songs.get(key);
    if (kept === undefined) {
      songs.set(key, [item]);
      out.push(item);
      continue;
    }
    let duplicate: boolean = false;
    for (const other of kept) {
      if (sameInterval(other.interval, item.interval)) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) {
      continue;
    }
    kept.push(item);
    out.push(item);
  }
  return out;
}

// ------------------------------------------------------------------ 聚合搜索

/** 单个平台这一页的结果（失败也占一条，界面好把「哪个平台没通」说清楚） */
export interface LxPlatformSearch {
  source: string;
  items: LxMusicInfo[];
  /** 空串 = 这个平台搜成功 */
  error: string;
  /** 这个平台一共几页（失败 = 就这一页） */
  allPage: number;
  total: number;
}

/** 聚合搜索一页的结果 */
export interface LxSearchOutcome {
  keyword: string;
  page: number;
  /** 逐平台一份（界面拿它做平台筛选与状态行） */
  platforms: LxPlatformSearch[];
  /**
   * 聚合列表：本页所有平台的结果按相关度排好、去过重（洛雪 setLists 的做法）
   *
   * 翻页时由界面往这个列表后面接 —— 洛雪也是「每页各自按相关度排，页与页之间按
   * 拉的先后往后摞」，而不是每翻一页把整张表重排一遍（那会让已经翻过的内容乱跳）。
   */
  items: LxMusicInfo[];
  /** 各平台里最大的总页数：> page 表示还能继续翻 */
  maxPage: number;
}

/** 单平台搜索，失败也返回（不抛），供聚合用 */
async function searchPlatform(
  keyword: string,
  source: string,
  page: number,
  limit: number,
): Promise<LxPlatformSearch> {
  try {
    const result: LxSearchPage = await searchMusicPage(keyword, source, page, limit);
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
 * 聚合搜索一页：一次问所有平台，合起来排一次、去一次重。
 *
 * 单个平台失败（超时、接口改了、歌没版权…）不该让整次搜索失败，所以逐平台各自
 * try 一遍，失败的把原因带回来给界面显示。
 *
 * @param page 页码，从 1 开始；翻页由界面连续调用（见 SearchView.loadMore）
 */
export async function searchMusicAll(
  keyword: string,
  sources: string[] = SEARCH_PLATFORMS,
  page: number = 1,
  limit: number = 30,
): Promise<LxSearchOutcome> {
  const str: string = keyword.trim();
  if (str.length === 0) {
    throw new Error('请输入搜索关键词');
  }
  const tasks: Promise<LxPlatformSearch>[] = [];
  for (let i = 0; i < sources.length; i++) {
    tasks.push(searchPlatform(str, sources[i], page, limit));
  }
  const settled: PromiseSettledResult<LxPlatformSearch>[] = await Promise.allSettled(tasks);
  const platforms: LxPlatformSearch[] = [];
  const flat: LxMusicInfo[] = [];
  let maxPage: number = page;
  for (let i = 0; i < settled.length; i++) {
    const r: PromiseSettledResult<LxPlatformSearch> = settled[i];
    const one: LxPlatformSearch = r.status === 'fulfilled'
      ? r.value
      : { source: sources[i], items: [], error: '搜索失败', allPage: page, total: 0 };
    platforms.push(one);
    if (one.allPage > maxPage) {
      maxPage = one.allPage;
    }
    for (const item of one.items) {
      flat.push(item);
    }
  }
  return {
    keyword: str,
    page: page,
    platforms: platforms,
    // 先去重再排序：同一首歌在几个平台都有时，留下的是**先问的那个平台**那一份
    // （sources 的顺序，缺省是 SEARCH_PLATFORMS = 酷我打头）。反过来先排序再去重的话，
    // 留下谁就取决于二分插入对同分条目的落位，读代码的人根本看不出来。
    items: sortByRelevance(dedupeSongs(flat), str),
    maxPage: maxPage,
  };
}

// ------------------------------------------------------------------ QQ 音乐 tx

const TX_PART_1_INDEXES: number[] = [23, 14, 6, 36, 16, 40, 7, 19];
const TX_PART_2_INDEXES: number[] = [16, 1, 32, 12, 19, 27, 8, 5];
const TX_SCRAMBLE_VALUES: number[] = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];
const TX_UA: string = 'QQMusic 14090508(android 12)';

/** 去掉 base64 里的 \\ / + = 四种字符（洛雪用 /[\\/+=]/g 全量替换） */
function stripB64Chars(input: string): string {
  let out: string = '';
  for (let i = 0; i < input.length; i++) {
    const c: string = input.charAt(i);
    if (c === '\\' || c === '/' || c === '+' || c === '=') {
      continue;
    }
    out += c;
  }
  return out;
}

function padZero5(value: number): string {
  const s: string = String(value);
  return '00000'.substring(0, 5 - s.length) + s;
}

/**
 * QQ 音乐 zzcSign，照抄洛雪 tx/utils/crypto.js。
 * 注意 PART_1_INDEXES 含越界下标 40：hash[40] 是 undefined，join('') 会变成空串。
 * 这里显式跳过越界下标，与原行为一致（原版依赖 join 对 undefined 的转换）。
 */
export function createZzcSign(text: string): string {
  const hash: string = sha1Hex(text);
  let part1: string = '';
  for (const idx of TX_PART_1_INDEXES) {
    part1 += idx < hash.length ? hash.charAt(idx) : '';
  }
  let part2: string = '';
  for (const idx of TX_PART_2_INDEXES) {
    part2 += idx < hash.length ? hash.charAt(idx) : '';
  }
  const part3: number[] = [];
  for (let i = 0; i < TX_SCRAMBLE_VALUES.length; i++) {
    const byte: number = Number.parseInt(hash.substring(i * 2, i * 2 + 2), 16);
    part3.push(TX_SCRAMBLE_VALUES[i] ^ byte);
  }
  const b64: string = stripB64Chars(toBase64(part3));
  return `zzc${part1}${b64}${part2}`.toLowerCase();
}

/** PC 客户端版 searchid：32 位大写 hex + 5 位补零随机数 */
function createTxSearchId(): string {
  let guid: string = '';
  for (let i = 0; i < 32; i++) {
    guid += Math.floor(Math.random() * 16).toString(16);
  }
  return guid.toUpperCase() + padZero5(Math.floor(Math.random() * 100000));
}

/** 构造 QQ 搜索请求体（键顺序必须与洛雪一致，因为签名是对这个 JSON 串算的） */
export function createTxRequestBody(keyword: string, page: number, limit: number): string {
  const comm: Record<string, Object> = {
    '_channelid': '0',
    '_os_version': '6.2.9200-2',
    'ct': '19',
    'cv': '2151',
    'guid': '1F70E520B2EAA7D25E11760783C53CA9',
    'patch': '118',
    'psrf_access_token_expiresAt': 0,
    'psrf_qqaccess_token': '',
    'psrf_qqopenid': '',
    'psrf_qqunionid': '',
    'tmeAppID': 'qqmusic',
    'tmeLoginType': 0,
    'uin': '0',
    'wid': '7223299733393904640',
  };
  const param: Record<string, Object> = {
    'grp': 1,
    'num_per_page': limit,
    'page_num': page,
    'query': keyword,
    'remoteplace': 'txt.newclient.top',
    'search_type': 0,
    'searchid': createTxSearchId(),
  };
  const method: Record<string, Object> = {
    'module': 'music.search.SearchCgiService',
    'method': 'DoSearchForQQMusicDesktop',
    'param': param,
  };
  const payload: Record<string, Object> = {};
  payload['comm'] = comm;
  payload['music.search.SearchCgiService'] = method;
  return JSON.stringify(payload);
}

/** 解析 QQ 搜索结果的 song.list */
export function parseTxSongs(songList: Object[]): LxMusicInfo[] {
  const out: LxMusicInfo[] = [];
  for (const raw of songList) {
    const item: Record<string, Object> = asRecord(raw);
    const file: Record<string, Object> = asRecord(item['file']);
    const mediaMid: string = asString(file['media_mid']);
    if (mediaMid.length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const qualityMap: Record<string, LxQualityItem> = {};
    addTxQuality(file, 'size_128mp3', '128k', types, qualityMap);
    addTxQuality(file, 'size_320mp3', '320k', types, qualityMap);
    addTxQuality(file, 'size_flac', 'flac', types, qualityMap);
    addTxQuality(file, 'size_hires', 'flac24bit', types, qualityMap);

    const album: Record<string, Object> = asRecord(item['album']);
    const albumId: string = asString(album['mid']);
    const albumName: string = asString(album['name']);
    let img: string = '';
    if (albumId.length > 0) {
      img = `https://y.gtimg.cn/music/photo_new/T002R500x500M000${albumId}.jpg`;
    } else {
      const singers: Object[] = asObjectArray(item['singer']);
      if (singers.length > 0) {
        const firstMid: string = asString(asRecord(singers[0])['mid']);
        if (firstMid.length > 0) {
          img = `https://y.gtimg.cn/music/photo_new/T001R500x500M000${firstMid}.jpg`;
        }
      }
    }

    const info: LxMusicInfo = createInfo(
      asString(item['title']),
      formatSingerName(item['singer']),
      'tx',
      asString(item['mid']),
      albumName,
      albumId,
      formatPlayTime(asNumber(item['interval'])),
      img,
      '',
      types,
      qualityMap,
    );
    // 源脚本（自定义源）取 tx 播放链接需要这几个字段
    info.songId = asString(item['id']);
    info.albumMid = albumId;
    info.strMediaMid = mediaMid;
    out.push(info);
  }
  return out;
}

function addTxQuality(
  file: Record<string, Object>,
  sizeKey: string,
  quality: string,
  types: LxQualityItem[],
  qualityMap: Record<string, LxQualityItem>,
): void {
  const size: number = asNumber(file[sizeKey]);
  if (size === 0) {
    return;
  }
  const qualityItem: LxQualityItem = { type: quality, size: sizeFormate(size) };
  types.push(qualityItem);
  qualityMap[quality] = qualityItem;
}

async function searchTx(str: string, page: number, limit: number): Promise<LxSearchPage> {
  let lastCode: number = 0;
  let list: LxMusicInfo[] = [];
  let total: number = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    const body: string = createTxRequestBody(str, page, limit);
    const sign: string = createZzcSign(body);
    const url: string = `https://u.y.qq.com/cgi-bin/musics.fcg?sign=${sign}`;
    const headers: Record<string, string> = { 'User-Agent': TX_UA };
    const resp: Record<string, Object> = await httpPostJson(url, body, headers);
    const service: Record<string, Object> = asRecord(resp['music.search.SearchCgiService']);
    const req: Record<string, Object> = service['code'] !== undefined ? service : asRecord(resp['req']);
    lastCode = asNumber(resp['code']) !== 0 ? asNumber(resp['code']) : asNumber(req['code']);
    if (lastCode !== 0) {
      continue;
    }
    const data: Record<string, Object> = asRecord(req['data']);
    const inner: Record<string, Object> = asRecord(data['body']);
    const song: Record<string, Object> = asRecord(inner['song']);
    // 命中总数在 data.meta.sum（洛雪 tx/musicSearch.js 也是取 meta.sum）
    total = asNumber(asRecord(data['meta'])['sum']);
    list = parseTxSongs(asObjectArray(song['list']));
    if (list.length > 0) {
      break;
    }
  }
  // 同上：接口报错如实抛，别伪装成「没搜到」
  if (lastCode !== 0) {
    throw new Error(`QQ 音乐接口返回 code ${lastCode}`);
  }
  return pageOf(list, total, page, limit);
}

// ------------------------------------------------------------------ 网易 wy

const WY_UA: string =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36';
const WY_EAPI_KEY: string = 'e82ckenh8dichen8';

/**
 * 网易 eapi 参数，照抄洛雪 wy/utils/crypto.js 的 eapi()：
 *   digest = md5(`nobody${url}use${text}md5forencrypt`)
 *   data   = `${url}-36cd479b6b5-${text}-36cd479b6b5-${digest}`
 *   params = hexUpper( AES-128-ECB/PKCS7(key, data) )
 * 其中 ECB 的 mode 在洛雪里是 Java 的 "AES"（= ECB/PKCS5Padding），不是 NoPadding。
 */
export function createEapiParams(path: string, dataJson: string): string {
  const digest: string = md5Hex(`nobody${path}use${dataJson}md5forencrypt`);
  const payload: string = `${path}-36cd479b6b5-${dataJson}-36cd479b6b5-${digest}`;
  return aes128EcbPkcs7HexUpper(utf8Bytes(WY_EAPI_KEY), utf8Bytes(payload));
}

/**
 * 网易的拓展音质档
 *
 * maxBrLevel 命中时才补这一档：母带 jymaster / 沉浸声 sky / 杜比全景声 dolby。
 * size 取同名子对象的 size，取不到就记 0（只影响界面上显示的体积，不影响解析）。
 */
function addWyExtendQuality(
  brLevel: string,
  item: Record<string, Object>,
  levelName: string,
  quality: string,
  types: LxQualityItem[],
  qualityMap: Record<string, LxQualityItem>,
): void {
  if (brLevel !== levelName) {
    return;
  }
  const size: number = asNumber(asRecord(item[levelName])['size']);
  const qualityItem: LxQualityItem = { type: quality, size: sizeFormate(size) };
  types.push(qualityItem);
  qualityMap[quality] = qualityItem;
}

/** 解析网易搜索结果（data.resources[].baseInfo.simpleSongData） */
export function parseWySongs(resources: Object[]): LxMusicInfo[] {
  const out: LxMusicInfo[] = [];
  for (const raw of resources) {
    const baseInfo: Record<string, Object> = asRecord(asRecord(raw)['baseInfo']);
    const item: Record<string, Object> = asRecord(baseInfo['simpleSongData']);
    if (Object.keys(item).length === 0) {
      continue;
    }
    const types: LxQualityItem[] = [];
    const qualityMap: Record<string, LxQualityItem> = {};
    const privilege: Record<string, Object> = asRecord(item['privilege']);
    const maxBr: number = asNumber(privilege['maxbr']);
    const hiresSize: number = asNumber(asRecord(item['hr'])['size']);
    const brLevel: string = asString(privilege['maxBrLevel']);
    if (brLevel === 'hires') {
      const qualityItem: LxQualityItem = { type: 'flac24bit', size: sizeFormate(hiresSize) };
      types.push(qualityItem);
      qualityMap['flac24bit'] = qualityItem;
    }
    // 拓展音质：网易把「母带 / 沉浸声 / 杜比全景声」也报在 maxBrLevel 上，
    // 补进 _types 后，用户在「设置 - 播放设置」里开了拓展音质才会被选中
    // （关着时协商只走普通音质，这几档躺着不影响播放）。
    addWyExtendQuality(brLevel, item, 'jymaster', 'master', types, qualityMap);
    addWyExtendQuality(brLevel, item, 'sky', 'atmos_plus', types, qualityMap);
    addWyExtendQuality(brLevel, item, 'dolby', 'atmos', types, qualityMap);
    // 注意：洛雪这里 switch 是「故意穿透」的，命中 999000 会同时补 320k 与 128k
    if (maxBr === 999000 || maxBr === 320000 || maxBr === 192000 || maxBr === 128000) {
      if (maxBr === 999000) {
        const size: number = asNumber(asRecord(item['sq'])['size']);
        const qualityItem: LxQualityItem = { type: 'flac', size: sizeFormate(size) };
        types.push(qualityItem);
        qualityMap['flac'] = qualityItem;
      }
      if (maxBr === 999000 || maxBr === 320000) {
        const size: number = asNumber(asRecord(item['h'])['size']);
        const qualityItem: LxQualityItem = { type: '320k', size: sizeFormate(size) };
        types.push(qualityItem);
        qualityMap['320k'] = qualityItem;
      }
      const lowSize: number = asNumber(asRecord(item['l'])['size']);
      const lowItem: LxQualityItem = { type: '128k', size: sizeFormate(lowSize) };
      types.push(lowItem);
      qualityMap['128k'] = lowItem;
    }
    types.reverse();

    const album: Record<string, Object> = asRecord(item['al']);
    out.push(createInfo(
      asString(item['name']),
      formatSingerName(item['ar']),
      'wy',
      asString(item['id']),
      asString(album['name']),
      asString(album['id']),
      formatPlayTime(Math.trunc(asNumber(item['dt']) / 1000)),
      asString(album['picUrl']),
      '',
      types,
      qualityMap,
    ));
  }
  return out;
}

async function searchWy(str: string, page: number, limit: number): Promise<LxSearchPage> {
  const path: string = '/api/search/song/list/page';
  const params: Record<string, Object> = {
    'keyword': str,
    'needCorrect': '1',
    'channel': 'typing',
    'offset': limit * (page - 1),
    'scene': 'normal',
    'total': page === 1,
    'limit': limit,
  };
  let lastCode: number = 0;
  let list: LxMusicInfo[] = [];
  let total: number = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    const dataJson: string = JSON.stringify(params);
    const form: Record<string, string> = { 'params': createEapiParams(path, dataJson) };
    const headers: Record<string, string> = {
      'User-Agent': WY_UA,
      'origin': 'https://music.163.com',
    };
    const body: Record<string, Object> = await httpPostForm('http://interface.music.163.com/eapi/batch', form, headers);
    lastCode = asNumber(body['code']);
    if (lastCode !== 200) {
      continue;
    }
    const data: Record<string, Object> = asRecord(body['data']);
    total = asNumber(data['totalCount']);
    list = parseWySongs(asObjectArray(data['resources']));
    if (list.length > 0) {
      break;
    }
  }
  // 接口返非 200 时以前也是返回空数组，界面上就成了「没有搜索结果（网易）」
  // —— 接口不通被伪装成「没搜到」（见 docs/DEFECTS.md D-001）。聚合搜索要按平台
  // 报「谁没通」，所以这里把接口错误如实抛出去；code 200 但确实没资源才返回空。
  if (lastCode !== 200) {
    throw new Error(`网易接口返回 code ${lastCode}（该接口当前不可用）`);
  }
  return pageOf(list, total, page, limit);
}

/** POST JSON，返回解析后的对象 */
function httpPostJson(
  url: string,
  body: string,
  headers: Record<string, string>,
): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, body: body };
    lxRequest(url, options, (resp: LxResponse) => {
      resolve(asJsonObject(resp));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/** POST 表单，返回解析后的对象 */
function httpPostForm(
  url: string,
  form: Record<string, string>,
  headers: Record<string, string>,
): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, form: form };
    lxRequest(url, options, (resp: LxResponse) => {
      resolve(asJsonObject(resp));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

function asJsonObject(resp: LxResponse): Record<string, Object> {
  const body = resp.body;
  if (body !== null && typeof body === 'object' && !Array.isArray(body)) {
    return body as Record<string, Object>;
  }
  if (typeof body === 'string') {
    try {
      const parsed = JSON.parse(body) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      // fallthrough
    }
  }
  throw new Error(`接口返回格式异常（HTTP ${resp.statusCode}）`);
}
