import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookPlaySettings';
const FILE_NAME: string = 'book_play_settings.json';
/** 落盘结构变了就 +1，读到更新的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/** 界面订阅这三个 key（@StorageLink）就能拿到最新值 */
export const K_BOOK_SPEED: string = 'cfg_book_speed';
export const K_BOOK_SKIP_INTRO: string = 'cfg_book_skip_intro_sec';
export const K_BOOK_SKIP_OUTRO: string = 'cfg_book_skip_outro_sec';

/**
 * 可选的倍速档位
 *
 * 这几档不是随便挑的：AVPlayer 只认 `media.PlaybackSpeed` 这个枚举，而它里面正好有
 * 0.50 / 0.75 / 1.00 / 1.25 / 1.50 / 2.00 六档（0.50 与 1.50 是 API 12 才补上的，
 * 本工程 compatibleSdkVersion 是 6.1.0(23)，都在）。
 * 想加 1.75x 也可以 —— 枚举里有 —— 但听书用 1.75 的体感很怪，先不给。
 */
export const BOOK_SPEED_CHOICES: number[] = [0.5, 0.75, 1, 1.25, 1.5, 2];

/** 片头 / 片尾跳过秒数的上限：再长就不是「跳过片头」而是「跳过正文」了 */
export const BOOK_SKIP_MAX_SEC: number = 600;

/** 倍速的显示文案：1 -> 1.0x、1.25 -> 1.25x、0.5 -> 0.5x */
export function bookSpeedText(rate: number): string {
  let text: string = rate.toFixed(2);
  while (text.endsWith('0') && text.indexOf('.') >= 0) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) {
    text = `${text}0`;
  }
  return `${text}x`;
}

/** 把任意读数夹到「最接近的一个合法档位」（老版本存了别的值也不会让播放器报参数错） */
function nearestSpeed(value: number): number {
  if (!Number.isFinite(value)) {
    return 1;
  }
  let best: number = BOOK_SPEED_CHOICES[0];
  let bestDiff: number = Math.abs(value - best);
  for (const choice of BOOK_SPEED_CHOICES) {
    const diff: number = Math.abs(value - choice);
    if (diff < bestDiff) {
      best = choice;
      bestDiff = diff;
    }
  }
  return best;
}

/** 秒数：取整、夹到 [0, BOOK_SKIP_MAX_SEC] */
function clampSeconds(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }
  const whole: number = Math.floor(value);
  return whole > BOOK_SKIP_MAX_SEC ? BOOK_SKIP_MAX_SEC : whole;
}

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface BookPlaySettingsData {
  version?: number;
  speed?: number;
  skipIntroSec?: number;
  skipOutroSec?: number;
}

/**
 * 听书播放设置：倍速 + 跳过片头 / 片尾
 *
 * 群反馈（2026-11-22 10:46，邦邦不吃香菜）：「听书那边能出一个倍速和跳过片头片尾嘛」
 * 「就是加一个片头片尾跳过多少秒就行啦」。所以这里是**听书专用**的一份设置，
 * 与音乐播放完全分开：音乐不该因为听书设了 2 倍速而跟着变快。
 *
 * 存法照 ListenSettings / BookShelf 那一套：一份 JSON 落在应用沙箱
 * （filesDir/book_play_settings.json），同时把值写进 AppStorage —— 界面用 @StorageLink
 * 订阅，改完立刻生效，重启不丢。
 *
 * 谁来 init：`BookEngine.prepare()`（应用启动时由 BookSandboxHost 调）。没 init 时
 * 读到的都是默认值（1.0x / 0 秒），写入只更新内存与 AppStorage、不落盘（与 ListenSettings 一致）。
 */
export class BookPlaySettings {
  private static instance: BookPlaySettings | null = null;

  static getInstance(): BookPlaySettings {
    if (BookPlaySettings.instance === null) {
      BookPlaySettings.instance = new BookPlaySettings();
    }
    return BookPlaySettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 默认原速：与改动前一致（听书一直只有 1.0x） */
  private speed: number = 1;
  /** 默认 0 = 不启用「跳过片头」 */
  private skipIntroSec: number = 0;
  /** 默认 0 = 不启用「跳过片尾」 */
  private skipOutroSec: number = 0;

  /**
   * 绑定沙箱目录并读回上次的设置。
   * 由 BookEngine.prepare 在应用启动时调一次（早于任何听书界面）。
   */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as BookPlaySettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse book play settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  isInited(): boolean {
    return this.inited;
  }

  private read(): string {
    if (this.file.length === 0) {
      return '';
    }
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read book play settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited || this.file.length === 0) {
      return;
    }
    const data: BookPlaySettingsData = {
      version: SETTINGS_VERSION,
      speed: this.speed,
      skipIntroSec: this.skipIntroSec,
      skipOutroSec: this.skipOutroSec,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write book play settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: BookPlaySettingsData): void {
    const version: number = data.version === undefined ? 0 : data.version;
    if (version > SETTINGS_VERSION) {
      // 比本版更新：字段含义可能已经变了，整份按默认处理
      return;
    }
    if (data.speed !== undefined) {
      this.speed = nearestSpeed(data.speed);
    }
    if (data.skipIntroSec !== undefined) {
      this.skipIntroSec = clampSeconds(data.skipIntroSec);
    }
    if (data.skipOutroSec !== undefined) {
      this.skipOutroSec = clampSeconds(data.skipOutroSec);
    }
  }

  /** 把内存里的值同步到 AppStorage，界面据此刷新 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_BOOK_SPEED, this.speed);
      AppStorage.setOrCreate(K_BOOK_SKIP_INTRO, this.skipIntroSec);
      AppStorage.setOrCreate(K_BOOK_SKIP_OUTRO, this.skipOutroSec);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时界面会用 @StorageLink 的
      // 默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish book play settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 倍速

  /** 当前倍速（1 = 原速） */
  getSpeed(): number {
    return this.speed;
  }

  /** 设倍速：夹到合法档位、落盘、通知界面（真正作用到播放器见 PlaySession.setBookPlaybackSpeed） */
  setSpeed(rate: number): void {
    const value: number = nearestSpeed(rate);
    if (value === this.speed) {
      return;
    }
    this.speed = value;
    AppStorage.setOrCreate(K_BOOK_SPEED, value);
    this.write();
  }

  // ---------------------------------------------------------------- 跳过片头 / 片尾

  /** 片头跳过秒数（0 = 不启用） */
  getSkipIntroSec(): number {
    return this.skipIntroSec;
  }

  setSkipIntroSec(seconds: number): void {
    const value: number = clampSeconds(seconds);
    if (value === this.skipIntroSec) {
      return;
    }
    this.skipIntroSec = value;
    AppStorage.setOrCreate(K_BOOK_SKIP_INTRO, value);
    this.write();
  }

  /** 片尾跳过秒数（0 = 不启用） */
  getSkipOutroSec(): number {
    return this.skipOutroSec;
  }

  setSkipOutroSec(seconds: number): void {
    const value: number = clampSeconds(seconds);
    if (value === this.skipOutroSec) {
      return;
    }
    this.skipOutroSec = value;
    AppStorage.setOrCreate(K_BOOK_SKIP_OUTRO, value);
    this.write();
  }
}
