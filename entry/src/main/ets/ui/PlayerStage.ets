import { image } from '@kit.ImageKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { BusinessError } from '@kit.BasicServicesKit';
import { CoverStore } from '../core/music/CoverStore';
import { HdsEdgeFlowLight, hdsEffectSupported } from './Hds';
import { dustSupported } from './Dust';

/**
 * 播放页沉浸视觉
 *
 * 全部都是「给静态封面加一点点活气」，不做假频谱 —— 我们没有 FFT
 * （AVPlayer 拿不到频域数据），所以任何「跟着鼓点跳」都只能是编的，这里一律不做。
 *
 * ## 两档效果（由设置里的三档决定，见 core/settings/PlaySettings.ets 的 K_PLAYER_MOTION）
 *
 * 轻量档（默认）三件，全部静态或声明式动画：
 *   1. PlayerAtmosphere  封面主色铺的一层氛围底，切歌时淡入过去（静态，不耗电）
 *   2. PlayerHalo        封面背后那团主色柔光，播放时在 0.15~0.3 之间明暗
 *   3. PlayerLightBand   沿封面边缘缓慢流动的一圈光带（HDS 着色器）
 *
 * 沉浸档在这三件之上再加四件（本文件后半部分）：
 *   4. PlayerRipple      封面后向外扩散的 2~3 圈波纹（声明式，30fps 上限）
 *   5. PlayerSparks      低密度上浮光点（Particle，同时最多 ≈11 颗）
 *   6. PlayerAtmosphere 的 `flow`：氛围底两层主色交叉淡入 + 轻微位移
 *   7. 封面 3D 倾斜与漂浮：**不在本文件里** —— 它只是 `rotate`/`translate` 两个
 *      通用属性，直接挂在 PlayerView 的封面节点上（常量与相位换算在这里，
 *      见下面的 TILT_* 与 swayOf）。
 *
 * ## 功耗纪律（这是本文件最要紧的部分）
 *
 * - **只在「前台 + 播放页可见 + 正在播 + 用户没关动效」四者同时成立时才有动画。**
 *   判断集中在 PlayerView.syncPlayerMotion() 一处，四个来源任一变化都会重算一遍；
 *   沉浸档的重效果再由「档位 == immersive」这同一个入口二次收口。
 * - **不用 setInterval / 不用每帧回调 / 不用 Canvas。** 呼吸、倾斜、波纹、流动背景
 *   全是 `animateTo` 的 `iterations: -1` 无限声明式动画，由框架在渲染侧推进；
 *   光带是 HDS 着色器自己的 autoPlay 循环；光点是 Particle 组件自己的发射循环。
 *   JS 侧一个定时器都没有，「停下来」就是真的没有东西在跑。
 *   （为什么没用 Canvas + displaySync：那要一条每 33ms 的 JS 帧回调来重画，
 *   而这几样东西的形状都能用 scale/opacity/linearGradient 表达 —— 声明式版本
 *   同样的观感、零 JS 帧回调，而且帧率上限能用 `expectedFrameRateRange` 直接钉住。
 *   本工程此前一处 Canvas 都没有，为一个纯装饰层引入一条新的绘制链路也不划算。）
 * - **帧率上限 30fps**：所有沉浸档动画都带 `MOTION_FPS_30`（`expectedFrameRateRange`
 *   的 max = 30），框架据此降频，不会按 60/120 满帧跑。
 * - **停下来靠「卸载」而不是「暂停」**：波纹 / 光点整颗组件从树上摘掉（Particle 与
 *   其发射循环随之释放）；倾斜用一次 380ms 的 animateTo 把相位拉回 0（角度归零，
 *   那条无限循环同时被替换掉）；流动背景同理把相位拉回 0。
 * - **每帧工作量小**：动的只有几处 transform 与 opacity，不重绘图片、不做模糊。
 * - **取主色一次性**：主色来自 CoverStore 里已经解好的小位图（迷你栏本来就在用），
 *   取色交给系统 ColorPicker 原生实现，不在 JS 里遍历像素；一首歌只取一次。
 *
 * ## 退化路径（能力位缺失就不做）
 *
 * - 没有 ImageKit 取色能力：`stageTint` 保持空串，氛围底整层不挂 —— 播放页维持原来
 *   那套「封面高斯模糊 + 深色渐变」，观感不倒退。波纹与光点会退到中性白（不是不画：
 *   它们是「光」，白色在任何封面上都成立），但仍然只在沉浸档里出现。
 * - 没有 HDS 能力位（低版本 / 模拟器）：光带不挂，其余照旧（呼吸 / 氛围底 / 波纹 /
 *   倾斜都只用通用属性，不需要任何能力位）。
 * - 没有 Particle 能力位（`dustSupported()` 为 false）：光点不挂，波纹与倾斜照旧。
 * - `drawing.RuntimeShader`（AGSL 片元着色器）在本机 SDK 里是存在的
 *   （见文件末尾的 `runtimeShaderSupported()`），但本轮**没有用**：它的着色器源码
 *   语法、参数绑定与 ImageShader 的配合都没有在本工程里验证过，而这里没有可编译
 *   验证的环境 —— 按「不确定就不要硬上」处理，留一个探测位而不是留一段猜出来的代码。
 */

