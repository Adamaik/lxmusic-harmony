/**
 * 纯 ArkTS 的摘要/对称加密实现。
 *
 * 沙箱里的 lx_utils.js 已经有一份（供源脚本的 lx.utils.crypto 使用），但那是在 WebView 里跑的；
 * 宿主侧内置搜索需要自己算（咪咕 md5 签名、QQ zzcSign 的 SHA-1、网易 eapi 的 AES-ECB），
 * 所以这里再实现一份，并由主机单元测试与 node:crypto 的已知向量对齐。
 */

// ------------------------------------------------------------------ 通用

function hex2(byte: number): string {
  const s: string = (byte & 0xFF).toString(16);
  return s.length === 1 ? `0${s}` : s;
}

function rotl(x: number, c: number): number {
  return ((x << c) | (x >>> (32 - c))) >>> 0;
}

/** 字符串 -> UTF-8 字节 */
export function utf8Bytes(str: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < str.length; i++) {
    let code: number = str.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
      const next: number = str.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        code = ((code - 0xD800) << 10) + (next - 0xDC00) + 0x10000;
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push((code >> 6) | 0xC0, (code & 0x3F) | 0x80);
    } else if (code < 0x10000) {
      out.push((code >> 12) | 0xE0, ((code >> 6) & 0x3F) | 0x80, (code & 0x3F) | 0x80);
    } else {
      out.push(
        (code >> 18) | 0xF0,
        ((code >> 12) & 0x3F) | 0x80,
        ((code >> 6) & 0x3F) | 0x80,
        (code & 0x3F) | 0x80,
      );
    }
  }
  return out;
}

/** 小写 hex -> 字节数组 */
export function hexToBytes(hex: string): number[] {
  const out: number[] = [];
  for (let i = 0; i + 1 < hex.length; i += 2) {
    out.push(Number.parseInt(hex.substring(i, i + 2), 16));
  }
  return out;
}

const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** base64 编码（纯 ArkTS 实现，不依赖系统 Base64Helper，便于主机单测） */
export function toBase64(bytes: number[]): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0: number = bytes[i] & 0xFF;
    const has1: boolean = i + 1 < bytes.length;
    const has2: boolean = i + 2 < bytes.length;
    const b1: number = has1 ? bytes[i + 1] & 0xFF : 0;
    const b2: number = has2 ? bytes[i + 2] & 0xFF : 0;
    out += B64_CHARS.charAt(b0 >> 2);
    out += B64_CHARS.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += has1 ? B64_CHARS.charAt(((b1 & 0x0F) << 2) | (b2 >> 6)) : '=';
    out += has2 ? B64_CHARS.charAt(b2 & 0x3F) : '=';
  }
  return out;
}

/** 字节数组 -> 字符串（UTF-8 解码，非法序列用 U+FFFD 兜底） */
export function bytesToUtf8(bytes: number[]): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0: number = bytes[i] & 0xFF;
    let code: number = 0;
    let extra: number = 0;
    if (b0 < 0x80) {
      code = b0;
      extra = 0;
    } else if ((b0 & 0xE0) === 0xC0) {
      code = b0 & 0x1F;
      extra = 1;
    } else if ((b0 & 0xF0) === 0xE0) {
      code = b0 & 0x0F;
      extra = 2;
    } else if ((b0 & 0xF8) === 0xF0) {
      code = b0 & 0x07;
      extra = 3;
    } else {
      out += '\uFFFD';
      i++;
      continue;
    }
    if (i + extra >= bytes.length) {
      out += '\uFFFD';
      break;
    }
    let ok: boolean = true;
    for (let j = 1; j <= extra; j++) {
      const b: number = bytes[i + j] & 0xFF;
      if ((b & 0xC0) !== 0x80) {
        ok = false;
        break;
      }
      code = (code << 6) | (b & 0x3F);
    }
    if (!ok) {
      out += '\uFFFD';
      i++;
      continue;
    }
    i += extra + 1;
    if (code > 0xFFFF) {
      const v: number = code - 0x10000;
      out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

let B64_LOOKUP: number[] = buildB64Lookup();

function buildB64Lookup(): number[] {
  const table: number[] = [];
  for (let i = 0; i < 128; i++) {
    table.push(-1);
  }
  for (let i = 0; i < B64_CHARS.length; i++) {
    table[B64_CHARS.charCodeAt(i)] = i;
  }
  return table;
}

/** base64 解码（纯 ArkTS 实现；忽略换行等非字母表字符） */
export function fromBase64(text: string): number[] {
  const out: number[] = [];
  let buffer: number = 0;
  let bits: number = 0;
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code >= 128) {
      continue;
    }
    const value: number = B64_LOOKUP[code];
    if (value < 0) {
      continue;
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xFF);
    }
  }
  return out;
}

