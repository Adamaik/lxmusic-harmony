import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'RecognizeSettings';
const FILE_NAME: string = 'recognize_settings.json';
/** 落盘结构变了就 +1，读到更新的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/** 界面订阅这个 key 就能拿到最新值（@StorageLink） */
export const K_RECOGNIZE_SOURCE: string = 'cfg_recognize_source';
/** 采集来源：外界录音 —— 用麦克风录周围的声音（线上听音箱外放） */
export const RECOGNIZE_SOURCE_MIC: string = 'mic';
/** 采集来源：媒体录音 —— 内录本机正在播放的声音（抖音 / 视频号在放什么就抓什么） */
export const RECOGNIZE_SOURCE_PLAYBACK: string = 'playback';

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface RecognizeSettingsData {
  version?: number;
  source?: string;
}

/**
 * 听歌识曲设置（识别页上的那一项）
 *
 * 只有一项：**采集来源** —— 用麦克风录周围的声音，还是内录本机正在播放的声音。
 *
 * 为什么不做成「本机有内录能力就直接用内录」的自动行为：抓本机播放的声音是隐私上更重
 * 的一档，得由用户自己明确选一次；所以默认是外界录音（麦克风），用户在识别页上切到
 * 「本机播放」之后才走内录，而且这一档会被记住，下次进来还是它。
 *
 * 开关为什么摆在识别页而不是设置页：这是「这一次要抓什么」的选择，跟着使用现场走最短，
 * 塞进设置页反而要退出去找。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/recognize_settings.json），同时把值写进
 * AppStorage —— 识别页用 @StorageLink 订阅它发布的值，切完立刻生效，重启不丢。
 */
export class RecognizeSettings {
  private static instance: RecognizeSettings | null = null;

  static getInstance(): RecognizeSettings {
    if (RecognizeSettings.instance === null) {
      RecognizeSettings.instance = new RecognizeSettings();
    }
    return RecognizeSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  /** 默认外界录音：用户没表过态之前不去抓本机播放的媒体音频 */
  private source: string = RECOGNIZE_SOURCE_MIC;

  /**
   * 绑定沙箱目录并读回上次的选择。
   * EntryAbility.onCreate 里调一次，且必须早于界面创建（识别页用 @StorageLink 订阅）。
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
        this.apply(JSON.parse(text) as RecognizeSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse recognize settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read recognize settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: RecognizeSettingsData = {
      version: SETTINGS_VERSION,
      source: this.source,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write recognize settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: RecognizeSettingsData): void {
    const version: number = data.version === undefined ? 0 : data.version;
    if (version > SETTINGS_VERSION) {
      // 比本版更新：字段含义可能已经变了，整份按默认处理
      return;
    }
    // 只认认得出的两个值：存档被改坏 / 来自更新的版本时留在默认档
    if (data.source === RECOGNIZE_SOURCE_MIC || data.source === RECOGNIZE_SOURCE_PLAYBACK) {
      this.source = data.source;
    }
  }

  /** 把内存里的值同步到 AppStorage，识别页据此画选中档 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_RECOGNIZE_SOURCE, this.source);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时识别页会用 @StorageLink 的
      // 默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish recognize settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  /** 当前采集来源（RECOGNIZE_SOURCE_MIC / RECOGNIZE_SOURCE_PLAYBACK） */
  getSource(): string {
    return this.source;
  }

  // ---------------------------------------------------------------- 写入

  /** 切换采集来源（识别页上那个开关），改完落盘，下次进来还是它 */
  setSource(value: string): void {
    if (value === this.source) {
      return;
    }
    if (value !== RECOGNIZE_SOURCE_MIC && value !== RECOGNIZE_SOURCE_PLAYBACK) {
      return;
    }
    this.source = value;
    AppStorage.setOrCreate(K_RECOGNIZE_SOURCE, value);
    this.write();
  }
}
