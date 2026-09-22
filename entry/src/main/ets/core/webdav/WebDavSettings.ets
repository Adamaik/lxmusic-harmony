import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebDavConfig } from './WebDavTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavSettings';

const FILE_NAME: string = 'webdav_settings.json';
/** 落盘结构变了就 +1，读到不认识的版本按默认值处理 */
const SETTINGS_VERSION: number = 1;

/** 服务器地址（可带路径）；界面用它做输入框的初值 */
export const K_WEBDAV_URL: string = 'cfg_webdav_url';
/** 用户名（可空 = 匿名，部分服务器允许） */
export const K_WEBDAV_USER: string = 'cfg_webdav_user';
/** 添加进曲库时是否读取云端标签（歌名/歌手/专辑/时长）—— 要逐首请求，慢但更准 */
export const K_WEBDAV_READ_TAGS: string = 'cfg_webdav_readtags';

/**
 * WebDAV 连接设置
 *
 * 只存「怎么连上服务器」这几项；曲库本身（歌曲索引、歌单侧表）在 WebDavLibrary 里。
 * 与 AppearanceSettings / DownloadSettings 同构：单例 + AppStorage 发布 + 沙箱 JSON 落盘。
 *
 * 密码按项目既有约定（同步的认证码、音源脚本）一样明文落在沙箱文件里：三方应用
 * 读不到别人的沙箱，系统也没有给普通应用「加密存一个自己的服务凭据」的通用接口
 * （Asset Store Kit 是给「用户凭据」用的，会弹系统授权框，不适合这里的静默重连）。
 */
export class WebDavSettings {
  private static instance: WebDavSettings | null = null;

  static getInstance(): WebDavSettings {
    if (WebDavSettings.instance === null) {
      WebDavSettings.instance = new WebDavSettings();
    }
    return WebDavSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  private url: string = '';
  private username: string = '';
  private password: string = '';
  private readTags: boolean = true;

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as WebDavSettingsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse webdav settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  isReady(): boolean {
    return this.inited;
  }

  isConfigured(): boolean {
    return this.url.length > 0;
  }

  getUrl(): string {
    return this.url;
  }

  getUsername(): string {
    return this.username;
  }

  /** 只给「填好初值就发请求」的调用方用，不要往 AppStorage / 日志里放 */
  getPassword(): string {
    return this.password;
  }

  getReadTags(): boolean {
    return this.readTags;
  }

  /** 给客户端用的完整配置（密码也在这里，别把它日志出来） */
  config(): WebDavConfig {
    return { url: this.url, username: this.username, password: this.password };
  }

  setUrl(value: string): void {
    const next: string = normalizeServerUrl(value);
    if (next === this.url) {
      return;
    }
    this.url = next;
    AppStorage.setOrCreate(K_WEBDAV_URL, next);
    this.write();
  }

  setUsername(value: string): void {
    const next: string = value.trim();
    if (next === this.username) {
      return;
    }
    this.username = next;
    AppStorage.setOrCreate(K_WEBDAV_USER, next);
    this.write();
  }

  setPassword(value: string): void {
    if (value === this.password) {
      return;
    }
    this.password = value;
    this.write();
  }

  setReadTags(value: boolean): void {
    if (value === this.readTags) {
      return;
    }
    this.readTags = value;
    AppStorage.setOrCreate(K_WEBDAV_READ_TAGS, value);
    this.write();
  }

  /** 清掉服务器地址与账号密码（曲库不动） */
  clearServer(): void {
    this.url = '';
    this.username = '';
    this.password = '';
    AppStorage.setOrCreate(K_WEBDAV_URL, '');
    AppStorage.setOrCreate(K_WEBDAV_USER, '');
    this.write();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read settings failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: WebDavSettingsData = {
      version: SETTINGS_VERSION,
      url: this.url,
      username: this.username,
      password: this.password,
      readTags: this.readTags,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write settings failed: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: WebDavSettingsData): void {
    if (data.version !== SETTINGS_VERSION) {
      return;
    }
    if (data.url !== undefined) {
      this.url = normalizeServerUrl(data.url);
    }
    if (data.username !== undefined) {
      this.username = data.username;
    }
    if (data.password !== undefined) {
      this.password = data.password;
    }
    if (data.readTags !== undefined) {
      this.readTags = data.readTags;
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_WEBDAV_URL, this.url);
      AppStorage.setOrCreate(K_WEBDAV_USER, this.username);
      AppStorage.setOrCreate(K_WEBDAV_READ_TAGS, this.readTags);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish settings failed: %{public}s', JSON.stringify(e));
    }
  }
}

interface WebDavSettingsData {
  version?: number;
  url?: string;
  username?: string;
  password?: string;
  readTags?: boolean;
}

/**
 * 把用户随手写的地址整成一个能用的 URL
 *
 * 手机键盘上没人愿意打 `https://`，所以没写协议时补 `http://`（局域网自建服务
 * 大多是 http）；末尾斜杠去掉，统一成「目录地址」的写法。
 */
export function normalizeServerUrl(raw: string): string {
  let text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  const lower: string = text.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    text = `http://${text}`;
  }
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}
