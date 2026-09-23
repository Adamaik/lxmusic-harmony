import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PlaybackService } from '../core/player/PlaybackService';
import { PlaySession } from '../core/player/PlaySession';
import { LocalMusic } from '../core/local/LocalMusic';
import { WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { WebDavSettings } from '../core/webdav/WebDavSettings';
import { AudioCache } from '../core/music/AudioCache';
import { MediaCache } from '../core/music/MediaCache';
import { SyncManager } from '../core/sync/SyncManager';
import { CollectedPlaylists } from '../core/sync/CollectedPlaylists';
import { PlaySettings } from '../core/settings/PlaySettings';
import { AppearanceSettings } from '../core/settings/AppearanceSettings';
import { DownloadSettings } from '../core/download/DownloadSettings';
import { DownloadManager } from '../core/download/DownloadManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 系统音乐服务（AVSession + 后台播放长时任务）要一个 Ability 的 Context。
    // 这里尽早给它：长时任务必须在应用还处于前台时申请。
    PlaybackService.getInstance().init(this.context);
    // 播放现场的落盘也要沙箱目录：必须在 seed()（Index 里）之前准备好，否则读不到上次的现场
    PlaySession.getInstance().init(this.context);
    // 本地音乐库：要读回导入过的索引（歌单 / 收藏里属于本地歌的那部分也挂在它上面），
    // 必须早于 SyncManager.init —— 音乐库镜像到界面时会读这份侧表
    LocalMusic.getInstance().init(this.context);
    // 云端音乐库（WebDAV）：同样有自己的索引与歌单侧表，也要早于 SyncManager.init
    WebDavLibrary.getInstance().init(this.context);
    // 同步模块也要 Context：读配置、落音乐库、找 gzip 的临时目录，越早准备越好
    SyncManager.getInstance().init(this.context);
    // 缓存：元数据（播放地址 / 歌词）与播放缓存都要沙箱目录，同样尽早初始化
    MediaCache.getInstance().init(this.context);
    AudioCache.getInstance().init(this.context);
    // 播放设置（音质 / 歌词 / 音频焦点）要读回上次的选择，而且必须早于界面创建：
    // 界面用 @StorageLink 订阅它发布的值，晚了第一帧会拿到默认值。
    PlaySettings.getInstance().init(this.context);
    // 外观设置（材质档位 / 首页流光 / 封面圆角）：同样要早于界面创建，
    // 界面用 @StorageLink 订阅它发布的值。
    AppearanceSettings.getInstance().init(this.context);
    // 下载：设置要先读回来（文件名格式 / 保存位置），管理器的索引也要在界面（我的页）
    // 建出来之前恢复好，否则列表第一帧是空的
    DownloadSettings.getInstance().init(this.context);
    DownloadManager.getInstance().init(this.context);
    // WebDAV 连接设置（服务器地址 / 账号密码）：要早于界面创建，
    // 设置页与浏览页用 @StorageLink 订阅它发布的值
    WebDavSettings.getInstance().init(this.context);
    // 收藏歌单（歌单级的收藏，纯本地）：要早于界面创建 —— 「我的」页歌单卡那一段
    // 与歌单详情页那颗「收藏歌单」钮都订阅它发布的版本号
    CollectedPlaylists.getInstance().init(this.context);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    PlaybackService.getInstance().close();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // 深浅模式先定下来（界面颜色已全部迁到资源 token，见 ui/Theme.ets 与
    // resources 下的 base / dark 两份 color.json）：跟随系统，外观设置里选了
    // 「浅色 / 深色」时按存档覆盖。**必须在下面给状态栏定字色之前**，
    // 否则按「覆盖前的模式」算出来的字色会与最终界面不一致。
    try {
      AppearanceSettings.getInstance().applyColorMode(this.context);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // 洛雪移动端是「内容铺满、状态栏压在内容上」的观感，这里开全屏布局；
    // 具体的安全区留白由页面自己读 AvoidArea 处理（见 pages/Index.ets）。
    // 状态栏字色按当前深浅模式给：启动窗口的底色是深色（dark 那份
    // start_window_background = #000000）时，黑字会整条看不见。
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      const dark: boolean = this.isDarkMode();
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000',
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to enable full screen layout. Cause: %{public}s',
        JSON.stringify(err));
    }
  }

  /** 当前是不是深色模式（读资源管理器的配置，UI 还没起来时也能用） */
  private isDarkMode(): boolean {
    try {
      return this.context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    } catch (err) {
      return false;
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 同步开着但连接断了（被系统挂起 / 网络切换 / 服务端重启）时补一次连接
    void SyncManager.getInstance().ensureConnected();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 退到后台是「记下停在哪儿」的最好时机：进度只在切歌/退后台时才落盘，
    // 不然每秒写一次文件。force 绕过节流，保证这次一定写上。
    PlaySession.getInstance().persistPlayState(true);
  }
}