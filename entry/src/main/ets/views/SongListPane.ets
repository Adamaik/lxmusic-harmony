import { LengthMetrics } from '@kit.ArkUI';
import { PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { SyncManager } from '../core/sync/SyncManager';
import { platformName } from '../core/music/MusicList';
import { C_DIVIDER, C_RED, C_TEXT, C_TEXT_WEAK, F_ITEM, F_SUB, platformColor, platformTint } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CIRCLE, I_MORE_CIRCLE, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, FavoriteHeart } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { isWebDavSong } from '../core/webdav/WebDavLibrary';

/**
 * 「我的」页与搜索结果共用的歌曲列表（懒加载：只建可见的行）
 *
 * 行尾的交互与排行榜（在线列表）一致：爱心收藏 + 两点「更多」菜单
 * （播放 / 下载 / 添加到歌单 / 添加到播放列表 / 添加到下一个播放）。
 * 播放历史就是从这里点进来的，所以两处不能各长一个样。
 */
@Component
export struct SongListPane {
  @Prop @Watch('onItemsChanged') items: SongItem[] = [];
  @Prop currentId: string = '';
  @Prop emptyText: string = '这里是空的';
  /** 行上是否标出来源平台（聚合搜索结果才需要，普通歌单里所有歌都是一个平台） */
  @Prop showSource: boolean = false;
  /**
   * 多选模式
   *
   * 打开后行尾的心/更多换成勾选圈，点行 = 勾选/取消，不再播歌。
   * 默认关，其余列表（歌单详情、搜索、在线榜单）的行为一点不变。
   */
  @Prop selecting: boolean = false;
  @Prop selectedIds: string[] = [];
  onToggleSelect: (item: SongItem) => void = () => {
  };
  /**
   * 长按能不能进多选
   *
   * 「我的」页的列表（播放历史 / 本地音乐 / 云端音乐）开着：长按任意一行就进多选。
   * 开着时长按不再弹那一行的菜单 —— 菜单还在行尾「更多」上，点它照样出来。
   */
  @Prop selectable: boolean = false;
  /** 长按第 index 行（宿主决定是「进多选并勾上它」还是别的） */
  onRequestSelect: (item: SongItem, index: number) => void = () => {
  };
  @Prop coverSize: number = 52;
  /** 列表底部要留出的空间（悬浮页签栏 / 手势条），由调用方给 */
  @Prop bottomInset: number = 0;
  onPick: (index: number) => void = () => {
  };
  /**
   * 「从本地音乐移除」的回调（只有 source='local' 的条目会用到）
   *
   * 不传就表示这个列表里不会出现本地歌（比如在线排行榜），菜单里也就不显示这一项。
   */
  onRemoveLocal: (item: SongItem) => void = () => {
  };
  /** 「添加到歌单」选歌单面板 */
  @State pickerOpen: boolean = false;
  @State pending: SongItem | null = null;
  @State candidates: PlaylistSummary[] = [];
  /** 封面懒解析好后版本号会变，订阅它把列表重画一遍 */
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;
  private source: SongListSource = new SongListSource();

  aboutToAppear(): void {
    this.source.setItems(this.items);
  }

