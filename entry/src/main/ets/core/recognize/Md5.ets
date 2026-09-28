/**
 * 纯 ArkTS 实现的 MD5（RFC 1321）
 *
 * 只服务酷狗识曲那条链路：它的 Android 签名是
 * `MD5(key + 排序后的 name=value + 原始二进制 body + key)`，而系统 cryptoFramework
 * 的摘要接口只吃 DataBlob、拼不出「字符串 + 二进制 + 字符串」这种混合体，
 * 所以这里自带一份能把任意字节算成十六进制的实现。
 *
 * 注意：这是**协议兼容**用的哈希，不是安全用途（别拿它存口令）。
 */
export class Md5 {
  /** 每轮的左移位数（RFC 1321 规定的常量表） */
  private static readonly S: Array<number> = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];

  /** 每轮的加法常量 K[i] = floor(2^32 * abs(sin(i + 1))) */
  private static readonly K: Array<number> = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  /** 算出一段字节的 MD5，返回 32 位小写十六进制 */
  static hex(bytes: Uint8Array): string {
    const length: number = bytes.length;
    // 填充到 64 的整数倍，并留出最后 8 字节放原始 bit 长度
    const paddedLength: number = (Math.floor((length + 8) / 64) + 1) * 64;
    const msg = new Uint8Array(paddedLength);
    msg.set(bytes);
    msg[length] = 0x80;
    const bitLenLow: number = (length * 8) >>> 0;
    const bitLenHigh: number = Math.floor(length / 0x20000000) >>> 0;
    const view = new DataView(msg.buffer);
    view.setUint32(paddedLength - 8, bitLenLow, true);
    view.setUint32(paddedLength - 4, bitLenHigh, true);

    // 四个链接变量（小端初值）
    let a0 = 0x67452301;
    let b0 = 0xefcdab89;
    let c0 = 0x98badcfe;
    let d0 = 0x10325476;

    for (let offset = 0; offset < paddedLength; offset += 64) {
      const m: Array<number> = [];
      for (let i = 0; i < 16; i++) {
        m.push(view.getUint32(offset + i * 4, true));
      }
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
        const sum: number = (f + a + Md5.K[i] + m[g]) >>> 0;
        const shift: number = Md5.S[i];
        const rotated: number = ((sum << shift) | (sum >>> (32 - shift))) >>> 0;
        a = d;
        d = c;
        c = b;
        b = (b + rotated) >>> 0;
      }
      a0 = (a0 + a) >>> 0;
      b0 = (b0 + b) >>> 0;
      c0 = (c0 + c) >>> 0;
      d0 = (d0 + d) >>> 0;
    }

    let out = '';
    out += Md5.toHexWord(a0);
    out += Md5.toHexWord(b0);
    out += Md5.toHexWord(c0);
    out += Md5.toHexWord(d0);
    return out;
  }

  /** 一个 32 位字按小端拆成 4 个字节的十六进制 */
  private static toHexWord(word: number): string {
    let out = '';
    for (let i = 0; i < 4; i++) {
      const byte: number = (word >>> (i * 8)) & 0xff;
      out += byte.toString(16).padStart(2, '0');
    }
    return out;
  }
}
