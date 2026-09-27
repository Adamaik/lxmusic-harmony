import { hilog } from '@kit.PerformanceAnalysisKit';

import { lxRequest, LxResponse } from '../source/LxHttp';
import { bytesToUtf8, fromBase64 } from '../music/LxCrypto';
import { BookNetRequest } from './BookTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookHttp';

/** 书源网络请求的默认超时：书源站点多是老站，慢一点也正常 */
const DEFAULT_TIMEOUT: number = 20000;

export interface BookResponse {
  statusCode: number;
  body: string;
  headers: Record<string, string>;
}

/**
 * 书源的 Cookie 罐
 *
 * 阅读的书源几乎都开着 `enabledCookieJar`：站点先给一次 Set-Cookie，后续请求
 * 带上才认（书音FM 那种 EmpireCMS 站就是「先返回一张提示页、带了 cookie 才给结果」）。
 * 这里按「书源 + 域」存一份，够用且不会几个源互相串。
 */
export class BookCookieJar {
  /** 域 -> (名 -> 值) */
  private jars: Record<string, Record<string, string>> = {};

  private hostOf(url: string): string {
    const m = url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^/?#]+)/);
    return m ? m[1].toLowerCase() : '';
  }

  /** 组装这一跳要带的 Cookie 头 */
  headerFor(url: string): string {
    const jar = this.jars[this.hostOf(url)];
    if (jar === undefined) {
      return '';
    }
    const parts: string[] = [];
    for (const name of Object.keys(jar)) {
      parts.push(`${name}=${jar[name]}`);
    }
    return parts.join('; ');
  }

  /** 把响应里的 Set-Cookie 收下来 */
  absorb(url: string, headers: Record<string, string>): void {
    const host: string = this.hostOf(url);
    if (host.length === 0) {
      return;
    }
    let jar: Record<string, string> | undefined = this.jars[host];
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() !== 'set-cookie') {
        continue;
      }
      const raw: string = headers[key];
      // 一次响应可能有多条 Set-Cookie（用换行或逗号分隔的伪多值）
      for (const line of raw.split('\n')) {
        const pair: string = line.split(';')[0].trim();
        const eq: number = pair.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        if (jar === undefined) {
          jar = {};
          this.jars[host] = jar;
        }
        jar[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
      }
    }
  }

  clear(): void {
    this.jars = {};
  }
}

/** `data:` URL 就地解码（书源的 `<js>` 搜索结果地址常用这个形式） */
function decodeDataUrl(url: string): string {
  const comma: number = url.indexOf(',');
  if (comma < 0) {
    return '';
  }
  const head: string = url.substring(0, comma);
  const payload: string = url.substring(comma + 1);
  if (head.toLowerCase().includes(';base64')) {
    try {
      return bytesToUtf8(fromBase64(payload));
    } catch (e) {
      return '';
    }
  }
  try {
    return decodeURIComponent(payload);
  } catch (e) {
    return payload;
  }
}

/** 不区分大小写地找一个请求头 */
function headerOf(headers: Record<string, string>, name: string): string {
  const lower: string = name.toLowerCase();
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === lower) {
      return headers[key];
    }
  }
  return '';
}

/**
 * 发一次书源请求
 *
 * 复用音源那套 `lxRequest`（同一份 UA / Content-Type / 表单处理逻辑），
 * 只是这里一律要**原始文本**（书源要自己按 HTML / XML 解析，不能被 JSON 化）。
 *
 * 但音源的两个默认值对书源是错的，这里显式改掉：
 *
 * - `lxRequest` 默认发 `Accept: application/json`。书源抓的是 HTML / XML / RSS，
 *   而且有些站按 `Accept` 给不同的东西（书源作者写的规则是按浏览器抓包来的）。
 * - POST 的正文在书源里是**一段原样字符串**（`keyboard={{key}}&show=...`）。
 *   源里没写 Content-Type 时 `lxRequest` 会套用音源的 `application/json`，
 *   站点于是拿 JSON 去解表单串（书音FM 这种 EmpireCMS 站直接回一张错误页），
 *   搜索就变成「0 条」。阅读对 POST 的默认也是表单。
 */
export function bookRequest(req: BookNetRequest, cookie: string): Promise<BookResponse> {
  return new Promise<BookResponse>((resolve, reject) => {
    const url: string = req.url;
    if (url.startsWith('data:')) {
      resolve({ statusCode: 200, body: decodeDataUrl(url), headers: {} });
      return;
    }
    const headers: Record<string, string> = {};
    for (const key of Object.keys(req.headers)) {
      headers[key] = req.headers[key];
    }
    if (headerOf(headers, 'accept').length === 0) {
      headers['Accept'] = '*/*';
    }
    const method: string = req.method.length > 0 ? req.method : 'GET';
    if (method === 'POST' && headerOf(headers, 'content-type').length === 0) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if (cookie.length > 0 && headerOf(headers, 'cookie').length === 0) {
      headers['Cookie'] = cookie;
    }
    lxRequest(
      url,
      {
        method: method,
        headers: headers,
        body: req.body.length > 0 ? req.body : undefined,
        timeout: DEFAULT_TIMEOUT,
        rawText: true,
      },
      (resp: LxResponse) => {
        const body: string =
          typeof resp.body === 'string' ? resp.body as string : JSON.stringify(resp.body);
        resolve({ statusCode: resp.statusCode, body: body, headers: resp.headers });
      },
      (message: string) => {
        hilog.warn(DOMAIN, TAG, 'book request failed: %{public}s %{public}s', url, message);
        reject(new Error(message));
      }
    );
  });
}
