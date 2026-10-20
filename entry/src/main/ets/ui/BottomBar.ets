import { deviceInfo } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BP_MEDIUM, K_WINDOW_WIDTH } from './Layout';
import { K_MINI_EXPANDED } from '../core/player/PlaySession';

const DOMAIN: number = 0x0001;
const TAG: string = 'BottomBar';

/**
 * 底部那条「双层栏」（页签 + 迷你播放器）的排布与滚动联动
 *
 * 做法照抄派音（RzdMusic）最新代码里跑通的那一版（`common/musicbasic/.../util/BarScrollHelper.ets`
 * 与 `products/default/.../pages/Index.ets`），三条要点：
 *
 *   一、**两排才是默认**。HDS 的 `miniBar.barLayoutMode` 给 `VERTICAL` 时，迷你条与页签各自一排
 *      （页签整条都在）；给 `HORIZONTAL` 时是单排——迷你条被拉成整条通栏，页签让位收成左侧一颗圆钮。
 *      派音/musicfree 的默认观感是**上下两排**（页签永远够得着），我们照此把默认定为两排。
 *
 *   二、**别声明 barWidth / miniBarWidth**。派音原先也传了（和我们一样按档算宽度），结论是
 *      「会让整条底栏明显窄于屏幕，上下两排时两侧留出很大空隙」——那正是他们实机反馈的问题。
 *      去掉之后由 HDS 自己按排布算宽度：单排时迷你条铺满、两排时两条各占一排。**所以这里不碰宽度**。
 *
 *   三、**滚动联动**：列表上滑（内容偏移增加）→ 收成单排；列表下滑 → 回到两排，
 *      用 `animateTo` + 弹簧曲线让 HDS 自己带动效。方向、阈值、时长都照派音那版
 *      （他们的注释写明「已按真机反馈确认」，别再自己反推）。
 *
 * 门控：`barLayoutMode` 是 **6.1.1(24)** 起才有的能力，而且判据要读
 * `deviceInfo.distributionOSApiVersion`（发行版版本码 60101），**不是** `sdkApiVersion`
 * ——派音那边明确记着这一条，读错字段会误放行/误拦截。另外 `targetSdkVersion` 必须 ≥ 24，
 * 否则编译期就没有这个字段（本工程 targetSdkVersion 26，满足）。
 * 低版本机型上这个能力不存在：不声明 `barLayoutMode`，底栏就只能是单排——
 * 这正是派音文档里写的「之前两排修不出来」的根因。
 */

/** 单排：迷你条被拉成整条通栏（宽样式 = 展开播放态），页签让位收成左侧一颗圆钮 */
export const BAR_ONE_ROW: number = 0;
/** 上下两排：迷你条一排、页签一排（默认；数值与 HDS 的 HdsBarLayoutMode 一致） */
export const BAR_TWO_ROWS: number = 1;

/** 界面订阅这个键拿到当前排布（@StorageLink，值是上面两个常量之一） */
export const K_BAR_LAYOUT: string = 'bar_layout_mode';

/** 6.1.1(24) 的发行版版本码（`distributionOSApiVersion`，格式为主*10000 + 次*100 + 补丁） */
const DISTRIBUTION_OS_6_1_1: number = 60101;
/** 触发切换的最小滚动增量（vp）：滤掉惯性抖动 */
const DELTA_THRESHOLD: number = 2;
/** 切换动效时长（ms），与派音同档 */
const ANIMATION_MS: number = 500;

/** 本机发行版是否支持 `barLayoutMode`（6.1.1(24) 起；低版本上这套排布不存在） */
export function twoRowLayoutSupported(): boolean {
  try {
    return deviceInfo.distributionOSApiVersion >= DISTRIBUTION_OS_6_1_1;
  } catch (e) {
    return false;
  }
}

/** 底栏的排布与滚动联动（全静态：状态都落在 AppStorage 上，界面用 @StorageLink 订阅） */
export class BottomBar {
  /** 联动总开关（派音那边用户要求「全都自动收起展开」，这里对齐） */
  static isEnabled(): boolean {
    return true;
  }

  /** 当前是不是「上下两排」 */
  static isTwoRows(): boolean {
    return (AppStorage.get<number>(K_BAR_LAYOUT) ?? BAR_TWO_ROWS) === BAR_TWO_ROWS;
  }

  /**
   * 切换排布（两排 / 单排）
   *
   * 两个键一起写：`K_BAR_LAYOUT` 是给壳层喂 HDS 的 `barLayoutMode`，`K_MINI_EXPANDED` 是
   * 迷你条自己的展开态（单排 = 展开成整条通栏，两排 = 收成窄胶囊）—— 页内那条迷你栏的宽度
   * 与各页的底部让位也读它（见 pages/Index.ets 的 publishLayout）。
   * 迷你条的样式由我们自己定（HDS 的回调只用来「看」，不拿它当状态源，见 Index 的说明）。
   */
  static applyLayout(twoRows: boolean): void {
    AppStorage.setOrCreate(K_BAR_LAYOUT, twoRows ? BAR_TWO_ROWS : BAR_ONE_ROW);
    AppStorage.setOrCreate(K_MINI_EXPANDED, !twoRows);
  }

  /** 带弹簧动效地切换（壳层那两处回调用它，让 HDS 自己重排） */
  static applyLayoutAnimated(ctx: UIContext, twoRows: boolean): void {
    ctx.animateTo({
      duration: ANIMATION_MS,
      curve: curves.springMotion(0.5, 0.7, 0.6),
    }, () => {
      BottomBar.applyLayout(twoRows);
    });
  }

  /**
   * 页面滚了一帧：按方向切换排布
   *
   * 上滑（增量 > 0、内容偏移增加）→ 单排；下滑（增量 < 0）→ 两排。
   * 传进来的必须是**本帧增量**（`onScrollFrameBegin` 的 offset），不是累计偏移 ——
   * 口径别反（派音的注释专门提醒过这一点）。
   *
   * 宽屏不联动：宽屏下两条栏本来就同时展开（HDS 自己按宽度排），跟着滚反而乱。
   * 低版本机型直接跳过，避免写入一个不存在的状态。
   */
  static notifyScrollDelta(ctx: UIContext, delta: number): void {
    if (!BottomBar.isEnabled() || !twoRowLayoutSupported()) {
      return;
    }
    const width: number = AppStorage.get<number>(K_WINDOW_WIDTH) ?? 0;
    if (width >= BP_MEDIUM) {
      return;
    }
    if (delta > DELTA_THRESHOLD) {
      if (!BottomBar.isTwoRows()) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'scroll up (%{public}d) -> one row', delta);
      BottomBar.applyLayoutAnimated(ctx, false);
    } else if (delta < -DELTA_THRESHOLD) {
      if (BottomBar.isTwoRows()) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'scroll down (%{public}d) -> two rows', delta);
      BottomBar.applyLayoutAnimated(ctx, true);
    }
  }
}
