/**
 * 屏幕宽度适配（折叠屏展开态 / 平板）
 *
 * 之前底部那两条栏（HdsTabs 的悬浮页签栏 + 迷你栏）的宽度是一组写死的分档值
 * （页签栏 280/340/440、迷你栏 286/300/328），只在「手机 + 迷你栏折叠」这一种组合下
 * 恰好放得下。窗口一变化就叠在一起：
 *
 *   - HdsTabs 宽度 ≥ 600vp 时 `miniBarStyle` 不生效，迷你栏恒为展开态，于是页签栏与
 *     迷你栏**同时**展开、并排左右布局（官方文档「迷你栏和页签栏处于左右布局场景」）。
 *     此时 340 + 300 = 640vp 已经超过 600vp 档位窗口的可用宽度，两条栏就压在一起
 *     （设置那颗齿轮被迷你栏的唱片圆钮盖住）；
 *   - 官方文档还有一条硬上限：页签数 ≥ 4 时单条栏宽度不超过 328vp，原来 large 档的
 *     440vp 本来就越界；
 *   - 迷你栏的分档宽度只在**展开态**生效（折叠态是一颗圆钮，宽度等于栏高），
 *     所以窄屏要按「圆钮 + 页签栏」算，宽屏要按「展开的迷你栏 + 页签栏」算。
 *
 * 所以这里不再写死：按**窗口实际宽度**算 —— 先定迷你栏要多少，剩下的都给页签栏，
 * 保证「页签栏 + 迷你栏 + 中间缝 = 可用宽度」，任何窗口宽度下都不会重叠。
 * 窗口尺寸一变（旋转、折叠屏展开/折叠、平板分屏/自由窗口）由调用方重算一次。
 */

/**
 * 断点口径与 HDS 底部悬浮页签栏一致（见 HdsBarWidthRangeOptions 的文档）：
 *   < 440vp         手机
 *   440vp - 600vp   大屏手机 / 折叠屏折叠态
 *   ≥ 600vp         折叠屏展开态 / 平板（两条栏同时展开，恒为中心对齐）
 *   600 - 840vp 之间还要看高宽比（> 0.8 按大屏算，< 0.8 按中档算），
 *   这里不重复判断：分档只用来选边距，两条栏的宽度本来就按实际可用宽度算。
 */
export const BP_COMPACT: number = 440;
export const BP_MEDIUM: number = 600;
export const BP_EXPANDED: number = 840;

/** 页签数 ≥ 4 时单条栏的宽度上限（官方文档写死的值） */
const BAR_WIDTH_MAX: number = 328;
/** 页签栏的宽度下限：4 个页签每个 56vp，再窄图标和文字就挤在一起了 */
const TAB_BAR_WIDTH_MIN: number = 224;
/** 迷你栏展开态的宽度下限：圆封面 40 + 歌名 + 三个控制钮，再窄歌名就没法看了 */
const MINI_BAR_WIDTH_MIN: number = 232;
/** 迷你栏展开态拿窗口可用宽度的比例：剩下的留给页签栏 */
const MINI_BAR_WIDTH_RATIO: number = 0.5;
/** 迷你栏折叠态：一颗圆钮，宽度等于栏高（HDS_BAR_HEIGHT） */
const MINI_BAR_COLLAPSED: number = 56;
/**
 * 窄屏下「迷你栏展开」时页签栏折叠后的宽度。
 * 折叠态宽度由 HDS 自己定，这里只是给它留位（估算值，宁可留宽一点）。
 */
const TAB_BAR_COLLAPSED: number = 96;
/** 两条栏之间的缝 */
const BAR_GAP: number = 8;

/**
 * 详情页 / 设置页里**表单类**内容的最大宽度（输入框、按钮、说明文字那几块）
 *
 * 列表可以多列，表单不行：窗口宽到 1400vp 还把输入框拉满，就是一条又长又扁的带子、
 * 两个按钮各占半个屏幕。所以这类控件单独收成这个宽度，**整页不再收窄**
 * （页面本身铺满窗口，见 contentColumnsFor）。
 */
export const CONTENT_MAX_WIDTH: number = 720;

/**
 * 宽屏下**一行内容至少多宽**（所有铺满窗口的列表页共用）
 *
 * 口径照华为音乐的平板首页：那边正文大约 1100vp 宽、一屏三列，每列 ~370vp；
 * 这里取 360vp —— 一行里要放下封面、歌名、副标题三样，再窄就只剩「歌名…」了。
 */