// ------------------------------------------------------------------ 呼吸

/** 呼吸缩放的峰值：1.03 是「看得见但不晃眼」的量级，再大就成了抽动 */
export const BREATH_SCALE_MAX: number = 1.03;
/** 静止态的缩放（暂停 / 停止 / 关掉动效时恒为它） */
export const BREATH_SCALE_REST: number = 1;
/** 一次涨（或一次缩）的时长：2.6 秒，慢到不抢内容 */
export const BREATH_CYCLE_MS: number = 2600;
/**
 * 回到静止态的时长
 *
 * 比一拍短得多：暂停键按下去要「立刻定住」，不能还慢慢飘两秒才停。
 */
export const BREATH_SETTLE_MS: number = 80;

// ------------------------------------------------------------------ 光晕

/** 光晕明暗的两端（就是这团柔光的 opacity） */
export const HALO_GLOW_REST: number = 0.15;
export const HALO_GLOW_MAX: number = 0.3;
/**
 * 光晕直径相对封面边长的倍数
 *
 * 必须比封面大一圈：它画在封面**背后**，和封面同样大的话整团都被盖住，
 * 一点都露不出来。
 */
const HALO_SCALE: number = 1.18;
/** 取不到主色时的光晕色：中性白，深浅两种封面都成立 */
const HALO_FALLBACK: string = '#FFFFFF';

// ------------------------------------------------------------------ 氛围底

/** 氛围底的最终不透明度：它只是「一层底」，不能变成主视觉 */
const WASH_OPACITY: number = 0.55;
/** 切歌时新主色的淡入时长 */
const TINT_FADE_MS: number = 700;

// ------------------------------------------------------------------ 光带

/** 光带的两条边：白色主光 + 一点品牌红副光（与播放钮那圈流光同一套配色） */
const BAND_COLOR_A: string = '#59FFFFFF';
const BAND_COLOR_B: string = '#33FF6B6B';
const BAND_OPACITY: number = 0.55;
/**
 * 光带走完一圈的时长
 *
 * 播放钮那圈是 10 秒，封面是整页最大的一块面，同一个速度在那儿会显得急 ——
 * 拉到 15 秒，一圈慢到几乎看不出在动，只有余光能察觉。
 */
const BAND_DURATION_MS: number = 15000;

// ------------------------------------------------------------------ 帧率上限

/**
 * 沉浸档动画的帧率上限（30fps）
 *
 * 这一档动的都是「大而慢」的东西（倾斜、波纹、流动背景），30 帧完全看不出卡。
 * `expectedFrameRateRange` 是框架的**降频**入口：把 max 写成 30，这条动画就不会
 * 按 60/120 满帧跑 —— 沉浸档最省电的一处就在这，也是「帧率上限」这个要求
 * 在 ArkUI 里唯一能真正落地的表达方式。
 * min 给 15：真机偶尔掉帧时不被强行拉回 30，免得反而更费。
 */
export const MOTION_FPS_30: ExpectedFrameRateRange = { min: 15, expected: 30, max: 30 };

// ------------------------------------------------------------------ 沉浸档：3D 倾斜与漂浮

/** 绕 X 轴的最大倾角（度）：±3.4°，再大就从「浮着」变成「在晃」 */
export const TILT_X_MAX: number = 3.4;
/** 绕 Y 轴的最大倾角（度）：比 X 轴小，横向摆动更轻，像空气里的浮动而不是风里的纸片 */
export const TILT_Y_MAX: number = 2.4;
/** 上下漂浮的幅度（vp）：4vp 是「看得出在浮、又不离开原来那块位置」的量 */
export const TILT_FLOAT_MAX: number = 4;
/** 绕 X 轴摆一个来回的时长 */
export const TILT_X_CYCLE_MS: number = 8000;
/**
 * 绕 Y 轴摆一个来回的时长
 *
 * 与 X 轴**故意错开**（8s vs 10s）：两条不同周期的正弦叠起来，合成的倾倒方向
 * 会慢慢游走，看起来是「浮着」而不是「来回机械摆动」—— 这是像不像的关键。
 */
