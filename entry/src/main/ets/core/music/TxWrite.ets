import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { musicAccount, txMusicKeyOf, txUinOf, TX_UA } from './MusicAccount';
import { createZzcSign } from './MusicSearch';
import { asNumber, asRecord, asString } from './PlatformHttp';
import { bytesToUtf8, utf8Bytes } from './PlatformCrypto';

const DOMAIN: number = 0x0001;
const TAG: string = 'TxWrite';

/** 「我喜欢」在 QQ 音乐里的固定目录号 */
const DIR_LIKE: number = 201;

/** 写通道：musics.fcg + zzc 签名 + ag-1 加密体（明文 musicu 通道对 201 返回 80105，不生效） */
/** 写接口：明文 musicu.fcg（与参考实现一致；ag-1 通道实测服务端不认） */
const WRITE_ENDPOINT: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
/** 写请求的 client version（参考实现同款，服务端按它判客户端形态） */
const WRITE_VERSION: number = 13020508;
/** 写请求 UA（浏览器形态，与网页版一致） */
const TX_WRITE_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
/** 只读通道：musicu.fcg（项目搜索 / 账号信息已在用，明文 JSON 即可） */
const READ_ENDPOINT: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg';

/** 单次请求超时（写与只读统一 10s；重试 / 批量节奏由编排层控制，函数内不重发） */
const REQUEST_TIMEOUT_MS: number = 10000;

/**
 * ag-1 请求体的 AES-128 固定密钥（16 字节）
 *
 * 来源：QQ 音乐网页 vendor bundle 的 cgiEncrypt 分支（qmweb-sign 固定源码：
 * requestKey = [189, 48, 95, 16, 208, 255, 116, 182, 239, 84, 218, 184, 53, 181, 225, 207]）。
 * 这**不是**登录票据，是端上写死的协议密钥；每次请求另配 12 字节随机 IV。
 */
const AG1_REQUEST_KEY: number[] = [
  189, 48, 95, 16, 208, 255, 116, 182, 239, 84, 218, 184, 53, 181, 225, 207,
];

/**
 * ag-1 响应体的 XOR 混淆密钥（21 字节，按位循环）
 *
 * 响应不是 AES-GCM，而是「字节 XOR 固定 21 字节表」后再按 UTF-8 解码成 JSON
 * （同 qmweb-sign decodeAG1Response）。解码必须用**默认（非 fatal）** UTF-8：
 * 实号写入的成功响应里会混入不规范字节，fatal 模式会把已生效的写入误报成解析失败。
 */
const AG1_RESPONSE_KEY: number[] = [
  122, 63, 140, 29, 94, 155, 47, 10, 108, 77, 126, 139, 31, 58, 92, 157, 14, 43, 111, 74, 129,
];

/** QQ 音乐写操作（红心）结果：ok=false 时 code 是能拿到的业务码（拿不到就是 -1） */
export interface TxWriteResult {
  ok: boolean;
  code: number;
  message: string;
}

function okResult(message: string): TxWriteResult {
  return { ok: true, code: 0, message: message };
}

function failResult(code: number, message: string): TxWriteResult {
  return { ok: false, code: code, message: message };
}

/** 取 Cookie 里某一项的值（MusicAccount 只导出了 uin / 票据的取值器，g_tk 还要看 skey/p_skey） */
function cookieItem(cookie: string, name: string): string {
  for (const pair of cookie.split(';')) {
    const text: string = pair.trim();
    const eq: number = text.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    if (text.substring(0, eq).trim() === name) {
      return text.substring(eq + 1).trim();
    }
  }
  return '';
}

/** QQ 的 hash33（g_tk 算法）：seed 5381，逐字符 `hash = hash*33 + c`，取 31 位 */
function hash33(value: string): number {
  let hash: number = 5381;
  for (let i = 0; i < value.length; i++) {
    hash = ((hash << 5) + hash + value.charCodeAt(i)) & 0x7fffffff;
  }
  return hash;
}

/**
 * 计算写请求的 g_tk
 *
 * 口径：**按 Cookie 算，skey / p_skey 优先**（任务调研口径），再退音乐票据
 * qm_keyst / qqmusic_key。注意两点，真机复测时按这个顺序排查：
 *   1) y.qq.com 网页登录一般只下发 qm_keyst，很少带 skey/p_skey —— 此时最终落到的
 *      就是音乐票据，与「实号成功的第三方实现（WaveForge）直接用 qm_keyst 算」一致；
 *   2) 若真机上 Cookie **同时**带 skey 与 qm_keyst 而写入仍返回 80105/2000，
 *      先试着把优先级换成 qm_keyst 优先再测（见任务报告「需真机实测」）。
 */
