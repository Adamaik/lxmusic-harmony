/**
 * 回响月报的「纯视觉组件库」（固定深色沉浸式版面）
 *
 * 这一页照网易云年度报告那一套做：整页近黑底 + 中部很淡的暖紫氛围 + 亮粉色强调色。
 * 它**故意不用主题 token**（C_BG / C_CARD / C_RED 这些）：
 *
 *   - 主题那套是「浅灰底 + 纯白卡片 + 洛雪红」，深色模式下才翻成近黑；
 *   - 月报不管系统深浅模式都必须是深色（截图就是深色，浅色模式下用 token 会整页变白，
 *     白底上再压深色卡片 / 白字，整页就散了）。
 *
 * 所以下面的调色板全是**字面量**，页面直接拿它们铺底色，别再引 Theme 里的颜色。
 * 同理，封面上的白字与压暗层也是字面量（跟播放页封面上的那几层白字一个道理）。
 *
 * 页面在 views/EchoView.ets 里按固定契约调用这些组件：组件只管「长什么样」，
 * 数据怎么聚合、点了之后播哪首由页面决定（回调一律 `(index) => void`）。
 */
import { curves } from '@kit.ArkUI';
import { CoverArt } from './Widgets';
import { I_CHEVRON_DOWN, I_CHEVRON_RIGHT, IconGlyph } from './Icons';

// ------------------------------------------------------------------ 调色板

/** 整页底色：顶部 / 中部氛围 / 底部（中部稍亮、偏紫棕，是那层「氛围」的落点） */
export const E_BG_TOP: string = '#0B0B0E';
export const E_BG_MID: string = '#191419';
export const E_BG_BOTTOM: string = '#0B0B0E';
/** 主文字（近白，比纯白柔一点，长时间看大字号不刺眼） */
export const E_TEXT: string = '#F7F7F9';
/** 次要文字（歌手、说明） */
export const E_TEXT_SUB: string = '#A0A0A8';
/** 更弱的文字（名次、计数、刻度）。2026-10-22 由 #6B6B73 提亮到 #82828A：真机截图里这档灰太沉 */
export const E_TEXT_WEAK: string = '#82828A';
/** 强调色：月报专用的亮粉，不是 App 主题的洛雪红 */
export const E_ACCENT: string = '#F04D7C';
/** 第 1 名的金色（只有「1st」这三个字用） */
export const E_GOLD: string = '#E8C87E';
/** 深色页上的卡片底：很淡的一层白（比纯色块更像玻璃，不抢内容）。2026-10-22 由 #12FFFFFF 提亮到 #1FFFFFFF */
export const E_CARD: string = '#1FFFFFFF';
/** 分割线：比卡片底再淡一点 */
export const E_DIVIDER: string = '#16FFFFFF';

/** 卡片圆角（页面里所有深色卡片共用，保证一页里圆角不分叉） */
const R_CARD_DARK: number = 18;
/** 卡片内边距 */
const CARD_PAD: number = 16;
/** 三格统计里数字的字号（截图里数字比正文重得多，但比总时长小一档） */
const STAT_SIZE: number = 25;
/** 列表行高：名次 + 歌名两行 + 右侧次数，56~62 之间取 58 */
const RANK_ROW_HEIGHT: number = 58;

// ------------------------------------------------------------------ 文本助手

/**
 * 时长文案
 *
 * 0 到 59 秒都说「不到 1 分钟」：月报这种东西，0 也要说得像句人话
 * （「0 分钟」既不像统计，也不像一句总结）。
 */
export function echoDurationText(ms: number): string {
  // 负数 / NaN 一律当 0：数据层算出个 -1 不该让页面上出现「NaN 分钟」
  const safe: number = ms > 0 ? ms : 0;
  const minutes: number = Math.floor(safe / 60000);
  if (minutes < 1) {
    return '不到 1 分钟';
  }
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const hours: number = Math.floor(minutes / 60);
  const rest: number = minutes % 60;
  return rest === 0 ? `${hours} 小时` : `${hours} 小时 ${rest} 分钟`;
}

/**
 * 「占了你 20% 的播放」那一截
 *
 * total <= 0（这个月根本没有播放）时返回空串，调用方拼串时自然省掉这一截，
 * 不会出现「占了你 NaN% 的播放」。
 */
export function echoShareText(part: number, total: number): string {
  if (total <= 0) {
    return '';
  }
  let pct: number = Math.round((part > 0 ? part : 0) / total * 100);
  if (pct < 0) {
    pct = 0;
  }
  if (pct > 100) {
    pct = 100;
  }
  return `占了你 ${pct}% 的播放`;
}

// ------------------------------------------------------------------ 数据类

/** 领奖台上的一首歌（rank 从 1 开始；页面按名次传，组件内部自己摆位） */
export class EchoPodiumSong {
  rank: number = 0;
  name: string = '';
  singer: string = '';
  coverUrl: string = '';
  /** 没有真实封面时用黑心占位（与 CoverArt 的 art 同一个语义） */
  art: boolean = false;
  plays: number = 0;
  /** 副信息后半截，一般由 echoShareText 生成；空串时只显示「N 次」 */
  share: string = '';
}

/** 榜单里的一行（第 4 名以后 / 歌手第 2 名以后 / 专辑行都用它） */
export class EchoRankRow {
  rank: number = 0;
  name: string = '';
  /** 副标题（歌手、专辑这类）；空串时这一行只显示名字 */
  sub: string = '';
  /** 右侧的次数文案（页面拼好，如「5 次」） */
  count: string = '';
}

/** 横向专辑条里的一张 */
export class EchoAlbumCard {
  name: string = '';
  coverUrl: string = '';
  art: boolean = false;
  /** 次数文案（如「1 次」） */
  meta: string = '';
}

// ------------------------------------------------------------------ 内部小工具

/** 名次文案：1st / 2nd / 3rd 之后都是 4th、5th…（领奖台只用前三，这里兜全） */
function rankLabel(rank: number): string {
  if (rank === 1) {
    return '1st';
  }
  if (rank === 2) {
    return '2nd';
  }
  if (rank === 3) {
    return '3rd';
  }
  return `${rank}th`;
}

/** 把数值收进 [min, max]（ArkTS 没有内置 clamp，图表里的比例都要先过一遍它） */
function clampNumber(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  return value > max ? max : value;
}

// ------------------------------------------------------------------ 标题