export const TILT_Y_CYCLE_MS: number = 10000;
/** 停下时把相位拉回 0 的时长：比一拍短，松手就要定住 */
export const TILT_SETTLE_MS: number = 80;

/**
 * 相位（0~1）-> 正弦摆动（-1~1）
 *
 * 为什么用正弦而不是「0 -> 最大值」的来回：正弦在相位 0 与 1 处都是 0、导数也连续，
 * 所以无限循环的接缝处没有跳变，「起」与「停」也都是从 0 平滑进出。
 * 否则 ±3° 的倾斜上任何一次硬跳，整页都看得见。
 */
export function swayOf(phase: number): number {
  return Math.sin(phase * Math.PI * 2);
}

// ------------------------------------------------------------------ 沉浸档：扩散波纹

/** 圈数上限：3 圈（再多就成了「涟漪堆」，也更费） */
const RIPPLE_RING_COUNT: number = 3;
/** 一圈从「藏在封面后面」扩到「散尽」的时长 */
const RIPPLE_PERIOD_MS: number = 6200;
/** 起始缩放：0.94 —— 整圈都在封面背后（封面是不透明的，画在后面就看不见） */
const RIPPLE_FROM_SCALE: number = 0.94;
/** 终止缩放：1.3 —— 手机竖屏 252vp 的封面扩到 ~328vp，还在屏内，且那时已经透明 */
const RIPPLE_TO_SCALE: number = 1.3;
/** 起始不透明度：薄薄一圈光，不能抢封面 */
const RIPPLE_ALPHA: number = 0.4;
/** 环的线宽（vp）：细才像光，粗就成了同心圆 */
const RIPPLE_STROKE: number = 1.6;
/** 取不到主色时的环色：中性白（环是「光」，白色在任何封面上都成立） */
const RIPPLE_FALLBACK_COLOR: string = '#FFFFFF';
/** 三圈的序号（ForEach 的稳定数据源，模块级常量避免每帧新建数组） */
const RIPPLE_SLOTS: number[] = [0, 1, 2];

// ------------------------------------------------------------------ 沉浸档：上浮光点

/**
 * 光点同时存活数的上限（≤12 颗）
 *
 * 算得出来，不是拍脑袋：`发射速率 × 最长寿命` = 同时存活数。
 * 1.5 × (6s + 1.5s 的寿命抖动上限) = 11.25 颗，压在 12 以下。
 * 改任何一个数都要重新算一遍这个乘积。
 */
const SPARK_EMIT_RATE: number = 1.5;
const SPARK_LIFETIME_MS: number = 6000;
const SPARK_LIFETIME_RANGE_MS: number = 1500;
const SPARK_RADIUS: number = 1.7;
/** 光点的起始不透明度：它是「浮尘」，不是星星 */
const SPARK_ALPHA: number = 0.45;

// ------------------------------------------------------------------ 沉浸档：氛围底流动

/** 两层主色交叉淡入淡出的一个来回（8~12 秒区间里取 9 秒，慢到看不出是「动画」） */
export const FLOW_CYCLE_MS: number = 9000;
/** 停下时相位回 0 的时长：流动是极慢的，收得稍慢一点也不显眼，但要好收 */
const FLOW_SETTLE_MS: number = 600;
/** 第二层的位移幅度（vp）：两层角度已经不同，再加一点漂移，边界就不会是死的 */
const FLOW_DRIFT_VP: number = 5;


// ------------------------------------------------------------------ 取主色

/** 位图还没解好时的重试间隔 */
const TINT_RETRY_MS: number = 500;
/**
 * 重试次数上限（约 3 秒）
 *
 * 这是**有限次**的重试，不是常驻轮询：到点还没解出来就彻底放弃、保持退化外观。
 * （CoverStore 的位图是异步解的，切歌瞬间常常还没好；等它一下比立刻放弃好，
 * 但绝不能一直等下去 —— 那会变成一个永不收手的定时器。）
 */
const TINT_RETRY_MAX: number = 6;

// ------------------------------------------------------------------ 工具

/**
 * 取色能力位
 *
 * effectKit 的 ColorPicker 与 ImageKit 的解码同属 Image.Core 能力位；
 * 拿不到就不去取色（调用方保持退化外观），不做「猜一个颜色」这种事。
 */
export function tintSupported(): boolean {
  try {
    return canIUse('SystemCapability.Multimedia.Image.Core');
  } catch (e) {
    return false;
  }
}

/**
 * '#RRGGBB' -> '#AARRGGBB'
 *
 * `alpha` 是 0~255 的整数（不是 0~1）：ArkUI 的字符串颜色一律按 ARGB 解析，
 * 渐变停靠点要「同一个色、不同透明度」，只能拼成这个形状
 * （资源色取不到 alpha，见 ui/Theme.ets 里 C_TOP_FADE_END 的说明）。
 */
