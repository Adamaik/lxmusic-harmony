import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';

/**
 * 平台接口的 JSON / 文本请求小工具
 *
 * 这几个函数原先长在 `PlatformLyric.ets` 里。评论（`PlatformComment.ets`）要用同一套
 * 「发一次请求、把响应变成 Record」的语义，与其抄第二份、让两份慢慢跑偏，不如提到这里共用。
 *
 * 二进制请求（酷我歌词的 zlib 流）只有歌词那条路在用，仍留在 PlatformLyric。
 */

/** 取值当字符串用：数字 / 布尔也转过来，其余（对象、数组、null）一律空串 */
export function asString(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return JSON.stringify(value);
  }
  return '';
}

/**
 * 取值当数字用
 *
 * 平台接口里的计数有的给数字、有的给字符串（酷我的 `comments_counts` 是字符串，
 * 咪咕的 `commentNums` 也是），所以这里统一收口，解析不出来给 `fallback`。
 */
export function asNumber(value: Object | undefined, fallback: number = 0): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (typeof value === 'number') {
    const num: number = value as number;
    return isNaN(num) ? fallback : num;
  }
  if (typeof value === 'string') {
    const parsed: number = parseInt(value as string, 10);
    return isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

/** 取值当对象用；数组 / 字符串 / null 都返回空对象（调用方不必再判类型） */
export function asRecord(value: Object | undefined): Record<string, Object> {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, Object>;
}

/** 取值当对象数组用；不是数组就给空数组 */
export function asObjectArray(value: Object | undefined): Object[] {
  return Array.isArray(value) ? value as Object[] : [];
}

/** 响应体 -> JSON 对象（HTTP 层已经尝试解析，这里再兜一层） */
export function resolveJson(resp: LxResponse): Record<string, Object> | null {
  const body = resp.body;
  if (body !== null && typeof body === 'object' && !Array.isArray(body)) {
    return body as Record<string, Object>;
  }
  if (typeof body === 'string') {
    try {
      const parsed: Object = JSON.parse(body) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as Record<string, Object>;
      }
    } catch (e) {
      return null;
    }
  }
  return null;
}

/** 请求的公共出口：把 onSuccess/onError 两段回调收成一个 Promise */
function requestJson(url: string, options: LxRequestOptions, what: string): Promise<Record<string, Object>> {
  return new Promise<Record<string, Object>>((resolve, reject) => {
    lxRequest(url, options, (resp: LxResponse) => {
      const parsed: Record<string, Object> | null = resolveJson(resp);
      if (parsed === null) {
        reject(new Error(`${what}接口返回格式异常（HTTP ${resp.statusCode}）`));
        return;
      }
      resolve(parsed);
    }, (message: string) => {
      reject(new Error(`${what}请求失败：${message}`));
    });
  });
}

export function httpGetJson(url: string, headers?: Record<string, string>,
  what: string = ''): Promise<Record<string, Object>> {
  const options: LxRequestOptions = { method: 'get', timeout: 15000 };
  if (headers !== undefined) {
    options.headers = headers;
  }
  return requestJson(url, options, what);
}

export function httpPostForm(url: string, form: Record<string, string>, headers: Record<string, string>,
  what: string = ''): Promise<Record<string, Object>> {
  const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, form: form };
  return requestJson(url, options, what);
}

/** POST 一个 JSON 体（QQ 的 musicu.fcg 是这种） */
export function httpPostJson(url: string, body: Object, headers: Record<string, string>,
  what: string = ''): Promise<Record<string, Object>> {
  const options: LxRequestOptions = { method: 'post', timeout: 15000, headers: headers, body: body };
  return requestJson(url, options, what);
}

export function httpGetText(url: string, headers?: Record<string, string>): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const options: LxRequestOptions = { method: 'get', timeout: 15000, rawText: true };
    if (headers !== undefined) {
      options.headers = headers;
    }
    lxRequest(url, options, (resp: LxResponse) => {
      const body = resp.body;
      resolve(typeof body === 'string' ? body : JSON.stringify(body));
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}
