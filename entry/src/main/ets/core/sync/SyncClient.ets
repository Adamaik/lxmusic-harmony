import { http, webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { LocalLibrary } from './LocalLibrary';
import { SyncRpc } from './SyncRpc';
import { packMessage, unpackMessage } from './SyncGzip';
import { aesDecryptBase64, aesEncryptBase64, deriveKeyB64, generateRsaKey, rsaDecryptBase64 } from './SyncCrypto';
import { defaultDeviceName, SyncStore } from './SyncStore';
import { FEATURE_VERSION, LxListData, LxSyncAction, SyncKeyInfo, SyncStatus, SyncUrlInfo,
  SYNC_AUTH_MSG, SYNC_CLIENT_TYPE, SYNC_CLOSE_FAILED, SYNC_CLOSE_NORMAL, SYNC_CODE_AUTH_FAILED,
  SYNC_CODE_CONNECTING, SYNC_CODE_CONNECT_SERVICE_FAILED, SYNC_CODE_GET_SERVICE_ID_FAILED,
  SYNC_CODE_HIGH_SERVICE_VERSION, SYNC_CODE_LOW_SERVICE_VERSION, SYNC_CODE_MISSING_AUTH_CODE,
  SYNC_HELLO_MSG, SYNC_ID_PREFIX, SYNC_MSG_AUTH_FAILED, SYNC_MSG_BLOCKED_IP, SYNC_MSG_CONNECT } from './SyncTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SyncClient';

/** /hello 与 /ah 的请求超时（洛雪是 10s） */
const HTTP_TIMEOUT_MS: number = 10000;
/**
 * 服务端每 30s 发一次文本 ping，超过这个时间没收到就当作断线
 *
 * 洛雪官方是 31s（30s + 1s 余量），但这台设备上「加一大批收藏 -> 打包上行」时
 * JS 线程会被压缩/落盘占住，31s 的窗口太容易误判，一次误判就会把连接关掉。
 * 放宽到 3 个 ping 周期：真断了有 WebSocket 的 close 事件兜底，不会漏。
 */
const PING_TIMEOUT_MS: number = 90 * 1000;
/** 建连超时（洛雪是 2 分钟） */
const CONNECT_TIMEOUT_MS: number = 2 * 60 * 1000;

/** getEnabledFeatures 的返回项（与洛雪 EnabledFeatures 一致） */
interface SyncFeatureOptions {
  skipSnapshot: boolean;
}

interface HttpTextResult {
  code: number;
  text: string;
}

export type SyncStatusListener = (status: SyncStatus) => void;
/** 同步方式选择：kind 为 'list' / 'dislike'，返回用户选的那一项 */
export type SyncModeSelector = (kind: string, serverName: string) => Promise<string>;
/** 同步进度：0-100 的百分比 + 当前在做的事（设置页展示用） */
export type SyncProgressListener = (percent: number, label: string) => void;

/**
 * 洛雪同步客户端
 *
 * 流程与服务端驱动逻辑（lx-music-sync-server/src/server/*）逐条对应：
 *   1. GET /hello      —— 校验服务端版本
 *   2. GET /id         —— 拿服务端 id（密钥按 serverId 存）
 *   3. GET /ah         —— 认证：有认证码就用「认证码 + RSA 交换客户端密钥」，
 *                         没有就用存下来的 clientId/key 直接验签
 *   4. WS  /socket     —— 连上后完全由服务端驱动：
 *                          getEnabledFeatures -> list_sync_* / dislike_sync_* -> finished
 *   5. 同步完成后进入实时阶段：本地改动上行 onListSyncAction/onDislikeSyncAction，
 *      服务端把其它设备的改动推回来（onListSyncAction 由服务端调用我们）。
 */
export class SyncClient {
  private store: SyncStore;
  private library: LocalLibrary;
  private statusListener: SyncStatusListener | null = null;
  private modeSelector: SyncModeSelector | null = null;
  private progressListener: SyncProgressListener | null = null;

  private status: SyncStatus = { status: false, message: '' };
  private urlInfo: SyncUrlInfo | null = null;
  private keyInfo: SyncKeyInfo | null = null;
  private ws: webSocket.WebSocket | null = null;
  private rpc: SyncRpc | null = null;

  private connectId: number = 0;
  private reconnecting: boolean = false;
  private connectTimer: number = 0;
  private pingTimer: number = 0;
  private retryTimer: number = 0;
  private failedNum: number = 0;
  /** 消息必须按到达顺序处理：解压是异步的，用一条串行链排队 */
  private inbox: Promise<void> = Promise.resolve();

  private listReady: boolean = false;
  private dislikeReady: boolean = false;

  constructor(store: SyncStore, library: LocalLibrary) {
    this.store = store;
    this.library = library;
  }

  setStatusListener(listener: SyncStatusListener | null): void {
    this.statusListener = listener;
  }

  setModeSelector(selector: SyncModeSelector | null): void {
    this.modeSelector = selector;
  }

  setProgressListener(listener: SyncProgressListener | null): void {
    this.progressListener = listener;
  }

  /** 报告同步进度（握手各阶段 + 列表传输） */
  private reportProgress(percent: number, label: string): void {
    const listener = this.progressListener;
    if (listener !== null) {
      listener(percent, label);
    }
  }

  getStatus(): SyncStatus {
    return this.status;
  }

  isConnected(): boolean {
    return this.status.status;
  }

  /** 是否正在退避重连（前台恢复时别去打断它） */
  isReconnecting(): boolean {
    return this.reconnecting;
  }

  private setStatus(status: boolean, message: string): void {
    this.status.status = status;
    this.status.message = message;
    const listener = this.statusListener;
    if (listener !== null) {
      listener({ status: status, message: message });
    }
  }

  // ------------------------------------------------------------ 连接

  /** 连接服务器；authCode 为空时使用本地保存的密钥 */
  async connect(host: string, deviceName: string, authCode: string): Promise<void> {
    this.connectId++;
    const id: number = this.connectId;
    this.failedNum = 0;
    this.setStatus(false, SYNC_CODE_CONNECTING);
    this.reportProgress(2, '正在连接服务器…');
    try {
      await this.doConnect(host, deviceName, authCode, id);
    } catch (e) {
      if (id !== this.connectId) {
        return;
      }
      const message: string = (e as Error).message;
      this.setStatus(false, message);
      hilog.error(DOMAIN, TAG, 'connect failed: %{public}s', message);
      throw e as Error;
    }
  }

  private async doConnect(host: string, deviceName: string, authCode: string, id: number): Promise<void> {
    await this.teardown(false);
    if (id !== this.connectId) {
      return;
    }
    const urlInfo: SyncUrlInfo = parseUrl(host);
    this.urlInfo = urlInfo;

    await this.checkHello(urlInfo);
    if (id !== this.connectId) {
      return;
    }
    const serverId: string = await this.getServerId(urlInfo);
    if (id !== this.connectId) {
      return;
    }
    const keyInfo: SyncKeyInfo =
      await this.auth(urlInfo, serverId, deviceName, authCode.length > 0 ? authCode : null);
    if (id !== this.connectId) {
      return;
    }
    this.keyInfo = keyInfo;
    this.reportProgress(12, '正在建立长连接…');
    this.openSocket(urlInfo, keyInfo, id);
  }

  /** 断开连接（isReset 为 false 时用于重连前的清理，不改状态文案） */
  async disconnect(): Promise<void> {
    this.connectId++;
    this.reconnecting = false;
    this.failedNum = 0;
    await this.teardown(true);
    this.setStatus(false, '');
    this.reportProgress(0, '');
  }

  private async teardown(resetStatus: boolean): Promise<void> {
    this.clearTimers();
    const ws = this.ws;
    this.ws = null;
    const rpc = this.rpc;
    this.rpc = null;
    if (rpc !== null) {
      rpc.destroy();
    }
    if (ws !== null) {
      try {
        await ws.close({ code: SYNC_CLOSE_NORMAL, reason: '' });
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close socket failed: %{public}s', JSON.stringify(e));
      }
    }
    this.library.setActionSink(null);
    this.listReady = false;
    this.dislikeReady = false;
    if (resetStatus) {
      this.setStatus(false, '');
    }
  }

  // ------------------------------------------------------------ 握手 / 认证

  private async checkHello(urlInfo: SyncUrlInfo): Promise<void> {
    const result: HttpTextResult =
      await this.httpGet(`${urlInfo.httpProtocol}//${urlInfo.hostPath}/hello`, {}, HTTP_TIMEOUT_MS);
    if (result.text === SYNC_HELLO_MSG) {
      return;
    }
    if (result.text.startsWith('Hello~::^-^::')) {
      const remote: number = parseHelloVersion(result.text);
      const local: number = parseHelloVersion(SYNC_HELLO_MSG);
      if (remote > local) {
        throw new Error(SYNC_CODE_HIGH_SERVICE_VERSION);
      }
      if (remote < local) {
        throw new Error(SYNC_CODE_LOW_SERVICE_VERSION);
      }
    }
    throw new Error(SYNC_CODE_CONNECT_SERVICE_FAILED);
  }

  private async getServerId(urlInfo: SyncUrlInfo): Promise<string> {
    const result: HttpTextResult =
      await this.httpGet(`${urlInfo.httpProtocol}//${urlInfo.hostPath}/id`, {}, HTTP_TIMEOUT_MS);
    if (!result.text.startsWith(SYNC_ID_PREFIX)) {
      throw new Error(SYNC_CODE_GET_SERVICE_ID_FAILED);
    }
    return result.text.substring(SYNC_ID_PREFIX.length);
  }

  private async auth(urlInfo: SyncUrlInfo, serverId: string, deviceName: string,
    authCode: string | null): Promise<SyncKeyInfo> {
    if (authCode !== null) {
      return await this.authByCode(urlInfo, serverId, deviceName, authCode);
    }
    const saved: SyncKeyInfo | null = this.store.loadKey(serverId);
    if (saved === null) {
      throw new Error(SYNC_CODE_MISSING_AUTH_CODE);
    }
    await this.authByKey(urlInfo, deviceName, saved);
    return saved;
  }

  /** 认证码方式：用认证码派生的 AES 密钥把「RSA 公钥 + 设备名」交给服务端，换回身份信息 */
  private async authByCode(urlInfo: SyncUrlInfo, serverId: string, deviceName: string,
    authCode: string): Promise<SyncKeyInfo> {
    const b64Key: string = deriveKeyB64(authCode);
    const pair = await generateRsaKey();
    const payload: string =
      `${SYNC_AUTH_MSG}\n${pair.publicKey}\n${deviceName}\n${SYNC_CLIENT_TYPE}`;
    const msg: string = aesEncryptBase64(payload, b64Key);
    const headers: Record<string, string> = { 'm': msg };
    const result: HttpTextResult =
      await this.httpGet(`${urlInfo.httpProtocol}//${urlInfo.hostPath}/ah`, headers, HTTP_TIMEOUT_MS);
    if (result.text === SYNC_MSG_BLOCKED_IP) {
      throw new Error(SYNC_MSG_BLOCKED_IP);
    }
    if (result.text === SYNC_MSG_AUTH_FAILED) {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    if (result.code !== 200) {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    let plain: string;
    try {
      plain = await rsaDecryptBase64(result.text, pair.privateKey);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'rsa decrypt failed: %{public}s', JSON.stringify(e));
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    let info: SyncKeyInfo;
    try {
      info = JSON.parse(plain) as SyncKeyInfo;
    } catch (e) {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    if (info === null || info === undefined || typeof info.clientId !== 'string'
      || typeof info.key !== 'string') {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    this.store.saveKey(serverId, info);
    return info;
  }

  /** 已保存密钥方式：用 clientId + AES 密钥验证身份 */
  private async authByKey(urlInfo: SyncUrlInfo, deviceName: string, keyInfo: SyncKeyInfo): Promise<void> {
    const msg: string = aesEncryptBase64(SYNC_AUTH_MSG + deviceName, keyInfo.key);
    const headers: Record<string, string> = { 'i': keyInfo.clientId, 'm': msg };
    const result: HttpTextResult =
      await this.httpGet(`${urlInfo.httpProtocol}//${urlInfo.hostPath}/ah`, headers, HTTP_TIMEOUT_MS);
    if (result.code !== 200) {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    let plain: string;
    try {
      plain = aesDecryptBase64(result.text, keyInfo.key);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'aes decrypt failed: %{public}s', JSON.stringify(e));
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
    if (plain !== SYNC_HELLO_MSG) {
      throw new Error(SYNC_CODE_AUTH_FAILED);
    }
  }

  private async httpGet(url: string, headers: Record<string, string>, timeout: number): Promise<HttpTextResult> {
    const request = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeout,
        readTimeout: timeout,
      });
      const raw: string | Object | ArrayBuffer = response.result;
      const text: string = typeof raw === 'string' ? raw as string : JSON.stringify(raw);
      return { code: response.responseCode, text: text };
    } finally {
      request.destroy();
    }
  }

  // ------------------------------------------------------------ WebSocket

  private openSocket(urlInfo: SyncUrlInfo, keyInfo: SyncKeyInfo, id: number): void {
    const ticket: string = aesEncryptBase64(SYNC_MSG_CONNECT, keyInfo.key);
    const url: string = `${urlInfo.wsProtocol}//${urlInfo.hostPath}/socket` +
      `?i=${encodeURIComponent(keyInfo.clientId)}&t=${encodeURIComponent(ticket)}`;
    const rpc = new SyncRpc((payload: string) => {
      this.sendPayload(payload);
    });
    this.rpc = rpc;
    this.registerHandlers(rpc);
    const socket = webSocket.createWebSocket();
    this.ws = socket;

    socket.on('open', () => {
      if (id !== this.connectId || socket !== this.ws) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'socket opened');
      this.failedNum = 0;
      this.listReady = false;
      this.dislikeReady = false;
      // 同步完成后本地改动要能上行；是否真的发送由 listReady/dislikeReady 把关
      this.library.setActionSink((action: LxSyncAction, kind: string) => {
        this.emitAction(action, kind);
      });
      this.armConnectTimeout(socket);
      // 文本 ping 的存活检测也在这里开个头：少数服务端不给非移动端发 ping，
      // 一上来就计时会把正常连接误判成断线（WS 层的 close 事件已经能兜住真正的断开），
      // 但移动端类型（lx_music_mobile）服务端是会发的。
      this.armPingTimeout(socket);
      this.setStatus(false, 'Wait syncing...');
      this.reportProgress(16, '长连接已建立，等待同步…');
    });

    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (id !== this.connectId || socket !== this.ws) {
        return;
      }
      if (err !== undefined && err !== null && err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'socket message error: %{public}s', err.message);
        return;
      }
      // 收到任何报文都说明链路还活着：立刻续一次存活计时，而不是等排队处理完。
      // 打包上行大列表时 JS 线程会被占住，处理时机可能晚于计时器。
      this.armPingTimeout(socket);
      this.enqueueIncoming(value);
    });

    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      // 重连时我们会先 close 掉旧 socket，它的 close 事件往往晚于新连接建立才到；
      // 那种迟到的旧事件不能去动新连接的 rpc / 计时器，否则新连接刚建好就被拆了
      if (id !== this.connectId || socket !== this.ws) {
        return;
      }
      if (err !== undefined && err !== null && err.code !== 0) {
        hilog.warn(DOMAIN, TAG, 'socket close with error: %{public}s', err.message);
      }
      const code: number = value !== undefined && value !== null ? value.code : 0;
      hilog.info(DOMAIN, TAG, 'socket closed, code=%{public}d', code);
      this.ws = null;
      this.onSocketClosed(code);
    });

    socket.on('error', (err: BusinessError) => {
      if (id !== this.connectId || socket !== this.ws) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'socket error: %{public}s', JSON.stringify(err));
      this.setStatus(false, err !== undefined && err !== null && err.message !== undefined
        ? err.message : 'connect error');
    });

    socket.connect(url).catch((err: BusinessError) => {
      if (id !== this.connectId || socket !== this.ws) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'connect socket failed: %{public}s', JSON.stringify(err));
      this.setStatus(false, err.message);
    });
  }

  private sendPayload(payload: string): void {
    const socket = this.ws;
    if (socket === null) {
      throw new Error('sync socket is not connected');
    }
    packMessage(payload).then((packed: string) => {
      const target = this.ws;
      if (target === null) {
        return;
      }
      target.send(packed).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'send failed: %{public}s', JSON.stringify(err));
      });
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'pack message failed: %{public}s', err.message);
    });
  }

  private enqueueIncoming(value: string | ArrayBuffer): void {
    this.inbox = this.inbox.then(() => this.handleIncoming(value)).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'handle message failed: %{public}s', err.message);
    });
  }

  private async handleIncoming(value: string | ArrayBuffer): Promise<void> {
    let text: string;
    if (typeof value === 'string') {
      text = value as string;
    } else {
      // 服务端只发字符串，这里做个兜底，免得遇到二进制帧直接丢消息
      const decoder = util.TextDecoder.create('utf-8');
      text = decoder.decodeToString(new Uint8Array(value as ArrayBuffer));
    }
    if (text === 'ping') {
      // 存活计时在 WS 的 message 事件里已经续过了（那才是收到的时间点）
      return;
    }
    let payload: string;
    try {
      payload = await unpackMessage(text);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'unpack message failed: %{public}s', JSON.stringify(e));
      const socket = this.ws;
      if (socket !== null) {
        socket.close({ code: SYNC_CLOSE_FAILED, reason: '' }).catch(() => {
        });
      }
      return;
    }
    const rpc = this.rpc;
    if (rpc !== null) {
      rpc.onMessage(payload);
    }
  }

  private onSocketClosed(code: number): void {
    this.clearTimers();
    const rpc = this.rpc;
    this.rpc = null;
    if (rpc !== null) {
      rpc.destroy();
    }
    this.library.setActionSink(null);
    this.listReady = false;
    this.dislikeReady = false;
    this.reportProgress(0, '');
    // 能走到这里的都是「服务端 / 网络那边断开」：本机主动断开（关同步、重连前清理）
    // 已经在 teardown 里把 ws 置空，close 事件不会再进来。所以不管什么关闭码都
    // 退避重连 —— 后台同步要能自己恢复，不能一次抖动就永久停在「已断开」。
    if (code === SYNC_CLOSE_FAILED && this.status.message.length === 0) {
      this.setStatus(false, 'failed');
    }
    this.scheduleReconnect();
  }

  // ------------------------------------------------------------ 心跳 / 重连

  private armPingTimeout(socket: webSocket.WebSocket | null): void {
    if (this.pingTimer !== 0) {
      clearTimeout(this.pingTimer);
    }
    if (socket === null) {
      return;
    }
    this.pingTimer = setTimeout(() => {
      this.pingTimer = 0;
      hilog.warn(DOMAIN, TAG, 'ping timeout, close socket');
      const target = this.ws;
      if (target !== null) {
        target.close({ code: SYNC_CLOSE_FAILED, reason: '' }).catch(() => {
        });
      }
    }, PING_TIMEOUT_MS);
  }

  private armConnectTimeout(socket: webSocket.WebSocket): void {
    if (this.connectTimer !== 0) {
      clearTimeout(this.connectTimer);
    }
    this.connectTimer = setTimeout(() => {
      this.connectTimer = 0;
      hilog.warn(DOMAIN, TAG, 'connect timeout');
      socket.close({ code: SYNC_CLOSE_FAILED, reason: '' }).catch(() => {
      });
    }, CONNECT_TIMEOUT_MS);
  }

  /** 意外断开后的重连（与洛雪一致：2s 起步，随失败次数增长，最多 30s） */
  private scheduleReconnect(): void {
    const urlInfo = this.urlInfo;
    const keyInfo = this.keyInfo;
    if (urlInfo === null || keyInfo === null) {
      return;
    }
    this.reconnecting = true;
    this.failedNum++;
    const wait: number = Math.min(2000 + Math.floor(this.failedNum / 2) * 3000, 30000);
    this.setStatus(false, `Try reconnect... (${this.failedNum})`);
    this.reportProgress(0, `连接已断开，${Math.round(wait / 1000)} 秒后重连（第 ${this.failedNum} 次）`);
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = 0;
      if (!this.reconnecting) {
        return;
      }
      const id: number = this.connectId;
      this.teardown(false).then(() => {
        if (id !== this.connectId) {
          return;
        }
        this.reconnecting = false;
        this.reportProgress(10, '正在重连…');
        this.openSocket(urlInfo, keyInfo, id);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'reconnect failed: %{public}s', err.message);
      });
    }, wait);
  }

  private clearTimers(): void {
    if (this.pingTimer !== 0) {
      clearTimeout(this.pingTimer);
      this.pingTimer = 0;
    }
    if (this.connectTimer !== 0) {
      clearTimeout(this.connectTimer);
      this.connectTimer = 0;
    }
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = 0;
    }
  }

  // ------------------------------------------------------------ 上行

  /** 本地改动 -> 服务端 */
  private emitAction(action: LxSyncAction, kind: string): void {
    const rpc = this.rpc;
    if (rpc === null || rpc.isDestroyed()) {
      return;
    }
    if (kind === 'list' && !this.listReady) {
      return;
    }
    if (kind === 'dislike' && !this.dislikeReady) {
      return;
    }
    const method: string = kind === 'dislike' ? 'onDislikeSyncAction' : 'onListSyncAction';
    rpc.call([method], [action]).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'send %{public}s failed: %{public}s', method, err.message);
    });
  }

  // ------------------------------------------------------------ 服务端调用的方法

  private registerHandlers(rpc: SyncRpc): void {
    rpc.register('getEnabledFeatures', async (args: Object[]) => {
      return this.handleGetEnabledFeatures(args);
    });
    rpc.register('finished', async () => {
      this.handleFinished();
      return undefined;
    });

    rpc.register('list_sync_get_md5', async () => {
      this.reportProgress(28, '正在校验试听列表…');
      return this.library.listDataMd5();
    });
    rpc.register('list_sync_get_sync_mode', async () => {
      this.reportProgress(33, '等待选择同步方式…');
      return await this.selectMode('list');
    });
    rpc.register('list_sync_get_list_data', async () => {
      this.reportProgress(45, '正在同步试听列表…');
      return this.library.listData() as Object;
    });
    rpc.register('list_sync_set_list_data', async (args: Object[]) => {
      this.reportProgress(45, '正在同步试听列表…');
      const data = args.length > 0 ? args[0] as LxListData : null;
      if (data !== null) {
        this.library.applyRemoteListData(data);
      }
      return undefined;
    });
    rpc.register('list_sync_finished', async () => {
      this.listReady = true;
      this.library.onListSynced();
      this.reportProgress(55, '试听列表已同步');
      return undefined;
    });

    rpc.register('dislike_sync_get_md5', async () => {
      this.reportProgress(62, '正在校验不喜欢规则…');
      return this.library.dislikeMd5();
    });
    rpc.register('dislike_sync_get_sync_mode', async () => {
      this.reportProgress(68, '等待选择同步方式…');
      return await this.selectMode('dislike');
    });
    rpc.register('dislike_sync_get_list_data', async () => {
      this.reportProgress(78, '正在同步不喜欢规则…');
      return this.library.dislikeRules();
    });
    rpc.register('dislike_sync_set_list_data', async (args: Object[]) => {
      this.reportProgress(78, '正在同步不喜欢规则…');
      const rules: string = args.length > 0 && typeof args[0] === 'string' ? args[0] as string : '';
      this.library.applyRemoteDislikeData(rules);
      return undefined;
    });
    rpc.register('dislike_sync_finished', async () => {
      this.dislikeReady = true;
      this.library.onDislikeSynced();
      this.reportProgress(90, '不喜欢规则已同步');
      return undefined;
    });
  }

  /**
   * 能力协商（服务端第一件事就是调它）
   *
   * 我们两个模块都支持快照版本 1，但不支持 skipSnapshot（与洛雪移动端一致），
   * 服务端会因此走「对比 md5 -> 询问同步方式 -> 合并」的完整流程。
   */
  private handleGetEnabledFeatures(args: Object[]): Record<string, Object> {
    const features: Record<string, Object> = {};
    const supported: Object | undefined = args.length > 1 ? args[1] : undefined;
    const names: string[] = ['list', 'dislike'];
    for (const name of names) {
      const supportedVersion: number = supportedVersionOf(supported, name);
      if (supportedVersion === FEATURE_VERSION[name]) {
        const options: SyncFeatureOptions = { skipSnapshot: false };
        features[name] = options as Object;
      }
    }
    return features;
  }

  private handleFinished(): void {
    if (this.connectTimer !== 0) {
      clearTimeout(this.connectTimer);
      this.connectTimer = 0;
    }
    this.failedNum = 0;
    this.setStatus(true, '');
    this.reportProgress(100, '同步完成');
  }

  private async selectMode(kind: string): Promise<string> {
    // 走到这里说明服务端在等我们（界面会弹选择框）。等用户点选的时间可能超过
    // 建连超时，那不是网络问题，别把连接关掉；链路是否还活着交给心跳判断。
    if (this.connectTimer !== 0) {
      clearTimeout(this.connectTimer);
      this.connectTimer = 0;
    }
    const selector = this.modeSelector;
    const serverName: string = this.keyInfo !== null && this.keyInfo.serverName !== undefined
      ? this.keyInfo.serverName : '';
    if (selector === null) {
      return 'cancel';
    }
    try {
      const mode: string = await selector(kind, serverName);
      return mode.length > 0 ? mode : 'cancel';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'select sync mode failed: %{public}s', JSON.stringify(e));
      return 'cancel';
    }
  }

  /** 供设置页展示：解析设备名（与认证时使用的一致） */
  deviceName(): string {
    return defaultDeviceName();
  }

  /** 服务器地址是否可用（配置里存着的地址） */
  static normalizeHost(host: string): string {
    let value: string = host.trim();
    if (value.length === 0) {
      return '';
    }
    if (!/^https?:\/\//.test(value)) {
      value = `http://${value}`;
    }
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}

