/*
 * 回响 · 月度收听报告 —— 纯视觉组件库
 *
 * 这些组件**不含任何数据来源**：数据由页面（views/EchoView.ets）整体算好后用 `@Prop` 传进来，
 * 组件内部只读 props、只发回调（回调在点击那一刻触发，页面自己去现取数据）。
 * 接口以 `_echo_port/PORT_CONTRACT.md` §6 为唯一契约；视觉细则以 `_echo_port/paiyin-echo-spec.md`
 * 的 §3.3（各段字号 / 圆角 / 间距 / token）与 §4（3D 榜台几何）为准，逐条对应派音
 * `features/recommendation/view/EchoReviewPage.ets` 的对应段。
 *
 * 本工程的落地差异（都写在对应组件上）：
 *   · V1 状态模型：`@Component` + `@Prop`（派音是 `@ComponentV2` + `@Local`）；
 *   · 颜色走本文件顶部导出的**固定深色调色板**（`ECHO_*` 常量）：回响是沉浸式月报，
 *     **永远深色、不跟系统浅色模式**（用户 2026-11-15 明确要求）；resources 里的
 *     `echo_*` 成对 token 保留但本页不再取用；
 *   · 不加 `.shadow()` / `.blur()`：派音最新版回响全页 0 处；
 *   · 图片一律走 `ui/Widgets.ets` 的 `CoverArt`（占位 / 黑心 / 首字母兜底都在里面），
 *     所以这里**没有**派音那种 `img.length > 0 ? Image : 占位块` 分支；
 *   · 自定义组件不直接挂通用属性（`CoverArt(...).scale(...)` 不在本工程既有写法里），
 *     需要镜像 / 定尺时套一层同尺寸容器再挂属性 —— 布局等价（见 `SongCard()`）。
 *
 * 与契约的已知缺口（已报 Lead，未擅自改签名）：
 *   · `Select` 没有「隐藏下拉箭头」的 API（`ArrowPosition` 只有 START / END），
 *     契约 §6.1「无箭头」只能做到「样式统一、无手势」，箭头会保留；
 *   · 派音的 `RzdSelectMenuMaterial`（下拉菜单光感材质，API 26 系统材质）属于派音模块，
 *     本工程不 import 派音，这里用系统默认菜单，只统一按钮自身的字号 / 文字色 / 底色 / 圆角。
 */
import { curves, matrix4 } from '@kit.ArkUI';
import { CoverArt } from './Widgets';
import { MonthlyAlbum, MonthlyArtist, MonthlySong } from '../core/history/EchoMonthly';

// =====================================================================================
// 固定深色调色板（回响专用，**不跟系统深浅色**）
//
// 用户 2026-11-15 明确要求：回响是「沉浸式月报」，**默认纯黑底**，不跟随系统浅色模式；
// 背景不透明度也按旧版聆听回响的口径（模糊 70 + 0.62，叠在纯黑上）。
// resources 里的 echo_* 是 base/dark 成对的（浅色模式会翻成浅底深字）⇒ 本页不取用，
// 这里把深色值固化成常量（与 dark/element/color.json 的 echo_* 逐字一致）。
// =====================================================================================
export const ECHO_ACCENT: string = '#FF3B6B';
export const ECHO_BACKDROP_SCRIM: string = '#00000000';
export const ECHO_BAR_REST: string = '#66FFFFFF';
export const ECHO_CARD_BACKGROUND: string = '#14FFFFFF';
export const ECHO_CHIP_BACKGROUND: string = '#1FFFFFFF';
export const ECHO_HEAT_HIGH: string = '#FFFF3B6B';
export const ECHO_HEAT_LOW: string = '#4DFF3B6B';
export const ECHO_HEAT_MID: string = '#99FF3B6B';
export const ECHO_ON_PHOTO_PRIMARY: string = '#FFFFFF';
export const ECHO_ON_PHOTO_SECONDARY: string = '#CCFFFFFF';
export const ECHO_PAGE_BACKGROUND: string = '#000000';
export const ECHO_PHOTO_SCRIM: string = '#CC000000';
export const ECHO_PLACEHOLDER_BACKGROUND: string = '#22FFFFFF';
export const ECHO_RANK_BRONZE: string = '#E0A16A';
export const ECHO_RANK_GOLD: string = '#FFD54A';
export const ECHO_RANK_SILVER: string = '#D6DEE8';
export const ECHO_TEXT_CHIP: string = '#E6FFFFFF';
export const ECHO_TEXT_FAINT: string = '#88FFFFFF';
export const ECHO_TEXT_PRIMARY: string = '#FFFFFF';
export const ECHO_TEXT_RATIO: string = '#B3FFFFFF';
export const ECHO_TEXT_SECONDARY: string = '#CCFFFFFF';
export const ECHO_TEXT_TERTIARY: string = '#99FFFFFF';
export const ECHO_TEXT_UNIT: string = '#8CFFFFFF';
export const ECHO_TOP_FADE: string = '#000000';
export const ECHO_TOP_FADE_END: string = '#00000000';
export const ECHO_TRACK_BACKGROUND: string = '#33FFFFFF';

/** 榜单第 1 名的封面边长（vp）—— 同时是四点投影变换盒的边长（spec §4.1 `MAIN_CARD_VP`） */
export const ECHO_COVER_MAIN_VP: number = 150;
/** 榜单两侧（2nd / 3rd）的封面边长（vp）= 150 × 0.92（spec §4.1 `SIDE_CARD_VP`） */
export const ECHO_COVER_SIDE_VP: number = 138;

/** 侧卡横向透视收缩比：可见宽 / 边长（spec §4.1 `SIDE_SQUEEZE`，414/488 ≈ 0.848） */
const SIDE_SQUEEZE: number = 0.848;
/** 侧卡上边斜率（按收缩后的可见宽算，spec §4.1 `SIDE_TOP_SLOPE`） */
const SIDE_TOP_SLOPE: number = 0.168;
/** 侧卡下边斜率（下边往内抬，spec §4.1 `SIDE_BOTTOM_SLOPE`） */
const SIDE_BOTTOM_SLOPE: number = 0.087;

/**
 * 台面「手势层」高度（vp）
 *
 * 透明 Swiper 需要一块可触摸的区域才收得到横向滑动。这个值只是**够用**即可：
 * 真正的台面高度由卡层里那张透明的高度锚决定（见 `HeightAnchor()`），两者取大，
 * 所以这里差几个 vp 不会让页面高度变形。
 */
const PODIUM_GESTURE_VP: number = 220;
/** 翻页吸附的动画时长（ms）；手感主要交给弹簧曲线，这个只是时基（照旧版 PODIUM_ANIM_MS） */
const PODIUM_ANIM_MS: number = 340;
/** 吸附弹簧的刚度 / 阻尼（Apple 口径：快起、长收尾、几乎不回弹，照旧版参数） */
const PODIUM_SPRING_STIFFNESS: number = 340;
const PODIUM_SPRING_DAMPING: number = 32;
/** 自定义页切换的兜底超时（ms）：超时未 finish 就当作自定义动画结束（照旧版） */
const PODIUM_SWIPE_TIMEOUT_MS: number = 1000;

/** 听歌时段柱图容器高（vp，spec §3.3 卡 1 / §4.6） */
const HOUR_CHART_VP: number = 90;
/** 柱高可用空间：容器 90 里留 4vp 余量（spec §4.6 `barHeightVp` 的 86） */
const HOUR_BAR_MAX_VP: number = 86;
/** 时段柱最小高度：全 0 时也要有一条能看见的底座（spec §4.6 的 2vp） */
const HOUR_BAR_MIN_VP: number = 2;

/** 完播率圆环直径 / 线宽（vp，契约 §6.1） */
const RING_VP: number = 78;
const RING_STROKE_VP: number = 8;

/** 外层卡片圆角（契约 §6.1：所有卡片 16） */
const CARD_RADIUS: number = 16;
/** 卡内小卡圆角（歌手列表 14 / 专辑封面 10 / 高亮卡 16，按 spec §3.3） */
const INNER_CARD_RADIUS: number = 14;