function txGtkOf(cookie: string): number {
  const candidates: string[] = ['skey', 'p_skey', 'qm_keyst', 'qqmusic_key'];
  for (const name of candidates) {
    const value: string = cookieItem(cookie, name);
    if (value.length > 0) {
      return hash33(value);
    }
  }
  return hash33('');
}

/** number[] -> Uint8Array（cryptoFramework 只收 Uint8Array） */
function toU8(bytes: number[]): Uint8Array {
  const u8: Uint8Array = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    u8[i] = bytes[i] & 0xFF;
  }
  return u8;
}

/**
 * ag-1 加密请求体：`AES-128-GCM(固定 key, 随机 12B IV, 无 AAD)`，输出 = IV ‖ 密文 ‖ 16B tag
 *
 * 与 qmweb-sign 的 encodeAG1Request 逐字节等价：WebCrypto 的 GCM 输出是「密文 ‖ tag」，
 * 再把 12 字节 IV 拼到最前面；本机 cryptoFramework 的 `doFinalSync(明文)` 在 GCM 单次
 * 加密下同样返回「密文 ‖ 最后 16B 是 tag」，所以这里直接 `IV + doFinalSync(明文)`。
 *
 * 需真机实测：OH 的 GcmParamsSpec 在**加密**时对 authTag 字段的处理（这里传 16 字节 0 占位，
 * 与官方示例一致），以及空 AAD 是否被当作「无附加数据」（协议侧等价于不传 AAD）。
 */
function encodeAg1Request(text: string): ArrayBuffer {
  const keyBlob: cryptoFramework.DataBlob = { data: toU8(AG1_REQUEST_KEY) };
  const key: cryptoFramework.SymKey =
    cryptoFramework.createSymKeyGenerator('AES128').convertKeySync(keyBlob);
  const iv: Uint8Array = cryptoFramework.createRandom().generateRandomSync(12).data;
  const spec: cryptoFramework.GcmParamsSpec = {
    algName: 'GcmParamsSpec',
    iv: { data: iv },
    aad: { data: new Uint8Array(0) },
    authTag: { data: new Uint8Array(16) },
  };
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|GCM|PKCS7');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, spec);
  const plain: cryptoFramework.DataBlob = { data: toU8(utf8Bytes(text)) };
  const sealed: cryptoFramework.DataBlob = cipher.doFinalSync(plain);
  const sealedBytes: Uint8Array = sealed.data;
  const buffer: ArrayBuffer = new ArrayBuffer(12 + sealedBytes.length);
  const view: Uint8Array = new Uint8Array(buffer);
  for (let i = 0; i < 12; i++) {
    view[i] = iv[i];
  }
  for (let i = 0; i < sealedBytes.length; i++) {
    view[12 + i] = sealedBytes[i];
  }
  return buffer;
}

/** ag-1 响应解码：按 21 字节表循环 XOR，再默认（非 fatal）UTF-8 解码 */
function decodeAg1Response(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  const plain: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    plain.push((bytes[i] ^ AG1_RESPONSE_KEY[i % AG1_RESPONSE_KEY.length]) & 0xFF);
  }
  return bytesToUtf8(plain);
}

/** 发一次二进制请求（ag-1 加密体必须原样发字节，不能走 JSON 序列化） */
async function postBinary(url: string, body: ArrayBuffer,
  headers: Record<string, string>): Promise<http.HttpResponse> {
  const request: http.HttpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: REQUEST_TIMEOUT_MS,
      readTimeout: REQUEST_TIMEOUT_MS,
      // 写请求禁止跟随重定向：避免请求头里的 Cookie 被带到别的地址
      maxRedirects: 0,
    };
    return await request.request(url, options);
  } finally {
    request.destroy();
  }
}

/** 发一次普通 JSON 文本请求（只读详情用） */
async function postJsonText(url: string, body: string,
  headers: Record<string, string>): Promise<http.HttpResponse> {
  const request: http.HttpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: REQUEST_TIMEOUT_MS,
      readTimeout: REQUEST_TIMEOUT_MS,
      maxRedirects: 0,
    };
    return await request.request(url, options);
  } finally {
    request.destroy();
  }
}

