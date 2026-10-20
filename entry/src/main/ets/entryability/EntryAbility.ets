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
import { SearchHistory } from '../core/music/SearchHistory';
import { initArtistCache } from '../core/music/MusicArtist';
import { applyImageByteCache, applyImageUiCache } from '../core/music/ImageCache';
import { RecognitionHistory } from '../core/recognize/RecognitionHistory';
import { ListenLog } from '../core/history/ListenLog';
import { ListenTracker } from '../core/history/ListenTracker';
import { SyncManager } from '../core/sync/SyncManager';
import { CollectedPlaylists } from '../core/sync/CollectedPlaylists';
import { PlaySettings } from '../core/settings/PlaySettings';
import { AppearanceSettings } from '../core/settings/AppearanceSettings';
import { RecommendSettings } from '../core/settings/RecommendSettings';
import { ListenSettings } from '../core/settings/ListenSettings';
import { RecognizeSettings } from '../core/settings/RecognizeSettings';
import { DownloadSettings } from '../core/download/DownloadSettings';
import { DownloadManager, K_APP_FOREGROUND } from '../core/download/DownloadManager';

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
    // 搜索历史：搜索页第一帧就要显示它（读一次 JSON，很快），也在这里读回来
    SearchHistory.getInstance().init(this.context);
    // 认过的歌手（含头像地址）：歌手列表页一进去就要给每位显示头像，缓存读回来就不用联网认人
    initArtistCache(this.context);
    // 图片（封面 / 头像）的字节与解码缓存：鸿蒙默认不缓存，不开的话每次滚回去都要重下重解码
    applyImageByteCache();
    // 听歌识曲的识别历史：识别页第一帧就要显示它，同样在这里读回来
    RecognitionHistory.getInstance().init(this.context);
    // 回响：收听流水要读回来（回响页第一帧就是它的月度账），记账的那一位也在这里挂上
    // 播放器 —— 越早越好，不然刚进应用听的第一首会漏记
    ListenLog.getInstance().init(this.context);
    ListenTracker.getInstance().init();
    // 播放设置（音质 / 歌词 / 音频焦点）要读回上次的选择，而且必须早于界面创建：
    // 界面用 @StorageLink 订阅它发布的值，晚了第一帧会拿到默认值。
    PlaySettings.getInstance().init(this.context);
    // 外观设置（材质档位 / 封面圆角 / 深浅模式）：同样要早于界面创建，
    // 界面用 @StorageLink 订阅它发布的值。
    AppearanceSettings.getInstance().init(this.context);
    // 推荐设置（首页推荐来源）：要早于界面创建，标题栏的来源胶囊与推荐页
    // 用 @StorageLink 订阅它发布的值，晚了第一帧会回到默认的酷我
    RecommendSettings.getInstance().init(this.context);
    // 听书设置（是否隐藏「听书」页签）：同样要早于界面创建，壳层按它决定导航栏里
    // 摆哪几栏（页签栏的序号由 TabContent 的位置决定，晚了第一帧会闪一下）
    ListenSettings.getInstance().init(this.context);
    // 听歌识曲的采集来源（周围声音 / 本机播放）：识别页的分段选择器用 @StorageLink
    // 订阅它发布的值，晚了第一帧会先画成默认那一档再跳
    RecognizeSettings.getInstance().init(this.context);
    // 下载：设置要先读回来（文件名格式 / 保存位置），管理器的索引也要在界面（我的页）
    // 建出来之前恢复好，否则列表第一帧是空的
    DownloadSettings.getInstance().init(this.context);
    // 应用此刻在前台：自动下载的「后台先别拿保存目录」那条判断要用它（见 DownloadManager）
    AppStorage.setOrCreate(K_APP_FOREGROUND, true);
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
    // 进程要走了：正在听的那一首先把时长结清落盘（与退到后台那一刻同一个道理）
    ListenTracker.getInstance().settle();
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
      // 界面起来了才拿得到 UIContext：把图片的缓存层开上（见 core/music/ImageCache）
      try {
        applyImageUiCache(windowStage.getMainWindowSync().getUIContext());
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'enable image ui cache failed: %{public}s', JSON.stringify(e));
      }
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
    // 回到前台：把在后台时不敢开工的自动下载接着排（保存目录那一步要在前台才拿得到）
    AppStorage.setOrCreate(K_APP_FOREGROUND, true);
    DownloadManager.getInstance().resume();
    // 同步开着但连接断了（被系统挂起 / 网络切换 / 服务端重启）时补一次连接
    void SyncManager.getInstance().ensureConnected();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 后台不再新开自动下载任务（保存目录拿不到，硬写会落到文件管理看不见的目录）
    AppStorage.setOrCreate(K_APP_FOREGROUND, false);
    // 退到后台是「记下停在哪儿」的最好时机：进度只在切歌/退后台时才落盘，
    // 不然每秒写一次文件。force 绕过节流，保证这次一定写上。
    PlaySession.getInstance().persistPlayState(true);
    // 收听流水同理：正在听的这一首到此结一次账（听满 30 秒的留下）。
    // 后台接着放的话，会另开一条继续记 —— 那一段也照样算进回响。
    ListenTracker.getInstance().settle();
  }
}