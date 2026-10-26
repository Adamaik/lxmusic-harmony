import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/**
 * 平台原生加解密 / 编解码（cryptoFramework + util）
 *
 * **为什么单开一个文件、而不是改 `LxCrypto`**：`LxCrypto` 是**纯 ArkTS、不引任何 kit** 的
 * 那一份 —— `entry/src/test/` 的主机单测（hypium 在 PC 上跑）要 import 它跟 node:crypto 的
 * 已知向量比对，而本地环境没有 `@kit.CryptoArchitectureKit` / `@kit.ArkTS`。所以：
 *   - `LxCrypto`：纯实现，**当单测的参照**，外加那些输入很小、不值得跨模块的调用；
 *   - 这个文件：**应用里真跑的大块数据**（酷我榜单响应一次 25 万字节、云同步载荷几十万字节）
 *     走原生实现 —— 同一套算法（AES-128-ECB/PKCS7）、同一批已知向量，但不占主线程去跑
 *     一万多个块的 S 盒循环。
 *
 * 同步接口（`convertKeySync` / `initSync` / `doFinalSync`）从 API 12 起有，本工程下限定在
 * 6.1.0(23)，用得起。
 */

function toU8(bytes: number[]): Uint8Array {
  const u8: Uint8Array = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    u8[i] = bytes[i] & 0xFF;
  }
  return u8;
}

function toNumbers(u8: Uint8Array): number[] {
  const out: number[] = new Array<number>(u8.length);
  for (let i = 0; i < u8.length; i++) {
    out[i] = u8[i];
  }
  return out;
}

/** UTF-8 文本 -> 字节（原生 TextEncoder） */
export function utf8Bytes(str: string): number[] {
  return toNumbers(new util.TextEncoder().encodeInto(str));
}

/** 字节 -> UTF-8 文本（原生 TextDecoder；非法序列按 U+FFFD 处理） */
export function bytesToUtf8(bytes: number[]): string {
  if (bytes.length === 0) {
    return '';
  }
  return util.TextDecoder.create('utf-8').decodeToString(toU8(bytes));
}

/** base64 编码（原生 Base64Helper） */
export function toBase64(bytes: number[]): string {
  return new util.Base64Helper().encodeToStringSync(toU8(bytes));
}

/**
 * base64 解码（原生 Base64Helper）
 *
 * 先洗掉字母表以外的字符：原生解码器遇到换行 / 杂字符会**抛错**，而服务端回来的
 * base64 文本偶尔带换行（纯实现那份是「忽略非法字符、能解就解」，口径更宽）。
 */
export function fromBase64(text: string): number[] {
  const clean: string = text.replace(/[^A-Za-z0-9+/=]/g, '');
  if (clean.length === 0) {
    return [];
  }
  return toNumbers(new util.Base64Helper().decodeSync(clean));
}