/** 错误码 -> 中文提示（80105 / 2000 是这条链路上最需要看懂的两个） */
function txCodeMessage(code: number): string {
  if (code === 80105) {
    return 'QQ 音乐返回 80105：写通道未被接受（通常是 ag-1 封装或 g_tk 口径问题，需真机复测）';
  }
  if (code === 2000) {
    return 'QQ 音乐返回 2000：请求签名校验未通过（sign / ag-1 不被接受）';
  }
  if (code === 1000) {
    return 'QQ 音乐返回 1000：登录态已失效，请重新登录 QQ 音乐';
  }
  if (code === 301 || code === 403) {
    return `QQ 音乐返回 ${code}：需要登录或没有权限`;
  }
  return `QQ 音乐返回错误 ${code}`;
}

/** 拼出「中文解释（服务端 msg）」；服务端 msg 只放消息体，绝不放 Cookie / 签名 */
function txErrorMessage(code: number, serverMessage: string): string {
  const base: string = txCodeMessage(code);
  return serverMessage.length > 0 ? `${base}（${serverMessage}）` : base;
}

/** 响应里的业务块：优先 req_0，个别通道回 req */
function requestBlockOf(body: Record<string, Object>): Record<string, Object> {
  const primary: Record<string, Object> = asRecord(body['req_0']);
  if (Object.keys(primary).length > 0) {
    return primary;
  }
  return asRecord(body['req']);
}

/**
 * 逐层校验业务码：HTTP 200 → 外层 code → 业务块 code → data.retCode
 *
 * 规则：**任何一层出现了非 0 就失败**；一层业务码都没有也按失败处理（不允许假成功，
 * 与 §2.8 记录的「外层 0 / 业务块 80105 / retCode 0 只查一层会误报成功」同一口径）。
 * 通过时返回 null，失败时返回带中文原因的 TxWriteResult。
 */
function checkBusinessLayers(body: Record<string, Object>): TxWriteResult | null {
  let sawCode: boolean = false;
  const outerCode: Object | undefined = body['code'];
  if (outerCode !== undefined && outerCode !== null) {
    sawCode = true;
    const code: number = asNumber(outerCode, -1);
    if (code !== 0) {
      const msg: string = asString(body['msg']).length > 0 ? asString(body['msg']) : asString(body['errMsg']);
      return failResult(code, txErrorMessage(code, msg));
    }
  }
  const req: Record<string, Object> = requestBlockOf(body);
  if (Object.keys(req).length === 0) {
    return failResult(-1, 'QQ 音乐响应里没有业务块（req_0），无法确认是否写入成功');
  }
  const reqCode: Object | undefined = req['code'];
  if (reqCode !== undefined && reqCode !== null) {
    sawCode = true;
    const code: number = asNumber(reqCode, -1);
    if (code !== 0) {
      const msg: string = asString(req['msg']).length > 0 ? asString(req['msg']) : asString(req['errMsg']);
      return failResult(code, txErrorMessage(code, msg));
    }
  }
  const data: Record<string, Object> = asRecord(req['data']);
  const retCode: Object | undefined = data['retCode'];
  if (retCode !== undefined && retCode !== null) {
    sawCode = true;
    const code: number = asNumber(retCode, -1);
    if (code !== 0) {
      return failResult(code, txErrorMessage(code, asString(data['msg'])));
    }
  }
  if (!sawCode) {
    return failResult(-1, 'QQ 音乐响应里没有业务码，按失败处理（避免假成功）');
  }
  return null;
}

/**
 * 登录态是否具备写条件（uin + 音乐票据齐）
 *
 * 只做本地判断：不发起请求、不校验票据是否仍在有效期（有效期只有服务端知道）。
 */
export function txCanWrite(): boolean {
  const cookie: string = musicAccount().cookieOf('tx');
  if (cookie.length === 0) {
    return false;
  }
  return txUinOf(cookie).length > 0 && txMusicKeyOf(cookie).length > 0;
}

/**
 * 加 / 取消「我喜欢」（dirId = 201）
 *
 * @param songId   **数字歌曲 ID**（不是 songmid）；服务端 v_songInfo.songId 只认数字
 * @param songType 歌曲类型（v_songInfo.songType）。解析不出时调用方应**跳过**而不是传 0，
 *                 所以这里对非法值直接失败，不替调用方猜
 * @param add      true = AddSonglist，false = DelSonglist
 *
 * 通道：POST u6.y.qq.com/cgi-bin/musics.fcg?sign=<zzcSign>&encoding=ag-1，
 * 请求体 = AES-128-GCM 加密后的原始字节（见 encodeAg1Request）。
 * 响应再按协议 XOR 解码后逐层校验业务码；只有全部 0 才返回 ok。
 */
