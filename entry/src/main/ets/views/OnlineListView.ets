import { LengthMetrics } from '@kit.ArkUI';
import { K_CURRENT_ID, PlaySession, PlaylistSummary, SongItem, songFromSearch } from '../core/player/PlaySession';
import { LxListDetail, LxListInfo, getBoardSongs, getPlaylistDetail, platformName } from '../core/music/MusicList';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { SyncManager } from '../core/sync/SyncManager';
import { C_BG, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_DOWNLOAD, I_HEART, I_MORE_CIRCLE, I_PLAY_CIRCLE, I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, FavoriteHeart } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { thinGlass } from '../ui/Glass';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { MiniBarView } from './MiniBar';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';

/** 一次最多往队列里放多少首（在线榜单动辄几百首，全塞进队列既慢也没意义） */
const MAX_SONGS: number = 500;

/**
 * 在线歌单 / 在线榜单详情
 *
 * 从推荐页点进来的那一页：顶部是在线歌单（或榜单）的封面与信息，
 * 下面「播放全部 / 全部收藏」，再下面是歌曲列表，点某一首就从这一首开始播。
 *
 * 数据来自宿主内置的平台接口（core/music/MusicList.ets），与音源无关：
 * 拿到 musicInfo 之后，播放链接照旧交给导入的源规则解析。
 * 榜单和歌单在这里是同一套界面，只有取数据的接口不同（kind 区分）。
 */
@Component
export struct OnlineListView {
  /** 'playlist' = 在线歌单，'board' = 在线榜单 */
  @Prop kind: string = 'playlist';
  /** 平台：kw / kg / mg / tx / wy */
  @Prop source: string = 'kw';
  /** 歌单 id 或榜单 bangid */
  @Prop listId: string = '';
  /** 进入时已知的名字（榜单一定有；歌单可能为空，加载后补齐） */
  @Prop listName: string = '';
  /** 进入时已知的封面（歌单有；榜单为空） */
  @Prop listCover: string = '';
  @Prop bottomInset: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @State songs: SongItem[] = [];
  @State info: LxListInfo = { name: '', img: '', desc: '', author: '', playCount: '' };
  @State total: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State error: string = '';
  @State page: number = 0;
  /** 封面懒解析好后版本号会变，订阅它把列表重画一遍 */
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  /** 「添加到歌单」选歌单面板 */
  @State pickerOpen: boolean = false;
  @State pending: SongItem | null = null;
  @State candidates: PlaylistSummary[] = [];
  /** 懒加载数据源：在线榜单可能上千首，一次性建完所有行会卡 */
  private listSource: SongListSource = new SongListSource();

  aboutToAppear(): void {
    void this.load(1, false);
  }

  private title(): string {
    if (this.info.name.length > 0) {
      return this.info.name;
    }
    return this.listName;
  }

  private cover(): string {
    if (this.info.img.length > 0) {
      return this.info.img;
    }
    return this.listCover;
  }

  private async load(page: number, append: boolean): Promise<void> {
    if (append) {
      if (this.loadingMore || this.loading) {
        return;
      }
      this.loadingMore = true;
    } else {
      this.loading = true;
      this.error = '';
    }
    try {
      const detail: LxListDetail = this.kind === 'board'
        ? await getBoardSongs(this.source, this.listId, page, this.listName)
        : await getPlaylistDetail(this.source, this.listId, page);
      const quality: string = PlaySession.getInstance().quality;
      const items: SongItem[] = [];
      for (const music of detail.list) {
        items.push(songFromSearch(music, quality));
      }
      this.songs = append ? this.songs.concat(items) : items;
      this.listSource.setItems(this.songs);
      this.total = detail.total > 0 ? detail.total : this.songs.length;
      if (this.info.name.length === 0 && detail.info.name.length > 0) {
        this.info = detail.info;
      } else if (this.info.img.length === 0 && detail.info.img.length > 0) {
        this.info = detail.info;
      } else if (this.info.author.length === 0 && detail.info.author.length > 0) {
        this.info = detail.info;
      }
      this.page = page;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
      this.loadingMore = false;
    }
  }

