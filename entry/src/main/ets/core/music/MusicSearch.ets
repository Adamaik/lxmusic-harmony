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

async function searchKw(str: string, page: number, limit: number): Promise<LxMusicInfo[]> {
  const url: string =
    `http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(str)}&pn=${page - 1}&rn=${limit}` +
    '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music' +
    '&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
  // 酷我偶发返回 SHOW=0 的空结果，重试一次
  for (let attempt = 0; attempt < 2; attempt++) {
    const body: Record<string, Object> = await httpGetJson(url);
    const list: LxMusicInfo[] = parseKwResult(asObjectArray(body['abslist']));
    if (list.length > 0) {
      return list;
    }
  }
  return [];
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

async function searchKg(str: string, page: number, limit: number): Promise<LxMusicInfo[]> {
  const url: string =
    `https://songsearch.kugou.com/song_search_v2?keyword=${encodeURIComponent(str)}&page=${page}&pagesize=${limit}` +
    '&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
  let lastError: number = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    const body: Record<string, Object> = await httpGetJson(url);
    lastError = asNumber(body['error_code']);
    if (lastError !== 0) {
      continue;
    }
    const data: Record<string, Object> = asRecord(body['data']);
    const list: LxMusicInfo[] = parseKgResult(asObjectArray(data['lists']));
    if (list.length > 0) {
      return list;
    }
  }
  // 接口报错不能当成「没搜到」：聚合搜索要按平台说清楚谁没通
  if (lastError !== 0) {
    throw new Error(`酷狗接口返回 error_code ${lastError}`);
  }
  return [];
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
      if (img.length > 0 && !/^https?:/.test(img)) {
        img = `http://d.musicapp.migu.cn${img}`;
      }

      out.push(createInfo(
        asString(data['name']),
        formatSingerName(data['singerList']),
        'mg',
        songId,
        asString(data['album']),
        asString(data['albumId']),
        formatPlayTime(asNumber(data['duration'])),
        img,
        '',
        types,
        qualityMap,
      ));
    }
  }
  return out;
}

async function searchMg(str: string, page: number, limit: number): Promise<LxMusicInfo[]> {
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
  return parseMgResult(asObjectArray(songResultData['resultList']));
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
 * 搜索音乐，返回可直接交给源规则解析播放链接的 musicInfo 列表。
 *
 * 返回空数组 = 这个平台确实没搜到；接口不通（非 200 / error_code / code != 0）
 * 一律抛错，不再返回空数组 —— 否则界面会把「接口挂了」显示成「没有搜索结果」。
 *
 * @param keyword 关键词
 * @param source  平台：kw / kg / mg / tx / wy
 * @param page    页码，从 1 开始
 * @param limit   每页数量
 */
export async function searchMusic(
  keyword: string,
  source: string,
  page: number = 1,
  limit: number = 30,
): Promise<LxMusicInfo[]> {
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

// ------------------------------------------------------------------ 聚合搜索

/** 单个平台的搜索结果（失败也占一条，界面好把「哪个平台没通」说清楚） */
export interface LxPlatformSearch {
  source: string;
  items: LxMusicInfo[];
  /** 空串 = 这个平台搜成功 */
  error: string;
}

/** 聚合搜索结果：逐平台一份（界面自己决定要不要交错合并） */
export interface LxAggSearchResult {
  keyword: string;
  platforms: LxPlatformSearch[];
}

/**
 * 把多份列表交错合并成一份：每个平台轮流取一条。
 *
 * 聚合搜索结果直接拼接是「30 条酷我 + 30 条酷狗」，用户在列表里要滚过一整个
 * 平台才能看到另一个；交错后前几行就能横向比较同一首歌在各平台的结果 ——
 * 这才是「聚合搜索」真正有用的地方。
 *
 * 放在这里而不是界面里：交错规则是搜索语义的一部分（和谁在前、取多少条有关），
 * 哪天要改成按相关度排，也应该只改这一处。
 */
export function interleave<T>(lists: T[][]): T[] {
  const merged: T[] = [];
  let depth: number = 0;
  let more: boolean = true;
  while (more) {
    more = false;
    for (let i = 0; i < lists.length; i++) {
      if (depth < lists[i].length) {
        merged.push(lists[i][depth]);
        more = true;
      }
    }
    depth++;
  }
  return merged;
}

/** 单平台搜索，失败也返回（不抛），供聚合用 */
export async function searchPlatform(
  keyword: string,
  source: string,
  page: number = 1,
  limit: number = 30,
): Promise<LxPlatformSearch> {
  try {
    const items: LxMusicInfo[] = await searchMusic(keyword, source, page, limit);
    return { source: source, items: items, error: '' };
  } catch (e) {
    return { source: source, items: [], error: (e as Error).message };
  }
}

/**
 * 聚合搜索：一次问所有平台。
 *
 * 单个平台失败（超时、接口改了、歌没版权…）不该让整次搜索失败，
 * 所以逐平台各自 try 一遍，失败的把原因带回来给界面显示。
 */
export async function searchMusicAll(
  keyword: string,
  sources: string[] = SEARCH_PLATFORMS,
  page: number = 1,
  limit: number = 30,
): Promise<LxAggSearchResult> {
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
  for (let i = 0; i < settled.length; i++) {
    const r: PromiseSettledResult<LxPlatformSearch> = settled[i];
    if (r.status === 'fulfilled') {
      platforms.push(r.value);
    } else {
      platforms.push({ source: sources[i], items: [], error: '搜索失败' });
    }
  }
  return { keyword: str, platforms: platforms };
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

async function searchTx(str: string, page: number, limit: number): Promise<LxMusicInfo[]> {
  let lastCode: number = 0;
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
    const list: LxMusicInfo[] = parseTxSongs(asObjectArray(song['list']));
    if (list.length > 0) {
      return list;
    }
  }
  // 同上：接口报错如实抛，别伪装成「没搜到」
  if (lastCode !== 0) {
    throw new Error(`QQ 音乐接口返回 code ${lastCode}`);
  }
  return [];
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

async function searchWy(str: string, page: number, limit: number): Promise<LxMusicInfo[]> {
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
    const list: LxMusicInfo[] = parseWySongs(asObjectArray(data['resources']));
    if (list.length > 0) {
      return list;
    }
  }
  // 接口返非 200 时以前也是返回空数组，界面上就成了「没有搜索结果（网易）」
  // —— 接口不通被伪装成「没搜到」（见 docs/DEFECTS.md D-001）。聚合搜索要按平台
  // 报「谁没通」，所以这里把接口错误如实抛出去；code 200 但确实没资源才返回空。
  if (lastCode !== 200) {
    throw new Error(`网易接口返回 code ${lastCode}（该接口当前不可用）`);
  }
  return [];
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
