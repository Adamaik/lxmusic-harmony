/**
 * 阅读（Legado）书源规则求值引擎 · HarmonyOS / ArkWeb 移植版
 *
 * 书源是「阅读」App 的 JSON 规则（bookSourceType=1 时有声书），与洛雪音源
 * （JS 规则脚本 + lx.on/lx.send）完全不是一套协议，所以这里是一份独立的引擎。
 *
 * ## 为什么能在 WebView 里跑
 *
 * 书源规则里有三类活：
 *   1. CSS 选择器 / 正则 / JSONPath —— 纯计算；
 *   2. `@js:` 规则 —— 需要 JS 运行时，且规则里会同步调用 `java.ajax`；
 *   3. 网络 —— 必须由宿主（ArkTS）用 @ohos.net.http 代理（WebView 里跨域 XHR 会被 CORS 拦掉）。
 *
 * 难点是 (2) 与 (3) 的矛盾：规则里的 `java.ajax(x)` 是**同步**调用（作者就是这么写的），
 * 而宿主的网络请求是异步的，同步等不了。这里用**回放（replay）**解决：
 *
 *   - `java.ajax(x)` 查内存里的响应缓存；缓存有就直接返回字符串；
 *   - 缓存没有就**记一笔缺失**并返回空串，规则继续跑（多半会在 JSON.parse 处抛错）；
 *   - `__book_run__` 捕获到任何结果后，只要本轮有缺失，就把缺失的 URL 报给宿主；
 *   - 宿主把 URL 抓回来塞进缓存，**原样重跑一遍**规则。
 *
 * 缓存只增不减，所以每一轮至少解决一个 URL，必然收敛；最终一轮没有缺失，
 * 结果与「同步发网络请求」完全一致。规则一个字都不用改写，语义与阅读一致。
 *
 * 另一个好处：CSS 选择器直接用宿主页面的 `DOMParser` / `querySelectorAll`
 * （这是真实 WebView，DOM 是完好的），不用自己写 CSS 引擎。
 *
 * ## 与阅读（Legado）的一处有意偏离
 *
 * 阅读把 `##正则##替换` 的解析放在连接符号（`||`/`&&`/`%%`）**之前**，于是
 * `A##r1##s1###||B##r2##s2###` 这种「两条规则各自带正则替换」的写法会被解析坏
 * （`||` 后面的部分被当成 replaceFirst 的判定标志丢掉）。本引擎按**作者的原意**实现：
 * 先切连接符号，每条分支各自走自己的 `##` 管道。这样 `播客听书聚合源` 的
 * 「先找 jt= 链接、找不到再找 <enclosure url=」才真的成立。
 *
 * ## 契约
 *
 *   ArkTS -> JS:  window.__book_run__(jobJson: string) : string
 *                 返回 { status:'ok'|'net'|'error', data, urls, message }
 *   ArkTS -> JS:  window.__book_ping__() : string
 *
 * job 结构：
 *   {
 *     action: 'search' | 'explore' | 'bookInfo' | 'toc' | 'content',
 *     source: <书源原始 JSON 对象>,
 *     key?: string, page?: number,          // search / explore
 *     book?: { bookUrl, name, author, ... },// bookInfo / toc / content
 *     chapter?: { url, name, index },       // content
 *     url?: string,                          // 直接指定要抓的地址（目录页等）
 *     netCache?: { [key]: string }           // 宿主已抓回来的响应
 *   }
 */
