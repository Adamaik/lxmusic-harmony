import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  BridgeInitData,
  BridgePicResultData,
  BridgeResponseData,
  BridgeResult,
  LxBootstrap,
  LxQuality,
  ScriptErrorData,
  SourceInfo,
  SourceLog,
  SupportedSource,
  UpdateAlertData,
} from './LxTypes';
import { SourceStore, ActiveSource } from './SourceStore';
import { MAX_SCRIPT_SIZE, buildSourceInfo, sourceMetaKey } from './LxMetadata';
import { LxRequestHandle, LxRequestOptions, LxResponse, lxRequest } from './LxHttp';
import { utf8Bytes } from '../music/LxCrypto';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceEngine';

const PAGE_READY_TIMEOUT: number = 10000;
const INIT_TIMEOUT: number = 10000;
/**
 * 等待源脚本解析出播放链接的上限。
 * 洛雪本身对 sendAction 不做超时（一直等），这里给一个足够宽松的上限：
 * 很多音源是「代理型」的（脚本再请求一个中转 API），冷启动 + 多次串行请求都可能很慢，
 * 超时太短只会把本来能成功的解析误判成失败。沙箱里 lx.request 自己的 timeout 上限是 60s。
 */
const REQUEST_TIMEOUT: number = 60000;

/**
 * 沙箱资源读不到时的提示。
 * DevEco Previewer（预览器）会把 rawfile / fs / TextDecoder 换成 mock，
 * 此时 lx_utils.js / lx_preload.js 内容为空，沙箱无法工作。
 */
export const SANDBOX_UNAVAILABLE_MESSAGE: string =
  '音源沙箱资源不可用：当前环境（如 DevEco Previewer 预览器）mock 了 rawfile 读取，导致 lx_utils.js / lx_preload.js 为空。请在模拟器或真机上运行。';

interface PendingResponse {
  resolve: (value: string) => void;
  reject: (reason: Error) => void;
  timer: number;
}

/** 沙箱 lx.request(url, options) 里的 options（见 lx_preload.js 的 lx.request） */
interface NativeRequestOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Object;
  form?: Record<string, string>;
  formData?: Record<string, string>;
  timeout?: number;
  binary?: boolean;
}

/** 桥接消息 'request' 的负载：{ requestKey, url, options } */
interface NativeRequestMessage {
  requestKey?: string;
  url?: string;
  options?: NativeRequestOptions;
}

/** 回灌沙箱的 HTTP 响应体（对应 lx_preload.js 里 callback(err, resp) 的 resp） */
interface NativeResponseBody {
  statusCode: number;
  statusMessage: string;
  headers: Record<string, string>;
  body: string | Object | number[];
}

/** 桥接回灌消息 'response' 的负载：{ requestKey, error, response } */
interface NativeResponseMessage {
  requestKey: string;
  error: string | null;
  response: NativeResponseBody | null;
}

/**
 * 洛雪音乐自定义音源核心引擎（HarmonyOS 版）
 *
 * 对应 lx-music-mobile 的组合：
 *   - src/core/userApi.ts                      导入 / 删除 / 加载音源
 *   - src/core/apiSource.ts                    切换音源 -> 拿到各平台 apis
 *   - src/core/init/userApi/index.ts            桥接：init / request / response / log
 *   - src/utils/nativeModules/userApi.ts        loadScript / sendAction
 *   - android/.../userApi/QuickJS.java          JS 沙箱
 *   - android/assets/script/user-api-preload.js 沙箱内的 lx API
 *   - src/core/music/utils.ts#handleGetOnlineMusicUrl  取播放链接的主链路
 *
 * 实现方式：用 ArkWeb 承载 lx_preload.js，得到一个可执行源脚本（源规则）的沙箱；
 * 沙箱里 lx.request 产生的网络请求通过 lxBridge 回调到 ArkTS，由 LxHttp 代理，
 * 再把响应送回沙箱。这与洛雪「QuickJS 沙箱 + 原生代理网络」的架构一一对应。
 *
 * 使用方式（外部调用只需三步）：
 *   1. 页面挂载 SourceSandboxHost（注入沙箱宿主）
 *   2. const info = await SourceEngine.getInstance().importFromUrl(url)   // 导入源
 *      或 SourceEngine.getInstance().importSource(scriptText)
 *   3. await SourceEngine.getInstance().loadSource(info.id)               // 初始化源
 *      const playUrl = await SourceEngine.getInstance().getMusicUrl(musicInfoJson, '320k', 'kw')
 */
export class SourceEngine {
  private static instance: SourceEngine | null = null;

  static getInstance(): SourceEngine {
    if (SourceEngine.instance === null) {
      SourceEngine.instance = new SourceEngine();
    }
    return SourceEngine.instance;
  }

  private store: SourceStore = new SourceStore();
  private controller: webview.WebviewController | null = null;
  private bridge: object | null = null;
  /** 桥接已通过自检 */
  private bridgeReady: boolean = false;
  /** 引擎代码已注入当前页面（之后加载源只在页面内重置，不再 reload） */
  private engineInjected: boolean = false;
  private prepared: boolean = false;
  private sandboxAssetsMissing: boolean = false;
  private utilsJs: string = '';
  private preloadJs: string = '';

  private pageReady: boolean = false;
  private pageWaiters: (() => void)[] = [];

  private scriptKey: string = '';
  private loadedSourceId: string = '';
  private inited: boolean = false;
  private supported: Record<string, SupportedSource> = {};
  private sandboxEnv: string = 'mobile';

  private bridgeProbeResolve: (() => void) | null = null;
  private probeCount: number = 0;
  /** 启动后的「自动恢复上次音源」是否已经尝试过 */
  private restoreTried: boolean = false;
  /** 正在自动恢复上次的音源（界面据此决定「准备音源」要不要等一等） */
  private restoring: boolean = false;
  /** 脚本自己抛出的错误（源脚本里的 throw / 运行时报错），失败时优先展示它 */
  private lastScriptError: string = '';

