import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo } from '../core/music/MusicSearch';
import { COMMENT_PAGE_SIZE, CommentKind, CommentPage, LxComment, commentsSupported, dedupeComments,
  fetchComments } from '../core/music/PlatformComment';
import { I_CHEVRON_LEFT, I_COMMENT, I_REFRESH, I_THUMB_UP, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState } from '../ui/Widgets';

const DOMAIN: number = 0x0001;
const TAG: string = 'CommentSheet';

/** 主评论正文超过这个字数就折起来（洛雪是 160，这里同量级） */
const TEXT_LIMIT: number = 140;

/** 评论页配色：跟着全屏播放器走（那个页面是深色的，评论盖在它上面） */
const C_PANEL_BG: string = '#0C0C0E';
const C_PANEL_TEXT: string = '#F2FFFFFF';
const C_PANEL_SUB: string = '#8CFFFFFF';
const C_PANEL_WEAK: string = '#5EFFFFFF';
const C_PANEL_LINE: string = '#1FFFFFFF';

/**
 * 评论页
 *
 * 对应洛雪的评论页（`src/screens/Comment/`）：头部是「「歌名」的评论」，
 * 下面「热门 / 最新」两个页签各一条分页列表（每页 15 条，拉到底是「上拉加载更多」），
 * 页签右边一颗刷新钮。
 *
 * 两处与洛雪不同的地方，都是为了贴合本工程的界面结构：
 *   1. **不走路由**：洛雪是 push 一个独立 screen。这里播放器本身是系统的半模态
 *      （见 PlayerView 开头的说明），再往上压系统弹层容易打架，所以和「更多」「匹配歌词」
 *      一样自绘一层铺满的覆盖物。
 *   2. **切歌就收起**：洛雪遇到切歌是提示一句「这已经是「X」的评论啦」等着用户自己点刷新。
 *      这里在播放器里监听当前歌变化，直接收起这一层 —— 少一种「屏幕上显示的是谁的评论」的困惑。
 *
 * 数据来自 `core/music/PlatformComment`（内置平台接口），与音源无关：
 * 洛雪的源协议里根本没有「取评论」这个 action，所以这条路是唯一的一条。
 */
