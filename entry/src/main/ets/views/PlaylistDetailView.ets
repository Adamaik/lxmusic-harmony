import { LengthMetrics } from '@kit.ArkUI';
import { K_CURRENT_ID, K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
import { C_BG, C_DIVIDER, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CIRCLE, I_DOWNLOAD, I_MORE_CIRCLE, I_PLAY_CIRCLE, I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, FavoriteHeart } from '../ui/Widgets';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  SelectionActions, SelectSession, toggleSelected } from '../ui/Selection';
import { SongListSource } from '../ui/SongListSource';
import { immersiveMaterialForBar } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { K_BAR_MINI_WIDTH, barSideMarginFor } from '../ui/Layout';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { MiniBarView } from './MiniBar';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { isWebDavSong } from '../core/webdav/WebDavLibrary';

/** 页内悬浮迷你播放条的离底距离：与壳层那条 HdsTabs 悬浮栏同一个口径 */
const PAGE_BAR_BOTTOM_GAP: number = 10;
/**
 * 悬浮栏底下那层渐隐蒙版：色值与高度都取壳层 `gradientMask` 的那组
 *
 * **必须显式给**：`FloatingTabBarStyle.maskColor` 有默认值 `#CCF1F3F5`（80% 不透明），
 * 不设的话框架自己画一层比壳层重得多的灰蒙版，两条栏的观感就分家了。
 */
const PAGE_BAR_MASK_COLOR: string = '#66F1F1F2';
const PAGE_BAR_MASK_HEIGHT: number = 104;

/**
 * 多选能做的事
 *
 * 分发看**文案**不看下标（下面两张表的下标对不上）：普通歌单先给「收藏」，
 * 内置那张收藏歌单里**不给「收藏」** —— 它里面的歌本来就都在收藏里，
 * 留着那颗只会得到一句「都已经在收藏里了」。
 * 红字那枚主操作按歌单来：普通歌单是「从歌单中删除」，收藏歌单里是「取消收藏」。
 */
