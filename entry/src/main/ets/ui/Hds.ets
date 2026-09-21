import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsEffect, hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';

/**
 * HDS（HarmonyOS Design System，UI Design Kit）能力接入
 *
 * 1) 光效：hdsEffect 的着色器（`ShaderEffectController` + `EffectType`）。
 *    这是**通用属性**路径：`HdsEffectBuilder().shaderEffect({...}).buildEffect()`
 *    产出一个 `VisualEffect`（即 `uiEffect.VisualEffect`，API 12 起的通用属性），
 *    挂在任意组件的 `.visualEffect()` 上即可，不需要任何现成控件当载体。
 *      - `UV_BACKGROUND_FLOW_LIGHT`：整片背景流光，挂在全屏 Stack 上就是「首页流光」；
 *      - `DUAL_EDGE_FLOW_LIGHT`：轮廓流光，挂在一块圆角容器上。
 *    之前这里走的是 `HdsVisualComponent` + `HdsSceneType` 那一套（场景组件），
 *    它必须有个现成控件可挂，底栏换成 HDS 悬浮页签后就没有落点了 —— 那条路已删掉。
 *
 * 2) 材质档位：`buildTitleMaterial(level)` 把「跟随系统 / 弱 / 均衡 / 强」映射成
 *    HDS 的系统材质参数。标题栏、底部页签栏、半模态三处共用同一个档位，
 *    全应用的玻璃厚度才是同一套。档位由外观设置页写入（见 core/settings/AppearanceSettings.ets）。
 *
 * 3) 材质与色板：`hdsMaterial.getSystemMaterialTypes()` 返回本机支持的材质类型；
 *    玻璃层取系统的 HDS 玻璃材质色（`$r('sys.color.glass_material_*')`），
 *    亮暗色模式下与系统一致，而不是自己拍一个半透明白。
 *
 * 关于模拟器：官方文档写明「模拟器不支持 HDS 沉浸视效（点光源、按压阴影、
 * 双边边缘流光、背景流光、沉浸光感材质）」，模拟器上渲不出来是平台侧的事。
 * 但**代码不因此把能力关掉**：能力位在就挂上去，能不能画出来交给平台 ——
 * 之前这里额外做了「模拟器就整层跳过」，结果是哪里都没有效果，
 * 设置页还把原因写成「当前设备不支持」，对不上问题。现在只在能力位缺失时才不挂。
 */

const SCENE: string = 'SystemCapability.UIDesign.HDSComponent.Core';

/**
 * HDS 标题栏自身占用的高度（不含状态栏）。
 *
 * HDS 的标题栏是「层叠布局，位于内容区上层」的（官方文档 Constraints 一节写明），
 * 也就是说它不会把内容往下推，页面内容必须自己让出这一段，否则首行文字会被标题栏压住。
 * 标题栏又默认是沉浸的（可以延伸进状态栏），所以调用方还要再加上状态栏高度：
 * 见 pages/Index.ets 里 `HDS_TITLE_BAR_HEIGHT + topInset`。
 */
export const HDS_TITLE_BAR_HEIGHT: number = 60;

/**
 * HDS 底部悬浮页签栏 / 迷你栏的高度。
 *
 * 不在页签体系里的页面自己挂迷你栏时（见 views/PlaylistDetailView.ets），
 * 高度、左右边距、离底距离都要跟这里对齐，否则同一个控件会出现两种样子。
 */
export const HDS_BAR_HEIGHT: number = 56;

/**
 * 是否为模拟器。
 * 只用于设置页把「为什么看不到视效」说清楚，不再用来关能力。
 * 模拟器上的 const.product.model / name / hardwareversion 都是 "emulator"，
 * 这里把几个可能命中的字段都查一遍，任一命中即认为是模拟器。
 */
export function isEmulatorDevice(): boolean {
  const probes: string[] = [];
  try {
    probes.push(deviceInfo.productModel);
    probes.push(deviceInfo.marketName);
    probes.push(deviceInfo.hardwareModel);
    probes.push(deviceInfo.productModelAlias);
  } catch (e) {
    // 个别字段在低版本上不存在，忽略即可
  }
  for (const item of probes) {
    const text: string = item.toLowerCase();
    if (text.includes('emulator') || text.includes('simulator')) {
      return true;
    }
  }
  return false;
}

let supportedCache: boolean | undefined = undefined;

/** 当前设备是否具备 HDS 能力（只看能力位；能不能渲染由平台决定） */
export function hdsEffectSupported(): boolean {
  if (supportedCache !== undefined) {
    return supportedCache;
  }
  let capability: boolean = false;
  try {
    capability = canIUse(SCENE);
  } catch (e) {
    capability = false;
  }
  supportedCache = capability;
  return supportedCache;
}

// ------------------------------------------------------------------ 材质档位

/** 外观设置里的档位顺序：0 跟随系统 / 1 弱 / 2 均衡 / 3 强 */
export const MATERIAL_LEVEL_LABELS: string[] = ['跟随系统', '弱', '均衡', '强'];
/** 档位上限（界面与校验用） */
export const MATERIAL_LEVEL_MAX: number = MATERIAL_LEVEL_LABELS.length - 1;

/** 档位收敛到 [0, MATERIAL_LEVEL_MAX]，越界按「跟随系统」处理 */
export function clampMaterialLevel(level: number): number {
  if (Number.isNaN(level) || level < 0 || level > MATERIAL_LEVEL_MAX) {
    return 0;
  }
  return Math.round(level);
}

/**
 * 档位 -> HDS 系统材质参数
 *
 * 标题栏（TitleBarStyleOptions.systemMaterialEffect）、底部页签栏
 * （barFloatingStyle.systemMaterialEffect）、半模态（bindSheet 的 systemMaterial）
 * 都走这一个函数，改一处档位三处一起变。
 */
