import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { utf8Bytes } from '../music/LxCrypto';
import { DownloadTagData } from './DownloadTags';

const DOMAIN: number = 0x0001;
const TAG: string = 'TagSink';

/**
 * 下载音频的标签写入（mp3 的 ID3v2.3 / flac 的元数据块）
 *
 * 系统里没有「往音频文件写标签」的 API —— `AVMetadataExtractor` 只能读
 * （拿到标题、歌手、内嵌封面图），所以这里按容器格式自己拼字节：
 *
 *   mp3  — 标签在文件**最开头**：ID3v2.3 头 + TIT2/TPE1/TALB 文字帧
 *          + APIC 封面帧 + USLT 歌词帧；
 *   flac — 元数据块紧跟在 `fLaC` 魔数之后、音频帧之前：
 *          STREAMINFO（原样搬过来，必须有）+ VORBIS_COMMENT（文字与歌词）+ PICTURE（封面）。
 *
 * 两条路都是**边下边写**，不整份重写一遍文件：
 * 开头一小段先攒在内存里认出格式（见 MAX_HEAD），认出之后把标签写出去、
 * 再把攒下的那一段补上，之后收到的数据直接落盘。
 * 认不出来的容器（m4a / aac / ogg …）原样直写，只是不写标签。
 */

/**
 * 攒开头的大小上限
 *
 * flac 要等元数据块**收全**才知道音频帧从哪开始（源文件自己也可能带着封面，
 * 几百 KB 都有可能）；超过这个数就不再等 —— 放弃写标签、把攒下的原样写出去，
 * 音频本身一点不受影响，只是这一首没有封面歌词。
 */
const MAX_HEAD: number = 512 * 1024;

/** 认出来的容器格式（决定标签怎么写） */
export type AudioFormat = 'mp3' | 'flac' | 'other' | 'unknown';

// ------------------------------------------------------------------ 字节小工具

function pushAll(target: number[], source: number[]): void {
  for (let i = 0; i < source.length; i++) {
    target.push(source[i]);
  }
}

/** 大端 32 位（flac 的 PICTURE 块、ID3v2.3 的帧长都用它） */
function u32be(value: number): number[] {
  return [(value >>> 24) & 0xFF, (value >>> 16) & 0xFF, (value >>> 8) & 0xFF, value & 0xFF];
}

/** 小端 32 位（vorbis comment 的长度字段） */
function u32le(value: number): number[] {
  return [value & 0xFF, (value >>> 8) & 0xFF, (value >>> 16) & 0xFF, (value >>> 24) & 0xFF];
}

/**
 * ID3v2 的「同步安全整数」：每字节只用低 7 位
 *
 * 标签长度里不能出现看起来像帧同步的字节（0xFF 开头），所以四个字节各让出最高位。
 */
function syncSafe(value: number): number[] {
  return [(value >>> 21) & 0x7F, (value >>> 14) & 0x7F, (value >>> 7) & 0x7F, value & 0x7F];
}

function syncSafeValue(bytes: number[], offset: number): number {
  return ((bytes[offset] & 0x7F) << 21) | ((bytes[offset + 1] & 0x7F) << 14)
    | ((bytes[offset + 2] & 0x7F) << 7) | (bytes[offset + 3] & 0x7F);
}

/** ISO-8859-1（帧 id、MIME 这类只能是 ASCII 的字段） */
function latin1(text: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    out.push(text.charCodeAt(i) & 0xFF);
  }
  return out;
}

/**
 * UTF-16LE 并带 BOM（ID3v2.3 里说中文的正规写法）
 *
 * v2.3 的编码字节只有 latin1(0x00) 与带 BOM 的 UTF-16(0x01) 两种 ——
 * UTF-8 是 v2.4 才有的，写在 v2.3 里会被老播放器当成乱码。
 */
function utf16Bytes(text: string): number[] {
  const out: number[] = [0xFF, 0xFE];
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    out.push(code & 0xFF, (code >>> 8) & 0xFF);
  }
  return out;
}

function toBuffer(bytes: number[]): ArrayBuffer {
  const out = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] & 0xFF;
  }
  return out.buffer;
}

function toNumbers(data: ArrayBuffer): number[] {
  const view = new Uint8Array(data);
  const out: number[] = [];
  for (let i = 0; i < view.length; i++) {
    out.push(view[i]);
  }
  return out;
}

// ------------------------------------------------------------------ ID3v2.3

/** 一个 ID3v2.3 帧：帧 id(4) + 长度(4，大端) + 标志(2) + 内容 */
function id3Frame(id: string, body: number[]): number[] {
  const out: number[] = latin1(id);
  pushAll(out, u32be(body.length));
  out.push(0x00, 0x00);
  pushAll(out, body);
  return out;
}

