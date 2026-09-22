import { util, xml } from '@kit.ArkTS';
import { WebDavEntry } from './WebDavTypes';

/**
 * WebDAV 的 XML / href 处理（纯函数，不联网、不落盘）
 *
 * PROPFIND 的响应是 WebDAV 里唯一需要解析 XML 的地方，格式固定：
 * ```
 * <?xml version="1.0" encoding="utf-8"?>
 * <D:multistatus xmlns:D="DAV:">
 *   <D:response>
 *     <D:href>/dav/music/</D:href>
 *     <D:propstat>
 *       <D:prop>
 *         <D:resourcetype><D:collection/></D:resourcetype>
 *         <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
 *         <D:getcontentlength>5242880</D:getcontentlength>
 *       </D:prop>
 *       <D:status>HTTP/1.1 200 OK</D:status>
 *     </D:propstat>
 *   </D:response>
 *   ...
 * </D:multistatus>
 * ```
 * 几个真实的坑都在这儿处理掉：
 *   - 命名空间前缀五花八门（`D:`、`d:`、`ns0:`，有的服务器完全不写前缀），所以读标签名
 *     一律先剥前缀再比；
 *   - `ignoreNameSpace` 打开后本地名才算得准，但仍然保留剥前缀这一步兜底；
 *   - href 可能是绝对路径（`/dav/music/a.mp3`）、完整 URL，也可能是没转义的中文名，
 *     三种都要能变成可请求的地址（见 resolveHref / encodeHref）；
 *   - 服务器会把「被请求的那个目录自己」也放进响应里（Depth: 1 的惯例），
 *     要按 href 比出来摘掉，否则目录里会多出一行它自己。
 */

/** URL 里不需要转义的字符（`%` 在内：已经转义过的序列不能再转一遍） */
const URL_SAFE: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  + '-_.~/:@!$&\'()*+,;=%[]?#';

/** PROPFIND 请求体：只问我们真正要用的四个属性（不用 allprop，免得被塞一坨没用的） */
export const PROPFIND_BODY: string = '<?xml version="1.0" encoding="utf-8"?>'
  + '<D:propfind xmlns:D="DAV:"><D:prop>'
  + '<D:displayname/><D:resourcetype/><D:getcontentlength/><D:getlastmodified/>'
  + '</D:prop></D:propfind>';

/** 解析出来的一条原始 response（还没和 base 地址拼） */
export interface ParsedResponse {
  href: string;
  isCollection: boolean;
  size: number;
  modifiedMs: number;
}

/**
 * 解析 PROPFIND 的响应体
 *
 * 用拉取式解析器按事件走一遍：START_TAG 记「现在在哪个标签里」，TEXT 把文本
 * 归到那个标签上，END_TAG 收尾一条 response。不用 DOMParser / convertToJSObject
 * 是因为这个 SDK 版本里没有它们（`@ohos.xml` 只有序列化器与两个解析器）。
 */
export function parsePropfind(text: string): ParsedResponse[] {
  const out: ParsedResponse[] = [];
  if (text.length === 0) {
    return out;
  }
  let href: string = '';
  let size: string = '';
  let modified: string = '';
  let isCollection: boolean = false;
  let inResponse: boolean = false;
  let tag: string = '';
  try {
    const parser: xml.XmlPullParser = new xml.XmlPullParser(toArrayBuffer(text), 'utf-8');
    const options: xml.ParseOptions = {
      supportDoctype: true,
      ignoreNameSpace: true,
      tokenValueCallbackFunction: (event: xml.EventType, value: xml.ParseInfo): boolean => {
        const name: string = localName(value.getName());
        if (event === xml.EventType.START_TAG) {
          tag = name;
          if (name === 'response') {
            inResponse = true;
            href = '';
            size = '';
            modified = '';
            isCollection = false;
          } else if (name === 'collection') {
            // `<D:collection/>` 是「这个条目是目录」的唯一标志
            isCollection = true;
          }
          return true;
        }
        if (event === xml.EventType.TEXT) {
          if (!inResponse) {
            return true;
          }
          const content: string = value.getText();
          if (tag === 'href') {
            href += content;
          } else if (tag === 'getcontentlength') {
            size += content;
          } else if (tag === 'getlastmodified') {
            modified += content;
          }
          return true;
        }
        if (event === xml.EventType.END_TAG) {
          if (name === 'collection') {
            isCollection = true;
          } else if (name === 'response') {
            if (href.length > 0) {
              out.push({
                href: href.trim(),
                isCollection: isCollection,
                size: parseSize(size),
                modifiedMs: parseHttpDate(modified),
              });
            }
            inResponse = false;
          }
          tag = '';
          return true;
        }
        return true;
      },
    };
    parser.parseXml(options);
  } catch (e) {
    // 服务器返回了非 XML（常见于认证失败时返回一张 HTML 登录页）：当作「一个条目都没有」
    return out;
  }
  return out;
}

/**
 * 把解析结果变成可直接请求的条目
 *
 * @param baseUrl 配置里的服务器地址（用来补全相对 href）
 * @param folderUrl 这次 PROPFIND 的目录地址（每个条目的 folder 就是它）
 */
