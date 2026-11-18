import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { K_CURRENT_SINGER } from '../core/player/PlaySession';
import { LxMusicInfo } from '../core/music/MusicSearch';
import { COMMENT_PAGE_SIZE, CommentKind, CommentPage, LxComment, commentPlatformName,
  commentsSupported, dedupeComments, fetchComments } from '../core/music/PlatformComment';
import { I_CHEVRON_LEFT, I_COMMENT, I_HEART, IconGlyph } from '../ui/Icons';
import { K_WINDOW_WIDTH, isWideWindow } from '../ui/Layout';

const DOMAIN: number = 0x0001;
const TAG: string = 'CommentSheet';

/**
 * 评论页的深色面板配色
 *
 * 与播放页同一个底（`#0C0C0E`）：这一层是盖在全屏播放器上的覆盖物，
 * 底色与播放页不一致时，边缘会露出一圈比播放页更亮/更暗的缝。
 * 其余几档是这套深色面板自己的文字层次（正文 / 次要 / 分隔线 / 头像底）。
 */
const C_PANEL_BG: string = '#151619';
const C_PANEL_TEXT: string = '#F4F4F4';
const C_PANEL_SUB: string = '#9D9FA3';
/** 平台提示卡的底：极淡的一层白，靠这点亮度差把卡片从背景里分出来 */
const C_NOTICE_BG: string = '#0DFFFFFF';
/** 评论之间的分隔线 */
const C_DIVIDER: string = '#12FFFFFF';
/** 有头像时的兜底底色（图片没加载出来时不至于闪白） */
const C_AVATAR_BG: string = '#1A1C20';
/** 没有头像时的首字底 */
const C_AVATAR_FALLBACK_BG: string = '#16FFFFFF';
/** 「重试」胶囊的底 */
const C_BUTTON_BG: string = '#16FFFFFF';
/** 失败文案的淡红（深色底上比纯红柔和，不刺眼） */
const C_ERROR: string = '#FFB4B4';
/** LxMine 暗色的强调色 text_accent：昵称、首字头像、加载圈都用它（暖金，不是主题红） */
const C_ACCENT: string = '#F4D28A';

/**
 * 评论列的最大宽度（vp）
 *
 * 大屏（平板 / 折叠展开 / 2in1）上正文若铺满整屏，一行 80 多个字根本没法读，
 * 所以收成一列居中。860 这个值是与参考版对齐的口径。
 */
const PANEL_MAX_WIDTH: number = 860;

/** 段标题「热门评论 / 最新评论」的字号 */
const SECTION_TITLE_SIZE: number = 18;

