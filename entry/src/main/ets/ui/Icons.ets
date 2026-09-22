/**
 * 图标 —— 全部使用 HarmonyOS 官方符号图标库（sys.symbol.*）
 *
 * 官方图标素材在 ArkTS 里的正确用法就是 SymbolGlyph + `$r('sys.symbol.<name>')`：
 * 图形由系统符号字体提供，任何 HarmonyOS 设备上都是同一套官方图形，支持
 * fontColor / fontSize / fontWeight / symbolEffect 动效，也不需要自己维护 SVG。
 *
 * 下面的名字都取自 SDK 的系统资源表（ets-loader/sysResource.js 的 symbol 段，
 * 共 4042 个），不是猜的；写错名字会静默渲染成空白。
 */

/** 首页（推荐） */
export const I_HOME: Resource = $r('sys.symbol.house');
export const I_HOME_FILL: Resource = $r('sys.symbol.house_fill');
/** 歌单 */
export const I_PLAYLIST: Resource = $r('sys.symbol.music_note_list');
export const I_PLAYLIST_FILL: Resource = $r('sys.symbol.music_note_list_fill');
/** 我的 */
export const I_PERSON: Resource = $r('sys.symbol.person');
export const I_PERSON_FILL: Resource = $r('sys.symbol.person_fill');
/** 设置 */
export const I_GEAR: Resource = $r('sys.symbol.gearshape');
export const I_GEAR_FILL: Resource = $r('sys.symbol.gearshape_fill');
/** 搜索 */
export const I_SEARCH: Resource = $r('sys.symbol.magnifyingglass');
/** 唱片 / 音源 */
export const I_DISC: Resource = $r('sys.symbol.record_circle');
/** 排序 */
export const I_SORT: Resource = $r('sys.symbol.line_3_horizontal');
/** 新建 */
export const I_PLUS: Resource = $r('sys.symbol.plus');
/** 删除 */
export const I_TRASH: Resource = $r('sys.symbol.trash');
/** 音量（播放中指示） */
export const I_VOLUME: Resource = $r('sys.symbol.speaker_wave_3');
/** 下载 */
export const I_DOWNLOAD: Resource = $r('sys.symbol.download');
/** 导入（歌单导入：往托盘里落的那支箭头） */
export const I_IMPORT: Resource = $r('sys.symbol.square_and_arrow_down');
/** 缓存 */
export const I_CACHE: Resource = $r('sys.symbol.externaldrive');
/** 主题 */
export const I_BRUSH: Resource = $r('sys.symbol.paintbrush');
/** 其它 */
export const I_THUMB_UP: Resource = $r('sys.symbol.hand_thumbsup');
/** 更多 */
export const I_MORE: Resource = $r('sys.symbol.more');
/** 列表行右侧的「更多」：圆环里两个竖点（洛雪歌单行尾那个图标） */
export const I_MORE_CIRCLE: Resource = $r('sys.symbol.dot_grid_1x2_circle');
/** 多选：已选中 / 未选中（本地音乐的批量移除用） */
export const I_CHECK_CIRCLE: Resource = $r('sys.symbol.checkmark_circle_fill');
export const I_CIRCLE: Resource = $r('sys.symbol.circle');
/** 箭头 */
export const I_CHEVRON_RIGHT: Resource = $r('sys.symbol.chevron_right');
export const I_CHEVRON_DOWN: Resource = $r('sys.symbol.chevron_down');
export const I_CHEVRON_LEFT: Resource = $r('sys.symbol.chevron_left');
/** 关闭 */
export const I_CLOSE: Resource = $r('sys.symbol.xmark');
/** 播放控制 */
export const I_PLAY: Resource = $r('sys.symbol.play_fill');
export const I_PAUSE: Resource = $r('sys.symbol.pause_fill');
/** 播放钮（圆底，洛雪迷你播放器里用的就是这种） */
export const I_PLAY_CIRCLE: Resource = $r('sys.symbol.play_circle_fill');
export const I_PAUSE_CIRCLE: Resource = $r('sys.symbol.pause_circle_fill');
export const I_PREV: Resource = $r('sys.symbol.backward_end_fill');
export const I_NEXT: Resource = $r('sys.symbol.forward_end_fill');
/** 播放模式：列表循环 / 顺序播放 / 单曲循环 / 随机播放（与系统播控中心同一套符号） */
export const I_REPEAT: Resource = $r('sys.symbol.repeat');
export const I_ORDER_PLAY: Resource = $r('sys.symbol.order_play');
export const I_REPEAT_ONE: Resource = $r('sys.symbol.repeat_1');
export const I_SHUFFLE: Resource = $r('sys.symbol.shuffle');
/** 播放列表 */
export const I_QUEUE: Resource = $r('sys.symbol.music_note_list');
/** 收藏 */
export const I_HEART: Resource = $r('sys.symbol.heart');
export const I_HEART_FILLED: Resource = $r('sys.symbol.heart_fill');
/** 分享 / 刷新 */
export const I_SHARE: Resource = $r('sys.symbol.share');
export const I_REFRESH: Resource = $r('sys.symbol.arrow_2_circlepath');
/** 通知 */
export const I_BELL: Resource = $r('sys.symbol.bell');
/**
 * 评论（气泡）
 *
 * 系统符号表里的 `message` 就是一个对话气泡，语义与洛雪的评论图标一致
 * （名字都取自 SDK 的 ets-loader/sysResource.js，写错会静默渲染成空白）。
 */
export const I_COMMENT: Resource = $r('sys.symbol.message');
/**
 * 投播至（投屏设备）
 *
 * 用系统的投播图标。AVCastPicker 默认外观由系统绘制（部分设备/状态下不显示），
 * 按官方建议改成自绘外观，图标取系统符号表里现成的投播符号。
 */
export const I_CAST: Resource = $r('sys.symbol.statusbar_cast');
/** 歌手 */
export const I_MIC: Resource = $r('sys.symbol.mic');
/** 榜单 */
export const I_TROPHY: Resource = $r('sys.symbol.star_trophy');
/** 分类 */
export const I_DOC: Resource = $r('sys.symbol.doc_plaintext');
/** 精选 */
export const I_STAR: Resource = $r('sys.symbol.star');
/** 关于 */
export const I_INFO: Resource = $r('sys.symbol.info_circle');
/** 复制（两张叠起来的文档） */
export const I_COPY: Resource = $r('sys.symbol.doc_text_on_doc_text');
/** 打开外部链接（右上方向的箭头） */
export const I_EXTERNAL: Resource = $r('sys.symbol.arrowshape_turn_up_right');
/** 群 / 多人 */
export const I_GROUP: Resource = $r('sys.symbol.person_2');

/**
 * 官方符号图标
 */
@Component
export struct IconGlyph {
  @Prop symbol: Resource;
  @Prop iconSize: number = 22;
  @Prop color: ResourceColor = '#1A1A1A';
  @Prop weight: FontWeight = FontWeight.Medium;
  /**
   * 换图时走系统的符号替换动效（播放 <-> 暂停、收藏 <-> 取消收藏这类成对图标）。
   *
   * 默认关：列表里成百上千个图标不应该各自带着动效。开着的时候图标是「长成」
   * 另一个形状，而不是硬切一张图。
   */
  @Prop replaceEffect: boolean = false;

  build() {
    SymbolGlyph(this.symbol)
      .fontSize(this.iconSize)
      .fontColor([this.color])
      .fontWeight(this.weight)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .symbolEffect(new ReplaceSymbolEffect(EffectScope.LAYER), this.replaceEffect)
  }
}
