import { LxArtist, LxArtistDetail, LxArtistOrder, getArtistDetail, getArtistSongs } from '../core/music/MusicArtist';
import { LxSearchPage } from '../core/music/MusicSearch';
import { platformName } from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_PLAY_QUALITY } from '../core/settings/PlaySettings';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_ON_ACCENT, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK,
  F_SECTION, F_SUB, platformColor, platformTint } from '../ui/Theme';
import { CoverArt, EmptyState } from '../ui/Widgets';
import { I_PLAY, IconGlyph } from '../ui/Icons';
import { SongListPane } from './SongListPane';
import { MiniBarHost } from './MiniBarHost';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { CONTENT_MAX_WIDTH, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED, contentColumnsFor } from '../ui/Layout';

/** 每页取多少首：与搜索页同口径（50 首一页，滚到底再拉） */
const ARTIST_PAGE_LIMIT: number = 50;

/**
 * 歌手头像边长（vp）
 *
 * 2026-11-23 照华为音乐的歌手页重排时从 84 放大到 96：华为音乐那一页的头像是「这张脸的
 * 主体」，比列表行的封面大一整档；84 在 12.5vp 的统计文字旁边还是个「列表头」的比例，
 * 站不出歌手页的身份。96 = 名字（24vp，最多两行）加统计行的总高，圆头像正好压在左边。
 */
const ARTIST_AVATAR: number = 96;

/**
 * 歌手页 —— 「按歌手聚合」的结果页（2026-11-23 照华为音乐重做）
 *
 * 从一个歌手出发，把他在这个平台上的歌聚到一处：头部是歌手（头像 / 名字 / 单曲与专辑
 * 计数 / 简介），下面就是这个歌手的全部歌曲，滚到底自动接下一页。
 *
 * ## 2026-11-23 这一版为什么改（用户原话「歌手页面也照着华为音乐优化一下，太丑了」）
 *
 * 改之前的头部是「小头像 + 名字 + 一行统计 + 一颗灰底红字的胶囊」，问题有三处：
 *   1. 头像 84 与名字 22 都是列表头的比例，撑不起一个页面；
 *   2. 「播放全部」是 `C_FILL_SOFT` 的浅灰药丸 + 红字 —— 那套样式在本应用里是**标签**用的
 *      （平台标签、筛选 chip 都是它），看着像说明文字，不像这个页面的主操作；
 *   3. 排序「最热 / 最新」是两个各自带浅灰底的独立药丸，和「播放全部」并排时三个灰块
 *      分量一样，主次全平。
 *
 * 现在照华为音乐那一页重排（这是**只改长相、不改逻辑**的一次改动）：
 *   - 头像 96 正圆 + 名字 24 加粗，左对齐一条边（与下面每一行的左边缘对齐）；
 *   - 名字下面一行：平台小标签 + 「单曲 N · 专辑 M」的统计行；
 *   - 简介收到两行（原来三行，头部太高会把列表挤下去）；
 *   - 「播放全部」改成**红底反白 + 播放图标**的主按钮（`C_RED` + `C_ON_ACCENT`，
 *     与歌单详情那个「播放全部」同一个强调色，只是这里做成了真正的按钮）；
 *   - 「最热 / 最新」改成**一个分段控件**（一个浅灰槽里两块，选中那块浮出卡片底色），
 *     与主按钮拉开主次；不认排序的平台（酷我 / 咪咕）整块不出现，位置留给主按钮；
 *   - 列表上方补一行「热门歌曲 / 最新歌曲 · 共 N 首」的小标题（华为音乐那一页也有）。
 *
 * ## 有意没做的两件事
 *
 * 1. **不在页内自绘返回键**：这一页是 `HdsNavDestination`，返回键与标题栏是 HDS 画的
 *    （见 pages/Index.ets 的 PAGE_ARTIST 分支）。页内再画一颗就是两颗返回键 ——
 *    用户看到的华为音乐截图里那颗返回键也正是系统标题栏里的那颗。
 * 2. **不做「收藏歌手」**：洛雪的同步结构里没有「歌手」这个类型（见 docs/LX_SYNC.md），
 *    硬加会多出一种同步不出去的数据。歌还是 `SongItem`（由 `songFromSearch` 转），
 *    所以行上的收藏 / 下载 / 更多菜单、以及播放链路与其它列表完全共用。
 *
 * ## 数据与回调一个字都没动
 *
 * `getArtistDetail` / `getArtistSongs` 的取数、翻页、排序切换、打开播放器 / 播放列表 /
 * toast 全按原样保留，这次只重排 UI（含那一行分页状态文案）。
 */