export function withAlpha(hex: string, alpha: number): string {
  if (hex.length !== 7 || hex.charAt(0) !== '#') {
    return hex;
  }
  const value: number = Math.max(0, Math.min(255, Math.round(alpha)));
  return `#${value.toString(16).padStart(2, '0')}${hex.substring(1)}`;
}

function clampByte(value: number): number {
  if (Number.isNaN(value) || value < 0) {
    return 0;
  }
  return value > 255 ? 255 : Math.round(value);
}

function hexByte(value: number): string {
  return clampByte(value).toString(16).padStart(2, '0');
}

/**
 * 取色器给的主色 -> 能铺在深色播放页上的色值
 *
 * 取的是「封面上占比最大的那个颜色」，深色封面（黑胶、夜景、纯色底）会给出接近黑
 * 的色，铺在本来就近黑的播放页上等于白做。这里按「最亮通道抬到 150」等比放大一次：
 * 色调不变、只是整体提亮；本来就够亮的封面（浅色专辑图）不动它。
 */
function washOf(color: effectKit.Color): string {
  let r: number = clampByte(color.red);
  let g: number = clampByte(color.green);
  let b: number = clampByte(color.blue);
  const top: number = Math.max(r, Math.max(g, b));
  if (top > 0 && top < 150) {
    const scale: number = 150 / top;
    r = clampByte(r * scale);
    g = clampByte(g * scale);
    b = clampByte(b * scale);
  }
  return `#${hexByte(r)}${hexByte(g)}${hexByte(b)}`;
}

/**
 * 封面主色解析器（一首歌解析一次）
 *
 * 数据来源是 CoverStore 里**已经解好的那张小位图**（迷你栏的同步绘制在用同一份），
 * 所以正常情况下是内存命中、零网络零解码；切歌瞬间位图还没解好时按 500ms 重试几次，
 * 拿到就回调一次然后自己收手。
 */
export class CoverTint {
  private timer: number = 0;
  private url: string = '';
  private tries: number = 0;
  private onTint: ((tint: string) => void) | null = null;

  /** 开始解析（会先取消上一次，切换歌曲不会堆积两条等待） */
  request(url: string, onTint: (tint: string) => void): void {
    this.cancel();
    if (url.length === 0 || !tintSupported()) {
      return;
    }
    this.url = url;
    this.tries = 0;
    this.onTint = onTint;
    this.attempt();
  }

  /** 收手（页面消失 / 换歌 / 关掉动效时都要调，别留定时器） */
  cancel(): void {
    if (this.timer !== 0) {
      clearTimeout(this.timer);
      this.timer = 0;
    }
    this.url = '';
    this.tries = 0;
    this.onTint = null;
  }

  private attempt(): void {
    if (this.onTint === null) {
      return;
    }
    const store: CoverStore = CoverStore.getInstance();
    const pixels: image.PixelMap | undefined = store.pixelFor(this.url);
    if (pixels === undefined) {
      // 位图还没解好（切歌那一下）：请它解一次，过一会儿再来问。有次数上限，见 TINT_RETRY_MAX
      store.preloadPixel(this.url);
      this.tries++;
      if (this.tries > TINT_RETRY_MAX) {
        this.cancel();
        return;
      }
      this.timer = setTimeout(() => {
        this.timer = 0;
        this.attempt();
      }, TINT_RETRY_MS);
      return;
    }
    // 位图在手：交给系统的取色器（原生实现，不在 JS 里遍历像素）
    effectKit.createColorPicker(pixels)
      .then((picker: effectKit.ColorPicker) => {
        let color: effectKit.Color | null = null;
        try {
          color = picker.getMainColorSync();
        } catch (e) {
          // 位图可能已经被 CoverStore 回收（缓存只有 12 张）：保持退化外观即可
          color = null;
        }
        if (color !== null && this.onTint !== null) {
          this.onTint(washOf(color));
        }
        this.cancel();
      })
      .catch((err: BusinessError) => {
        this.cancel();
      });
  }
}

// ------------------------------------------------------------------ 氛围底

