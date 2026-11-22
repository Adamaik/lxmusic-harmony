import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { C_BG, C_CARD, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, F_ITEM, F_SUB } from '../ui/Theme';
import { I_CLOSE, I_REFRESH, IconGlyph } from '../ui/Icons';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookLoginWeb';

/**
 * 桌面（Windows Chrome）User-Agent
 *
 * 音乐站点的网页登录都必须用桌面 UA：QQ 音乐 / 网易云都会按 UA 把页面分成 PC 版和手机版，
 * 手机版（如 `i2.y.qq.com/n3/other/pages/myqq/index.html`）只有一个「下载APP」，**没有登录入口**，
 * 用鸿蒙 Web 组件的默认移动 UA 打开就表现为「点进去跳到手机版、找不到登录的地方」。
 *
 * 值与 core/music/MusicAccount.ets 里的 `TX_UA` / `WY_UA` 保持一致：那边是 HTTP 请求头用的，
 * 这里是 WebView 用的，两处必须是同一个身份，否则「网页拿到的登录态」和「接口认的客户端」会对不上。
 * 不从 MusicAccount 导出复用，是为了不让这个通用组件反向依赖音乐核心模块（它也给书源登录用）。
 */
export const DESKTOP_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/** 自动点「登录」的重试间隔（毫秒）：首屏 onPageEnd 时页面 JS 常常还没绑好点击事件，等一会儿再试 */
const AUTO_LOGIN_RETRY_MS: number = 800;
/** 最多重试几次：6 次 × 800ms ≈ 5 秒，够慢网跑完首页脚本，又不至于一直点下去 */
const AUTO_LOGIN_MAX_TRIES: number = 6;

/**
 * 自动点开「登录」入口的注入脚本
 *
 * QQ 音乐 PC 首页右上角那个「登录」是 `<a class="top_login__link">登录</a>`，**没有 href**，
 * 点击由页面 JS 接管、去开登录弹窗（走 `window.open` 或内嵌 iframe）。ArkWeb 默认把
 * `window.open` 拦掉，于是表现为「点了登录完全没反应」。
 *
 * 脚本思路（通用，不写死 QQ 音乐的选择器）：
 * 1. 先找 `a.top_login__link`（QQ 音乐），命中就点；
 * 2. 否则遍历 `a,button,div,span`，取第一个 `textContent.trim() === '登录'` 且**可见**的元素来点
 *    （网易云、以及站点改版后都能命中）；
 * 3. 返回一个字符串给 `runJavaScript` 的 Promise：`clicked:xxx` / `not_found` / `error:xxx`，
 *    调用方据此决定「成功就停」还是「过 800ms 再试」。
 *
 * 整段包在 IIFE 里，避免把函数名丢进页面全局作用域。
 */
const AUTO_LOGIN_SCRIPT: string = `(function () {
  try {
    function visible(el) {
      if (!el) { return false; }
      var rect = el.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) { return false; }
      var style = window.getComputedStyle(el);
      if (!style) { return true; }
      if (style.display === 'none' || style.visibility === 'hidden') { return false; }
      if (parseFloat(style.opacity || '1') < 0.1) { return false; }
      return true;
    }
    var fast = document.querySelector('a.top_login__link');
    if (fast && typeof fast.click === 'function' && visible(fast)) {
      fast.click();
      return 'clicked:top_login__link';
    }
    var all = document.querySelectorAll('a,button,div,span');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if ((el.textContent || '').trim() !== '登录') { continue; }
      if (!visible(el)) { continue; }
      if (typeof el.click !== 'function') { continue; }
      el.click();
      return 'clicked:' + el.tagName.toLowerCase();
    }
    return 'not_found';
  } catch (e) {
    return 'error:' + (e && e.message ? e.message : 'unknown');
  }
})()`;