// ------------------------------------------------------------------ MD5

const MD5_S: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

function buildMd5K(): number[] {
  const k: number[] = [];
  for (let i = 0; i < 64; i++) {
    k.push(Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296));
  }
  return k;
}

const MD5_K: number[] = buildMd5K();

function readLE32(buf: Uint8Array, pos: number): number {
  return (buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16) | (buf[pos + 3] << 24)) >>> 0;
}

function writeLE32(buf: Uint8Array, pos: number, value: number): void {
  buf[pos] = value & 0xFF;
  buf[pos + 1] = (value >>> 8) & 0xFF;
  buf[pos + 2] = (value >>> 16) & 0xFF;
  buf[pos + 3] = (value >>> 24) & 0xFF;
}

/** MD5(UTF-8) -> 小写 hex */
export function md5Hex(input: string): string {
  const bytes: number[] = utf8Bytes(input);
  const len: number = bytes.length;
  const bitLenLo: number = (len * 8) >>> 0;
  const bitLenHi: number = Math.floor(len / 536870912);
  let total: number = len + 1 + 8;
  if (total % 64 !== 0) {
    total += 64 - (total % 64);
  }
  const buf = new Uint8Array(total);
  for (let i = 0; i < len; i++) {
    buf[i] = bytes[i];
  }
  buf[len] = 0x80;
  writeLE32(buf, total - 8, bitLenLo);
  writeLE32(buf, total - 4, bitLenHi);

  let a0: number = 0x67452301;
  let b0: number = 0xEFCDAB89;
  let c0: number = 0x98BADCFE;
  let d0: number = 0x10325476;

  for (let off = 0; off < total; off += 64) {
    let a: number = a0;
    let b: number = b0;
    let c: number = c0;
    let d: number = d0;
    for (let i = 0; i < 64; i++) {
      let f: number;
      let g: number;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      const sum: number = (f + a + MD5_K[i] + readLE32(buf, off + g * 4)) >>> 0;
      const nextB: number = (b + rotl(sum, MD5_S[i])) >>> 0;
      a = d;
      d = c;
      c = b;
      b = nextB;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  let out: string = '';
  const words: number[] = [a0, b0, c0, d0];
  for (const word of words) {
    for (let i = 0; i < 4; i++) {
      out += hex2((word >>> (i * 8)) & 0xFF);
    }
  }
  return out;
}

// ------------------------------------------------------------------ SHA-1

function readBE32(buf: Uint8Array, pos: number): number {
  return ((buf[pos] << 24) | (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3]) >>> 0;
}

function writeBE32(buf: Uint8Array, pos: number, value: number): void {
  buf[pos] = (value >>> 24) & 0xFF;
  buf[pos + 1] = (value >>> 16) & 0xFF;
  buf[pos + 2] = (value >>> 8) & 0xFF;
  buf[pos + 3] = value & 0xFF;
}

function hex8(value: number): string {
  let out: string = '';
  for (let shift = 28; shift >= 0; shift -= 4) {
    out += ((value >>> shift) & 0x0F).toString(16);
  }
  return out;
}

/** SHA-1(UTF-8) -> 小写 hex（与洛雪原生 CryptoModule.sha1 一致） */
export function sha1Hex(input: string): string {
  const bytes: number[] = utf8Bytes(input);
  const msgLen: number = bytes.length;
  const bitLenHi: number = Math.floor(msgLen / 536870912);
  const bitLenLo: number = (msgLen * 8) >>> 0;
  let total: number = msgLen + 1 + 8;
  if (total % 64 !== 0) {
    total += 64 - (total % 64);
  }
  const buf = new Uint8Array(total);
  for (let i = 0; i < msgLen; i++) {
    buf[i] = bytes[i];
  }
  buf[msgLen] = 0x80;
  writeBE32(buf, total - 8, bitLenHi);
  writeBE32(buf, total - 4, bitLenLo);

  let h0: number = 0x67452301;
  let h1: number = 0xEFCDAB89;
  let h2: number = 0x98BADCFE;
  let h3: number = 0x10325476;
  let h4: number = 0xC3D2E1F0;
  const w: number[] = new Array<number>(80);

  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = readBE32(buf, off + i * 4);
    }
    for (let i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    let a: number = h0;
    let b: number = h1;
    let c: number = h2;
    let d: number = h3;
    let e: number = h4;
    for (let i = 0; i < 80; i++) {
      let f: number;
      let k: number;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      const temp: number = (rotl(a, 5) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }
  return hex8(h0) + hex8(h1) + hex8(h2) + hex8(h3) + hex8(h4);
}

// ------------------------------------------------------------------ AES-128-ECB

const AES_SBOX: number[] = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

const AES_RCON: number[] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36];

function aesGmul(a: number, b: number): number {
  let p: number = 0;
  let x: number = a;
  let y: number = b;
  for (let i = 0; i < 8; i++) {
    if (y & 1) {
      p ^= x;
    }
    const hi: number = x & 0x80;
    x = (x << 1) & 0xFF;
    if (hi) {
      x ^= 0x1B;
    }
    y >>= 1;
  }
  return p;
}

function aesExpandKey(key: number[]): number[] {
  const w: number[] = new Array<number>(176);
  for (let i = 0; i < 16; i++) {
    w[i] = key[i];
  }
  let generated: number = 16;
  let rconIndex: number = 0;
  const temp: number[] = [0, 0, 0, 0];
  while (generated < 176) {
    for (let i = 0; i < 4; i++) {
      temp[i] = w[generated - 4 + i];
    }
    if (generated % 16 === 0) {
      const t0: number = temp[0];
      temp[0] = AES_SBOX[temp[1]] ^ AES_RCON[rconIndex++];
      temp[1] = AES_SBOX[temp[2]];
      temp[2] = AES_SBOX[temp[3]];
      temp[3] = AES_SBOX[t0];
    }
    for (let i = 0; i < 4; i++) {
      w[generated] = w[generated - 16] ^ temp[i];
      generated++;
    }
  }
  return w;
}

function aesEncryptBlock(block: number[], w: number[]): void {
  for (let i = 0; i < 16; i++) {
    block[i] ^= w[i];
  }
  for (let round = 1; round <= 10; round++) {
    for (let i = 0; i < 16; i++) {
      block[i] = AES_SBOX[block[i]];
    }
    let t: number = block[1];
    block[1] = block[5];
    block[5] = block[9];
    block[9] = block[13];
    block[13] = t;
    t = block[2];
    block[2] = block[10];
    block[10] = t;
    t = block[6];
    block[6] = block[14];
    block[14] = t;
    t = block[3];
    block[3] = block[15];
    block[15] = block[11];
    block[11] = block[7];
    block[7] = t;
    if (round !== 10) {
      for (let c = 0; c < 4; c++) {
        const o: number = c * 4;
        const a0: number = block[o];
        const a1: number = block[o + 1];
        const a2: number = block[o + 2];
        const a3: number = block[o + 3];
        block[o] = aesGmul(a0, 2) ^ aesGmul(a1, 3) ^ a2 ^ a3;
        block[o + 1] = a0 ^ aesGmul(a1, 2) ^ aesGmul(a2, 3) ^ a3;
        block[o + 2] = a0 ^ a1 ^ aesGmul(a2, 2) ^ aesGmul(a3, 3);
        block[o + 3] = aesGmul(a0, 3) ^ a1 ^ a2 ^ aesGmul(a3, 2);
      }
    }
    const base: number = round * 16;
    for (let i = 0; i < 16; i++) {
      block[i] ^= w[base + i];
    }
  }
}

/**
 * AES-128-ECB + PKCS7 填充，输出大写 hex。
 *
 * 注意：洛雪的 AES_MODE.ECB_128_NoPadding 实际取值是 Java 的 "AES"，
 * 即 Cipher.getInstance("AES") = AES/ECB/PKCS5Padding —— 所以这里是 PKCS7 而不是 NoPadding。
 */
export function aes128EcbPkcs7HexUpper(keyBytes: number[], dataBytes: number[]): string {
  const bytes: number[] = aes128EcbPkcs7EncryptBytes(keyBytes, dataBytes);
  let hex: string = '';
  for (const byte of bytes) {
    hex += hex2(byte);
  }
  return hex.toUpperCase();
}

/** AES-128-ECB + PKCS7 加密，密文按字节返回 */
export function aes128EcbPkcs7EncryptBytes(keyBytes: number[], dataBytes: number[]): number[] {
  if (keyBytes.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  const w: number[] = aesExpandKey(keyBytes);
  const padLen: number = 16 - (dataBytes.length % 16);
  const data: number[] = dataBytes.slice();
  for (let i = 0; i < padLen; i++) {
    data.push(padLen);
  }
  const out: number[] = [];
  for (let off = 0; off < data.length; off += 16) {
    const block: number[] = new Array<number>(16);
    for (let i = 0; i < 16; i++) {
      block[i] = data[off + i];
    }
    aesEncryptBlock(block, w);
    for (let i = 0; i < 16; i++) {
      out.push(block[i]);
    }
  }
  return out;
}

/** AES-128-ECB + PKCS7 解密，返回去掉填充后的字节 */
export function aes128EcbPkcs7DecryptBytes(keyBytes: number[], dataBytes: number[]): number[] {
  if (keyBytes.length !== 16) {
    throw new Error('AES-128 key must be 16 bytes');
  }
  if (dataBytes.length === 0 || dataBytes.length % 16 !== 0) {
    throw new Error('AES-ECB ciphertext must be a non-empty multiple of 16 bytes');
  }
  const w: number[] = aesExpandKey(keyBytes);
  const out: number[] = [];
  for (let off = 0; off < dataBytes.length; off += 16) {
    const block: number[] = new Array<number>(16);
    for (let i = 0; i < 16; i++) {
      block[i] = dataBytes[off + i];
    }
    aesDecryptBlock(block, w);
    for (let i = 0; i < 16; i++) {
      out.push(block[i]);
    }
  }
  const padLen: number = out[out.length - 1];
  if (padLen < 1 || padLen > 16 || padLen > out.length) {
    throw new Error('invalid PKCS7 padding');
  }
  for (let i = out.length - padLen; i < out.length; i++) {
    if (out[i] !== padLen) {
      throw new Error('invalid PKCS7 padding');
    }
  }
  return out.slice(0, out.length - padLen);
}

/** AES-128 逆 S 盒，解密用 */
const AES_INV_SBOX: number[] = buildInvSbox();

function buildInvSbox(): number[] {
  const table: number[] = new Array<number>(256);
  for (let i = 0; i < 256; i++) {
    table[AES_SBOX[i]] = i;
  }
  return table;
}

/**
 * 单块 AES 解密：逆 ShiftRows -> 逆 SubBytes -> AddRoundKey -> 逆 MixColumns。
 * block 的下标按 row + 4 * col 摆放，与 aesEncryptBlock 保持一致。
 */
function aesDecryptBlock(block: number[], w: number[]): void {
  for (let i = 0; i < 16; i++) {
    block[i] ^= w[160 + i];
  }
  for (let round = 9; round >= 0; round--) {
    let t: number = block[13];
    block[13] = block[9];
    block[9] = block[5];
    block[5] = block[1];
    block[1] = t;
    t = block[2];
    block[2] = block[10];
    block[10] = t;
    t = block[6];
    block[6] = block[14];
    block[14] = t;
    t = block[3];
    block[3] = block[7];
    block[7] = block[11];
    block[11] = block[15];
    block[15] = t;
    for (let i = 0; i < 16; i++) {
      block[i] = AES_INV_SBOX[block[i]];
    }
    const base: number = round * 16;
    for (let i = 0; i < 16; i++) {
      block[i] ^= w[base + i];
    }
    if (round !== 0) {
      for (let c = 0; c < 4; c++) {
        const o: number = c * 4;
        const a0: number = block[o];
        const a1: number = block[o + 1];
        const a2: number = block[o + 2];
        const a3: number = block[o + 3];
        block[o] = aesGmul(a0, 14) ^ aesGmul(a1, 11) ^ aesGmul(a2, 13) ^ aesGmul(a3, 9);
        block[o + 1] = aesGmul(a0, 9) ^ aesGmul(a1, 14) ^ aesGmul(a2, 11) ^ aesGmul(a3, 13);
        block[o + 2] = aesGmul(a0, 13) ^ aesGmul(a1, 9) ^ aesGmul(a2, 14) ^ aesGmul(a3, 11);
        block[o + 3] = aesGmul(a0, 11) ^ aesGmul(a1, 13) ^ aesGmul(a2, 9) ^ aesGmul(a3, 14);
      }
    }
  }
}
