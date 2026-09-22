import { LengthMetrics } from '@kit.ArkUI';
import { K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
import { LOVE_LIST_NAME } from '../core/sync/SyncTypes';
import { C_BG, C_DIVIDER, C_RED, C_TEXT, C_TEXT_WEAK, F_ITEM, F_SUB, platformColor,
  platformTint } from '../ui/Theme';
import { platformName } from '../core/music/MusicList';
import { I_CHECK_CIRCLE, I_CHEVRON_RIGHT, I_CIRCLE, I_HEART_FILLED, I_IMPORT, I_MORE, I_MORE_CIRCLE,
  I_PLUS, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, FavoriteHeart, PageTitle, RoundIconButton } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { ImportPlaylistSheet } from './ImportPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { isWebDavSong } from '../core/webdav/WebDavLibrary';

/**
 * 歌单页
 *
 * 顶栏右侧两个玻璃圆钮（排序 / 新建），下面是歌单列表：
 * 名称 + 曲目数 + 更多 + 右箭头。
 *
 * 歌单数据由同步模块（LocalLibrary）持有：开启同步时它与服务端互通，
 * 未开启时也照常保存在本地。这里只负责展示与转达「新建 / 重命名 / 删除」。
 */
@Component
export struct PlaylistView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onOpenPlaylist: (playlist: PlaylistSummary) => void = () => {
  };
  @State playlists: PlaylistSummary[] = [];
  /** 最近一次触摸点：删除歌单时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;
  /** 新建 / 重命名共用的小面板：editingId 为空表示新建 */
  @State editOpen: boolean = false;
  @State editingId: string = '';
  @State editName: string = '';
  /** 「导入歌单」面板（粘贴第三方歌单分享链接） */
  @State importOpen: boolean = false;
  /** 同步模块或本地库改动后重新读一次歌单 */
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('refresh') syncVersion: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const library = SyncManager.getInstance().getLibrary();
    const rows: PlaylistSummary[] = [];
    // 内置收藏歌单永远在最上面：它不属于用户歌单，删不掉也改不了名
    rows.push(library.favoritePlaylistSummary());
    if (library.isInitialized() || library.playlistSummaries().length > 0) {
      for (const item of library.playlistSummaries()) {
        rows.push(item);
      }
    } else {
      // 还没落过库时沿用手工铺的演示歌单，保持界面原样
      for (const item of PlaySession.getInstance().playlists) {
        rows.push(item);
      }
    }
    this.playlists = rows;
  }

  private openCreate(): void {
    this.editingId = '';
    this.editName = '';
    this.editOpen = true;
  }

  private openRename(item: PlaylistSummary): void {
    this.editingId = item.id;
    this.editName = item.name;
    this.editOpen = true;
  }

  private submitEdit(): void {
    const name: string = this.editName.trim();
    if (name.length === 0) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    if (this.editingId.length === 0) {
      library.createPlaylist(name);
    } else {
      library.renamePlaylist(this.editingId, name);
    }
    this.editOpen = false;
    this.refresh();
  }

  private removePlaylist(item: PlaylistSummary): void {
    this.getUIContext().showAlertDialog({
      title: '删除歌单',
      message: `确定要删除「${item.name}」吗？删除会同步到其它设备。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        { value: '删除', fontColor: C_RED, action: () => {
          SyncManager.getInstance().getLibrary().removePlaylists([item.id]);
          // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
          dustBus.spray(this.dustX, this.dustY);
          this.refresh();
        } },
      ],
    });
  }

  /** 记住这次触摸的位置：删除歌单时拿它当粒子飘散的起点 */
  private rememberTouch(event: TouchEvent): void {
    const point: DustPoint | null = dustPointOf(event);
    if (point !== null) {
      this.dustX = point.x;
      this.dustY = point.y;
    }
  }

  /** 是不是内置收藏歌单（不可删除 / 不可改名，菜单里也不给这些入口） */
  private isBuiltin(item: PlaylistSummary): boolean {
    return SyncManager.getInstance().getLibrary().isBuiltinPlaylist(item.id);
  }

  @Builder
  rowMenu(item: PlaylistSummary) {
    // 内置歌单不给菜单（长按不弹）：它只能进去看歌、播全部、删歌
    if (!this.isBuiltin(item)) {
      Menu() {
        MenuItem({ content: '添加到收藏' })
          .onClick(() => {
            this.addPlaylistToFavorites(item);
          })
        MenuItem({ content: '重命名' })
          .onClick(() => {
            this.openRename(item);
          })
        MenuItem({ content: '删除' })
          .onClick(() => {
            this.removePlaylist(item);
          })
      }
    }
  }

  /** 把整张歌单的歌批量加进收藏（收藏是参与同步的数据，只上行一次） */
  private addPlaylistToFavorites(item: PlaylistSummary): void {
    const songs: SongItem[] = SyncManager.getInstance().getLibrary().playlistSongs(item.id);
    if (songs.length === 0) {
      this.toast(`「${item.name}」还没有歌曲`);
      return;
    }
    const added: number = PlaySession.getInstance().addFavorites(songs);
    this.toast(added > 0
      ? `已把「${item.name}」的 ${added} 首歌添加到${LOVE_LIST_NAME}`
      : `「${item.name}」里的歌都已经在${LOVE_LIST_NAME}里了`);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      Text(this.editingId.length === 0 ? '新建歌单' : '重命名歌单')
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .width('100%')
        .textAlign(TextAlign.Start)
      TextInput({ text: this.editName, placeholder: '歌单名称' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 14 })
        .fontSize(14)
        .height(46)
        .backgroundColor('#F2F2F4')
        .onChange((value: string) => {
          this.editName = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .backgroundColor('#E8E8EA')
          .fontColor(C_TEXT)
          .onClick(() => {
            this.editOpen = false;
          })
        Button('确定')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_RED)
          .onClick(() => {
            this.submitEdit();
          })
      }
      .width('100%')

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  @Builder
  importSheet() {
    ImportPlaylistSheet({
      bottomInset: this.bottomInset,
      onDone: (message: string) => {
        this.importOpen = false;
        this.toast(message);
      },
    })
  }

  build() {
    // 两个半模态各自挂在一个节点上：同一个节点叠两个 bindSheet 会互相干扰
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 10 }) {
          PageTitle({ text: '歌单' })
          Blank()
          // 歌单页只留「导入」「新建」两个悬浮钮：原来中间那颗「排序」点下去只弹一句
          // 「暂未接入」，摆在那里是误导，直接去掉（排序在「推荐」页是按来源走的，
          // 本地歌单的排序还没有真实需求）
          RoundIconButton({ icon: I_IMPORT, boxSize: 40, iconSize: 20, label: '导入歌单', onTap: () => {
            this.importOpen = true;
          } })
          RoundIconButton({ icon: I_PLUS, boxSize: 40, iconSize: 22, label: '新建歌单', onTap: () => {
            this.openCreate();
          } })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.topInset + 6, bottom: 10 })

        // 系统列表：ListItemGroup(CARD) 给整块白卡，行内分隔线由 group 的 divider 统一画
        List() {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            ForEach(this.playlists, (item: PlaylistSummary) => {
              ListItem() {
                Row({ space: 10 }) {
                  // 内置收藏歌单前面挂一颗心，跟普通歌单区分开
                  if (this.isBuiltin(item)) {
                    IconGlyph({ symbol: I_HEART_FILLED, iconSize: 18, color: C_RED })
                  }

                  Column({ space: 5 }) {
                    Text(item.name)
                      .fontSize(F_ITEM)
                      .fontColor(C_TEXT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                      .textAlign(TextAlign.Start)
                    Text(this.isBuiltin(item) ? `${item.count} 首 · 默认收藏歌单` : `${item.count} 首`)
                      .fontSize(F_SUB)
                      .fontColor(C_TEXT_WEAK)
                      .width('100%')
                      .textAlign(TextAlign.Start)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  // 内置歌单不给「更多」入口：它不能改名、也不能删除
                  if (!this.isBuiltin(item)) {
                    IconGlyph({ symbol: I_MORE, iconSize: 20, color: C_TEXT_WEAK })
                  }
                  IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_TEXT_WEAK })
                }
                .width('100%')
                .height(76)
                .padding({ left: 16, right: 14 })
                .onClick(() => {
                  this.onOpenPlaylist(item);
                })
                .onTouch((event: TouchEvent) => {
                  this.rememberTouch(event);
                })
                .bindContextMenu(this.rowMenu(item), ResponseType.LongPress)
              }
            }, (item: PlaylistSummary) => `${item.id}_${item.count}_${item.name}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
          .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 16 })

          if (this.playlists.length === 0) {
            ListItem() {
              EmptyState({
                text: '还没有歌单',
                hint: '点右上角「+」新建一个歌单，或者从「导入歌单」粘贴分享链接',
                topPadding: 72,
              })
            }
          }

          ListItem() {
            Column().height(this.bottomInset + 12).width('100%')
          }
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.editOpen, this.editSheet(), {
        preferType: SheetType.BOTTOM,
        detents: [SheetSize.MEDIUM],
        detentSelection: SheetSize.MEDIUM,
        dragBar: true,
        showClose: false,
        title: { title: this.editingId.length === 0 ? '新建歌单' : '重命名' },
      })

      // 导入面板：挂在另一个 1x1 节点上（上面那个节点已经占了新建面板）
      Column()
        .width(1)
        .height(1)
        .bindSheet($$this.importOpen, this.importSheet(), {
          preferType: SheetType.BOTTOM,
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.LARGE,
          dragBar: true,
          showClose: true,
          title: { title: '导入歌单' },
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}

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
   * 多选模式（本地音乐的批量移除用）
   *
   * 打开后行尾的心/更多换成勾选圈，点行 = 勾选/取消，不再播歌。
   * 默认关，其余列表（歌单、搜索、播放历史…）的行为一点不变。
   */
  @Prop selecting: boolean = false;
  @Prop selectedIds: string[] = [];
  onToggleSelect: (item: SongItem) => void = () => {
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
    }
    .font({ size: 16 })
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: C_DIVIDER,
      startMargin: LengthMetrics.vp(14),
      endMargin: LengthMetrics.vp(14),
    })
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
                Row({ space: 8 }) {
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