/** 文字帧（TIT2=标题 / TPE1=艺术家 / TALB=专辑）：编码字节 + UTF-16 文本 */
function textFrame(id: string, text: string): number[] {
  if (text.length === 0) {
    return [];
  }
  const body: number[] = [0x01];
  pushAll(body, utf16Bytes(text));
  return id3Frame(id, body);
}

/**
 * APIC 封面帧：编码 + MIME + 图片类型 + 描述 + 图片数据
 *
 * MIME 永远是 latin1（不受第一个编码字节影响），描述跟着编码字节走 ——
 * 描述用 UTF-16 空串时占 4 个字节（BOM + 结束符），少写这两个字节后面整块就错位了。
 */
function apicFrame(data: DownloadTagData): number[] {
  const cover: number[] | null = data.cover;
  if (cover === null || data.coverMime.length === 0) {
    return [];
  }
  const body: number[] = [0x01];
  pushAll(body, latin1(data.coverMime));
  body.push(0x00);
  body.push(0x03);
  body.push(0xFF, 0xFE, 0x00, 0x00);
  pushAll(body, cover);
  return id3Frame('APIC', body);
}

/** USLT 歌词帧：编码 + 语言(3) + 内容描述（空）+ 歌词文本 */
function usltFrame(lyric: string): number[] {
  if (lyric.length === 0) {
    return [];
  }
  const body: number[] = [0x01];
  pushAll(body, latin1('eng'));
  pushAll(body, [0xFF, 0xFE, 0x00, 0x00]);
  pushAll(body, utf16Bytes(lyric));
  return id3Frame('USLT', body);
}

/** 整个 ID3v2.3 标签（含 10 字节头）；没有任何要写的帧时返回空数组 */
export function buildId3v23(data: DownloadTagData): number[] {
  const frames: number[] = [];
  pushAll(frames, textFrame('TIT2', data.title));
  pushAll(frames, textFrame('TPE1', data.artist));
  pushAll(frames, textFrame('TALB', data.album));
  pushAll(frames, usltFrame(data.lyric));
  pushAll(frames, apicFrame(data));
  if (frames.length === 0) {
    return [];
  }
  const out: number[] = latin1('ID3');
  out.push(0x03, 0x00, 0x00);
  pushAll(out, syncSafe(frames.length));
  pushAll(out, frames);
  return out;
}

/**
 * 源文件开头自带的 ID3v2 标签有多长（0=没有这种标签）
 *
 * 带标签的流拼上我们的标签会变成「两个标签叠在一起」，所以认出长度后整段跳过。
 * 返回 -1 表示头还没收够、长度还不知道（继续等数据）。
 */
function id3v2SkipLength(bytes: number[]): number {
  if (bytes.length < 3 || bytes[0] !== 0x49 || bytes[1] !== 0x44 || bytes[2] !== 0x33) {
    return 0;
  }
  if (bytes.length < 10) {
    return -1;
  }
  const size: number = syncSafeValue(bytes, 6);
  // 长度离谱（超过我们肯攒的上限）就当没有标签：跳不过去，原样留着就好
  if (size <= 0 || size > MAX_HEAD) {
    return 0;
  }
  return 10 + size;
}

// ------------------------------------------------------------------ FLAC

/** flac 元数据块头：1 字节（最高位=是否最后一块，低 7 位=类型）+ 3 字节长度 */
function flacBlock(type: number, body: number[], last: boolean): number[] {
  const out: number[] = [(last ? 0x80 : 0x00) | type];
  out.push((body.length >>> 16) & 0xFF, (body.length >>> 8) & 0xFF, body.length & 0xFF);
  pushAll(out, body);
  return out;
}

/** VORBIS_COMMENT 块：厂商串 + 「KEY=value」列表（都是小端长度前缀的 UTF-8） */
function vorbisComments(data: DownloadTagData): number[] {
  const comments: string[] = [];
  if (data.title.length > 0) {
    comments.push(`TITLE=${data.title}`);
  }
  if (data.artist.length > 0) {
    comments.push(`ARTIST=${data.artist}`);
  }
  if (data.album.length > 0) {
    comments.push(`ALBUM=${data.album}`);
  }
  if (data.lyric.length > 0) {
    comments.push(`LYRICS=${data.lyric}`);
  }
  const vendor: number[] = utf8Bytes('listen');
  const out: number[] = [];
  pushAll(out, u32le(vendor.length));
  pushAll(out, vendor);
  pushAll(out, u32le(comments.length));
  for (const text of comments) {
    const bytes: number[] = utf8Bytes(text);
    pushAll(out, u32le(bytes.length));
    pushAll(out, bytes);
  }
  return out;
}

