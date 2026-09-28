import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  BookAudio,
  BookChapter,
  BookDetail,
  BookExploreCategory,
  BookHit,
  BookLoginResult,
  BookLoginUiItem,
  BookNetRequest,
  BookRunResult,
  BookRunStats,
  BookSource,
  BookSourceInfo,
} from './BookTypes';
import { BookCookieJar, BookResponse, bookRequest } from './BookHttp';
import { BookSourceStore, sourceText } from './BookSourceStore';
import { bytesToUtf8, utf8Bytes } from '../music/LxCrypto';
import { unwrapJsonString } from '../source/SourceEngine';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookEngine';

/** 沙箱页就绪 / 注入脚本的上限 */
const PAGE_READY_TIMEOUT: number = 10000;
/**
 * 一次书源动作最多「抓一轮 → 重跑」多少次
 *
 * 每轮至少解决一个缺失的地址（缓存只增不减），所以轮数 ≈ 不同地址的个数。
 * 喜马拉雅那种「一个专辑扫 30 页 + 签名」的源一次目录能到几十轮，
 * 留够余量但别无限等。
 */
const MAX_ROUNDS: number = 240;
/** 单次动作的总耗时上限（毫秒）：超过就报错，别把界面吊死 */
const ACTION_TIMEOUT: number = 120000;
/** 一轮里并发抓多少个地址 */
const FETCH_CONCURRENCY: number = 4;

export const BOOK_SANDBOX_UNAVAILABLE: string =
  '听书沙箱不可用：当前环境（如 DevEco Previewer 预览器）mock 了 rawfile 读取，导致 book_preload.js 为空。请在模拟器或真机上运行。';

/** 一个源被删除 / 替换时要能中断它的在途请求 */
interface ActiveRequest {
  cancelled: boolean;
}

/**
 * 站点 -> 真实登录页
 *
 * 书源里的 `loginUrl` 大多**不是登录页**：喜马拉雅的源写的是站址
 * （`https://www.ximalaya.com/`，会跳到手机版首页），播客聚合那个源写的是
 * `https://passport.ximalaya.com/` —— 那只是一台 Tengine 的默认页
 * （「Welcome to tengine!」）。直接打开就会出现「网页登录打开的不是登录页」。
 * 这几条是实测过的真实登录页；命中不到就退回源里写的地址 / 站址，让用户自己在页面上找登录入口。
 */
const LOGIN_PAGES: Record<string, string> = {
  'ximalaya.com': 'https://passport.ximalaya.com/page/web/login',
  'bilibili.com': 'https://passport.bilibili.com/login',
};

