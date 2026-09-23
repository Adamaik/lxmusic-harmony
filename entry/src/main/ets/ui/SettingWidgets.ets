import { C_ON_ACCENT, C_RED, C_SEG_BG, C_SEG_UNSELECTED, C_SLIDER_TRACK, C_TEXT, C_TEXT_WEAK,
  F_SUB } from './Theme';

/**
 * 设置页通用控件
 *
 * 播放设置 / 下载设置 / 外观设置 / WebDAV 设置四页共用这一套：标题、说明文字、
 * 开关项、单选项、滑块项。
 *
 * 开关与滑块是 iOS 设置页那种「一行一项」：**左边标题、右边控件**
 *   开关 -> 右侧一枚小滑块（iPhone 上 WiFi 开关那种）
 *   滑块 -> 右侧一条短轨（歌词字号、封面圆角）
 * 多选（音质四档、材质四档、文件名格式三种）**占两行**：标题一行、胶囊整行铺在下面 ——
 * 档位名加上三四枚中文药丸挤在同一行里，字会被压成省略号（「全景声+」「艺术家-标题」），
 * 那还不如多占一行。
 * 之前每一项是「标题一行 + 控件铺满整行」：开关是 34 高横贯整行的「开 / 关」胶囊、
 * 滑块也是一条整行大滑块 —— 播放设置一页十几项，一屏只能看到五六项，得来回滚。
 * 开关九项、滑块两项现在都是一行，同样的内容高度约减半。
 *
 * 全部是 @Component 而不是 @Builder —— @Builder 的参数按值传递，状态改完不会刷新
 * 里面的 UI（开关会「点了不动」），这类会随状态变的控件必须是组件。
 */

/** 一行设置的高度：左标题 + 右控件，开关与滑块项共用 */
export const ROW_H: number = 46;

/** 右侧滑块的轨道宽度 */
const SLIDER_W: number = 116;

/** 开关项的标题（行的左半边：占满除右侧滑块以外的宽度，太长就省略号） */
@Component
struct RowLabel {
  @Prop label: string = '';

  build() {
    Text(this.label)
      .fontSize(15)
      .fontColor(C_TEXT)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .textAlign(TextAlign.Start)
      .layoutWeight(1)
  }
}

/**
 * 分段胶囊（音质四档 / 材质四档 / 文件名格式三种）
 *
 * 与我的页的 SegmentedTabs 是同一种观感，但这里不用玻璃材质：设置页是白卡片底，
 * 胶囊容器直接用浅灰实色，选中项才是红色药丸（与设置页参考图一致）。
 * 比我的页那套小一号：药丸高 30、字号 13（原先是高 34、字号 14）。
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
          .fontSize(13)
          .fontWeight(this.activeIndex === i ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.activeIndex === i ? C_ON_ACCENT : C_SEG_UNSELECTED)
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .height(30)
          .borderRadius(15)
          .backgroundColor(this.activeIndex === i ? C_RED : Color.Transparent)
          .animation({ duration: 200, curve: Curve.EaseInOut })
          .onClick(() => {
            this.onPick(i);
          })
      }, (label: string, i: number) => `${i}_${label}`)
    }
    .width('100%')
    .padding(3)
    .borderRadius(18)
    .backgroundColor(C_SEG_BG)
  }
}

/** 只读的一行：左标题 + 右侧当前值（值长了省略号，标题不缩） */
@Component
export struct SettingLabel {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor(C_TEXT)
        .maxLines(1)
        .flexShrink(0)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
      }
    }
    .width('100%')
    .height(ROW_H)
  }
}

/** 说明文字（挂在它说明的那一项下面，比正文小一号、更淡） */
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
 * 「开 / 关」一项：左标题 + 右侧一枚小滑块
 *
 * 开关用系统的 Toggle(Switch)：它自己画滑块与轨道，选中色走强调红，
 * 观感即 iPhone 设置页里 WiFi 那种小开关。**不要再改回「开 / 关」胶囊** ——
 * 那是两枚文字药丸占满整行，比这枚小滑块高一半还多，设置项一多就显长。
 */
@Component
export struct ToggleSetting {
  @Prop label: string = '';
  @Prop value: boolean = false;
  onPick: (next: boolean) => void = () => {
  };

  build() {
    Row({ space: 10 }) {
      RowLabel({ label: this.label })
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(C_RED)
        .onChange((isOn: boolean) => {
          this.onPick(isOn);
        })
    }
    .width('100%')
    .height(ROW_H)
  }
}

/**
 * 多选一项：标题一行 + 胶囊整行铺在下面（档位、文件名格式）
 *
 * 这一项**不并成一行**：档位名加上三四枚中文药丸（「全景声+」「艺术家-标题」）挤在同
 * 一行里，药丸里的字会被压成省略号，看不清选了哪档。宁可多占一行。
 * 标题与开关项同字号同色（15 / 主文字），读下来是同一套标题。
 */
@Component
export struct OptionSetting {
  @Prop label: string = '';
  @Prop options: string[] = [];
  @Prop activeIndex: number = 0;
  @Prop hint: string = '';
  onPick: (index: number) => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

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

/**
 * 滑块一项：左标题 + 右侧「当前值 + 一条短轨」
 *
 * 拖动时实时回调（界面跟着变），松手 / 点击轨道才落盘 —— 由外层看 done 决定。
 * 滑块是系统 Slider，OutSet 样式下自带 40 高的触摸区，所以行高要给够（ROW_H）。
 * 当前值贴着滑块放（标题与它之间用 Blank 撑开），这样「标题 -> 值 -> 轨道」是一条
 * 从左到右的读线，值也始终在滑块边上，不会因为标题长短而跑位。
 */
@Component
export struct SliderSetting {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop min: number = 0;
  @Prop max: number = 100;
  onPick: (value: number, done: boolean) => void = () => {
  };

  build() {
    Row({ space: 6 }) {
      Text(this.label)
        .fontSize(15)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Blank()

      Text(`${this.value}`)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)

      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: 1,
        style: SliderStyle.OutSet,
      })
        .trackThickness(3)
        .blockSize({ width: 16, height: 16 })
        .blockColor(Color.White)
        .selectedColor(C_RED)
        .trackColor(C_SLIDER_TRACK)
        .width(SLIDER_W)
        .onChange((value: number, mode: SliderChangeMode) => {
          const done: boolean = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
          this.onPick(value, done);
        })
    }
    .width('100%')
    .height(ROW_H)
  }
}