  private initResolve: ((value: Record<string, SupportedSource>) => void) | null = null;
  private initReject: ((reason: Error) => void) | null = null;
  private initTimer: number = 0;

  private pending: Map<string, PendingResponse> = new Map();
  private requestSeq: number = 0;
  /** 源脚本发起、正在由宿主代理的 HTTP 请求（requestKey -> 句柄，用于取消） */
  private httpRequests: Map<string, LxRequestHandle> = new Map();
  /** 最近一次音源请求的响应摘要（状态码/长度/片段），源脚本报错时一并展示，便于定位 */
  private lastResponseExcerpt: string = '';

  private logs: SourceLog[] = [];
  private logListener: ((log: SourceLog) => void) | null = null;
  private maxLogs: number = 300;

  // ------------------------------------------------------------ 生命周期

  /** 读取 rawfile 中的沙箱引擎代码，只需要调用一次 */
  prepare(context: common.Context): void {
    if (this.prepared) {
      return;
    }
    this.store.init(context);
    // 老版本导入时不去重，同一个源可能存了好几份，启动时清一次
    if (this.store.isReady()) {
      this.dedupeStored();
    }
    const decoder = util.TextDecoder.create('utf-8');
    const rm = context.resourceManager;
    this.utilsJs = decoder.decodeToString(rm.getRawFileContentSync('lx_utils.js'));
    this.preloadJs = decoder.decodeToString(rm.getRawFileContentSync('lx_preload.js'));
    this.sandboxAssetsMissing = this.utilsJs.length === 0 || this.preloadJs.length === 0;
    this.prepared = true;
    if (this.sandboxAssetsMissing) {
      this.pushLog('error', SANDBOX_UNAVAILABLE_MESSAGE);
    }
  }

  /** 由 SourceSandboxHost 调用，绑定 Web 控制器与桥对象 */
  attach(controller: webview.WebviewController, bridge: object): void {
    this.controller = controller;
    this.bridge = bridge;
  }

  /** 由 SourceSandboxHost 的 onPageEnd 调用 */
  onPageEnd(): void {
    this.pageReady = true;
    const waiters: (() => void)[] = this.pageWaiters;
    this.pageWaiters = [];
    for (const waiter of waiters) {
      waiter();
    }
  }

  isPrepared(): boolean {
    return this.prepared;
  }

  isAttached(): boolean {
    return this.controller !== null;
  }

  /** rawfile 读不到（预览器 mock）时为 true，表示沙箱不可用 */
  isSandboxAvailable(): boolean {
    return this.prepared && !this.sandboxAssetsMissing;
  }

  getStatus(): string {
    if (!this.prepared) {
      return '引擎未初始化';
    }
    if (this.controller === null) {
      return '沙箱未挂载（页面缺少 SourceSandboxHost）';
    }
    if (this.loadedSourceId.length === 0) {
      return '未加载音源';
    }
    return this.inited ? `已就绪：${this.loadedSourceId}` : `加载中/失败：${this.loadedSourceId}`;
  }

  isInited(): boolean {
    return this.inited;
  }

  getSupportedSources(): Record<string, SupportedSource> {
    return this.supported;
  }

  getLoadedSourceId(): string {
    return this.loadedSourceId;
  }

  /** 沙箱内 lx.env 的取值。部分源脚本只在特定 env 下调用 lx.send('inited')。 */
  setSandboxEnv(env: string): void {
    this.sandboxEnv = env === 'desktop' ? 'desktop' : 'mobile';
  }

  getSandboxEnv(): string {
    return this.sandboxEnv;
  }

  // ------------------------------------------------------------ 导入 / 管理

  /** 导入源脚本正文 */
  importSource(script: string): SourceInfo {
    if (!this.prepared) {
      throw new Error('SourceEngine 未初始化，请先调用 prepare(context)');
    }
    if (script.length > MAX_SCRIPT_SIZE) {
      throw new Error('源脚本过大（超过 9MB）');
    }
    const info: SourceInfo = buildSourceInfo(script);
    // 同一个源（名字+版本+作者相同）重复导入时不再新增一条，改为覆盖更新，
    // 否则导入两次同一个链接就会在列表里堆出两条一模一样的音源。
    const duplicate: SourceInfo | null = this.findDuplicate(info);
    if (duplicate !== null) {
      const same: boolean = this.isSameScript(duplicate.id, script);
      const updated: SourceInfo = this.store.replace(duplicate.id, info, script);
      this.pushLog('info', same
        ? `该音源已存在，跳过重复导入：${updated.name} [${updated.id}]`
        : `该音源已存在，已用新脚本覆盖更新：${updated.name} [${updated.id}]`);
      return updated;
    }
    this.store.add(info, script);
    this.pushLog('info', `导入音源成功：${info.name} [${info.id}]`);
    return info;
  }

  /** 列表里是否已有同名/同版本/同作者的源 */
  private findDuplicate(info: SourceInfo): SourceInfo | null {
    const key: string = sourceMetaKey(info);
    const list: SourceInfo[] = this.store.list();
    for (const item of list) {
      if (sourceMetaKey(item) === key) {
        return item;
      }
    }
    return null;
  }

  /** 旧脚本正文是否与本次导入的完全一致（一致则只是重复导入，不必覆盖） */
  private isSameScript(id: string, script: string): boolean {
    try {
      if (!this.store.hasScript(id)) {
        return false;
      }
      return this.store.getScript(id) === script;
    } catch (e) {
      return false;
    }
  }