/**
 * 大节标题（「你听了什么」「你是怎样的听众」）
 *
 * 字号按截图放大到 23：月报的节标题要比普通列表的区标题（17）重一档，
 * 否则整页全是统计数字，层次分不开。
 */
@Component
export struct EchoSectionTitle {
  @Prop text: string = '';
  @Prop topMargin: number = 34;

  build() {
    Text(this.text)
      .fontSize(23)
      .fontWeight(FontWeight.Bold)
      .fontColor(E_TEXT)
      .width('100%')
      .textAlign(TextAlign.Start)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: this.topMargin })
  }
}

/** 子标题（「最常听的歌」「最常听的歌手」） */
@Component
export struct EchoSubTitle {
  @Prop text: string = '';
  @Prop topMargin: number = 20;

  build() {
    Text(this.text)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor(E_TEXT)
      .width('100%')
      .textAlign(TextAlign.Start)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: this.topMargin })
  }
}

/**
 * 年月选择器胶囊
 *
 * 只有外观：点击行为由页面包一层 `bindMenu` 实现（页面还要弹年份 / 月份菜单，
 * 组件里拿不到那些数据）。带一枚朝下的小尖角，是为了让人看得出「这里能展开」。
 */
@Component
export struct EchoPickerPill {
  @Prop text: string = '';

