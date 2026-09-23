import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookSandboxHost';

/**
 * 听书沙箱宿主
 *
 * 和音源的宿主是同一个思路（1x1 的透明 ArkWeb 承载 JS 引擎），但**刻意做成两个独立页面**：
 *   - 音源沙箱跑的是洛雪那套 preload（禁了 eval、只暴露 lx.*），状态由 SourceEngine 管；
 *   - 听书沙箱跑的是书源规则引擎（需要 eval 求值规则、需要 DOM 做 CSS 选择器）。
 * 两者要的全局环境正好相反，塞进同一个页面会互相破坏，所以各用各的
 * （多一个 1x1 的 Web 换来的隔离是值得的）。
 *
 * 这里不需要 javaScriptProxy：书源引擎与宿主的交互只有「调用 → 同步返回」和
 * 「缺网络 → 宿主抓完重跑」，都能用 runJavaScript 的返回值表达（见 book_preload.js）。
 */
@Component
export struct BookSandboxHost {
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const engine = BookEngine.getInstance();
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      engine.prepare(context);
      engine.attach(this.controller);
    } catch (e) {
      // 预览器 / 受限环境里 rawfile 与 Web 都是 mock 的，别让它把整个页面拖崩
      hilog.error(DOMAIN, TAG, 'book sandbox host init failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      Web({ src: $rawfile('lx_host.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(false)
        .imageAccess(false)
        .onlineImageAccess(false)
        .zoomAccess(false)
        .onPageEnd(() => {
          // 只通知引擎「页面就绪」，注入引擎与自检由 BookEngine.ensureInjected() 负责
          BookEngine.getInstance().onPageEnd();
        })
        .width('100%')
        .height('100%')
    }
    .width(1)
    .height(1)
    .opacity(0.01)
    .focusable(false)
  }
}
