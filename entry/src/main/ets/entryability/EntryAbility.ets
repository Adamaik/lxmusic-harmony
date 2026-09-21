import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PlaybackService } from '../core/player/PlaybackService';
import { PlaySession } from '../core/player/PlaySession';
import { LocalMusic } from '../core/local/LocalMusic';
import { AudioCache } from '../core/music/AudioCache';
import { MediaCache } from '../core/music/MediaCache';
import { SyncManager } from '../core/sync/SyncManager';
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

    // 洛雪移动端是「内容铺满、状态栏压在内容上」的观感，这里开全屏布局；
    // 具体的安全区留白由页面自己读 AvoidArea 处理（见 pages/Index.ets）。
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: '#000000',
        navigationBarContentColor: '#000000',
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to enable full screen layout. Cause: %{public}s',
        JSON.stringify(err));
    }

    // 深浅模式先固定「跟随系统」：自绘界面的颜色还在 Theme.ets 的常量里，
    // 还没有迁到资源（base / dark 同名 token），所以外观设置里暂时不开放这一项。
    // 等颜色迁完资源，这里改成读外观设置里存的档位即可。
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
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