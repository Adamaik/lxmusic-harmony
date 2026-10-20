import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { HintText, OptionSetting, SliderSetting, ToggleSetting } from '../ui/SettingWidgets';
import { hdsEffectSupported, hdsMaterialType, isEmulatorDevice, MATERIAL_LEVEL_LABELS } from '../ui/Hds';
import { harmony7ApiReady, isGlassMaterialSupported } from '../ui/Glass';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { AppearanceSettings, COLOR_MODE_LABELS, COVER_RADIUS_DEFAULT, COVER_RADIUS_MAX,
  COVER_RADIUS_MIN, K_COLOR_MODE, K_COVER_RADIUS, K_MATERIAL_LEVEL, K_NAV_FOLLOW_HAND }
  from '../core/settings/AppearanceSettings';

/**
 * 外观设置（设置 - 外观）
 *
 * 五组：
 *   一、深浅模式：跟随系统 / 浅色 / 深色 —— 界面颜色都是 base / dark 同名资源，
 *      这一档改的是应用级 colorMode（见 core/settings/AppearanceSettings.ets）；
 *   二、玻璃材质档位：跟随系统 / 弱 / 均衡 / 强 —— 标题栏、底部页签栏、半模态三处共用；
 *   三、圆角：播放页封面圆角；
 *   四、底部导航栏左右跟手：开着时迷你播放器展开、页签栏折叠成的那颗球按握持手换边；
 *   五、底部把 HDS 能力的实际生效情况摊开（能力位 / 材质类型 / 是否模拟器），
 *      效果对不上时先看这一行，不用猜。
 *
 * 之前设置页里的「主题」是一个死入口：点进去提示「该功能暂未接入」。外观相关的
 * 选择全都在这里，改完立即生效并落盘（AppearanceSettings，沙箱 JSON + AppStorage）。
 */
