import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { clampMaterialLevel } from '../../ui/Hds';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppearanceSettings';
const FILE_NAME: string = 'appearance_settings.json';
/** 落盘结构变了就 +1，读到不认识的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 外观设置（设置 - 外观）
 *
 * 对应界面上这几项：
 *   玻璃材质档位（跟随系统 / 弱 / 均衡 / 强）
 *   首页流光（HDS 背景流光）
 *   播放页封面圆角
 *
 * 深浅模式**没有**放进来：那要先把全部颜色迁到资源（resources/base 与 resources/dark
 * 下的同名 token），而现在自绘界面用的是 Theme.ets 里的常量，只切系统模式会出现
 * 「浅色界面 + 深色系统栏」的四不像。宁可先不给这个开关，也不给一个点着没用的。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/appearance_settings.json），同时把每个值写进
 * AppStorage —— 界面用 @StorageLink 订阅即可实时响应，改完立即落盘。
 *
 * 为什么要有「档位」这一项：HDS 的系统材质有弱/均衡/强三档（SMOOTH / GENTLE /
 * EXQUISITE），另外还有「跟随系统」的自适应档（ADAPTIVE）。系统默认是自适应，
 * 但自适应在不同机型上表现差别很大（有的机型为了省电把玻璃压得很淡，
 * 看上去就像没生效），所以把选择权交给用户，标题栏、底部页签栏、半模态三处
 * 一起跟着变（见 ui/Hds.ets 的 buildTitleMaterial）。
 */

/** 界面订阅这些 key 就能拿到最新设置（@StorageLink） */
export const K_MATERIAL_LEVEL: string = 'cfg_material_level';
export const K_FLOW_LIGHT: string = 'cfg_flow_light';
export const K_COVER_RADIUS: string = 'cfg_cover_radius';

/** 播放页封面圆角范围（vp）与默认值 */
export const COVER_RADIUS_MIN: number = 0;
export const COVER_RADIUS_MAX: number = 40;
export const COVER_RADIUS_DEFAULT: number = 12;

function clampCoverRadius(value: number): number {
  if (Number.isNaN(value)) {
    return COVER_RADIUS_DEFAULT;
  }
  if (value < COVER_RADIUS_MIN) {
    return COVER_RADIUS_MIN;
  }
  if (value > COVER_RADIUS_MAX) {
    return COVER_RADIUS_MAX;
  }
  return Math.round(value);
}

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface AppearanceSettingsData {
  version?: number;
  materialLevel?: number;
  flowLight?: boolean;
  coverRadius?: number;
}

export class AppearanceSettings {
  private static instance: AppearanceSettings | null = null;

  static getInstance(): AppearanceSettings {
    if (AppearanceSettings.instance === null) {
      AppearanceSettings.instance = new AppearanceSettings();
    }
    return AppearanceSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 材质档位默认「跟随系统」：不替用户拍板，想更厚自己去外观页调 */
  private materialLevel: number = 0;
  /**
   * 首页流光默认开：这是 HDS 的常驻背景视效，慢速（10 秒一圈）、半透明，
   * 不影响文字对比度；不看光效的用户可以在外观页关掉（关掉就不挂这一层，
   * 省一份着色器开销）。
   */
  private flowLight: boolean = true;
  /** 播放页封面圆角：默认 12，与改动前一致；0 是直角，40 接近圆形 */
  private coverRadius: number = COVER_RADIUS_DEFAULT;

  /**
   * 绑定沙箱目录并读回上次的设置。
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
        this.apply(JSON.parse(text) as AppearanceSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse appearance settings: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'failed to read appearance settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: AppearanceSettingsData = {
      version: SETTINGS_VERSION,
      materialLevel: this.materialLevel,
      flowLight: this.flowLight,
      coverRadius: this.coverRadius,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write appearance settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: AppearanceSettingsData): void {
    if (data.version !== SETTINGS_VERSION) {
      return;
    }
    const level: number | undefined = data.materialLevel;
    if (level !== undefined) {
      this.materialLevel = clampMaterialLevel(level);
    }
    if (data.flowLight !== undefined) {
      this.flowLight = data.flowLight;
    }
    const radius: number | undefined = data.coverRadius;
    if (radius !== undefined) {
      this.coverRadius = clampCoverRadius(radius);
    }
  }

  /** 把内存里的值同步到 AppStorage，界面据此实时刷新 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_MATERIAL_LEVEL, this.materialLevel);
      AppStorage.setOrCreate(K_FLOW_LIGHT, this.flowLight);
      AppStorage.setOrCreate(K_COVER_RADIUS, this.coverRadius);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；万一环境不支持也不能让启动挂掉，
      // 界面自己会用 @StorageLink 的默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish appearance settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  getMaterialLevel(): number {
    return this.materialLevel;
  }

  isFlowLight(): boolean {
    return this.flowLight;
  }

  getCoverRadius(): number {
    return this.coverRadius;
  }

  // ---------------------------------------------------------------- 写入

  setMaterialLevel(value: number): void {
    const next: number = clampMaterialLevel(value);
    if (next === this.materialLevel) {
      return;
    }
    this.materialLevel = next;
    AppStorage.setOrCreate(K_MATERIAL_LEVEL, next);
    this.write();
  }

  setFlowLight(value: boolean): void {
    if (value === this.flowLight) {
      return;
    }
    this.flowLight = value;
    AppStorage.setOrCreate(K_FLOW_LIGHT, value);
    this.write();
  }

  /**
   * 拖圆角滑块时每一格都会调进来：先只更新 AppStorage（播放页封面立刻跟着变），
   * 松手（persist = true）才落盘，避免一次拖动写十几个文件。
   */
  setCoverRadius(value: number, persist: boolean = true): void {
    const next: number = clampCoverRadius(value);
    if (next === this.coverRadius) {
      return;
    }
    this.coverRadius = next;
    AppStorage.setOrCreate(K_COVER_RADIUS, next);
    if (persist) {
      this.write();
    }
  }
}
