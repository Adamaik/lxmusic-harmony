import { PlaySession } from '../core/player/PlaySession';
import { K_BUFFERING, K_CURRENT_COVER, K_CURRENT_ID, K_CURRENT_NAME, K_CURRENT_SINGER,
  K_DURATION, K_MINI_EXPANDED, K_PLAYER_STATUS, K_PROGRESS } from '../core/player/PlaySession';
import { C_ICON, C_ICON_CIRCLE, C_RED, C_SLIDER_TRACK, C_TEXT, C_TEXT_SUB } from '../ui/Theme';
import { I_NEXT, I_PAUSE_CIRCLE, I_PLAY_CIRCLE, I_QUEUE, IconGlyph } from '../ui/Icons';
import { CoverStore } from '../core/music/CoverStore';
import { BAR_TWO_ROWS, K_BAR_LAYOUT } from '../ui/BottomBar';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 折叠态封面边长：HDS 折叠时只给一颗圆钮的宽度，封面要正好填满 */
const COVER_COLLAPSED: number = 56;
/** 展开态封面边长：让出位置给歌名与三个控制钮 */
const COVER_EXPANDED: number = 44;
/**
 * 底栏处于「上下两排」时的封面边长
 *
 * 两排时迷你条只占上面那一排（高度就是栏高，宽裕度与单排的整条通栏完全不同），封面按展开态
 * 那 44 画会显得压住那一排 —— 派音的 `HomeMiniBarAlbumCover` 同款处理：两排时封面收到 30vp
 * （并左移一点）。想再紧/松就改这一个数。
 */
const COVER_TWO_ROW: number = 30;
/**
 * 页内那条（详情页 / 面板页）胶囊的**实际**高度：48vp
 *
 * 我们给那些 Tabs 声明了 `barHeight(HDS_BAR_HEIGHT)`（56），但 **ArkUI 的悬浮栏不认**，
 * 它按自己那套画 48 高的胶囊 —— 那一页封面（44）上下只剩 (48 − 44) / 2 = **2vp**。
 * 左留白必须跟这个 2vp 对齐，而不是按声明值 56 推出来的 6：用户反馈「左边大概是上下方向的
 * 两倍」，正是因为按 56 推、把左留白给成了 4~6。页签里那条走 HDS 的迷你栏（真 56），另算。
 */
const IN_PAGE_CAPSULE: number = 48;
/**
 * 进度环的描边宽度（vp）—— 它压在封面圆边上，肉眼看到的圆比封面图本身大这一圈
 *
 * 算「封面到自己上下边的距离」时要按**看得见的圆**（封面 + 这圈描边）算：
 * 页内那条 48 胶囊里，44 的封面其实只剩 (48 − 44 − 1.8) / 2 ≈ 1.1vp 的留白，
 * 按 44 算成 2 就会偏宽一点（用户反馈「变窄了一点点，但还是左边比上下宽」）。
 */
const RING_STROKE: number = 1.8;
/** ArkUI 悬浮胶囊自己的内边距（每侧，vp）：48 的胶囊里内容盒只剩 ≈44 */
const IN_PAGE_INSET: number = 2;

