import { LIST_PLATFORMS, LxBoardItem, LxPlaylistItem, LxSortItem, OnlineRoute, getBoards, getRecommendPlaylists, platformName, sortListOf } from '../core/music/MusicList';
import { C_BG, C_CARD, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_CHEVRON_RIGHT, I_DISC, I_MIC, I_PLAY, I_SEARCH, IconGlyph } from '../ui/Icons';
import { CoverArt, PageTitle, RoundIconButton, SectionTitle } from '../ui/Widgets';

/** 在线排行榜卡片 */
@Component
struct RankCard {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop platform: string = '';
  @Prop colorA: string = '#7B6CF6';
  @Prop colorB: string = '#4E3FD6';
  @Prop cardWidth: number = 228;
  @Prop cardHeight: number = 268;
  onTap: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 160, colors: [[this.colorA, 0.0], [this.colorB, 1.0]] })
      // 底部压暗，让文字和播放钮跳出来
      Column()
        .width('100%')
        .height('58%')
        .linearGradient({ angle: 0, colors: [['#00000000', 0.0], ['#66000000', 1.0]] })

      Column() {
        Row({ space: 5 }) {
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(17).height(17).fill('#FFFFFF')
            IconGlyph({
              symbol: I_MIC,
              iconSize: 11,
              color: '#E2432F',
            })
          }
          Text(this.platform)
            .fontSize(11.5)
            .fontColor('#E6FFFFFF')
        }
        .width('100%')
        .padding({ left: 13, top: 13 })

        Blank()
        Text(this.title)
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textShadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 3 })
        Blank()

        // 给底部信息条留位
        Column().height(80)
      }
      .width('100%')
      .height('100%')

      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Text(this.title)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.subtitle)
            .fontSize(11.5)
            .fontColor('#B3FFFFFF')
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)

        Stack({ alignContent: Alignment.Center }) {
          Circle().width(34).height(34).fill('#FFFFFF')
          IconGlyph({
            symbol: I_PLAY,
            iconSize: 19,
            color: '#1A1A1A',
          })
        }
        .width(38)
        .height(38)
      }
      .width('100%')
      .height(80)
      .padding({ left: 13, right: 13 })
    }
    .width(this.cardWidth)
    .height(this.cardHeight)
    .borderRadius(22)
    .clip(true)
    .shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 6 })
    .onClick(() => {
      this.onTap();
    })
  }
}

/** 榜单卡片的配色（按榜单顺序循环取，同榜每次进入颜色不变） */
const BOARD_COLORS: string[][] = [
  ['#7B6CF6', '#4E3FD6'],
  ['#3FD07A', '#17A94F'],
  ['#FF7A59', '#E2432F'],
  ['#4FA8FF', '#1E6FD9'],
  ['#FFB13D', '#E0810F'],
  ['#F26DB4', '#C22C86'],
];

function boardColors(index: number): string[] {
  return BOARD_COLORS[index % BOARD_COLORS.length];
}

