import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadSettings';
const FILE_NAME: string = 'download_settings.json';
/** 落盘结构变了就 +1，读到不认识的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 下载设置（设置 - 下载设置）
 *
 * 对应界面上三项：
 *   文件名称格式（歌曲名 / 艺术家-标题 / 标题-艺术家）
 *   下载文件标注音质（开/关：文件名后缀带上音质，如 `歌名-320k.mp3`）
 *   保存位置（手动选择 / Download目录）
 *
 * 存法与播放设置一致：一份 JSON 落在沙箱（filesDir/download_settings.json），
 * 同时把每个值写进 AppStorage，界面用 @StorageLink 订阅即可实时响应。
 *
 * 「手动选择」保存的是系统文件选择器返回的目录 uri（file://docs/...）。它只用来把
 * 系统保存对话框定位到那儿（见 DownloadManager.openTarget）——往用户目录新建文件
 * 只有系统保存对话框这一条官方通路，所以手动模式下每首会确认一次。
 */

/** 文件名格式（顺序与界面一致） */
export const NAME_FORMATS: string[] = ['song', 'artist-title', 'title-artist'];
export const NAME_FORMAT_LABELS: string[] = ['歌曲名', '艺术家-标题', '标题-艺术家'];

/**
 * 保存位置
 *
 *   manual ：自己选一个目录，下载时把系统保存对话框定位到它
 *   app    ：系统的 Download/<应用> 目录，不用选、全程不弹对话框
 *
 * 「手动选择」用的是文件选择器的**文件夹模式**（SystemCapability.FileManagement
 * .UserFileService.FolderSelection，手机/平板/PC 都在支持列表里），只记住目录本身。
 * 不做「持久化授权」：那需要受限 ACL 权限 FILE_ACCESS_PERSIST（要 Profile 声明），
 * 而且真正写文件的系统保存对话框并不需要它。
 */
export const SAVE_MODES: string[] = ['manual', 'app'];
export const SAVE_MODE_LABELS: string[] = ['手动选择', 'Download目录'];

export const K_DOWNLOAD_NAME_FORMAT: string = 'cfg_download_name_format';
export const K_DOWNLOAD_MARK_QUALITY: string = 'cfg_download_mark_quality';
export const K_DOWNLOAD_SAVE_MODE: string = 'cfg_download_save_mode';

/** 落盘结构（字段全部可选：老文件可能缺字段） */
interface DownloadSettingsData {
  version?: number;
  nameFormat?: string;
  markQuality?: boolean;
  saveMode?: string;
  saveDirUri?: string;
  saveDirLabel?: string;
}

export class DownloadSettings {
  private static instance: DownloadSettings | null = null;

  static getInstance(): DownloadSettings {
    if (DownloadSettings.instance === null) {
      DownloadSettings.instance = new DownloadSettings();
    }
    return DownloadSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  /** 文件名称格式：参考图里默认「歌曲名」 */
  private nameFormat: string = 'song';
  /** 下载文件标注音质：默认开（参考图里也是开） */
  private markQuality: boolean = true;
  /** 保存位置默认「Download目录」：不用先选目录就能用 */
  private saveMode: string = 'app';
  /** 手动选择的目录 uri 与短名（file://docs/... 那种） */
  private saveDirUri: string = '';
  private saveDirLabel: string = '';

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as DownloadSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse download settings: %{public}s', JSON.stringify(e));
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
      hilog.warn(DOMAIN, TAG, 'failed to read download settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: DownloadSettingsData = {
      version: SETTINGS_VERSION,
      nameFormat: this.nameFormat,
      markQuality: this.markQuality,
      saveMode: this.saveMode,
      saveDirUri: this.saveDirUri,
      saveDirLabel: this.saveDirLabel,
    };
    try {
      const handle = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write download settings: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: DownloadSettingsData): void {
    if (data.version !== SETTINGS_VERSION) {
      return;
    }
    const format: string | undefined = data.nameFormat;
    if (format !== undefined && NAME_FORMATS.includes(format)) {
      this.nameFormat = format;
    }
    const mode: string | undefined = data.saveMode;
    if (mode !== undefined && SAVE_MODES.includes(mode)) {
      this.saveMode = mode;
    }
    if (data.markQuality !== undefined) {
      this.markQuality = data.markQuality;
    }
    if (data.saveDirUri !== undefined) {
      this.saveDirUri = data.saveDirUri;
    }
    if (data.saveDirLabel !== undefined) {
      this.saveDirLabel = data.saveDirLabel;
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_DOWNLOAD_NAME_FORMAT, this.nameFormat);
      AppStorage.setOrCreate(K_DOWNLOAD_MARK_QUALITY, this.markQuality);
      AppStorage.setOrCreate(K_DOWNLOAD_SAVE_MODE, this.saveMode);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to publish download settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  getNameFormat(): string {
    return this.nameFormat;
  }

  isMarkQuality(): boolean {
    return this.markQuality;
  }

  getSaveMode(): string {
    return this.saveMode;
  }

  // ---------------------------------------------------------------- 写入

  setNameFormat(value: string): void {
    if (!NAME_FORMATS.includes(value) || value === this.nameFormat) {
      return;
    }
    this.nameFormat = value;
    AppStorage.setOrCreate(K_DOWNLOAD_NAME_FORMAT, value);
    this.write();
  }

  setMarkQuality(value: boolean): void {
    if (value === this.markQuality) {
      return;
    }
    this.markQuality = value;
    AppStorage.setOrCreate(K_DOWNLOAD_MARK_QUALITY, value);
    this.write();
  }

  /** 手动选择的目录 uri（saveMode = app 时也可能有：用户以前选过） */
  getSaveDirUri(): string {
    return this.saveDirUri;
  }

  /** 手动选择的目录短名（设置页显示用） */
  getSaveDirLabel(): string {
    return this.saveDirLabel;
  }

  /** 选好目录后调用：记下 uri 并切到手动模式 */
  setSaveDir(uri: string, label: string): void {
    this.saveDirUri = uri;
    this.saveDirLabel = label;
    this.saveMode = uri.length > 0 ? 'manual' : 'app';
    AppStorage.setOrCreate(K_DOWNLOAD_SAVE_MODE, this.saveMode);
    this.write();
  }

  /** 切保存位置（app / manual） */
  setSaveMode(mode: string): void {
    if (!SAVE_MODES.includes(mode) || mode === this.saveMode) {
      return;
    }
    this.saveMode = mode;
    AppStorage.setOrCreate(K_DOWNLOAD_SAVE_MODE, mode);
    this.write();
  }
}
