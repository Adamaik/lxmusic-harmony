import { LengthMetrics } from '@kit.ArkUI';
import { K_CURRENT_ID, K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
import { LOVE_LIST_NAME } from '../core/sync/SyncTypes';
import { C_BG, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_DOWNLOAD, I_HEART, I_MORE_CIRCLE, I_PLAY_CIRCLE, I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, FavoriteHeart } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { MiniBarView } from './MiniBar';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';

/**
 * 歌单详情（点歌单进来的那一页）
 *
 * 对应洛雪点开歌单后的界面：顶部是歌单封面 + 名称 + 曲目数，
 * 下面「播放全部」，再下面是歌单里的歌曲，点某一首就从这一首开始播。
 * 点歌单**不再**直接「全部播放 + 弹播放列表」——那是播放列表（队列）的入口，
 * 歌单本身要先能看、能挑。
 *
 * 歌单数据由同步模块（LocalLibrary）持有，所以同步服务端改了歌单（改名 / 加歌 / 删歌）
 * 这里也要跟着变：订阅 K_LIBRARY_VERSION / K_SYNC_DATA_VERSION 重新读一次。
 */
@Component
export struct PlaylistDetailView {
  @Prop playlistId: string = '';
  @Prop playlistName: string = '';
  @Prop bottomInset: number = 0;
  /** 页面主滚动容器，由壳层传进来（HDS 标题栏的滚动渐变要绑它，见 Index.titleBarOptions） */
  scroller: Scroller = new Scroller();
  /** 玻璃厚度档位（外观设置）：页内那层悬浮迷你播放条的毛玻璃跟着它变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @State songs: SongItem[] = [];
  @State title: string = '';
  /** 懒加载数据源：只建屏幕上可见的那几行 */
  private source: SongListSource = new SongListSource();
  /** 「添加到歌单」选歌单面板 */
  @State pickerOpen: boolean = false;
  @State pending: SongItem | null = null;
  @State candidates: PlaylistSummary[] = [];
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('refresh') syncVersion: number = 0;
  /** 封面懒解析好后版本号会变，订阅它把列表重画一遍 */
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;

  /** 最近一次触摸点：删除时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const library = SyncManager.getInstance().getLibrary();
    this.songs = library.playlistSongs(this.playlistId);
    this.source.setItems(this.songs);
    this.title = this.playlistName;
    if (library.isBuiltinPlaylist(this.playlistId)) {
      // 内置收藏歌单的名字固定
      this.title = library.favoritePlaylistSummary().name;
      return;
    }
    // 歌单在别的设备上改了名，标题跟着走
    for (const item of library.playlistSummaries()) {
      if (item.id === this.playlistId) {
        this.title = item.name;
        break;
      }
    }
  }

  /** 从某一首开始播：整张歌单成为播放队列（与洛雪一致） */
  private playFrom(index: number): void {
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    void PlaySession.getInstance().setQueueAndPlay(this.songs, index);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 行尾菜单里的六个动作

  /** 播放：这首歌在歌单里的位置当起点 */
  private playSong(item: SongItem): void {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === item.id) {
        this.playFrom(i);
        return;
      }
    }
    void PlaySession.getInstance().setQueueAndPlay([item], 0);
  }

  /** 下载：交给下载管理排队（设置里的文件名格式 / 保存位置都生效） */
  private download(item: SongItem): void {
    // 本地歌已经在本机了（菜单里也不显示这一项，这里只作兜底）
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    const manager = DownloadManager.getInstance();
    if (!manager.isReady()) {
      this.toast('下载管理没准备好，稍后再试');
      return;
    }
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
   * 收藏入口从「更多」菜单搬到行上（爱心在两点左边），所以这里不再有重复的菜单项。
   * 内置收藏歌单里取消收藏 = 把这首歌从歌单里去掉，所以照样要 refresh 一次。
   */
  private toggleFavorite(item: SongItem): void {
    const session = PlaySession.getInstance();
    if (session.isFavorite(item.id)) {
      if (session.removeFavorite(item.id)) {
        this.toast(`已取消收藏：${item.name}`);
        this.refresh();
      }
      return;
    }
    if (session.addFavorite(item)) {
      this.toast(`已添加到收藏：${item.name}`);
    }
  }

  /** 添加到播放列表：追加到队尾（队列就是洛雪的「试听列表」，会同步出去） */
  private addToQueue(item: SongItem): void {
    PlaySession.getInstance().addToQueue(item);
    this.toast(`已添加到播放列表：${item.name}`);
  }

  /** 添加到下一个播放：插到当前这首的后面；列表里还没有正在播放的就当追加 */
  private addToNext(item: SongItem): void {
    const session = PlaySession.getInstance();
    const hasCurrent: boolean =
      session.currentIndex >= 0 && session.currentIndex < session.queue.length;
    session.addToQueue(item, true);
    this.toast(hasCurrent ? `已设为下一首播放：${item.name}` : `播放列表是空的，已加入：${item.name}`);
  }

  private removeFromPlaylist(item: SongItem): void {
    const library = SyncManager.getInstance().getLibrary();
    const builtin: boolean = library.isBuiltinPlaylist(this.playlistId);
    if (builtin) {
      // 内置收藏歌单里删歌 = 取消收藏：走会话的收藏接口，
      // 同步方式与官方一致（整份 love 列表覆盖），也不会顺带把播放队列镜像一遍
      PlaySession.getInstance().removeFavorite(item.id);
    } else {
      library.removeMusicFromPlaylist(this.playlistId, [item.id]);
    }
    // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
    dustBus.spray(this.dustX, this.dustY);
    this.toast(builtin ? `已取消收藏「${item.name}」` : `已从歌单中删除「${item.name}」`);
    this.refresh();
  }

  // ------------------------------------------------------------ 添加到歌单（选歌单面板）

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

  @Builder
  rowMenu(item: SongItem) {
    Menu() {
      MenuItem({ content: '播放' })
        .onClick(() => {
          this.playSong(item);
        })
      // 本地歌已经在本机了，下载这一项对它没有意义
      if (!isLocalSong(item)) {
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
      MenuItem({ content: '从歌单中删除' })
        .onClick(() => {
          this.removeFromPlaylist(item);
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

  @Builder
  header() {
    Row({ space: 14 }) {
      CoverArt({ url: '', name: this.title, art: false, boxSize: 86, radius: 18 })

      Column({ space: 8 }) {
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(`${this.songs.length} 首`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
  }

  @Builder
  playAllRow() {
    Row({ space: 12 }) {
      IconGlyph({ symbol: I_PLAY_CIRCLE, iconSize: 46, color: C_RED })

      Text('播放全部')
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
      Text(`${this.songs.length}`)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      // 批量收藏：把这张歌单里的歌一次全部加进收藏（只上行一次同步）。
      // 内置收藏歌单里不显示 —— 它里面的歌本来就都收藏过了。
      // 子组件的点击会吃掉整行的点击，点它不会顺带播放。
      if (!this.isBuiltin()) {
        Row({ space: 4 }) {
          IconGlyph({ symbol: I_HEART, iconSize: 19, color: C_RED })
          Text('全部收藏')
            .fontSize(F_SUB)
            .fontColor(C_RED)
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(16)
        .backgroundColor('#14E33B3B')
        .onClick(() => {
          this.collectAll();
        })
      }

      // 下载这个歌单里的全部歌曲（已在下载列表里的不会重复排）
      Row() {
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 19, color: C_RED })
      }
      .padding({ left: 9, right: 9, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor('#14E33B3B')
      .onClick(() => {
        this.downloadAll();
      })
    }
    .width('100%')
    .height(70)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.playFrom(0);
    })
  }

  /** 是不是内置收藏歌单（它里面的歌都已收藏，收藏相关入口要藏起来） */
  private isBuiltin(): boolean {
    return SyncManager.getInstance().getLibrary().isBuiltinPlaylist(this.playlistId);
  }

  /** 歌单里的歌批量加进收藏，返回加进去几首 */
  /** 下载全部：交给下载管理排队（已在列表里的不重复排） */
  private downloadAll(): void {
    if (this.songs.length === 0) {
      this.toast('歌单里还没有歌曲');
      return;
    }
    // 本地歌跳过（已经在本机了）：只把在线歌排进下载队列
    const online: SongItem[] = [];
    let localCount: number = 0;
    for (const item of this.songs) {
      if (isLocalSong(item)) {
        localCount++;
      } else {
        online.push(item);
      }
    }
    if (online.length === 0) {
      this.toast('这个歌单里都是本地歌，不需要下载');
      return;
    }
    const added: number = DownloadManager.getInstance().enqueueMany(online);
    if (added === 0) {
      this.toast('这些歌都已经在下载列表里了');
      return;
    }
    const skipped: string = localCount > 0 ? `（跳过 ${localCount} 首本地歌）` : '';
    this.toast(`已加入下载 ${added} 首${skipped}，可在「我的 - 下载管理」查看进度`);
  }

  private collectAll(): void {
    if (this.songs.length === 0) {
      this.toast('这个歌单还没有歌曲');
      return;
    }
    const added: number = PlaySession.getInstance().addFavorites(this.songs);
    this.toast(added > 0
      ? `已把 ${added} 首歌添加到${LOVE_LIST_NAME}`
      : `这个歌单里的歌都已经在${LOVE_LIST_NAME}里了`);
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
      // ⋮ 点开菜单（长按整行同一个菜单）；子组件的点击会吃掉整行的点击，不会误触播放
      IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: C_TEXT_WEAK })
        .bindMenu(this.rowMenu(item))
    }
    .width('100%')
    .height(72)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.playFrom(index);
    })
    .onTouch((event: TouchEvent) => {
      this.rememberTouch(event);
    })
    .bindContextMenu(this.rowMenu(item), ResponseType.LongPress)
  }

  /** 记住这次触摸的位置：行菜单里的删除拿它当粒子飘散的起点 */
  private rememberTouch(event: TouchEvent): void {
    const point: DustPoint | null = dustPointOf(event);
    if (point !== null) {
      this.dustX = point.x;
      this.dustY = point.y;
    }
  }

  build() {
    // 迷你播放条浮在列表之上（不是另占一行）：滚动的歌曲从它下面透过，
    // 毛玻璃才有东西可模糊——HDS 那条悬浮栏也是压在内容上的观感。
    Stack({ alignContent: Alignment.Bottom }) {
      List({ scroller: this.scroller }) {
        ListItem() {
          this.header()
        }

        ListItem() {
          this.playAllRow()
        }

        if (this.songs.length === 0) {
          ListItem() {
            EmptyState({
              text: '这个歌单还没有歌曲',
              hint: '可以在洛雪桌面端 / 移动端把歌加进来，同步后就会出现',
              topPadding: 56,
            })
          }
        } else {
          // 懒加载：歌单动辄几百首，一次性建完所有行既卡又占内存
          // （每行还要建封面并解析封面，请求堆多了会闪退）。
          // 平铺行（不套 CARD 卡片组）：卡片自己还要左右各缩进 16，行内又缩进 16，
          // 歌曲封面就会比顶部歌单封面、「播放全部」多缩一档，三个左边缘对不齐。
          LazyForEach(this.source, (item: SongItem, index: number) => {
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
        }

        // 给悬浮的迷你播放条让位：最后一行能滚到栏的上方，而不是被它压住
        ListItem() {
          Column().height(this.bottomInset + HDS_BAR_HEIGHT + 26).width('100%')
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')

      /**
       * 迷你播放条
       *
       * 这一页不在页签体系里，HdsTabs 那条迷你栏不在，所以单独挂一条；观感必须和
       * 页签里那条一致，否则同一个控件两个样子。做法是把 HDS 悬浮栏的样子照抄过来：
       *   - 几何：左右边距 12、离手势条 10、栏高 56（共享常量 HDS_BAR_HEIGHT）、胶囊圆角
       *   - 表面：系统的玻璃材质色（sys.color.glass_material_mask_primary）打底 + 毛玻璃
       *     + 系统玻璃描边色 + 轻阴影（见 ui/Glass.ets）
       * 注意这里不能用 uiMaterial 沉浸材质：官方限制普通组件只有「Navigation 标题栏 /
       * 底部 TabBar / 弹窗」区域吃得到材质，页面内容区设了也不渲染（会画成空的）。
       */
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
        .attributeModifier(thinGlass(HDS_BAR_HEIGHT / 2, false, '', this.materialLevel))
        .systemMaterial(immersiveMaterialFor(this.materialLevel))
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