/**
 * 书源「网页登录」用的应用内浏览器
 *
 * 需要登录的书源（喜马拉雅、哔哩哔哩这类）大多没法靠一个表单填明白：有的要扫码、
 * 有的要短信验证、有的要跳好几次域。所以这里直接**把站点自己的登录页装进 Web 里**，
 * 用户像在浏览器里一样登录，登录完成后点「完成」，应用从 WebView 的 Cookie 罐里
 * 把该站 Cookie 整串抓走交给引擎（见 BookEngine.saveWebLogin）。
 *
 * 抓 Cookie 用 `WebCookieManager.fetchCookieSync(url)`：它返回该 URL 适用的一整串
 * Cookie（含父域 `.xxx.com` 上的）。登录后常常会跳到主站，所以除了登录页，站址和
 * 当前页也各抓一次再合并去重，免得只拿到 half 的登录态。
 */
@Component
export struct BookLoginWeb {
  /** 顶部标题（书源名） */
  @Prop title: string = '登录';
  /** 书源声明的登录页地址 */
  loginUrl: string = '';
  /** 书源站址（登录后跳到主站时也能抓到 Cookie） */
  siteUrl: string = '';
  /**
   * 自定义 User-Agent（空串 = 用 Web 组件的系统默认 UA）
   *
   * 书源登录页大多是移动站（喜马拉雅、哔哩哔哩这类），保持默认 UA 才是它们想要的版式，
   * 所以这里不设全局默认值，由调用方按需传入：音乐登录页传 {@link DESKTOP_UA}。
   */
  userAgent: string = '';
  /**
   * 是否自动点开页面上的「登录」入口（默认 false）
   *
   * 只给音乐站点登录开：QQ 音乐 PC 首页的「登录」没有 href，点击靠页面 JS 走 `window.open`，
   * ArkWeb 默认拦掉，用户点了没反应。开启后页面加载完会注入脚本替用户点一下，
   * 并且打开 `multiWindowAccess` + `onWindowNew`，把弹窗地址装回当前 WebView。
   * 书源登录一律不传，保持「用户自己点」的原样行为。
   */
  autoLogin: boolean = false;
  /**
   * 状态栏高度（vp）
   *
   * 这一层是 `bindContentCover` 的整屏覆盖层，铺满整个窗口、**不经过标题栏**，
   * 所以顶栏得自己避开状态栏，否则「完成」会被压在状态栏底下点不到。
   */
  @Prop safeTop: number = 0;
  /** 底部手势条高度（vp），给最下面那行说明留白 */
  @Prop safeBottom: number = 0;
  /** 关闭：把抓到的 Cookie 串交回去（可能为空串） */
  onClose: (cookie: string) => void = () => {
  };

  private controller: webview.WebviewController = new webview.WebviewController();
  /**
   * 弹窗的「接住点」
   *
   * ArkWeb 的 `onWindowNew` 规定：不给 `setWebController` 一个 controller，渲染进程会一直等，
   * 主页面看着像卡住。我们的做法是把弹窗地址直接装回当前 WebView（Cookie 才落在同一个罐里），
   * 所以这里给一个**不挂到界面上**的 controller，让 ArkWeb 认为新窗口已经被处理过，
   * 真正要显示的 URL 由我们自己 loadUrl 到当前 WebView。
   */
  private popupSink: webview.WebviewController = new webview.WebviewController();
  /** 自动点登录的重试定时器（-1 = 没有在等） */
  private autoLoginTimer: number = -1;
  /** 每次 onPageEnd 自增的序号：翻页后把上一页还没跑完的重试作废，避免在新的页面上乱点 */
  private autoLoginSeq: number = 0;
  /** 当前这一轮已经试了几次 */
  private autoLoginTries: number = 0;
  /**
   * 整个 WebView 生命周期内是否已经点中过
   *
   * 点中之后就不再自动点：登录弹窗自己也有「登录」按钮（账号密码提交），
   * 在同一个 WebView 里继续注入会拿空账号去提交，比不点更糟。
   */
  private autoLoginDone: boolean = false;
  @State progress: number = 0;
  @State currentUrl: string = '';

