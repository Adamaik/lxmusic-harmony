/**
 * 视觉规范（照洛雪移动端取色）
 *
 * 洛雪的移动端是「浅灰底 + 纯白卡片 + 高饱和红强调色」的一套 Material 风格，
 * 底部导航、迷你播放器、全屏播放器这几层是悬浮的半透明玻璃层。
 *
 * **每个颜色都是资源 token（`$r('app.color.xxx')`），不是写死的十六进制**：
 * `resources/base/element/color.json` 是亮色那份，`resources/dark/element/color.json`
 * 是深色那份、同名同义，系统切深浅模式时自动换。所以这里只管「语义」，
 * 具体色值去那两份文件里看。**不要在界面代码里写死颜色** —— 写死的那个在深色模式下
 * 一定是错的（白卡片配白字、深色材质上的深灰图标、浅色渐隐蒙层压着深色列表，
 * 都是这么来的）。
 *
 * 与深浅模式无关的装饰色仍留字面量：占位封面配色、榜单卡片渐变、播放页封面上的
 * 那几层白字（无论深浅模式都在深色封面上）。
 */

/** 页面底色（浅灰 / 深色下近黑） */
export const C_BG: Resource = $r('app.color.c_bg');
/**
 * 顶栏渐隐蒙版的起色 / 终色
 *
 * 标题栏是纯透明的（华为音乐那一套），内容会从标题底下穿过。直接在标题文字后面
 * 滑动会很脏，所以内容最上面压一层「底色 → 全透明」的渐变。
 * `linearGradient` 的端点要写颜色本身，取不到资源色的 alpha，所以终色单独做一个
 * token（同色、alpha 0），深浅模式各一份。
 */
export const C_TOP_FADE: Resource = $r('app.color.c_top_fade');
export const C_TOP_FADE_END: Resource = $r('app.color.c_top_fade_end');
/** 卡片 / 列表底 */
export const C_CARD: Resource = $r('app.color.c_card');
/** 主要文字 */
export const C_TEXT: Resource = $r('app.color.c_text');
/** 次要文字（歌手、副标题） */
export const C_TEXT_SUB: Resource = $r('app.color.c_text_sub');
/** 更弱的文字（占位、计数） */
export const C_TEXT_WEAK: Resource = $r('app.color.c_text_weak');
/** 强调色（洛雪红） */
export const C_RED: Resource = $r('app.color.c_red');
/** 强调色的淡底（12%）：标签、重试钮这类小面积色块 */
export const C_RED_TINT: Resource = $r('app.color.c_red_tint');
/** 分割线 */
export const C_DIVIDER: Resource = $r('app.color.c_divider');
/** 分段控件底（浅灰胶囊容器） */
export const C_SEG_BG: Resource = $r('app.color.c_seg_bg');
/** 未选中图标 */
export const C_ICON: Resource = $r('app.color.c_icon');
/** 列表行尾那种小箭头（比次要文字再淡一点） */
export const C_CHEVRON: Resource = $r('app.color.c_chevron');

/** 玻璃层主色（半透明白，材质不生效时的兜底观感） */
export const C_GLASS: Resource = $r('app.color.c_glass_mask');
/** 玻璃层描边（顶边高光） */
export const C_GLASS_EDGE: Resource = $r('app.color.c_glass_mask_edge');
/** 深色玻璃（全屏播放器控制区；封面是深色的，深浅模式都是它） */
export const C_GLASS_DARK: Resource = $r('app.color.c_glass_on_media');

/** 悬浮玻璃层里最透的那一档底色（圆钮 / 迷你栏） */
export const C_GLASS_FILL: Resource = $r('app.color.c_glass_fill');
/** 中等厚度那档玻璃底色（卡片式浮层） */
export const C_GLASS_TINT: Resource = $r('app.color.c_glass_tint');
/** 提示条那种要保证文字可读的更实的玻璃底色 */
export const C_GLASS_SOLID: Resource = $r('app.color.c_glass_solid');
/** 底部页签栏底下的渐隐蒙层色（内容从这里淡出，必须跟着底色走） */
export const C_MASK_BOTTOM: Resource = $r('app.color.c_mask_bottom');

