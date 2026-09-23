import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo, fetchMusicPic } from '../music/MusicSearch';
import { CachedLyricInfo, MediaCache, mediaKeyOf } from '../music/MediaCache';
import { PlatformLyric, fetchPlatformLyric } from '../music/PlatformLyric';
import { asRecord, asString } from '../music/PlatformHttp';
import { SourceEngine } from '../source/SourceEngine';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadTags';

/**
 * 下载时的封面与歌词收集
 *
 * 下载器只管把音频字节落盘，「要嵌进去的封面和歌词长什么样」在这里凑齐 ——
 * 两者都是网络请求，跟解析播放链接一起开跑（见 DownloadManager.runTask），
 * 收不齐就不嵌：**标签是锦上添花，不能因为它把下载弄失败**。
 *
 * 与播放页取封面 / 歌词走同一批来源，顺序也一样：
 *   封面 —— 条目自带的 coverUrl -> musicInfo.img -> 封面地址缓存 -> 平台接口现查；
 *   歌词 —— 歌词缓存 -> 源脚本的 lyric action -> 内置平台歌词（kw/kg/tx/mg/wy）。
 */

/**
 * 收集标签的总超时
 *
 * 封面与歌词一起开跑，从开始到放弃一共等这么久（不是各等一次）：
 * 平台接口抽风时不能一直卡着，下载该开始就开始，大不了这一首没标签。
 */
const COLLECT_TIMEOUT_MS: number = 12000;

/** 封面原图上限：内嵌封面是给播放器看的，几 MB 的大图不往文件里塞 */
const COVER_MAX_BYTES: number = 6 * 1024 * 1024;

/** 封面请求用的 UA：部分图床对空 UA 会直接拒绝 */
const UA: string = 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99 Mobile Safari/537.36';

/** 带时间轴的歌词（`[00:12.34]`），与播放页 hasTimeTag 一致 */
const TIME_TAG: RegExp = /\[\d{1,2}:.*\d{1,4}\]/;

/** 写进音频文件的标签内容（字段含义见 TagWriter） */
export interface DownloadTagData {
  title: string;
  artist: string;
  album: string;
  /** LRC（带时间轴）或纯文本歌词；空串表示没有 */
  lyric: string;
  /** 封面原图字节（JPEG / PNG）；null 表示没有 */
  cover: number[] | null;
  coverMime: string;
  coverWidth: number;
  coverHeight: number;
}

interface CoverBits {
  bytes: number[];
  mime: string;
  width: number;
  height: number;
}

/** 接口返回的歌词体（源脚本的 lyric action 也是这个结构） */
interface LyricBody {
  lyric: string;
  tlyric: string;
}

const EMPTY_LYRIC: LyricBody = { lyric: '', tlyric: '' };

/**
 * 已嵌入内容的说法（列表里显示）
 *
 * 只有真的写进文件了才由调用方拿去显示；封面与歌词都没嵌进去时返回空串，
 * 免得在列表里写一句「已嵌入」让用户以为嵌了。
 */
export function tagSummary(data: DownloadTagData): string {
  const parts: string[] = [];
  if (data.cover !== null) {
    parts.push('封面');
  }
  if (data.lyric.length > 0) {
    parts.push('歌词');
  }
  return parts.length > 0 ? `已嵌入${parts.join('与')}` : '';
}

/**
 * 凑齐一首歌要嵌入的封面与歌词
 *
 * 任何一步失败都只影响对应的那一项，不会抛出去（下载不该因为标签失败）。
 */
export async function collectDownloadTags(
  name: string,
  singer: string,
  musicInfoJson: string,
  coverUrl: string,
): Promise<DownloadTagData> {
  let info: LxMusicInfo | null = null;
  if (musicInfoJson.length > 0) {
    try {
      info = JSON.parse(musicInfoJson) as LxMusicInfo;
    } catch (e) {
      info = null;
    }
  }
  const deadline: number = Date.now() + COLLECT_TIMEOUT_MS;
  // 两个请求同时发出去，再依次等结果：等第一个的时间不会被第二个叠加
  const coverTask: Promise<CoverBits | null> = resolveCover(coverUrl, info, musicInfoJson);
  const lyricTask: Promise<string> = resolveLyric(info, musicInfoJson);
  const cover: CoverBits | null = await withTimeout(coverTask, deadline - Date.now(), null);
  const lyric: string = await withTimeout(lyricTask, deadline - Date.now(), '');
  const data: DownloadTagData = {
    title: name,
    artist: singer,
    album: info !== null ? orEmpty(info.albumName) : '',
    lyric: lyric,
    cover: null,
    coverMime: '',
    coverWidth: 0,
    coverHeight: 0,
  };
  if (cover !== null) {
    data.cover = cover.bytes;
    data.coverMime = cover.mime;
    data.coverWidth = cover.width;
    data.coverHeight = cover.height;
  }
  return data;
}

