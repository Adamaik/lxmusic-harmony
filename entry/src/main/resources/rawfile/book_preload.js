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
  /** 宿主已抓回来的响应头：key -> { Name: Value }（`java.post(...).headers()` 要用） */
  var NET_HEADERS = {};
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

  /**
   * 宽松解析一段 JSON
   *
   * 书源里把 key / 字符串写成单引号很常见（`{'headers':{...}}`）—— 这在标准 JSON 里
   * 非法，但阅读用的 Gson 宽松模式能吃。严格 JSON 解析失败时，把单引号换成双引号再试一次。
   */
  function parseLooseJson(text) {
    try { return JSON.parse(text); } catch (e) { /* 再宽松试一次 */ }
    var fixed = String(text)
      .replace(/([{,]\s*)'([^']+)'\s*:/g, '$1"$2":')
      .replace(/:\s*'([^']*)'/g, ':"$1"')
      .replace(/,\s*([}\]])/g, '$1');
    try { return JSON.parse(fixed); } catch (e2) { return null; }
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
          options = (typeof arg[1] === 'string') ? parseLooseJson(arg[1]) || {} : arg[1];
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
      var parsed = parseLooseJson(tail);
      if (parsed && typeof parsed === 'object') {
        options = parsed;
        url = url.slice(0, comma);
      }
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

  /**
   * 同一次请求的**响应头**（宿主与正文一起带回来）
   *
   * 只有正文被缓存过的 key 才有头；没缓存就返回空对象（不额外登记缺失 ——
   * 正文那一步已经登记过了，宿主抓回来时头和正文是一起到的）。
   */
  function requestHeaders(spec) {
    var key = netKey(spec);
    return Object.prototype.hasOwnProperty.call(NET_HEADERS, key) ? NET_HEADERS[key] : {};
  }

  /**
   * java.ajax(url[, header])：同步返回响应正文
   *
   * 阅读的 `java.ajax` 允许第二个参数给请求头（书音FM 的 ECMS 调用就传了一段
   * header JSON）。早先这里只收一个参数，那些头被静默丢掉 —— 站点按 Referer /
   * Accept 区分响应时会拿到错误结果。现在与 `java.connect` 一样吃下这个参数。
   */
  function ajax(arg, header) {
    var spec = specOf(arg, CUR_SOURCE ? sourceHeaders() : null);
    if (header) {
      var h = header;
      if (typeof h === 'string') { try { h = JSON.parse(h); } catch (e) { h = null; } }
      if (h) {
        for (var k in h) { spec.headers[k] = String(h[k]); }
        // 头变了要重新算 key
        spec = { url: spec.url, method: spec.method, body: spec.body, headers: spec.headers };
      }
    }
    return requestBody(spec);
  }

  /** java.connect(url, header, body)：返回一个带 body() / headers() 的响应对象 */
  function connect(arg, header, body) {
    var spec = specOf(arg, sourceHeaders());
    if (body !== undefined && body !== null) { spec.body = String(body); }
    if (header) {
      var h = header;
      if (typeof h === 'string') { try { h = parseLooseJson(h); } catch (e) { h = null; } }
      if (h) { for (var k in h) { spec.headers[k] = String(h[k]); } }
    }
    // body / 头变过都要重新算 key（netKey 把它们都算进去了）
    spec = { url: spec.url, method: spec.method, body: spec.body, headers: spec.headers };
    return {
      url: spec.url,
      code: function () { return 200; },
      headers: function () {
        var raw = requestHeaders(spec);
        var out = {};
        for (var k in raw) {
          out[k] = raw[k];
          // 头名大小写不一：源里常写 `res.location` 而后端发的是 `Location`
          out[String(k).toLowerCase()] = raw[k];
        }
        return out;
      },
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
      /** 登录信息（同 getLoginInfoMap；阅读里两个名字都有） */
      getLoginInfo: function () { return CUR_LOGIN; },
      /**
       * 保存登录信息（登录弹窗里的「保存 Cookie」按钮会调）
       *
       * 沙箱每次调用都是无状态的，所以这里只把值并进本轮的 `CUR_LOGIN`，
       * 宿主从返回值里把它取走落盘（见 BookEngine.runLoginAction）。
       */
      putLoginInfo: function (map) {
        if (map !== null && map !== undefined && typeof map === 'object') {
          for (var k in map) { CUR_LOGIN[k] = map[k] === undefined || map[k] === null ? '' : String(map[k]); }
        }
        return CUR_LOGIN;
      },
      /** 源自己的临时变量（阅读里 source.put / source.get，跨规则共享，如懒人听书的 bookIds） */
      put: function (key, value) {
        PUT_STORE[String(key)] = (value === undefined || value === null) ? '' : String(value);
        return value;
      },
      get: function (key) {
        var v = PUT_STORE[String(key)];
        return v === undefined ? '' : v;
      },
      getKey: function () { return CUR_VARIABLE; },
      // 阅读里 bookSourceUrl 是**属性**（`source.bookSourceUrl + "xxx"`），不是方法：
      // 写成方法会让 `source.bookSourceUrl + "e/search"` 拼出整个函数源码
      bookSourceUrl: CUR_SOURCE ? String(CUR_SOURCE.bookSourceUrl || '') : '',
    };
  }

  // ============================================================ 3. 工具

  var PURE = global.LXPureUtils;

  /**
   * md5（小写 hex）
   *
   * `lx_utils.js` 导出的是 `str2md5(str)`（内部才是 `md5Hex(bytes)`），
   * 早先这里写的 `PURE.md5(...)` 并不存在 —— 于是 `java.md5Encode()` 永远返回空串，
   * 书源里凡是用 md5 签名（书音FM 的 ECMS token 就是）的接口都会算错 token、拿不到音频。
   * 两个名字都认一下，避免以后改名又悄悄失效。
   */
  function md5Hex(text) {
    if (PURE && typeof PURE.str2md5 === 'function') { return PURE.str2md5(String(text)); }
    if (PURE && typeof PURE.md5 === 'function') { return PURE.md5(String(text)); }
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

  /** 十六进制字符串 -> UTF-8 文本（阅读的 java.hexDecodeToString） */
  function hexDecodeToString(text) {
    var hex = String(text === undefined || text === null ? '' : text).replace(/[^0-9a-fA-F]/g, '');
    if (hex.length === 0) { return ''; }
    var encoded = '';
    for (var i = 0; i + 1 < hex.length; i += 2) {
      encoded += '%' + hex.substr(i, 2);
    }
    try {
      return decodeURIComponent(encoded);
    } catch (e) {
      return '';
    }
  }

  /**
   * 阅读的 `getArguments(str, key, def)`：从 `key=value&...` 或 JSON 串里取一个值
   *
   * 「小说，漫画，听书」那类源把配置塞在 variable/comment 里，规则开头的 `<js>` 用它取服务器地址。
   */
  function getArguments(text, key, def) {
    var s = String(text === undefined || text === null ? '' : text).trim();
    if (s.length === 0) { return def === undefined ? '' : def; }
    if (s.charAt(0) === '{') {
      var obj = parseLooseJson(s);
      if (obj && typeof obj === 'object' && obj[key] !== undefined && obj[key] !== null) { return obj[key]; }
      return def === undefined ? '' : def;
    }
    var parts = s.split(/[&\n]/);
    for (var i = 0; i < parts.length; i++) {
      var idx = parts[i].indexOf('=');
      if (idx > 0 && parts[i].slice(0, idx).trim() === String(key)) {
        return parts[i].slice(idx + 1).trim();
      }
    }
    return def === undefined ? '' : def;
  }

  /** 从 `a=1; b=2` 的 Cookie 串里取一个名字的值（忽略大小写） */
  function cookieValueOf(cookieString, name) {
    var parts = String(cookieString === undefined || cookieString === null ? '' : cookieString).split(';');
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].trim();
      var eq = pair.indexOf('=');
      if (eq > 0 && pair.slice(0, eq).trim().toLowerCase() === String(name).toLowerCase()) {
        return pair.slice(eq + 1).trim();
      }
    }
    return '';
  }

  /**
   * 当前源的登录 Cookie 串
   *
   * 优先用固定键 `Cookie`；没有就找登录信息表里任何「名字含 cookie」的字段 ——
   * 喜马拉雅只写了 `喜马拉雅Cookie` 这个键，哔哩哔哩靠网页登录写进来的 `Cookie`，
   * 两者都要能取到。
   */
  function loginCookieString() {
    if (CUR_LOGIN) {
      if (CUR_LOGIN['Cookie']) { return String(CUR_LOGIN['Cookie']); }
      if (CUR_LOGIN['cookie']) { return String(CUR_LOGIN['cookie']); }
      for (var k in CUR_LOGIN) {
        if (String(k).toLowerCase().indexOf('cookie') >= 0 && CUR_LOGIN[k]) { return String(CUR_LOGIN[k]); }
      }
    }
    return '';
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

  // ============================================================ 6.5 Rhino 的 Java 互操作

  /**
   * 阅读的书源跑在 Rhino 里，`Packages.xxx` / `java.lang.String` 能直接拿到真实 Java 类；
   * 有些源的 jsLib 就靠这个做解密（听友FM 的 XChaCha20Poly1305、懒人听书本地源的
   * android.util.Base64）。ArkWeb 里没有 Packages，规则一跑到那一行就抛
   * `Packages is not defined`，`listField` 把它吞成空数组 —— 表现是「一本都没有」，
   * 还看不出错在哪。
   *
   * 这里只补**实际用到的**那几个类，不做通用 Java 桥（浏览器里没有意义）：
   *   java.io.ByteArrayOutputStream、java.lang.String、
   *   javax.crypto.Cipher（ChaCha20-Poly1305，纯 JS）、spec.SecretKeySpec / GCMParameterSpec、
   *   android.util.Base64。
   * 规则是**同步**求值的，所以不能用 WebCrypto（全是 Promise），AEAD 只能自己写。
   */

  function __chachaRotl(v, n) { return ((v << n) | (v >>> (32 - n))) >>> 0; }

  function __chachaQr(s, a, b, c, d) {
    s[a] = (s[a] + s[b]) >>> 0; s[d] = __chachaRotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) >>> 0; s[b] = __chachaRotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) >>> 0; s[d] = __chachaRotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) >>> 0; s[b] = __chachaRotl(s[b] ^ s[c], 7);
  }

  /** ChaCha20 的一个 64 字节密钥块（IETF 版：32 位计数器 + 12 字节 nonce） */
  function __chachaBlock(key, counter, nonce) {
    var st = new Uint32Array(16);
    st[0] = 0x61707865; st[1] = 0x3320646e; st[2] = 0x79622d32; st[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      st[4 + i] = (key[i * 4] | (key[i * 4 + 1] << 8) | (key[i * 4 + 2] << 16) | (key[i * 4 + 3] << 24)) >>> 0;
    }
    st[12] = counter >>> 0;
    for (var j = 0; j < 3; j++) {
      st[13 + j] = (nonce[j * 4] | (nonce[j * 4 + 1] << 8) | (nonce[j * 4 + 2] << 16) | (nonce[j * 4 + 3] << 24)) >>> 0;
    }
    var w = st.slice(0);
    for (var r = 0; r < 10; r++) {
      __chachaQr(st, 0, 4, 8, 12); __chachaQr(st, 1, 5, 9, 13); __chachaQr(st, 2, 6, 10, 14); __chachaQr(st, 3, 7, 11, 15);
      __chachaQr(st, 0, 5, 10, 15); __chachaQr(st, 1, 6, 11, 12); __chachaQr(st, 2, 7, 8, 13); __chachaQr(st, 3, 4, 9, 14);
    }
    var out = new Uint8Array(64);
    for (var k = 0; k < 16; k++) {
      var v = (st[k] + w[k]) >>> 0;
      out[k * 4] = v & 255; out[k * 4 + 1] = (v >>> 8) & 255;
      out[k * 4 + 2] = (v >>> 16) & 255; out[k * 4 + 3] = (v >>> 24) & 255;
    }
    return out;
  }

  function __chachaXor(key, counter, nonce, data) {
    var out = new Uint8Array(data.length);
    var off = 0;
    var c = counter >>> 0;
    while (off < data.length) {
      var ks = __chachaBlock(key, c, nonce);
      for (var i = 0; i < 64 && off < data.length; i++, off++) { out[off] = data[off] ^ ks[i]; }
      c = (c + 1) >>> 0;
    }
    return out;
  }

  /** Poly1305（RFC 8439），130 位乘法交给 BigInt，省得自己拼 limb */
  function __poly1305(key, msg) {
    var i;
    var r = 0n;
    for (i = 15; i >= 0; i--) { r = (r << 8n) | BigInt(key[i]); }
    r &= 0x0ffffffc0ffffffc0ffffffc0fffffffn;
    var s = 0n;
    for (i = 15; i >= 0; i--) { s = (s << 8n) | BigInt(key[16 + i]); }
    var p = (1n << 130n) - 5n;
    var acc = 0n;
    for (var off = 0; off < msg.length; off += 16) {
      var n = msg.subarray(off, Math.min(off + 16, msg.length));
      var v = 0n;
      for (i = n.length - 1; i >= 0; i--) { v = (v << 8n) | BigInt(n[i]); }
      v |= (1n << BigInt(n.length * 8));
      acc = ((acc + v) * r) % p;
    }
    acc = (acc + s) & ((1n << 128n) - 1n);
    var tag = new Uint8Array(16);
    for (i = 0; i < 16; i++) { tag[i] = Number((acc >> BigInt(i * 8)) & 255n); }
    return tag;
  }

  /** ChaCha20-Poly1305 AEAD 解密：`sealed` = 密文 || 16 字节标签（`aad` 可省，默认空） */
  function __aeadDecrypt(key, nonce, sealed, aad) {
    if (sealed.length < 16) { throw new Error('ChaCha20-Poly1305：密文短于 16 字节'); }
    var ct = sealed.subarray(0, sealed.length - 16);
    var tag = sealed.subarray(sealed.length - 16);
    var ad = (aad === undefined || aad === null) ? new Uint8Array(0) : __bytesOf(aad);
    var polyKey = __chachaBlock(key, 0, nonce).subarray(0, 32);
    // MAC 的输入：aad || pad16 || 密文 || pad16 || len(aad) || len(密文)（RFC 8439 §2.8）
    var adPad = (16 - (ad.length % 16)) % 16;
    var ctPad = (16 - (ct.length % 16)) % 16;
    var macLen = ad.length + adPad + ct.length + ctPad + 16;
    var macData = new Uint8Array(macLen);
    var at = 0;
    macData.set(ad, at);
    at += ad.length + adPad;
    macData.set(ct, at);
    var alen = ad.length;
    var clen = ct.length;
    for (var b = 0; b < 8; b++) {
      macData[macLen - 16 + b] = b < 4 ? ((alen >>> (8 * b)) & 255) : 0;
      macData[macLen - 8 + b] = b < 4 ? ((clen >>> (8 * b)) & 255) : 0;
    }
    var mac = __poly1305(polyKey, macData);
    var diff = 0;
    for (var i = 0; i < 16; i++) { diff |= mac[i] ^ tag[i]; }
    if (diff !== 0) { throw new Error('ChaCha20-Poly1305：标签校验不过（密钥/密文/随机数对不上）'); }
    return __chachaXor(key, 1, nonce, ct);
  }

  function __bytesOf(x) {
    if (x instanceof Uint8Array) { return x; }
    if (x && x.length !== undefined) { return new Uint8Array(Array.prototype.slice.call(x)); }
    return new Uint8Array(0);
  }

  /** UTF-8 自己解：不依赖宿主的 TextDecoder（沙箱与无设备自检环境并不都提供它） */
  function __utf8Decode(b) {
    var out = '';
    var i = 0;
    while (i < b.length) {
      var c = b[i++];
      if (c < 0x80) { out += String.fromCharCode(c); continue; }
      var extra = 0;
      var cp = 0;
      if ((c & 0xe0) === 0xc0) { extra = 1; cp = c & 0x1f; }
      else if ((c & 0xf0) === 0xe0) { extra = 2; cp = c & 0x0f; }
      else if ((c & 0xf8) === 0xf0) { extra = 3; cp = c & 0x07; }
      else { out += '\ufffd'; continue; }
      if (i + extra > b.length) { out += '\ufffd'; break; }
      for (var k = 0; k < extra; k++) { cp = (cp << 6) | (b[i++] & 0x3f); }
      if (cp > 0xffff) {
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      } else {
        out += String.fromCharCode(cp);
      }
    }
    return out;
  }

  function __bytesToString(bytes, charset) {
    var b = __bytesOf(bytes);
    var cs = String(charset === undefined || charset === null ? 'UTF-8' : charset).toUpperCase();
    if (cs === 'UTF-8' || cs === 'UTF8') { return __utf8Decode(b); }
    // 非 UTF-8 少见（书源解密出来的都是 JSON），有 TextDecoder 就借一下
    try {
      if (typeof TextDecoder !== 'undefined') { return new TextDecoder(cs.toLowerCase()).decode(b); }
    } catch (e) { /* 落回 UTF-8 */ }
    return __utf8Decode(b);
  }

  var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function __base64NoWrap(b) {
    var out = '';
    for (var i = 0; i < b.length; i += 3) {
      var b0 = b[i];
      var b1 = i + 1 < b.length ? b[i + 1] : -1;
      var b2 = i + 2 < b.length ? b[i + 2] : -1;
      out += B64_CHARS.charAt(b0 >> 2);
      out += B64_CHARS.charAt(((b0 & 3) << 4) | (b1 < 0 ? 0 : (b1 >> 4)));
      out += b1 < 0 ? '=' : B64_CHARS.charAt(((b1 & 15) << 2) | (b2 < 0 ? 0 : (b2 >> 6)));
      out += b2 < 0 ? '=' : B64_CHARS.charAt(b2 & 63);
    }
    return out;
  }

  /**
   * `new java.lang.String(bytes, charset)` —— 书源拿它把解密结果转成字符串
   *
   * 必须返回 **String 包装对象**，不能是原始字符串：`new F()` 里 F 返回原始值时
   * JS 会丢掉它、改返回新对象，于是 JSON.parse 收到 "[object Object]"。
   * 包装对象当字符串用没区别（拼接 / JSON.parse / .length / 下标都行）。
   */
  function javaLangString(bytes, charset) {
    return new String(__bytesToString(bytes, charset));
  }

  var JAVA_PKG_CACHE = null;

  /** 建出 `Packages` / `javax` / `android` 这几个门面（建一次就缓存） */
  function buildJavaPackages() {
    function ByteArrayOutputStream() {
      var buf = [];
      this.write = function (v) { buf.push(v & 255); };
      this.toByteArray = function () { return new Uint8Array(buf); };
    }

    function SecretKeySpec(key, alg) { this.bytes = __bytesOf(key); this.alg = alg; }
    function GCMParameterSpec(tagLen, iv) { this.tagLen = tagLen; this.iv = __bytesOf(iv); }

    var DECRYPT_MODE = 2;
    var ENCRYPT_MODE = 1;

    function Cipher() {
      this.__alg = '';
      this.__mode = 0;
      this.__key = null;
      this.__iv = null;
      this.__aad = null;
      this.init = function (mode, key, spec) {
        this.__mode = mode;
        this.__key = key && key.bytes !== undefined ? key.bytes : __bytesOf(key);
        this.__iv = spec && spec.iv !== undefined ? spec.iv : (spec ? __bytesOf(spec) : null);
      };
      this.updateAAD = function (aad) { this.__aad = __bytesOf(aad); };
      this.doFinal = function (input) {
        var data = __bytesOf(input);
        if (String(this.__alg).toUpperCase().indexOf('CHACHA20-POLY1305') >= 0) {
          if (this.__mode !== DECRYPT_MODE) { throw new Error('沙箱只实现了 ChaCha20-Poly1305 解密'); }
          return __aeadDecrypt(this.__key, this.__iv, data, this.__aad);
        }
        throw new Error('沙箱没有实现这个算法：' + this.__alg);
      };
    }
    Cipher.getInstance = function (name) {
      var c = new Cipher();
      c.__alg = String(name === undefined || name === null ? '' : name);
      return c;
    };
    Cipher.DECRYPT_MODE = DECRYPT_MODE;
    Cipher.ENCRYPT_MODE = ENCRYPT_MODE;

    var Base64 = {
      /** Android 的 `Base64.encodeToString(bytes, flags)`，flags 2 = NO_WRAP（不折行） */
      encodeToString: function (bytes, flags) {
        var out = __base64NoWrap(__bytesOf(bytes));
        if ((Number(flags) & 2) === 0) { out = out.replace(/(.{76})/g, '$1\n'); }
        return out;
      },
    };

    return {
      java: {
        io: { ByteArrayOutputStream: ByteArrayOutputStream },
        lang: { String: javaLangString },
      },
      javax: {
        crypto: {
          Cipher: Cipher,
          spec: { SecretKeySpec: SecretKeySpec, GCMParameterSpec: GCMParameterSpec },
        },
      },
      android: { util: { Base64: Base64 } },
    };
  }

  function javaPackages() {
    if (JAVA_PKG_CACHE === null) { JAVA_PKG_CACHE = buildJavaPackages(); }
    return JAVA_PKG_CACHE;
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
    var pkg = javaPackages();
    return {
      java: java,
      // Rhino 的 Java 互操作门面（见第 6.5 节）：jsLib 里的函数是在全局作用域跑的，
      // publishGlobals 会把这两个也挂成全局量，书源里的 `Packages.` / 裸 `javax.` 才认
      Packages: pkg,
      javax: pkg.javax,
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
      cookie: {
        /** cookie.getCookie(url[, name])：返回网页登录抓来的 Cookie（可按名字取单个） */
        getCookie: function (url, name) {
          var c = loginCookieString();
          if (name !== undefined && name !== null && String(name).length > 0) {
            return cookieValueOf(c, name);
          }
          return c;
        },
        /**
         * 删除 Cookie 并返回删除前的值（阅读的 cookie.removeCookie）
         *
         * 书源把它当「取一次并清掉」用（幸福听书的 searchUrl 就是
         * `{{cookie.removeCookie(source.getKey())}}`）。应用不在这里维护站点 Cookie 的
         * 生命周期，所以返回空串 —— 效果是把那段模板替换成空，地址自然接成相对路径。
         * 注意别返回整串登录 Cookie：那会被拼进 URL 里。
         */
        removeCookie: function () { return ''; },
        setCookie: function () { },
      },
      getArguments: getArguments,
      fromBookInfo: ctx.fromBookInfo,
      // 登录弹窗的动作里要读用户刚填的值（`infoMap["喜马拉雅Cookie"]`），
      // 以及裸调 `startBrowser('...')`（播客源的登录按钮就是裸调）
      infoMap: CUR_LOGIN,
      startBrowser: function (url) { java.startBrowser(url); },
      loginInfo: CUR_LOGIN,
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
      // `new java.lang.String(bytes, 'UTF-8')` —— 解密类 jsLib 用它把 byte[] 转字符串
      lang: { String: javaLangString },
      ajax: function (url, header) { return ajax(url, header); },
      connect: function (url, header) { return connect(url, header); },
      /**
       * java.post(url, body, headers)：发一个 POST，返回带 body()/headers()/code() 的对象
       *
       * 阅读的书源用它先拿一次 302 的 Location（书听FM 的搜索就是这么两跳的）。
       * 走的是同一套回放循环，所以 body()/headers() 是同步取缓存。
       */
      post: function (url, body, header) {
        var opts = '{"method":"POST"}';
        return connect(url + ',' + opts, header, body);
      },
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
      hexDecodeToString: function (s) { return hexDecodeToString(s); },
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
      /** java.getCookie(domain[, name])：从网页登录抓来的 Cookie 串里取值 */
      getCookie: function (domain, name) {
        var c = loginCookieString();
        if (name !== undefined && name !== null && String(name).length > 0) {
          return cookieValueOf(c, name);
        }
        return c;
      },
      setCookie: function () { },
      log: function (msg) { LOGS.push(String(msg)); },
      logType: function () { },
      /** 阅读的 java.toast：登录弹窗里用来给用户回话，宿主拿出来显示 */
      toast: function (msg) { TOASTS.push(String(msg)); LOGS.push('[toast] ' + String(msg)); },
      longToast: function (msg) { TOASTS.push(String(msg)); LOGS.push('[toast] ' + String(msg)); },
      /** 阅读的 java.startBrowser：宿主用系统浏览器打开（登录页） */
      startBrowser: function (url) {
        var u = String(url || '');
        if (u.length > 0) { OPENS.push(u); }
      },
      androidId: function () { return 'zcode-harmony-listen'; },
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
  /** 登录弹窗里 java.toast 说的话（宿主拿出来显示给用户） */
  var TOASTS = [];
  /** java.startBrowser / startBrowser 要打开的地址（宿主用系统浏览器打开） */
  var OPENS = [];

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

  /**
   * 这一次要用哪一组规则
   *
   * 发现（explore）在阅读里是**会退回搜索规则**的：exploreUrl 有、ruleExplore 却空
   * 的时候，用 ruleSearch 去解析发现页。导出的书源里这种情况很常见 —— 有的把
   * ruleExplore 写成空对象，有的干脆是个空数组（`"ruleExplore": []`）。阅读 BookList.kt
   * 的判据是 `getExploreRule().bookList.isNullOrBlank() -> getSearchRule()`，这里照抄。
   *
   * 不退回的后果是「分类列得出来、点进去一本没有」，而且**不报错**，很难查。
   */
  function searchRulesFor(source, isExplore) {
    if (!isExplore) { return source.ruleSearch || {}; }
    var explore = source.ruleExplore;
    var list = explore ? explore.bookList : null;
    if (list !== null && list !== undefined && String(list).trim().length > 0) {
      return explore;
    }
    return source.ruleSearch || {};
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

    var rules = searchRulesFor(source, isExplore);
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

  /**
   * 地址里的**可选段** `<,_{{page}}>`
   *
   * 书源这么写的意思是「第一页没有这一段」—— 阅读的规则说明里给的就是它，
   * 等价于 `{{page - 1 == 0 ? "": page}}`。例如 `/booklist/1<,_{{page}}>.html`：
   * 第一页是 `/booklist/1.html`，第二页起才是 `/booklist/1_2.html`。
   *
   * 引擎原先不认这个语法：`{{page}}` 照样被替换成 1，地址里带着 `<,1>` 就去请求了 ——
   * 幻听网这类源于是**第一页就 404**，看着像「站点挂了」，其实是地址拼错。
   *
   * `<js>` / `</js>` 与 `@js:` 里的比较运算符不能动，所以只认「像可选段」的：
   * 首项为空（`,xxx`）或内含 `{{...}}`。
   */
  function resolveOptionalSegments(text, page) {
    var s = String(text || '');
    if (s.indexOf('<') < 0) { return s; }
    return s.replace(/<([^<>]*)>/g, function (whole, inner) {
      var body = String(inner);
      if (body.charAt(0) !== ',' && body.indexOf('{{') < 0) { return whole; }
      if (Number(page) <= 1) { return ''; }
      // 第一页以外：那个空首项是「第一页的形态」，跳过它取第一个有内容的候选
      var alts = body.split(',');
      for (var i = 0; i < alts.length; i++) {
        if (String(alts[i]).trim().length > 0) { return alts[i]; }
      }
      return '';
    });
  }

  /** 书源地址可能是相对路径：优先用书源自己的域名拼 */
  function buildUrl(rawRule, ctx, jsOnly, explicitUrl) {
    var text = String(rawRule || '').trim();
    if (explicitUrl) {
      // 由宿主直接给的地址（目录页等）
      return absolute(String(ctx.baseUrl || ''), explicitUrl);
    }
    // 整条就是个 js：跑出地址来（阅读里 `<js>` 与 `@js:` 两种写法都算数，
    // 目录 / 详情 / 搜索地址都可能是 `@js:` —— 只认 `<js>` 会把规则原样当地址拼，
    // 结果就是一个 404 的 `https://站点/@js:(function...`）
    if (/^<js>/i.test(text)) {
      var code = text.replace(/^<js>/i, '').replace(/<\/js>$/i, '');
      var v = runJS(code, ctx);
      return v === null || v === undefined ? '' : String(v).trim();
    }
    if (/^@js:/i.test(text)) {
      var code2 = text.replace(/^@js:/i, '');
      var v2 = runJS(code2, ctx);
      return v2 === null || v2 === undefined ? '' : String(v2).trim();
    }
    var made = makeUpRule(resolveOptionalSegments(text, ctx.page), ctx, jsOnly).trim();
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

  /**
   * exploreUrl → 分类表（**与 BookEngine.exploreCategories 同一口径**，改一处要改两处）
   *
   * 两种静态写法：JSON 数组，与「标题::地址」。后者**用 `&&` 或换行隔开都算**
   * （56听书的分类表整条都在一行里、用 `&&` 串起来）；`url` 为空的是分组标题，跳过。
   * `@js:` 那种整段脚本自己生成分类表的写法这里不处理（要跑沙箱，见 BookEngine 的说明）。
   */
  function parseExplore(source) {
    var raw = String(source.exploreUrl || '').trim();
    var out = [];
    if (raw.length === 0) { return out; }
    if (raw.charAt(0) === '[') {
      // 宽松解析：分类表里带尾逗号很常见（幸福听书整张表最后一项后面就多一个逗号），
      // 阅读的 Gson 吃得下，严格的 JSON.parse 会直接抛
      var arr = parseLooseJson(raw);
      if (arr && arr.length !== undefined) {
        for (var i = 0; i < arr.length; i++) {
          var it = arr[i];
          if (!it) { continue; }
          var title = String(it.title || '').trim();
          var url = String(it.url || '').trim();
          if (title.length === 0 || url.length === 0) { continue; }
          out.push({ title: title, url: url });
        }
        return out;
      }
    }
    var lines = raw.split(/&&|\n/);
    for (var j = 0; j < lines.length; j++) {
      var line = String(lines[j]).trim();
      if (line.length === 0) { continue; }
      var idx = line.indexOf('::');
      if (idx < 0) { continue; }
      var t = line.slice(0, idx).trim();
      var u = line.slice(idx + 2).trim();
      if (t.length === 0 || u.length === 0) { continue; }
      out.push({ title: t, url: u });
    }
    return out;
  }

  function resetRound() {
    NET_MISS = {};
    LOGS = [];
    TOASTS = [];
    OPENS = [];
  }

  /**
   * 登录动作（登录弹窗里的按钮 / `loginCheckJs`）
   *
   * 跑一条 `@js:` 规则，把 `infoMap` 与 `source` 绑进去。规则里通常会：
   *   - `source.putLoginInfo(infoMap)` 保存用户填的值；
   *   - `java.connect(...)` 校验（会走回放循环，缺地址就 return 'net'，宿主抓完再重跑）；
   *   - `java.toast('...')` 给用户回话。
   * 宿主从返回值里拿走三样：`login`（落盘）、`toasts`、`openUrl`。
   */
  function doLogin(job) {
    var rule = String(job.rule || '');
    // 规则通常写成 `@js: ...`（也有 `<js></js>` 的），要先把前缀摘掉再 eval
    var code = stripPrefix(rule, 'js');
    var ctx = new Ctx('', String(CUR_SOURCE ? CUR_SOURCE.bookSourceUrl : ''), '', {});
    var value = '';
    try {
      var v = runJS(code, ctx);
      value = (v === undefined || v === null) ? '' : String(v);
    } catch (e) {
      LOGS.push('登录动作出错：' + (e && e.message ? e.message : String(e)));
      value = '';
    }
    return {
      result: value,
      login: CUR_LOGIN,
      toasts: TOASTS.slice(0),
      openUrl: OPENS.length > 0 ? OPENS[OPENS.length - 1] : '',
    };
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
    if (job.netHeaders) {
      for (var hk in job.netHeaders) { NET_HEADERS[hk] = job.netHeaders[hk]; }
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
      else if (action === 'login') { data = doLogin(job); }
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
