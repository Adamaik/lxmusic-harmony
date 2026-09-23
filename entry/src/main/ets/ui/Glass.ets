import { uiMaterial } from '@kit.ArkUI';
import { buildGlassBlur, clampMaterialLevel } from './Hds';
import { C_RED } from './Theme';

/**
 * 华为「沉浸式材质」玻璃效果
 *
 * 一句话：悬浮控件要的是**系统材质**（`.systemMaterial()` + `uiMaterial.ImmersiveMaterial`），
 * 底部导航栏那种「流光溢彩」的玻璃就是它画的 —— 折射、随底下内容提亮、按压形变、
 * 光感反馈都在材质滤镜里，手画不出来。
 *
 * **但它有生效范围（这是关键，别再记错）**：`systemMaterial` 虽然是 API 26 起的通用属性、
 * 任何组件都能挂，可官方「沉浸光感」的约束里写明 —— 除弹窗类组件 / 弹窗类接口 /
 * Slider、Toggle、Select 可在全页面生效外，**其他组件仅在 Navigation/NavDestination
 * 标题栏，或横向 Tabs 的底部 TabBar 中生效**；画在页面内容区里的普通组件设了也不生效，
 * 运行时会打印 `Material inactive: out of scope. Use component in navigation title bar
 * or Tabbar.`。所以内容区里的悬浮控件仍然只能自绘玻璃，想让它有光感就得把它放进标题栏
 * （见 pages/Index.ets 的 homeHeader）。
 *
 * 另外，即使位置对了，**同一个节点上也不能再叠自绘玻璃**：官方 FAQ 写明沉浸光感的
 * 视觉层级位于 `backgroundColor` / `backgroundBlurStyle` **之下**，自己画一层半透明底
 * 或毛玻璃就会把材质整片盖住。要材质就走 `materialFirstGlass`，二选一，不能叠加。
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
 *
 * 色值现在都是资源 token（亮色 / 深色两份，见 resources 下的 element/color.json（base 与 dark 各一份））：
 * 深色模式下白底会变成白 10%、描边变成 40% 白，玻璃层在深底上仍然是玻璃，
 * 而不是一块发亮的白牌子。
 */
const FLOAT_FILL_DARK: string = '#19FFFFFF';
const EDGE_HIGHLIGHT_DARK: string = '#66FFFFFF';

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
 * 档位 -> 系统材质的厚度（**悬浮控件那一族**：圆钮、来源胶囊、迷你栏这种小面积表层）
 *
 * 官方在《组件适配沉浸光感》里对按钮与选择类组件的要求是「通常使用较薄的材质样式
 * （ULTRA_THIN 或 THIN），在保持组件背景通透的同时，通过交互形变与点光源提供反馈」。
 *
 * **2026-09 实机更正（Mate 70 Pro / 鸿蒙7 / API 26，实测 globalMaterialLevel=EXQUISITE）**：
 * 早先这里「跟随系统」是按算力往上顶的 —— 高算力折算成 ULTRA_THICK。那是弹窗档，
 * 「完全模糊背景」用的，落在一颗 40vp 的圆钮上就成了一块发亮发白的实心牌子，
 * 正是「底栏页签是玻璃、顶栏这两颗钮不是」的观感来源：同一套材质，厚度差了三档。
 * 现在这一族整体压薄，「跟随系统」落到 THIN（与底部页签栏的 ADAPTIVE 观感对齐）。
 *
 * 弹窗类不走这里，见 {@link dialogStyleOf}（那里下限是 THICK）。
 */
export function immersiveStyleOf(level: number): uiMaterial.ImmersiveStyle {
  switch (clampMaterialLevel(level)) {
    case 1:
      return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    case 2:
      return uiMaterial.ImmersiveStyle.THIN;
    case 3:
      return uiMaterial.ImmersiveStyle.REGULAR;
    default:
      // 「跟随系统」：小控件上不按算力往厚里顶，顶到最厚就是白牌子。
      // 算力只用来在薄档里二选一，低算力设备退回超薄（材质本身在低算力上只有一档，
      // 这里给什么都不影响最终效果，见沉浸光感常见问题）
      try {
        const global: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
        if (global === uiMaterial.MaterialLevel.SMOOTH) {
          return uiMaterial.ImmersiveStyle.ULTRA_THIN;
        }
      } catch (e) {
        // 取不到就按 THIN
      }
      return uiMaterial.ImmersiveStyle.THIN;
  }
}

/**
 * 弹窗类表面的厚度下限
 *
 * 官方在《组件适配沉浸光感》里对弹窗类的要求是「通常使用较厚的材质样式（THICK 或
 * ULTRA_THICK），以获得更强的背景模糊效果，确保弹窗内容与背景内容之间有清晰的视觉分离」。
 * 而外观设置里「弱」那一档在悬浮控件上落成 THIN —— 放在一整块半模态上太薄了，背后
 * 的内容会直接透上来。所以弹窗类把下限抬到 THICK，「均衡 / 强」两档不受影响。
 */
