import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { BlurStrategy, HdsBarStyle, HdsNavigation, HdsNavigationTitleBarOptions, HdsNavigationTitleMode,
  HdsNavDestination, HdsTabs, HdsTabsController, HdsTitleBarContentStyle,
  TitleBarStyleOptions, TitleSize } from '@kit.UIDesignKit';
import { K_CURRENT_ID, K_MINI_EXPANDED, K_QUEUE_COUNT, K_STATUS_TEXT, PlaySession, SongItem } from '../core/player/PlaySession';
import { LocalMusic } from '../core/local/LocalMusic';
import { WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { SourceEngine } from '../core/source/SourceEngine';
import { SourceInfo, SourceLog } from '../core/source/LxTypes';
import { OnlineRoute, LIST_PLATFORMS, platformName } from '../core/music/MusicList';
import { C_BG, C_GLASS_SOLID, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, F_SUB } from '../ui/Theme';
import { immersiveMaterialFor, immersiveMaterialForDialog, isGlassMaterialSupported, materialFirstGlass,
  thinGlass } from '../ui/Glass';
import { DustLayer } from '../ui/Dust';
import { SourceSandboxHost } from '../components/SourceSandboxHost';
import { SyncManager, K_SYNC_STATUS } from '../core/sync/SyncManager';
import { describeStatus, shouldNotifySyncMessage } from '../core/sync/SyncStatusText';
import { buildTitleMaterial, HDS_BAR_HEIGHT, HDS_TITLE_BAR_HEIGHT } from '../ui/Hds';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { contentMaxWidthFor, K_BAR_MINI_WIDTH, publishedMiniBarWidth } from '../ui/Layout';
import { PageTitle, RoundIconButton, WidePane } from '../ui/Widgets';
import { AppearanceSettingsView } from '../views/AppearanceSettingsView';
import { AboutView } from '../views/AboutView';
import { WebDavSettingsView } from '../views/WebDavSettingsView';
import { I_BOOK, I_BOOK_FILL, I_CHEVRON_DOWN, I_CLOSE, I_HOME, I_HOME_FILL, I_PERSON, I_PERSON_FILL,
  I_SEARCH, I_SELECT_ALL, IconGlyph } from '../ui/Icons';
import { MiniBarView } from '../views/MiniBar';
import { BookSandboxHost } from '../components/BookSandboxHost';
import { BookDetailView } from '../views/BookDetailView';
import { ListenView } from '../views/ListenView';
import { BookShelf } from '../core/book/BookShelf';
import { BookHit } from '../core/book/BookTypes';
import { MineView } from '../views/MineView';
import { OnlineListView } from '../views/OnlineListView';
import { PanePage } from '../views/PanePage';
import { PlayerView } from '../views/PlayerView';
import { PlayQueueContent } from '../views/PlayQueueSheet';
import { PlaylistDetailView } from '../views/PlaylistDetailView';
import { HistoryView } from '../views/HistoryView';
import { LocalMusicPane } from '../views/LocalMusicView';
import { DownloadListPane } from '../views/DownloadListView';
import { WebDavPane } from '../views/WebDavView';
import { K_RECOMMEND_SOURCE, RecommendView } from '../views/RecommendView';
import { SearchView } from '../views/SearchView';
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
/** 本地音乐（导入本机音频 / 批量移除） */
const PAGE_LOCAL: string = 'local';
/** 下载管理（下载中 / 已完成 / 失败重下） */
const PAGE_DOWNLOADS: string = 'downloads';
/** 云端音乐（WebDAV 曲库，与「WebDAV 云端音乐」设置页是两件事） */
const PAGE_CLOUD: string = 'cloud';
/** 听书：一本书的详情 + 目录 */
const PAGE_BOOK: string = 'book';

/** 底部悬浮页签的页签 */
interface TabDef {
  icon: Resource;
  iconActive: Resource;
  label: string;
}

/**
 * 三个页签：推荐 / 听书 / 我的
 *
 * 原来是四个（推荐 / 歌单 / 我的 / 设置）：歌单与设置的**内容**现在都在「我的」页里
 * （照华为音乐的「我的」重排：快捷入口 + 歌单卡 + 设置卡），再留着那两个页签就是
 * 同一件事有两个入口，所以先收成两个。
 *
 * 「听书」单独占一栏，夹在推荐与我的之间：它**不是**音乐的一种（书源是阅读/Legado
 * 的 JSON 规则，与音源完全不同的一套协议，见 core/book/book_preload.js），
 * 混进推荐页会让「音乐」那一栏的语义变糊；而它又是使用频率很高的主功能，
 * 藏在「我的」的二级入口里不合适，所以给它一个并列的一级页签。
 */
const TABS: TabDef[] = [
  { icon: I_HOME, iconActive: I_HOME_FILL, label: '推荐' },
  { icon: I_BOOK, iconActive: I_BOOK_FILL, label: '听书' },
  { icon: I_PERSON, iconActive: I_PERSON_FILL, label: '我的' },
];

/**
 * 应用壳层
 *
 * 结构对应洛雪移动端：
 *   底部是 HDS 的悬浮页签栏（推荐 / 歌单 / 我的 / 设置）+ 挂在它右边的迷你栏：
 *     迷你栏折叠 = 洛雪那颗悬浮专辑圆钮，展开 = 迷你播放器（封面 + 播放/下一首/播放列表）。
 *     展开与折叠的互斥、让位动画都是 HDS 自己做的，点一下就切换。
 *   点迷你播放器的信息区弹出全屏播放器：它是系统的底部半模态（bindSheet），
 *     从下往上弹、顶边停在状态栏下方，下面那层页面不重建也不退出；
 *     播放列表是另一层半模态，两者各自挂在不同节点上，互不干扰。
 *   音源沙箱（1x1 的 ArkWeb）始终挂在最外层，保证换页不会打断源脚本状态
 */
@Entry
@Component
struct Index {
  @State activeTab: number = 0;
  @State playerOpen: boolean = false;
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
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_STATUS_TEXT) statusText: string = '';
  @StorageLink(K_QUEUE_COUNT) queueCount: number = 0;
  /**
   * 窗口宽度（vp）
   *
   * 底部两条悬浮栏的宽度、内容列的最大宽度都按它算（见 ui/Layout.ets）：
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
      if (log.type === 'error' || log.type === 'warn') {
        this.showToast(log.message);
      }
    };
    engine.setLogListener(this.logListener);

    this.noticeListener = (text: string) => {
      this.showToast(text);
    };
    PlaySession.getInstance().setNoticeListener(this.noticeListener);

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
      // 底部两条栏的宽度与内容列的最大宽度都得跟着重算（见 ui/Layout.ets）
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
   * 只有页内那条迷你栏（歌单详情 / 在线详情，不在页签体系里）需要：
   * 宽屏下它要跟 HdsTabs 那条迷你栏同宽（0 = 窄屏，照旧铺满）。
   */
  private publishLayout(): void {
    // 从 AppStorage 读展开态而不是 @StorageLink：HDS 的 onBarStyleChange 里刚写完
    // 这个键就调本方法，此时 @StorageLink 还没同步回来，会读到上一轮的旧值。
    const expanded: boolean = AppStorage.get<boolean>(K_MINI_EXPANDED) ?? false;
    AppStorage.setOrCreate(K_BAR_MINI_WIDTH, publishedMiniBarWidth(this.windowWidth, expanded));
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
   * 播放器是**系统的底部半模态**（bindSheet，SheetSize.LARGE = 接近满屏、顶部留一条），
   * 不是当前页里的一层覆盖物、也不是路由页：
   *   - 路由页会把下面的页面整个盖住/重建，不符合「从下往上弹、不干扰原页面」；
   *   - 而半模态是系统弹窗，下面的页面原样留着（只压一层遮罩），返回键 / 侧滑返回
   *     由系统分发给最上层弹窗并收起它（DismissReason.PRESS_BACK），不会把应用退回桌面。
   * 状态栏字色挂在半模态的 onWillAppear / onDisappear 上，跟弹出、收起对齐。
   */
  private openPlayer(): void {
    this.playerOpen = true;
  }

  private closePlayer(): void {
    this.playerOpen = false;
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
   * 悬浮页签栏的宽度（vp）
   *
   * 口径照派音：小档按「窗口宽 - 96」（左右各留 48）。窄屏下这条要铺到接近满宽，
   * 与华为音乐那种「一条长胶囊托住所有页签」的观感一致。
   * 中 / 大档另给（见 barFloatingStyle 里的 barWidth）—— **不要再自己算宽度塞给
   * miniBarWidth**，那会和 HDS 的让位动画打架。
   */
  private floatingBarSmallWidthVp(): number {
    return this.windowWidth > 0 ? this.windowWidth - 96 : 264;
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
   * 内容列的最大宽度（vp）
   *
   * 宽屏（≥ 600vp）收成居中一列，手机返回 0 = 不限宽（WidePane 会翻成「不限」）。
   */
  private contentMaxWidth(): number {
    return contentMaxWidthFor(this.windowWidth);
  }

  /** 页签选中态用的强调色 / 未选中态的图标 token */
  private tabColor(index: number): Resource {
    return this.activeTab === index ? C_RED : C_ICON;
  }

  /**
   * 单个页签：图标 + 文字（照派音的 `TabBarItem`）
   *
   * 悬浮页签栏的样式下 `tabBar` 只认官方 BottomTabBarStyle 或自定义构建器，
   * 这里用后者，好和派音保持同一套字号与间距：图标 22、文字 11、间距 4，
   * 选中态换实心变体 + 主题红，未选中走图标 token（深浅模式各一份）。
   */
  @Builder
  tabBarItem(index: number) {
    Column({ space: 4 }) {
      SymbolGlyph(this.activeTab === index ? TABS[index].iconActive : TABS[index].icon)
        .fontSize(22)
        .fontWeight(FontWeight.Regular)
        .height(22)
        .fontColor([this.tabColor(index)])
      Text(TABS[index].label)
        .fontSize(11)
        .fontColor(this.tabColor(index))
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
       *   3) 标题栏自身不做模糊 —— 模糊是「通透」的反面：静止时它把流光糊成一片
       *      看着"跟背景一样"，一旦有列表从底下经过就立刻显形成一条灰白。
       *      注意这条只影响标题栏**这层表面**，不影响圆钮上的沉浸光感。
       */
      scrollEffectOpts: { enableScrollEffect: false },
      blurStrategy: BlurStrategy.DISABLE,
      /**
       * 栏体**不给**材质：首页只要「透明底 + 不留蒙版」，材质全部留给栏里的自绘钮
       *
       * 试过给这一项（实测栏体会整条变成一层材质玻璃带，压在首页那层 HDS 背景流光上
       * 挡掉一截，列表滑到栏下也会被模糊），但那样顶栏就成了一整条玻璃栏，而不是
       * 「两颗玻璃钮浮在流光上」—— 官方那套「标题栏按钮沉浸光感」的观感本来就是后者，
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
   * 动作按页签给：只有「推荐」有（来源 + 搜索）。「我的」页的动作（新建歌单 / 导入 /
   * 设置）都在页面自己的卡片里，标题栏这一行不再挂东西 —— 与华为音乐的「我的」一致，
   * 那边标题栏也只有标题（外加它自己的会员 / 消息钮，那两样我们没有）。
   *
   * 画在标题栏里的钮走 `materialFirstGlass`：材质可用时不叠自绘底（沉浸光感的视觉层级在
   * backgroundColor / backgroundBlurStyle 之下，自己再画一层磨砂就把材质整片盖住了），
   * 材质不可用的设备自动退回自绘玻璃。
   */
  @Builder
  homeHeader() {
    Row({ space: 10 }) {
      PageTitle({ text: TABS[this.activeTab].label })
      Blank()
      if (this.activeTab === 0) {
        this.sourcePicker()
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

  /** 来源下拉菜单：改的是 AppStorage 里的推荐来源，推荐页订阅它重新取数 */
  @Builder
  sourceMenu() {
    Menu() {
      ForEach(LIST_PLATFORMS, (id: string) => {
        MenuItem({ content: platformName(id) })
          .onClick(() => {
            AppStorage.setOrCreate(K_RECOMMEND_SOURCE, id);
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
   * 播放器半模态的内容
   *
   * 半模态的顶边已经在状态栏下方，所以这里给 PlayerView 的 topInset 传 0：
   * 再让一次状态栏的位就会多出一条空白。底部手势条的避让仍旧照给。
   */
  @Builder
  playerSheet() {
    PlayerView({
      topInset: 0,
      bottomInset: this.bottomInset,
      onClose: () => {
        this.closePlayer();
      },
      onOpenQueue: () => {
        this.openQueue();
      },
      onKeepScreenOn: (on: boolean) => {
        this.setKeepScreenOn(on);
      },
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
        WidePane({ maxWidth: this.contentMaxWidth() }) {
          SearchView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('搜索'))
    } else if (name === PAGE_SOURCE) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          SourceSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('音源设置'))
      .onHidden(() => {
        this.refreshSourceSummary();
      })
    } else if (name === PAGE_SYNC) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          SyncSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('同步设置'))
    } else if (name === PAGE_CACHE) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          CacheSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('缓存'))
    } else if (name === PAGE_PLAY) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          PlaySettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('播放设置'))
    } else if (name === PAGE_DOWNLOAD) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          DownloadSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('下载设置'))
    } else if (name === PAGE_APPEARANCE) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          AppearanceSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('外观'))
    } else if (name === PAGE_WEBDAV) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          WebDavSettingsView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('WebDAV 云端音乐'))
    } else if (name === PAGE_ABOUT) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
          AboutView({ bottomInset: this.bottomInset, topInset: HDS_TITLE_BAR_HEIGHT + this.topInset })
        }
      }
      .titleBar(this.titleBarOptions('关于'))
    } else if (name === PAGE_SETTINGS) {
      // 「我的」页那张卡的「设置」：内容就是原来的设置页（它原来是一个页签），
      // 所以让位方式与页签时一样 —— 页面内部自己带顶部占位与渐隐，这里不再套 fadeTop
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
    } else if (name === PAGE_LOCAL) {
      HdsNavDestination() {
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
        WidePane({ maxWidth: this.contentMaxWidth() }) {
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
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
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
        WidePane({ maxWidth: this.contentMaxWidth(), fadeTop: HDS_TITLE_BAR_HEIGHT + this.topInset + 10 }) {
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
        HdsTabs({ index: this.activeTab, controller: this.tabsController, barPosition: BarPosition.End }) {
          // 页签内容是「宽屏收成居中一列、手机铺满」：收窄交给 WidePane，见 ui/Widgets.ets
          TabContent() {
            WidePane({ maxWidth: this.contentMaxWidth() }) {
              RecommendView({
                topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                bottomInset: this.bottomInset + 96,
                onOpenSearch: () => {
                  this.go(PAGE_SEARCH);
                },
                onOpenOnline: (route: OnlineRoute) => {
                  this.openOnline(route);
                },
              })
            }
          }
          .tabBar(this.tabBarItem(0))

          TabContent() {
            WidePane({ maxWidth: this.contentMaxWidth() }) {
              ListenView({
                topInset: this.topInset + HDS_TITLE_BAR_HEIGHT,
                bottomInset: this.bottomInset + 96,
                onOpenBook: (hit: BookHit) => {
                  this.openBook(hit);
                },
              })
            }
          }
          .tabBar(this.tabBarItem(1))

          TabContent() {
            WidePane({ maxWidth: this.contentMaxWidth() }) {
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
          .tabBar(this.tabBarItem(2))
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
           * 只给「页签栏宽度 + 离底距离 + 材质 + 迷你栏」，其余全部交给 HDS 自己算
           *
           * 这是派音（RzdMusic）那套配置，也正是这里之前被改坏的地方 —— 之前额外塞了
           * `miniBarWidth` / `barSideMargin` / `gradientMask` / `barLayoutMode`：
           *   - `miniBarWidth` 顶掉了 HDS 的让位动画：折叠态本来只有一颗圆钮宽
           *     （宽度等于栏高），硬塞展开态的 286~328 就在页签栏右边压出一整条；
           *   - `barSideMargin` 与 HDS 内部的宽度分配互相打架，两条栏一起展开时叠在一起；
           *   - `barLayoutMode` 又把两条栏的排布方式改了第二遍。
           * 现在宽度只声明页签栏那一档（见下面 barWidth），迷你栏多宽、怎么让位，
           * 全由 HDS 按形态自己决定。
           */
          barWidth: {
            // 窄屏铺到接近满宽（照华为音乐那种一条长胶囊托住页签的观感）
            smallWidth: this.floatingBarSmallWidthVp(),
            // 中 / 大档按**页签署数**给：284 / 328 是 HDS 对四个页签的档位值
            // （官方文档里的分档只按窗口宽度给，不管页签署数），照那个宽度画就是一条
            // 空落落的宽胶囊，所以按每颗页签 ~72vp 收窄：三个页签 = 216 / 240。
            mediumWidth: 216,
            largeWidth: 240,
          },
          barBottomMargin: this.homeTabBarBottomMarginVp(),
          // 与标题栏、半模态共用同一个材质档位（外观设置里改一处，三处一起变）
          systemMaterialEffect: buildTitleMaterial(this.materialLevel),
          // 迷你栏：折叠态是那颗圆封面，展开态是迷你播放器
          miniBar: {
            miniBarBuilder: () => this.miniBarBuilder(),
            onBarStyleChange: (miniBarStyle: HdsBarStyle) => {
              AppStorage.setOrCreate(K_MINI_EXPANDED, miniBarStyle === HdsBarStyle.EXPAND);
              this.publishLayout();
            },
          },
        })
        .onChange((index: number) => {
          this.activeTab = index;
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
       * 全屏播放器：系统的底部半模态
       *
       * 挂在导航节点而不是最外层 Stack 上，是为了和播放列表那个 bindSheet 分开挂载，
       * 免得同一个组件上叠两个 bindSheet。LARGE = 高度接近整屏、顶部留出一条，
       * 于是下面那层页面（页签 + 迷你栏）保持原样留在上方那条缝里，不会被重建。
       * 没有拖动条与关闭钮：播放器自己的顶栏（下拉箭头 / 页码 / 分享）就是它的头部。
       */
      .bindSheet($$this.playerOpen, this.playerSheet(), {
        preferType: SheetType.BOTTOM,
        detents: [SheetSize.LARGE],
        detentSelection: SheetSize.LARGE,
        dragBar: false,
        showClose: false,
        onWillAppear: () => {
          this.applyStatusBarColor(true);
        },
        onDisappear: () => {
          this.applyStatusBarColor(false);
        },
      })

      // 全屏播放器不在这层：它是压在 HdsNavigation 路由栈上的真实页面（见 destination），
      // 这样系统侧滑返回 / 返回键才有「上一级」可退，而不是把应用退回桌面。

      // 播放列表是系统的半模态：bindSheet 挂在最外层 Stack 上（见文件末尾）

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