/** 一次拉取的结果：两个段落各自成败，互不牵连 */
interface SectionResult {
  ok: boolean;
  comments: LxComment[];
  total: number;
  message: string;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/**
 * 评论时间的展示口径：刚刚 / N 分钟前 / N 小时前 / N 天前 / yyyy-MM-dd
 *
 * 为什么不在数据层直接用 `PlatformComment.relativeTime`：那是「数据层口径」
 * （一分钟内给「N 秒前」、超过一天直接给日期）。评论页的排版要与参考版一致，
 * 一周内给「N 天前」比给日期更好读，所以这里按页面口径再算一次。
 * 拿不到时间戳（老数据 / 平台没给）时回落到数据层已经格式化好的 `timeStr`。
 */
function panelTime(ms: number): string {
  const diff: number = Date.now() - ms;
  if (diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return `${Math.floor(diff / 60000)} 分钟前`;
  }
  if (diff < 86400000) {
    return `${Math.floor(diff / 3600000)} 小时前`;
  }
  if (diff < 604800000) {
    return `${Math.floor(diff / 86400000)} 天前`;
  }
  const date = new Date(ms);
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

/**
 * 评论页
 *
 * 结构（自上而下）：深色底 -> 顶栏（歌名 / 歌手 · 平台 / 返回歌曲）-> 滚动区。
 * 滚动区里依次是：平台提示卡、「热门评论」段落、「最新评论」段落、总数一行。
 * **两个段落同一个滚动流，不是页签** —— 用户一次能同时看到热门与最新，
 * 不用来回点（这是本次改造的核心变化）。
 *
 * 数据来自 `core/music/PlatformComment`（内置平台接口，五家平台）：
 * 进页面时**并行**拉「热门」与「最新」各一页（15 条），哪一段失败只影响那一段；
 * 两段都失败才整页报错并给「重试」。不翻页：参考版也不翻页，
 * 一页 15+15 条已经够翻，翻页会破坏「两个段落同屏」的结构。
 *
 * 与播放页的接线：本组件是自绘的一层铺满播放器的覆盖物（不是路由页），
 * 顶栏需要自己让出状态栏那一段，所以 topInset / bottomInset 由播放页量好传进来。
 */
@Component
export struct CommentSheet {
  @Prop songName: string = '';
  /**
   * 状态栏的避让高度（vp）
   *
   * 播放页是**全屏模态**（bindContentCover），根节点又用 expandSafeArea 把背景铺到了
   * 状态栏底下，所以这一层铺满播放器的覆盖物也是从**窗口顶边**开始摆的 ——
   * 不给顶栏垫这一截，返回键和歌名就会直接压在时间/电量的字上。
   * 读到 0 表示系统已经避让过，此时按 0 处理，避免双重留白。
   */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /**
   * 这首歌是不是「需要先匹配」的本地音乐 / 云端音乐
   *
   * 只影响提示文案：本地歌与云端歌得先匹配到平台上的那一首才有评论，
   * 这句话得说清楚，否则用户只会看到「看不到评论」而不知道该干什么。
   */
  @Prop needsMatch: boolean = false;
  /**
   * 取当前歌的平台身份（musicInfo JSON，空串 = 拿不到）
   *
   * 在线歌是同步就有的；本地歌 / 云端歌可能要先联网匹配一次，所以这里设计成异步回调，
   * 由播放会话（`PlaySession.platformIdentityOf`）去解析 —— 评论页自己不该知道
   * 「本地歌怎么匹配」这件事。
   */
  onResolveTarget: () => Promise<string> = () => Promise.resolve('');
  onClose: () => void = () => {
  };
  /**
   * 窗口宽度（vp）与当前歌的歌手
   *
   * 这两个都不从播放页传：窗口宽度在 AppStorage 里（全应用同一个），
   * 歌手是播放会话发布的状态（`K_CURRENT_SINGER`）。评论页只读它们，
   * 不需要为了一句副标题去改播放页的接参。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;
  @StorageLink(K_CURRENT_SINGER) singer: string = '';
  /** 热门评论（第一页） */
  @State hot: LxComment[] = [];
  /** 最新评论（第一页） */
  @State latest: LxComment[] = [];
  @State hotTotal: number = 0;
  @State latestTotal: number = 0;
  @State loading: boolean = false;
  @State error: string = '';
  /** 解析出来的平台身份（musicInfo JSON），空串 = 这首歌没有 */
  @State targetJson: string = '';
  /** 正在解析平台身份（本地歌 / 云端歌可能要联网匹配一次） */
  @State resolving: boolean = true;
  /** 每次重拉签发一个 token，晚回来的旧响应直接丢掉 */
  private token: number = 0;
  /**
   * `target()` 的解析结果缓存
   *
   * build 里要反复问「这首歌有没有平台身份」（决定画提示卡还是空态），
   * 若每次都 JSON.parse 一遍 musicInfo，列表滚动时就是几十次无谓解析。
   * 按 targetJson 的原文做 key：换了歌（或匹配结果变了）自然失效。
   */
  private cachedJson: string = '';
  private cachedTarget: LxMusicInfo | null = null;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    void this.start();
  }

  /**
   * 先解析出平台身份，再并行拉两份评论
   *
   * 在线歌这一步是瞬时的（条目自带 musicInfo）；本地歌 / 云端歌可能要联网匹配，
   * 所以这两件事分成两个阶段，但都用同一个占位块（转圈 + 「正在读取评论…」），
   * 用户看到的只是「稍等一下」，不会先闪一个空列表再跳成内容。
   */
  private async start(): Promise<void> {
    this.resolving = true;
    try {
      this.targetJson = await this.onResolveTarget();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'resolve target failed: %{public}s', (e as Error).message);
      this.targetJson = '';
    }
    this.resolving = false;
    if (this.targetJson.length > 0) {
      void this.load();
    }
  }