// ------------------------------------------------------------------ 封面

/** 封面：拿到地址 -> 下原图 -> 从图片头里读出真实格式与尺寸 */
async function resolveCover(
  coverUrl: string,
  info: LxMusicInfo | null,
  musicInfoJson: string,
): Promise<CoverBits | null> {
  let url: string = coverUrl;
  if (url.length === 0 && info !== null) {
    url = orEmpty(info.img);
  }
  if (url.length === 0 && musicInfoJson.length > 0) {
    const key: string = mediaKeyOf(musicInfoJson);
    if (key.length > 0) {
      url = MediaCache.getInstance().getPic(key);
    }
  }
  // kw / kg 的搜索结果不带封面，只能按接口现查（与列表里那条「懒解析」同一批接口）
  if (url.length === 0 && info !== null) {
    try {
      url = await fetchMusicPic(info);
    } catch (e) {
      url = '';
    }
  }
  if (!url.startsWith('http')) {
    return null;
  }
  const bytes: number[] = await fetchBinary(url);
  if (bytes.length === 0 || bytes.length > COVER_MAX_BYTES) {
    if (bytes.length > COVER_MAX_BYTES) {
      hilog.warn(DOMAIN, TAG, 'cover too large (%{public}d bytes), skip', bytes.length);
    }
    return null;
  }
  return readImageInfo(bytes);
}

/** 下一份二进制（封面原图）；失败返回空数组，不抛 */
function fetchBinary(url: string): Promise<number[]> {
  return new Promise<number[]>((resolve: (value: number[]) => void) => {
    const request: http.HttpRequest = http.createHttp();
    const headers: Record<string, string> = { 'User-Agent': UA };
    const done = (bytes: number[]): void => {
      try {
        request.destroy();
      } catch (e) {
        // 已经结束的请求 destroy 报错无所谓
      }
      resolve(bytes);
    };
    request.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 10000,
      readTimeout: 20000,
    }).then((response: http.HttpResponse) => {
      const body: string | Object | ArrayBuffer = response.result;
      done(response.responseCode === http.ResponseCode.OK && body instanceof ArrayBuffer
        ? toNumbers(body as ArrayBuffer) : []);
    }).catch((e: Object) => {
      hilog.warn(DOMAIN, TAG, 'cover download failed: %{public}s', JSON.stringify(e));
      done([]);
    });
  });
}

/**
 * 图片头里读格式与尺寸
 *
 * 不解析图片本身（封面只是要嵌进文件，尺寸只是 PICTURE 块的元信息）：
 * PNG 的宽高在 IHDR 里固定位置；JPEG 顺着段长走到 SOF 段即可。
 * 认不出格式的（webp / gif / 下回来一页 HTML）一律放弃 —— 写进去也没播放器认。
 */
function readImageInfo(bytes: number[]): CoverBits | null {
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E
    && bytes[3] === 0x47) {
    const width: number = u32beAt(bytes, 16);
    const height: number = u32beAt(bytes, 20);
    if (width > 0 && height > 0) {
      return { bytes: bytes, mime: 'image/png', width: width, height: height };
    }
    return null;
  }
  if (bytes.length >= 4 && bytes[0] === 0xFF && bytes[1] === 0xD8) {
    const size: number[] = jpegSize(bytes);
    if (size.length === 2) {
      return { bytes: bytes, mime: 'image/jpeg', width: size[0], height: size[1] };
    }
  }
  return null;
}

/** JPEG：跳过各段，在 SOF 段里读宽高（返回 [] 表示没找到） */
function jpegSize(bytes: number[]): number[] {
  let offset: number = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xFF) {
      offset++;
      continue;
    }
    const marker: number = bytes[offset + 1];
    // 无长度字段的标记：填充、以及重启标记
    if (marker === 0xFF || marker === 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    const length: number = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) {
      return [];
    }
    // SOF0..SOF15 里带尺寸（C4 是霍夫曼表、C8 是 JPEG 扩展、CC 是算术编码表，都不带）
    if (marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8
      && marker !== 0xCC) {
      const height: number = (bytes[offset + 5] << 8) | bytes[offset + 6];
      const width: number = (bytes[offset + 7] << 8) | bytes[offset + 8];
      return width > 0 && height > 0 ? [width, height] : [];
    }
    offset += 2 + length;
  }
  return [];
}

