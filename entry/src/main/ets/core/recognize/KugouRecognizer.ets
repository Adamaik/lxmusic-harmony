import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Md5 } from './Md5';
import { RecognitionResult } from './RecognitionTypes';
import { RecognitionNetworkError } from './errors';

const DOMAIN: number = 0x0001;
const TAG: string = 'KugouRecognizer';

const REQUEST_TIMEOUT_MS = 10000;
/** 酷狗 Android 客户端的固定签名 key（协议常量，不是我们的密钥） */
const ANDROID_KEY = 'OIlwieks28dk2k092lksi2UIkp';
const APP_ID = 1005;
const CLIENT_VERSION = 20489;
/** 每个引擎最多展示几条候选（多了列表里也挑不过来） */
const MAX_RESULTS = 5;

/**
 * 采集 PCM 是 s16le 单声道 16000Hz，酷狗识曲接口要 8000Hz，按点对平均降采样。
 * 取平均（而不是抽点）是因为这里已经是最后一步降采样，滤一下高频能少些毛刺。
 */
const resampleTo8k = (pcm: Int16Array): Uint8Array => {
  const outSamples: number = Math.floor(pcm.length / 2);
  const out = new Uint8Array(outSamples * 2);
  const view = new DataView(out.buffer);
  for (let i = 0; i < outSamples; i++) {
    const a: number = pcm[i * 2];
    const b: number = i * 2 + 1 < pcm.length ? pcm[i * 2 + 1] : a;
    const value: number = Math.max(-32768, Math.min(32767, Math.round((a + b) / 2)));
    view.setInt16(i * 2, value, true);
  }
  return out;
};

const md5Hex = (value: string): string => {
  const encoder = new util.TextEncoder();
  return Md5.hex(encoder.encodeInto(value));
};

/**
 * 设备标识
 *
 * 酷狗的正式版 Android 客户端把 MD5 出来的设备号当**无符号大整数**用（mid 那一串
 * 十进制的长度就有 39 位，明显超了 Number 的安全范围），所以这里必须走 BigInt，
 * 用 Number 会精度丢失、签名跟着对不上；也不能随便造一个随机 hex 当 mid。
 */
const getDeviceIdentity = (): Record<string, string> => {
  const dfid = '-';
  const mid: string = BigInt(`0x${md5Hex(dfid)}`).toString();
  const uuid: string = md5Hex(`${dfid}${mid}`);
  return { 'dfid': dfid, 'mid': mid, 'uuid': uuid };
};

/** 与 KuGou.Net / KuGouMusicApi 一致的 Android 签名：MD5(key + 排序后的 name=value + 原始二进制 body + key) */
const signRequest = (params: Record<string, string>, body: Uint8Array): string => {
  const keys: Array<string> = Object.keys(params).sort();
  let paramsString = '';
  for (const name of keys) {
    paramsString += `${name}=${params[name]}`;
  }
  const encoder = new util.TextEncoder();
  const head: Uint8Array = encoder.encodeInto(ANDROID_KEY + paramsString);
  const tail: Uint8Array = encoder.encodeInto(ANDROID_KEY);
  const total = new Uint8Array(head.length + body.length + tail.length);
  total.set(head, 0);
  total.set(body, head.length);
  total.set(tail, head.length + body.length);
  return Md5.hex(total);
};

/** 候选条目的专辑字段（老接口给对象、新接口给字符串，字段名还不统一） */
interface KugouAlbum {
  albumname?: string;
  album_name?: string;
  name?: string;
}

/**
 * 把酷狗返回的一条候选映射成统一结果
 *
 * 字段名两套并存（下划线与驼峰），是因为这个接口在不同 clientver 下返回的结构不一样，
 * 两边都兜一下比认死一套稳。取不到歌名的条目直接丢掉（界面上没法展示）。
 */