  aboutToAppear(): void {
    // 先把要打开的地址显示出来，页面加载完再由 onPageEnd 换成最终地址
    this.currentUrl = this.loginUrl;
  }

  aboutToDisappear(): void {
    // 覆盖层关掉时把还没跑完的重试掐掉，别在已经销毁的 WebView 上注入脚本
    this.autoLoginSeq++;
    this.clearAutoLoginTimer();
  }

  /**
   * 把自定义 UA 装到 WebView 上
   *
   * 时机按官方 `setCustomUserAgent` 的说明来：`src` 已带 URL 时，**在 `onControllerAttached`
   * 回调里设置**（此时 controller 刚绑定；换成 onLoadIntercept 里设会概率性失败）。
   * 设置生效时组件会带着新 UA 重新请求一次首页 —— 这一下重载正是把「移动 UA 打开的手机版
   * 页面」换成「桌面 UA 打开的 PC 版页面」的关键，否则首屏已经被服务端 302 到手机站了。
   * `Web` 组件上的 `.userAgent()` 属性从 API 10 起已废弃，官方替代就是本方法。
   */
  private applyUserAgent(): void {
    if (this.userAgent.length === 0) {
      return;
    }
    try {
      this.controller.setCustomUserAgent(this.userAgent);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setCustomUserAgent failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 从 URL 里抠出主机名（小写）
   *
   * 不用 `new URL()`：ArkTS 里它的异常路径和 d.ts 版本差异不值得为这点事冒险，
   * 这里只需要「协议后面到第一个 / 或 : 之前」这一段。
   */
  private hostOf(url: string): string {
    if (url === undefined || url === null) {
      return '';
    }
    const scheme: number = url.indexOf('://');
    if (scheme < 0) {
      return '';
    }
    let rest: string = url.substring(scheme + 3);
    const slash: number = rest.indexOf('/');
    if (slash >= 0) {
      rest = rest.substring(0, slash);
    }
    const colon: number = rest.indexOf(':');
    if (colon >= 0) {
      rest = rest.substring(0, colon);
    }
    return rest.toLowerCase();
  }

  /**
   * 当前页是不是「要点开登录」的那个站点
   *
   * 只认 y.qq.com / music.163.com（含子域）。别的一律不注入，免得到登录后跳去的
   * 其它域上乱点；书源登录更不会走到这里（autoLogin 为 false）。
   */
  private isLoginSite(url: string): boolean {
    const host: string = this.hostOf(url);
    if (host.length === 0) {
      return false;
    }
    return host === 'y.qq.com' || host.endsWith('.y.qq.com')
      || host === 'music.163.com' || host.endsWith('.music.163.com');
  }

  /** 每次页面加载完成都开一轮新的自动点登录（旧的一轮用序号作废） */
  private startAutoLogin(): void {
    if (!this.autoLogin || this.autoLoginDone) {
      return;
    }
    this.autoLoginSeq++;
    this.autoLoginTries = 0;
    this.attemptAutoLogin(this.autoLoginSeq);
  }

  /**
   * 试一次：注入脚本 -> 看返回值决定停还是等一会儿再来
   *
   * `runJavaScript` 是异步的（Promise<string>），页面若返回空值就是 null/undefined，
   * 这里统一当「没点中」处理，继续重试。
   */
  private attemptAutoLogin(seq: number): void {
    if (seq !== this.autoLoginSeq || !this.autoLogin || this.autoLoginDone) {
      return;
    }
    let url: string = this.currentUrl;
    try {
      url = this.controller.getUrl();
      this.currentUrl = url;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'autoLogin getUrl failed, fallback to currentUrl');
    }
    if (!this.isLoginSite(url)) {
      hilog.info(DOMAIN, TAG, 'autoLogin skipped: host not a login site');
      return;
    }
    if (this.autoLoginTries >= AUTO_LOGIN_MAX_TRIES) {
      hilog.info(DOMAIN, TAG, 'autoLogin gave up after %{public}d tries', this.autoLoginTries);
      return;
    }
    this.autoLoginTries++;
    this.controller.runJavaScript(AUTO_LOGIN_SCRIPT)
      .then((result: string) => {
        const text: string = result === undefined || result === null ? '' : result;
        hilog.info(DOMAIN, TAG, 'autoLogin try %{public}d -> %{public}s', this.autoLoginTries, text);
        if (text.indexOf('clicked') === 0) {
          // 点中了就停：登录弹窗 / 新窗口由 onWindowNew 或页面自己的 iframe 接住
          this.autoLoginDone = true;
          this.clearAutoLoginTimer();
          return;
        }
        this.scheduleAutoLoginRetry(seq);
      })
      .catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'autoLogin runJavaScript failed: %{public}s', JSON.stringify(e));
        this.scheduleAutoLoginRetry(seq);
      });
  }

  /** 等 AUTO_LOGIN_RETRY_MS 再试一次（页面 JS 可能还没就绪） */
  private scheduleAutoLoginRetry(seq: number): void {
    if (seq !== this.autoLoginSeq || this.autoLoginTries >= AUTO_LOGIN_MAX_TRIES) {
      return;
    }
    this.clearAutoLoginTimer();
    this.autoLoginTimer = setTimeout(() => {
      this.autoLoginTimer = -1;
      this.attemptAutoLogin(seq);
    }, AUTO_LOGIN_RETRY_MS);
  }

  private clearAutoLoginTimer(): void {
    if (this.autoLoginTimer >= 0) {
      clearTimeout(this.autoLoginTimer);
      this.autoLoginTimer = -1;
    }
  }

  /**
   * 页面用 `window.open` 开登录弹窗时，把目标地址装回当前 WebView
   *
   * 不新开界面：登录要在同一个 WebView 里完成，Cookie 才会落在同一个罐里，
   * 点「完成」时 `harvest()` 才抓得到 `qm_keyst` / `MUSIC_U`。
   *
   * 两件事都要 try/catch：
   * - `setWebController` 是 ArkWeb 的硬性要求（不给的话渲染进程会一直等，页面像卡死）；
   * - `targetUrl` 可能是空串（页面先 open('about:blank') 再改 location），此时只记日志、不导航。
   */
  private handleWindowNew(event: OnWindowNewEvent): void {
    try {
      const target: string = event === undefined || event === null ? '' : event.targetUrl;
      hilog.info(DOMAIN, TAG, 'onWindowNew: %{public}s', target);
      try {
        event.handler.setWebController(this.popupSink);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setWebController failed: %{public}s', JSON.stringify(e));
      }
      if (target === undefined || target === null || target.length === 0) {
        hilog.warn(DOMAIN, TAG, 'onWindowNew with empty targetUrl, nothing to load');
        return;
      }
      if (!/^https?:/i.test(target)) {
        hilog.warn(DOMAIN, TAG, 'onWindowNew target is not http(s), ignored');
        return;
      }
      this.controller.loadUrl(target);
      this.currentUrl = target;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onWindowNew failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 把几个地址上的 Cookie 合并成一串（同名以先出现的为准）
   *
   * 直接把几串拼起来会有重复的键，服务端多数能容忍，但去重后更干净、也更好看。
   */
  private harvest(): string {
    const merged: Record<string, string> = {};
    const urls: string[] = [this.loginUrl, this.siteUrl, this.currentUrl];
    for (const url of urls) {
      if (url === undefined || url === null || !/^https?:/i.test(url)) {
        continue;
      }
      let raw: string = '';
      try {
        raw = webview.WebCookieManager.fetchCookieSync(url);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'fetchCookieSync failed for %{public}s', url);
        continue;
      }
      if (raw === undefined || raw === null || raw.length === 0) {
        continue;
      }
      for (const pair of raw.split(';')) {
        const text: string = pair.trim();
        const eq: number = text.indexOf('=');
        if (eq <= 0) {
          continue;
        }
        const name: string = text.substring(0, eq).trim();
        if (merged[name] === undefined) {
          merged[name] = text.substring(eq + 1);
        }
      }
    }
    const parts: string[] = [];
    for (const name of Object.keys(merged)) {
      parts.push(`${name}=${merged[name]}`);
    }
    return parts.join('; ');
  }

  private finish(): void {
    const cookie: string = this.harvest();
    try {
      // 落盘，换个页面/重启后 WebView 里也还在登录态
      webview.WebCookieManager.saveCookieSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveCookieSync failed');
    }
    this.onClose(cookie);
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        IconGlyph({ symbol: I_CLOSE, iconSize: 20, color: C_TEXT_SUB })
          .padding(6)
          .onClick(() => {
            this.onClose('');
          })
          .accessibilityText('取消登录')
          .accessibilityLevel('yes')
        Text(this.title.length > 0 ? `${this.title} · 登录` : '登录')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        IconGlyph({ symbol: I_REFRESH, iconSize: 19, color: C_TEXT_SUB })
          .padding(6)
          .onClick(() => {
            try {
              this.controller.refresh();
            } catch (e) {
              hilog.warn(DOMAIN, TAG, 'refresh failed');
            }
          })
          .accessibilityText('刷新')
          .accessibilityLevel('yes')
        Text('完成')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_RED)
          .padding({ left: 10, right: 6, top: 6, bottom: 6 })
          .onClick(() => {
            this.finish();
          })
          .accessibilityText('完成登录并抓取 Cookie')
          .accessibilityLevel('yes')
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: this.safeTop + 6, bottom: 6 })
      .backgroundColor(C_CARD)

      // 把当前地址显出来：书源里的 loginUrl 常常不是登录页，用户能据此判断打开了什么
      if (this.currentUrl.length > 0) {
        Text(this.currentUrl)
          .fontSize(11)
          .fontColor(C_TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 5 })
          .backgroundColor(C_CARD)
      }

      Divider().strokeWidth(0.6).color(C_DIVIDER)

      if (this.progress > 0 && this.progress < 100) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(C_RED)
      }

      Web({ src: this.loginUrl, controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .onlineImageAccess(true)
        .fileAccess(false)
        .zoomAccess(true)
        .mixedMode(MixedMode.All)
        // 多窗口权限：`onWindowNew` 的前置开关，默认 false 时 `window.open` 会被直接丢掉、
        // 回调根本不触发（这正是「点登录没反应」的另一半原因）。
        // 只在 autoLogin 时打开，书源登录保持默认，行为与改动前完全一致。
        .multiWindowAccess(this.autoLogin)
        .onWindowNew((event: OnWindowNewEvent) => {
          if (!this.autoLogin) {
            // 理论上 autoLogin=false 时 multiWindowAccess 也是 false、不会走到这里；多一道闸更稳
            return;
          }
          this.handleWindowNew(event);
        })
        .onControllerAttached(() => {
          this.applyUserAgent();
        })
        .onProgressChange((event: OnProgressChangeEvent) => {
          this.progress = event.newProgress;
        })
        .onPageEnd(() => {
          try {
            this.currentUrl = this.controller.getUrl();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'getUrl failed');
          }
          // 登录站点的首页加载完就把「登录」替用户点开（书源登录 autoLogin=false，直接返回）
          try {
            this.startAutoLogin();
          } catch (e) {
            hilog.warn(DOMAIN, TAG, 'startAutoLogin failed: %{public}s', JSON.stringify(e));
          }
        })
        .width('100%')
        .layoutWeight(1)

      Text('登录成功后点右上角「完成」，应用会抓取本站 Cookie 用于解析音频。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: this.safeBottom + 6 })
        .backgroundColor(C_CARD)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
