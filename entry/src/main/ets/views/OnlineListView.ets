import { LengthMetrics } from '@kit.ArkUI';
import { K_CURRENT_ID, PlaySession, PlaylistSummary, SongItem, songFromSearch } from '../core/player/PlaySession';
import { LxListDetail, LxListInfo, getBoardSongs, getPlaylistDetail, platformName } from '../core/music/MusicList';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { SyncManager } from '../core/sync/SyncManager';
import { CollectedPlaylists, K_COLLECTED_VERSION } from '../core/sync/CollectedPlaylists';
import { C_BG, C_DIVIDER, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CIRCLE, I_DOWNLOAD, I_HEART, I_HEART_FILLED,
  I_MORE_CIRCLE, I_PLAY_CIRCLE, I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, FavoriteHeart } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  SelectionActions, SelectSession, toggleSelected } from '../ui/Selection';
import { immersiveMaterialForBar } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { K_BAR_MINI_WIDTH, barSideMarginFor } from '../ui/Layout';
import { MiniBarView } from './MiniBar';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';

/** 一次最多往队列里放多少首（在线榜单动辄几百首，全塞进队列既慢也没意义） */
const MAX_SONGS: number = 500;

/**
 * 多选能做的事（与 `onBatchAction` 的下标同序）
 *
 * 红字那枚主操作是「收藏」（把勾选的歌收进收藏）；这里没有「从歌单中删除」这类 ——
 * 在线列表里的歌不在我们的库里，拿不掉，只能收藏 / 入库 / 下载。
 */
