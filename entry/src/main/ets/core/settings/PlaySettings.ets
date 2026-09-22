import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlaySettings';
const FILE_NAME: string = 'play_settings.json';
/** 落盘结构变了就 +1，读到不认识的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 播放设置（设置 - 播放设置）
 *
 * 对应界面上这几项：
 *   播放音质 / 拓展音质（含 Hi-Res、全景声、全景声+、母带）/ 与其他应用同时播放
 *   播放页显示小歌词 / 歌词页模糊效果 / 歌词居中显示 / 歌词字号 / 歌词页不熄屏
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/play_settings.json），同时把每个值写进
 * AppStorage——界面用 @StorageLink 订阅即可实时响应，播放器侧直接读本单例。
 * 改动立即落盘，不做节流：这些都是用户点一下才变一次的低频操作，不存在写放大。
 *
 * 说明：洛雪本体把播放设置存在它的设置对象里（player.playQuality /
 * player.isHandleAudioFocus / playDetail.style.* 等）；本移植版原先只有缓存上限
 * 一项是真的，其余播放/歌词设置页还没接，这里把它们补齐并落盘，重启不丢。
 */

/** 播放音质四档（界面：128K / 320K / FLAC / 24Bit），顺序与界面一致 */
export const MAIN_QUALITYS: string[] = ['128k', '320k', 'flac', 'flac24bit'];
export const MAIN_QUALITY_LABELS: string[] = ['128K', '320K', 'FLAC', '24Bit'];
/**
 * 拓展音质四档（界面：Hi-Res / 全景声 / 全景声+ / 母带），顺序与界面一致（低 -> 高）
 *
 * 这四档不是所有平台都给：拿不到时播放会退回「播放音质」里选的那档，
 * 所以打开它不会把能放的歌变成放不了。
 */
export const EXTEND_QUALITYS: string[] = ['hires', 'atmos', 'atmos_plus', 'master'];
export const EXTEND_QUALITY_LABELS: string[] = ['Hi-Res', '全景声', '全景声+', '母带'];

/** 主音质从高到低：用户选的那档不可用时按这个顺序往下退 */
const MAIN_QUALITY_ORDER: string[] = ['flac24bit', 'flac', '320k', '128k'];
/** 拓展音质从高到低，同上 */
const EXTEND_QUALITY_ORDER: string[] = ['master', 'atmos_plus', 'atmos', 'hires'];

/** 歌词字号范围（vp）与默认值：歌词页与封面页小歌词共用同一档字号 */
export const LYRIC_FONT_MIN: number = 13;
export const LYRIC_FONT_MAX: number = 30;
export const LYRIC_FONT_DEFAULT: number = 19;

/** 界面订阅这些 key 就能拿到最新设置（@StorageLink） */
export const K_PLAY_QUALITY: string = 'cfg_play_quality';
export const K_EXTEND_QUALITY: string = 'cfg_extend_quality';
export const K_EXTEND_QUALITY_TYPE: string = 'cfg_extend_quality_type';
export const K_PLAY_WITH_OTHERS: string = 'cfg_play_with_others';
export const K_SHOW_MINI_LYRIC: string = 'cfg_show_mini_lyric';
export const K_LYRIC_BLUR: string = 'cfg_lyric_blur';
export const K_LYRIC_CENTERED: string = 'cfg_lyric_centered';
export const K_LYRIC_FONT_SIZE: string = 'cfg_lyric_font_size';
export const K_LYRIC_KEEP_SCREEN: string = 'cfg_lyric_keep_screen';
/** 桌面歌词（系统歌词悬浮窗）开关 */
export const K_DESKTOP_LYRIC: string = 'cfg_desktop_lyric';
/**
 * 车载蓝牙歌词
 *
 * 把「当前这一句」写进 AVMetadata.singleLyricText：系统蓝牙模块读这个字段，
 * 把它送到已连接的蓝牙设备（车机、蓝牙音箱）显示。
 * 跟桌面歌词不是一回事：那个是手机上的悬浮窗，读的是 AVMetadata.lyric。
 */