// ------------------------------------------------------------------ 工具

/** 解析 'Hello~::^-^::~v4~' 里的版本号 */
function parseHelloVersion(text: string): number {
  const match: RegExpMatchArray | null = text.match(/v(\d+)/);
  if (match === null || match.length < 2) {
    return 0;
  }
  const value: number = Number.parseInt(match[1], 10);
  return Number.isNaN(value) ? 0 : value;
}

/** 解析并规范化服务器地址（对应洛雪 parseUrl） */
export function parseUrl(host: string): SyncUrlInfo {
  let href: string = host.trim();
  while (href.endsWith('/')) {
    href = href.substring(0, href.length - 1);
  }
  const httpProtocol: string = /^https:/.test(href) ? 'https:' : 'http:';
  const wsProtocol: string = httpProtocol === 'https:' ? 'wss:' : 'ws:';
  const hostPath: string = href.replace(`${httpProtocol}//`, '');
  return {
    href: href,
    httpProtocol: httpProtocol,
    wsProtocol: wsProtocol,
    hostPath: hostPath,
  };
}

function supportedVersionOf(supported: Object | undefined, name: string): number {
  if (supported === undefined || supported === null) {
    return -1;
  }
  const map = supported as Record<string, number>;
  const value: number | undefined = map[name];
  return value === undefined ? -1 : value;
}
