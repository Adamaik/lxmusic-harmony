import { PlaySession, SongItem } from '../core/player/PlaySession';
import { K_BUFFERED_SECONDS, K_BUFFERING, K_CURRENT_ART, K_CURRENT_COVER, K_CURRENT_ID, K_CURRENT_NAME,
  K_CURRENT_QUALITY, K_CURRENT_SINGER, K_DURATION, K_LYRIC_LINES, K_LYRIC_STATUS, K_PLAYER_STATUS,
  K_PLAY_MODE, K_PROGRESS } from '../core/player/PlaySession';
import { LyricLine, activeLyricIndex } from '../core/music/Lyric';
import { K_LYRIC_BLUR, K_LYRIC_CENTERED, K_LYRIC_FONT_SIZE, K_LYRIC_KEEP_SCREEN,
  K_SHOW_MINI_LYRIC } from '../core/settings/PlaySettings';
import { I_CAST, I_CHECK_CIRCLE, I_CHEVRON_DOWN, I_COMMENT, I_DOWNLOAD, I_MORE_CIRCLE, I_NEXT, I_ORDER_PLAY,
  I_PAUSE, I_PLAY, I_PREV, I_QUEUE, I_REPEAT, I_REPEAT_ONE, I_SHARE, I_SHUFFLE, IconGlyph } from '../ui/Icons';