/**
 * 氛围底：封面主色铺的一层渐变
 *
 * 挂在播放页背景里（封面模糊图**之上**、压暗层**之下**）：模糊图负责「形」，
 * 这一层负责「色」。取不到主色时整层不挂，背景退回原来那套观感。
 *
 * 切歌时的淡入：先把新色的 opacity 压到 0（瞬时生效，不走动画），再 animateTo 拉到 1。
 * 观感是「底色跟着这首慢慢换过来」，而不是硬切。关掉动效时不做这一步 ——
 * 氛围底本身是静态的，静态的东西不耗电，关掉的只是「动」。
 *
 * 沉浸档的 `flow`：在上面那层之外再叠一层**同色不同角度**的渐变，两层按相位交叉
 * 淡入淡出（A 层的 opacity = 1-相位，B 层 = 相位），B 层同时轻微位移。
 * 观感是「这片底色在极慢地晃」，而**不是**一个会动的图层盖上去 ——
 * 所以它不碰 Canvas、不重绘，动的只有两个 opacity 和一个 translate。
 * 两层之和恒为 1，整页亮度不变（不会一呼一吸地把文字衬得忽明忽暗）。
 */
@Component
export struct PlayerAtmosphere {
  /** 封面主色（'#RRGGBB'；空串 = 取不到，不挂这层） */
  @Prop @Watch('onTintChanged') tint: string = '';
  /** 动效开关（档位不是「关闭」）：关掉时氛围底照样在，但不再做淡入 */
  @Prop active: boolean = true;
  /** 沉浸档的缓慢流动（只有这一档为真） */
  @Prop @Watch('onFlowChanged') flow: boolean = false;
  @State wash: number = 1;
  /**
   * 流动相位（0~1）：0 = 只有 A 层（与加流动之前一模一样），1 = 只有 B 层
   *
   * 静止时恒为 0，所以「关掉沉浸档」的观感与轻量档完全一致，不需要另做退化版。
   */
  @State flowPhase: number = 0;
  /** 流动是否在跑（非状态：build 只依赖 flowPhase，它变了才要重绘） */
  private flowing: boolean = false;

  aboutToAppear(): void {
    // 进来时可能已经在放：该流动就直接起，别等第一次档位变化
    this.syncFlow();
  }

  aboutToDisappear(): void {
    /**
     * 页面销毁前把无限动画收掉
     *
     * 与呼吸那套同一个理由：这里虽然会随着组件一起被销毁，但先把相位拉回 0
     * 能保证「重建同一棵树」时不会继承到一个跑着的动画。不额外起定时器。
     */
    this.flowing = false;
  }

  onTintChanged(): void {
    if (!this.active || this.tint.length === 0) {
      this.wash = 1;
      this.syncFlow();
      return;
    }
    this.wash = 0;
    animateTo({ duration: TINT_FADE_MS, curve: Curve.EaseInOut }, () => {
      this.wash = 1;
    });
    // 主色换了：流动得跟着新色重新决定跑不跑（没取到色就别对着空节点跑动画）
    this.syncFlow();
  }

  onFlowChanged(): void {
    this.syncFlow();
  }

  /**
   * 流动的**唯一**开关：沉浸档 + 有主色
   *
   * 没有主色时这层在 build 里根本不挂，起动画等于对着一个不存在的节点跑 —— 白费。
   */
  private syncFlow(): void {
    if (this.flow && this.tint.length > 0) {
      this.startFlow();
    } else {
      this.stopFlow();
    }
  }

  /** 起流动：一条 9 秒的无限往返，30fps 上限（见 MOTION_FPS_30） */
  private startFlow(): void {
    if (this.flowing) {
      return;
    }
    this.flowing = true;
    animateTo({
      duration: FLOW_CYCLE_MS,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate,
      expectedFrameRateRange: MOTION_FPS_30,
    }, () => {
      this.flowPhase = 1;
    });
  }

  /**
   * 停流动：把相位拉回 0
   *
   * 同一个属性上的新 animateTo 会替换掉那条无限循环（与呼吸那边同一套做法），
   * 所以这里不需要「取消动画」的接口，也没有残留。
   */
  private stopFlow(): void {
    if (!this.flowing) {
      return;
    }
    this.flowing = false;
    animateTo({ duration: FLOW_SETTLE_MS, curve: Curve.EaseOut }, () => {
      this.flowPhase = 0;
    });
  }

  build() {
    if (this.tint.length > 0) {
      Stack() {
        // A 层：原来的那一层（角度 200），相位到 1 时完全淡出
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 200,
            colors: [[withAlpha(this.tint, 0x6B), 0.0], [withAlpha(this.tint, 0x00), 0.92]],
          })
          .opacity(1 - this.flowPhase)
          .hitTestBehavior(HitTestMode.None)
        /**
         * B 层：同色、换一个角度（200 -> 20），相位到 1 时才是满的
         *
         * 尺寸给 112% 是为了给下面的位移留余量：它被 Stack 居中，多出来的 6% 两边均分，
         * 所以 ±5vp 的漂移不会在边上露出一条缝（露缝的话会看到一条硬边）。
         */
        Column()
          .width('112%')
          .height('112%')
          .linearGradient({
            angle: 20,
            colors: [[withAlpha(this.tint, 0x5A), 0.0], [withAlpha(this.tint, 0x00), 0.88]],
          })
          .opacity(this.flowPhase)
          .translate({
            x: FLOW_DRIFT_VP * (this.flowPhase - 0.5),
            y: FLOW_DRIFT_VP * (0.5 - this.flowPhase),
          })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      // 整层的不透明度：与加流动之前同一个数，所以亮度一分没变
      .opacity(WASH_OPACITY * (this.active ? this.wash : 1))
      .hitTestBehavior(HitTestMode.None)
    }
  }
}