/** 浅一档的填充色（搜索框、说明块这种贴着卡片的底） */
export const C_FILL_SOFT: Resource = $r('app.color.c_fill_soft');
/** 再深一档的填充色（分段控件容器、轨道底） */
export const C_FILL_SOFT_STRONG: Resource = $r('app.color.c_fill_soft_strong');
/** 分段胶囊里未选中那项的文字色 */
export const C_SEG_UNSELECTED: Resource = $r('app.color.c_seg_unselected');
/** 底部页签栏未选中页签的文字色（压在系统材质上，深浅模式各一档） */
export const C_TAB_UNSELECTED: Resource = $r('app.color.c_tab_unselected');
/** 强调色药丸上的文字色（红底反白，深浅模式都是白） */
export const C_ON_ACCENT: Resource = $r('app.color.c_on_accent');
/** 设置行图标那种淡圆底 */
export const C_ICON_CIRCLE: Resource = $r('app.color.c_icon_circle');
/** 按压态覆盖色 */
export const C_PRESSED: Resource = $r('app.color.c_pressed');
/** 滑块轨道 */
export const C_SLIDER_TRACK: Resource = $r('app.color.c_slider_track');
/** 迷你栏折叠态那颗唱片圆钮的底色 */
export const C_RECORD_BUTTON: Resource = $r('app.color.c_record_button');

/** 底部悬浮导航/迷你播放器的玻璃圆角 */
export const R_PILL: number = 30;
/** 卡片圆角 */
export const R_CARD: number = 16;
/** 列表封面圆角 */
export const R_COVER: number = 12;

/** 页面大标题字号 */
export const F_TITLE: number = 29;
/** 分组标题 */
export const F_SECTION: number = 17;
/** 列表主标题 */
export const F_ITEM: number = 16.5;
/** 列表副标题 */
export const F_SUB: number = 12.5;
/** 底部导航文字 */
export const F_TAB: number = 10.5;

/** 设置页图标底色（深色模式下提亮一档，见 color.json） */
export const C_ICON_BLUE: Resource = $r('app.color.c_icon_blue');
export const C_ICON_PURPLE: Resource = $r('app.color.c_icon_purple');
export const C_ICON_GREEN: Resource = $r('app.color.c_icon_green');
export const C_ICON_ORANGE: Resource = $r('app.color.c_icon_orange');
export const C_ICON_CORAL: Resource = $r('app.color.c_icon_coral');

/**
 * 平台品牌色（聚合搜索结果行上的来源小标签）
 *
 * 聚合结果里同一首歌会来自好几个平台，光有文字标签不好扫，用平台自己的品牌色
 * 区分（和派音同一套色值）。取不到的平台退回次要文字色。
 *
 * 品牌色与它的淡底都是 token：深色模式下色值提亮一档、淡底加深一档
 * （原来那套 12% 淡底是算出来的，深色模式下既算不出也没法当资源用）。
 */
const PLATFORM_COLORS: Record<string, Resource> = {
  'kw': $r('app.color.p_kw'),
  'kg': $r('app.color.p_kg'),
  'mg': $r('app.color.p_mg'),
  'tx': $r('app.color.p_tx'),
  'wy': $r('app.color.p_wy'),
};

const PLATFORM_TINTS: Record<string, Resource> = {
  'kw': $r('app.color.p_kw_tint'),
  'kg': $r('app.color.p_kg_tint'),
  'mg': $r('app.color.p_mg_tint'),
  'tx': $r('app.color.p_tx_tint'),
  'wy': $r('app.color.p_wy_tint'),
};

export function platformColor(source: string): ResourceColor {
  const color: Resource | undefined = PLATFORM_COLORS[source];
  return color !== undefined ? color : C_TEXT_SUB;
}

/** 品牌色的淡底，给标签做胶囊底 */
export function platformTint(source: string): ResourceColor {
  const tint: Resource | undefined = PLATFORM_TINTS[source];
  return tint !== undefined ? tint : C_RED_TINT;
}