  build() {
    Row({ space: 3 }) {
      Text(this.text)
        .fontSize(12.5)
        .fontColor(E_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      IconGlyph({ symbol: I_CHEVRON_DOWN, iconSize: 11, color: E_TEXT_SUB })
        .accessibilityLevel('no')
    }
    .padding({ left: 12, right: 9, top: 6, bottom: 6 })
    .borderRadius(15)
    .backgroundColor(E_CARD)
    .border({ width: 1, color: E_DIVIDER })
    .constraintSize({ maxWidth: 160 })
  }
}

// ------------------------------------------------------------------ 顶部三格统计

/** 一格统计（数字 + 说明），给页面单独用；三格并排的行为见 EchoStatsRow */
@Component
export struct EchoStatCell {
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column({ space: 5 }) {
      Text(this.value)
        .fontSize(STAT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(E_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      Text(this.label)
        .fontSize(12.5)
        .fontColor(E_TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

/**
 * 三格统计：5 次播放 / 5 首歌 / 6 位歌手
 *
 * 三格等分一行、各自左对齐。「位歌手」那一格是歌手名单的入口（页面绑 `onArtists`），
 * 所以只有它带小尖角、也就只有它可点 —— 不给一个看着能点、其实点不动的样子。
 * 前两格的数字用 `value`（数字）直接转字符串，不再让页面拼。
 */
@Component
export struct EchoStatsRow {
  @Prop playCount: number = 0;
  @Prop songCount: number = 0;
  @Prop artistCount: number = 0;
  onArtists: () => void = () => {
  };

  /** 一格：数字 + 说明（`more` 时说明后面跟一枚小尖角） */
  @Builder
  cell(value: string, label: string, more: boolean) {
    Column({ space: 5 }) {
      Text(value)
        .fontSize(STAT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(E_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      Row({ space: 2 }) {
        Text(label)
          .fontSize(12.5)
          .fontColor(E_TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (more) {
          IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 11, color: E_TEXT_SUB })
            .accessibilityLevel('no')
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Row() {
      // 三格各自包一层 Column 再 layoutWeight：@Builder 的调用结果不能直接挂属性
      // （build/@Builder 内只做 UI 描述，属性必须挂在真正的组件节点上）
      Column() {
        this.cell(`${this.playCount}`, '次播放', false)
      }
      .layoutWeight(1)

      Column() {
        this.cell(`${this.songCount}`, '首歌', false)
      }
      .layoutWeight(1)

      Column() {
        this.cell(`${this.artistCount}`, '位歌手', true)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.onArtists();
      })
      // 这一格读屏当成一整句（数字 + 说明 + 能点进去做什么），不逐个元素念
      .accessibilityGroup(true)
      .accessibilityText(`点按查看这个月听过的 ${this.artistCount} 位歌手`)
      .accessibilityLevel('yes')
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}

// ------------------------------------------------------------------ 领奖台

/**
 * Top3 立体轮播（Coverflow：静止时三张卡各遮一半，翻页时三步走、全程不重叠）
 *
 * 渲染通路沿用上一版验证过的结构（这是《HarmonyOS 鸿蒙 Coverflow 3D 轮播实战》的核心结论）：
 *
 *   centerIndex / active / progress（父级 @State，唯一真相）
 *        ↓ 以 @Prop 传给每张卡
 *   EchoPodiumCard 的 @Watch 重算 → 写进自己的 @State geo* 字段
 *        ↓ 属性绑定到 geo*
 *   .translate / .scale / .rotate / .blur / .zIndex 每帧真正重绑
 *
 * **几何必须由子组件 @State 驱动**：ForEach 的 key 只负责挂哪几张卡，key 不变时 ArkUI
 * 复用节点、不会重绑父级算好塞进来的 transform（症状：数值在变、卡不动 / 卡消失）。
 *
 * 2026-10-27 第十二次调整 —— 动画改成**三步编排**（用户口径）：
 *   1. 先把左边背后那张撤掉（0% ~ 20% 淡出，然后在隐身状态下绕到右侧）；
 *   2. 中间那张移到左半边（20% ~ 60%）；
 *   3. 右边那张往前顶到台前（60% ~ 100%），同时撤掉的那张在右侧淡入。
 * 每个时刻最多只有「正在让位」的一对卡在动，而且它们不在同一位置，所以**翻页全程不会
 * 出现两张卡互相压在一起**（之前用的是连续插值，两张卡会同时穿过中心 → 才有交叠感）。
 *
 * 尺寸：三张卡整体放大（中间 200、两侧 160），侧卡中心仍压在前卡边缘
 * （PODIUM_SIDE_X = 前卡半宽），所以「各被前卡遮住一半」的关系保持不变。
 *
 * 参考：harmonyosdev.csdn.net/6a7d390c10ee7a33f29a3e1a.html（R4 / R10 / R16）
 */

/** 中间（台前）那张的封面边长 */
const PODIUM_CENTER_SIZE: number = 200;
/** 两侧封面的边长（比中间小一档） */
const PODIUM_SIDE_SIZE: number = 160;
/** 封面下方文字块的高度：名次 + 歌名 + 副信息，三张卡共用一个值 → 文字块等长 */
const PODIUM_TEXT_HEIGHT: number = 86;
/** 整块高度在「卡片 = 封面 + 文字块」之外再留的余量（旋转投影与底部留白） */
const PODIUM_BREATH: number = 16;
/**
 * 侧卡相对前卡的水平中心距 = 前卡半宽
 *
 * 侧卡中心压在前卡边缘时，被前卡盖住的部分正好是它投影宽度的一半 —— 也就是用户要的
 * 「后边两张卡分别被前边的卡片遮住一半」。这个关系与卡片大小无关，放大后依然成立。
 */
const PODIUM_SIDE_X: number = PODIUM_CENTER_SIZE / 2;
/** 侧卡绕 Y 轴角度：用户要 50°，侧得更明显（投影宽度约为原宽的 64%） */
const PODIUM_SIDE_ANGLE: number = 50;
/** 侧卡压暗一档 */
const PODIUM_SIDE_OPACITY: number = 0.93;
/** 侧卡虚化半径（vp）：用户要「极淡」，1.5 只留一点点柔化 */
const PODIUM_SIDE_BLUR: number = 1.5;
/** 侧卡 z 轴位移（px）：负值 = 往观众后方退（它本来就该在后方） */
const PODIUM_SIDE_DEPTH: number = -24;
/** 透视视距（px）：相机到 z=0 平面的距离，越小 3D 变形越强 */
const PODIUM_PERSPECTIVE: number = 1100;
/** 落定动效时长（ms）：弹簧参数主导手感，这里作为 Swiper 的动画时基 */
const PODIUM_ANIM_MS: number = 340;

/**
 * 单张轮播卡
 *
 * 只认 `rel`（当前所在的位置槽）与 `progress`（翻页进度），把几何算进 @State，
 * 再让属性绑定这些 @State —— 每一帧都是「状态变化 → 属性重绑」。
 */
@Component
struct EchoPodiumCard {
  @Require @Prop item: EchoPodiumSong;
  /** 这张卡在 items 里的下标（点它时要回传给页面） */
  @Prop index: number = 0;
  /** 这张卡相对台前的位置槽：-1 左 / 0 中 / 1 右 */
  @Prop @Watch('onGeometryDeps') rel: number = 0;
  /** 翻页进度：0 停稳；0→1 正在往前翻一页；0→-1 正在往后翻 */
  @Prop @Watch('onGeometryDeps') progress: number = 0;
  /** 这一帧进度的增量（≈ 速度），只用来给卡片算一点点跟手倾角 */
  @Prop @Watch('onGeometryDeps') motion: number = 0;
  /** 点卡回调（带状态的对象不要 @Prop） */
  onSelect: (index: number) => void = () => {
  };

  // ---- 几何：全部由 onGeometryDeps 写入，属性绑定的就是这些 ----
  @State geoX: number = 0;
  @State geoZ: number = 0;
  @State geoScale: number = 1;
  @State geoRotateY: number = 0;
  @State geoBlur: number = 0;
  @State geoOpacity: number = 1;
  @State geoZIndex: number = 0;
  @State geoShadow: number = 0;
  @State geoLeanX: number = 0;
  @State pressScale: number = 1;
  @State geoFront: boolean = false;

  aboutToAppear(): void {
    this.onGeometryDeps('');
  }

  /** 收进 0..1 */
  private unit(v: number): number {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  /** 线性插值 */
  private lerp(a: number, b: number, t: number): number {
    return a + (b - a) * t;
  }

  /** 某个位置槽的水平中心 */
  private slotX(slot: number): number {
    return slot * PODIUM_SIDE_X;
  }

  /** 某个位置槽的 Y 轴角度 */
  private slotAngle(slot: number): number {
    return slot * PODIUM_SIDE_ANGLE;
  }

  /** 某个位置槽的缩放：台前 1、两侧 160/200 */
  private slotScale(slot: number): number {
    return slot === 0 ? 1 : PODIUM_SIDE_SIZE / PODIUM_CENTER_SIZE;
  }

  /** 某个位置槽的纵深：台前 0、两侧后退 */
  private slotZ(slot: number): number {
    return slot === 0 ? 0 : PODIUM_SIDE_DEPTH;
  }

  /** 某个位置槽的虚化：台前不虚化、两侧极淡 */
  private slotBlur(slot: number): number {
    return slot === 0 ? 0 : PODIUM_SIDE_BLUR;
  }

  /** 某个位置槽的透明度：台前 1、两侧压暗 */
  private slotOpacity(slot: number): number {
    return slot === 0 ? 1 : PODIUM_SIDE_OPACITY;
  }

  /** 平滑收放（smoothstep）：两端速度为 0，不会在接缝处出现速度突变 */
  private smooth(t: number): number {
    return t * t * (3 - 2 * t);
  }

  /**
   * 中卡：单条强 ease-out 曲线（Apple 的「快起、长收尾」）
   *
   * 用一条连续可导的曲线而不是分段拼接：分段在 50% 处会出现速度折点（前段末尾速度 0、
   * 后段开头速度突然拉满），真机上手感就是「一顿」。这条曲线起步导数 ≈ 2.18（第一像素
   * 就翻起来），落位时导数为 0（软着陆）。
   */
  private centerEase(s: number): number {
    const t: number = this.unit(s);
    return 1 - Math.pow(1 - t, 2.18);
  }

  /**
   * 右卡：先慢、后快、再缓落（smoothstep ∘ 幂函数，速度两端都是 0）
   *
   * 与中卡的 2.18 指数配对：50% 时中卡走到 0.78、右卡走到 0.215 —— 两张卡正好左右对称
   * （x ≈ -78 与 +78，缩放同为 0.84，转角同为 31°），边缘间隙 ≈ 12vp，几乎相接。
   */
  private sideEase(s: number): number {
    const t: number = this.unit(s);
    return this.smooth(Math.pow(t, 1.74));
  }

  /**
   * 翻页编排：根据「槽位 + 进度」算出这张卡此刻该在哪、多大、转多少
   *
   * 正向（progress ≥ 0）：
   *   中卡  用 centerEase（单条强 ease-out）：起步就翻，50% 时已到中间偏左；
   *   右卡  用 sideEase（先慢后快、软着陆）：50% 时只到中间偏右，两卡左右对称、边缘几乎相接；
   *         之后右卡滚到台前、中卡滚到台后；
   *   左卡  0~10% 平滑淡出撤走 → 隐身绕到右槽 → 90~100% 在右槽平滑淡入（成为新右卡）。
   * 反向（progress < 0）完全镜像。
   *
   * 两条曲线都是**连续可导**的单一曲线（两端速度为 0）：分段拼接会在接缝处产生速度突变，
   * 真机手感就是「一顿」。这也是 Apple《Designing Fluid Interfaces》那条「快起、长收尾」。
   */
  onGeometryDeps(propName: string): void {
    const s: number = this.progress;
    const slot: number = this.rel;
    let fromSlot: number = slot;
    let toSlot: number = slot;
    let u: number = 0;
    let fade: number = 1;

    if (s >= 0) {
      if (slot === 0) {
        toSlot = -1;
        u = this.centerEase(s);
      } else if (slot > 0) {
        toSlot = 0;
        u = this.sideEase(s);
      } else {
        // 左卡：开头平滑淡出(0~10%)，隐身期间绕到右槽，最后(90%~100%)平滑淡入
        if (s < 0.10) {
          fade = 1 - this.smooth(this.unit(s / 0.10));
        } else if (s < 0.90) {
          fromSlot = -1;
          toSlot = 1;
          u = this.unit((s - 0.10) / 0.80);
          fade = 0;
        } else {
          fromSlot = 1;
          toSlot = 1;
          fade = this.smooth(this.unit((s - 0.90) / 0.10));
        }
      }
    } else {
      const t: number = -s;
      if (slot === 0) {
        toSlot = 1;
        u = this.centerEase(t);
      } else if (slot < 0) {
        toSlot = 0;
        u = this.sideEase(t);
      } else {
        if (t < 0.10) {
          fade = 1 - this.smooth(this.unit(t / 0.10));
        } else if (t < 0.90) {
          fromSlot = 1;
          toSlot = -1;
          u = this.unit((t - 0.10) / 0.80);
          fade = 0;
        } else {
          fromSlot = -1;
          toSlot = -1;
          fade = this.smooth(this.unit((t - 0.90) / 0.10));
        }
      }
    }

    this.geoX = this.lerp(this.slotX(fromSlot), this.slotX(toSlot), u);
    this.geoZ = this.lerp(this.slotZ(fromSlot), this.slotZ(toSlot), u);
    this.geoScale = this.lerp(this.slotScale(fromSlot), this.slotScale(toSlot), u);
    this.geoRotateY = this.lerp(this.slotAngle(fromSlot), this.slotAngle(toSlot), u);
    this.geoBlur = this.lerp(this.slotBlur(fromSlot), this.slotBlur(toSlot), u);
    this.geoOpacity = this.lerp(this.slotOpacity(fromSlot), this.slotOpacity(toSlot), u) * fade;
    // 层级：越靠中间越前（连续函数，避免擦身而过时前后突然互换）
    this.geoZIndex = 1000 - Math.round(Math.abs(this.geoX));
    // 阴影：越靠中间投影越大
    this.geoShadow = Math.max(0, 22 * (1 - Math.abs(this.geoX) / PODIUM_SIDE_X));
    this.geoFront = Math.abs(this.geoX) < PODIUM_SIDE_X * 0.5;

    // 跟手倾斜：拖得越快，卡片顺着运动方向倾得越多（最大 ±5°），停稳自动回正
    let lean: number = -this.motion * 30;
    if (lean < -5) {
      lean = -5;
    } else if (lean > 5) {
      lean = 5;
    }
    this.geoLeanX = lean;
  }

  build() {
    Column() {
      Column() {
        CoverArt({
          url: this.item.coverUrl,
          name: this.item.name,
          art: this.item.art,
          boxSize: PODIUM_CENTER_SIZE,
          radius: 14,
          fill: true,
        })
          .width('100%')
          .height('100%')
      }
      .width(PODIUM_CENTER_SIZE)
      .height(PODIUM_CENTER_SIZE)
      // 深度用真模糊（不拿 opacity 冒充），且只糊封面、文字保持可读
      .blur(this.geoBlur)

      Text(rankLabel(this.item.rank))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.geoFront ? E_GOLD : E_TEXT_SUB)
        .maxLines(1)
        .margin({ top: 8 })

      Text(this.item.name)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(E_TEXT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 2 })

      Text(this.item.share.length > 0 ? `${this.item.plays} 次 · ${this.item.share}` : `${this.item.plays} 次`)
        .fontSize(11)
        .fontColor(E_TEXT_WEAK)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 1 })
    }
    // R10：排版尺寸固定（文字不 reflow），视觉大小交给 scale
    .width(PODIUM_CENTER_SIZE)
    .height(PODIUM_CENTER_SIZE + PODIUM_TEXT_HEIGHT)
    .alignItems(HorizontalAlign.Center)
    // 真 3D：Y 轴侧转 + 跟手的小幅 X 轴倾斜（RotateAngleOptions 支持两轴同设）
    .rotate({
      angleX: this.geoLeanX,
      angleY: this.geoRotateY,
      angleZ: 0,
      centerX: '50%',
      centerY: '50%',
      centerZ: 0,
      perspective: PODIUM_PERSPECTIVE,
    })
    // centerX / centerY 必须与 rotate 一致：同时设置时以最后设置的属性为准
    .scale({
      x: this.geoScale * this.pressScale,
      y: this.geoScale * this.pressScale,
      centerX: '50%',
      centerY: '50%',
    })
    .translate({ x: this.geoX, z: this.geoZ })
    .zIndex(this.geoZIndex)
    .opacity(this.geoOpacity)
    .shadow({ radius: this.geoShadow, color: '#66000000', offsetX: 0, offsetY: 6 })
    // Apple 的第一条原则：反馈发生在「按下」的瞬间
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
          this.pressScale = 0.97;
        });
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
          this.pressScale = 1;
        });
      }
    })
    .onClick(() => {
      this.onSelect(this.index);
    })
    .accessibilityGroup(true)
    .accessibilityText(`${rankLabel(this.item.rank)}，${this.item.name}`)
    .accessibilityLevel('yes')
  }
}

@Component
export struct EchoSongPodium {
  /** 换月时页面会整体换一个新数组 → 用 @Watch 把轮播复位到第 1 名 */
  @Prop @Watch('onItemsChanged') items: EchoPodiumSong[] = [];
  onPick: (index: number) => void = () => {
  };
  /** 中心卡换人时通知页面（页面据此切换背景主题色） */
  onActive: (index: number) => void = () => {
  };
  /** 当前在台前的那张卡在 items 里的下标（0 = 第 1 名） */
  @State active: number = 0;
  /** 连续的「中心位置」：拖动/收尾时是小数，停稳时是整数 */
  @State centerIndex: number = 0;
  /** 这一帧 centerIndex 的增量（≈ 速度），只用来给卡片一点跟手倾角 */
  @State motion: number = 0;
  /** 背景主题当前用的是哪张卡（滑动过半就提前切，见 syncThemeIndex） */
  @State themeIndex: number = 0;
  /** Swiper 只当手势与进度源（页内容留空、完全透明） */
  private swiper: SwiperController = new SwiperController();

