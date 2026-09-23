import { PlaySession } from '../core/player/PlaySession';
import { K_BUFFERING, K_CURRENT_COVER, K_CURRENT_ID, K_CURRENT_NAME, K_CURRENT_SINGER,
  K_DURATION, K_MINI_EXPANDED, K_PLAYER_STATUS, K_PROGRESS } from '../core/player/PlaySession';
import { C_ICON, C_ICON_CIRCLE, C_RED, C_SLIDER_TRACK, C_TEXT, C_TEXT_SUB } from '../ui/Theme';
import { I_NEXT, I_PAUSE_CIRCLE, I_PLAY_CIRCLE, I_QUEUE, IconGlyph } from '../ui/Icons';
import { CoverStore } from '../core/music/CoverStore';
import { image } from '@kit.ImageKit';

/** 折叠态封面边长：HDS 折叠时只给一颗圆钮的宽度，封面要正好填满 */
const COVER_COLLAPSED: number = 56;
/** 展开态封面边长：让出位置给歌名与三个控制钮 */
const COVER_EXPANDED: number = 44;
/** 折叠态封面在迷你栏里的上下留白（栏高 56 = 6 + 44 + 6 是展开态的口径，折叠态同值） */
const COVER_INSET_V: number = 6;
/** 控制钮图标大小与间距（与派音 HomeMiniBarPlayerAside 一致） */
const CONTROL_SIZE: number = 24;
const CONTROL_GAP: number = 16;
/**
 * 页内那条（挂在 Tabs 悬浮栏里）内容的左右留白
 *
 * 页签里那条是左 6 / 右 16 —— 那组数是配 **HDS 迷你栏格子**的：HDS 在格子里自己还会留一层，
 * 我们再加 16 正好。页内这条的胶囊是 Tabs 自己画的（ArkUI 悬浮栏），格子里没有那层内边距，
 * 再照抄 16 右端就空了（实机反馈「迷你播放器里面的左右两边的空白有点大」），
 * 所以这里取官方 HDS 迷你栏示例里的 4vp（示例里封面就是 `margin({left:4,right:4})`）。
 *
 * 4vp 不会被胶囊端部的圆角切到：封面是直径 44 的**圆**、胶囊高 56（端部是 r=28 的半圆），
 * 两者同心（都是垂直居中），同心圆只要半径和 ≤ 28 就完全在内 —— 4 + 22 = 26 < 28。
 * 想再松/紧一点就改这一个数（越大越松）。
 */
const FORCE_EXPANDED_SIDE_INSET: number = 4;
/** 歌名 / 歌手字号与行高（与派音一致） */
const TITLE_SIZE: number = 12;
const TITLE_LINE: number = 16;
const SINGER_SIZE: number = 10;
const SINGER_LINE: number = 13;

/**
 * 折叠态迷你栏内容与栏边的留白，按窗口宽度分档
 *
 * 与派音的断点口径一致（`BreakpointType(16, 24, 32, 32)`）：
 * < 600vp 给 16、600–840vp 给 24、≥ 840vp 给 32。
 */
function sideInsetFor(windowWidth: number): number {
  if (windowWidth >= 840) {
    return 32;
  }
  if (windowWidth >= 600) {
    return 24;
  }
  return 16;
}

/**
 * HdsTabs 迷你栏（MiniBar）的内容
 *
 * HDS 的悬浮页签栏右边会跟一条「迷你栏」，结构照派音（RzdMusic）的
 * `HomeMiniBarPlayer` 搬过来：
 *   圆封面（外圈一圈播放进度环，播放中叠一颗跳动符）+ 歌名/歌手 + 三个控制钮。
 * 折叠与展开**画的是同一份内容**，只有封面尺寸和留白不同：
 *   - 折叠：封面 56（正好填满 HDS 给的那颗圆钮），左右留白按窗口宽度分档；
 *   - 展开：封面 44，右边留给歌名和控制钮。
 * 多宽、裁哪里都由 HDS 按形态自己算（`enableMiniBarClip` 默认就是开的），
 * 所以折叠态看到的就是那颗圆封面本身，不需要我们再画一层「唱片圆钮」的底
 * —— 之前那层近黑圆底压在深色页签栏上会糊成一片，和派音也不一致。
 *
 * 「展开/折叠」只从 AppStorage 读（HDS 的 onBarStyleChange 写进去），
 * 这样即使 builder 不被重新调用，内容也会跟着变。
 */
