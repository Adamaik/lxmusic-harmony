import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { HintText, OptionSetting, SliderSetting, ToggleSetting } from '../ui/SettingWidgets';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { PlaySession } from '../core/player/PlaySession';
import { PlaybackService } from '../core/player/PlaybackService';
import { DEFAULT_SOURCE_LABELS, DEFAULT_SOURCE_VALUES,
  EXTEND_QUALITYS, EXTEND_QUALITY_LABELS, K_AUTO_MATCH_LYRIC, K_AUTO_PAUSE_HEADSET_OFF,
  K_AUTO_RESUME_AFTER_INTERRUPT,
  K_BLUETOOTH_LYRIC, K_DEFAULT_SOURCE, K_DESKTOP_LYRIC,
  K_EXTEND_QUALITY,
  K_EXTEND_QUALITY_TYPE,
  K_LYRIC_BLUR, K_LYRIC_CENTERED, K_LYRIC_FONT_SIZE, K_LYRIC_KEEP_SCREEN, K_PLAY_QUALITY, K_PLAY_WITH_OTHERS,
  K_PLAYER_MOTION, K_SHOW_MINI_LYRIC, K_SWIPE_SWITCH_SONG, K_SWITCH_PLATFORM_SAME_SONG,
  LYRIC_FONT_MAX, LYRIC_FONT_MIN,
  MAIN_QUALITYS, MAIN_QUALITY_LABELS,
  PLAYER_MOTION_IMMERSIVE, PLAYER_MOTION_LABELS, PLAYER_MOTION_LEVELS, PLAYER_MOTION_LIGHT,
  PlaySettings } from '../core/settings/PlaySettings';
import { isFileQuality, K_ACTUAL_QUALITY, qualityFallbackNote, qualityLabel, targetQuality } from '../core/music/Quality';

/** 拓展音质：开关 +（开着时）档位 + 说明 */
@Component
struct ExtendQualitySetting {
  @Prop label: string = '';
  @Prop on: boolean = false;
  @Prop options: string[] = [];
  @Prop activeIndex: number = 0;
  @Prop hint: string = '';
  /**
   * 开关旁边常驻的一句说明
   *
   * 与 `hint` 分开：`hint` 只在开关打开后（选了档位才需要看）显示，而
   * 「需要登录 + 会员」是**决定要不要打开**的前置条件，开关关着也得看得见，
   * 否则用户会以为打开就一定有母带（2026-10-21 用户就是被这个坑到的）。
   */
  @Prop note: string = '';
  onToggle: (next: boolean) => void = () => {
  };
  onPickOption: (index: number) => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      ToggleSetting({
        label: this.label,
        value: this.on,
        onPick: (next: boolean) => {
          this.onToggle(next);
        },
      })
      if (this.note.length > 0) {
        HintText({ text: this.note })
      }
      if (this.on) {
        OptionSetting({
          label: '拓展音质档位',
          options: this.options,
          activeIndex: this.activeIndex,
          onPick: (index: number) => {
            this.onPickOption(index);
          },
        })
        if (this.hint.length > 0) {
          HintText({ text: this.hint })
        }
      }
    }
    .width('100%')
  }
}

