import { uiMaterial } from '@kit.ArkUI';
import { hdsGlassOutline } from './Hds';
import { C_GLASS_EDGE } from './Theme';

/**
 * 华为「沉浸式材质」玻璃效果
 *
 * 先说清楚平台限制（官方《开启沉浸光感》）：沉浸式系统材质
 * （uiMaterial 的 ImmersiveMaterial，API 26 / HarmonyOS 6）对**普通组件**
 * 只在这些区域生效：
 *   - Navigation / NavDestination 的标题栏
 *   - 横向 Tabs 中 barPosition 为 BarPosition.End 的底部 TabBar
 *   - 弹窗类组件（Popup / Menu / BindSheet / Toast / Dialog 等）
 * 在页面内容区里给普通 Row/Column 设 systemMaterial 是**不渲染的**（画出来是空的）。
 *
 * 所以这里的策略是：
 *   1) 能吃到系统材质的地方交给 HDS —— 底部页签栏/迷你栏走
 *      HdsTabsFloatingStyle.systemMaterialEffect，半模态走 sheet 的 systemMaterial 字段，
 *      标题栏走 TitleBarStyleOptions.systemMaterialEffect。这些是真正的系统玻璃。
 *   2) 页面内容区里自绘的玻璃层（圆钮、歌曲行、筛选胶囊、提示条、页面内迷你播放条）
 *      自己画一层磨砂：毛玻璃模糊 + 半透明白 + 系统玻璃描边色 + 轻阴影。
 *
 * 为什么自绘层不用系统玻璃色（sys.color.glass_material_mask_primary）当底：
 * 那个色值是 #0C808080 —— 只有 5% 不透明度（深色模式甚至全透明），系统那条玻璃栏
 * 之所以看着是「玻璃」，靠的是材质滤镜本体的折射与提亮，而滤镜在内容区不可用。
 * 单用这个色打底等于什么都没画。所以这里用半透明白 + 模糊来还原同样的观感，
 * 描边仍然用系统的 sys.color.glass_material_outline_primary，跟系统同源。
 *
 * 另外：别在同一节点上叠不透明底色，不透明色会把毛玻璃完全盖住，看着就是一块死白。
 */

export const GLASS_THIN: number = 0;
export const GLASS_REGULAR: number = 1;

/** 没显式给色调时的默认磨砂底（必须半透明，留住模糊的通透感） */
const TINT_THIN: string = 'rgba(255, 255, 255, 0.62)';
const TINT_REGULAR: string = 'rgba(255, 255, 255, 0.74)';
const TINT_DARK: string = 'rgba(22, 22, 24, 0.58)';

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

/** 当前设备是否支持沉浸式材质（供设置页展示，便于排查效果差异） */
export function isGlassMaterialSupported(): boolean {
  probe();
  return supported;
}

/** 玻璃配方：一个 AttributeModifier 让所有玻璃层共用同一套参数 */
export class GlassModifier implements AttributeModifier<CommonAttribute> {
  private radius: number = 20;
  private dark: boolean = false;
  private tint: string = '';
  private thin: boolean = true;
  private shadowRadius: number = 22;
  private blurStyle: BlurStyle = BlurStyle.COMPONENT_ULTRA_THICK;

  constructor(radius: number, thin: boolean, dark: boolean, tint: string) {
    this.radius = radius;
    this.thin = thin;
    this.dark = dark;
    this.tint = tint;
  }

  withShadow(radius: number): GlassModifier {
    this.shadowRadius = radius;
    return this;
  }

  withBlur(style: BlurStyle): GlassModifier {
    this.blurStyle = style;
    return this;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance.borderRadius(this.radius);
    // 毛玻璃：透过来的内容做模糊（通透感主要靠这一层）
    instance.backgroundBlurStyle(this.blurStyle);

    // 磨砂底：显式给了色调就用它（必须半透明），否则按薄/常规/深色给默认值
    const mask: ResourceColor = this.tint.length > 0
      ? this.tint
      : (this.dark ? TINT_DARK : (this.thin ? TINT_THIN : TINT_REGULAR));
    instance.backgroundColor(mask);

    // 描边：系统的玻璃描边色，取不到时退回自绘高光边
    instance.borderWidth(0.5);
    let edge: ResourceColor = C_GLASS_EDGE;
    try {
      edge = hdsGlassOutline();
    } catch (e) {
      edge = C_GLASS_EDGE;
    }
    instance.borderColor(edge);

    // 薄玻璃（悬浮层）影子轻一点，常规玻璃重一点
    instance.shadow({
      radius: this.thin ? this.shadowRadius : this.shadowRadius + 8,
      color: this.dark ? '#33000000' : '#14000000',
      offsetX: 0,
      offsetY: 8,
    });
  }
}

/** 便捷构造：悬浮导航胶囊 / 迷你播放器这类最透的一层 */
export function thinGlass(radius: number, dark: boolean = false, tint: string = ''): GlassModifier {
  return new GlassModifier(radius, true, dark, tint);
}

/** 便捷构造：卡片 / 弹层这类中等厚度的一层 */
export function regularGlass(radius: number, dark: boolean = false, tint: string = ''): GlassModifier {
  return new GlassModifier(radius, false, dark, tint);
}