@Component
export struct AppearanceSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /** 材质档位：0 跟随系统 / 1 弱 / 2 均衡 / 3 强 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /** 播放页封面圆角 */
  @StorageLink(K_COVER_RADIUS) coverRadius: number = COVER_RADIUS_DEFAULT;
  /** 深浅模式：0 跟随系统 / 1 浅色 / 2 深色 */
  @StorageLink(K_COLOR_MODE) colorMode: number = 0;
  /** 底部导航栏左右跟手（开 / 关），见 core/settings/AppearanceSettings.ets */
  @StorageLink(K_NAV_FOLLOW_HAND) followHand: boolean = true;
  /**
   * 窗口宽度（vp）：宽屏下这几张卡并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  /** 「跟随系统」时才说明这一档的实际含义：选了浅色 / 深色就是钉死的 */
  private colorModeHint(): string {
    if (this.colorMode === 0) {
      return '跟随系统：手机切到深色模式，界面跟着变。'
        + '界面上所有颜色都是 base / dark 两份同名资源（resources 下 base / dark 两份同名 color.json），'
        + '不跟随的话在深色系统里会出现白卡片配浅字这类看不清的问题。';
    }
    return '这一档会覆盖系统设置：无论手机是什么模式，应用都用这一档的深浅。';
  }

  /** 这一行是给「效果对不上」时看的：系统版本、能力位、材质类型、模拟器都要摆出来 */
  private capabilityText(): string {
    const device: string = isEmulatorDevice() ? '模拟器' : '真机';
    const effect: string = hdsEffectSupported() ? '已挂载' : '当前设备无此能力位';
    // 三档要说清楚，别把「系统版本不够」和「设备没能力位」混成一句「不支持」：
    // 前者是鸿蒙6（API 23），整条材质路径都不存在，走的是 HDS 轮廓点光；后者是鸿蒙7。
    const glass: string = isGlassMaterialSupported()
      ? '系统材质'
      : (harmony7ApiReady() ? '设备无材质能力位，用点光兜底' : '鸿蒙7 以下，材质不可用，用点光兜底');
    return `HDS 能力位：${effect}　材质类型：${hdsMaterialType()}（玻璃：${glass}，${device}）`;
  }

  /**
   * 左右跟手那行提示
   *
   * 这一项管的是「整条悬浮栏贴屏幕哪一侧」，**不是**「栏里谁在左谁在右」—— 真机上验证过：
   * 开着它、换手时，折叠成的那颗球不会从组的左端跑到右端（组的内部次序「页签栏在左、
   * 迷你栏在右」是 HDS 固定的，官方没给换的接口）。所以提示里把「能做什么 / 不能做什么 /
   * 哪种窗口下才看得出来」三件事都写清楚，免得照着「球会换边」去试、试不出来以为坏了。
   */
  private followHandHint(): string {
    if (!this.followHand) {
      return '关着：悬浮栏恒定居中，不看握姿（HDS / ArkUI 的默认行为）。';
    }
    return '开着：悬浮栏不再恒定居中，而是贴到握持手那一侧 —— 右手握持贴右、左手握持贴左，'
      + '让拇指够得着。'
      + '只在**栏比窗口窄**时才看得出来：折叠屏展开态、平板、横屏下两条栏只占一部分宽度，'
      + '差别很明显；手机竖屏两条栏本来就铺满，看不出变化。'
      + '底部主页那条（页签栏 + 迷你栏）与歌单详情 / 在线详情 / 四个面板页那条播放条都跟这一档。'
      + '注意：它不动页签的次序，也不会把折叠成的那颗球从组的左端挪到右端。';
  }

  private materialHint(): string {
    if (!harmony7ApiReady()) {
      return '当前系统低于鸿蒙7（API 26），沉浸式系统材质这条接口在本机根本不存在，'
        + '所以这一档不生效：悬浮控件的玻璃走自绘（模糊 + 半透明白 + 亮边），'
        + '边沿那圈光改由 HDS 的轮廓点光出（普通光效）。升级到鸿蒙7 后会自动切回系统材质。';
    }
    if (!isGlassMaterialSupported()) {
      return '当前设备没有沉浸光感材质，这一档不影响自绘的毛玻璃层（那几层走的是模糊 + 半透明白兜底）。';
    }
    return '档位越高，系统材质的折射与提亮越强。「跟随系统」交给系统按温度/电量策略决定，'
      + '机型之间差别较大（有的会把玻璃压得很淡，看上去像没生效）——这时手工选一档「均衡」或「强」。';
  }

  build() {
    Column() {
      Scroll() {
        /**
         * 卡片的排布用 Flex 而不是 Column：**宽屏并排、窄屏一列**
         *
         * 窄屏是 `direction: Column` + 不换行 + main 间距 14，与原来的 `Column({ space: 14 })`
         * 逐像素一样；宽屏换成 `Row` + 换行，每张卡 48% 宽（见 ui/Layout.ets 的 cardWidthOf），
         * 自动一行两张。这一页每张卡的说明文字都在卡里面，所以不必再包一层单元。
         */
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 三张卡高矮差得多（圆角那张六行、深浅模式两行），居中的话短的会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')
          // ------------------------------------------------ 深浅模式
          Column({ space: 8 }) {
            OptionSetting({
              label: '深浅模式',
              options: COLOR_MODE_LABELS,
              activeIndex: this.colorMode,
              onPick: (index: number) => {
                AppearanceSettings.getInstance().setColorMode(index, this.getUIContext()
                  .getHostContext() as common.Context);
              },
            })
            HintText({ text: this.colorModeHint() })
          }
          .width(cardWidthOf(this.windowWidth))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          // ------------------------------------------------ 玻璃材质
          Column({ space: 8 }) {
            OptionSetting({
              label: '玻璃材质档位',
              options: MATERIAL_LEVEL_LABELS,
              activeIndex: this.materialLevel,
              onPick: (index: number) => {
                AppearanceSettings.getInstance().setMaterialLevel(index);
              },
            })
            HintText({ text: this.materialHint() })
          }
          .width(cardWidthOf(this.windowWidth))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          // ------------------------------------------------ 圆角
          Column({ space: 8 }) {
            // 封面圆角：拖动实时变（播放页封面跟着走），松手才落盘
            SliderSetting({
              label: '播放页封面圆角',
              value: this.coverRadius,
              min: COVER_RADIUS_MIN,
              max: COVER_RADIUS_MAX,
              onPick: (value: number, done: boolean) => {
                AppearanceSettings.getInstance().setCoverRadius(value, done);
              },
            })
            HintText({
              text: '0 是直角，40 接近圆形。播放页的大封面与小歌词下面的小封面共用这一个值，'
                + '列表里的封面不受影响（那是列表自己的排版）。',
            })
          }
          .width(cardWidthOf(this.windowWidth))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          // ------------------------------------------------ 底部导航栏左右跟手
          Column({ space: 8 }) {
            ToggleSetting({
              label: '悬浮栏左右跟手',
              value: this.followHand,
              onPick: (next: boolean) => {
                AppearanceSettings.getInstance().setFollowHand(next);
              },
            })
            HintText({ text: this.followHandHint() })
          }
          .width(cardWidthOf(this.windowWidth))
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          // ------------------------------------------------ 能力诊断
          HintText({ text: this.capabilityText() })
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
