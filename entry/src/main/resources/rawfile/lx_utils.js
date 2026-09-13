'use strict';

/**
 * 洛雪音乐自定义音源 - 纯 JS 工具库（HarmonyOS 移植版）
 *
 * 对应 lx-music-mobile 原生侧通过 __lx_native_call__utils_* 暴露给沙箱的能力：
 *   md5 / base64 / buffer / aes-128-cbc / aes-128-ecb / rsa(NoPadding)
 *
 * 移植时改为纯 JS 实现，避免依赖 ArkWeb javaScriptProxy 的同步返回值
 * （javaScriptProxy 的方法默认是异步的，无法同步返回字符串）。
 */
(function (global) {
  // ---------------------------------------------------------------- 字节工具
  function stringToBytes (str) {
    const out = []
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i)
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
        const next = str.charCodeAt(i + 1)
        if (next >= 0xDC00 && next <= 0xDFFF) {
          code = ((code - 0xD800) << 10) + (next - 0xDC00) + 0x10000
          i++
        }
      }
      if (code < 0x80) {
        out.push(code)
      } else if (code < 0x800) {
        out.push((code >> 6) | 0xC0, (code & 0x3F) | 0x80)
      } else if (code < 0x10000) {
        out.push((code >> 12) | 0xE0, ((code >> 6) & 0x3F) | 0x80, (code & 0x3F) | 0x80)
      } else {
        out.push(
          (code >> 18) | 0xF0,
          ((code >> 12) & 0x3F) | 0x80,
          ((code >> 6) & 0x3F) | 0x80,
          (code & 0x3F) | 0x80
        )
      }
    }
    return out
  }

  function bytesToString (bytes) {
    let result = ''
    let i = 0
    while (i < bytes.length) {
      const b = bytes[i]
      if (b < 0x80) {
        result += String.fromCharCode(b)
        i += 1
      } else if (b >= 0xC0 && b < 0xE0) {
        result += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F))
        i += 2
      } else if (b >= 0xE0 && b < 0xF0) {
        result += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F))
        i += 3
      } else {
        let cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F)
        cp -= 0x10000
        result += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
        i += 4
      }
    }
    return result
  }

  // ---------------------------------------------------------------- Base64
  const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

  function base64EncodeBytes (bytes) {
    let out = ''
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i]
      const b1 = i + 1 < bytes.length ? bytes[i + 1] : NaN
      const b2 = i + 2 < bytes.length ? bytes[i + 2] : NaN
      out += B64_CHARS[b0 >> 2]
      out += B64_CHARS[((b0 & 3) << 4) | (isNaN(b1) ? 0 : b1 >> 4)]
      out += isNaN(b1) ? '=' : B64_CHARS[((b1 & 15) << 2) | (isNaN(b2) ? 0 : b2 >> 6)]
      out += isNaN(b2) ? '=' : B64_CHARS[b2 & 63]
    }
    return out
  }

  function base64DecodeToBytes (str) {
    const clean = String(str).replace(/[\r\n\s]/g, '').replace(/-/g, '+').replace(/_/g, '/')
    const out = []
    let buffer = 0
    let bits = 0
    for (let i = 0; i < clean.length; i++) {
      const ch = clean[i]
      if (ch === '=') break
      const idx = B64_CHARS.indexOf(ch)
      if (idx < 0) continue
      buffer = (buffer << 6) | idx
      bits += 6
      if (bits >= 8) {
        bits -= 8
        out.push((buffer >> bits) & 0xFF)
      }
    }
    return out
  }

  // ---------------------------------------------------------------- MD5
  const MD5_S = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ]
  const MD5_K = (function () {
    const k = new Uint32Array(64)
    for (let i = 0; i < 64; i++) k[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296)
    return k
  })()

  function rotl (x, c) {
    return ((x << c) | (x >>> (32 - c))) >>> 0
  }

  function md5Hex (bytes) {
    const len = bytes.length
    const bitLenLo = (len * 8) >>> 0
    const bitLenHi = Math.floor(len / 536870912)
    let total = len + 1 + 8
    if (total % 64 !== 0) total += 64 - (total % 64)
    const buf = new Uint8Array(total)
    buf.set(bytes)
    buf[len] = 0x80
    const view = new DataView(buf.buffer)
    view.setUint32(total - 8, bitLenLo, true)
    view.setUint32(total - 4, bitLenHi, true)

    let a0 = 0x67452301
    let b0 = 0xEFCDAB89
    let c0 = 0x98BADCFE
    let d0 = 0x10325476
    const M = new Uint32Array(16)

    for (let off = 0; off < total; off += 64) {
      for (let i = 0; i < 16; i++) M[i] = view.getUint32(off + i * 4, true)
      let A = a0
      let B = b0
      let C = c0
      let D = d0
      for (let i = 0; i < 64; i++) {
        let F
        let g
        if (i < 16) {
          F = (B & C) | (~B & D)
          g = i
        } else if (i < 32) {
          F = (D & B) | (~D & C)
          g = (5 * i + 1) % 16
        } else if (i < 48) {
          F = B ^ C ^ D
          g = (3 * i + 5) % 16
        } else {
          F = C ^ (B | ~D)
          g = (7 * i) % 16
        }
        F = (F + A + MD5_K[i] + M[g]) >>> 0
        A = D
        D = C
        C = B
        B = (B + rotl(F, MD5_S[i])) >>> 0
      }
      a0 = (a0 + A) >>> 0
      b0 = (b0 + B) >>> 0
      c0 = (c0 + C) >>> 0
      d0 = (d0 + D) >>> 0
    }
    return leHex(a0) + leHex(b0) + leHex(c0) + leHex(d0)
  }

  function leHex (n) {
    let s = ''
    for (let i = 0; i < 4; i++) {
      s += ((n >>> (i * 8)) & 0xFF).toString(16).padStart(2, '0')
    }
    return s
  }

  // ---------------------------------------------------------------- AES-128
  const AES_SBOX = new Uint8Array([
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
  ])

  const AES_RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

  function xtime (b) {
    return ((b << 1) ^ ((b & 0x80) ? 0x1B : 0)) & 0xFF
  }

  function gmul (a, b) {
    let p = 0
    for (let i = 0; i < 8; i++) {
      if (b & 1) p ^= a
      const hi = a & 0x80
      a = (a << 1) & 0xFF
      if (hi) a ^= 0x1B
      b >>= 1
    }
    return p
  }

  function aesExpandKey (key) {
    const w = new Uint8Array(176)
    w.set(key)
    let generated = 16
    let rconIndex = 0
    const temp = new Uint8Array(4)
    while (generated < 176) {
      for (let i = 0; i < 4; i++) temp[i] = w[generated - 4 + i]
      if (generated % 16 === 0) {
        const t0 = temp[0]
        temp[0] = AES_SBOX[temp[1]] ^ AES_RCON[rconIndex++]
        temp[1] = AES_SBOX[temp[2]]
        temp[2] = AES_SBOX[temp[3]]
        temp[3] = AES_SBOX[t0]
      }
      for (let i = 0; i < 4; i++) {
        w[generated] = w[generated - 16] ^ temp[i]
        generated++
      }
    }
    return w
  }

  function aesEncryptBlock (block, w) {
    for (let i = 0; i < 16; i++) block[i] ^= w[i]
    for (let round = 1; round <= 10; round++) {
      for (let i = 0; i < 16; i++) block[i] = AES_SBOX[block[i]]
      // ShiftRows
      let t = block[1]
      block[1] = block[5]
      block[5] = block[9]
      block[9] = block[13]
      block[13] = t
      t = block[2]
      block[2] = block[10]
      block[10] = t
      t = block[6]
      block[6] = block[14]
      block[14] = t
      t = block[3]
      block[3] = block[15]
      block[15] = block[11]
      block[11] = block[7]
      block[7] = t
      if (round !== 10) {
        for (let c = 0; c < 4; c++) {
          const o = c * 4
          const a0 = block[o]
          const a1 = block[o + 1]
          const a2 = block[o + 2]
          const a3 = block[o + 3]
          block[o] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3
          block[o + 1] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3
          block[o + 2] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3)
          block[o + 3] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2)
        }
      }
      const base = round * 16
      for (let i = 0; i < 16; i++) block[i] ^= w[base + i]
    }
  }

  function pkcs7Pad (bytes, size) {
    const padLen = size - (bytes.length % size)
    const out = new Uint8Array(bytes.length + padLen)
    out.set(bytes)
    for (let i = 0; i < padLen; i++) out[bytes.length + i] = padLen
    return out
  }

  function aesEncryptBytes (dataBytes, mode, keyBytes, ivBytes) {
    if (keyBytes.length !== 16) throw new Error('Only aes-128 keys are supported')
    const w = aesExpandKey(keyBytes)
    let data
    if (mode === 'ECB_NoPadding') {
      if (dataBytes.length % 16 !== 0) throw new Error('data length must be a multiple of 16')
      data = dataBytes
    } else {
      // CBC_PKCS7 与 ECB_PKCS7 都要填充。
      // 注意：洛雪的 AES_MODE.ECB_128_NoPadding 取值是 Java 的 "AES"，
      // 即 Cipher.getInstance("AES") = AES/ECB/PKCS5Padding，所以 ECB 实际是带填充的。
      data = pkcs7Pad(dataBytes, 16)
    }
    const out = new Uint8Array(data.length)
    let prev = (ivBytes && ivBytes.length >= 16) ? ivBytes.slice(0, 16) : new Uint8Array(16)
    for (let off = 0; off < data.length; off += 16) {
      const block = new Uint8Array(16)
      for (let i = 0; i < 16; i++) {
        block[i] = data[off + i] ^ (mode === 'CBC_PKCS7' ? prev[i] : 0)
      }
      aesEncryptBlock(block, w)
      out.set(block, off)
      if (mode === 'CBC_PKCS7') prev = block
    }
    return out
  }

  // ---------------------------------------------------------------- RSA NoPadding
  function derReadTlv (bytes, pos) {
    const tag = bytes[pos]
    let p = pos + 1
    let len = bytes[p++]
    if (len & 0x80) {
      const count = len & 0x7F
      len = 0
      for (let i = 0; i < count; i++) len = (len << 8) | bytes[p++]
    }
    return { tag, contentStart: p, contentEnd: p + len, next: p + len }
  }

  function derBytesToBigInt (bytes, start, end) {
    let hex = '0x'
    for (let i = start; i < end; i++) hex += bytes[i].toString(16).padStart(2, '0')
    return BigInt(hex)
  }

  function derReadInteger (bytes, pos) {
    const tlv = derReadTlv(bytes, pos)
    if (tlv.tag !== 0x02) throw new Error('RSA key: expected INTEGER')
    return { value: derBytesToBigInt(bytes, tlv.contentStart, tlv.contentEnd), next: tlv.next }
  }

  function parseRsaPublicKey (der) {
    const outer = derReadTlv(der, 0)
    if (outer.tag !== 0x30) throw new Error('RSA key: bad sequence')
    let pos = outer.contentStart
    const first = derReadTlv(der, pos)
    if (first.tag === 0x02) {
      // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
      const n = derReadInteger(der, pos)
      const e = derReadInteger(der, n.next)
      return { n: n.value, e: e.value }
    }
    // SubjectPublicKeyInfo ::= SEQUENCE { algorithm, BIT STRING }
    pos = first.next
    const bitString = derReadTlv(der, pos)
    if (bitString.tag !== 0x03) throw new Error('RSA key: expected BIT STRING')
    let inner = bitString.contentStart
    if (der[inner] === 0x00) inner += 1 // unused bits
    const seq = derReadTlv(der, inner)
    const n = derReadInteger(der, seq.contentStart)
    const e = derReadInteger(der, n.next)
    return { n: n.value, e: e.value }
  }

  function modPow (base, exp, mod) {
    let result = 1n
    let b = base % mod
    let e = exp
    while (e > 0n) {
      if (e & 1n) result = (result * b) % mod
      b = (b * b) % mod
      e >>= 1n
    }
    return result
  }

  function bigIntToBytes (value, length) {
    const out = new Uint8Array(length)
    let v = value
    for (let i = length - 1; i >= 0; i--) {
      out[i] = Number(v & 0xFFn)
      v >>= 8n
    }
    return out
  }

  // ---------------------------------------------------------------- 对外接口
  global.LXPureUtils = {
    stringToBytes,
    bytesToString,
    base64EncodeBytes,
    base64DecodeToBytes,

    // 等价于原生 __lx_native_call__utils_str2b64（UTF-8 字符串 -> base64）
    str2b64 (str) {
      return base64EncodeBytes(stringToBytes(String(str)))
    },
    // 等价于原生 __lx_native_call__utils_b642buf（base64 -> 字节数组）
    b642buf (b64) {
      return base64DecodeToBytes(b64)
    },
    // 等价于原生 __lx_native_call__utils_str2md5（MD5(UTF-8) -> 小写 hex）
    str2md5 (str) {
      return md5Hex(stringToBytes(String(str)))
    },
    // 等价于原生 utils_aes_encrypt；入参/出参均为 base64
    aesEncryptB64 (dataB64, keyB64, ivB64, mode) {
      const data = new Uint8Array(base64DecodeToBytes(dataB64))
      const key = new Uint8Array(base64DecodeToBytes(keyB64))
      const iv = ivB64 ? new Uint8Array(base64DecodeToBytes(ivB64)) : new Uint8Array(0)
      return base64EncodeBytes(aesEncryptBytes(data, mode, key, iv))
    },
    // 等价于原生 utils_rsa_encrypt（RSA/ECB/NoPadding）；入参/出参均为 base64
    rsaEncryptB64 (dataB64, keyB64) {
      const data = new Uint8Array(base64DecodeToBytes(dataB64))
      const key = parseRsaPublicKey(base64DecodeToBytes(keyB64))
      const k = Math.ceil(key.n.toString(16).length / 2)
      if (data.length > k) throw new Error('RSA: data too long')
      const m = derBytesToBigInt(data, 0, data.length)
      return base64EncodeBytes(bigIntToBytes(modPow(m, key.e, key.n), k))
    },
    // 供自检使用
    md5Hex,
    aesEncryptBytes,
  }
})(typeof globalThis !== 'undefined' ? globalThis : this)
