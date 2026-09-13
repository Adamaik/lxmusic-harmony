import { C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { IconGlyph, I_CHEVRON_RIGHT } from '../ui/Icons';
import { DISLIKE_MODE_OPTIONS, LIST_MODE_OPTIONS, SyncModeOption, SYNC_MODE_CANCEL } from '../core/sync/SyncTypes';

/**
 * 同步方式选择（服务端要求选择时弹出）
 *
 * 服务端在合并前会回调客户端要一个方式（list_sync_get_sync_mode / dislike_sync_get_sync_mode），
 * 用户选完由 SyncManager.answerMode 回传。选项文案与洛雪移动端的弹窗一致。
 */
@Component
export struct SyncModeContent {
  /** 'list' 或 'dislike' */
  @Prop kind: string = 'list';
  @Prop serverName: string = '';
  @Prop bottomInset: number = 0;
  onPick: (mode: string) => void = () => {
  };

  private options(): SyncModeOption[] {
    return this.kind === 'dislike' ? DISLIKE_MODE_OPTIONS : LIST_MODE_OPTIONS;
  }

  private title(): string {
    const name: string = this.serverName.length > 0 ? this.serverName : '远程';
    return this.kind === 'dislike'
      ? `选择与「${name}」的「不喜欢的歌曲」同步方式`
      : `选择与「${name}」的列表同步方式`;
  }

  private tip(): string {
    return this.kind === 'dislike'
      ? '合并会去掉重复规则；覆盖会用一方的规则替换另一方。'
      : '合并会把两边的歌单合并去重；覆盖会用一方的歌单替换 ID 相同的歌单。';
  }

  @Builder
  optionRow(option: SyncModeOption) {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(option.title)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(option.desc)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 17, color: '#C2C2C6' })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor('#14404044') },
      })
      .onClick(() => {
        this.onPick(option.value);
      })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 16 })
    }
    .width('100%')
  }

  build() {
    Column() {
      Text(this.title())
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        .textAlign(TextAlign.Start)

      Text(this.tip())
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        .textAlign(TextAlign.Start)

      Scroll() {
        Column() {
          ForEach(this.options(), (option: SyncModeOption) => {
            this.optionRow(option)
          }, (option: SyncModeOption) => option.value)

          Column() {
            Row({ space: 10 }) {
              Text(SYNC_MODE_CANCEL.title)
                .fontSize(F_ITEM)
                .fontColor(C_RED)
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .onClick(() => {
              this.onPick(SYNC_MODE_CANCEL.value);
            })
          }
          .width('100%')
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
