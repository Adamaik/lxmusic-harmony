import { immersiveMaterialForBar } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { K_BAR_MINI_WIDTH, barSideMarginFor } from '../ui/Layout';
import { K_SELECT_ACTIVE, SelectionActions } from '../ui/Selection';
import { C_BG } from '../ui/Theme';
import { MiniBarView } from './MiniBar';

/** 页内悬浮迷你播放条的离底距离：与壳层那条 HdsTabs 悬浮栏同一个口径 */
const PAGE_BAR_BOTTOM_GAP: number = 10;

/**
 * 子页面外壳：本地音乐 / 播放历史 / 下载管理 / 云端音乐
 *
 * 这四页都是「一列歌曲 + 一条迷你播放条」，结构与歌单详情、在线详情完全一样，
 * 所以外壳也照抄那两页：根容器是**只有一个页签的 Tabs**，为的是拿到那条官方认可的
 * 底部悬浮栏 —— 沉浸光感有生效范围（除弹窗类组件外，普通组件只有落在
 * Navigation/NavDestination 标题栏或「横向 Tabs 中 barPosition 为 BarPosition.End
 * 的底部 TabBar」里才渲染材质），画在内容区的普通组件不构成材质，运行时只得到一句
 * `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
 *
 * 这几页是压在路由栈上的 HdsNavDestination，把壳层那条带迷你栏的 HdsTabs 整个盖住了，
 * 所以迷你条得自己挂一条；胶囊的圆角、边距、底色、材质全由框架画，这里**只提供栏里的内容**，
 * 栏里不要再叠自绘玻璃（材质层级在 backgroundColor / backgroundBlurStyle 之下）。
 *
 * 内容（各面板）自己让出顶部标题栏那一段：它们是「静态头部 + 列表」的布局，
 * 头部是常驻控件（导入 / 刷新 / 选择），不该滚进标题栏底下，所以用一段固定占位，
 * 而不是首页那种 `contentStartOffset`。
 */
@Component
export struct PanePage {
  /** 窗口宽度（vp）：算悬浮栏的左右边距与铺满宽度，与壳层同一份量（0 = 还没量到） */
  @Prop windowWidth: number = 0;
  /** 手势条避让高度（vp）。**不含**页签栏：这一页底下是页内那条迷你条，不是壳层那条 */
  @Prop bottomInset: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @BuilderParam content: () => void;
  /** 玻璃厚度档位（外观设置）：页内那条迷你条的材质跟着它变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /** 迷你条的最大宽度：壳层按窗口宽度算好（0 = 窄屏不限，见 ui/Layout.ets） */
  @StorageLink(K_BAR_MINI_WIDTH) wideMiniBarWidth: number = 0;
  /** 里面的面板是不是正在多选（是的话这条悬浮栏换成批量操作条，见 miniBarTabBar） */
  @StorageLink(K_SELECT_ACTIVE) selectBarActive: boolean = false;

  /**
   * 悬浮栏里的内容
   *
   * 平时是迷你播放条；**页面进多选时这条让给批量操作**（{@link SelectionActions}）——
   * 栏本身一个字都不改（位置、圆角、边距、材质都是下面 floatBarStyle 那套），只换内容，
   * 所以底栏看上去与迷你条是同一条胶囊。多选状态在四个面板自己身上（勾选、入口都在
   * 那边），这里靠 ui/Selection.ets 的全局会话对话，见那边的说明。
   *
   * `forceExpanded: true` —— 这一页没有页签栏跟它抢宽度，迷你栏始终是展开态
   * （与歌单详情 / 在线详情一致）。
   */
  @Builder
  miniBarTabBar() {
    Row() {
      if (this.selectBarActive) {
        SelectionActions()
      } else {
        MiniBarView({
          forceExpanded: true,
          onOpenPlayer: this.onOpenPlayer,
          onOpenQueue: this.onOpenQueue,
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 悬浮栏的样式：材质 + 几何（与歌单详情、在线详情同一套，改一处要一起改）
   *
   * 与壳层那条 HdsTabs 悬浮栏同口径：左右边距取同一个函数、离底距离同样是「手势条 + 10」、
   * 栏高同样 HDS_BAR_HEIGHT。差别只有宽度 —— 这一页没有页签栏，整条都该给迷你条。
   *
   * `systemMaterial` 必须是 `uiMaterial.ImmersiveMaterial` 实例（不能塞 HDS 的
   * `SystemMaterialParams`：那是个普通对象，编译能过但运行时不构成材质）。设备没有
   * 材质能力位时给 `undefined`，悬浮胶囊仍由框架按默认样式画出来，不会变成一条透明带子。
   */
  private floatBarStyle(): FloatingTabBarStyle {
    const side: number = barSideMarginFor(this.windowWidth);
    const style: FloatingTabBarStyle = {
      barSideMargin: side,
      barBottomMargin: this.bottomInset + PAGE_BAR_BOTTOM_GAP,
      systemMaterial: immersiveMaterialForBar(this.materialLevel),
    };
    // 宽度必须显式给（否则框架按自己的默认宽度画，内容会被挤在一条窄胶囊里）：
    // 宽屏与壳层那条迷你栏同宽；窄屏铺满（窗口宽 － 左右边距），也就是「把外面那条延长」
    let barWidthVp: number = this.wideMiniBarWidth;
    if (barWidthVp <= 0 && this.windowWidth > 0) {
      barWidthVp = this.windowWidth - side * 2;
    }
    if (barWidthVp > 0) {
      const width: FloatingTabBarWidth = {
        smallBarWidth: barWidthVp,
        mediumBarWidth: barWidthVp,
        largeBarWidth: barWidthVp,
      };
      style.barWidth = width;
    }
    return style;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          this.content()
        }
        .tabBar(this.miniBarTabBar())
      }
      // 横向 + 底部页签：这两个同样是沉浸光感生效范围的条件（见上面的说明）
      .vertical(false)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      // 悬浮栏压在内容之上：列表从栏下透过，材质才有东西可折射、可模糊
      .barOverlap(true)
      .barHeight(HDS_BAR_HEIGHT)
      // 栏体那一条不要自己的底色（默认是一条灰白带）：观感全交给悬浮胶囊本身
      .barBackgroundColor(Color.Transparent)
      .barFloatingStyle(this.floatBarStyle())
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