  /** 还有没有下一页：拉到的比总数少、且没到上限 */
  private hasMore(): boolean {
    return this.songs.length > 0 && this.songs.length < this.total && this.songs.length < MAX_SONGS;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 动作

  /** 从某一首开始播：整张列表成为播放队列（与歌单详情一致） */
  private playFrom(index: number): void {
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    void PlaySession.getInstance().setQueueAndPlay(this.songs, index);
  }

  private playSong(item: SongItem): void {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === item.id) {
        this.playFrom(i);
        return;
      }
    }
    void PlaySession.getInstance().setQueueAndPlay([item], 0);
  }

  /** 下载：交给下载管理排队 */
  private download(item: SongItem): void {
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

  /**
   * 行上的爱心：收藏 / 取消收藏
   *
   * 收藏入口从「更多」菜单搬到行上（爱心在两点左边）：菜单里的「添加到收藏」太深，
   * 榜单里连着收藏好几首要一路点菜单。
   */
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

  /** 下载全部：交给下载管理排队（已在列表里的不重复排） */
  private downloadAll(): void {
    if (this.songs.length === 0) {
      this.toast('列表里还没有歌曲');
      return;
    }
    const added: number = DownloadManager.getInstance().enqueueMany(this.songs);
    if (added === 0) {
      this.toast('这些歌都已经在下载列表里了');
      return;
    }
    this.toast(`已加入下载 ${added} 首，可在「我的 - 下载管理」查看进度`);
  }

  private collectAll(): void {
    if (this.songs.length === 0) {
      this.toast('列表里还没有歌曲');
      return;
    }
    const added: number = PlaySession.getInstance().addFavorites(this.songs);
    this.toast(added > 0 ? `已收藏 ${added} 首` : '这些歌都已经在收藏里了');
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

  @Builder
  rowMenu(item: SongItem) {
    Menu() {
      MenuItem({ content: '播放' })
        .onClick(() => {
          this.playSong(item);
        })
      MenuItem({ content: '下载' })
        .onClick(() => {
          this.download(item);
        })
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
    }
    .font({ size: 16 })
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: C_DIVIDER,
      startMargin: LengthMetrics.vp(14),
      endMargin: LengthMetrics.vp(14),
    })
  }

  // ------------------------------------------------------------ 顶部信息

  @Builder
  header() {
    Column({ space: 12 }) {
      CoverArt({
        url: this.cover(),
        name: this.title(),
        art: this.cover().length === 0,
        boxSize: 132,
        radius: 24,
      })

      Text(this.title())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')

      Row({ space: 8 }) {
        Text(platformName(this.source))
          .fontSize(12)
          .fontColor(C_RED)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor('#14E33B3B')
        if (this.info.author.length > 0) {
          Text(this.info.author)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.info.playCount.length > 0) {
          Text(`· ${this.info.playCount}`)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
        }
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')

      if (this.info.desc.length > 0) {
        Text(this.info.desc)
          .fontSize(12.5)
          .fontColor(C_TEXT_WEAK)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 4, right: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20, top: 18, bottom: 14 })
  }

  @Builder
  actionRow() {
    Row({ space: 12 }) {
      Row({ space: 6 }) {
        IconGlyph({ symbol: I_PLAY_CIRCLE, iconSize: 22, color: Color.White })
        Text('播放全部')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
        Text(`${this.songs.length}`)
          .fontSize(12.5)
          .fontColor('#D9FFFFFF')
      }
      .layoutWeight(1)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor(C_RED)
      .onClick(() => {
        this.playFrom(0);
      })

      Row({ space: 6 }) {
        IconGlyph({ symbol: I_HEART, iconSize: 20, color: C_RED })
        Text('全部收藏')
          .fontSize(15)
          .fontColor(C_RED)
      }
      .height(46)
      .padding({ left: 16, right: 16 })
      .borderRadius(23)
      .backgroundColor('#14E33B3B')
      .onClick(() => {
        this.collectAll();
      })

      // 下载全部：列表里有几十上百首，一个个点太费事
      Row() {
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 20, color: C_RED })
      }
      .width(46)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor('#14E33B3B')
      .onClick(() => {
        this.downloadAll();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  statusBlock() {
    Column({ space: 10 }) {
      if (this.loading) {
        Text('正在加载…')
          .fontSize(15)
          .fontColor(C_TEXT_SUB)
      } else if (this.error.length > 0) {
        Text(this.error)
          .fontSize(14)
          .fontColor(C_TEXT_SUB)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .padding({ left: 28, right: 28 })
        Text('点击重试')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_RED)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(18)
          .backgroundColor('#14E33B3B')
          .onClick(() => {
            void this.load(1, false);
          })
      } else {
        Text('列表里还没有歌曲')
          .fontSize(15)
          .fontColor(C_TEXT_SUB)
      }
    }
    .width('100%')
    .padding({ left: 32, right: 32, top: 50, bottom: 20 })
  }

  @Builder
  songRow(item: SongItem, index: number) {
    Row({ space: 12 }) {
      CoverArt({
        url: CoverStore.getInstance().coverFor(item.musicInfoJson, item.coverUrl),
        name: item.name,
        art: item.art,
        boxSize: 50,
        radius: 12,
      })

      Column({ space: 4 }) {
        Text(item.name)
          .fontSize(F_ITEM)
          .fontColor(this.currentId === item.id ? C_RED : C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (item.singer.length > 0) {
          Text(item.singer)
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

      if (this.currentId === item.id) {
        IconGlyph({ symbol: I_VOLUME, iconSize: 19, color: C_RED })
      }
      // 收藏搬到行上（爱心在两点左边），菜单里不再有「添加到收藏」
      FavoriteHeart({
        songId: item.id,
        onToggle: () => {
          this.toggleFavorite(item);
        },
      })
      IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: C_TEXT_WEAK })
        .bindMenu(this.rowMenu(item))
    }
    .width('100%')
    .height(72)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.playFrom(index);
    })
    .bindContextMenu(this.rowMenu(item), ResponseType.LongPress)
  }

  build() {
    // 迷你播放条浮在列表之上（与歌单详情同一套观感）
    Stack({ alignContent: Alignment.Bottom }) {
      List() {
        ListItem() {
          this.header()
        }

        ListItem() {
          this.actionRow()
        }

        if (this.songs.length === 0) {
          ListItem() {
            this.statusBlock()
          }
        } else {
          // 懒加载：在线榜单动辄几百首，一次性建完所有行会卡
          LazyForEach(this.listSource, (item: SongItem, index: number) => {
            ListItem() {
              Column() {
                this.songRow(item, index)
                if (index < this.songs.length - 1) {
                  Divider()
                    .strokeWidth(0.6)
                    .color(C_DIVIDER)
                    .margin({ left: 78 })
                }
              }
              .width('100%')
            }
          }, (item: SongItem, index: number) => `${index}_${item.id}`)

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
                    void this.load(this.page + 1, true);
                  })
              }
              .width('100%')
              .padding({ top: 14, bottom: 14 })
            }
          } else if (this.hasMore()) {
            ListItem() {
              Text(this.loadingMore ? '正在加载更多…' : '上拉加载更多')
                .fontSize(13)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 14, bottom: 14 })
            }
          } else {
            ListItem() {
              Text(`共 ${this.songs.length} 首`)
                .fontSize(12.5)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 14, bottom: 14 })
            }
          }
        }

        // 给悬浮的迷你播放条让位
        ListItem() {
          Column().height(this.bottomInset + HDS_BAR_HEIGHT + 26).width('100%')
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .onReachEnd(() => {
        if (this.hasMore() && !this.loadingMore && this.error.length === 0) {
          void this.load(this.page + 1, true);
        }
      })

      Column() {
        Row() {
          MiniBarView({
            forceExpanded: true,
            onOpenPlayer: this.onOpenPlayer,
            onOpenQueue: this.onOpenQueue,
          })
        }
        .width('100%')
        .height(HDS_BAR_HEIGHT)
        .attributeModifier(thinGlass(HDS_BAR_HEIGHT / 2))
        .clip(true)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: this.bottomInset + 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
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