export function buildEntries(baseUrl: string, folderUrl: string, parsed: ParsedResponse[]): WebDavEntry[] {
  const folder: string = withTrailingSlash(folderUrl);
  const out: WebDavEntry[] = [];
  for (const item of parsed) {
    const url: string = resolveHref(baseUrl, item.href);
    if (url.length === 0) {
      continue;
    }
    // 服务器把被请求的目录自己也算一条：摘掉，否则列表里会多一行它自己
    if (samePath(url, folderUrl)) {
      continue;
    }
    out.push({
      url: url,
      name: nameOfHref(item.href),
      folder: folder,
      isCollection: item.isCollection,
      size: item.size,
      modifiedMs: item.modifiedMs,
    });
  }
  return out;
}

/** href -> 能直接请求的绝对地址 */
export function resolveHref(baseUrl: string, href: string): string {
  const trimmed: string = href.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const lower: string = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return encodeHref(trimmed);
  }
  if (trimmed.startsWith('/')) {
    const origin: string = originOf(baseUrl);
    return origin.length > 0 ? encodeHref(`${origin}${trimmed}`) : '';
  }
  const base: string = withTrailingSlash(baseUrl);
  return base.length > 0 ? encodeHref(`${base}${trimmed}`) : '';
}

/** `https://host:5006/dav/music/` -> `https://host:5006` */
export function originOf(url: string): string {
  const at: number = url.indexOf('://');
  if (at < 0) {
    return '';
  }
  const rest: string = url.substring(at + 3);
  const slash: number = rest.indexOf('/');
  const authority: string = slash < 0 ? rest : rest.substring(0, slash);
  return `${url.substring(0, at + 3)}${authority}`;
}

/**
 * 只转义 URL 里真正不允许出现的字符
 *
 * 服务器给的 href 多数已经转义过（`%E5%91%A8`），但有的（旧版 Apache、部分网盘）
 * 会把中文原样吐回来。`%` 也在安全集里，所以已经转义的部分不会被转第二遍。
 */
export function encodeHref(href: string): string {
  const encoder = new util.TextEncoder();
  let out: string = '';
  let i: number = 0;
  while (i < href.length) {
    const code: number = href.charCodeAt(i);
    if (code < 0x80) {
      const ch: string = href.charAt(i);
      out += URL_SAFE.includes(ch) ? ch : `%${hex2(code)}`;
      i++;
      continue;
    }
    // 非 ASCII：连着取到下一个 ASCII 之前，整段按 UTF-8 逐字节转义
    let end: number = i + 1;
    while (end < href.length && href.charCodeAt(end) >= 0x80) {
      end++;
    }
    const bytes: Uint8Array = encoder.encodeInto(href.substring(i, end));
    for (let k = 0; k < bytes.length; k++) {
      out += `%${hex2(bytes[k])}`;
    }
    i = end;
  }
  return out;
}

/** href 里最后一段的解码显示名（`/dav/%E5%91%A8%E6%9D%B0%E4%BC%A6/a.mp3` -> `a.mp3`） */
export function nameOfHref(href: string): string {
  const path: string = pathOfHref(href);
  const trimmed: string = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  const at: number = trimmed.lastIndexOf('/');
  const raw: string = at >= 0 ? trimmed.substring(at + 1) : trimmed;
  return decodeOrRaw(raw);
}

/** href 的路径部分（去掉 scheme/host、query、fragment） */
export function pathOfHref(href: string): string {
  let text: string = href.trim();
  const at: number = text.indexOf('://');
  if (at >= 0) {
    const rest: string = text.substring(at + 3);
    const slash: number = rest.indexOf('/');
    text = slash < 0 ? '/' : rest.substring(slash);
  }
  const hash: number = text.indexOf('#');
  if (hash >= 0) {
    text = text.substring(0, hash);
  }
  const query: number = text.indexOf('?');
  if (query >= 0) {
    text = text.substring(0, query);
  }
  return text;
}

/** 两个地址是不是同一个路径（用来摘掉 PROPFIND 里「目录自己」那一条） */
export function samePath(a: string, b: string): boolean {
  const left: string = withTrailingSlash(pathOfHref(a)).toLowerCase();
  const right: string = withTrailingSlash(pathOfHref(b)).toLowerCase();
  return left.length > 0 && left === right;
}

/** 目录地址的规范形态：以 `/` 结尾（WebDAV 对集合的惯例写法） */
export function withTrailingSlash(url: string): string {
  const trimmed: string = url.trim();
  if (trimmed.length === 0) {
    return '';
  }
  return trimmed.endsWith('/') ? trimmed : `${trimmed}/`;
}

/** 剥掉命名空间前缀：`D:href` / `ns0:href` / `href` 都要变成 `href` */
export function localName(name: string): string {
  const at: number = name.lastIndexOf(':');
  return at >= 0 ? name.substring(at + 1) : name;
}

/** `5242880` -> 5242880；没有 / 不是数字 -> -1 */
function parseSize(text: string): number {
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return -1;
  }
  const value: number = Number.parseInt(trimmed, 10);
  return Number.isNaN(value) || value < 0 ? -1 : value;
}

/** HTTP 日期（RFC 1123 / ISO 8601）-> 毫秒；解析不了返回 -1 */
function parseHttpDate(text: string): number {
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return -1;
  }
  const value: number = Date.parse(trimmed);
  return Number.isNaN(value) ? -1 : value;
}

function decodeOrRaw(raw: string): string {
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}

function hex2(value: number): string {
  const text: string = value.toString(16).toUpperCase();
  return text.length >= 2 ? text : `0${text}`;
}

function toArrayBuffer(text: string): ArrayBuffer {
  const encoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(text);
  // encodeInto 返回的 buffer 可能比实际内容大，切一块刚刚好的
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length);
}