/** 歌手第一名大图高（vp，契约 §6.1） */
const ARTIST_HERO_VP: number = 220;
/** 歌手 2/3/4 名行高（vp，契约 §6.1） */
const ARTIST_ROW_VP: number = 60;
/** 高亮卡（单曲循环之王 / 深夜之歌）封面边长（vp，spec §3.3 ⑧⑨） */
const HIGHLIGHT_COVER_VP: number = 64;

/** 单曲循环之王 / 深夜之歌两段的条件阈值由页面控制，这里只兜住 null；`>= 2` 的常量留给页面 */

/**
 * 占比（%）：`plays / total`。
 *
 * 总次数为 0 时给 0 而不是 NaN —— 空月份（或数据层还没算完）时榜单不该出现「占 NaN%」。
 * @param plays 该条目的播放次数
 * @param total 当月总播放次数
 * @returns 0..100 的整数
 */
function echoShareOf(plays: number, total: number): number {
  if (total <= 0) {
    return 0;
  }
  return Math.round(plays * 100 / total);
}

/**
 * 名次颜色（金 / 银 / 铜）。
 *
 * 三档都是**成对 token**：日间是压浅底可读的深金 / 深银 / 深铜，夜间是原来的亮色，
 * 所以这里不能写成固定的亮色字面量（日间会看不见）。
 * @param rank `1st` / `2nd` / `3rd`
 * @returns 该名次的颜色资源
 */
function echoRankColor(rank: string): ResourceColor {
  if (rank === '1st') {
    return ECHO_RANK_GOLD;
  }
  if (rank === '2nd') {
    return ECHO_RANK_SILVER;
  }
  return ECHO_RANK_BRONZE;
}

// =====================================================================================
// ① 页头：N 分钟 + 与上月的倍数
// =====================================================================================

/**
 * 页头（派音 `Header()`，spec §3.3 ①）。
 *
 * 主数字 24fp Bold 主文字色；副行 13fp `echo_text_ratio`，空串时整行不渲染
 * （数据层在「上个月还没记录」时才给「上个月还没有听歌记录」，见契约 §3.1 `ratioText`）。
 */