@Component
export struct CommentSheet {
  @Prop songName: string = '';
  @Prop bottomInset: number = 0;
  /**
   * 这首歌是不是「需要先匹配」的本地音乐 / 云端音乐
   *
   * 只影响提示文案：本地歌与云端歌得先匹配到平台上的那一首才有评论，
   * 这句话得说清楚，否则用户只会看到「看不到评论」而不知道该干什么。
   */
  @Prop needsMatch: boolean = false;
  /**
   * 取当前歌的平台身份（musicInfo JSON，空串 = 拿不到）
   *
   * 在线歌是同步就有的；本地歌 / 云端歌可能要先联网匹配一次，所以这里设计成异步回调，
   * 由播放会话（`PlaySession.platformIdentityOf`）去解析 —— 评论页自己不该知道
   * 「本地歌怎么匹配」这件事。
   */
  onResolveTarget: () => Promise<string> = () => Promise.resolve('');
  onClose: () => void = () => {
  };
  /** 0 = 热门，1 = 最新（与洛雪的两个页签一致，默认停在热门） */
  @State kindIndex: number = 0;
  @State comments: LxComment[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  /** 已经拉过的最后一页 */
  @State page: number = 0;
  @State maxPage: number = 1;
  @State error: string = '';
  /** 两个页签各自的总数（洛雪把总数写在页签文字里） */
  @State hotTotal: number = 0;
  @State newTotal: number = 0;
  /** 解析出来的平台身份（musicInfo JSON），空串 = 这首歌没有 */
  @State targetJson: string = '';
  /** 正在解析平台身份（本地歌 / 云端歌可能要联网匹配一次） */
  @State resolving: boolean = true;
  /** 每次切歌 / 换页签发一个 token，晚回来的旧响应直接丢掉 */
  private token: number = 0;

  aboutToAppear(): void {
    void this.start();
  }

  /**
   * 先解析出平台身份，再拉第一页评论
   *
   * 在线歌这一步是瞬时的（条目自带 musicInfo）；本地歌 / 云端歌可能要联网匹配，
   * 所以这两件事分成两个阶段，界面分别给「正在准备」和「正在加载评论」两种提示。
   */
  private async start(): Promise<void> {
    this.resolving = true;
    try {
      this.targetJson = await this.onResolveTarget();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolve target failed: %{public}s', (e as Error).message);
      this.targetJson = '';
    }
    this.resolving = false;
    if (this.targetJson.length > 0) {
      void this.load(1, false);
    }
  }

  private kind(): CommentKind {
    return this.kindIndex === 0 ? 'hot' : 'new';
  }

  /** 当前歌的平台身份：没有（本地歌没匹配上 / 平台不支持）就返回 null */
  private target(): LxMusicInfo | null {
    if (this.targetJson.length === 0) {
      return null;
    }
    try {
      const info: LxMusicInfo = JSON.parse(this.targetJson) as LxMusicInfo;
      return commentsSupported(info.source) ? info : null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse musicInfo failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /** 「看不到评论」时到底为什么：能说得具体就具体，用户才知道下一步做什么 */
  private unsupportedText(): string {
    // 先看「有没有平台身份」：「匹配到了但那个平台没有评论接口」与「根本没匹配到」
    // 是两件事，提示也该不一样
    if (this.targetJson.length > 0) {
      return '这个平台看不到评论';
    }
    if (this.needsMatch) {
      return '这首歌还没匹配到平台上的版本';
    }
    return '这首歌看不到评论';
  }

  private unsupportedHint(): string {
    if (this.targetJson.length > 0) {
      return '评论来自音乐平台，目前支持酷我、酷狗、QQ 音乐、咪咕与网易。';
    }
    if (this.needsMatch) {
      return '评论只存在于音乐平台上，本地音乐与云端音乐要先匹配到平台的那一首：' +
        '播放页「更多 - 匹配歌词」里搜一次并选中正确的版本，之后评论与歌词都会用它。';
    }
    return '评论来自音乐平台，目前支持酷我、酷狗、QQ 音乐、咪咕与网易。';
  }

  private async load(page: number, append: boolean): Promise<void> {
    const info: LxMusicInfo | null = this.target();
    if (info === null) {
      return;
    }
    if (append) {
      if (this.loadingMore || this.loading) {
        return;
      }
      this.loadingMore = true;
    } else {
      this.loading = true;
      this.error = '';
      this.page = 0;
    }
    const myToken: number = ++this.token;
    try {
      const result: CommentPage = await fetchComments(info, this.kind(), page, COMMENT_PAGE_SIZE);
      if (myToken !== this.token) {
        return;
      }
      this.comments = append ? dedupeComments(this.comments.concat(result.comments)) : result.comments;
      this.maxPage = result.maxPage;
      this.page = page;
      if (this.kind() === 'hot') {
        this.hotTotal = result.total;
      } else {
        this.newTotal = result.total;
      }
    } catch (e) {
      if (myToken !== this.token) {
        return;
      }
      const message: string = (e as Error).message;
      hilog.warn(DOMAIN, TAG, 'load comments failed: %{public}s', message);
      this.error = message;
    } finally {
      if (myToken === this.token) {
        this.loading = false;
        this.loadingMore = false;
      }
    }
  }

  private switchKind(index: number): void {
    if (this.kindIndex === index) {
      return;
    }
    this.kindIndex = index;
    this.comments = [];
    this.page = 0;
    this.maxPage = 1;
    void this.load(1, false);
  }

  /** 还有没有下一页：按平台给的 maxPage 判断（洛雪同口径） */
  private hasMore(): boolean {
    return this.comments.length > 0 && this.page < this.maxPage;
  }

  private tabLabel(label: string, total: number): string {
    return total > 0 ? `${label} (${total})` : label;
  }

  @Builder
  tabItem(index: number, label: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.kindIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.kindIndex === index ? '#FFFFFFFF' : C_PANEL_SUB)
      // 选中态下面那条短线（洛雪是换文字颜色，这里多加一条线更好认）
      Column()
        .width(this.kindIndex === index ? 18 : 0)
        .height(2)
        .borderRadius(1)
        .backgroundColor('#FFFFFFFF')
    }
    .height(38)
    .padding({ left: 12, right: 12 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchKind(index);
    })
    .accessibilityText(label)
    .accessibilityLevel('yes')
  }

  @Builder
  header() {
    Row() {
      IconGlyph({ symbol: I_CHEVRON_LEFT, iconSize: 22, color: C_PANEL_TEXT })
        .onClick(() => {
          this.onClose();
        })
        .padding({ left: 6, right: 10, top: 6, bottom: 6 })
        .accessibilityText('返回')
        .accessibilityLevel('yes')

      Text(this.songName.length > 0 ? `「${this.songName}」的评论` : '评论')
        .fontSize(16)
        .fontColor(C_PANEL_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      IconGlyph({ symbol: I_REFRESH, iconSize: 20, color: C_PANEL_SUB })
        .onClick(() => {
          void this.load(1, false);
        })
        .padding({ left: 10, right: 6, top: 6, bottom: 6 })
        .accessibilityText('刷新评论')
        .accessibilityLevel('yes')
    }
    .width('100%')
    .height(50)
    .padding({ left: 6, right: 6 })
  }

  @Builder
  tabs() {
    Row() {
      this.tabItem(0, this.tabLabel('热门', this.hotTotal))
      this.tabItem(1, this.tabLabel('最新', this.newTotal))
      Blank()
    }
    .width('100%')
    .padding({ left: 6, right: 12 })
  }

  @Builder
  footer() {
    if (this.error.length > 0) {
      Column({ space: 6 }) {
        Text(this.error)
          .fontSize(13)
          .fontColor(C_PANEL_WEAK)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text('点击重试')
          .fontSize(13.5)
          .fontColor('#FFFFFFFF')
          .onClick(() => {
            // page = 0 表示第一页就没拉起来（重试第一页），否则重试「下一页」
            void this.load(this.page + 1, this.page > 0);
          })
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
    } else if (this.hasMore()) {
      Text(this.loadingMore ? '正在加载更多…' : '上拉加载更多')
        .fontSize(13)
        .fontColor(C_PANEL_WEAK)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
    } else if (this.comments.length > 0) {
      Text(`共 ${this.comments.length} 条`)
        .fontSize(12.5)
        .fontColor(C_PANEL_WEAK)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
    }
  }

  @Builder
  body() {
    if (this.resolving) {
      Text(this.needsMatch ? '正在匹配这首歌的平台版本…' : '正在准备评论…')
        .fontSize(13.5)
        .fontColor(C_PANEL_SUB)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 40 })
    } else if (this.target() === null) {
      EmptyState({
        icon: I_COMMENT,
        text: this.unsupportedText(),
        hint: this.unsupportedHint(),
      })
    } else if (this.loading && this.comments.length === 0 && this.error.length === 0) {
      Text('正在加载评论…')
        .fontSize(13.5)
        .fontColor(C_PANEL_SUB)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 40 })
    } else if (this.comments.length === 0 && this.error.length === 0) {
      EmptyState({ icon: I_COMMENT, text: '还没有人评论', hint: '来听这首歌的人还不多，过些时候再看看。' })
    } else {
      List() {
        ForEach(this.comments, (item: LxComment) => {
          ListItem() {
            CommentRow({ comment: item })
          }
        }, (item: LxComment) => item.id)

        ListItem() {
          this.footer()
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .onReachEnd(() => {
        if (this.hasMore() && !this.loadingMore && !this.loading && this.error.length === 0) {
          void this.load(this.page + 1, true);
        }
      })
    }
  }

  build() {
    Column() {
      this.header()
      if (this.target() !== null) {
        this.tabs()
      }
      this.body()
      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_PANEL_BG)
  }
}

/**
 * 一条评论（含楼中楼）
 *
 * 长文默认折起来：平台上随手写的长评不少，整段铺开会把列表拉得没法扫。
 */
@Component
struct CommentRow {
  @Prop comment: LxComment;
  /** 楼中楼（缩进一层），字号与头像都小一号 */
  @Prop nested: boolean = false;
  @State expanded: boolean = false;

