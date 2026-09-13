import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceEngine } from '../core/source/SourceEngine';

const DOMAIN: number = 0x0001;
const TAG: string = 'SandboxHost';

/**
 * 注入沙箱的桥对象。
 *
 * 对应洛雪原生侧的 UserApiModule.sendAction / JsHandler：
 * 沙箱里的 lx_preload.js 通过 lxBridge.postMessage(action, dataJson) 把
 * init / request / response / log / scriptError 回调给 ArkTS。
 *
 * 注意：必须用「对象字面量 + 自有属性」的形式。ArkWeb 的 javaScriptProxy 只暴露
 * 对象自身的属性；如果写成 class 的方法（在 prototype 上），window.lxBridge 里
 * 拿不到 postMessage，沙箱就会静默失败（表现为「初始化超时」）。
 */
interface LxBridgeObject {
  postMessage: (action: string, dataJson: string) => void;
}

/**
 * 音源沙箱宿主。
 *
 * 洛雪用原生 QuickJS 跑源脚本；HarmonyOS 侧没有可直接调用的通用 JS 引擎，
 * 这里用 ArkWeb 承载同一套 preload 引擎。Web 组件必须挂在 UI 树上，
 * 因此需要页面在任意位置放置一个 SourceSandboxHost（1x1、几乎透明）。
 */
@Component
export struct SourceSandboxHost {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: LxBridgeObject = {
    postMessage: (action: string, dataJson: string): void => {
      SourceEngine.getInstance().handleBridgeMessage(action, dataJson);
    },
  };

  aboutToAppear(): void {
    const engine = SourceEngine.getInstance();
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      engine.prepare(context);
      engine.attach(this.controller, this.bridge);
    } catch (e) {
      // 预览器 / 受限环境下 rawfile 与文件 API 是 mock 的，这里不让它把整个页面拖崩
      hilog.error(DOMAIN, TAG, 'sandbox host init failed: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      Web({ src: $rawfile('lx_host.html'), controller: this.controller })
        .javaScriptProxy({
          object: this.bridge,
          name: 'lxBridge',
          // 同一个方法同时登记在同步/异步列表时，ArkWeb 按异步方法处理。
          // 这里的回调都是单向通知（无返回值），异步方式更稳。
          methodList: ['postMessage'],
          asyncMethodList: ['postMessage'],
          controller: this.controller,
        })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(false)
        .imageAccess(false)
        .onlineImageAccess(false)
        .zoomAccess(false)
        .onPageEnd(() => {
          // 只通知引擎页面已就绪；桥接注册与自检由 SourceEngine.ensureBridge() 负责
          const engine = SourceEngine.getInstance();
          engine.onPageEnd();
          // 页面就绪后自动恢复上次加载的音源（内部只尝试一次），
          // 否则每次重启都要去音源设置里重新点一次
          void engine.restoreLastSource();
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
