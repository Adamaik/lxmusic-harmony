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
  @State progress: number = 0;
  @State currentUrl: string = '';

  aboutToAppear(): void {
    // 先把要打开的地址显示出来，页面加载完再由 onPageEnd 换成最终地址
    this.currentUrl = this.loginUrl;
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