const mapItem = (item: Record<string, Object>): RecognitionResult | undefined => {
  const baseName: string = item['songname'] !== undefined ? item['songname'] as string : item['song_name'] as string;
  if (baseName === undefined || baseName === '') {
    return undefined;
  }
  // 「现场版」这类后缀单独一个字段，拼进歌名里才看得出是哪一版
  const nameSuffix: string = item['songNameSuffix'] !== undefined
    ? item['songNameSuffix'] as string
    : (item['song_name_suffix'] !== undefined ? item['song_name_suffix'] as string : '');
  const suffix: string = nameSuffix === '' ? '' : ` (${nameSuffix})`;
  const authors: Array<Object> = item['authors'] as Array<Object>;
  let artist = '';
  const singerName: Object = item['singername'];
  const singerName2: Object = item['singer_name'];
  if (singerName !== undefined) {
    artist = singerName as string;
  } else if (singerName2 !== undefined) {
    artist = singerName2 as string;
  } else if (authors !== undefined) {
    const names: Array<string> = [];
    for (const author of authors) {
      const authorRecord: Record<string, Object> = author as Record<string, Object>;
      const name: Object = authorRecord['name'];
      const authorName: Object = authorRecord['author_name'];
      if (name !== undefined) {
        names.push(name as string);
      } else if (authorName !== undefined) {
        names.push(authorName as string);
      }
    }
    artist = names.join('、');
  }

  // 专辑可能是字符串、对象，也可能是一个只取首项的数组
  let albumRaw: Object | undefined = item['album'];
  if (Array.isArray(albumRaw)) {
    const albumList: Array<Object> = albumRaw as Array<Object>;
    albumRaw = albumList.length > 0 ? albumList[0] as Object : undefined;
  }
  let albumName = '';
  if (typeof albumRaw === 'string') {
    albumName = albumRaw as string;
  } else if (albumRaw !== undefined) {
    const album: KugouAlbum = albumRaw as KugouAlbum;
    let name: string = '';
    if (album.albumname !== undefined) {
      name = album.albumname;
    } else if (album.album_name !== undefined) {
      name = album.album_name;
    } else if (album.name !== undefined) {
      name = album.name;
    }
    albumName = name;
  }
  if (albumName === '' && item['album_name'] !== undefined) {
    albumName = item['album_name'] as string;
  }

  // 播放要靠 32 位十六进制的文件 hash，接口里叫什么都不一定，逐个试；
  // 都没有就退回数值 songid（那多半播不了，界面上会走「按歌名搜索」补播）
  let trackIdStr: string = '';
  const hashKeys: string[] = ['hash', 'file_hash', 'filehash', 'hash_320', 'hash_128', 'hash320', 'hash128', 'mixsongid'];
  for (const key of hashKeys) {
    const raw: Object = item[key];
    if (raw !== undefined && raw !== null) {
      const candidate: string = String(raw);
      if (candidate.length > 0 && /^[0-9A-Fa-f]{32}$/.test(candidate)) {
        trackIdStr = candidate;
        break;
      }
    }
  }
  if (trackIdStr.length === 0) {
    const fallbackId: Object = item['songid'] !== undefined ? item['songid'] : item['song_id'];
    trackIdStr = fallbackId !== undefined ? String(fallbackId) : baseName;
  }

  const coverRaw: Object = item['union_cover'];
  let coverUrl = '';
  if (typeof coverRaw === 'string') {
    // 封面地址里带 {size} 占位，换成具体尺寸才是真地址
    coverUrl = (coverRaw as string).replace('{size}', '400');
  }

  return RecognitionResult.create(
    `${baseName}${suffix}`, artist, albumName, coverUrl,
    `kg:${trackIdStr}`, Date.now());
};

/**
 * 酷狗听歌识曲：把 16k PCM 降到 8k 直接 POST 给指纹接口，拿回候选列表。
 *
 * 不需要音源脚本、也不需要登录，是「内置能力」的一部分；失败一律抛
 * {@link RecognitionNetworkError}，由 RecognitionEngine 归并成「这个引擎没结果」。
 */