  private tooLong(): boolean {
    return this.comment.text.length > TEXT_LIMIT;
  }

  private shownText(): string {
    if (!this.tooLong() || this.expanded) {
      return this.comment.text;
    }
    return `${this.comment.text.substring(0, TEXT_LIMIT)}…`;
  }

  @Builder
  meta() {
    Row({ space: 8 }) {
      Text(this.comment.userName)
        .fontSize(this.nested ? 13.5 : 14.5)
        .fontColor(C_PANEL_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.comment.likedCount >= 0) {
        Row({ space: 3 }) {
          IconGlyph({ symbol: I_THUMB_UP, iconSize: 12, color: C_PANEL_WEAK })
          Text(String(this.comment.likedCount))
            .fontSize(12)
            .fontColor(C_PANEL_WEAK)
        }
        .accessibilityLevel('no')
      }
    }
    .width('100%')
  }

  @Builder
  subLine() {
    if (this.comment.timeStr.length > 0 || this.comment.location.length > 0) {
      Row({ space: 10 }) {
        if (this.comment.timeStr.length > 0) {
          Text(this.comment.timeStr)
            .fontSize(11.5)
            .fontColor(C_PANEL_WEAK)
        }
        if (this.comment.location.length > 0) {
          Text(`IP属地：${this.comment.location}`)
            .fontSize(11.5)
            .fontColor(C_PANEL_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ top: 3 })
    }
  }

  @Builder
  images() {
    if (this.comment.images.length > 0) {
      // 固定方框 + Contain：评论图多是截图，裁掉两边会看不到原意；
      // 也不去量原始尺寸（那要异步等图片头），固定框最省事且不跳版
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.comment.images, (url: string) => {
          Stack({ alignContent: Alignment.Center }) {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#1FFFFFFF')
            Image(url)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }
          .width(this.nested ? 88 : 110)
          .height(this.nested ? 88 : 110)
          .borderRadius(8)
          .clip(true)
          .margin({ top: 8, right: 8 })
        }, (url: string) => url)
      }
      .width('100%')
    }
  }

