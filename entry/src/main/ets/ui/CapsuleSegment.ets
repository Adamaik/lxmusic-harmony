import { ColorMetrics, LengthMetrics } from '@ohos.arkui.node';
import {
  CapsuleSegmentButtonV2,
  SegmentButtonV2ItemOptions,
  SegmentButtonV2Items
} from '@ohos.arkui.advanced.SegmentButtonV2';

/**
 * 左右切换的胶囊分段选择器（我的页：播放历史 / 平台音乐 / 下载管理 / 本地音乐）
 *
 * 直接用系统的 `CapsuleSegmentButtonV2`（`@ohos.arkui.advanced.SegmentButtonV2`）。
 *
 * 为什么不再自己画：之前这里是一排自绘胶囊 + 手画毛玻璃，怎么调都不像系统的样子。
 * 系统这套组件的圆角、内边距、选中态的过渡都是平台设计好的 ——
 * 平台有的组件就用平台的，这是「像系统」最短的一条路。
 *
 * 取值与派音的实现一致（它的 `CapsuleSegmentedSelector.ets`）：
 *   底 = 页面同色系的浅灰（不是玻璃，也不是白卡）；选中项 = 强调色药丸 + 反白字；
 *   未选中 = 深灰正文色；常规档高 40 / 圆角 20，紧凑档 30 / 15。
 *
 * 为什么这个组件必须写成 V2 而不是 V1：`SegmentButtonV2Items` 在 SDK 里是
 * `@ObservedV2` 装饰的类，V1 的 `@State` 不允许持有它（编译期直接报
 * 「The type of the '@State' property can not be a class decorated with '@ObservedV2'」），
 * 所以这里跟派音一样用 `@ComponentV2` + `@Local`。
 *
 * 另外两点写法上的注意：
 *   - 系统组件的尺寸 / 颜色只能通过 `LengthMetrics` / `ColorMetrics` 传，不能直接写数字；
 *   - 颜色用 `ColorMetrics.resourceColor()` 传**资源 token**（色板在 `ui/Theme.ets`
 *     与 `resources` 下同名同义的 base / dark 两份 color.json）：传 Resource 而不是 rgba 数值，
 *     深色模式才能跟着换成深色那份。之前因为色板是十六进制常量只能 rgba 换算，
 *     深色模式下就一直是一块浅灰底。
 */
@ComponentV2
export struct CapsuleSegment {
  @Param labels: string[] = [];
  /** 外部持有的选中项；外部改了它，这里跟着走（@Monitor） */
  @Param selectedIndex: number = 0;
  /** 紧凑档（高度 30 / 圆角 15）：放在标题栏这种矮地方时用 */
  @Param compact: boolean = false;
  @Param onSelect: (index: number) => void = () => {
  };
  /** 系统组件要一个 `SegmentButtonV2Items` 实例，不是裸数组 */
  @Local items: SegmentButtonV2Items = new SegmentButtonV2Items([]);
  /** 组件内部当前选中的下标 */
  @Local current: number = 0;

  aboutToAppear(): void {
    this.current = this.selectedIndex;
    this.rebuild();
  }

  @Monitor('selectedIndex')
  onIndexChanged(): void {
    if (this.current !== this.selectedIndex) {
      this.current = this.selectedIndex;
    }
  }

  @Monitor('labels')
  onLabelsChanged(): void {
    this.rebuild();
  }

  /** labels 变了要重建 items（选项是构造进去的，不是每帧读的） */
  private rebuild(): void {
    const options: SegmentButtonV2ItemOptions[] = [];
    for (const label of this.labels) {
      options.push({ text: label });
    }
    this.items = new SegmentButtonV2Items(options);
  }

  build() {
    CapsuleSegmentButtonV2({
      items: this.items,
      selectedIndex: this.current,
      onItemClicked: (index: number): void => {
        this.current = index;
        this.onSelect(index);
      },
      // 底：与「我的」页底色同色系的浅灰（C_SEG_BG，深色模式下自动换成深色那份）
      buttonBackgroundColor: ColorMetrics.resourceColor($r('app.color.c_seg_bg')),
      buttonMinHeight: LengthMetrics.vp(this.compact ? 30 : 40),
      buttonBorderRadius: LengthMetrics.vp(this.compact ? 15 : 20),
      itemMinHeight: LengthMetrics.vp(this.compact ? 30 : 40),
      itemBorderRadius: LengthMetrics.vp(this.compact ? 15 : 20),
      // 未选中：正文色（深色模式下是浅色字）；选中：反白字 + 强调色药丸（C_RED）
      itemFontColor: ColorMetrics.resourceColor($r('app.color.c_seg_unselected')),
      itemSelectedFontColor: ColorMetrics.resourceColor($r('app.color.c_on_accent')),
      itemSelectedBackgroundColor: ColorMetrics.resourceColor($r('app.color.c_red')),
    })
      .width('100%')
  }
}
