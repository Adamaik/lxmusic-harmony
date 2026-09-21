import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'LxHttp';

/**
 * 洛雪自定义音源网络代理
 *
 * 移植自 lx-music-mobile/src/core/init/userApi/request.js + src/utils/request.js：
 * 源脚本里的 lx.request(url, options) 最终会走到这里，由宿主 App 发起真实请求，
 * 再把响应回灌给沙箱。请求语义（默认 UA / Content-Type 推断 / body 处理 /
 * 响应 JSON 自动解析）都与洛雪保持一致。
 */

/** 与洛雪默认 UA 一致，部分平台的 API 会校验 UA */
const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';

const DEFAULT_TIMEOUT: number = 13000;

export interface LxRequestOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Object;
  form?: Record<string, string>;
  formData?: Record<string, string>;
  timeout?: number;
  binary?: boolean;
  /** 为 true 时不做 JSON 解析，body 始终返回原始文本（用于下载源脚本） */
  rawText?: boolean;
  /**
   * 最大重定向次数。0 = 由调用方自己处理 3xx（从响应的 Location 头里读下一跳），
   * 用于把短链（163cn.tv / c.migu.cn / t1.kugou.com 这类）解析成最终地址。
   * 不传时保持系统默认（30 次自动跟随），与源脚本的请求语义一致。
   */
  maxRedirects?: number;
}

export interface LxResponse {
  statusCode: number;
  statusMessage: string;
  headers: Record<string, string>;
  /** 非二进制：解析后的 JSON 对象或原始文本；二进制：字节数组 */
  body: string | Object | number[];
  url: string;
  ok: boolean;
}

export interface LxRequestHandle {
  abort: () => void;
}