  /** items 换新（换月份 / 重新聚合完成）→ 回到第 1 名 */
  onItemsChanged(): void {
    this.active = 0;
    this.centerIndex = 0;
    this.motion = 0;
    this.themeIndex = 0;
    this.swiper.changeIndex(0, false);
    this.onActive(0);
  }

  /** items 个数 */
  private count(): number {
    return this.items.length;
  }

  /** 整块高度：卡片（200 封面 + 文字块）+ 余量 */
  private podiumHeight(): number {
    return PODIUM_CENTER_SIZE + PODIUM_TEXT_HEIGHT + PODIUM_BREATH;
  }

  /**
   * 某张卡现在处在哪个位置槽（-1 左 / 0 中 / 1 右）
   *
   * 三张以上按环形收进 (-n/2, n/2]；只有两张时不绕环（下标差就是槽位），否则左右槽
   * 会互相冒充。
   */
  private slotOf(index: number): number {
    const n: number = this.items.length;
    let rel: number = index - this.active;
    if (n >= 3) {
      rel = ((rel % n) + n) % n;
      if (rel > n / 2) {
        rel -= n;
      }
    }
    return rel;
  }

  /** 当前翻页进度（-1 ~ 1），与 slotOf 配合把「三步编排」推下去 */
  private progressNow(): number {
    return this.centerIndex - this.active;
  }

