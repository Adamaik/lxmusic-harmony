import { PlaylistSummary } from '../core/player/PlaySession';
import { C_DIVIDER, C_FILL_SOFT, C_RED, C_TEXT, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';

/**
 * 「添加到歌单」的选歌单面板
 *
 * 歌单详情、在线榜单、播放历史三处的行菜单都用它，所以从歌单详情里抽出来。
 * 面板只负责挑/新建，真正的落库由宿主做（宿主手里有要添加的那首歌）；
 * 歌单列表由宿主在打开前重新读一次传进来，这样刚建的歌单马上就能选到。
 */
@Component
export struct AddToPlaylistSheet {
  /** 标题里显示的歌曲名 */
  @Prop songName: string = '';
  /** 可选歌单（打开面板前由宿主刷新） */
  @Prop candidates: PlaylistSummary[] = [];
  @Prop bottomInset: number = 0;
  /** 选中一个已有歌单 */
  onPick: (playlist: PlaylistSummary) => void = () => {
  };
  /** 新建歌单并添加（名字已在面板里去过首尾空格） */
  onCreate: (name: string) => void = () => {
  };
  @State name: string = '';

  build() {
    Column() {
      Text(this.songName.length === 0 ? '添加到歌单' : `添加到歌单：${this.songName}`)
        .fontSize(F_ITEM)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      Row({ space: 8 }) {
        TextInput({ text: this.name, placeholder: '新建歌单名称' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .height(44)
          .backgroundColor(C_FILL_SOFT)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.name = value;
          })
        Button('新建并添加')
          .fontSize(F_SUB)
          .height(44)
          .backgroundColor(C_RED)
          .enabled(this.name.trim().length > 0)
          .onClick(() => {
            this.onCreate(this.name.trim());
          })
      }
      .width('100%')

      if (this.candidates.length === 0) {
        Text('还没有歌单，在上面新建一个；歌单会同步到其它设备')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ top: 18, bottom: 6 })
          .textAlign(TextAlign.Start)
      } else {
        List() {
          ForEach(this.candidates, (item: PlaylistSummary) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(item.name)
                  .fontSize(F_ITEM)
                  .fontColor(C_TEXT)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
                Text(`${item.count} 首`)
                  .fontSize(F_SUB)
                  .fontColor(C_TEXT_WEAK)
              }
              .width('100%')
              .height(50)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.onPick(item);
              })
            }
          }, (item: PlaylistSummary) => `${item.id}_${item.count}_${item.name}`)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 6 })
        .divider({ strokeWidth: 0.6, color: C_DIVIDER })
      }

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }
}