  /**
   * 清理历史遗留的重复音源（早期版本导入时不去重，同一个源会存好几份）。
   * 按「名字+版本+作者」分组，每组只保留最早导入的那条，其余连脚本一起删掉。
   */
  private dedupeStored(): void {
    const list: SourceInfo[] = this.store.list();
    const kept: Record<string, string> = {};
    const remove: string[] = [];
    for (const item of list) {
      const key: string = sourceMetaKey(item);
      const existing: string | undefined = kept[key];
      if (existing === undefined) {
        kept[key] = item.id;
      } else {
        remove.push(item.id);
      }
    }
    if (remove.length === 0) {
      return;
    }
    this.store.remove(remove);
    this.pushLog('info', `已清理 ${remove.length} 条重复音源`);
  }

  /** 通过链接导入源脚本（对应洛雪的「导入在线源」） */
  async importFromUrl(url: string): Promise<SourceInfo> {
    if (!/^https?:\/\//.test(url)) {
      throw new Error('请输入以 http:// 或 https:// 开头的音源链接');
    }
    this.pushLog('info', `正在下载音源：${url}`);
    const script: string = await new Promise<string>((resolve, reject) => {
      lxRequest(url, { method: 'get', timeout: 20000, rawText: true }, (resp: LxResponse) => {
        const body = resp.body;
        resolve(typeof body === 'string' ? body : JSON.stringify(body));
      }, (message: string) => {
        reject(new Error(`下载音源失败：${message}`));
      });
    });
    return this.importSource(script);
  }

  listSources(): SourceInfo[] {
    return this.store.list();
  }

  removeSource(id: string): SourceInfo[] {
    const remains: SourceInfo[] = this.store.remove([id]);
    // 删掉的正好是「上次加载的源」，把恢复记录一起清掉，免得下次启动去加载一个不存在的 id
    const active: ActiveSource | null = this.store.loadActive();
    if (active !== null && active.id === id) {
      this.store.clearActive();
    }
    return remains;
  }

  /**
   * 启动后自动恢复上次加载的音源
   *
   * 以前每次重启都要去音源设置里重新点一次：加载的是哪个源只存在内存里。
   * 这里在沙箱页面就绪后调用（SourceSandboxHost.onPageEnd），只做一次；
   * 失败只记日志，用户仍可到音源设置里手动选择。
   */
  async restoreLastSource(): Promise<boolean> {
    if (this.restoreTried) {
      return false;
    }
    this.restoreTried = true;
    if (this.inited || !this.prepared || this.sandboxAssetsMissing) {
      return false;
    }
    const active: ActiveSource | null = this.store.loadActive();
    if (active === null || active.id === undefined || active.id.length === 0) {
      return false;
    }
    this.setSandboxEnv(active.env);
    this.restoring = true;
    try {
      await this.loadSource(active.id);
      this.pushLog('info', `已自动恢复上次的音源：${active.id}`);
      return true;
    } catch (e) {
      this.pushLog('warn', `自动恢复音源失败：${(e as Error).message}（可到音源设置里手动选择）`);
      return false;
    } finally {
      this.restoring = false;
    }
  }

  /** 正在自动恢复上次的音源 */
  isRestoring(): boolean {
    return this.restoring;
  }

