import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { BlurStrategy, HdsBarLayoutMode, HdsBarStyle, HdsNavigation, HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode, HdsNavDestination, HdsTabs, HdsTabsBarChangeMode, HdsTabsController,
  HdsTabsMiniBar, HdsTitleBarContentStyle, TitleBarStyleOptions, TitleSize } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { K_CURRENT_ID, K_MINI_EXPANDED, K_QUEUE_COUNT, K_STATUS_TEXT, PlaySession,
  SongItem } from '../core/player/PlaySession';
import { LocalMusic } from '../core/local/LocalMusic';
import { WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { SourceEngine } from '../core/source/SourceEngine';
import { SourceInfo, SourceLog } from '../core/source/LxTypes';
import { OnlineRoute, LIST_PLATFORMS, platformName } from '../core/music/MusicList';
import { C_BG, C_GLASS_SOLID, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, F_SUB } from '../ui/Theme';
import { glassLight, immersiveMaterialFor, immersiveMaterialForDialog, isGlassMaterialSupported, materialFirstGlass,
  thinGlass } from '../ui/Glass';
import { DustLayer } from '../ui/Dust';
import { SourceSandboxHost } from '../components/SourceSandboxHost';
import { SyncManager, K_SYNC_STATUS } from '../core/sync/SyncManager';
import { describeStatus, shouldNotifySyncMessage } from '../core/sync/SyncStatusText';
import { buildTitleMaterial, HDS_BAR_HEIGHT, HDS_TITLE_BAR_HEIGHT } from '../ui/Hds';
import { K_MATERIAL_LEVEL, K_NAV_FOLLOW_HAND } from '../core/settings/AppearanceSettings';
import { K_BAR_MINI_WIDTH, K_WINDOW_WIDTH, publishedMiniBarWidth } from '../ui/Layout';
import { BAR_ONE_ROW, BAR_TWO_ROWS, BottomBar, K_BAR_LAYOUT, twoRowLayoutSupported }
  from '../ui/BottomBar';
import { PageTitle, RoundIconButton, WidePane } from '../ui/Widgets';
import { AppearanceSettingsView } from '../views/AppearanceSettingsView';
import { AboutView } from '../views/AboutView';
import { WebDavSettingsView } from '../views/WebDavSettingsView';
import { ListenSettingsView } from '../views/ListenSettingsView';
import { I_BOOK, I_BOOK_FILL, I_CHEVRON_DOWN, I_CLOSE, I_ECHO, I_ECHO_FILL, I_HOME, I_HOME_FILL,
  I_IDENTIFY, I_PERSON, I_PERSON_FILL, I_SEARCH, I_SELECT_ALL, IconGlyph } from '../ui/Icons';
import { MiniBarView } from '../views/MiniBar';
import { BookSandboxHost } from '../components/BookSandboxHost';
import { BookDetailView } from '../views/BookDetailView';
import { ListenView } from '../views/ListenView';
import { EchoView, echoTitleOf, K_ECHO_TITLE } from '../views/EchoView';
import { BookShelf } from '../core/book/BookShelf';
import { BookHit } from '../core/book/BookTypes';
import { MineView } from '../views/MineView';
import { OnlineListView } from '../views/OnlineListView';
import { PanePage } from '../views/PanePage';
import { PlayerView } from '../views/PlayerView';
import { PlayQueueContent } from '../views/PlayQueueSheet';
import { PlaylistDetailView } from '../views/PlaylistDetailView';
import { HistoryView } from '../views/HistoryView';
import { PlaylistSquareView } from '../views/PlaylistSquareView';
import { LocalMusicPane } from '../views/LocalMusicView';
import { DownloadListPane } from '../views/DownloadListView';
import { WebDavPane } from '../views/WebDavView';
import { K_RECOMMEND_SOURCE, RecommendSettings } from '../core/settings/RecommendSettings';
import { K_HIDE_LISTEN_TAB } from '../core/settings/ListenSettings';
import { RecommendView } from '../views/RecommendView';
import { RecognizeView } from '../views/RecognizeView';
import { SearchView } from '../views/SearchView';
import { ArtistView } from '../views/ArtistView';
import { ArtistPickerView } from '../views/ArtistPickerView';
import { ArtistNav } from '../ui/ArtistNav';
import { ArtistCandidate, artistCandidatesOf, cachedArtistOf, LxArtist,
  resolveArtistByName } from '../core/music/MusicArtist';
import { SettingsView } from '../views/SettingsView';
import { SourceSettingsView } from '../views/SourceSettingsView';
import { SyncModeContent } from '../views/SyncModeSheet';
import { SyncSettingsView } from '../views/SyncSettingsView';
import { CacheSettingsView } from '../views/CacheSettingsView';
import { PlaySettingsView } from '../views/PlaySettingsView';
import { DownloadSettingsView } from '../views/DownloadSettingsView';
import { PlaylistSummary } from '../core/player/PlaySession';
import { K_SELECT_ACTIVE, K_SELECT_ALL, K_SELECT_COUNT, SelectSession } from '../ui/Selection';

/** 主界面 / 子页面 */
const PAGE_MAIN: string = 'main';
const PAGE_SEARCH: string = 'search';
/** 听歌识曲（推荐页标题栏那颗钮压的就是它） */
const PAGE_RECOGNIZE: string = 'recognize';
const PAGE_SOURCE: string = 'source';
const PAGE_SYNC: string = 'sync';
const PAGE_PLAYLIST: string = 'playlist';
const PAGE_CACHE: string = 'cache';
/** 播放设置 */
const PAGE_PLAY: string = 'play';
/** 下载设置 */
const PAGE_DOWNLOAD: string = 'download';
/** 外观设置（材质档位 / 光效 / 深浅模式） */
const PAGE_APPEARANCE: string = 'appearance';
/** 听书设置（是否隐藏「听书」页签） */
const PAGE_LISTEN: string = 'listen';
/** 在线歌单 / 在线榜单详情 */
const PAGE_ONLINE: string = 'online';
/** WebDAV 云端音乐设置（服务器地址 / 账号密码 / 曲库管理） */
const PAGE_WEBDAV: string = 'webdav';
/** 关于（作者 / 开源协议 / 仓库地址 / 反馈渠道） */
const PAGE_ABOUT: string = 'about';
/** 设置（「我的」页那张卡的「设置」；原来是底部的一个页签，现在从「我的」里进） */
const PAGE_SETTINGS: string = 'settings';
/** 播放历史（「我的」页快捷入口里的「最近播放」） */
const PAGE_HISTORY: string = 'history';
/** 全部歌单（推荐页分区标题右边「更多」进来的那一页） */
const PAGE_SQUARE: string = 'square';
/** 本地音乐（导入本机音频 / 批量移除） */
const PAGE_LOCAL: string = 'local';
/** 下载管理（下载中 / 已完成 / 失败重下） */
const PAGE_DOWNLOADS: string = 'downloads';
/** 云端音乐（WebDAV 曲库，与「WebDAV 云端音乐」设置页是两件事） */
const PAGE_CLOUD: string = 'cloud';
/** 听书：一本书的详情 + 目录 */
const PAGE_BOOK: string = 'book';
/** 歌手页：一位歌手的全部歌曲（按歌手聚合，见 core/music/MusicArtist） */
const PAGE_ARTIST: string = 'artist';
/** 歌手列表页：挑一位歌手（回响的常听歌手 / 一首歌挂着几位歌手时） */
const PAGE_ARTIST_PICKER: string = 'artistPicker';

/**
 * 底部悬浮页签的页签
 *
 * `key` 是这一栏的**身份**（推荐 / 听书 / 我的），与「第几栏」无关：听书可以在设置里隐藏，
 * 一藏栏位就整体前移（我的从第 2 栏变第 1 栏）。所以「这是哪一栏」一律用 key 判断；
 * 栏位下标只在要交给 HdsTabs 时由 key 现算（见 tabIndexOf）—— 下标是**位置**、会随听书
 * 的显隐变，把它当身份交给按值传递的 @Builder 迟早对不上（之前那版就是这么把「我的」
 * 那一栏显示成「推荐」的）。
 */
interface TabDef {
  key: string;
  icon: Resource;
  iconActive: Resource;
  label: string;
}

/**
 * 四个页签：推荐 / 听书 / 回响 / 我的
 *
 * 原来是四个（推荐 / 歌单 / 我的 / 设置）：歌单与设置的**内容**现在都在「我的」页里
 * （照华为音乐的「我的」重排：快捷入口 + 歌单卡 + 设置卡），再留着那两个页签就是
 * 同一件事有两个入口，所以先收成两个。
 *
 * 「听书」单独占一栏，夹在推荐与我的之间：它**不是**音乐的一种（书源是阅读/Legado
 * 的 JSON 规则，与音源完全不同的一套协议，见 core/book/book_preload.js），
 * 混进推荐页会让「音乐」那一栏的语义变糊；而它又是使用频率很高的主功能，
 * 藏在「我的」的二级入口里不合适，所以给它一个并列的一级页签。
 *
 * 「回响」（月度收听记录）排在「我的」前面，与无界音乐的「首页 / 回响 / 我的」同一个排法：
 * 左边两栏是**内容**（推荐、听书），右边两栏是**关于我自己的**（回响是我听过的账，
 * 我的是我收藏的东西），两两相邻。
 *
 * 「听书」可以在「设置 - 听书」里隐藏：整块 TabContent 一起不摆，导航栏只剩「推荐」「回响」「我的」。
 *
 * 四栏的**排法**是固定的（推荐 / 听书 / 回响 / 我的，我的在最右）。悬浮栏整体的**位置**另说：
 * 开了「左右跟手」（设置 - 外观）之后它不再恒定居中，而是贴到握持手那一侧 —— 这件事由 HDS
 * 的 `adaptToHandedness` 做（见 build 里 barFloatingStyle），并且只在「栏比窗口窄」的宽屏下
 * 看得出来。它不动栏里的次序，折叠成的那颗球永远是那一组的左端元素。
 */
const TAB_KEY_HOME: string = 'home';
const TAB_KEY_LISTEN: string = 'listen';
const TAB_KEY_ECHO: string = 'echo';
const TAB_KEY_MINE: string = 'mine';

const TAB_HOME: TabDef = { key: TAB_KEY_HOME, icon: I_HOME, iconActive: I_HOME_FILL, label: '推荐' };
const TAB_LISTEN: TabDef = { key: TAB_KEY_LISTEN, icon: I_BOOK, iconActive: I_BOOK_FILL, label: '听书' };
const TAB_ECHO: TabDef = { key: TAB_KEY_ECHO, icon: I_ECHO, iconActive: I_ECHO_FILL, label: '回响' };
const TAB_MINE: TabDef = { key: TAB_KEY_MINE, icon: I_PERSON, iconActive: I_PERSON_FILL, label: '我的' };

const TABS: TabDef[] = [TAB_HOME, TAB_LISTEN, TAB_ECHO, TAB_MINE];

/**
 * 底栏那份日志（HDS 的样式回调与滚动联动各打一行，`hdc shell hilog | grep BottomBar` 能查到）
 *
 * 宽度不再按「每颗页签占多少」算（barWidth / miniBarWidth 都不声明了，见 barFloatingStyle 那段），
 * 所以原来那两个 TAB_SLOT_* 常量一并去掉。
 */
const DOMAIN_BAR: number = 0x0001;
const TAG_BAR: string = 'BottomBar';



/**
 * 应用壳层
 *
 * 结构对应洛雪移动端：
 *   底部是 HDS 的悬浮页签栏（推荐 / 歌单 / 我的 / 设置）+ 挂在它右边的迷你栏：
 *     迷你栏折叠 = 洛雪那颗悬浮专辑圆钮，展开 = 迷你播放器（封面 + 播放/下一首/播放列表）。
 *     展开与折叠的互斥、让位动画都是 HDS 自己做的，点一下就切换。
 *   点迷你播放器的信息区弹出全屏播放器：它是**全屏模态**（bindContentCover），
 *     整页从下往上升起、收起时从上往下滑走（`ModalTransition.DEFAULT`）；
 *     下面那层页面不重建也不退出；播放列表是另一层半模态，
 *     两者各自挂在不同节点上，互不干扰。
 *   音源沙箱（1x1 的 ArkWeb）始终挂在最外层，保证换页不会打断源脚本状态
 */
@Entry
@Component
struct Index {
  /**
   * 当前选中的页签（用**身份** key 记，不记第几栏）
   *
   * 听书能在设置里隐藏，一藏栏位就整体前移。把「第几栏」当状态存的话，隐藏时得手工平移、
   * 还容易跟框架的下标打架；存 key 之后，栏位下标每次渲染由 key 现算（见 tabIndexOf），
   * 隐藏 / 显示都不需要搬移，当前页永远是同一页。
   */
  @State activeTabKey: string = TAB_KEY_HOME;
  @State playerOpen: boolean = false;
  /**
   * 播放页里那一层自绘覆盖物（评论 / 更多 / 音质 / 匹配歌词）开着没有
   *
   * 播放页是 bindContentCover 全屏模态：系统返回键默认直接收起整个模态。
   * 评论页只是模态里自绘的一层，如果不拦一下，按返回会把播放页一起收掉、露出
   * 下面的页签页 —— 就是用户反馈的「从评论返回有概率回到一级菜单」。
   * 由 PlayerView 在覆盖物开合时回调过来，见下面 bindContentCover 的 onWillDismiss。
   */
  @State playerOverlayOpen: boolean = false;
  /**
   * 让播放页「收掉最上面那层覆盖物」的信号（每次返回键 +1）
   *
   * 壳层没法直接调子组件的私有方法，就按状态传：PlayerView 里 @Watch 它，
   * 收到就按「评论 → 匹配歌词 → 音质 → 更多」的顺序收一层。
   */
  @State playerBackTick: number = 0;
  @State queueOpen: boolean = false;
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  @State sourceSummary: string = '未加载音源';
  @State toast: string = '';
  /** 同步方式选择框：服务端要求选择时由 SyncManager 回调打开 */
  @State syncModeOpen: boolean = false;
  @State syncModeKind: string = 'list';
  @State syncModeServer: string = '';
  /** 歌单详情页当前打开的歌单（路由参数只收 Object，这里直接由壳层持有更省事） */
  @State routePlaylistId: string = '';
  @State routePlaylistName: string = '歌单';
  /** 在线歌单 / 榜单详情页的当前目标 */
  /** 全部歌单那一页的口径：哪个平台 × 哪个排序 */
  @State routeSquareSource: string = 'kw';
  @State routeSquareSortId: string = '';
  @State routeSquareName: string = '';
  @State routeOnlineKind: string = 'playlist';
  @State routeOnlineSource: string = 'kw';
  @State routeOnlineId: string = '';
  @State routeOnlineName: string = '';
  @State routeOnlineCover: string = '';
  /** 听书详情页当前打开的书（同样由壳层持有，路由参数只收 Object） */
  @State routeBook: BookHit = {
    id: '', sourceId: '', sourceName: '', name: '', author: '', coverUrl: '',
    intro: '', kind: '', wordCount: '', status: '', lastChapter: '', bookUrl: '',
  };
  /**
   * 歌手页当前要看的歌手
   *
   * 与歌单 / 听书同样由壳层持有（路由参数只收 Object，传对象进来还要再拆一遍）。
   * 这几项都是基本类型，正好对上 ArtistView 那几个 @Prop。
   */
  @State routeArtistSource: string = '';
  @State routeArtistId: string = '';
  @State routeArtistMid: string = '';
  @State routeArtistName: string = '';
  @State routeArtistPicUrl: string = '';
  @State routeArtistSongNum: number = 0;
  /**
   * 歌手列表页要显示的那份名单
   *
   * 两个来源共用：回响的「常听歌手」整份名单，或一首歌挂着几位歌手时的候选。
   */
  @State routeArtistCandidates: ArtistCandidate[] = [];
  @State routeArtistPickerTitle: string = '选择歌手';
  @State routeArtistPickerHint: string = '';
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_STATUS_TEXT) statusText: string = '';
  @StorageLink(K_QUEUE_COUNT) queueCount: number = 0;
  /**
   * 窗口宽度（vp）
   *
   * 底部两条悬浮栏的宽度按它算，各页面的列数也按它算（见 ui/Layout.ets）：
   * 旋转、折叠屏展开/折叠、平板分屏与自由窗口都会改这个值，改完界面重排一次。
   * 0 = 还没量到（此时按手机档处理，与改之前的行为一致）。
   */
  @State windowWidth: number = 0;
  /** HDS 的页签控制器：悬浮页签 + 迷你栏都由它统管 */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 材质档位（外观设置）：标题栏 / 底部页签栏 / 半模态共用，改一处三处一起变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /**
   * 「推荐来源」（酷我 / 酷狗 / …）
   *
   * 那颗来源胶囊跟着「搜索」钮一起搬进了标题栏（沉浸光感只在标题栏 / 底部 TabBar
   * 里生效，见 ui/Glass.ets），所以这个值现在由壳层写；推荐页订阅同一个键重新取数。
   */
  @StorageLink(K_RECOMMEND_SOURCE) recommendSource: string = 'kw';
  /**
   * 是否隐藏「听书」页签（设置 - 听书）
   *
   * 存法在 core/settings/ListenSettings.ets（沙箱 JSON + AppStorage）。改值的是设置页，
   * 壳层订阅后重排导航栏：隐藏时不再摆那一栏 TabContent。当前页是按**身份**记的
   * （见 activeTabKey），栏位下标每次渲染现算，所以隐藏 / 显示都不需要搬移选中项。
   */
  @StorageLink(K_HIDE_LISTEN_TAB) hideListenTab: boolean = false;
  /**
   * 悬浮栏左右跟手（设置 - 外观，默认开）
   *
   * 交给 HDS 自己的左右跟手能力（见 build 里 barFloatingStyle 的 adaptToHandedness）：
   * 悬浮栏不再恒定居中，而是贴到握持手那一侧（右手握持贴右、左手握持贴左）。
   * 只在「栏比窗口窄」的宽屏下看得出来；手机竖屏两条栏本来就铺满，看不出变化。
   * 三条页内播放条（歌单详情 / 在线详情 / 四个面板页）跟着同一个值走，见那几页的 followHand。
   */
  @StorageLink(K_NAV_FOLLOW_HAND) followHand: boolean = true;
  /**
   * 底栏现在是「上下两排」还是「单排」（ui/BottomBar.ets 是唯一的状态源）
   *
   * 默认**两排**（派音 / musicfree 的默认观感）：迷你条一排、页签一排，页签永远够得着 ——
   * 这也是这次改动的初衷（单排时页签让位收成左侧一颗圆钮，右手握着够不到）。
   * 列表上滑收成单排、下滑回到两排，见 ui/BottomBar.ets 的 notifyScrollDelta。
   */
  @StorageLink(K_BAR_LAYOUT) barLayout: number = BAR_TWO_ROWS;
  /**
   * 迷你条是不是展开态（单排 = 拉成整条通栏，两排 = 收成窄胶囊）
   *
   * 这个值现在**由我们写**（ui/BottomBar.ets 里与排布一起翻），HDS 的样式回调只当报告看
   * （唯一例外是用户点那颗圆钮，见 onBarStyleChanged）。页内那条自绘迷你栏的宽度、各页的
   * 底部让位也读它（见 publishLayout）。
   */
  @StorageLink(K_MINI_EXPANDED) miniExpanded: boolean = false;

  /**
   * 回响那一栏的页头大标题（「10 月 · 回响」）
   *
   * 页头一律由壳层画（见 homeHeader），而回响的标题要带**月份**、跟着页面里那颗月份
   * 选择器走，所以由 views/EchoView 把标题发布到这个键、壳层订阅它。
   * 默认按当月给：回响页是懒加载的，还没被创建过时就先显示当月这一档。
   */
  @StorageLink(K_ECHO_TITLE) echoTitle: string = echoTitleOf(new Date().getMonth() + 1);
  /**
   * 多选：顶栏整条换成「取消 + 已选中 N 项 + 全选」
   *
   * 多选的宿主是各个列表页（它的勾选状态在自己身上），而顶栏是壳层画的
   * （HdsNavDestination 的标题栏，沉浸光感只在这里生效），两边只能靠这三个订阅值
   * 对话 —— 会话本身（操作项与回调）在 ui/Selection.ets，见那边的说明。
   */
  @StorageLink(K_SELECT_ACTIVE) selectBarActive: boolean = false;
  @StorageLink(K_SELECT_COUNT) selectBarCount: number = 0;
  @StorageLink(K_SELECT_ALL) selectBarAll: boolean = false;
  /**
   * 详情页的主滚动容器。
   *
   * HDS 标题栏的渐变模糊（IMMERSIVE_GRADIENT_BLUR）是「滚动多少、磨砂多厚」，
   * 它必须绑到页面真正的滚动容器上才知道滚了多少（见 titleBarOptions + bindToScrollable）。
   * 只有封面会滚到标题栏底下、返回键浮在封面上的两个详情页需要；
   * 其余子页面是白底设置页，标题栏直接给系统材质就够，不必绑。
   */
  private onlineScroller: Scroller = new Scroller();
  private playlistScroller: Scroller = new Scroller();
  /** HDS 路由栈：搜索页 / 音源设置都作为 HdsNavDestination 压栈，标题栏与返回键由 HDS 提供 */
  private pathStack: NavPathStack = new NavPathStack();
  private mainWindow: window.Window | null = null;
  /** 窗口尺寸变化（旋转 / 折叠 / 分屏 / 自由窗口）的监听，销毁时摘掉 */
  private sizeListener: ((size: window.Size) => void) | null = null;
  /**
   * 音源引擎的日志流
   *
   * 只负责刷新摘要 + 转交「值得打断」的那几条：引擎的 warn/error 大多是自检与回退的
   * 过程留痕（自动恢复失败还能手动选音源、脚本重试、某个接口报错但脚本自己兜住了），
   * 全弹提示条的话一进应用就是一串失败提醒。是否打断由日志自己声明（见 SourceLog.alert），
   * 其余照旧进日志面板，在「设置 → 音源设置」里能查到。
   */
  private logListener: ((log: SourceLog) => void) | null = null;
  /** 播放会话的提示（缺音源 / 解析失败 / 播放错误），统一走 HDS 提示条 */
  private noticeListener: ((text: string) => void) | null = null;
  private toastTimer: number = 0;

  aboutToAppear(): void {
    PlaySession.getInstance().bootstrap();

    // 听书：书架要早于任何页面初始化（「我的」页与听书页都可能立刻读它）
    try {
      const hostContext: common.Context = this.getUIContext().getHostContext() as common.Context;
      BookShelf.getInstance().init(hostContext);
    } catch (e) {
      // 预览器等环境拿不到 context：听书那栏会降级成「没有书源」，不影响其余功能
    }

    const engine = SourceEngine.getInstance();
    this.refreshSourceSummary();
    this.logListener = (log: SourceLog) => {
      this.refreshSourceSummary();
      if (log.alert === true) {
        this.showToast(log.message);
      }
    };
    engine.setLogListener(this.logListener);

    this.noticeListener = (text: string) => {
      this.showToast(text);
    };
    PlaySession.getInstance().setNoticeListener(this.noticeListener);

    /**
     * 「点歌手名 -> 歌手聚合页」的入口注册（见 ui/ArtistNav.ets）
     *
     * 播放页、每一个歌曲列表行、回响的常听歌手都通过这个单例触发；页面栈在这边，
     * 所以只有这里知道该怎么开。放在 aboutToAppear 而不是别处：壳层先于任何页面建好，
     * 注册完就一直在（重复注册也只是覆盖同一个函数）。
     */
    const artistNav: ArtistNav = ArtistNav.getInstance();
    artistNav.register((source: string, singer: string) => {
      this.openArtistFromSinger(source, singer);
    });
    artistNav.registerList((title: string, hint: string, candidates: ArtistCandidate[]) => {
      this.openArtistList(title, hint, candidates);
    });

    // 同步模块的提示（认证失败、连接断开等）走同一条提示条；
    // 服务端要同步方式时，把选择框弹出来，用户选完再回传给 SyncManager。
    const sync = SyncManager.getInstance();
    sync.setMessageListener((message: string) => {
      // 「Connecting... / Wait syncing...」是过程消息，设置页里本来就实时显示着状态，
      // 再弹一次提示条只会打扰用户；这里只提示需要用户知道的失败与断开。
      if (!shouldNotifySyncMessage(message)) {
        return;
      }
      const connected: boolean = AppStorage.get<boolean>(K_SYNC_STATUS) ?? false;
      this.showToast(describeStatus(connected, message));
    });
    sync.setModeRequestListener((kind: string, serverName: string) => {
      this.syncModeKind = kind;
      this.syncModeServer = serverName;
      this.syncModeOpen = true;
    });

    this.setupWindow();
  }

  aboutToDisappear(): void {
    SourceEngine.getInstance().setLogListener(null);
    PlaySession.getInstance().setNoticeListener(null);
    const sync = SyncManager.getInstance();
    sync.setMessageListener(null);
    sync.setModeRequestListener(null);
    const win = this.mainWindow;
    const listener = this.sizeListener;
    if (win !== null && listener !== null) {
      try {
        win.off('windowSizeChange', listener);
      } catch (e) {
        // 忽略：窗口已经没了
      }
      this.sizeListener = null;
    }
  }

  // ------------------------------------------------------------ 窗口 / 安全区

  private async setupWindow(): Promise<void> {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      this.mainWindow = await window.getLastWindow(context);
      this.applyStatusBarColor(false);
      this.readAvoidArea();
      this.readWindowWidth();
      // 全屏布局刚生效时系统可能还没回填避让区，稍后再读一次并监听后续变化
      setTimeout(() => {
        this.readAvoidArea();
      }, 500);
      this.mainWindow.on('avoidAreaChange', () => {
        this.readAvoidArea();
      });
      // 窗口尺寸变化：旋转 / 折叠屏展开折叠 / 平板分屏 / 自由窗口拖拽都会触发，
      // 底部两条栏的宽度与各页面的列数都得跟着重算（见 ui/Layout.ets）
      const onSize = (size: window.Size) => {
        this.windowWidth = this.getUIContext().px2vp(size.width);
        this.publishLayout();
      };
      this.sizeListener = onSize;
      this.mainWindow.on('windowSizeChange', onSize);
    } catch (e) {
      this.topInset = 38;
      this.bottomInset = 14;
    }
  }

  /** 读一次窗口宽度，读到 0 就保持 0（按手机档处理，不会把界面缩没） */
  private readWindowWidth(): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      const width: number = win.getWindowProperties().windowRect.width;
      const vp: number = this.getUIContext().px2vp(width);
      this.windowWidth = vp > 0 ? vp : 0;
    } catch (e) {
      this.windowWidth = 0;
    }
    this.publishLayout();
  }

  /**
   * 把布局量同步给子页面
   *
   * 两样东西：
   *   - 页内那条迷你栏（歌单详情 / 在线详情，不在页签体系里）：宽屏下它要跟 HdsTabs
   *     那条迷你栏同宽（0 = 窄屏，照旧铺满）；
   *   - 窗口宽度：首页三个页签按它算一屏几列（见 ui/Layout.ets 的 contentColumnsFor）。
   */
  private publishLayout(): void {
    // 从 AppStorage 读展开态而不是 @StorageLink：HDS 的 onBarStyleChange 里刚写完
    // 这个键就调本方法，此时 @StorageLink 还没同步回来，会读到上一轮的旧值。
    const expanded: boolean = AppStorage.get<boolean>(K_MINI_EXPANDED) ?? false;
    AppStorage.setOrCreate(K_BAR_MINI_WIDTH, publishedMiniBarWidth(this.windowWidth, expanded));
    AppStorage.setOrCreate(K_WINDOW_WIDTH, this.windowWidth);
  }

  /** 读取状态栏 / 手势条的避让高度，读到 0 时退回经验值 */
  private readAvoidArea(): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const top: number = this.getUIContext().px2vp(system.topRect.height);
      const bottom: number = this.getUIContext().px2vp(indicator.bottomRect.height);
      // 读到 0 说明系统已经把根节点避让过了（此时再补一次就会双重留白），所以保持 0
      this.topInset = top > 5 ? top : 0;
      this.bottomInset = bottom > 3 ? bottom : 0;
    } catch (e) {
      this.topInset = 0;
      this.bottomInset = 0;
    }
  }

  /**
   * 状态栏字色
   *
   * 两种情况下要白字：**播放页弹出来的时候**（那一层是深色封面）、以及**深色模式**下
   * （状态栏压在深色页面上）。之前只判了播放页，深色模式下状态栏一直是黑字 ——
   * 黑字压在近黑底上，就是「看不见时间/电量」。
   */
  private applyStatusBarColor(playerOpen: boolean): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.setWindowSystemBarProperties({
        statusBarContentColor: (playerOpen || this.isDarkMode()) ? '#FFFFFF' : '#000000',
      });
    } catch (e) {
      // 忽略：部分设备不支持单独改内容色
    }
  }

  /** 当前是不是深色模式（跟随系统，也跟随外观设置里选的档位） */
  private isDarkMode(): boolean {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      // 资源管理器给的配置是「应用生效后」的模式（外观设置里选了浅色/深色也在这里体现）
      return context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      return false;
    }
  }

  // ------------------------------------------------------------ 状态提示

  private refreshSourceSummary(): void {
    const engine = SourceEngine.getInstance();
    const list: SourceInfo[] = engine.listSources();
    if (!engine.isInited()) {
      this.sourceSummary = list.length > 0 ? `本地已存 ${list.length} 个音源（未加载）` : '未加载音源';
      return;
    }
    const loaded: string = engine.getLoadedSourceId();
    for (const item of list) {
      if (item.id === loaded) {
        this.sourceSummary = `已就绪：${item.name}`;
        return;
      }
    }
    this.sourceSummary = '已加载音源';
  }

  /**
   * 提示条
   *
   * 用页面内自绘的玻璃条，**不用 HDS 的 HdsSnackBar**。
   * HdsSnackBar 是非模态弹窗：它自己是一个子窗口，弹出后会拿到焦点与返回手势。
   * 它不处理返回，页面层的 Navigation 也就收不到这个返回事件，系统按「没人处理」
   * 把应用直接退回桌面——表现就是「弹过提示条之后，侧滑返回退到桌面」。
   * 自绘提示条只是当前页面里的一层覆盖物，不参与返回事件的分发，返回永远归页面自己。
   */
  private showToast(message: string): void {
    if (message.length === 0) {
      return;
    }
    this.toast = message;
    if (this.toastTimer !== 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = 0;
    }, 3200);
  }

  // ------------------------------------------------------------ 交互

  private go(target: string): void {
    if (target === PAGE_MAIN) {
      this.pathStack.clear();
      return;
    }
    this.pathStack.pushPath({ name: target });
  }

  /**
   * 打开 / 关闭全屏播放器
   *
   * 播放器是**全屏模态**（bindContentCover）：铺满整个窗口，下面那层页面原样留着，
   * 返回键 / 侧滑返回由系统分发给它并收起（DismissReason.PRESS_BACK），不会把应用退回桌面。
   * 状态栏字色挂在它的 onWillAppear / onDisappear 上，跟弹出、收起对齐。
   *
   * 这里**不裹 animateTo**：进入/退出动效由模态自己那条 `ModalTransition.DEFAULT`
   * （向上滑入 / 向下滑出）带动，包一层 animateTo 反而会跟它抢动画配置。
   * 曾经在这里裹 animateTo 驱动的「迷你栏封面 ↔ 播放页封面」共享元素转场已经撤掉，
   * 理由见下面 bindContentCover 上那段说明。
   */
  private openPlayer(): void {
    // 每次打开都是新的一层播放页（覆盖物默认全关）：把壳层记的「覆盖物开着」清掉，
    // 免得上一次留下的状态让第一次返回键什么都不做
    this.playerOverlayOpen = false;
    this.playerOpen = true;
  }

  private closePlayer(): void {
    this.playerOpen = false;
    this.playerOverlayOpen = false;
  }

  private openQueue(): void {
    // 半模态的弹出/收起由 bindSheet 自己带动效，这里只翻状态位
    this.queueOpen = true;
  }

  private closeQueue(): void {
    this.queueOpen = false;
  }

  // ------------------------------------------------------------ 底部页签 / 迷你栏



  /**
   * 传给 HDS 的排布模式（见 ui/BottomBar.ets）
   *
   * 两排 = `VERTICAL`、单排 = `HORIZONTAL`；低版本发行版（< 6.1.1(24)）没有这一项能力，
   * 返回 undefined —— 那种机型上底栏只能是单排，是能力不存在，不是写法问题。
   */
  private barLayoutModeForHds(): HdsBarLayoutMode | undefined {
    if (!twoRowLayoutSupported()) {
      return undefined;
    }
    return this.barLayout === BAR_ONE_ROW ? HdsBarLayoutMode.HORIZONTAL : HdsBarLayoutMode.VERTICAL;
  }

  /**
   * 迷你栏的配置
   *
   * 单独拼一遍是因为 `barLayoutMode` 这个键**在低版本上要整条不出现**（不是给 undefined）：
   * 实机上见过「键在、值为空」时页签栏整条不见的现象，而官方文档说的「未设置时默认左右布局」
   * 指的是键不存在。支持这一项的机型上（`distributionOSApiVersion >= 60101`）才补上。
   */
  private miniBarConfig(): HdsTabsMiniBar {
    const bar: HdsTabsMiniBar = {
      miniBarBuilder: () => this.miniBarBuilder(),
      // 受控：状态在我们手里，HDS 只负责画（见 onBarStyleChanged）
      miniBarStyle: this.miniExpanded ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE,
      onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
        miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode) => {
        this.onBarStyleChanged(miniBarStyle, tabBarStyle, miniBarWidth, tabBarWidth, mode);
      },
    };
    const mode: HdsBarLayoutMode | undefined = this.barLayoutModeForHds();
    if (mode !== undefined) {
      bar.barLayoutMode = mode;
    }
    return bar;
  }

  /**
   * HDS 的样式回调：只当「报告」看，不当状态源（派音最新代码里明确写了这一条）
   *
   * NORMAL（屏幕尺寸变化）/ APP_TRIGGER（应用触发）都只落一条日志：排布的唯一来源是
   * ui/BottomBar.ets 里的那个状态，拿回调再反过来改状态就会两边打架。
   *
   * 唯一例外是**用户点击**（USER_CLICK）：单排时页签让位收成了左侧一颗圆钮，点它 HDS 会把
   * 页签栏展开、顺手把迷你条收起来。那一下要恢复成「完整两排」，而不是停在 HDS 自己挑的
   * 单排形态里 —— 做法与派音一致：翻回两排 + 让控制器把迷你条收起。
   */
  private onBarStyleChanged(miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle,
    miniBarWidth: number, tabBarWidth: number, mode: HdsTabsBarChangeMode): void {
    hilog.info(DOMAIN_BAR, TAG_BAR, 'style report: mini=%{public}d tab=%{public}d width=%{public}d/%{public}d mode=%{public}d',
      miniBarStyle, tabBarStyle, miniBarWidth, tabBarWidth, mode);
    if (mode === HdsTabsBarChangeMode.USER_CLICK && this.barLayout === BAR_ONE_ROW) {
      BottomBar.applyLayoutAnimated(this.getUIContext(), true);
      this.tabsController.applyMiniBarStyle(HdsBarStyle.COLLAPSE);
      hilog.info(DOMAIN_BAR, TAG_BAR, '%{public}s', 'user click on round tab -> restored two rows');
    }
  }

  /**
   * 悬浮页签栏离屏幕底边的距离（vp）
   *
   * 照派音：压着导航条避让区，但至少留 16。
   */
  private homeTabBarBottomMarginVp(): number {
    return Math.max(16, this.bottomInset);
  }

  /**
   * 宽屏布局：**所有页面都铺满窗口**，多列由各页自己排
   *
   * 这里不再有「内容列最大宽度」那套（原来宽屏一律收成居中的 720：平板上两侧各留
   * 一大片白、列表一行从屏左拉到屏右，正是被吐槽的那一版）。现在：
   *   - 每个 destination 的 WidePane 都不给 maxWidth（0 = 不限宽，铺满窗口）；
   *   - 列表页把 `contentColumnsFor(windowWidth)` 喂给 `List.lanes()`，条目自己排成多列
   *     （歌单详情 / 在线详情 / 搜索结果 / 最近播放 / 本地 / 下载 / 云端 / 听书…）；
   *   - 页内的头部（封面那一块）整行铺满，表单类控件自己限宽到 CONTENT_MAX_WIDTH。
   *
   * 窗口宽度由 publishLayout 写进 AppStorage，页面自己订阅（见 ui/Layout.ets）。
   */

  /**
   * 当前挂在导航栏上的页签（「听书」可以在设置里隐藏）
   *
   * 顺序必须与 build() 里 TabContent 的出现顺序**一致**：页签下标是位置决定的，
   * 隐藏听书之后「回响」「我的」各自往前顶一格。所以栏里的图标 / 文字 / 选中态一律用
   * {@link tabDefOf} 按 key 取（key 不随显隐变），绝不把下标当身份传来传去。
   */
  private visibleTabDefs(): TabDef[] {
    return this.hideListenTab ? [TAB_HOME, TAB_ECHO, TAB_MINE] : TABS;
  }

  /** 某个身份（key）对应的页签定义 */
  private tabDefOf(key: string): TabDef {
    const defs: TabDef[] = this.visibleTabDefs();
    for (let i = 0; i < defs.length; i++) {
      if (defs[i].key === key) {
        return defs[i];
      }
    }
    return defs[0];
  }

  /** 当前选中那一页的下标（交给 HdsTabs 用；每次渲染由 key 现算） */
  private tabIndexOf(key: string): number {
    const defs: TabDef[] = this.visibleTabDefs();
    for (let i = 0; i < defs.length; i++) {
      if (defs[i].key === key) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 页签被点了：按下标认出是哪一栏，记下它的**身份**
   *
   * 下标只在这里出现一次（进来的是框架给的位置），出去立刻换成 key，之后所有判断都用 key。
   */
  private onTabChanged(index: number): void {
    const defs: TabDef[] = this.visibleTabDefs();
    if (index < 0 || index >= defs.length) {
      return;
    }
    this.activeTabKey = defs[index].key;
  }

  /** 页签选中态用的强调色 / 未选中态的图标 token（比的是身份，不是下标） */
  private tabColorOf(key: string): Resource {
    return this.activeTabKey === key ? C_RED : C_ICON;
  }

  /**
   * 单个页签：图标 + 文字（照派音的 `TabBarItem`）
   *
   * 悬浮页签栏的样式下 `tabBar` 只认官方 BottomTabBarStyle 或自定义构建器，
   * 这里用后者，好和派音保持同一套字号与间距：图标 22、文字 11、间距 4，
   * 选中态换实心变体 + 主题红，未选中走图标 token（深浅模式各一份）。
   *
   * 参数是**身份 key**（推荐 / 听书 / 我的），不是下标：@Builder 的参数按值传递、
   * 状态改完不会重刷（见 ui/SettingWidgets.ets 开头那条），传下标的话隐藏听书时
   * 参数会留在旧值上，跟 builder 体内重新读到的定义表对不上 —— 之前「我的」显示成
   * 「推荐」就是这么来的。
   */
  @Builder
  tabBarItem(key: string) {
    Column({ space: 4 }) {
      SymbolGlyph(this.activeTabKey === key ? this.tabDefOf(key).iconActive : this.tabDefOf(key).icon)
        .fontSize(22)
        .fontWeight(FontWeight.Regular)
        .height(22)
        .fontColor([this.tabColorOf(key)])
      Text(this.tabDefOf(key).label)
        .fontSize(11)
        .fontColor(this.tabColorOf(key))
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(16)
  }

  /**
   * 迷你栏内容
   *
   * 用箭头函数包一层再交给 HDS：HDS 是系统 HSP，直接传方法引用会丢 this，
   * 里面的组件创建函数就找不到渲染上下文（之前 PrefixCustomBuilder 就是这么崩的）。
   */
  @Builder
  miniBarBuilder() {
    MiniBarView({
      windowWidth: this.windowWidth,
      onOpenPlayer: () => {
        this.openPlayer();
      },
      onOpenQueue: () => {
        this.openQueue();
      },
    })
  }

  // ------------------------------------------------------------ 首页标题栏（页头）

  /**
   * 首页页签的标题栏选项
   *
   * 为什么要把页头（大标题 + 那几个圆钮）从各页的内容区搬进标题栏：
   * 沉浸光感有**生效范围** —— 官方约束里写明，除弹窗类组件 / 弹窗类接口 /
   * Slider、Toggle、Select 可在全页面生效外，**其他组件只在 Navigation/NavDestination
   * 标题栏或横向 Tabs 的底部 TabBar 里生效**；画在内容区的普通组件，即使调了
   * `systemMaterial` 系统也不会激活（运行时会打印
   * `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`）。
   * 运动健康那两颗搜索 / 更多圆钮之所以有光感，就是因为在标题栏里。
   *
   * 这里用 `content.stackBuilder`（官方的「标题栏顶部自定义区域」）承载整排页头：
   * 它保留原来的观感（大标题在左、动作在右、同一行），但整排都落在标题栏内，
   * 于是圆钮与胶囊上的 `systemMaterial` 才真的会渲染。
   */
  private homeTitleBar(): HdsNavigationTitleBarOptions {
    const style: TitleBarStyleOptions = {
      /**
       * 关掉标题栏的滚动效果（这是「一滑就变灰白」的根因）
       *
       * `scrollEffectOpts.enableScrollEffect` **默认是 true**，类型默认 `COMMON_BLUR`：
       * 意思是随着内容滚动，标题栏会逐渐起雾，滚过 `blurEffectiveEndOffset`（默认 8vp）
       * 之后就是一层实打实的磨砂 —— 表现正是「停在顶部通透、一往下滑就变回一条灰白」。
       * 官方那套「标题栏按钮沉浸光感」的示例里也是显式把 `enableScrollEffect` 置 false，
       * 让标题栏样式恒定，不去跟滚动联动。
       *
       * 首页要的是华为音乐 / 运动健康那种恒定的纯透明标题栏，所以这里：
       *   1) 关滚动效果（不再随滚动起雾）；
       *   2) 底色透明 + 蒙版高度收成 0（见下面 originalStyle）；
       *   3) 标题栏自身不做模糊 —— 模糊是「通透」的反面：静止时它把底下的内容糊成一片
       *      看着"跟背景一样"，一旦有列表从底下经过就立刻显形成一条灰白。
       *      注意这条只影响标题栏**这层表面**，不影响圆钮上的沉浸光感。
       */
      scrollEffectOpts: { enableScrollEffect: false },
      blurStrategy: BlurStrategy.DISABLE,
      /**
       * 栏体**不给**材质：首页只要「透明底 + 不留蒙版」，材质全部留给栏里的自绘钮
       *
       * 试过给这一项（实测栏体会整条变成一层材质玻璃带，压在首页内容上
       * 挡掉一截，列表滑到栏下也会被模糊），但那样顶栏就成了一整条玻璃栏，而不是
       * 「两颗玻璃钮浮在页面上」—— 官方那套「标题栏按钮沉浸光感」的观感本来就是后者，
       * 所以材质只挂在钮上（`.systemMaterial(immersiveMaterialFor(...))`），栏体保持透明。
       *
       * 钮的材质是**真的会渲染**的，不是像早先推测的那样被 out of scope：
       * 在 Mate 70 Pro / 鸿蒙7 上抓日志确认 `isImmersiveMaterialSupported()=true`、
       * `globalMaterialLevel=EXQUISITE`（那条 `Material inactive: out of scope` 来自
       * 内容区的悬浮层，内容区本来就不在生效范围里）。先前「钮是白牌子、不是玻璃」的
       * 真正原因是**厚度**：「跟随系统」在高算力设备上被折算成 ULTRA_THICK（弹窗档），
       * 已修在 ui/Glass.ets 的 immersiveStyleOf —— 那一族整体压到 ULTRA_THIN/THIN。
       *
       * 底色这一项：`maskExtraHeight` 默认 32 —— 官方说明「蒙版实际高度 = 标题栏高度 +
       * maskExtraHeight」，也就是贴在标题栏底下那一条同色但不透明的带子
       * （「顶栏下面莫名其妙的一条」），这里收成 0。
       */
      originalStyle: {
        backgroundStyle: {
          backgroundColor: Color.Transparent,
          maskExtraHeight: 0,
        },
      },
    };
    return {
      avoidLayoutSafeArea: true,
      style: style,
      content: {
        // 箭头包一层：HDS 是系统 HSP，直接传方法引用会丢 this（同 miniBarBuilder）
        stackBuilder: () => this.homeHeader(),
      },
    };
  }

  /**
   * 首页各页签的页头：大标题 + 该页签的动作
   *
   * 动作按页签给：只有「推荐」有（来源 + 听歌识曲 + 搜索）。「我的」页的动作（新建歌单 /
   * 导入 / 设置）都在页面自己的卡片里，标题栏这一行不再挂东西 —— 与华为音乐的「我的」
   * 一致，那边标题栏也只有标题（外加它自己的会员 / 消息钮，那两样我们没有）。
   *
   * 推荐页右侧三样从左到右是「来源胶囊 → 听歌识曲 → 搜索」：来源是这一页的数据口径，
   * 另外两颗是「找歌」的两种路子（听周围在放什么 / 自己敲关键词），所以识曲紧挨着搜索、
   * 排在它左边，而来源留在最左、与自己管着的那一页内容离得最近。
   *
   * 画在标题栏里的钮走 `materialFirstGlass`：材质可用时不叠自绘底（沉浸光感的视觉层级在
   * backgroundColor / backgroundBlurStyle 之下，自己再画一层磨砂就把材质整片盖住了），
   * 材质不可用的设备自动退回自绘玻璃。
   */
  @Builder
  homeHeader() {
    Row({ space: 10 }) {
      // 标题按页签取：回响是「10 月 · 回响」（月份跟着它的选择器变，见 echoTitle），
      // 其余直接用页签自己的名字
      PageTitle({ text: this.activeTabKey === TAB_KEY_ECHO
        ? this.echoTitle
        : this.tabDefOf(this.activeTabKey).label })
      Blank()
      if (this.activeTabKey === TAB_KEY_HOME) {
        this.sourcePicker()
        RoundIconButton({
          icon: I_IDENTIFY, boxSize: 40, iconSize: 21, label: '听歌识曲', materialFirst: true,
          onTap: () => {
            this.go(PAGE_RECOGNIZE);
          },
        })
        RoundIconButton({
          icon: I_SEARCH, boxSize: 40, iconSize: 21, label: '搜索', materialFirst: true,
          onTap: () => {
            this.go(PAGE_SEARCH);
          },
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /**
   * 推荐来源胶囊（酷我 / 酷狗 / 咪咕 / QQ / 网易云）
   *
   * 自己画胶囊 + 系统的下拉菜单（bindMenu），不用系统 `Select` 再套一层自绘框：
   * Select 自带一套内边距与高度（≥40vp），塞进 38vp 的框里就会出现「框一种尺寸、
   * 文字按另一种尺寸排」的错位。现在框高、文字基线、箭头间距全由这里定，必然对得上。
   *
   * 玻璃走 materialFirstGlass：它在标题栏里，要让系统材质自己画，不叠自绘底。
   */
  @Builder
  sourcePicker() {
    Row({ space: 3 }) {
      Text(platformName(this.recommendSource))
        .fontSize(14.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .maxLines(1)
      IconGlyph({ symbol: I_CHEVRON_DOWN, iconSize: 14, color: C_TEXT_SUB })
    }
    .height(36)
    .padding({ left: 14, right: 10 })
    .attributeModifier(materialFirstGlass(18, this.materialLevel))
    .systemMaterial(immersiveMaterialFor(this.materialLevel))
    .bindMenu(this.sourceMenu())
    .accessibilityText(`推荐来源：${platformName(this.recommendSource)}，点按切换`)
    .accessibilityLevel('yes')
  }

  /** 来源下拉菜单：改的是 RecommendSettings 里的推荐来源（落沙箱，下次进页面还是它），推荐页订阅它重新取数 */
  @Builder
  sourceMenu() {
    Menu() {
      ForEach(LIST_PLATFORMS, (id: string) => {
        MenuItem({ content: platformName(id) })
          .onClick(() => {
            RecommendSettings.getInstance().setSource(id);
          })
      }, (id: string) => id)
    }
  }

  @Builder
  queueSheet() {
    PlayQueueContent({ bottomInset: this.bottomInset })
  }

  @Builder
  syncModeSheet() {
    SyncModeContent({
      kind: this.syncModeKind,
      serverName: this.syncModeServer,
      bottomInset: this.bottomInset,
      onPick: (mode: string) => {
        this.syncModeOpen = false;
        SyncManager.getInstance().answerMode(mode);
      },
    })
      .width('100%')
      .height('100%')
  }

  /**
   * 全屏播放器的内容
   *
   * 全屏模态的顶边就是窗口顶（不再像半模态那样自带一条状态栏的让位），所以状态栏那一段
   * 要交给 PlayerView 自己让：把量到的 topInset 传进去，它给顶栏（下拉箭头 / 页码 / 分享）
   * 垫出那一截，背景则铺到状态栏底下。底部手势条的避让照旧。
   */
  @Builder
  playerSheet() {
    PlayerView({
      topInset: this.topInset,
      bottomInset: this.bottomInset,
      // 宽屏下播放页走「左封面 + 右歌词」的并排版式（见 PlayerView 的 wideLeftPane）
      windowWidth: this.windowWidth,
      onClose: () => {
        this.closePlayer();
      },
      onOpenQueue: () => {
        this.openQueue();
      },
      onKeepScreenOn: (on: boolean) => {
        this.setKeepScreenOn(on);
      },
      // 返回键的交接：覆盖物开着没有（评论 / 更多 / 音质 / 匹配歌词）
      onOverlayChange: (open: boolean) => {
        this.playerOverlayOpen = open;
      },
      // 收到返回键：按 +1 通知播放页收掉最上面那层
      backTick: this.playerBackTick,
    })
      .width('100%')
      .height('100%')
  }

  /**
   * 「歌词页不熄屏」（设置 - 播放设置）
   *
   * 窗口在页面手里，播放器只报「该不该常亮」。窗口没拿到（模拟器/异常）时静默忽略：
   * 这只是个体验项，不该因为它崩了播放页。
   */
  private setKeepScreenOn(on: boolean): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.setWindowKeepScreenOn(on).catch(() => {
      });
    } catch (e) {
      // 忽略：部分设备/场景不支持常亮
    }
  }

  /**
   * 点歌单 -> 打开歌单详情页
   *
   * 之前这里是「把歌单灌进播放队列 + 弹播放列表」，跳过了「看歌单」这一步：
   * 歌单是歌单，播放列表（队列）是播放列表，洛雪点歌单进的也是歌单详情。
   * 详情页里再「播放全部」或者点某一首，才动播放队列。
   */
  private openPlaylist(playlist: PlaylistSummary): void {
    const library = SyncManager.getInstance().getLibrary();
    if (!library.hasPlaylist(playlist.id)) {
      // 兜底：列表可能是同步覆盖前刷新出来的旧值，这时不该打开一个已不存在的歌单
      this.showToast(`「${playlist.name}」还没有歌单数据`);
      return;
    }
    this.routePlaylistId = playlist.id;
    this.routePlaylistName = playlist.name;
    this.pathStack.pushPath({ name: PAGE_PLAYLIST });
  }

  /** 点在线榜单 / 在线歌单 -> 打开在线详情页（歌单与榜单共用一页，kind 区分取数接口） */
  /** 打开「全部歌单」页（推荐页每个歌单分区的「更多」） */
  private openSquare(source: string, sortId: string, name: string): void {
    this.routeSquareSource = source;
    this.routeSquareSortId = sortId;
    this.routeSquareName = name;
    this.pathStack.pushPath({ name: PAGE_SQUARE });
  }

  private openOnline(route: OnlineRoute): void {
    this.routeOnlineKind = route.kind;
    this.routeOnlineSource = route.source;
    this.routeOnlineId = route.id;
    this.routeOnlineName = route.name;
    this.routeOnlineCover = route.cover;
    this.pathStack.pushPath({ name: PAGE_ONLINE });
  }

  /** 点一本听书 -> 打开书籍详情页（目录 + 播放那一集） */
  private openBook(hit: BookHit): void {
    this.routeBook = hit;
    this.pathStack.pushPath({ name: PAGE_BOOK });
  }

  /**
   * 点一位歌手 -> 打开歌手页（这位歌手在该平台的全部歌曲，按歌手聚合）
   *
   * 参数用基本类型逐项搬过去：ArtistView 那几个 @Prop 就是按值收的，
   * 与歌单 / 听书一样由壳层持有当前目标。
   */
  private openArtist(artist: LxArtist): void {
    this.routeArtistSource = artist.source;
    this.routeArtistId = artist.id;
    this.routeArtistMid = artist.mid;
    this.routeArtistName = artist.name;
    this.routeArtistPicUrl = artist.picUrl;
    this.routeArtistSongNum = artist.songNum;
    this.pathStack.pushPath({ name: PAGE_ARTIST });
  }

  /**
   * 点了某个歌手名（播放页那一行、歌曲列表行、回响的歌手列表都走这里）
   *
   * 这些调用点只报「谁在哪首歌里点的」，怎么开页面是这里的事，三件事都得在这一条路上办：
   *
   *   1. **播放页是全屏模态**（bindContentCover，压在导航层之上）—— 从播放页点歌手时
   *      得先把它收起来，否则歌手页会开在它底下、看不见。收起用的是同一个动画
   *      （closePlayer），所以观感上是「播放页退出去、歌手页进来」。
   *   2. **一位歌手就直接开**：歌手名是「名字」，而歌手页要的是「平台 + id」，
   *      所以先拿名字去平台认人（认不到会换别的平台试，见 resolveArtistByName）。
   *   3. **多位歌手先让人挑**：一首歌挂着「周杰伦、方文山」两位时，点一下没法知道
   *      用户想看谁 —— 先开歌手列表页，选完再进歌手页（回响的名单也是这一页）。
   */
  private openArtistFromSinger(source: string, singer: string): void {
    const candidates: ArtistCandidate[] = artistCandidatesOf(source, singer);
    if (candidates.length === 0) {
      return;
    }
    this.dismissPlayerIfOpen();
    if (candidates.length > 1) {
      this.openArtistList('选择歌手', '这首歌有几位歌手，想看哪一位？', candidates);
      return;
    }
    void this.resolveAndOpenArtist(candidates[0].source, candidates[0].name);
  }

  /** 开歌手列表页（回响的「常听歌手」整份名单也走它） */
  private openArtistList(title: string, hint: string, candidates: ArtistCandidate[]): void {
    if (candidates.length === 0) {
      return;
    }
    this.dismissPlayerIfOpen();
    this.routeArtistCandidates = candidates;
    this.routeArtistPickerTitle = title;
    this.routeArtistPickerHint = hint;
    this.pathStack.pushPath({ name: PAGE_ARTIST_PICKER });
  }

  /**
   * 播放页开着就先收起来（歌手页要压在导航层上，不收起来会被模态盖住）
   *
   * 播放队列那个半模态也一样得收：它挂在**最外层 Stack**上（比导航层还高一档），
   * 从队列里点歌手名时若不收起它，歌手页会被它整个盖住 —— 用户看到的是
   * 「点了没反应」。两个弹层都可能开着，所以一起收。
   */
  private dismissPlayerIfOpen(): void {
    if (this.playerOpen) {
      this.closePlayer();
    }
    if (this.queueOpen) {
      this.closeQueue();
    }
  }

  /**
   * 认人这件事正在飞（防连点）
   *
   * 认人要联网，一两秒内连点两下会解析出两条路由、叠两个歌手页。与回响那边
   * `playingKey` 是同一个意思，只是这里不需要参与渲染，所以用普通私有字段。
   */
  private artistOpening: boolean = false;

  /**
   * 拿名字去认一位歌手，认到了就开歌手页
   *
   * 认人要联网（就是一次歌手搜索），所以先给一句提示：点了一下没反应、
   * 一两秒后才跳页是最容易被当成「卡了」的。认不到就说清楚，别静默失败。
   */
  private async resolveAndOpenArtist(source: string, name: string): Promise<void> {
    // 认过的歌手直接开，不闪那句「正在查找歌手…」：从歌手列表页点进来时几乎总是命中
    // （那一页进去时已经挨个认过一遍，结果落盘了，见 MusicArtist 的 ArtistStore）
    const known: LxArtist | null = cachedArtistOf(name);
    if (known !== null) {
      this.openArtist(known);
      return;
    }
    if (this.artistOpening) {
      return;
    }
    this.artistOpening = true;
    this.showToast(`正在查找歌手「${name}」…`);
    let found: LxArtist | null = null;
    try {
      found = await resolveArtistByName(name, source);
    } catch (e) {
      found = null;
    } finally {
      this.artistOpening = false;
    }
    if (found === null) {
      this.showToast(`没找到歌手「${name}」（各平台都没搜到同名歌手）`);
      return;
    }
    this.openArtist(found);
  }

  /**
   * 页面之间的跳转请求（设置页的每一项、「我的」页的快捷入口与那张设置卡都走这里）
   *
   * 两个页面传进来的都是「去哪」这种字符串，路由统一在壳层实现（`go` 会往
   * HdsNavigation 的栈上压一个 HdsNavDestination），页面自己不认识 PAGE_* 常量。
   */
  private onSettingAction(action: string): void {
    if (action === 'source') {
      this.go(PAGE_SOURCE);
      return;
    }
    if (action === 'sync') {
      this.go(PAGE_SYNC);
      return;
    }
    if (action === 'cache') {
      this.go(PAGE_CACHE);
      return;
    }
    if (action === 'play') {
      this.go(PAGE_PLAY);
      return;
    }
    if (action === 'download') {
      this.go(PAGE_DOWNLOAD);
      return;
    }
    if (action === 'about') {
      this.go(PAGE_ABOUT);
      return;
    }
    if (action === 'appearance') {
      this.go(PAGE_APPEARANCE);
      return;
    }
    if (action === 'listen') {
      this.go(PAGE_LISTEN);
      return;
    }
    if (action === 'webdav') {
      this.go(PAGE_WEBDAV);
      return;
    }
    if (action === 'settings') {
      this.go(PAGE_SETTINGS);
      return;
    }
    // 「我的」页那一排快捷入口：收藏进内置那张收藏歌单的详情，其余四样各自是一页
    // （内容就是原来的四个分段面板）
    if (action === 'favorites') {
      this.openPlaylist(SyncManager.getInstance().getLibrary().favoritePlaylistSummary());
      return;
    }
    if (action === 'local') {
      this.go(PAGE_LOCAL);
      return;
    }
    if (action === 'history') {
      this.go(PAGE_HISTORY);
      return;
    }
    if (action === 'downloads') {
      this.go(PAGE_DOWNLOADS);
      return;
    }
    if (action === 'cloud') {
      this.go(PAGE_CLOUD);
      return;
    }
    this.showToast('该功能暂未接入');
  }

  /**
   * 子页面标题栏（HDS）
   *
   * 配方与系统应用的标题栏一致：
   *   - 系统材质：档位取外观设置（标题栏 / 底部页签栏 / 半模态三处同一档，见 buildTitleMaterial）；
   *   - 毛玻璃：blurStrategy ENABLE，标题栏后面的内容透上来，而不是一条死白；
   *   - 标题与图标颜色：系统主文字色，深浅模式切换后自动跟着换（不用自己判断）。
   *
   * 传了 `scroller` 才开渐变模糊：那是「一开始透明、滚起来才变磨砂」的过程，
   * 只有封面会滚到标题栏底下的详情页需要；白底设置页直接给材质更稳
   * （渐变模糊要绑滚动容器才算得出滚了多少，见各 destination 的 bindToScrollable）。
   *
   * title 传空字符串时只留返回键：在线歌单 / 歌单详情页的名字已经写在封面下面，
   * 标题栏再写一遍就是同一行字出现两次。
   */
  private titleBarOptions(title: string = '', scroller?: Scroller): HdsNavigationTitleBarOptions {
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      style: this.subTitleBarStyle(scroller),
    };
    if (title.length > 0) {
      options.content = { title: { mainTitle: title, mainTitleSize: TitleSize.TITLE_ML } };
    }
    return options;
  }

  /**
   * 子页面标题栏的样式（常规态与多选态共用同一份）
   *
   * 与首页 `homeTitleBar()` 同一套：`enableScrollEffect: false`（不随滚动起雾）、
   * `blurStrategy: DISABLE`（栏体不做模糊）、底色透明 + `maskExtraHeight: 0`
   * （不留任何实心面，包括标题栏底下那一条 32vp 的同色带）。
   *
   * 唯一与首页不同的是 **保留 `systemMaterialEffect`**：官方文档对它的说明是
   * 「可为标题栏**按钮**设置沉浸光感视效」—— 子页面的返回键是 HDS 自己画的按钮，
   * 它的液态玻璃就来自这一项；首页那排圆钮是我们自绘的组件、各自带 `.systemMaterial()`，
   * 所以首页那条不需要它（也因此不会被它在栏体上再刷一层材质）。
   * 之前统一配方时把这一项一起删了，返回键就退化成一个纯透明的箭头 —— 那是错的。
   *
   * 两套标题栏（常规 / 多选）只差内容（标题与钮），**样式一个字都不改**，所以多选时那颗
   * 「取消」与「全选」的玻璃动效与返回键同源，不必自绘 —— 内容区里自绘的玻璃在沉浸光感的
   * 生效范围之外，材质根本不渲染（见 ui/Glass.ets）。
   */
  private subTitleBarStyle(scroller?: Scroller): TitleBarStyleOptions {
    const contentStyle: HdsTitleBarContentStyle = {
      titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
      menuStyle: { iconColor: $r('sys.color.font_primary') },
    };
    const style: TitleBarStyleOptions = {
      scrollEffectOpts: { enableScrollEffect: false },
      blurStrategy: BlurStrategy.DISABLE,
      // 返回键 / 菜单项的液态玻璃（只作用于按钮，不画栏体）
      systemMaterialEffect: buildTitleMaterial(this.materialLevel),
      originalStyle: {
        backgroundStyle: {
          backgroundColor: Color.Transparent,
          maskExtraHeight: 0,
        },
        contentStyle: contentStyle,
      },
    };
    if (scroller !== undefined) {
      /**
       * 详情页（歌单详情 / 在线详情）的滚动联动样式
       *
       * 注意：**这段目前是不生效的** —— 上面 `enableScrollEffect` 已置 false，HDS 不会再
       * 按滚动量切到这一档；页面那边传 scroller 只是为了 `bindToScrollable`。留着它是因为
       * 一旦要把这两页的滚动联动重新打开（封面滚进标题栏时逐渐起雾），样式得是通透的这
       * 一份、不能退回默认的白底，否则又会冒出一条纯白。
       *
       * 另外要留意：这两页的内容外面套着 `WidePane(topPadding: HDS_TITLE_BAR_HEIGHT +
       * topInset)`，列表可视区是从标题栏下边缘才开始的，所以封面实际上**到不了**标题栏
       * 底下 —— 原来那句「封面会滚到标题栏底下」并没有真的发生。要让封面真的从标题栏下
       * 面滚过去，得把这两页的 topPadding 去掉、改用 List 的 contentStartOffset。
       */
      style.scrollEffectStyle = {
        backgroundStyle: {
          backgroundColor: Color.Transparent,
          maskExtraHeight: 0,
          blurRadius: 0,
        },
        contentStyle: contentStyle,
      };
    }
    return style;
  }

  /**
   * 子页面标题栏（多选时自动换成工具条那一套）
   *
   * 六个能进多选的页面（歌单详情 / 在线歌单 / 最近播放 / 本地音乐 / 下载管理 / 云端音乐）
   * 都走这里：平时就是原来那条（返回键 + 标题），多选时整条换掉。
   *
   * 多选那条**不用自绘**：三样都塞进 HDS 自己的槽位 ——
   *   - 左：`backIcon`（图标换成叉、动作换成「取消」）—— 就是原来那颗返回键的位置和长相，
   *     玻璃动效同源，所以不必自己画一颗「玻璃圆钮」（内容区自绘的玻璃在沉浸光感的
   *     生效范围之外，材质根本不渲染，见 ui/Glass.ets）；
   *   - 中：`title`，「已选中 N 项」，字号取 TITLE_ML，与华为音乐那一屏同一个版式；
   *   - 右：`menu` 里一项「全选 / 取消全选」，同样是标题栏按钮，玻璃与左钮一致。
   *
   * 换的是 options 本身，所以这一整条依赖上面那三个 @StorageLink 订阅值：勾选一变，
   * 标题里的数字与右钮的文案跟着变。
   */
  private pageTitleBar(title: string = '', scroller?: Scroller): HdsNavigationTitleBarOptions {
    if (!this.selectBarActive) {
      return this.titleBarOptions(title, scroller);
    }
    const session: SelectSession = SelectSession.getInstance();
    return {
      avoidLayoutSafeArea: true,
      style: this.subTitleBarStyle(scroller),
      content: {
        title: { mainTitle: `已选中 ${this.selectBarCount} 项`, mainTitleSize: TitleSize.TITLE_ML },
        backIcon: {
          icon: new SymbolGlyphModifier(I_CLOSE),
          label: '取消',
          action: () => {
            session.onCancel();
          },
        },
        menu: {
          value: [{
            content: {
              icon: new SymbolGlyphModifier(I_SELECT_ALL),
              label: this.selectBarAll ? '取消全选' : '全选',
              action: () => {
                session.onToggleAll();
              },
            },
          }],
        },
      },
    };
  }

  /**
   * HDS 子页面：搜索、音源设置、全屏播放器
   *
   * 标题栏与返回键全部交给 HdsNavDestination，页面本身不再自绘头部。
   * 标题栏默认是「沉浸」的（与内容层叠、可延伸进状态栏），所以这里给它开
   * avoidLayoutSafeArea，让返回键与标题自己退到状态栏下方；内容层再按
   * 「标题栏高度 + 状态栏高度」让位，两层各管各的，互不重叠。
   */
  @Builder
  destination(name: string, param: Object) {
    if (name === PAGE_SEARCH) {
      HdsNavDestination() {
        WidePane() {
          /**
           * 搜索页也套 `PanePage`：**底下要有那条页内迷你播放条**
           *
           * 这一页与歌单详情 / 在线详情 / 本地音乐那几页是同一类：压在 HdsNavigation 路由栈上
           * 的 NavDestination，把壳层那条带迷你栏的 HdsTabs 整个盖住了 —— 不自己挂一条，
           * 搜索页上就没有任何播放条（用户反馈「搜索结果页面也加上播放条，跟详情页面一样」）。
           * 复用 PanePage 而不是又抄一份 Tabs 外壳：那条胶囊的几何、材质、左右跟手、多选时
           * 让位给批量操作条，全都只有一份实现（见 views/PanePage.ets 开头）。
           */
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            SearchView({
              // 列表滚到底时要停在悬浮迷你条**上方**：条高 + 与它的间距，与其余几页同一口径
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              // 搜索页的「歌手」模式里点一位歌手 -> 歌手页（按歌手聚合的全部歌曲）
              onOpenArtist: (artist: LxArtist) => {
                this.openArtist(artist);
              },
              // 搜索页的「歌单」模式里点一张歌单 -> 在线歌单详情（与推荐页的歌单广场同一条路）
              onOpenOnline: (route: OnlineRoute) => {
                this.openOnline(route);
              },
            })
          }
        }
      }
      .titleBar(this.titleBarOptions('搜索'))
    } else if (name === PAGE_ARTIST) {
      // 歌手页：与搜索页同一套让位方式（顶部是固定的歌手头，歌曲列表自己滚）
      HdsNavDestination() {
        WidePane() {
          ArtistView({
            source: this.routeArtistSource,
            artistId: this.routeArtistId,
            artistMid: this.routeArtistMid,
            artistName: this.routeArtistName,
            artistPicUrl: this.routeArtistPicUrl,
            artistSongNum: this.routeArtistSongNum,
            topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
            bottomInset: this.bottomInset + HDS_BAR_HEIGHT,
            currentId: this.currentId,
          })
        }
      }
      // 歌手名已经写在头部（大头像右边），标题栏不再重复同一行字
      .titleBar(this.titleBarOptions(''))
    } else if (name === PAGE_ARTIST_PICKER) {
      // 歌手列表页：挑一位再进歌手页（回响的常听歌手 / 一首歌有几位歌手时）
      HdsNavDestination() {
        WidePane() {
          ArtistPickerView({
            title: this.routeArtistPickerTitle,
            hint: this.routeArtistPickerHint,
            candidates: this.routeArtistCandidates,
            topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
            bottomInset: this.bottomInset,
            onPick: (candidate: ArtistCandidate) => {
              void this.resolveAndOpenArtist(candidate.source, candidate.name);
            },
          })
        }
      }
      // 标题栏与页内那个「N 位」标题重复，所以这里不给标题
      .titleBar(this.titleBarOptions(''))
    } else if (name === PAGE_RECOGNIZE) {
      // 听歌识曲：可滚动的内容页，给一条顶栏渐隐（同各设置页），
      // 内容自己用一段会跟着滚走的顶部占位让开标题栏
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          RecognizeView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('听歌识曲'))
    } else if (name === PAGE_SOURCE) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          SourceSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('音源设置'))
      .onHidden(() => {
        this.refreshSourceSummary();
      })
    } else if (name === PAGE_SYNC) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          SyncSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('同步设置'))
    } else if (name === PAGE_CACHE) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          CacheSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('缓存'))
    } else if (name === PAGE_PLAY) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          PlaySettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('播放设置'))
    } else if (name === PAGE_DOWNLOAD) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          DownloadSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('下载设置'))
    } else if (name === PAGE_APPEARANCE) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          AppearanceSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('外观'))
    } else if (name === PAGE_LISTEN) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          ListenSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('听书'))
    } else if (name === PAGE_WEBDAV) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          WebDavSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('WebDAV 云端音乐'))
    } else if (name === PAGE_ABOUT) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          AboutView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('关于'))
    } else if (name === PAGE_SETTINGS) {
      // 「我的」页那张卡的「设置」：内容就是原来的设置页（它原来是一个页签），
      // 所以让位方式与页签时一样 —— 页面内部自己带顶部占位与渐隐，这里不再套 fadeTop
      HdsNavDestination() {
        WidePane() {
          SettingsView({
            topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
            bottomInset: this.bottomInset,
            sourceSummary: this.sourceSummary,
            onNavigate: (action: string) => {
              this.onSettingAction(action);
            },
          })
        }
      }
      .titleBar(this.titleBarOptions('设置'))
    } else if (name === PAGE_HISTORY) {
      HdsNavDestination() {
        WidePane() {
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            HistoryView({
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              currentId: this.currentId,
            })
          }
        }
      }
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('最近播放'))
    } else if (name === PAGE_SQUARE) {
      // 全部歌单：某个平台 × 某个排序的全部歌单（推荐页分区标题右边「更多」进来的）
      HdsNavDestination() {
        WidePane() {
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            PlaylistSquareView({
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              source: this.routeSquareSource,
              sortId: this.routeSquareSortId,
              sortName: this.routeSquareName,
              onOpenOnline: (route: OnlineRoute) => {
                this.openOnline(route);
              },
            })
          }
        }
      }
      .titleBar(this.pageTitleBar(this.routeSquareName))
    } else if (name === PAGE_LOCAL) {
      HdsNavDestination() {
        WidePane() {
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            LocalMusicPane({
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              currentId: this.currentId,
              onPick: (index: number) => {
                const list: SongItem[] = LocalMusic.getInstance().songsForUi();
                if (index >= 0 && index < list.length) {
                  PlaySession.getInstance().setQueueAndPlay(list, index);
                }
              },
            })
          }
        }
      }
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('本地音乐'))
    } else if (name === PAGE_DOWNLOADS) {
      HdsNavDestination() {
        WidePane() {
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            DownloadListPane({
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
            })
          }
        }
      }
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('下载管理'))
    } else if (name === PAGE_CLOUD) {
      HdsNavDestination() {
        WidePane() {
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            WebDavPane({
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              currentId: this.currentId,
              onPick: (index: number) => {
                const list: SongItem[] = WebDavLibrary.getInstance().songsForUi();
                if (index >= 0 && index < list.length) {
                  PlaySession.getInstance().setQueueAndPlay(list, index);
                }
              },
              onOpenSettings: () => {
                this.go(PAGE_WEBDAV);
              },
            })
          }
        }
      }
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('云端音乐'))
    } else if (name === PAGE_BOOK) {
      HdsNavDestination() {
        WidePane() {
          // 用 PanePage 而不是裸页面：它底下是「一列内容 + 一条悬浮迷你播放条」，
          // 点一集开始听之后，这一页自己就有一条迷你栏，不必退回首页才看得到进度
          PanePage({
            windowWidth: this.windowWidth,
            bottomInset: this.bottomInset,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          }) {
            BookDetailView({
              book: this.routeBook,
              topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
              bottomInset: this.bottomInset + HDS_BAR_HEIGHT + 26,
              windowWidth: this.windowWidth,
              onOpenPlayer: () => {
                this.openPlayer();
              },
              onOpenQueue: () => {
                this.openQueue();
              },
            })
          }
        }
      }
      // 书名写在头图里，标题栏不再重复（与歌单详情 / 在线详情同一处理）
      .titleBar(this.titleBarOptions(''))
    } else if (name === PAGE_ONLINE) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          OnlineListView({
            kind: this.routeOnlineKind,
            source: this.routeOnlineSource,
            listId: this.routeOnlineId,
            listName: this.routeOnlineName,
            listCover: this.routeOnlineCover,
            bottomInset: this.bottomInset,
            // 悬浮迷你栏的左右边距与「铺满」宽度按窗口算，与壳层那条同口径（见 ui/Layout.ets）
            windowWidth: this.windowWidth,
            topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
            scroller: this.onlineScroller,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          })
        }
      }
      // 顶栏不给标题：歌单名在封面下方已经有了，导航栏再重复一遍就是同一行字出现两次。
      // 这一页的封面会滚到标题栏底下，所以绑上滚动容器开渐变模糊：
      // 开始时返回键浮在封面上（底色透明），滚起来标题栏才变成磨砂。
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('', this.onlineScroller))
      .bindToScrollable([this.onlineScroller])
    } else if (name === PAGE_PLAYLIST) {
      HdsNavDestination() {
        WidePane({ fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          PlaylistDetailView({
            playlistId: this.routePlaylistId,
            playlistName: this.routePlaylistName,
            bottomInset: this.bottomInset,
            // 悬浮迷你栏的左右边距与「铺满」宽度按窗口算，与壳层那条同口径（见 ui/Layout.ets）
            windowWidth: this.windowWidth,
            topInset: HDS_TITLE_BAR_HEIGHT + this.topInset,
            scroller: this.playlistScroller,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          })
        }
      }
      // 同上：本地歌单的名字写在封面右边，顶栏不再重复；封面滚上去时标题栏才起磨砂
      // 多选时整条换成「取消 + 已选中 N 项 + 全选」（见 pageTitleBar）
      .titleBar(this.pageTitleBar('', this.playlistScroller))
      .bindToScrollable([this.playlistScroller])
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ---------------------------------------------------- HDS 导航（主页签 + 子页面）
      HdsNavigation(this.pathStack) {
        HdsTabs({ index: this.tabIndexOf(this.activeTabKey), controller: this.tabsController, barPosition: BarPosition.End }) {
          /**
           * 三个页签的内容**铺满窗口**（WidePane 的 maxWidth 给 0 = 不限宽），多列由各页
           * 自己按窗口宽度排（见 ui/Layout.ets 的 contentColumnsFor）——
           * 华为音乐的平板首页就是这样：正文铺到窗口边上，一屏三列。
           *
           * 之前这里是 `maxWidth: this.contentMaxWidth()`（宽屏收成居中的 720）：
           * 平板上两侧各留一大片白，列表一行从屏左拉到屏右，正是被吐槽的那一版。
           * 收窄那套仍然留给详情页 / 设置页（见 contentMaxWidth 的说明）。
           */
          TabContent() {
            WidePane() {
              RecommendView({
                topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                bottomInset: this.bottomInset + 96,
                onOpenOnline: (route: OnlineRoute) => {
                  this.openOnline(route);
                },
                onOpenSquare: (source: string, sortId: string, name: string) => {
                  this.openSquare(source, sortId, name);
                },
              })
            }
          }
          .tabBar(this.tabBarItem(TAB_KEY_HOME))

          /**
           * 听书这一栏可以在「设置 - 听书」里隐藏（见 hideListenTab）
           *
           * 整块 TabContent 一起不摆：栏里的那一项与它的内容一起没掉，导航栏只剩推荐与我的。
           * 栏位的下标会跟着前移，但那一栏的图标 / 文字是按**身份**取的（tabBarItem 的入参
           * 是 TAB_KEY_*，不是下标），所以「我的」照样显示成「我的」。
           */
          if (!this.hideListenTab) {
            TabContent() {
              WidePane() {
                ListenView({
                  topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                  bottomInset: this.bottomInset + 96,
                  // 网页登录是整屏覆盖层（bindContentCover），不经过标题栏，所以另给一份
                  // 纯状态栏 / 手势条的高度，它自己补留白
                  safeTop: this.topInset,
                  safeBottom: this.bottomInset,
                  onOpenBook: (hit: BookHit) => {
                    this.openBook(hit);
                  },
                })
              }
            }
            .tabBar(this.tabBarItem(TAB_KEY_LISTEN))
          }

          /**
           * 回响：月度收听记录（大标题 + 总时长 + 三格统计 + 年月选择 + 这个月听过的歌）
           *
           * 它跟「听书」一样是**内容铺满**的页签页，页内自带顶栏渐隐与底部让位
           * （见 views/EchoView.ets）。
           */
          TabContent() {
            WidePane() {
              EchoView({
                topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                bottomInset: this.bottomInset + 96,
              })
            }
          }
          .tabBar(this.tabBarItem(TAB_KEY_ECHO))

          TabContent() {
            WidePane() {
              MineView({
                topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                bottomInset: this.bottomInset + 96,
                // 「我的」页里那一排快捷入口（本地音乐 / 最近播放 / 下载管理 / 云端音乐）、
                // 那张设置卡的「设置 / 帮助和反馈」，以及云端音乐的「去设置」都走壳层路由
                onNavigate: (action: string) => {
                  this.onSettingAction(action);
                },
                // 歌单卡里点一张歌单 → 与原来歌单页同一个入口（详情页在路由栈上）
                onOpenPlaylist: (playlist: PlaylistSummary) => {
                  this.openPlaylist(playlist);
                },
                // 「收藏歌单」那一段里点一张 → 那是**在线**歌单，走在线详情页
                onOpenOnline: (route: OnlineRoute) => {
                  this.openOnline(route);
                },
              })
            }
          }
          .tabBar(this.tabBarItem(TAB_KEY_MINE))
        }
        // 悬浮页签栏：贴底、横向、固定宽度档、页签悬浮在内容之上（照派音）
        .barPosition(BarPosition.End)
        .vertical(false)
        .barMode(BarMode.Fixed)
        .barOverlap(true)
        .scrollable(true)
        // 高度写死成与自绘迷你栏同一个常量：两边必须一样高，观感才统一
        .barHeight(HDS_BAR_HEIGHT)
        .zIndex(1)
        .barFloatingStyle({
          /**
           * 左右跟手：迷你播放器展开、页签栏折叠成一颗球时，那颗球按托着手机的那只手换边
           *
           * 迷你栏展开时两条栏是左右并排的（页签栏一边、迷你栏一边），页签栏被让位折叠成
           * 一颗圆球 —— 球站哪一边由 HDS 的 `adaptToHandedness`（6.1.0/23 起）定：
           * 开了就跟着握持手走（右手握持时那颗球贴右边，拇指够得着），不开是恒定的
           * 「页签栏在左、迷你栏在右」。官方文档里这一项只有一句「左右手跟手能力依赖底层
           * 硬件，部分历史设备硬件能力不支持」——**没有**任何权限要求，跟手这件事是 HDS
           * 自己读的（不必在应用侧订阅握姿，见 module.json5 里没有相关权限）。
           * 开关在「设置 - 外观」，读不出来 / 不支持的机型上就是原样，不会乱跑。
           */
          adaptToHandedness: this.followHand,
          /**
           * **不声明 barWidth / miniBarWidth**（派音最新代码踩过一轮后的结论）
           *
           * 我们原来按档算了页签栏与迷你栏的宽度（smallWidth = 窗口宽 − 96、miniBarWidth 按
           * 每档减掉另一条栏要占的宽度）。派音那边也这么干过，结论写在他们的 Index.ets 里：
           * 「不要传 barWidth……我们原来传的三档会让整条底栏明显窄于屏幕，**上下两排时两侧就
           * 留出很大空隙**（用户反馈的就是这个）」。他们现在只留
           * barBottomMargin / systemMaterialEffect / adaptToHandedness / miniBar 四项 ——
           * 宽度全交给 HDS 按排布自己算：单排时迷你条铺满整条、两排时两条各占一排。
           * 这里照此把两项一起去掉（原来那套按档算的口径留在 ui/Layout.ets，页内那条自绘迷你栏
           * 还在用）。
           *
           * `barSideMargin` / `gradientMask` 也仍然不声明：前者与 HDS 内部的宽度分配互相打架
           * （两条栏一起展开时叠在一起），后者没必要。
           */
          barBottomMargin: this.homeTabBarBottomMarginVp(),
          // 与标题栏、半模态共用同一个材质档位（外观设置里改一处，三处一起变）
          systemMaterialEffect: buildTitleMaterial(this.materialLevel),
          // 迷你栏：单排时被拉成整条通栏（展开播放态），两排时收成窄胶囊，页签自己一排。
          // 配置由 miniBarConfig() 拼（那里说明了两排状态怎么落给 HDS、以及低版本为什么要
          // 让 barLayoutMode 这个键整条不出现）。
          miniBar: this.miniBarConfig(),
        })
        .onChange((index: number) => {
          // 框架给的是「第几栏」，这里立刻换成身份存下来（见 onTabChanged）
          this.onTabChanged(index);
        })
        .width('100%')
        .height('100%')
      }
      // 首页也是有标题栏的：页头（大标题 + 那几个圆钮）就画在标题栏的 stackBuilder 里，
      // 沉浸光感才生效（见 homeTitleBar 的说明）
      .titleBar(this.homeTitleBar())
      /**
       * 标题栏模式固定成 MINI（小标题栏）
       *
       * 不设的话默认是大标题栏那一档：往下滚的时候它会随滚动收拢/换样式，表现就是
       * 「停在顶部时通透、一滑就变回一条灰白」。首页要的是一块固定高度、始终通透的
       * 标题栏（页头本来就由 stackBuilder 画），所以锁成 MINI，不让它跟着滚动变。
       * 官方示例里配 stackBuilder 用的也是 MINI。
       */
      .titleMode(HdsNavigationTitleMode.MINI)
      /**
       * 首页不要返回键
       *
       * 这是导航栈的根（`pathStack` 为空），本来就没有上一级可退；而 `stackBuilder`
       * 已经把整排页头（大标题 + 圆钮）铺在标题栏那一行里，HDS 再画一颗返回键就会跟
       * 「推荐」这两个字叠在一起。返回键只属于子页面（HdsNavDestination）。
       */
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .navDestination(this.destination)
      .width('100%')
      .height('100%')
      /**
       * 全屏播放器：全屏模态（bindContentCover）
       *
       * 以前这里是 bindSheet（底部半模态）：弹起时整块面板从下往上滑，与下面那条迷你栏
       * 没有任何视觉联系，观感上就是「一个盖子上来」——也就是「割裂」的来源。
       * 中间试过一版「共享元素转场（一镜到底）」：把迷你栏那颗封面与播放页封面绑同一个
       * `geometryTransition` id，让封面从迷你栏长到播放页。**那一版已撤掉**，因为配对根本不成立：
       *   - `geometryTransition` 只能在**同一棵渲染树**里配对 in/out 两个节点，而播放页是
       *     bindContentCover 的**模态**（独立渲染根），迷你栏那颗封面在模态之外的那棵树里；
       *   - 迷你栏内容又会被 HDS 在页签变化/壳层重渲染时重建，起点节点连自己那一帧的几何
       *     都还没量好。
       * 框架拿不到可信的起点几何，就按「未知帧」起飞 —— 实机表现就是用户反馈的
       * 「屏幕左上角莫名其妙闪一张歌曲封面、然后消失，再打开播放页」。同时 `follow: true`
       * 官方写明**只在 `if` 语法里生效**，常驻在树上的迷你栏封面不在 if 里，也参与不进来。
       *
       * 现在用系统标准模态转场 `ModalTransition.DEFAULT`：官方定义就是
       * 「Upward animation when entering and downward animation when exiting」
       * —— 打开时整页从下往上升起、收起（返回 / 侧滑 / 下拉）时从上往下滑走，
       * 不需要我们自己的 animateTo 或 transition 参与（见 openPlayer 的说明）。
       * 以后若要做「从小播放器展开成播放页」那种华为音乐式的一镜到底，得走官方那条路
       * （同一棵树里的 if/else 配对 + `follow`，或 NavContentTransition 那一套），
       * 不能再把 geometryTransition 跨到模态上去。
       *
       * 仍然挂在导航节点（而不是最外层 Stack）上，好和播放列表那个 bindSheet 分开挂载：
       * 同一个节点上叠两个弹层会互相干扰。
       */
      .bindContentCover($$this.playerOpen, this.playerSheet(), {
        modalTransition: ModalTransition.DEFAULT,
        // 底色交给 PlayerView 自己画：模态这层再铺一层不透明底会把转场那一下盖掉
        backgroundColor: Color.Transparent,
        onWillAppear: () => {
          this.applyStatusBarColor(true);
        },
        onDisappear: () => {
          this.applyStatusBarColor(false);
          // 模态被系统收掉（下拉 / 侧滑 / 返回）时不走 closePlayer，这里兜底清状态
          this.playerOverlayOpen = false;
        },
        /**
         * 系统返回键先交给播放页处理
         *
         * 注册这个回调之后，返回键不再立刻收起模态：评论 / 更多 / 音质 / 匹配歌词
         * 这些自绘覆盖物还开着时，先去收那一层（评论页的返回箭头一直是好的，系统
         * 返回键以前却会把整个播放页收掉，露出下面的页签页 —— 就是「有概率回到
         * 一级菜单」的由来）。其余情况（没有覆盖物、下拉手势等）照旧收起播放页。
         */
        onWillDismiss: (action: DismissContentCoverAction) => {
          if (action.reason === DismissReason.PRESS_BACK && this.playerOverlayOpen) {
            this.playerBackTick++;
            return;
          }
          this.playerOverlayOpen = false;
          action.dismiss();
        },
      })

      // 播放列表是系统的半模态：bindSheet 挂在最外层 Stack 上（见文件末尾）
      // ——弹层之间「后开的在上」，所以从播放页里点开播放列表，它会盖在播放页之上。

      // ---------------------------------------------------- 状态提示
      if (this.toast.length > 0) {
        Column() {
          Text(this.toast)
            .fontSize(F_SUB)
            .fontColor(C_TEXT)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .constraintSize({ maxWidth: '86%' })
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        // 提示条要保证文字可读，色调给得比其它玻璃层实一点；但必须带透明度，
        // 不透明底色会把毛玻璃的模糊盖掉（玻璃感就没了）。厚度跟外观设置的档位走，
        // 底色是 token：深色模式下换成深色半透明底，不然白底黑字会一直亮着
        .attributeModifier(thinGlass(18, false, C_GLASS_SOLID, this.materialLevel))
        .systemMaterial(immersiveMaterialFor(this.materialLevel))
        // 边沿那圈光：鸿蒙7 是空效果（光感归材质），鸿蒙6 落成 HDS 轮廓点光（普通光效）
        .visualEffect(glassLight())
        // 压在底部迷你栏 / 页签栏之上：顶部在子页面里是标题栏与返回键的位置，别挡着
        .align(Alignment.Bottom)
        .margin({ left: 16, right: 16, bottom: this.bottomInset + 92 })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }

      // ---------------------------------------------------- 音源沙箱（1x1）
      Column() {
        SourceSandboxHost()
      }
      .width(1)
      .height(1)
      .position({ x: 0, y: 0 })

      // ---------------------------------------------------- 听书沙箱（1x1）
      // 与音源沙箱是**两个独立页面**：音源沙箱要禁 eval、只暴露 lx.*；
      // 听书沙箱要能 eval 规则、要用 DOM 做 CSS 选择器。塞进同一个页面会互相破坏，
      // 所以各用各的（成本只是多一个 1x1 的 Web，见 components/BookSandboxHost.ets）
      Column() {
        BookSandboxHost()
      }
      .width(1)
      .height(1)
      .position({ x: 0, y: 0 })

      // ---------------------------------------------------- 删除粒子飘散
      // 全局唯一的一层：任何页面删除时调 dustBus.spray(x, y)，粒子就在那里散开
      DustLayer()

      // ---------------------------------------------------- 同步方式选择
      // 独立挂在 Stack 的另一个节点上：播放列表那个 bindSheet 已经占了最外层节点，
      // 同一个节点叠两个 bindSheet 会互相干扰。
      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindSheet($$this.syncModeOpen, this.syncModeSheet(), {
          preferType: SheetType.BOTTOM,
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.MEDIUM,
          dragBar: true,
          showClose: true,
          // 背景色必须显式改成透明：SheetOptions 的 backgroundColor 默认是 Color.White，
          // 不透明的底色会把材质整片盖住（官方示例10 也是这么配的）
          backgroundColor: isGlassMaterialSupported() ? Color.Transparent : undefined,
          systemMaterial: immersiveMaterialForDialog(this.materialLevel),
          title: { title: '同步方式' },
          onDisappear: () => {
            // 用户下滑关掉也算「取消同步」；已选过的话 answerMode 是空操作
            this.syncModeOpen = false;
            SyncManager.getInstance().answerMode('cancel');
          },
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    /**
     * 播放列表：华为官方的半模态（bindSheet）
     *
     * 标题栏、右上角关闭钮、顶部拖动条、背景材质全部由系统给，我们只提供队列内容；
     * isShow 用 $$ 双向绑定，用户下滑或点关闭时状态位会自动收回来。
     */
    .bindSheet($$this.queueOpen, this.queueSheet(), {
      preferType: SheetType.BOTTOM,
      // 默认只升到半屏（还能往上拖到接近全屏）
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      detentSelection: SheetSize.MEDIUM,
      // 高度变化时滚动区域要跟着实时变（默认 FOLLOW_DETENT 是「滑完才更新」，见下）。
      // 默认值 `ScrollSizeMode.FOLLOW_DETENT` 的官方语义是「滑完（档位动画结束）之后才更新
      // 滚动区域」：从 MEDIUM 往上拖到 LARGE 的这几百毫秒里，面板本身已经长高了，里面的
      // List 却还按半屏的高度排版 —— 实机表现就是用户反馈的
      // 「向上滑先滑一半，再拉到顶的时候，歌曲会先显示一半，然后再加载出剩下的部分」：
      // 白卡只铺到半屏，等动画结束 List 视口才被换成满高，下半截的行这时才建出来补上。
      // 改成 `CONTINUOUS`（官方语义：滑动过程中就更新滚动区域）之后，List 的视口与面板
      // 同步长高，新露出来的那几行当场量出来，不再有「先半屏、再补全」的两段式。
      // 依据：华为开发者问答《为什么在半模态中渲染列表，半模态高度变化的时候，列表会延迟
      // 渲染》的采纳答复就是加这一个属性（提问描述的现象与本条反馈完全一致）。
      // `scrollSizeMode` 是 API 12 的接口，本工程 compatibleSdkVersion 6.1.0(23) 起就能用，
      // 不用像材质那套（鸿蒙7 才有）那样做版本判断。
      scrollSizeMode: ScrollSizeMode.CONTINUOUS,
      dragBar: true,
      showClose: true,
      // 材质与毛玻璃是互斥的两条路，不能同时挂着：官方对弹出框写明「已主动设置背景色、
      // 背景模糊等自定义样式属性，则不呈现沉浸光感效果」，而且 SheetOptions 的
      // backgroundColor 默认是 Color.White，不改透明同样会把材质盖住。
      // 所以材质可用时两者一起让位，只有材质不可用才轮到 blurStyle 兜底
      // （见 ui/Glass.ets 的 immersiveMaterialForDialog）。
      blurStyle: isGlassMaterialSupported() ? undefined : BlurStyle.COMPONENT_ULTRA_THICK,
      backgroundColor: isGlassMaterialSupported() ? Color.Transparent : undefined,
      systemMaterial: immersiveMaterialForDialog(this.materialLevel),
      title: { title: '播放列表', subtitle: `共 ${this.queueCount} 首` },
    })
  }
}
