import { C_BG, C_CARD, C_RED, R_CARD } from '../ui/Theme';
import { HintText, OptionSetting, SettingLabel, ToggleSetting } from '../ui/SettingWidgets';
import { hdsEffectSupported, hdsMaterialType, isEmulatorDevice, MATERIAL_LEVEL_LABELS } from '../ui/Hds';
import { isGlassMaterialSupported } from '../ui/Glass';
import { AppearanceSettings, COVER_RADIUS_DEFAULT, COVER_RADIUS_MAX, COVER_RADIUS_MIN,
  K_COVER_RADIUS, K_FLOW_LIGHT, K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';

/**
 * 外观设置（设置 - 外观）
 *
 * 三组：
 *   一、玻璃材质档位：跟随系统 / 弱 / 均衡 / 强 —— 标题栏、底部页签栏、半模态三处共用；
 *   二、光效与圆角：首页流光（HDS 背景流光）、播放页封面圆角；
 *   三、底部把 HDS 能力的实际生效情况摊开（能力位 / 材质类型 / 是否模拟器），
 *      效果对不上时先看这一行，不用猜。
 *
 * 深浅模式没有放进来：那要先把全部颜色迁到资源（base / dark 同名 token），
 * 现在自绘界面用的是 Theme.ets 里的常量，只切系统模式会出现「浅色界面 + 深色系统栏」
 * 的四不像。宁可先不给这个开关，也不给一个点着没用的。
 *
 * 之前设置页里的「主题」是一个死入口：点进去提示「该功能暂未接入」。外观相关的
 * 选择全都在这里，改完立即生效并落盘（AppearanceSettings，沙箱 JSON + AppStorage）。
 */
@Component
export struct AppearanceSettingsView {
  @Prop bottomInset: number = 0;
  /** 材质档位：0 跟随系统 / 1 弱 / 2 均衡 / 3 强 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /** 首页流光 */
  @StorageLink(K_FLOW_LIGHT) flowLight: boolean = true;
  /** 播放页封面圆角 */
  @StorageLink(K_COVER_RADIUS) coverRadius: number = COVER_RADIUS_DEFAULT;

  /** 这一行是给「效果对不上」时看的：能力位、材质类型、模拟器都要摆出来 */
  private capabilityText(): string {
    const device: string = isEmulatorDevice() ? '模拟器' : '真机';
    const effect: string = hdsEffectSupported() ? '已挂载' : '当前设备无此能力位';
    const glass: string = isGlassMaterialSupported() ? '系统材质可用' : '毛玻璃兜底';
    return `HDS 能力位：${effect}　材质类型：${hdsMaterialType()}（玻璃：${glass}，${device}）`;
  }

  private materialHint(): string {
    if (!isGlassMaterialSupported()) {
      return '当前设备没有沉浸光感材质，这一档不影响自绘的毛玻璃层（那几层走的是模糊 + 半透明白兜底）。';
    }
    return '档位越高，系统材质的折射与提亮越强。「跟随系统」交给系统按温度/电量策略决定，'
      + '机型之间差别较大（有的会把玻璃压得很淡，看上去像没生效）——这时手工选一档「均衡」或「强」。';
  }

  private flowLightHint(): string {
    const base: string = '首页底色之上、内容之下铺一层 HDS 着色器流光（10 秒一圈，无限循环，'
      + '半透明），慢速扫过所以不抢文字。关掉就不挂这一层，省一份着色器开销。';
    if (!hdsEffectSupported()) {
      return base + '当前设备没有 HDS 能力位，开关不会有实际效果。';
    }
    if (isEmulatorDevice()) {
      return base + '注意：官方文档写明模拟器不支持 HDS 沉浸视效（点光源、按压阴影、'
        + '双边边缘流光、背景流光、沉浸光感材质），所以模拟器上看不到这层光是正常的，真机上会出来。';
    }
    return base;
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          // ------------------------------------------------ 玻璃材质
          Column({ space: 17 }) {
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
          .width('100%')
          .padding({ left: 16, right: 16, top: 17, bottom: 17 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          // ------------------------------------------------ 光效
          Column({ space: 17 }) {
            ToggleSetting({
              label: '首页流光',
              value: this.flowLight,
              onPick: (next: boolean) => {
                AppearanceSettings.getInstance().setFlowLight(next);
              },
            })
            HintText({ text: this.flowLightHint() })

            // 封面圆角：拖动实时变（播放页封面跟着走），松手才落盘
            Column({ space: 4 }) {
              SettingLabel({ label: '播放页封面圆角', value: `${this.coverRadius}` })
              Slider({
                value: this.coverRadius,
                min: COVER_RADIUS_MIN,
                max: COVER_RADIUS_MAX,
                step: 1,
                style: SliderStyle.OutSet,
              })
                .trackThickness(3)
                .blockSize({ width: 18, height: 18 })
                .blockColor(Color.White)
                .selectedColor(C_RED)
                .trackColor('#E4E4E8')
                .width('100%')
                .onChange((value: number, mode: SliderChangeMode) => {
                  const done: boolean = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
                  AppearanceSettings.getInstance().setCoverRadius(value, done);
                })
            }
            .width('100%')
            HintText({
              text: '0 是直角，40 接近圆形。播放页的大封面与小歌词下面的小封面共用这一个值，'
                + '列表里的封面不受影响（那是列表自己的排版）。',
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 17, bottom: 17 })
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