export const HOME_ROW_MIN_WIDTH: number = 360;

/** 最多列数：PC 那种超宽窗口上再分下去，一行会被拉成"细长条"，封在四列 */
export const HOME_COLUMNS_MAX: number = 4;

/**
 * 宽屏下一屏放几列（首页三个页签、歌单详情、搜索结果、我的各列表…全部共用）
 *
 * 宽屏的内容**不再收成居中的 720 一列**（那是改坏掉的那一版：两侧留一大片白，
 * 列表一行从屏左拉到屏右），而是铺满窗口、按窗口宽度自动多列 —— 与华为音乐的
 * 平板版同一套做法。各页把这个值喂给 `List.lanes()`：
 * 列表条目自己排成多列，页内的头部（歌单封面那一块）则整行铺满。
 *
 * 列数 = 能放内容的宽度 ÷ HOME_ROW_MIN_WIDTH，最少 1 列、最多 HOME_COLUMNS_MAX 列。
 * 窗口宽度 0（还没量到）或窄屏一律 1 列，也就是改之前的样子。
 */
export function contentColumnsFor(windowWidth: number): number {
  // 页面自己左右各留 16 的内边距，算列数要按真正能放内容的宽度算
  const avail: number = windowWidth - 32;
  if (windowWidth < BP_MEDIUM || avail <= 0) {
    return 1;
  }
  let columns: number = Math.floor(avail / HOME_ROW_MIN_WIDTH);
  if (columns < 1) {
    columns = 1;
  }
  return columns > HOME_COLUMNS_MAX ? HOME_COLUMNS_MAX : columns;
}

/**
 * 窗口宽度（AppStorage 键）
 *
 * 壳层（pages/Index.ets）量到窗口宽度后写进来，各页读它算列数
 * （{@link contentColumnsFor}）与表单限宽 —— 与 K_BAR_MINI_WIDTH 同一条路子：
 * 窗口尺寸一变，壳层重写一次，订阅者自己重排。
 */
export const K_WINDOW_WIDTH: string = 'layout_window_width';

// ---------------------------------------------------------------- 卡片流（设置类页面）

/**
 * 并排的一张卡至少要多宽
 *
 * 设置类页面不像列表页那样是「一列歌曲行」，而是**一张张卡**（一张卡里往往有
 * 图标 + 标题 + 说明好几段），比列表行更需要宽度，所以这里给 460vp：
 * 两列并排至少要 460 × 2 + 间距，窗口再窄就还是一列。
 */
const CARD_MIN_WIDTH: number = 460;

/**
 * 设置类页面宽屏下并排几张卡（1 或 2）
 *
 * 与列表页的 {@link contentColumnsFor} 是两个口径：列表一行是「封面 + 歌名」，
 * 360vp 就够；卡片要放好几段内容，窄了会挤成一团，所以门槛更高、最多两列。
 */
export function cardColumnsFor(windowWidth: number): number {
  const avail: number = windowWidth - 32;
  if (windowWidth < BP_MEDIUM || avail < CARD_MIN_WIDTH * 2 + 14) {
    return 1;
  }
  return 2;
}

/**
 * 并排时每张卡的宽度：宽屏 48%（两份 + 间距正好一行），窄屏铺满
 *
 * 用百分比而不是按窗口算出来的 vp：Flex 换行是按子项自己的宽度决定的，
 * 给 48% 无论窗口多宽都稳（留 4% 给那一列间距）。
 */
export function cardWidthOf(windowWidth: number): string {
  return cardColumnsFor(windowWidth) > 1 ? '48%' : '100%';
}

/**
 * 「不限宽」的占位值。
 *
 * `constraintSize({ maxWidth })` 必须给一个数，窄屏（按手机铺满）与「窗口宽度还没量到」
 * 这两种情况都要的是「别管我」，所以给一个够大的数让这条约束等于没有。
 */
export const LAYOUT_UNBOUNDED: number = 100000;

/** 底部两条悬浮栏的几何 */
export interface BarMetrics {
  /** 栏与窗口左右边的距离 */
  sideMargin: number;
  /** 页签栏宽度 */
  tabBarWidth: number;
  /** 迷你栏宽度（展开态；折叠态由 HDS 自己按圆钮画） */
  miniBarWidth: number;
}