// ------------------------------------------------------------------ 光晕

/**
 * 封面背后那团主色柔光
 *
 * 用一个径向渐变画「中心浓、边缘透明」，**不用 blur**：模糊是每帧重算的，
 * 而径向渐变本身自带柔和过渡，一次画好就不再变，动的只是 opacity。
 *
 * 为什么要靠 `scale` 而不是把宽高写成 1.18 倍：它画在封面**背后**，必须比封面大一圈
 * 才露得出来，而它是那个固定尺寸 Stack 的子节点 —— 子节点的尺寸会被父约束夹住，
 * 写多大都会被压回封面的边长。`scale` 是**绘制阶段的变换**，不参与布局测量，
 * 所以既能把光晕放到封面外面，又完全不动既有布局（封面块占的空间一分没变）。
 */
@Component
export struct PlayerHalo {
  @Prop tint: string = '';
  /** 封面边长（vp）：径向渐变的半径按它算 */
  @Prop coverSize: number = 0;
  /** 当前明暗（由播放页的呼吸动画推进，0.15~0.3） */
  @Prop glow: number = HALO_GLOW_REST;
  /** 动效在跑：不在跑时锁在静止态那一档 */
  @Prop active: boolean = true;

  /** 光晕色：有主色用主色，没有用中性白 */
  private haloColor(): string {
    return this.tint.length > 0 ? this.tint : HALO_FALLBACK;
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .radialGradient({
        center: [this.coverSize / 2, this.coverSize / 2],
        radius: this.coverSize / 2,
        /**
         * 中空的一圈：中间全透明（别把封面本身洗白），最亮的一档压在 0.84 处
         *
         * 为什么是 0.84 而不是 1.0：光晕整体被 scale 放到 1.18 倍，封面于是占了它的
         * 1/1.18 ≈ 0.85，也就是说**能看见的那一圈正好落在 0.85~1.0 之间**。
         * 如果按「中心最亮、边缘最暗」去铺，露在封面外面的恰好是最淡的那一段，等于白画。
         */
        colors: [
          [withAlpha(this.haloColor(), 0x00), 0.0],
          [withAlpha(this.haloColor(), 0x00), 0.55],
          [withAlpha(this.haloColor(), 0x8C), 0.84],
          [withAlpha(this.haloColor(), 0x00), 1.0],
        ],
      })
      // 放大到封面的 1.18 倍：只影响绘制，不占布局（见上面组件注释）
      .scale({ x: HALO_SCALE, y: HALO_SCALE, centerX: '50%', centerY: '50%' })
      .opacity(this.active ? this.glow : HALO_GLOW_REST)
      .hitTestBehavior(HitTestMode.None)
  }
}

// ------------------------------------------------------------------ 光带

/**
 * 沿封面边缘缓慢流动的光带
 *
 * 直接用工程里已有的 HDS 双边流光（播放钮那圈就是它，见 ui/Hds.ets）：
 * 它内部是着色器自己的 `iterations: -1` 循环，**不占 JS**，而且停的方式很干脆 ——
 * 把组件从树上摘掉，着色器跟着释放，没有「暂停」这种中间状态要维护。
 * 所以调用方只要按「该不该动」决定挂不挂它（见 PlayerView 的 motionRunning）。
 *
 * 能力位缺失（低版本 / 模拟器渲不出 HDS 视效）就不挂，页面其余部分照旧。
 */
@Component
export struct PlayerLightBand {
  @Prop active: boolean = false;
  /** 圆角跟着封面走（外观设置里可调） */
  @Prop radius: number = 12;

  build() {
    if (this.active && hdsEffectSupported()) {
      HdsEdgeFlowLight({
        radius: this.radius,
        colorA: BAND_COLOR_A,
        colorB: BAND_COLOR_B,
        lightOpacity: BAND_OPACITY,
        durationMs: BAND_DURATION_MS,
      })
    }
  }
}

// ------------------------------------------------------------------ 沉浸档：扩散波纹

