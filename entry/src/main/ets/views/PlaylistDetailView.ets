import { LengthMetrics } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { K_CURRENT_ID, K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem,
  songFromSearch } from '../core/player/PlaySession';
import { getPlaylistDetailAll, LxListDetail, PlaylistDetailProgress } from '../core/music/MusicList';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
// AddMusicResult：加歌的返回值从「加进去几首」改成了 { added, skipped }，要显式标类型
// DuplicateGroup：「检查重复歌曲」扫出来的分组（保留哪一首由库里的 keepId 定）
import { AddMusicResult, DuplicateGroup } from '../core/sync/LocalLibrary';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM,
  F_SUB } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CIRCLE, I_CLOSE, I_DOWNLOAD, I_MORE, I_MORE_CIRCLE, I_PLAY_CIRCLE, I_SEARCH,
  I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, FavoriteHeart, SingerLink } from '../ui/Widgets';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  SelectionActions, K_SELECT_END_SEQ, SelectSession, toggleSelected } from '../ui/Selection';
import { SongListSource } from '../ui/SongListSource';
import { glassLight, harmony7ApiReady, immersiveMaterialForBar, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL, K_NAV_FOLLOW_HAND } from '../core/settings/AppearanceSettings';
import { HDS_BAR_HEIGHT } from '../ui/Hds';
import { K_BAR_MINI_WIDTH, barSideMarginFor, contentColumnsFor } from '../ui/Layout';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { MiniBarView } from './MiniBar';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';
import { DuplicateSongsSheet } from './DuplicateSongsSheet';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { ExportOutcome, PlaylistPort } from '../core/local/PlaylistPort';
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
 * 一条歌是否命中关键词（歌名 + 歌手，大小写不敏感）
 *
 * 关键词调用方已经 trim + toLowerCase，这里只把两个字段也降到小写再比：
 * 中文没有大小写，需要这一步的是英文歌名 / 歌手（「Taylor Swift」敲 taylor 也得中）。
 * 抽成模块级纯函数放在循环外，1000 首逐字过滤时省掉方法查表与闭包分配。
 */
