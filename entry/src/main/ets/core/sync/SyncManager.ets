import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LocalLibrary } from './LocalLibrary';
import { SyncClient } from './SyncClient';
import { initGzip } from './SyncGzip';
import { defaultDeviceName, SyncConfig, SyncStore } from './SyncStore';
import { SyncStatus } from './SyncTypes';
import { PlaySession } from '../player/PlaySession';

const DOMAIN: number = 0x0001;
const TAG: string = 'SyncManager';

/** 同步状态相关的 AppStorage key（界面只订阅这几个） */
export const K_SYNC_ENABLE: string = 'sync_enable';
export const K_SYNC_STATUS: string = 'sync_status';
export const K_SYNC_MESSAGE: string = 'sync_message';
/** 同步数据（歌单/收藏/规则）的版本号，界面据此重新读一次 */
export const K_SYNC_DATA_VERSION: string = 'sync_data_version';
/** 同步进度：0-100 的百分比与当前阶段文案（同步设置页展示） */
export const K_SYNC_PROGRESS: string = 'sync_progress';
export const K_SYNC_STAGE: string = 'sync_stage';

/** 界面注册的「选择同步方式」监听：拿到请求后自己弹选择框，再用 answerMode 回答案 */
export type SyncModeRequestListener = (kind: string, serverName: string, options: string) => void;
/** 界面注册的状态提示监听（用于 toast 认证失败等） */
export type SyncMessageListener = (message: string) => void;

/**
 * 同步模块的对外门面
 *
 * 界面（设置页 / 主页）只跟它打交道：
 *   - 开 / 关同步、改服务器地址、查看状态；
 *   - 服务端要求选择同步方式时，通过 modeRequestListener 让界面弹框，再用 answerMode 回传。
 * 它把 SyncStore（持久化）、LocalLibrary（本地音乐库）、SyncClient（协议）三者接起来。
 */
export class SyncManager {
  private static instance: SyncManager | null = null;

  static getInstance(): SyncManager {
    if (SyncManager.instance === null) {
      SyncManager.instance = new SyncManager();
    }
    return SyncManager.instance;
  }

  private store: SyncStore = new SyncStore();
  private library: LocalLibrary = LocalLibrary.getInstance();
  private client: SyncClient | null = null;
  private config: SyncConfig = { enable: false, host: '', deviceName: '', hostHistory: [] };
  private inited: boolean = false;
  private connectedOnce: boolean = false;
  private progress: number = 0;
  private stage: string = '';

  private modeRequestListener: SyncModeRequestListener | null = null;
  private messageListener: SyncMessageListener | null = null;
  private pendingModeResolve: ((mode: string) => void) | null = null;
  private lastMessage: string = '';

  /** 在 EntryAbility.onCreate 里调用：准备存储并接上界面的音乐库出口 */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.inited = true;
    this.store.init(context);
    initGzip(context.cacheDir);
    this.library.init(context);
    this.config = this.store.loadConfig();
    PlaySession.getInstance().setLibrarySink(this.library);

    this.client = new SyncClient(this.store, this.library);
    this.client.setStatusListener((status: SyncStatus) => {
      this.onStatusChanged(status);
    });
    this.client.setModeSelector((kind: string, serverName: string) => {
      return this.requestMode(kind, serverName);
    });
    this.client.setProgressListener((percent: number, label: string) => {
      this.progress = percent;
      this.stage = label;
      this.publishState();
    });

    // 已经落过库就先镜像到界面（收藏 / 听列表），没落过库就什么都不铺、界面是空的
    if (this.library.isInitialized()) {
      this.library.mirrorToSession();
    }
    this.publishState();

