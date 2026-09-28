import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LIST_PLATFORMS } from '../music/MusicList';

const DOMAIN: number = 0x0001;
const TAG: string = 'RecommendSettings';
const FILE_NAME: string = 'recommend_settings.json';
/** 落盘结构变了就 +1，读到不认识的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 推荐设置（首页「推荐」）
 *
 * 目前只有一项：推荐来源（酷我 / 酷狗 / 咪咕 / QQ / 网易云）。
 * 这颗胶囊在标题栏里，改它的是壳层（见 pages/Index.ets 的 sourceMenu），
 * 推荐页订阅同一个值重新取数。以前这个值只写在 AppStorage 里 —— 切页签回来还在，
 * 但**杀进程重进就回到默认的酷我**；落到沙箱之后下次进页面还是上次选的那个来源。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/recommend_settings.json），同时把值写进
 * AppStorage —— 界面用 @StorageLink 订阅即可实时响应，改一次立即落盘（低频操作，
 * 不做节流）。
 */

/** 界面订阅这个 key 就能拿到最新来源（@StorageLink） */
export const K_RECOMMEND_SOURCE: string = 'recommend_source';

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface RecommendSettingsData {
  version?: number;
  source?: string;
}

export class RecommendSettings {
  private static instance: RecommendSettings | null = null;

  static getInstance(): RecommendSettings {
    if (RecommendSettings.instance === null) {
      RecommendSettings.instance = new RecommendSettings();
    }
    return RecommendSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 推荐来源默认酷我，与改动前一致 */
  private source: string = 'kw';

  /**
   * 绑定沙箱目录并读回上次的选择。
   * EntryAbility.onCreate 里调一次，且必须早于界面创建（界面用 @StorageLink 订阅）。
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
        this.apply(JSON.parse(text) as RecommendSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse recommend settings: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'failed to read recommend settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: RecommendSettingsData = {
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
      hilog.warn(DOMAIN, TAG, 'failed to write recommend settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: RecommendSettingsData): void {
    if (data.version !== SETTINGS_VERSION) {
      return;
    }
    const source: string | undefined = data.source;
    if (source !== undefined && LIST_PLATFORMS.includes(source)) {
      this.source = source;
    }
  }

  /** 把内存里的值同步到 AppStorage，界面据此实时刷新 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_RECOMMEND_SOURCE, this.source);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时界面自己会用
      // @StorageLink 的默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish recommend settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  getSource(): string {
    return this.source;
  }

  // ---------------------------------------------------------------- 写入

  /** 切换推荐来源（标题栏那颗来源胶囊点选时调），改完落盘、下次进页面还是它 */
  setSource(value: string): void {
    if (!LIST_PLATFORMS.includes(value) || value === this.source) {
      return;
    }
    this.source = value;
    AppStorage.setOrCreate(K_RECOMMEND_SOURCE, value);
    this.write();
  }
}
