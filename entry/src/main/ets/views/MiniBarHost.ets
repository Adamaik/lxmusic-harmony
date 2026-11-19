import { glassLight, harmony7ApiReady, immersiveMaterialForBar, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL, K_NAV_FOLLOW_HAND } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { K_BAR_MINI_WIDTH, barSideMarginFor } from '../ui/Layout';
import { K_SELECT_ACTIVE, SelectionActions } from '../ui/Selection';
import { MiniBarView } from './MiniBar';

/** 页内悬浮迷你播放条的离底距离：与壳层那条 HdsTabs 悬浮栏同一个口径 */
const PAGE_BAR_BOTTOM_GAP: number = 10;

/**
 * 「一列内容 + 一条页内迷你播放条」的通用外壳
 *
 * 背景：压在路由栈上的页面（NavDestination）会把壳层那条带迷你栏的 HdsTabs 整个盖住，
 * 所以每张这样的页面都得自己挂一条播放条。此前这套外壳在 PanePage / 歌单详情 / 在线详情
 * 各抄了一份，**歌手页漏了**（群反馈：「这个界面有点突兀，看能不能把底部音乐栏加上去」，
 * 2026-11-19 11:33）。这里把它抽成一个组件，新页面直接套，不再复制粘贴。
 *
 * 两种实现，按系统版本走：
 *   - 鸿蒙7（API 26）：**只有一个页签的 Tabs** + `barFloatingStyle`，拿到系统那条官方
 *     悬浮栏材质。沉浸光感有生效范围：普通组件只有落在 Navigation/NavDestination 标题栏
 *     或「横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar」里才渲染材质，
 *     画在内容区只会得到 `Material inactive: out of scope`。
 *   - 鸿蒙6：`FloatingTabBarStyle` 是 API 26 的类型，低版本连方法都不存在（调了就闪退），
 *     退回自绘胶囊：几何与鸿蒙7 那条对齐，表面是自绘玻璃 + HDS 轮廓点光。
 *
 * 用法：
 *   MiniBarHost({ windowWidth: this.windowWidth, bottomInset: this.bottomInset }) {
 *     Column() { ...页面内容... }
 *   }
 */
@Component
export struct MiniBarHost {
  /** 窗口宽度（vp）：算悬浮栏左右边距与铺满宽度；传 0 时用 AppStorage 里的全局值兜底 */
  @Prop windowWidth: number = 0;
  /** 手势条避让高度（vp）。不含壳层页签栏：这一页底下是页内这条迷你条 */
  @Prop bottomInset: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @BuilderParam content: () => void;
  /** 玻璃厚度档位（外观设置） */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /** 迷你条最大宽度：壳层按窗口宽度算好（0 = 窄屏不限） */
  @StorageLink(K_BAR_MINI_WIDTH) wideMiniBarWidth: number = 0;
  /** 悬浮栏左右跟手（设置 - 外观）：与壳层那条同一个开关 */
  @StorageLink(K_NAV_FOLLOW_HAND) followHand: boolean = true;
  /** 面板是不是正在多选（是的话这条栏让给批量操作条） */
  @StorageLink(K_SELECT_ACTIVE) selectBarActive: boolean = false;

  /** 实际使用的窗口宽度：调用方没传就用壳层写进 AppStorage 的那份 */
  private effectiveWidth(): number {
    return this.windowWidth > 0 ? this.windowWidth : this.wideMiniBarWidth > 0 ? this.windowWidth : this.windowWidth;
  }

  @Builder
  miniBarTabBar() {
    Row() {
      if (this.selectBarActive) {
        SelectionActions()
      } else {
        MiniBarView({
          forceExpanded: true,
          windowWidth: this.windowWidth,
          onOpenPlayer: this.onOpenPlayer,
          onOpenQueue: this.onOpenQueue,
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 悬浮栏样式：材质 + 几何（与壳层那条 HdsTabs 悬浮栏同口径） */
  private floatBarStyle(): FloatingTabBarStyle {
    const side: number = barSideMarginFor(this.windowWidth);
    const style: FloatingTabBarStyle = {
      barSideMargin: side,
      barBottomMargin: this.bottomInset + PAGE_BAR_BOTTOM_GAP,
      systemMaterial: immersiveMaterialForBar(this.materialLevel),
      adaptToHandedness: this.followHand,
    };
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

  /** 迷你栏宽度：宽屏给壳层算好的最大宽度，窄屏铺满 */
  private fallbackBarWidth(): Length {
    return this.wideMiniBarWidth > 0 ? this.wideMiniBarWidth : '100%';
  }

  /** 鸿蒙6 的迷你栏兜底：自绘一条悬浮胶囊（见文件头说明） */
  @Builder
  fallbackMiniBar() {
    Column() {
      Row() {
        this.miniBarTabBar()
      }
      .width(this.fallbackBarWidth())
      .height(HDS_BAR_HEIGHT)
      .attributeModifier(thinGlass(HDS_BAR_HEIGHT / 2, false, '', this.materialLevel))
      .visualEffect(glassLight())
      .clip(true)
    }
    .width('100%')
    .padding({
      left: barSideMarginFor(this.windowWidth),
      right: barSideMarginFor(this.windowWidth),
      bottom: this.bottomInset + PAGE_BAR_BOTTOM_GAP,
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (harmony7ApiReady()) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            this.content()
          }
          .tabBar(this.miniBarTabBar())
        }
        .vertical(false)
        .barMode(BarMode.Fixed)
        .scrollable(false)
        // 悬浮栏压在内容之上：列表从栏下透过，材质才有东西可折射
        .barOverlap(true)
        .barHeight(HDS_BAR_HEIGHT)
        .barBackgroundColor(Color.Transparent)
        .barFloatingStyle(this.floatBarStyle())
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.content()
        }
        .width('100%')
        .height('100%')

        this.fallbackMiniBar()
      }
    }
    .width('100%')
    .height('100%')
  }
}
