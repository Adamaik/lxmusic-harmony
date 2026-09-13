import { LxMusicInfo, decodeName } from './MusicSearch';
import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
import { bytesToUtf8, fromBase64, utf8Bytes } from './LxCrypto';
import { inflateZlib } from './Inflate';

/**
 * 内置平台歌词
 *
 * 为什么不能靠自定义源：洛雪的源协议里，平台源的 action 白名单只有 `musicUrl`
 * （见 lx_preload.js 的 supportActions / 官方 user-api-preload.js），
 * 也就是说「给 musicInfo 拿歌词」这件事本来就不属于源规则。洛雪自己是用内置的
 * 平台 SDK 取词的（`musicSdk[source].getLyric`），所以这里把 kw / kg / tx / mg / wy
 * 五个平台的内置歌词移植过来，与源无关、开箱即有词。
 *
 * 五个平台的接口都用真实请求验证过：
 *   - 酷我：mlyric 返回 zlib 流，解压后是 base64，再 XOR 'yeelion'（照抄 kw/decodeLyric.js）
 *   - 酷狗：lyrics.kugou.com 搜索 + download(fmt=lrc)，content 是 base64 的明文 LRC
 *   - QQ ：fcg_query_lyric_new.fcg?nobase64=1 直接返回明文 LRC（HTML 实体需解码）
 *   - 咪咕：resourceinfo 拿 lrcUrl，再取明文 LRC
 *   - 网易：/api/song/lyric 公开 GET，明文 LRC 在 lrc.lyric，翻译在 tlyric.lyric
 */

/** 平台歌词结果：两段 LRC 文本，交给 parseLyric 解析 */
export interface PlatformLyric {
  lyric: string;
  tlyric: string;
}

const EMPTY_LYRIC: PlatformLyric = { lyric: '', tlyric: '' };

const KG_HEADERS: Record<string, string> = {
  'KG-RC': '1',
  'KG-THash': 'expand_search_manager.cpp:852736169:451',
  'User-Agent': 'KuGou2012-9020-ExpandSearchManager',
};
const TX_HEADERS: Record<string, string> = {
  'Referer': 'https://y.qq.com/portal/player.html',
};
const MG_HEADERS: Record<string, string> = {
  'Referer': 'https://app.c.nf.migu.cn/',
  'User-Agent': 'Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36',
  'channel': '0146921',
};
/** 酷我歌词的逐字时间标签，如 `<1022,-1022>`，展示前要剥掉 */
const KW_WORD_TAG: RegExp = /<(-?\d+),(-?\d+)(?:,-?\d+)?>/g;
const KW_XOR_KEY: string = 'yeelion';

// ------------------------------------------------------------------ 小工具

function asString(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  return '';
}

function asRecord(value: Object | undefined): Record<string, Object> {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, Object>;
}

function asObjectArray(value: Object | undefined): Object[] {
  return Array.isArray(value) ? value as Object[] : [];
}

function toBytes(values: number[]): Uint8Array {
  const out = new Uint8Array(values.length);
  for (let i = 0; i < values.length; i++) {
    out[i] = values[i] & 0xFF;
  }
  return out;
}

/** 'mm:ss' -> 秒（酷狗歌词搜索要传时长） */
function durationSeconds(interval: string): number {
  const parts: string[] = interval.split(':');
  if (parts.length !== 2) {
    return 0;
  }
  const minutes: number = parseInt(parts[0], 10);
  const seconds: number = parseInt(parts[1], 10);
  return isNaN(minutes) || isNaN(seconds) ? 0 : minutes * 60 + seconds;
}

// ------------------------------------------------------------------ HTTP

