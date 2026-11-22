import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CONFIG_SYNC_DEFAULT_DIR, WebDavConfig } from './WebDavTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavSettings';

const FILE_NAME: string = 'webdav_settings.json';
/**
 * 落盘结构变了就 +1，读到不认识的版本按默认值处理
 *
 * v2：新增配置同步用的三项（目录 / 自动同步 / 上次同步戳）。v1 存档没有这些字段，
 * apply 里按默认值处理 —— 行为与加这个功能之前完全一致，用户不会「被动开着自动同步」。
 */
const SETTINGS_VERSION: number = 2;

/** 服务器地址（可带路径）；界面用它做输入框的初值 */
export const K_WEBDAV_URL: string = 'cfg_webdav_url';
/** 用户名（可空 = 匿名，部分服务器允许） */
export const K_WEBDAV_USER: string = 'cfg_webdav_user';
/** 添加进曲库时是否读取云端标签（歌名/歌手/专辑/时长）—— 要逐首请求，慢但更准 */
export const K_WEBDAV_READ_TAGS: string = 'cfg_webdav_readtags';
/** 配置同步在网盘上的目录（相对服务器地址；界面输入框用它） */
export const K_WEBDAV_SYNC_DIR: string = 'cfg_webdav_sync_dir';
/** 自动同步开关（开机 / 退出各试一次，失败静默） */
export const K_WEBDAV_SYNC_AUTO: string = 'cfg_webdav_sync_auto';

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
  /** 配置同步目录（空串按默认目录处理，见 getSyncDir） */
  private syncDir: string = '';
  private syncAuto: boolean = false;
  /**
   * 上次「成功同步」时的 exportedAt（ISO）
   *
   * 冲突判断就靠它：网盘上的 exportedAt 比它新 = 另一台设备在这之后写过。空串表示
   * 本机还没跟网盘对齐过（第一次同步 / 恢复后清过），此时网盘上有配置就按「更新」提示。
   */
  private lastSyncedAt: string = '';
  /** 上次成功同步时的内容指纹（不含时间），用来判断「内容是否真的变了」 */
  private lastSyncedHash: string = '';

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

  /** 配置同步目录（没填过就是默认目录；界面输入框用它做初值） */
  getSyncDir(): string {
    return this.syncDir.length > 0 ? this.syncDir : CONFIG_SYNC_DEFAULT_DIR;
  }

  isAutoSync(): boolean {
    return this.syncAuto;
  }

  getLastSyncedAt(): string {
    return this.lastSyncedAt;
  }

  getLastSyncedHash(): string {
    return this.lastSyncedHash;
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

  /** 设配置同步目录；空串 = 回到默认目录 */
  setSyncDir(value: string): void {
    const next: string = normalizeSyncDir(value);
    if (next === this.syncDir) {
      return;
    }
    this.syncDir = next;
    AppStorage.setOrCreate(K_WEBDAV_SYNC_DIR, this.getSyncDir());
    this.write();
  }

  setAutoSync(value: boolean): void {
    if (value === this.syncAuto) {
      return;
    }
    this.syncAuto = value;
    AppStorage.setOrCreate(K_WEBDAV_SYNC_AUTO, value);
    this.write();
  }

  /**
   * 记一次成功同步（上传或恢复之后调）
   *
   * 时间与指纹一起写：只写时间会在「内容没变但被点了一次上传」时把 exportedAt 推新，
   * 让另一台设备误以为有更新。
   */
  setSyncState(exportedAt: string, hash: string): void {
    if (exportedAt === this.lastSyncedAt && hash === this.lastSyncedHash) {
      return;
    }
    this.lastSyncedAt = exportedAt;
    this.lastSyncedHash = hash;
    this.write();
  }

  /** 清掉服务器地址与账号密码（曲库不动；同步戳一起清，重新配置后按「第一次同步」处理） */
  clearServer(): void {
    this.url = '';
    this.username = '';
    this.password = '';
    this.lastSyncedAt = '';
    this.lastSyncedHash = '';
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
      syncDir: this.syncDir,
      syncAuto: this.syncAuto,
      lastSyncedAt: this.lastSyncedAt,
      lastSyncedHash: this.lastSyncedHash,
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
    // 只认 1、2：v1 是没有配置同步的那些字段，其余照读；将来 v3 再往上加时这里要补
    if (data.version !== 1 && data.version !== 2) {
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
    if (data.syncDir !== undefined) {
      this.syncDir = normalizeSyncDir(data.syncDir);
    }
    if (data.syncAuto !== undefined) {
      this.syncAuto = data.syncAuto;
    }
    if (data.lastSyncedAt !== undefined) {
      this.lastSyncedAt = data.lastSyncedAt;
    }
    if (data.lastSyncedHash !== undefined) {
      this.lastSyncedHash = data.lastSyncedHash;
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_WEBDAV_URL, this.url);
      AppStorage.setOrCreate(K_WEBDAV_USER, this.username);
      AppStorage.setOrCreate(K_WEBDAV_READ_TAGS, this.readTags);
      AppStorage.setOrCreate(K_WEBDAV_SYNC_DIR, this.getSyncDir());
      AppStorage.setOrCreate(K_WEBDAV_SYNC_AUTO, this.syncAuto);
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
  syncDir?: string;
  syncAuto?: boolean;
  lastSyncedAt?: string;
  lastSyncedHash?: string;
}

/**
 * 把用户随手写的同步目录整成一个干净写法
 *
 * 允许三种：空（= 默认目录）、相对目录（`listen-config`、`config/listen`）、
 * 绝对路径（`/dav/config`）与整条 URL（原样保留，由 WebDavConfigData.buildFolderUrl
 * 判断）。这里只去空白与**末尾**斜杠，不动开头 —— 开头的 `/` 是有意义的。
 */
function normalizeSyncDir(raw: string): string {
  let text: string = raw.trim();
  while (text.length > 1 && text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text === '/' ? '' : text;
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