// ------------------------------------------------------------------ 歌词

/** 歌词：缓存 -> 源脚本 -> 内置平台歌词（与播放页取词同一条链） */
async function resolveLyric(info: LxMusicInfo | null, musicInfoJson: string): Promise<string> {
  if (musicInfoJson.length === 0) {
    return '';
  }
  const key: string = mediaKeyOf(musicInfoJson);
  if (key.length > 0) {
    const cached: CachedLyricInfo | null = MediaCache.getInstance().getLyric(key);
    if (cached !== null) {
      const merged: string = mergeTranslation(cached.lyric, cached.tlyric);
      if (merged.length > 0) {
        return merged;
      }
    }
  }
  if (info === null) {
    return '';
  }
  const engine = SourceEngine.getInstance();
  if (engine.isInited() && engine.supportsAction(info.source, 'lyric')) {
    try {
      const fromSource: LyricBody = parseLyricBody(await engine.getLyric(musicInfoJson, info.source));
      // 源只给纯文本（没有时间轴）时继续走内置：有轴的词才跟着进度滚
      if (TIME_TAG.test(fromSource.lyric)) {
        return mergeTranslation(fromSource.lyric, fromSource.tlyric);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'source lyric failed: %{public}s', (e as Error).message);
    }
  }
  try {
    const result: PlatformLyric = await fetchPlatformLyric(info);
    return mergeTranslation(result.lyric, result.tlyric);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'platform lyric failed: %{public}s', (e as Error).message);
    return '';
  }
}

/** 源脚本 lyric action 的返回值：`{ data: { lyric, tlyric } }` */
function parseLyricBody(raw: string): LyricBody {
  try {
    const body: Record<string, Object> = asRecord(JSON.parse(raw) as Object);
    const data: Record<string, Object> = asRecord(body['data']);
    return { lyric: asString(data['lyric']), tlyric: asString(data['tlyric']) };
  } catch (e) {
    return EMPTY_LYRIC;
  }
}

/**
 * 原文与译文合成一份双语歌词
 *
 * 逐字对齐原文行的时间标签，把译文那一句紧跟在原文后面 —— 这是双语 LRC 的通行写法
 * （同一时间点两行），播放器会把译文当第二行显示。时间标签对不上就不合，
 * 免得嵌进去一份读不出对应关系的词。
 */
function mergeTranslation(lyric: string, tlyric: string): string {
  if (lyric.length === 0) {
    return tlyric;
  }
  if (tlyric.length === 0 || !TIME_TAG.test(lyric) || !TIME_TAG.test(tlyric)) {
    return lyric;
  }
  const byTime: Map<string, string> = new Map();
  for (const row of tlyric.split(/\r?\n/)) {
    const match = /^\[([\d:.]+)\]\s*(.+)$/.exec(row.trim());
    if (match !== null) {
      byTime.set(match[1], match[2]);
    }
  }
  if (byTime.size === 0) {
    return lyric;
  }
  const out: string[] = [];
  for (const row of lyric.split(/\r?\n/)) {
    out.push(row);
    const match = /^\[([\d:.]+)\]\s*(.+)$/.exec(row.trim());
    if (match === null) {
      continue;
    }
    const translation: string | undefined = byTime.get(match[1]);
    if (translation !== undefined) {
      out.push(`[${match[1]}]${translation}`);
    }
  }
  return out.join('\n');
}

// ------------------------------------------------------------------ 小工具

function orEmpty(value: string | undefined): string {
  return value !== undefined && value !== null ? value : '';
}

function u32beAt(bytes: number[], offset: number): number {
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8)
    | bytes[offset + 3]) >>> 0;
}

function toNumbers(data: ArrayBuffer): number[] {
  const view = new Uint8Array(data);
  const out: number[] = [];
  for (let i = 0; i < view.length; i++) {
    out.push(view[i]);
  }
  return out;
}

/** 等一个 promise，超时或失败都退回到 fallback（标签收集永远不抛给下载流程） */
function withTimeout<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void) => {
    let settled: boolean = false;
    const timer = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(fallback);
    }, ms > 0 ? ms : 0);
    promise.then((value: T) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }).catch(() => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(fallback);
    });
  });
}
