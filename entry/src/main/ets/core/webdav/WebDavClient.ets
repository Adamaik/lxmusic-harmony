import { http } from '@kit.NetworkKit';
import { media } from '@kit.MediaKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebDavConfig, WebDavEntry, WebDavProbeResult, WebDavTags, emptyTags } from './WebDavTypes';
import { PROPFIND_BODY, buildEntries, parsePropfind, withTrailingSlash } from './WebDavXml';
import { isIgnorableFile } from '../local/LocalMusic';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavClient';

/** PROPFIND / GET 的超时（毫秒）：目录大时服务器要现场遍历，给得比普通请求宽一些 */
const LIST_TIMEOUT_MS: number = 20000;
/** 读远端标签的超时：只是取文件头，超过这个时间就当这台服务器不支持 */
const TAG_TIMEOUT_MS: number = 12000;
/** 递归收集时的上限，防止手滑选了「根目录」把整个网盘扫一遍 */
const MAX_FOLDERS: number = 300;
const MAX_AUDIO_ENTRIES: number = 5000;

/** 递归收集的结果 */
export interface WebDavCollectResult {
  /** 找到的音频条目（含「格式不支持」的，由曲库去报数） */
  entries: WebDavEntry[];
  /** 扫过的目录数 */
  folders: number;
  /** 因为超过上限提前停了（界面要说明「只添加了一部分」） */
  truncated: boolean;
  /** 没读成功的目录（权限不够 / 超时），界面提示用 */
  failedFolders: number;
}

/** Base64Helper 是类，要实例化（SyncGzip 里也是这么用的） */
const BASE64 = new util.Base64Helper();

function emptyCollect(): WebDavCollectResult {
  return { entries: [], folders: 0, truncated: false, failedFolders: 0 };
}

/**
 * WebDAV 客户端
 *
 * 只做协议：列目录（PROPFIND）、取文本/二进制（GET）、读远端标签。曲库与界面的
 * 事不在这里。
 *
 * 三个关键点：
 *  1. **PROPFIND 不是标准方法**，`@ohos.net.http` 的 `RequestMethod` 枚举里没有它。
 *     API 23 起 `RequestOptions.customMethod` 就是为这种扩展协议开的（官方注释里
 *     直接写了「when the WebDAV extension protocol is implemented」），用它比伪造
 *     一个枚举值可靠。本工程 compatibleSdkVersion 正好是 23。
 *  2. **认证只做 HTTP Basic**。自建服务（Nextcloud / Alist / 群晖 / Apache mod_dav）
 *     基本都支持 Basic；服务器只提供 Digest 时给一句明确的话，不做半吊子实现。
 *  3. **音频格式白名单不在本地判断**，复用 LocalMusic 的 `isIgnorableFile` ——
 *     那份列表（AVPlayer / AVMetadataExtractor 官方支持的格式）只能有一处。
 */
export class WebDavClient {
  private static instance: WebDavClient | null = null;

  static getInstance(): WebDavClient {
    if (WebDavClient.instance === null) {
      WebDavClient.instance = new WebDavClient();
    }
    return WebDavClient.instance;
  }

  /**
   * 请求头
   *
   * 用户名留空时不带 Authorization：Alist 之类默认匿名可读，带上空凭据反而会被拒。
   */
  authHeaders(config: WebDavConfig): Record<string, string> {
    const out: Record<string, string> = {};
    if (config.username.length === 0 && config.password.length === 0) {
      return out;
    }
    const encoder = new util.TextEncoder();
    const raw: string = `${config.username}:${config.password}`;
    const bytes: Uint8Array = encoder.encodeInto(raw);
    out['Authorization'] = `Basic ${BASE64.encodeToStringSync(bytes)}`;
    return out;
  }

  /** 列一个目录（Depth: 1，只要下一层） */
  async list(config: WebDavConfig, folderUrl: string): Promise<WebDavEntry[]> {
    const target: string = withTrailingSlash(folderUrl);
    const headers: Record<string, string> = this.authHeaders(config);
    headers['Depth'] = '1';
    headers['Content-Type'] = 'application/xml; charset=utf-8';
    headers['Accept'] = 'application/xml, text/xml, */*';
    const text: string = await this.requestText(config, target, {
      method: http.RequestMethod.POST,
      customMethod: 'PROPFIND',
      header: headers,
      extraData: PROPFIND_BODY,
      connectTimeout: LIST_TIMEOUT_MS,
      readTimeout: LIST_TIMEOUT_MS,
    });
    const parsed = parsePropfind(text);
    return buildEntries(config.url, target, parsed);
  }