/**
 * 加 / 取消「我喜欢」（dirId = 201）
 *
 * ## 通道（2026-11-27 在 PC 上实测）
 * 走**明文** `u.y.qq.com/cgi-bin/musicu.fcg`，请求体以「module 名」为键：
 * ```json
 * { "comm": {...}, "music.musicasset.PlaylistDetailWrite": { "method": "AddSonglist", "module": "...", "param": {...} } }
 * ```
 * comm 里必须带 `tmeAppID / tmeLoginType / uid / qq / authst / loginUin`，Cookie 里要带
 * `tmeLoginType`。实测：这套信封读接口直接 code=0；写接口在登录有效时可用，
 * 登录过期时返回 **1000**（而不是 2001/500003 那种通道错误）。
 *
 * 早期实现用 `musics.fcg?sign=zzcSign&encoding=ag-1` + AES-GCM 加密体，那条路在真机上
 * 一律回 2001（服务端解不开），已弃用。
 *
 * ## 错误码
 * - 1000 / 104400 / 104401 = **登录已失效**（读接口不校验登录态，所以会出现「能读不能写」）
 * - 其它 code 交给 txCodeMessage 做中文映射
 *
 * 只读不写的前提：本函数只做「加/删我喜欢」这一件事。
 */
export async function txFavorite(songId: string, songType: number, add: boolean): Promise<TxWriteResult> {
  const cookie: string = musicAccount().cookieOf('tx');
  if (cookie.length === 0) {
    return failResult(301, '需要登录 QQ 音乐账号');
  }
  const uin: string = txUinOf(cookie);
  const authst: string = txMusicKeyOf(cookie);
  if (uin.length === 0 || authst.length === 0) {
    return failResult(301, 'QQ 音乐登录凭证缺少 uin 或音乐票据（qm_keyst），请重新登录');
  }
  const idText: string = typeof songId === 'string' ? songId.trim() : '';
  if (!/^\d+$/.test(idText)) {
    return failResult(-1, 'QQ 音乐红心写入需要数字歌曲 ID（不是 songmid）');
  }
  if (!Number.isFinite(songType) || songType < 0) {
    return failResult(-1, '歌曲类型未解析出来，已跳过（避免按错误的 songType 写入）');
  }
  const type: number = Math.floor(songType);
  // 1 = 微信登录（musickey 以 W_X 开头），2 = QQ 登录
  const loginType: string = authst.startsWith('W_X') ? '1' : '2';
  const comm: Record<string, Object> = {
    'cv': WRITE_VERSION,
    'v': WRITE_VERSION,
    'ct': '11',
    'tmeAppID': 'qqmusic',
    'format': 'json',
    'inCharset': 'utf-8',
    'outCharset': 'utf-8',
    'uid': uin,
    'qq': uin,
    'uin': uin,
    'authst': authst,
    'tmeLoginType': loginType,
    'loginUin': uin,
  };
  const songInfo: Record<string, Object> = {
    'songType': type,
    'songId': Number(idText),
  };
  const param: Record<string, Object> = {
    'dirId': DIR_LIKE,
    'v_songInfo': [songInfo],
  };
  const block: Record<string, Object> = {
    'method': add ? 'AddSonglist' : 'DelSonglist',
    'module': 'music.musicasset.PlaylistDetailWrite',
    'param': param,
  };
  const payload: Record<string, Object> = { 'comm': comm };
  payload['music.musicasset.PlaylistDetailWrite'] = block;
  const cookieWithType: string = cookie.indexOf('tmeLoginType=') >= 0
    ? cookie : `${cookie}; tmeLoginType=${loginType};`;
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'User-Agent': TX_WRITE_UA,
    'Referer': 'https://y.qq.com/',
    'Origin': 'https://y.qq.com',
    'Cookie': cookieWithType,
  };
  let response: http.HttpResponse;
  try {
    response = await postJsonText(WRITE_ENDPOINT, JSON.stringify(payload), headers);
  } catch (e) {
    const detail: string = (e as Error).message !== undefined ? (e as Error).message : '网络异常';
    hilog.warn(DOMAIN, TAG, 'tx favorite request failed: %{public}s', detail);
    return failResult(-1, `QQ 音乐红心请求失败：${detail}`);
  }
  if (response.responseCode !== 200) {
    return failResult(response.responseCode, `QQ 音乐红心请求失败（HTTP ${response.responseCode}）`);
  }
  const raw: Object = response.result as Object;
  const text: string = typeof raw === 'string' ? raw : JSON.stringify(raw);
  let body: Record<string, Object>;
  try {
    body = JSON.parse(text) as Record<string, Object>;
  } catch (e) {
    return failResult(-1, 'QQ 音乐红心响应不是合法 JSON（可能被风控拦截）');
  }
  const inner: Record<string, Object> = asRecord(body['music.musicasset.PlaylistDetailWrite']);
  if (Object.keys(inner).length === 0) {
    return failResult(-1, 'QQ 音乐红心响应里没有业务块（接口形状可能已变）');
  }
  const code: number = asNumber(inner['code'], -1);
  if (code === 0) {
    hilog.info(DOMAIN, TAG, 'tx favorite ok, add=%{public}d, songId=%{public}s', add ? 1 : 0, idText);
    return okResult(add ? '已加入「我喜欢」' : '已取消「我喜欢」');
  }
  if (code === 1000 || code === 104400 || code === 104401) {
    hilog.warn(DOMAIN, TAG, 'tx favorite: login expired (code=%{public}d)', code);
    return failResult(code, 'QQ 音乐登录已失效，请到「设置 - 登录音乐」重新登录 QQ 音乐');
  }
  const serverMessage: string = asString(inner['message']).length > 0
    ? asString(inner['message']) : asString(inner['msg']);
  hilog.warn(DOMAIN, TAG, 'tx favorite rejected, code=%{public}d', code);
  return failResult(code, txErrorMessage(code, serverMessage));
}
/**
 * 尽力解析一首歌的 songType（按 songmid 查详情）
 *
 * QQ 音乐在「写我喜欢」的 v_songInfo.songType 里要的类型值来自歌曲详情的 `type` 字段。
 * 这里走只读 musicu.fcg（匿名即可，不碰账号数据），模块
 * `music.pf_song_detail_svr / get_song_detail_yqq`（项目外第三方实现已在用）。
 * 解析不出（网络失败 / 字段缺失 / 非数字）一律返回 0，**调用方据此跳过**而不是按 0 写入。
 *
 * 需真机实测：详情响应里的类型字段名（按 `type` → `songtype` → `songType` 依次兜底）。
 */