  /**
   * 逐帧回调：把「手指滑到哪了」变成连续的 centerIndex
   *
   * `proxy.position` 是选中页相对初始位置的偏移：向左翻时 0 → -1，所以
   * centerIndex = active - position（0 → +1）。收尾动画期间同样逐帧回调。
   */
  private onContentTransition(proxy: SwiperContentTransitionProxy): void {
    if (proxy.index !== proxy.selectedIndex) {
      return;
    }
    let next: number = this.active - proxy.position;
    if (next < this.active - 1) {
      next = this.active - 1;
    } else if (next > this.active + 1) {
      next = this.active + 1;
    }
    if (next !== this.centerIndex) {
      this.motion = next - this.centerIndex;
      this.centerIndex = next;
      // 背景主题色跟着动画走：进度过半就算「已经换到下一张」，往回拖过半则切回来
      this.syncThemeIndex();
    }
  }

  /** 换页完成：centerIndex 归到整数（两者在收尾那一刻本来就相等，不会跳） */
  private onPageChanged(index: number): void {
    this.active = index;
    this.motion = 0;
    if (this.centerIndex !== index) {
      this.centerIndex = index;
    }
    this.applyThemeIndex(index);
  }

  /** 滑动彻底结束（也包括没换页、弹回去的那次）：把 centerIndex 吸附到 active */
  private onSwipeSettled(): void {
    this.motion = 0;
    if (this.centerIndex !== this.active) {
      this.centerIndex = this.active;
    }
    // 弹回去（没换页）时把中途换掉的背景主题也切回来
    this.syncThemeIndex();
  }

  /**
   * 按当前进度决定「背景主题该用哪张封面」
   *
   * progress 过半（±0.5）就切到相邻那张：用户在滑动途中就能看到背景开始过渡，
   * 而不是等松手落定之后才变。往回拖回 0.5 以内会自动切回原来那张。
   */
  private syncThemeIndex(): void {
    const n: number = this.items.length;
    if (n <= 0) {
      return;
    }
    const p: number = this.progressNow();
    let target: number = this.active;
    if (p >= 0.5) {
      target = (this.active + 1) % n;
    } else if (p <= -0.5) {
      target = (this.active - 1 + n) % n;
    }
    this.applyThemeIndex(target);
  }

  /** 只有目标真的变了才通知页面（EchoView 据此交叉淡入背景） */
  private applyThemeIndex(index: number): void {
    if (index !== this.themeIndex) {
      this.themeIndex = index;
      this.onActive(index);
    }
  }

  /** 点卡：台前那张播放；左边那张往左翻、右边那张往右翻 */
  private onSelect(index: number): void {
    if (this.count() <= 0) {
      return;
    }
    const slot: number = this.slotOf(index);
    if (slot === 0) {
      this.onPick(index);
      return;
    }
    if (slot < 0) {
      this.swiper.showPrevious();
      return;
    }
    this.swiper.showNext();
  }