  /** 当前歌的平台身份：没有（本地歌没匹配上 / 平台不支持）就返回 null */
  private target(): LxMusicInfo | null {
    if (this.targetJson.length === 0) {
      return null;
    }
    if (this.cachedJson === this.targetJson) {
      return this.cachedTarget;
    }
    let parsed: LxMusicInfo | null = null;
    try {
      const info: LxMusicInfo = JSON.parse(this.targetJson) as LxMusicInfo;
      parsed = commentsSupported(info.source) ? info : null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse musicInfo failed: %{public}s', JSON.stringify(e));
      parsed = null;
    }
    this.cachedJson = this.targetJson;
    this.cachedTarget = parsed;
    return parsed;
  }

  /** 「评论来自XX」用的平台名；调用处只在有平台身份时画这一句，所以不会返回空串 */
  private platformLabel(): string {
    const info: LxMusicInfo | null = this.target();
    return info !== null ? commentPlatformName(info.source) : '';
  }

  /**
   * 这首歌的平台 code（不管这个平台支不支持评论）
   *
   * `target()` 在平台不支持时返回 null —— 那正是空态要对用户说话的时刻，
   * 所以这里单独取一次 source：点名说「汽水音乐暂时没有评论」比「这个平台看不到评论」有用。
   * 只在空态这条路上调用，多一次解析无所谓。
   */
  private targetSource(): string {
    if (this.targetJson.length === 0) {
      return '';
    }
    try {
      const info: LxMusicInfo = JSON.parse(this.targetJson) as LxMusicInfo;
      // 用 length 判空而不是跟 undefined 比：JSON 里真缺这个字段时这里会抛，
      // 落到 catch 一样是空串，而不用在严格模式里比一个不可能的值
      return info.source.length > 0 ? info.source : '';
    } catch (e) {
      return '';
    }
  }

  /** 「看不到评论」时到底为什么：能说得具体就具体，用户才知道下一步做什么 */
  private unsupportedText(): string {
    const source: string = this.targetSource();
    if (source.length > 0) {
      return `${commentPlatformName(source)}暂时没有评论`;
    }
    if (this.needsMatch) {
      return '这首歌还没匹配到平台上的版本';
    }
    return '这首歌看不到评论';
  }

  private unsupportedHint(): string {
    if (this.targetSource().length > 0) {
      return '这个平台的评论接口还没接。目前有评论的是酷我、酷狗、QQ 音乐、咪咕与网易云。';
    }
    if (this.needsMatch) {
      return '评论只存在于音乐平台上，本地音乐与云端音乐要先匹配到平台的那一首：' +
        '播放页「更多 - 匹配歌词」里搜一次并选中正确的版本，之后评论与歌词都会用它。';
    }
    return '评论来自音乐平台，目前支持酷我、酷狗、QQ 音乐、咪咕与网易云。';
  }

  /** 宽屏（平板 / 折叠展开）：内容居中一列，左右留 32，窄屏留 20 */
  private wide(): boolean {
    return isWideWindow(this.windowWidth > 0 ? this.windowWidth : 360);
  }

  /** 顶栏标题就是歌名；拿不到歌名时退回一句通用标题 */
  private titleText(): string {
    return this.songName.length > 0 ? this.songName : '歌曲评论';
  }