export async function txResolveSongType(songMid: string): Promise<number> {
  const mid: string = typeof songMid === 'string' ? songMid.trim() : '';
  if (mid.length === 0) {
    return -1;
  }
  const detailParam: Record<string, Object> = {
    'song_type': 0,
    'song_mid': mid,
  };
  const req0: Record<string, Object> = {
    'module': 'music.pf_song_detail_svr',
    'method': 'get_song_detail_yqq',
    'param': detailParam,
  };
  const comm: Record<string, Object> = {
    'ct': '19',
    'cv': '1859',
    'uin': '0',
  };
  const payload: Record<string, Object> = {
    'comm': comm,
    'req': req0,
  };
  const headers: Record<string, string> = {
    'User-Agent': TX_UA,
    'Referer': 'https://y.qq.com/',
  };
  try {
    const response: http.HttpResponse = await postJsonText(READ_ENDPOINT, JSON.stringify(payload), headers);
    if (response.responseCode !== 200) {
      hilog.warn(DOMAIN, TAG, 'tx resolve song type http %{public}d', response.responseCode);
      return -1;
    }
    const raw: Object = response.result as Object;
    const text: string = typeof raw === 'string' ? raw : JSON.stringify(raw);
    const body: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    if (asNumber(body['code'], -1) !== 0) {
      hilog.warn(DOMAIN, TAG, 'tx resolve song type: outer code=%{public}d', asNumber(body['code'], -1));
      return -1;
    }
    const req: Record<string, Object> = asRecord(body['req']);
    if (asNumber(req['code'], -1) !== 0) {
      hilog.warn(DOMAIN, TAG, 'tx resolve song type: inner code=%{public}d', asNumber(req['code'], -1));
      return -1;
    }
    const track: Record<string, Object> = asRecord(asRecord(req['data'])['track_info']);
    let rawType: Object | undefined = track['type'];
    if (rawType === undefined || rawType === null) {
      rawType = track['songtype'];
    }
    if (rawType === undefined || rawType === null) {
      rawType = track['songType'];
    }
    const type: number = asNumber(rawType, -1);
    if (type < 0 || !Number.isFinite(type)) {
      return -1;
    }
    // 注意：0 是**合法值**（普通歌曲）。之前把 0 当「没解析出来」，导致普通歌永远推不进去。
    return Math.floor(type);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'tx resolve song type failed');
    return -1;
  }
}
