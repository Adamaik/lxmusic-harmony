import { C_BG, C_CARD, C_DIVIDER, C_ON_ACCENT, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SUB,
  R_CARD } from '../ui/Theme';
import { CONTENT_MAX_WIDTH } from '../ui/Layout';
import { CHANGELOG, ChangelogEntry, fullDateOf, updateCount, weekdayOf } from '../core/changelog/Changelog';

/** 时间线竖线的宽度 */
const RAIL_W: number = 1;
/** 日期行首那个圆点的直径（最新一条大一号，用强调色） */
const DOT_LATEST: number = 10;
const DOT_OTHER: number = 7;
/** 圆点垂直位置：让它落在日期那行的光学中线上（16.5 号字，行高约 20） */
const DOT_TOP_LATEST: number = 5;
const DOT_TOP_OTHER: number = 6.5;

/**
 * 更新公告（帮助和反馈 → 更新公告）
 *
 * 版式是一条**从上往下连的时间线**：左边一条竖线，每一条公告在线上有一个圆点，
 * 圆点右边是日期、这一版的主题、以及若干条更新内容（放在白卡里）。**最新的在最上面，
 * 越往下越老** —— 用户点进来第一眼看到的就是「这次更新了什么」。
 *
 * 竖线是怎么画的：每条公告的**外层容器自己带一条 left border**，条与条之间不留缝
 * （间距做在内边距里），于是相邻两条的 border 首尾相接，看上去就是一条连续的线。
 * 不用「一条 height('100%') 的线元素」：那个百分比在高度由内容撑开的容器里算不准，
 * 宽屏 / 字体放大 / 条目多寡一变就会断线或只剩一小截。圆点是绝对定位压在这条 border 上的
 * （`.position` 不参与排版，所以它不会把内容挤歪）。
 *
 * 内容宽度收在 720（CONTENT_MAX_WIDTH）以内：时间线是「一列窄内容」，平板上拉满整屏
 * 会变成一行字横穿一块 1400vp 的白板，读起来很累。
 */
@Component
export struct ChangelogView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」） */
  @Prop topInset: number = 0;
  /** 底部让出手势条 */
  @Prop bottomInset: number = 0;

  /**
   * 一条公告
   *
   * `index` 只用来分「最新一条」（红点 + 标签）与「最后一条」（线尾留短一点）。
   */
  @Builder
  entryOf(entry: ChangelogEntry, index: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Column({ space: 8 }) {
          // 日期：2026年10月27日 · 周二 [+ 最新]
          Row({ space: 8 }) {
            Text(fullDateOf(entry.date))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT)
            Text(weekdayOf(entry.date))
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
            if (index === 0) {
              Text('最新')
                .fontSize(10.5)
                .fontColor(C_ON_ACCENT)
                .backgroundColor(C_RED)
                .borderRadius(7)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            }
          }
          .width('100%')

          Text(entry.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)

          // 这一版的更新条目
          Column({ space: 9 }) {
            ForEach(entry.items, (text: string) => {
              Row({ space: 9 }) {
                // 小圆点用 Column + 圆角画，不用 Circle().fill(资源色)：fill 取不到资源时会退回黑色
                Column()
                  .width(4)
                  .height(4)
                  .borderRadius(2)
                  .backgroundColor(C_RED)
                  .margin({ top: 8 })
                Text(text)
                  .fontSize(13.5)
                  .lineHeight(20)
                  .fontColor(C_TEXT)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (text: string, itemIndex: number) => `${entry.date}-${itemIndex}`)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(C_CARD)
          .borderRadius(R_CARD)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // 左边留出竖线的位置；条与条之间的空隙做在**内边距**里，竖线才能连上
        .padding({ left: 26, bottom: index === CHANGELOG.length - 1 ? 12 : 28 })
      }
      .width('100%')

      // 线上的圆点（绝对定位，不参与排版）
      Column()
        .width(index === 0 ? DOT_LATEST : DOT_OTHER)
        .height(index === 0 ? DOT_LATEST : DOT_OTHER)
        .borderRadius(index === 0 ? DOT_LATEST / 2 : DOT_OTHER / 2)
        .backgroundColor(index === 0 ? C_RED : C_DIVIDER)
        .position({
          x: index === 0 ? -DOT_LATEST / 2 : -DOT_OTHER / 2,
          y: index === 0 ? DOT_TOP_LATEST : DOT_TOP_OTHER,
        })
    }
    .width('100%')
    .border({ width: { left: RAIL_W }, color: { left: C_DIVIDER } })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 0 }) {
          // 顶部占位：内容落在透明标题栏下方，且这段跟着内容一起滚走
          // （用容器内边距会把内容裁在标题栏下边缘，看起来就"像被顶栏挡住"）
          Column().height(this.topInset + 6).width('100%')

          Column() {
            Column({ space: 4 }) {
              Text('每次更新做了什么，都记在这里。')
                .fontSize(F_SUB)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(`共 ${updateCount()} 次更新 · 最新的在最上面`)
                .fontSize(11.5)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 2, right: 2, bottom: 16 })

            ForEach(CHANGELOG, (entry: ChangelogEntry, index: number) => {
              this.entryOf(entry, index)
            }, (entry: ChangelogEntry) => entry.date)

            Text('以上就是全部更新记录')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 6, bottom: 8 })
          }
          .width('100%')
          .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
          .padding({ bottom: this.bottomInset + 20 })
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    // 时间线是「一列窄内容」：宽屏收在 720 以内并居中（Column 默认子项居中）
    .padding({ left: 16, right: 16, top: 8 })
  }
}