  build() {
    Row({ space: 10 }) {
      CoverArt({
        url: this.comment.avatar,
        name: this.comment.userName,
        boxSize: this.nested ? 28 : 36,
        radius: this.nested ? 14 : 18,
      })

      Column() {
        this.meta()
        this.subLine()
        Text(this.shownText())
          .fontSize(this.nested ? 13.5 : 14.5)
          .fontColor(C_PANEL_TEXT)
          .lineHeight(this.nested ? 20 : 21)
          .width('100%')
          .padding({ top: 5 })
          .textAlign(TextAlign.Start)
        if (this.tooLong()) {
          Text(this.expanded ? '收起' : '展开')
            .fontSize(12.5)
            .fontColor(C_PANEL_SUB)
            .padding({ top: 4 })
            .onClick(() => {
              this.expanded = !this.expanded;
            })
            .accessibilityText(this.expanded ? '收起这条评论' : '展开这条评论')
            .accessibilityLevel('yes')
        }
        this.images()

        // 楼中楼：平台一般只给前几条
        if (this.comment.reply.length > 0) {
          Column() {
            ForEach(this.comment.reply, (reply: LxComment) => {
              CommentRow({ comment: reply, nested: true })
            }, (reply: LxComment) => reply.id)
          }
          .width('100%')
          .margin({ top: 10 })
          .padding({ top: 10 })
          .border({ width: { top: 0.6 }, color: C_PANEL_LINE, style: BorderStyle.Dashed })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 14, bottom: 14 })
    .border({ width: { bottom: 0.6 }, color: C_PANEL_LINE, style: BorderStyle.Dashed })
  }
}
