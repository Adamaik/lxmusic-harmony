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
}

const SETTINGS_VERSION: number = 1;

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
  /**
   * 上一次「应用」时的增益快照
   *
   * dirty 不是「有没有拖过」，而是「现在的值和已经生效的那一份是否不同」：
   * 拖出去再拖回原位，应该重新变回「已应用」，而不是一直挂着待应用的记号。
   */
  private appliedGains: number[] = defaultGains();
  /** 配置变更订阅者（播放侧注册，用来「切完就重播」） */
  private listeners: EqChangeListener[] = [];

  /** 订阅配置变更；只保留一个订阅者（播放会话），重复注册不会叠加 */
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
    // 读进来的配置就是「已经生效的那一份」：下次起播就用它，不该显示成待应用
    this.appliedGains = this.gains.slice();
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

  /** 当前是否真的会走 EQ 管线（开关打开且不是全 0） */
  shouldProcess(): boolean {
    if (!this.enabled) return false;
    return this.gains.some((g: number) => g !== 0);
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
}