/** 数值收敛到 [min, max] */
function clamp(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  return value > max ? max : value;
}

/** 页签栏 / 迷你栏与窗口左右边的距离：窗口越宽留得越多（与 HDS 默认口径一致） */
export function barSideMarginFor(windowWidth: number): number {
  if (windowWidth >= BP_EXPANDED) {
    return 24;
  }
  if (windowWidth >= BP_MEDIUM) {
    return 16;
  }
  return 12;
}

/** 窗口宽度是否算「宽屏」（宽屏下迷你栏恒为展开态，且内容收成居中一列） */
export function isWideWindow(windowWidth: number): boolean {
  return windowWidth >= BP_MEDIUM;
}

/**
 * 算底部两条栏的宽度
 *
 * @param windowWidth 窗口宽度（vp）；0 表示还没量到，按手机档处理
 * @param miniExpanded 迷你栏当前是否展开（由 HdsTabs 的 onBarStyleChange 写进 AppStorage）
 */
export function barMetricsFor(windowWidth: number, miniExpanded: boolean): BarMetrics {
  const sideMargin: number = barSideMarginFor(windowWidth);
  const avail: number = Math.max(0, windowWidth - sideMargin * 2);
  // 宽屏下 miniBarStyle 不生效（官方文档：仅 HdsTabs 宽度小于 600vp 时生效），
  // 迷你栏一定处于展开态，页签栏也保持展开 —— 两条的宽度都得算进去。
  const wide: boolean = isWideWindow(windowWidth);
  const expanded: boolean = wide || miniExpanded;

  let mini: number = clamp(Math.round(avail * MINI_BAR_WIDTH_RATIO), MINI_BAR_WIDTH_MIN, BAR_WIDTH_MAX);
  if (expanded) {
    // 展开态旁边那条也得有位置：宽屏是展开的页签栏，窄屏是折叠的页签栏
    const otherMin: number = wide ? TAB_BAR_WIDTH_MIN : TAB_BAR_COLLAPSED;
    mini = Math.min(mini, Math.max(MINI_BAR_WIDTH_MIN, avail - otherMin - BAR_GAP));
  }

  const reserved: number = (expanded ? mini : MINI_BAR_COLLAPSED) + BAR_GAP;
  let tab: number = Math.min(BAR_WIDTH_MAX, avail - reserved);
  if (tab < TAB_BAR_WIDTH_MIN) {
    // 窗口窄到两条都放不下（小屏手机）：页签栏保底，迷你栏让位。
    // 这种尺寸下页签栏与迷你栏是一个展开一个折叠，两者不同时占满宽度，不会真压上。
    tab = Math.min(BAR_WIDTH_MAX, Math.max(TAB_BAR_WIDTH_MIN, avail - reserved));
  }
  return { sideMargin: sideMargin, tabBarWidth: tab, miniBarWidth: mini };
}

/**
 * 页内那条迷你栏（歌单详情 / 在线详情，不在页签体系里）该收多宽
 *
 * 拿壳层同步过来的宽度：> 0 = 宽屏，收成与 HdsTabs 那条迷你栏同一宽度，
 * 这样「页签里那条」与「页内那条」在同一个设备上宽度一致；= 0 = 窄屏，不限宽。
 */
export function miniBarWidthOrUnbounded(published: number): number {
  return published > 0 ? published : LAYOUT_UNBOUNDED;
}

// ---------------------------------------------------------------- 跨页面共享的布局量

/**
 * 迷你栏宽度（AppStorage 键）
 *
 * 壳层（pages/Index.ets）按窗口宽度算好后写进来：> 0 = 宽屏下迷你栏该占的宽度，
 * 0 = 窄屏（页内那条迷你栏照旧铺满，由 wideMiniBarMaxWidthFor 翻成「不限宽」）。
 * 详情页里那条页内迷你栏读它，免得同一个控件在不同页面两种宽度。
 */
export const K_BAR_MINI_WIDTH: string = 'layout_bar_mini_width';

/**
 * 壳层要同步给别的页面的迷你栏宽度
 *
 * 宽屏给实际算出来的值，窄屏给 0（页内那条迷你栏照旧铺满，只留左右边距）。
 */
export function publishedMiniBarWidth(windowWidth: number, miniExpanded: boolean): number {
  if (!isWideWindow(windowWidth)) {
    return 0;
  }
  return barMetricsFor(windowWidth, miniExpanded).miniBarWidth;
}
