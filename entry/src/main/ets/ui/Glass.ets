import { uiMaterial } from '@kit.ArkUI';
import { buildGlassBlur, clampMaterialLevel } from './Hds';
import { C_RED } from './Theme';

/**
 * 华为「沉浸式材质」玻璃效果
 *
 * 一句话：悬浮控件要的是**系统材质**（`.systemMaterial()` + `uiMaterial.ImmersiveMaterial`），
 * 底部导航栏那种「流光溢彩」的玻璃就是它画的 —— 折射、随底下内容提亮、按压形变、
 * 光感反馈都在材质滤镜里，手画不出来。`systemMaterial` 是 API 26 起的**通用属性**，
 * 任何组件都能挂（不是只能用在标题栏 / 底部 TabBar / 弹窗上，那是早先版本的限制）。
 *
 * 所以这里的配方是两层：
 *   1) **真材质**（首选）：`ImmersiveMaterial({ style, interactive, lightEffect, applyShadow })`。
 *      `interactive: true` 是按压形变反馈，`lightEffect` 是光感交互反馈（动感光效的来源），
 *      `style` 是厚度（跟随外观设置里的档位，见 immersiveStyleOf）。
 *   2) **自绘兜底**：毛玻璃模糊 + 半透明白底 + 1vp 亮边 + 轻阴影。
 *      只在设备不支持沉浸材质时才是唯一的一层；支持时它仍然先画上去，
 *      因为材质生效会接管底色 / 描边 / 阴影 —— 万一某个机型上材质在内容区不渲染，
 *      控件不至于变成一片透明（宁可退化，不能消失）。
 *
 * 为什么兜底层不用系统玻璃色（sys.color.glass_material_mask_primary）当底：
 * 那个色值是 #0C808080 —— 只有 5% 不透明度（深色模式甚至全透明），系统那条玻璃栏
 * 之所以看着是「玻璃」，靠的是材质滤镜本体的折射与提亮。单用这个色打底等于什么都没画。
 * 所以兜底层用半透明白 + 模糊，描边仍取系统的 sys.color.glass_material_outline_primary。
 *
 * 另外：别在同一节点上叠不透明底色 —— 那会把材质与模糊一起盖掉，看着就是一块死白。
 */

export const GLASS_THIN: number = 0;
export const GLASS_REGULAR: number = 1;

/**
 * 悬浮控件那一族的取值：**照抄派音的配方**
 *
 * 它顶栏那颗圆钮就这三个属性 —— 10% 白底、纯白 1vp 描边、没有阴影、没有光效
 * （见它的 `HomeTopBar.ets` + `home_icon_button_background/border` 两个资源色）。
 * 玻璃感来自「透出背后的内容」这一件事：底子给得越淡，背后的东西透得越多，越像玻璃；
 * 加阴影、加高光边、把底调厚，反而会变成一块实心白牌子 —— 这就是之前「粗糙」的来源。
 */
const FLOAT_FILL: string = '#1AFFFFFF';
const FLOAT_FILL_DARK: string = '#19FFFFFF';
/** 描边：亮色下纯白，暗色下 40% 白（同样来自派音的 dark 资源色） */
const EDGE_HIGHLIGHT: string = '#FFFFFF';
const EDGE_HIGHLIGHT_DARK: string = '#66FFFFFF';

/** 没显式给色调时的默认磨砂底（必须半透明，留住模糊与材质的通透感） */
const TINT_REGULAR: string = 'rgba(255, 255, 255, 0.74)';

let probed: boolean = false;
let supported: boolean = false;

function probe(): void {
  if (probed) {
    return;
  }
  probed = true;
  try {
    supported = uiMaterial.isImmersiveMaterialSupported();
  } catch (e) {
    supported = false;
  }
}

/** 当前设备是否支持沉浸式材质（供设置页展示，也决定走真材质还是纯自绘） */
export function isGlassMaterialSupported(): boolean {
  probe();
  return supported;
}

/**
 * 档位 -> 系统材质的厚度
 *
 * 1 弱 / 2 均衡 / 3 强 直接对应 THIN / REGULAR / ULTRA_THICK；
 * 「跟随系统」问系统自己的材质档位（`getGlobalMaterialLevel`）再折算，
 * 这样自绘控件和系统应用的玻璃厚度是一致的。
 */
export function immersiveStyleOf(level: number): uiMaterial.ImmersiveStyle {
  switch (clampMaterialLevel(level)) {
    case 1:
      return uiMaterial.ImmersiveStyle.THIN;
    case 2:
      return uiMaterial.ImmersiveStyle.REGULAR;
    case 3:
      return uiMaterial.ImmersiveStyle.ULTRA_THICK;
    default:
      try {
        const global: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
        if (global === uiMaterial.MaterialLevel.EXQUISITE) {
          return uiMaterial.ImmersiveStyle.ULTRA_THICK;
        }
        if (global === uiMaterial.MaterialLevel.GENTLE) {
          return uiMaterial.ImmersiveStyle.THICK;
        }
      } catch (e) {
        // 取不到就按 REGULAR
      }
      return uiMaterial.ImmersiveStyle.REGULAR;
  }
}