  /** 顶栏副标题：歌手 · 平台（哪一半缺就只显示另一半） */
  private suffixText(): string {
    const platform: string = this.platformLabel();
    if (this.singer.length === 0) {
      return platform;
    }
    if (platform.length === 0) {
      return this.singer;
    }
    return `${this.singer} · ${platform}`;
  }

  /** 有没有平台身份（决定画内容还是画「看不到评论」） */
  private ready(): boolean {
    return this.target() !== null;
  }

  /** 两个段落都空 */
  private isEmpty(): boolean {
    return this.hot.length === 0 && this.latest.length === 0;
  }

  /**
   * 底部总数
   *
   * 优先用「最新」的总数：热门那一路各平台报的是「热门条数」，
   * 与评论总数不是一回事，拿它当「共 N 条」会明显偏小。
   * 平台都不报总数时退回已加载条数，避免写出「共 0 条」而屏幕上明明有评论。
   */
  private totalCount(): number {
    if (this.latestTotal > 0) {
      return this.latestTotal;
    }
    if (this.hotTotal > 0) {
      return this.hotTotal;
    }
    return this.hot.length + this.latest.length;
  }

  /**
   * 并行拉一份
   *
   * 两段各拉各的：热门接口挂掉不该把最新评论一起藏起来（五个平台里
   * 咪咕的热门与 QQ 的热门是两套完全不同的接口，稳定性也不一样）。
   * 失败不当场抛给上层，而是折成 `ok: false` 让调用处决定「整页报错」还是「只画有内容的那段」。
   */
  /**
   * 评论接口的报错也多是英文（DNS / 超时 / 403）：翻成人话再显示
   *
   * 真机断网时用户看到的是「获取热门评论请求失败：Failed to resolve the host name」，
   * 既看不懂也不知道该点哪。这里只做「说清是什么 + 下一步做什么」，认不出的原样保留。
   */
  private friendlyLoadError(message: string): string {
    const lower: string = message.toLowerCase();
    if (lower.includes('resolve') || lower.includes('unknown host') || lower.includes('no address')) {
      return '连不上评论服务（域名解析失败），请检查网络后点「重试」';
    }
    if (lower.includes('timeout') || lower.includes('timed out')) {
      return '评论加载超时，请稍后点「重试」';
    }
    if (lower.includes('refused') || lower.includes('reset') || lower.includes('disconnect')) {
      return '与评论服务的连接被中断，请稍后点「重试」';
    }
    if (message.includes('403') || message.includes('人机验证') || message.includes('卡密') ||
      lower.includes('unauthorized')) {
      return '该平台的评论接口暂时拒绝了请求（可能需要登录或稍后再试）';
    }
    return message;
  }
  private async sectionOf(info: LxMusicInfo, kind: CommentKind): Promise<SectionResult> {
    try {
      const page: CommentPage = await fetchComments(info, kind, 1, COMMENT_PAGE_SIZE);
      const okResult: SectionResult = {
        ok: true,
        comments: dedupeComments(page.comments),
        total: page.total,
        message: '',
      };
      return okResult;
    } catch (e) {
      const message: string = (e as Error).message;
      hilog.warn(DOMAIN, TAG, 'load %{public}s comments failed: %{public}s', kind, message);
      const failResult: SectionResult = { ok: false, comments: [], total: 0, message: message };
      return failResult;
    }
  }

  private async load(): Promise<void> {
    const info: LxMusicInfo | null = this.target();
    if (info === null) {
      return;
    }
    const myToken: number = ++this.token;
    this.loading = true;
    this.error = '';
    // 重拉时旧内容先清掉：占位块是「整页在等」，留着旧内容再盖一层转圈反而会闪
    this.hot = [];
    this.latest = [];
    this.hotTotal = 0;
    this.latestTotal = 0;
    const results: SectionResult[] = await Promise.all([
      this.sectionOf(info, 'hot'),
      this.sectionOf(info, 'new'),
    ]);
    if (myToken !== this.token) {
      return;
    }
    const hotResult: SectionResult = results[0];
    const newResult: SectionResult = results[1];
    this.hot = hotResult.comments;
    this.hotTotal = hotResult.total;
    this.latest = newResult.comments;
    this.latestTotal = newResult.total;
    // 只有两段都失败才算整页失败：一段成功时，成功的那段照常画出来
    if (!hotResult.ok && !newResult.ok) {
      this.error = this.friendlyLoadError(hotResult.message.length > 0 ? hotResult.message : newResult.message);
    }
    this.loading = false;
    this.toTop();
  }