/**
 * 播放设置
 *
 * 对应设置页里的「播放设置」。**音效不在这里**：它已经挪成设置页的一行独立入口
 * （「播放设置」下面、「缓存」上面），页面是 views/EqSettingsView.ets ——
 * 音效改的是声音本身的频响，与这里「播什么 / 怎么显示」的项不是一类。
 *
 * 参考图上的分区：
 *   〇、渠道：默认渠道（自动 / 酷我 / 酷狗 / 咪咕 / QQ / 网易）——
 *       歌手页、本地与云端自动匹配歌词这类没有渠道选择项的地方，先从这个平台取数
 *   一、音质：播放音质（128K/320K/FLAC/24Bit）、拓展音质（开关 + Hi-Res/全景声/全景声+/母带）、
 *       与其他应用同时播放、被其他应用打断结束后自动重新播放
 *   二、歌词：播放页显示小歌词、歌词页模糊效果、歌词居中显示、歌词字号、歌词页不熄屏、
 *       桌面歌词、车载蓝牙歌词
 *   三、播放页：播放页动效（三档：关闭 / 轻量 = 封面呼吸 + 主色光晕 + 边缘光带 /
 *       沉浸 = 再加 3D 倾斜 + 扩散波纹 + 上浮光点 + 背景流动；默认轻量）、
 *       上下滑动切歌（默认关：打开后播放页上滑下一首、下滑上一首）
 *
 * 参考图里还有一项「歌词帧率」，这里没做：歌词本身不是逐帧渲染的（靠 AVPlayer 的
 * timeUpdate 一秒一推、行间是 240ms 的补间），给一个帧率选项只是摆设。
 * （「播放页动效」那几处也不是逐帧 JS 渲染：呼吸与光带都是框架 / 着色器侧的声明式动画，
 * JS 侧没有任何每帧回调，所以同样的理由不适用于它。）
 *
 * 所有项都写进 PlaySettings（沙箱 JSON + AppStorage），改完立即落盘，重启不丢。
 * 真机上生效的路径：
 *   - 默认渠道 -> 歌手解析（MusicArtist.resolveArtistByName）与本地 / 云端自动匹配歌词
 *     （LyricMatch.autoMatchLyric）先从这个平台取数，取不到再按原来的顺序回退
 *   - 播放音质 / 拓展音质 -> PlaySession.negotiateQuality 解析播放链接时按候选顺序取
 *   - 与其他应用同时播放 -> LxPlayer 起播时设 audioInterruptMode、并激活「与其他应用混音」
 *     的应用级音频会话（跨应用只认后者，见 LxPlayer.applyConcurrency）
 *   - 被打断结束后自动重新播放 -> LxPlayer 的 audioInterrupt 监听收到 RESUME 时再 play 一次
 *   - 歌词各项 -> PlayerView（封面页小歌词 / 歌词页背景、对齐、字号）
 *   - 歌词页不熄屏 -> 页面把窗口的 keepScreenOn 打开（见 pages/Index.ets）
 *   - 桌面歌词 -> PlaybackService 控制系统歌词悬浮窗的显隐
 *   - 车载蓝牙歌词 -> PlaybackService 往 AVMetadata.singleLyricText 写当前这一句，走系统蓝牙模块
 */
