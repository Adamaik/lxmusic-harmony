import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { aes128EcbPkcs7EncryptBytes, aes128EcbPkcs7DecryptBytes, bytesToUtf8, fromBase64,
  md5Hex, toBase64, utf8Bytes } from '../music/LxCrypto';
import { RsaKeyPairB64 } from './SyncTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SyncCrypto';

/**
 * 洛雪同步用到的加解密
 *
 * 与官方实现对位关系：
 *   - 对称：AES-128-ECB / PKCS7（洛雪 AES_MODE.ECB_128_NoPadding 的真实取值是 Java 的 "AES"，
 *     即 AES/ECB/PKCS5Padding），密文以 base64 传输；
 *   - 非对称：RSA-2048 + OAEP(SHA-1, MGF1-SHA1)，与服务端 Node 的
 *     RSA_PKCS1_OAEP_PADDING 默认参数、移动端 OAEPWithSHA1AndMGF1Padding 一致；
 *   - 摘要：MD5 小写 hex（洛雪 toMD5 就是 crypto.createHash('md5').digest('hex')）。
 *
 * AES/MD5/Base64 复用 core/music/LxCrypto.ets（纯 ArkTS，已与 node:crypto 的向量对齐），
 * 这里只补 RSA —— 它必须走系统 CryptoArchitectureKit：密钥生成与 OAEP 解密都不是
 * 纯 ArkTS 能可靠实现的。
 */

// ------------------------------------------------------------------ 工具

function numbersToU8(bytes: number[]): Uint8Array {
  const out = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] & 0xFF;
  }
  return out;
}

function u8ToNumbers(data: Uint8Array): number[] {
  const out: number[] = [];
  for (let i = 0; i < data.length; i++) {
    out.push(data[i]);
  }
  return out;
}

// ------------------------------------------------------------------ 对称

/** 由认证码/密码派生 AES 密钥：md5(code) 的前 16 个字符，再 base64（洛雪的做法） */
export function deriveKeyB64(authCode: string): string {
  const key: string = md5Hex(authCode).substring(0, 16);
  return toBase64(utf8Bytes(key));
}

/** AES-128-ECB/PKCS7 加密，明文按 UTF-8，输出 base64 */
export function aesEncryptBase64(text: string, b64Key: string): string {
  const keyBytes: number[] = fromBase64(b64Key);
  return toBase64(aes128EcbPkcs7EncryptBytes(keyBytes, utf8Bytes(text)));
}

/** AES-128-ECB/PKCS7 解密，输入 base64 密文，输出 UTF-8 文本 */
export function aesDecryptBase64(cipherB64: string, b64Key: string): string {
  const keyBytes: number[] = fromBase64(b64Key);
  return bytesToUtf8(aes128EcbPkcs7DecryptBytes(keyBytes, fromBase64(cipherB64)));
}

// ------------------------------------------------------------------ 非对称

/**
 * 生成 RSA-2048 密钥对，导出格式与洛雪移动端原生模块一致：
 *   - 公钥：X.509(SPKI) DER 的 base64（认证时发给服务端，不带 PEM 头尾与换行）
 *   - 私钥：PKCS#8 DER 的 base64（用于解开服务端用公钥加密的身份信息）
 */
export async function generateRsaKey(): Promise<RsaKeyPairB64> {
  const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
  const pair = await generator.generateKeyPair();
  const pubDer: cryptoFramework.DataBlob = pair.pubKey.getEncoded();
  const priDer: cryptoFramework.DataBlob = pair.priKey.getEncoded();
  return {
    publicKey: toBase64(u8ToNumbers(pubDer.data)),
    privateKey: toBase64(u8ToNumbers(priDer.data)),
  };
}

/** RSA-OAEP(SHA-1) 解密：输入 base64 密文与 PKCS#8 私钥 base64，输出 UTF-8 文本 */
export async function rsaDecryptBase64(cipherB64: string, privateKeyB64: string): Promise<string> {
  const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
  const priBlob: cryptoFramework.DataBlob = { data: numbersToU8(fromBase64(privateKeyB64)) };
  const pair = await generator.convertKey(null, priBlob);
  const cipher = cryptoFramework.createCipher('RSA2048|PKCS1_OAEP|SHA1|MGF1_SHA1');
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, pair.priKey, null);
  const input: cryptoFramework.DataBlob = { data: numbersToU8(fromBase64(cipherB64)) };
  const output: cryptoFramework.DataBlob = await cipher.doFinal(input);
  return bytesToUtf8(u8ToNumbers(output.data));
}

/** 摘要：MD5 小写 hex（与洛雪 toMD5 一致） */
export function toMD5(text: string): string {
  return md5Hex(text);
}

export function logCryptoError(where: string, err: Object): void {
  hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', where, JSON.stringify(err));
}
