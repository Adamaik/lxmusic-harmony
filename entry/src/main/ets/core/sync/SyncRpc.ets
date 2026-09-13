import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'SyncRpc';

/**
 * 与洛雪 message2call 线上格式一致的极简 RPC
 *
 * 官方两端都用 message2call（Proxy 版）互相调用，线上报文只有三种：
 *   调用  ：{ name: "<a.b>__<随机>", path: ['a','b'], data: [参数...] }
 *   请求  ：{ name: "<方法名>__<随机>", path: ['方法名'], data: [参数...] }   // 对方向我发起
 *   应答  ：{ name: "<原样带回>", error: null | "错误信息", data: 结果 }
 * 调用方用 name 匹配自己的等待队列，被调方执行完按原 name 回包。
 *
 * 这里不用 Proxy（ArkTS 下静态类型更友好，也更好排查），把方法名显式注册即可：
 * 客户端需要向服务端发起的调用只有 finished / onListSyncAction / onDislikeSyncAction，
 * 需要响应的方法在 SyncClient 里逐个注册。
 */

export type SyncSendFn = (payload: string) => void;
export type SyncHandlerFn = (args: Object[]) => Promise<Object | undefined>;

/** 线上消息（字段都可缺省，按 message2call 的约定判断类型） */
interface WireMessage {
  name?: string;
  path?: string[];
  error?: string | null;
  data?: Object;
}

interface PendingCall {
  resolve: (data: Object | undefined) => void;
  reject: (err: Error) => void;
  timer: number;
}

const CALL_TIMEOUT_MS: number = 120 * 1000;

export class SyncRpc {
  private send: SyncSendFn;
  private handlers: Map<string, SyncHandlerFn> = new Map<string, SyncHandlerFn>();
  private pending: Map<string, PendingCall> = new Map<string, PendingCall>();
  private seq: number = 0;
  private destroyed: boolean = false;

  constructor(send: SyncSendFn) {
    this.send = send;
  }

  /** 注册一个「服务端会调我」的方法 */
  register(method: string, handler: SyncHandlerFn): void {
    this.handlers.set(method, handler);
  }

  /** 调用服务端的方法：path 形如 ['list_sync_get_md5'] 或 ['onListSyncAction'] */
  call(path: string[], args: Object[]): Promise<Object | undefined> {
    if (this.destroyed) {
      return Promise.reject(new Error('sync disconnected'));
    }
    this.seq++;
    const name: string = `${path.join('.')}__${this.seq}`;
    const message: WireMessage = { name: name, path: path, data: args };
    return new Promise<Object | undefined>((resolve: (data: Object | undefined) => void,
      reject: (err: Error) => void) => {
      const timer: number = setTimeout(() => {
        this.pending.delete(name);
        reject(new Error(`sync call ${path.join('.')} timeout`));
      }, CALL_TIMEOUT_MS);
      this.pending.set(name, { resolve: resolve, reject: reject, timer: timer });
      try {
        this.send(JSON.stringify(message));
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(name);
        reject(e as Error);
      }
    });
  }

  /** 收到一条已解密的报文 */
  onMessage(raw: string): void {
    if (this.destroyed) {
      return;
    }
    let message: WireMessage;
    try {
      message = JSON.parse(raw) as WireMessage;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse message failed: %{public}s', JSON.stringify(e));
      return;
    }
    const name: string | undefined = message.name;
    if (name === undefined || name.length === 0) {
      return;
    }
    const path: string[] | undefined = message.path;
    if (path !== undefined && path.length > 0) {
      void this.handleRequest(name, path, message.data);
      return;
    }
    const pending: PendingCall | undefined = this.pending.get(name);
    if (pending === undefined) {
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(name);
    const error: string | null | undefined = message.error;
    if (error !== undefined && error !== null) {
      pending.reject(new Error(error));
      return;
    }
    pending.resolve(message.data);
  }

  /** 处理服务端发来的请求：执行本地方法并按原 name 回包 */
  private async handleRequest(name: string, path: string[], data?: Object): Promise<void> {
    const method: string = path.join('.');
    const handler: SyncHandlerFn | undefined = this.handlers.get(method);
    if (handler === undefined) {
      hilog.warn(DOMAIN, TAG, 'no handler for %{public}s', method);
      this.send(JSON.stringify({ name: name, error: `${method} is not defined` } as WireMessage));
      return;
    }
    let args: Object[] = [];
    if (Array.isArray(data)) {
      args = data as Object[];
    } else if (data !== undefined) {
      args = [data];
    }
    try {
      const result: Object | undefined = await handler(args);
      const ok: WireMessage = { name: name, error: null, data: result };
      this.send(JSON.stringify(ok));
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'handler %{public}s failed: %{public}s', method, err.message);
      const failed: WireMessage = { name: name, error: err.message };
      this.send(JSON.stringify(failed));
    }
  }

  /** 断开时让所有等待中的调用立刻失败，避免悬挂 */
  destroy(): void {
    this.destroyed = true;
    const names: string[] = Array.from(this.pending.keys());
    for (const name of names) {
      const pending: PendingCall | undefined = this.pending.get(name);
      if (pending === undefined) {
        continue;
      }
      clearTimeout(pending.timer);
      this.pending.delete(name);
      pending.reject(new Error('sync disconnected'));
    }
  }

  isDestroyed(): boolean {
    return this.destroyed;
  }
}