export const recognizeKugou = async(pcm: Int16Array): Promise<Array<RecognitionResult>> => {
  hilog.info(DOMAIN, TAG, '识别开始 pcm=%{public}d samples', pcm.length);
  const body: Uint8Array = resampleTo8k(pcm);
  if (body.length === 0) {
    hilog.warn(DOMAIN, TAG, '降采样后音频为空');
    return [];
  }
  hilog.info(DOMAIN, TAG, '8k PCM body=%{public}d bytes', body.length);
  const clienttime: number = Math.floor(Date.now() / 1000);
  const device: Record<string, string> = getDeviceIdentity();
  const params: Record<string, string> = {
    'dfid': device['dfid'],
    'mid': device['mid'],
    'uuid': device['uuid'],
    'appid': String(APP_ID),
    'clientver': String(CLIENT_VERSION),
    'clienttime': String(clienttime),
    'fpid': String(Date.now()),
    'area_code': '1',
    'include_unpublish': '1',
    'useid': '0',
    'multi_result': '1',
  };
  const signature: string = signRequest(params, body);
  const keys: Array<string> = Object.keys(params).sort();
  let query = '';
  for (const name of keys) {
    if (query !== '') {
      query += '&';
    }
    query += `${name}=${params[name]}`;
  }
  query += `&signature=${signature}`;
  const url: string = `https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit?${query}`;

  const httpRequest = http.createHttp();
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    header: {
      'content-type': 'application/octet-stream',
      'user-agent': 'KuGou/11490 (Android)',
      'dfid': '-',
      'mid': device['mid'],
      'clienttime': String(clienttime),
      'kg-rc': '1',
      'kg-thash': '5d816a0',
      'kg-rec': '1',
      'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
    },
    extraData: body.buffer as ArrayBuffer,
    connectTimeout: REQUEST_TIMEOUT_MS,
    readTimeout: REQUEST_TIMEOUT_MS,
    expectDataType: http.HttpDataType.STRING,
  };
  let response: http.HttpResponse;
  try {
    response = await httpRequest.request(url, options);
  } catch (err) {
    hilog.error(DOMAIN, TAG, '网络请求异常: %{public}s', JSON.stringify(err));
    throw new RecognitionNetworkError('酷狗听歌识曲网络请求失败');
  } finally {
    httpRequest.destroy();
  }
  hilog.info(DOMAIN, TAG, 'HTTP status=%{public}d', response.responseCode);
  if (response.responseCode < 200 || response.responseCode >= 300) {
    hilog.error(DOMAIN, TAG, '服务返回非2xx: %{public}d', response.responseCode);
    throw new RecognitionNetworkError(`酷狗听歌识曲服务请求失败（${response.responseCode}）`);
  }
  const resultStr: string = response.result as string;
  hilog.info(DOMAIN, TAG, '响应原文(前200): %{public}s', resultStr.substring(0, 200));
  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(resultStr) as Record<string, Object>;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'JSON解析失败: %{public}s', resultStr.substring(0, 120));
    throw new RecognitionNetworkError('酷狗听歌识曲服务返回数据异常');
  }
  const status: Object = parsed['status'];
  const errorCode: Object = parsed['error_code'];
  hilog.info(DOMAIN, TAG, 'status=%{public}s error_code=%{public}s', String(status), String(errorCode));
  // status != 1 就是「没认出来」（不是错误），返回空列表让引擎那边报 notMatched
  if (status !== 1) {
    hilog.warn(DOMAIN, TAG, 'status != 1，视为未匹配');
    return [];
  }
  const dataRaw: Object = parsed['data'];
  let items: Array<Object> = [];
  if (dataRaw === undefined) {
    hilog.warn(DOMAIN, TAG, 'data 缺失，视为未匹配');
    return [];
  }
  if (Array.isArray(dataRaw)) {
    items = dataRaw as Array<Object>;
  } else {
    const dataRecord: Record<string, Object> = dataRaw as Record<string, Object>;
    const list: Array<Object> = dataRecord['list'] as Array<Object>;
    const songs: Array<Object> = dataRecord['songs'] as Array<Object>;
    if (list !== undefined) {
      items = list;
    } else if (songs !== undefined) {
      items = songs;
    } else {
      const keys: string[] = Object.keys(dataRecord);
      hilog.warn(DOMAIN, TAG, 'data 无 list/songs 字段，keys=%{public}s', keys.join(','));
    }
  }
  hilog.info(DOMAIN, TAG, '候选条目数=%{public}d', items.length);
  if (items.length > 0) {
    const first: Record<string, Object> = items[0] as Record<string, Object>;
    hilog.info(DOMAIN, TAG, '首条字段keys=%{public}s', Object.keys(first).join(','));
  }
  const results: Array<RecognitionResult> = [];
  for (const item of items) {
    const mapped: RecognitionResult | undefined = mapItem(item as Record<string, Object>);
    if (mapped !== undefined) {
      results.push(mapped);
      hilog.info(DOMAIN, TAG, '命中候选: %{public}s - %{public}s id=%{public}s',
        mapped.title, mapped.artist, mapped.providerTrackId);
      if (results.length >= MAX_RESULTS) {
        break;
      }
    }
  }
  hilog.info(DOMAIN, TAG, '识别完成 结果数=%{public}d', results.length);
  return results;
};