const MULTI_ACTIONS: string[] = ['添加到歌单', '添加到播放列表', '下一个播放', '下载'];

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
 * 在线歌单 / 在线榜单详情
 *
 * 从推荐页点进来的那一页：顶部是在线歌单（或榜单）的封面与信息，
 * 下面「播放全部 / 收藏」，再下面是歌曲列表，点某一首就从这一首开始播。
 * 名字只出现在封面下方那一处（导航栏不再重复一遍歌单名）。
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
  /** 内容起始偏移：让封面 / 列表能滚进透明标题栏底下并从它下面透出来（同首页） */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /** 窗口宽度（vp）：与壳层同一份量，用来算悬浮栏的左右边距与「铺满」宽度（0 = 还没量到） */
  @Prop windowWidth: number = 0;
  /**
   * 页面主滚动容器，由壳层（pages/Index.ets）传进来。
   *
   * HDS 标题栏的渐变模糊要知道「滚了多少」，靠的是 HdsNavDestination.bindToScrollable
   * 绑这个 Scroller：封面滚到标题栏底下时，返回键从浮在封面上变成浮在磨砂上。
   * 不传也能跑，只是标题栏不会有滚动渐变。
   */
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
  /** 「添加到歌单」的目标：单选是一首，多选时是勾选的那些 */
  @State pending: SongItem[] = [];
  @State candidates: PlaylistSummary[] = [];
  /**
   * 这张在线歌单在不在「我的 - 收藏歌单」里（**歌单级**的收藏，纯本地）
   *
   * 顶部那颗「收藏歌单」钮的状态跟着它。收藏歌单不参与同步（洛雪的协议里没有
   * 歌单这一级的收藏），所以这里不听同步的版本号，只订阅 CollectedPlaylists 发的
   * `K_COLLECTED_VERSION`。榜单没有这一枚（见 actionRow 的说明）。
   */
  @State collected: boolean = false;
  /**
   * 多选（长按任意一行进）
   *
   * 进去后点行 = 勾选，行尾的爱心 / 更多换成勾选圈；工具条不画在页里 ——
   * 顶栏换成「取消 + 已选中 N 项 + 全选」（壳层画，见 pages/Index.ets 的 pageTitleBar），
   * 底栏那条悬浮胶囊由迷你播放条换成批量操作条（见 miniBarTabBar）。两条都靠下面这个
   * @Watch 往全局会话里发布状态。
   * 这一页能做的事：收藏、加入歌单、加入播放列表 / 下一个播放、下载
   * （在线列表没有「从歌单中删除」—— 那些歌不在我们的库里，拿不掉）。
   */
  @State selecting: boolean = false;
  @State @Watch('syncSelectBar') selectedIds: string[] = [];
  /** 懒加载数据源：在线榜单可能上千首，一次性建完所有行会卡 */
  private listSource: SongListSource = new SongListSource();
  /** 收藏歌单在别处被改了（「我的」页里取消收藏）时把顶部那颗钮的状态同步过来 */
  @StorageLink(K_COLLECTED_VERSION) @Watch('onCollectedChanged') collectedVersion: number = 0;

  aboutToAppear(): void {
    this.loadCollected();
    void this.load(1, false);
  }

  private onCollectedChanged(): void {
    this.loadCollected();
  }

  private loadCollected(): void {
    this.collected = CollectedPlaylists.getInstance().isCollected(this.source, this.listId);
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
      // 拉回下一页 / 重试之后，把已经不在列表里的勾选摘掉，
      // 否则批量操作会带着幽灵条目算数
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

  /**
   * 下载全部
   *
   * **先问一句再下**：在线歌单动辄几百首，一点就把它们全排进下载队列太莽，
   * 所以在真排之前一律弹一句确认（与歌单详情页那颗「下载」同一个规矩）。
   */
  private downloadAll(): void {
    if (this.songs.length === 0) {
      this.toast('列表里还没有歌曲');
      return;
    }
    const count: number = this.songs.length;
    this.getUIContext().showAlertDialog({
      title: '下载全部',
      message: `确定要把这一页的 ${count} 首歌全部加入下载吗？可以在「我的 - 下载管理」里看进度。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '下载',
          fontColor: C_RED,
          action: () => {
            this.enqueueAll();
          },
        },
      ],
    });
  }

  /** 确认之后的真排队（已在列表里的不重复排） */
  private enqueueAll(): void {
    const added: number = DownloadManager.getInstance().enqueueMany(this.songs);
    if (added === 0) {
      this.toast('这些歌都已经在下载列表里了');
      return;
    }
    this.toast(`已加入下载 ${added} 首，可在「我的 - 下载管理」查看进度`);
  }

  /**
   * 收藏 / 取消收藏**整张在线歌单**
   *
   * 收进去之后出现在「我的」页歌单卡的「收藏歌单」那一段（与「自建歌单」并排、
   * 两段互斥）。存法见 core/sync/CollectedPlaylists：只记平台 + 歌单 id + 显示要用的
   * 那几项，纯本地、不参与同步。**注意与行上那颗爱心区分**：那是收藏的**歌**。
   */
  private toggleCollectPlaylist(): void {
    if (!this.collected) {
      // 已经导入到自建歌单里的不算收藏（互斥）：那种情况去「我的」里看那张歌单
      const imported = SyncManager.getInstance().getLibrary()
        .playlistBySourceListId(`${this.source}__${this.listId}`);
      if (imported !== null) {
        this.toast(`「${this.title()}」已经导入到我的歌单里了，不用再收藏`);
        return;
      }
    }
    const store = CollectedPlaylists.getInstance();
    const now: boolean = store.toggle({
      source: this.source,
      id: this.listId,
      name: this.title(),
      cover: this.cover(),
      meta: this.playlistMetaText(),
    });
    this.collected = now;
    this.toast(now
      ? `已收藏「${this.title()}」，在「我的 - 收藏歌单」里看`
      : `已取消收藏「${this.title()}」`);
  }

  /** 收藏记录里那条说明：作者 · 播放量 · 曲目数（能凑几项凑几项） */
  private playlistMetaText(): string {
    const parts: string[] = [];
    if (this.info.author.length > 0) {
      parts.push(this.info.author);
    }
    if (this.info.playCount.length > 0) {
      parts.push(this.info.playCount);
    }
    if (this.songs.length > 0) {
      parts.push(`${this.songs.length} 首`);
    }
    return parts.join(' · ');
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
      selectActionsOf(MULTI_ACTIONS, '收藏'),
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

  /**
   * 批量操作：按**会话里那一项的叫法**分发（底栏按下标回调，这里翻译回它是什么）
   *
   * 不按下标硬编码：底栏的排列是「各页面的操作 + 红字那枚主操作放最后」
   * （见 ui/Selection.ets 的 selectActionsOf），下标会随操作项数量变。
   */
  private onBatchAction(index: number): void {
    const list: SelectAction[] = SelectSession.getInstance().actions;
    if (index < 0 || index >= list.length) {
      return;
    }
    const targets: SongItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选歌曲');
      return;
    }
    const label: string = list[index].label;
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
    this.enqueueSongs(targets);
  }

  /** 批量下载勾选的（在线列表里的歌都是在线歌，直接排队） */
  private enqueueSongs(songs: SongItem[]): void {
    const manager = DownloadManager.getInstance();
    if (!manager.isReady()) {
      this.toast('下载管理没准备好，稍后再试');
      return;
    }
    const added: number = manager.enqueueMany(songs);
    this.exitSelecting();
    if (added === 0) {
      this.toast('这些歌都已经在下载列表里了');
      return;
    }
    this.toast(`已加入下载 ${added} 首，可在「我的 - 下载管理」查看进度`);
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
          .backgroundColor(C_RED_TINT)
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

      // 收藏歌单：把**整张**在线歌单收进「我的 - 收藏歌单」（歌单级的收藏，纯本地）。
      // 收进去之后出现在「我的」页歌单卡里「自建歌单 | 收藏歌单」的右边那一段。
      // 榜单没有这一枚 —— 榜单不是歌单（bangid 与歌单 id 不是一回事），收下来也没法再更新。
      // 行上那颗爱心是收藏**歌**，与这里不是一件事。
      if (this.kind === 'playlist') {
        Row({ space: 6 }) {
          IconGlyph({
            symbol: this.collected ? I_HEART_FILLED : I_HEART,
            iconSize: 20,
            color: C_RED,
            // 收藏 <-> 取消收藏是同一颗心的两种状态，用符号替换动效过渡
            replaceEffect: true,
          })
          Text(this.collected ? '已收藏' : '收藏歌单')
            .fontSize(15)
            .fontColor(C_RED)
        }
        .height(46)
        .padding({ left: 16, right: 16 })
        .borderRadius(23)
        .backgroundColor(C_RED_TINT)
        .onClick(() => {
          this.toggleCollectPlaylist();
        })
        .accessibilityText(this.collected ? '取消收藏这张歌单' : '收藏这张歌单')
        .accessibilityLevel('yes')
      }

      // 下载全部：列表里有几十上百首，一个个点太费事
      Row() {
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 20, color: C_RED })
      }
      .width(46)
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor(C_RED_TINT)
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
          .backgroundColor(C_RED_TINT)
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
        // ⋮ 点开菜单（长按是进多选，见下面）
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
    // 长按进多选（行菜单还在那颗「更多」上）：长按腾出来做多选，
    // 两个手势就不打架了 —— 与歌单详情页、本应用其它列表同一套
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.enterSelecting(item);
      }
    }))
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
   * 底部悬浮栏的样式：材质 + 几何（与歌单详情页同一套，改一处要一起改）
   *
   * 与壳层那条 HdsTabs 悬浮栏同一套口径：左右边距取同一个函数、离底距离同样是
   * 「手势条 + 10」、栏高同样 HDS_BAR_HEIGHT；差别只有宽度（见下面 barWidth）。
   *
   * `systemMaterial` 必须是 `uiMaterial.ImmersiveMaterial` 实例（官方类型就是
   * `UIMaterial.ImmersiveMaterial`），不能塞 HDS 的 `SystemMaterialParams` ——
   * 那是个普通对象，能编译过但运行时不构成材质（见 ui/Glass.ets）。
   * 设备没有材质能力位时给 `undefined`，悬浮胶囊仍由框架按默认样式画出来。
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
    // 宽度必须显式给（否则框架按自己的默认宽度画，内容会被挤在一条窄胶囊里）：
    // 宽屏与壳层那条迷你栏同宽；窄屏铺满（窗口宽 － 左右边距），也就是「把外面那条延长」
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

  build() {
    // 迷你播放条浮在列表之上（与歌单详情同一套做法：Tabs 自带的悬浮栏，见 miniBarTabBar）
    Stack({ alignContent: Alignment.Bottom }) {
      /**
       * 页面主体是「只有一个页签的 Tabs」—— 为的是那条**官方认可的底部悬浮栏**
       *
       * 这一页是压在 HdsNavigation 路由栈上的 NavDestination，把壳层那条带迷你栏的
       * HdsTabs 整个盖住了，所以迷你播放条得自己挂一条。而沉浸光感有**生效范围**：
       * 除弹窗类组件外，普通组件只有落在「Navigation/NavDestination 标题栏」或
       * 「横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar」里才会渲染材质。
       * 早先把它当普通组件画在内容区，那一行 `.systemMaterial()` 其实是死的 ——
       * 运行时只得到一句
       *     `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
       *
       * 现在用 Tabs 自带的悬浮栏材质（`barFloatingStyle({ systemMaterial })`）：胶囊的
       * 圆角、边距、位置、材质全由框架画，我们只提供栏里的内容，几何与观感和歌单详情页、
       * 以及壳层那条 HdsTabs 悬浮栏是同一套口径。**别在栏里再叠自绘玻璃**：材质层级在
       * backgroundColor / backgroundBlurStyle 之下。
       */
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          Column() {
          List({ scroller: this.scroller }) {
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
          // 内容可以滚进透明标题栏底下（壳层传来的 topInset 就是「状态栏 + 标题栏」）。
          // 多选时工具条在顶栏里，列表不用让位 —— 一直是同一段偏移。
          .contentStartOffset(this.topInset + 6)
          .layoutWeight(1)
          .width('100%')
          .onReachEnd(() => {
            if (this.hasMore() && !this.loadingMore && this.error.length === 0) {
              void this.load(this.page + 1, true);
            }
          })
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
        this.pending = [];
      },
    })
  }
}