function dialogStyleOf(level: number): uiMaterial.ImmersiveStyle {
  const style: uiMaterial.ImmersiveStyle = immersiveStyleOf(level);
  if (style === uiMaterial.ImmersiveStyle.ULTRA_THIN || style === uiMaterial.ImmersiveStyle.THIN ||
    style === uiMaterial.ImmersiveStyle.REGULAR) {
    return uiMaterial.ImmersiveStyle.THICK;
  }
  return style;
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

/**
 * 弹窗类表面（半模态 / 弹窗）的沉浸材质
 *
 * **这里是踩过的坑，别改回去**：`SheetOptions.systemMaterial`（以及各类弹窗 options 里
 * 的 systemMaterial）的官方类型是 `SystemUiMaterial`，也就是 `uiMaterial.Material` ——
 * 必须传 `new uiMaterial.ImmersiveMaterial({...})` 出来的**材质实例**（官方示例10
 * 「半模态设置系统材质」就是这么写的）。早先这里传的是 HDS 的 `buildTitleMaterial()`
 * 返回的 `SystemMaterialParams`（`{ materialType, materialLevel }`），那是个普通对象：
 * `Material` 基类没有实例成员，结构上"恰好兼容"，编译器和静态检查都不会报错
 * （只在 `.systemMaterial()` 通用属性上给一条 API 版本警告），但运行时它不构成材质，
 * 鸿蒙7 上半模态压根不出玻璃。
 *
 * 注意 HDS 那套只在 **HDS 导航标题栏 / HDS 底部页签** 生效（用 `systemMaterialEffect`），
 * 半模态属于 ArkUI 的弹窗类组件，走的就是 ArkUI 的 `systemMaterial`，两者不能混。
 *
 * 与 {@link immersiveMaterialFor} 的区别：厚度下限是 THICK（见 {@link dialogStyleOf}），
 * 并且**不开**按压形变与点光源 —— `interactive` / `lightEffect` 是给按钮、选择类控件
 * 做按压反馈的，一整块半模态跟着手指闪光是错的。
 *
 * 设备没有材质能力位时返回 `undefined`，调用方据此回退（半模态上就是 `blurStyle`）。
 */
export function immersiveMaterialForDialog(level: number): uiMaterial.Material | undefined {
  if (!isGlassMaterialSupported()) {
    return undefined;
  }
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: dialogStyleOf(level),
      applyShadow: true,
    });
  } catch (e) {
    return undefined;
  }
}

/**
 * 档位 -> 悬浮栏（底部迷你播放条那条胶囊）的厚度
 *
 * 一条 56vp 高、横贯屏幕的栏，面积比圆钮大一个量级，用圆钮那套超薄档会「看不出有材质」，
 * 所以整体比 {@link immersiveStyleOf} 厚一档；「强」也只到 THICK —— ULTRA_THICK 是
 * 「完全模糊背景的弹窗」档（见官方样式表），压在一条栏上就是一块实心板。
 * 「跟随系统」直接给 REGULAR（官方对它的说明就是「通用场景」）。
 */
function barStyleOf(level: number): uiMaterial.ImmersiveStyle {
  switch (clampMaterialLevel(level)) {
    case 1:
      return uiMaterial.ImmersiveStyle.THIN;
    case 2:
      return uiMaterial.ImmersiveStyle.REGULAR;
    case 3:
      return uiMaterial.ImmersiveStyle.THICK;
    default:
      return uiMaterial.ImmersiveStyle.REGULAR;
  }
}

/**
 * 悬浮栏（底部迷你播放条）的沉浸材质
 *
 * 给 `Tabs.barFloatingStyle({ systemMaterial })` 用（`FloatingTabBarStyle.systemMaterial`
 * 的官方类型就是 `uiMaterial.ImmersiveMaterial`）。子页面（歌单 / 在线详情）是压在
 * HdsNavigation 路由栈上的 NavDestination，把壳层那条带迷你栏的 HdsTabs 盖住了，
 * 只能自己挂一条 —— 而普通组件画在内容区吃不到材质（运行时打
 * `Material inactive: out of scope`），走 Tabs 自带的悬浮栏才是官方认可的位置。
 *
 * 与 {@link immersiveMaterialFor} 的区别：不开按压形变与点光源 —— 那是给按钮、
 * 选择类控件的按压反馈（整条栏跟着手指形变是错的）；厚度见 {@link barStyleOf}。
 */
