import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, HdsSceneController, HdsSceneType, HdsVisualComponent } from '@kit.UIDesignKit';

/**
 * HDS（HarmonyOS Design System，UI Design Kit）能力接入
 *
 * 1) 沉浸视效：HdsVisualComponent + HdsSceneController。
 *    当前 HDS 开放的场景是 DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK
 *    （双边边缘流光 + 背景叠加色），用 HdsSceneController 的
 *    start/pause/resume/stop 控制动画，setSceneParams 配置两条光带的
 *    起止位置（按周长比例）与颜色。
 *
 * 2) 沉浸光感材质：hdsMaterial.getSystemMaterialTypes() 返回本机支持的材质类型
 *    （NONE / ADAPTIVE / IMMERSIVE），玻璃层据此决定用系统材质还是自绘兜底。
 *
 * 3) 材质色板：直接取系统的 HDS 玻璃材质色（$r('sys.color.glass_material_*')），
 *    而不是自己拍一个半透明白，这样亮暗色模式下都与系统一致。
 *
 * 注意：官方文档明确「模拟器不支持 HDS 沉浸视效（点光源、按压阴影、双边边缘流光、
 * 背景流光、沉浸光感材质）」，所以这里在模拟器上自动跳过视效层，
 * 避免画出不该有的背景遮罩；真机上会自动生效。
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
 * 模拟器上的 const.product.model / name / hardwareversion 都是 "emulator"，
 * 这里把几个可能命中的字段都查一遍，任一命中即认为是模拟器。
 */
function isEmulator(): boolean {
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

/** 当前设备是否具备 HDS 视效能力（能力位存在，且不是模拟器） */
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
  supportedCache = capability && !isEmulator();
  return supportedCache;
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

/** HDS 玻璃材质底色（系统色，跟随亮暗模式） */
export function hdsGlassMask(): Resource {
  return $r('sys.color.glass_material_mask_primary');
}

/** HDS 玻璃材质描边（系统色） */
export function hdsGlassOutline(): Resource {
  return $r('sys.color.glass_material_outline_primary');
}

/**
 * HDS 沉浸视效层：双边边缘流光
 *
 * 铺满父容器，作为最底层或覆盖层使用（本身不接收点击）。
 */
@Component
export struct HdsFlowLight {
  @Prop radius: number = 30;
  /** 第一条光带的颜色（从主题色推导，默认跟随强调色） */
  @Prop colorA: ResourceColor = '#59FF6B6B';
  @Prop colorB: ResourceColor = '#40FF9F43';
  private controller: HdsSceneController = new HdsSceneController();
  private configured: boolean = false;

  aboutToAppear(): void {
    if (!hdsEffectSupported()) {
      return;
    }
    try {
      this.controller.setSceneParams({
        // 背景叠加色用全透明：只叠加流光，不盖住下层玻璃
        backgroundMaskColors: ['#00000000', '#00000000'],
        firstEdgeFlowLight: { startPos: 0, endPos: 0.3, color: this.colorA },
        secondEdgeFlowLight: { startPos: 0.5, endPos: 0.8, color: this.colorB },
      });
      this.configured = true;
    } catch (e) {
      this.configured = false;
    }
  }

  aboutToDisappear(): void {
    if (!this.configured) {
      return;
    }
    try {
      this.controller.stop();
    } catch (e) {
      // 忽略：视效层被销毁时停止动画失败没有影响
    }
  }

  build() {
    if (hdsEffectSupported()) {
      HdsVisualComponent()
        .scene(HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK, this.controller)
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
        .onAppear(() => {
          if (this.configured) {
            try {
              this.controller.start();
            } catch (e) {
              // 忽略：不支持时系统会静默忽略
            }
          }
        })
    }
  }
}
