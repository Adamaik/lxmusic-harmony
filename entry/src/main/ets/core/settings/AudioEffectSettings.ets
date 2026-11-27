import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'AudioEffectSettings';
const FILE_NAME: string = 'audio_effect_settings.json';

/**
 * 音效设置（设置页独立一行「音效设置」，页面见 views/EqSettingsView.ets）
 *
 * 走的是「解码 -> AudioSuite 10 段 EQ -> 重新封装 WAV -> 交给 AVPlayer」这条链路，
 * 所以默认关闭：开着的时候每首要多一次解码+EQ，起播会多等 0.3~0.5 秒。
 * 用户没主动打开时，播放链路和以前完全一样，零开销。
 *
 * EQ 是**烘焙**进 WAV 的，所以改设置不会影响正在响的那一份：配置一变就通知播放侧
 * 从头重播当前曲目（见 EqChangeListener / PlaySession.requestEqReplay）。
 *
 * 存法与 PlaySettings 一致：一份 JSON 落在沙箱，同时把值写进 AppStorage，
 * 界面用 @StorageLink 订阅，播放器侧直接读本单例。改动立即落盘。
 */

/** 10 段中心频率，与 AudioSuite EQUALIZER_BAND_NUM=10 一一对应 */
export const EQ_BANDS: number[] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
export const EQ_BAND_LABELS: string[] = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
/**
 * 单段增益范围（dB）
 *
 * **必须落在 -10 ~ +10**：AudioSuite 的 EQ 只接受这个区间，越界时
 * `OH_AudioSuiteEngine_SetEqualizerFrequencyBandGains` 直接返回失败
 * （真机日志：`input value -15 not in -10, 10`），并且节点会停在一个半初始化状态，
 * 紧接着 StartPipeline 就崩在 libaudio_suite 的 ObtainProcessedData 里
 * （SIGSEGV@0x40）—— 这正是「把 500 段拉到 -15 就闪退」的原因。
 *
 * 所以界面不许给到 ±15：调不到的声音没法让人听到，只会换来一次崩溃。
 */
export const EQ_GAIN_MIN: number = -10;
export const EQ_GAIN_MAX: number = 10;

// ---------------------------------------------------------------------------
// 空间音效（平台现成的 3 个 AudioSuite 节点）
//
// 这三项和 EQ 一样是「烘焙」进 WAV 的，所以共用同一条离线处理管线：
//   INPUT -> EQUALIZER -> SOUND_FIELD -> ENVIRONMENT -> SPACE_RENDER -> OUTPUT
// 四个节点在 SDK 里的输出格式都是 48kHz / S16LE / 2ch，可以直接串。
//
// 值全部对应 native_audio_suite_base.h 的枚举，0 一律表示「不建这个节点」。
// ---------------------------------------------------------------------------

/** 声场类型：OH_SoundFieldType（1 前置 / 2 宏大 / 3 近场 / 4 宽广） */
export const SOUND_FIELD_LABELS: string[] = ['关闭', '前置', '宏大', '近场', '宽广'];
/** 环境音类型：OH_EnvironmentType（1 广播 / 2 听筒 / 3 水下 / 4 留声机） */
export const ENVIRONMENT_LABELS: string[] = ['关闭', '广播', '听筒', '水下', '留声机'];
/** 空间渲染模式：0 关 / 1 静态定位 / 2 环绕旋转 / 3 扩散 */
export const SPACE_MODE_LABELS: string[] = ['关闭', '定位', '环绕', '扩散'];

/** 位置坐标合法范围，单位米。越界时 setter 返回 INVALID_PARAM 且节点半初始化 */
export const SPACE_XYZ_MIN: number = -5;
export const SPACE_XYZ_MAX: number = 5;
/** 环绕一周的秒数 [2, 40] */
export const SURROUND_TIME_MIN: number = 2;
export const SURROUND_TIME_MAX: number = 40;
/** 扩散半径 [1.0, 5.0] 米 */
export const EXT_RADIUS_MIN: number = 1;
export const EXT_RADIUS_MAX: number = 5;
/** 扩散角度 (0, 360) 度，开区间 */
export const EXT_ANGLE_MIN: number = 1;
export const EXT_ANGLE_MAX: number = 359;

