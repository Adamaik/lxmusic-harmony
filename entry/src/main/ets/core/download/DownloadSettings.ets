import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadSettings';
const FILE_NAME: string = 'download_settings.json';
/**
 * 落盘结构变了就 +1，读到不认识的版本按默认值处理。
 * v1 -> v2：去掉「保存位置」相关字段（保存位置不再可选），新增 downloadDirUri
 * （系统实际给的那个公共目录，用来在设置页显示「下载目录」）。v1 的文件仍按 v2 读：
 * 留下的 nameFormat / markQuality 字段名没变，照样认得。
 */
const SETTINGS_VERSION: number = 2;

/**
 * 下载设置（设置 - 下载设置）
 *
 * 对应界面上两项：
 *   文件名称格式（歌曲名 / 艺术家-标题 / 标题-艺术家）
 *   下载文件标注音质（开/关：文件名后缀带上音质，如 `歌名-320k.mp3`）
 *
 * 保存位置**不再让用户选、也不再存在这里**：目录由 DownloadManager 直接问系统要
 * （`Environment.getUserDownloadDir()` 的预授权 Download 目录 + 我们自己的子目录），
 * 是算出来的而不是记下来的，所以没必要落盘。
 *
 * 存法与播放设置一致：一份 JSON 落在沙箱（filesDir/download_settings.json），
 * 同时把每个值写进 AppStorage，界面用 @StorageLink 订阅即可实时响应。
 */

export const NAME_FORMATS: string[] = ['song', 'artist-title', 'title-artist'];
export const NAME_FORMAT_LABELS: string[] = ['歌曲名', '艺术家-标题', '标题-艺术家'];

export const K_DOWNLOAD_NAME_FORMAT: string = 'cfg_download_name_format';
export const K_DOWNLOAD_MARK_QUALITY: string = 'cfg_download_mark_quality';
export const K_DOWNLOAD_DIR_URI: string = 'cfg_download_dir_uri';

/** 落盘结构（字段全部可选：老文件可能缺字段） */
interface DownloadSettingsData {
  version?: number;
  nameFormat?: string;
  markQuality?: boolean;
  /** 系统实际给的公共下载目录 uri（file://docs/... 那种），写成功一次就记下来 */
  downloadDirUri?: string;
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
  /** 系统给的公共下载目录 uri（第一次写进公共目录后才有值） */
  private downloadDirUri: string = '';

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
      downloadDirUri: this.downloadDirUri,
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
    // v1 的文件也收下：去掉的保存位置字段忽略掉，剩下的两项字段名没变
    if (data.version !== SETTINGS_VERSION && data.version !== 1) {
      return;
    }
    const format: string | undefined = data.nameFormat;
    if (format !== undefined && NAME_FORMATS.includes(format)) {
      this.nameFormat = format;
    }
    if (data.markQuality !== undefined) {
      this.markQuality = data.markQuality;
    }
    if (data.downloadDirUri !== undefined) {
      this.downloadDirUri = data.downloadDirUri;
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_DOWNLOAD_NAME_FORMAT, this.nameFormat);
      AppStorage.setOrCreate(K_DOWNLOAD_MARK_QUALITY, this.markQuality);
      AppStorage.setOrCreate(K_DOWNLOAD_DIR_URI, this.downloadDirUri);
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

  /** 系统给的公共下载目录 uri（file://docs/... 那种）；还没写进去过时是空串 */
  getDownloadDirUri(): string {
    return this.downloadDirUri;
  }

  /**
   * 记下系统实际使用的公共下载目录
   *
   * 目录不是我们编出来的：保存对话框返回的文件 uri 去掉文件名就是真实目录
   * （各机型/各版本下这个目录长什么样由系统定）。记下来之后，设置页「下载目录」
   * 显示的就是它真实的样子，而不是我们猜的一个名字。
   */
  learnDownloadDir(dirUri: string): void {
    if (dirUri.length === 0 || dirUri === this.downloadDirUri) {
      return;
    }
    this.downloadDirUri = dirUri;
    AppStorage.setOrCreate(K_DOWNLOAD_DIR_URI, dirUri);
    this.write();
  }
}