  /** 列表数据换了（切分段、收藏被改动）就重设数据源 */
  onItemsChanged(): void {
    this.source.setItems(this.items);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 这一条是否被勾选（多选模式） */
  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /** 下载：交给下载管理排队 */
  private download(item: SongItem): void {
    // 本地歌没什么可下的（菜单里也不显示这一项，这里只作兜底）
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    // 云端歌的「下载」由播放缓存的边听边下负责（DownloadManager 那条路要问音源要链接）
    if (isWebDavSong(item)) {
      this.toast(`「${item.name}」是云端音乐，播放时会自动缓存`);
      return;
    }
    const manager = DownloadManager.getInstance();
    const state: DownloadItem | null = manager.stateOf(downloadKeyOf(item));
    if (state !== null && state.status === 'done') {
      this.toast(`「${item.name}」已经下载过了`);
      return;
    }
    if (state !== null && (state.status === 'waiting' || state.status === 'downloading')) {
      this.toast(`「${item.name}」正在下载中`);
      return;
    }
    if (manager.enqueue(item) !== null) {
      this.toast(`已加入下载：${item.name}`);
    } else {
      this.toast('这首歌没法下载（缺少歌曲信息）');
    }
  }

  private toggleFavorite(item: SongItem): void {
    const session = PlaySession.getInstance();
    if (session.isFavorite(item.id)) {
      if (session.removeFavorite(item.id)) {
        this.toast(`已取消收藏：${item.name}`);
      }
      return;
    }
    if (session.addFavorite(item)) {
      this.toast(`已添加到收藏：${item.name}`);
    }
  }

  private addToQueue(item: SongItem): void {
    PlaySession.getInstance().addToQueue(item);
    this.toast(`已添加到播放列表：${item.name}`);
  }

  private addToNext(item: SongItem): void {
    const session = PlaySession.getInstance();
    const hasCurrent: boolean =
      session.currentIndex >= 0 && session.currentIndex < session.queue.length;
    session.addToQueue(item, true);
    this.toast(hasCurrent ? `已设为下一首播放：${item.name}` : `播放列表是空的，已加入：${item.name}`);
  }

  // ------------------------------------------------------------ 添加到歌单

  private openPlaylistPicker(item: SongItem): void {
    this.pending = item;
    this.candidates = SyncManager.getInstance().getLibrary().playlistSummaries();
    this.pickerOpen = true;
  }

  private addToPlaylist(playlist: PlaylistSummary): void {
    const song: SongItem | null = this.pending;
    if (song === null) {
      return;
    }
    const added: number = SyncManager.getInstance().getLibrary().addMusicToPlaylist(playlist.id, [song]);
    this.closePicker();
    this.toast(added > 0 ? `已添加到「${playlist.name}」` : `「${playlist.name}」里已经有这首歌了`);
  }

  private createPlaylistAndAdd(name: string): void {
    const song: SongItem | null = this.pending;
    if (name.length === 0 || song === null) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    const id: string = library.createPlaylist(name);
    library.addMusicToPlaylist(id, [song]);
    this.closePicker();
    this.toast(`已新建歌单「${name}」并添加`);
  }

  private closePicker(): void {
    this.pickerOpen = false;
    this.pending = null;
  }

  /** 「添加到歌单」面板（面板本体是三处共用的那个组件） */
  @Builder
  playlistPickerSheet() {
    AddToPlaylistSheet({
      songName: this.pending === null ? '' : this.pending.name,
      candidates: this.candidates,
      bottomInset: this.bottomInset,
      onPick: (playlist: PlaylistSummary) => {
        this.addToPlaylist(playlist);
      },
      onCreate: (name: string) => {
        this.createPlaylistAndAdd(name);
      },
    })
  }

  /** 行尾菜单：与排行榜的歌曲条目同一套（收藏已经在行上的爱心里了） */
  @Builder
  rowMenu(item: SongItem, index: number) {
    Menu() {
      MenuItem({ content: '播放' })
        .onClick(() => {
          if (index >= 0) {
            this.onPick(index);
          }
        })
      // 本地歌已经在本地了、云端歌由播放缓存负责，下载这一项对它们都没有意义
      if (!isLocalSong(item) && !isWebDavSong(item)) {
        MenuItem({ content: '下载' })
          .onClick(() => {
            this.download(item);
          })
      }
      MenuItem({ content: '添加到歌单' })
        .onClick(() => {
          this.openPlaylistPicker(item);
        })
      MenuItem({ content: '添加到播放列表' })
        .onClick(() => {
          this.addToQueue(item);
        })
      MenuItem({ content: '添加到下一个播放' })
        .onClick(() => {
          this.addToNext(item);
        })
      if (isLocalSong(item)) {
        MenuItem({ content: '从本地音乐移除' })
          .onClick(() => {
            this.onRemoveLocal(item);
          })
      }
      // 长按进多选是主入口，这一项是给「想不起来长按」的人留的
      if (this.selectable) {
        MenuItem({ content: '多选' })
          .onClick(() => {
            this.onRequestSelect(item, index);
          })
      }
    }
    .font({ size: 16 })
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: C_DIVIDER,
      startMargin: LengthMetrics.vp(14),
      endMargin: LengthMetrics.vp(14),
    })
  }

  /** 一行的内容（封面 / 歌名歌手 / 行尾）—— 多选与非多选两种外壳共用它 */
  @Builder
  songRowContent(item: SongItem, index: number) {
    CoverArt({
      url: CoverStore.getInstance().coverFor(item.musicInfoJson, item.coverUrl),
      name: item.name,
      art: item.art,
      boxSize: this.coverSize,
      radius: 13,
    })
    Column({ space: 4 }) {
      Text(item.name)
        .fontSize(F_ITEM)
        .fontColor(this.currentId === item.id ? C_RED : C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      if (item.singer.length > 0 || this.showSource) {
        Row({ space: 6 }) {
          if (item.singer.length > 0) {
            Text(item.singer)
              .fontSize(F_SUB)
              .fontColor(C_TEXT_WEAK)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
          }
          if (this.showSource) {
            // 来源标签：同一首歌在五个平台都有，扫列表时得一眼看出哪条是哪个站
            Text(platformName(item.source))
              .fontSize(10.5)
              .fontColor(platformColor(item.source))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(platformTint(item.source))
              .flexShrink(0)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)

    if (this.selecting) {
      // 多选模式：行尾只留一个勾选圈（爱心/更多这时没意义，点了还会误触）
      IconGlyph({
        symbol: this.isSelected(item.id) ? I_CHECK_CIRCLE : I_CIRCLE,
        iconSize: 22,
        color: this.isSelected(item.id) ? C_RED : C_TEXT_WEAK,
      })
        .accessibilityLevel('no')
    } else {
      // 爱心 + 两点：与排行榜的行尾一致（子组件的点击会吃掉整行的点击）
      FavoriteHeart({
        songId: item.id,
        onToggle: () => {
          this.toggleFavorite(item);
        },
      })
      IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: C_TEXT_WEAK })
        .bindMenu(this.rowMenu(item, index))
    }
  }

  build() {
    Column() {
      if (this.items.length === 0) {
        EmptyState({ text: this.emptyText, topPadding: 82 })
      } else {
        List() {
          LazyForEach(this.source, (item: SongItem, index: number) => {
            ListItem() {
              Column() {
                if (this.selectable) {
                  // 我的页的列表：长按进多选（右键菜单还在行尾「更多」上，没丢）
                  Row({ space: 8 }) {
                    this.songRowContent(item, index)
                  }
                  .width('100%')
                  .height(this.coverSize + 22)
                  .padding({ left: 16, right: 14 })
                  .onClick(() => {
                    if (this.selecting) {
                      this.onToggleSelect(item);
                      return;
                    }
                    this.onPick(index);
                  })
                  .gesture(LongPressGesture().onAction(() => {
                    if (!this.selecting) {
                      this.onRequestSelect(item, index);
                    }
                  }))
                } else {
                  Row({ space: 8 }) {
                    this.songRowContent(item, index)
                  }
                  .width('100%')
                  .height(this.coverSize + 22)
                  .padding({ left: 16, right: 14 })
                  .onClick(() => {
                    if (this.selecting) {
                      this.onToggleSelect(item);
                      return;
                    }
                    this.onPick(index);
                  })
                  .bindContextMenu(this.rowMenu(item, index), ResponseType.LongPress)
                }

                Divider()
                  .strokeWidth(0.6)
                  .color(C_DIVIDER)
                  .margin({ left: this.coverSize + 28 })
              }
              .width('100%')
            }
          }, (item: SongItem, index: number) => `${index}_${item.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // 底部留出悬浮页签栏 / 手势条的位置，最后一行能滚到它上面
        .padding({ bottom: this.bottomInset })
        // 多缓存几屏，快速滑动时不至于白屏
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.pickerOpen, this.playlistPickerSheet(), {
      preferType: SheetType.BOTTOM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      detentSelection: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '添加到歌单' },
      onDisappear: () => {
        this.pending = null;
      },
    })
  }
}
