import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenSettings';
const FILE_NAME: string = 'listen_settings.json';
/** 落盘结构变了就 +1，读到更新的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 听书设置（设置 - 听书）
 *
 * 目前只有一项：**隐藏「听书」页签**。听书（书架 / 搜索 / 书源）单独占底部导航栏的一栏
 * （见 pages/Index.ets 的 TABS），不看书的人可以让那一栏让位，关掉就回来。
 *
 * 为什么这一项落在设置里、而不是听书页自己身上：页签一藏，听书页就没有入口了 ——
 * 开关必须留在进得去的地方（我的 → 设置 → 听书），否则等于把用户锁在外面。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/listen_settings.json），同时把值写进
 * AppStorage —— 壳层用 @StorageLink 订阅，改完立刻生效，重启不丢。
 */

/** 界面订阅这个 key 就能拿到最新值（@StorageLink） */
export const K_HIDE_LISTEN_TAB: string = 'cfg_hide_listen_tab';

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface ListenSettingsData {
  version?: number;
  hideTab?: boolean;
}

export class ListenSettings {
  private static instance: ListenSettings | null = null;

  static getInstance(): ListenSettings {
    if (ListenSettings.instance === null) {
      ListenSettings.instance = new ListenSettings();
    }
    return ListenSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 默认显示「听书」页签，与改动前一致 */
  private hideTab: boolean = false;

  /**
   * 绑定沙箱目录并读回上次的选择。
   * EntryAbility.onCreate 里调一次，且必须早于界面创建（壳层用 @StorageLink 订阅）。
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
        this.apply(JSON.parse(text) as ListenSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse listen settings: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'failed to read listen settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: ListenSettingsData = {
      version: SETTINGS_VERSION,
      hideTab: this.hideTab,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write listen settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: ListenSettingsData): void {
    const version: number = data.version === undefined ? 0 : data.version;
    if (version > SETTINGS_VERSION) {
      // 比本版更新：字段含义可能已经变了，整份按默认处理
      return;
    }
    if (data.hideTab !== undefined) {
      this.hideTab = data.hideTab;
    }
  }

  /** 把内存里的值同步到 AppStorage，壳层据此重排页签 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_HIDE_LISTEN_TAB, this.hideTab);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时壳层会用 @StorageLink 的
      // 默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish listen settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  isHideTab(): boolean {
    return this.hideTab;
  }

  // ---------------------------------------------------------------- 写入

  /** 隐藏 / 显示「听书」页签（设置页那一项），改完落盘，下次进来还是它 */
  setHideTab(value: boolean): void {
    if (value === this.hideTab) {
      return;
    }
    this.hideTab = value;
    AppStorage.setOrCreate(K_HIDE_LISTEN_TAB, value);
    this.write();
  }
}