  /**
   * 递归收集一个目录下的音频（含子目录）
   *
   * 广度优先一层层走，每层都发一次 PROPFIND；目录数、条目数都有上限，
   * 达到上限就停下并如实报告 `truncated`，不假装扫完了。
   *
   * @param maxDepth 目录层级上限（0 = 只看这一层）。`音乐/<歌手>/<专辑>/<歌>` 是 3 层
   */
  async collectAudio(config: WebDavConfig, startUrl: string, maxDepth: number,
    onProgress: (text: string) => void): Promise<WebDavCollectResult> {
    const result: WebDavCollectResult = emptyCollect();
    const visited: Set<string> = new Set<string>();
    let pending: string[] = [withTrailingSlash(startUrl)];
    let depth: number = 0;
    while (pending.length > 0) {
      const next: string[] = [];
      for (const folder of pending) {
        if (visited.has(folder) || visited.size >= MAX_FOLDERS) {
          if (visited.size >= MAX_FOLDERS) {
            result.truncated = true;
          }
          continue;
        }
        visited.add(folder);
        result.folders++;
        onProgress(`正在读取第 ${result.folders} 个目录（已找到 ${result.entries.length} 首）`);
        let entries: WebDavEntry[] = [];
        try {
          entries = await this.list(config, folder);
        } catch (e) {
          result.failedFolders++;
          hilog.warn(DOMAIN, TAG, 'list folder failed: %{public}s', (e as Error).message);
          continue;
        }
        for (const entry of entries) {
          if (entry.isCollection) {
            if (depth < maxDepth && !visited.has(withTrailingSlash(entry.url))) {
              next.push(withTrailingSlash(entry.url));
            }
            continue;
          }
          // 歌词、封面图、说明文本这些不是歌曲，静默跳过（与本地导入同一口径）
          if (isIgnorableFile(entry.name)) {
            continue;
          }
          result.entries.push(entry);
          if (result.entries.length >= MAX_AUDIO_ENTRIES) {
            result.truncated = true;
            return result;
          }
        }
      }
      if (next.length === 0) {
        break;
      }
      pending = next;
      depth++;
    }
    return result;
  }

  /** 连接自检：列一次根目录，把失败原因翻译成一句人话 */
  async probe(config: WebDavConfig): Promise<WebDavProbeResult> {
    if (config.url.length === 0) {
      return { ok: false, message: '还没有填服务器地址', entryCount: 0 };
    }
    try {
      const entries: WebDavEntry[] = await this.list(config, config.url);
      const folders: number = countFolders(entries);
      const files: number = entries.length - folders;
      return {
        ok: true,
        message: `连上了：根目录下 ${folders} 个文件夹、${files} 个文件`,
        entryCount: entries.length,
      };
    } catch (e) {
      return { ok: false, message: (e as Error).message, entryCount: 0 };
    }
  }

  /** 取一段文本（同名 `.lrc` 歌词） */
  async fetchText(config: WebDavConfig, url: string): Promise<string> {
    const headers: Record<string, string> = this.authHeaders(config);
    headers['Accept'] = 'text/plain, */*';
    const buffer: ArrayBuffer | null = await this.requestBinary(config, url, headers);
    return buffer === null ? '' : decodeText(buffer);
  }

  /** 取一段二进制（同目录的封面图） */
  async fetchBytes(config: WebDavConfig, url: string): Promise<ArrayBuffer | null> {
    return await this.requestBinary(config, url, this.authHeaders(config));
  }

  /**
   * 读远端音频文件的标签
   *
   * 用 `AVMetadataExtractor.setUrlSource(url, headers)`（API 20）：这是官方唯一一条
   * 「带请求头读网络媒体元数据」的路。注意它只能读 metadata —— **内嵌封面读不到**
   * （官方写明网络源只支持 fetchMetadata / 缩略图），所以封面只能靠同目录的图片
   * 或平台匹配，见 WebDavLibrary。
   *
   * 读不到就返回空标签（不抛错）：标签不是必需的，界面会退回文件名。
   */
  async readTags(config: WebDavConfig, url: string): Promise<WebDavTags> {
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      const target = extractor;
      target.setUrlSource(url, this.authHeaders(config));
      const meta: media.AVMetadata | null = await withTimeout(target.fetchMetadata(), TAG_TIMEOUT_MS);
      if (meta === null) {
        return emptyTags();
      }
      return {
        title: asText(meta.title),
        artist: asText(meta.artist),
        album: asText(meta.album),
        durationMs: asNumber(meta.duration),
      };
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'read remote tags failed: %{public}s', (e as Error).message);
      return emptyTags();
    } finally {
      if (extractor !== null) {
        try {
          await extractor.release();
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'release extractor failed: %{public}s', JSON.stringify(e));
        }
      }
    }
  }

  // ------------------------------------------------------------ 请求

  private async requestText(config: WebDavConfig, url: string,
    options: http.HttpRequestOptions): Promise<string> {
    const request = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, options);
      assertOk(response, config);
      if (typeof response.result === 'string') {
        return response.result;
      }
      return '';
    } finally {
      request.destroy();
    }
  }

  private async requestBinary(config: WebDavConfig, url: string,
    headers: Record<string, string>): Promise<ArrayBuffer | null> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: LIST_TIMEOUT_MS,
        readTimeout: LIST_TIMEOUT_MS,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      const response: http.HttpResponse = await request.request(url, options);
      assertOk(response, config);
      if (response.result instanceof ArrayBuffer) {
        return response.result;
      }
      return null;
    } finally {
      request.destroy();
    }
  }
}

