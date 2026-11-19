import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DismissedSongs';
const FILE_NAME: string = 'dismissed_songs.json';
const VERSION: number = 1;
/**
 * 名单上限（FIFO 淘汰）
 *
 * 只是「首页推荐歌曲里别再出现这几首」的本地名单，不是黑名单库：500 条已经远超
 * 正常用户会标记的量，再多就说明有人在拿它当收藏用，那种用法本来就该用收藏。
 */
const MAX_KEYS: number = 500;

/**
 * 「不感兴趣」名单（推荐歌曲 / 私人雷达的长按菜单）
 *
 * 群反馈（2026-11-19 16:00，不喜欢吃鱼）：「这个推荐歌曲功能老是推荐各种抖音短视频
 * 歌曲，全是各种变速和烟嗓版，有没有不感兴趣按钮」。
 *
 * 这一份解决两件事，都必须在**端上立刻可见**：
 *   1) 标记完这首马上从首页那两排卡片里消失（不用等下次刷新）；
 *   2) 下次打开 App 也不会再出现 —— 所以要落盘，只在内存里记着等于没做。
 *
 * 为什么按「歌名 + 歌手」而不是歌曲 id：同一首歌在不同平台的 id 完全不同，
 * 而用户说的「别再推这首」是内容层面的意思；跨平台换源后照样认得出来。
 * 归一化只做小写 + 去首尾空白：刻意不做「去括号 / 去 Live 后缀」那种模糊匹配 ——
 * 那会把《某歌》和《某歌 (Live)》当成同一首，误伤比漏杀更难受。
 *
 * 推荐算法那侧的画像 / 负反馈是另一条线（core/heart，见 docs/RECOMMEND_HANDOFF.md），
 * 这里只做「用户明确说了不要的，别再摆到他面前」，不碰权重。
 */

interface DismissedData {
  version?: number;
  keys?: string[];
}

/** 归一化：小写 + 去首尾空白（只用来拼 key，不改显示） */
function norm(text: string): string {
  return text.trim().toLowerCase();
}

export class DismissedSongs {
  private static instance: DismissedSongs | null = null;

  static getInstance(): DismissedSongs {
    if (DismissedSongs.instance === null) {
      DismissedSongs.instance = new DismissedSongs();
    }
    return DismissedSongs.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 标记过的 key（顺序即标记顺序，超上限从最早的那条开始丢） */
  private keys: string[] = [];
  /** 查表用的集合：名单可能几百条、每张卡每次重画都要查，线性扫太亏 */
  private lookup: Set<string> = new Set<string>();

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        const data: DismissedData = JSON.parse(text) as DismissedData;
        if (data.version === VERSION && data.keys !== undefined) {
          for (const key of data.keys) {
            this.pushKey(key);
          }
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse dismissed songs: %{public}s', JSON.stringify(e));
      }
    }
    hilog.info(DOMAIN, TAG, 'dismissed songs loaded: %{public}d', this.keys.length);
  }

  /**
   * 这首歌的名单 key（歌名 + 歌手）
   *
   * 歌名或歌手为空的条目不进名单：那种 key 会把同歌手的一大批歌一起干掉。
   */
  keyOf(name: string, singer: string): string {
    const n: string = norm(name);
    const s: string = norm(singer);
    if (n.length === 0 || s.length === 0) {
      return '';
    }
    return `${n}|${s}`;
  }

  /** 这首歌是否已被标记为「不感兴趣」 */
  isDismissed(name: string, singer: string): boolean {
    const key: string = this.keyOf(name, singer);
    return key.length > 0 && this.lookup.has(key);
  }

  /** 标记「不感兴趣」（重复标记无副作用） */
  dismiss(name: string, singer: string): boolean {
    const key: string = this.keyOf(name, singer);
    if (key.length === 0 || this.lookup.has(key)) {
      return false;
    }
    this.pushKey(key);
    this.write();
    hilog.info(DOMAIN, TAG, 'dismissed: %{public}s', key);
    return true;
  }

  /** 名单条数（设置页显示 / 日志用） */
  count(): number {
    return this.keys.length;
  }

  /** 清空名单（设置里给一个后悔的出口） */
  clear(): void {
    if (this.keys.length === 0) {
      return;
    }
    this.keys = [];
    this.lookup = new Set<string>();
    this.write();
    hilog.info(DOMAIN, TAG, 'dismissed songs cleared');
  }

  private pushKey(key: string): void {
    if (key.length === 0 || this.lookup.has(key)) {
      return;
    }
    this.keys.push(key);
    this.lookup.add(key);
    while (this.keys.length > MAX_KEYS) {
      const dropped: string | undefined = this.keys.shift();
      if (dropped !== undefined) {
        this.lookup.delete(dropped);
      }
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read dismissed songs: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: DismissedData = { version: VERSION, keys: this.keys };
    try {
      const handle = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write dismissed songs: %{public}s', JSON.stringify(e));
    }
  }
}