export function immersiveMaterialForBar(level: number): uiMaterial.ImmersiveMaterial | undefined {
  if (!isGlassMaterialSupported()) {
    return undefined;
  }
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: barStyleOf(level),
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
  /**
   * 显式指定的底色（必须半透明）。空串 = 用默认那档，跟着深浅模式走。
   * 类型是 ResourceColor 而不是 string：默认档是资源 token（见 applyNormalAttribute）。
   */
  private tint: ResourceColor = '';
  private thin: boolean = true;
  /** 阴影半径，0 = 不画阴影（默认不画，与派音一致） */
  private shadowRadius: number = 0;
  private blurStyle: BlurStyle = BlurStyle.COMPONENT_THICK;
  /** 是否被 withBlur 显式指定过厚度（显式指定后就不再按档位换算） */
  private blurFixed: boolean = false;
  /**
   * 材质优先：材质可用时**不要**画自绘那层玻璃
   *
   * 官方 FAQ 写明「沉浸光感的视觉层级位于组件的 backgroundColor、backgroundBlurStyle
   * 等属性之下」—— 也就是说，只要同一节点上还挂着我们自己的半透明底或毛玻璃，
   * 材质就被压在最底下，看不见。所以**要给材质的地方不能叠自绘玻璃**，二选一。
   *
   * 默认 false（内容区的悬浮控件吃不到材质，必须自绘兜底，见 ui/Hds.ets 的说明）；
   * 只有在沉浸光感的生效范围内（Navigation 标题栏 / 底部 TabBar）才置 true ——
   * 那里材质真的会渲染，自绘那层是多余且有害的。材质不可用的设备上它自动退回自绘，
   * 不会变成一颗透明钮。
   */
  private materialFirst: boolean = false;

  constructor(radius: number, thin: boolean, dark: boolean, tint: ResourceColor = '', level: number = 0) {
    this.radius = radius;
    this.thin = thin;
    this.dark = dark;
    this.tint = tint;
    this.blurStyle = buildGlassBlur(level);
  }

  /** 见 {@link materialFirst} 的说明 */
  setMaterialFirst(on: boolean): GlassModifier {
    this.materialFirst = on;
    return this;
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
    /**
     * 材质优先且本机支持材质：只留圆角 + 一个**显式的透明底**。
     *
     * 沉浸光感是渲染在 backgroundColor 与 backgroundBlurStyle **下层**的，
     * 我们再画一层自己的磨砂白底，就等于把材质整片盖掉 —— 表现是「明明调了
     * systemMaterial，看起来还是原来那块死白」，官方 FAQ 里单列了这一条。
     *
     * 但**必须显式写透明**，不能什么都不设：`Button` 这类组件自带一个默认底色
     * （系统强调色，也就是那片蓝），它同样压在材质层之上。官方 FAQ 的原话是
     * 「将组件的背景色设置为透明（Color.Transparent）**或**移除背景色设置」，
     * 少了这一步，材质没露出来、反倒把组件自己的蓝底露出来了。
     */
    if (this.materialFirst && isGlassMaterialSupported()) {
      instance.backgroundColor(Color.Transparent);
      return;
    }
    // 毛玻璃：透过来的内容做模糊（材质不可用时通透感主要靠这一层）
    instance.backgroundBlurStyle(this.blurStyle);

    // 底：显式给了色调就用它（必须半透明），否则用派音那档极淡的白。
    // 「极淡的白」是资源 token：深色模式下换成白 10% / 深色磨砂底，深浅模式都不变白牌子。
    const hasTint: boolean = this.tint !== '';
    const mask: ResourceColor = hasTint
      ? this.tint
      : (this.dark ? FLOAT_FILL_DARK : (this.thin ? $r('app.color.c_glass_fill') : $r('app.color.c_glass_tint')));
    instance.backgroundColor(mask);

    // 描边：系统的玻璃描边色（取不到时退回自绘高光边），1vp ——
    // 玻璃层「看着有厚度」靠的就是这条亮边，0.5vp 在浅色底上基本看不出来
    instance.borderWidth(1);
    instance.borderColor(this.dark ? EDGE_HIGHLIGHT_DARK : $r('app.color.c_glass_edge'));

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
 * `tint` 是显式底色（留空 = 用默认那档，跟着深浅模式走，见 applyNormalAttribute），
 * `level` 是外观设置里的玻璃材质档位（0 跟随系统 / 1 弱 / 2 均衡 / 3 强），
 * 决定模糊厚度；不传就按「跟随系统」那一档。
 */
export function thinGlass(radius: number, dark: boolean = false, tint: ResourceColor = '',
  level: number = 0): GlassModifier {
  return new GlassModifier(radius, true, dark, tint, level);
}

/** 便捷构造：卡片 / 弹层这类中等厚度的一层 */
export function regularGlass(radius: number, dark: boolean = false, tint: ResourceColor = '',
  level: number = 0): GlassModifier {
  return new GlassModifier(radius, false, dark, tint, level);
}

/**
 * 便捷构造：**在沉浸光感生效范围内**（Navigation 标题栏 / 底部 TabBar）的悬浮控件
 *
 * 与 thinGlass 的唯一区别是「材质可用时不自绘玻璃」：那些位置系统材质真的会渲染，
 * 自绘那一层只会把材质盖住。材质不可用的设备上退回与 thinGlass 完全一样的观感。
 */
export function materialFirstGlass(radius: number, level: number = 0): GlassModifier {
  return thinGlass(radius, false, '', level).setMaterialFirst(true);
}