// ------------------------------------------------------------ 工具

/**
 * 状态码不是 2xx 就抛一句能看懂的话
 *
 * WebDAV 的失败码挺集中：401 是账号密码，403 是权限，404 是路径写错，
 * 405/501 是服务器根本不支持 PROPFIND。翻译成人话比让用户看 405 有用得多。
 */
function assertOk(response: http.HttpResponse, config: WebDavConfig): void {
  // 207 Multi-Status 落在 2xx 里，PROPFIND 的成功码就是它
  const code: number = response.responseCode;
  if (code >= 200 && code < 300) {
    return;
  }
  if (code === 401) {
    const scheme: string = headerValue(response.header, 'www-authenticate').toLowerCase();
    if (scheme.includes('digest')) {
      throw new Error('服务器只支持 Digest 认证，本应用目前只支持 HTTP Basic（Nextcloud / Alist / 群晖一般都能用 Basic）');
    }
    throw new Error(config.username.length === 0
      ? '服务器要求登录，请填用户名和密码'
      : '用户名或密码不对');
  }
  if (code === 403) {
    throw new Error('这个账号没有读取该目录的权限');
  }
  if (code === 404) {
    throw new Error('服务器上说这个地址不存在，检查一下路径（注意大小写）');
  }
  if (code === 405 || code === 501) {
    throw new Error(`服务器不支持 WebDAV 的 PROPFIND（HTTP ${code}），确认地址指向的是 WebDAV 服务`);
  }
  if (code >= 500) {
    throw new Error(`服务器出错（HTTP ${code}）`);
  }
  throw new Error(`服务器返回了 HTTP ${code}`);
}

function headerValue(header: Object | undefined, name: string): string {
  if (header === undefined || header === null) {
    return '';
  }
  const record = header as Record<string, Object>;
  const wanted: string = name.toLowerCase();
  for (const key of Object.keys(record)) {
    if (key.toLowerCase() === wanted) {
      const value = record[key];
      return typeof value === 'string' ? value : '';
    }
  }
  return '';
}

function countFolders(entries: WebDavEntry[]): number {
  let count: number = 0;
  for (const entry of entries) {
    if (entry.isCollection) {
      count++;
    }
  }
  return count;
}

/** UTF-8 解码；出现替换字符（U+FFFD）说明不是 UTF-8，再按 GBK 试一遍（中文 .lrc 常见） */
function decodeText(buffer: ArrayBuffer): string {
  const utf8: string = decodeWith('utf-8', buffer);
  if (utf8.indexOf('\uFFFD') < 0) {
    return utf8;
  }
  const gbk: string = decodeWith('gbk', buffer);
  if (gbk.length > 0 && gbk.indexOf('\uFFFD') < 0) {
    return gbk;
  }
  return utf8;
}

function decodeWith(encoding: string, buffer: ArrayBuffer): string {
  try {
    const decoder: util.TextDecoder = util.TextDecoder.create(encoding);
    return decoder.decodeToString(new Uint8Array(buffer));
  } catch (e) {
    return '';
  }
}

/**
 * 给一个 promise 加超时
 *
 * `AVMetadataExtractor.fetchMetadata()` 在网络源上没有超时参数，服务器半死不活时
 * 会一直挂着 —— 扫描几百首时不能让它挂住整条队列。超时返回 null，调用方按
 * 「读不到标签」处理；那个还挂着的 promise 后面自己 reject 也不会变成未处理异常。
 */
function withTimeout<T>(pending: Promise<T>, ms: number): Promise<T | null> {
  return new Promise<T | null>((resolve: (value: T | null) => void) => {
    let settled: boolean = false;
    const timer: number = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(null);
    }, ms);
    pending.then((value: T) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    }).catch((err: BusinessError) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      hilog.info(DOMAIN, TAG, 'metadata pending rejected: %{public}s', err.message);
      resolve(null);
    });
  });
}

function asText(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: string | undefined): number {
  if (typeof value !== 'string') {
    return 0;
  }
  const parsed: number = Number.parseInt(value, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}