  build() {
    /**
     * 结构：**透明 Swiper 只负责收手势 + 给逐帧进度，真正画的是上面那层卡**
     *
     * 三张卡是 Stack 里三个真实节点（不是 Swiper 的页），所以任何时刻都在；每张卡自己
     * 持有几何 @State，由 rel / progress 的 @Watch 驱动重算重绑。
     */
    Stack({ alignContent: Alignment.Top }) {
      // 手势 / 进度来源：页内容留空、完全透明（视觉全靠上面那层卡）
      Swiper(this.swiper) {
        ForEach(this.items, (item: EchoPodiumSong, index: number) => {
          Column()
            .width('100%')
            .height(this.podiumHeight())
        }, (item: EchoPodiumSong, index: number) => `podium_page_${index}`)
      }
      .loop(this.count() > 1)
      .indicator(false)
      // 弹簧落定：Apple 口径 response ≈ 0.34s、阻尼比 ζ ≈ 0.88（快起、长收尾、几乎不回弹）
      .duration(PODIUM_ANIM_MS)
      .curve(curves.springCurve(0, 1, 340, 32))
      .cachedCount(1)
      .disableSwipe(this.count() <= 1)
      .width('100%')
      .height(this.podiumHeight())
      .customContentTransition({
        timeout: 1000,
        transition: (proxy: SwiperContentTransitionProxy): void => {
          this.onContentTransition(proxy);
        },
      })
      .onChange((index: number) => {
        this.onPageChanged(index);
      })
      .onAnimationEnd((index: number, extraInfo: SwiperAnimationEvent) => {
        this.onSwipeSettled();
      })

      // 3D 卡层：每张卡按槽位 + 进度自己算几何
      Stack({ alignContent: Alignment.Top }) {
        ForEach(this.items, (item: EchoPodiumSong, index: number) => {
          EchoPodiumCard({
            item: item,
            index: index,
            rel: this.slotOf(index),
            progress: this.progressNow(),
            motion: this.motion,
            onSelect: (i: number) => {
              this.onSelect(i);
            },
          })
        }, (item: EchoPodiumSong, index: number) => `podium_card_${index}_${item.name}_${item.coverUrl}`)
      }
      .width('100%')
      .height(this.podiumHeight())
      // 透明层不挡手势：下面 Swiper 照样能收到横向滑动
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height(this.podiumHeight())
    .accessibilityDescription('左右滑动可切换前三名')
  }
}



// ------------------------------------------------------------------ 榜单行

/**
 * 榜单列表（第 4 名以后的歌曲 / 歌手第 2 名以后 / 专辑明细行）
 *
 * `card = true` 时整块是一张深色半透明卡片（圆角 18、裁切）：月报里这些行
 * 是「一整块玻璃板」，不是一行行白条。行与行之间用一条很淡的线分开。
 * 行高固定 58，封面不占位（这一块是纯文字榜）。
 */
@Component
export struct EchoRankList {
  @Prop rows: EchoRankRow[] = [];
  @Prop card: boolean = true;
  onPick: (index: number) => void = () => {
  };