/**
 * 一圈扩散波纹
 *
 * 用 `Circle` 的描边画一个环，再靠两个由相位推出来的派生值动起来：
 *   - 缩放 0.94 -> 1.3（从「整圈藏在封面后面」扩到「散尽」）
 *   - 不透明度 0.4 -> 0（扩到最外圈时正好透明）
 *
 * 为什么不用 Canvas 逐帧画：这两条曲线都能被 scale / opacity 精确表达，
 * 用声明式动画画出来的观感一模一样，但**零 JS 帧回调** —— 而 Canvas 方案需要
 * 一条每 33ms 的回调去 clearRect + arc + stroke，是常驻的 JS 抖动。
 * 帧率上限用 `expectedFrameRateRange`（MOTION_FPS_30）钉在 30，
 * 与「30fps 的 Canvas 驱动」付出的是同一个帧率预算，省下来的只有 CPU。
 *
 * 循环接缝：相位 1 时 opacity 已经是 0，回到相位 0 的那一帧是看不见的，所以
 * `PlayMode.Normal`（每轮从头）不会有跳变。
 */
@Component
struct RippleRing {
  /** 封面边长（vp）：环的直径与它相同，靠缩放扩出去 */
  @Prop coverSize: number = 0;
  @Prop tint: string = '';
  /** 相位延迟（ms）：三圈错开，看起来是一圈接一圈往外走 */
  @Prop phaseMs: number = 0;
  /** 一圈的生命进度 0 -> 1（由 aboutToAppear 里那条无限动画推进） */
  @State progress: number = 0;

  aboutToAppear(): void {
    animateTo({
      duration: RIPPLE_PERIOD_MS,
      // EaseOut：刚离开封面时快、往外扩散时越来越慢 —— 水面涟漪就是这个形状
      curve: Curve.EaseOut,
      /**
       * 延迟只用来把三圈错开
       *
       * 三圈周期相同，所以这个延迟在每一圈上都成立：第一圈先走，后两圈各自晚
       * 1/3、2/3 个周期，永远保持等间距（不是只在第一轮错开）。
       */
      delay: this.phaseMs,
      iterations: -1,
      /**
       * `Normal` = 每轮从起点重新播（就是「Restart」的意思）
       *
       * ArkUI 的 PlayMode 只有 Normal / Reverse / Alternate / AlternateReverse 四个，
       * **没有 Restart**；「一直从头重复」是靠 Normal + iterations:-1 表达的。
       */
      playMode: PlayMode.Normal,
      expectedFrameRateRange: MOTION_FPS_30,
    }, () => {
      this.progress = 1;
    });
  }

  /** 环色：有主色用主色（它从封面主色里渗出来），没有就用中性白 */
  private ringColor(): string {
    return this.tint.length > 0 ? this.tint : RIPPLE_FALLBACK_COLOR;
  }