/** PICTURE 块：类型 + MIME + 描述 + 宽高色深 + 图片数据（都是大端） */
function flacPicture(data: DownloadTagData): number[] {
  const cover: number[] | null = data.cover;
  if (cover === null || data.coverMime.length === 0) {
    return [];
  }
  const mime: number[] = utf8Bytes(data.coverMime);
  const out: number[] = [];
  pushAll(out, u32be(3));
  pushAll(out, u32be(mime.length));
  pushAll(out, mime);
  pushAll(out, u32be(0));
  pushAll(out, u32be(data.coverWidth));
  pushAll(out, u32be(data.coverHeight));
  pushAll(out, u32be(24));
  pushAll(out, u32be(0));
  pushAll(out, u32be(cover.length));
  pushAll(out, cover);
  return out;
}

/** 元数据区的解析结果：audioOffset 是音频帧起点，streamInfo 原样搬回文件头 */
export interface FlacHead {
  /** 收全了没有：还没收全时 streamInfo / audioOffset 无意义 */
  complete: boolean;
  /** 不是 flac（或结构不对）：这种就不去动它 */
  invalid: boolean;
  streamInfo: number[];
  audioOffset: number;
}

const FLAC_HEAD_UNKNOWN: FlacHead = { complete: false, invalid: false, streamInfo: [], audioOffset: 0 };

/**
 * 顺着块头把 flac 的元数据区走一遍
 *
 * 规范要求 STREAMINFO 是**第一块**（34 字节，采样率、总时长、MD5 都在里面），
 * 音频帧紧跟在最后一块之后。我们只留这一块，其余（源文件自己的文字标签、
 * 填充、seek 表、甚至它内嵌的封面）全部换成我们新写的那几块。
 */