function encodeForm(form: Record<string, string>): string {
  const parts: string[] = [];
  const keys: string[] = Object.keys(form);
  for (const key of keys) {
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(form[key])}`);
  }
  return parts.join('&');
}

function encodeMultipart(formData: Record<string, string>, boundary: string): string {
  const lines: string[] = [];
  const keys: string[] = Object.keys(formData);
  for (const key of keys) {
    lines.push(`--${boundary}`);
    lines.push(`Content-Disposition: form-data; name="${key}"`);
    lines.push('');
    lines.push(formData[key]);
  }
  lines.push(`--${boundary}--`);
  lines.push('');
  return lines.join('\r\n');
}

function stringifyBody(body: string | Object): string {
  if (typeof body === 'string') {
    return body;
  }
  return JSON.stringify(body);
}

function arrayBufferToBytes(buffer: ArrayBuffer): number[] {
  const view = new Uint8Array(buffer);
  const out: number[] = [];
  for (let i = 0; i < view.length; i++) {
    out.push(view[i]);
  }
  return out;
}

function toHeaderRecord(header: Object): Record<string, string> {
  const out: Record<string, string> = {};
  if (header === null || header === undefined) {
    return out;
  }
  try {
    const parsed = JSON.parse(JSON.stringify(header)) as Record<string, Object>;
    const keys: string[] = Object.keys(parsed);
    for (const key of keys) {
      const value: Object = parsed[key];
      out[key] = typeof value === 'string' ? value as string : JSON.stringify(value);
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'failed to normalize response headers: %{public}s', JSON.stringify(e));
  }
  return out;
}

function toHttpMethod(method: string): http.RequestMethod {
  switch (method) {
    case 'GET':
      return http.RequestMethod.GET;
    case 'HEAD':
      return http.RequestMethod.HEAD;
    case 'PUT':
      return http.RequestMethod.PUT;
    case 'DELETE':
      return http.RequestMethod.DELETE;
    case 'OPTIONS':
      return http.RequestMethod.OPTIONS;
    case 'TRACE':
      return http.RequestMethod.TRACE;
    case 'CONNECT':
      return http.RequestMethod.CONNECT;
    default:
      return http.RequestMethod.POST;
  }
}

/**
 * 发起一次请求。
 * @returns 句柄，调用 abort() 可中断请求（对应源脚本里 lx.request 返回的 cancel 函数）
 */
export function lxRequest(
  url: string,
  options: LxRequestOptions,
  onSuccess: (resp: LxResponse) => void,
  onError: (message: string) => void
): LxRequestHandle {
  const httpRequest: http.HttpRequest = http.createHttp();
  let destroyed: boolean = false;
  const method: string = options.method !== undefined ? options.method.toUpperCase() : 'GET';
  const timeout: number = (options.timeout !== undefined && options.timeout > 0) ? options.timeout : DEFAULT_TIMEOUT;

  const headers: Record<string, string> = {};
  // 洛雪默认带 Accept: application/json
  headers['Accept'] = 'application/json';
  headers['User-Agent'] = DEFAULT_UA;
  if (options.headers !== undefined) {
    const keys: string[] = Object.keys(options.headers);
    for (const key of keys) {
      headers[key] = options.headers[key];
    }
  }

  let contentType: string = '';
  const headerKeys: string[] = Object.keys(headers);
  for (const key of headerKeys) {
    if (key.toLowerCase() === 'content-type') {
      contentType = headers[key];
    }
  }

  let bodyText: string | undefined = undefined;
  if (method === 'POST' && contentType.length === 0) {
    if (options.form !== undefined) {
      contentType = 'application/x-www-form-urlencoded';
      bodyText = encodeForm(options.form);
    } else if (options.formData !== undefined) {
      const boundary: string = `----lxboundary${Date.now().toString(16)}`;
      contentType = `multipart/form-data; boundary=${boundary}`;
      bodyText = encodeMultipart(options.formData, boundary);
    } else {
      contentType = 'application/json';
      if (options.body !== undefined) {
        bodyText = stringifyBody(options.body);
      }
    }
  } else if (contentType.toLowerCase() === 'application/json' && options.body !== undefined) {
    bodyText = JSON.stringify(options.body);
  } else if (options.body !== undefined) {
    bodyText = stringifyBody(options.body);
  }
  if (contentType.length > 0) {
    headers['Content-Type'] = contentType;
  }

  const requestOptions: http.HttpRequestOptions = {
    method: toHttpMethod(method),
    header: headers,
    expectDataType: options.binary === true ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
    connectTimeout: timeout,
    readTimeout: timeout,
  };
  if (bodyText !== undefined && method !== 'GET' && method !== 'HEAD') {
    requestOptions.extraData = bodyText;
  }
  if (options.maxRedirects !== undefined) {
    requestOptions.maxRedirects = options.maxRedirects;
  }

  httpRequest.request(url, requestOptions)
    .then((resp: http.HttpResponse) => {
      if (destroyed) {
        return;
      }
      const statusCode: number = resp.responseCode;
      let body: string | Object | number[];
      if (options.binary === true) {
        const raw: string | Object | ArrayBuffer = resp.result;
        body = (raw instanceof ArrayBuffer) ? arrayBufferToBytes(raw) : [];
      } else {
        const raw: string | Object | ArrayBuffer = resp.result;
        const text: string = typeof raw === 'string' ? raw as string : JSON.stringify(raw);
        if (options.rawText === true) {
          body = text;
        } else {
          try {
            const parsed: Object = JSON.parse(text) as Object;
            body = (parsed !== null && typeof parsed === 'object') ? parsed : text;
          } catch (e) {
            body = text;
          }
        }
      }
      onSuccess({
        statusCode: statusCode,
        statusMessage: '',
        headers: toHeaderRecord(resp.header),
        body: body,
        url: url,
        ok: statusCode >= 200 && statusCode < 300,
      });
    })
    .catch((err: BusinessError) => {
      if (destroyed) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'request failed: %{public}s %{public}s', url, err.message);
      onError(err.message);
    });

  return {
    abort: () => {
      destroyed = true;
      httpRequest.destroy();
    },
  };
}
