/**
 * DEFLATE（RFC 1951）+ zlib 包装的解压，纯 ArkTS 实现。
 *
 * 为什么自己写：HarmonyOS 的 `@ohos.zlib` 只有文件级的 zip/gzip 解压，
 * 没有「内存字节 -> 内存字节」的 inflate；而酷我的歌词接口返回的正是
 * zlib 流（`78 9c ...`），要现解。算法照 RFC 实现，已在宿主侧用
 * 酷我真实响应逐字节验证过（解出来是 base64 文本，再 XOR 'yeelion' 得到 LRC）。
 *
 * 只做解压，不做校验；解压失败（数据不完整/表非法）直接抛错，由调用方降级。
 */

/** 按位读（LSB first，DEFLATE 的规定顺序） */
class BitReader {
  private data: Uint8Array;
  private pos: number;
  private buffer: number = 0;
  private count: number = 0;

  constructor(data: Uint8Array, pos: number) {
    this.data = data;
    this.pos = pos;
  }

  read(bits: number): number {
    let value: number = 0;
    for (let i = 0; i < bits; i++) {
      if (this.count === 0) {
        if (this.pos >= this.data.length) {
          throw new Error('deflate 数据提前结束');
        }
        this.buffer = this.data[this.pos++];
        this.count = 8;
      }
      value |= (this.buffer & 1) << i;
      this.buffer >>= 1;
      this.count--;
    }
    return value;
  }

  /** 丢弃当前字节里剩余的位（stored block 用） */
  align(): void {
    this.count = 0;
    this.buffer = 0;
  }
}

/** 规范 Huffman 表 */
interface HuffmanTable {
  counts: number[];
  symbols: number[];
  maxBits: number;
}

function buildTable(lengths: number[], maxBits: number): HuffmanTable {
  const counts: number[] = [];
  for (let i = 0; i <= maxBits; i++) {
    counts.push(0);
  }
  for (const length of lengths) {
    if (length > 0) {
      counts[length]++;
    }
  }
  const offsets: number[] = [];
  for (let i = 0; i <= maxBits + 1; i++) {
    offsets.push(0);
  }
  for (let i = 1; i <= maxBits; i++) {
    offsets[i + 1] = offsets[i] + counts[i];
  }
  const symbols: number[] = [];
  for (let i = 0; i < lengths.length; i++) {
    symbols.push(0);
  }
  for (let symbol = 0; symbol < lengths.length; symbol++) {
    const length: number = lengths[symbol];
    if (length !== 0) {
      symbols[offsets[length]] = symbol;
      offsets[length]++;
    }
  }
  return { counts: counts, symbols: symbols, maxBits: maxBits };
}

function decodeSymbol(reader: BitReader, table: HuffmanTable): number {
  let code: number = 0;
  let first: number = 0;
  let index: number = 0;
  for (let len = 1; len <= table.maxBits; len++) {
    code |= reader.read(1);
    const count: number = table.counts[len];
    if (code - first < count) {
      return table.symbols[index + (code - first)];
    }
    index += count;
    first = (first + count) << 1;
    code <<= 1;
  }
  throw new Error('非法的 Huffman 编码');
}

const LENGTH_BASE: number[] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
  67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const LENGTH_EXTRA: number[] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
  4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: number[] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: number[] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
  9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];
/** 动态块里「码长表」本身的解码顺序 */
const CODE_LENGTH_ORDER: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

let FIXED_LIT: HuffmanTable | null = null;
let FIXED_DIST: HuffmanTable | null = null;

function fixedTables(): void {
  if (FIXED_LIT !== null && FIXED_DIST !== null) {
    return;
  }
  const lit: number[] = [];
  for (let i = 0; i < 288; i++) {
    if (i < 144) {
      lit.push(8);
    } else if (i < 256) {
      lit.push(9);
    } else if (i < 280) {
      lit.push(7);
    } else {
      lit.push(8);
    }
  }
  const dist: number[] = [];
  for (let i = 0; i < 30; i++) {
    dist.push(5);
  }
  FIXED_LIT = buildTable(lit, 15);
  FIXED_DIST = buildTable(dist, 15);
}

