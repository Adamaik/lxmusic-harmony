import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { HintText, ToggleSetting } from '../ui/SettingWidgets';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { K_HIDE_LISTEN_TAB, ListenSettings } from '../core/settings/ListenSettings';

/**
 * 听书设置（设置 - 听书）
 *
 * 一项：**隐藏「听书」页签**。听书（书架 / 搜索 / 书源）单独占底部导航栏的一栏，
 * 不看书的人可以让那一栏让位，导航栏只剩「推荐」与「我的」；关掉这一项它就回来。
 *
 * 开关放在这里而不是听书页自己身上，是因为页签一藏听书页就没有入口了 —— 这一页
 * 是把它找回来的唯一入口（我的 → 设置 → 听书），所以它必须待在设置里。
 *
 * 卡片排布与其余设置页同一套：窄屏一列、宽屏两张并排（这里是单张卡，宽屏同样铺满一行）。
 */
@Component
export struct ListenSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /** 是否隐藏「听书」页签 */
  @StorageLink(K_HIDE_LISTEN_TAB) hideTab: boolean = false;
  /**
   * 窗口宽度（vp）：宽屏下卡片并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  /** 说明文字跟着开关变：打开要说清楚去哪儿关回来 */
  private hint(): string {
    if (this.hideTab) {
      return '「听书」已从底部导航栏隐藏，书架 / 搜索 / 书源都不再占一栏。'
        + '要再显示出来，把上面这项关掉即可 —— 页签藏着的时候，这一个开关就是它的入口。';
    }
    return '听书（书架 / 搜索 / 书源）现在单独占底部导航栏的一栏，夹在「推荐」与「我的」之间。'
      + '用不上听书就打开上面这项，把那一栏从导航栏里去掉。';
  }

  build() {
    Column() {
      Scroll() {
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 卡片高度差得远时居中的话短卡会飘在半空，统一顶对齐
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一张卡落在透明标题栏下方，但它跟着内容一起滚走，
          // 这样往下滚时卡片能进到标题栏底下并透出来
          Column().height(this.topInset + 6).width('100%')

          Column({ space: 14 }) {
            Column({ space: 8 }) {
              ToggleSetting({
                label: '隐藏「听书」页签',
                value: this.hideTab,
                onPick: (next: boolean) => {
                  ListenSettings.getInstance().setHideTab(next);
                },
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({ text: this.hint() })
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
