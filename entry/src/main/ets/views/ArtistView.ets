import { LxArtist, LxArtistDetail, LxArtistOrder, getArtistDetail, getArtistSongs } from '../core/music/MusicArtist';
import { LxSearchPage } from '../core/music/MusicSearch';
import { platformName } from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_PLAY_QUALITY } from '../core/settings/PlaySettings';
import { C_BG, C_DIVIDER, C_FILL_SOFT, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK,
  F_SUB, platformColor, platformTint } from '../ui/Theme';
import { CoverArt, EmptyState } from '../ui/Widgets';
import { SongListPane } from './SongListPane';
import { CONTENT_MAX_WIDTH, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED, contentColumnsFor } from '../ui/Layout';

/** 每页取多少首：与搜索页同口径（50 首一页，滚到底再拉） */
const ARTIST_PAGE_LIMIT: number = 50;

/**
 * 歌手页 —— 「按歌手聚合」的结果页
 *
 * 从一个歌手出发，把他在这个平台上的歌聚到一处：头部是歌手（头像 / 名字 / 单曲与专辑
 * 计数 / 简介），下面就是这个歌手的全部歌曲，滚到底自动接下一页。
 *
 * 对应派音的 `ArtistDetailPage`（`features/setting/src/main/ets/view/ArtistDetailPage.ets`）。
 * 那一版还带专辑列表与「收藏歌手」，这里只保留「按歌手聚合歌曲」这一件事：
 * 本项目里歌单/收藏是同步协议的一部分（见 docs/LX_SYNC.md），而「收藏歌手」在洛雪的
 * 同步结构里没有对应的类型，硬加会多出一种同步不出去的数据。
 *
 * 歌还是 `SongItem`（由 `songFromSearch` 转），所以行上的收藏 / 下载 / 更多菜单、
 * 以及播放链路与搜索结果完全共用 —— 这一页不新增任何播放入口。
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
  /** 列表底部要留出的空间（悬浮页签栏 / 手势条），由壳层给 */
  @Prop bottomInset: number = 0;
  @Prop currentId: string = '';
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

  /** 计数文案：单曲 N · 专辑 M（哪一项没有就不写哪一项） */
  private countText(): string {
    const parts: string[] = [];
    if (this.detail.songNum > 0) {
      parts.push(`单曲 ${this.detail.songNum}`);
    }
    if (this.detail.albumSize > 0) {
      parts.push(`专辑 ${this.detail.albumSize}`);
    }
    if (parts.length === 0) {
      parts.push(platformName(this.source));
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------ 头部

  @Builder
  sortChip(label: string, value: LxArtistOrder) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.order === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.order === value ? C_RED : C_TEXT_SUB)
      .padding({ left: 13, right: 13, top: 6, bottom: 6 })
      .backgroundColor(C_FILL_SOFT)
      .borderRadius(15)
      .onClick(() => {
        void this.switchOrder(value);
      })
      .accessibilityText(`按${label}排序`)
      .accessibilityLevel('yes')
  }

  @Builder
  header() {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        // 歌手头像是圆的：CoverArt 的 radius 给一半边长就是圆
        CoverArt({
          url: this.detail.picUrl,
          name: this.detail.name,
          boxSize: 84,
          radius: 42,
        })
        Column({ space: 6 }) {
          Text(this.detail.name.length > 0 ? this.detail.name : '歌手')
            .fontSize(22)
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
            Text(this.countText())
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .maxLines(1)
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.detail.desc.length > 0) {
        Text(this.detail.desc)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Row({ space: 10 }) {
        // 播放全部：整页入队并从第一首开始（播放列表是全局那一份，与搜索结果共用）
        Row({ space: 6 }) {
          Text('播放全部')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_RED)
        }
        .height(34)
        .padding({ left: 16, right: 16 })
        .backgroundColor(C_FILL_SOFT)
        .borderRadius(17)
        .onClick(() => {
          this.playAll();
        })
        .accessibilityText('播放这个歌手的全部歌曲')
        .accessibilityLevel('yes')

        if (this.sortable()) {
          Blank()
          this.sortChip('最热', 'hot')
          this.sortChip('最新', 'new')
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

  build() {
    Column() {
      this.header()

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
        // SongListPane 自己是可滚动的懒加载列表，别再套 Scroll（嵌套滚动会打架）
        SongListPane({
          items: this.songs,
          currentId: this.currentId,
          emptyText: '',
          // 这一页的歌都来自同一个平台，行上不必再标来源（平台已标在头部）
          showSource: false,
          bottomInset: this.bottomInset,
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
