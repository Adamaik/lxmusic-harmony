import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, C_CHEVRON, C_ON_ACCENT, C_RED, C_RED_TINT, C_SEG_BG, C_SEG_UNSELECTED,
  C_SLIDER_TRACK, C_TEXT, C_TEXT_WEAK, R_CARD } from '../ui/Theme';
import { HintText, ToggleSetting } from '../ui/SettingWidgets';
import { AudioEffectSettings, EQ_BAND_LABELS, EQ_GAIN_MAX, EQ_GAIN_MIN, EQ_PRESETS, EqPreset,
  K_EQ_DIRTY, K_EQ_ENABLED, K_EQ_GAINS, K_EQ_PRESET } from '../core/settings/AudioEffectSettings';
import { cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';

/**
 * 音效控制台（设置 - 播放设置 - 音效控制台）
 *
 * 为什么单独开一页，而不是塞在播放设置那张卡里：10 段 EQ 要的是**一屏放得下的操作面**
 * —— 一条能看出形状的响应曲线 + 十段能精确拖动的推子 + 九枚预设。挤在设置页的卡片里
 * （内容宽只有三百来 vp）时，预设胶囊一行要放十枚、推子一屏只有十行紧贴在一起，
 * 怎么排都局促。单独成页之后，曲线能画到 118 高、每段推子 40 高、预设可以换行，
 * 才像一台均衡器而不是一堆控件。
 *
 * 播放设置里只留「开关 + 跳转这一页」两行（见 PlaySettingsView 的 SoundEffectSetting）。
 *
 * 页面本身不改播放逻辑：所有值都写进 AudioEffectSettings（AppStorage + 落盘），
 * 播放侧订阅变更后从头重播当前曲目（见 PlaySession.requestEqReplay）。
 */
@Component
export struct EqSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  @StorageLink(K_EQ_ENABLED) eqEnabled: boolean = false;
  @StorageLink(K_EQ_PRESET) eqPreset: string = 'off';
  @StorageLink(K_EQ_GAINS) eqGains: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  /** 推子改过但还没点「应用」 */
  @StorageLink(K_EQ_DIRTY) eqDirty: boolean = false;
  /** 窗口宽度（vp）：宽屏下三张卡并排（0 = 还没量到，按手机一列） */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /** 预设胶囊的平均宽度够不够一行放四个（宽屏时卡片更宽，一排能放更多） */
  private chipsGap(): number {
    return 8;
  }

  /**
   * 预设按三列切行
   *
   * 不做「自动换行」是因为九枚胶囊按内容宽度换行会落成 4/4/1 —— 最后一行孤零零一枚，
   * 看着像排坏了。固定三列 + 等宽，就是整整齐齐的 3×3。
   */
  private presetRows(): EqPreset[][] {
    const rows: EqPreset[][] = [];
    for (let i = 0; i < EQ_PRESETS.length; i += 3) {
      rows.push(EQ_PRESETS.slice(i, i + 3));
    }
    return rows;
  }

  /** 最后一行不满三个时补的空位（占住三分之一宽度，药丸不会被拉宽） */
  private fillers(count: number): number[] {
    const holes: number[] = [];
    for (let i = count; i < 3; i++) {
      holes.push(i);
    }
    return holes;
  }

  build() {
    Column() {
      Scroll() {
        Flex({
          direction: this.windowWidth >= 840 ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.windowWidth >= 840 ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 三张卡高度差得多（开关卡只有两行、推子卡十行），居中的话短卡会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走
          Column().height(this.topInset + 6).width('100%')

          // ------------------------------------------------ 开关
          Column({ space: 12 }) {
            Column({ space: 8 }) {
              ToggleSetting({
                label: '音效（EQ）',
                value: this.eqEnabled,
                onPick: (next: boolean) => {
                  AudioEffectSettings.getInstance().setEnabled(next);
                },
              })
              HintText({
                text: this.eqEnabled
                  ? '开着的时候，每首歌在起播前先过一次 EQ：起播多等约 0.3~0.5 秒，之后就是普通播放。'
                  : '音效现在关着：下面的调节会存下来，打开这个开关才开始生效。',
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 10 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 预设
          Column({ space: 12 }) {
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Text('预设')
                  .fontSize(15)
                  .fontColor(C_TEXT)
                if (this.eqPreset === 'custom') {
                  Text('自定义')
                    .fontSize(10.5)
                    .fontColor(C_RED)
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .borderRadius(8)
                    .backgroundColor(C_RED_TINT)
                }
                Blank()
              }
              .width('100%')

              Column({ space: this.chipsGap() }) {
                ForEach(this.presetRows(), (row: EqPreset[], rowIndex: number) => {
                  Row({ space: 8 }) {
                    ForEach(row, (preset: EqPreset) => {
                      Text(preset.label)
                        .fontSize(13.5)
                        .fontWeight(this.eqPreset === preset.key ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(this.eqPreset === preset.key ? C_ON_ACCENT : C_SEG_UNSELECTED)
                        .textAlign(TextAlign.Center)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .height(36)
                        .layoutWeight(1)
                        .borderRadius(18)
                        .backgroundColor(this.eqPreset === preset.key ? C_RED : C_SEG_BG)
                        .animation({ duration: 180, curve: Curve.EaseInOut })
                        .onClick(() => {
                          AudioEffectSettings.getInstance().selectPreset(preset.key);
                        })
                    }, (preset: EqPreset) => preset.key)
                    // 最后一行不满三个：补空位，别让剩下的胶囊被拉得比上面宽
                    ForEach(this.fillers(row.length), (hole: number) => {
                      Blank().layoutWeight(1)
                    }, (hole: number) => `eq_preset_hole_${rowIndex}_${hole}`)
                  }
                  .width('100%')
                }, (row: EqPreset[], rowIndex: number) => `eq_preset_row_${rowIndex}`)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 14 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '「原声」= 十段全 0，等于不做处理；「自定义」是自己拖过推子之后的状态。'
                + '选预设立刻生效；手动调的值要按右上角「应用」才生效。',
            })
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 十段推子
          Column({ space: 12 }) {
            Column({ space: 4 }) {
              Row({ space: 6 }) {
                Text('10 段均衡器')
                  .fontSize(15)
                  .fontColor(C_TEXT)
                Text('Hz / dB')
                  .fontSize(10.5)
                  .fontColor(C_TEXT_WEAK)
                Blank()
                /**
                 * 应用：把自己拖出来的这套增益交给播放侧（重播一次，和选预设一样快）
                 *
                 * 为什么不是自动：一次调整常常要动好几段推子，段段都重播会把一首歌
                 * 打回开头七八次。调完统一按一下，只重播一次。
                 * 没改动时按钮变灰写「已应用」，按了也不打断播放。
                 */
                Row({ space: 5 }) {
                  if (this.eqDirty) {
                    Column()
                      .width(5)
                      .height(5)
                      .borderRadius(2.5)
                      .backgroundColor(C_ON_ACCENT)
                  }
                  Text(this.eqDirty ? '应用' : '已应用')
                    .fontSize(11.5)
                    .fontWeight(this.eqDirty ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(this.eqDirty ? C_ON_ACCENT : C_TEXT_WEAK)
                }
                .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(this.eqDirty ? C_RED : C_SEG_BG)
                .animation({ duration: 160, curve: Curve.EaseInOut })
                .accessibilityText(this.eqDirty ? '应用音效设置' : '音效设置已应用')
                .onClick(() => {
                  AudioEffectSettings.getInstance().applyGains();
                })
              }
              .width('100%')
              .height(30)

              EqCurve({ gains: this.eqGains })
                // 曲线底边别贴着第一段推子：两块内容要能看出是「图」和「操作」两层
                .margin({ top: 4, bottom: 8 })

              ForEach(EQ_BAND_LABELS, (label: string, index: number) => {
                EqBandRow({
                  label: label,
                  gain: this.eqGains[index] ?? 0,
                  onPick: (gain: number, done: boolean) => {
                    // 拖动过程只改内存，松手才落盘（见 setBandGain 的 commit 参数）
                    AudioEffectSettings.getInstance().setBandGain(index, gain, done);
                  },
                })
              }, (label: string, index: number) => `eq_band_${index}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '左端 31 Hz 是低频（鼓、贝斯），右端 16 kHz 是高频（镲片、齿音）；'
                + '每段往右抬、往左压，中点是 0 dB 不增不减。点轨道直接跳到该位置，'
                + '横向拖动连续调；调完按右上角「应用」，当前这首会从头重新处理一遍。',
            })
          }
          .width(cardWidthOf(this.windowWidth))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}

/**
 * 一段 EQ 推子（横向、双极：-10 ~ +10 dB，0 dB 在中点）
 *
 * 为什么要自己画外观：这一段是**双极**的。系统 Slider 的进度条只能从 min 一路填到当前值
 * —— 增益全是 0 时它照样把半根轨道涂成红色，十段堆在一起就是十条长度相近的红线，
 * 既看不出「哪段加、哪段减」，一眼扫过去还特别拥挤。这里画的是「淡轨道 + 从中点向两侧
 * 长出去的红色填充 + 一枚圆钮」，抬哪段压哪段一看就懂。
 *
 * 但**手势仍然交给一枚透明的系统 Slider**（轨道、选中段、圆钮全设成透明，只留触摸）。
 * 原因是自绘 PanGesture 在可滚动页面里会被外层 Scroll 抢走：实测横向拖动时页面跟着滚，
 * 推子纹丝不动。Slider 是框架自己的控件，抢手势的优先级与外层滚动是配好的，
 * 放在任何滚动列表里都可靠。
 *
 * 两套坐标要对齐：Slider 在 OutSet/blockSize=KNOB 时，圆钮中心从 KNOB/2 走到 宽-KNOB/2，
 * 这里画圆钮也用同一个映射（见 knobX），所以看到的圆钮就在手指底下。
 */
@Component
struct EqBandRow {
  @Prop label: string = '';
  @Prop gain: number = 0;
  /** 拖动中 done=false，松手 / 点击 done=true */
  onPick: (gain: number, done: boolean) => void = () => {
  };

  private static readonly KNOB: number = 13;
  private static readonly H: number = 40;

  /** 轨道区可用宽度；首帧为 0，等 onAreaChange 填上再画内容 */
  @State private bandWidth: number = 0;

  private usable(): number {
    return Math.max(1, this.bandWidth - EqBandRow.KNOB);
  }

  private ratio(gain: number): number {
    return (gain - EQ_GAIN_MIN) / (EQ_GAIN_MAX - EQ_GAIN_MIN);
  }

  /** 圆钮左上角（与 Slider 的块位置同一条映射） */
  private knobX(gain: number): number {
    return this.ratio(gain) * this.usable();
  }

  /** 轨道中点（0 dB 的位置） */
  private center(): number {
    return this.bandWidth / 2;
  }

  /** 填充条左端：正增益从中点往右长，负增益往左长 */
  private fillX(): number {
    const knobCenter: number = this.knobX(this.gain) + EqBandRow.KNOB / 2;
    return knobCenter >= this.center() ? this.center() : knobCenter;
  }

  private fillW(): number {
    const knobCenter: number = this.knobX(this.gain) + EqBandRow.KNOB / 2;
    return Math.abs(knobCenter - this.center());
  }

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(C_TEXT_WEAK)
        .width(30)
        .textAlign(TextAlign.End)

      Stack() {
        // 淡轨道
        Row()
          .width('100%')
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(C_SLIDER_TRACK)
          .position({ x: 0, y: (EqBandRow.H - 3) / 2 })

        if (this.bandWidth > 0) {
          // 0 dB 中线：抬还是压，看填充长在中点的哪一侧
          Row()
            .width(1)
            .height(13)
            .backgroundColor(C_TEXT_WEAK)
            .opacity(0.45)
            .position({ x: this.center() - 0.5, y: (EqBandRow.H - 13) / 2 })

          if (this.fillW() >= 1) {
            Row()
              .width(this.fillW())
              .height(3)
              .borderRadius(1.5)
              .backgroundColor(C_RED)
              .position({ x: this.fillX(), y: (EqBandRow.H - 3) / 2 })
          }

          Row()
            .width(EqBandRow.KNOB)
            .height(EqBandRow.KNOB)
            .borderRadius(EqBandRow.KNOB / 2)
            .backgroundColor(C_RED)
            .position({ x: this.knobX(this.gain), y: (EqBandRow.H - EqBandRow.KNOB) / 2 })
        }

        // 只负责手势的透明滑块：轨道与圆钮都藏起来，外观由上面几层画
        Slider({
          value: this.gain,
          min: EQ_GAIN_MIN,
          max: EQ_GAIN_MAX,
          step: 1,
          style: SliderStyle.OutSet,
        })
          .width('100%')
          .height(EqBandRow.H)
          .blockSize({ width: EqBandRow.KNOB, height: EqBandRow.KNOB })
          .blockColor(Color.Transparent)
          .trackThickness(3)
          .trackColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .onChange((value: number, mode: SliderChangeMode) => {
            // 拖动过程只改内存，松手 / 点击才落盘（见 setBandGain 的 commit 参数）
            const done: boolean = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
            if (value !== this.gain || done) {
              this.onPick(value, done);
            }
          })
      }
      .layoutWeight(1)
      .height(EqBandRow.H)
      .onAreaChange((_old: Area, area: Area) => {
        const w: number = Number.parseFloat(area.width.toString());
        if (!Number.isNaN(w) && Math.abs(w - this.bandWidth) > 0.5) {
          this.bandWidth = w;
        }
      })

      Text(`${this.gain > 0 ? '+' : ''}${this.gain}`)
        .fontSize(12)
        .fontColor(this.gain === 0 ? C_TEXT_WEAK : C_TEXT)
        .width(28)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(EqBandRow.H)
  }
}

/**
 * 10 段均衡器的响应曲线
 *
 * 用 Path 而不是 Canvas：Canvas 的 fillStyle 只吃色值字符串，取不到资源色，
 * 深色模式下必然画错（本项目的色全是 token）。Path 的 fill / stroke 接受 ResourceColor，
 * 深浅模式自动跟着走。
 *
 * 只是概览：横轴 10 个点对应 10 段中心频率，纵轴是增益，中间那条线是 0 dB。
 */
@Component
struct EqCurve {
  @Prop gains: number[] = [];
  @State private curveWidth: number = 0;

  private static readonly H: number = 118;
  /** 上下留白：增益拉满时线不要贴边 */
  private static readonly PAD: number = 12;

  /**
   * commands 里的坐标是**物理像素**，而组件的宽高是 vp
   *
   * 实测踩到的坑：按 vp 写 commands 时，曲线只画出左边三分之一（1 vp ≈ 2.7 px，
   * 画出来就是 1/2.7 大）。这里统一乘一次密度，让命令里的单位与组件盒子对齐。
   */
  private density(): number {
    return this.getUIContext().vp2px(1);
  }

  /** 折线（不闭合，给描边用）：两端各补一个边界点，铺满整条宽度 */
  private linePath(): string {
    const n: number = this.gains.length;
    if (this.curveWidth <= 0 || n < 2) {
      return '';
    }
    const k: number = this.density();
    const mid: number = EqCurve.H / 2;
    const amp: number = mid - EqCurve.PAD;
    let d: string = '';
    // i 从 -1 到 n：-1 补在 x=0，n 补在 x=右边缘，这样曲线是「贴边」的，
    // 下面的填充也就是一条竖直边，而不是从首末点斜着收口（那样像个水桶）
    for (let i = -1; i <= n; i++) {
      const at: number = Math.min(n - 1, Math.max(0, i));
      const g: number = Math.max(EQ_GAIN_MIN, Math.min(EQ_GAIN_MAX, this.gains[at] ?? 0));
      const x: number = (i < 0 ? 0 : (i >= n ? this.curveWidth : (this.curveWidth * (i + 0.5)) / n)) * k;
      const y: number = (mid - (g / EQ_GAIN_MAX) * amp) * k;
      d += `${i < 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`;
    }
    return d;
  }

  /** 同一条线再收口到底边，给那层很淡的红填充用 */
  private areaPath(): string {
    const line: string = this.linePath();
    if (line.length === 0) {
      return '';
    }
    const k: number = this.density();
    return `${line}L${(this.curveWidth * k).toFixed(1)} ${(EqCurve.H * k).toFixed(1)}`
      + `L0 ${(EqCurve.H * k).toFixed(1)}Z`;
  }

  build() {
    Stack() {
      if (this.curveWidth > 0) {
        Path()
          .width('100%')
          .height(EqCurve.H)
          .commands(this.areaPath())
          .fill(C_RED_TINT)
          // Path 不给 stroke 时默认会描一圈黑边，把填充的形状勾出来就脏了
          .stroke(Color.Transparent)
        Path()
          .width('100%')
          .height(EqCurve.H)
          .commands(this.linePath())
          .fill(Color.Transparent)
          .stroke(C_RED)
          .strokeWidth(2)
          .strokeLineJoin(LineJoinStyle.Round)
      }

      // 0 dB 基准线
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(C_SLIDER_TRACK)
        .position({ x: 0, y: EqCurve.H / 2 })

      Row()
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height(EqCurve.H)
    .onAreaChange((_old: Area, area: Area) => {
      const w: number = Number.parseFloat(area.width.toString());
      if (!Number.isNaN(w) && Math.abs(w - this.curveWidth) > 0.5) {
        this.curveWidth = w;
      }
    })
  }
}
