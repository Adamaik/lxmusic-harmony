import { C_RED, C_SEG_BG, C_TEXT_SUB, C_TEXT_WEAK, F_SUB } from './Theme';

/**
 * 设置页通用控件
 *
 * 播放设置与下载设置两页共用这一套：分段胶囊、标题行、说明文字、开关项、单选项。
 * 全部是 @Component 而不是 @Builder —— @Builder 的参数按值传递，状态改完不会刷新
 * 里面的 UI（开关会「点了不动」），这类会随状态变的控件必须是组件。
 */

export const TOGGLE_LABELS: string[] = ['开', '关'];

/**
 * 分段胶囊（音质四选一 / 开关二选一）
 *
 * 与我的页的 SegmentedTabs 是同一种观感，但这里不用玻璃材质：设置页是白卡片底，
 * 胶囊容器直接用浅灰实色，选中项才是红色药丸（与设置页参考图一致）。
 *
 * 选中态**只由外层传入的 activeIndex 决定**，不在组件里另存一份「当前选中」：
 * 那样在「点了但外层值没变」的场景（比如选了保存目录又取消）药丸会停在点击项上，
 * 与真实设置不一致。外层值变了这个 @Prop 就会刷新。
 */
@Component
export struct SegPills {
  @Prop labels: string[] = [];
  @Prop activeIndex: number = 0;
  onPick: (index: number) => void = () => {
  };

  build() {
    Row() {
      ForEach(this.labels, (label: string, i: number) => {
        Text(label)
          .fontSize(14)
          .fontWeight(this.activeIndex === i ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.activeIndex === i ? Color.White : '#3A3A3C')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.activeIndex === i ? C_RED : Color.Transparent)
          .animation({ duration: 200, curve: Curve.EaseInOut })
          .onClick(() => {
            this.onPick(i);
          })
      }, (label: string, i: number) => `${i}_${label}`)
    }
    .width('100%')
    .padding(3)
    .borderRadius(20)
    .backgroundColor(C_SEG_BG)
  }
}

/** 设置项的标题行（左标题，右侧可选的当前值） */
@Component
export struct SettingLabel {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
    }
    .width('100%')
  }
}

/** 说明文字 */
@Component
export struct HintText {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(11.5)
      .fontColor(C_TEXT_WEAK)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .textAlign(TextAlign.Start)
  }
}

/**
 * 「开 / 关」一项
 *
 * 注意这里是 @Component 而不是 @Builder：@Builder 的参数是**按值**传的，
 * 状态变量改完不会刷新 builder 里的 UI，表现就是「开关点了不动」
 * （初版踩过这个坑，所以播放设置页的每一项都是组件）。
 */
@Component
export struct ToggleSetting {
  @Prop label: string = '';
  @Prop value: boolean = false;
  onPick: (next: boolean) => void = () => {
  };

  build() {
    Column({ space: 9 }) {
      SettingLabel({ label: this.label })
      SegPills({
        labels: TOGGLE_LABELS,
        activeIndex: this.value ? 0 : 1,
        onPick: (index: number) => {
          this.onPick(index === 0);
        },
      })
    }
    .width('100%')
  }
}

/** 单选一项（播放音质、拓展音质的档位） */
@Component
export struct OptionSetting {
  @Prop label: string = '';
  @Prop options: string[] = [];
  @Prop activeIndex: number = 0;
  @Prop hint: string = '';
  onPick: (index: number) => void = () => {
  };

  build() {
    Column({ space: 9 }) {
      SettingLabel({ label: this.label })
      SegPills({
        labels: this.options,
        activeIndex: this.activeIndex,
        onPick: (index: number) => {
          this.onPick(index);
        },
      })
      if (this.hint.length > 0) {
        HintText({ text: this.hint })
      }
    }
    .width('100%')
  }
}

