import { PlaySession, SongItem } from '../core/player/PlaySession';
import { K_CURRENT_ART, K_CURRENT_COVER, K_CURRENT_ID, K_CURRENT_NAME, K_CURRENT_QUALITY, K_CURRENT_SINGER,
  K_DURATION, K_LYRIC_LINES, K_LYRIC_STATUS, K_PLAYER_STATUS,
  K_PLAY_MODE, K_PROGRESS } from '../core/player/PlaySession';
import { LyricLine, activeLyricIndex } from '../core/music/Lyric';
import { K_LYRIC_BLUR, K_LYRIC_CENTERED, K_LYRIC_FONT_SIZE, K_LYRIC_KEEP_SCREEN,
  K_SHOW_MINI_LYRIC } from '../core/settings/PlaySettings';
import { I_BELL, I_CAST, I_CHEVRON_DOWN, I_DOWNLOAD, I_MORE_CIRCLE, I_NEXT, I_ORDER_PLAY,
  I_PAUSE, I_PLAY, I_PREV, I_QUEUE, I_REPEAT, I_REPEAT_ONE, I_SHARE, I_SHUFFLE, IconGlyph } from '../ui/Icons';
import { CoverArt, FavoriteHeart } from '../ui/Widgets';
import { AVCastPicker, AVCastPickerStyle } from '@kit.AVSessionKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';

function formatTime(seconds: number): string {
  const total: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return `${m < 10 ? '0' : ''}${m}:${s < 10 ? '0' : ''}${s}`;
}

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
  /** 当前这首歌的条目 id：传给收藏爱心（换歌时爱心跟着换状态） */
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_CURRENT_NAME) name: string = '';
  @StorageLink(K_CURRENT_SINGER) singer: string = '';
  @StorageLink(K_CURRENT_COVER) cover: string = '';
  @StorageLink(K_CURRENT_ART) art: boolean = false;
  @StorageLink(K_CURRENT_QUALITY) quality: string = '128k';
  @StorageLink(K_PLAYER_STATUS) status: string = 'idle';
  @StorageLink(K_PROGRESS) @Watch('onProgressChanged') progress: number = 0;
  @StorageLink(K_DURATION) duration: number = 0;
  @StorageLink(K_LYRIC_LINES) @Watch('onLyricChanged') lyricLines: LyricLine[] = [];
  @StorageLink(K_LYRIC_STATUS) lyricStatus: string = 'none';
  @StorageLink(K_PLAY_MODE) playMode: string = 'list';
  @State pageIndex: number = 0;
  /** 右下角「更多」的底部面板是否展开 */
  @State moreOpen: boolean = false;
  /** 当前唱到的歌词行；-1 = 没有时间轴/还没开始 */
  @State activeLine: number = -1;
  private controller: SwiperController = new SwiperController();
  private lyricScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 打开播放器时可能已经唱到一半了，先把当前行对上，别等下一秒 timeUpdate
    this.activeLine = activeLyricIndex(this.lyricLines, this.progress);
    this.syncKeepScreenOn();
  }

  aboutToDisappear(): void {
    // 播放器收起就把常亮还回去，别让这个窗口一直钉在亮屏上
    this.onKeepScreenOn(false);
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

  /** 下载当前这首歌（设置里的文件名格式 / 保存位置都生效） */
  private downloadCurrent(): void {
    const session = PlaySession.getInstance();
    const item: SongItem | null = session.current;
    if (item === null) {
      this.toast('还没有正在播放的歌');
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
          boxSize: 252,
          radius: 12,
          // 还在解析/缓冲时封面可能没到：先给深色底，别闪一张默认封面
          pending: this.status === 'loading',
        })
      }
      .width(252)
      .height(252)
      .borderRadius(12)
      .shadow({ radius: 40, color: '#66000000', offsetX: 0, offsetY: 18 })

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
      // 圆底用带圆角的容器 + 系统阴影，不要用 Circle().shadow()：
      // Shape 的阴影是按「组件矩形减去图形」算的，会画出一个方块状的底，很难看
      Column()
        .width(72)
        .height(72)
        .borderRadius(36)
        .backgroundColor('#F4F4F6')
        .shadow({ radius: 26, color: '#66FFFFFF', offsetX: 0, offsetY: 0 })
      if (this.loading()) {
        // 解析播放链接 / 缓冲期间转圈：这时还没出声，不能显示成「播放中」
        LoadingProgress()
          .width(30)
          .height(30)
          .color('#8A8A90')
      } else {
        IconGlyph({
              symbol: this.playing() ? I_PAUSE : I_PLAY,
              iconSize: 26,
              color: '#17171A',
            })
          .offset({ x: this.playing() ? 0 : 2 })
      }
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      PlaySession.getInstance().toggle();
    })
  }

  @Builder
  controlBar() {
    Column({ space: 0 }) {
      Slider({
        value: this.progress,
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        style: SliderStyle.OutSet,
      })
        .trackThickness(1.5)
        .blockSize({ width: 9, height: 9 })
        .blockColor('#FFFFFF')
        .selectedColor('#FFFFFF')
        .trackColor('#40FFFFFF')
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

      Row() {
        Text(formatTime(this.progress))
          .fontSize(11.5)
          .fontColor('#A6FFFFFF')
        Blank()
        Text(this.quality)
          .fontSize(11.5)
          .fontColor('#CCFFFFFF')
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(9)
          .backgroundColor('#26FFFFFF')
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

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_BELL, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_DOWNLOAD, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)
        .onClick(() => {
          this.downloadCurrent();
        })

        Stack({ alignContent: Alignment.Center }) {
          IconGlyph({ symbol: I_MORE_CIRCLE, iconSize: 22, color: '#8CFFFFFF' })
        }
        .layoutWeight(1)
        .height(44)
        .onClick(() => {
          this.moreOpen = true;
        })
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0C0C0E')
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 12 })
        .onActionEnd((event: GestureEvent) => {
          // 「更多」面板开着时不下滑关闭：在面板上往下拖不该把整个播放器收掉
          if (!this.moreOpen && event.offsetY > 70) {
            this.onClose();
          }
        })
    )
  }
}