/** 推荐歌单列表的懒加载数据源（一页 30 条、可继续上拉，用 LazyForEach 更稳） */
class PlaylistSource implements IDataSource {
  private items: LxPlaylistItem[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: LxPlaylistItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): LxPlaylistItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

/** 推荐来源的持久化键（放在 AppStorage 里，切页签回来还在） */
const K_RECOMMEND_SOURCE: string = 'recommend_source';

/**
 * 推荐页
 *
 * 对应洛雪的「歌单」页 + 「排行榜」页合起来的那块内容：
 *   顶部是来源（酷我 / 酷狗 / 咪咕 / QQ / 网易）与排序页签（最新 / 最热 / 推荐…），
 *   下面是该来源的在线榜单（横向卡片）和推荐歌单（列表）。
 *   点榜单卡片或歌单进「在线详情页」，在那里播放全部或挑某一首。
 *
 * 数据全部来自宿主内置的平台接口（core/music/MusicList.ets），不依赖导入的音源；
 * 音源只决定「这些歌能不能解析出播放链接」。
 */
@Component
export struct RecommendView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onOpenSearch: () => void = () => {
  };
  onOpenSource: () => void = () => {
  };
  onOpenOnline: (route: OnlineRoute) => void = () => {
  };
  /** 当前推荐来源，切走再回来保持上次选的平台 */
  @StorageLink(K_RECOMMEND_SOURCE) platform: string = 'kw';
  @State sorts: LxSortItem[] = sortListOf('kw');
  @State sortIndex: number = 0;
  @State boards: LxBoardItem[] = [];
  @State playlists: LxPlaylistItem[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  @State error: string = '';
  @State page: number = 0;
  /** 某一页返回空 = 已经到底，别再用 onReachEnd 反复拉 */
  @State noMore: boolean = false;
  private playlistSource: PlaylistSource = new PlaylistSource();

  aboutToAppear(): void {
    this.sorts = sortListOf(this.platform);
    this.sortIndex = 0;
    if (this.playlists.length === 0) {
      void this.reload();
    }
  }

  private currentSortId(): string {
    if (this.sortIndex >= 0 && this.sortIndex < this.sorts.length) {
      return this.sorts[this.sortIndex].id;
    }
    return '';
  }

  /** 拉第一页（换来源、换排序、下拉刷新都走它） */
  private async reload(): Promise<void> {
    this.error = '';
    if (this.playlists.length === 0) {
      this.loading = true;
    }
    this.boards = getBoards(this.platform);
    try {
      const list: LxPlaylistItem[] =
        await getRecommendPlaylists(this.platform, this.currentSortId(), 1);
      this.playlists = list;
      this.playlistSource.setItems(this.playlists);
      this.page = 1;
      this.noMore = list.length === 0;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 上拉加载下一页 */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.noMore || this.error.length > 0) {
      return;
    }
    this.loadingMore = true;
    try {
      const list: LxPlaylistItem[] =
        await getRecommendPlaylists(this.platform, this.currentSortId(), this.page + 1);
      if (list.length === 0) {
        this.noMore = true;
        return;
      }
      this.playlists = this.playlists.concat(list);
      this.playlistSource.setItems(this.playlists);
      this.page = this.page + 1;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loadingMore = false;
    }
  }

  private switchPlatform(id: string): void {
    if (id === this.platform) {
      return;
    }
    this.platform = id;
    this.sorts = sortListOf(id);
    this.sortIndex = 0;
    this.playlists = [];
    this.playlistSource.setItems(this.playlists);
    this.page = 0;
    void this.reload();
  }

  private switchSort(index: number): void {
    if (index === this.sortIndex) {
      return;
    }
    this.sortIndex = index;
    this.playlists = [];
    this.playlistSource.setItems(this.playlists);
    this.page = 0;
    void this.reload();
  }

  private openBoard(board: LxBoardItem): void {
    const route: OnlineRoute = {
      kind: 'board',
      source: board.source,
      id: board.bangid,
      name: board.name,
      cover: '',
    };
    this.onOpenOnline(route);
  }

  private openPlaylist(item: LxPlaylistItem): void {
    const route: OnlineRoute = {
      kind: 'playlist',
      source: item.source,
      id: item.id,
      name: item.name,
      cover: item.img,
    };
    this.onOpenOnline(route);
  }

  /** 歌单行第二行的说明：作者 · 播放量 · 曲目数（有谁显示谁） */
  private playlistMeta(item: LxPlaylistItem): string {
    const parts: string[] = [];
    if (item.author.length > 0) {
      parts.push(item.author);
    }
    if (item.playCount.length > 0) {
      parts.push(item.playCount);
    }
    if (item.total > 0) {
      parts.push(`${item.total} 首`);
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------ 构建

  @Builder
  sourcePill(id: string) {
    Text(platformName(id))
      .fontSize(13.5)
      .fontWeight(this.platform === id ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.platform === id ? Color.White : '#3A3A3C')
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.platform === id ? C_RED : C_CARD)
      .animation({ duration: 180, curve: Curve.EaseInOut })
      .onClick(() => {
        this.switchPlatform(id);
      })
  }

  @Builder
  sortPill(item: LxSortItem, index: number) {
    Text(item.name)
      .fontSize(13.5)
      .fontWeight(this.sortIndex === index ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.sortIndex === index ? C_RED : '#3A3A3C')
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.sortIndex === index ? '#FBE9E9' : C_CARD)
      .animation({ duration: 180, curve: Curve.EaseInOut })
      .onClick(() => {
        this.switchSort(index);
      })
  }

  @Builder
  playlistRow(item: LxPlaylistItem) {
    Row({ space: 12 }) {
      CoverArt({
        url: item.img,
        name: item.name,
        art: item.img.length === 0,
        boxSize: 58,
        radius: 14,
      })

      Column({ space: 5 }) {
        Text(item.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.playlistMeta(item).length > 0) {
          Text(this.playlistMeta(item))
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 17, color: '#C2C2C6' })
    }
    .width('100%')
    .height(78)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.openPlaylist(item);
    })
  }

  @Builder
  statusBlock() {
    Column({ space: 10 }) {
      if (this.loading) {
        Text(`正在加载${platformName(this.platform)}的推荐…`)
          .fontSize(14.5)
          .fontColor(C_TEXT_SUB)
      } else if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13.5)
          .fontColor(C_TEXT_SUB)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .padding({ left: 26, right: 26 })
        Text('点击重试')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_RED)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor('#14E33B3B')
          .onClick(() => {
            void this.reload();
          })
      } else {
        Text('这个来源暂时没有推荐内容')
          .fontSize(14.5)
          .fontColor(C_TEXT_SUB)
      }
    }
    .width('100%')
    .padding({ left: 32, right: 32, top: 40, bottom: 30 })
  }

  build() {
    Column() {
      // ---------------------------------------------------- 顶栏
      Row({ space: 10 }) {
        PageTitle({ text: '推荐' })
        Blank()
        RoundIconButton({ icon: I_DISC, boxSize: 40, iconSize: 21, onTap: this.onOpenSource })
        RoundIconButton({ icon: I_SEARCH, boxSize: 40, iconSize: 21, onTap: this.onOpenSearch })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInset + 6, bottom: 6 })

      // ---------------------------------------------------- 推荐来源
      Scroll() {
        Row({ space: 8 }) {
          ForEach(LIST_PLATFORMS, (id: string) => {
            this.sourcePill(id)
          }, (id: string) => id)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(44)

      // ---------------------------------------------------- 排序页签（有的平台只有一个，就不占位）
      if (this.sorts.length > 1) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.sorts, (item: LxSortItem, index: number) => {
              this.sortPill(item, index)
            }, (item: LxSortItem, index: number) => `${index}_${item.tid}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(42)
      }

      // ---------------------------------------------------- 内容
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 0 }) {
          if (this.boards.length > 0) {
            // -------------------------------------------- 在线榜单
            ListItem() {
              Row({ space: 8 }) {
                SectionTitle({ text: '在线榜单' })
                Text(platformName(this.platform))
                  .fontSize(12)
                  .fontColor(C_RED)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  .borderRadius(9)
                  .backgroundColor('#14E33B3B')
                Blank()
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 12 })
            }

            ListItem() {
              List({ space: 12 }) {
                ForEach(this.boards, (board: LxBoardItem, index: number) => {
                  ListItem() {
                    RankCard({
                      title: board.name,
                      subtitle: '在线排行榜',
                      platform: platformName(board.source),
                      colorA: boardColors(index)[0],
                      colorB: boardColors(index)[1],
                      cardWidth: 180,
                      cardHeight: 212,
                      onTap: () => {
                        this.openBoard(board);
                      },
                    })
                  }
                }, (board: LxBoardItem) => board.id)
              }
              .scrollBar(BarState.Off)
              .listDirection(Axis.Horizontal)
              .width('100%')
              .height(212)
              .padding({ left: 16 })
            }
          }

          // -------------------------------------------- 推荐歌单
          ListItem() {
            Row({ space: 8 }) {
              SectionTitle({ text: '推荐歌单' })
              Blank()
              if (this.loadingMore) {
                Text('加载中…')
                  .fontSize(12)
                  .fontColor(C_TEXT_WEAK)
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: this.boards.length > 0 ? 22 : 4, bottom: 10 })
          }

          if (this.playlists.length === 0) {
            ListItem() {
              this.statusBlock()
            }
          } else {
            LazyForEach(this.playlistSource, (item: LxPlaylistItem) => {
              ListItem() {
                Column() {
                  this.playlistRow(item)
                  Divider()
                    .strokeWidth(0.6)
                    .color(C_DIVIDER)
                    .margin({ left: 86 })
                }
                .width('100%')
              }
            }, (item: LxPlaylistItem) => `${item.id}_${item.name}`)

            if (this.error.length > 0) {
              ListItem() {
                Column({ space: 8 }) {
                  Text(this.error)
                    .fontSize(13)
                    .fontColor(C_TEXT_WEAK)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('点击重试')
                    .fontSize(13.5)
                    .fontColor(C_RED)
                    .onClick(() => {
                      this.error = '';
                      void this.loadMore();
                    })
                }
                .width('100%')
                .padding({ top: 14, bottom: 14 })
              }
            } else {
              ListItem() {
                Text(this.loadingMore ? '正在加载更多…' : (this.noMore ? '没有更多了' : '上拉加载更多'))
                  .fontSize(13)
                  .fontColor(C_TEXT_WEAK)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 16, bottom: 16 })
              }
            }
          }

          ListItem() {
            Column().height(this.bottomInset + 12).width('100%')
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .onReachEnd(() => {
          void this.loadMore();
        })
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        void this.reload();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
