import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { BlurStrategy, HdsBarLayoutMode, HdsBarStyle, HdsNavigation, HdsNavigationTitleBarOptions,
  HdsNavDestination, HdsTabs, HdsTabsBarChangeMode, HdsTabsController, HdsTitleBarContentStyle,
  ScrollEffectType, TitleBarStyleOptions, TitleSize } from '@kit.UIDesignKit';
import { K_CURRENT_ID, K_MINI_EXPANDED, K_QUEUE_COUNT, K_STATUS_TEXT, PlaySession } from '../core/player/PlaySession';
import { SourceEngine } from '../core/source/SourceEngine';
import { SourceInfo, SourceLog } from '../core/source/LxTypes';
import { OnlineRoute } from '../core/music/MusicList';
import { C_BG, C_ICON, C_RED, C_TEXT, F_SUB } from '../ui/Theme';
import { immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { DustLayer } from '../ui/Dust';
import { SourceSandboxHost } from '../components/SourceSandboxHost';
import { SyncManager, K_SYNC_STATUS } from '../core/sync/SyncManager';
import { describeStatus, shouldNotifySyncMessage } from '../core/sync/SyncStatusText';
import { buildTitleMaterial, HDS_BAR_HEIGHT, HDS_TITLE_BAR_HEIGHT } from '../ui/Hds';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { AppearanceSettingsView } from '../views/AppearanceSettingsView';
import { I_GEAR, I_GEAR_FILL, I_HOME, I_HOME_FILL, I_PERSON, I_PERSON_FILL, I_PLAYLIST,
  I_PLAYLIST_FILL } from '../ui/Icons';
import { MiniBarView } from '../views/MiniBar';
import { MineView } from '../views/MineView';
import { OnlineListView } from '../views/OnlineListView';
import { PlayerView } from '../views/PlayerView';
import { PlayQueueContent } from '../views/PlayQueueSheet';
import { PlaylistView } from '../views/PlaylistView';
import { PlaylistDetailView } from '../views/PlaylistDetailView';
import { RecommendView } from '../views/RecommendView';
import { SearchView } from '../views/SearchView';
import { SettingsView } from '../views/SettingsView';
import { SourceSettingsView } from '../views/SourceSettingsView';
import { SyncModeContent } from '../views/SyncModeSheet';
import { SyncSettingsView } from '../views/SyncSettingsView';
import { CacheSettingsView } from '../views/CacheSettingsView';
import { PlaySettingsView } from '../views/PlaySettingsView';
import { DownloadSettingsView } from '../views/DownloadSettingsView';
import { PlaylistSummary } from '../core/player/PlaySession';

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

/** 底部悬浮页签的四个页签 */
interface TabDef {
  icon: Resource;
  iconActive: Resource;
  label: string;
}

const TABS: TabDef[] = [
  { icon: I_HOME, iconActive: I_HOME_FILL, label: '推荐' },
  { icon: I_PLAYLIST, iconActive: I_PLAYLIST_FILL, label: '歌单' },
  { icon: I_PERSON, iconActive: I_PERSON_FILL, label: '我的' },
  { icon: I_GEAR, iconActive: I_GEAR_FILL, label: '设置' },
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
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_STATUS_TEXT) statusText: string = '';
  @StorageLink(K_QUEUE_COUNT) queueCount: number = 0;
  /** HDS 的页签控制器：悬浮页签 + 迷你栏都由它统管 */
  private tabsController: HdsTabsController = new HdsTabsController();
  /** 材质档位（外观设置）：标题栏 / 底部页签栏 / 半模态共用，改一处三处一起变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
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
  private logListener: ((log: SourceLog) => void) | null = null;
  /** 播放会话的提示（缺音源 / 解析失败 / 播放错误），统一走 HDS 提示条 */
  private noticeListener: ((text: string) => void) | null = null;
  private toastTimer: number = 0;

  aboutToAppear(): void {
    PlaySession.getInstance().seed();

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
  }

  // ------------------------------------------------------------ 窗口 / 安全区

  private async setupWindow(): Promise<void> {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      this.mainWindow = await window.getLastWindow(context);
      this.applyStatusBarColor(false);
      this.readAvoidArea();
      // 全屏布局刚生效时系统可能还没回填避让区，稍后再读一次并监听后续变化
      setTimeout(() => {
        this.readAvoidArea();
      }, 500);
      this.mainWindow.on('avoidAreaChange', () => {
        this.readAvoidArea();
      });
    } catch (e) {
      this.topInset = 38;
      this.bottomInset = 14;
    }
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

  /** 播放页是深色，状态栏文字要跟着翻成白色 */
  private applyStatusBarColor(dark: boolean): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.setWindowSystemBarProperties({
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
      });
    } catch (e) {
      // 忽略：部分设备不支持单独改内容色
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
   * 页签样式
   *
   * 悬浮样式下页签只支持 BottomTabBarStyle 或自定义构建器，这里用官方的
   * BottomTabBarStyle：图形仍是官方 sys.symbol 符号图标，选中态用实心变体 + 主题红，
   * 文字颜色走 labelStyle。
   */
  private tabBarStyle(index: number): BottomTabBarStyle {
    const def: TabDef = TABS[index];
    const symbol: TabBarSymbol = {
      normal: new SymbolGlyphModifier(def.icon).fontColor([C_ICON]).fontSize(23),
      selected: new SymbolGlyphModifier(def.iconActive).fontColor([C_RED]).fontSize(23),
    };
    return new BottomTabBarStyle(symbol, def.label)
      .labelStyle({ selectedColor: C_RED, unselectedColor: '#4A4A4C' });
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
      onOpenPlayer: () => {
        this.openPlayer();
      },
      onOpenQueue: () => {
        this.openQueue();
      },
    })
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
      // 首次安装时界面上铺的演示歌单不属于音乐库，没有可打开的列表
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
      this.showToast('洛雪音乐 HarmonyOS 复刻版 · 界面演示');
      return;
    }
    if (action === 'appearance') {
      this.go(PAGE_APPEARANCE);
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
    const contentStyle: HdsTitleBarContentStyle = {
      titleStyle: { mainTitleColor: $r('sys.color.font_primary') },
      menuStyle: { iconColor: $r('sys.color.font_primary') },
    };
    const style: TitleBarStyleOptions = {
      blurStrategy: BlurStrategy.ENABLE,
      systemMaterialEffect: buildTitleMaterial(this.materialLevel),
      originalStyle: { contentStyle: contentStyle },
    };
    if (scroller !== undefined) {
      style.scrollEffectOpts = { scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR };
      style.scrollEffectStyle = {
        backgroundStyle: { blurRadius: 40 },
        contentStyle: contentStyle,
      };
    }
    const options: HdsNavigationTitleBarOptions = {
      avoidLayoutSafeArea: true,
      style: style,
    };
    if (title.length > 0) {
      options.content = { title: { mainTitle: title, mainTitleSize: TitleSize.TITLE_ML } };
    }
    return options;
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
        Column() {
          SearchView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('搜索'))
    } else if (name === PAGE_SOURCE) {
      HdsNavDestination() {
        Column() {
          SourceSettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('音源设置'))
      .onHidden(() => {
        this.refreshSourceSummary();
      })
    } else if (name === PAGE_SYNC) {
      HdsNavDestination() {
        Column() {
          SyncSettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('同步设置'))
    } else if (name === PAGE_CACHE) {
      HdsNavDestination() {
        Column() {
          CacheSettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('缓存'))
    } else if (name === PAGE_PLAY) {
      HdsNavDestination() {
        Column() {
          PlaySettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('播放设置'))
    } else if (name === PAGE_DOWNLOAD) {
      HdsNavDestination() {
        Column() {
          DownloadSettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('下载设置'))
    } else if (name === PAGE_APPEARANCE) {
      HdsNavDestination() {
        Column() {
          AppearanceSettingsView({ bottomInset: this.bottomInset })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      .titleBar(this.titleBarOptions('外观'))
    } else if (name === PAGE_ONLINE) {
      HdsNavDestination() {
        Column() {
          OnlineListView({
            kind: this.routeOnlineKind,
            source: this.routeOnlineSource,
            listId: this.routeOnlineId,
            listName: this.routeOnlineName,
            listCover: this.routeOnlineCover,
            bottomInset: this.bottomInset,
            scroller: this.onlineScroller,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      // 顶栏不给标题：歌单名在封面下方已经有了，导航栏再重复一遍就是同一行字出现两次。
      // 这一页的封面会滚到标题栏底下，所以绑上滚动容器开渐变模糊：
      // 开始时返回键浮在封面上（底色透明），滚起来标题栏才变成磨砂。
      .titleBar(this.titleBarOptions('', this.onlineScroller))
      .bindToScrollable([this.onlineScroller])
    } else if (name === PAGE_PLAYLIST) {
      HdsNavDestination() {
        Column() {
          PlaylistDetailView({
            playlistId: this.routePlaylistId,
            playlistName: this.routePlaylistName,
            bottomInset: this.bottomInset,
            scroller: this.playlistScroller,
            onOpenPlayer: () => {
              this.openPlayer();
            },
            onOpenQueue: () => {
              this.openQueue();
            },
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: HDS_TITLE_BAR_HEIGHT + this.topInset })
      }
      // 同上：本地歌单的名字写在封面右边，顶栏不再重复；封面滚上去时标题栏才起磨砂
      .titleBar(this.titleBarOptions('', this.playlistScroller))
      .bindToScrollable([this.playlistScroller])
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ---------------------------------------------------- HDS 导航（主页签 + 子页面）
      HdsNavigation(this.pathStack) {
        HdsTabs({ index: this.activeTab, controller: this.tabsController, barPosition: BarPosition.End }) {
          TabContent() {
            RecommendView({
              topInset: this.topInset,
              bottomInset: this.bottomInset + 96,
              onOpenSearch: () => {
                this.go(PAGE_SEARCH);
              },
              onOpenOnline: (route: OnlineRoute) => {
                this.openOnline(route);
              },
            })
          }
          .tabBar(this.tabBarStyle(0))

          TabContent() {
            PlaylistView({
              topInset: this.topInset,
              bottomInset: this.bottomInset + 96,
              onOpenPlaylist: (playlist: PlaylistSummary) => {
                this.openPlaylist(playlist);
              },
            })
          }
          .tabBar(this.tabBarStyle(1))

          TabContent() {
            MineView({
              topInset: this.topInset,
              bottomInset: this.bottomInset + 96,
            })
          }
          .tabBar(this.tabBarStyle(2))

          TabContent() {
            SettingsView({
              topInset: this.topInset,
              bottomInset: this.bottomInset + 96,
              sourceSummary: this.sourceSummary,
              onNavigate: (action: string) => {
                this.onSettingAction(action);
              },
            })
          }
          .tabBar(this.tabBarStyle(3))
        }
        // 悬浮页签栏的三个前提：贴底、横向、页签悬浮在内容之上
        .barPosition(BarPosition.End)
        .vertical(false)
        .barOverlap(true)
        // 高度写死成与自绘迷你栏同一个常量：两边必须一样高，观感才统一
        .barHeight(HDS_BAR_HEIGHT)
        .barFloatingStyle({
          // 页签栏和迷你栏是「分别贴左右两边」摆的，两者之间的空隙就是剩余的宽度，
          // 所以页签栏要给足宽度（手机 ≈ 屏宽 - 两侧边距 - 迷你栏 - 一点缝），
          // 否则中间会空出一大块。
          barWidth: { smallWidth: 280, mediumWidth: 340, largeWidth: 440 },
          barSideMargin: 12,
          barBottomMargin: this.bottomInset + 10,
          // 内容从页签栏底下淡出，官方推荐的悬浮页签观感
          gradientMask: { maskColor: '#66F1F1F2', maskHeight: 104 },
          // 与标题栏、半模态共用同一个材质档位（外观设置里改一处，三处一起变）
          systemMaterialEffect: buildTitleMaterial(this.materialLevel),
          // 迷你栏：折叠态就是右边那颗唱片圆钮，展开态是迷你播放器
          miniBar: {
            miniBarBuilder: () => this.miniBarBuilder(),
            miniBarWidth: { smallWidth: 286, mediumWidth: 300, largeWidth: 328 },
            miniBarStyle: HdsBarStyle.COLLAPSE,
            enableMiniBarBackground: true,
            enableMiniBarClip: true,
            barLayoutMode: HdsBarLayoutMode.HORIZONTAL,
            onBarStyleChange: (miniBarStyle: HdsBarStyle, tabBarStyle: HdsBarStyle, miniBarWidth: number,
              tabBarWidth: number, mode: HdsTabsBarChangeMode) => {
              AppStorage.setOrCreate(K_MINI_EXPANDED, miniBarStyle === HdsBarStyle.EXPAND);
            },
          },
        })
        .onChange((index: number) => {
          this.activeTab = index;
        })
        .width('100%')
        .height('100%')
      }
      .hideTitleBar(true)
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
        // 不透明底色会把毛玻璃的模糊盖掉（玻璃感就没了）。厚度跟外观设置的档位走。
        .attributeModifier(thinGlass(18, false, 'rgba(255, 255, 255, 0.82)', this.materialLevel))
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
          systemMaterial: buildTitleMaterial(this.materialLevel),
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
      blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      // 与标题栏、底部页签栏同一档材质（blurStyle 是材质不可用时的兜底）
      systemMaterial: buildTitleMaterial(this.materialLevel),
      title: { title: '播放列表', subtitle: `共 ${this.queueCount} 首` },
    })
  }
}