  build() {
    Circle()
      .width(this.coverSize)
      .height(this.coverSize)
      .fill(Color.Transparent)
      .stroke(this.ringColor())
      .strokeWidth(RIPPLE_STROKE)
      .scale({
        x: RIPPLE_FROM_SCALE + (RIPPLE_TO_SCALE - RIPPLE_FROM_SCALE) * this.progress,
        y: RIPPLE_FROM_SCALE + (RIPPLE_TO_SCALE - RIPPLE_FROM_SCALE) * this.progress,
        centerX: '50%',
        centerY: '50%',
      })
      .opacity(RIPPLE_ALPHA * (1 - this.progress))
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 封面后向外扩散的波纹（沉浸档，最多 3 圈）
 *
 * 挂在封面 Stack 里、**封面之前**（也就是它下面）：起始缩放 0.94 让它整圈藏在
 * 不透明的封面背后，扩出去才从封面边缘「渗」出来 —— 这正是这类播放器的观感。
 *
 * 停的方式：整颗组件从树上摘掉（见 PlayerView 的 immersiveRunning），
 * 三条无限动画随组件一起消失，不留任何驱动。
 *
 * `generation` 进 ForEach 的 key：切歌时把它 +1，三圈会**重建**（进度从 0 开始），
 * 也就是「旧动画先停再起」，任何时刻只有一份。
 */
@Component
export struct PlayerRipple {
  /** 只有沉浸档且正在播放时才为真 */
  @Prop active: boolean = false;
  @Prop tint: string = '';
  @Prop coverSize: number = 0;
  /** 代数：切歌时 +1，用来让三圈重头开始（见上） */
  @Prop generation: number = 0;

  build() {
    Stack() {
      if (this.active && this.coverSize > 0) {
        ForEach(RIPPLE_SLOTS, (slot: number) => {
          RippleRing({
            coverSize: this.coverSize,
            tint: this.tint,
            // 三圈等分一个周期：一圈扩散到 2/3 时下一圈才从封面里出来
            phaseMs: slot * (RIPPLE_PERIOD_MS / RIPPLE_RING_COUNT),
          })
        }, (slot: number) => `ripple_${this.generation}_${slot}`)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

// ------------------------------------------------------------------ 沉浸档：上浮光点

/**
 * 上浮光点（沉浸档）
 *
 * 为什么不用 \Particle\ 组件：真机上它一颗都没出来 —— 发射器尺寸依赖 \onSizeChange\
 * 回传的 vp 值，而播放页这层覆盖物里该回调没有触发，尺寸为 0 时粒子全挤在原点。
 * 这里改成**纯声明式**的 8 颗 \SparkDot\：每颗自己一条 \nimateTo\ 无限循环
 * （iterations:-1），横向用百分比定位、上浮用 translate、透明度随相位衰减 ——
 * 走的是普通图元渲染，不依赖任何能力位，一定看得见。
 *
 * 数量固定 8 颗（<=12），周期 7.2~12 秒、起点错开，观感是稀薄的浮尘。
 */
const SPARK_COUNT_LIMIT: number = 8;
const SPARK_SIZE_VP: number = 6;
const SPARK_RISE_VP: number = 90;
const SPARK_MIN_ALPHA: number = 0.85;
/** 光点颜色：亮白微暖 —— 用封面主色会在深色背景上彻底看不见（首版就是这么消失的） */
const SPARK_COLOR: string = '#F2EFE6';

/** 一颗光点的固定参数（确定性，便于复现与排障） */
interface SparkSeed {
  left: number;
  top: number;
  ms: number;
}

const SPARK_SEEDS: SparkSeed[] = [
  { left: 4, top: 30, ms: 9000 },
  { left: 8, top: 44, ms: 11000 },
  { left: 94, top: 32, ms: 7600 },
  { left: 90, top: 46, ms: 12000 },
  { left: 18, top: 12, ms: 8400 },
  { left: 42, top: 9, ms: 10200 },
  { left: 66, top: 11, ms: 7200 },
  { left: 84, top: 14, ms: 9600 },
];

@Component
struct SparkDot {
  @Prop tint: string = '';
  /** 横向位置（百分比 0~100） */
  @Prop leftPercent: number = 50;
  /** 纵向起点（百分比，越大越靠下） */
  @Prop topPercent: number = 90;
  /** 一轮上浮时长（毫秒） */
  @Prop riseMs: number = 9000;
  @State phase: number = 0;

  aboutToAppear(): void {
    animateTo({
      duration: this.riseMs,
      curve: Curve.Linear,
      iterations: -1,
      playMode: PlayMode.Normal,
      expectedFrameRateRange: MOTION_FPS_30,
    }, () => {
      this.phase = 1;
    });
  }

  build() {
    Circle()
      .width(SPARK_SIZE_VP)
      .height(SPARK_SIZE_VP)
      .fill(SPARK_COLOR)
      .opacity(SPARK_MIN_ALPHA * (1 - this.phase))
      .position({ x: this.leftPercent + '%', y: this.topPercent + '%' })
      .translate({ y: -SPARK_RISE_VP * this.phase })
      .hitTestBehavior(HitTestMode.None)
  }
}

@Component
export struct PlayerSparks {
  /** 只有沉浸档且正在播放时才为真 */
  @Prop active: boolean = false;
  @Prop tint: string = '';

  build() {
    Stack() {
      if (this.active) {
        ForEach(SPARK_SEEDS, (seed: SparkSeed, index: number) => {
          SparkDot({
            tint: this.tint,
            leftPercent: seed.left,
            topPercent: seed.top,
            riseMs: seed.ms,
          })
        }, (seed: SparkSeed, index: number) => 'spark_' + index + '_' + seed.ms)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

// ------------------------------------------------------------------ 能力位：AGSL 片元着色器

/**
 * `drawing.RuntimeShader`（AGSL 片元着色器）能力位
 *
 * 本轮**没有**用它做「主色流光扭曲」，只留这个探测位：能力存在（API 18 起的
 * 图元绘制接口里有 RuntimeShader），但它的着色器源码语法、uniform 绑定、
 * 与 ImageShader 的配合都没有在本工程里跑通过，而这里没有可编译验证的环境 ——
 * 按「不确定就不要硬上」处理。真要用的话，落点应该是把 PlayerAtmosphere 的
 * 两层渐变换成一层着色器（一个全屏 pass，代价比现在两层渐变高）。
 *
 * 保留这个函数是为了让「能力存在但未用」这件事是**可验证**的，而不是一句口头说明：
 * 想看本机到底有没有，调一次即可。
 */
export function runtimeShaderSupported(): boolean {
  try {
    return canIUse('SystemCapability.Graphics.Drawing');
  } catch (e) {
    return false;
  }
}