  /**
   * 等音源初始化完成（正在自动恢复时用）。
   * 刚启动的那几秒源脚本还在沙箱里跑，这时候点播放不该直接报「音源未加载」。
   * 返回是否就绪；超时就返回 false，由调用方照常报错。
   */
  async whenInited(timeoutMs: number): Promise<boolean> {
    if (this.inited) {
      return true;
    }
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 200);
      });
      if (this.inited) {
        return true;
      }
    }
    return this.inited;
  }

  // ------------------------------------------------------------ 加载源（初始化）

  /**
   * 在沙箱中加载并初始化一个音源。
   * 每次加载都会刷新沙箱页面，保证不同源脚本的全局上下文互不污染
   * （对应洛雪每次 loadScript 都会新建 QuickJSContext）。
   */
  async loadSource(id: string): Promise<Record<string, SupportedSource>> {
    if (!this.prepared) {
      throw new Error('SourceEngine 未初始化，请先调用 prepare(context)');
    }
    const controller = this.controller;
    if (controller === null) {
      throw new Error('音源沙箱未挂载，请确认页面中存在 SourceSandboxHost');
    }
    const info: SourceInfo | null = this.store.find(id);
    if (info === null) {
      throw new Error(`音源不存在：${id}`);
    }
    if (this.sandboxAssetsMissing) {
      throw new Error(SANDBOX_UNAVAILABLE_MESSAGE);
    }
    const script: string = this.store.getScript(id);

    this.inited = false;
    this.supported = {};
    this.lastScriptError = '';
    this.loadedSourceId = id;
    this.scriptKey = `lx_${Math.random().toString(36).substring(2)}_${Date.now()}`;
    this.pushLog('info', `开始加载音源：${info.name}`);

    // 1) 等待宿主页首次加载完成。之后不再 refresh：registerJavaScriptProxy 注册的对象
    //    要等页面下次 (re)load 才生效，频繁 reload 会让桥接状态变得不确定。
    await this.whenPageReady(PAGE_READY_TIMEOUT);

    // 2) 确保桥接可用（必要时用「显式注册 + reload」兜底一次）
    await this.ensureBridge();

    // 3) 页面内重置上一次的源脚本状态，再注入引擎
    this.abortHttpRequests();
    if (this.engineInjected) {
      await this.callJs('if (typeof __lx_destroy__ === "function") { __lx_destroy__(); }');
    }
    await this.injectEngine(info, script);
    this.engineInjected = true;

    // 4) 先挂 init 等待再执行脚本，避免脚本同步调用 lx.send('inited') 造成竞态
    const initPromise = new Promise<Record<string, SupportedSource>>((resolve, reject) => {
      this.initResolve = resolve;
      this.initReject = reject;
      this.initTimer = setTimeout(() => {
        this.initResolve = null;
        this.initReject = null;
        this.initTimer = 0;
        // 超时时把沙箱自检状态带上，否则「没 inited」无从判断是脚本没跑起来还是它自己没走到初始化
        this.readDebugState().then((state: SandboxDebugState) => {
          const scriptErr: string = this.lastScriptError.length > 0 ? `脚本抛出：${this.lastScriptError}。` : '';
          reject(new Error(
            `音源初始化超时：脚本已执行但没有调用 lx.send("inited")。${scriptErr}沙箱状态：${state.raw}`,
          ));
        }).catch(() => {
          reject(new Error(
            '音源初始化超时：脚本已执行但没有调用 lx.send("inited")。' +
            '可能原因：脚本报错（看日志）、脚本要求 lx.env 为 desktop（可切换兼容模式）、或脚本不是洛雪自定义源格式。',
          ));
        });
      }, INIT_TIMEOUT);
    });

    if (looksLikeEsm(script)) {
      this.cancelInitWait();
      throw new Error('源脚本是 ES Module（含顶层 import/export），本引擎只支持洛雪自定义源脚本（普通脚本）');
    }
    this.pushLog('info', `源脚本长度 ${script.length} 字符`);
    // 头部（元信息注释）与尾部（通常在这里 lx.send('inited')）最能说明脚本格式是否正常
    this.pushLog('info', `源脚本头部：${script.substring(0, 160)}`);
    this.pushLog('info', `源脚本尾部：${script.substring(script.length > 160 ? script.length - 160 : 0)}`);
    // IIFE 包裹：同一页面里多次加载不同源脚本时，各自作用域互不污染
    const wrapped: string =
      `try { (function () {\n${script}\n})(); } catch (e) { lxBridge.postMessage('scriptError', JSON.stringify({ message: String((e && e.message) || e) })); }`;
    const scriptResult: string = await this.runJs(wrapped);
    // scriptError 是异步回传的，等一下再判断，否则拿不到脚本抛出的原始错误
    await this.delay(150);
    if (isScriptErrorResult(scriptResult)) {
      this.cancelInitWait();
      throw new Error(`源脚本执行失败：${scriptResult.substring(0, 300)}`);
    }
    if (scriptResult.length > 0 && scriptResult !== 'null' && scriptResult !== 'undefined') {
      this.pushLog('warn', `源脚本执行返回：${scriptResult.substring(0, 300)}`);
    }
    // ArkWeb 的 runJavaScript 在脚本执行失败时返回 null（不是 reject），
    // 所以不能只看返回值，必须问沙箱「脚本跑到哪一步了」。
    let state: SandboxDebugState = await this.readDebugState();
    if (!state.hasHandler) {
      this.pushLog('warn', `源脚本未注册 request 处理器（${state.raw}），改用 ArrayBuffer 注入重试`);
      await this.callJs('if (typeof __lx_destroy__ === "function") { __lx_destroy__(); }');
      await this.injectEngine(info, script);
      await this.runJsBuffer(wrapped);
      await this.delay(150);
      state = await this.readDebugState();
      if (!state.hasHandler) {
        this.cancelInitWait();
        const scriptErr: string = this.lastScriptError.length > 0 ? `脚本抛出：${this.lastScriptError}。` : '';
        throw new Error(
          `源脚本执行后仍未注册 request 处理器（脚本可能不是洛雪自定义源格式，或自身校验未通过）。` +
          `${scriptErr}脚本长度 ${script.length}，沙箱状态 ${state.raw}`,
        );
      }
      this.pushLog('info', '改用 ArrayBuffer 注入后脚本成功注册 request 处理器');
    }
    const sources: Record<string, SupportedSource> = await initPromise;
    // 记住「这次用的是哪个源」：下次启动自动加载（见 restoreLastSource）
    this.store.saveActive(id, this.sandboxEnv);
    return sources;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      setTimeout(() => resolve(), ms);
    });
  }

  /** 取消 init 等待（在抛错前调用，避免留下未处理的 promise 拒绝） */
  private cancelInitWait(): void {
    this.initResolve = null;
    this.initReject = null;
    if (this.initTimer !== 0) {
      clearTimeout(this.initTimer);
      this.initTimer = 0;
    }
  }

  /** 询问沙箱：脚本注册 handler 了吗、send 过哪些事件、发过几次请求 */
  private async readDebugState(): Promise<SandboxDebugState> {
    const fallback: SandboxDebugState = {
      hasHandler: false,
      inited: false,
      sendCalls: [],
      requestCount: 0,
      scriptLength: 0,
      env: '',
      raw: '(无法读取沙箱状态)',
    };
    let text: string = '';
    try {
      const result: string =
        await this.runJs('(typeof __lx_debug_state__ === \'function\') ? __lx_debug_state__() : \'\'');
      text = unwrapJsonString(result);
    } catch (e) {
      return fallback;
    }
    if (text.length === 0) {
      return fallback;
    }
    try {
      const rec = JSON.parse(text) as Record<string, Object>;
      const sendCalls: string[] = [];
      const rawCalls = rec['sendCalls'];
      if (Array.isArray(rawCalls)) {
        for (const item of rawCalls as Object[]) {
          sendCalls.push(typeof item === 'string' ? item as string : JSON.stringify(item));
        }
      }
      return {
        hasHandler: debugBool(rec['hasHandler']),
        inited: debugBool(rec['inited']),
        sendCalls: sendCalls,
        requestCount: debugNumber(rec['requestCount']),
        scriptLength: debugNumber(rec['scriptLength']),
        env: debugString(rec['env']),
        raw: text,
      };
    } catch (e) {
      return fallback;
    }
  }

  /** 注入引擎：bootstrap(元信息) -> 工具库 -> preload(lx API) */
  private async injectEngine(info: SourceInfo, script: string): Promise<void> {
    const boot: LxBootstrap = {
      key: this.scriptKey,
      rawScript: script,
      env: this.sandboxEnv,
      meta: {
        name: info.name,
        description: info.description,
        version: info.version,
        author: info.author,
        homepage: info.homepage,
      },
    };
    await this.callJs(`window.__lx_bootstrap__ = ${JSON.stringify(boot)};`);
    await this.callJs(this.utilsJs);
    await this.callJs(this.preloadJs);
  }

  /**
   * 确保沙箱桥接可用。
   * 首次：Web 组件属性注册的代理应已随初始页面注入，直接探针即可。
   * 兜底：按官方建议「显式 registerJavaScriptProxy + reload」再注册一次并重试。
   */
  private async ensureBridge(): Promise<void> {
    if (this.bridgeReady) {
      return;
    }
    try {
      await this.probeBridge();
      this.bridgeReady = true;
      return;
    } catch (e) {
      this.pushLog('warn', `桥接自检未通过（${(e as Error).message}），尝试显式注册 + reload`);
    }
    const controller = this.controller;
    const bridge = this.bridge;
    if (controller === null || bridge === null) {
      throw new Error('沙箱桥接未就绪：缺少 WebviewController 或桥对象');
    }
    // 同一方法同时登记在 methodList 与 asyncMethodList 时，ArkWeb 按异步方法处理
    controller.registerJavaScriptProxy(bridge, 'lxBridge', ['postMessage'], ['postMessage']);
    this.pageReady = false;
    controller.refresh();
    await this.whenPageReady(PAGE_READY_TIMEOUT);
    await this.probeBridge();
    this.bridgeReady = true;
    this.pushLog('info', '桥接在显式注册并 reload 后可用');
  }

  /**
   * 桥接自检：ArkTS -> 沙箱（runJavaScript 检查 lxBridge） -> ArkTS（收到 probe）。
   * 用计数判断而不是「先挂 waiter 再发」，这样同步送达与异步送达都能正确识别。
   */
  private async probeBridge(): Promise<void> {
    const before: number = this.probeCount;
    const probeJs: string =
      '(function(){ if (typeof lxBridge === \'undefined\' || typeof lxBridge.postMessage !== \'function\') return \'BRIDGE_MISSING\'; lxBridge.postMessage(\'probe\', \'{}\'); return \'PROBE_SENT\'; })()';
    const result: string = await this.runJs(probeJs);
    if (result.includes('BRIDGE_MISSING')) {
      throw new Error('window.lxBridge.postMessage 未注入（javaScriptProxy 注册失败）');
    }
    if (!result.includes('PROBE_SENT')) {
      throw new Error(`桥接探针返回了意外结果 ${result.substring(0, 200)}`);
    }
    if (this.probeCount > before) {
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const timer: number = setTimeout(() => {
        this.bridgeProbeResolve = null;
        reject(new Error('lxBridge 消息无法送达宿主'));
      }, 3000);
      this.bridgeProbeResolve = () => {
        clearTimeout(timer);
        this.bridgeProbeResolve = null;
        resolve();
      };
    });
  }

  // ------------------------------------------------------------ 取播放链接（核心）

  /**
   * 根据源规则解析指定音乐的播放链接。
   *
   * @param musicInfoJson 洛雪旧版 musicInfo 的 JSON 文本（与源脚本 request.info.musicInfo 一致）
   * @param quality       目标音质
   * @param source        平台 id（kw/kg/tx/wy/mg），需与 musicInfoJson.source 一致
   */
  async getMusicUrl(musicInfoJson: string, quality: LxQuality, source: string): Promise<string> {
    if (!this.inited) {
      throw new Error('音源未加载或初始化失败，请先调用 loadSource()');
    }
    const supportedSource = this.findSupported(source);
    if (supportedSource === undefined) {
      throw new Error(`当前音源不支持平台：${source}（支持：${Object.keys(this.supported).join(', ')}）`);
    }
    if (!supportedSource.actions.includes('musicUrl')) {
      throw new Error(`当前音源的 ${source} 未实现 musicUrl`);
    }
    const requestKey = `req_${this.requestSeq++}_${Math.random().toString(36).substring(2)}`;
    const payload: string =
      `{"requestKey":${JSON.stringify(requestKey)},"data":{"source":${JSON.stringify(source)},"action":"musicUrl","info":{"type":${JSON.stringify(quality)},"musicInfo":${musicInfoJson}}}}`;
    const started: number = Date.now();
    let resultJson: string;
    try {
      resultJson = await this.sendToSandbox(requestKey, payload);
    } catch (e) {
      // 源脚本报的错（如「unknow error」）往往只是它对响应的解读，
      // 把最近一次真实响应的状态码/长度/片段带上，才能判断是接口报错还是响应格式变了。
      const message: string = (e as Error).message;
      const extra: string = this.lastResponseExcerpt.length > 0
        ? `；最近一次音源请求响应：${this.lastResponseExcerpt}` : '';
      throw new Error(message + extra);
    }
    let url: string = '';
    try {
      const result = JSON.parse(resultJson) as BridgeResult;
      url = result.data.url !== undefined ? result.data.url : '';
    } catch (e) {
      url = '';
    }
    if (url.length === 0) {
      throw new Error('音源未返回播放链接');
    }
    this.pushLog('info', `解析播放链接成功（${Date.now() - started}ms）：${url}`);
    return url;
  }

  /** 取歌词（源脚本实现 lyric 时可用），返回 result.data 的 JSON 文本 */
  async getLyric(musicInfoJson: string, source: string): Promise<string> {
    if (!this.inited) {
      throw new Error('音源未加载或初始化失败，请先调用 loadSource()');
    }
    const requestKey = `req_${this.requestSeq++}_${Math.random().toString(36).substring(2)}`;
    const payload: string =
      `{"requestKey":${JSON.stringify(requestKey)},"data":{"source":${JSON.stringify(source)},"action":"lyric","info":{"musicInfo":${musicInfoJson}}}}`;
    return this.sendToSandbox(requestKey, payload);
  }

  /**
   * 取封面（源脚本实现 pic 时可用）。
   * pic 的 result.data 是裸字符串（见 lx_preload.js 的 handleRequest），不是对象。
   */
  async getPic(musicInfoJson: string, source: string): Promise<string> {
    if (!this.inited) {
      throw new Error('音源未加载或初始化失败，请先调用 loadSource()');
    }
    const requestKey = `req_${this.requestSeq++}_${Math.random().toString(36).substring(2)}`;
    const payload: string =
      `{"requestKey":${JSON.stringify(requestKey)},"data":{"source":${JSON.stringify(source)},"action":"pic","info":{"musicInfo":${musicInfoJson}}}}`;
    const resultJson: string = await this.sendToSandbox(requestKey, payload);
    try {
      const result = JSON.parse(resultJson) as BridgePicResultData;
      return typeof result.data === 'string' ? result.data as string : '';
    } catch (e) {
      return '';
    }
  }

  /** 该平台的源脚本是否声明了某个 action（pic / lyric / musicUrl） */
  supportsAction(source: string, action: string): boolean {
    const supportedSource: SupportedSource | undefined = this.findSupported(source);
    return supportedSource !== undefined && supportedSource.actions.includes(action);
  }

  private findSupported(source: string): SupportedSource | undefined {
    const keys: string[] = Object.keys(this.supported);
    for (const key of keys) {
      if (key === source) {
        return this.supported[key];
      }
    }
    return undefined;
  }

  /**
   * 把一次 request action 投递给沙箱里的源脚本，等待它按源规则解析完成。
   * resolve 值为 BridgeResult 的 JSON 文本（即 {source, action, data}）。
   */
  private sendToSandbox(requestKey: string, payload: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const timer: number = setTimeout(() => {
        this.pending.delete(requestKey);
        reject(new Error('音源响应超时'));
      }, REQUEST_TIMEOUT);
      this.pending.set(requestKey, { resolve: resolve, reject: reject, timer: timer });
      const js: string =
        `window.__lx_native__(${JSON.stringify(this.scriptKey)}, 'request', ${JSON.stringify(payload)});`;
      this.callJs(js).catch((err: Error) => {
        const target = this.pending.get(requestKey);
        if (target === undefined) {
          return;
        }
        this.pending.delete(requestKey);
        clearTimeout(target.timer);
        target.reject(new Error(`调用音源失败：${err.message}`));
      });
    });
  }

  /**
   * 源脚本里的 lx.request 会带着 requestKey 回调到宿主，这里用 LxHttp 发起真实请求，
   * 拿到响应后再回灌沙箱的 requestQueue（对应洛雪的原生网络代理）。
   * 少了这一步，任何走 lx.request 的音源都不会有回调，表现为「音源响应超时」。
   */
  private handleNativeRequest(dataJson: string): void {
    let data: NativeRequestMessage;
    try {
      data = JSON.parse(dataJson) as NativeRequestMessage;
    } catch (e) {
      return;
    }
    const requestKey: string = data.requestKey !== undefined ? data.requestKey : '';
    const url: string = data.url !== undefined ? data.url : '';
    if (requestKey.length === 0 || url.length === 0) {
      return;
    }
    const options: LxRequestOptions = {};
    const raw: NativeRequestOptions | undefined = data.options;
    if (raw !== undefined) {
      if (raw.method !== undefined) {
        options.method = raw.method;
      }
      if (raw.headers !== undefined) {
        options.headers = raw.headers;
      }
      if (raw.body !== undefined) {
        options.body = raw.body;
      }
      if (raw.form !== undefined) {
        options.form = raw.form;
      }
      if (raw.formData !== undefined) {
        options.formData = raw.formData;
      }
      if (raw.timeout !== undefined) {
        options.timeout = raw.timeout;
      }
      if (raw.binary !== undefined) {
        options.binary = raw.binary === true;
      }
    }
    this.pushLog('log', `音源请求：${options.method !== undefined ? options.method : 'get'} ${url}`);
    const handle: LxRequestHandle = lxRequest(url, options, (resp: LxResponse) => {
      this.httpRequests.delete(requestKey);
      const excerpt: string = this.describeResponse(resp);
      this.lastResponseExcerpt = excerpt;
      this.pushLog(resp.ok ? 'info' : 'warn', `音源请求响应：${excerpt}`);
      const body: NativeResponseBody = {
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        headers: resp.headers,
        body: resp.body,
      };
      const envelope: NativeResponseMessage = {
        requestKey: requestKey,
        error: null,
        response: body,
      };
      this.postResponseToSandbox(envelope);
    }, (message: string) => {
      this.httpRequests.delete(requestKey);
      const friendly: string = describeNetworkError(message, url);
      this.lastResponseExcerpt = `请求失败(${url})：${friendly}`;
      this.pushLog('warn', `音源请求失败（${url}）：${friendly}`);
      const envelope: NativeResponseMessage = {
        requestKey: requestKey,
        error: message,
        response: null,
      };
      this.postResponseToSandbox(envelope);
    });
    this.httpRequests.set(requestKey, handle);
  }

  /**
   * 把响应压成一行摘要：状态码 + 正文长度 + 前 300 字符。
   * 源脚本的 handler 只看 body 里的字段，一旦它报「unknow error」这类自己的错，
   * 只有这行摘要能说明服务端到底回了什么（HTML 错误页 / 空 body / 字段改名）。
   */
  private describeResponse(resp: LxResponse): string {
    const raw: string | Object | number[] = resp.body;
    let text: string;
    if (typeof raw === 'string') {
      text = raw as string;
    } else if (Array.isArray(raw)) {
      text = `[binary ${(raw as number[]).length} bytes]`;
    } else {
      text = JSON.stringify(raw);
    }
    const clipped: string = text.length > 200 ? `${text.substring(0, 200)}…` : text;
    // 压成单行：状态栏只有一行，HTML 错误页里的换行会让提示被截断得毫无信息
    const oneLine: string = clipped.split('\r').join(' ').split('\n').join(' ').split('\t').join(' ').trim();
    return `HTTP ${resp.statusCode}, body(${text.length})=${oneLine}`;
  }

  /** 源脚本取消请求（lx.request 返回的 cancel / 请求超时） */
  private handleCancelRequest(dataJson: string): void {
    // lx_preload.js 里 nativeCall(cancelRequest, requestKey) 传的是裸字符串，
    // JSON.stringify 后形如 "0.123456"，这里直接去掉首尾引号。
    let requestKey: string = dataJson;
    if (requestKey.length >= 2 && requestKey.charAt(0) === '"' && requestKey.charAt(requestKey.length - 1) === '"') {
      requestKey = requestKey.substring(1, requestKey.length - 1);
    }
    const handle: LxRequestHandle | undefined = this.httpRequests.get(requestKey);
    if (handle !== undefined) {
      this.httpRequests.delete(requestKey);
      handle.abort();
    }
  }

  /** 把网络响应回灌沙箱（对应洛雪原生侧把结果写回 QuickJS 的 response 通道） */
  private postResponseToSandbox(envelope: NativeResponseMessage): void {
    if (this.controller === null) {
      return;
    }
    const payload: string = JSON.stringify(envelope);
    const js: string =
      `window.__lx_native__(${JSON.stringify(this.scriptKey)}, 'response', ${JSON.stringify(payload)});`;
    this.callJs(js).catch((err: Error) => {
      this.pushLog('error', `回灌网络响应失败：${err.message}`);
    });
  }

  /** 中断所有宿主代理中的请求（换源 / 销毁时调用，避免旧源的回调回灌到新沙箱） */
  private abortHttpRequests(): void {
    for (const handle of this.httpRequests.values()) {
      handle.abort();
    }
    this.httpRequests.clear();
  }

  // ------------------------------------------------------------ 沙箱消息处理

  /** 由 LxBridge（javaScriptProxy）回调 */
  handleBridgeMessage(action: string, dataJson: string): void {
    switch (action) {
      case 'probe': {
        this.probeCount++;
        const resolve = this.bridgeProbeResolve;
        if (resolve !== null) {
          resolve();
        }
        break;
      }
      case 'init':
        this.handleInit(dataJson);
        break;
      case 'request':
        this.handleNativeRequest(dataJson);
        break;
      case 'cancelRequest':
        this.handleCancelRequest(dataJson);
        break;
      case 'response':
        this.handleResponse(dataJson);
        break;
      case 'log':
        this.handleLog(dataJson);
        break;
      case 'scriptError':
        this.handleScriptError(dataJson);
        break;
      case 'showUpdateAlert':
        this.handleUpdateAlert(dataJson);
        break;
      default:
        break;
    }
  }

  private handleInit(dataJson: string): void {
    let data: BridgeInitData;
    try {
      data = JSON.parse(dataJson) as BridgeInitData;
    } catch (e) {
      return;
    }
    const resolve = this.initResolve;
    const reject = this.initReject;
    this.initResolve = null;
    this.initReject = null;
    if (this.initTimer !== 0) {
      clearTimeout(this.initTimer);
      this.initTimer = 0;
    }
    if (resolve === null || reject === null) {
      return;
    }
    if (data.status && data.info !== null && data.info !== undefined) {
      this.supported = data.info.sources;
      this.inited = true;
      this.pushLog('info', `音源初始化成功，支持平台：${Object.keys(this.supported).join(', ')}`);
      resolve(data.info.sources);
    } else {
      this.inited = false;
      const message: string = data.errorMessage !== undefined ? data.errorMessage : '音源初始化失败';
      this.pushLog('error', message);
      reject(new Error(message));
    }
  }

  private handleResponse(dataJson: string): void {
    let data: BridgeResponseData;
    try {
      data = JSON.parse(dataJson) as BridgeResponseData;
    } catch (e) {
      return;
    }
    const target = this.pending.get(data.requestKey);
    if (target === undefined) {
      return;
    }
    this.pending.delete(data.requestKey);
    clearTimeout(target.timer);
    if (!data.status) {
      target.reject(new Error(data.errorMessage !== undefined ? data.errorMessage : '音源解析失败'));
      return;
    }
    const result = data.result;
    if (result === undefined) {
      target.reject(new Error('音源返回为空'));
      return;
    }
    target.resolve(JSON.stringify(result));
  }

  private handleLog(dataJson: string): void {
    try {
      const data = JSON.parse(dataJson) as LogData;
      const type: string = data.type !== undefined ? data.type : 'log';
      const message: string = data.log !== undefined ? data.log : '';
      this.pushLog(type, message);
    } catch (e) {
      // ignore
    }
  }

  private handleScriptError(dataJson: string): void {
    let message: string = '源脚本运行异常';
    try {
      const data = JSON.parse(dataJson) as ScriptErrorData;
      if (data.message !== undefined) {
        message = data.message;
      }
    } catch (e) {
      // ignore
    }
    this.lastScriptError = message;
    this.pushLog('error', `源脚本异常：${message}`);
    const reject = this.initReject;
    if (reject !== null) {
      this.initResolve = null;
      this.initReject = null;
      if (this.initTimer !== 0) {
        clearTimeout(this.initTimer);
        this.initTimer = 0;
      }
      reject(new Error(message));
    }
  }

  private handleUpdateAlert(dataJson: string): void {
    try {
      const data = JSON.parse(dataJson) as UpdateAlertData;
      const name: string = data.name !== undefined ? data.name : '';
      const log: string = data.log !== undefined ? data.log : '';
      this.pushLog('warn', `音源 ${name} 有更新提示：${log}`);
    } catch (e) {
      // ignore
    }
  }

  // ------------------------------------------------------------ 工具

  private async callJs(js: string): Promise<void> {
    await this.runJs(js);
  }

  /** 执行注入的 JS，并返回 runJavaScript 的原始结果（JSON 字符串） */
  private async runJs(js: string): Promise<string> {
    const controller = this.controller;
    if (controller === null) {
      throw new Error('音源沙箱未挂载');
    }
    const result: string = await controller.runJavaScript(js);
    return result !== null && result !== undefined ? result : '';
  }

  /**
   * 以 ArrayBuffer 形式执行注入的 JS（runJavaScriptExt，API 12+ 支持）。
   * 大脚本用字符串形式注入可能失败且被 ArkWeb 静默吞成 null，这里作为兜底注入方式。
   */
  private async runJsBuffer(js: string): Promise<void> {
    const controller = this.controller;
    if (controller === null) {
      throw new Error('音源沙箱未挂载');
    }
    const bytes = new Uint8Array(utf8Bytes(js));
    await controller.runJavaScriptExt(bytes.buffer as ArrayBuffer);
  }

  private whenPageReady(timeoutMs: number): Promise<void> {
    if (this.pageReady) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      const timer: number = setTimeout(() => {
        reject(new Error('沙箱页面加载超时'));
      }, timeoutMs);
      this.pageWaiters.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  // ------------------------------------------------------------ 日志

  setLogListener(listener: ((log: SourceLog) => void) | null): void {
    this.logListener = listener;
  }

  getLogs(): SourceLog[] {
    return this.logs;
  }

  clearLogs(): void {
    this.logs = [];
  }

  private pushLog(type: string, message: string): void {
    const log: SourceLog = { time: Date.now(), type: type, message: message };
    hilog.info(DOMAIN, TAG, '[%{public}s] %{public}s', type, message);
    this.logs.push(log);
    if (this.logs.length > this.maxLogs) {
      this.logs.shift();
    }
    const listener = this.logListener;
    if (listener !== null) {
      listener(log);
    }
  }

  destroy(): void {
    for (const value of this.pending.values()) {
      clearTimeout(value.timer);
      value.reject(new Error('引擎已销毁'));
    }
    this.pending.clear();
    this.abortHttpRequests();
    this.inited = false;
    this.supported = {};
    this.loadedSourceId = '';
    this.controller = null;
  }
}