/** 折叠态封面在迷你栏里的上下留白（栏高 56 = 6 + 44 + 6 是展开态的口径，折叠态同值） */
const COVER_INSET_V: number = 6;
/** 控制钮图标大小与间距（与派音 HomeMiniBarPlayerAside 一致） */
const CONTROL_SIZE: number = 24;
const CONTROL_GAP: number = 16;
/**
 * 页内那条（挂在 Tabs 悬浮栏里）内容的**右**留白
 *
 * 左留白现在由实测格高推（见 sideInset / contentVerticalGap）：它要等于封面到自己上下边的
 * 距离。右端仍用这个数 —— 右边是三个控制钮，按「与上下留白相等」推出来的会大得多
 * （≈16），而页内这条早先就因为它显空被调小过（实机反馈「迷你播放器里面的左右两边的空白
 * 有点大」），所以保持紧凑；页签里那条（HDS 的格子）另算，见 sideInsetEnd。
 *
 * 4vp 不会被胶囊端部的圆角切到：控制钮/封面都在胶囊中部，胶囊高 56（端部是 r=28 的半圆）。
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
  /**
   * 迷你条那一格的**实测**高度（vp，0 = 还没量到）
   *
   * 只给「上下两排」用：HDS 给的那一格就是看得见的那一排，它比栏高矮不少（≈35），
   * 用户已确认按实测推出来的留白（≈2.5）才是对的；按名义 56 推会得到 13（那个数早先被否掉过）。
   */
  @State barCellHeight: number = 0;
  /** 底栏现在是「上下两排」还是「单排」（ui/BottomBar.ets 是状态源）：两排时封面要缩小 */
  @StorageLink(K_BAR_LAYOUT) barLayout: number = BAR_TWO_ROWS;

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
  /** 这张封面**按地址**加载失败了（地址过期 / 断网）：退回应用图标兜底，见 showAppIcon */
  @State coverFailed: boolean = false;

  /** 当前是否按展开态排版（页签里由 HDS 定，页内那条恒为展开） */
  private isExpanded(): boolean {
    return this.forceExpanded || this.expanded;
  }

  aboutToAppear(): void {
    hilog.info(0x0001, 'MiniBar', 'enter: %{public}s', `force=${this.forceExpanded}`
      + ` twoRows=${this.barsTwoRows()} expanded=${this.isExpanded()} cover=${this.coverSide()}`
      + ` cell=${this.barCellHeight} left=${this.sideInset()} right=${this.sideInsetEnd()}`
      + ` window=${this.windowWidth}`);
    // 先把当前这首的封面解成位图：切页签时 HDS 会重建迷你栏，有现成的位图就不会
    // 重新加载那一趟（见 CoverStore.pixelFor 的说明）
    CoverStore.getInstance().preloadPixel(this.cover);
  }

  /** 换歌了：新封面的位图也提前解出来；上一首加载失败不算这一首的（同 CoverArt 的 onUrlChanged） */
  onCoverChanged(): void {
    this.coverFailed = false;
    CoverStore.getInstance().preloadPixel(this.cover);
  }

  /**
   * 要不要显示应用图标兜底
   *
   * **只认「确实没有封面」两种情况**：没有地址（没在放 / 这首歌本来就没图）、
   * 或这张地址已经确认加载失败。**加载中不算** —— 见 coverView 上那段说明：
   * 拿应用图标当加载占位，重建出来的那一帧露的就是它。
   */
  private showAppIcon(): boolean {
    return this.cover.length === 0 || this.coverFailed;
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

  /** 底栏是不是「上下两排」（页内那条 forceExpanded 不参与：它不在页签体系里） */
  private barsTwoRows(): boolean {
    return !this.forceExpanded && (this.barLayout ?? BAR_TWO_ROWS) === BAR_TWO_ROWS;
  }

  /** 圆封面边长：上下两排 30、展开 44、折叠（单排那颗圆钮）56 */
  private coverSide(): number {
    if (this.barsTwoRows()) {
      return COVER_TWO_ROW;
    }
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
    // 页内那条、上下两排、单排展开态：左留白一律取「封面到自己上下边的距离」，
    // 封面到左边缘就与它到上下边缘相等（页内那条原先写死 4、展开态写死 6，都是猜的数）。
    if (this.forceExpanded) {
      // 页内那条：胶囊 48，且要按「封面 + 进度环」这个看得见的圆算
      return this.inPageCoverGap();
    }
    if (this.barsTwoRows() || this.isExpanded()) {
      return this.coverVerticalGap();
    }
    return sideInsetFor(this.windowWidth);
  }

  /** 右侧留白：同上，页内那条用同一个数（左右对称） */
  private sideInsetEnd(): number {
    if (this.forceExpanded) {
      return FORCE_EXPANDED_SIDE_INSET;
    }
    if (this.barsTwoRows()) {
      // 两排：右留白 = 控制钮到自己上下边的距离，与它上下的留白相等
      return this.contentVerticalGap(CONTROL_SIZE);
    }
    return this.isExpanded() ? 16 : sideInsetFor(this.windowWidth);
  }

  /**
   * 那一格**看得见**的高度（vp）：按**宿主**取常数，不再实测
   *
   * - 页内那条（详情页 / 面板页）：宿主是 **ArkUI 的悬浮栏**，它画的胶囊是 **48**（我们自己
   *   声明的 `barHeight(56)` 它不认）→ 封面 44 上下只剩 (48 − 44) / 2 = 2vp；
   * - 页签里那条：宿主是 **HDS 的迷你栏格子**，就是 **56**（「两排」那组数已经验证过按它算）。
   *
   * 实测（`onAreaChange`）试过两轮，真机上给出的格高一会儿 35、一会儿整页（宿主不同、重建时机
   * 都会影响），不可信；宿主是谁我们本来就知道，直接取常数最稳。
   */
  private visibleCellHeight(): number {
    // 实测格高优先（任何宿主：HDS 的迷你栏格子 / ArkUI 的悬浮胶囊，量到的就是看得见的那一格）
    if (this.barCellHeight > 0 && this.barCellHeight <= 120) {
      return this.barCellHeight;
    }
    // 量不到时的兜底：页内那条按 ArkUI 自己的 48，页签里那条按 HDS 的 56
    return this.forceExpanded ? IN_PAGE_CAPSULE : HDS_BAR_HEIGHT;
  }

  /**
   * 页内那条（详情页 / 面板页）封面到上下边的距离
   *
   * 宿主是 ArkUI 的悬浮栏，胶囊 48（我们声明的 barHeight(56) 它不认）；而**看得见的圆**
   * 是封面 + 进度环那圈描边 → (48 − 44 − 1.8) / 2 ≈ 1.1vp。左留白取它。
   */
  private inPageCoverGap(): number {
    // 这一格实测 48（真机日志 cell=48），封面 44 + 进度环 45.8 → 几何余量不到 1vp。
    // 几何上左右已经没差，剩下的差是**视觉**的：胶囊左端是圆弧，眼睛看到的空白比几何值大，
    // 所以取 0 —— 封面直接贴住胶囊左端，让它自己当那个左端圆（派音「左圆 + 右长条」的观感）。
    // 若哪天真机上 0 显窄，就取 1（半个环宽）。
    return 0;
  }

  /**
   * 高度为 `side` 的元素，到容器**上下边**的实际距离（vp）
   *
   * 内容在容器里垂直居中，上下还有一层内边距：
   *   放得下 → 内边距 + 居中后的余量：padV + (格高 − 2·padV − side) / 2
   *   放不下（元素比内容盒还高）→ 居中会把元素往两边溢出去，那一层内边距实际被吃掉，
   *                              剩下的只有 (格高 − side) / 2 —— 详情页那条（44 封面在 48 格子里）
   *                              走的正是这一支，得到 2vp。
   * 左右留白取这个数，元素到左右边缘就与它到上下边缘一致。
   */
  private contentVerticalGap(side: number): number {
    const padV: number = this.barsTwoRows() ? 0 : COVER_INSET_V;
    const cell: number = this.visibleCellHeight();
    const inner: number = cell - padV * 2;
    if (inner >= side) {
      return padV + (inner - side) / 2;
    }
    return Math.max(0, (cell - side) / 2);
  }

  /**
   * 封面到自己上下边的距离（左留白取它，见 sideInset）
   *
   * 由宿主胶囊高度与封面尺寸推出（见 contentVerticalGap）：
   *   页内那条：44 封面在 48 胶囊里 → 2vp
   *   页签里那条：44 封面在 56 格子里 → 6vp；两排时 30 封面 → (格高−30)/2
   */
  private coverVerticalGap(): number {
    return this.contentVerticalGap(this.coverSide());
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
   *
   * 现在的画法：淡圆底 +（**确实没有封面时**才有的）应用图标 + 真封面，三层都是圆的。
   *
   * **加载期间露的必须是圆底，不能是应用图标**（这一条是用户反馈「切页签时那颗圆会跳回
   * 聆听的应用图标、再闪一下才变回封面」的成因）：重建出来的那一帧真封面画不出来时，
   * 看见的就是它底下那层 —— 底下垫应用图标的话，那一帧是「应用图标」，看着像播放器
   * 被重置了；垫圆底的话只是一闪而过的底色，几乎看不出来。全屏播放器那边早就是这条口径
   * （见 ui/Widgets.ets 的 CoverArt：**不给 Image 设 alt**，应用图标只在「没有封面」
   * 时出现，而不是当加载占位）。
   * 所以应用图标只在 `showAppIcon()` 为真（没有地址 / 地址已确认失效）时才画。
   */
  @Builder
  coverView() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(this.coverSide())
        .height(this.coverSide())
        .borderRadius(this.coverSide() / 2)
        .backgroundColor(C_ICON_CIRCLE)
      if (this.showAppIcon()) {
        Image($r('app.media.startIcon'))
          .width(this.coverSide())
          .height(this.coverSide())
          .objectFit(ImageFit.Cover)
          .borderRadius(this.coverSide() / 2)
          .draggable(false)
      }
      if (this.cover.length > 0 && !this.coverFailed) {
        Image(this.coverDrawable())
          .width(this.coverSide())
          .height(this.coverSide())
          .objectFit(ImageFit.Cover)
          .borderRadius(this.coverSide() / 2)
          .draggable(false)
          .onError(() => {
            // 地址过期 / 断网：这张图再也画不出来，退回应用图标（同 CoverArt 的处理）
            this.coverFailed = true;
          })
      }
      /**
       * 这里**不许**再挂 `transition`：迷你栏内容在每次切换页签时都会被 HDS 重建，
       * 新节点带上 insert 转场就会跟着淡入一次 —— 那是「切页签时封面闪一下」的来源之一。
       */
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
      // 两排时上下不给内边距：内容垂直居中后，它到上下边的距离就是 (格高 − 自身高) / 2，
      // 左右留白正是按这个数给的（见 twoRowInsetFor）——加了内边距两边就不相等了
      top: this.barsTwoRows() ? 0 : COVER_INSET_V,
      bottom: this.barsTwoRows() ? 0 : COVER_INSET_V,
    })
    // 量一下这一格的实际高度：只有「上下两排」会用到（见 barCellHeight / visibleCellHeight）
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const height: number = Number(newArea.height);
      if (height > 0 && height <= 120 && Math.abs(height - this.barCellHeight) >= 0.5) {
        this.barCellHeight = height;
        // 量到之后打一行：这一格的真实高度 + 由它算出的最终 left/right
        hilog.info(0x0001, 'MiniBar', 'measured: %{public}s', `force=${this.forceExpanded}`
          + ` cell=${height} cover=${this.coverSide()} left=${this.sideInset()}`
          + ` right=${this.sideInsetEnd()} window=${this.windowWidth}`);
      }
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
