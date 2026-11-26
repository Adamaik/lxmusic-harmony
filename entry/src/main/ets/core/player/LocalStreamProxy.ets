import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalStreamProxy';

/**
 * 单次向上游请求的最大字节数。
 *
 * ArkTS 的 http.request 是把整个响应读进内存再返回的（内存模式），一首 30MB 的歌一次拿全
 * 会直接失败；分片要既省内存又能让上游的 Range 语义照常工作（206 + Content-Range）。
 * 4MB 足够应付解封装器一次读几 KB~几 MB 的常规节奏，又远低于 netstack 的内存上限。
 */
const UPSTREAM_CHUNK_BYTES: number = 4 * 1024 * 1024;
/** 一次 send 最多发这么多：TCPSocket 单次写入有上限，整块 4MB 塞进去会失败 */
const SEND_CHUNK_BYTES: number = 64 * 1024;
const UPSTREAM_CONNECT_MS: number = 15000;
const UPSTREAM_READ_MS: number = 30000;
/** 请求头最多攒这么多字节，超了就断开（防被塞垃圾） */
const REQUEST_HEAD_MAX: number = 8 * 1024;
/**
 * 候选监听端口：先让系统随机分配（0）；万一某些设备不接受 0，再试几个高位固定端口。
 * 都失败就抛出去，调用方回退到「整份下载」（见 AudioEffectProcessor.processByProxy）。
 */
const PORT_CANDIDATES: number[] = [0, 47311, 51234, 55321, 59432];

/** 一次 Range 请求的解析结果 */
class ByteSpan {
  /** 起始偏移；-1 表示后缀区间（bytes=-N，只要最后 N 字节） */
  start: number = 0;
  /** 闭区间右端；-1 = 开放（一直到文件尾） */
  end: number = -1;
  /** 后缀区间的原样 spec（"65536" 这种），非空时按它原样转发给上游 */
  suffix: string = '';
}

/**
 * 本机回环 HTTP 代理：替 Native 给上游请求加上请求头。
 *
 * ## 为什么需要它
 * 需要认证的源（WebDAV 的 Basic 认证、防盗链的 Referer/UA）必须带请求头才能拉到数据，
 * 而 `OH_AVSource` 只接受一个 URI，没有任何入口能加请求头。原来的做法是「先整份下载到本地
 * 再处理」——功能对，但起播要等整首歌下载完（见 AudioEffectProcessor 类注释里的 20s 预缓冲窗口）。
 *
 * 有了这个代理，链路变成：
 *   Native ──http──> 127.0.0.1:<随机端口>/<token> ──http(带请求头)──> 真源
 * Native 依旧用系统解封装器直连拉流（边下边解码边写 WAV），只是这条「直连」的尽头是我们自己，
 * 请求头由代理补上。起播等待从「整首下载」降到「几秒数据」。
 *
 * ## 实现要点
 * - **Range 原样透传**：解封装器靠 Range 定位（MP4 的 moov 常在文件尾），代理必须把
 *   `Range: bytes=a-b` 转给上游、把 206 + `Content-Range` 原样回给客户端，否则 seek 全废。
 * - **单次响应有上限**：客户端要开放区间（`bytes=a-`）时只向上游要 4MB，回的 Content-Range
 *   如实写 `a-(a+4MB-1)/总数`，客户端会自己接着要下一段。这样既不会把整首歌读进内存，
 *   也不会骗客户端（Content-Length 与实际 body 严格一致）。
 * - **一问一答、关连接**：响应带 `Connection: close`，处理完就关。不做 keep-alive 和 pipelining，
 *   省掉一整套状态机；HTTP 客户端会自动重连。
 * - **token 白名单**：URL 里带一个随机串，路径不含它的一律 403。代理只听 127.0.0.1，
 *   但同机其它进程理论上也能连上来，加个 token 免得被人白嫖请求头（里面可能有认证信息）。
 * - 只处理 GET/HEAD，其它方法直接 405。
 */
