import { PlaySession } from '../core/player/PlaySession';
import { K_CURRENT_ART, K_CURRENT_COVER, K_CURRENT_ID, K_CURRENT_NAME, K_CURRENT_SINGER, K_MINI_EXPANDED,
  K_PLAYER_STATUS } from '../core/player/PlaySession';
import { C_TEXT, C_TEXT_SUB } from '../ui/Theme';
import { I_NEXT, I_PAUSE_CIRCLE, I_PLAY_CIRCLE, I_QUEUE, IconGlyph } from '../ui/Icons';
import { CoverArt } from '../ui/Widgets';

/**
 * HdsTabs 迷你栏（MiniBar）的内容
 *
 * HDS 的悬浮页签栏右边会跟一条「迷你栏」：高度与页签栏相等，分展开/折叠两种形态，
 * 宽度、位置和两者之间的让位动画都由 HDS 自己算，我们只负责画里面是什么。
 * 于是洛雪底部那套交互就成了官方的默认行为：
 *   点折叠态的迷你栏（唱片圆钮）-> 迷你栏展开、页签栏收起来；
 *   点收起来的页签栏 -> 迷你栏折回去。
 *
 * 形态从 AppStorage 读（HDS 的 onBarStyleChange 回调写进去），
 * 这样即使 builder 不被重新调用，内容也会跟着变。
 */
@Component
export struct MiniBarView {
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  /**
   * 强制用展开态
   *
   * 页签体系里的迷你栏由 HDS 管展开/折叠（形态从 K_MINI_EXPANDED 读）；
   * 歌单详情这类不在页签里的页面单独挂一条迷你栏，恒为展开态。
   */
  @Prop forceExpanded: boolean = false;
  @StorageLink(K_MINI_EXPANDED) expanded: boolean = false;
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_CURRENT_NAME) name: string = '';
  @StorageLink(K_CURRENT_SINGER) singer: string = '';
  @StorageLink(K_CURRENT_COVER) cover: string = '';
  @StorageLink(K_CURRENT_ART) art: boolean = false;
  @StorageLink(K_PLAYER_STATUS) status: string = 'idle';

  build() {
    if (this.expanded || this.forceExpanded) {
      // 展开态：封面 + 歌名/歌手 + 播放、下一首、播放列表
      Row({ space: 8 }) {
        // 封面 + 歌名一起当「回到全屏播放器」的热区，右边三个按钮各管各的
        Row({ space: 8 }) {
          // 圆封面：半径给一半即正圆，和折叠态那颗唱片圆钮、播放页的圆形控件是一套观感
          CoverArt({ url: this.cover, name: this.name, art: this.art, boxSize: 40, radius: 20 })

          Column({ space: 2 }) {
            Text(this.name)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_TEXT)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
            if (this.singer.length > 0) {
              Text(this.singer)
                .fontSize(11)
                .fontColor(C_TEXT_SUB)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .onClick(() => {
          this.onOpenPlayer();
        })

        if (this.status === 'loading') {
          // 切歌/缓冲期间转圈，不出声就不显示成播放中
          LoadingProgress()
            .width(22)
            .height(22)
            .color('#17171A')
            .onClick(() => {
              PlaySession.getInstance().toggle();
            })
        } else {
          IconGlyph({
            symbol: this.status === 'playing' ? I_PAUSE_CIRCLE : I_PLAY_CIRCLE,
            iconSize: 28,
            color: '#17171A',
          })
            .onClick(() => {
              PlaySession.getInstance().toggle();
            })
        }
        IconGlyph({ symbol: I_NEXT, iconSize: 25, color: C_TEXT })
          .onClick(() => {
            PlaySession.getInstance().next();
          })
        IconGlyph({ symbol: I_QUEUE, iconSize: 23, color: C_TEXT })
          .onClick(() => {
            this.onOpenQueue();
          })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 14 })
    } else {
      // 折叠态：一颗黑色唱片圆钮（和右侧那颗悬浮专辑钮长得一样）
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(30)
          .backgroundColor('#0B0B0C')
        CoverArt({ url: this.cover, name: this.name, art: this.art, boxSize: 42, radius: 21 })
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
  }
}