const BATCH_ACTIONS: string[] = ['收藏', '添加到歌单', '添加到播放列表', '下一个播放', '下载'];
const BATCH_ACTIONS_FAVORITE: string[] = ['添加到歌单', '添加到播放列表', '下一个播放', '下载'];

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
  /** 内容起始偏移：让封面 / 列表能滚进透明标题栏底下并从它下面透出来（同首页） */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /** 窗口宽度（vp）：与壳层同一份量，用来算悬浮栏的左右边距与「铺满」宽度（0 = 还没量到） */
  @Prop windowWidth: number = 0;
  /** 页面主滚动容器，由壳层传进来（HDS 标题栏的滚动渐变要绑它，见 Index.titleBarOptions） */
  scroller: Scroller = new Scroller();
  /** 玻璃厚度档位（外观设置）：页内那层悬浮迷你播放条的毛玻璃跟着它变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /** 页内迷你播放条的最大宽度：壳层按窗口宽度算好（0 = 窄屏不限，见 ui/Layout.ets） */
  @StorageLink(K_BAR_MINI_WIDTH) wideMiniBarWidth: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @State songs: SongItem[] = [];
  @State title: string = '';
  /**
   * 多选（长按任意一行进）
   *
   * 进去后点行 = 勾选，行尾的爱心 / 更多换成勾选圈；工具条不画在页里 ——
   * 顶栏换成「取消 + 已选中 N 项 + 全选」（壳层画，见 pages/Index.ets 的 pageTitleBar），
   * 底栏那条悬浮胶囊由迷你播放条换成批量操作条（见 miniBarTabBar）。两条都靠下面这个
   * @Watch 往全局会话里发布状态。
   * 这一页能做的事：收藏、加入歌单、加入播放列表 / 下一个播放、下载，
   * 以及红字那枚「从歌单中删除」（内置收藏歌单里是「取消收藏」）。
   */
  @State selecting: boolean = false;
  @State @Watch('syncSelectBar') selectedIds: string[] = [];
  /** 懒加载数据源：只建屏幕上可见的那几行 */
  private source: SongListSource = new SongListSource();
  /** 「添加到歌单」选歌单面板：要加入的歌（单选时一首，多选时是勾选的那些） */
  @State pickerOpen: boolean = false;
  @State pending: SongItem[] = [];
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
    // 歌曲列表变了（别处删了歌 / 同步覆盖）就把已经不存在的勾选摘掉，
    // 否则批量删除会带着幽灵条目算数
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.songs) {
        alive.push(item.id);
      }
      const pruned: string[] = pruneSelected(this.selectedIds, alive);
      if (pruned.length !== this.selectedIds.length) {
        this.selectedIds = pruned;
      }
    }
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

  /**
   * 底部悬浮栏里的内容
   *
   * 平时是迷你播放条；**多选时这条让给批量操作**（{@link SelectionActions}）——
   * 栏本身一个字都没改（几何与材质都在 {@link floatBarStyle} 里），只换内容，
   * 所以底栏看上去与迷你条是同一条胶囊。
   *
   * **只放内容，不给任何底**：胶囊的圆角、底色、材质由 Tabs 的 `barFloatingStyle`
   * 画。这里再叠一层自绘玻璃就把材质盖住了。
   *
   * `forceExpanded: true` —— 这一页没有页签栏跟它抢宽度，迷你栏始终是展开态。
   */
  @Builder
  miniBarTabBar() {
    Row() {
      if (this.selecting) {
        SelectionActions()
      } else {
        MiniBarView({
          forceExpanded: true,
          onOpenPlayer: this.onOpenPlayer,
          onOpenQueue: this.onOpenQueue,
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 底部悬浮栏的样式：材质 + 几何
   *
   * 与壳层那条 HdsTabs 悬浮栏**同一套口径**：左右边距取同一个函数（手机 12 / 600–840 给 16 /
   * ≥840 给 24）、离底距离同样是「手势条 + 10」、栏高同样 HDS_BAR_HEIGHT。
   * 唯一的差别是宽度 —— 见下面 barWidth 的说明，就是「把外面那条延长」。
   *
   * `systemMaterial` 必须是 `uiMaterial.ImmersiveMaterial` 实例（官方类型就是
   * `UIMaterial.ImmersiveMaterial`）。**不能**像早先在半模态上那样塞 HDS 的
   * `SystemMaterialParams`（`{materialType, materialLevel}`）：那是个普通对象，
   * `Material` 基类没有实例成员，结构上"恰好兼容"，编译不会报错，但运行时不构成材质
   * （见 ui/Glass.ets）。
   *
   * 设备没有材质能力位时给 `undefined`：悬浮胶囊仍由框架按默认样式画出来，
   * 不会变成一条透明带子（宁可退化，不能消失）。
   */
  private floatBarStyle(): FloatingTabBarStyle {
    const side: number = barSideMarginFor(this.windowWidth);
    const style: FloatingTabBarStyle = {
      barSideMargin: side,
      barBottomMargin: this.bottomInset + PAGE_BAR_BOTTOM_GAP,
      maskColor: PAGE_BAR_MASK_COLOR,
      maskHeight: PAGE_BAR_MASK_HEIGHT,
      systemMaterial: immersiveMaterialForBar(this.materialLevel),
    };
    /**
     * 宽度：**必须显式给**，否则 Tabs 会按自己的默认宽度画
     *
     * 壳层窄屏下迷你栏只占半条（另一半留给页签栏），所以 HDS 把它算成半个窗口宽；
     * 这一页没有页签栏，整条都该给迷你栏 —— 也就是「把外面那条迷你播放器延长到铺满」。
     * 不给 barWidth 时框架给的默认宽度不是铺满（早先那版就是被挤在一条窄胶囊里，
     * 内容又挤又丑），所以这里两种形态都把数字算出来：
     *   宽屏：与壳层那条迷你栏同宽（壳层算好写进 AppStorage，见 ui/Layout.ets）
     *   窄屏：窗口宽 － 左右边距（铺满）
     * 窗口宽度还没量到时（0）不给 barWidth，等量到下一帧自然会重画。
     */
    let barWidthVp: number = this.wideMiniBarWidth;
    if (barWidthVp <= 0 && this.windowWidth > 0) {
      barWidthVp = this.windowWidth - side * 2;
    }
    if (barWidthVp > 0) {
      const width: FloatingTabBarWidth = {
        smallBarWidth: barWidthVp,
        mediumBarWidth: barWidthVp,
        largeBarWidth: barWidthVp,
      };
      style.barWidth = width;
    }
    return style;
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
    // 本地歌已经在本机了、云端歌由播放缓存的边听边下负责（菜单里也不显示这一项）
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    if (isWebDavSong(item)) {
      this.toast(`「${item.name}」是云端音乐，播放时会自动缓存`);
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

  /** 选歌单面板要加入的歌（单选一首 / 多选勾选的那些） */
  private openPlaylistPicker(items: SongItem[]): void {
    if (items.length === 0) {
      this.toast('先勾选要加入歌单的歌');
      return;
    }
    this.pending = items;
    this.candidates = SyncManager.getInstance().getLibrary().playlistSummaries();
    this.pickerOpen = true;
  }

  /** 面板里那句说明：一首给歌名，多首给条数 */
  private pendingLabel(): string {
    const songs: SongItem[] = this.pending;
    if (songs.length === 0) {
      return '';
    }
    return songs.length === 1 ? songs[0].name : `已选 ${songs.length} 首`;
  }

  private addToPlaylist(playlist: PlaylistSummary): void {
    const songs: SongItem[] = this.pending;
    if (songs.length === 0) {
      return;
    }
    const added: number = SyncManager.getInstance().getLibrary().addMusicToPlaylist(playlist.id, songs);
    this.closePicker();
    this.exitSelecting();
    if (songs.length === 1) {
      this.toast(added > 0 ? `已添加到「${playlist.name}」` : `「${playlist.name}」里已经有这首歌了`);
      return;
    }
    this.toast(added > 0 ? `已把 ${added} 首加入「${playlist.name}」` : `「${playlist.name}」里已经有这些歌了`);
  }

  private createPlaylistAndAdd(name: string): void {
    const songs: SongItem[] = this.pending;
    if (name.length === 0 || songs.length === 0) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    const id: string = library.createPlaylist(name);
    library.addMusicToPlaylist(id, songs);
    this.closePicker();
    this.exitSelecting();
    this.toast(songs.length === 1 ? `已新建歌单「${name}」并添加` : `已新建歌单「${name}」并加入 ${songs.length} 首`);
  }

  private closePicker(): void {
    this.pickerOpen = false;
    this.pending = [];
  }

  // ------------------------------------------------------------ 多选

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /** 长按某一行进多选：顺手把长按的那条勾上 */
  private enterSelecting(item: SongItem): void {
    this.selecting = true;
    this.selectedIds = [item.id];
    // @Watch 只在**值真的变了**时才回调，进多选这一下不能只靠它（同一条二次长按就不变）
    this.publishSelectBar();
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
    SelectSession.getInstance().end();
  }

  /** 勾选数一变就把工具条的状态重发一遍（顶栏的标题、底栏主操作的可用态都在听） */
  private syncSelectBar(): void {
    if (!this.selecting) {
      return;
    }
    this.publishSelectBar();
  }

  /** 把「勾了几首 / 能做什么」交给全局会话：顶栏与底栏据此绘制 */
  private publishSelectBar(): void {
    SelectSession.getInstance().show(
      this.selectedIds.length,
      allSelectedOf(this.selectedIds, this.songs.length),
      selectActionsOf(this.batchActions(), this.isBuiltin() ? '取消收藏' : '从歌单中删除'),
      () => {
        this.exitSelecting();
      },
      () => {
        this.toggleSelectAll();
      },
      (index: number) => {
        this.onBatchAction(index);
      });
  }

  /** 页面被弹掉时把工具条一起收走（不然它会留在下一层页面上） */
  aboutToDisappear(): void {
    SelectSession.getInstance().end();
  }

  private toggleSelect(item: SongItem): void {
    this.selectedIds = toggleSelected(this.selectedIds, item.id);
  }

  private toggleSelectAll(): void {
    if (allSelectedOf(this.selectedIds, this.songs.length)) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.songs) {
      ids.push(item.id);
    }
    this.selectedIds = ids;
  }

  private selected(): SongItem[] {
    return selectedSongs(this.songs, this.selectedIds);
  }

  /** 当前这张歌单多选时能做什么（见 BATCH_ACTIONS 的说明） */
  private batchActions(): string[] {
    return this.isBuiltin() ? BATCH_ACTIONS_FAVORITE : BATCH_ACTIONS;
  }

  /**
   * 批量操作：按**会话里那一项的叫法**分发（底栏按下标回调，这里翻译回它是什么）
   *
   * 不按下标硬编码：底栏的排列是「各页面的操作 + 红字那枚主操作放最后」
   * （见 ui/Selection.ets 的 selectActionsOf），下标会随操作项数量变。
   */
  private onBatchAction(index: number): void {
    const actions: SelectAction[] = SelectSession.getInstance().actions;
    if (index < 0 || index >= actions.length) {
      return;
    }
    const targets: SongItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选歌曲');
      return;
    }
    const label: string = actions[index].label;
    if (label === '收藏') {
      this.toast(favoriteSongs(targets));
      return;
    }
    if (label === '添加到歌单') {
      this.openPlaylistPicker(targets);
      return;
    }
    if (label === '添加到播放列表') {
      this.toast(queueSongs(targets, false));
      this.exitSelecting();
      return;
    }
    if (label === '下一个播放') {
      this.toast(queueSongs(targets, true));
      this.exitSelecting();
      return;
    }
    if (label === '从歌单中删除' || label === '取消收藏') {
      this.removeSelected();
      return;
    }
    this.downloadSongs(targets);
  }

  /** 红字那枚主操作：从这张歌单里移除（内置收藏歌单里是取消收藏） */
  private removeSelected(): void {
    const targets: SongItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选要移除的歌');
      return;
    }
    const builtin: boolean = this.isBuiltin();
    const ids: string[] = [];
    for (const item of targets) {
      ids.push(item.id);
    }
    this.getUIContext().showAlertDialog({
      title: builtin ? '取消收藏' : '从歌单中删除',
      message: builtin
        ? `把勾选的 ${ids.length} 首从收藏里去掉？下载与本地文件都不受影响。`
        : `从「${this.title}」里删掉这 ${ids.length} 首？收藏与下载都不受影响。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: builtin ? '移出' : '删除',
          fontColor: C_RED,
          action: () => {
            let count: number = 0;
            if (builtin) {
              // 内置收藏歌单：一次性摘掉（逐首调 removeFavorite 会每首都上行一次同步）
              count = PlaySession.getInstance().removeFavorites(ids);
            } else {
              SyncManager.getInstance().getLibrary().removeMusicFromPlaylist(this.playlistId, ids);
              count = ids.length;
            }
            // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
            dustBus.spray(this.dustX, this.dustY);
            this.exitSelecting();
            this.refresh();
            this.toast(builtin ? `已取消收藏 ${count} 首` : `已从歌单中删除 ${count} 首`);
          },
        },
      ],
    });
  }

  @Builder
  rowMenu(item: SongItem) {
    Menu() {
      MenuItem({ content: '播放' })
        .onClick(() => {
          this.playSong(item);
        })
      // 本地歌已经在本机了，下载这一项对它没有意义
      if (!isLocalSong(item) && !isWebDavSong(item)) {
        MenuItem({ content: '下载' })
          .onClick(() => {
            this.download(item);
          })
      }
      MenuItem({ content: '添加到歌单' })
        .onClick(() => {
          this.openPlaylistPicker([item]);
        })
      MenuItem({ content: '添加到播放列表' })
        .onClick(() => {
          this.addToQueue(item);
        })
      MenuItem({ content: '添加到下一个播放' })
        .onClick(() => {
          this.addToNext(item);
        })
      // 内置收藏歌单里这一项就是取消收藏（歌单本身是 loveList，删歌 = 取消收藏）
      MenuItem({ content: this.isBuiltin() ? '取消收藏' : '从歌单中删除' })
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
      songName: this.pendingLabel(),
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

      // 下载这个歌单里的全部歌曲（已在下载列表里的不会重复排）
      Row() {
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 19, color: C_RED })
      }
      .padding({ left: 9, right: 9, top: 6, bottom: 6 })
      .borderRadius(16)
      .backgroundColor(C_RED_TINT)
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

  /**
   * 下载全部
   *
   * **先问一句再下**：整张歌单动辄几百首，点一下就把它们全排进下载队列太莽，
   * 所以在真排队之前一律弹一句确认。批量那一份在 {@link downloadSongs}
   * （多选里的「下载」共用它 —— 那是用户一首首勾出来的，不必再确认一遍）。
   */
  private downloadAll(): void {
    if (this.songs.length === 0) {
      this.toast('歌单里还没有歌曲');
      return;
    }
    const count: number = this.songs.length;
    this.getUIContext().showAlertDialog({
      title: '下载全部',
      message: `确定要把「${this.title}」里的 ${count} 首歌全部加入下载吗？可以在「我的 - 下载管理」里看进度。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '下载',
          fontColor: C_RED,
          action: () => {
            this.downloadSongs(this.songs);
          },
        },
      ],
    });
  }

  /**
   * 批量下载：本地歌（已经在本机）与云端歌（由播放缓存负责）都跳过，只把在线歌排进下载队列
   */
  private downloadSongs(songs: SongItem[]): void {
    const manager = DownloadManager.getInstance();
    if (!manager.isReady()) {
      this.toast('下载管理没准备好，稍后再试');
      return;
    }
    const online: SongItem[] = [];
    let skipped: number = 0;
    for (const item of songs) {
      if (isLocalSong(item) || isWebDavSong(item)) {
        skipped++;
      } else {
        online.push(item);
      }
    }
    if (online.length === 0) {
      this.toast('这些歌都是本地或云端音乐，不需要下载');
      return;
    }
    const added: number = manager.enqueueMany(online);
    this.exitSelecting();
    if (added === 0) {
      this.toast('这些歌都已经在下载列表里了');
      return;
    }
    const hint: string = skipped > 0 ? `（跳过 ${skipped} 首本地 / 云端音乐）` : '';
    this.toast(`已加入下载 ${added} 首${hint}，可在「我的 - 下载管理」查看进度`);
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

      if (this.selecting) {
        // 多选：行尾只留一个勾选圈（爱心 / 更多这时点一下就是误触）
        IconGlyph({
          symbol: this.isSelected(item.id) ? I_CHECK_CIRCLE : I_CIRCLE,
          iconSize: 22,
          color: this.isSelected(item.id) ? C_RED : C_TEXT_WEAK,
        })
          .accessibilityLevel('no')
      } else {
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
        // ⋮ 点开菜单（长按是进多选，见下面）；子组件的点击会吃掉整行的点击，不会误触播放
        IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: C_TEXT_WEAK })
          .bindMenu(this.rowMenu(item))
      }
    }
    .width('100%')
    .height(72)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelect(item);
        return;
      }
      this.playFrom(index);
    })
    .onTouch((event: TouchEvent) => {
      this.rememberTouch(event);
    })
    // 长按进多选（行菜单还在那颗「更多」上）：长按腾出来做多选，
    // 两个手势就不打架了 —— 与「我的」页那几个列表同一套
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.enterSelecting(item);
      }
    }))
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
    /**
     * 页面根容器是「只有一个页签的 Tabs」—— 为的是那条**官方认可的底部悬浮栏**
     *
     * 这一页是压在 HdsNavigation 路由栈上的 NavDestination，把壳层那条带迷你栏的
     * HdsTabs 整个盖住了，所以迷你播放条得自己挂一条。而沉浸光感有**生效范围**：
     * 除弹窗类组件外，普通组件只有落在「Navigation/NavDestination 标题栏」或
     * 「横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar」里才会渲染材质。
     * 早先把它当普通组件画在内容区，那一行 `.systemMaterial()` 其实是死的 ——
     * 运行时只得到一句
     *     `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
     *
     * 现在改用 Tabs **自带的悬浮栏材质**（`barFloatingStyle({ systemMaterial })`）：
     * 胶囊的圆角、边距、位置、材质全由框架画，我们只提供栏里的内容（MiniBarView），
     * 几何与观感和壳层那条 HdsTabs 悬浮栏是同一套口径。
     *
     * **别再往栏里叠自绘玻璃**：沉浸光感的视觉层级在 backgroundColor /
     * backgroundBlurStyle 之下，自己再画一层半透明底或毛玻璃就把材质整片盖住了 ——
     * 栏里现在只有内容，没有任何底。
     */
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Column() {
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
          // 内容可以滚进透明标题栏底下（壳层传来的 topInset 就是「状态栏 + 标题栏」）。
          // 多选时工具条在顶栏里，列表不用让位 —— 一直是同一段偏移。
          .contentStartOffset(this.topInset + 6)
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
      }
      .tabBar(this.miniBarTabBar())
    }
    // 横向 + 底部页签：这两个同样是沉浸光感生效范围的条件（见上面的说明）
    .vertical(false)
    .barMode(BarMode.Fixed)
    .scrollable(false)
    // 悬浮栏压在内容之上：滚动的歌曲从栏下透过，材质才有东西可折射、可模糊
    .barOverlap(true)
    .barHeight(HDS_BAR_HEIGHT)
    // 栏体那一条不要自己的底色（默认是一条灰白带）：观感全交给悬浮胶囊本身
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle(this.floatBarStyle())
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