(function (global) {

  // ============================================================ 1. 网络回放

  /** 宿主已抓回来的响应：key -> 响应正文 */
  var NET_CACHE = {};
  /** 本轮缺失的请求：key -> 请求描述 */
  var NET_MISS = {};

  /**
   * 只对非 ASCII 与空格做百分号编码
   *
   * 书源里写的是 `?q={{key}}` 这种**不编码**的地址（作者习惯），宿主侧的 http 客户端
   * 未必会替我们编码中文；已经存在的 %XX 不动，否则会二次编码。
   */
  function encodeNonAscii(url) {
    var out = '';
    for (var i = 0; i < url.length; i++) {
      var ch = url.charAt(i);
      var code = url.charCodeAt(i);
      if (code > 0x7f || ch === ' ') {
        out += encodeURIComponent(ch);
      } else {
        out += ch;
      }
    }
    return out;
  }

  /** 归一化请求描述（java.ajax 接的既可能是字符串，也可能是 `url,{json}`） */
  function specOf(arg, extraHeaders) {
    var url = '';
    var options = {};
    if (typeof arg === 'string') {
      url = arg;
    } else if (arg && arg.length !== undefined && arg.length > 0) {
      // 阅读允许传数组：[url, {method, headers, body}]
      url = String(arg[0]);
      if (arg.length > 1 && arg[1]) {
        try {
          options = (typeof arg[1] === 'string') ? JSON.parse(arg[1]) : arg[1];
        } catch (e) { options = {}; }
      }
    } else if (arg !== undefined && arg !== null) {
      url = String(arg);
    }
    url = String(url || '').trim();
    // `url,{"method":"POST","body":"..."}` 这种写法
    var comma = url.lastIndexOf(',{');
    if (comma > 0) {
      var tail = url.slice(comma + 1);
      try {
        var parsed = JSON.parse(tail);
        if (parsed && typeof parsed === 'object') {
          options = parsed;
          url = url.slice(0, comma);
        }
      } catch (e) { /* 不是选项 JSON，原样当 URL */ }
    }
    var headers = {};
    if (extraHeaders) {
      for (var k in extraHeaders) { headers[k] = extraHeaders[k]; }
    }
    if (options.headers) {
      var oh = options.headers;
      if (typeof oh === 'string') {
        try { oh = JSON.parse(oh); } catch (e) { oh = null; }
      }
      if (oh) { for (var k2 in oh) { headers[k2] = String(oh[k2]); } }
    }
    return {
      url: encodeNonAscii(url),
      method: String(options.method || 'GET').toUpperCase(),
      body: options.body === undefined || options.body === null ? '' : String(options.body),
      headers: headers,
    };
  }

  function netKey(spec) {
    var names = Object.keys(spec.headers).sort();
    var flat = [];
    for (var i = 0; i < names.length; i++) { flat.push(names[i] + '=' + spec.headers[names[i]]); }
    return [spec.method, spec.url, spec.body, flat.join('&')].join('\u0001');
  }

  /**
   * 同步取一个请求的响应正文（回放式，见文件头说明）。
   * 缓存没有就登记缺失并返回空串 —— 宿主下一轮会把它抓回来。
   */
  function requestBody(spec) {
    var key = netKey(spec);
    if (Object.prototype.hasOwnProperty.call(NET_CACHE, key)) {
      return NET_CACHE[key];
    }
    if (!NET_MISS[key]) {
      NET_MISS[key] = { key: key, url: spec.url, method: spec.method, body: spec.body, headers: spec.headers };
    }
    return '';
  }

  /** java.ajax(url)：同步返回响应正文 */
  function ajax(arg) {
    var spec = specOf(arg, CUR_SOURCE ? sourceHeaders() : null);
    return requestBody(spec);
  }

  /** java.connect(url, header)：返回一个带 body() 的响应对象 */
  function connect(arg, header) {
    var spec = specOf(arg, sourceHeaders());
    if (header) {
      var h = header;
      if (typeof h === 'string') { try { h = JSON.parse(h); } catch (e) { h = null; } }
      if (h) { for (var k in h) { spec.headers[k] = String(h[k]); } }
      // 头变了要重新算 key
      spec = { url: spec.url, method: spec.method, body: spec.body, headers: spec.headers };
    }
    return {
      url: spec.url,
      code: function () { return 200; },
      headers: function () { return ''; },
      body: function () { return requestBody(spec); },
      toString: function () { return requestBody(spec); },
    };
  }

  // ============================================================ 2. 书源上下文

  /** 当前正在跑的书源（原始 JSON 对象） */
  var CUR_SOURCE = null;
  /** 书源声明的请求头 */
  var CUR_HEADERS = null;
  /** 书源变量（variable 字段 + setVariable） */
  var CUR_VARIABLE = '';
  /** 登录信息（宿主注入的 Cookie 等） */
  var CUR_LOGIN = {};

  function sourceHeaders() {
    if (CUR_HEADERS) { return CUR_HEADERS; }
    CUR_HEADERS = {};
    var raw = CUR_SOURCE ? CUR_SOURCE.header : null;
    if (!raw) { return CUR_HEADERS; }
    var obj = raw;
    if (typeof raw === 'string') {
      var text = raw.trim();
      if (text.length === 0 || text === '[object Object]') { return CUR_HEADERS; }
      try { obj = JSON.parse(text); } catch (e) { obj = null; }
    }
    if (obj && typeof obj === 'object') {
      for (var k in obj) {
        if (typeof obj[k] === 'object') { continue; }
        CUR_HEADERS[k] = String(obj[k]);
      }
    }
    return CUR_HEADERS;
  }

  /** 阅读的 cache（CacheManager）：跨调用的内存缓存，带过期时间 */
  var CACHE_STORE = {};
  var cache = {
    get: function (key) {
      var hit = CACHE_STORE[key];
      if (!hit) { return null; }
      if (hit.expire > 0 && hit.expire < Date.now()) {
        delete CACHE_STORE[key];
        return null;
      }
      return hit.value;
    },
    put: function (key, value, expireSeconds) {
      var seconds = parseInt(expireSeconds, 10);
      if (isNaN(seconds) || seconds <= 0) { seconds = 0; }
      CACHE_STORE[key] = {
        value: String(value),
        expire: seconds > 0 ? Date.now() + seconds * 1000 : 0,
      };
      return String(value);
    },
    delete: function (key) {
      delete CACHE_STORE[key];
    },
  };

  /** 阅读的 source（BaseSource）：目前只用到变量与登录信息 */
  function sourceApi() {
    return {
      getVariable: function () { return CUR_VARIABLE; },
      setVariable: function (v) { CUR_VARIABLE = v === undefined || v === null ? '' : String(v); },
      getLoginInfoMap: function () { return CUR_LOGIN; },
      getKey: function () { return CUR_VARIABLE; },
      bookSourceUrl: function () { return CUR_SOURCE ? String(CUR_SOURCE.bookSourceUrl || '') : ''; },
    };
  }

  // ============================================================ 3. 工具

  var PURE = global.LXPureUtils;

  function md5Hex(text) {
    if (PURE && PURE.md5) { return PURE.md5(String(text)); }
    return '';
  }

  function base64Encode(text) {
    try {
      var bytes = unescape(encodeURIComponent(String(text)));
      return global.btoa(bytes);
    } catch (e) {
      return '';
    }
  }

  function base64Decode(text) {
    try {
      return decodeURIComponent(escape(global.atob(String(text))));
    } catch (e) {
      return '';
    }
  }

  function pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function timeFormat(millis, format) {
    var d = new Date(Number(millis));
    if (isNaN(d.getTime())) { return ''; }
    var fmt = format || 'yyyy-MM-dd HH:mm';
    var map = {
      yyyy: d.getFullYear(),
      MM: pad2(d.getMonth() + 1),
      dd: pad2(d.getDate()),
      HH: pad2(d.getHours()),
      mm: pad2(d.getMinutes()),
      ss: pad2(d.getSeconds()),
    };
    return fmt.replace(/yyyy|MM|dd|HH|mm|ss/g, function (m) { return String(map[m]); });
  }

  /** 相对地址转绝对（与阅读的 getAbsoluteURL 等价） */
  function absolute(base, rel) {
    var r = String(rel || '').trim();
    if (r.length === 0) { return base || ''; }
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(r)) { return r; }
    var b = String(base || '');
    if (b.length === 0) { return r; }
    if (r.indexOf('//') === 0) {
      var scheme = b.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
      return (scheme ? scheme[1] : 'https') + ':' + r;
    }
    var m = b.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]*)/);
    var origin = m ? m[1] : '';
    if (origin.length === 0) { return r; }
    if (r.charAt(0) === '/') { return origin + r; }
    // 目录就是「源站 + 已有路径的上一级」；源站没有路径时目录就是根
    var rest = b.slice(origin.length).split('#')[0].split('?')[0];
    var dir = (rest.length === 0 || rest === '/') ? '/' : rest.slice(0, rest.lastIndexOf('/') + 1);
    return origin + dir + r;
  }

  /** HTML 实体反转义（阅读在结果里含 & 时会做一次） */
  function unescapeHtml(text) {
    var s = String(text);
    if (s.indexOf('&') < 0) { return s; }
    return s.replace(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});/g, function (whole, body) {
      if (body.charAt(0) === '#') {
        var code = body.charAt(1) === 'x' || body.charAt(1) === 'X'
          ? parseInt(body.slice(2), 16)
          : parseInt(body.slice(1), 10);
        if (isNaN(code)) { return whole; }
        try { return String.fromCodePoint(code); } catch (e) { return whole; }
      }
      var named = {
        amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
        ldquo: '\u201c', rdquo: '\u201d', lsquo: '\u2018', rsquo: '\u2019',
        hellip: '\u2026', mdash: '\u2014', ndash: '\u2013', middot: '\u00b7',
      };
      var low = body.toLowerCase();
      return Object.prototype.hasOwnProperty.call(named, low) ? named[low] : whole;
    });
  }

  // ============================================================ 4. 规则切分

  /**
   * 顶层切分：只按 `[]` `()` 的配对深度跳过内部定界符
   *
   * **不跟踪引号** —— 这是照阅读的实现来的：正则里常有 `[^"&]` 这种带引号的字符类，
   * 一旦按引号成对匹配就会把后面的 `||` 吞掉（播客源的 chapterUrl 正是这种写法）。
   */
  function splitTop(text, delims) {
    var parts = [];
    var cur = '';
    var depth = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charAt(i);
      if (c === '[' || c === '(') { depth++; cur += c; continue; }
      if (c === ']' || c === ')') { depth--; cur += c; continue; }
      if (depth <= 0) {
        var hit = null;
        for (var d = 0; d < delims.length; d++) {
          if (text.substr(i, delims[d].length) === delims[d]) { hit = delims[d]; break; }
        }
        if (hit) {
          parts.push(cur);
          cur = '';
          i += hit.length - 1;
          continue;
        }
      }
      cur += c;
    }
    parts.push(cur);
    return parts;
  }

  // ============================================================ 5. JSONPath（子集）

  /**
   * 支持书源里实际用到的子集：
   *   `$`           根
   *   `.name`       取字段
   *   `['name']`    取字段
   *   `[0]` / `[-1]` 取下标
   *   `[*]`         取全部（展开）
   * 例如 `$.data.result.response.docs[*]`、`$.data.durl[0].url`、`$['$0']`
   */
  function jsonPathNodes(root, path) {
    var tokens = [];
    var i = 0;
    if (path.charAt(0) === '$') { i = 1; }
    while (i < path.length) {
      var c = path.charAt(i);
      if (c === '.') {
        i++;
        var name = '';
        while (i < path.length && path.charAt(i) !== '.' && path.charAt(i) !== '[') {
          name += path.charAt(i);
          i++;
        }
        if (name.length > 0) { tokens.push({ kind: 'key', value: name }); }
      } else if (c === '[') {
        var close = path.indexOf(']', i);
        if (close < 0) { break; }
        var body = path.slice(i + 1, close).trim();
        i = close + 1;
        if (body === '*') {
          tokens.push({ kind: 'all' });
        } else if (/^-?\d+$/.test(body)) {
          tokens.push({ kind: 'index', value: parseInt(body, 10) });
        } else {
          var q = body.replace(/^['"]/, '').replace(/['"]$/, '');
          tokens.push({ kind: 'key', value: q });
        }
      } else {
        i++;
      }
    }
    var nodes = [root];
    for (var t = 0; t < tokens.length; t++) {
      var token = tokens[t];
      var next = [];
      for (var n = 0; n < nodes.length; n++) {
        var node = nodes[n];
        if (node === null || node === undefined) { continue; }
        if (token.kind === 'all') {
          if (Array.isArray(node)) {
            for (var a = 0; a < node.length; a++) { next.push(node[a]); }
          } else if (typeof node === 'object') {
            for (var k in node) { next.push(node[k]); }
          }
        } else if (token.kind === 'index') {
          if (Array.isArray(node) || typeof node === 'string') {
            var idx = token.value < 0 ? node.length + token.value : token.value;
            next.push(node[idx]);
          }
        } else {
          if (typeof node === 'object' && !Array.isArray(node)) { next.push(node[token.value]); }
        }
      }
      nodes = next;
    }
    return nodes;
  }

  function jsonPathList(root, path) {
    var out = [];
    var nodes = jsonPathNodes(root, path);
    for (var i = 0; i < nodes.length; i++) {
      var v = nodes[i];
      if (v === null || v === undefined) { continue; }
      out.push(typeof v === 'string' ? v : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
    }
    return out;
  }

  function jsonPathOne(root, path) {
    var list = jsonPathList(root, path);
    return list.length > 0 ? list[0] : '';
  }

  // ============================================================ 6. HTML / CSS

  function parseDoc(html) {
    return new DOMParser().parseFromString(String(html || ''), 'text/html');
  }

  function queryAll(html, selector) {
    if (!selector) { return []; }
    var doc = parseDoc(html);
    var sel = selector.trim();
    if (sel.length === 0) { return []; }
    var root = doc.body || doc.documentElement;
    var nodes;
    try {
      nodes = doc.querySelectorAll(sel);
    } catch (e) {
      return null; // 不是合法 CSS：交给调用方走「阅读老式写法」
    }
    var out = [];
    for (var i = 0; i < nodes.length; i++) { out.push(nodes[i]); }
    if (out.length === 0 && root && root.matches) {
      // 片段本身就是目标元素时（例如 bookList 给的 outerHTML 就是 <h3>），
      // querySelectorAll 只找后代、找不到自己，这里补一次自身匹配
      try {
        if (root.matches(sel)) { out.push(root); }
      } catch (e2) { /* ignore */ }
    }
    return out;
  }

  var ATTR_NAMES = {
    text: 1, textnodes: 1, owntext: 1, html: 1, all: 1, outerhtml: 1,
    href: 1, src: 1, content: 1, value: 1, title: 1, alt: 1, datetime: 1, data: 1,
  };

  function collapse(text) {
    return String(text || '').replace(/\s+/g, ' ').trim();
  }

  function readNode(node, accessor) {
    var acc = String(accessor || 'text').trim();
    var low = acc.toLowerCase();
    if (low === 'text') { return collapse(node.textContent); }
    if (low === 'textnodes' || low === 'owntext') {
      var buf = '';
      for (var i = 0; i < node.childNodes.length; i++) {
        var child = node.childNodes[i];
        if (child.nodeType === 3) { buf += child.nodeValue; }
        else if (low === 'textnodes') { buf += child.textContent || ''; }
      }
      return collapse(buf);
    }
    if (low === 'html') { return node.innerHTML; }
    if (low === 'all' || low === 'outerhtml') { return node.outerHTML; }
    if (node.getAttribute) {
      var v = node.getAttribute(acc);
      return v === null || v === undefined ? '' : String(v);
    }
    return '';
  }

  /**
   * 阅读老式写法（`class.odd.0@tag.a.0@text`）
   *
   * 这批书源没用到，但社区里大量老书源是这种写法，顺手支持一下：
   * 每段是「类型.名称.位置」，类型 ∈ class / tag / id / text。
   */
  function legacyQuery(html, segments) {
    var scope = [parseDoc(html).body];
    for (var s = 0; s < segments.length; s++) {
      var seg = String(segments[s]).trim();
      if (seg.length === 0) { continue; }
      var parts = seg.split('.');
      var type = String(parts[0] || '').toLowerCase();
      var name = parts.length > 1 ? parts[1] : '';
      var pos = null;
      if (parts.length > 2 && /^-?\d+$/.test(parts[2])) { pos = parseInt(parts[2], 10); }
      var selector = '';
      if (type === 'class') { selector = '.' + name; }
      else if (type === 'id') { selector = '#' + name; }
      else if (type === 'tag') { selector = name; }
      else if (type === 'children') { selector = '*'; }
      else if (type === 'text') { selector = '*'; }
      else { selector = seg; }
      var next = [];
      for (var i = 0; i < scope.length; i++) {
        var parent = scope[i];
        if (!parent || !parent.querySelectorAll) { continue; }
        var found;
        try { found = parent.querySelectorAll(selector); } catch (e) { continue; }
        var arr = [];
        for (var j = 0; j < found.length; j++) {
          if (type === 'text') {
            if (name.length === 0 || collapse(found[j].textContent).indexOf(name) >= 0) { arr.push(found[j]); }
          } else {
            arr.push(found[j]);
          }
        }
        if (pos === null) {
          for (var k = 0; k < arr.length; k++) { next.push(arr[k]); }
        } else {
          var at = pos < 0 ? arr.length + pos : pos;
          if (at >= 0 && at < arr.length) { next.push(arr[at]); }
        }
      }
      scope = next;
    }
    return scope;
  }

  // ============================================================ 7. 规则求值

  /** 求值上下文 */
  function Ctx(result, baseUrl, src, extra) {
    this.result = result;
    this.baseUrl = baseUrl || '';
    this.src = src === undefined ? '' : src;
    this.book = (extra && extra.book) || null;
    this.chapter = (extra && extra.chapter) || null;
    this.key = (extra && extra.key !== undefined) ? extra.key : '';
    this.page = (extra && extra.page !== undefined) ? extra.page : 1;
    this.title = (extra && extra.title) || (this.chapter ? this.chapter.name : '');
    this.fromBookInfo = !!(extra && extra.fromBookInfo);
  }

  function jsBindings(ctx) {
    var java = javaApi(ctx);
    return {
      java: java,
      cache: cache,
      source: sourceApi(),
      book: ctx.book,
      chapter: ctx.chapter,
      result: ctx.result,
      baseUrl: ctx.baseUrl,
      src: ctx.src,
      key: ctx.key,
      page: ctx.page,
      title: ctx.title,
      bookUrl: ctx.book ? String(ctx.book.bookUrl || '') : '',
      cookie: { getCookie: function () { return ''; } },
      fromBookInfo: ctx.fromBookInfo,
    };
  }

  /** 执行一段 JS 规则（取最后一个表达式的值，与阅读的 Rhino script.eval 一致） */
  function runJS(code, ctx) {
    // jsLib 里的函数是在全局作用域跑的，先把当前上下文同步成全局量
    publishGlobals(ctx);
    var b = jsBindings(ctx);
    var names = Object.keys(b);
    var decl = '';
    for (var i = 0; i < names.length; i++) {
      decl += 'var ' + names[i] + ' = __bindings[' + JSON.stringify(names[i]) + '];';
    }
    var __bindings = b;
    /* eslint-disable no-eval */
    return eval(decl + '\n' + String(code));
    /* eslint-enable no-eval */
  }

  /** java.* 门面（对应阅读的 AnalyzeRule 自己） */
  function javaApi(ctx) {
    var api = {
      ajax: function (url) { return ajax(url); },
      connect: function (url, header) { return connect(url, header); },
      ajaxAll: function (urls) {
        var out = [];
        if (urls && urls.length !== undefined) {
          for (var i = 0; i < urls.length; i++) { out.push(ajax(urls[i])); }
        }
        return out;
      },
      timeFormat: function (time, format) {
        if (arguments.length === 1) { return timeFormat(time, 'yyyy-MM-dd HH:mm'); }
        return timeFormat(time, format);
      },
      md5Encode: function (s) { return md5Hex(s); },
      md5Encode16: function (s) { return md5Hex(s).slice(8, 24); },
      base64Encode: function (s) { return base64Encode(s); },
      base64EncodeToString: function (s) { return base64Encode(s); },
      base64Decode: function (s) { return base64Decode(s); },
      encodeURI: function (s) { return encodeURIComponent(String(s)); },
      getString: function (rule, content, isUrl) {
        var sub = new Ctx(content === undefined || content === null ? ctx.result : content, ctx.baseUrl, ctx.src, {
          book: ctx.book, chapter: ctx.chapter, key: ctx.key, page: ctx.page,
        });
        return evalField(rule, sub, isUrl);
      },
      getStringList: function (rule, content) {
        var sub = new Ctx(content === undefined || content === null ? ctx.result : content, ctx.baseUrl, ctx.src, {
          book: ctx.book, chapter: ctx.chapter, key: ctx.key, page: ctx.page,
        });
        return evalList(rule, sub);
      },
      getElement: function (rule) { return evalList(rule, ctx)[0] || ''; },
      getCookie: function () { return ''; },
      setCookie: function () { },
      log: function (msg) { LOGS.push(String(msg)); },
      logType: function () { },
      toast: function () { },
      put: function (key, value) { PUT_STORE[String(key)] = value === undefined ? '' : String(value); return value; },
      get: function (key) { var v = PUT_STORE[String(key)]; return v === undefined ? '' : v; },
      reGetBook: function () { },
      refreshTocUrl: function () { },
      isRule: function (r) { return typeof r === 'string' && /^@|^\$[.[]|^\/\//.test(r); },
    };
    return api;
  }

  var LOGS = [];
  var PUT_STORE = {};

  /**
   * 书源的 jsLib（公共函数库）
   *
   * 阅读会把 jsLib 作为「本源共享的顶层脚本」先求值一次，之后所有 `@js:` 规则都能
   * 直接调用里面的函数（275听书的 `i275_cleanText`、书音FM 的 `shuyin_getAudioUrl`、
   * 喜马拉雅的 `_decryptXmUrl` 都在这里）。
   *
   * 必须用**间接 eval** `(0, eval)(...)`：它在全局作用域执行，`function foo(){}`
   * 才会挂到 window 上；直接 eval 会把它们声明在本书源求值函数内部，规则里看不见。
   */
  var LIB_SRC = '';
  var LIB_NAMES = [];

  function installLib(source) {
    var lib = source ? source.jsLib : '';
    lib = (lib === null || lib === undefined) ? '' : String(lib);
    if (lib === LIB_SRC) { return; }
    // 换源时把上一个源挂上去的函数摘掉，避免同名函数互相串味
    for (var i = 0; i < LIB_NAMES.length; i++) {
      try { delete global[LIB_NAMES[i]]; } catch (e) { /* ignore */ }
      try { if (global[LIB_NAMES[i]] !== undefined) { global[LIB_NAMES[i]] = undefined; } } catch (e2) { /* ignore */ }
    }
    LIB_NAMES = [];
    LIB_SRC = lib;
    if (lib.trim().length === 0) { return; }
    var before = {};
    for (var k in global) { before[k] = 1; }
    try {
      // eslint-disable-next-line no-eval
      (0, eval)(lib);
    } catch (e) {
      LOGS.push('jsLib 执行失败：' + (e && e.message ? e.message : String(e)));
      return;
    }
    for (var k2 in global) {
      if (!before[k2] && typeof global[k2] === 'function') { LIB_NAMES.push(k2); }
    }
  }

  /**
   * 把当前上下文里的绑定量同步成**全局量**
   *
   * jsLib 里的函数是在全局作用域定义的，它们引用 `java` / `result` / `book` 时
   * 只能看到全局的那一份，所以每次求值前都要把最新的上下文放上去。
   */
  function publishGlobals(ctx) {
    var b = jsBindings(ctx);
    for (var k in b) {
      try { global[k] = b[k]; } catch (e) { /* ignore */ }
    }
  }

  /** `{{ }}` 与 `@get:{...}` 替换 */
  function makeUpRule(rule, ctx, jsOnly) {
    var text = String(rule || '');
    if (text.indexOf('@get:') < 0 && text.indexOf('{{') < 0) { return text; }
    // @get:{key} -> 变量
    text = text.replace(/@get:\{([^}]*)\}/g, function (whole, name) {
      var key = String(name).trim();
      if (key === 'book') { return ctx.book ? String(ctx.book.bookUrl || '') : ''; }
      if (key === 'key') { return String(ctx.key); }
      if (key === 'page') { return String(ctx.page); }
      var stored = PUT_STORE[key];
      return stored === undefined ? '' : String(stored);
    });
    // {{ 表达式 }}
    text = text.replace(/\{\{([\s\S]*?)\}\}/g, function (whole, code) {
      var expr = String(code).trim();
      if (expr.length === 0) { return ''; }
      if (expr === 'key') { return String(ctx.key); }
      if (expr === 'page') { return String(ctx.page); }
      // 搜索 / 发现地址里的 {{}} 只认 js；规则字段里的 {{}} 可以写「任意规则」，
      // 但要有明显的标志头（`$.`、`$[`、`@`、`//`），否则仍按 js 算。
      if (!jsOnly && /^(@|<js>|\$[.[]|\/\/)/.test(expr)) {
        try {
          var viaRule = evalField(expr, ctx, false);
          return viaRule === null || viaRule === undefined ? '' : String(viaRule);
        } catch (e) {
          return '';
        }
      }
      try {
        var v = runJS(expr, ctx);
        if (v === null || v === undefined) { return ''; }
        if (typeof v === 'number' && v % 1 === 0) { return String(Math.round(v)); }
        return String(v);
      } catch (e) {
        return '';
      }
    });
    return text;
  }

  /** 一条分支的 `##` 正则管道 */
  function applyRegexPipeline(value, ruleStr) {
    var parts = String(ruleStr).split('##');
    if (parts.length < 2) { return value; }
    var base = parts[0];
    var regex = parts[1] === undefined ? '' : parts[1];
    var replacement = parts.length > 2 ? parts[2] : '';
    var replaceFirst = parts.length > 3;
    var out = value;
    if (regex.length > 0) {
      var re;
      try { re = new RegExp(regex); } catch (e) { return base === '' ? out : out; }
      if (replaceFirst) {
        // `##正则##替换###`：取第一个匹配，在匹配内做替换（阅读的 OnlyOne 规则）
        var m = re.exec(out);
        if (!m) { return ''; }
        try {
          out = m[0].replace(new RegExp(regex), replacement);
        } catch (e) {
          out = '';
        }
      } else {
        try {
          out = out.replace(new RegExp(regex, 'g'), replacement);
        } catch (e) { /* 正则不合法：原样返回 */ }
      }
    }
    return out;
  }

  function modeOf(rule) {
    var t = rule.trim();
    if (/^<js>/i.test(t) || /^@js:/i.test(t)) { return 'js'; }
    if (/^@css:/i.test(t)) { return 'css'; }
    if (/^@json:/i.test(t) || /^@jsonpath:/i.test(t) || /^\$[.[]/.test(t)) { return 'json'; }
    if (/^@xpath:/i.test(t) || /^\/\//.test(t)) { return 'xpath'; }
    if (t.charAt(0) === ':') { return 'regex'; }
    return 'default';
  }

  function stripPrefix(rule, mode) {
    var t = rule.trim();
    if (mode === 'js') {
      if (/^<js>/i.test(t)) { return t.replace(/^<js>/i, '').replace(/<\/js>$/i, ''); }
      return t.replace(/^@js:/i, '');
    }
    if (mode === 'css') { return t.replace(/^@css:/i, ''); }
    if (mode === 'json') { return t.replace(/^@jsonpath:/i, '').replace(/^@json:/i, ''); }
    if (mode === 'xpath') { return t.replace(/^@xpath:/i, ''); }
    if (mode === 'regex') { return t.slice(1); }
    return t;
  }

  /** 单条分支求值（不含连接符号） */
  function evalBranch(rule, ctx, isUrl) {
    var mode = modeOf(rule);
    var body = stripPrefix(rule, mode);
    // `##` 管道先切出来，再求值前面的部分
    var parts = body.split('##');
    var head = parts[0];
    var headRule = mode === 'default' ? head : head;
    var raw = '';

    if (mode === 'js') {
      try {
        var v = runJS(headRule.length > 0 ? headRule : 'result', ctx);
        raw = v === null || v === undefined ? '' : String(v);
      } catch (e) {
        throw e; // 交给上层：可能是网络回放导致的，也可能真的是规则错
      }
    } else if (mode === 'json') {
      var root = ctx.result;
      if (typeof root === 'string') {
        try { root = JSON.parse(root); } catch (e) { root = null; }
      }
      raw = headRule.trim().length === 0 ? '' : jsonPathOne(root, headRule.trim());
    } else if (mode === 'css') {
      var nodes = queryAll(String(ctx.result === null || ctx.result === undefined ? '' : ctx.result), headRule);
      if (nodes === null) { nodes = []; }
      raw = nodes.length > 0 ? readNode(nodes[0], 'text') : '';
      if (nodes.length > 0 && parts.length > 1) {
        // 带 ## 的 CSS 规则要把内容（默认 text）取出后再替换
      }
    } else if (mode === 'xpath') {
      raw = xpathOne(ctx.result, headRule);
    } else if (mode === 'regex') {
      // 正则 AllInOne 只在列表场景有意义，单值场景走第一个匹配
      var list = regexList(ctx.src !== '' ? ctx.src : String(ctx.result || ''), headRule);
      raw = list.length > 0 ? list[0]['$0'] : '';
    } else {
      raw = defaultOne(headRule, ctx, parts.length > 1);
    }

    var out = String(raw === null || raw === undefined ? '' : raw);
    // `##` 管道
    if (parts.length > 1) {
      out = applyRegexPipelineParts(out, parts);
    }
    if (isUrl) { out = absolute(ctx.baseUrl, out); }
    return out;
  }

  /** 复用已切好的 parts，避免把正则里的 ## 再切一次 */
  function applyRegexPipelineParts(value, parts) {
    return applyRegexPipeline(value, parts.join('##'));
  }

  /**
   * Default 模式取单值
   *
   * 阅读的 Default 其实是 JSOUP，同时覆盖三种情况：
   *   - `result` 是对象/数组 → 直接按键取值（`name`、`url`、`0`）
   *   - `result` 是 HTML 字符串 → `选择器@取值`（这批书源都是 CSS）
   *   - 老式写法 → `class.x.0@tag.a.0@text`
   */
  function defaultOne(rule, ctx, keepAccessor) {
    var r = String(rule || '').trim();
    if (r.length === 0) {
      return ctx.result === null || ctx.result === undefined ? '' : String(ctx.result);
    }
    var result = ctx.result;
    // 对象 / 数组：按键取值
    if (result !== null && result !== undefined && typeof result === 'object') {
      if (Array.isArray(result)) {
        var idx = /^-?\d+$/.test(r) ? parseInt(r, 10) : -1;
        if (idx >= 0 && idx < result.length) { return String(result[idx]); }
        return '';
      }
      var val = result[r];
      if (val === undefined) {
        // 可能是 `$0` 之类的分组键，或带 @ 的规则
        return '';
      }
      return typeof val === 'string' ? val : JSON.stringify(val);
    }
    if (typeof result !== 'string') {
      return result === null || result === undefined ? '' : String(result);
    }
    var html = result;
    // 纯取值（`@text` 这种）直接用当前片段当根
    if (r.charAt(0) === '@') {
      var selfDoc = parseDoc(html);
      var selfRoot = selfDoc.body;
      return readNode(selfRoot, r.slice(1));
    }
    var segments = splitTop(r, ['@']);
    var accessor = 'text';
    if (segments.length > 1) {
      accessor = String(segments[segments.length - 1]).trim();
      if (accessor.length === 0) { accessor = 'text'; }
    }
    var selector = String(segments[0]).trim();
    var nodes = queryAll(html, selector);
    if (nodes === null || nodes.length === 0) {
      // CSS 不认（或没命中）→ 试阅读老式写法
      var legacy = legacyQuery(html, segments.slice(0, Math.max(1, segments.length - 1)));
      if (legacy.length > 0) {
        return readNode(legacy[0], accessor);
      }
      // 选择器不合法（queryAll 返回 null）或确实没命中：都是空结果
      if (nodes === null || nodes.length === 0) { return ''; }
    }
    return nodes.length > 0 ? readNode(nodes[0], accessor) : '';
  }

  /** 极简 XPath：只支持 `//tag`、`//*[@attr="v"]`、`/@attr` 这类，够用即可 */
  function xpathOne(html, rule) {
    var nodes = xpathList(html, rule);
    return nodes.length > 0 ? nodes[0] : '';
  }

  function xpathList(html, rule) {
    var doc = parseDoc(html);
    var path = String(rule).trim();
    // 取末尾的 /@attr 或 /text()
    var accessor = 'text';
    var m = path.match(/\/(@[^/]+|text\(\))\s*$/);
    if (m) {
      accessor = m[1] === 'text()' ? 'text' : m[1].slice(1);
      path = path.slice(0, m.index);
    }
    var sel = path.replace(/^@XPath:\s*/i, '').replace(/^\/\//, '');
    sel = sel.replace(/\[contains\(@([\w-]+),\s*['"]([^'"]*)['"]\)\]/g, '[$1*="$2"]');
    sel = sel.replace(/\[@([\w-]+)\s*=\s*['"]([^'"]*)['"]\]/g, '[$1="$2"]');
    sel = sel.replace(/^\/+/, '');
    if (sel.length === 0 || sel.indexOf('::') >= 0) { return []; }
    var nodes = queryAll(html, sel);
    if (nodes === null) { return []; }
    var out = [];
    for (var i = 0; i < nodes.length; i++) { out.push(readNode(nodes[i], accessor)); }
    return out;
  }

  /** 正则列表：返回 [{ $0, $1, ... }]，供 `$['$0']` 取用（与阅读一致） */
  function regexList(text, regex, reverse) {
    var out = [];
    var re;
    try { re = new RegExp(regex, 'g'); } catch (e) { return out; }
    var m;
    var guard = 0;
    while ((m = re.exec(text)) !== null) {
      var item = { '$0': m[0] };
      for (var g = 1; g < m.length; g++) {
        item['$' + g] = m[g] === undefined ? '' : m[g];
      }
      out.push(item);
      if (m[0].length === 0) { re.lastIndex++; }
      if (++guard > 20000) { break; }
    }
    if (reverse) { out.reverse(); }
    return out;
  }

  // ============================================================ 8. 求值入口（含连接符号）

  function evalSingle(rule, ctx, isUrl) {
    var mode = modeOf(rule);
    // 连接符号（`||` / `&&` / `%%`）不用于 js 与正则规则
    if (mode === 'js' || mode === 'regex') {
      return evalBranch(rule, ctx, isUrl);
    }
    var delim = '';
    if (rule.indexOf('||') >= 0) { delim = '||'; }
    else if (rule.indexOf('&&') >= 0) { delim = '&&'; }
    else if (rule.indexOf('%%') >= 0) { delim = '%%'; }
    if (delim === '') { return evalBranch(rule, ctx, isUrl); }

    var branches = splitTop(rule, [delim]);
    if (branches.length <= 1) { return evalBranch(rule, ctx, isUrl); }
    if (delim === '||') {
      // 取第一个非空
      for (var i = 0; i < branches.length; i++) {
        var one = evalBranch(String(branches[i]).trim(), ctx, isUrl);
        if (one !== '') { return one; }
      }
      return '';
    }
    if (delim === '&&') {
      // 合并全部
      var buf = '';
      for (var j = 0; j < branches.length; j++) {
        buf += evalBranch(String(branches[j]).trim(), ctx, isUrl);
      }
      return buf;
    }
    // %% 依次取数：需要各分支等长，这里退化成拼接（极少用）
    var acc = '';
    for (var k = 0; k < branches.length; k++) {
      acc += evalBranch(String(branches[k]).trim(), ctx, isUrl);
    }
    return acc;
  }

  function evalField(rule, ctx, isUrl) {
    if (rule === null || rule === undefined) { return ''; }
    var text = String(rule);
    if (text.trim().length === 0) { return ''; }
    /**
     * 规则里出现 `{{...}}` 且它排在第一个 `##` 之前时，**替换结果本身就是值**
     *
     * 这是阅读的行为：`{{}}` 会把规则切成「正则模式」，而正则模式在取值时不做
     * 选择器/JSONPath 解析，直接返回规则串本身（随后再走 `##` 管道）。
     * 所以 `https://…?albumId={{$.id}}` 得到的是拼好的地址，`{{$.title}}` 得到的是书名，
     * 而不是把「书名」当成一个 CSS 选择器去查。
     *
     * 若 `{{}}` 排在 `##` 之后（例如 `selector@text##{{book.name}}`），它只是替换段，
     * 规则仍按正常方式求值。
     */
    var firstTpl = text.indexOf('{{');
    var firstHash = text.indexOf('##');
    if (firstTpl >= 0 && (firstHash < 0 || firstTpl < firstHash)) {
      var made = makeUpRule(text, ctx);
      var tplParts = made.split('##');
      var tplValue = tplParts[0];
      if (tplParts.length > 1) {
        tplValue = applyRegexPipelineParts(tplValue, tplParts);
      }
      if (isUrl) { tplValue = absolute(ctx.baseUrl, tplValue); }
      return unescapeHtml(tplValue);
    }
    var joined = makeUpRule(text, ctx);
    // 一条规则里可能混着 `<js>...</js>` 与普通规则段（阅读允许），按 js 段切开逐段求值
    var out = evalWithJsSegments(joined, ctx, isUrl);
    return unescapeHtml(out);
  }

  /** 处理 `tag.li<js></js>//a` 这种「js 段夹在普通规则之间」的写法 */
  function evalWithJsSegments(rule, ctx, isUrl) {
    var re = /<js>([\s\S]*?)<\/js>/g;
    if (!re.test(rule)) { return evalSingle(rule, ctx, isUrl); }
    re.lastIndex = 0;
    var out = '';
    var last = 0;
    var m;
    var isFirst = true;
    while ((m = re.exec(rule)) !== null) {
      var plain = rule.slice(last, m.index);
      if (plain.trim().length > 0) {
        out = isFirst ? evalSingle(plain, ctx, isUrl) : applyToValue(out, plain, ctx, isUrl);
        isFirst = false;
      }
      var sub = new Ctx(out !== '' ? out : ctx.result, ctx.baseUrl, ctx.src, {
        book: ctx.book, chapter: ctx.chapter, key: ctx.key, page: ctx.page,
      });
      var v;
      try { v = runJS(m[1], sub); } catch (e) { v = ''; }
      out = v === null || v === undefined ? '' : String(v);
      isFirst = false;
      last = re.lastIndex;
    }
    var tail = rule.slice(last);
    if (tail.trim().length > 0) {
      out = applyToValue(out, tail, ctx, isUrl);
    }
    return out;
  }

  /** 把「后面的规则段」作用到前一段的结果上 */
  function applyToValue(value, rule, ctx, isUrl) {
    var sub = new Ctx(value, ctx.baseUrl, ctx.src, {
      book: ctx.book, chapter: ctx.chapter, key: ctx.key, page: ctx.page,
    });
    var t = String(rule).trim();
    // 以 `@` 开头的是取值后缀（如 `@text`），否则是选择器
    return evalSingle(t, sub, isUrl);
  }

  /** 列表求值：搜索/发现的 bookList、目录的 chapterList */
  function evalList(rule, ctx) {
    if (rule === null || rule === undefined) { return []; }
    var text = String(rule);
    if (text.trim().length === 0) { return []; }
    var made = makeUpRule(text, ctx);
    var mode = modeOf(made);
    var body = stripPrefix(made, mode);

    if (mode === 'regex') {
      var reverse = false;
      var pattern = body;
      if (pattern.charAt(0) === '-') { reverse = true; pattern = pattern.slice(1); }
      pattern = pattern.split('##')[0];
      var items = regexList(ctx.src !== '' ? ctx.src : String(ctx.result || ''), pattern, reverse);
      return items.map(function (o) { return JSON.stringify(o); });
    }
    if (mode === 'js') {
      var v;
      try { v = runJS(body, ctx); } catch (e) { throw e; }
      return jsValueToList(v);
    }
    if (mode === 'json') {
      var root2 = ctx.result;
      if (typeof root2 === 'string') {
        try { root2 = JSON.parse(root2); } catch (e) { root2 = null; }
      }
      return jsonPathList(root2, body.trim());
    }
    // Default / CSS：返回每个元素的 outerHTML（下一级字段规则会在片段里找）
    var html = String(ctx.result === null || ctx.result === undefined ? '' : ctx.result);
    var nodes = queryAll(html, body);
    if (nodes !== null && nodes.length > 0) {
      return nodes.map(function (n) { return n.outerHTML; });
    }
    var legacy = legacyQuery(html, splitTop(body, ['@']));
    if (legacy.length > 0) {
      return legacy.map(function (n) { return n.outerHTML; });
    }
    return [];
  }

  /**
   * JS 列表规则的结果转成条目列表
   *
   * **对象要原样保留**：`ruleSearch.bookList` 常常是 `@js:` 直接造出
   * `[{name, url, cover, author}]`，接着 `name: "name"` / `bookUrl: "url"` 这种
   * 字段规则是「按键取值」而不是 CSS 选择器。一旦在这里 JSON.stringify 成字符串，
   * 后面就会把它当 HTML 去查选择器，条目全丢（书音FM 正是这么写的）。
   */
  function jsValueToList(v) {
    if (v === null || v === undefined) { return []; }
    if (Array.isArray(v)) {
      var out = [];
      for (var i = 0; i < v.length; i++) {
        var item = v[i];
        if (item === null || item === undefined) { continue; }
        out.push(item);
      }
      return out;
    }
    if (typeof v === 'string') {
      var s = v.trim();
      if (s.charAt(0) === '[') {
        try {
          var arr = JSON.parse(s);
          if (Array.isArray(arr)) { return jsValueToList(arr); }
        } catch (e) { /* 当普通字符串 */ }
      }
      return s.length > 0 ? [s] : [];
    }
    return [v];
  }

  // ============================================================ 9. 动作

  function fetchText(url, extra) {
    var spec = specOf(url, sourceHeaders());
    if (extra && extra.method) { spec.method = String(extra.method).toUpperCase(); }
    if (extra && extra.body) { spec.body = String(extra.body); }
    if (extra && extra.headers) {
      for (var k in extra.headers) { spec.headers[k] = String(extra.headers[k]); }
    }
    return requestBody(spec);
  }

  function pick(rules, names) {
    for (var i = 0; i < names.length; i++) {
      var key = names[i];
      var v = rules ? rules[key] : null;
      if (v !== null && v !== undefined && String(v).trim().length > 0) {
        return String(v);
      }
    }
    return '';
  }

  /** 逐条目求值时用的上下文：result 是条目本身，src 是它的文本形式 */
  function itemCtx(element, baseUrl, extra) {
    var ctx = new Ctx(element, baseUrl, '', extra);
    ctx.src = typeof element === 'string' ? element : JSON.stringify(element);
    return ctx;
  }

  /** 把书源里的一条「字段规则」求出来（单条规则出错不该拖垮整个动作） */
  function field(rules, name, ctx) {
    var r = rules ? rules[name] : null;
    if (r === null || r === undefined) { return ''; }
    try {
      return evalField(r, ctx, false);
    } catch (e) {
      LOGS.push('字段 ' + name + ' 规则出错：' + (e && e.message ? e.message : String(e)));
      return '';
    }
  }

  function listField(rules, name, ctx) {
    var r = rules ? rules[name] : null;
    if (r === null || r === undefined) { return []; }
    try {
      return evalList(r, ctx);
    } catch (e) {
      LOGS.push('列表 ' + name + ' 规则出错：' + (e && e.message ? e.message : String(e)));
      return [];
    }
  }

  /** 搜索 / 发现：走 searchUrl / exploreUrl 拿到列表页，再按 ruleSearch / ruleExplore 拆条目 */
  function doSearch(job, isExplore) {
    var source = job.source;
    var key = job.key === undefined ? '' : String(job.key);
    var page = job.page === undefined ? 1 : Number(job.page);
    var rawUrl = isExplore
      ? String(job.exploreUrl || job.url || source.exploreUrl || '')
      : String(source.searchUrl || '');
    if (rawUrl.trim().length === 0) {
      throw new Error(isExplore ? '该书源没有发现规则' : '该书源没有搜索规则');
    }
    var ctx = new Ctx('', String(source.bookSourceUrl || ''), '', { key: key, page: page });
    var url = buildUrl(rawUrl, ctx, true, job.url);
    var body = fetchTextFor(url, ctx);
    ctx.result = body;
    ctx.src = body;
    ctx.baseUrl = typeof url === 'string' && url.indexOf('http') === 0 ? url : String(source.bookSourceUrl || '');

    var rules = isExplore ? source.ruleExplore : source.ruleSearch;
    var elements = listField(rules, 'bookList', ctx);
    var out = [];
    for (var i = 0; i < elements.length && i < 200; i++) {
      // 逐条目求值时 `result` 与 `src` 都是这一条（阅读里是 analyzeRule.setContent(item)），
      // 不是整个列表页 —— 于是 `@js: JSON.parse(src)` 拿到的是本条 JSON
      var item = itemCtx(elements[i], ctx.baseUrl, { key: key, page: page });
      var bookUrl = field(rules, 'bookUrl', item);
      if (bookUrl.length === 0) { continue; }
      bookUrl = absolute(ctx.baseUrl, bookUrl);
      var name = field(rules, 'name', item);
      if (name.length === 0) { name = field(rules, 'title', item); }
      out.push({
        name: name,
        author: field(rules, 'author', item),
        coverUrl: absolute(ctx.baseUrl, field(rules, 'coverUrl', item)),
        intro: field(rules, 'intro', item),
        kind: field(rules, 'kind', item),
        lastChapter: field(rules, 'lastChapter', item),
        wordCount: field(rules, 'wordCount', item),
        status: field(rules, 'status', item),
        updateTime: field(rules, 'updateTime', item),
        bookUrl: bookUrl,
      });
    }
    return out;
  }

  /** 书源地址可能是相对路径：优先用书源自己的域名拼 */
  function buildUrl(rawRule, ctx, jsOnly, explicitUrl) {
    var text = String(rawRule || '').trim();
    if (explicitUrl) {
      // 由宿主直接给的地址（目录页等）
      return absolute(String(ctx.baseUrl || ''), explicitUrl);
    }
    // 整条就是个 js：跑出地址来
    if (/^<js>/i.test(text)) {
      var code = text.replace(/^<js>/i, '').replace(/<\/js>$/i, '');
      var v = runJS(code, ctx);
      return v === null || v === undefined ? '' : String(v).trim();
    }
    var made = makeUpRule(text, ctx, jsOnly).trim();
    // 搜索 / 发现地址允许写成相对路径（`/search.php?...`），用书源自己的站址补全
    if (made.length > 0 && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(made)) {
      made = absolute(String(lastSourceUrl() || ''), made);
    }
    return made;
  }

  var LAST_SOURCE_URL = '';
  function lastSourceUrl() { return LAST_SOURCE_URL; }

  /** 抓取一个地址，若是 data: URL 就地解码 */
  function fetchTextFor(url, ctx) {
    var u = String(url || '').trim();
    if (u.length === 0) { throw new Error('规则没有算出地址'); }
    if (/^data:/i.test(u)) {
      var comma = u.indexOf(',');
      var payload = comma >= 0 ? u.slice(comma + 1) : '';
      if (/;base64/i.test(u.slice(0, comma))) {
        return base64Decode(payload);
      }
      try { return decodeURIComponent(payload); } catch (e) { return payload; }
    }
    return fetchText(u);
  }

  function doBookInfo(job) {
    var source = job.source;
    var book = job.book || {};
    var rules = source.ruleBookInfo || {};
    var ctx = new Ctx('', String(book.bookUrl || ''), '', { book: book, fromBookInfo: true });
    var url = String(book.bookUrl || '');
    var initRule = String(rules.init || '').trim();
    if (initRule.length > 0) {
      var built = buildUrl(initRule, ctx, false, null);
      if (built.length > 0) { url = built; }
    }
    var body = fetchTextFor(url, ctx);
    ctx.result = body;
    ctx.src = body;
    ctx.baseUrl = url;
    var out = {
      name: field(rules, 'name', ctx),
      author: field(rules, 'author', ctx),
      coverUrl: absolute(url, field(rules, 'coverUrl', ctx)),
      intro: field(rules, 'intro', ctx),
      kind: field(rules, 'kind', ctx),
      status: field(rules, 'status', ctx),
      wordCount: field(rules, 'wordCount', ctx),
      lastChapter: field(rules, 'lastChapter', ctx),
      updateTime: field(rules, 'updateTime', ctx),
      tocUrl: '',
    };
    var tocRule = String(rules.tocUrl || '').trim();
    if (tocRule.length > 0) {
      var toc = makeUpRule(tocRule, ctx);
      // `{{bookUrl}}` 这种模板已在 makeUpRule 里换掉；若算出来是空就用书本身地址
      out.tocUrl = toc.trim().length > 0 ? absolute(url, toc.trim()) : url;
    } else {
      out.tocUrl = url;
    }
    return out;
  }

  /** 目录最多翻多少页（阅读是懒加载，这里一次拉全，所以要有个上限） */
  var TOC_PAGE_LIMIT = 60;

  function doToc(job) {
    var source = job.source;
    var book = job.book || {};
    var rules = source.ruleToc || {};
    var startUrl = String(job.url || book.tocUrl || book.bookUrl || '');
    var out = [];
    var seen = {};
    var nextUrl = startUrl;
    var guard = 0;

    while (nextUrl && nextUrl.length > 0 && guard < TOC_PAGE_LIMIT) {
      guard++;
      var ctx = new Ctx('', nextUrl, '', { book: book });
      var body = fetchTextFor(nextUrl, ctx);
      ctx.result = body;
      ctx.src = body;
      ctx.baseUrl = nextUrl;

      var elements = listField(rules, 'chapterList', ctx);
      for (var i = 0; i < elements.length && i < 5000; i++) {
        // 与搜索一致：逐章求值时 result / src 都是这一条
        var item = itemCtx(elements[i], nextUrl, { book: book });
        var name = field(rules, 'chapterName', item);
        var url = field(rules, 'chapterUrl', item);
        url = absolute(nextUrl, url);
        if (name.length === 0 && url.length === 0) { continue; }
        var dedupe = url.length > 0 ? url : name;
        if (seen[dedupe]) { continue; }
        seen[dedupe] = 1;
        out.push({
          index: out.length,
          name: name.length > 0 ? name : ('第' + (out.length + 1) + '集'),
          url: url,
          duration: field(rules, 'duration', item),
          isVip: field(rules, 'isVip', item),
          updateTime: field(rules, 'updateTime', item),
        });
      }

      // 下一页
      var nextRule = String(rules.nextTocUrl || '').trim();
      if (nextRule.length === 0) { break; }
      var ctx2 = new Ctx('', nextUrl, body, { book: book });
      var candidate = '';
      try {
        candidate = evalField(nextRule, ctx2, true);
      } catch (e) { candidate = ''; }
      candidate = String(candidate || '').trim();
      candidate = absolute(nextUrl, candidate);
      if (candidate.length === 0 || candidate === nextUrl || seen[candidate] === 1) { break; }
      seen[candidate] = 1;
      nextUrl = candidate;
    }
    return out;
  }

  function doContent(job) {
    var source = job.source;
    var book = job.book || {};
    var chapter = job.chapter || {};
    var rules = source.ruleContent || {};
    var url = String(chapter.url || '');
    var ctx = new Ctx('', url, '', { book: book, chapter: chapter });
    var body = fetchTextFor(url, ctx);
    ctx.result = body;
    ctx.src = body;
    ctx.baseUrl = url;

    // 有声书：优先 audioUrl，其次 content（各家写法不一）
    var candidates = [];
    var audioRule = String(rules.audioUrl || '').trim();
    if (audioRule.length > 0) { candidates.push(['audioUrl', audioRule]); }
    var contentRule = String(rules.content || '').trim();
    if (contentRule.length > 0) { candidates.push(['content', contentRule]); }

    var found = '';
    var from = '';
    for (var i = 0; i < candidates.length && found.length === 0; i++) {
      var value = field({ __r: candidates[i][1] }, '__r', ctx);
      value = String(value || '').trim();
      if (value.length === 0) { continue; }
      var extracted = extractUrl(value);
      if (extracted.length > 0) {
        found = absolute(url, extracted);
        from = candidates[i][0];
      }
    }
    // ruleContent 整个为空（悦听 / 播客）：章节地址本身就是音频直链
    if (found.length === 0 && candidates.length === 0) {
      if (/\.(mp3|m4a|aac|wav|ogg|m3u8|flac)(\?|$)/i.test(url) || /^https?:/i.test(url)) {
        found = url;
        from = 'chapterUrl';
      }
    }
    return { url: found, from: from, title: field(rules, 'title', ctx) };
  }

  /** 从一段文本里挖出音频直链（规则可能返回 JSON 片段或整页 HTML） */
  function extractUrl(value) {
    var v = String(value || '').trim();
    if (v.length === 0) { return ''; }
    if (/^https?:\/\//i.test(v)) {
      // 已经是直链，但可能带了说明文字，取第一段连续的非空白
      var sp = v.split(/\s+/)[0];
      return sp;
    }
    if (v.charAt(0) === '{' || v.charAt(0) === '[') {
      try {
        var obj = JSON.parse(v);
        var picked = pickUrlFromObject(obj);
        if (picked.length > 0) { return picked; }
      } catch (e) { /* 继续用正则 */ }
    }
    // 从 HTML / JS 片段里抓第一个音频地址
    var m = v.match(/https?:\/\/[^\s"'<>\\)]+?\.(?:mp3|m4a|aac|wav|ogg|m3u8|flac)(?:\?[^\s"'<>]*)?/i);
    if (m) { return m[0]; }
    m = v.match(/https?:\/\/[^\s"'<>\\)]+/);
    return m ? m[0] : '';
  }

  function pickUrlFromObject(obj) {
    if (obj === null || obj === undefined) { return ''; }
    if (typeof obj === 'string') { return /^https?:\/\//i.test(obj) ? obj : ''; }
    if (Array.isArray(obj)) {
      for (var i = 0; i < obj.length; i++) {
        var got = pickUrlFromObject(obj[i]);
        if (got.length > 0) { return got; }
      }
      return '';
    }
    var prefer = ['url', 'playUrl', 'playUrl64', 'src', 'audio', 'audioUrl', 'm4a', 'mp3', 'playPathAacv224', 'playPath'];
    for (var p = 0; p < prefer.length; p++) {
      if (typeof obj[prefer[p]] === 'string' && /^https?:\/\//i.test(obj[prefer[p]])) {
        return obj[prefer[p]];
      }
    }
    for (var k in obj) {
      var v = pickUrlFromObject(obj[k]);
      if (v.length > 0) { return v; }
    }
    return '';
  }

  // ============================================================ 10. 入口

  function parseExplore(source) {
    var raw = String(source.exploreUrl || '').trim();
    var out = [];
    if (raw.length === 0) { return out; }
    if (raw.charAt(0) === '[') {
      try {
        var arr = JSON.parse(raw);
        for (var i = 0; i < arr.length; i++) {
          var it = arr[i];
          if (!it) { continue; }
          var title = String(it.title || '');
          var url = String(it.url || '');
          if (title.length === 0) { continue; }
          out.push({ title: title, url: url });
        }
        return out;
      } catch (e) { /* 退回逐行格式 */ }
    }
    var lines = raw.split('\n');
    for (var j = 0; j < lines.length; j++) {
      var line = String(lines[j]).trim();
      if (line.length === 0) { continue; }
      var idx = line.indexOf('::');
      if (idx < 0) { continue; }
      out.push({ title: line.slice(0, idx).trim(), url: line.slice(idx + 2).trim() });
    }
    return out;
  }

  function resetRound() {
    NET_MISS = {};
    LOGS = [];
  }

  function netMissList() {
    var keys = Object.keys(NET_MISS);
    var out = [];
    for (var i = 0; i < keys.length; i++) { out.push(NET_MISS[keys[i]]); }
    return out;
  }

  global.__book_run__ = function (jobJson) {
    var job;
    try {
      job = (typeof jobJson === 'string') ? JSON.parse(jobJson) : jobJson;
    } catch (e) {
      return JSON.stringify({ status: 'error', message: '作业参数不是合法 JSON' });
    }
    resetRound();
    CUR_SOURCE = job.source || null;
    CUR_HEADERS = null;
    CUR_VARIABLE = CUR_SOURCE && CUR_SOURCE.variable ? String(CUR_SOURCE.variable) : '';
    CUR_LOGIN = job.login || {};
    LAST_SOURCE_URL = CUR_SOURCE ? String(CUR_SOURCE.bookSourceUrl || '') : '';
    installLib(CUR_SOURCE);
    if (job.netCache) {
      for (var k in job.netCache) { NET_CACHE[k] = job.netCache[k]; }
    }

    var data = null;
    var error = null;
    try {
      var action = String(job.action || '');
      if (action === 'search') { data = doSearch(job, false); }
      else if (action === 'explore') { data = doSearch(job, true); }
      else if (action === 'exploreList') { data = parseExplore(CUR_SOURCE); }
      else if (action === 'bookInfo') { data = doBookInfo(job); }
      else if (action === 'toc') { data = doToc(job); }
      else if (action === 'content') { data = doContent(job); }
      else { error = '未知动作：' + action; }
    } catch (e) {
      error = (e && e.message) ? String(e.message) : String(e);
    }

    // 只要本轮有「没抓到的地址」，就先让宿主去抓、下一轮重跑；
    // 这一轮算出来的结果（哪怕是报错）都丢掉 —— 它本来就是拿空响应算出来的。
    var miss = netMissList();
    if (miss.length > 0) {
      return JSON.stringify({ status: 'net', urls: miss, logs: LOGS });
    }
    if (error !== null) {
      return JSON.stringify({ status: 'error', message: error, logs: LOGS });
    }
    return JSON.stringify({ status: 'ok', data: data, logs: LOGS });
  };

  global.__book_ping__ = function () {
    return JSON.stringify({ ok: true, hasDom: typeof DOMParser !== 'undefined', hasEval: true });
  };

})(window);