export class LocalStreamProxy {
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private token: string = '';
  private target: string = '';
  /** 要替客户端加上的请求头（认证等），每次上游请求都带上 */
  private extraHeaders: Record<string, string> = {};
  private conns: socket.TCPSocketConnection[] = [];
  private httpRequests: http.HttpRequest[] = [];
  private stopping: boolean = false;
  /** 已经收过尾：cancelActive 与 execute 的 finally 都会调 stop，第二次直接返回 */
  private stopped: boolean = false;
  /** 已经代理出去的字节数 / 请求数（收尾打日志用，排查「到底有没有走代理」） */
  private servedBytes: number = 0;
  private servedReqs: number = 0;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder();

  /**
   * 起服务，返回可供 Native 使用的本地 URL。
   *
   * @param target 真正的音频地址（http/https，可带 query）
   * @param headers 要代加的请求头（空表也可以，那就是纯透传代理）
   * @throws 端口起不来 / 监听失败时抛出，调用方应回退到整份下载
   */
  async start(target: string, headers: Record<string, string>): Promise<string> {
    this.target = target;
    this.extraHeaders = headers;
    // token 只要不可猜即可：时间戳 + 随机数，长度足够，且不泄露任何源信息
    this.token = `t${Date.now().toString(36)}${Math.floor(Math.random() * 0x7fffffff).toString(36)}`;

    let lastError: string = '';
    for (const port of PORT_CANDIDATES) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      server.on('connect', (conn: socket.TCPSocketConnection) => {
        this.onConnect(conn);
      });
      server.on('error', (err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'proxy server error: %{public}s', JSON.stringify(err));
      });
      try {
        await server.listen({ address: '127.0.0.1', port: port, family: 1 });
        const addr: socket.NetAddress = await server.getLocalAddress();
        const boundPort: number = addr.port !== undefined ? addr.port : 0;
        if (boundPort <= 0) {
          throw new Error('no port bound');
        }
        this.server = server;
        this.port = boundPort;
        hilog.info(DOMAIN, TAG, 'proxy listening on 127.0.0.1:%{public}d (ask %{public}d)',
          this.port, port);
        return this.localUrl();
      } catch (e) {
        lastError = JSON.stringify(e);
        hilog.warn(DOMAIN, TAG, 'proxy listen on port %{public}d failed: %{public}s', port, lastError);
        try {
          await server.close();
        } catch (ce) {
          // 没起来就没什么可关的
        }
      }
    }
    throw new Error(`proxy listen failed: ${lastError}`);
  }

  /** 停服务：断开所有连接、销毁在途上游请求、释放端口。可重复调用 */
  async stop(): Promise<void> {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    this.stopping = true;

    const reqs: http.HttpRequest[] = this.httpRequests;
    this.httpRequests = [];
    for (const r of reqs) {
      try {
        r.destroy();
      } catch (e) {
        // 已结束的请求 destroy 会报错，忽略
      }
    }

    const conns: socket.TCPSocketConnection[] = this.conns;
    this.conns = [];
    for (const c of conns) {
      await this.closeQuietly(c);
    }

    const server: socket.TCPSocketServer | null = this.server;
    this.server = null;
    if (server !== null) {
      try {
        await server.close();
      } catch (e) {
        // 忽略
      }
    }
    if (this.servedReqs > 0) {
      hilog.info(DOMAIN, TAG, 'proxy stopped: %{public}d request(s), %{public}d bytes relayed',
        this.servedReqs, this.servedBytes);
    } else {
      hilog.info(DOMAIN, TAG, 'proxy stopped: no upstream request was made');
    }
  }

  // ------------------------------------------------------------ 内部

  /**
   * 本地 URL。末尾借上游的扩展名（.flac/.m4a/.mp3…）：
   * 部分解封装器会看后缀挑插件，代理路径上原样保留最保险（内容类型另外由 Content-Type 带过去）。
   */
  private localUrl(): string {
    return `http://127.0.0.1:${this.port}/${this.token}${this.guessExt()}`;
  }

  private guessExt(): string {
    let path: string = this.target;
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const slash: number = path.lastIndexOf('/');
    const name: string = slash >= 0 ? path.substring(slash + 1) : path;
    const dot: number = name.lastIndexOf('.');
    if (dot < 0 || dot === name.length - 1) {
      return '';
    }
    const ext: string = name.substring(dot + 1).toLowerCase();
    if (ext.length < 1 || ext.length > 5) {
      return '';
    }
    for (let i = 0; i < ext.length; i++) {
      const ch: string = ext.charAt(i);
      const okChar: boolean = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
      if (!okChar) {
        return '';
      }
    }
    return `.${ext}`;
  }

  private onConnect(conn: socket.TCPSocketConnection): void {
    if (this.stopping) {
      void this.closeQuietly(conn);
      return;
    }
    this.conns.push(conn);

    let buf: Uint8Array = new Uint8Array(0);
    let handled: boolean = false;

    conn.on('close', () => {
      this.dropConn(conn);
    });
    conn.on('error', (err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'proxy connection error: %{public}s', JSON.stringify(err));
      this.dropConn(conn);
    });
    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (handled) {
        return;   // 一个连接只服务一个请求（响应带 Connection: close）
      }
      buf = concatBytes(buf, new Uint8Array(info.message));
      const end: number = indexOfHeadEnd(buf);
      if (end < 0) {
        if (buf.length > REQUEST_HEAD_MAX) {
          handled = true;
          void this.reply(conn, 431, 'Request Header Fields Too Large', '');
        }
        return;
      }
      handled = true;
      const head: string = this.decoder.decodeToString(buf.subarray(0, end));
      void this.serve(conn, head);
    });
  }

  /** 解析请求 → 带上请求头打上游 → 把结果按 HTTP 语义回给客户端 */
  private async serve(conn: socket.TCPSocketConnection, head: string): Promise<void> {
    try {
      const lines: string[] = head.split('\r\n');
      const reqLine: string = lines.length > 0 ? lines[0] : '';
      const parts: string[] = reqLine.split(' ');
      const method: string = parts.length > 0 ? parts[0] : '';
      const path: string = parts.length > 1 ? parts[1] : '';

      if (path.indexOf(this.token) < 0) {
        // 不是我们发出去的 URL（同机别的进程在探），直接拒
        hilog.warn(DOMAIN, TAG, 'proxy rejected request for path: %{public}s', path);
        await this.reply(conn, 403, 'Forbidden', '');
        return;
      }
      if (method !== 'GET' && method !== 'HEAD') {
        await this.reply(conn, 405, 'Method Not Allowed', 'Allow: GET, HEAD\r\n');
        return;
      }

      const span: ByteSpan = parseRange(headerValue(lines, 'range'));
      const upHeaders: Record<string, string> = {};
      for (const k of Object.keys(this.extraHeaders)) {
        upHeaders[k] = this.extraHeaders[k];
      }
      if (method === 'HEAD') {
        // 只要个长度，别真拉 4MB
        upHeaders['Range'] = 'bytes=0-0';
      } else if (span.suffix.length > 0) {
        upHeaders['Range'] = `bytes=${span.suffix}`;
      } else {
        const askEnd: number = span.end >= 0
          ? Math.min(span.end, span.start + UPSTREAM_CHUNK_BYTES - 1)
          : span.start + UPSTREAM_CHUNK_BYTES - 1;
        upHeaders['Range'] = `bytes=${span.start}-${askEnd}`;
      }

      const t0: number = Date.now();
      const resp: http.HttpResponse = await this.fetchUpstream(upHeaders);
      const fetchMs: number = Date.now() - t0;
      if (this.stopping) {
        return;
      }

      const headers: Record<string, string> = toHeaderMap(resp.header);
      const contentType: string = headers['content-type'] !== undefined
        ? headers['content-type'] : 'application/octet-stream';
      const contentRange: string = headers['content-range'] !== undefined
        ? headers['content-range'] : '';
      const body: ArrayBuffer = resp.result as ArrayBuffer;
      const len: number = body === undefined || body === null ? 0 : body.byteLength;
      const code: number = resp.responseCode;
      const total: number = contentRangeTotal(contentRange);

      if (method === 'HEAD') {
        // 长度取上游 Content-Range 里的总数；拿不到就不写 Content-Length（比写 0 诚实）
        const lengthLine: string = total > 0 ? `Content-Length: ${total}\r\n` : '';
        const headText: string = `HTTP/1.1 200 OK\r\n${lengthLine}Content-Type: ${contentType}\r\n` +
          `Accept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
        await this.sendBytes(conn, this.encoder.encodeInto(headText));
        await this.closeQuietly(conn);
        return;
      }

      if (code !== 200 && code !== 206) {
        hilog.warn(DOMAIN, TAG, 'upstream replied %{public}d for %{public}s', code, path);
        await this.reply(conn, code, 'Upstream Error', '');
        return;
      }

      /**
       * 客户端没发 Range 时有两种情况：
       * - 上游把整份都给了（200，或 206 且总数 ≤ 本片）→ 直接按 200 回去，跟普通服务器一致；
       * - 文件比本片大 → 只能回 206 分片（Content-Range 如实写），客户端会自己接着要。
       * 不能对「没要求 Range」的请求谎报 200 + 半个 body，那是让客户端以为文件就这么长。
       */
      const wholeFile: boolean = code === 200 || total > 0 && total <= len;
      let statusLine: string;
      let rangeLine: string = '';
      if (wholeFile) {
        statusLine = '200 OK';
      } else if (contentRange.length > 0) {
        statusLine = '206 Partial Content';
        rangeLine = `Content-Range: ${contentRange}\r\n`;
      } else {
        // 上游不认 Range 又不肯给整份：没法给客户端一个自洽的响应
        hilog.warn(DOMAIN, TAG, 'upstream returned %{public}d without Content-Range', code);
        await this.reply(conn, 502, 'Bad Gateway', '');
        return;
      }

      const headText: string = `HTTP/1.1 ${statusLine}\r\nContent-Type: ${contentType}\r\n` +
        `Content-Length: ${len}\r\n${rangeLine}Accept-Ranges: bytes\r\nConnection: close\r\n\r\n`;
      await this.sendBytes(conn, this.encoder.encodeInto(headText));
      if (len > 0) {
        // 直接按块切原始 buffer 发，不再整体拷一份 Uint8Array（大响应省一半峰值内存）
        await this.sendBody(conn, body);
      }
      this.servedBytes += len;
      this.servedReqs++;
      // 耗时分开记：fetch 是上游慢（源站/网络），total - fetch 是我们发回客户端的慢
      hilog.info(DOMAIN, TAG,
        'relayed %{public}s %{public}s -> %{public}s, %{public}d bytes%s, fetch=%{public}dms total=%{public}dms',
        method, path, statusLine, len, wholeFile ? ' (whole)' : '', fetchMs, Date.now() - t0);
      await this.closeQuietly(conn);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'proxy serve failed: %{public}s', JSON.stringify(e));
      await this.closeQuietly(conn);
    }
  }

  /** 带上请求头打上游；结束后立刻销毁请求对象（响应已整份读进内存） */
  private async fetchUpstream(upHeaders: Record<string, string>): Promise<http.HttpResponse> {
    const req: http.HttpRequest = http.createHttp();
    this.httpRequests.push(req);
    try {
      return await req.request(this.target, {
        method: http.RequestMethod.GET,
        header: upHeaders,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: false,
        connectTimeout: UPSTREAM_CONNECT_MS,
        readTimeout: UPSTREAM_READ_MS,
      });
    } finally {
      const i: number = this.httpRequests.indexOf(req);
      if (i >= 0) {
        this.httpRequests.splice(i, 1);
      }
      try {
        req.destroy();
      } catch (e) {
        // 忽略
      }
    }
  }

  /** 分片发送：TCPSocket 单次写入有上限，而且逐片 await 天然形成背压 */
  private async sendBytes(conn: socket.TCPSocketConnection, data: Uint8Array): Promise<void> {
    let off: number = 0;
    while (off < data.length) {
      const n: number = Math.min(SEND_CHUNK_BYTES, data.length - off);
      const piece: ArrayBuffer = data.buffer.slice(data.byteOffset + off, data.byteOffset + off + n);
      await conn.send({ data: piece });
      off += n;
    }
  }

  /** 同上，直接切 ArrayBuffer（响应体走这条，省掉一次整块拷贝） */
  private async sendBody(conn: socket.TCPSocketConnection, body: ArrayBuffer): Promise<void> {
    let off: number = 0;
    while (off < body.byteLength) {
      const n: number = Math.min(SEND_CHUNK_BYTES, body.byteLength - off);
      await conn.send({ data: body.slice(off, off + n) });
      off += n;
    }
  }

  /** 回一个只有头（和可选短文本）的错误响应 */
  private async reply(conn: socket.TCPSocketConnection, status: number, reason: string,
    extra: string): Promise<void> {
    const text: string = `${status} ${reason}\n`;
    const body: Uint8Array = this.encoder.encodeInto(text);
    const headText: string = `HTTP/1.1 ${status} ${reason}\r\nContent-Type: text/plain\r\n` +
      `Content-Length: ${body.length}\r\n${extra}Connection: close\r\n\r\n`;
    try {
      await this.sendBytes(conn, this.encoder.encodeInto(headText));
      await this.sendBytes(conn, body);
    } catch (e) {
      // 客户端已经走了
    }
    await this.closeQuietly(conn);
  }

  private async closeQuietly(conn: socket.TCPSocketConnection): Promise<void> {
    this.dropConn(conn);
    try {
      await conn.close();
    } catch (e) {
      // 已关闭 / 正在关闭：忽略
    }
  }

  private dropConn(conn: socket.TCPSocketConnection): void {
    const i: number = this.conns.indexOf(conn);
    if (i >= 0) {
      this.conns.splice(i, 1);
    }
  }
}

/** 把 http 响应头转成小写键的表（上游大小写不固定，这里统一） */
function toHeaderMap(raw: Object): Record<string, string> {
  const out: Record<string, string> = {};
  if (raw === undefined || raw === null) {
    return out;
  }
  const map: Record<string, string> = raw as Record<string, string>;
  for (const k of Object.keys(map)) {
    out[k.toLowerCase()] = `${map[k]}`;
  }
  return out;
}

function headerValue(lines: string[], name: string): string {
  const want: string = name.toLowerCase();
  for (let i = 1; i < lines.length; i++) {
    const line: string = lines[i];
    const c: number = line.indexOf(':');
    if (c <= 0) {
      continue;
    }
    if (line.substring(0, c).trim().toLowerCase() === want) {
      return line.substring(c + 1).trim();
    }
  }
  return '';
}

/** 解析 `bytes=a-b` / `bytes=a-` / `bytes=-N` */
function parseRange(value: string): ByteSpan {
  const span: ByteSpan = new ByteSpan();
  if (value.length === 0) {
    return span;   // 没 Range：从 0 开始，长度由本侧决定
  }
  const eq: number = value.indexOf('=');
  if (eq < 0) {
    return span;
  }
  const spec: string = value.substring(eq + 1).trim();
  const dash: number = spec.indexOf('-');
  if (dash < 0) {
    return span;
  }
  const head: string = spec.substring(0, dash).trim();
  if (head.length === 0) {
    // 后缀区间：只想要最后 N 字节，原样转发给上游（量通常很小，不必分片）
    span.start = -1;
    span.suffix = spec;
    return span;
  }
  const start: number = Number(head);
  if (isNaN(start) || start < 0) {
    return span;
  }
  span.start = Math.floor(start);
  const tail: string = spec.substring(dash + 1).trim();
  if (tail.length > 0) {
    const end: number = Number(tail);
    if (!isNaN(end) && end >= span.start) {
      span.end = Math.floor(end);
    }
  }
  return span;
}

/** 从 `bytes 0-4194303/30000000` 里取总数；拿不到（`*` 或空）返回 -1 */
function contentRangeTotal(value: string): number {
  if (value.length === 0) {
    return -1;
  }
  const slash: number = value.lastIndexOf('/');
  if (slash < 0) {
    return -1;
  }
  const tail: string = value.substring(slash + 1).trim();
  if (tail.length === 0 || tail === '*') {
    return -1;
  }
  const n: number = Number(tail);
  return isNaN(n) ? -1 : Math.floor(n);
}

/** 请求头可能跨多个 TCP 包到达：拼起来找第一个空行 */
function indexOfHeadEnd(buf: Uint8Array): number {
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10 && buf[i + 2] === 13 && buf[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.length === 0) {
    return b;
  }
  if (b.length === 0) {
    return a;
  }
  const out: Uint8Array = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