import { CoverArt, FavoriteHeart } from '../ui/Widgets';
import { AVCastPicker, AVCastPickerStyle } from '@kit.AVSessionKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong, LocalMusic } from '../core/local/LocalMusic';
import { isWebDavSong, WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { LxMusicInfo } from '../core/music/MusicSearch';
import { C_BG, C_RED } from '../ui/Theme';
import { HdsEdgeFlowLight } from '../ui/Hds';
import { COVER_RADIUS_DEFAULT, K_COVER_RADIUS } from '../core/settings/AppearanceSettings';
import { LyricMatchSheet } from './LyricMatchSheet';
import { CommentSheet } from './CommentSheet';
import { LOCAL_QUALITY_MARK, isFileQuality, qualityLabel, switchableQualitys } from '../core/music/Quality';

function formatTime(seconds: number): string {
  const total: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
}

/** 值 / 总长 -> 百分比（0~100），总长还不知道（0）时给 0 */
function percentOf(value: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  const percent: number = (value / total) * 100;
  if (percent < 0) {
    return 0;
  }
  return percent > 100 ? 100 : percent;
}

/** 进度条几何：自绘的缓冲条要让出半个滑块，才能和 Slider 的轨道对齐 */
const TRACK_THICKNESS: number = 3;
const BLOCK_SIZE: number = 9;
const TRACK_INSET: number = BLOCK_SIZE / 2;
/** 进度条宽度变化的过渡时长：缓冲是分块长出来的，加个短过渡看着才像连续走 */
const TRACK_ANIM_MS: number = 260;

/**
 * 全屏播放器
 *
 * 洛雪的播放页是一张「封面 / 歌词」双页可横滑的深色页：背景是当前封面的高斯模糊，
 * 顶部只有下拉箭头、页码指示和分享；底部是进度条 + 播放控制 + 一排功能入口。
 */
@Component
export struct PlayerView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onClose: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  /**
   * 「歌词页不熄屏」要动的是窗口，窗口在 pages/Index.ets 手里，
   * 所以这里只报「该不该常亮」，由页面去开/关。
   */
  onKeepScreenOn: (on: boolean) => void = () => {
  };

  @StorageLink(K_SHOW_MINI_LYRIC) showMiniLyric: boolean = false;
  @StorageLink(K_LYRIC_BLUR) lyricBlur: boolean = true;
  @StorageLink(K_LYRIC_CENTERED) lyricCentered: boolean = true;
  @StorageLink(K_LYRIC_FONT_SIZE) lyricFontSize: number = 19;
  @StorageLink(K_LYRIC_KEEP_SCREEN) @Watch('syncKeepScreenOn') lyricKeepScreen: boolean = true;
  /** 当前这首歌的条目 id：传给收藏爱心（换歌时爱心跟着换状态），也在换歌时收起评论页 */
  @StorageLink(K_CURRENT_ID) @Watch('onCurrentIdChanged') currentId: string = '';
  @StorageLink(K_CURRENT_NAME) name: string = '';
  @StorageLink(K_CURRENT_SINGER) singer: string = '';
  @StorageLink(K_CURRENT_COVER) cover: string = '';
  @StorageLink(K_CURRENT_ART) art: boolean = false;
  @StorageLink(K_CURRENT_QUALITY) quality: string = '128k';
  @StorageLink(K_PLAYER_STATUS) @Watch('onStatusChanged') status: string = 'idle';
  /** 播放页封面圆角（外观设置里可调，默认 12） */
  @StorageLink(K_COVER_RADIUS) coverRadius: number = COVER_RADIUS_DEFAULT;
  /** 弱网下播放器在等数据：状态仍是 playing，但播放钮要显示成转圈 */
  @StorageLink(K_BUFFERING) buffering: boolean = false;
  /** 已缓冲到哪个位置（秒）：进度条上比已播更长的那一段（见 bufferTrack） */
  @StorageLink(K_BUFFERED_SECONDS) buffered: number = 0;
  @StorageLink(K_PROGRESS) @Watch('onProgressChanged') progress: number = 0;
  @StorageLink(K_DURATION) duration: number = 0;
  @StorageLink(K_LYRIC_LINES) @Watch('onLyricChanged') lyricLines: LyricLine[] = [];
  @StorageLink(K_LYRIC_STATUS) lyricStatus: string = 'none';
  @StorageLink(K_PLAY_MODE) playMode: string = 'list';
  @State pageIndex: number = 0;
  /** 右下角「更多」的底部面板是否展开 */
  @State moreOpen: boolean = false;
  /** 「匹配歌词」面板是否展开（本地歌专用） */
  @State matchOpen: boolean = false;
  /** 音质面板是否展开（进度条下面那颗音质钮点出来的） */
  @State qualityOpen: boolean = false;
  /** 评论页是否展开（铺满播放器的自绘覆盖物，见 CommentSheet 开头的说明） */
  @State commentOpen: boolean = false;
  /** 当前唱到的歌词行；-1 = 没有时间轴/还没开始 */
  @State activeLine: number = -1;
  /**
   * 封面的弹簧缩放（播放 1.05 / 暂停 0.95）
   *
   * 系统没有「带过冲的弹簧」这个曲线（Curve 里最接近的也是单向缓动），
   * 所以这里按 16ms 一帧做数值积分：阻尼弹簧，约 12% 过冲、0.5 秒收住。
   * 播放/暂停时封面「弹」一下，是这类播放器最容易被记住的一处细节。
   */
  @State coverSpringScale: number = 1;
  private controller: SwiperController = new SwiperController();
  private lyricScroller: Scroller = new Scroller();
  /** 弹簧的目标值与速度（速度不参与渲染，不需要 @State） */
  private coverSpringTarget: number = 1;
  private coverSpringVelocity: number = 0;
  private coverSpringTimer: number = 0;
  private coverSpringLastMs: number = 0;

  aboutToAppear(): void {
    // 打开播放器时可能已经唱到一半了，先把当前行对上，别等下一秒 timeUpdate
    this.activeLine = activeLyricIndex(this.lyricLines, this.progress);
    this.syncKeepScreenOn();
    // 进来时正在播就直接是放大的样子，不要从 1 弹一下（那是给「切播放状态」用的）
    this.coverSpringTarget = this.playing() ? 1.05 : 0.95;
    this.coverSpringScale = this.coverSpringTarget;
  }

  aboutToDisappear(): void {
    // 播放器收起就把常亮还回去，别让这个窗口一直钉在亮屏上
    this.onKeepScreenOn(false);
    this.stopCoverSpring();
  }

  /** 播放状态变了：让封面弹到对应的目标尺寸（弹簧过程由 startCoverSpring 推进） */
  onStatusChanged(): void {
    this.coverSpringTarget = this.playing() ? 1.05 : 0.95;
    this.startCoverSpring();
  }

  /**
   * 推进封面的阻尼弹簧（stiffness 220 / damping 13）
   *
   * 每 16ms 积一帧：加速度 = 位移差 * 刚度 - 速度 * 阻尼；位移与速度都足够小
   * （肉眼看不出、也快过一帧的像素）时直接吸附到目标值并停表，避免定时器常驻。
   */
  private startCoverSpring(): void {
    if (this.coverSpringTimer !== 0) {
      return;
    }
    this.coverSpringLastMs = Date.now();
    this.coverSpringTimer = setInterval(() => {
      const now: number = Date.now();
      // 卡顿掉帧时限制单帧步长，否则数值积分会发散（画面直接跳飞）
      const dt: number = Math.min(32, now - this.coverSpringLastMs) / 1000;
      this.coverSpringLastMs = now;
      const acc: number = (this.coverSpringTarget - this.coverSpringScale) * 220 - this.coverSpringVelocity * 13;
      this.coverSpringVelocity += acc * dt;
      this.coverSpringScale += this.coverSpringVelocity * dt;
      if (Math.abs(this.coverSpringTarget - this.coverSpringScale) < 0.0005
        && Math.abs(this.coverSpringVelocity) < 0.0005) {
        this.coverSpringScale = this.coverSpringTarget;
        this.coverSpringVelocity = 0;
        this.stopCoverSpring();
      }
    }, 16);
  }

  private stopCoverSpring(): void {
    if (this.coverSpringTimer !== 0) {
      clearInterval(this.coverSpringTimer);
      this.coverSpringTimer = 0;
    }
  }

  /**
   * 歌词页不熄屏
   *
   * 只有「全屏播放器停在歌词页」时才要求常亮：翻回封面页、关掉设置、
   * 播放器收起，三种情况都要还原，所以每次页码/设置变化都重算一遍。
   */
  private syncKeepScreenOn(): void {
    this.onKeepScreenOn(this.lyricKeepScreen && this.pageIndex === 1);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 点收藏：走会话的收藏接口（收藏是参与同步的数据，会即时上行到服务端）。
   *
   * 爱心自己的状态由 FavoriteHeart 读 AppStorage 里的收藏名单决定，这里不用回写：
   * 收藏一变，页面上所有爱心（含这一颗）自己就重绘了。
   */
  private toggleLiked(): void {
    const session = PlaySession.getInstance();
    const item: SongItem | null = session.current;
    if (item === null) {
      return;
    }
    if (session.isFavorite(item.id)) {
      if (session.removeFavorite(item.id)) {
        this.toast(`已取消收藏「${item.name}」`);
      }
    } else if (session.addFavorite(item)) {
      this.toast(`已收藏「${item.name}」`);
    }
  }

  /**
   * 分享（右上角）
   *
   * 走系统的分享面板（ShareKit 的 systemShare），内容按「歌名-歌手-解析出来的播放链接」拼。
   * 链接优先用正在播的那一条；解析不出来（音源失效等）就只分享歌名与歌手，并提示一声。
   * 平台给的播放地址大多带时效，分享出去的链接过一阵会失效，这是平台侧规则。
   */
  private async share(): Promise<void> {
    const name: string = this.name;
    if (name.length === 0) {
      this.toast('还没有正在播放的歌');
      return;
    }
    this.toast('正在解析分享链接…');
    const url: string = await PlaySession.getInstance().currentMusicUrl();
    const title: string = this.singer.length > 0 ? `${name}-${this.singer}` : name;
    if (url.length === 0) {
      this.toast('这首歌没解析出链接（音源可能已失效），只分享歌名');
    }
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.PLAIN_TEXT,
      content: url.length > 0 ? `${title}-${url}` : title,
      title: title,
    };
    try {
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      };
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await new systemShare.ShareController(data).show(context, options);
    } catch (err) {
      this.toast(`分享失败：${(err as BusinessError).message}`);
    }
  }

  /** 当前这首是不是本地音乐（决定要不要给「匹配歌词」入口） */
  private isCurrentLocal(): boolean {
    return LocalMusic.getInstance().hasId(this.currentId);
  }

  /** 当前这首是不是云端（WebDAV）音乐：匹配歌词的入口对它与本地歌一样需要 */
  private isCurrentWebDav(): boolean {
    return WebDavLibrary.getInstance().hasId(this.currentId);
  }

  /** 本地歌 / 云端歌的时长（毫秒，0 = 未知）：给匹配结果排序用 */
  private currentLocalDurationMs(): number {
    if (this.isCurrentWebDav()) {
      const lib = WebDavLibrary.getInstance();
      return lib.durationMsOf(lib.keyOfId(this.currentId));
    }
    const music = LocalMusic.getInstance();
    return music.durationMsOf(music.keyOfId(this.currentId));
  }

  /**
   * 用户在手动的匹配面板里选中了一条：记住它并重新取词
   *
   * 本地歌与云端歌的匹配结果各存各的库（都是非同步侧表那一套），按当前这首的来源选。
   */
  private applyLyricMatch(info: LxMusicInfo, source: string): void {
    const key: string = this.matchOwnerKey();
    if (key.length === 0) {
      this.matchOpen = false;
      return;
    }
    if (this.isCurrentWebDav()) {
      WebDavLibrary.getInstance().saveMatch(key, source, JSON.stringify(info));
    } else {
      LocalMusic.getInstance().saveMatch(key, source, JSON.stringify(info));
    }
    this.matchOpen = false;
    this.toast(`已匹配到「${info.name} - ${info.singer}」，正在取词`);
    PlaySession.getInstance().refreshLyric();
  }

  /** 当前这首在它所属库里的 key（本地 / 云端；都不是则空串） */
  private matchOwnerKey(): string {
    if (this.isCurrentWebDav()) {
      return WebDavLibrary.getInstance().keyOfId(this.currentId);
    }
    return LocalMusic.getInstance().keyOfId(this.currentId);
  }

  /**
   * 换歌了就把评论页收起来
   *
   * 洛雪遇到切歌只提示一句「这已经是「X」的评论啦」，等用户自己点刷新；
   * 这里直接收起：那一层铺满整个播放器，显示的又永远是「当前这首」的评论，
   * 换歌后留着容易让人以为是新歌的评论。下次点开自然就是新歌的。
   */
  onCurrentIdChanged(): void {
    this.commentOpen = false;
  }

  /**
   * 取当前这首歌的「平台身份」（评论要它，评论只存在于音乐平台上）
   *
   * 三种来源都由 `PlaySession.platformIdentityOf` 统一解析：在线歌用它自己的 musicInfo；
   * 本地歌 / 云端歌用它匹配到的那一首 —— 与取歌词同一条匹配结果，必要时**按需补一次匹配**
   * （本地歌带 .lrc 时取词不会去匹配，但评论仍然需要平台身份）。
   */
  private async resolveCommentTarget(): Promise<string> {
    const item: SongItem | null = PlaySession.getInstance().current;
    if (item === null) {
      return '';
    }
    const info: LxMusicInfo | null = await PlaySession.getInstance().platformIdentityOf(item);
    return info !== null ? JSON.stringify(info) : '';
  }

  /** 下载当前这首歌（设置里的文件名格式 / 保存位置都生效） */
  private downloadCurrent(): void {
    const session = PlaySession.getInstance();
    const item: SongItem | null = session.current;
    if (item === null) {
      this.toast('还没有正在播放的歌');
      return;
    }
    // 本地歌已经在本机了、云端歌由播放缓存的边听边下负责，没什么可下的
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    if (isWebDavSong(item)) {
      this.toast(`「${item.name}」是云端音乐，播放时会自动缓存`);
      return;
    }
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

  /** 「更多」面板里的「播放」：这首歌从头再放一遍 */
  private replayCurrent(): void {
    const index: number = PlaySession.getInstance().currentIndex;
    if (index >= 0) {
      void PlaySession.getInstance().playAt(index);
    }
  }

  /** 「更多」面板里的加入播放列表；asNext = 插到当前播放的下一首 */
  private addCurrentToQueue(asNext: boolean): void {
    const session = PlaySession.getInstance();
    const item: SongItem | null = session.current;
    if (item === null) {
      return;
    }
    const hasCurrent: boolean = session.currentIndex >= 0;
    session.addToQueue(item, asNext);
    this.toast(asNext
      ? (hasCurrent ? `已设为下一首播放：${item.name}` : `播放列表是空的，已加入：${item.name}`)
      : `已加入播放列表：${item.name}`);
  }

  /** 投播按钮的外观（系统只负责交互与设备面板，图标自己画） */
  @Builder
  castPickerBuilder() {
    IconGlyph({ symbol: I_CAST, iconSize: 23, color: '#8CFFFFFF' })
  }

  // ------------------------------------------------------------ 右下角「更多」面板

  /** 面板里的一项（标签是常量、动作由外部给，用 @Builder 不会踩「按值传递不刷新」的坑） */
  @Builder
  moreItem(label: string, onTap: () => void) {
    Text(label)
      .fontSize(16)
      .fontColor('#F2FFFFFF')
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(54)
      .onClick(() => {
        this.moreOpen = false;
        onTap();
      })
  }

  /**
   * 底部菜单面板
   *
   * 内容与歌单 / 在线列表行尾那个「更多」菜单一致：播放 / 添加到播放列表 /
   * 添加到下一个播放，外加一条「取消」。收藏不在这里 —— 歌曲名右边就是爱心，
   * 列表行上也是爱心，收藏不再藏在「更多」里面。
   *
   * 播放器自己就是系统的半模态，再往它上面叠一个 bindSheet 容易和系统弹窗打架，
   * 所以这里自绘一层：遮罩 + 深色圆角面板 + 上滑动效，观感与系统底部弹窗一致。
   */
  @Builder
  morePanel() {
    Column() {
      Text(this.name)
        .fontSize(13)
        .fontColor('#8CFFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 16, bottom: 10 })

      this.moreItem('播放', () => {
        this.replayCurrent();
      })
      this.moreItem('添加到播放列表', () => {
        this.addCurrentToQueue(false);
      })
      this.moreItem('添加到下一个播放', () => {
        this.addCurrentToQueue(true);
      })
      // 洛雪的评论入口就在播放页的「更多」底部菜单里（Vertical/Player 的 MoreBtn），
      // 底部那排图标上的评论钮是同一条路的快捷入口
      this.moreItem('查看评论', () => {
        this.commentOpen = true;
      })

      // 本地歌 / 云端歌才有：自动匹配没把握（或没匹配上）时，让用户自己搜一次、选正确的那条
      if (this.isCurrentLocal() || this.isCurrentWebDav()) {
        this.moreItem('匹配歌词', () => {
          this.moreOpen = false;
          this.matchOpen = true;
        })
      }

      Divider()
        .strokeWidth(0.5)
        .color('#26FFFFFF')
        .margin({ top: 8 })

      Text('取消')
        .fontSize(16)
        .fontColor('#8CFFFFFF')
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(54)
        .onClick(() => {
          this.moreOpen = false;
        })
    }
    .width('100%')
    .padding({ bottom: this.bottomInset + 4 })
    .borderRadius({ topLeft: 20, topRight: 20 })
    .backgroundColor('#232326')
    .transition(TransitionEffect.translate({ y: 320 }).animation({ duration: 240, curve: Curve.Friction }))
  }

  @Builder
  moreOverlay() {
    Column() {
      // 点面板以外的区域收起
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.moreOpen = false;
        })
      this.morePanel()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#8A000000')
  }

  // ------------------------------------------------------------ 音质

  /**
   * 这首歌现在能切到哪几档（空数组 = 没得切，见 Quality.switchableQualitys）
   *
   * 读「正在播的那一首」而不是界面上的字段：音质档列表来自歌曲条目里的 musicInfo。
   */
  private qualityOptions(): string[] {
    const item: SongItem | null = PlaySession.getInstance().current;
    if (item === null) {
      return [];
    }
    return switchableQualitys(item.musicInfoJson, item.source, this.quality);
  }

  /** 面板顶上那行「当前：xxx」 */
  private currentQualityText(): string {
    return `当前：${qualityLabel(this.quality)}`;
  }

  /**
   * 没得切时的那句说明
   *
   * 三种情况各说各的：本地文件、云端文件（音质由文件本身决定），
   * 以及在线歌但只有一档 / 连音质列表都没给。
   */
  private noChoiceHint(): string {
    if (PlaySession.getInstance().current === null) {
      return '还没有正在播放的歌。';
    }
    if (isFileQuality(this.quality)) {
      // isFileQuality 为真时只可能是「本地」或「云端」两个标记之一，所以拿其中一个当判断
      return this.quality === LOCAL_QUALITY_MARK
        ? '这是本机上的音频文件，音质由文件本身决定，没法切换。'
        : '这是云端服务器上的音频文件，音质由文件本身决定，没法切换。';
    }
    const options: string[] = this.qualityOptions();
    if (options.length === 1) {
      return `这首歌只有 ${qualityLabel(options[0])} 一档可选。`;
    }
    return '这首歌没有可切换的音质档（音源可能没给出这首歌的音质列表）。';
  }

  /** 面板里点某一档：收起面板，交给播放会话换档重放 */
  private pickQuality(quality: string): void {
    this.qualityOpen = false;
    void PlaySession.getInstance().switchQuality(quality);
  }

  /**
   * 音质钮（进度条下面那一行中间那颗胶囊）
   *
   * 原来它只是一段文字（当前音质），现在是个钮：点开音质面板换档。
   * 可切的档超过一档才挂右边那枚小箭头 —— 本地 / 云端文件没有档可切，
   * 标着箭头却点不出东西更让人困惑；点它仍然会开面板，那里给一句说明。
   */
  @Builder
  qualityButton() {
    Row({ space: 3 }) {
      Text(qualityLabel(this.quality))
        .fontSize(11.5)
        .fontColor('#CCFFFFFF')
      if (this.qualityOptions().length > 1) {
        IconGlyph({ symbol: I_CHEVRON_DOWN, iconSize: 12, color: '#CCFFFFFF' })
      }
    }
    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
    .borderRadius(10)
    .backgroundColor('#26FFFFFF')
    .onClick(() => {
      this.qualityOpen = true;
    })
    .accessibilityText(`音质：${qualityLabel(this.quality)}，点按切换`)
    .accessibilityLevel('yes')
  }

  /** 音质面板里的一项：正在用的那一档标主题红并带一枚勾（尺寸与「更多」那几项一致） */
  @Builder
  qualityItem(quality: string) {
    Row({ space: 6 }) {
      Text(qualityLabel(quality))
        .fontSize(16)
        .fontColor(this.quality === quality ? C_RED : '#F2FFFFFF')
      if (this.quality === quality) {
        IconGlyph({ symbol: I_CHECK_CIRCLE, iconSize: 15, color: C_RED })
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.pickQuality(quality);
    })
    .accessibilityText(this.quality === quality
      ? `${qualityLabel(quality)}，当前音质`
      : `切换到 ${qualityLabel(quality)}`)
    .accessibilityLevel('yes')
  }

  /**
   * 音质面板
   *
   * 与「更多」同一套自绘底部面板（遮罩 + 深色圆角 + 上滑动效）：播放器本身就是系统的
   * 半模态，不再往它上面叠系统弹层（原因见 morePanel 的说明）。
   *
   * 档位只有一档或没有（本地 / 云端文件）时不给列表，只给一句说明 —— 列一排点不动的档
   * 不如直接说清楚为什么不能切。
   */
  @Builder
  qualityPanel() {
    Column() {
      Text('播放音质')
        .fontSize(13)
        .fontColor('#8CFFFFFF')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 16, bottom: 4 })
      Text(this.currentQualityText())
        .fontSize(12)
        .fontColor('#66FFFFFF')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ bottom: 10 })

      if (this.qualityOptions().length > 1) {
        ForEach(this.qualityOptions(), (quality: string) => {
          this.qualityItem(quality)
        }, (quality: string) => quality)

        Text('换档会用新音质把这个位置重新解析一次（中间会重新缓冲一小会儿）；'
          + '选中的这一档同时成为以后播放的音质（设置 - 播放设置）。')
          .fontSize(11.5)
          .fontColor('#59FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .lineHeight(16)
          .padding({ left: 24, right: 24, top: 4, bottom: 10 })
      } else {
        Text(this.noChoiceHint())
          .fontSize(13)
          .fontColor('#8CFFFFFF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .lineHeight(19)
          .padding({ left: 24, right: 24, top: 2, bottom: 16 })
      }

      Divider()
        .strokeWidth(0.5)
        .color('#26FFFFFF')
        .margin({ top: 8 })

      Text('取消')
        .fontSize(16)
        .fontColor('#8CFFFFFF')
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(54)
        .onClick(() => {
          this.qualityOpen = false;
        })
    }
    .width('100%')
    .padding({ bottom: this.bottomInset + 4 })
    .borderRadius({ topLeft: 20, topRight: 20 })
    .backgroundColor('#232326')
    .transition(TransitionEffect.translate({ y: 320 }).animation({ duration: 240, curve: Curve.Friction }))
  }

  /** 音质面板那一层：点面板以外收起（与 moreOverlay 同一套） */
  @Builder
  qualityOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.qualityOpen = false;
        })
      this.qualityPanel()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#8A000000')
  }

  /**
   * 「匹配歌词」面板
   *
   * 同样自绘、不用 bindSheet：播放器本身就是系统的半模态（见本文件开头那段说明），
   * 再叠一个系统弹层容易和它打架。
   */
  @Builder
  matchOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.matchOpen = false;
        })
      Column() {
        LyricMatchSheet({
          songName: this.name,
          singer: this.singer,
          durationMs: this.currentLocalDurationMs(),
          bottomInset: this.bottomInset,
          onPick: (info: LxMusicInfo, source: string) => {
            this.applyLyricMatch(info, source);
          },
        })
      }
      .width('100%')
      .height('62%')
      .borderRadius({ topLeft: 20, topRight: 20 })
      // 面板内容用的是浅色主题的配色（与「添加到歌单」那个系统半模态一致）
      .backgroundColor(C_BG)
      .clip(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#8A000000')
  }

  /**
   * 评论页
   *
   * 洛雪是 push 一个独立 screen（`navigation.pushCommentScreen`），这里和「更多」「匹配歌词」
   * 一样自绘一层铺满播放器的覆盖物 —— 播放器本身是系统半模态，不再往上叠系统弹层。
   * 页面内容与数据都在 views/CommentSheet.ets。
   */
  @Builder
  commentOverlay() {
    CommentSheet({
      songName: this.name,
      bottomInset: this.bottomInset,
      needsMatch: this.isCurrentLocal() || this.isCurrentWebDav(),
      onResolveTarget: () => this.resolveCommentTarget(),
      onClose: () => {
        this.commentOpen = false;
      },
    })
      .width('100%')
      .height('100%')
  }

  /** 播放模式按钮的图标：列表循环 / 顺序播放 / 单曲循环 / 随机播放 */
  private playModeIcon(): Resource {
    if (this.playMode === 'order') {
      return I_ORDER_PLAY;
    }
    if (this.playMode === 'single') {
      return I_REPEAT_ONE;
    }
    if (this.playMode === 'shuffle') {
      return I_SHUFFLE;
    }
    return I_REPEAT;
  }

  /** 切播放模式：图标只画得下四种模式的一种，顺带用提示条报一下切到了哪个 */
  private switchPlayMode(): void {
    const session = PlaySession.getInstance();
    session.cyclePlayMode();
    this.toast(`已切换为「${session.playModeLabel()}」`);
  }

  private playing(): boolean {
    return this.status === 'playing';
  }

  /** 播放模式的中文名（读屏要读出来；文案与 PlaySession.playModeLabel 一致） */
  private playModeLabel(): string {
    if (this.playMode === 'order') {
      return '顺序播放';
    }
    if (this.playMode === 'single') {
      return '单曲循环';
    }
    if (this.playMode === 'shuffle') {
      return '随机播放';
    }
    return '列表循环';
  }

  private loading(): boolean {
    return this.status === 'loading';
  }

  /**
   * 进度来自 AVPlayer 的 timeUpdate（每秒一次），这里只负责把当前行算出来并滚动过去。
   * 只有行号真的变了才滚，不然每秒都会触发一次滚动动画。
   */
  onProgressChanged(): void {
    const index: number = activeLyricIndex(this.lyricLines, this.progress);
    if (index === this.activeLine) {
      return;
    }
    this.activeLine = index;
    this.scrollToLine(index);
  }

  /** 换歌：歌词整批换掉，回到第一行 */
  onLyricChanged(): void {
    this.activeLine = -1;
    this.scrollToLine(0);
  }

  private scrollToLine(index: number): void {
    if (index < 0 || index >= this.lyricLines.length) {
      return;
    }
    try {
      // 列表第一个 ListItem 是顶部占位行，所以真实歌词行要 +1
      this.lyricScroller.scrollToIndex(index + 1, true, ScrollAlign.CENTER);
    } catch (e) {
      // 列表还没挂载（歌词刚回来那一瞬间）时忽略
    }
  }

  @Builder
  pageIndicator() {
    Row({ space: 5 }) {
      Column()
        .width(this.pageIndex === 0 ? 20 : 6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(this.pageIndex === 0 ? '#FFFFFF' : '#59FFFFFF')
      Column()
        .width(this.pageIndex === 1 ? 20 : 6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(this.pageIndex === 1 ? '#FFFFFF' : '#59FFFFFF')
    }
    .animation({ duration: 200, curve: Curve.EaseInOut })
    .onClick(() => {
      const next: number = this.pageIndex === 0 ? 1 : 0;
      this.pageIndex = next;
      this.syncKeepScreenOn();
      if (next === 0) {
        this.controller.showPrevious();
      } else {
        this.controller.showNext();
      }
    })
  }

  /** 当前唱到的那句歌词；还没有时间轴（activeLine = -1）就退到第一句 */
  private currentLyric(): LyricLine | null {
    if (this.lyricLines.length === 0) {
      return null;
    }
    const index: number = this.activeLine;
    if (index >= 0 && index < this.lyricLines.length) {
      return this.lyricLines[index];
    }
    return this.lyricLines[0];
  }

  private miniLyricText(): string {
    const line: LyricLine | null = this.currentLyric();
    return line === null ? '' : line.text;
  }

  private miniLyricTranslation(): string {
    const line: LyricLine | null = this.currentLyric();
    return line === null ? '' : line.translation;
  }

  /**
   * 封面页的小歌词（设置 - 播放设置 - 播放页显示小歌词）
   *
   * 就是当前那一句 + 翻译，跟着播放进度走；没歌词时整块不占位。
   */
  @Builder
  miniLyricBlock() {
    if (this.showMiniLyric && this.currentLyric() !== null) {
      Column({ space: 3 }) {
        Text(this.miniLyricText())
          .fontSize(this.lyricFontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(this.lyricCentered ? TextAlign.Center : TextAlign.Start)
          .width('100%')
        if (this.miniLyricTranslation().length > 0) {
          Text(this.miniLyricTranslation())
            .fontSize(Math.max(11, this.lyricFontSize * 0.72))
            .fontColor('#99FFFFFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(this.lyricCentered ? TextAlign.Center : TextAlign.Start)
            .width('100%')
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
    }
  }

  @Builder
  coverPage() {
    Column({ space: 26 }) {
      Blank()
      Stack() {
        CoverArt({
          url: this.cover,
          name: this.name,
          art: this.art,
          // 没有歌 / 没有封面 / 封面失效：兜底给聆听的应用图标（见 ui/Widgets.ets 的 CoverArt）
          appIcon: true,
          boxSize: 252,
          // 圆角来自外观设置（默认 12）
          radius: this.coverRadius,
          // 还在解析/缓冲时封面可能没到：先给深色底，别闪一张默认封面
          pending: this.status === 'loading',
        })
      }
      .width(252)
      .height(252)
      .borderRadius(this.coverRadius)
      .shadow({ radius: 40, color: '#66000000', offsetX: 0, offsetY: 18 })
      // 播放/暂停时的弹簧缩放（缩放中心放在封面正中，别从左上角放大）
      .scale({
        x: this.coverSpringScale,
        y: this.coverSpringScale,
        centerX: '50%',
        centerY: '50%',
      })

      Row({ space: 12 }) {
        Column({ space: 7 }) {
          Text(this.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.singer)
            .fontSize(13.5)
            .fontColor('#A6FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 收藏：与歌曲行上是同一个组件（深色底上的颜色由这里给），点一下收藏/
        // 再点一下取消收藏，状态来自收藏名单，换歌、在别处改收藏都跟着变
        FavoriteHeart({
          songId: this.currentId,
          iconSize: 25,
          colorOn: '#FF5A5A',
          colorOff: '#CCFFFFFF',
          onToggle: () => {
            this.toggleLiked();
          },
        })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      // 小歌词：跟着进度走的当前一句（可在「设置 - 播放设置」里关掉）
      this.miniLyricBlock()

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 30, right: 30 })
  }

  /** 一行歌词：点一下跳到那一句（字号/对齐来自设置 - 播放设置） */
  @Builder
  lyricLine(line: LyricLine, index: number) {
    Column({ space: 3 }) {
      Text(line.text)
        .fontSize(this.lyricFontSize)
        .fontWeight(index === this.activeLine ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(index === this.activeLine ? '#FFFFFF' : (index < this.activeLine ? '#B3FFFFFF' : '#59FFFFFF'))
        .textAlign(this.lyricCentered ? TextAlign.Center : TextAlign.Start)
        .width('100%')
        .animation({ duration: 240, curve: Curve.EaseInOut })
      if (line.translation.length > 0) {
        Text(line.translation)
          .fontSize(Math.max(11, this.lyricFontSize * 0.72))
          .fontColor(index === this.activeLine ? '#B3FFFFFF' : '#40FFFFFF')
          .textAlign(this.lyricCentered ? TextAlign.Center : TextAlign.Start)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .onClick(() => {
      if (line.time >= 0) {
        PlaySession.getInstance().seek(line.time);
      }
    })
  }

  /**
   * 歌词页
   *
   * 用 List + Scroller：当前行由播放进度算出来，scrollToIndex(CENTER) 把它滚到中间；
   * 首尾各垫一个占位行，短歌词也能滚到正中间（否则头尾几句永远贴着边）。
   */
  @Builder
  lyricPage() {
    Column() {
      if (this.lyricStatus === 'loading') {
        Column({ space: 10 }) {
          LoadingProgress().width(28).height(28).color('#8CFFFFFF')
          Text('正在加载歌词…')
            .fontSize(13)
            .fontColor('#8CFFFFFF')
        }
      } else if (this.lyricLines.length === 0) {
        Column({ space: 8 }) {
          Text('暂无歌词')
            .fontSize(16)
            .fontColor('#8CFFFFFF')
          Text(PlaySession.getInstance().current === null ? '先点一首歌' : '音源和内置平台都没取到这首的歌词')
            .fontSize(12.5)
            .fontColor('#59FFFFFF')
        }
      } else {
        List({ scroller: this.lyricScroller }) {
          ListItem() {
            Column().width('100%').height(200)
          }
          ForEach(this.lyricLines, (line: LyricLine, index: number) => {
            ListItem() {
              this.lyricLine(line, index)
            }
          }, (line: LyricLine, index: number) => `${index}_${line.time}_${line.text}`)
          ListItem() {
            Column().width('100%').height(200)
          }
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 26, right: 26 })
    // 关掉「歌词页模糊效果」时压一层纯深色底，把这页背后的封面模糊盖住
    .backgroundColor(this.lyricBlur ? Color.Transparent : '#0C0C0E')
  }

  /** 播放钮：圆形白色底 + 居中播放/暂停图形（和迷你播放器里那颗播放钮同一种形状） */
  @Builder
  playButton() {
    Stack({ alignContent: Alignment.Center }) {
      // 轮廓流光垫在最底下：白色主光带 + 一点品牌红副光带，低透明度，
      // 只在播放钮外缘走一圈（HDS 着色器，不吃触摸，不影响点击）
      HdsEdgeFlowLight({
        radius: 36,
        colorA: '#66FFFFFF',
        colorB: '#33FF6B6B',
        lightOpacity: 0.5,
      })
      // 圆底用带圆角的容器 + 系统阴影，不要用 Circle().shadow()：
      // Shape 的阴影是按「组件矩形减去图形」算的，会画出一个方块状的底，很难看
      Column()
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor('#F4F4F6')
        .shadow({ radius: 26, color: '#66FFFFFF', offsetX: 0, offsetY: 0 })
      if (this.loading() || this.buffering) {
        // 解析播放链接 / 弱网等数据期间转圈：这时没在出声，不能显示成「播放中」
        LoadingProgress()
          .width(30)
          .height(30)
          .color('#8A8A90')
      } else {
        IconGlyph({
              symbol: this.playing() ? I_PAUSE : I_PLAY,
              iconSize: 26,
              color: '#17171A',
              // 播放 <-> 暂停换图时走系统的符号替换动效（图标自己形变，不是硬切）
              replaceEffect: true,
            })
          .offset({ x: this.playing() ? 0 : 2 })
      }
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      PlaySession.getInstance().toggle();
    })
    .accessibilityText(this.playing() ? '暂停' : '播放')
    .accessibilityLevel('yes')
  }

  /**
   * 进度条底下的「缓冲条」
   *
   * 惯例（浏览器 / 各家播放器都这么做）：进度条上除了已播的那一段，还有一条更长的浅色段，
   * 表示「已经缓冲到哪儿了」—— 网络断了还能靠它撑到那一段，用户一眼就知道要不要等。
   * 系统的 Slider 只有一条轨道，画不出三段，所以这里自绘一条垫在 Slider 底下，
   * 把 Slider 自己的轨道设成透明：交互（拖动 seek）仍然归 Slider。
   *
   * 左右各让出半个滑块，才能和 Slider 的轨道两端对齐（滑块是沿轨道中心走的）。
   */
  @Builder
  bufferTrack() {
    Stack({ alignContent: Alignment.Start }) {
      // 整条底（没缓冲到的部分）
      Column()
        .width('100%')
        .height(TRACK_THICKNESS)
        .borderRadius(TRACK_THICKNESS / 2)
        .backgroundColor('#33FFFFFF')
      // 已缓冲（可以播到这里）：按块往前长，加个短动画让它看起来是连续走而不是一格一格跳
      Column()
        .width(`${this.bufferPercent()}%`)
        .height(TRACK_THICKNESS)
        .borderRadius(TRACK_THICKNESS / 2)
        .backgroundColor('#80FFFFFF')
        .animation({ duration: TRACK_ANIM_MS, curve: Curve.Linear })
      // 已播
      Column()
        .width(`${this.progressPercent()}%`)
        .height(TRACK_THICKNESS)
        .borderRadius(TRACK_THICKNESS / 2)
        .backgroundColor('#FFFFFF')
        .animation({ duration: TRACK_ANIM_MS, curve: Curve.Linear })
    }
    .width('100%')
    .height(TRACK_THICKNESS)
    .padding({ left: TRACK_INSET, right: TRACK_INSET })
  }

  /** 已播进度占总长的百分比 */
  private progressPercent(): number {
    return percentOf(this.progress, this.duration);
  }

  /** 已缓冲进度占总长的百分比（本地播放整首都在本地，直接画满） */
  private bufferPercent(): number {
    return percentOf(this.buffered, this.duration);
  }

  @Builder
  controlBar() {
    Column({ space: 0 }) {
      // 进度条 = 自己画的缓冲条（底） + 系统 Slider（交互）
      Stack() {
        this.bufferTrack()

        Slider({
          value: this.progress,
          min: 0,
          max: this.duration > 0 ? this.duration : 1,
          style: SliderStyle.OutSet,
        })
          .trackThickness(TRACK_THICKNESS)
          .blockSize({ width: BLOCK_SIZE, height: BLOCK_SIZE })
          .blockColor('#FFFFFF')
          // 轨道交给下面自绘的那条（要画三段：整条底 / 缓冲段 / 已播段），
          // Slider 只留滑块和拖动交互
          .selectedColor(Color.Transparent)
          .trackColor(Color.Transparent)
          .width('100%')
          .padding({ left: 0, right: 0 })
          // 还没真正出声（loading）时进度条不可拖，避免拖了却没反应
          .enabled(this.status === 'playing' || this.status === 'paused')
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              return;
            }
            // 真正 seek 到播放器；进度条随后由 AVPlayer 的 timeUpdate 回写
            PlaySession.getInstance().seek(value);
          })
      }
      .width('100%')

      Row() {
        Text(formatTime(this.progress))
          .fontSize(11.5)
          .fontColor('#A6FFFFFF')
        Blank()
        this.qualityButton()
        Blank()
        Text(formatTime(this.duration))
          .fontSize(11.5)
          .fontColor('#A6FFFFFF')
      }
      .width('100%')
      .padding({ top: 6, bottom: 4 })

      // ------------------------------------------------ 播放控制
      // 五个等分格：播放模式 / 上一首 / 播放 / 下一首 / 播放列表，
      // 这样五个按钮的间距与洛雪一致，也不会贴到屏幕两边
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({
              symbol: this.playModeIcon(),
              iconSize: 23,
              color: '#CCFFFFFF',
            })
        }
        .layoutWeight(1)
        .height(84)
        .onClick(() => {
          this.switchPlayMode();
        })
        .accessibilityText(`播放模式：${this.playModeLabel()}，点按切换`)
        .accessibilityLevel('yes')

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({
              symbol: I_PREV,
              iconSize: 30,
              color: '#FFFFFF',
            })
        }
        .layoutWeight(1)
        .height(84)
        .onClick(() => {
          PlaySession.getInstance().prev();
        })
        .accessibilityText('上一首')
        .accessibilityLevel('yes')

        Stack({ alignContent: Alignment.Center }) {
          this.playButton()
        }
        .layoutWeight(1)
        .height(84)

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({
              symbol: I_NEXT,
              iconSize: 30,
              color: '#FFFFFF',
            })
        }
        .layoutWeight(1)
        .height(84)
        .onClick(() => {
          PlaySession.getInstance().next();
        })
        .accessibilityText('下一首')
        .accessibilityLevel('yes')

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({
              symbol: I_QUEUE,
              iconSize: 24,
              color: '#CCFFFFFF',
            })
        }
        .layoutWeight(1)
        .height(84)
        .onClick(() => {
          this.onOpenQueue();
        })
        .accessibilityText('播放列表')
        .accessibilityLevel('yes')
      }
      .width('100%')

      /**
       * 底部功能入口
       *
       * 这里没有用 HdsActionBar：它是按「主按钮 + 左右两组按钮」排布的，
       * 不会把 N 个图标等分铺满整行（实测四个图标会挤在左侧，还多留一块底部空白），
       * 所以这行自己排：四等分格，每个图标居中。
       * 左一是系统的投播选择器（点开是系统的设备面板），右一是「更多」底部菜单。
       */
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          /**
           * 投播至：系统组件负责交互与设备面板（STYLE_PANEL = 底部面板样式），
           * 外观自己画 —— 官方说明里就建议用 customPicker，系统默认外观是运行时画的，
           * 实测在这台设备上根本没渲染出来（只有可点区域在）。
           */
          AVCastPicker({
            normalColor: '#8CFFFFFF',
            activeColor: '#FFFFFF',
            pickerStyle: AVCastPickerStyle.STYLE_PANEL,
            sessionType: 'audio',
            customPicker: () => this.castPickerBuilder(),
          })
            .width(44)
            .height(44)
        }
        .layoutWeight(1)
        .height(44)
        .accessibilityText('投播至')
        .accessibilityLevel('yes')

        /**
         * 评论（原位是那颗没接功能的铃铛）
         *
         * 洛雪的播放页把评论收在「更多」菜单里，横向布局才在工具栏上给一颗钮。
         * 这里把它放到工具栏：一来「更多」里同样有入口，二来这颗钮原本就是个占位
         * （点不动、读屏也跳过），换成评论钮之后底部这排四个入口都是能用的。
         */
        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_COMMENT, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)
        .onClick(() => {
          this.commentOpen = true;
        })
        .accessibilityText('查看评论')
        .accessibilityLevel('yes')

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_DOWNLOAD, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)
        .onClick(() => {
          this.downloadCurrent();
        })
        .accessibilityText('下载这首歌')
        .accessibilityLevel('yes')

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)
        .onClick(() => {
          this.moreOpen = true;
        })
        .accessibilityText('更多')
        .accessibilityLevel('yes')
      }
      .width('100%')
      .padding({ top: 8, bottom: 6 })
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // ---------------------------------------------------- 背景（封面高斯模糊 + 压暗）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 205, colors: [['#33333A', 0.0], ['#0C0C0E', 1.0]] })
      if (this.cover.length > 0) {
        Image(this.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(70)
          .opacity(0.5)
          .draggable(false)
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#40000000')

      // ---------------------------------------------------- 页面主体
      Column() {
        // 顶栏
        Row() {
          IconGlyph({
              symbol: I_CHEVRON_DOWN,
              iconSize: 26,
              color: '#E6FFFFFF',
            })
            .onClick(() => {
              this.onClose();
            })
          Blank()
          this.pageIndicator()
          Blank()
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(36).height(36).fill('#26FFFFFF')
            IconGlyph({
              symbol: I_SHARE,
              iconSize: 20,
              color: '#E6FFFFFF',
            })
          }
          .width(36)
          .height(36)
          .onClick(() => {
            void this.share();
          })
        }
        .width('100%')
        // 高度要把状态栏的留白算进去，否则 padding 会把这 56vp 的内容区吃掉一截
        .height(56 + this.topInset)
        .padding({ left: 18, right: 18, top: this.topInset })

        // 封面 / 歌词
        Swiper(this.controller) {
          this.coverPage()
          this.lyricPage()
        }
        .index(this.pageIndex)
        .loop(false)
        .indicator(false)
        .duration(280)
        .curve(Curve.Friction)
        .layoutWeight(1)
        .width('100%')
        .onChange((index: number) => {
          this.pageIndex = index;
          this.syncKeepScreenOn();
        })

        // 控制区
        this.controlBar()
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset + 12 })

      // 右下角「更多」：盖在播放器内容之上的自绘底部面板
      if (this.moreOpen) {
        this.moreOverlay()
      }

      // 音质面板：进度条下面那颗音质钮点出来的（同一套自绘面板）
      if (this.qualityOpen) {
        this.qualityOverlay()
      }

      // 「匹配歌词」：同样是自绘面板（播放器本身是系统半模态，不再叠系统弹层）
      if (this.matchOpen) {
        this.matchOverlay()
      }

      // 评论页：与上面两层同一套做法（自绘、铺满）
      if (this.commentOpen) {
        this.commentOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0C0C0E')
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 12 })
        .onActionEnd((event: GestureEvent) => {
          // 「更多」/「音质」/「评论」面板开着时不下滑关闭：在面板上往下拖不该把整个播放器收掉
          if (!this.moreOpen && !this.qualityOpen && !this.commentOpen && event.offsetY > 70) {
            this.onClose();
          }
        })
    )
  }
}