function httpGetText(url: string, headers?: Record<string, string>): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: 15000, rawText: true };
    if (headers !== undefined) {
      options.headers = headers;
    }
    lxRequest(url, options, (resp: LxResponse) => {
      const body = resp.body;
      resolve(typeof body === 'string' ? body : JSON.stringify(body));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/** 响应体 -> JSON 对象（HTTP 层已经尝试解析，这里再兜一层） */
function resolveJson(resp: LxResponse): Record<string, Object> | null {
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
      return null;
    }
  }
  return null;
}

function httpGetJson(url: string, headers?: Record<string, string>): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: 15000 };
    if (headers !== undefined) {
      options.headers = headers;
    }
    lxRequest(url, options, (resp: LxResponse) => {
      const parsed: Record<string, Object> | null = resolveJson(resp);
      if (parsed === null) {
        reject(new Error(`接口返回格式异常（HTTP ${resp.statusCode}）`));
        return;
      }
      resolve(parsed);
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

function httpPostForm(url: string, form: Record<string, string>,
  headers: Record<string, string>): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, form: form };
    lxRequest(url, options, (resp: LxResponse) => {
      const parsed: Record<string, Object> | null = resolveJson(resp);
      if (parsed === null) {
        reject(new Error(`接口返回格式异常（HTTP ${resp.statusCode}）`));
        return;
      }
      resolve(parsed);
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

function httpGetBinary(url: string): Promise<number[]> {
  return new Promise<number[]>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: 15000, binary: true };
    lxRequest(url, options, (resp: LxResponse) => {
      const body = resp.body;
      resolve(Array.isArray(body) ? body as number[] : []);
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

// ------------------------------------------------------------------ LRC 文本处理

interface RawLrcLine {
  /** 原样的时间标签，如 00:06.650 */
  time: string;
  text: string;
}

function toLrcText(lines: RawLrcLine[]): string {
  const parts: string[] = [];
  for (const line of lines) {
    parts.push(`[${line.time}]${line.text}`);
  }
  return parts.join('\n');
}

/** 解析 `[时间]文本`；只保留时间标签是数字的行（`[ti:..]`/`[kuwo:..]` 这类元信息会被跳过） */
function parseRawLrc(text: string, stripWordTags: boolean): RawLrcLine[] {
  const out: RawLrcLine[] = [];
  const rows: string[] = text.split(/\r?\n/);
  for (const row of rows) {
    const match = /^\[([\d:.]*)\](.*)$/.exec(row.trim());
    if (match === null) {
      continue;
    }
    let content: string = match[2];
    if (stripWordTags) {
      content = content.replace(KW_WORD_TAG, '');
    }
    content = content.trim();
    if (content.length === 0) {
      continue;
    }
    out.push({ time: match[1], text: content });
  }
  return out;
}

/**
 * 同一时间点出现两句时，后一句其实是翻译（酷我歌词的排法）。
 * 这一条照抄洛雪 kw/lyric.js 的 sortLrcArr：把重复时间的后一句挪成
 * 「上一句时间的翻译」，避免界面上出现两条一样的词。
 */
function splitTranslation(lines: RawLrcLine[]): PlatformLyric {
  const indexOf: Map<string, number> = new Map();
  const lrc: RawLrcLine[] = [];
  const lrcT: RawLrcLine[] = [];
  for (const line of lines) {
    if (indexOf.get(line.time) !== undefined) {
      if (lrc.length < 2) {
        continue;
      }
      const moved: RawLrcLine | undefined = lrc.pop();
      if (moved === undefined) {
        continue;
      }
      moved.time = lrc[lrc.length - 1].time;
      lrcT.push(moved);
      lrc.push(line);
      indexOf.set(line.time, lrc.length - 1);
    } else {
      lrc.push(line);
      indexOf.set(line.time, lrc.length - 1);
    }
  }
  return { lyric: toLrcText(lrc), tlyric: lrcT.length > 0 ? toLrcText(lrcT) : '' };
}

// ------------------------------------------------------------------ 酷我

/**
 * 酷我：`mlyric.kuwo.cn/mobi.s?...&lrcx=1`
 * 响应是 `TP=content\r\nlrcx=1\r\n\r\n` + zlib 流；解压出来是 base64 文本，
 * 再按 'yeelion' 循环 XOR 得到 LRC（照抄 kw/decodeLyric.js）。
 */
async function kwLyric(songmid: string): Promise<PlatformLyric> {
  if (songmid.length === 0) {
    return EMPTY_LYRIC;
  }
  const url: string =
    `http://mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid=${encodeURIComponent(songmid)}&encode=utf8`;
  const bytes: number[] = await httpGetBinary(url);
  if (bytes.length < 16 || bytesToUtf8(bytes.slice(0, 10)).toLowerCase().indexOf('tp=content') !== 0) {
    return EMPTY_LYRIC;
  }
  // 头与正文之间是空行
  let bodyStart: number = -1;
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
      bodyStart = i + 4;
      break;
    }
  }
  if (bodyStart < 0) {
    return EMPTY_LYRIC;
  }
  const inflated: number[] = inflateZlib(toBytes(bytes), bodyStart);
  const xorSource: number[] = fromBase64(bytesToUtf8(inflated));
  if (xorSource.length === 0) {
    return EMPTY_LYRIC;
  }
  const key: number[] = utf8Bytes(KW_XOR_KEY);
  const decoded: number[] = [];
  for (let i = 0; i < xorSource.length; i++) {
    decoded.push((xorSource[i] ^ key[i % key.length]) & 0xFF);
  }
  return splitTranslation(parseRawLrc(bytesToUtf8(decoded), true));
}

// ------------------------------------------------------------------ 酷狗

/**
 * 酷狗：先按「歌名 + hash + 时长」搜歌词，再按 id/accesskey 下载。
 * `fmt=lrc` 时 content 是 base64 的明文 LRC；只有 krc（加密格式）时放弃。
 */
async function kgLyric(info: LxMusicInfo): Promise<PlatformLyric> {
  const hash: string = info.hash !== undefined ? info.hash : '';
  if (hash.length === 0) {
    return EMPTY_LYRIC;
  }
  const searchUrl: string =
    `http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=${encodeURIComponent(info.name)}` +
    `&hash=${hash}&timelength=${durationSeconds(info.interval)}&lrctxt=1`;
  const search: Record<string, Object> = await httpGetJson(searchUrl, KG_HEADERS);
  const candidates: Object[] = asObjectArray(search['candidates']);
  if (candidates.length === 0) {
    return EMPTY_LYRIC;
  }
  const first: Record<string, Object> = asRecord(candidates[0]);
  const id: string = asString(first['id']);
  const accessKey: string = asString(first['accesskey']);
  if (id.length === 0 || accessKey.length === 0) {
    return EMPTY_LYRIC;
  }
  const downloadUrl: string =
    `http://lyrics.kugou.com/download?ver=1&client=pc&id=${id}&accesskey=${accessKey}&fmt=lrc&charset=utf8`;
  const download: Record<string, Object> = await httpGetJson(downloadUrl, KG_HEADERS);
  if (asString(download['fmt']) !== 'lrc') {
    return EMPTY_LYRIC;
  }
  const content: string = asString(download['content']);
  if (content.length === 0) {
    return EMPTY_LYRIC;
  }
  return { lyric: bytesToUtf8(fromBase64(content)), tlyric: '' };
}

// ------------------------------------------------------------------ QQ 音乐

/**
 * QQ：老的 fcg 歌词接口，`nobase64=1` 直接给明文 LRC（UTF-8），
 * 正文里的数字实体（`&#58;` 之类）要解码。
 */
async function txLyric(songmid: string): Promise<PlatformLyric> {
  if (songmid.length === 0) {
    return EMPTY_LYRIC;
  }
  const url: string =
    'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' + encodeURIComponent(songmid) +
    '&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq&nobase64=1';
  const body: Record<string, Object> = await httpGetJson(url, TX_HEADERS);
  return {
    lyric: decodeName(asString(body['lyric'])),
    tlyric: decodeName(asString(body['trans'])),
  };
}

// ------------------------------------------------------------------ 咪咕

/**
 * 咪咕：先按 songId 查资源信息拿 lrcUrl，再取明文 LRC。
 * 新歌往往只有 mrcUrl（另一套 mrc 加密）而 `lrcUrl` 为空，这种就放弃。
 */
async function mgLyric(songmid: string): Promise<PlatformLyric> {
  if (songmid.length === 0) {
    return EMPTY_LYRIC;
  }
  const infoUrl: string = 'https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2';
  const form: Record<string, string> = { 'resourceId': songmid };
  const body: Record<string, Object> = await httpPostForm(infoUrl, form, MG_HEADERS);
  const resources: Object[] = asObjectArray(body['resource']);
  if (resources.length === 0) {
    return EMPTY_LYRIC;
  }
  const first: Record<string, Object> = asRecord(resources[0]);
  const lrcUrl: string = asString(first['lrcUrl']);
  if (lrcUrl.length === 0) {
    return EMPTY_LYRIC;
  }
  const lyric: string = await httpGetText(lrcUrl, MG_HEADERS);
  let tlyric: string = '';
  const trcUrl: string = asString(first['trcUrl']);
  if (trcUrl.length > 0) {
    try {
      tlyric = await httpGetText(trcUrl, MG_HEADERS);
    } catch (e) {
      tlyric = '';
    }
  }
  return { lyric: lyric, tlyric: tlyric };
}

// ------------------------------------------------------------------ 网易

const WY_HEADERS: Record<string, string> = {
  'Referer': 'https://music.163.com/',
};

/**
 * 网易：老的 web 歌词接口，明文 LRC 在 `lrc.lyric`，翻译在 `tlyric.lyric`。
 *
 * 这条路以前被记成「走不通」：当时试的是它 eapi 那套（要签名）的端点，返回 404。
 * 换这个公开 GET 就正常了（实测 code 200，中文词、英文歌的中文翻译都有）。
 * 补它的意义不只是「多一个平台」：网易的歌本来全靠音源给词，音源一失效
 * 整库都变成「暂无歌词」，内置取词才能让歌词不受音源死活影响。
 */
async function wyLyric(songmid: string): Promise<PlatformLyric> {
  if (songmid.length === 0) {
    return EMPTY_LYRIC;
  }
  const url: string =
    `https://music.163.com/api/song/lyric?id=${encodeURIComponent(songmid)}&lv=-1&kv=-1&tv=-1`;
  const body: Record<string, Object> = await httpGetJson(url, WY_HEADERS);
  const lyric: string = asString(asRecord(body['lrc'])['lyric']);
  const tlyric: string = asString(asRecord(body['tlyric'])['lyric']);
  if (lyric.length === 0) {
    return EMPTY_LYRIC;
  }
  // 纯音乐/纯文本词没有时间轴，交给调用方判空（有翻译也一起带回去）
  return { lyric: lyric, tlyric: tlyric };
}

// ------------------------------------------------------------------ 入口

/** 按平台取内置歌词；任何失败都返回空，界面显示「暂无歌词」 */
export async function fetchPlatformLyric(info: LxMusicInfo): Promise<PlatformLyric> {
  try {
    if (info.source === 'wy') {
      return await wyLyric(info.songmid);
    }
    if (info.source === 'kw') {
      return await kwLyric(info.songmid);
    }
    if (info.source === 'kg') {
      return await kgLyric(info);
    }
    if (info.source === 'tx') {
      return await txLyric(info.songmid);
    }
    if (info.source === 'mg') {
      return await mgLyric(info.songmid);
    }
  } catch (e) {
    return EMPTY_LYRIC;
  }
  return EMPTY_LYRIC;
}
