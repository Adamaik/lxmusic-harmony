import { LengthMetrics } from '@kit.ArkUI';
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo, LxSearchOutcome, SEARCH_PLATFORMS, searchMusic, searchMusicAll } from '../core/music/MusicSearch';
import { platformName } from '../core/music/MusicList';
import { PlaySession, songFromSearch } from '../core/player/PlaySession';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT_STRONG, C_ON_ACCENT, C_RED, C_TEXT, C_TEXT_SUB,
  C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB, R_CARD, platformColor, platformTint } from '../ui/Theme';
import { CoverArt, SectionTitle } from '../ui/Widgets';
import { I_IDENTIFY, I_MORE, I_TRASH, IconGlyph } from '../ui/Icons';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { CapsuleSegment } from '../ui/CapsuleSegment';
import { EngineReport, EngineResultGroup, RecognitionResult, RecognitionStatus } from '../core/recognize/RecognitionTypes';
import { AudioRecorder, CaptureCancelledError, CapturePermissionError, CaptureSource } from '../core/recognize/AudioRecorder';
import { RecognitionNetworkError } from '../core/recognize/errors';
import { RecognitionHistory } from '../core/recognize/RecognitionHistory';
import { K_RECOGNIZE_SOURCE, RecognizeSettings, RECOGNIZE_SOURCE_MIC,
  RECOGNIZE_SOURCE_PLAYBACK } from '../core/settings/RecognizeSettings';
import { MultiEngineOutput, recognizeAll } from '../core/recognize/RecognitionEngine';
import { NeteaseRecognizer } from '../core/recognize/NeteaseRecognizer';

const DOMAIN: number = 0x0001;
const TAG: string = 'RecognizeView';

/** 低于这个 RMS 就当没听到声音（环境底噪远在这之下，正常放歌远在这之上） */
const SILENCE_RMS: number = 32 / 32768;
/** 播放时按「歌名 + 歌手」搜几条候选，取第一条 */
const PLAY_SEARCH_LIMIT: number = 10;
/**
 * 采集来源分段选择器的两档
 *
 * 下标即这一档在界面上的位置，也用来在「存档里的来源」与「选中哪一档」之间换算。
 * 默认那档（外界录音）排在左边 —— 抓本机播放的声音是隐私上更重的一档，得用户自己选。
 */
const SOURCE_LABELS: string[] = ['周围声音', '本机播放'];
const SRC_MIC: number = 0;
const SRC_PLAYBACK: number = 1;
/** 来源选择器的宽度：两档各占一半，拉满整卡会成一条又长又扁的带子 */
const SOURCE_SEGMENT_WIDTH: number = 210;

/** 网易云 AFP 指纹页面回调的桥对象（必须用对象字面量，见 SourceSandboxHost 的说明） */
interface AfpBridgeObject {
  onResult: (result: string) => void;
}

/**
 * 听歌识曲页
 *
 * 流程：选采集来源 → 走麦克风时先要权限 → 录 12 秒 → 酷狗 + 网易云两个引擎并发识别 →
 * 归并出主结果，每个引擎的候选各自分组展示，成功识别的歌记进「识别历史」。
 *
 * 采集来源是页面上一个开关（见 core/recognize/AudioRecorder）：
 *   - 周围声音：麦克风录周围的声音，听音箱外放的场合用；
 *   - 本机播放：直接抓本机正在播放的媒体音频，抖音 / 视频号放什么就抓什么，不挑环境。
 * 默认是「周围声音」，用户自己切到「本机播放」才走内录 —— 抓本机播放的声音隐私上更重一档，
 * 不能替用户默认打开；选过的那一档会记住（见 core/settings/RecognizeSettings）。
 *
 * 移植自派音的听歌识曲页，界面按聆听的规范重写：
 *   - 颜色一律走 ui/Theme 的语义 token（深浅模式自动换），不再有自绘的主题色；
 *   - 卡片是「白底圆角 + 上下留白」的常规卡片，宽屏下「结果 / 历史」两组并排；
 *   - 标题栏与返回键交给壳层的 HdsNavDestination（见 pages/Index.ets）。
 */