/** URL 的 host（小写，不含端口后的路径） */
function hostOfUrl(url: string): string {
  const m: RegExpMatchArray | null = url.match(/^https?:\/\/([^/?#]+)/i);
  return m !== null ? m[1].toLowerCase() : '';
}

/** 命不命中内置的登录页表（含子域） */
function mappedLoginPage(url: string): string {
  const host: string = hostOfUrl(url);
  if (host.length === 0) {
    return '';
  }
  for (const key of Object.keys(LOGIN_PAGES)) {
    if (host === key || host.endsWith('.' + key)) {
      return LOGIN_PAGES[key];
    }
  }
  return '';
}

/** 地址本身像不像登录页 */
function looksLikeLoginPage(url: string): boolean {
  return /(^|[/.?#])(login|signin|sign_in|passport|auth)([/.?#]|$)/i.test(url);
}

export class BookEngine {
  private static instance: BookEngine | null = null;

  static getInstance(): BookEngine {
    if (BookEngine.instance === null) {
      BookEngine.instance = new BookEngine();
    }
    return BookEngine.instance;
  }

  private store: BookSourceStore = new BookSourceStore();
  private jar: BookCookieJar = new BookCookieJar();
  private controller: webview.WebviewController | null = null;
  private pageReady: boolean = false;
  private pendingReady: (() => void)[] = [];
  private active: ActiveRequest | null = null;
  private logListener: ((line: string) => void) | null = null;
  /** 沙箱引擎代码（与音源共用 lx_utils.js 的 md5/base64 工具） */
  private utilsJs: string = '';
  private preloadJs: string = '';
  private prepared: boolean = false;
  private injected: boolean = false;
  private sandboxAssetsMissing: boolean = false;

  // ------------------------------------------------------------ 生命周期

  /** 读 rawfile 里的沙箱引擎（只需要一次） */
  prepare(context: common.Context): void {
    if (this.prepared) {
      return;
    }
    this.store.init(context);
    this.prepared = true;
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const rm = context.resourceManager;
      this.utilsJs = decoder.decodeToString(rm.getRawFileContentSync('lx_utils.js'));
      this.preloadJs = decoder.decodeToString(rm.getRawFileContentSync('book_preload.js'));
      this.sandboxAssetsMissing = this.utilsJs.length === 0 || this.preloadJs.length === 0;
    } catch (e) {
      this.sandboxAssetsMissing = true;
      hilog.error(DOMAIN, TAG, 'failed to read sandbox assets: %{public}s', JSON.stringify(e));
    }
    if (this.sandboxAssetsMissing) {
      this.log(BOOK_SANDBOX_UNAVAILABLE);
    }
  }

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
    this.pageReady = false;
    this.injected = false;
  }

  onPageEnd(): void {
    this.pageReady = true;
    const waiters: (() => void)[] = this.pendingReady;
    this.pendingReady = [];
    for (const waiter of waiters) {
      waiter();
    }
  }

  isAttached(): boolean {
    return this.controller !== null && this.pageReady;
  }

  setLogListener(listener: ((line: string) => void) | null): void {
    this.logListener = listener;
  }

  private log(line: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    const listener = this.logListener;
    if (listener !== null) {
      listener(line);
    }
  }

  private waitForPage(timeoutMs: number): Promise<void> {
    if (this.pageReady) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      const waiter = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.pendingReady = this.pendingReady.filter((item: () => void) => item !== waiter);
        reject(new Error('听书沙箱页面加载超时'));
      }, timeoutMs);
      this.pendingReady.push(waiter);
    });
  }

  // ------------------------------------------------------------ 书源管理

  /**
   * 导入书源（支持「单个对象」与「对象数组」两种写法）
   *
   * 阅读导出的书源文件两种都有：单源文件是 `[ {...} ]`，合集是多个对象。
   * 返回这次导入的结果描述，界面直接拿去提示。
   */
  importSources(text: string): BookSourceInfo[] {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      throw new Error('书源内容为空');
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(trimmed) as Object;
    } catch (e) {
      throw new Error('不是合法的 JSON，阅读书源应该是 JSON 文件');
    }
    // 兼容「一个对象」与「对象数组」
    let list: BookSource[] = [];
    if (Array.isArray(parsed)) {
      list = parsed as BookSource[];
    } else {
      list = [parsed as BookSource];
    }
    const imported: BookSourceInfo[] = [];
    for (const source of list) {
      const info: BookSourceInfo | null = this.importOne(source);
      if (info !== null) {
        imported.push(info);
      }
    }
    if (imported.length === 0) {
      throw new Error('书源里没有可用的条目（缺 bookSourceName / bookSourceUrl？）');
    }
    return imported;
  }

  private importOne(source: BookSource): BookSourceInfo | null {
    const name: string = sourceText(source, 'bookSourceName');
    const url: string = sourceText(source, 'bookSourceUrl');
    if (name.length === 0 && url.length === 0) {
      return null;
    }
    const searchUrl: string = sourceText(source, 'searchUrl');
    const exploreUrl: string = sourceText(source, 'exploreUrl');
    const loginUrl: string = source.loginUrl !== undefined && source.loginUrl !== null ? source.loginUrl : '';
    const candidate: BookSourceInfo = {
      id: '',
      name: name.length > 0 ? name : url,
      group: sourceText(source, 'bookSourceGroup'),
      url: url,
      comment: sourceText(source, 'bookSourceComment'),
      type: source.bookSourceType !== undefined ? source.bookSourceType : 1,
      canSearch: searchUrl.length > 0,
      canExplore: exploreUrl.length > 0,
      needLogin: loginUrl.length > 0,
      importedAt: Date.now(),
    };
    // 同「名字 + 站址」视为同一个源：已存在就原地覆盖，避免导入两次出现两条
    for (const existing of this.store.list()) {
      if (existing.name === candidate.name && existing.url === candidate.url) {
        return this.store.replace(existing.id, candidate, JSON.stringify(source));
      }
    }
    candidate.id = `book_${Date.now().toString(36)}_${Math.floor(Math.random() * 100000).toString(36)}`;
    return this.store.add(candidate, JSON.stringify(source));
  }

  listSources(): BookSourceInfo[] {
    return this.store.list();
  }

  getSource(id: string): BookSourceInfo | null {
    return this.store.find(id);
  }

  removeSource(id: string): BookSourceInfo[] {
    return this.store.remove(id);
  }

  isReady(): boolean {
    return this.store.isReady();
  }

  private rawOf(sourceId: string): string {
    return this.store.getRaw(sourceId);
  }

  /** 书源的发现分类（exploreUrl 有两种写法：JSON 数组与「标题::地址」逐行） */
  exploreCategories(sourceId: string): BookExploreCategory[] {
    const raw: string = this.rawOf(sourceId);
    const source: BookSource = JSON.parse(raw) as BookSource;
    const text: string = sourceText(source, 'exploreUrl');
    const out: BookExploreCategory[] = [];
    if (text.trim().length === 0) {
      return out;
    }
    if (text.trim().startsWith('[')) {
      try {
        const arr = JSON.parse(text) as BookExploreCategory[];
        for (const item of arr) {
          const title: string = item.title !== undefined ? String(item.title) : '';
          const url: string = item.url !== undefined ? String(item.url) : '';
          if (title.length > 0) {
            out.push({ title: title, url: url });
          }
        }
        return out;
      } catch (e) {
        // 掉回逐行格式
      }
    }
    for (const line of text.split('\n')) {
      const trimmed: string = line.trim();
      const idx: number = trimmed.indexOf('::');
      if (idx < 0) {
        continue;
      }
      out.push({
        title: trimmed.substring(0, idx).trim(),
        url: trimmed.substring(idx + 2).trim(),
      });
    }
    return out;
  }

  // ------------------------------------------------------------ 动作

  async search(sourceId: string, key: string, page: number): Promise<BookHit[]> {
    const info: BookSourceInfo | null = this.store.find(sourceId);
    if (info === null) {
      throw new Error('书源不存在');
    }
    const data: Object = await this.run(sourceId, 'search', {
      'key': key,
      'page': page,
    });
    return this.toHits(info, data);
  }

  /** 发现（分类）列表：与搜索同一套解析，只是地址换成分类地址 */
  async explore(sourceId: string, categoryUrl: string, page: number): Promise<BookHit[]> {
    const info: BookSourceInfo | null = this.store.find(sourceId);
    if (info === null) {
      throw new Error('书源不存在');
    }
    const data: Object = await this.run(sourceId, 'explore', {
      'exploreUrl': categoryUrl,
      'key': '',
      'page': page,
    });
    return this.toHits(info, data);
  }

  /** 书籍详情：拿到作者 / 简介 / 封面，以及**目录地址** */
  async bookInfo(sourceId: string, hit: BookHit): Promise<BookDetail> {
    const data: Object = await this.run(sourceId, 'bookInfo', {
      'book': this.bookParam(hit),
    });
    const detail: BookDetail = {
      name: '',
      author: '',
      coverUrl: '',
      intro: '',
      kind: '',
      status: '',
      wordCount: '',
      tocUrl: '',
    };
    const record: Record<string, Object> = JSON.parse(JSON.stringify(data)) as Record<string, Object>;
    detail.name = this.textOf(record, 'name');
    detail.author = this.textOf(record, 'author');
    detail.coverUrl = this.textOf(record, 'coverUrl');
    detail.intro = this.textOf(record, 'intro');
    detail.kind = this.textOf(record, 'kind');
    detail.status = this.textOf(record, 'status');
    detail.wordCount = this.textOf(record, 'wordCount');
    detail.tocUrl = this.textOf(record, 'tocUrl');
    return detail;
  }

  /** 目录：一本书的全部章节 */
  async toc(sourceId: string, hit: BookHit, tocUrl: string): Promise<BookChapter[]> {
    const url: string = tocUrl.length > 0 ? tocUrl : hit.bookUrl;
    const data: Object = await this.run(sourceId, 'toc', {
      'book': this.bookParam(hit, url),
      'url': url,
    });
    const out: BookChapter[] = [];
    if (!Array.isArray(data)) {
      return out;
    }
    const list = data as Record<string, Object>[];
    for (let i = 0; i < list.length; i++) {
      const item: Record<string, Object> = JSON.parse(JSON.stringify(list[i])) as Record<string, Object>;
      out.push({
        index: i,
        name: this.textOf(item, 'name'),
        url: this.textOf(item, 'url'),
        duration: this.textOf(item, 'duration'),
      });
    }
    return out;
  }

  /** 解析出这一章的音频直链 */
  async resolveAudio(sourceId: string, hit: BookHit, chapter: BookChapter): Promise<BookAudio> {
    return this.resolveAudioOf(sourceId, hit.bookUrl, hit.name, chapter.url, chapter.name, chapter.index);
  }

  /**
   * 解析音频直链（轻量入参版）
   *
   * 播放链路（PlaySession）手里只有队列条目里的载荷，凑不出完整的 BookHit，
   * 所以这里按「书源 + 书地址 + 章节地址」这几个真正会用到的字段来收参数。
   */
  async resolveAudioOf(
    sourceId: string,
    bookUrl: string,
    bookName: string,
    chapterUrl: string,
    chapterName: string,
    chapterIndex: number
  ): Promise<BookAudio> {
    const bookParam: Record<string, Object> = { 'bookUrl': bookUrl, 'name': bookName };
    const chapterParam: Record<string, Object> = {
      'url': chapterUrl,
      'name': chapterName,
      'index': chapterIndex,
    };
    const data: Object = await this.run(sourceId, 'content', {
      'book': bookParam,
      'chapter': chapterParam,
    });
    const record: Record<string, Object> = JSON.parse(JSON.stringify(data)) as Record<string, Object>;
    return { url: this.textOf(record, 'url'), from: this.textOf(record, 'from') };
  }

  /**
   * 书源声明的请求头（给播放器用）
   *
   * 有声书的音频 CDN 常常校验 Referer（悦听、六月这类站都如此），所以播直链时
   * 要把书源的头部带上；沙箱那边请求时也用的是同一份。
   */
  audioHeaders(sourceId: string): Record<string, string> {
    const out: Record<string, string> = {};
    let raw: string = '';
    try {
      raw = this.rawOf(sourceId);
    } catch (e) {
      return out;
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const header: Object | undefined = parsed['header'];
      if (header === undefined || header === null) {
        return out;
      }
      let obj: Record<string, Object> | null = null;
      if (typeof header === 'string') {
        const text: string = (header as string).trim();
        if (text.length === 0 || text === '[object Object]') {
          return out;
        }
        try {
          obj = JSON.parse(text) as Record<string, Object>;
        } catch (e) {
          return out;
        }
      } else {
        obj = JSON.parse(JSON.stringify(header)) as Record<string, Object>;
      }
      if (obj === null) {
        return out;
      }
      for (const key of Object.keys(obj)) {
        const value: Object = obj[key];
        if (value === null || value === undefined) {
          continue;
        }
        out[key] = typeof value === 'string' ? value as string : JSON.stringify(value);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to parse source header: %{public}s', JSON.stringify(e));
    }
    return out;
  }

  // ------------------------------------------------------------ 登录

  /** 是否已经填过登录信息（界面据此显示「已登录 / 需登录」） */
  hasLoginInfo(sourceId: string): boolean {
    return this.store.hasLoginInfo(sourceId);
  }

  getLoginInfo(sourceId: string): Record<string, string> {
    return this.store.getLoginInfo(sourceId);
  }

  saveLoginInfo(sourceId: string, info: Record<string, string>): void {
    this.store.saveLoginInfo(sourceId, info);
  }

  clearLoginInfo(sourceId: string): void {
    this.store.clearLoginInfo(sourceId);
  }

  /**
   * 网页登录要打开的地址
   *
   * 顺序：内置的「站点 → 真实登录页」表 → 源里写的地址本身就像登录页 → 源里写的地址 →
   * 站址。书源的 `loginUrl` 常常只是站址或一个空的服务页（见 `LOGIN_PAGES` 的注释），
   * 直接信它就会出现「打开的不是登录页」。
   */
  loginPageUrl(sourceId: string): string {
    let raw: string = '';
    try {
      raw = this.rawOf(sourceId);
    } catch (e) {
      return '';
    }
    let loginUrl: string = '';
    let siteUrl: string = '';
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      loginUrl = this.textOf(parsed, 'loginUrl');
      siteUrl = this.textOf(parsed, 'bookSourceUrl');
    } catch (e) {
      return '';
    }
    const mapped: string = mappedLoginPage(loginUrl).length > 0
      ? mappedLoginPage(loginUrl) : mappedLoginPage(siteUrl);
    if (mapped.length > 0) {
      return mapped;
    }
    if (looksLikeLoginPage(loginUrl)) {
      return loginUrl;
    }
    if (/^https?:/i.test(loginUrl)) {
      return loginUrl;
    }
    return siteUrl;
  }

  /**
   * 保存「网页登录」抓到的 Cookie
   *
   * 用应用内的真实网页登录后，从 WebView 的 Cookie 罐里把该站的 Cookie 整串取回来，
   * 这里落盘。写进登录信息表的作用有三层，缺一层就有源用不了：
   *   1. 固定键 `Cookie` / `cookie`：宿主发请求时直接当 Cookie 头带上（普通请求就带登录态）；
   *   2. 书源 `loginUi` 里凡是名字/标题含「cookie」的字段：像喜马拉雅那样在规则里
   *      读 `infoMap['喜马拉雅Cookie']` 自己拼签名请求的源，得能在那个键下拿到；
   *   3. 规则里 `source.getLoginInfoMap()` 拿到的就是这张表，所以上面两条一次都覆盖到。
   */
  saveWebLogin(sourceId: string, cookie: string): void {
    const trimmed: string = cookie.trim();
    if (trimmed.length === 0) {
      return;
    }
    const info: Record<string, string> = this.store.getLoginInfo(sourceId);
    info['Cookie'] = trimmed;
    info['cookie'] = trimmed;
    for (const item of this.getLoginUi(sourceId)) {
      if (item.type === 'button' || item.isHint) {
        continue;
      }
      const key: string = item.name.toLowerCase();
      const title: string = item.title.toLowerCase();
      if (key.includes('cookie') || title.includes('cookie')) {
        info[item.name] = trimmed;
      }
    }
    this.store.saveLoginInfo(sourceId, info);
  }

  /** 宿主发请求时要带的登录 Cookie（网页登录抓来的那一串） */
  private loginCookieOf(sourceId: string): string {
    const info: Record<string, string> = this.store.getLoginInfo(sourceId);
    const c: string | undefined = info['Cookie'];
    if (c !== undefined && c !== null && c.length > 0) {
      return c;
    }
    const lower: string | undefined = info['cookie'];
    return lower !== undefined && lower !== null ? lower : '';
  }

  /**
   * 书源的登录界面（`loginUi`）规整成能直接渲染的项
   *
   * 阅读里 `loginUi` 是一段 JSON，有的源写成字符串、有的直接是数组，两种都吃。
   * 字段语义见 `BookLoginUiItem`。没有 `loginUi` 的源（如哔哩哔哩）返回空数组 ——
   * 那种源靠站内 Cookie，界面上不给填表单。
   */
  getLoginUi(sourceId: string): BookLoginUiItem[] {
    const out: BookLoginUiItem[] = [];
    let raw: string = '';
    try {
      raw = this.rawOf(sourceId);
    } catch (e) {
      return out;
    }
    let items: Object | undefined = undefined;
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      items = parsed['loginUi'];
    } catch (e) {
      return out;
    }
    if (items === undefined || items === null) {
      return out;
    }
    let list: Object[] = [];
    if (typeof items === 'string') {
      const text: string = (items as string).trim();
      if (text.length === 0) {
        return out;
      }
      try {
        const arr: Object = JSON.parse(text) as Object;
        list = Array.isArray(arr) ? arr as Object[] : [];
      } catch (e) {
        return out;
      }
    } else if (Array.isArray(items)) {
      list = items as Object[];
    } else {
      return out;
    }
    for (const entry of list) {
      if (entry === null || entry === undefined || typeof entry !== 'object') {
        continue;
      }
      const item: Record<string, Object> = entry as Record<string, Object>;
      const title: string = this.textOf(item, 'title');
      const name: string = this.textOf(item, 'name');
      const type: string = this.textOf(item, 'type');
      const action: string = this.textOf(item, 'action');
      const value: string = this.textOf(item, 'value');
      const placeholder: string = this.textOf(item, 'placeholder');
      // 没有 name、只有一段长文本的 text 项是「使用说明」，渲染成一段灰字而不是输入框
      const isHint: boolean = type !== 'button' && name.length === 0 && action.length === 0 && value.length >= 24;
      out.push({
        name: name.length > 0 ? name : title,
        title: title,
        type: type.length > 0 ? type : 'text',
        value: value,
        action: action,
        placeholder: placeholder,
        isHint: isHint,
      });
    }
    return out;
  }

  /** `loginCheckJs`（可能没有） */
  private loginCheckRule(sourceId: string): string {
    let raw: string = '';
    try {
      raw = this.rawOf(sourceId);
    } catch (e) {
      return '';
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const rule: Object | undefined = parsed['loginCheckJs'];
      if (rule === undefined || rule === null) {
        return '';
      }
      return typeof rule === 'string' ? rule as string : String(rule);
    } catch (e) {
      return '';
    }
  }

  /**
   * 跑一次登录动作（登录弹窗里的按钮，或 `loginCheckJs`）
   *
   * 规则里可能 `java.connect` 发请求，所以走完整回放循环、是 async。
   * 结果里带回「保存后的登录信息表」，界面负责落盘（见 `saveLoginInfo`）。
   */
  async runLoginAction(sourceId: string, rule: string): Promise<BookLoginResult> {
    const data: Object = await this.run(sourceId, 'login', { 'rule': rule });
    return this.toLoginResult(data);
  }

  /** 检查登录状态：跑 `loginCheckJs`，返回它算出来的字符串（没有规则就空串） */
  async checkLogin(sourceId: string): Promise<string> {
    const rule: string = this.loginCheckRule(sourceId);
    if (rule.trim().length === 0) {
      return '';
    }
    const result: BookLoginResult = await this.runLoginAction(sourceId, rule);
    return result.result;
  }

  private toLoginResult(data: Object): BookLoginResult {
    const out: BookLoginResult = { result: '', login: {}, toasts: [], openUrl: '' };
    let record: Record<string, Object>;
    try {
      record = JSON.parse(JSON.stringify(data)) as Record<string, Object>;
    } catch (e) {
      return out;
    }
    if (record === null || record === undefined) {
      return out;
    }
    out.result = this.textOf(record, 'result');
    out.openUrl = this.textOf(record, 'openUrl');
    const login: Object | undefined = record['login'];
    if (login !== null && login !== undefined && typeof login === 'object') {
      const map: Record<string, Object> = login as Record<string, Object>;
      for (const key of Object.keys(map)) {
        out.login[key] = this.textOf(map, key);
      }
    }
    const toasts: Object | undefined = record['toasts'];
    if (Array.isArray(toasts)) {
      for (const line of toasts as Object[]) {
        out.toasts.push(line === null || line === undefined ? '' : String(line));
      }
    }
    return out;
  }

  // ------------------------------------------------------------ 回放循环（核心）

  private bookParam(hit: BookHit, tocUrl?: string): Record<string, Object> {
    const book: Record<string, Object> = {};
    book['bookUrl'] = hit.bookUrl;
    book['name'] = hit.name;
    book['author'] = hit.author;
    book['origin'] = hit.sourceId;
    book['originName'] = hit.sourceName;
    if (tocUrl !== undefined && tocUrl.length > 0) {
      book['tocUrl'] = tocUrl;
    }
    return book;
  }

  private textOf(record: Record<string, Object>, key: string): string {
    const value: Object | undefined = record[key];
    if (value === undefined || value === null) {
      return '';
    }
    return typeof value === 'string' ? value as string : String(value);
  }

  private toHits(info: BookSourceInfo, data: Object): BookHit[] {
    const out: BookHit[] = [];
    if (!Array.isArray(data)) {
      return out;
    }
    const list = data as Record<string, Object>[];
    for (const raw of list) {
      const item: Record<string, Object> = JSON.parse(JSON.stringify(raw)) as Record<string, Object>;
      const name: string = this.textOf(item, 'name');
      const bookUrl: string = this.textOf(item, 'bookUrl');
      if (bookUrl.length === 0) {
        continue;
      }
      out.push({
        id: `${info.id}:${bookUrl}`,
        sourceId: info.id,
        sourceName: info.name,
        name: name.length > 0 ? name : '(未命名)',
        author: this.textOf(item, 'author'),
        coverUrl: this.textOf(item, 'coverUrl'),
        intro: this.textOf(item, 'intro'),
        kind: this.textOf(item, 'kind'),
        wordCount: this.textOf(item, 'wordCount'),
        status: this.textOf(item, 'status'),
        lastChapter: this.textOf(item, 'lastChapter'),
        bookUrl: bookUrl,
      });
    }
    return out;
  }

  /**
   * 跑一次书源动作
   *
   * 与沙箱的契约见 book_preload.js 文件头：沙箱把规则**同步**跑完，
   * 遇到没抓到的地址就回一个 `status:'net'` + 缺失清单；宿主抓回来塞进缓存再让它重跑。
   * 缓存只增不减，所以必然收敛。
   */
  private async run(
    sourceId: string,
    action: string,
    params: Record<string, Object>
  ): Promise<Object> {
    const raw: string = this.rawOf(sourceId);
    // 登录信息随每一个作业下发（沙箱里 `source.getLoginInfoMap()` 取的就是它）：
    // 喜马拉雅的音频、需要 Cookie 的站点都靠这个才解析得出来。
    const login: Record<string, string> = this.store.getLoginInfo(sourceId);
    // 网页登录抓来的 Cookie 也要加到宿主请求上（书源自己只发得动规则里的请求）
    const loginCookie: string = this.loginCookieOf(sourceId);
    const started: number = Date.now();
    let rounds: number = 0;
    let requests: number = 0;
    const netCache: Record<string, string> = {};
    // 响应头与正文一起缓存：`java.post(...).headers()` 要读 Location 之类的头
    const netHeaders: Record<string, string> = {};
    const token: ActiveRequest = { cancelled: false };
    this.active = token;

    try {
      while (rounds < MAX_ROUNDS) {
        if (Date.now() - started > ACTION_TIMEOUT) {
          throw new Error('解析超时：这本书的规则请求太多或站点响应太慢');
        }
        rounds++;
        const job: string = this.buildJob(action, raw, params, netCache, netHeaders, login);
        const result: BookRunResult = await this.runInSandbox(job, token);
        for (const line of (result.logs !== undefined ? result.logs : [])) {
          this.log(`[${sourceId}] ${line}`);
        }
        const status: string = result.status;
        if (status === 'net') {
          const urls: BookNetRequest[] = result.urls !== undefined ? result.urls : [];
          if (urls.length === 0) {
            throw new Error('沙箱报告缺网络数据但没有给出地址');
          }
          requests += urls.length;
          await this.fetchAll(urls, netCache, netHeaders, loginCookie);
          continue;
        }
        if (status === 'error') {
          throw new Error(result.message !== undefined ? result.message : '书源规则执行失败');
        }
        const stats: BookRunStats = { rounds: rounds, requests: requests, elapsedMs: Date.now() - started };
        this.log(
          `${action} 完成：${rounds} 轮 / ${requests} 次请求 / ${stats.elapsedMs}ms`
        );
        return result.data !== undefined ? result.data : '';
      }
      throw new Error(`解析轮数超过上限（${MAX_ROUNDS}），可能是规则在自我循环`);
    } finally {
      if (this.active === token) {
        this.active = null;
      }
    }
  }

  /** 拼一个动作的作业 JSON（源正文原样透传，宿主不改写书源） */
  private buildJob(
    action: string,
    sourceRaw: string,
    params: Record<string, Object>,
    netCache: Record<string, string>,
    netHeaders: Record<string, string>,
    login: Record<string, string>
  ): string {
    const parts: string[] = [
      `"action":${JSON.stringify(action)}`,
      `"source":${sourceRaw}`,
      `"login":${JSON.stringify(login)}`,
      `"netCache":${JSON.stringify(netCache)}`,
      `"netHeaders":${JSON.stringify(netHeaders)}`,
    ];
    parts.push(`"bookSourceName":""`);
    for (const key of Object.keys(params)) {
      parts.push(`${JSON.stringify(key)}:${JSON.stringify(params[key])}`);
    }
    return `{${parts.join(',')}}`;
  }

  private async runInSandbox(job: string, token: ActiveRequest): Promise<BookRunResult> {
    const controller = this.controller;
    if (controller === null) {
      throw new Error(BOOK_SANDBOX_UNAVAILABLE);
    }
    await this.waitForPage(PAGE_READY_TIMEOUT);
    await this.ensureInjected();
    if (token.cancelled) {
      throw new Error('已取消');
    }
    const script: string = `window.__book_run__(${JSON.stringify(job)})`;
    let raw: string;
    try {
      raw = await controller.runJavaScript(script);
    } catch (e) {
      throw new Error(`书源沙箱执行失败：${(e as Error).message}`);
    }
    // ArkWeb 的坑之一：脚本执行失败时返回 null 而不是 reject；
    // 之二是它把返回值**又做了一次 JSON 序列化** —— 规则引擎返回的是字符串，
    // 于是宿主拿到的是 `"{\"status\":\"ok\"...}"`（带引号）。不还原的话
    // `JSON.parse` 出来是字符串，`result.status` 永远是 undefined，表现就是「搜到 0 条」。
    const text: string = unwrapJsonString(raw !== null && raw !== undefined ? raw : '');
    if (text.length === 0) {
      throw new Error(
        '书源沙箱没有返回结果（脚本可能执行失败，或 book_preload.js 没读到）。' +
          '预览器里沙箱不可用，请在模拟器/真机上跑。'
      );
    }
    try {
      return JSON.parse(text) as BookRunResult;
    } catch (e) {
      throw new Error(`书源沙箱返回了无法解析的内容：${text.substring(0, 120)}`);
    }
  }

  /**
   * 注入沙箱引擎（一次）
   *
   * 顺序不能反：book_preload.js 依赖 lx_utils.js 提供的 md5 / base64。
   * 注入完用 `__book_ping__` 自检；字符串注入失败时改用 runJavaScriptExt
   * （传字节）再来一次 —— 大脚本用字符串注入容易被 ArkWeb 静默吞掉。
   */
  private async ensureInjected(): Promise<void> {
    if (this.injected) {
      return;
    }
    const controller = this.controller;
    if (controller === null) {
      throw new Error(BOOK_SANDBOX_UNAVAILABLE);
    }
    if (this.sandboxAssetsMissing) {
      throw new Error(BOOK_SANDBOX_UNAVAILABLE);
    }
    await controller.runJavaScript(this.utilsJs);
    await controller.runJavaScript(this.preloadJs);
    let ok: boolean = await this.ping();
    if (!ok) {
      this.log('字符串注入未生效，改用 runJavaScriptExt（传字节）重试');
      const bytes: Uint8Array = new Uint8Array(utf8Bytes(this.utilsJs));
      await controller.runJavaScriptExt(bytes.buffer as ArrayBuffer);
      const bytes2: Uint8Array = new Uint8Array(utf8Bytes(this.preloadJs));
      await controller.runJavaScriptExt(bytes2.buffer as ArrayBuffer);
      ok = await this.ping();
      if (!ok) {
        throw new Error(
          '听书沙箱注入失败：book_preload.js 没有在页面里生效。请确认在模拟器/真机上运行（预览器的 Web 是残缺桩）。'
        );
      }
      this.log('沙箱在改用 runJavaScriptExt 后可用');
    }
    this.injected = true;
  }

  /** 沙箱自检：能拿到 DOMParser / eval 才算可用 */
  private async ping(): Promise<boolean> {
    const controller = this.controller;
    if (controller === null) {
      return false;
    }
    try {
      const raw: string = await controller.runJavaScript('typeof window.__book_ping__ === "function" ? window.__book_ping__() : ""');
      // 这里同样要吃 `unwrapJsonString`：设备上 runJavaScript 会把返回值序列化一次，
      // 不还原就 `JSON.parse` 成字符串，`parsed['ok']` 永远是 undefined ——
      // 引擎明明注入成功了，却报「注入失败」。
      const text: string = unwrapJsonString(raw !== null && raw !== undefined ? raw : '');
      if (text.length === 0) {
        return false;
      }
      const parsed: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      return parsed['ok'] === true;
    } catch (e) {
      return false;
    }
  }

  /** 一轮里把缺失的地址抓回来（限量并发） */
  private async fetchAll(
    urls: BookNetRequest[],
    netCache: Record<string, string>,
    netHeaders: Record<string, string>,
    loginCookie: string
  ): Promise<void> {
    for (let i = 0; i < urls.length; i += FETCH_CONCURRENCY) {
      const slice: BookNetRequest[] = urls.slice(i, i + FETCH_CONCURRENCY);
      const tasks: Promise<void>[] = [];
      for (const req of slice) {
        tasks.push(this.fetchOne(req, netCache, netHeaders, loginCookie));
      }
      await Promise.all(tasks);
    }
  }

  private async fetchOne(
    req: BookNetRequest,
    netCache: Record<string, string>,
    netHeaders: Record<string, string>,
    loginCookie: string
  ): Promise<void> {
    // 网页登录抓来的 Cookie 优先（它是真实会话）；没有就退回站点 Set-Cookie 攒的那个罐
    const jarCookie: string = this.jar.headerFor(req.url);
    const cookie: string = loginCookie.length > 0 ? loginCookie : jarCookie;
    try {
      const resp: BookResponse = await bookRequest(req, cookie);
      this.jar.absorb(req.url, resp.headers);
      netCache[req.key] = resp.body;
      // 头一起回灌（`java.post(...).headers()` 读 Location 用）
      netHeaders[req.key] = JSON.stringify(resp.headers);
      if (resp.statusCode >= 400) {
        this.log(`请求 ${req.url} 返回 HTTP ${resp.statusCode}`);
      }
    } catch (e) {
      // 单个地址失败按空响应处理：规则会算出空结果，界面上表现为「这章没解析出来」，
      // 但不该让整本书都打不开（一个封面 404 不该毁掉整个搜索）
      this.log(`请求失败 ${req.url}：${(e as Error).message}`);
      netCache[req.key] = '';
      netHeaders[req.key] = '{}';
    }
  }

  /** 导出书源文件用的原始 JSON（设置页里「导出」用） */
  exportRaw(sourceId: string): string {
    return this.rawOf(sourceId);
  }

  /**
   * 从文件导入（选择器给的沙箱 URI）
   *
   * 两个坑叠在一起，所以不能一句 `readTextSync(uri)` 了事：
   *   1. `readTextSync` 只认**沙箱路径**，把 Picker 给的 `file://docs/...` 传进去
   *      会报 "No such file or directory"（URI 只有 `openSync` 认）；
   *   2. 这个 SDK 的 `readTextSync` 声明只收 string，按 fd 读也不行。
   * 所以照本地音乐导入那套：先 `openSync(uri)` 拿 fd，读字节，再自己按 UTF-8 解。
   */
  importFromUri(uri: string): BookSourceInfo[] {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      if (size <= 0) {
        throw new Error('书源文件是空的');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fs.readSync(file.fd, buffer);
      const view: Uint8Array = new Uint8Array(buffer, 0, read);
      const bytes: number[] = [];
      for (let i = 0; i < read; i++) {
        bytes.push(view[i]);
      }
      return this.importSources(bytesToUtf8(bytes));
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'failed to close source file: %{public}s', JSON.stringify(e));
        }
      }
    }
  }
}