export const K_BLUETOOTH_LYRIC: string = 'cfg_bluetooth_lyric';
/**
 * 本地音乐自动匹配歌词
 *
 * 本地歌没有平台身份，只能拿「歌名 + 歌手 + 时长」去平台搜一首对应的在线歌再取词，
 * 也就是要联网。默认开着（大多数人希望本地歌也有滚动歌词），但它会发网络请求，
 * 所以给一个开关；关掉之后仍然可以在播放页手动匹配。
 */
export const K_AUTO_MATCH_LYRIC: string = 'cfg_auto_match_lyric';

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface PlaySettingsData {
  version?: number;
  quality?: string;
  extendQuality?: boolean;
  extendQualityType?: string;
  playWithOthers?: boolean;
  showMiniLyric?: boolean;
  lyricBlur?: boolean;
  lyricCentered?: boolean;
  lyricFontSize?: number;
  lyricKeepScreenOn?: boolean;
  desktopLyric?: boolean;
  autoMatchLyric?: boolean;
  bluetoothLyric?: boolean;
}

function clampFontSize(value: number): number {
  if (Number.isNaN(value)) {
    return LYRIC_FONT_DEFAULT;
  }
  if (value < LYRIC_FONT_MIN) {
    return LYRIC_FONT_MIN;
  }
  if (value > LYRIC_FONT_MAX) {
    return LYRIC_FONT_MAX;
  }
  return Math.round(value);
}

export class PlaySettings {
  private static instance: PlaySettings | null = null;