    if (this.config.enable && this.config.host.length > 0) {
      void this.connect().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'auto connect failed: %{public}s', err.message);
      });
    }
  }

  isInited(): boolean {
    return this.inited;
  }

  getLibrary(): LocalLibrary {
    return this.library;
  }

  getConfig(): SyncConfig {
    return this.config;
  }

  deviceName(): string {
    if (this.config.deviceName.length === 0) {
      this.config.deviceName = defaultDeviceName();
    }
    return this.config.deviceName;
  }

  getStatus(): SyncStatus {
    const client = this.client;
    return client === null ? { status: false, message: '' } : client.getStatus();
  }

  getLastMessage(): string {
    return this.lastMessage;
  }

  hostHistory(): string[] {
    return this.config.hostHistory;
  }

  // ------------------------------------------------------------ 界面回调

  setModeRequestListener(listener: SyncModeRequestListener | null): void {
    this.modeRequestListener = listener;
  }

  setMessageListener(listener: SyncMessageListener | null): void {
    this.messageListener = listener;
  }

  /** 界面选完同步方式后回传（传空串或 cancel 都表示取消） */
  answerMode(mode: string): void {
    const resolve = this.pendingModeResolve;
    this.pendingModeResolve = null;
    if (resolve !== null) {
      resolve(mode.length > 0 ? mode : 'cancel');
    }
  }

  private requestMode(kind: string, serverName: string): Promise<string> {
    const listener = this.modeRequestListener;
    if (listener === null) {
      return Promise.resolve('cancel');
    }
    return new Promise<string>((resolve: (mode: string) => void) => {
      // 上一个还没答就直接取消，避免悬挂
      this.answerMode('cancel');
      this.pendingModeResolve = resolve;
      listener(kind, serverName, '');
    });
  }

  // ------------------------------------------------------------ 开关 / 地址

  /** 打开同步并连接 */
  async enable(host: string): Promise<void> {
    const normalized: string = SyncClient.normalizeHost(host);
    if (normalized.length === 0) {
      throw new Error('请先填写同步服务器地址');
    }
    this.updateHost(normalized);
    this.config.enable = true;
    this.config.deviceName = this.deviceName();
    this.store.saveConfig(this.config);
    this.publishState();
    await this.connect();
  }

  /** 关闭同步并断开 */
  async disable(): Promise<void> {
    this.config.enable = false;
    this.store.saveConfig(this.config);
    this.publishState();
    const client = this.client;
    if (client !== null) {
      await client.disconnect();
    }
  }

  /**
   * 回到前台时补一次连接
   *
   * 同步要「配置好之后后台自动连接」：连接断了（或被系统回收）时，
   * 前台恢复就自己补上，不用用户手动点重连。
   */
  async ensureConnected(): Promise<void> {
    if (!this.config.enable || this.config.host.length === 0) {
      return;
    }
    const client = this.client;
    if (client === null || client.isConnected() || client.isReconnecting()) {
      return;
    }
    try {
      await this.connect();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'foreground reconnect failed: %{public}s', (e as Error).message);
    }
  }

  getProgress(): number {
    return this.progress;
  }

  getStage(): string {
    return this.stage;
  }

  /** 用认证码连接（认证失败后用户补填认证码再连） */
  async connectWithCode(authCode: string): Promise<void> {
    const client = this.client;
    if (client === null) {
      throw new Error('同步模块未初始化');
    }
    await client.connect(this.config.host, this.deviceName(), authCode);
  }

  /** 用已保存的密钥连接 */
  private async connect(): Promise<void> {
    const client = this.client;
    if (client === null) {
      throw new Error('同步模块未初始化');
    }
    await client.connect(this.config.host, this.deviceName(), '');
  }

  /** 手动重连（设置页的「重新连接」） */
  async reconnect(): Promise<void> {
    await this.connect();
  }

  updateHost(host: string): void {
    const normalized: string = SyncClient.normalizeHost(host);
    if (normalized.length === 0 || normalized === this.config.host) {
      return;
    }
    this.config.host = normalized;
    if (!this.config.hostHistory.includes(normalized)) {
      this.config.hostHistory.unshift(normalized);
      if (this.config.hostHistory.length > 20) {
        this.config.hostHistory = this.config.hostHistory.slice(0, 20);
      }
    }
    this.store.saveConfig(this.config);
    this.publishState();
  }

  removeHostHistory(host: string): void {
    const remains: string[] = [];
    for (const item of this.config.hostHistory) {
      if (item !== host) {
        remains.push(item);
      }
    }
    this.config.hostHistory = remains;
    this.store.saveConfig(this.config);
  }

  // ------------------------------------------------------------ 状态发布

  private onStatusChanged(status: SyncStatus): void {
    if (status.message.length > 0 && status.message !== this.lastMessage) {
      this.lastMessage = status.message;
      const listener = this.messageListener;
      if (listener !== null) {
        listener(status.message);
      }
    }
    if (status.status && !this.connectedOnce) {
      this.connectedOnce = true;
    }
    this.publishState();
    // 同步过程会整体替换本地列表，通知界面刷新
    this.bumpDataVersion();
  }

  /** 同步数据发生变化（服务端推来或本地库加载）时递增，界面据此刷新 */
  bumpDataVersion(): void {
    const version: number = AppStorage.get<number>(K_SYNC_DATA_VERSION) ?? 0;
    AppStorage.setOrCreate(K_SYNC_DATA_VERSION, version + 1);
  }

  private publishState(): void {
    const client = this.client;
    const status: SyncStatus = client === null ? { status: false, message: '' } : client.getStatus();
    AppStorage.setOrCreate(K_SYNC_ENABLE, this.config.enable);
    AppStorage.setOrCreate(K_SYNC_STATUS, status.status);
    AppStorage.setOrCreate(K_SYNC_MESSAGE, status.message);
    AppStorage.setOrCreate(K_SYNC_PROGRESS, this.progress);
    AppStorage.setOrCreate(K_SYNC_STAGE, this.stage);
  }
}