@Component
export struct PlaySettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @StorageLink(K_PLAY_QUALITY) quality: string = '128k';
  /** 默认渠道（'' = 自动 / 不指定，见 PlaySettings.K_DEFAULT_SOURCE） */
  @StorageLink(K_DEFAULT_SOURCE) defaultSource: string = '';
  @StorageLink(K_EXTEND_QUALITY) extend: boolean = false;
  @StorageLink(K_EXTEND_QUALITY_TYPE) extendType: string = 'hires';
  /**
   * 正在播的那一首**实际生效**的音质档（见 Quality.ets 的 K_ACTUAL_QUALITY）
   *
   * 设置页显示的仍然是用户选的目标档（那是设置项，不该被一首歌带偏）；
   * 这一项只用来补一句「刚才那一首实际到了哪一档」，让用户明白设置没失效，
   * 是这首歌 / 这个音源只给到这一档。
   */
  @StorageLink(K_ACTUAL_QUALITY) actualQuality: string = '';
  @StorageLink(K_PLAY_WITH_OTHERS) playWithOthers: boolean = false;
  @StorageLink(K_SHOW_MINI_LYRIC) showMiniLyric: boolean = false;
  @StorageLink(K_LYRIC_BLUR) lyricBlur: boolean = true;
  @StorageLink(K_LYRIC_CENTERED) lyricCentered: boolean = true;
  @StorageLink(K_LYRIC_FONT_SIZE) fontSize: number = 19;
  @StorageLink(K_LYRIC_KEEP_SCREEN) keepScreen: boolean = true;
  @StorageLink(K_DESKTOP_LYRIC) desktopLyric: boolean = false;
  /** 车载蓝牙歌词：往 AVMetadata.singleLyricText 写当前这一句，由系统蓝牙模块送给车机 */
  @StorageLink(K_BLUETOOTH_LYRIC) bluetoothLyric: boolean = false;
  /** 本地音乐 / 云端（WebDAV）音乐自动匹配歌词（要联网搜一次，所以给了开关） */
  @StorageLink(K_AUTO_MATCH_LYRIC) autoMatchLyric: boolean = true;
  /** 被打断（来电 / 闹铃 / 别的应用出声）结束后自动接着放 */
  @StorageLink(K_AUTO_RESUME_AFTER_INTERRUPT) autoResume: boolean = true;
  /** 摘下耳机 / 断蓝牙是否自动暂停（见 PlaySettings.K_AUTO_PAUSE_HEADSET_OFF） */
  @StorageLink(K_AUTO_PAUSE_HEADSET_OFF) autoPauseHeadsetOff: boolean = true;
  /**
   * 播放页动效档位（'off' / 'light' / 'immersive'，见 PlaySettings.K_PLAYER_MOTION）
   *
   * 早先是布尔开关；三档之后用同一套分段胶囊（OptionSetting）选，
   * 因为「轻量 / 沉浸」不是「开与关」的关系，开关表达不了。
   */
  @StorageLink(K_PLAYER_MOTION) playerMotion: string = PLAYER_MOTION_LIGHT;
  /**
   * 上下滑动切歌（默认关，见 PlaySettings.K_SWIPE_SWITCH_SONG）
   *
   * 播放页在每次纵向拖动松手时现读这一项，拨完立刻生效，不用重进播放页。
   */
  @StorageLink(K_SWIPE_SWITCH_SONG) swipeSwitchSong: boolean = false;
  /**
   * 放不出来时自动换别的平台的同名歌（默认关，见 PlaySettings.K_SWITCH_PLATFORM_SAME_SONG）
   *
   * PlaySession 取地址最终失败时现读这一项，拨完立刻生效。
   */
  @StorageLink(K_SWITCH_PLATFORM_SAME_SONG) switchPlatformSameSong: boolean = false;
  /** 系统是否支持桌面歌词：问过系统之前不下结论（见 desktopLyricHint） */
  @State lyricSupportKnown: boolean = false;
  @State lyricSupported: boolean = false;
  /**
   * 窗口宽度（vp）：宽屏下两张卡并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  aboutToAppear(): void {
    const service = PlaybackService.getInstance();
    this.lyricSupportKnown = service.isDesktopLyricSupportKnown();
    this.lyricSupported = service.isDesktopLyricSupported();
    if (!this.lyricSupportKnown) {
      // 没播过歌时会话还没建，这里主动查一次，不然提示会说错
      service.probeDesktopLyricSupport().then((supported: boolean) => {
        this.lyricSupportKnown = true;
        this.lyricSupported = supported;
      });
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private qualityIndex(): number {
    const index: number = MAIN_QUALITYS.indexOf(this.quality);
    return index < 0 ? MAIN_QUALITYS.length - 1 : index;
  }

  /**
   * 「设置里的目标档」与「刚才那一首实际生效档」不一致时的一句轻提示（空串 = 不显示）
   *
   * 为什么设置页也要这一句：用户群多次反馈「开了拓展音质却看不到高品 / 实际音质不符」
   * （2026-11-18 22:07、11-19 09:28 / 15:24）。设置页保留用户选的目标档不动，
   * 但在这里如实说一句「实际是 FLAC（源不支持 母带）」，困惑就解开了。
   * 只在真的有歌在放的时候显示 —— 没播歌时这一项无意义。
   */
  private actualQualityHint(): string {
    if (this.actualQuality.length === 0) {
      return '';
    }
    if (isFileQuality(this.actualQuality)) {
      return '当前播放的是本地 / 云端音频文件，音质由文件本身决定。';
    }
    const note: string = qualityFallbackNote(this.actualQuality, targetQuality());
    if (note.length > 0) {
      return `正在播放的这首实际是 ${qualityLabel(this.actualQuality)}（${note}），`
        + '设置里的目标档仍然保留。';
    }
    return `正在播放的这首实际是 ${qualityLabel(this.actualQuality)}。`;
  }

  /** 默认渠道胶囊选中的是第几枚（存档里是空串 / 不认识的平台都落在「自动」上） */
  private defaultSourceIndex(): number {
    const index: number = DEFAULT_SOURCE_VALUES.indexOf(this.defaultSource);
    return index < 0 ? 0 : index;
  }

  private extendIndex(): number {
    const index: number = EXTEND_QUALITYS.indexOf(this.extendType);
    return index < 0 ? 0 : index;
  }

  /** 播放页动效胶囊选中的是第几枚（存档里不认识的取值都落在「轻量」上） */
  private motionIndex(): number {
    const index: number = PLAYER_MOTION_LEVELS.indexOf(this.playerMotion);
    return index < 0 ? PLAYER_MOTION_LEVELS.indexOf(PLAYER_MOTION_LIGHT) : index;
  }

  /**
   * 播放页动效三档的说明（选中哪档说哪档）
   *
   * 为什么逐档给一句话而不是一段通用说明：三档的取舍就是「省电 <-> 好看」，
   * 用户要能一眼看出多出来的那点观感是用什么换的。沉浸档还必须讲清它比轻量档贵在哪，
   * 否则「更好看」的默认预期会让人一路开到沉浸、然后觉得费电。
   */
  private motionHint(): string {
    if (this.playerMotion === PLAYER_MOTION_IMMERSIVE) {
      return '在轻量档之上再加：封面 3D 倾斜并缓慢漂浮、封面后向外扩散的波纹、'
        + '少量上浮光点、背景主色缓慢流动。代价是播放时多一条 30fps 上限的动画'
        + '与最多 12 颗粒子；暂停、收起播放页、退到后台、切歌时就全部停掉并卸载。';
    }
    if (this.playerMotion === PLAYER_MOTION_LIGHT) {
      return '封面随播放轻微呼吸、背后一团主色柔光、沿封面边缘一道缓慢流动的光带。'
        + '零 JS 定时器：全靠框架侧的声明式动画，停下来就真的没有东西在跑。';
    }
    return '最省电：播放页一点动画都不跑。封面主色的氛围底是静态渐变（画一次就不变），'
      + '不产生持续功耗，所以它仍然保留。';
  }

  /**
   * 上下滑动切歌的说明
   *
   * 必须讲清三件事：手势方向、**默认关闭**（不是坏了），以及它和「下滑收起播放页」
   * 的关系 —— 这一项会占掉播放页正文区的下拉手势，用户要能预期到「下滑不再收起」。
   */
  private swipeSwitchSongHint(): string {
    return '在播放页上滑切下一首、下滑切上一首（位移超过约 72vp，或快速甩动时才触发，'
      + '轻轻一划不会误切）。打开后正文区的下滑不再收起播放页 —— 收起请点左上角的箭头，'
      + '或在顶栏那一条上向下拖动。顺序播放到队首/队尾时会提示，不会静默失败。';
  }

  /**
   * 跨平台同名歌替换的说明
   *
   * 这一项的风险必须写在用户看得见的地方：不同平台的曲库、版本、时长都不一样，
   * 同名歌可能是 Live、翻唱、加速版，换过去的「不是没歌可放」而是「可能放错歌」。
   * 所以讲清默认关闭、以及关着时是直接报错而不是干等。
   */
  private switchPlatformSameSongHint(): string {
    return '由于不同平台的曲库与版本存在差异，可能会播放成同名但不同版本的歌曲'
      + '（Live、翻唱、加速版等）或错误的音乐，请自行确认。默认关闭：关着时当前平台取不到'
      + '播放地址会直接报错，不会替你换成别的平台的歌。它和「音源设置 - 自动切换音源」'
      + '不是一回事，那一项换的是同一平台下的不同音源。';
  }

  /** 桌面歌词这一项的说明：不支持的设备上明说，免得用户以为开关坏了 */
  private desktopLyricHint(): string {
    if (this.lyricSupportKnown && !this.lyricSupported) {
      return '当前设备/系统不支持桌面歌词（系统的歌词悬浮窗），这个开关不会有实际效果；'
        + '播控中心里的歌词不受影响。';
    }
    return '桌面歌词是系统的悬浮歌词窗，由系统按时间轴自己滚动：播放中且这首歌有词时显示，'
      + '暂停不收起，停播、换到没词的歌或关掉这个开关时收起。';
  }

  /**
   * 车载蓝牙歌词这一项的说明
   *
   * 讲清三件事：开关做的是什么、手机这边不受影响、以及能不能显示由车机决定 ——
   * 免得用户在自己车上没看到歌词，以为开关坏了。
   */
  private bluetoothLyricHint(): string {
    return '把正在唱的这一句交给系统蓝牙模块，由它下发给已连接的蓝牙设备（车机、蓝牙音箱）显示。'
      + '手机这边的播控中心不受影响：歌名、滚动歌词各有各的字段。'
      + '能不能显示取决于车机或音箱本身是否支持（车机端通常还要打开「歌词显示」）；'
      + '每换一句都会重推一次蓝牙媒体信息，不在车里时建议关掉，以免影响车机播放的流畅度。';
  }

  /**
   * 「被打断结束后自动重新播放」的说明
   *
   * 要讲两件事：这一项在什么场景下管用（来电 / 闹铃 / 别的应用出声），以及它和上面那项
   * 「与其他应用同时播放」的关系 —— 同时播放走的是混音会话，别的声音压不住我们，
   * 自然不会收到打断；收不到打断，这一项也就用不上。
   * 不说清就会出现「开关拨了没反应」的困惑（与桌面歌词那一项的处理一致）。
   */
  private autoResumeHint(): string {
    const base: string = '被来电、闹铃或别的应用的声音打断时，系统会把我们暂停；这一项开着，'
      + '打断结束（挂断、闹铃停）就自动接着放，关掉则停在暂停、等你自己按播放。';
    if (this.playWithOthers) {
      return base + '「与其他应用同时播放」开着时走的是混音，别的声音一般不打断我们，这一项多半用不上。';
    }
    return base;
  }

  /**
   * 摘下耳机自动暂停的说明
   *
   * 要讲清三件事：谁触发（拔有线 / 断蓝牙 / 拔 USB）、是暂停而不是静音、
   * 以及「本来就没耳机」时不会有副作用 —— 否则用户会担心外放时被误暂停。
   */
  private autoPauseHeadsetOffHint(): string {
    return '拔掉有线耳机、断开蓝牙耳机或拔掉 USB 耳机时自动暂停（否则声音会突然改从外放出来）。'
      + '只是暂停，点播放就能接着听；本来就没插耳机时不生效。';
  }

  build() {
    Column() {
      Scroll() {
        /**
         * 卡片的排布用 Flex 而不是 Column：**宽屏并排、窄屏一列**
         *
         * 窄屏是 `direction: Column` + 不换行 + main 间距 14，与原来的 `Column({ space: 14 })`
         * 逐像素一样；宽屏换成 `Row` + 换行，每张卡 48% 宽（见 ui/Layout.ets 的 cardWidthOf），
         * 自动一行两张。每张「卡 + 它下面那行说明」包在一个 Column 里当**一个单元**：
         * 说明文字本身就是铺满宽度的，不包起来的话它会把换行打断，两张卡就并不到一排去。
         */
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 两张卡高度差得远（音质那张四行、歌词那张十几行），居中的话短卡会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')

          // ------------------------------------------------ 渠道（默认渠道：没有渠道选择项的页面先走它）
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              OptionSetting({
                label: '默认渠道',
                options: DEFAULT_SOURCE_LABELS,
                activeIndex: this.defaultSourceIndex(),
                onPick: (index: number) => {
                  PlaySettings.getInstance().setDefaultSource(DEFAULT_SOURCE_VALUES[index]);
                },
              })
              HintText({
                text: '「自动」= 不指定，仍按内容原本的来源平台走。选定一个平台后，'
                  + '所有没有渠道选择项的页面都先从这个平台取数：点歌手名进的歌手页优先在这个平台'
                  + '认人、取该歌手的歌，本地与云端音乐自动匹配歌词也先在这个平台搜；'
                  + '这个平台没有对应内容时，再按原来的顺序回退，不会因为选了它就打不开。',
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '只影响这些没有渠道选择项的地方。首页标题栏的「推荐来源」胶囊、'
                + '搜索页的平台筛选各管各的，不受这一项影响。',
            })
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 音质（卡 + 说明是一个单元）
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              OptionSetting({
                label: '播放音质',
                options: MAIN_QUALITY_LABELS,
                activeIndex: this.qualityIndex(),
                onPick: (index: number) => {
                  PlaySettings.getInstance().setQuality(MAIN_QUALITYS[index]);
                },
              })

              ExtendQualitySetting({
                label: '拓展音质',
                on: this.extend,
                options: EXTEND_QUALITY_LABELS,
                activeIndex: this.extendIndex(),
                note: '需要登录并有会员才能用：网易云先到「设置 - 登录音乐」登录会员账号；'
                  + '平台不提供这一档、或当前音源没声明支持时，会自动退回「播放音质」里选的那档。',
                hint: '这几档多数平台要会员，且要有支持它的音源；拿不到时自动退回「播放音质」里选的那档。',
                onToggle: (next: boolean) => {
                  PlaySettings.getInstance().setExtendQuality(next);
                  if (next) {
                    this.toast(`已开启拓展音质：优先「${EXTEND_QUALITY_LABELS[this.extendIndex()]}」，`
                      + '平台或音源拿不到时自动退回普通音质');
                  }
                },
                onPickOption: (index: number) => {
                  PlaySettings.getInstance().setExtendQualityType(EXTEND_QUALITYS[index]);
                },
              })

              // 目标档与「实际生效档」不一致时的一句实情（见 actualQualityHint）：
              // 设置项本身照旧显示用户选的那档，这里只补事实，不替用户改设置
              if (this.actualQualityHint().length > 0) {
                HintText({ text: this.actualQualityHint() })
              }

              ToggleSetting({
                label: '与其他应用同时播放',
                value: this.playWithOthers,
                onPick: (next: boolean) => {
                  // 走会话：既改设置，也立刻作用到正在播的播放器
                  PlaySession.getInstance().setPlayWithOthers(next);
                },
              })

              ToggleSetting({
                label: '被其他应用打断结束后自动重新播放',
                value: this.autoResume,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setAutoResumeAfterInterrupt(next);
                },
              })
              HintText({ text: this.autoResumeHint() })

              ToggleSetting({
                label: '摘下耳机自动暂停',
                value: this.autoPauseHeadsetOff,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setAutoPauseHeadsetOff(next);
                },
              })
              HintText({ text: this.autoPauseHeadsetOffHint() })

              /**
               * 放不出来时自动换别的平台的同名歌（默认关，见 PlaySettings.K_SWITCH_PLATFORM_SAME_SONG）
               *
               * 放在这张卡里是因为它和上面几项一样都管「真放不出来时怎么办」。
               * 与「音源设置 - 自动切换音源」分工不同：那一项换的是同一平台的不同音源脚本。
               */
              ToggleSetting({
                label: '放不出来时自动切换其他平台的同名音乐',
                value: this.switchPlatformSameSong,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setSwitchPlatformSameSong(next);
                  if (next) {
                    this.toast('已开启：取不到播放地址时会去其他平台搜同名同歌手的歌');
                  }
                },
              })
              HintText({ text: this.switchPlatformSameSongHint() })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({ text: '播放音质是首选档：这首没有该档时会自动往下退，不会因为选高了就放不出来。' })
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 歌词（卡 + 说明是一个单元）
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              ToggleSetting({
                label: '播放页显示小歌词',
                value: this.showMiniLyric,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setShowMiniLyric(next);
                },
              })
              ToggleSetting({
                label: '歌词页模糊效果',
                value: this.lyricBlur,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setLyricBlur(next);
                },
              })
              ToggleSetting({
                label: '歌词居中显示',
                value: this.lyricCentered,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setLyricCentered(next);
                },
              })
              SliderSetting({
                label: '歌词字号',
                value: this.fontSize,
                min: LYRIC_FONT_MIN,
                max: LYRIC_FONT_MAX,
                onPick: (value: number, done: boolean) => {
                  PlaySettings.getInstance().setLyricFontSize(value, done);
                },
              })
              ToggleSetting({
                label: '歌词页不熄屏',
                value: this.keepScreen,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setLyricKeepScreenOn(next);
                },
              })
              ToggleSetting({
                label: '桌面歌词',
                value: this.desktopLyric,
                onPick: (next: boolean) => {
                  // 走会话：既改设置，也让播控服务立刻重算悬浮窗显隐
                  PlaySession.getInstance().setDesktopLyric(next);
                },
              })
              HintText({ text: this.desktopLyricHint() })
              ToggleSetting({
                label: '车载蓝牙歌词',
                value: this.bluetoothLyric,
                onPick: (next: boolean) => {
                  // 走会话：既改设置，也让播控服务立刻重推（打开当句就上去，关闭立刻清掉）
                  PlaySession.getInstance().setBluetoothLyric(next);
                },
              })
              HintText({ text: this.bluetoothLyricHint() })
              ToggleSetting({
                label: '本地 / 云端自动匹配歌词',
                value: this.autoMatchLyric,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setAutoMatchLyric(next);
                },
              })
              HintText({
                text: '本地歌与云端歌（WebDAV）都没有平台身份，只能拿歌名与歌手去平台上搜一首'
                  + '对应的歌再取词（要联网，每首歌只搜一次）。匹配没把握时宁可不显示 —— '
                  + '配错的歌词比没有歌词更糟；这时可以在播放页的「更多 - 匹配歌词」里自己搜一次、'
                  + '选正确的那条。同目录下的同名 .lrc 会一起导入 / 取回，优先用它，不联网也不会配错。',
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '「歌词页模糊效果」关掉后歌词页用纯深色底（封面页不受影响）；'
                + '「歌词页不熄屏」只在全屏播放器停在歌词页时生效。',
            })
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 播放页（卡 + 说明是一个单元）
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              /**
               * 三档用分段胶囊而不是开关：见上面 motionHint 的说明。
               * 选中态只由 `motionIndex()` 决定（读 AppStorage 里的档位），
               * 组件自己不存「当前选中」—— 点一下设置没落下去时药丸不会骗人。
               */
              OptionSetting({
                label: '播放页动效',
                options: PLAYER_MOTION_LABELS,
                activeIndex: this.motionIndex(),
                hint: this.motionHint(),
                onPick: (index: number) => {
                  PlaySettings.getInstance().setPlayerMotionLevel(PLAYER_MOTION_LEVELS[index]);
                },
              })

              /**
               * 上下滑动切歌：默认关（见 PlaySettings.K_SWIPE_SWITCH_SONG）
               *
               * 放在「播放页」这一张卡里，因为它与上面那项一样只管播放页的交互。
               * 它和「播放页动效」互不影响：关掉动效也照样能滑。
               */
              ToggleSetting({
                label: '上下滑动切歌',
                value: this.swipeSwitchSong,
                onPick: (next: boolean) => {
                  PlaySettings.getInstance().setSwipeSwitchSong(next);
                  if (next) {
                    this.toast('已开启上下滑动切歌：播放页上滑下一首、下滑上一首');
                  }
                },
              })
              HintText({ text: this.swipeSwitchSongHint() })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '三档共用同一条开关条件：只有「正在播放 + 应用在前台 + 播放页可见 + 没选关闭」'
                + '同时成立才有动画。暂停、收起播放页、退到后台、切歌加载时立刻停；'
                + '切歌是先停旧再起新，不会两份叠着跑。',
            })
          }
          .width(cardWidthOf(this.windowWidth))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
