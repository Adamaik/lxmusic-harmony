import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { HintText, OptionSetting, SliderSetting, ToggleSetting } from '../ui/SettingWidgets';
import { PlaySession } from '../core/player/PlaySession';
import { PlaybackService } from '../core/player/PlaybackService';
import { EXTEND_QUALITYS, EXTEND_QUALITY_LABELS, K_AUTO_MATCH_LYRIC, K_AUTO_RESUME_AFTER_INTERRUPT,
  K_BLUETOOTH_LYRIC, K_DESKTOP_LYRIC,
  K_EXTEND_QUALITY,
  K_EXTEND_QUALITY_TYPE,
  K_LYRIC_BLUR, K_LYRIC_CENTERED, K_LYRIC_FONT_SIZE, K_LYRIC_KEEP_SCREEN, K_PLAY_QUALITY, K_PLAY_WITH_OTHERS,
  K_SHOW_MINI_LYRIC, LYRIC_FONT_MAX, LYRIC_FONT_MIN, MAIN_QUALITYS, MAIN_QUALITY_LABELS,
  PlaySettings } from '../core/settings/PlaySettings';

/** 拓展音质：开关 +（开着时）档位 + 说明 */
@Component
struct ExtendQualitySetting {
  @Prop label: string = '';
  @Prop on: boolean = false;
  @Prop options: string[] = [];
  @Prop activeIndex: number = 0;
  @Prop hint: string = '';
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
 * 对应设置页里的「播放设置」，参考图上的分区：
 *   一、音质：播放音质（128K/320K/FLAC/24Bit）、拓展音质（开关 + Hi-Res/全景声/全景声+/母带）、
 *       与其他应用同时播放、被其他应用打断结束后自动重新播放
 *   二、歌词：播放页显示小歌词、歌词页模糊效果、歌词居中显示、歌词字号、歌词页不熄屏、
 *       桌面歌词、车载蓝牙歌词
 *
 * 参考图里还有一项「歌词帧率」，这里没做：本移植版没有逐帧渲染的动效（歌词靠
 * AVPlayer 的 timeUpdate 一秒一推、行间是 240ms 的补间），给一个帧率选项只是摆设。
 *
 * 所有项都写进 PlaySettings（沙箱 JSON + AppStorage），改完立即落盘，重启不丢。
 * 真机上生效的路径：
 *   - 播放音质 / 拓展音质 -> PlaySession.negotiateQuality 解析播放链接时按候选顺序取
 *   - 与其他应用同时播放 -> LxPlayer 建 AVPlayer 时设 audioInterruptMode
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
  @StorageLink(K_EXTEND_QUALITY) extend: boolean = false;
  @StorageLink(K_EXTEND_QUALITY_TYPE) extendType: string = 'hires';
  @StorageLink(K_PLAY_WITH_OTHERS) playWithOthers: boolean = false;
  @StorageLink(K_SHOW_MINI_LYRIC) showMiniLyric: boolean = false;
  @StorageLink(K_LYRIC_BLUR) lyricBlur: boolean = true;
  @StorageLink(K_LYRIC_CENTERED) lyricCentered: boolean = true;
  @StorageLink(K_LYRIC_FONT_SIZE) fontSize: number = 19;
  @StorageLink(K_LYRIC_KEEP_SCREEN) keepScreen: boolean = true;
  @StorageLink(K_DESKTOP_LYRIC) desktopLyric: boolean = true;
  /** 车载蓝牙歌词：往 AVMetadata.singleLyricText 写当前这一句，由系统蓝牙模块送给车机 */
  @StorageLink(K_BLUETOOTH_LYRIC) bluetoothLyric: boolean = false;
  /** 本地音乐 / 云端（WebDAV）音乐自动匹配歌词（要联网搜一次，所以给了开关） */
  @StorageLink(K_AUTO_MATCH_LYRIC) autoMatchLyric: boolean = true;
  /** 被打断（来电 / 闹铃 / 别的应用出声）结束后自动接着放 */
  @StorageLink(K_AUTO_RESUME_AFTER_INTERRUPT) autoResume: boolean = true;
  /** 系统是否支持桌面歌词：问过系统之前不下结论（见 desktopLyricHint） */
  @State lyricSupportKnown: boolean = false;
  @State lyricSupported: boolean = false;

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

  private extendIndex(): number {
    const index: number = EXTEND_QUALITYS.indexOf(this.extendType);
    return index < 0 ? 0 : index;
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
   * 「与其他应用同时播放」的关系 —— 同时播放走独立焦点，基本不会被我们这边的开关管到。
   * 不说清就会出现「开关拨了没反应」的困惑（与桌面歌词那一项的处理一致）。
   */
  private autoResumeHint(): string {
    const base: string = '被来电、闹铃或别的应用的声音打断时，系统会把我们暂停；这一项开着，'
      + '打断结束（挂断、闹铃停）就自动接着放，关掉则停在暂停、等你自己按播放。';
    if (this.playWithOthers) {
      return base + '「与其他应用同时播放」开着时走独立音频焦点模式，一般不会被打断，这一项多半用不上。';
    }
    return base;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')
          // ------------------------------------------------ 音质
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
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          HintText({ text: '播放音质是首选档：这首没有该档时会自动往下退，不会因为选高了就放不出来。' })

          // ------------------------------------------------ 歌词
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