/** AES-128-ECB + PKCS7 加密（原生；key 必须是 16 字节） */
export function aes128EcbPkcs7EncryptBytes(keyBytes: number[], dataBytes: number[]): number[] {
  if (keyBytes.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  const keyBlob: cryptoFramework.DataBlob = { data: toU8(keyBytes) };
  const key: cryptoFramework.SymKey =
    cryptoFramework.createSymKeyGenerator('AES128').convertKeySync(keyBlob);
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|ECB|PKCS7');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, null);
  const input: cryptoFramework.DataBlob = { data: toU8(dataBytes) };
  return toNumbers(cipher.doFinalSync(input).data);
}

/** AES-128-ECB + PKCS7 解密（原生，返回去掉填充后的字节） */
export function aes128EcbPkcs7DecryptBytes(keyBytes: number[], dataBytes: number[]): number[] {
  if (keyBytes.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  if (dataBytes.length === 0 || dataBytes.length % 16 !== 0) {
    throw new Error('AES-ECB ciphertext must be a non-empty multiple of 16 bytes');
  }
  const keyBlob: cryptoFramework.DataBlob = { data: toU8(keyBytes) };
  const key: cryptoFramework.SymKey =
    cryptoFramework.createSymKeyGenerator('AES128').convertKeySync(keyBlob);
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|ECB|PKCS7');
  cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, null);
  const input: cryptoFramework.DataBlob = { data: toU8(dataBytes) };
  return toNumbers(cipher.doFinalSync(input).data);
}

/**
 * base64 密文 -> 明文文本（全程原生：base64 解码 + AES 解密 + UTF-8 解码）
 *
 * 酷我榜单接口那一条就靠它：响应是 35 万字符的加密 base64，解出来 25 万字节 JSON ——
 * 以前这三步都是纯 ArkTS 手写循环，主线程要卡好几秒。
 */
export function decodeAes128EcbPkcs7Text(keyBytes: number[], cipherText: string): string {
  const cipherBytes: number[] = fromBase64(cipherText);
  const plainBytes: number[] = aes128EcbPkcs7DecryptBytes(keyBytes, cipherBytes);
  return bytesToUtf8(plainBytes);
}

/** AES-128-CBC + PKCS7 加密（网易 weapi 用：固定 key + IV 都是 16 字节） */
export function aes128CbcPkcs7EncryptBytes(keyBytes: number[], ivBytes: number[],
  dataBytes: number[]): number[] {
  if (keyBytes.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  if (ivBytes.length !== 16) {
    throw new Error('AES CBC iv must be 16 bytes');
  }
  const keyBlob: cryptoFramework.DataBlob = { data: toU8(keyBytes) };
  const key: cryptoFramework.SymKey =
    cryptoFramework.createSymKeyGenerator('AES128').convertKeySync(keyBlob);
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  const spec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: toU8(ivBytes) },
  };
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, spec);
  const input: cryptoFramework.DataBlob = { data: toU8(dataBytes) };
  return toNumbers(cipher.doFinalSync(input).data);
}

/**
 * RSA 公钥**裸加密**（NoPadding）+ 十六进制输出
 *
 * 网易 weapi 的 `encSecKey` 是把 16 字节随机串用网易那把固定 RSA-1024 公钥做**无填充**
 * 模幂后的十六进制串（公认实现里是 `forgePublicKey.encrypt(str, 'NONE')`／手写 modPow）。
 * 这里必须用 NoPadding 而不是 PKCS1：服务端按裸 RSA 解，带填充会解出垃圾，
 * 表现为「HTTP 200 但返回 HTML 错误页」。
 *
 * 裸 RSA 要求输入正好等于密钥长度（1024 位 = 128 字节），明文右对齐、左侧补 0。
 */
export function rsa1024NoPaddingEncryptHex(spkiDerBase64: string, dataBytes: number[]): string {
  const generator: cryptoFramework.AsyKeyGenerator =
    cryptoFramework.createAsyKeyGenerator('RSA1024');
  const pubDerBlob: cryptoFramework.DataBlob = { data: toU8(fromBase64(spkiDerBase64)) };
  const pair: cryptoFramework.KeyPair = generator.convertKeySync(pubDerBlob, null);
  const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher('RSA1024|NoPadding');
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, pair.pubKey, null);
  const blockSize: number = 128;
  if (dataBytes.length > blockSize) {
    throw new Error(`RSA-1024 明文超过 ${blockSize} 字节`);
  }
  const block: number[] = new Array<number>(blockSize);
  for (let i = 0; i < blockSize; i++) {
    block[i] = 0;
  }
  const offset: number = blockSize - dataBytes.length;
  for (let i = 0; i < dataBytes.length; i++) {
    block[offset + i] = dataBytes[i] & 0xFF;
  }
  const input: cryptoFramework.DataBlob = { data: toU8(block) };
  return toHex(toNumbers(cipher.doFinalSync(input).data));
}

/** 字节 -> 小写十六进制串 */
export function toHex(bytes: number[]): string {
  const parts: string[] = new Array<string>(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    const h: string = (bytes[i] & 0xFF).toString(16);
    parts[i] = h.length === 1 ? `0${h}` : h;
  }
  return parts.join('');
}