@Component
export struct ArtistView {
  /** 歌手所属平台（kw / kg / mg / tx / wy） */
  @Prop source: string = '';
  @Prop artistId: string = '';
  /** tx 要 singerMID，其余平台留空（见 MusicArtist.LxArtist.mid） */
  @Prop artistMid: string = '';
  @Prop artistName: string = '';
  @Prop artistPicUrl: string = '';
  @Prop artistSongNum: number = 0;
  /** 让出标题栏那一段（壳层传来的「状态栏 + 标题栏」） */
  @Prop topInset: number = 0;
  /** 列表底部要留出的空间（手势条），由壳层给；页内那条迷你条的高度在这页自己补 */
  @Prop bottomInset: number = 0;
  @Prop currentId: string = '';
  /** 点迷你播放条 → 打开播放页 / 播放列表（与其它页同一个壳层回调） */
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  /** 排序：最热 / 最新（只有 kg / tx / wy 认这一项，见 sortable） */
  @State order: LxArtistOrder = 'hot';
  /**
   * 歌手详情（头像 / 名字 / 计数 / 简介）
   *
   * 初值给空对象而不是靠构造函数：ArkUI 的 struct 不支持自定义构造函数，
   * aboutToAppear 里再按路由参数铺一遍。
   */
  @State detail: LxArtistDetail = { name: '', picUrl: '', desc: '', songNum: 0, albumSize: 0 };
  @State songs: SongItem[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State page: number = 0;
  @State maxPage: number = 0;
  @State status: string = '';
  /**
   * 曲目自带的音质字段来自设置里的那一份（设置 - 播放设置 - 播放音质）
   *
   * 与搜索页一样：歌手歌曲多数平台不在列表里报音质档（酷我这条接口就没有），
   * 此时 `Quality.pickQuality` 会回到这一档，所以这里必须跟着设置走，不能写死。
   */
  @StorageLink(K_PLAY_QUALITY) quality: string = '128k';
  /**
   * 窗口宽度（vp）：宽屏下歌曲列表一屏多列（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  aboutToAppear(): void {
    // 先用路由带上来的那几项把头部铺出来（头像 / 名字立刻可见），详情回来再补齐简介与计数
    this.detail = {
      name: this.artistName,
      picUrl: this.artistPicUrl,
      desc: '',
      songNum: this.artistSongNum,
      albumSize: 0,
    };
    void this.loadDetail();
    void this.loadFirstPage();
  }

  /** 一屏几列（宽屏多列，窄屏 1 列，见 ui/Layout.ets） */
  private columns(): number {
    return contentColumnsFor(this.windowWidth);
  }

  /** 重建歌手对象：子页面只收基本类型（@Prop 传对象在多列/多实例下容易对不上身份） */
  private artist(): LxArtist {
    return {
      source: this.source,
      id: this.artistId,
      mid: this.artistMid,
      name: this.artistName,
      alias: '',
      picUrl: this.artistPicUrl,
      songNum: this.artistSongNum,
      albumSize: 0,
    };
  }

  /** 这个平台的歌手歌曲接口认不认「最热 / 最新」（酷我、咪咕那条接口只有一种顺序） */
  private sortable(): boolean {
    return this.source === 'kg' || this.source === 'tx' || this.source === 'wy';
  }

  private async loadDetail(): Promise<void> {
    const info: LxArtistDetail = await getArtistDetail(this.artist());
    // 详情接口没回名字/头像时（咪咕就是这样）保留路由带过来的那份，别把头部清空
    this.detail = {
      name: info.name.length > 0 ? info.name : this.artistName,
      picUrl: info.picUrl.length > 0 ? info.picUrl : this.artistPicUrl,
      desc: info.desc,
      songNum: info.songNum,
      albumSize: info.albumSize,
    };
  }

  private toItems(page: LxSearchPage): SongItem[] {
    const items: SongItem[] = [];
    for (const info of page.list) {
      items.push(songFromSearch(info, this.quality));
    }
    return items;
  }

  private async loadFirstPage(): Promise<void> {
    this.loading = true;
    this.status = '';
    try {
      const result: LxSearchPage = await getArtistSongs(this.artist(), 1, ARTIST_PAGE_LIMIT, this.order);
      this.songs = this.toItems(result);
      this.page = 1;
      this.maxPage = result.allPage;
      this.status = this.footerStatus();
    } catch (e) {
      this.songs = [];
      this.page = 0;
      this.maxPage = 0;
      this.status = `歌手歌曲加载失败：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  /** 列表滚到底 / 点尾部那一行：再拉一页（与搜索页同一套） */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore()) {
      return;
    }
    this.loadingMore = true;
    try {
      const result: LxSearchPage =
        await getArtistSongs(this.artist(), this.page + 1, ARTIST_PAGE_LIMIT, this.order);
      this.songs = this.songs.concat(this.toItems(result));
      this.page = this.page + 1;
      this.maxPage = result.allPage;
    } catch (e) {
      // 拉下一页失败不该把已经看到的那几页清掉：只把原因挂在状态行上
      this.status = `加载更多失败：${(e as Error).message}`;
    } finally {
      this.loadingMore = false;
      this.status = this.footerStatus();
    }
  }

  private hasMore(): boolean {
    return this.page > 0 && this.page < this.maxPage;
  }

  private footerStatus(): string {
    if (this.loadingMore) {
      return '正在加载更多…';
    }
    if (this.hasMore()) {
      return '上拉加载更多';
    }
    return this.songs.length > 0 ? `共 ${this.songs.length} 首` : '';
  }

  private async switchOrder(next: LxArtistOrder): Promise<void> {
    if (this.order === next) {
      return;
    }
    this.order = next;
    this.songs = [];
    this.page = 0;
    this.maxPage = 0;
    await this.loadFirstPage();
  }

  /** 头部「播放全部」：整页作为队列从第一首开始放 */
  private playAll(): void {
    if (this.songs.length === 0) {
      return;
    }
    void PlaySession.getInstance().setQueueAndPlay(this.songs, 0);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 统计文案：单曲 N · 专辑 M
   *
   * 哪一项没有就不写哪一项；**两项都没有时返回空串**（原来这里回退成平台名，而平台名
   * 现在由名字下面那颗小标签单独画 —— 两处并排会出现「酷狗 酷狗」）。
   * 空串时调用方整段不画，不会留一行空行。
   */
  private countText(): string {
    const parts: string[] = [];
    if (this.detail.songNum > 0) {
      parts.push(`单曲 ${this.detail.songNum}`);
    }
    if (this.detail.albumSize > 0) {
      parts.push(`专辑 ${this.detail.albumSize}`);
    }
    return parts.join(' · ');
  }

  /**
   * 列表上方那行小标题
   *
   * 照华为音乐：歌手页在歌曲列表前有一行「热门作品」这样的字。这里跟着排序态走
   * （最近 / 最新），不认排序的平台（酷我 / 咪咕）只有一种顺序，就叫「歌曲」——
   * 那时写「热门」是假的（接口没按热度排过）。
   */
  private sectionLabel(): string {
    if (!this.sortable()) {
      return '歌曲';
    }
    return this.order === 'hot' ? '热门歌曲' : '最新歌曲';
  }

  /**
   * 选中那块分段控件的底色
   *
   * 单独抽一个方法而不是在 @Builder 里写三元：三元的两支类型不同（`Resource` 与
   * `Color`），ArkTS 严格模式下对返回值的推断容易出联合类型告警；这里显式声明
   * `ResourceColor`，一处收敛。
   */
  private chipFill(value: LxArtistOrder): ResourceColor {
    return this.order === value ? C_CARD : Color.Transparent;
  }

  // ------------------------------------------------------------ 头部

  /**
   * 排序分段控件里的一格
   *
   * 选中态：卡片底色浮在浅灰槽上 + 主题红字；未选中：透明底 + 次要文字色。
   * 这是华为音乐那种分段控件的画法，与「播放全部」那颗红按钮的主次关系一眼可分。
   */
  @Builder
  sortChip(label: string, value: LxArtistOrder) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.order === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.order === value ? C_RED : C_TEXT_SUB)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.chipFill(value))
      .borderRadius(13)
      .onClick(() => {
        void this.switchOrder(value);
      })
      .accessibilityText(`按${label}排序`)
      .accessibilityLevel('yes')
  }

  /** 排序：两块装在一个浅灰槽里（不认排序的平台由调用方整块不画） */
  @Builder
  sortSegment() {
    Row() {
      this.sortChip('最热', 'hot')
      this.sortChip('最新', 'new')
    }
    .padding(2)
    .backgroundColor(C_FILL_SOFT)
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 主操作：「播放全部」
   *
   * 红底 + 反白字 + 播放图标 —— 这一页唯一的主按钮。改之前是浅灰底 + 红字，
   * 与旁边的排序 chip 同一种长相，用户在群里说的「太丑」有一半来自这个：
   * 主操作长得像标签，页面就没有落点。反白色走 `C_ON_ACCENT`（主题里那枚
   * 「压在强调色上的文字色」，深浅模式都保证可读），不写死白色。
   *
   * 没有歌时整颗按钮半透明（`opacity`）但**仍可点**：点了走 `playAll()` 的
   * 空判断什么也不做，比给一颗点不动的死按钮更不容易让人误会是卡住了。
   */
  @Builder
  playAllButton() {
    Row({ space: 6 }) {
      IconGlyph({ symbol: I_PLAY, iconSize: 15, color: C_ON_ACCENT })
        .accessibilityLevel('no')
      Text('播放全部')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_ON_ACCENT)
    }
    .height(38)
    .padding({ left: 18, right: 20 })
    .backgroundColor(C_RED)
    .borderRadius(19)
    .opacity(this.songs.length > 0 ? 1 : 0.45)
    .onClick(() => {
      this.playAll();
    })
    .accessibilityText('播放这个歌手的全部歌曲')
    .accessibilityLevel('yes')
  }

  /**
   * 头部：头像 + 名字 + 平台标签 + 统计 + 简介 + 主操作行
   *
   * 「左对齐要一致」这一条是照用户给的那张截图说的：头像、名字、统计、简介、主按钮
   * 全部压在同一条左边缘上（左右各 16，与下面每一行的内边距同值），页面上只有一条
   * 竖向对齐线，不会出现头像居中而文字靠左那种错位感。
   *
   * 返回键**不在这里**：由 `HdsNavDestination` 的标题栏提供（见 struct 开头第 1 条说明）。
   */
  @Builder
  header() {
    Column({ space: 12 }) {
      Row({ space: 16 }) {
        // 歌手头像是圆的：CoverArt 的 radius 给一半边长就是正圆
        CoverArt({
          url: this.detail.picUrl,
          name: this.detail.name,
          boxSize: ARTIST_AVATAR,
          radius: ARTIST_AVATAR / 2,
        })
        Column({ space: 9 }) {
          Text(this.detail.name.length > 0 ? this.detail.name : '歌手')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_TEXT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Row({ space: 8 }) {
            // 来源平台标签：聚合搜索去重后同一个人只留先问到的那个平台，标出来才知道
            // 下面这批歌是哪个站的（也才好理解「为什么只有这些歌」）
            Text(platformName(this.source))
              .fontSize(10.5)
              .fontColor(platformColor(this.source))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(platformTint(this.source))
              .flexShrink(0)
            // 统计行：单曲 N · 专辑 M（接口没给计数时整段不画，见 countText）
            if (this.countText().length > 0) {
              Text(this.countText())
                .fontSize(F_SUB)
                .fontColor(C_TEXT_SUB)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // 头像与右边那两块竖直居中：头像 96、右边名字最多两行，居中比顶对齐更稳
      .alignItems(VerticalAlign.Center)

      if (this.detail.desc.length > 0) {
        Text(this.detail.desc)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          // 两行封顶（原来三行）：头像放大之后头部本来就高了，简介再占三行会把
          // 歌曲列表挤到一屏只剩三四首，反而更难用
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Row({ space: 10 }) {
        this.playAllButton()
        if (this.sortable()) {
          Blank()
          this.sortSegment()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider().strokeWidth(0.6).color(C_DIVIDER)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: this.topInset + 8, bottom: 8 })
  }

  /** 列表上方那行小标题：热门歌曲 / 最新歌曲 + 共 N 首 */
  @Builder
  sectionTitle() {
    Row({ space: 8 }) {
      Text(this.sectionLabel())
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
      Blank()
      Text(`共 ${this.songs.length} 首`)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    /**
     * 页内挂一条迷你播放条（MiniBarHost）：这一页是压在路由栈上的 NavDestination，
     * 会把壳层那条带迷你栏的 HdsTabs 整个盖住 —— 不自己挂一条，进来就没有播放条
     * （群反馈 2026-11-19 11:33「这个界面有点突兀，看能不能把底部音乐栏加上去」）。
     *
     * 这条外壳与搜索页 / 本地音乐那几页用的 `PanePage` 是同一套实现（单页签 Tabs +
     * barFloatingStyle 拿系统材质；鸿蒙6 退回自绘玻璃胶囊），栏里那条迷你条本身就是
     * 全应用共用的 `MiniBarView`，所以几何、材质、点击行为与其它页完全一致。
     */
    MiniBarHost({
      windowWidth: this.windowWidth,
      bottomInset: this.bottomInset,
      onOpenPlayer: this.onOpenPlayer,
      onOpenQueue: this.onOpenQueue,
    }) {
      Column() {
        this.header()

        if (!this.loading && this.songs.length > 0) {
          this.sectionTitle()
        }

        if (this.loading) {
          Column() {
            LoadingProgress().width(38).height(38).color(C_RED)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.songs.length === 0) {
          Column() {
            EmptyState({
              text: '这个歌手没有可播放的歌',
              hint: this.status.length > 0 ? this.status : '换一个平台或换一个歌手试试。',
              topPadding: 48,
            })
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          // SongListPane 自己是可滚动的懒加载列表，别再套 Scroll（嵌套滚动会打架）。
          // 行上的样式与其它列表页**同一份实现**：歌名 + 歌手两行、右侧爱心 + 更多三点、
          // 当前播放那行红字。`showPlayingIcon` 是它在 2026-11-23 新加的开关：
          // 打开后当前播放那一行会多一枚红色小喇叭（华为音乐 / 其它列表页都是这个记号，
          // 这里不自己另写一套行）。
          SongListPane({
            items: this.songs,
            currentId: this.currentId,
            emptyText: '',
            // 这一页的歌都来自同一个平台，行上不必再标来源（平台已标在头部）
            showSource: false,
            showPlayingIcon: true,
            // 滚到底要停在悬浮迷你条上方：条高 + 与它的间距（与其它页同一口径，
            // 见 PlaylistDetailView / SearchView 的同一处算法）。少了这一段最后几首
            // 会被那条悬浮栏压住。
            bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
            footerStatus: this.status,
            onReachEnd: () => {
              void this.loadMore();
            },
            onPick: (index: number) => {
              if (index < 0 || index >= this.songs.length) {
                return;
              }
              void PlaySession.getInstance().setQueueAndPlay(this.songs, index);
              this.toast(`已加入播放列表并开始解析：${this.songs[index].name}`);
            },
          })
            .layoutWeight(1)
            .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      // 宽屏下与搜索页同口径限宽：歌手页是一列内容，铺满整屏会让头像与歌名隔得老远
      .constraintSize({ maxWidth: this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(C_BG)
    }
  }
}