@Component
export struct MiniBarView {
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  /**
   * 页内那条迷你栏
   *
   * 页签体系里的迷你栏由 HDS 管展开/折叠（形态从 K_MINI_EXPANDED 读）；
   * 歌单详情这类不在页签里的页面单独挂一条迷你栏（外面已经裹了一层玻璃胶囊，
   * 左右各留 12），它恒为展开态，且不重复给左右边距。
   */
  @Prop forceExpanded: boolean = false;
  /** 窗口宽度（vp）；0 = 还没量到，按手机档给留白 */
  @Prop windowWidth: number = 0;
  @StorageLink(K_MINI_EXPANDED) expanded: boolean = false;
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_CURRENT_NAME) name: string = '';
  @StorageLink(K_CURRENT_SINGER) singer: string = '';
  @StorageLink(K_CURRENT_COVER) @Watch('onCoverChanged') cover: string = '';
  @StorageLink(K_PLAYER_STATUS) status: string = 'idle';
  /** 弱网下播放器在等数据：状态仍是 playing，但要显示成转圈（见 PlaySession.onPlayerBuffer） */
  @StorageLink(K_BUFFERING) buffering: boolean = false;
  /** 已播秒数 / 总秒数：封面外圈那圈进度环用 */
  @StorageLink(K_PROGRESS) progress: number = 0;
  @StorageLink(K_DURATION) duration: number = 0;

  /** 当前是否按展开态排版（页签里由 HDS 定，页内那条恒为展开） */
  private isExpanded(): boolean {
    return this.forceExpanded || this.expanded;
  }

  aboutToAppear(): void {
    // 先把当前这首的封面解成位图：切页签时 HDS 会重建迷你栏，有现成的位图就不会
    // 重新加载那一趟（见 CoverStore.pixelFor 的说明）
    CoverStore.getInstance().preloadPixel(this.cover);
  }

  /** 换歌了：新封面的位图也提前解出来 */
  onCoverChanged(): void {
    CoverStore.getInstance().preloadPixel(this.cover);
  }

  /**
   * 真封面要画的那张图
   *
   * 内存里有解好的位图就用它（同步绘制，重建迷你栏时不会先黑一下再亮起来），
   * 没有就按地址加载 —— CoverStore 在后台解一张，下一次重建就命中了。
   */
  private coverDrawable(): PixelMap | string {
    const pixel: image.PixelMap | undefined = CoverStore.getInstance().pixelFor(this.cover);
    return pixel !== undefined ? pixel : this.cover;
  }

  /** 圆封面边长：折叠 56、展开 44 */
  private coverSide(): number {
    return this.isExpanded() ? COVER_EXPANDED : COVER_COLLAPSED;
  }

  /**
   * 迷你栏内容与栏边的留白
   *
   * 页签里那条由 HDS 定形态（折叠 / 展开），页内那条（forceExpanded）恒为展开态。
   * 但**页内那条的左右留白不能照抄页签里那条**（6/16）：两边的胶囊不是同一套实现 ——
   * HDS 的迷你栏格子里自己还有一层内边距，ArkUI 悬浮栏格子里没有，照抄 16 就空了。
   * 见 FORCE_EXPANDED_SIDE_INSET 的说明。
   */
  private sideInset(): number {
    if (this.forceExpanded) {
      return FORCE_EXPANDED_SIDE_INSET;
    }
    return this.isExpanded() ? 6 : sideInsetFor(this.windowWidth);
  }

  /** 右侧留白：同上，页内那条用同一个数（左右对称） */
  private sideInsetEnd(): number {
    if (this.forceExpanded) {
      return FORCE_EXPANDED_SIDE_INSET;
    }
    return this.isExpanded() ? 16 : sideInsetFor(this.windowWidth);
  }

  /**
   * 封面
   *
   * 三层叠在一起（照派音的 `HomeMiniBarAlbumCover`）：圆图 + 外圈进度环 + 播放中那颗跳动符，
   * 进度环走 OVERLAY 混合，压在封面上不挡图。
   *
   * 这里**刻意不用 `CoverArt`**：它给封面垫的是一块近黑的底（`#1C1C1E`），而迷你栏挂在
   * 悬浮栏上 —— 每次切换页签 HDS 都会把它整个重建一遍，重建出来的 `Image` 有一小段时间
   * 什么也画不出来（封面地址是网络图，不是本地文件），露出来的就是那块近黑的底，
   * 于是表现为「切换页签时右边那颗封面先黑一下再亮起来」。
   * 派音那颗圆封面底下从来没有黑底，加载期间露的是它自带的默认封面，所以看不出这一下。
   *
   * 现在的画法：淡圆底 + **应用图标**（与锁屏媒体卡、播放器的兜底封面是同一张）垫在最下面，
   * 有封面地址再在上面画真封面。没有地址、或地址加载失败时，看到的就是那张默认封面
   * —— 与原来 `CoverArt({ appIcon: true })` 的兜底一致，只是不再经过那块黑底。
   */
  @Builder
  coverView() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.coverSide())
        .height(this.coverSide())
        .borderRadius(this.coverSide() / 2)
        .backgroundColor(C_ICON_CIRCLE)
      Image($r('app.media.startIcon'))
        .width(this.coverSide())
        .height(this.coverSide())
        .objectFit(ImageFit.Cover)
        .borderRadius(this.coverSide() / 2)
        .draggable(false)
      if (this.cover.length > 0) {
        Image(this.coverDrawable())
          .width(this.coverSide())
          .height(this.coverSide())
          .objectFit(ImageFit.Cover)
          .borderRadius(this.coverSide() / 2)
          .draggable(false)
      }
      if (this.duration > 0) {
        Progress({ value: this.progress, total: this.duration, type: ProgressType.Ring })
          .width(this.coverSide())
          .height(this.coverSide())
          .backgroundColor(C_SLIDER_TRACK)
          .color(C_RED)
          .style({ strokeWidth: '1.8vp' })
          .blendMode(BlendMode.OVERLAY)
      }
      if (this.status === 'playing' && !this.buffering) {
        SymbolGlyph($r('sys.symbol.rhythm'))
          .fontSize(CONTROL_SIZE)
          .fontWeight(FontWeight.Regular)
          .height(CONTROL_SIZE)
          .fontColor([C_TEXT])
      }
    }
  }

  /**
   * 歌名 / 歌手 / 控制钮
   *
   * 折叠态下这一整块会被 HDS 裁掉（HDS 只给一颗圆钮的宽度），不用自己判形态。
   */
  @Builder
  aside() {
    Column({ space: 0 }) {
      Text(this.name)
        .fontSize(TITLE_SIZE)
        .fontWeight(FontWeight.Bold)
        .lineHeight(TITLE_LINE)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.singer.length > 0) {
        Text(this.singer)
          .fontSize(SINGER_SIZE)
          .lineHeight(SINGER_LINE)
          .fontColor(C_TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpenPlayer();
    })
    .accessibilityGroup(true)
    .accessibilityText(this.singer.length > 0 ? `${this.name}，${this.singer}，打开播放页` : `${this.name}，打开播放页`)
    .accessibilityLevel('yes')

    Row({ space: CONTROL_GAP }) {
      if (this.status === 'loading' || this.buffering) {
        // 切歌 / 等数据期间转圈，不出声就不显示成播放中。
        // 颜色必须走主题 token：迷你栏是系统材质底，深色模式下底色是深的，
        // 写死的深色图标会整颗「消失」在底上
        LoadingProgress()
          .width(CONTROL_SIZE)
          .height(CONTROL_SIZE)
          .color(C_TEXT)
          .onClick(() => {
            PlaySession.getInstance().toggle();
          })
          .accessibilityText('暂停')
          .accessibilityLevel('yes')
      } else {
        IconGlyph({
          symbol: this.status === 'playing' ? I_PAUSE_CIRCLE : I_PLAY_CIRCLE,
          iconSize: CONTROL_SIZE,
          color: C_TEXT,
          replaceEffect: true,
        })
          .onClick(() => {
            PlaySession.getInstance().toggle();
          })
          .accessibilityText(this.status === 'playing' ? '暂停' : '播放')
          .accessibilityLevel('yes')
      }
      IconGlyph({ symbol: I_NEXT, iconSize: CONTROL_SIZE, color: C_ICON })
        .onClick(() => {
          PlaySession.getInstance().next();
        })
        .accessibilityText('下一首')
        .accessibilityLevel('yes')
      IconGlyph({ symbol: I_QUEUE, iconSize: CONTROL_SIZE, color: C_ICON })
        .onClick(() => {
          this.onOpenQueue();
        })
        .accessibilityText('播放列表')
        .accessibilityLevel('yes')
    }
  }

  build() {
    Row({ space: 8 }) {
      this.coverView()
      this.aside()
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
    // 留白照派音：展开态 6/16，折叠态左右按断点分档。
    // 页内那条（forceExpanded）左右用 FORCE_EXPANDED_SIDE_INSET —— 见 sideInset 的说明
    .padding({
      left: this.sideInset(),
      right: this.sideInsetEnd(),
      top: COVER_INSET_V,
      bottom: COVER_INSET_V,
    })
    // 上滑打开全屏播放器（派音同一处手势）；点击仍归 HDS 与各按钮
    .gesture(
      PanGesture({ direction: PanDirection.Vertical })
        .onActionEnd((event: GestureEvent) => {
          if (event.offsetY < -10) {
            this.onOpenPlayer();
          }
        })
    )
  }
}