@Component
export struct RecognizeView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」） */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @State status: RecognitionStatus = RecognitionStatus.Idle;
  @State captureProgress: number = 0;
  @State errorText: string = '';
  @State result: RecognitionResult | undefined = undefined;
  @State groups: EngineResultGroup[] = [];
  @State engineReports: EngineReport[] = [];
  @State history: RecognitionResult[] = [];
  /** 正在解析播放的那一条（防止连点重复起播） */
  @State playingId: string = '';
  /**
   * 窗口宽度（vp）：宽屏下「结果 / 历史」两组并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;
  /** 本机能不能内录；不能就只剩「周围声音」一路，来源选择器也不显示 */
  @State playbackSupported: boolean = false;
  /**
   * 采集来源（识别页上那个开关，取值见 core/settings/RecognizeSettings）
   *
   * 用 @StorageLink 而不是 @State：这一档要记住 —— 默认是外界录音，用户切到「本机播放」
   * 之后下次进来还是它。存法在 RecognizeSettings（沙箱 JSON）。
   */
  @StorageLink(K_RECOGNIZE_SOURCE) recognizeSource: string = RECOGNIZE_SOURCE_MIC;
  private recorder: AudioRecorder = new AudioRecorder();
  private webController: webview.WebviewController = new webview.WebviewController();
  private netease: NeteaseRecognizer = new NeteaseRecognizer(this.webController);
  private afpBridge: AfpBridgeObject = {
    onResult: (result: string): void => {
      this.netease.handleAfpResult(result);
    },
  };
  private pageScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.history = RecognitionHistory.getInstance().list();
    /**
     * 「本机播放」（内录本机声音）这一档**已取消**，所以这里恒为 false：不摆来源选择器，
     * 识曲只走「周围声音」（麦克风）。
     *
     * 取消的原因（2026-10-11 实机排查结论）：按官方口径把内录该走的接口都走通了 —— 先
     * `requestPlaybackCaptureStart` 触发用户授权、回调返回 STATE_SUCCESS，紧接着 `start()`
     * 被判 6800103「状态不支持」，之后**一个字节都收不到**。这是平台没把 AudioCapturer 的
     * 回放采集放给三方应用：native 侧同族接口（PlaybackCaptureMode / StartState /
     * RequestPlaybackCaptureStart）标着「该API暂不对外支持」，ArkTS 侧的
     * SOURCE_TYPE_PLAYBACK_CAPTURE 自 API 12 起就废弃、官方让改用录屏接口 AVScreenCapture。
     * 三方要拿系统音频只能起录屏会话（每次授权 + 系统指示常亮），不适配识曲这个场景。
     *
     * 采集侧的实现（AudioRecorder 的内录分支、RecognizeSettings 的 source 字段）保持原样，
     * 将来平台放开时把这里恢复成 `AudioRecorder.isPlaybackSupported()` 即可。
     */
    this.playbackSupported = false;
  }

  aboutToDisappear(): void {
    // 录音中途离开页面必须停采集：不然麦克风一直占着（系统也会一直提示正在录音）
    this.recorder.stop();
  }

  // ------------------------------------------------------------ 状态

  private isBusy(): boolean {
    return this.status === RecognitionStatus.Capturing ||
      this.status === RecognitionStatus.Recognizing ||
      this.status === RecognitionStatus.RequestingPermission;
  }

  private statusText(): string {
    switch (this.status) {
      case RecognitionStatus.Idle:
        return '就绪，点下面的按钮开始识别';
      case RecognitionStatus.RequestingPermission:
        return '正在请求麦克风权限…';
      case RecognitionStatus.Capturing:
        return '正在聆听…';
      case RecognitionStatus.Recognizing:
        return '正在识别…';
      case RecognitionStatus.Matched:
        return '识别成功';
      case RecognitionStatus.NotMatched:
        return '没有认出来';
      case RecognitionStatus.PermissionDenied:
        return '麦克风权限被拒绝';
      case RecognitionStatus.NoAudio:
        return '没有检测到声音';
      case RecognitionStatus.NetworkError:
        return '网络错误';
      default:
        return '识别出错';
    }
  }

  /** 存档里的来源 → 分段选择器选中的那一档 */
  private sourceIndex(): number {
    return this.recognizeSource === RECOGNIZE_SOURCE_PLAYBACK ? SRC_PLAYBACK : SRC_MIC;
  }

  /**
   * 这次跑的是内录（抓本机正在播放的声音）还是外录（麦克风）
   *
   * 两个条件是「与」：存档里选了「本机播放」，但这台设备压根没有内录能力时，仍然按外录走。
   */
  private isPlayback(): boolean {
    return this.playbackSupported && this.recognizeSource === RECOGNIZE_SOURCE_PLAYBACK;
  }

  private statusDetail(): string {
    if (this.status === RecognitionStatus.Capturing) {
      return `采集进度 ${Math.round(this.captureProgress * 100)}%`;
    }
    if (this.status === RecognitionStatus.PermissionDenied ||
      this.status === RecognitionStatus.NoAudio || this.status === RecognitionStatus.NetworkError ||
      this.status === RecognitionStatus.Error) {
      return this.errorText;
    }
    if (this.status === RecognitionStatus.Idle) {
      return this.isPlayback()
        ? '点「开始识别」后录 12 秒，抓的是本机正在播放的声音（抖音等应用照常放着就行）。'
        : '把手机靠近音源，点「开始识别」后录 12 秒。';
    }
    return '';
  }

  /** providerTrackId 的前缀（kg / wy）—— 决定这条结果来自哪个平台 */
  private sourceOf(item: RecognitionResult): string {
    const at: number = item.providerTrackId.indexOf(':');
    return at > 0 ? item.providerTrackId.substring(0, at) : '';
  }

  // ------------------------------------------------------------ 识别

  private async requestMicPermission(): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'request microphone permission failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private async handleStart(): Promise<void> {
    if (this.isBusy()) {
      return;
    }
    const source: CaptureSource = this.isPlayback() ? CaptureSource.PLAYBACK : CaptureSource.MIC;
    // 只有麦克风那一路要权限：内录抓的是本机自己的音频通路，本应用没有任何可申请的权限
    // （系统侧相关权限全是 system_grant，见 module.json5 的说明），也就别弹无谓的授权框
    if (source === CaptureSource.MIC) {
      this.status = RecognitionStatus.RequestingPermission;
      const granted: boolean = await this.requestMicPermission();
      if (!granted) {
        this.status = RecognitionStatus.PermissionDenied;
        this.errorText = '没有麦克风权限就没法听周围的声音，请在系统设置里允许「聆听」使用麦克风。';
        return;
      }
    }
    this.status = RecognitionStatus.Capturing;
    this.captureProgress = 0;
    this.errorText = '';
    this.engineReports = [];
    this.groups = [];
    let samples: Int16Array;
    try {
      samples = await this.recorder.capture((progress: number): void => {
        this.captureProgress = progress;
      }, source);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '音频采集异常: %{public}s', JSON.stringify(e));
      this.handleError(e);
      return;
    }
    // 先过一道静音检查：对着一屋子底噪跑一次网络识别只会白等往返，还容易被误报成结果
    const rms: number = AudioRecorder.computeRms(samples);
    hilog.info(DOMAIN, TAG, '采集完成 来源=%{public}d 样本数=%{public}d RMS=%{public}f 时长=%{public}fs',
      source, samples.length, rms, samples.length / 16000);
    if (rms < SILENCE_RMS) {
      this.status = RecognitionStatus.NoAudio;
      this.errorText = source === CaptureSource.PLAYBACK
        ? '本机这会儿没有在播放声音。先让抖音等应用把歌放起来，再点「开始识别」；如果是音箱外放，把来源切成「周围声音」。'
        : '录到的几乎都是环境底噪，把手机再靠近音源一些试试。';
      return;
    }
    this.status = RecognitionStatus.Recognizing;
    try {
      const output: MultiEngineOutput = await recognizeAll(samples, this.netease);
      this.engineReports = output.engineReports;
      this.groups = output.groups;
      for (const report of output.engineReports) {
        hilog.info(DOMAIN, TAG, '引擎报告 %{public}s status=%{public}s', report.engine, report.status);
      }
      if (output.match !== undefined) {
        this.result = output.match;
        this.status = RecognitionStatus.Matched;
        hilog.info(DOMAIN, TAG, '识别成功: %{public}s id=%{public}s',
          output.match.title, output.match.providerTrackId);
        this.history = RecognitionHistory.getInstance().add(output.match);
      } else {
        this.result = undefined;
        this.status = RecognitionStatus.NotMatched;
        hilog.warn(DOMAIN, TAG, '两个引擎均未返回可展示结果');
      }
    } catch (e) {
      this.handleError(e);
    }
  }

  private handleError(err: Object): void {
    if (err instanceof CaptureCancelledError) {
      // 用户自己点的「停止」：不是错误，回到待机就好
      this.status = RecognitionStatus.Idle;
      this.errorText = '';
      return;
    }
    if (err instanceof CapturePermissionError) {
      this.status = RecognitionStatus.PermissionDenied;
      this.errorText = err.message;
      return;
    }
    if (err instanceof RecognitionNetworkError) {
      this.status = RecognitionStatus.NetworkError;
      this.errorText = err.message;
      return;
    }
    this.status = RecognitionStatus.Error;
    this.errorText = err instanceof Error ? err.message : String(err);
  }

  private handleStop(): void {
    this.recorder.stop();
    this.status = RecognitionStatus.Idle;
    this.errorText = '';
  }

  // ------------------------------------------------------------ 播放

  /**
   * 播放一条识别结果
   *
   * 识别接口返回的 id 不一定是「能取流的 id」（酷狗那边尤其如此，返回的可能只是数值
   * songid 而不是文件 hash），所以这里不直接拿 id 去解析，而是**按「歌名 + 歌手」
   * 在识别它的那个平台上搜一遍**，取第一条：这条走的是与搜索页完全相同的播放链路，
   * 能播就是能播。该平台搜不到（没版权 / 接口抽风）再跨平台聚合找一遍。
   */
  private async playResult(item: RecognitionResult): Promise<void> {
    if (this.playingId.length > 0) {
      return;
    }
    const keyword: string = `${item.title} ${item.artist}`.trim();
    if (keyword.length === 0) {
      return;
    }
    const source: string = this.sourceOf(item);
    const quality: string = PlaySession.getInstance().quality;
    this.playingId = item.id;
    try {
      if (source === 'kg' || source === 'wy') {
        hilog.info(DOMAIN, TAG, '按识别来源搜索播放 source=%{public}s keyword=%{public}s', source, keyword);
        const list: LxMusicInfo[] = await searchMusic(keyword, source, 1, PLAY_SEARCH_LIMIT);
        if (list.length > 0) {
          await PlaySession.getInstance().setQueueAndPlay([songFromSearch(list[0], quality)], 0);
          return;
        }
      }
      hilog.info(DOMAIN, TAG, '来源内没搜到，改为跨平台聚合搜索 keyword=%{public}s', keyword);
      const outcome: LxSearchOutcome = await searchMusicAll(keyword, SEARCH_PLATFORMS, 1, PLAY_SEARCH_LIMIT);
      if (outcome.items.length > 0) {
        await PlaySession.getInstance().setQueueAndPlay([songFromSearch(outcome.items[0], quality)], 0);
        return;
      }
      this.toast('没有找到可播放的版本');
    } catch (e) {
      hilog.error(DOMAIN, TAG, '播放识别结果失败: %{public}s', JSON.stringify(e));
      this.toast(`播放失败：${(e as Error).message}`);
    } finally {
      this.playingId = '';
    }
  }

  /** 复制「歌名 - 歌手」（复制失败也要让信息看得见，所以失败时把内容弹出来） */
  private copyInfo(item: RecognitionResult): void {
    const text: string = item.artist.length > 0 ? `${item.title} - ${item.artist}` : item.title;
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制');
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'copy recognition info failed: %{public}s', err.message);
        this.toast(text);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'create paste data failed: %{public}s', JSON.stringify(e));
      this.toast(text);
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private wideLayout(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  private reportText(status: string): string {
    if (status === 'matched') {
      return '命中';
    }
    if (status === 'notMatched') {
      return '未匹配';
    }
    return '出错';
  }

  // ------------------------------------------------------------ 构建

  /**
   * 识别结果 / 历史里的一行
   *
   * 参数用可空类型并在里面判一次：调用处（识别结果那张卡）手里的是一个
   * `RecognitionResult | undefined`，传进来再判比在调用处做类型收窄稳。
   */
  @Builder
  resultRow(item: RecognitionResult | undefined, showDelete: boolean) {
    if (item !== undefined) {
      Row({ space: 11 }) {
        CoverArt({
          url: item.coverUrl,
          name: item.title,
          art: item.coverUrl.length === 0,
          boxSize: 52,
        })

        Column({ space: 4 }) {
          Text(item.title)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(item.artist.length > 0 ? item.artist : '未知歌手')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 来源小标签：这条是哪个平台认出来的
        Text(platformName(this.sourceOf(item)))
          .fontSize(11)
          .fontColor(platformColor(this.sourceOf(item)))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(platformTint(this.sourceOf(item)))

        if (showDelete) {
          IconGlyph({ symbol: I_TRASH, iconSize: 19, color: C_TEXT_WEAK })
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .onClick(() => {
              this.history = RecognitionHistory.getInstance().remove(item.id);
            })
            .accessibilityText(`从识别历史里删除 ${item.title}`)
            .accessibilityLevel('yes')
        } else {
          IconGlyph({ symbol: I_MORE, iconSize: 19, color: C_TEXT_WEAK })
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .bindMenu([
              {
                value: '播放',
                action: (): void => {
                  void this.playResult(item);
                },
              },
              {
                value: '复制信息',
                action: (): void => {
                  this.copyInfo(item);
                },
              },
            ])
            .accessibilityText(`${item.title} 的更多操作`)
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .height(74)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        void this.playResult(item);
      })
      // 整行当一个节点：读屏读「歌名，歌手」，而不是把封面、标签、图标逐个念一遍
      .accessibilityGroup(true)
      .accessibilityText(item.artist.length > 0 ? `${item.title}，${item.artist}` : item.title)
      .accessibilityLevel('yes')
    }
  }

  /** 顶部那张卡：状态 + 进度 + 开始 / 停止 */
  @Builder
  actionCard() {
    Column({ space: 10 }) {
      IconGlyph({
        symbol: I_IDENTIFY,
        iconSize: 34,
        color: this.status === RecognitionStatus.Matched ? C_RED : C_TEXT_SUB,
      })
        .accessibilityLevel('no')

      Text(this.statusText())
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)

      if (this.statusDetail().length > 0) {
        Text(this.statusDetail())
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
      }

      if (this.status === RecognitionStatus.Capturing) {
        Progress({ value: Math.round(this.captureProgress * 100), total: 100, type: ProgressType.Linear })
          .width('72%')
          .color(C_RED)
      }

      // 采集来源开关：本机不给内录就只剩「周围声音」一路，那就不摆这个选择器了
      if (this.playbackSupported) {
        Row() {
          CapsuleSegment({
            labels: SOURCE_LABELS,
            selectedIndex: this.sourceIndex(),
            compact: true,
            onSelect: (index: number): void => {
              // 走存档：切完立刻落盘，识别页靠 @StorageLink 跟着变色
              RecognizeSettings.getInstance().setSource(
                index === SRC_PLAYBACK ? RECOGNIZE_SOURCE_PLAYBACK : RECOGNIZE_SOURCE_MIC);
            },
          })
        }
        .width(SOURCE_SEGMENT_WIDTH)
        .accessibilityText('采集来源')
        .accessibilityLevel('yes')
      }

      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Text(this.isBusy() ? '停止' : '开始识别')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isBusy() ? C_TEXT : C_ON_ACCENT)
      }
      .width(168)
      .height(42)
      .backgroundColor(this.isBusy() ? C_FILL_SOFT_STRONG : C_RED)
      .margin({ top: 4 })
      .onClick(() => {
        if (this.isBusy()) {
          this.handleStop();
        } else {
          void this.handleStart();
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 20 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .alignItems(HorizontalAlign.Center)
  }

  /** 引擎结果卡：逐引擎一行，命中就列候选、失败就把原因写出来 */
  @Builder
  enginesCard() {
    Column() {
      Row() {
        SectionTitle({ text: '引擎结果' })
        Blank()
        ForEach(this.engineReports, (report: EngineReport) => {
          Text(`${platformName(report.engine)} ${this.reportText(report.status)}`)
            .fontSize(11)
            .fontColor(C_TEXT_WEAK)
            .padding({ left: 6, right: 2 })
        }, (report: EngineReport) => report.engine)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 6 })

      ForEach(this.groups, (group: EngineResultGroup) => {
        Column() {
          Row({ space: 8 }) {
            Text(platformName(group.engine))
              .fontSize(13.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_TEXT)
            Blank()
            if (group.error.length > 0) {
              Text(group.error)
                .fontSize(11.5)
                .fontColor(C_TEXT_WEAK)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            } else {
              Text(group.results.length > 0 ? `${group.results.length} 条` : '未匹配')
                .fontSize(11.5)
                .fontColor(C_TEXT_WEAK)
            }
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 10, bottom: 2 })

          ForEach(group.results, (item: RecognitionResult) => {
            this.resultRow(item, false)
          }, (item: RecognitionResult) => item.id)
        }
        .width('100%')
      }, (group: EngineResultGroup) => group.engine)

      // 卡底留一点空：最后一行贴着圆角会显得很挤
      Column().height(8).width('100%')
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 识别历史卡 */
  @Builder
  historyCard() {
    Column() {
      Row({ space: 8 }) {
        SectionTitle({ text: '识别历史' })
        Blank()
        if (this.history.length > 0) {
          Text('清空')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .onClick(() => {
              RecognitionHistory.getInstance().clear();
              this.history = [];
            })
            .accessibilityText('清空识别历史')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 6 })

      if (this.history.length === 0) {
        Text('还没有识别过歌。识别成功的歌会留在这里，点一下就能播放。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 22 })
          .textAlign(TextAlign.Start)
      } else {
        ForEach(this.history, (item: RecognitionResult, index: number) => {
          Column() {
            if (index > 0) {
              Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 77 })
            }
            this.resultRow(item, true)
          }
          .width('100%')
        }, (item: RecognitionResult) => item.id)
      }
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  build() {
    Column() {
      Scroll(this.pageScroller) {
        Column({ space: 14 }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 ——
          // 用容器内边距会把这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"
          Column().height(this.topInset + 6).width('100%')

          this.actionCard()

          /**
           * 下半部分：窄屏一列、宽屏两组并排
           *
           * 与缓存设置页同一套排布（见 CacheSettingsView）：每组（小标题 + 卡）包成
           * 一个 Column 当**一个单元**，换行时才不会把卡从标题下面拆开。
           */
          Flex({
            direction: this.wideLayout() ? FlexDirection.Row : FlexDirection.Column,
            wrap: this.wideLayout() ? FlexWrap.Wrap : FlexWrap.NoWrap,
            alignItems: ItemAlign.Start,
            space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
          }) {
            // ------------------------------------------ 识别结果（主结果 + 引擎明细）
            Column({ space: 14 }) {
              if (this.status === RecognitionStatus.Matched && this.result !== undefined) {
                Column() {
                  Row() {
                    SectionTitle({ text: '识别结果' })
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, top: 14, bottom: 4 })

                  this.resultRow(this.result, false)
                }
                .width('100%')
                .borderRadius(R_CARD)
                .backgroundColor(C_CARD)
                .clip(true)
              }

              if (this.groups.length > 0) {
                this.enginesCard()
              }

              if (this.status === RecognitionStatus.NotMatched) {
                Text('两个引擎都没听出来。换一首、或者把手机再靠近音源一些再试一次。')
                  .fontSize(F_SUB)
                  .fontColor(C_TEXT_WEAK)
                  .width('100%')
                  .padding({ left: 4, right: 4 })
              }
            }
            .width(cardWidthOf(this.windowWidth))

            // ------------------------------------------ 识别历史
            Column({ space: 14 }) {
              this.historyCard()
            }
            .width(cardWidthOf(this.windowWidth))
          }
          .width('100%')

          Column().height(this.bottomInset + 16).width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)

      /**
       * 网易云 AFP 指纹 WASM 的隐藏宿主
       *
       * 用 1x1 + opacity(0) 而不是负坐标定位：负坐标会被系统当成「不可见区域」而不去
       * 加载页面，onPageEnd 就永远不触发、markReady 也等不到，网易云那一半引擎会一直
       * 报「指纹引擎未就绪」。
       */
      Web({ src: $rawfile('afp/afp_worker.html'), controller: this.webController })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onlineImageAccess(true)
        .mixedMode(MixedMode.All)
        .javaScriptProxy({
          object: this.afpBridge,
          name: 'afpBridge',
          methodList: ['onResult'],
          controller: this.webController,
        })
        .width(1)
        .height(1)
        .opacity(0)
        .focusable(false)
        .onPageEnd(() => {
          hilog.info(DOMAIN, TAG, 'AFP WebView 加载完成 onPageEnd');
          this.netease.markReady();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