  /**
   * 回到顶部
   *
   * 换歌 / 重试后如果不归位，新内容会从半中间开始，用户会以为上面缺了几条。
   * 放在 setTimeout(0) 里等首帧布局落定 —— 布局还没完成时 scrollTo 会抛。
   */
  private toTop(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'scroll to top skipped: %{public}s', JSON.stringify(e));
      }
    }, 0);
  }

  /**
   * 顶栏：返回「返回歌曲」+ 居中的歌名 / 歌手 · 平台
   *
   * 用 Stack 而不是 Row 排：居中标题不能受左边「返回歌曲」宽度影响，
   * 否则标题会随文案长度左右漂。
   */
  @Builder
  headerBar() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 2 }) {
        Text(this.titleText())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_PANEL_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
        Text(this.suffixText())
          .fontSize(11)
          .fontColor(C_PANEL_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      // 左右各让出一块，标题不会钻到返回区底下
      .padding({ left: this.wide() ? 128 : 96, right: this.wide() ? 128 : 96 })
      .alignItems(HorizontalAlign.Center)

      Row({ space: 2 }) {
        IconGlyph({ symbol: I_CHEVRON_LEFT, iconSize: 22, color: C_PANEL_TEXT })
        Text('返回歌曲')
          .fontSize(14)
          .fontColor(C_PANEL_TEXT)
          .maxLines(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: 6, right: 12 })
      .justifyContent(FlexAlign.Start)
      .onClick(() => {
        this.onClose();
      })
      .accessibilityText('返回歌曲')
      .accessibilityLevel('yes')
    }
    .width('100%')
    // 状态栏那一段由 topInset 让出来（播放页量好传进来）
    .height(56 + this.topInset)
    .padding({ top: this.topInset })
  }

  /**
   * 平台提示卡
   *
   * 两行字说清两件事：评论是哪个平台的（五家平台的条数与热度口径各不相同）、
   * 这里只能看不能发（本工程没有平台登录态与写接口）。
   * 与其画一个按下去没反应的「写评论」按钮，不如直接说白 —— 这也是参考版的写法。
   */
  @Builder
  notice() {
    Row({ space: 10 }) {
      IconGlyph({ symbol: I_COMMENT, iconSize: 18, color: C_PANEL_SUB })
      Column({ space: 3 }) {
        Text(`评论来自${this.platformLabel()}`)
          .fontSize(12)
          .fontColor(C_PANEL_TEXT)
          .width('100%')
        Text('仅供浏览，发表评论请前往原平台')
          .fontSize(10)
          .fontColor(C_PANEL_SUB)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor(C_NOTICE_BG)
  }

  /**
   * 占位块（加载 / 失败 / 空）
   *
   * 三种状态共用一个 280 高的居中块：高度写死是为了三种状态切换时页面不跳 ——
   * 若按内容高度撑开，转圈时矮、失败文案时高一截，用户会觉得页面在抖。
   */
  @Builder
  stateBlock(emptyText: string, emptyHint: string) {
    Column({ space: 14 }) {
      if (this.loading || this.resolving) {
        LoadingProgress()
          .width(34)
          .height(34)
          .color(C_ACCENT)
        Text('正在读取评论…')
          .fontSize(13)
          .fontColor(C_PANEL_SUB)
      } else if (this.error.length > 0 && this.ready()) {
        Text(this.error)
          .fontSize(13)
          .fontColor(C_ERROR)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('重试')
          .fontSize(13)
          .fontColor(C_PANEL_TEXT)
          .height(36)
          .padding({ left: 20, right: 20 })
          .backgroundColor(C_BUTTON_BG)
          .borderRadius(18)
          .onClick(() => {
            void this.load();
          })
          .accessibilityText('重新加载评论')
          .accessibilityLevel('yes')
      } else {
        IconGlyph({ symbol: I_COMMENT, iconSize: 30, color: C_PANEL_SUB })
        Text(emptyText)
          .fontSize(13)
          .fontColor(C_PANEL_SUB)
          .textAlign(TextAlign.Center)
          .maxLines(3)
        /*
          第二行只在「压根没有评论可取」时出现（平台不支持 / 本地歌没匹配）。
          只说「还没有评论」会让用户以为这首歌真的没人评论，可实际上是我们拿不到 ——
          这一行是必须交代的差别，正常空态下不显示。
        */
        if (emptyHint.length > 0) {
          Text(emptyHint)
            .fontSize(11)
            .fontColor(C_PANEL_SUB)
            .textAlign(TextAlign.Center)
            .maxLines(4)
        }
      }
    }
    .width('100%')
    .height(280)
    .justifyContent(FlexAlign.Center)
  }

  /** 热门段落：有热门才渲染（平台不报热门时整段不出现，不画一个空标题） */
  @Builder
  hotSection() {
    if (this.hot.length > 0) {
      Text('热门评论')
        .fontSize(SECTION_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_PANEL_TEXT)
        .width('100%')
      ForEach(this.hot, (comment: LxComment) => {
        CommentItem({ comment: comment })
        Divider().color(C_DIVIDER).strokeWidth(1)
      }, (comment: LxComment) => `hot-${comment.id}`)
    }
  }

  /** 最新段落：除最后一条外都带分隔线（最后一条下面紧跟总数，不该再有一条线） */
  @Builder
  latestSection() {
    if (this.latest.length > 0) {
      Text('最新评论')
        .fontSize(SECTION_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_PANEL_TEXT)
        .width('100%')
        .margin({ top: 4 })
      ForEach(this.latest, (comment: LxComment, index: number) => {
        CommentItem({ comment: comment })
        if (index < this.latest.length - 1) {
          Divider().color(C_DIVIDER).strokeWidth(1)
        }
      }, (comment: LxComment) => `new-${comment.id}`)
    }
  }

  @Builder
  totalLine() {
    Text(`共 ${this.totalCount()} 条评论，仅显示近期公开内容`)
      .fontSize(11)
      .fontColor(C_PANEL_SUB)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(C_PANEL_BG)
      Column() {
        this.headerBar()
        Scroll(this.scroller) {
          Column({ space: 16 }) {
            if (!this.ready()) {
              // 没有平台身份：解析中给转圈，解析完给「为什么看不到」
              this.stateBlock(this.unsupportedText(), this.resolving ? '' : this.unsupportedHint())
            } else if (this.loading || this.isEmpty()) {
              // 加载中 / 失败 / 真没人评论：三种情况由 stateBlock 自己按状态分派，
              // 这里共用一条分支，保证它们占的版面高度完全一致（切换时不跳）
              this.stateBlock('还没有评论', '')
            } else {
              this.notice()
              this.hotSection()
              this.latestSection()
              this.totalLine()
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: PANEL_MAX_WIDTH })
          .padding({
            left: this.wide() ? 32 : 20,
            right: this.wide() ? 32 : 20,
            top: 6,
            bottom: this.bottomInset + 40,
          })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

/**
 * 一条评论
 *
 * 排版是固定的三段：昵称 + 相对时间 / 正文 / 地点 + 点赞数。
 * 正文不折叠：折叠会让同一条评论在两个条目上的高度差出几十 vp，
 * 列表扫起来参差不齐（参考版也是整段铺开）。
 * 楼中楼与评论图片也都不在这里画 —— 它们会把这条三行的高度撑开，
 * 与「每条评论高度接近」的排版目标冲突，且平台多数只给前几条回复。
 * 复制走长按菜单：不占版面，是列表类页面的既有习惯。
 */
@Component
struct CommentItem {
  @Prop comment: LxComment;

  /** 无头像时用昵称首字兜底；昵称为空给一个占位字，避免画出一个空圆圈 */
  private initial(): string {
    const nick: string = this.comment.userName;
    return nick.length > 0 ? nick.substring(0, 1) : '匿';
  }

  private nickText(): string {
    return this.comment.userName.length > 0 ? this.comment.userName : '匿名用户';
  }

  /** 优先用原始时间戳按页面口径算；老数据没有时间戳时用平台给的文案 */
  private timeLabel(): string {
    // 先取到局部变量再判空：直接写 `comment.timeMs !== undefined ? comment.timeMs : 0`
    // 在严格模式的属性访问链上不一定能收窄，落成局部变量最稳
    const raw: number | undefined = this.comment.timeMs;
    const ms: number = raw !== undefined ? raw : 0;
    if (ms > 0) {
      return panelTime(ms);
    }
    return this.comment.timeStr;
  }

  private bodyText(): string {
    return this.comment.text.length > 0 ? this.comment.text : '（图片评论）';
  }

  /**
   * 复制一条评论
   *
   * 与「设置 - 日志」「关于」页同一套 pasteboard 用法（工程里没有更上层的封装）。
   * 失败要出声：不提示的话用户会以为已经复制好，去别处粘贴却是空的。
   */
  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制评论');
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'copy comment failed: %{public}s', err.message);
        this.toast('复制失败，请稍后再试');
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'copy comment threw: %{public}s', (e as BusinessError).message);
      this.toast('复制失败，请稍后再试');
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  copyMenu() {
    Menu() {
      MenuItem({ content: '复制评论' })
        .onClick(() => {
          this.copyText(this.comment.text);
        })
      MenuItem({ content: '复制昵称和评论' })
        .onClick(() => {
          this.copyText(`${this.nickText()}：${this.comment.text}`);
        })
    }
  }

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.comment.avatar.length > 0) {
          Image(this.comment.avatar)
            .width(40)
            .height(40)
            .borderRadius(20)
            .objectFit(ImageFit.Cover)
            .backgroundColor(C_AVATAR_BG)
            .draggable(false)
        } else {
          Text(this.initial())
            .fontSize(15)
            .fontColor(C_ACCENT)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(C_AVATAR_FALLBACK_BG)
            .borderRadius(20)
        }
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .clip(true)

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.nickText())
            .fontSize(13)
            .fontColor(C_ACCENT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.timeLabel())
            .fontSize(10)
            .fontColor(C_PANEL_SUB)
            .maxLines(1)
        }
        .width('100%')

        Text(this.bodyText())
          .fontSize(14)
          .fontColor(C_PANEL_TEXT)
          .lineHeight(21)
          .width('100%')

        Row({ space: 6 }) {
          if (this.comment.location.length > 0) {
            Text(this.comment.location)
              .fontSize(10)
              .fontColor(C_PANEL_SUB)
              .maxLines(1)
          }
          Blank()
          /*
            点赞数只展示，不做成按钮
            本工程没有平台的登录态与写接口，点赞发不出去；把这里画成可点的样子，
            点下去只能假装成功 —— 那是最糟的一种谎。数字是平台返回的真值，照原样显示；
            平台没给（likedCount 为 -1）或确实为 0 时显示一个「赞」字，与参考版一致。
          */
          IconGlyph({ symbol: I_HEART, iconSize: 12, color: C_PANEL_SUB })
          Text(this.comment.likedCount > 0 ? String(this.comment.likedCount) : '赞')
            .fontSize(10)
            .fontColor(C_PANEL_SUB)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Top)
    .bindContextMenu(this.copyMenu(), ResponseType.LongPress)
  }
}