@Component
export struct EchoMonthHeader {
  /** 已算好的分钟数（数据层 `echoMinutes(totalMs)`） */
  @Prop minutes: number = 0;
  /** 与上月的倍数文案，空串 = 不显示这一行 */
  @Prop ratioText: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.minutes + ' 分钟')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(ECHO_TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.ratioText.length > 0) {
        Text(this.ratioText)
          .fontSize(13)
          .fontColor(ECHO_TEXT_RATIO)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// =====================================================================================
// ② 三格统计：次播放 / 首歌 / 位歌手
// =====================================================================================

/**
 * 三格统计（派音 `OverviewCard()` + `StatCell(kind)`，spec §3.3 ②）。
 *
 * ⚠️ 与派音同一个坑：`@Builder` 的实参只许是**常量**（这里只传 `kind`），
 * 数字在 builder **体内**读 `@Prop`。若把 `String(this.playCount)` 当实参传进来，
 * 那棵子树不建立对 `@Prop` 的依赖 ⇒ 切月份后数字永久停在首帧。
 */
@Component
export struct EchoOverviewCard {
  @Prop playCount: number = 0;
  @Prop songCount: number = 0;
  @Prop artistCount: number = 0;

  /**
   * 单格：数字 24fp Bold 主文字色 + 单位 12fp `echo_text_unit`。
   * （派音注释：三格的文字颜色**不混主题色**，数字恒主文字色、单位恒弱色位）
   * @param kind `play` / `song` / `singer`（常量）
   */
  @Builder
  private StatCell(kind: string) {
    Column({ space: 4 }) {
      Text(this.statValueOf(kind))
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(ECHO_TEXT_PRIMARY)
      Text(this.statLabelOf(kind))
        .fontSize(12)
        .fontColor(ECHO_TEXT_UNIT)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 单格的数字文案（体内读 props，保证切月份刷新） */
  private statValueOf(kind: string): string {
    if (kind === 'play') {
      return String(this.playCount);
    }
    if (kind === 'song') {
      return String(this.songCount);
    }
    return String(this.artistCount);
  }

  /** 单格的单位文案 */
  private statLabelOf(kind: string): string {
    if (kind === 'play') {
      return '次播放';
    }
    if (kind === 'song') {
      return '首歌';
    }
    return '位歌手';
  }

  build() {
    Row() {
      this.StatCell('play')
      this.StatCell('song')
      this.StatCell('singer')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }
}

// =====================================================================================
// ③ 年月两枚胶囊
// =====================================================================================

/**
 * 年 / 月两枚胶囊（派音 `MonthPicker()`，spec §3.3 ③）。
 *
 * 位置：**在三格统计下面**（不是页头上面）。两枚完全同款：高 30、13fp、
 * `echo_text_chip` 字色、`echo_chip_background` 底、圆角 15（= 高的一半，胶囊）。
 * 无左右箭头、无滑动手势 —— 只能点开下拉选。
 *
 * 与派音的差异：派音给 Select 挂了 `RzdSelectMenuMaterial`（下拉菜单的沉浸材质，
 * 依赖派音模块与 API 26 系统材质），本工程不 import 派音 ⇒ 用系统默认菜单。
 * 另外 ArkUI 的 `Select` **没有隐藏箭头的 API**，箭头会保留（契约缺口，已报 Lead）。
 */
@Component
export struct EchoMonthPicker {
  /** 年档位文案，如 `["2026 年", "2025 年"]`（新的在前，由页面排好） */
  @Prop yearLabels: string[] = [];
  /** 当前年档位下标 */
  @Prop yearIndex: number = 0;
  /** 月档位文案，如 `["10 月", "9 月"]` */
  @Prop monthLabels: string[] = [];
  /** 当前月档位下标 */
  @Prop monthIndex: number = 0;
  onPickYear: (index: number) => void = (index: number) => {};
  onPickMonth: (index: number) => void = (index: number) => {};

  /**
   * 把文案数组包成 `SelectOption[]`。
   *
   * 对象字面量必须带显式类型（ArkTS 规矩），所以先声明 `const option: SelectOption`
   * 再 push，不用 `as` 断言。
   * @param labels 档位文案
   * @returns 下拉选项数组（空数组时调用方不渲染 Select）
   */
  private optionsOf(labels: string[]): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i: number = 0; i < labels.length; i++) {
      const option: SelectOption = { value: labels[i] };
      options.push(option);
    }
    return options;
  }

  /**
   * 当前档位的按钮文案。
   *
   * 下标越界（页面重建档位的那一帧可能还是旧下标）+ 数组为空都兜成空串，
   * 免得 `Select` 去读 `undefined`。
   * @param labels 档位文案
   * @param index 当前下标
   * @returns 按钮上显示的文字
   */
  private labelAt(labels: string[], index: number): string {
    if (index < 0 || index >= labels.length) {
      return '';
    }
    return labels[index];
  }

  build() {
    Row({ space: 8 }) {
      if (this.yearLabels.length > 0) {
        Select(this.optionsOf(this.yearLabels))
          .selected(this.yearIndex)
          .value(this.labelAt(this.yearLabels, this.yearIndex))
          .height(30)
          .font({ size: 13 })
          .fontColor(ECHO_TEXT_CHIP)
          .backgroundColor(ECHO_CHIP_BACKGROUND)
          .borderRadius(15)
          .onSelect((index: number) => {
            this.onPickYear(index);
          })
      }
      if (this.monthLabels.length > 0) {
        Select(this.optionsOf(this.monthLabels))
          .selected(this.monthIndex)
          .value(this.labelAt(this.monthLabels, this.monthIndex))
          .height(30)
          .font({ size: 13 })
          .fontColor(ECHO_TEXT_CHIP)
          .backgroundColor(ECHO_CHIP_BACKGROUND)
          .borderRadius(15)
          .onSelect((index: number) => {
            this.onPickMonth(index);
          })
      }
    }
    .width('100%')
  }
}

// =====================================================================================
// 段标题
// =====================================================================================

/**
 * 段标题：18fp Bold 主文字色 + 可选副题（13fp `echo_text_tertiary`）。
 *
 * 派音的段标题是**卡片外的纯文字**（用户 2026-10-13 明确要求「文字放卡片外」），
 * 所以这个组件只画字，不带底色。
 */
@Component
export struct EchoSectionTitle {
  @Prop text: string = '';
  @Prop subtitle: string = '';

  build() {
    Column({ space: 10 }) {
      Text(this.text)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(ECHO_TEXT_PRIMARY)
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(13)
          .fontColor(ECHO_TEXT_TERTIARY)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// =====================================================================================
// ④ 你听了什么：3D 三卡榜台
// =====================================================================================

/**
 * 你听了什么：3D 三卡榜台 + **左右可翻页**（派音 `TopSongsSection()`/`SongCover()`/`sideQuadFor()`，spec §3.3 ④ / §4）
 *
 * 视觉仍是派音最新版的**四点透视**（`rotate` 那条参数路线已被派音真机证伪，不用）；
 * 翻页交互则把旧版回响那一套拉回来（`_echo_port/old/EchoReport.ets` 的 `EchoSongPodium`）：
 * **透明 Swiper 只当手势与进度源**（页内容留空、完全透明），上层按连续进度重画三张卡，
 * 吸附仍由 Swiper 自己完成（`customContentTransition` 逐帧给 position）。
 *
 * 位置编排（旧版 3-1-2 环形）：
 *   · 顺序是 **3rd 在左、1st 居中、2nd 在右**（照参考软件，不是常见的 2-1-3 领奖台）；
 *   · `centerIndex` 是**连续**的中心位置（拖动中逐帧变化，停稳后是整数）；
 *   · 每张卡到中心的**环形有符号距离** `d`：n≥3 时收进 (-n/2, n/2]；n=2 时退化成 -1/0（照旧版 `slotOf`）；
 *   · `p = min(|d|, 1)` 就是「中心形态 → 侧卡形态」的插值进度。
 *
 * 几何连续插值（**p=0 / p=1 两端与静态版逐字一致**）：
 *   box      = 150 + (138-150)·p              // 封面边长，同时是四点透视的变换盒边长
 *   squeeze  = 1 + (0.848-1)·p                // 横向收缩比
 *   topSlope = 0.168·p ; bottomSlope = 0.087·p
 *   innerX   = box·squeeze ; topDrop = innerX·topSlope ; bottomRise = innerX·bottomSlope
 *   dst      = TL(0,0) / TR(innerX, topDrop) / BL(0, box) / BR(innerX, box-bottomRise)
 *   ⇒ p=0：squeeze=1、两个斜率=0 ⇒ dst 与 src 完全重合（恒等矩阵，150 正方形、无透视）
 *     p=1：box=138、0.848 / 0.168 / 0.087 ⇒ 与静态侧卡形态完全一致。
 *
 * 水平位置用 **`.translate({x})` + 量一次容器宽度** 来插值（不用左右弹性空格）：
 *   卡片是卡层 Stack 里**自己那块 box 宽的节点**，所以命中矩形就是卡片本身（侧卡也点得到）；
 *   重叠区域由 `zIndex`（中心 2 / 两侧 1）决定谁接管点击，和视觉层级完全一致。
 *   水平位移 offset = ±p·(W - box)/2（W = 量到的台面宽；左卡为负、右卡为正）
 *   ⇒ p=1 时卡贴到容器边（左留白 0 = 页面内边距 16vp）、p=0 时正好居中，**两个端点都是精确值**，
 *     中途与理想线性最多差 ≈1.5vp（看不出来）。
 *   W 用 `onAreaChange` 量一次；量到之前 offset=0（三张都在中间，只可能出现在首帧前）。
 *   居中时（p=0）offset=0，所以 d 过零、左右身份互换的那一刻位置连续，不会跳。
 *
 * 环形绕回：三张卡里必有一张要「从一侧绕到另一侧」，它只在 |d|>1 的区间里移动，所以让它在
 * |d| 从 1 到 1.5 的过程中**淡出/淡入**，绕回发生在不可见区间内 —— 看不到瞬移
 * （旧版是「隐身绕槽 + 淡入」的三步编排，这里用透明度把同一件事做简）。
 *
 * 数据不足三张时**空位不画**（契约 §6「0..2，不足时空位不画」）；0/1 条时不建 Swiper（单卡居中，同静态版）。
 */
@Component
export struct EchoTopSongs {
  /**
   * 0..2 条（不足时空位不画）
   *
   * 换月时页面会整体换一个新数组 ⇒ `@Watch` 把轮播复位到第 1 名（照旧版 `onItemsChanged`）。
   */
  @Prop @Watch('onItemsChanged') songs: MonthlySong[] = [];
  /** 当月总播放次数，用于算每张卡的占比 */
  @Prop totalPlays: number = 0;
  /** 点**中心卡**：播这一首（点侧卡只会翻页，不会播） */
  onPlay: (index: number) => void = (index: number) => {};
  /**
   * 吸附落定后回调：现在台前的是第几名（0 = 第 1 名）
   *
   * 只在**翻页停稳**时回调（Swiper 的 onChange），拖动途中不回调 —— 页面据此换背景。
   */
  onActive: (index: number) => void = (index: number) => {};

  /** 已吸附到的页码（整数） */
  @State active: number = 0;
  /** 连续的中心位置：拖动 / 收尾时是小数，停稳时等于 `active` */
  @State centerIndex: number = 0;
  /** 台面宽度（vp）：由 `onAreaChange` 量一次，用来算卡片该推到多边上（见 `offsetXOf`） */
  @State stageWidth: number = 0;
  /** Swiper 只当手势与进度源（页内容留空、完全透明） */
  private swiper: SwiperController = new SwiperController();

  // ---------------------------------------------------------------- 翻页

  /**
   * 换数据（换月份 / 重新聚合）⇒ 轮播回到第 1 名。
   *
   * 不这么做的话：用户在第 3 名翻着，切到上个月数据只剩 2 首，页码会越界。
   */
  onItemsChanged(): void {
    this.active = 0;
    this.centerIndex = 0;
    if (this.songs.length > 1) {
      this.swiper.changeIndex(0, false);
    }
    this.onActive(0);
  }

  /**
   * 逐帧回调：把「手指滑到哪了」变成连续的 centerIndex。
   *
   * `proxy.position` 是选中页相对初始位置的偏移：向左翻时 0 → -1，所以
   * `centerIndex = active - position`（0 → +1）。收尾动画期间同样逐帧回调。
   *
   * 只认「正在动的那一页」（`index === selectedIndex`）；并把结果夹在 active±1，
   * 免得一次多页跳转把中间值算飞。
   * @param proxy Swiper 给的内容过渡代理
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
      this.centerIndex = next;
    }
  }

  /**
   * 换页完成（吸附到某一页）：centerIndex 归到整数。
   *
   * 两者在收尾那一刻本来就相等，所以这里不会跳；顺手通知页面「台前换人了」。
   * @param index 吸附到的页码
   */
  private onPageChanged(index: number): void {
    this.active = index;
    if (this.centerIndex !== index) {
      this.centerIndex = index;
    }
    this.onActive(index);
  }

  /**
   * 滑动彻底结束（也含「没换页、弹回去」那次）：把 centerIndex 吸附到 active。
   *
   * 只吸附、不回调 `onActive` —— 弹回去时台前的人没变，页面不需要换背景。
   */
  private onSwipeSettled(): void {
    if (this.centerIndex !== this.active) {
      this.centerIndex = this.active;
    }
  }

  /**
   * 名次文案：**按 index 固定**（第 1 名永远是 `1st`），不随翻页进度变。
   * @param index 榜单下标
   * @returns `1st` / `2nd` / `3rd`
   */
  private rankOf(index: number): string {
    if (index === 0) {
      return '1st';
    }
    if (index === 1) {
      return '2nd';
    }
    return '3rd';
  }


  // ---------------------------------------------------------------- 安全取数
  // @Builder 体内直接 `this.songs[index]` 在数组变短时会读到 undefined，
  // 所以统一走这几个带边界检查的取值方法。

  /** 第 index 首；越界返回 null */
  private songAt(index: number): MonthlySong | null {
    if (index < 0 || index >= this.songs.length) {
      return null;
    }
    return this.songs[index];
  }

  private coverOf(index: number): string {
    const song: MonthlySong | null = this.songAt(index);
    return song === null ? '' : song.coverUrl;
  }

  private nameOf(index: number): string {
    const song: MonthlySong | null = this.songAt(index);
    return song === null ? '' : song.name;
  }

  private artOf(index: number): boolean {
    const song: MonthlySong | null = this.songAt(index);
    return song === null ? false : song.art;
  }

  private playsOf(index: number): number {
    const song: MonthlySong | null = this.songAt(index);
    return song === null ? 0 : song.plays;
  }

  private shareOf(index: number): number {
    return echoShareOf(this.playsOf(index), this.totalPlays);
  }

  // ---------------------------------------------------------------- 几何

  /**
   * 这张卡到中心的**环形有符号距离**（负 = 在左，正 = 在右，0 = 居中）。
   *
   * n≥3 用环形收进 (-n/2, n/2]：这样「3rd 在左、1st 居中、2nd 在右」在任何一页都成立，
   * 而且翻页时中心位置即使从 -1 跳到 n-1（loop 绕回），差值恰好是 n、取模后不变 ⇒ 不跳。
   * n=2 时**不绕环**（下标差就是槽位），否则左右槽会互相冒充（照旧版 `slotOf` 的注释）。
   * @param index 榜单下标
   * @returns 有符号距离（可为小数）
   */
  private distanceOf(index: number): number {
    const n: number = this.songs.length;
    if (n <= 1) {
      return 0;
    }
    let d: number = index - this.centerIndex;
    if (n >= 3) {
      d = d - n * Math.round(d / n);
    }
    return d;
  }

  /**
   * 插值进度 p = min(|d|, 1)：0 = 中心形态，1 = 侧卡形态。
   * @param index 榜单下标
   * @returns 0..1
   */
  private progressOf(index: number): number {
    const a: number = Math.abs(this.distanceOf(index));
    return a > 1 ? 1 : a;
  }

  /**
   * 透明度：|d| ≤ 1 时完全不透明；1→1.4 之间线性淡出到 0。
   *
   * 为什么窗口收在 1.4 而不是 1.5：环形取模在 |d|=1.5 处会把卡片从一侧翻到另一侧，
   * 让它在 1.4 就已经全透明，那个翻转就绝对看不见了。
   * @param index 榜单下标
   * @returns 0..1
   */
  private alphaOf(index: number): number {
    const a: number = Math.abs(this.distanceOf(index));
    if (a <= 1) {
      return 1;
    }
    const t: number = (1.4 - a) / 0.4;
    return t < 0 ? 0 : t;
  }

  /**
   * 封面边长（vp），同时也是四点透视变换盒的边长：150 → 138 连续插值。
   * @param index 榜单下标
   * @returns 边长 vp
   */
  private boxOf(index: number): number {
    const p: number = this.progressOf(index);
    return ECHO_COVER_MAIN_VP + (ECHO_COVER_SIDE_VP - ECHO_COVER_MAIN_VP) * p;
  }

  /**
   * 封面圆角（vp）：150 ⇒ 13vp、138 ⇒ 12vp，按 p 线性插值。
   * @param index 榜单下标
   * @returns 圆角 vp
   */
  private coverRadiusOf(index: number): number {
    return 13 - this.progressOf(index);
  }

  /**
   * 右卡整层镜像用的 x 缩放因子：右侧卡 -1，左侧卡 / 中心卡 1。
   *
   * `.scale({x:-1, y:1})` 是唯一语义明确的镜像手段（锚点就是组件自己的中心）；
   * 派音试过给右卡单独写一份镜像 dst，真机上横向退化成「纯平移 +35px」，左右差 10vp。
   * 注意：d 过零时镜像会翻一次，但那一刻 p=0（恒等矩阵 + 左右权重相等）、图形对称 ⇒ 看不出跳。
   * @param index 榜单下标
   * @returns 1 或 -1
   */
  private mirrorOf(index: number): number {
    return this.distanceOf(index) > 0 ? -1 : 1;
  }

  /**
   * 卡片相对「居中位置」的水平位移（vp）：左卡为负、右卡为正、居中为 0。
   *
   * 推导：居中时卡片左边缘在 (W-box)/2；贴边时在 0（左）或 W-box（右）⇒
   * 线性插值即 offset = ∓p·(W-box)/2。p=1 / p=0 两个端点都是精确值。
   * 台面宽度还没量到时给 0（三张叠在中间，只可能出现在首帧之前）。
   * @param index 榜单下标
   * @returns 水平位移 vp
   */
  private offsetXOf(index: number): number {
    const p: number = this.progressOf(index);
    if (p <= 0 || this.stageWidth <= 0) {
      return 0;
    }
    const half: number = Math.max(0, (this.stageWidth - this.boxOf(index)) / 2);
    return this.distanceOf(index) < 0 ? -half * p : half * p;
  }

  /**
   * 量台面宽度（只在真的变了才写状态，避免每帧触发重排）。
   *
   * `Area.width` 是 `Length`（可能是 number 或 px 字符串），统一转成 number 再用。
   * @param area 布局区域
   */
  private onStageResize(area: Area): void {
    let width: number = 0;
    if (typeof area.width === 'number') {
      width = area.width;
    } else if (typeof area.width === 'string') {
      width = parseFloat(area.width);
    }
    if (width > 0 && width !== this.stageWidth) {
      this.stageWidth = width;
    }
  }

  /**
   * 文字用侧卡档（12fp / 非加粗）还是中心档（14fp / Bold）：以 p=0.5 为界。
   * @param index 榜单下标
   * @returns true = 侧卡档
   */
  private isSideStyle(index: number): boolean {
    return this.progressOf(index) >= 0.5;
  }

  /**
   * 层级：中心 2、两侧 1。
   * @param index 榜单下标
   * @returns 2 或 1
   */
  private zIndexOf(index: number): number {
    return this.progressOf(index) <= 0.5 ? 2 : 1;
  }

  /**
   * 全新的单位矩阵。
   *
   * ⚠️ **禁止 `matrix4.identity()`**：`Matrix4Transit` 的 `setPolyToPoly / translate / scale / combine`
   * 都是**就地修改**调用它的那个对象，而 `matrix4.identity()` 疑似返回同一个共享对象 ⇒ 同一帧里
   * 连造三张卡会互相污染（派音真机症状：左卡对、右卡退化成纯平移、中间的 1st 被轻微压扁）。
   * `matrix4.init()` 传 16 个数字才会真正**新建**一个矩阵对象。
   * @returns 单位矩阵
   */
  private freshIdentity(): Matrix4Transit {
    return matrix4.init([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
  }

  /**
   * 这张卡的**四点透视投影矩阵**（把静态版那套常量换成按 p 插值）。
   *
   * 形状（以左侧卡为例，外边在左）：外边 TL/BL 原地不动（满高、严格竖直）；
   * 内边挪到 x = box × squeeze（横向收缩 = 绕竖轴旋转的透视）；上边 TR 下沉、下边 BR 上抬。
   * p=0 时 squeeze=1、两个斜率=0 ⇒ dst 与 src 完全重合（恒等矩阵），也就是静态版的中心形态。
   *
   * ⚠️ 三个必写参数（spec §4.2 / §8.5）：
   *   · `pointCount: 4` 才是透视矩阵（0/1/2/3 = 恒等/平移/仿射/含剪切仿射）；
   *   · `dstIndex` 默认是 `src.length/2`（这里会变成 2！）⇒ **必须显式传 0**；
   *   · `Point.x/y` 单位是 **px** ⇒ 必须 `vp2px` 换算（这里用 `getUIContext()`）。
   *
   * 矩阵加在**整列**（封面 + 三行文字）上，但 src/dst 只按封面边长给：这套映射在 y 方向是线性的
   * （`y' = y·s(ξ) + ξ·topDrop`），超出 `[0, box]` 的 y 会被同一线性关系外推 ⇒ 下面三行文字
   * 自动拿到同一个透视（一起斜、一起横向收窄），并且与封面底边无缝衔接（不出台阶）。
   *
   * @param index 榜单下标
   * @returns 变换矩阵
   */
  private quadFor(index: number): Matrix4Transit {
    const p: number = this.progressOf(index);
    const box: number = this.boxOf(index);
    const squeeze: number = 1 + (SIDE_SQUEEZE - 1) * p;
    const topSlope: number = SIDE_TOP_SLOPE * p;
    const bottomSlope: number = SIDE_BOTTOM_SLOPE * p;
    const side: number = this.getUIContext().vp2px(box);
    const innerX: number = side * squeeze;
    const topDrop: number = innerX * topSlope;
    const bottomRise: number = innerX * bottomSlope;
    // 点序 TL,TR,BL,BR（与官方示例一致；src/dst 同序，映射只认「第 i 对第 i」）
    const src: matrix4.Point[] = [
      { x: 0, y: 0 },
      { x: side, y: 0 },
      { x: 0, y: side },
      { x: side, y: side }
    ];
    const dst: matrix4.Point[] = [
      { x: 0, y: 0 },
      { x: innerX, y: topDrop },
      { x: 0, y: side },
      { x: innerX, y: side - bottomRise }
    ];
    return this.freshIdentity().setPolyToPoly({
      src: src,
      dst: dst,
      srcIndex: 0,
      dstIndex: 0,
      pointCount: 4
    });
  }

  /**
   * 单张歌曲卡：封面 + 名次 + 歌名 + 「N 次 · 占 X%」，整列一起做四点透视。
   *
   * ⚠️ 与派音同一个坑：参数只许是**常量**（`index` 0/1/2），数据与进度全部在体内读
   * `this.songs` / `this.centerIndex` —— 否则切月份后歌名 / 封面 / 次数会永久停在首帧，
   * 连 `onClick` 闭包捕获的都是旧对象（点旧卡播旧歌）。
   *
   * 结构（四层，缺一不可）：
   *   1. 外层「定位层」Column（宽 = box）：`.translate({x})` 把它推到该在的位置，命中也靠它；
   *   2. 「镜像层」Column（宽 = box）：右卡 `.scale({x:-1})` 整层镜像，左卡 / 中卡是空操作；
   *   3. 「卡片本体」Column：`.scale({centerX:0, centerY:0, x:1})` + `.transform(矩阵)`；
   *      前一句是官方 `setPolyToPoly` 示例的硬性要求 —— 把变换中心从「组件中心」挪到「左上角」，
   *      否则四点坐标会被当成相对中心的坐标（`x:1` 是恒等缩放、不改尺寸）；
   *   4. 卡内每个 Image / Text 各自再 `.scale({x: mirror, y:1})` 反镜像一次 ⇒ 右卡的文字 / 照片
   *      方向依然正常（不会被镜像成反字）。
   *
   * 点击：中心卡播放，侧卡只翻页（见 `onCardClick`）。热区是**外层未变换的 Row/镜像层矩形**，
   * 四点透视只作用在内层本体上，所以透视不会把点击区挪走。
   *
   * @param index 榜单下标（常量 0/1/2）
   */
  @Builder
  private SongCard(index: number) {
    // 定位层：一个 box 宽的节点 —— 它的矩形**就是**这张卡的命中区域，
    // 所以侧卡也点得到；重叠处由 zIndex 决定谁接管（与视觉层级一致）。
    Column() {
      // 镜像层：右卡整层水平镜像
      Column() {
        Column({ space: 6 }) {
          // 封面：CoverArt 的占位 / 黑心 / 首字母兜底都在组件内部，这里不用判空
          Column() {
            CoverArt({
              url: this.coverOf(index),
              name: this.nameOf(index),
              art: this.artOf(index),
              boxSize: this.boxOf(index),
              radius: this.coverRadiusOf(index)
            })
          }
          .width(this.boxOf(index))
          .height(this.boxOf(index))
          .scale({ x: this.mirrorOf(index), y: 1 })

          Text(this.rankOf(index))
            .fontSize(12)
            .fontColor(echoRankColor(this.rankOf(index)))
            .scale({ x: this.mirrorOf(index), y: 1 })
          Text(this.nameOf(index))
            .fontSize(this.isSideStyle(index) ? 12 : 14)
            .fontWeight(this.isSideStyle(index) ? FontWeight.Normal : FontWeight.Bold)
            .fontColor(ECHO_TEXT_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .scale({ x: this.mirrorOf(index), y: 1 })
          Text(this.playsOf(index) + ' 次 · 占 ' + this.shareOf(index) + '%')
            .fontSize(11)
            .fontColor(ECHO_TEXT_FAINT)
            .maxLines(1)
            .scale({ x: this.mirrorOf(index), y: 1 })
        }
        .width(this.boxOf(index))
        .alignItems(HorizontalAlign.Center)
        // ★ 官方 setPolyToPoly 示例要求：变换中心挪到左上角（x:1 不改尺寸）
        .scale({ centerX: 0, centerY: 0, x: 1 })
        .transform(this.quadFor(index))
      }
      .width(this.boxOf(index))
      .scale({ x: this.mirrorOf(index), y: 1 })
    }
    .width(this.boxOf(index))
    // ★ 水平位置：左卡为负、右卡为正（见 offsetXOf）
    .translate({ x: this.offsetXOf(index) })
    // 绕回那一张在 |d|>1 时淡出（见 alphaOf）
    .opacity(this.alphaOf(index))
    // 中间那张要在最上层，才能压住左右两侧的内边
    .zIndex(this.zIndexOf(index))
    // ★ 点击那一刻才把 index 交给页面 / 控制器，闭包里不留状态快照
    .onClick(() => {
      this.onCardClick(index);
    })
  }

  /**
   * 台面**高度锚**：一张完全透明、按「中心形态」排的卡。
   *
   * 为什么需要它：滑动途中三张卡的 box 都 < 150，卡层高度会跟着缩，于是台面高度在翻页时
   * 会一抽一抽的。这里用一张不可见的「中心形态卡」把卡层高度钉死（等于静态版的高度），
   * 滑动时高度不再变化。
   */
  @Builder
  private HeightAnchor() {
    Row() {
      Column().layoutWeight(0.5)
      Column({ space: 6 }) {
        Column()
          .width(ECHO_COVER_MAIN_VP)
          .height(ECHO_COVER_MAIN_VP)
        Text('1st').fontSize(12)
        Text('占位').fontSize(14).fontWeight(FontWeight.Bold)
        Text('0 次').fontSize(11)
      }
      .width(ECHO_COVER_MAIN_VP)
      .alignItems(HorizontalAlign.Center)
      Column().layoutWeight(0.5)
    }
    .width('100%')
    .opacity(0)
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 点卡：中心卡播放；侧卡把它翻到中间（**不播放**）。
   * @param index 被点的卡下标
   */
  private onCardClick(index: number): void {
    const d: number = this.distanceOf(index);
    if (Math.abs(d) < 0.5) {
      this.onPlay(index);
      return;
    }
    if (d < 0) {
      this.swiper.showPrevious();
    } else {
      this.swiper.showNext();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ① 手势 / 进度层（最底）：页内容留空、完全透明，只收横向手势 + 给逐帧进度
      if (this.songs.length > 1) {
        Swiper(this.swiper) {
          ForEach(this.songs, (item: MonthlySong, index: number) => {
            Column()
              .width('100%')
              .height(PODIUM_GESTURE_VP)
          }, (item: MonthlySong, index: number) => 'podium_page_' + index)
        }
        .loop(true)
        .indicator(false)
        .duration(PODIUM_ANIM_MS)
        .curve(curves.springCurve(0, 1, PODIUM_SPRING_STIFFNESS, PODIUM_SPRING_DAMPING))
        .cachedCount(1)
        .width('100%')
        .height(PODIUM_GESTURE_VP)
        .customContentTransition({
          timeout: PODIUM_SWIPE_TIMEOUT_MS,
          transition: (proxy: SwiperContentTransitionProxy): void => {
            this.onContentTransition(proxy);
          }
        })
        .onChange((index: number) => {
          this.onPageChanged(index);
        })
        .onAnimationEnd((index: number, extraInfo: SwiperAnimationEvent) => {
          this.onSwipeSettled();
        })
      }

      // ② 卡层（顶层）：Transparent 让横向手势穿到下面的 Swiper，卡自己的 onClick 仍然生效
      Stack({ alignContent: Alignment.Bottom }) {
        this.HeightAnchor()
        if (this.songs.length > 2) {
          this.SongCard(2)
        }
        if (this.songs.length > 1) {
          this.SongCard(1)
        }
        if (this.songs.length > 0) {
          this.SongCard(0)
        }
      }
      .width('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.onStageResize(newValue);
      })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
  }
}

// =====================================================================================
// ⑤ 最常听的歌手：冠军大图 + 2/3/4 名列表
// =====================================================================================

/**
 * 最常听的歌手（派音 `TopArtistSection()`，spec §3.3 ⑤）。
 *
 * 结构是**卡套卡**（派音注释 1622）：外层一张 `padding 14` 的卡片，里面
 *   · 第一名：高 220 的大图 + 底部一条 `echo_photo_scrim` 暗蒙层文字带（26fp Bold / 12fp），
 *     整卡圆角 14、`clip(true)`、可点；
 *   · 2/3/4 名：一张圆角 14 的连续卡，每行高 60（序号 15fp / 封面 40×40 r6 / 名字 15fp / 次数 12fp）。
 *
 * 大图与列表都走 `CoverArt`（契约 §2.7）：无图时它自己给占位，`art=true` 时给黑心，
 * 所以这里没有派音的 `img.length > 0` 分支。
 */
@Component
export struct EchoTopArtists {
  /** 0..3 位（不足时空位不画） */
  @Prop artists: MonthlyArtist[] = [];
  /** 当月总播放次数，用于算第一名的占比 */
  @Prop totalPlays: number = 0;
  onOpen: (index: number) => void = (index: number) => {};

  /** 第 index 位歌手；越界返回 null（数组变短的那一帧不崩） */
  private artistAt(index: number): MonthlyArtist | null {
    if (index < 0 || index >= this.artists.length) {
      return null;
    }
    return this.artists[index];
  }

  private nameOf(index: number): string {
    const artist: MonthlyArtist | null = this.artistAt(index);
    return artist === null ? '' : artist.name;
  }

  private coverOf(index: number): string {
    const artist: MonthlyArtist | null = this.artistAt(index);
    return artist === null ? '' : artist.coverUrl;
  }

  private artOf(index: number): boolean {
    const artist: MonthlyArtist | null = this.artistAt(index);
    return artist === null ? false : artist.art;
  }

  private playsOf(index: number): number {
    const artist: MonthlyArtist | null = this.artistAt(index);
    return artist === null ? 0 : artist.plays;
  }

  /**
   * 大图副题：`N 次播放 · 占了你 X% 的播放`（spec §3.3 ⑤）。
   * @param index 歌手下标
   * @returns 副题文案
   */
  private heroSubtitleOf(index: number): string {
    return this.playsOf(index) + ' 次播放 · 占了你 ' +
      echoShareOf(this.playsOf(index), this.totalPlays) + '% 的播放';
  }

  build() {
    Column({ space: 10 }) {
      if (this.artists.length > 0) {
        // ---- 第一名：大图卡（图 220 + 暗蒙层文字带）----
        Column() {
          Column() {
            CoverArt({
              url: this.coverOf(0),
              name: this.nameOf(0),
              art: this.artOf(0),
              boxSize: ARTIST_HERO_VP,
              radius: 0,
              fill: true
            })
          }
          .width('100%')
          .height(ARTIST_HERO_VP)

          Column({ space: 4 }) {
            Text(this.nameOf(0))
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              // 这行字压在**照片上的暗蒙层**（echo_photo_scrim）上，不是压页面底：
              // 两个主题都用白字，否则日间就是「深字压深蒙层」，直接不可读。
              .fontColor(ECHO_ON_PHOTO_PRIMARY)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text(this.heroSubtitleOf(0))
              .fontSize(12)
              .fontColor(ECHO_ON_PHOTO_SECONDARY)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 14 })
          // 照片上的蒙层：base / dark 同值，故意不跟主题翻
          .backgroundColor(ECHO_PHOTO_SCRIM)
        }
        .width('100%')
        .borderRadius(INNER_CARD_RADIUS)
        .clip(true)
        .onClick(() => {
          this.onOpen(0);
        })

        // ---- 2/3/4 名：一张连续卡，每行 60 高 ----
        if (this.artists.length > 1) {
          Column() {
            ForEach(this.artists.slice(1), (item: MonthlyArtist, index: number) => {
              Row({ space: 12 }) {
                Text(String(index + 2))
                  .fontSize(15)
                  .fontColor(ECHO_TEXT_PRIMARY)
                  .width(22)
                CoverArt({
                  url: item.coverUrl,
                  name: item.name,
                  art: item.art,
                  boxSize: 40,
                  radius: 6
                })
                Text(item.name)
                  .fontSize(15)
                  .fontColor(ECHO_TEXT_PRIMARY)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.plays + ' 次')
                  .fontSize(12)
                  .fontColor(ECHO_TEXT_TERTIARY)
              }
              .width('100%')
              .height(ARTIST_ROW_VP)
              // 行下标 index 是 0 起的「列表下标」，对应的歌手下标是 index + 1
              .onClick(() => {
                this.onOpen(index + 1);
              })
            // key 带上 index 与播放次数：重名歌手不会撞 key 丢项；次数进 key 才能让
            // ArkUI 在切月后重跑 itemBuilder（key 不变时它复用节点、不重建内容）
            }, (item: MonthlyArtist, index: number) => 'artist_' + index + '_' + item.name
              + '_' + item.plays)
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(ECHO_CARD_BACKGROUND)
          .borderRadius(INNER_CARD_RADIUS)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(ECHO_CARD_BACKGROUND)
    .borderRadius(CARD_RADIUS)
  }
}

// =====================================================================================
// ⑥ 最常听的专辑：3 张平分横排
// =====================================================================================

/**
 * 最常听的专辑（派音 `TopAlbumsSection()`，spec §3.3 ⑥）。
 *
 * 一张圆角 16 的卡里 `Row({space:10})` 三张平分（`layoutWeight(1)`）：
 * 封面 `width 100% + aspectRatio(1)` + r10，专辑名 12fp，次数 11fp `echo_text_faint`。
 *
 * ⚠️ 与派音的**有意差异**：派音在只有 1~2 张时让它们平分整行（封面会被拉得很大），
 * 这里改成**固定 3 个等宽槽位**（不足的槽位用空 Column 占位），保证封面尺寸恒定。
 * 若要与派音逐字一致，删掉 build() 里那段 `if (this.albums.length === 1/2)` 的占位即可。
 */
@Component
export struct EchoTopAlbums {
  /** 0..2 张 */
  @Prop albums: MonthlyAlbum[] = [];
  onOpen: (index: number) => void = (index: number) => {};

  build() {
    Column({ space: 10 }) {
      if (this.albums.length > 0) {
        Row({ space: 10 }) {
          ForEach(this.albums, (item: MonthlyAlbum, index: number) => {
            Column({ space: 6 }) {
              // 封面：宽度吃满这一格、正方形、r10；CoverArt(fill) 铺满
              Column() {
                CoverArt({
                  url: item.coverUrl,
                  name: item.name,
                  art: item.art,
                  boxSize: 64,
                  radius: 10,
                  fill: true
                })
              }
              .width('100%')
              .aspectRatio(1)
              Text(item.name)
                .fontSize(12)
                .fontColor(ECHO_TEXT_PRIMARY)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(item.plays + ' 次')
                .fontSize(11)
                .fontColor(ECHO_TEXT_FAINT)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.onOpen(index);
            })
            // key 带上 index 与播放次数：同名专辑不会撞 key，且切月后次数变化能重跑 itemBuilder
          }, (item: MonthlyAlbum, index: number) => 'album_' + index + '_' + item.name
            + '_' + item.plays)
          // ★ 不足 3 张时补「空位」占住 1/3 宽度。
          //   不补的话 Row 里只剩 1~2 个 layoutWeight(1) 的格子，它们会把整行吃满 ——
          //   只听过 1 张专辑时封面会被拉成约 300vp 的正方形，比歌手区 220 高的大图还大，
          //   明显是画崩了。数据层上限就是 3 张（EchoMonthly 的 TOP_ALBUM_LIMIT），最多补 2 个。
          if (this.albums.length === 1) {
            Column().layoutWeight(1)
            Column().layoutWeight(1)
          } else if (this.albums.length === 2) {
            Column().layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(ECHO_CARD_BACKGROUND)
    .borderRadius(CARD_RADIUS)
  }
}

// =====================================================================================
// ⑦ 你是怎样的听众：时段柱图 + 日历热力
// =====================================================================================

/**
 * 你是怎样的听众（派音 `AudienceSection()`，spec §3.3 ⑦）。
 *
 * 两张卡（用户 2026-10-13 明确「听歌时段和听歌日历是两张卡片」），小标题都在卡外：
 *   · 卡 1 听歌时段：`Row({space:2})` 24 根柱，容器高 90，柱宽圆角 3，
 *     峰值柱 `echo_accent` / 其余 `echo_bar_rest`，柱高按 `hourAxisMax` 自适应（§4.6）；
 *   · 卡 2 听歌日历：`Grid` 16 列（31 天排两行），gap 2，宽 100% / 高 60，
 *     格子 `aspectRatio(1)` r3，色阶 0 / 1 / 2 / ≥3 四档。
 *
 * 日历第一行文案的天数用 `days.length`（当月天数）而不是写死 31 —— 聆听给的
 * `dayBuckets` 是「定长 = 当月天数」，2 月就只该有 28 / 29 格。
 */
@Component
export struct EchoAudience {
  /** 定长 24：各小时播放次数 */
  @Prop hours: number[] = [];
  /** 定长 = 当月天数，下标 0 = 1 号 */
  @Prop days: number[] = [];
  /** 「10 月」（用于「10 月 11 日听得最多」那一行） */
  @Prop monthLabel: string = '';
  /** 有听歌的天数 */
  @Prop listenDays: number = 0;
  /** 最长连续有听歌的天数 */
  @Prop longestStreak: number = 0;
  /** 听得最多的那天（1..31，0 = 无） */
  @Prop bestDay: number = 0;
  /** 听得最多的那天听了几次（0 = 无） */
  @Prop bestDayCount: number = 0;

  /**
   * 纵轴上限：把当前最大值「向上取整到 nice 值」（4/5/7/10/12/15/20…），保证柱子不截断。
   * 全 0 ⇒ 返回 0（调用方据此给 2vp 底座）。见 spec §4.6。
   * @returns 纵轴上限
   */
  private hourAxisMax(): number {
    let max: number = 0;
    for (let i: number = 0; i < this.hours.length; i++) {
      if (this.hours[i] > max) {
        max = this.hours[i];
      }
    }
    if (max <= 0) {
      return 0;
    }
    const steps: number[] = [4, 5, 7, 10, 12, 15, 20, 25, 30, 40, 50, 70, 100];
    for (let i: number = 0; i < steps.length; i++) {
      if (max <= steps[i]) {
        return steps[i];
      }
    }
    return Math.ceil(max / 50) * 50;
  }

  /**
   * 柱高（vp）：按自适应上限归一；容器 90 里留 4vp 余量，最低 2vp。
   * @param count 该小时的播放次数
   * @returns 柱高 vp
   */
  private barHeightVp(count: number): number {
    const axisMax: number = this.hourAxisMax();
    if (axisMax <= 0) {
      return HOUR_BAR_MIN_VP;
    }
    return Math.max(HOUR_BAR_MIN_VP, Math.round(count * HOUR_BAR_MAX_VP / axisMax));
  }

  /**
   * 峰值小时（用于给柱子高亮）。
   *
   * `bestCount` 从 -1 起 ⇒ 全 0 时返回 0（0 点会被高亮，与派音一致）。
   * @returns 峰值小时下标
   */
  private peakHour(): number {
    let best: number = 0;
    let bestCount: number = -1;
    for (let i: number = 0; i < this.hours.length; i++) {
      if (this.hours[i] > bestCount) {
        bestCount = this.hours[i];
        best = i;
      }
    }
    return best;
  }

  /**
   * 日历格颜色（热力图）：0 次 = 卡片底、1 次 = 低热、2 次 = 中热、≥3 次 = 高热。
   *
   * 四个都是成对 token（日间是深玫红各档 α、夜间是亮玫红各档 α）——
   * 不能返回写死的十六进制，否则日间压在浅底上等于看不见。
   * @param count 当天播放次数
   * @returns 该格底色
   */
  private dayColor(count: number): ResourceColor {
    if (count <= 0) {
      return ECHO_CARD_BACKGROUND;
    }
    if (count === 1) {
      return ECHO_HEAT_LOW;
    }
    if (count === 2) {
      return ECHO_HEAT_MID;
    }
    return ECHO_HEAT_HIGH;
  }

  /** 当月天数：空数组兜成 31（不该发生，但不让文案出现「0 天里有…」） */
  private dayTotal(): number {
    return this.days.length > 0 ? this.days.length : 31;
  }

  /** 日历第三行文案：数据层给 0 时走「还没有哪一天听得特别多」兜底 */
  private bestDayText(): string {
    if (this.bestDayCount <= 0) {
      return '还没有哪一天听得特别多';
    }
    return this.monthLabel + ' ' + this.bestDay + ' 日听得最多 —— ' + this.bestDayCount + ' 次';
  }

  build() {
    Column({ space: 10 }) {
      // ---------------- 卡 1：听歌时段 ----------------
      Text('听歌时段')
        .fontSize(13)
        .fontColor(ECHO_TEXT_TERTIARY)
        .width('100%')
        .textAlign(TextAlign.Start)
      Column({ space: 10 }) {
        Row({ space: 2 }) {
          ForEach(this.hours, (count: number, hour: number) => {
            Column() {
              Column()
                .width('100%')
                .height(this.barHeightVp(count))
                .borderRadius(3)
                .backgroundColor(hour === this.peakHour()
                  ? ECHO_ACCENT
                  : ECHO_BAR_REST)
            }
            .layoutWeight(1)
            .height(HOUR_CHART_VP)
            .justifyContent(FlexAlign.End)
          // key 里必须并入 count：ArkUI 的 ForEach 在 key 不变时复用节点、不重跑 itemBuilder，
          // 只用 'hour_'+hour 的话切月后柱高会停在上个月（派音侧同样写法，属移植引入的缺陷）
          }, (count: number, hour: number) => 'hour_' + hour + '_' + count)
        }
        .width('100%')
        .height(HOUR_CHART_VP)
        .alignItems(VerticalAlign.Bottom)

        Row() {
          Text('0 点').fontSize(11).fontColor(ECHO_TEXT_FAINT)
          Blank()
          Text('12 点').fontSize(11).fontColor(ECHO_TEXT_FAINT)
          Blank()
          Text('23 点').fontSize(11).fontColor(ECHO_TEXT_FAINT)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .backgroundColor(ECHO_CARD_BACKGROUND)
      .borderRadius(CARD_RADIUS)

      // ---------------- 卡 2：听歌日历 ----------------
      Text('听歌日历')
        .fontSize(13)
        .fontColor(ECHO_TEXT_TERTIARY)
        .width('100%')
        .textAlign(TextAlign.Start)
      Column({ space: 10 }) {
        Grid() {
          ForEach(this.days, (count: number, dayIndex: number) => {
            GridItem() {
              Column()
                .width('100%')
                .aspectRatio(1)
                .borderRadius(3)
                .backgroundColor(this.dayColor(count))
            }
            // 同上：key 里并入 count，切月后日历热力才会重刷
          }, (count: number, dayIndex: number) => 'day_' + dayIndex + '_' + count)
        }
        // 一行 16 格 ⇒ 31 天排成 2 行（用户 2026-10-13 明确「官方是两行小方块」）
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
        .rowsGap(2)
        .columnsGap(2)
        .width('100%')
        .height(60)

        // 三行说明（官方版式）
        Text(this.dayTotal() + ' 天里有 ' + this.listenDays + ' 天在听歌')
          .fontSize(12)
          .fontColor(ECHO_TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('最长连续 ' + this.longestStreak + ' 天没断过')
          .fontSize(12)
          .fontColor(ECHO_TEXT_TERTIARY)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.bestDayText())
          .fontSize(12)
          .fontColor(ECHO_TEXT_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .backgroundColor(ECHO_CARD_BACKGROUND)
      .borderRadius(CARD_RADIUS)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

// =====================================================================================
// ⑧ / ⑨ 单曲循环之王 / 深夜之歌（同一个组件，换标题与副行文案）
// =====================================================================================

/**
 * 单曲循环之王 / 深夜之歌（派音 `LoopKingSection()` / `NightSongSection()`，spec §3.3 ⑧⑨）。
 *
 * 两段除文案外结构完全相同，所以合成一个组件：`title` 与 `countText` 由页面给。
 *
 * ⚠️ `title` 入参**不在这里渲染**：页面已经用 `EchoSectionTitle` 单独画了段标题
 * （见 views/EchoView.ets 的 `loopKingSection()` / `nightSongSection()`），
 * 这个组件只负责下面那张卡，否则段标题会出现两遍。
 *
 * 卡片：`Row({space:12})` + padding 16 + r16 + 卡片底；
 * 封面 64×64 r8，歌名 18fp Bold、歌手 13fp secondary、第三行 12fp tertiary。
 * `song === null` 时整张卡不画（页面也会先判一次，这里是第二道保险）。
 */
@Component
export struct EchoSongHighlight {
  /** 段标题文案（契约要求入参保留；实际渲染由页面的 EchoSectionTitle 负责） */
  @Prop title: string = '';
  /** 这首歌；null = 不画 */
  @Prop song: MonthlySong | null = null;
  /** 第三行文案，如「连着放了 7 遍」/「深夜听了 3 次」 */
  @Prop countText: string = '';
  onPlay: () => void = () => {};

  // song 是 `MonthlySong | null`：ArkTS 对「成员表达式的类型收窄」在闭包 / builder 里不可靠，
  // 所以统一用这几个带 null 兜底的方法取值，不在 build 里写 `this.song!.name`。
  private songName(): string {
    return this.song === null ? '' : this.song.name;
  }

  private songSinger(): string {
    return this.song === null ? '' : this.song.singer;
  }

  private songCover(): string {
    return this.song === null ? '' : this.song.coverUrl;
  }

  private songArt(): boolean {
    return this.song === null ? false : this.song.art;
  }

  build() {
    // 根节点必须是单个组件 ⇒ 外面套一层 Column，null 时它自然高度为 0
    Column() {
      if (this.song !== null) {
        Row({ space: 12 }) {
          CoverArt({
            url: this.songCover(),
            name: this.songName(),
            art: this.songArt(),
            boxSize: HIGHLIGHT_COVER_VP,
            radius: 8
          })
          Column({ space: 4 }) {
            Text(this.songName())
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(ECHO_TEXT_PRIMARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.songSinger())
              .fontSize(13)
              .fontColor(ECHO_TEXT_SECONDARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.countText)
              .fontSize(12)
              .fontColor(ECHO_TEXT_TERTIARY)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(16)
        .borderRadius(CARD_RADIUS)
        .backgroundColor(ECHO_CARD_BACKGROUND)
        .onClick(() => {
          this.onPlay();
        })
      }
    }
    .width('100%')
  }
}

// =====================================================================================
// ⑩ 完播率
// =====================================================================================

/**
 * 完播率（派音 `CompletionSection()`，spec §3.3 ⑩）。
 *
 * 左边圆环 78×78 / 线宽 8 / `echo_accent`，环心百分比 18fp Bold；
 * 右边三行 + 卡底一行「平均每个听歌日 N 分钟」。
 *
 * 口径说明那一行**故意不画**（用户 2026-10-14 让删，派音注释 1834-1835）：
 * 页面只呈现结果，不在界面上解释「≥85% 算完整」。
 */
@Component
export struct EchoCompletionCard {
  /** 0..100 整数 */
  @Prop rate: number = 0;
  /** 被听到最后的首数（页面文案「重复播放 N 首」） */
  @Prop completeCount: number = 0;
  /** 中途切走的首数（页面文案「只听一次 N 首」） */
  @Prop skippedCount: number = 0;
  /** 每个听歌日的平均分钟数 */
  @Prop avgMinutes: number = 0;

  /** 圆环进度值：收进 0..100（数据层算歪了也不会把环画断） */
  private ringValue(): number {
    if (this.rate < 0) {
      return 0;
    }
    if (this.rate > 100) {
      return 100;
    }
    return this.rate;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 14 }) {
        Stack({ alignContent: Alignment.Center }) {
          Progress({ value: this.ringValue(), total: 100, type: ProgressType.Ring })
            .width(RING_VP)
            .height(RING_VP)
            .color(ECHO_ACCENT)
            .style({ strokeWidth: RING_STROKE_VP, enableSmoothEffect: true })
          Text(this.ringValue() + '%')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(ECHO_TEXT_PRIMARY)
        }
        .width(RING_VP)
        .height(RING_VP)

        Column({ space: 4 }) {
          Text('的歌被听到了最后')
            .fontSize(14)
            .fontColor(ECHO_TEXT_PRIMARY)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('重复播放 ' + this.completeCount + ' 首')
            .fontSize(12)
            .fontColor(ECHO_TEXT_TERTIARY)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('只听一次 ' + this.skippedCount + ' 首')
            .fontSize(12)
            .fontColor(ECHO_TEXT_TERTIARY)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Text('平均每个听歌日 ' + this.avgMinutes + ' 分钟')
        .fontSize(12)
        .fontColor(ECHO_TEXT_TERTIARY)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(ECHO_CARD_BACKGROUND)
    .borderRadius(CARD_RADIUS)
  }
}

// =====================================================================================
// ⑪ 新发现
// =====================================================================================

/**
 * 新发现（派音 `NewDiscoverySection()`，spec §3.3 ⑪）。
 *
 * 大数字（24fp Bold `echo_accent`）+ `/ N 首`（14fp tertiary，底对齐）+ 进度条
 * （线性，宽 100% / 高 6，槽底 `echo_track_background`）+ 一行说明。
 */
@Component
export struct EchoDiscoveryCard {
  /** 本月第一次听到的歌数 */
  @Prop count: number = 0;
  /** 本月听过的歌总数（= songCount） */
  @Prop total: number = 0;

  /** 进度百分比：分母为 0 ⇒ 0（不产生 NaN） */
  private percent(): number {
    if (this.total <= 0) {
      return 0;
    }
    return Math.round(this.count * 100 / this.total);
  }

  /** 说明行：零数据时给「这个月还没有听得上的歌」 */
  private noteText(): string {
    if (this.total <= 0) {
      return '这个月还没有听得上的歌';
    }
    return '其中 ' + this.count + ' 首是这个月才第一次听的 · 占 ' + this.percent() + '%';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(String(this.count))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(ECHO_ACCENT)
        Text('/ ' + this.total + ' 首')
          .fontSize(14)
          .fontColor(ECHO_TEXT_TERTIARY)
          .margin({ bottom: 3 })
      }
      .width('100%')

      Progress({ value: this.percent(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color(ECHO_ACCENT)
        .backgroundColor(ECHO_TRACK_BACKGROUND)

      Text(this.noteText())
        .fontSize(12)
        .fontColor(ECHO_TEXT_SECONDARY)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(ECHO_CARD_BACKGROUND)
    .borderRadius(CARD_RADIUS)
  }
}

// =====================================================================================
// 空态两行字
// =====================================================================================

/**
 * 空态（派音 `EmptyHint()`，契约 §6「空态两行字」）。
 *
 * 派音只有一行「这个月还没有听歌记录，去播放几首吧」；聆听这边拆成
 * 主文案 + 一句「怎么才会有内容」的提示（与工程 `EmptyState` 的口径一致：
 * 光说「没有数据」不如说「听满 30 秒就会进来」）。
 */
@Component
export struct EchoEmptyHint {
  @Prop text: string = '这个月还没有听歌记录';
  @Prop hint: string = '听满 30 秒的歌会出现在回响里';

  build() {
    Column({ space: 4 }) {
      Text(this.text)
        .fontSize(13)
        .fontColor(ECHO_TEXT_TERTIARY)
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor(ECHO_TEXT_FAINT)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