interface LogData {
  type?: string;
  log?: string;
}

/**
 * 判断源脚本是否为 ES Module。
 * 洛雪自定义源是普通脚本（由宿主 evaluate），ESM 需要 import/export，本引擎不支持。
 */
function looksLikeEsm(script: string): boolean {
  const head: string = script.substring(0, 6000);
  const lines: string[] = head.split(/\r?\n/);
  for (const rawLine of lines) {
    const line: string = rawLine.trim();
    if (line.startsWith('import ') || line.startsWith('export ')) {
      return true;
    }
  }
  return false;
}

/** runJavaScript 结果里出现这些关键字，说明脚本本身抛错了（ArkWeb 有时以返回值而非 reject 报错） */
function isScriptErrorResult(result: string): boolean {
  const lower: string = result.toLowerCase();
  return lower.includes('syntaxerror') || lower.includes('referenceerror') ||
    lower.includes('typeerror') || lower.includes('is not defined');
}

/** 取出 URL 里的主机名（提示里要说清是哪个服务端连不上） */
function hostOf(url: string): string {
  const matched: RegExpMatchArray | null = url.match(/^https?:\/\/([^/?#]+)/);
  return matched !== null ? matched[1] : url;
}

/**
 * 把网络层的英文错误翻成能指导操作的中文
 *
 * 音源脚本的播放链接是它自己的服务端给的，那个域名一旦失效（最常见：
 * 卖音源的服务端跑路/换域名），报错原文只有一句 "Failed to resolve the host name"，
 * 看上去像手机没网。这里点明是哪台服务端、并告知换音源，用户才知道下一步该做什么。
 */
function describeNetworkError(message: string, url: string): string {
  const lower: string = message.toLowerCase();
  const host: string = hostOf(url);
  if (lower.includes('resolve') || lower.includes('unknown host') || lower.includes('no address')) {
    return `连不上音源服务端 ${host}（域名解析失败）。该音源很可能已经失效，` +
      `请到「设置 → 音源设置」换一个音源`;
  }
  if (lower.includes('timeout') || lower.includes('timed out')) {
    return `音源服务端 ${host} 响应超时；可稍后重试，或到「设置 → 音源设置」换一个音源`;
  }
  if (lower.includes('refused')) {
    return `音源服务端 ${host} 拒绝连接（服务可能已关闭）；建议换一个音源`;
  }
  if (lower.includes('reset') || lower.includes('broken pipe') || lower.includes('disconnect')) {
    return `与音源服务端 ${host} 的连接被中断；可稍后重试`;
  }
  return `${message}（${host}）`;
}

/** 沙箱自检状态（由 lx_preload.js 的 __lx_debug_state__() 返回） */
interface SandboxDebugState {
  hasHandler: boolean;
  inited: boolean;
  sendCalls: string[];
  requestCount: number;
  scriptLength: number;
  env: string;
  /** 原始 JSON，直接拼进错误信息便于排查 */
  raw: string;
}

function debugBool(v: Object | undefined): boolean {
  return typeof v === 'boolean' ? v as boolean : false;
}

function debugNumber(v: Object | undefined): number {
  return typeof v === 'number' ? v as number : 0;
}

function debugString(v: Object | undefined): string {
  return typeof v === 'string' ? v as string : '';
}

/**
 * runJavaScript 返回的是结果的 JSON 序列化字符串。
 * 这里把「返回一个字符串」的情况还原成字符串本体。
 */
function unwrapJsonString(result: string): string {
  if (result.length === 0 || result === 'null' || result === 'undefined') {
    return '';
  }
  try {
    const parsed = JSON.parse(result) as Object;
    if (typeof parsed === 'string') {
      return parsed as string;
    }
    if (parsed !== null && typeof parsed === 'object') {
      return JSON.stringify(parsed);
    }
    return result;
  } catch (e) {
    return result;
  }
}