export function buildTitleMaterial(level: number): SystemMaterialParams {
  switch (clampMaterialLevel(level)) {
    case 1:
      return { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.SMOOTH };
    case 2:
      return { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.GENTLE };
    case 3:
      return { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.EXQUISITE };
    default:
      return { materialType: hdsMaterial.MaterialType.IMMERSIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE };
  }
}

/**
 * 档位 -> 自绘玻璃层的模糊厚度
 *
 * 内容区里的普通组件吃不到系统材质（见 ui/Glass.ets 开头的平台限制），只能自己画磨砂，
 * 所以「档位」在这里落成 backgroundBlurStyle 的厚度。映射与派音一致
 * （它的 PlaylistFloatingMiniBar / PlaylistsPage 也是按 level 选 Thin/Regular/Thick）：
 *   1 弱   -> COMPONENT_THIN            能透出更多背后的内容
 *   2 均衡 -> COMPONENT_REGULAR
 *   3 强   -> COMPONENT_ULTRA_THICK     最厚，背后几乎糊成一片
 *   0 跟随系统 -> COMPONENT_ULTRA_THICK 自绘层没有「系统的档位」可跟，直接给最厚 ——
 *                                      底部悬浮页签栏就是最厚那一档的观感，默认要对齐它
 *   （3 强 与 0 都落在最厚一档，因为 ULTRA_THICK 已经是最厚，再往上没有了）
 */
export function buildGlassBlur(level: number): BlurStyle {
  switch (clampMaterialLevel(level)) {
    case 1:
      return BlurStyle.COMPONENT_THIN;
    case 2:
      return BlurStyle.COMPONENT_REGULAR;
    default:
      return BlurStyle.COMPONENT_ULTRA_THICK;
  }
}

let materialCache: string | undefined = undefined;

/** 本机支持的 HDS 材质类型（用于设置页展示与兜底判断） */
export function hdsMaterialType(): string {
  if (materialCache !== undefined) {
    return materialCache;
  }
  let text: string = 'NONE';
  try {
    const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
    if (types.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
      text = 'IMMERSIVE';
    } else if (types.includes(hdsMaterial.MaterialType.ADAPTIVE)) {
      text = 'ADAPTIVE';
    }
  } catch (e) {
    text = 'NONE';
  }
  materialCache = text;
  return text;
}

// ------------------------------------------------------------------ 光效

/** 流光完整循环一圈的时长（ms）：10 秒一圈是系统首页流光的默认观感，慢到不抢内容 */
export const FLOW_LIGHT_DURATION_MS: number = 10000;
/** 流光层不透明度：压在页面底色之上、内容之下，避免喧宾夺主 */
export const FLOW_LIGHT_OPACITY: number = 0.5;

/**
 * 背景流光层
 *
 * 用法：
 *   Stack({ alignContent: Alignment.TopStart }) {
 *     HdsFlowLightBackground()        // 首个子节点：画在底色之上、内容之下
 *     Column() { ...页面内容... }
 *   }
 *   .backgroundColor(页面底色)         // 底色必须挂在这一层 Stack 上
 *
 * 底色一定要给外层 Stack：如果把不透明底色留在内容那一层，流光会被整片盖掉，
 * 看上去就是「加了没效果」。
 *
 * 布局与交互都不受影响：铺满父容器、不拦触摸（HitTestMode.Transparent）、
 * 本身没有子节点，不参与测量。
 */
@Component
export struct HdsFlowLightBackground {
  @Prop lightOpacity: number = FLOW_LIGHT_OPACITY;
  @Prop durationMs: number = FLOW_LIGHT_DURATION_MS;
  private controller: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();

  build() {
    if (hdsEffectSupported()) {
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .opacity(this.lightOpacity)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .shaderEffect({
            effectType: hdsEffect.EffectType.UV_BACKGROUND_FLOW_LIGHT,
            animation: {
              duration: this.durationMs,
              // -1 = 无限循环
              iterations: -1,
              autoPlay: true
            },
            controller: this.controller
          })
          .buildEffect())
    }
  }
}

/**
 * 轮廓流光（双边边缘流光）
 *
 * 需要「一块有圆角的容器自己在发光」时用：垫在内容下面当光底（圆钮、播放胶囊），
 * 或者盖在封面这类整块图片上。铺满父容器，不拦触摸。
 *
 * 与背景流光的区别：`UV_BACKGROUND_FLOW_LIGHT` 是整片背景流光，这个是沿轮廓走的
 * 两条光带，观感更「贴边」，两者不要叠在同一层上。
 */
@Component
export struct HdsEdgeFlowLight {
  @Prop radius: number = 30;
  @Prop colorA: ResourceColor = '#59FF6B6B';
  @Prop colorB: ResourceColor = '#40FF9F43';
  @Prop lightOpacity: number = 0.8;
  @Prop durationMs: number = FLOW_LIGHT_DURATION_MS;
  private controller: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();

  build() {
    if (hdsEffectSupported()) {
      Stack()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .hitTestBehavior(HitTestMode.Transparent)
        .opacity(this.lightOpacity)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .shaderEffect({
            effectType: hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT,
            params: {
              firstEdgeFlowLight: { startPos: 0, endPos: 0.3, color: this.colorA },
              secondEdgeFlowLight: { startPos: 0.5, endPos: 0.8, color: this.colorB }
            },
            animation: {
              duration: this.durationMs,
              iterations: -1,
              autoPlay: true
            },
            controller: this.controller
          })
          .buildEffect())
    }
  }
}