function matchKeyword(item: SongItem, key: string): boolean {
  if (item.name.toLowerCase().includes(key)) {
    return true;
  }
  return item.singer.toLowerCase().includes(key);
}

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
  /**
   * 悬浮栏左右跟手（设置 - 外观）：这一页那条播放条跟着同一档走
   *
   * 与壳层底部那条同一个开关，只是这一页走的是 ArkUI 原生的
   * `Tabs.barFloatingStyle`（`FloatingTabBarStyle.adaptToHandedness`，API 26 起），
   * 所以要在这里再接一次（见 PanePage 里同一项的说明）。
   */
  @StorageLink(K_NAV_FOLLOW_HAND) followHand: boolean = true;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  @State songs: SongItem[] = [];
  /**
   * 整张歌单的歌（**全量**，顺序就是同步模块给的那一份）
   *
   * `songs` 改成「当前该显示的那些」：没搜索时与它同一份，搜索时是过滤结果。
   * 列表、播放全部、多选、下载全部一律以 `songs` 为准 —— 所见即所操作，
   * 不会出现「列表只剩 3 首、点播放全部却把 800 首塞进队列」这种错位。
   * 它不是 @State：每次变化都跟着重写 `songs`，重绘由 `songs` 通知。
   */
  private allSongs: SongItem[] = [];
  /** 搜索框是否展开：头部那颗放大镜点开 / 再点收起 */
  @State searching: boolean = false;
  /** 搜索关键词：只跟输入框走，过滤结果在 applyFilter 里算 */
  @State keyword: string = '';
  @State title: string = '';
  /** 正在「从原歌单更新」：按钮禁用，避免连点重复拉取 */
  @State updating: boolean = false;
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
  /**
   * 多选被全局收尾的序号（见 ui/Selection.ets 的 K_SELECT_END_SEQ）
   *
   * 不依赖 onCancel 回调：壳层点叉 / 会话被别处 end 时，序号 +1，这里无条件把自己
   * 的多选状态清掉。真机上「顶栏退了、行尾还是勾选圈」就是回调链断掉的现场。
   */
  @StorageLink(K_SELECT_END_SEQ) @Watch('onSelectEnded') selectEndSeq: number = 0;
  /** 懒加载数据源：只建屏幕上可见的那几行 */
  private source: SongListSource = new SongListSource();
  /** 「添加到歌单」选歌单面板：要加入的歌（单选时一首，多选时是勾选的那些） */
  @State pickerOpen: boolean = false;
  @State pending: SongItem[] = [];
  @State candidates: PlaylistSummary[] = [];
  /**
   * 「检查重复歌曲」面板
   *
   * 只有查出重复时才打开（一组都没有就只 toast 一句，不弹空面板）。
   * 分组存在这里、面板只管确认：确认后由本页调 `removeDuplicateSongs` 再 `refresh()`，
   * 面板那一刻已经被系统收掉了（见 views/DuplicateSongsSheet.ets 的说明）。
   */
  @State dupOpen: boolean = false;
  @State dupGroups: DuplicateGroup[] = [];
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('refresh') syncVersion: number = 0;
  /** 封面懒解析好后版本号会变，订阅它把列表重画一遍 */
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;

  /** 最近一次触摸点：删除时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;

  aboutToAppear(): void {
    // 这一页刚出现，不可能已经在多选，所以本页与全局会话两边一起归零：
    //   - 新实例本来是默认值，这两行只是把「复用实例再次出现」这种情形也拉回一致 ——
    //     否则可能出现 selecting=true（页内画着勾选圈）而顶栏已是普通标题的反向错位；
    //   - 全局会话是单例，上一份页面实例留下的「已选中 N 项」与指向旧实例的取消回调
    //     会跟着进这一页（目的地内容被重建 / 页面被回收后再进来时就是这样）。
    // 先归零再读数据（end() 幂等：没在多选时只是把结束态再写一遍，顺带让壳层标题栏重算）。
    this.selecting = false;
    this.selectedIds = [];
    SelectSession.getInstance().end();
    this.refresh();
  }

  private refresh(): void {
    const library = SyncManager.getInstance().getLibrary();
    this.allSongs = library.playlistSongs(this.playlistId);
    // 数据变了也按**当前关键词**重算一次再灌回列表：搜索态下别处删掉一首，
    // 它能立刻从结果里消失，不用等用户再敲一遍关键词
    this.applyFilter();
    // 歌曲列表变了（别处删了歌 / 同步覆盖）就把已经不存在的勾选摘掉，
    // 否则批量删除会带着幽灵条目算数。按**全量**摘：搜索态下按过滤结果摘会误删勾选
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.allSongs) {
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

  // ------------------------------------------------------------ 歌单内搜索

  /**
   * 按「歌名 + 歌手」重算可见歌曲，并灌回懒加载数据源
   *
   * 只替换数组引用：不重建 SongItem、不碰封面解析（重解析封面等于每敲一个字发一批请求）。
   * 1000 首也就是一次纯数组遍历 + 两次 toLowerCase，毫秒级，输入框不会掉字。
   * `this.songs` 换掉后 @State 负责通知页面，而 LazyForEach 必须靠 source.setItems
   * 才会 onDataReloaded（见 ui/SongListSource.ets），两件事都要做。
   */
  private applyFilter(): void {
    const key: string = this.keyword.trim().toLowerCase();
    if (key.length === 0) {
      this.songs = this.allSongs;
    } else {
      // 顺着 allSongs 走：过滤结果天然保持原排序（同步模块给的顺序 = 原列表顺序）
      const matched: SongItem[] = [];
      for (const item of this.allSongs) {
        if (matchKeyword(item, key)) {
          matched.push(item);
        }
      }
      this.songs = matched;
    }
    this.source.setItems(this.songs);
  }

  /** 输入框每一次变化：立刻重算（见 applyFilter 的性能说明） */
  private onKeywordChanged(value: string): void {
    if (this.keyword === value) {
      return;
    }
    this.keyword = value;
    this.applyFilter();
  }

  /** 当前是否真的在筛选（空关键词等同没筛，列表就是原来那份全量） */
  private filtering(): boolean {
    return this.keyword.trim().length > 0;
  }

  /**
   * 收起搜索并清掉过滤
   *
   * 收起时**必须**把过滤一起清掉：否则输入框没了、列表却还只剩搜出来的几首，
   * 用户会以为歌被删了。滚的是原来那个 List / scroller，收起后回到同一份列表。
   */
  private closeSearch(): void {
    this.searching = false;
    this.keyword = '';
    this.applyFilter();
  }

  /** 头部那颗放大镜：点开 / 再点收起 */
  private toggleSearch(): void {
    if (this.selecting) {
      // 多选时顶栏、底栏都在报「已选中 N 项」，这时候再筛一遍就会出现
      // 「勾着的歌被过滤出列表」的错位，所以多选态下这颗钮不接（头部也不画它）
      return;
    }
    if (this.searching) {
      this.closeSearch();
      return;
    }
    this.searching = true;
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
          // 窗口宽必须传：不传的话里面读到 0，右留白与任何按窗口算的量都会错（真机日志里 window=0）
          windowWidth: this.windowWidth,
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
      // 左右跟手：与壳层底部那条同一个开关；宽屏下这条栏比窗口窄，贴到手那一侧才看得见
      adaptToHandedness: this.followHand,
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
    const result: AddMusicResult = SyncManager.getInstance().getLibrary()
      .addMusicToPlaylist(playlist.id, songs);
    this.closePicker();
    this.exitSelecting();
    this.reportAdded(playlist.name, result, songs.length);
  }

  /**
   * 加歌之后那句提示，按**真实结果**说话
   *
   * 库里现在会把「已经在歌单里的」那些跳过，返回 { added, skipped }，
   * 所以不能再只看 `added > 0` 就一句「已把 N 首加入」—— 那样部分重复时用户会以为全进去了。
   * 四种情形分开说（单选另算：一句「里已经有这首歌了」就够自然，不必报数）：
   *   - 全进去：保持原口径「已把 N 首加入「X」」；
   *   - 进去一部分：把跳过的首数也说出来；
   *   - 全被跳过：改说「这 N 首都已经在「X」里了」，点明数量（原文案不提数量，容易被当成失败）；
   *   - 单选：进去说「已添加到」，没进去说「里已经有这首歌了」。
   */
  private reportAdded(playlistName: string, result: AddMusicResult, total: number): void {
    if (total === 1) {
      this.toast(result.added > 0
        ? `已添加到「${playlistName}」`
        : `「${playlistName}」里已经有这首歌了`);
      return;
    }
    if (result.added <= 0) {
      this.toast(`这 ${total} 首都已经在「${playlistName}」里了`);
      return;
    }
    if (result.skipped > 0) {
      this.toast(`已加入 ${result.added} 首，${result.skipped} 首已在歌单里`);
      return;
    }
    this.toast(`已把 ${result.added} 首加入「${playlistName}」`);
  }

  private createPlaylistAndAdd(name: string): void {
    const songs: SongItem[] = this.pending;
    if (name.length === 0 || songs.length === 0) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    const id: string = library.createPlaylist(name);
    // 刚建的空歌单里不可能有重复，这里照样读返回值（而不是假设「一定全加进去了」）：
    // 万一某条歌曲信息不全被库里挡下，提示里的数字才对得上
    const result: AddMusicResult = library.addMusicToPlaylist(id, songs);
    this.closePicker();
    this.exitSelecting();
    if (result.added <= 0) {
      this.toast(`已新建歌单「${name}」，但这些歌没能加进去`);
      return;
    }
    this.toast(result.added === 1
      ? `已新建歌单「${name}」并添加`
      : `已新建歌单「${name}」并加入 ${result.added} 首`);
  }

  // ------------------------------------------------------------ 检查重复歌曲

  /**
   * ⋮ →「检查重复歌曲」
   *
   * 先扫一遍再决定弹什么：没有重复就只 toast（弹一个空面板等于让用户白点一次关闭）。
   * 有重复就报「几组 / 几首可清理」再开面板 —— 这个数面板顶部还会再写一次，
   * 但用户点菜单那一下就得知道「值不值得点进去」。
   */
  private checkDuplicates(): void {
    const groups: DuplicateGroup[] = SyncManager.getInstance().getLibrary()
      .findDuplicateGroups(this.playlistId);
    if (groups.length === 0) {
      this.toast('没有发现重复歌曲');
      return;
    }
    let removable: number = 0;
    for (const group of groups) {
      removable += group.duplicateIds.length;
    }
    this.dupGroups = groups;
    this.dupOpen = true;
    this.toast(`发现 ${groups.length} 组重复，共 ${removable} 首可清理`);
  }

  /**
   * 面板确认：删掉这些 id，然后刷新列表并如实报数
   *
   * 先收面板再删：删除会让 `libraryVersion` 变化、@Watch 触发 refresh，
   * 面板这会儿还开着的话，列表在面板底下换一遍观感很怪。
   */
  private cleanDuplicates(ids: string[]): void {
    const removed: number = SyncManager.getInstance().getLibrary()
      .removeDuplicateSongs(this.playlistId, ids);
    this.dupOpen = false;
    // **不**在这里清 dupGroups：面板还要播一段收起动画，清早了它在动画里会先闪成
    // 「没有发现重复歌曲」的空态。等 onDisappear（收完）再清，见 build 末尾那个挂载点。
    this.refresh();
    this.toast(removed > 0 ? `已清理 ${removed} 首重复歌曲` : '没有可清理的重复歌曲');
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
    // 搜索态进多选：**先把过滤清掉**。不然后面「已选中 N 项 / 全选 / 批量操作」
    // 算的都是过滤后那几首，而屏幕上勾着的歌随时可能被关键词挡在列表外，数就对不上
    if (this.searching || this.filtering()) {
      this.closeSearch();
    }
    this.selecting = true;
    this.selectedIds = [item.id];
    // @Watch 只在**值真的变了**时才回调，进多选这一下不能只靠它（同一条二次长按就不变）
    this.publishSelectBar();
  }

  /** 全局多选已收尾：无条件复位本地状态（回调可能根本没被调到） */
  private onSelectEnded(): void {
    if (this.selecting) {
      this.selecting = false;
      this.selectedIds = [];
    }
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

  /**
   * 歌单级 ⋮ 菜单（头部那一颗）
   *
   * 与 {@link rowMenu} 分开：那个挂在每一行上、每一项只作用于「这一首歌」；
   * 这里的项作用于整张歌单。内置收藏歌单（isBuiltinPlaylist）也用这一项 ——
   * 收藏歌单同样会积重复（同一个源重复收藏、多端同步合并），库里的去重口径两种都兼容。
   */
  @Builder
  playlistMenu() {
    Menu() {
      // 「从原歌单更新」：只对从线上歌单导入的本地歌单有意义（自建/收藏没有源头）
      if (this.canUpdateFromSource()) {
        MenuItem({ content: this.updating ? '正在更新…' : '从原歌单更新' })
          .onClick(() => {
            if (!this.updating) {
              void this.updateFromSource();
            }
          })
      }
      MenuItem({ content: '检查重复歌曲' })
        .onClick(() => {
          this.checkDuplicates();
        })
      // 导出整张歌单：换设备时把文件传过去，在「我的 -> 导入文件」一键导入
      MenuItem({ content: '导出为文件' })
        .onClick(() => {
          void this.exportPlaylistFile();
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
        // 曲目数按**全量**给：这一行说的是「这张歌单有多少首」，
        // 筛出来几首由搜索条下面那行「筛选出 N 首」负责，两个数各说各的
        Text(`${this.allSongs.length} 首`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 歌单内搜索入口：画在页面自己的头部里，**不依赖壳层那条标题栏**
      // （pageTitleBar 在 pages/Index.ets，那是壳层的东西，这一页改不了它）
      if (!this.selecting) {
        Row() {
          IconGlyph({
            symbol: I_SEARCH,
            iconSize: 19,
            color: this.searching ? C_RED : C_TEXT_SUB,
          })
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.searching ? C_RED_TINT : C_FILL_SOFT)
        .onClick(() => {
          this.toggleSearch();
        })
        .accessibilityText(this.searching ? '收起搜索' : '搜索歌单内的歌曲')
        .accessibilityLevel('yes')
      }

      // 歌单级 ⋮：这一颗管的是**整张歌单**（目前是「检查重复歌曲」），
      // 与每行那颗行尾 ⋮（管那一首歌）分开挂 —— 塞进行菜单的话，
      // 点某首歌的「更多」却弹出「检查重复歌曲」，会让人以为只检查这一首
      if (!this.selecting) {
        Row() {
          IconGlyph({ symbol: I_MORE, iconSize: 20, color: C_TEXT_SUB })
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(18)
        .backgroundColor(C_FILL_SOFT)
        .bindMenu(this.playlistMenu())
        .accessibilityText('歌单更多操作')
        .accessibilityLevel('yes')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
  }

  /**
   * 搜索条：点开头部那颗放大镜后就地展开，输入时列表在眼皮底下实时变
   *
   * 用的是搜索页那颗输入框的同一套写法（Row + 放大镜 + 透明 TextInput + 右侧清除），
   * 只是底色用页面自己的柔和填充、**不叠玻璃**：它在滚动内容里，沉浸光感的材质
   * 只在 Navigation 标题栏 / 底部 TabBar 内才渲染（见下面 build 那段长注释），
   * 这里挂 systemMaterial 也是死的，白叠一层毛玻璃只会盖住内容。
   *
   * 输入即过滤：每敲一个字只重算一次数组（见 applyFilter），不弹面板、不阻塞输入。
   */
  @Builder
  searchPanel() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        IconGlyph({ symbol: I_SEARCH, iconSize: 17, color: C_TEXT_SUB })
          .accessibilityLevel('no')
        TextInput({ text: this.keyword, placeholder: '搜歌名 / 歌手' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 15 })
          .fontSize(15)
          .fontColor(C_TEXT)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .height(28)
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.onKeywordChanged(value);
          })
        if (this.keyword.length > 0) {
          // 清除 = 清关键词并收起搜索条（与「再点放大镜」同一个出口）
          IconGlyph({ symbol: I_CLOSE, iconSize: 16, color: C_TEXT_WEAK })
            .onClick(() => {
              this.closeSearch();
            })
            .accessibilityText('清除搜索')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .height(40)
      .padding({ left: 14, right: 12 })
      .borderRadius(20)
      .backgroundColor(C_FILL_SOFT)

      if (this.filtering()) {
        // 计数：告诉用户「现在看到的是筛出来的几首」，免得以为歌单被削减了
        Text(`筛选出 ${this.songs.length} 首`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  playAllRow() {
    Row({ space: 12 }) {
      IconGlyph({ symbol: I_PLAY_CIRCLE, iconSize: 46, color: C_RED })

      // 文案跟着筛选态走：队列就是 `this.songs`（搜索时是筛出来的那几首），
      // 不写清楚的话用户会以为「播放全部」把整张歌单都塞进队列了
      Text(this.filtering() ? '播放筛选结果' : '播放全部')
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
      // 搜索无结果时这一行还画在列表头上，点它要有个回音，不能静默什么都不发生
      if (this.songs.length === 0) {
        this.toast('没有可播放的歌曲');
        return;
      }
      this.playFrom(0);
    })
  }

  /** 是不是内置收藏歌单（它里面的歌都已收藏，收藏相关入口要藏起来） */
  private isBuiltin(): boolean {
    return SyncManager.getInstance().getLibrary().isBuiltinPlaylist(this.playlistId);
  }

  /**
   * 导出这张歌单为 JSON 文件（换设备迁移用，不经过服务器）
   *
   * 导出的是**整张歌单**（按 id 从库里重新取），不是当前搜索结果 —— 搜索框只是查看用的过滤，
   * 拿它去导出会让用户得到一份「少了歌」的文件。本地/云端歌曲会被跳过并计数。
   */
  private async exportPlaylistFile(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.toast('当前环境不支持保存文件');
      return;
    }
    try {
      const result: ExportOutcome = await PlaylistPort.getInstance()
        .exportToFile(context as common.Context, [this.playlistId], this.title);
      if (!result.canceled) {
        this.toast(result.message);
      }
    } catch (e) {
      this.toast('导出失败，请重试');
    }
  }

  /**
   * 下载全部
   *
   * **先问一句再下**：整张歌单动辄几百首，点一下就把它们全排进下载队列太莽，
   * 所以在真排队之前一律弹一句确认。批量那一份在 {@link downloadSongs}
   * （多选里的「下载」共用它 —— 那是用户一首首勾出来的，不必再确认一遍）。
   */
  private downloadAll(): void {
    // 判「歌单是不是空的」要看**全量**：搜索无结果时 songs 也是 0，
    // 这时候说「歌单里还没有歌曲」就撒谎了（歌单有歌，只是没筛出来）
    if (this.allSongs.length === 0) {
      this.toast('歌单里还没有歌曲');
      return;
    }
    const count: number = this.songs.length;
    // 搜索态下「下载全部」下的是筛出来的那些（与列表所见一致），文案得跟着说清楚
    this.getUIContext().showAlertDialog({
      title: '下载全部',
      message: this.filtering()
        ? `确定把筛选出的 ${count} 首加入下载吗？可以在「我的 - 下载管理」里看进度。`
        : `确定要把「${this.title}」里的 ${count} 首歌全部加入下载吗？可以在「我的 - 下载管理」里看进度。`,
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
          // 歌手名：点它进这位歌手的聚合页（共用组件，见 ui/Widgets.ets 的 SingerLink）
          SingerLink({ singer: item.singer, source: item.source })
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

  /** 组头：歌单封面那一块 + 搜索条（展开时）+ 「播放全部」（宽屏通栏，见 pageBody 的说明） */
  @Builder
  listHeader() {
    Column() {
      this.header()
      // 搜索条夹在头部与「播放全部」之间：展开/收起只动这一块，列表其余部分不搬家
      if (this.searching) {
        this.searchPanel()
      }
      this.playAllRow()
    }
    .width('100%')
  }

  /** 组尾：空歌单 / 搜索无结果的空态 + 给悬浮迷你播放条让位的那一段 */
  @Builder
  listFooter() {
    Column() {
      if (this.allSongs.length === 0) {
        EmptyState({
          text: '这个歌单还没有歌曲',
          hint: '可以在洛雪桌面端 / 移动端把歌加进来，同步后就会出现',
          topPadding: 56,
        })
      } else if (this.songs.length === 0) {
        // 有歌、但一首都没筛出来。这里必须给一个「清除搜索」的出口：
        // 搜索条在组头，用户滚到这里时早就看不见它了，让人自己滚回去找太别扭
        Column({ space: 12 }) {
          EmptyState({
            icon: I_SEARCH,
            text: `没有找到「${this.keyword.trim()}」`,
            hint: '换个歌名或歌手试试，也可以清除搜索看全部',
            topPadding: 48,
          })
          Row() {
            Text('清除搜索')
              .fontSize(F_SUB)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_RED)
          }
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .borderRadius(16)
          .backgroundColor(C_RED_TINT)
          .onClick(() => {
            this.closeSearch();
          })
          .accessibilityText('清除搜索，显示全部歌曲')
          .accessibilityLevel('yes')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 24 })
      }

      // 给悬浮的迷你播放条让位：最后一行能滚到栏的上方，而不是被它压住
      Column().height(this.bottomInset + HDS_BAR_HEIGHT + 26).width('100%')
    }
    .width('100%')
  }

  /**
   * 页面主体：歌单头部 + 歌曲列表
   *
   * 单独抽成一个 builder：鸿蒙6 上底部那条悬浮栏要换成自绘的（见 build 的 else 分支），
   * 主体两种系统上完全一样，抽出来就不会被复制成两份、以后改一处漏一处。
   *
   * 整页只有**一个 ListItemGroup**：组头是歌单封面与「播放全部」，组内每一首是一行，
   * 组尾是空态与底部让位。套一层组是为了宽屏多列 —— List 的 `lanes` 是按条目分的，
   * 把头部当普通条目丢进去，宽屏下封面那一块会被挤进一列里（见 ui/Layout.ets 的
   * contentColumnsFor）；ListItemGroup 在分栏模式下自己占满整行，组内条目再按 `lanes`
   * 排。窄屏 `lanes` 是 1，与改之前逐像素一样。
   */
  @Builder
  pageBody() {
    Column() {
      List({ scroller: this.scroller }) {
        ListItemGroup({ header: this.listHeader(), footer: this.listFooter() }) {
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
      }
      // 宽屏一屏多列（每列至少 360vp、最多 4 列），窄屏恒为 1 列
      .lanes(contentColumnsFor(this.windowWidth))
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

  /**
   * 「检查重复歌曲」面板
   *
   * 只传查好的分组，删不删由用户在这里拍板；确认后回调宿主（见 cleanDuplicates）。
   * bottomInset 照传：面板底部那条安全区留白与「添加到歌单」面板同一口径。
   */
  @Builder
  duplicateSheet() {
    DuplicateSongsSheet({
      groups: this.dupGroups,
      playlistName: this.title,
      bottomInset: this.bottomInset,
      onConfirm: (ids: string[]) => {
        this.cleanDuplicates(ids);
      },
      onClose: () => {
        // 只收面板，不动 dupGroups：理由同 cleanDuplicates（收起动画里别闪空态）
        this.dupOpen = false;
      },
    })
  }

  /** 迷你栏的宽度：宽屏给壳层算好的最大宽度（与鸿蒙7 那条 `barWidth` 同口径），窄屏铺满 */
  private fallbackBarWidth(): Length {
    return this.wideMiniBarWidth > 0 ? this.wideMiniBarWidth : '100%';
  }

  /**
   * 鸿蒙6 的迷你栏兜底：自绘一条悬浮胶囊
   *
   * `Tabs.barFloatingStyle` 是 API 26（鸿蒙7）才有的，鸿蒙6（compatibleSdkVersion
   * 6.1.0(23)）上这个方法不存在 —— 直接调就是闪退，实测的现场正是「主页能开，
   * 点进歌单就闪退」。低版本退回**改造前**那套：自己挂一条胶囊，几何与鸿蒙7 那条对齐
   * （左右边距、离底距离、栏高都是共享常量），表面是自绘玻璃 + HDS 轮廓点光
   * （`glassLight()`）—— 鸿蒙7 那份光感来自材质的 `lightEffect`，鸿蒙6 上没有材质，由点光补上。
   */
  @Builder
  fallbackMiniBar() {
    Column() {
      Row() {
        this.miniBarTabBar()
      }
      .width(this.fallbackBarWidth())
      .height(HDS_BAR_HEIGHT)
      .attributeModifier(thinGlass(HDS_BAR_HEIGHT / 2, false, '', this.materialLevel))
      .visualEffect(glassLight())
      .clip(true)
    }
    .width('100%')
    .padding({
      left: barSideMarginFor(this.windowWidth),
      right: barSideMarginFor(this.windowWidth),
      bottom: this.bottomInset + PAGE_BAR_BOTTOM_GAP,
    })
  }

  /** 这张歌单能不能回源更新：必须是「从线上歌单导入」的（有平台 + 线上歌单标识） */
  private canUpdateFromSource(): boolean {
    if (this.isBuiltin()) {
      return false;
    }
    const library = SyncManager.getInstance().getLibrary();
    return library.playlistSourceOf(this.playlistId).length > 0
      && library.sourceListIdOf(this.playlistId).length > 0;
  }

  /**
   * 从原歌单更新：重新拉一遍线上歌单，整表替换本地这张
   *
   * 群反馈（2026-11-17 13:38，StarFlame）：「lx 有这个功能（跟着原歌单更新）」，
   * 群主答「行，我加上」。落点复用导入链路：`LocalLibrary.importPlaylist` 对同一张线上歌单
   * 本来就是**原地更新**（同一个 source + sourceListId 落到同一条本地歌单），
   * 所以这里只要重新拉全量歌曲再喂给它。
   *
   * 语义按洛雪来：以线上为准整表替换（本地手动加的歌会被覆盖，这是「更新」的应有之义）；
   * 拉不到 / 线上空了就保持原样并提示，绝不用空结果覆盖用户数据。
   */
  private async updateFromSource(): Promise<void> {
    const library = SyncManager.getInstance().getLibrary();
    const source: string = library.playlistSourceOf(this.playlistId);
    const sourceListId: string = library.sourceListIdOf(this.playlistId);
    if (source.length === 0 || sourceListId.length === 0) {
      this.toast('这张歌单不是从线上导入的，没有可更新的来源');
      return;
    }
    this.updating = true;
    const name: string = this.title;
    try {
      this.toast('正在从原歌单拉取最新内容…');
      // 不把进度写进 title：title 是这张歌单的名字，导入时还要用它
      const detail: LxListDetail = await getPlaylistDetailAll(source, sourceListId);
      const quality: string = PlaySession.getInstance().quality;
      const items: SongItem[] = [];
      for (const music of detail.list) {
        items.push(songFromSearch(music, quality));
      }
      if (items.length === 0) {
        this.toast('原歌单现在是空的，已保留本地内容');
        return;
      }
      const summary: PlaylistSummary | null = library.importPlaylist(name, source,
        sourceListId, items);
      if (summary === null) {
        this.toast('更新失败：没有可导入的歌曲');
        return;
      }
      this.refresh();
      this.toast(`已从原歌单更新：共 ${summary.count} 首`);
    } catch (e) {
      this.toast(`更新失败：${(e as Error).message}`);
    } finally {
      this.updating = false;
    }
  }

  /**
   * 靶心图标：外圈一道环 + 中间一个点（不依赖系统 symbol 里有没有「靶心」）
   *
   * 与参考图同观感：环和点都用主题红，点比环小一圈。
   */  @Builder
  locateButton() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .border({ width: 1.6, color: C_RED })
      Column()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(C_RED)
    }
    .width(24)
    .height(24)
  }

  /**
   * 滚到正在播放的那首
   *
   * 列表可能正被搜索框过滤（`this.songs` 是过滤后的那份），所以在**当前显示的列表**里找：
   * 找到就居中，找不到说明这首歌不在这张歌单（或是被搜索条件筛掉了），给一句提示。
   */
  private scrollToCurrent(): void {
    if (this.currentId.length === 0) {
      this.toast('还没有在播放的歌曲');
      return;
    }
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === this.currentId) {
        this.scroller.scrollToIndex(i, true, ScrollAlign.CENTER);
        return;
      }
    }
    this.toast(this.keyword.trim().length > 0
      ? '正在播放的这首歌被当前搜索筛掉了'
      : '正在播放的这首歌不在这个歌单里');
  }

  build() {
    /**
     * 根容器是 Stack：鸿蒙7 那条悬浮栏由 Tabs 自己画、鸿蒙6 换成自绘的一条（见下面的
     * else 分支），两条都靠 `Alignment.Bottom` 压在列表之上。
     *
     * 「只有一个页签的 Tabs」是为了那条**官方认可的底部悬浮栏** —— 这一页是压在
     * HdsNavigation 路由栈上的 NavDestination，把壳层那条带迷你栏的 HdsTabs 整个盖住了，
     * 所以迷你播放条得自己挂一条。而沉浸光感有**生效范围**：除弹窗类组件外，普通组件
     * 只有落在「Navigation/NavDestination 标题栏」或「横向 Tabs 中 barPosition 为
     * BarPosition.End 的底部 TabBar」里才会渲染材质。早先把它当普通组件画在内容区，
     * 那一行 `.systemMaterial()` 其实是死的 —— 运行时只得到一句
     *     `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`
     *
     * 鸿蒙7 上走 Tabs **自带的悬浮栏材质**（`barFloatingStyle({ systemMaterial })`）：
     * 胶囊的圆角、边距、位置、材质全由框架画，我们只提供栏里的内容（MiniBarView），
     * 几何与观感和壳层那条 HdsTabs 悬浮栏是同一套口径。**别再往栏里叠自绘玻璃**：
     * 沉浸光感的视觉层级在 backgroundColor / backgroundBlurStyle 之下，自己再画一层
     * 半透明底或毛玻璃就把材质整片盖住了 —— 栏里只有内容，没有任何底。
     *
     * **鸿蒙6 必须换一条路**：`FloatingTabBarStyle` / `Tabs.barFloatingStyle` 是 API 26
     * （鸿蒙7）才有的，低版本上这个方法根本不存在，调了就闪退（`compatibleSdkVersion`
     * 是 6.1.0(23)，所以低版本是必须支持的目标平台，不是「理论上有人用」）。
     */
    Stack({ alignContent: Alignment.Bottom }) {
      if (harmony7ApiReady()) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            this.pageBody()
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
        // 鸿蒙7 专有（API 26）：低版本上没有这个方法，走 else 那条自绘胶囊
        .barFloatingStyle(this.floatBarStyle())
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.pageBody()
        }
        .width('100%')
        .height('100%')

        this.fallbackMiniBar()
      }

      /**
       * 「定位到正在播放的那一行」悬浮按钮（靶心）
       *
       * 群反馈（2026-11-16 07:55，看海）：「没有那个歌单里导航到歌曲那一行的按钮」，
       * 附的参考图就是右侧这颗靶心。几百首的歌单里找正在放的那首确实得靠它。
       *
       * 只在「有歌在放 + 列表非空」时出现；点一下滚到那行并居中，找不到就提示一句。
       * 图标用两层圆自绘（环 + 点），不依赖系统 symbol 里有没有靶心。
       */
      if (this.currentId.length > 0 && this.songs.length > 0) {
        Column() {
          Row() {
            this.locateButton()
          }
          .width(42)
          .height(42)
          .justifyContent(FlexAlign.Center)
          .borderRadius(21)
          .backgroundColor(C_CARD)
          .shadow({ radius: 14, color: '#33000000', offsetX: 0, offsetY: 3 })
          .onClick(() => {
            this.scrollToCurrent();
          })
          .accessibilityText('定位到正在播放的歌曲')
          .accessibilityLevel('yes')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        // 让出底部那条悬浮迷你栏，别压住它
        .padding({
          right: 18,
          bottom: this.bottomInset + HDS_BAR_HEIGHT + PAGE_BAR_BOTTOM_GAP + 14,
        })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 「检查重复歌曲」面板：**单独挂一个节点**。
      // 最外层那个节点已经被「添加到歌单」的 bindSheet 占了，同一个节点叠两个半模态
      // 会互相干扰（工程里同一处结论见 pages/Index.ets 的 syncMode 那段）。
      // 1×1 + 贴左上角：只是个挂载点，不参与布局、也点不到。
      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindSheet($$this.dupOpen, this.duplicateSheet(), {
          preferType: SheetType.BOTTOM,
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.MEDIUM,
          dragBar: true,
          showClose: true,
          title: { title: '检查重复歌曲' },
          onDisappear: () => {
            // 下滑关掉也要把分组清掉：下次打开前一定重新扫一遍库，别拿旧结果删歌
            this.dupGroups = [];
          },
        })
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
