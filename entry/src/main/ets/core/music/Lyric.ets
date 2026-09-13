/**
 * LRC 歌词解析
 *
 * 洛雪源脚本的 `lyric` action 返回 `{ lyric, tlyric, rlyric, lxlyric }`，
 * 其中 `lyric` / `tlyric` 是标准 LRC 文本（`[mm:ss.xx]歌词`）。
 * 这里只做「有时间轴的行」：解析出时间与文本，可选的翻译按时间对齐到原文行。
 *
 * 没有时间标签的歌词（少数源只给纯文本）会保留成 time = -1 的行，界面上不跟随进度高亮。
 */

/** 一行歌词 */
export interface LyricLine {
  /** 秒；-1 表示没有时间轴 */
  time: number;
  text: string;
  /** 翻译（tlyric 里同一时间点的那句），没有就是空串 */
  translation: string;
}

interface RawLine {
  time: number;
  text: string;
}

/** `[mm:ss]`、`[mm:ss.xx]`、`[mm:ss:xx]` 都接受 */
function parseTimeTag(tag: string): number {
  const match = /^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$/.exec(tag);
  if (match === null) {
    return -1;
  }
  const minutes: number = parseInt(match[1], 10);
  const seconds: number = parseInt(match[2], 10);
  if (isNaN(minutes) || isNaN(seconds)) {
    return -1;
  }
  let fraction: number = 0;
  const frac: string | undefined = match[3];
  if (frac !== undefined && frac.length > 0) {
    fraction = parseInt(frac, 10) / Math.pow(10, frac.length);
  }
  return minutes * 60 + seconds + fraction;
}

/** 解析带时间标签的 LRC 文本（一行多个标签会产生多行） */
function parseTimed(text: string): RawLine[] {
  const out: RawLine[] = [];
  if (text.length === 0) {
    return out;
  }
  let offsetSeconds: number = 0;
  const rows: string[] = text.split(/\r?\n/);
  for (const row of rows) {
    let rest: string = row;
    const times: number[] = [];
    // 一行开头可能连着好几个标签：`[00:01.00][00:05.00]副歌`
    while (true) {
      const match = /^\s*\[([^\]]+)\]/.exec(rest);
      if (match === null) {
        break;
      }
      const tag: string = match[1].trim();
      rest = rest.substring(match[0].length);
      if (tag.startsWith('offset:')) {
        const value: number = parseInt(tag.substring('offset:'.length), 10);
        if (!isNaN(value)) {
          offsetSeconds = value / 1000;
        }
        continue;
      }
      const time: number = parseTimeTag(tag);
      if (time >= 0) {
        times.push(time);
      }
    }
    const content: string = rest.trim();
    for (const time of times) {
      out.push({ time: time, text: content });
    }
  }
  if (offsetSeconds !== 0) {
    for (const item of out) {
      item.time = item.time + offsetSeconds;
    }
  }
  return out;
}

/** 没有时间轴时，退化成逐行纯文本 */
function plainLines(text: string): LyricLine[] {
  const out: LyricLine[] = [];
  const rows: string[] = text.split(/\r?\n/);
  for (const row of rows) {
    const line: string = row.trim();
    if (line.length > 0) {
      out.push({ time: -1, text: line, translation: '' });
    }
  }
  return out;
}

/** 时间轴对齐时允许 0.1s 的误差（不同源的小数位精度不一样） */
function findTranslation(trans: RawLine[], time: number): string {
  const key: number = Math.round(time * 10);
  for (const item of trans) {
    if (Math.round(item.time * 10) === key && item.text.length > 0) {
      return item.text;
    }
  }
  return '';
}

/**
 * 解析歌词。
 * @param lyric  原文 LRC
 * @param tlyric 翻译 LRC（可选）
 */
export function parseLyric(lyric: string, tlyric: string = ''): LyricLine[] {
  const raw: RawLine[] = parseTimed(lyric);
  if (raw.length === 0) {
    return plainLines(lyric);
  }
  const trans: RawLine[] = parseTimed(tlyric);
  const lines: LyricLine[] = [];
  for (const item of raw) {
    if (item.text.length === 0) {
      continue;
    }
    lines.push({ time: item.time, text: item.text, translation: findTranslation(trans, item.time) });
  }
  lines.sort((a: LyricLine, b: LyricLine) => a.time - b.time);
  return lines;
}

/**
 * 当前唱到的行号（二分找最后一个 time <= seconds 的行）。
 * 没有时间轴时返回 -1，界面就不做高亮与滚动。
 */
export function activeLyricIndex(lines: LyricLine[], seconds: number): number {
  if (lines.length === 0 || lines[0].time < 0) {
    return -1;
  }
  let low: number = 0;
  let high: number = lines.length - 1;
  let found: number = -1;
  while (low <= high) {
    const mid: number = Math.floor((low + high) / 2);
    if (lines[mid].time <= seconds) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return found;
}