/**
 * 解压一段 zlib 流（自动跳过 2 字节 zlib 头；末尾 4 字节 Adler-32 用不到）。
 * @param data  原始字节
 * @param start zlib 流的起始下标
 * @returns 解压后的字节
 */
export function inflateZlib(data: Uint8Array, start: number): number[] {
  let begin: number = start;
  if (begin + 1 < data.length && (data[begin] & 0x0F) === 8) {
    const header: number = (data[begin] << 8) | data[begin + 1];
    if (header % 31 === 0) {
      begin += 2;
    }
  }
  const reader: BitReader = new BitReader(data, begin);
  const out: number[] = [];
  while (true) {
    const last: number = reader.read(1);
    const type: number = reader.read(2);
    if (type === 0) {
      reader.align();
      const length: number = reader.read(16);
      reader.read(16);
      for (let i = 0; i < length; i++) {
        out.push(reader.read(8));
      }
    } else if (type === 1 || type === 2) {
      let litTable: HuffmanTable;
      let distTable: HuffmanTable;
      if (type === 1) {
        fixedTables();
        litTable = FIXED_LIT as HuffmanTable;
        distTable = FIXED_DIST as HuffmanTable;
      } else {
        const hlit: number = reader.read(5) + 257;
        const hdist: number = reader.read(5) + 1;
        const hclen: number = reader.read(4) + 4;
        const codeLengths: number[] = [];
        for (let i = 0; i < 19; i++) {
          codeLengths.push(0);
        }
        for (let i = 0; i < hclen; i++) {
          codeLengths[CODE_LENGTH_ORDER[i]] = reader.read(3);
        }
        const codeTable: HuffmanTable = buildTable(codeLengths, 7);
        const lengths: number[] = [];
        while (lengths.length < hlit + hdist) {
          const symbol: number = decodeSymbol(reader, codeTable);
          if (symbol < 16) {
            lengths.push(symbol);
          } else if (symbol === 16) {
            const previous: number = lengths[lengths.length - 1];
            const repeat: number = 3 + reader.read(2);
            for (let i = 0; i < repeat; i++) {
              lengths.push(previous);
            }
          } else if (symbol === 17) {
            const repeat: number = 3 + reader.read(3);
            for (let i = 0; i < repeat; i++) {
              lengths.push(0);
            }
          } else {
            const repeat: number = 11 + reader.read(7);
            for (let i = 0; i < repeat; i++) {
              lengths.push(0);
            }
          }
        }
        litTable = buildTable(lengths.slice(0, hlit), 15);
        distTable = buildTable(lengths.slice(hlit), 15);
      }
      while (true) {
        const symbol: number = decodeSymbol(reader, litTable);
        if (symbol < 256) {
          out.push(symbol);
        } else if (symbol === 256) {
          break;
        } else {
          const index: number = symbol - 257;
          if (index >= LENGTH_BASE.length) {
            throw new Error('非法的长度码');
          }
          const length: number = LENGTH_BASE[index] + reader.read(LENGTH_EXTRA[index]);
          const distSymbol: number = decodeSymbol(reader, distTable);
          if (distSymbol >= DIST_BASE.length) {
            throw new Error('非法的距离码');
          }
          const distance: number = DIST_BASE[distSymbol] + reader.read(DIST_EXTRA[distSymbol]);
          const from: number = out.length - distance;
          if (from < 0) {
            throw new Error('非法的回溯距离');
          }
          for (let i = 0; i < length; i++) {
            out.push(out[from + i]);
          }
        }
      }
    } else {
      throw new Error('非法的块类型');
    }
    if (last === 1) {
      break;
    }
  }
  return out;
}
