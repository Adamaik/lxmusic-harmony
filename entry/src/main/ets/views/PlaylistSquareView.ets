import { LxPlaylistItem, OnlineRoute, getRecommendPlaylists } from '../core/music/MusicList';
import { C_BG, C_FILL_SOFT_STRONG, C_RED, C_RED_TINT, C_TEXT_SUB, C_TEXT_WEAK } from '../ui/Theme';
import { PlaylistCard, PlaylistRow, PlaylistRowSource } from '../ui/PlaylistGrid';
import { K_WINDOW_WIDTH } from '../ui/Layout';

/**
 * 全部歌单（一个平台 × 一个排序的全部歌单）
 *
 * 推荐页每个分区标题右边的「更多」进来的那一页：分区里只露三张卡，这里铺开全部，
 * 而且是两列大卡、往下滑继续翻页（与推荐页的「歌单广场」同一套卡）。
 *
 * 与广场的关系：广场是「当前选中的分类」，这一页是「点进来的那个分类」——
 * 两者取数完全一样（`getRecommendPlaylists(source, sortId, page)`），
 * 所以这里也不带分类切换器：要换分类回推荐页的「歌单分类」点一下就行。
 */
const PAGE_PAD: number = 16;
const CARD_GAP: number = 10;
const ROW_GAP: number = 18;
/** 加载中骨架摆几行 */
const BONE_ROWS: number = 3;

function boneIndexes(n: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    out.push(i);
  }
  return out;
}

@Component
export struct PlaylistSquareView {
  /** 状态栏 + 标题栏那一段的高度（壳层给） */
  @Prop topInset: number = 0;
  /** 页内悬浮迷你条 + 手势条的让位高度（壳层给） */
  @Prop bottomInset: number = 0;
  /** 平台（kw / kg / mg / tx / wy） */
  @Prop source: string = 'kw';
  /** 排序 id（与 sortListOf 里的 id 一致） */
  @Prop sortId: string = '';
  /** 排序名：只用在空态 / 失败文案上（标题栏由壳层画） */
  @Prop sortName: string = '';
  onOpenOnline: (route: OnlineRoute) => void = () => {
  };
  /** 窗口宽度（vp）：决定两列还是三、四列 */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  @State items: LxPlaylistItem[] = [];
  @State page: number = 0;
  @State loading: boolean = false;
  /** 下拉刷新那个圈（与翻页的 loading 分开：翻页时不该把刷新的圈也转起来） */
  @State refreshing: boolean = false;
  @State noMore: boolean = false;
  @State error: string = '';
  private rows: PlaylistRowSource = new PlaylistRowSource();

  aboutToAppear(): void {
    this.rows.setItems(this.items, this.gridCols());
    void this.load(1, false);
  }

  /** 拉某一页（append = 下拉继续翻） */
  private async load(page: number, append: boolean): Promise<void> {
    if (this.loading || this.sortId.length === 0) {
      return;
    }
    this.loading = true;
    try {
      const list: LxPlaylistItem[] = await getRecommendPlaylists(this.source, this.sortId, page);
      if (list.length === 0 && append) {
        this.noMore = true;
      } else {
        this.items = append ? this.items.concat(list) : list;
        this.rows.setItems(this.items, this.gridCols());
        this.page = page;
        this.noMore = list.length === 0;
      }
      this.error = '';
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
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

  private gridCols(): number {
    if (this.windowWidth >= 840) {
      return 4;
    }
    if (this.windowWidth >= 600) {
      return 3;
    }
    return 2;
  }

  private gridCardWidth(): number {
    const cols: number = this.gridCols();
    const usable: number = (this.windowWidth > 0 ? this.windowWidth : 360) - PAGE_PAD * 2
      - CARD_GAP * (cols - 1);
    return Math.max(120, usable / cols);
  }

  @Builder
  bone(width: Length, height: number | string, radius: number) {
    Column()
      .width(width)
      .height(height)
      .borderRadius(radius)
      .backgroundColor(C_FILL_SOFT_STRONG)
  }

  /** 骨架：两列几行灰卡 */
  @Builder
  gridBone() {
    Column({ space: ROW_GAP }) {
      ForEach(boneIndexes(BONE_ROWS), () => {
        Row({ space: CARD_GAP }) {
          ForEach(boneIndexes(this.gridCols()), () => {
            Column({ space: 8 }) {
              this.bone('100%', this.gridCardWidth(), 12)
              this.bone('100%', 16, 4)
              this.bone('65%', 12, 4)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }, (i: number) => `sqbone_${i}`)
        }
        .width('100%')
      }, (i: number) => `sqbonerow_${i}`)
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }

  /** 一行卡（不足一行时补空位，否则一张孤卡会被撑成整行宽） */
  @Builder
  gridRow(row: PlaylistRow) {
    Row({ space: CARD_GAP }) {
      ForEach(row.items, (item: LxPlaylistItem) => {
        PlaylistCard({
          title: item.name,
          coverUrl: item.img,
          meta: item.playCount.length > 0 ? item.playCount : item.author,
          coverBox: this.gridCardWidth(),
          onOpen: () => {
            this.openPlaylist(item);
          },
        })
      }, (item: LxPlaylistItem) => `${row.version}_${item.id}`)
      ForEach(boneIndexes(this.gridCols() - row.items.length), () => {
        Column().layoutWeight(1)
      }, (i: number) => `sqgap_${i}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }

  build() {
    Column() {
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: ROW_GAP }) {
          if (this.items.length === 0) {
            ListItem() {
              if (this.error.length > 0) {
                Column({ space: 10 }) {
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
                    .backgroundColor(C_RED_TINT)
                    .onClick(() => {
                      void this.load(1, false);
                    })
                }
                .width('100%')
                .padding({ top: 40, bottom: 30 })
              } else {
                this.gridBone()
              }
            }
          } else {
            LazyForEach(this.rows, (row: PlaylistRow) => {
              ListItem() {
                this.gridRow(row)
              }
            }, (row: PlaylistRow, index: number) => `sqrow_${index}_${row.version}`)
          }

          // 尾巴：翻页状态 + 底部让位（页内迷你条压在这儿，最后一行不该被盖住）
          ListItem() {
            Column() {
              Text(this.loading ? '正在加载更多…' : (this.noMore ? '没有更多了' : '上拉加载更多'))
                .fontSize(13)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
              Column().height(this.bottomInset + 12).width('100%')
            }
            .width('100%')
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .contentStartOffset(this.topInset + 6)
        .onReachEnd(() => {
          if (!this.noMore && !this.loading) {
            void this.load(this.page + 1, true);
          }
        })
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.refreshing = true;
        void this.load(1, false);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
