import {
  aes128CbcPkcs7EncryptBytes,
  rsa1024NoPaddingEncryptHex,
  toBase64,
  utf8Bytes,
} from './PlatformCrypto';

/**
 * 网易 weapi 加密
 *
 * 为什么需要它：`/api/v1/discovery/recommend/resource`（私人推荐歌单）这类「账号接口」
 * 在真实客户端里都不是明文调的 —— 公认实现 NeteaseCloudMusicApi 的
 * `module/recommend_resource.js` 用的是 `createOption(query, 'weapi')`，其 `util/request.js`
 * 会把路径改写成 `/weapi/v1/discovery/recommend/resource`，并把参数做成
 * `params` + `encSecKey` 两个表单字段。我们之前拿明文空 form 去 POST，匿名能拿到
 * `code:301`，但登录后依然取不到，就是缺这层加密（顺带 `csrf_token` 也没带）。
 *
 * 算法（全网一致，非私有）：
 *   1. text = JSON.stringify(data)
 *   2. once = base64(AES-128-CBC(text,      key = '0CoJUm6Qyw8W8jud', iv = '0102030405060708'))
 *   3. params = base64(AES-128-CBC(once,    key = secret(16 位随机),   iv = '0102030405060708'))
 *   4. encSecKey = hex(RSA-1024-PKCS1(secret 反转后的 16 字节, 网易固定公钥))
 *   5. data 里必须带 `csrf_token`（取自 Cookie 的 `__csrf`，没有就空串）
 */

/** 网易固定 AES key（第一层）与 IV */
const WY_AES_KEY: string = '0CoJUm6Qyw8W8jud';
const WY_AES_IV: string = '0102030405060708';

/**
 * 网易固定 RSA-1024 公钥（X.509 SPKI DER 的 base64）
 *
 * 由模数 + 指数 65537 导出，全网公开常量。`convertKeySync` 收 DER，不收 PEM 文本。
 */
const WY_RSA_SPKI: string =
  'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6' +
    'sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz' +
    '+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB';

/** 随机密钥用的字符集（与各实现一致：字母 + 数字） */
const WY_SECRET_CHARS: string =
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

/** AES-128-CBC + PKCS7，返回 base64 文本（weapi 的两层都是这个） */
function aesBase64(text: string, key: string): string {
  const keyBytes: number[] = utf8Bytes(key);
  const ivBytes: number[] = utf8Bytes(WY_AES_IV);
  const plain: number[] = utf8Bytes(text);
  return toBase64(aes128CbcPkcs7EncryptBytes(keyBytes, ivBytes, plain));
}

/** 16 位随机密钥 */
function randomSecret(): string {
  let out: string = '';
  for (let i = 0; i < 16; i++) {
    const index: number = Math.floor(Math.random() * WY_SECRET_CHARS.length);
    out += WY_SECRET_CHARS.charAt(index);
  }
  return out;
}

/** 反转字符串（RSA 那一步要的是反转后的 secret） */
function reverseText(text: string): string {
  let out: string = '';
  for (let i = text.length - 1; i >= 0; i--) {
    out += text.charAt(i);
  }
  return out;
}

/**
 * 把业务参数加密成 weapi 的两个表单字段
 *
 * 返回的对象直接当 `form` 发出去（`params` / `encSecKey`）。
 * 每一步都包一层带步骤名的错误：真机上一旦失败，日志能直接指出是 AES 还是 RSA 出的问题
 * （曾经因为只有一句「取不到」，根本分不清是网络、登录态还是加密）。
 */
export function wyWeapiForm(data: Record<string, string>): Record<string, string> {
  const text: string = JSON.stringify(data);
  const secret: string = randomSecret();
  let once: string = '';
  let params: string = '';
  try {
    once = aesBase64(text, WY_AES_KEY);
    params = aesBase64(once, secret);
  } catch (e) {
    throw new Error(`weapi AES 加密失败：${errorText(e)}`);
  }
  let encSecKey: string = '';
  try {
    encSecKey = rsa1024NoPaddingEncryptHex(WY_RSA_SPKI, utf8Bytes(reverseText(secret)));
  } catch (e) {
    throw new Error(`weapi RSA 加密失败：${errorText(e)}`);
  }
  const form: Record<string, string> = {
    'params': params,
    'encSecKey': encSecKey,
  };
  return form;
}

/** 把 catch 到的异常变成可读文本（Error 直接 JSON.stringify 会得到 `{}`） */
function errorText(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  return JSON.stringify(e);
}

/** 从 Cookie 头里取 `__csrf`（weapi 的写/读接口都要求带上，没有就空串） */
export function wyCsrfFromCookie(cookieHeader: string): string {
  const match: RegExpMatchArray | null = cookieHeader.match(/(^|;\s*)__csrf=([^;]*)/);
  if (match === null || match.length < 3) {
    return '';
  }
  return match[2].trim();
}