export function parseFlacHead(bytes: number[]): FlacHead {
  if (bytes.length < 4) {
    return FLAC_HEAD_UNKNOWN;
  }
  if (bytes[0] !== 0x66 || bytes[1] !== 0x4C || bytes[2] !== 0x61 || bytes[3] !== 0x43) {
    return { complete: false, invalid: true, streamInfo: [], audioOffset: 0 };
  }
  let offset: number = 4;
  let streamInfo: number[] = [];
  let first: boolean = true;
  while (true) {
    if (offset + 4 > bytes.length) {
      return FLAC_HEAD_UNKNOWN;
    }
    const head: number = bytes[offset];
    const last: boolean = (head & 0x80) !== 0;
    const type: number = head & 0x7F;
    const length: number = (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
    // 127 是非法类型；第一块必须是 34 字节的 STREAMINFO
    if (type === 127 || (first && (type !== 0 || length !== 34))) {
      return { complete: false, invalid: true, streamInfo: [], audioOffset: 0 };
    }
    if (offset + 4 + length > bytes.length) {
      return FLAC_HEAD_UNKNOWN;
    }
    if (first) {
      streamInfo = bytes.slice(offset + 4, offset + 4 + length);
    }
    offset += 4 + length;
    first = false;
    if (last) {
      break;
    }
  }
  return { complete: true, invalid: false, streamInfo: streamInfo, audioOffset: offset };
}

/** 新的文件头：魔数 + STREAMINFO + 我们写的文字 / 封面块；没有可写的块时返回空数组 */
export function buildFlacHeader(streamInfo: number[], data: DownloadTagData): number[] {
  const hasText: boolean = data.title.length > 0 || data.artist.length > 0
    || data.album.length > 0 || data.lyric.length > 0;
  const hasPicture: boolean = data.cover !== null && data.coverMime.length > 0;
  if (!hasText && !hasPicture) {
    return [];
  }
  const out: number[] = [0x66, 0x4C, 0x61, 0x43];
  pushAll(out, flacBlock(0, streamInfo, false));
  if (hasText) {
    pushAll(out, flacBlock(4, vorbisComments(data), !hasPicture));
  }
  if (hasPicture) {
    pushAll(out, flacBlock(6, flacPicture(data), true));
  }
  return out;
}

// ------------------------------------------------------------------ 边下边写

/** 按魔数认容器；'unknown' 表示还得再攒一点才认得出 */
function sniff(bytes: number[]): AudioFormat {
  if (bytes.length >= 4 && bytes[0] === 0x66 && bytes[1] === 0x4C
    && bytes[2] === 0x61 && bytes[3] === 0x43) {
    return 'flac';
  }
  // 'ID3' 开头的（带标签的 mp3），或直接的 mpeg 帧同步
  if (bytes.length >= 3 && bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) {
    return 'mp3';
  }
  if (bytes.length >= 2 && bytes[0] === 0xFF && (bytes[1] & 0xE0) === 0xE0) {
    return 'mp3';
  }
  // 其余容器（m4a 的 ftyp / ogg 的 OggS / wav 的 RIFF…）看头 8 个字节就够判了
  return bytes.length >= 8 ? 'other' : 'unknown';
}

/**
 * 把标签跟着音频一起写进文件
 *
 * 用法：`new TagSink(fd, tags)` 之后，每收到一块数据就 `write(data)`，
 * 全部收完再 `finish()`。mp3 的标签要出现在**第一个音频字节之前**，
 * 而「音频从哪开始」这件事只有收到数据才知道，所以开头先攒着 —— 攒的过程对
 * 调用方透明，写文件的位置与顺序由这里保证。
 */
export class TagSink {
  private fd: number = -1;
  private data: DownloadTagData;
  /** 攒着还没写出去的文件开头 */
  private head: number[] = [];
  /** 已经过了开头这一关，后面收到的数据直写 */
  private streaming: boolean = false;
  /** 标签真的写进文件了（决定下载列表里显示什么） */
  private written: boolean = false;
  private format: AudioFormat = 'unknown';

  constructor(fd: number, data: DownloadTagData) {
    this.fd = fd;
    this.data = data;
  }

  /** 收到的音频数据（顺序调用） */
  write(data: ArrayBuffer): void {
    if (this.streaming) {
      fs.writeSync(this.fd, data);
      return;
    }
    pushAll(this.head, toNumbers(data));
    this.drainHead();
  }

  /** 收完数据：还攒着的（下载太短、开头认不出来）原样补写出去 */
  finish(): void {
    if (this.streaming) {
      return;
    }
    this.giveUp();
  }

  /** 标签是否已经写进文件 */
  embedded(): boolean {
    return this.written;
  }

  /** 认出来的容器格式；'other' 表示这种容器我们写不了标签 */
  knownFormat(): AudioFormat {
    return this.format;
  }

  /** 试着把攒下的开头消化掉：认出格式就写标签 + 补数据，之后转直写 */
  private drainHead(): void {
    const format: AudioFormat = sniff(this.head);
    if (format === 'unknown') {
      this.waitMore();
      return;
    }
    this.format = format;
    if (format === 'mp3') {
      this.drainMp3();
      return;
    }
    if (format === 'flac') {
      this.drainFlac();
      return;
    }
    this.giveUp();
  }

  private drainMp3(): void {
    const skip: number = id3v2SkipLength(this.head);
    // -1：标签长度还不知道；head.length < skip：标签本体还没收全 —— 都继续等
    if (skip < 0 || this.head.length < skip) {
      this.waitMore();
      return;
    }
    const out: number[] = buildId3v23(this.data);
    if (out.length === 0) {
      this.giveUp();
      return;
    }
    pushAll(out, this.head.slice(skip));
    this.written = true;
    this.commit(out);
  }

  private drainFlac(): void {
    const head: FlacHead = parseFlacHead(this.head);
    if (head.invalid) {
      hilog.warn(DOMAIN, TAG, 'flac head malformed, skip tags');
      this.giveUp();
      return;
    }
    if (!head.complete) {
      this.waitMore();
      return;
    }
    const out: number[] = buildFlacHeader(head.streamInfo, this.data);
    if (out.length === 0) {
      this.giveUp();
      return;
    }
    pushAll(out, this.head.slice(head.audioOffset));
    this.written = true;
    this.commit(out);
  }

  /**
   * 还差数据、要接着攒：只有这时候才看「攒太多就放弃」
   *
   * 上限判在这里而不是认格式之前 —— 一批数据块本身就可能比上限还大，
   * 那种情况下格式其实已经认得出来，不该被当成「攒太多」白扔掉。
   */
  private waitMore(): void {
    if (this.head.length > MAX_HEAD) {
      hilog.warn(DOMAIN, TAG, 'head too large, skip tags');
      this.giveUp();
    }
  }

  /** 把攒下的开头原样写出去，之后直写（不写标签） */
  private giveUp(): void {
    const pending: number[] = this.head;
    this.head = [];
    this.streaming = true;
    if (pending.length > 0) {
      fs.writeSync(this.fd, toBuffer(pending));
    }
  }

  /** 写出「标签 + 攒下的音频」，之后转直写 */
  private commit(bytes: number[]): void {
    this.head = [];
    this.streaming = true;
    fs.writeSync(this.fd, toBuffer(bytes));
  }
}