  /** 一行：名次 + 歌名/歌手 + 右侧次数 */
  @Builder
  rankRow(row: EchoRankRow, index: number, last: boolean) {
    Column() {
      Row({ space: 10 }) {
        Text(row.rank > 0 ? `${row.rank}` : '')
          .fontSize(14.5)
          .fontColor(E_TEXT_WEAK)
          .width(28)
          .textAlign(TextAlign.End)
          .maxLines(1)
        Column({ space: 3 }) {
          Text(row.name)
            .fontSize(15.5)
            .fontColor(E_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          if (row.sub.length > 0) {
            Text(row.sub)
              .fontSize(12)
              .fontColor(E_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)

        Text(row.count)
          .fontSize(12.5)
          .fontColor(E_TEXT_WEAK)
          .maxLines(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .height(RANK_ROW_HEIGHT)
      .padding({ left: 14, right: 14 })

      if (!last) {
        // 分割线：左端缩进到歌名下面（名次 28 + 间距 10 + 行内边距 14 = 52），
        // 右端缩到行内边距。**给 Row 加 padding 而不是给线加 margin**：
        // 线本身 width('100%') 再加 margin 会超出卡片宽度，被裁掉一截。
        Row() {
          Divider()
            .strokeWidth(0.6)
            .color(E_DIVIDER)
        }
        .width('100%')
        .padding({ left: 52, right: 14 })
      }
    }
    .width('100%')
    .onClick(() => {
      this.onPick(index);
    })
    .accessibilityGroup(true)
    .accessibilityText(this.rowA11y(row))
    .accessibilityLevel('yes')
  }

  /** 读屏一句读完：名次 + 名字 + 副标题 + 次数 */
  private rowA11y(row: EchoRankRow): string {
    let text: string = row.rank > 0 ? `第 ${row.rank} 名，${row.name}` : row.name;
    if (row.sub.length > 0) {
      text = `${text}，${row.sub}`;
    }
    if (row.count.length > 0) {
      text = `${text}，${row.count}`;
    }
    return text;
  }

  build() {
    Column() {
      ForEach(this.rows, (row: EchoRankRow, index: number) => {
        this.rankRow(row, index, index === this.rows.length - 1)
      }, (row: EchoRankRow, index: number) =>
        // key 带上 count（次数）：同一首歌在正听的时候次数会往上走，只按名次 + 歌名当 key
        // 的话 ForEach 认成同一行、不会再画一遍，右边的「N 次」会停在旧值上
        `rank_${row.rank}_${row.name}_${row.sub}_${row.count}_${index}`)
    }
    .width('100%')
    .backgroundColor(this.card ? E_CARD : '#00000000')
    .borderRadius(this.card ? R_CARD_DARK : 0)
    .clip(this.card)
    .padding({ top: 4, bottom: 4 })
  }
}

// ------------------------------------------------------------------ 最常听歌手

/**
 * 最常听歌手第 1 名：铺满宽度的大方图
 *
 * 封面铺满、底部压一层由透明到黑的渐变（从 y=0.45 开始变黑），
 * 左下角白色大字歌手名 + 一行「1 次播放 · 占了你 20% 的播放」。
 * 名字压在图上，所以用 26 号 + 压暗层保证任何封面下都读得清。
 */
@Component
export struct EchoArtistHero {
  @Prop name: string = '';
  @Prop coverUrl: string = '';
  @Prop art: boolean = false;
  @Prop meta: string = '';
  /**
   * 圆角
   *
   * 默认 20 是「单独一张大图卡」的圆角；页面把它和下面那张榜单拼成一张连续卡片时
   * 传 0（上下两块的圆角由外层卡片统一给），所以这里必须让调用方能改。
   */
  @Prop radius: number = 20;
  onPick: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      CoverArt({
        url: this.coverUrl,
        name: this.name,
        art: this.art,
        boxSize: 200,
        radius: 0,
        fill: true,
      })
        .width('100%')
        .height('100%')

      // 压暗层：上半透明、越往下越黑（0.45 之前全透，图的主体还能看见）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.45], ['#CC000000', 1.0]],
        })

      Column({ space: 5 }) {
        Text(this.name)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(E_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.meta.length > 0) {
          // 灰白而不是 E_TEXT_SUB：这行字压在封面图上，主题那档灰在亮封面上会糊掉
          Text(this.meta)
            .fontSize(12.5)
            .fontColor('#D9FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .aspectRatio(1)
    .borderRadius(this.radius)
    .clip(true)
    .onClick(() => {
      this.onPick();
    })
    .accessibilityGroup(true)
    .accessibilityText(this.meta.length > 0 ? `${this.name}，${this.meta}` : this.name)
    .accessibilityLevel('yes')
  }
}

// ------------------------------------------------------------------ 最常听专辑

/** 专辑条里每张卡的宽度：页面左右各 16、卡片内边距 16、卡间距 12，一屏正好露三张多一点 */
const ALBUM_CARD_WIDTH: number = 104;

/**
 * 专辑横滚区的高度
 *
 * 横向 `Scroll` 必须给显式高度：Scroll 是「铺满父容器」的容器，放在高度自适应的
 * Column 里不给高度，它会按父级给到的可用高度撑开（月报页外层是竖向 Scroll，
 * 往下发的约束很大），整张卡会莫名其妙变高。这里按「封面 104 + 两段文字 30 + 两道 6 的间距」取整。
 */
const ALBUM_SCROLL_HEIGHT: number = 152;

/**
 * 最常听专辑：深色卡片里横向排若干方形封面（可横滑，隐藏滚动条）
 *
 * 组件不知道窗口宽度，所以每张卡用固定宽度 104（比「正好三张」略小）：
 * 手机上能露出「还有下一张」的暗示，宽屏上也不会被拉成一片。
 */
@Component
export struct EchoAlbumStrip {
  @Prop items: EchoAlbumCard[] = [];
  onPick: (index: number) => void = () => {
  };

  /** 一张专辑：封面 → 专辑名（单行省略）→ 次数 */
  @Builder
  albumCard(item: EchoAlbumCard, index: number) {
    Column({ space: 6 }) {
      Column() {
        CoverArt({
          url: item.coverUrl,
          name: item.name,
          art: item.art,
          boxSize: ALBUM_CARD_WIDTH,
          radius: 12,
          fill: true,
        })
          .width('100%')
          .height('100%')
      }
      .width(ALBUM_CARD_WIDTH)
      .height(ALBUM_CARD_WIDTH)

      Text(item.name)
        .fontSize(13)
        .fontColor(E_TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      if (item.meta.length > 0) {
        Text(item.meta)
          .fontSize(11.5)
          .fontColor(E_TEXT_WEAK)
          .maxLines(1)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width(ALBUM_CARD_WIDTH)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onPick(index);
    })
    .accessibilityGroup(true)
    .accessibilityText(item.meta.length > 0 ? `${item.name}，${item.meta}` : item.name)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.items, (item: EchoAlbumCard, index: number) => {
            this.albumCard(item, index)
          }, (item: EchoAlbumCard, index: number) =>
            // 同上：meta（「N 次」）变了要重绘，key 里带上它
            `album_${item.name}_${item.meta}_${index}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(ALBUM_SCROLL_HEIGHT)
    }
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(E_CARD)
    .borderRadius(R_CARD_DARK)
    .clip(true)
  }
}

// ------------------------------------------------------------------ 听歌时段

/** 时段柱状图的柱子区域高度（24 根柱在这个高度里按最大值归一化） */
const HOUR_BAR_AREA: number = 76;
/** 柱子最小可见高度：没有播放的那一格也留一根很暗的小桩，24 个格位才数得出来 */
const HOUR_BAR_MIN: number = 3;

/**
 * 听歌时段：24 根竖柱（24 小时各一根）
 *
 * 有播放的柱用亮粉，没播放的用很暗的灰（仍保留最小高度，否则 24 个格位里
 * 没听过的那些会直接消失，图就不成「一天」的形状了）。
 * 底部一条虚线基线与 0 点 / 12 点 / 23 点三个刻度。
 *
 * counts 全为 0（或长度不足 24）时也要能画：最大值按 1 兜底，除零不会出现 NaN。
 */
@Component
export struct EchoHourChart {
  @Prop counts: number[] = [];

  /** 24 小时里最大的一次播放数（<= 0 时按 1 兜底，避免归一化除零） */
  private maxCount(): number {
    let max: number = 0;
    for (let i = 0; i < this.counts.length; i++) {
      if (this.counts[i] > max) {
        max = this.counts[i];
      }
    }
    return max > 0 ? max : 1;
  }

  /** 第 i 小时的次数（越界按 0，页面上永远是 24 根柱） */
  private countAt(index: number): number {
    return index < this.counts.length && this.counts[index] > 0 ? this.counts[index] : 0;
  }

  /** 第 i 小时柱子的高度：按最大值归一化，最小 3 */
  private barHeight(index: number): number {
    const count: number = this.countAt(index);
    if (count <= 0) {
      return HOUR_BAR_MIN;
    }
    return Math.max(HOUR_BAR_MIN, Math.round(count / this.maxCount() * HOUR_BAR_AREA));
  }

  /** 柱子颜色：有播放 = 亮粉；没播放 = 很暗的白（深色底上的「灰」） */
  private barColor(index: number): string {
    return this.countAt(index) > 0 ? E_ACCENT : '#1AFFFFFF';
  }

  build() {
    Column() {
      // 24 根柱：Row 底对齐 + 每根 layoutWeight(1) 等宽
      Row({ space: 2 }) {
        ForEach(this.hourIndexes(), (hour: number) => {
          // 宽度必须交给 layoutWeight：给 width('100%') 的话 24 根会各自撑满整行、直接溢出
          Column()
            .layoutWeight(1)
            .height(this.barHeight(hour))
            .borderRadius(2)
            .backgroundColor(this.barColor(hour))
        }, (hour: number) => `hour_${hour}_${this.countAt(hour)}`)
      }
      .width('100%')
      .height(HOUR_BAR_AREA)
      .alignItems(VerticalAlign.Bottom)

      // 基线：虚线（深色页上的一条刻度线，不抢柱子）
      Column()
        .width('100%')
        .height(1)
        .borderStyle(BorderStyle.Dashed)
        .borderWidth({ top: 1 })
        .borderColor('#26FFFFFF')
        .margin({ top: 6 })

      // 刻度：0 点 / 12 点 / 23 点，两端 + 中间分布
      Row() {
        Text('0 点')
          .fontSize(10.5)
          .fontColor(E_TEXT_WEAK)
        Blank()
        Text('12 点')
          .fontSize(10.5)
          .fontColor(E_TEXT_WEAK)
        Blank()
        Text('23 点')
          .fontSize(10.5)
          .fontColor(E_TEXT_WEAK)
      }
      .width('100%')
      .margin({ top: 5 })
    }
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(E_CARD)
    .borderRadius(R_CARD_DARK)
    .clip(true)
  }

  /** ForEach 用的 0..23：写成方法而不是在 build 里建数组（build 里只做 UI 描述） */
  private hourIndexes(): number[] {
    const list: number[] = [];
    for (let i = 0; i < 24; i++) {
      list.push(i);
    }
    return list;
  }
}

// ------------------------------------------------------------------ 听歌日历

/**
 * 日历方块边长
 *
 * 截图里 31 天**不是 7 列周历，而是一片密集小方块**：一行约 18 格、格子约 13vp、
 * 圆角很小（约 4）—— 一个月就两行（31 天 = 18 + 13），一眼能扫出「哪几天听得凶」。
 * 所以这里按「小方块阵」做，不按日历 App 那种周几对齐的表格做。
 */
const CAL_DAY_SIZE: number = 13;
/** 日历方块圆角（小方块不配大圆角，否则每一格都像药丸） */
const CAL_DAY_RADIUS: number = 4;
/** 方块之间的横竖间距 */
const CAL_DAY_GAP: number = 3;

/**
 * 听歌日历：一片小圆角方块（下标 0 = 当月 1 号）
 *
 * 有听歌的那天是粉色实心，其它是很暗的灰（也要画出来 —— 日历的「形状」靠它们）。
 * 次数越多方块越亮（透明度分档），这样一屏就能看出哪几天听得最凶。
 * 用 `Flex` 自动换行而不是固定 7 列：一行能放几格由卡片宽度决定（手机约 18 格），
 * 宽屏上自然排得更开，不会把 7 列拉成七块大方砖。
 */
@Component
export struct EchoCalendar {
  @Prop counts: number[] = [];
  /** 「31 天里有 1 天在听歌」 */
  @Prop hint: string = '';
  /** 「10 月 21 日听得最多 —— 5 次」；空串不显示 */
  @Prop bestText: string = '';

  /** 当天次数（越界按 0） */
  private countAt(index: number): number {
    return index < this.counts.length && this.counts[index] > 0 ? this.counts[index] : 0;
  }

  /**
   * 当天方块的颜色：次数越多越实
   *
   * 用同一个粉色的不同透明度分档（1→55%、2→75%、3 及以上→100%）：
   * 颜色只有一个语义 = 那天听过，浓淡表示听得多不多。
   */
  private dayColor(index: number): string {
    const count: number = this.countAt(index);
    if (count <= 0) {
      return '#1AFFFFFF';
    }
    if (count === 1) {
      return '#8CF04D7C';
    }
    if (count === 2) {
      return '#BFF04D7C';
    }
    return E_ACCENT;
  }

  /** 当月天数索引 0..n-1（ForEach 用；build 里不建数组） */
  private dayIndexes(): number[] {
    const list: number[] = [];
    for (let i = 0; i < this.counts.length; i++) {
      list.push(i);
    }
    return list;
  }

  build() {
    Column() {
      if (this.counts.length > 0) {
        // Flex 自动换行：每格固定 13、右下留 3 的间距，一行放得下多少就放多少
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.dayIndexes(), (day: number) => {
            Column()
              .width(CAL_DAY_SIZE)
              .height(CAL_DAY_SIZE)
              .borderRadius(CAL_DAY_RADIUS)
              .backgroundColor(this.dayColor(day))
              .margin({ right: CAL_DAY_GAP, bottom: CAL_DAY_GAP })
          }, (day: number) => `cal_${day}_${this.countAt(day)}`)
        }
        .width('100%')
      }

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12.5)
          .fontColor(E_TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 14 })
      }
      if (this.bestText.length > 0) {
        Text(this.bestText)
          .fontSize(12)
          .fontColor(E_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(E_CARD)
    .borderRadius(R_CARD_DARK)
    .clip(true)
  }
}

// ------------------------------------------------------------------ 完播率

/** 完播率圆环的直径 */
const RING_SIZE: number = 92;

/**
 * 完播率卡片：左边圆环（中间大字百分比）+ 右边三行说明 + 底部一行平均时长
 *
 * 圆环用系统 `Progress`（Ring）：比自绘两段圆弧稳（尺寸一改就对齐），
 * 中心百分比用 Stack 压在圆环上。rate <= 0 时环色退成灰白 ——
 * 一个 0% 的粉色空环看着像「有进度但没走到」，灰色才读得出「这个月没有完播」。
 */
@Component
export struct EchoCompletionCard {
  @Prop rate: number = 0;
  @Prop percentText: string = '0%';
  @Prop mainText: string = '';
  @Prop completeText: string = '';
  @Prop skipText: string = '';
  @Prop footText: string = '';

  /** 圆环进度值：收进 0..100（数据层算歪了也不会把环画断） */
  private ringValue(): number {
    return clampNumber(this.rate, 0, 100);
  }

  /** 环色：有完播才用亮粉，0 完播用灰白（说明这是空环） */
  private ringColor(): string {
    return this.ringValue() > 0 ? E_ACCENT : '#3AFFFFFF';
  }

  build() {
    Column() {
      Row({ space: 18 }) {
        // 圆环 + 中间百分比
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: this.ringValue(), total: 100, type: ProgressType.Ring })
            .width(RING_SIZE)
            .height(RING_SIZE)
            .color(this.ringColor())
            .backgroundColor('#26FFFFFF')
            .style({ strokeWidth: 10, enableSmoothEffect: true })
          Text(this.percentText)
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(E_TEXT)
            .maxLines(1)
            .textAlign(TextAlign.Center)
        }
        .width(RING_SIZE)
        .height(RING_SIZE)

        // 右侧三行：主文案 / 完整听完 / 中途切走
        Column({ space: 6 }) {
          if (this.mainText.length > 0) {
            Text(this.mainText)
              .fontSize(14)
              .fontColor(E_TEXT)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          if (this.completeText.length > 0) {
            Text(this.completeText)
              .fontSize(12.5)
              .fontColor(E_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          if (this.skipText.length > 0) {
            Text(this.skipText)
              .fontSize(12.5)
              .fontColor(E_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.footText.length > 0) {
        Text(this.footText)
          .fontSize(12.5)
          .fontColor(E_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 14 })
      }
    }
    .width('100%')
    .padding(CARD_PAD)
    .backgroundColor(E_CARD)
    .borderRadius(R_CARD_DARK)
    .clip(true)
  }
}