/**
 * 取一个系统沉浸材质对象（给组件在 build 里直接 `.systemMaterial(...)` 用）
 *
 * 为什么不放在 `GlassModifier.applyNormalAttribute` 里：官方对 visualEffect 明确写过
 * 「API 20 起才允许在 attributeModifier 里调用」，属性修改器里能调哪些接口是有讲究的；
 * 材质这种新接口直接挂在组件上更稳（挂不上也看得见 —— 就是没效果）。
 *
 * 设备没有材质能力位时返回 `undefined`：`systemMaterial` 的参数本来就允许 undefined，
 * 等于不设材质，界面回落到自绘那层玻璃。
 */
export function immersiveMaterialFor(level: number): uiMaterial.Material | undefined {
  if (!isGlassMaterialSupported()) {
    return undefined;
  }
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: immersiveStyleOf(level),
      interactive: true,
      lightEffect: { color: C_RED },
      applyShadow: true,
    });
  } catch (e) {
    return undefined;
  }
}

/** 玻璃配方：一个 AttributeModifier 让所有玻璃层共用同一套参数 */
export class GlassModifier implements AttributeModifier<CommonAttribute> {
  private radius: number = 20;
  private dark: boolean = false;
  private tint: string = '';
  private thin: boolean = true;
  /** 阴影半径，0 = 不画阴影（默认不画，与派音一致） */
  private shadowRadius: number = 0;
  private blurStyle: BlurStyle = BlurStyle.COMPONENT_THICK;
  /** 是否被 withBlur 显式指定过厚度（显式指定后就不再按档位换算） */
  private blurFixed: boolean = false;

  constructor(radius: number, thin: boolean, dark: boolean, tint: string, level: number = 0) {
    this.radius = radius;
    this.thin = thin;
    this.dark = dark;
    this.tint = tint;
    this.blurStyle = buildGlassBlur(level);
  }

  withShadow(radius: number): GlassModifier {
    this.shadowRadius = radius;
    return this;
  }

  withBlur(style: BlurStyle): GlassModifier {
    this.blurStyle = style;
    this.blurFixed = true;
    return this;
  }

  /**
   * 换一个档位重新出玻璃（外观设置里改了档位就调它）。
   *
   * 档位是响应式的：宿主组件用 @StorageLink 订阅 K_MATERIAL_LEVEL，在 build 里
   * 按当前值取玻璃，改档位时所有玻璃层一起变厚变薄 —— 与派音
   * 「一个 AmbientState 驱动全应用玻璃厚度」是同一个做法。
   */
  withLevel(level: number): GlassModifier {
    if (!this.blurFixed) {
      this.blurStyle = buildGlassBlur(level);
    }
    return this;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance.borderRadius(this.radius);
    // 毛玻璃：透过来的内容做模糊（材质不可用时通透感主要靠这一层）
    instance.backgroundBlurStyle(this.blurStyle);

    // 底：显式给了色调就用它（必须半透明），否则用派音那档极淡的白
    const mask: ResourceColor = this.tint.length > 0
      ? this.tint
      : (this.dark ? FLOAT_FILL_DARK : (this.thin ? FLOAT_FILL : TINT_REGULAR));
    instance.backgroundColor(mask);

    // 描边：系统的玻璃描边色（取不到时退回自绘高光边），1vp ——
    // 玻璃层「看着有厚度」靠的就是这条亮边，0.5vp 在浅色底上基本看不出来
    instance.borderWidth(1);
    instance.borderColor(this.dark ? EDGE_HIGHLIGHT_DARK : EDGE_HIGHLIGHT);

    // 阴影默认不画（派音全项目没有一处阴影配方）。需要「浮起来」的层自己 on：
    // thinGlass(...).withShadow(24)
    if (this.shadowRadius > 0) {
      instance.shadow({
        radius: this.shadowRadius,
        color: this.dark ? '#3D000000' : '#1F000000',
        offsetX: 0,
        offsetY: 10,
      });
    }

    /**
     * 真材质：与底部导航栏同一套系统材质引擎。
     *
     * 材质生效时会接管底色 / 描边 / 阴影（官方说明：本接口会影响 backgroundColor、
     * borderColor、borderWidth、shadow），所以上面那几项在支持材质时是兜底不是叠加；
     * 万一内容区里材质不渲染，控件仍然是上面那层玻璃，不会变成一片透明。
     */
  }
}

/**
 * 便捷构造：悬浮导航胶囊 / 迷你播放器 / 圆钮这类最透的一层
 *
 * `level` 是外观设置里的玻璃材质档位（0 跟随系统 / 1 弱 / 2 均衡 / 3 强），
 * 决定模糊厚度；不传就按「跟随系统」那一档。
 */
export function thinGlass(radius: number, dark: boolean = false, tint: string = '',
  level: number = 0): GlassModifier {
  return new GlassModifier(radius, true, dark, tint, level);
}

/** 便捷构造：卡片 / 弹层这类中等厚度的一层 */
export function regularGlass(radius: number, dark: boolean = false, tint: string = '',
  level: number = 0): GlassModifier {
  return new GlassModifier(radius, false, dark, tint, level);
}
