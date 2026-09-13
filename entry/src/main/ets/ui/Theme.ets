/**
 * 视觉规范（照洛雪移动端取色）
 *
 * 洛雪的移动端是「浅灰底 + 纯白卡片 + 高饱和红强调色」的一套 Material 风格，
 * 底部导航、迷你播放器、全屏播放器这几层是悬浮的半透明玻璃层。
 * 这里把用到的色值/尺寸集中一处，避免散落在各个视图里对不上。
 */

/** 页面底色（浅灰） */
export const C_BG: string = '#F1F1F2';
/** 卡片 / 列表底 */
export const C_CARD: string = '#FFFFFF';
/** 主要文字 */
export const C_TEXT: string = '#0D0D0D';
/** 次要文字（歌手、副标题） */
export const C_TEXT_SUB: string = '#8A8A8E';
/** 更弱的文字（占位、计数） */
export const C_TEXT_WEAK: string = '#B4B4B8';
/** 强调色（洛雪红） */
export const C_RED: string = '#E33B3B';
/** 分割线 */
export const C_DIVIDER: string = '#EDEDEE';
/** 分段控件底（浅灰胶囊容器） */
export const C_SEG_BG: string = '#EBEBED';
/** 未选中图标 */
export const C_ICON: string = '#1A1A1A';

/** 玻璃层主色（半透明白，材质不生效时的兜底观感） */
export const C_GLASS: string = '#B8FFFFFF';
/** 玻璃层描边（顶边高光） */
export const C_GLASS_EDGE: string = '#B3FFFFFF';
/** 深色玻璃（全屏播放器控制区） */
export const C_GLASS_DARK: string = '#2EFFFFFF';

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

/** 设置页图标底色 */
export const C_ICON_BLUE: string = '#2F6BFF';
export const C_ICON_PURPLE: string = '#8257F5';
export const C_ICON_GREEN: string = '#2FBE5B';
export const C_ICON_ORANGE: string = '#F4A11E';
export const C_ICON_CORAL: string = '#F4634B';