  static getInstance(): PlaySettings {
    if (PlaySettings.instance === null) {
      PlaySettings.instance = new PlaySettings();
    }
    return PlaySettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 播放音质：洛雪默认也是 128k */
  private quality: string = '128k';
  /**
   * 拓展音质默认关：这几档多数平台要会员，拿不到链接时表现为「点了不出声」，
   * 让用户自己开更合适（开了也能自动退回普通音质）。
   */
  private extendQuality: boolean = false;
  private extendQualityType: string = 'hires';
  /** 与其他应用同时播放默认关（独占音频焦点，与洛雪 isHandleAudioFocus=true 一致） */
  private playWithOthers: boolean = false;
  private showMiniLyric: boolean = false;
  private lyricBlur: boolean = true;
  private lyricCentered: boolean = true;
  private lyricFontSize: number = LYRIC_FONT_DEFAULT;
  private lyricKeepScreenOn: boolean = true;
  /**
   * 桌面歌词（系统歌词悬浮窗）默认开，与改动前的行为一致：
   * 以前这个能力一接上就是「有词就显示」，没有开关；现在用户能关掉。
   */
  private desktopLyric: boolean = true;
  /** 本地歌自动匹配歌词默认开，见 K_AUTO_MATCH_LYRIC 的说明 */
  private autoMatchLyric: boolean = true;
  /**
   * 车载蓝牙歌词默认关。
   *
   * 每换一句就要重推一次元数据、触发一次蓝牙侧的更新，华为官方明确提醒过
   * 「开启蓝牙歌词同步后可能导致车载播放音乐卡顿」——不在车里就不该付这个代价，
   * 所以跟洛雪上游（player.isShowBluetoothLyric）一样默认关，要用时自己开。
   */
  private bluetoothLyric: boolean = false;

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
        this.apply(JSON.parse(text) as PlaySettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse play settings: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'failed to read play settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: PlaySettingsData = {
      version: SETTINGS_VERSION,
      quality: this.quality,
      extendQuality: this.extendQuality,
      extendQualityType: this.extendQualityType,
      playWithOthers: this.playWithOthers,
      showMiniLyric: this.showMiniLyric,
      lyricBlur: this.lyricBlur,
      lyricCentered: this.lyricCentered,
      lyricFontSize: this.lyricFontSize,
      lyricKeepScreenOn: this.lyricKeepScreenOn,
      desktopLyric: this.desktopLyric,
      autoMatchLyric: this.autoMatchLyric,
      bluetoothLyric: this.bluetoothLyric,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write play settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: PlaySettingsData): void {
    if (data.version !== SETTINGS_VERSION) {
      return;
    }
    const quality: string | undefined = data.quality;
    if (quality !== undefined && MAIN_QUALITYS.includes(quality)) {
      this.quality = quality;
    }
    const extended: string | undefined = data.extendQualityType;
    if (extended !== undefined && EXTEND_QUALITYS.includes(extended)) {
      this.extendQualityType = extended;
    }
    if (data.extendQuality !== undefined) {
      this.extendQuality = data.extendQuality;
    }
    if (data.playWithOthers !== undefined) {
      this.playWithOthers = data.playWithOthers;
    }
    if (data.showMiniLyric !== undefined) {
      this.showMiniLyric = data.showMiniLyric;
    }
    if (data.lyricBlur !== undefined) {
      this.lyricBlur = data.lyricBlur;
    }
    if (data.lyricCentered !== undefined) {
      this.lyricCentered = data.lyricCentered;
    }
    if (data.lyricKeepScreenOn !== undefined) {
      this.lyricKeepScreenOn = data.lyricKeepScreenOn;
    }
    if (data.desktopLyric !== undefined) {
      this.desktopLyric = data.desktopLyric;
    }
    if (data.autoMatchLyric !== undefined) {
      this.autoMatchLyric = data.autoMatchLyric;
    }
    if (data.bluetoothLyric !== undefined) {
      this.bluetoothLyric = data.bluetoothLyric;
    }
    const fontSize: number | undefined = data.lyricFontSize;
    if (fontSize !== undefined) {
      this.lyricFontSize = clampFontSize(fontSize);
    }
  }

  /** 把内存里的值同步到 AppStorage，界面据此实时刷新 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_PLAY_QUALITY, this.quality);
      AppStorage.setOrCreate(K_EXTEND_QUALITY, this.extendQuality);
      AppStorage.setOrCreate(K_EXTEND_QUALITY_TYPE, this.extendQualityType);
      AppStorage.setOrCreate(K_PLAY_WITH_OTHERS, this.playWithOthers);
      AppStorage.setOrCreate(K_SHOW_MINI_LYRIC, this.showMiniLyric);
      AppStorage.setOrCreate(K_LYRIC_BLUR, this.lyricBlur);
      AppStorage.setOrCreate(K_LYRIC_CENTERED, this.lyricCentered);
      AppStorage.setOrCreate(K_LYRIC_FONT_SIZE, this.lyricFontSize);
      AppStorage.setOrCreate(K_LYRIC_KEEP_SCREEN, this.lyricKeepScreenOn);
      AppStorage.setOrCreate(K_DESKTOP_LYRIC, this.desktopLyric);
      AppStorage.setOrCreate(K_AUTO_MATCH_LYRIC, this.autoMatchLyric);
      AppStorage.setOrCreate(K_BLUETOOTH_LYRIC, this.bluetoothLyric);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；万一环境不支持也不能让启动挂掉，
      // 界面自己会用 @StorageLink 的默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish play settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  getQuality(): string {
    return this.quality;
  }

  isExtendQuality(): boolean {
    return this.extendQuality;
  }

  getExtendQualityType(): string {
    return this.extendQualityType;
  }

  isPlayWithOthers(): boolean {
    return this.playWithOthers;
  }

  isShowMiniLyric(): boolean {
    return this.showMiniLyric;
  }

  isLyricBlur(): boolean {
    return this.lyricBlur;
  }

  isLyricCentered(): boolean {
    return this.lyricCentered;
  }

  getLyricFontSize(): number {
    return this.lyricFontSize;
  }

  isLyricKeepScreenOn(): boolean {
    return this.lyricKeepScreenOn;
  }

  isDesktopLyric(): boolean {
    return this.desktopLyric;
  }

  /** 车载蓝牙歌词（写 AVMetadata.singleLyricText，见 K_BLUETOOTH_LYRIC） */
  isBluetoothLyric(): boolean {
    return this.bluetoothLyric;
  }

  /**
   * 候选音质（从高到低），协商播放音质时按这个顺序一个个试
   *
   * 拓展音质开着时先排拓展档：用户选的那档就是他能接受的最高档，
   * 所以从它往下排（而不是把所有拓展档都排上）——选了「全景声」却去要母带
   * 既不符合选择，也更容易因为没会员而失败。之后再接普通音质。
   */
  qualityCandidates(): string[] {
    const out: string[] = [];
    if (this.extendQuality) {
      const index: number = EXTEND_QUALITY_ORDER.indexOf(this.extendQualityType);
      for (let i = index < 0 ? 0 : index; i < EXTEND_QUALITY_ORDER.length; i++) {
        out.push(EXTEND_QUALITY_ORDER[i]);
      }
    }
    return out.concat(this.mainQualityCandidates());
  }

  /** 只含普通音质的候选（从用户选的那档往下）：拓展音质解析失败时用它回落 */
  mainQualityCandidates(): string[] {
    const out: string[] = [];
    const start: number = MAIN_QUALITY_ORDER.indexOf(this.quality);
    for (let i = start < 0 ? 0 : start; i < MAIN_QUALITY_ORDER.length; i++) {
      out.push(MAIN_QUALITY_ORDER[i]);
    }
    return out;
  }

  // ---------------------------------------------------------------- 写入

  setQuality(value: string): void {
    if (!MAIN_QUALITYS.includes(value) || value === this.quality) {
      return;
    }
    this.quality = value;
    AppStorage.setOrCreate(K_PLAY_QUALITY, value);
    this.write();
  }

  setExtendQuality(value: boolean): void {
    if (value === this.extendQuality) {
      return;
    }
    this.extendQuality = value;
    AppStorage.setOrCreate(K_EXTEND_QUALITY, value);
    this.write();
  }

  setExtendQualityType(value: string): void {
    if (!EXTEND_QUALITYS.includes(value) || value === this.extendQualityType) {
      return;
    }
    this.extendQualityType = value;
    AppStorage.setOrCreate(K_EXTEND_QUALITY_TYPE, value);
    this.write();
  }

  setPlayWithOthers(value: boolean): void {
    if (value === this.playWithOthers) {
      return;
    }
    this.playWithOthers = value;
    AppStorage.setOrCreate(K_PLAY_WITH_OTHERS, value);
    this.write();
  }

  setShowMiniLyric(value: boolean): void {
    if (value === this.showMiniLyric) {
      return;
    }
    this.showMiniLyric = value;
    AppStorage.setOrCreate(K_SHOW_MINI_LYRIC, value);
    this.write();
  }

  setLyricBlur(value: boolean): void {
    if (value === this.lyricBlur) {
      return;
    }
    this.lyricBlur = value;
    AppStorage.setOrCreate(K_LYRIC_BLUR, value);
    this.write();
  }

  setLyricCentered(value: boolean): void {
    if (value === this.lyricCentered) {
      return;
    }
    this.lyricCentered = value;
    AppStorage.setOrCreate(K_LYRIC_CENTERED, value);
    this.write();
  }

  /**
   * 拖字号滑块时每一格都会调进来：先只更新 AppStorage（歌词页立刻跟着变大），
   * 松手（mode = End）才落盘，避免一次拖动写十几个文件。
   */
  setLyricFontSize(value: number, persist: boolean = true): void {
    const next: number = clampFontSize(value);
    if (next === this.lyricFontSize) {
      return;
    }
    this.lyricFontSize = next;
    AppStorage.setOrCreate(K_LYRIC_FONT_SIZE, next);
    if (persist) {
      this.write();
    }
  }

  setLyricKeepScreenOn(value: boolean): void {
    if (value === this.lyricKeepScreenOn) {
      return;
    }
    this.lyricKeepScreenOn = value;
    AppStorage.setOrCreate(K_LYRIC_KEEP_SCREEN, value);
    this.write();
  }

  setDesktopLyric(value: boolean): void {
    if (value === this.desktopLyric) {
      return;
    }
    this.desktopLyric = value;
    AppStorage.setOrCreate(K_DESKTOP_LYRIC, value);
    this.write();
  }

  /** 车载蓝牙歌词开关（改完由 PlaySession.setBluetoothLyric 让播控服务立刻重推一次） */
  setBluetoothLyric(value: boolean): void {
    if (value === this.bluetoothLyric) {
      return;
    }
    this.bluetoothLyric = value;
    AppStorage.setOrCreate(K_BLUETOOTH_LYRIC, value);
    this.write();
  }

  /** 本地音乐自动匹配歌词（要联网搜一次，所以给了开关） */
  getAutoMatchLyric(): boolean {
    return this.autoMatchLyric;
  }

  setAutoMatchLyric(value: boolean): void {
    if (value === this.autoMatchLyric) {
      return;
    }
    this.autoMatchLyric = value;
    AppStorage.setOrCreate(K_AUTO_MATCH_LYRIC, value);
    this.write();
  }
}