/** 空间音效的全部可调值。UI 通过 @StorageLink(K_FX_STATE) 订阅这一整个对象 */
export interface SpaceFxState {
  soundField: number;
  environment: number;
  spaceMode: number;
  posX: number;
  posY: number;
  posZ: number;
  surroundTime: number;
  surroundDir: number;
  extRadius: number;
  extAngle: number;
}

/** 传给 Native 的扁平参数，索引含义见 toNativeArray / napi_init.cpp 的 FxConfig */
export const FX_PARAM_COUNT: number = 10;

/** 空间音效的默认状态（界面 @StorageLink 的初始值也用它） */
export function defaultFx(): SpaceFxState {
  return {
    soundField: 0,
    environment: 0,
    spaceMode: 0,
    posX: 0,
    posY: 0,
    posZ: 2,
    surroundTime: 10,
    surroundDir: 1,
    extRadius: 3,
    extAngle: 90,
  };
}

/**
 * 内置预设，数值来自 HarmonyOS AudioSuite 官方常量（native_audio_suite_base.h），
 * 顺序与 EQ_BANDS 一致（31/62/125/250/500/1k/2k/4k/8k/16k Hz）。
 */
export interface EqPreset {
  key: string;
  label: string;
  gains: number[];
}
export const EQ_PRESETS: EqPreset[] = [
  // key 仍是 off（增益全 0 = 不做任何处理），标签写「原声」：
  // 它旁边就是总开关，再叫「关闭音效」会让人以为点它会关掉整个音效
  { key: 'off', label: '原声', gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
  { key: 'pop', label: '流行', gains: [5, 2, 1, -1, -5, -5, -2, 1, 2, 4] },
  { key: 'classical', label: '古典', gains: [2, 3, 2, 1, 0, 0, -5, -5, -5, -6] },
  { key: 'rock', label: '摇滚', gains: [6, 4, 4, 2, 0, 1, 3, 3, 5, 4] },
  { key: 'jazz', label: '爵士', gains: [2, 0, 2, 3, 6, 5, -1, 3, 4, 4] },
  { key: 'ballads', label: '民谣', gains: [3, 5, 2, -4, 1, 2, -3, 1, 4, 5] },
  { key: 'rb', label: 'R&B', gains: [1, 4, 5, 3, -2, -2, 2, 3, 5, 5] },
  { key: 'dance', label: '电子', gains: [4, 3, 2, -3, 0, 0, 5, 4, 2, 0] },
  { key: 'chinese', label: '中国风', gains: [0, 0, 2, 0, 0, 4, 4, 2, 2, 5] },
];

/** 界面订阅这些 key 就能拿到最新设置（@StorageLink） */
export const K_EQ_ENABLED: string = 'cfg_eq_enabled';
export const K_EQ_PRESET: string = 'cfg_eq_preset';
/**
 * 这一趟播放**实际**有没有过上音效（true = 现在听到的就是过了 EQ 的声音）
 *
 * 与 K_EQ_ENABLED 是两件事：开关开着但这一首走了回退（格式不支持、带请求头的长音频
 * 没在预缓冲窗口内下完…）时，音效并没有生效。播放页那颗标识要能区分这两种状态，
 * 否则用户看到「EQ · 流行」却听不出区别，只会怀疑音效坏了。
 */
export const K_EQ_ACTIVE: string = 'cfg_eq_active';
export const K_EQ_GAINS: string = 'cfg_eq_gains';
/**
 * 「调过但还没点应用」：true = 推子上的值和正在听的那一份不一样
 *
 * 为什么要有这个键：手动调 10 段推子是**两段式**的——拖动只改界面（并随时落盘，
 * 免得退出丢设置），真正的「重新处理当前这首」由右上角「应用」触发（见 applyGains）。
 * 页面上的应用按钮据此显示「应用 / 已应用」，用户才不会以为拖完就已经生效了。
 */
export const K_EQ_DIRTY: string = 'cfg_eq_dirty';
/** 空间音效（声场 / 环境音 / 空间渲染）的整体状态，界面订阅它 */
export const K_FX_STATE: string = 'cfg_fx_state';

/**
 * 音效配置变更回调。
 *
 * 为什么需要它：EQ 是在**起播前**烘焙进 WAV 的（AVPlayer 不收 PCM，见 AudioEffectProcessor），
 * 改增益对已经在响的那一份无效。播放侧订阅这个回调，改完就从头重播一次，
 * 用户才听得到差别（见 PlaySession.requestEqReplay）。
 *
 * reason 只是个便于打日志/决定要不要提示的标签：enabled / preset / band / reset。
 */
export type EqChangeListener = (reason: string) => void;

interface AudioEffectData {
  version: number;
  enabled: boolean;
  preset: string;
  gains: number[];
  /** v2 新增；老配置文件里没有这个字段，读进来按全关处理 */
  fx?: SpaceFxState;
}

/** v1 只有 EQ；v2 追加空间音效。读到更高版本直接忽略，避免未来格式被旧代码写坏 */
const SETTINGS_VERSION: number = 2;

function defaultGains(): number[] {
  return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
}

export class AudioEffectSettings {
  private static instance: AudioEffectSettings = new AudioEffectSettings();
  static getInstance(): AudioEffectSettings {
    return AudioEffectSettings.instance;
  }

  private inited: boolean = false;
  private file: string = '';
  private enabled: boolean = false;
  private preset: string = 'off';
  private gains: number[] = defaultGains();
  /** 空间音效状态（声场 / 环境音 / 空间渲染） */
  private fx: SpaceFxState = defaultFx();
  /**
   * 上一次「应用」时的增益快照
   *
   * dirty 不是「有没有拖过」，而是「现在的值和已经生效的那一份是否不同」：
   * 拖出去再拖回原位，应该重新变回「已应用」，而不是一直挂着待应用的记号。
   */
  private appliedGains: number[] = defaultGains();
  /** 配置变更订阅者（播放侧注册，用来「切完就重播」） */
  private listeners: EqChangeListener[] = [];

  /**
   * 订阅配置变更；注册即 append，**不做去重**。
   *
   * 当前只有 PlaySession 在 init() 里注册一次（那里的 stateInited 守卫保证只执行一次），
   * 所以不会叠加；将来若新增调用方，别在同一生命周期里重复注册（每条通知都会被调用一次）。
   */
  onChanged(listener: EqChangeListener): void {
    this.listeners.push(listener);
  }

  private notifyChanged(reason: string): void {
    for (const listener of this.listeners) {
      try {
        listener(reason);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'eq change listener failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  /** EntryAbility.onCreate 里调一次，且必须早于界面创建 */
  init(context: common.Context): void {
    if (this.inited) return;
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as AudioEffectData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse audio effect settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) return '';
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read audio effect settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private apply(data: AudioEffectData): void {
    if (!data || data.version > SETTINGS_VERSION) return;
    if (typeof data.enabled === 'boolean') this.enabled = data.enabled;
    if (typeof data.preset === 'string') this.preset = data.preset;
    if (Array.isArray(data.gains) && data.gains.length === 10) {
      this.gains = data.gains.map((v: number) => this.clampGain(v));
    }
    if (data.fx !== undefined && data.fx !== null) {
      this.fx = this.sanitizeFx(data.fx);
    }
    // 读进来的配置就是「已经生效的那一份」：下次起播就用它，不该显示成待应用
    this.appliedGains = this.gains.slice();
  }

  /**
   * 把任意来源（旧配置、手工改坏的 JSON、UI 传来的滑块值）的空间参数夹到 SDK 的合法区间。
   *
   * 这不是防御性编程的仪式：SpaceRender 的 setter 对越界值返回失败后节点会停在半初始化
   * 状态，StartPipeline 随后在系统库里空指针崩溃 —— 和 EQ 增益 -15 那次是同一类问题。
   * Native 侧还会再夹一次，这里是第一道。
   */
  private clampFxNum(v: number, fallback: number, min: number, max: number): number {
    if (typeof v !== 'number' || !Number.isFinite(v)) return fallback;
    return Math.max(min, Math.min(max, v));
  }

  private sanitizeFx(raw: SpaceFxState): SpaceFxState {
    const d: SpaceFxState = defaultFx();
    d.soundField = Math.round(this.clampFxNum(raw.soundField, 0, 0, 4));
    d.environment = Math.round(this.clampFxNum(raw.environment, 0, 0, 4));
    d.spaceMode = Math.round(this.clampFxNum(raw.spaceMode, 0, 0, 3));
    d.posX = this.clampFxNum(raw.posX, 0, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
    d.posY = this.clampFxNum(raw.posY, 0, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
    d.posZ = this.clampFxNum(raw.posZ, 2, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
    d.surroundTime = Math.round(this.clampFxNum(raw.surroundTime, 10, SURROUND_TIME_MIN, SURROUND_TIME_MAX));
    d.surroundDir = Math.round(this.clampFxNum(raw.surroundDir, 1, 0, 1));
    d.extRadius = this.clampFxNum(raw.extRadius, 3, EXT_RADIUS_MIN, EXT_RADIUS_MAX);
    d.extAngle = Math.round(this.clampFxNum(raw.extAngle, 90, EXT_ANGLE_MIN, EXT_ANGLE_MAX));
    return d;
  }

  private clampGain(v: number): number {
    if (!Number.isFinite(v)) return 0;
    return Math.max(EQ_GAIN_MIN, Math.min(EQ_GAIN_MAX, Math.round(v)));
  }

  private write(): void {
    if (!this.inited) return;
    const data: AudioEffectData = {
      version: SETTINGS_VERSION,
      enabled: this.enabled,
      preset: this.preset,
      gains: this.gains.slice(),
      fx: this.getFx(),
    };
    try {
      const file: fs.File = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write audio effect settings: %{public}s', JSON.stringify(e));
    }
  }

  private publish(): void {
    AppStorage.setOrCreate(K_EQ_ENABLED, this.enabled);
    AppStorage.setOrCreate(K_EQ_PRESET, this.preset);
    AppStorage.setOrCreate(K_EQ_GAINS, this.gains.slice());
    AppStorage.setOrCreate(K_EQ_DIRTY, this.isDirty());
    AppStorage.setOrCreate(K_FX_STATE, this.getFx());
    // 「这一趟到底有没有过上音效」是播放器写的（见 LxPlayer.markEqApplied）；
    // 这里只保证键存在，免得播放页 @StorageLink 拿到 undefined。
    if (AppStorage.get<boolean>(K_EQ_ACTIVE) === undefined) {
      AppStorage.setOrCreate(K_EQ_ACTIVE, false);
    }
  }

  /** 推子上的值和「已经生效的那一份」是否不同 */
  private isDirty(): boolean {
    if (this.gains.length !== this.appliedGains.length) return true;
    for (let i = 0; i < this.gains.length; i++) {
      if (this.gains[i] !== this.appliedGains[i]) return true;
    }
    return false;
  }

  private publishGains(): void {
    AppStorage.setOrCreate(K_EQ_PRESET, this.preset);
    AppStorage.setOrCreate(K_EQ_GAINS, this.gains.slice());
    AppStorage.setOrCreate(K_EQ_DIRTY, this.isDirty());
  }

  // ---------------- 读 ----------------

  isEnabled(): boolean {
    return this.enabled;
  }

  getPreset(): string {
    return this.preset;
  }

  /** 返回副本，避免调用方改到内部数组 */
  getGains(): number[] {
    return this.gains.slice();
  }

  /** 返回副本，避免调用方改到内部状态 */
  getFx(): SpaceFxState {
    return {
      soundField: this.fx.soundField,
      environment: this.fx.environment,
      spaceMode: this.fx.spaceMode,
      posX: this.fx.posX,
      posY: this.fx.posY,
      posZ: this.fx.posZ,
      surroundTime: this.fx.surroundTime,
      surroundDir: this.fx.surroundDir,
      extRadius: this.fx.extRadius,
      extAngle: this.fx.extAngle,
    };
  }

  /** 有没有开任意一个空间模块（EQ 全 0 时也要靠它决定要不要进管线） */
  hasSpaceFx(): boolean {
    return this.fx.soundField !== 0 || this.fx.environment !== 0 || this.fx.spaceMode !== 0;
  }

  /**
   * 交给 Native 的扁平参数数组。
   * 用定长 number[] 而不是对象，是为了让 NAPI 侧和 gains 一样走同一套数组解析。
   * 顺序必须与 napi_init.cpp 的 readFxArg / eq_pipeline.h 的 FxConfig 一致。
   */
  toNativeArray(): number[] {
    const f: SpaceFxState = this.fx;
    return [
      f.soundField, f.environment, f.spaceMode,
      f.posX, f.posY, f.posZ,
      f.surroundTime, f.surroundDir,
      f.extRadius, f.extAngle,
    ];
  }

  /** 播放侧用它做「配置有没有真的变」的指纹（见 PlaySession.requestEqReplay） */
  effectSignature(): string {
    return `${this.enabled ? 1 : 0}|${this.gains.join(',')}|${this.toNativeArray().join(',')}`;
  }

  /**
   * 当前是否真的要走离线处理管线。
   *
   * 以前只判「EQ 增益非全 0」—— 只开空间模块、EQ 停在原声时会直接返回 false，
   * 整条管线都不进，空间效果自然一点声音都没有。这里必须把三项一起算上。
   */
  shouldProcess(): boolean {
    if (!this.enabled) return false;
    return this.gains.some((g: number) => g !== 0) || this.hasSpaceFx();
  }

  private publishFx(): void {
    AppStorage.setOrCreate(K_FX_STATE, this.getFx());
  }

  // ---------------- 写 ----------------

  setEnabled(on: boolean): void {
    if (this.enabled === on) return;
    this.enabled = on;
    this.write();
    AppStorage.setOrCreate(K_EQ_ENABLED, on);
    this.notifyChanged('enabled');
  }

  /** 选预设：把预设增益同步到当前值，**立即生效**（和以前一样重播一次） */
  selectPreset(key: string): void {
    const p: EqPreset | undefined = EQ_PRESETS.find((x: EqPreset) => x.key === key);
    if (!p) return;
    this.preset = key;
    this.gains = p.gains.slice();
    this.appliedGains = this.gains.slice();
    this.write();
    this.publishGains();
    this.notifyChanged('preset');
  }

  /**
   * 应用一组自定义增益（来自用户保存 / 导入的预设）：**立即生效**
   *
   * 与 selectPreset 走同一条路 —— 改完就通知播放侧从头重播当前曲目，用户才听得到差别。
   * 与 applySynced（同步恢复）的区别：那是「无声」的恢复，不能打断正在播的歌；这里是
   * 用户主动点的，所以照常 notifyChanged('preset')。
   *
   * 校验与规范化：必须正好 10 段（与 EQ_BANDS 对齐），少一段 / 多一段整条忽略（不猜半套曲线）；
   * 单段按 clampGain 收敛到 [-10, 10] 并取整。preset 名**由增益反推**而不是由调用方给：
   * 与某套内置预设完全一致就用那套的 key（含全 0 = off「原声」），否则 'custom' —— 保证
   * 「preset 名与 gains 自洽」这个不变量，播放页标识才不会写「原声」而实际走了 EQ。
   * enabled 不动：应用一套预设不等于打开音效开关（开关关着时它只生效为设置）。
   */
  selectCustomGains(gains: number[]): void {
    if (!Array.isArray(gains) || gains.length !== EQ_BANDS.length) {
      hilog.warn(DOMAIN, TAG, 'selectCustomGains ignored: gains must have %{public}d bands',
        EQ_BANDS.length);
      return;
    }
    const nextGains: number[] = gains.map((g: number) => this.clampGain(g));
    const matched: EqPreset | undefined =
      EQ_PRESETS.find((p: EqPreset) => this.gainsEqual(p.gains, nextGains));
    this.preset = matched !== undefined ? matched.key : 'custom';
    this.gains = nextGains;
    this.appliedGains = nextGains.slice();
    this.write();
    this.publishGains();
    this.notifyChanged('preset');
  }

  /**
   * 手动改某一段增益；改完预设自动变成「自定义」。
   *
   * 注意这里**只落盘、不重播**：拖推子是连续动作，每松一次手就重播一遍会变成
   * 十几次从头开始。重播统一交给右上角的「应用」（见 applyGains）。
   * 落盘照做——用户拖完直接退出，设置也不该丢。
   *
   * @param commit 拖动结束才传 true 落盘；拖动过程中传 false 只更新内存 + AppStorage
   */
  setBandGain(index: number, gain: number, commit: boolean = true): void {
    if (index < 0 || index >= this.gains.length) return;
    const next: number = this.clampGain(gain);
    /**
     * 值没变就什么都不做
     *
     * 手指点在圆钮当前位置、或在推子上划过但没改变数值时，滑块照样会回调到这里；
     * 若照旧把 preset 置成 'custom'，用户只是滑了一下列表，预设名就没了。
     */
    if (next !== this.gains[index]) {
      this.gains[index] = next;
      this.preset = 'custom';
      this.publishGains();
    }
    if (commit) {
      this.write();
    }
  }

  /**
   * 「应用」：把手动调好的增益真正交给播放侧
   *
   * 和选预设走同一条路：落盘 + 通知（PlaySession 收到就从 0 重新处理当前这首）。
   * 之前自定义增益只能靠切歌才生效，就是因为缺了这一步——松手时值早就被拖成同一个数，
   * setBandGain 的「值没变」分支把它当无事发生，通知从来没发出去过。
   */
  applyGains(): void {
    const wasDirty: boolean = this.isDirty();
    this.appliedGains = this.gains.slice();
    this.write();
    AppStorage.setOrCreate(K_EQ_DIRTY, false);
    // 没改动就不必打断播放；音效关着也不用重播（这次改动本来就听不到）
    if (!wasDirty || !this.enabled) {
      return;
    }
    this.notifyChanged('apply');
  }

  // ---------------- 空间音效写接口 ----------------

  /** 声场档位（0 关 / 1 前置 / 2 宏大 / 3 近场 / 4 宽广）：点一下一档，立即生效 */
  setSoundField(v: number): void {
    const next: number = Math.round(this.clampFxNum(v, 0, 0, 4));
    if (next === this.fx.soundField) return;
    this.fx.soundField = next;
    this.write();
    this.publishFx();
    this.notifyChanged('soundField');
  }

  /** 环境音档位（0 关 / 1 广播 / 2 听筒 / 3 水下 / 4 留声机） */
  setEnvironment(v: number): void {
    const next: number = Math.round(this.clampFxNum(v, 0, 0, 4));
    if (next === this.fx.environment) return;
    this.fx.environment = next;
    this.write();
    this.publishFx();
    this.notifyChanged('environment');
  }

  /** 空间渲染模式（0 关 / 1 静态定位 / 2 环绕旋转 / 3 扩散） */
  setSpaceMode(v: number): void {
    const next: number = Math.round(this.clampFxNum(v, 0, 0, 3));
    if (next === this.fx.spaceMode) return;
    this.fx.spaceMode = next;
    this.write();
    this.publishFx();
    this.notifyChanged('spaceMode');
  }

  /**
   * 改空间渲染的数值参数。
   *
   * 与 EQ 推子同样的两段式：拖动中 commit=false 只更新界面，松手 commit=true 才落盘并
   * 通知播放侧重播 —— 否则拖一下 XYZ 会连着把歌打回开头十几次。
   * 每个字段按 SDK 的合法区间夹紧（越界会让 SpaceRender 节点半初始化 → 启动管线崩溃）。
   */
  setSpaceParam(field: string, value: number, commit: boolean = true): void {
    switch (field) {
      case 'posX':
        this.fx.posX = this.clampFxNum(value, 0, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
        break;
      case 'posY':
        this.fx.posY = this.clampFxNum(value, 0, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
        break;
      case 'posZ':
        this.fx.posZ = this.clampFxNum(value, 2, SPACE_XYZ_MIN, SPACE_XYZ_MAX);
        break;
      case 'surroundTime':
        this.fx.surroundTime = Math.round(this.clampFxNum(value, 10, SURROUND_TIME_MIN, SURROUND_TIME_MAX));
        break;
      case 'surroundDir':
        this.fx.surroundDir = Math.round(this.clampFxNum(value, 1, 0, 1));
        break;
      case 'extRadius':
        this.fx.extRadius = this.clampFxNum(value, 3, EXT_RADIUS_MIN, EXT_RADIUS_MAX);
        break;
      case 'extAngle':
        this.fx.extAngle = Math.round(this.clampFxNum(value, 90, EXT_ANGLE_MIN, EXT_ANGLE_MAX));
        break;
      default:
        return;
    }
    this.publishFx();
    if (commit) {
      this.write();
      // 值没变时 PlaySession 的 effectSignature 会去重，不会真的重播
      this.notifyChanged('space');
    }
  }

  /**
   * 新的播放已经按当前增益处理过了：清掉「待应用」的记号
   *
   * 场景：拖完推子没按应用就切了下一首——新歌本来就是用新增益处理的，
   * 这时按钮还挂着「应用」，用户会以为没生效。由播放器在实际带上音效时回调
   * （见 LxPlayer.markEqApplied）。
   */
  markApplied(): void {
    if (!this.isDirty()) {
      return;
    }
    this.appliedGains = this.gains.slice();
    AppStorage.setOrCreate(K_EQ_DIRTY, false);
  }

  reset(): void {
    this.preset = 'off';
    this.gains = defaultGains();
    this.appliedGains = this.gains.slice();
    this.write();
    this.publishGains();
    this.notifyChanged('reset');
  }

  // ---------------------------------------------------------------- 同步恢复（WebDAV 配置同步）

  /**
   * 同步恢复（WebDAV 配置同步）时一次性写入开关 / 预设 / 十段增益
   *
   * 与 selectPreset / setBandGain 建立的不变量保持一致：**preset 名必须与 gains 自洽**。
   * 所以这里不信远端给的 preset 字符串，而是按规范化后的 gains 反推：
   *   - 与某套内置预设完全一致 -> 用那套的名字（含全 0 = off「原声」）；
   *   - 否则 -> 'custom'（远端写 'custom'、写成非法名、或名字与增益对不上，都落在这里）。
   * 不这么做会写出「preset=off 但增益非零」这种半套状态：播放页标识写「原声」，
   * 播放器却真的走 EQ（shouldProcess 看的是 gains），比不恢复更糟。
   *
   * 副作用约定：同步恢复发生在「没有 UI、没有播放上下文」的地方，所以
   *   - **不调 notifyChanged**：否则会触发「切音效重播」，把正在播的歌打断；
   *   - 只写内存（enabled / preset / gains / appliedGains）+ 落盘 + publish 到 AppStorage；
   *   - appliedGains 与 gains 一致，K_EQ_DIRTY 由 publish() 按 isDirty() 置 false
   *     （同步来的这一份就是「已经生效的那一份」，本机没有待应用的概念）。
   *
   * 非法输入安全：gains 不是正好 10 段（与 EQ_BANDS 对齐）时整条丢弃、不动本机设置
   * （不半信半疑地只应用一半）；单段 NaN / 越界由 clampGain 收敛到 [-10, 10]；
   * enabled 非 true 一律按关闭处理；未 init 时只更新内存与 AppStorage，write() 会跳过落盘。
   */
  applySynced(enabled: boolean, preset: string, gains: number[]): void {
    // 增益必须正好 10 段：少一段 / 多一段都不猜，整条恢复丢弃（避免只应用半套曲线）
    if (!Array.isArray(gains) || gains.length !== EQ_BANDS.length) {
      hilog.warn(DOMAIN, TAG, 'applySynced ignored: gains must have %{public}d bands',
        EQ_BANDS.length);
      return;
    }
    const nextGains: number[] = gains.map((g: number) => this.clampGain(g));
    const matched: EqPreset | undefined =
      EQ_PRESETS.find((p: EqPreset) => this.gainsEqual(p.gains, nextGains));
    if (matched === undefined && preset !== 'custom') {
      // 远端名字与增益对不上：名字按自定义走，打一条日志便于排查（不是错误）
      hilog.info(DOMAIN, TAG, 'synced preset %{public}s does not match gains, use custom', preset);
    }
    this.enabled = enabled === true;
    this.preset = matched !== undefined ? matched.key : 'custom';
    this.gains = nextGains;
    this.appliedGains = nextGains.slice();
    this.write();
    this.publish();
    // 不调 notifyChanged：同步恢复不应触发「切音效重播」打断正在播的歌
  }

  /** 两组 10 段增益是否完全一致（applySynced 判定 preset 名与增益是否自洽用） */
  private gainsEqual(a: number[], b: number[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }
}
