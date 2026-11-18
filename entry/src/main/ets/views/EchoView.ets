/*
 * 回响（月度收听报告）
 *
 * 版式与几何移植自派音 2.0.0 的回响页（features/recommendation/view/EchoReviewPage.ets，
 * 2095 行，2026-11-15 版），但**数据口径按聆听自己的 ListenLog**（30 秒门槛、真实 playedMs）。
 * 颜色是**固定深色**（`ui/EchoMonthlyKit.ets` 顶部的 ECHO_* 调色板 + 纯黑页底），
 * 不跟系统浅色模式 —— 沉浸式月报，用户 2026-11-15 明确要求；标题仍由壳层 PageTitle 承载（白字）。
 * 背景氛围层按旧版聆听回响的口径：当前段落/领奖台中心卡封面 → 模糊 70 + 0.62 不透明度，
 * 两层交叉淡入 420ms；滚到底 / 进入听众段渐隐回纯黑。
 *
 * 与派音的有意差异（详见 _echo_port/PORT_CONTRACT.md §10）：
 *   · 完播率用聆听真实的「播完 / 切走」判定（≥85% 算完整），不是派音「播≥2 次占比」；
 *   · 裁掉派音的「新收藏」段：聆听的收藏项（PlaySession.favorites）没有时间戳，无法按月统计；
 *   · 不移植 HDS 标题栏：标题写 AppStorage 由壳层画，滚动切段名的逻辑保留；
 *   · 聆听没有专辑详情页：点专辑 = 播这张专辑里这个月最常听的那首。
 *
 * 数据只有 ListenLog 一个来源（一次播放一条流水），聚合全部在 core/history/EchoMonthly.ets，
 * 本页只做「整体赋值 + 布局 + 交互」。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BottomBar } from '../ui/BottomBar';
import { ArtistNav } from '../ui/ArtistNav';
import { isWideWindow, K_WINDOW_WIDTH } from '../ui/Layout';
import { ArtistCandidate, cachedArtistOf, LxArtist, resolveArtistByName } from '../core/music/MusicArtist';
import { isSearchSupported, LxMusicInfo, LxSearchOutcome, SEARCH_PLATFORMS, searchMusic,
  searchMusicAll } from '../core/music/MusicSearch';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_ECHO_VERSION, ListenLog, MonthKey } from '../core/history/ListenLog';
import { buildMonthlyStats, buildMonthOptions, echoMinutes, monthRangeOf, MonthlyAlbum,
  MonthlyArtist, MonthlySong, MonthlyStats, MonthOption, MonthRange } from '../core/history/EchoMonthly';
import { ECHO_PAGE_BACKGROUND, ECHO_TOP_FADE, ECHO_TOP_FADE_END, EchoAudience, EchoCompletionCard,
  EchoDiscoveryCard, EchoEmptyHint, EchoMonthHeader,
  EchoMonthPicker, EchoOverviewCard, EchoSectionTitle, EchoSongHighlight, EchoTopAlbums,
  EchoTopArtists, EchoTopSongs } from '../ui/EchoMonthlyKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'EchoView';

/**
 * 页头大标题（壳层订阅的那个键）
 *
 * 「10 月 · 回响」这行字画在**壳层的标题栏**里，与「推荐」「我的」同一个位置、同一档字号
 * （见 pages/Index.ets 的 homeHeader）—— 所以这一页把标题**发布**给壳层，自己不再画一遍。
 */
export const K_ECHO_TITLE: string = 'ps_echo_title';

/** 页头大标题的文案（月份跟着选择器走，所以不能写死在 TABS 里） */
export function echoTitleOf(month: number): string {
  return month > 0 ? `${month} 月 · 回响` : '回响';
}

/** 段落下标 → 页头标题里「N 月 · ×××」那半句（相邻多段共用，所以全程只变 3 次） */
const SECTION_NAMES: string[] = ['回响', '你听了什么', '你听了什么', '你听了什么',
  '你是怎样的听众', '你是怎样的听众', '有趣的发现'];
/** 点一行去播放时，按「歌名 + 歌手」搜几条候选、取第一条（与识别页同一套） */
const PLAY_SEARCH_LIMIT: number = 10;
/** 背景氛围层：两层模糊封面交叉淡入的时长（照旧版回响，400ms 左右是「颜色化过去」的量） */
const THEME_FADE_MS: number = 420;
/** 背景封面模糊半径：要大到只剩色块，否则背景里能看出封面轮廓，文字压上去很脏 */
const BACKDROP_BLUR: number = 70;
/** 背景封面的最终不透明度（叠在页面底色上，再压一层日间遮罩） */
const BACKDROP_OPACITY: number = 0.62;

@Component
export struct EchoView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 内容底部要留出的空间：悬浮页签栏 + 迷你条（由壳层算好） */
  @Prop bottomInset: number = 0;
  /** 当前窗口宽度：判宽屏双列（宽度变了标题档位要跟着归位，见 onWindowWidthChanged） */
  @StorageLink(K_WINDOW_WIDTH) @Watch('onWindowWidthChanged') windowWidth: number = 0;
  /** 流水版本号：变了就重算这一页 */
  @StorageLink(K_ECHO_VERSION) @Watch('onLogChanged') logVersion: number = 0;
  /** 月份偏移：0 = 本月，-1 = 上月 …（最多回溯 12 个自然月）。不要叫 offset：与 CustomComponent 基类属性冲突 */
  @State monthOffset: number = 0;
  /** 整页统计（一次性构建、整体替换） */
  @State stats: MonthlyStats = new MonthlyStats();
  /** 年下拉的档位文案 / 当前档 / 每档对应的「代表月份偏移」 */
  @State yearLabels: string[] = [];
  @State yearIndex: number = 0;
  @State yearOffsets: number[] = [];
  /** 月下拉的档位文案 / 当前档 / 每档对应的月份偏移 */
  @State monthLabels: string[] = [];
  @State monthIndex: number = 0;
  @State monthOffsets: number[] = [];
  /** 标题里的「当前状态」名（回响 / 你听了什么 / 你是怎样的听众 / 有趣的发现） */
  @State sectionTitle: string = '回响';
  /** 正在按名字去搜的那一首（防连点） */
  @State playingKey: string = '';
  /**
   * 背景氛围层（旧版回响的「跟着内容走」的那层，用户要求拉回来）
   *
   * 当前段落 / 领奖台中心卡是哪张封面，背景就用那张图的**高斯大模糊 + 低透明度**；
   * 换段落时两层交叉淡入（直接换 URL 会闪一下）。段落进入「听众 / 完播率 / 新发现」时
   * 目标为空串 ⇒ 两层都淡到 0，回到纯页面底色。宽屏两列同屏，段落判定没有意义，
   * 只跟领奖台中心那张走。
   */
  @State bgUrlA: string = '';
  @State bgUrlB: string = '';
  @State bgOpA: number = 0;
  @State bgOpB: number = 0;
  /** 当前滚动到第几段（0 页头 / 1 歌曲 / 2 歌手 / 3 专辑 / 4 听众 / 5 完播率 / 6 新发现） */
  @State sectionIdx: number = 0;
  /** 领奖台当前中心卡下标（背景跟着中心那张封面走） */
  @State podiumActive: number = 0;
  /** 「最常听的歌手」本人写真（背景用）；空串 = 还没解析到，退回他的歌封面 */
  @State artistPicUrl: string = '';
  /** 上面这张写真对应的歌手键（来源+名字），换歌手才重新解析 */
  private artistPicKey: string = '';
  /** 下一次主题图写哪一层（两层轮换） */
  private nextIsB: boolean = true;
  /** 上一次应用的主题地址（同一个值不重复做动画） */
  private themeApplied: string = '';
  /** 第一次应用主题直接给结果、不做动画（页面刚进来时不要闪一下） */
  private themeInited: boolean = false;
  private scroller: Scroller = new Scroller();
  /** 首次进入是否已经做过「自动落到最近有数据的月份」（只做一次，不抢用户手动选择） */
  private initialMonthPicked: boolean = false;
  /**
   * 各段起点（相对窄屏那一列 Column 的 y，vp）与滚动视口高度
   *
   * 段落判定**必须按滚动偏移算**，不能用 `onVisibleAreaChange` 的比例：那个回调只在
   * 可见比例跨过给定阈值时触发，而长区块（比如榜单卡）永远到不了 1.0，背景就永远停在
   * 第一段 —— 旧版回响踩过同一个坑，注释里写着「不要用露出过半」。这里照旧版：
   * 视口 45% 处落在哪一段，背景/标题就用哪一段。
   */
  private sectionTops: number[] = [-1, -1, -1, -1, -1, -1, -1];
  /** Scroll 视口高度（vp）：锚点 = 视口 45% */
  private scrollViewportH: number = 0;
  /** 内容总高（vp）：滚到底判定用 */
  private contentHeight: number = 0;

  aboutToAppear(): void {
    this.pickInitialMonth();
    this.refresh();
  }

  /**
   * 首屏月份：本月没有「听满 30 秒」的记录时，自动落到最近一个有数据的月份
   *
   * 回响的统计门槛是 `playedMs ≥ 30 秒`（ListenLog），而且流水里还混着旧版本迁移进来的
   * 历史（`playedMs=0`、`startedAt=0`，只进「最近播放」，不进回响）—— 所以「播放历史里
   * 有上百首、本月回响却是空的」是常态，不是数据丢了。旧版与派音都默认停在「本月」，
   * 用户第一眼就是空页，会以为坏了。这里只在**首次进入**自动跳一次；用户自己手动选到
   * 空月份时不再抢方向盘。
   */
  private pickInitialMonth(): void {
    if (this.initialMonthPicked) {
      return;
    }
    this.initialMonthPicked = true;
    const log: ListenLog = ListenLog.getInstance();
    const now = new Date();
    const currentYear: number = now.getFullYear();
    const currentMonth: number = now.getMonth() + 1;
    if (log.hasData(currentYear, currentMonth)) {
      return;
    }
    const months: MonthKey[] = log.months();
    if (months.length === 0) {
      return;
    }
    const latest: MonthKey = months[0];
    let offset: number = (latest.year - currentYear) * 12 + (latest.month - currentMonth);
    if (offset > 0) {
      offset = 0;
    }
    if (offset < -11) {
      offset = -11;
    }
    hilog.info(DOMAIN, TAG, '本月无回响数据，自动落到 %{public}d-%{public}d（offset=%{public}d）',
      latest.year, latest.month, offset);
    this.monthOffset = offset;
  }

  /** 流水在别处变了（播放器落盘 / 清空）：重算这一页 */
  onLogChanged(): void {
    this.refresh();
  }

  // ------------------------------------------------------------ 数据

  private refresh(): void {
    const log: ListenLog = ListenLog.getInstance();
    const range: MonthRange = monthRangeOf(this.monthOffset);
    const prev: MonthRange = monthRangeOf(this.monthOffset - 1);
    this.stats = buildMonthlyStats(log, range, prev);
    const options: MonthOption[] = buildMonthOptions(log.months(), range, this.monthOffset);
    this.rebuildPickers(range, options);
    this.publishTitle(range);
    // 换月后领奖台回到第 1 名，背景也跟着换成新月份的第 1 名封面
    this.podiumActive = 0;
    this.artistPicUrl = '';
    this.artistPicKey = '';
    this.resolveArtistBackground();
    this.applyTheme(this.themeCoverOfSection());
  }

  // ------------------------------------------------------------ 歌手写真（背景用）

  /**
   * 解析「最常听的歌手」本人的写真，给背景用
   *
   * 回响的聚合数据里 `EchoArtist.coverUrl` 是**借用的**「该歌手最常听那首歌的封面」——
   * 看起来就是一张专辑封面，用户 2026-11-15 反馈「有时候背景显示的是专辑封面，应该显示
   * 最常听歌手的封面」。本工程已有歌手写真缓存（`artist_cache.json`，`cachedArtistOf`
   * 同步读；没缓存再 `resolveArtistByName` 在线取一次），这里按「歌手名 + 来源」去解析：
   *   · 命中缓存 → 立刻用；
   *   · 没命中 → 先用歌封面兜底，在线取到后再淡入换成真写真。
   */
  private resolveArtistBackground(): void {
    if (this.stats.topArtists.length === 0) {
      return;
    }
    const artist: MonthlyArtist = this.stats.topArtists[0];
    const key: string = `${artist.source}\u0001${artist.name}`;
    if (key === this.artistPicKey) {
      return;
    }
    this.artistPicKey = key;
    const cached: LxArtist | null = cachedArtistOf(artist.name);
    if (cached !== null && cached.picUrl.length > 0) {
      this.artistPicUrl = cached.picUrl;
      this.applyTheme(this.themeCoverOfSection());
      return;
    }
    resolveArtistByName(artist.name, artist.source).then((resolved: LxArtist | null) => {
      // 异步回来时可能已经换月 / 换歌手了：只认「现在仍是同一个歌手」
      if (resolved === null || resolved.picUrl.length === 0 || this.artistPicKey !== key) {
        return;
      }
      hilog.info(DOMAIN, TAG, '歌手写真解析成功 name=%{public}s', artist.name);
      this.artistPicUrl = resolved.picUrl;
      this.applyTheme(this.themeCoverOfSection());
    }).catch(() => {
      // 取不到就继续用歌封面兜底，不影响页面
    });
  }

  // ------------------------------------------------------------ 背景氛围层

  /** 当前段落该拿哪张封面当背景（空串 = 没有氛围层，渐隐回纯黑） */
  private themeCoverOfSection(): string {
    if (this.isWide()) {
      // 宽屏两列同屏，段落判定没有意义：只跟领奖台中心那张走
      return this.podiumCover();
    }
    // 页头与歌曲榜都用领奖台中心那张封面（旧版进页面第一眼就是封面背景，不是黑屏）
    if (this.sectionIdx <= 1) {
      return this.podiumCover();
    }
    // 歌手段用**歌手本人的写真**（解析中 / 取不到时退回「他最常听那首歌的封面」）；
    // **专辑段沿用歌手背景**（用户 2026-11-15：取消专辑的背景过渡）
    if (this.sectionIdx === 2 || this.sectionIdx === 3) {
      if (this.artistPicUrl.length > 0) {
        return this.artistPicUrl;
      }
      return this.stats.topArtists.length > 0 ? this.stats.topArtists[0].coverUrl : '';
    }
    // 听众 / 完播率 / 新发现 / 滚到底：渐隐回纯黑
    return '';
  }

  /** 领奖台中心卡那张封面（没有就退第 1 名） */
  private podiumCover(): string {
    if (this.podiumActive >= 0 && this.podiumActive < this.stats.topSongs.length) {
      return this.stats.topSongs[this.podiumActive].coverUrl;
    }
    return this.stats.topSongs.length > 0 ? this.stats.topSongs[0].coverUrl : '';
  }

  /**
   * 应用背景主题（两层交叉淡入）
   *
   * 口径照旧版回响：同一个地址不重复做动画；第一次直接给结果（进页面不要闪）；
   * 目标为空串时两层都淡到 0（渐隐回页面底色）。
   */
  private applyTheme(cover: string): void {
    if (!this.themeInited) {
      this.themeInited = true;
      this.themeApplied = cover;
      this.bgUrlA = cover;
      this.bgOpA = cover.length > 0 ? 1 : 0;
      this.bgUrlB = '';
      this.bgOpB = 0;
      this.nextIsB = true;
      return;
    }
    if (cover === this.themeApplied) {
      return;
    }
    this.themeApplied = cover;
    if (cover.length === 0) {
      animateTo({ duration: THEME_FADE_MS, curve: Curve.EaseInOut }, () => {
        this.bgOpA = 0;
        this.bgOpB = 0;
      });
      return;
    }
    if (this.nextIsB) {
      this.bgUrlB = cover;
    } else {
      this.bgUrlA = cover;
    }
    animateTo({ duration: THEME_FADE_MS, curve: Curve.EaseInOut }, () => {
      if (this.nextIsB) {
        this.bgOpB = 1;
        this.bgOpA = 0;
      } else {
        this.bgOpA = 1;
        this.bgOpB = 0;
      }
    });
    this.nextIsB = !this.nextIsB;
  }

  /** 领奖台中心卡换了（滑到另一张）→ 背景跟着换 */
  private onPodiumActive(index: number): void {
    this.podiumActive = index;
    if (this.sectionIdx === 1 || this.isWide()) {
      this.applyTheme(this.themeCoverOfSection());
    }
  }

  /** 重建年 / 月两枚下拉的档位（有记录的月份在前，今年只到当月） */
  private rebuildPickers(range: MonthRange, options: MonthOption[]): void {
    // 年份：当前年 + 历史里出现过的年，新的在前
    const currentYear: number = new Date().getFullYear();
    const years: number[] = [currentYear];
    for (const option of options) {
      if (!years.includes(option.year)) {
        years.push(option.year);
      }
    }
    years.sort((left: number, right: number): number => right - left);
    const yearLabels: string[] = [];
    const yearOffsets: number[] = [];
    for (const year of years) {
      yearLabels.push(`${year} 年`);
      // 这一年的「代表偏移」：同月优先，否则该年最接近的一个（有记录才进来）
      yearOffsets.push(this.yearRepresentativeOffset(year, range, options));
    }
    this.yearLabels = yearLabels;
    this.yearOffsets = yearOffsets;
    this.yearIndex = Math.max(0, years.indexOf(range.year));

    // 月份：只列该年的有记录月份（当月永远补上）
    const monthLabels: string[] = [];
    const monthOffsets: number[] = [];
    for (const option of options) {
      if (option.year !== range.year) {
        continue;
      }
      monthLabels.push(`${option.month} 月`);
      monthOffsets.push(option.offset);
    }
    if (monthLabels.length === 0) {
      monthLabels.push(`${range.month} 月`);
      monthOffsets.push(this.monthOffset);
    }
    this.monthLabels = monthLabels;
    this.monthOffsets = monthOffsets;
    let index: number = monthOffsets.indexOf(this.monthOffset);
    if (index < 0) {
      index = 0;
    }
    this.monthIndex = index;
  }

  /** 某年份下拉档位应跳到哪个月份偏移：同月优先，否则该年最接近的一个 */
  private yearRepresentativeOffset(year: number, range: MonthRange, options: MonthOption[]): number {
    let best: number = this.monthOffset;
    let bestDistance: number = Number.MAX_SAFE_INTEGER;
    const now = new Date();
    for (const option of options) {
      if (option.year !== year) {
        continue;
      }
      const distance: number = Math.abs(option.month - range.month);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = option.offset;
      }
    }
    if (year === now.getFullYear()) {
      const distance: number = Math.abs((now.getMonth() + 1) - range.month);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = 0;
      }
    }
    return best;
  }

  /** 切月份：统一走这里（负数偏移夹到 [-11, 0]），切完重算并回顶 */
  private pickOffset(offset: number): void {
    const clamped: number = Math.min(0, Math.max(-11, offset));
    if (clamped === this.monthOffset) {
      return;
    }
    this.monthOffset = clamped;
    this.refresh();
    this.scroller.scrollEdge(Edge.Top);
    this.sectionTitle = '回响';
    this.publishTitle(monthRangeOf(this.monthOffset));
  }

  /**
   * 窗口宽度变了（分屏 / 横竖屏 / 折叠展开）：标题档位要跟着归位
   *
   * 宽屏两列同屏不切段名，所以切到宽屏时标题必须回到「N 月 · 回响」；切回窄屏时
   * 再按当前滚动段名给（sectionIdx 一直保留着最后判定出来的段）。
   */
  onWindowWidthChanged(): void {
    this.publishTitle(monthRangeOf(this.monthOffset));
    this.applyTheme(this.themeCoverOfSection());
  }

  /** 发布页头标题（值没变就不写 AppStorage，免得白刷一遍壳层） */
  private publishTitle(range: MonthRange): void {
    const name: string = this.isWide() ? '回响' : SECTION_NAMES[this.sectionIdx];
    const title: string = `${range.label} · ${name}`;
    if (AppStorage.get<string>(K_ECHO_TITLE) !== title) {
      AppStorage.setOrCreate(K_ECHO_TITLE, title);
    }
  }

  /**
   * 记下某一段的起点（相对窄屏 Column 的 y）
   *
   * 只存相对值：绝对位置 = 内容顶部内边距（this.topInset + 8）+ 相对值。这样不依赖
   * onAreaChange 的触发顺序（用 globalPosition 反推会要求 Scroll 的全局坐标先量到）。
   */
  private recordSectionTop(index: number, relativeY: number): void {
    if (index < 0 || index >= this.sectionTops.length) {
      return;
    }
    this.sectionTops[index] = relativeY;
    this.syncSectionByScroll();
  }

  /**
   * 按滚动位置决定「当前是哪一段」（背景主题与标题都跟着它）
   *
   * 锚点取视口 45% 处：锚点落到哪一段，就用哪一段的主题封面；段落顺序固定
   * 页头 → 歌曲 → 歌手 → 专辑 → 听众 → 完播率 → 新发现。滚到底部时自然进入
   * 「新发现」（主题为空 → 氛围层渐隐，露出纯黑/页面底色）。
   * 宽屏两列同屏，段落判定没有意义（背景只跟领奖台中心卡）。
   */
  private syncSectionByScroll(): void {
    if (this.isWide() || this.scrollViewportH <= 0) {
      return;
    }
    const offsetY: number = this.scroller.currentOffset().yOffset;
    const anchor: number = offsetY + this.scrollViewportH * 0.45;
    const paddingTop: number = this.topInset + 8;
    let target: number = 0;
    // 滚到底：直接算「最后一段」，让背景渐隐到纯黑
    // （内容不够长、锚点到不了最后一段时，用户仍能看到「底部变黑」的效果）
    if (this.contentHeight > 0 && offsetY + this.scrollViewportH >= this.contentHeight - 4) {
      target = 6;
    } else {
      for (let i: number = 0; i < this.sectionTops.length; i++) {
        const rel: number = this.sectionTops[i];
        if (rel >= 0 && anchor >= paddingTop + rel) {
          target = i;
        }
      }
    }
    if (target === this.sectionIdx) {
      return;
    }
    this.sectionIdx = target;
    this.applyTheme(this.themeCoverOfSection());
    if (!this.isWide()) {
      this.sectionTitle = SECTION_NAMES[target];
      this.publishTitle(monthRangeOf(this.monthOffset));
    }
  }

  private isWide(): boolean {
    return isWideWindow(this.windowWidth > 0 ? this.windowWidth : 360);
  }

  // ------------------------------------------------------------ 交互

  /**
   * 毫秒 → `m:ss`（给 `SongItem.interval` 用）
   *
   * 回响记录里没有原始 interval 字符串（只有 `ListenRecord.durationMs` 真实时长），
   * 直接传空串会让播放页 / 媒体中心**首帧**总时长是 0:00（随后被播放器回调修正）。
   * 用记录里的真实时长还原一下，首帧就是对的。
   */
  private intervalTextOf(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const total: number = Math.round(ms / 1000);
    const minutes: number = Math.floor(total / 60);
    const seconds: number = total % 60;
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`;
  }

  /**
   * 点一首歌 → 播放
   *
   * 与识别页同一个路子：回响里存的是「歌名 + 歌手 + 来源」，没有可以直接取流的地址
   * （那是**播放记录**，不是搜索结果），所以按名字在它原来的平台上搜一遍、取第一条；
   * 那个平台没版权或者搜不到，再跨平台聚合找一遍。
   */
  private async playSong(song: MonthlySong): Promise<void> {
    const key: string = `${song.name}\u0001${song.singer}`;
    if (this.playingKey.length > 0) {
      return;
    }
    const keyword: string = `${song.name} ${song.singer}`.trim();
    if (keyword.length === 0) {
      return;
    }
    this.playingKey = key;
    const quality: string = PlaySession.getInstance().quality;
    try {
      // ① 有平台 id + musicInfoJson 时**直接建队列播放**（与播放历史 / 收藏同一套装配，
      //    见 HistoryView.songItemOf + setQueueAndPlay）。旧回响只能按名字搜，是因为当时的
      //    EchoSong 不带 id；2.0 的 MonthlySong 专门补了 songId / musicInfoJson 两个字段。
      if (song.songId.length > 0 && song.musicInfoJson.length > 0) {
        const item: SongItem = {
          id: song.songId,
          name: song.name,
          singer: song.singer,
          coverUrl: song.coverUrl,
          art: song.art,
          source: song.source,
          quality: quality,
          interval: this.intervalTextOf(song.durationMs),
          musicInfoJson: song.musicInfoJson,
        };
        hilog.info(DOMAIN, TAG, '按记录 id 直接播放 id=%{public}s', song.songId);
        await PlaySession.getInstance().setQueueAndPlay([item], 0);
        return;
      }
      // ② 没有 id（v1 老记录 / 本地歌）：退回按「歌名 + 歌手」搜索
      if (song.source.length > 0 && isSearchSupported(song.source)) {
        hilog.info(DOMAIN, TAG, '按记录来源搜索播放 source=%{public}s keyword=%{public}s',
          song.source, keyword);
        const list: LxMusicInfo[] = await searchMusic(keyword, song.source, 1, PLAY_SEARCH_LIMIT);
        if (list.length > 0) {
          await PlaySession.getInstance().setQueueAndPlay([songFromSearch(list[0], quality)], 0);
          return;
        }
      }
      hilog.info(DOMAIN, TAG, '来源内没搜到，改为跨平台聚合搜索 keyword=%{public}s', keyword);
      const outcome: LxSearchOutcome = await searchMusicAll(keyword, SEARCH_PLATFORMS, 1, PLAY_SEARCH_LIMIT);
      if (outcome.items.length > 0) {
        await PlaySession.getInstance().setQueueAndPlay([songFromSearch(outcome.items[0], quality)], 0);
        return;
      }
      this.toast('没有找到可播放的版本');
    } catch (e) {
      hilog.error(DOMAIN, TAG, '播放收听记录失败: %{public}s', JSON.stringify(e));
      this.toast(`播放失败：${(e as Error).message}`);
    } finally {
      this.playingKey = '';
    }
  }

  /** 领奖台上的第 index 首（0 = 第 1 名） */
  private playSongAt(index: number): void {
    if (index < 0 || index >= this.stats.topSongs.length) {
      return;
    }
    void this.playSong(this.stats.topSongs[index]);
  }

  /** 点一张专辑 → 播这张专辑里这个月最常听的那首（聆听没有专辑详情页） */
  private playAlbumAt(index: number): void {
    if (index < 0 || index >= this.stats.topAlbums.length) {
      return;
    }
    const album: MonthlyAlbum = this.stats.topAlbums[index];
    if (album.topSong === null) {
      this.toast('这张专辑里没有能直接播放的版本');
      return;
    }
    void this.playSong(album.topSong);
  }

  /** 点第 index 位歌手（0 = 第 1 名）→ 他的聚合页 */
  private openArtistAt(index: number): void {
    if (index < 0 || index >= this.stats.topArtists.length) {
      return;
    }
    const artist: MonthlyArtist = this.stats.topArtists[index];
    const candidate: ArtistCandidate = {
      source: artist.source,
      name: artist.name,
      // 行尾小字写「N 首」：名单页据此说明「这位在这个月里听过几首」
      note: `${artist.songCount} 首`,
    };
    ArtistNav.getInstance().openArtist(candidate);
  }

  /** 点「单曲循环之王」/「深夜之歌」那一张卡 */
  private playHighlight(song: MonthlySong | null): void {
    if (song === null) {
      return;
    }
    void this.playSong(song);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 构建

  /** 你听了什么：3D 三卡榜台（数据不够三张时空位不画） */
  @Builder
  private topSongsSection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '你听了什么', subtitle: '最常听的歌' })
      if (this.stats.topSongs.length === 0) {
        EchoEmptyHint({ text: '这个月还没有听歌记录', hint: '听满 30 秒的歌会出现在回响里' })
      } else {
        EchoTopSongs({
          songs: this.stats.topSongs,
          totalPlays: this.stats.playCount,
          onPlay: (index: number) => {
            this.playSongAt(index);
          },
          onActive: (index: number) => {
            this.onPodiumActive(index);
          },
        })
      }
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(1, Number(newValue.position.y));
    })
  }

  /** 最常听的歌手 */
  @Builder
  private topArtistsSection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '最常听的歌手' })
      if (this.stats.topArtists.length === 0) {
        EchoEmptyHint({ text: '这个月还没有听歌记录', hint: '听满 30 秒的歌会出现在回响里' })
      } else {
        EchoTopArtists({
          artists: this.stats.topArtists,
          totalPlays: this.stats.playCount,
          onOpen: (index: number) => {
            this.openArtistAt(index);
          },
        })
      }
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(2, Number(newValue.position.y));
    })
  }

  /** 最常听的专辑 */
  @Builder
  private topAlbumsSection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '最常听的专辑' })
      if (this.stats.topAlbums.length === 0) {
        EchoEmptyHint({ text: '这个月还没有听歌记录', hint: '听满 30 秒的歌会出现在回响里' })
      } else {
        EchoTopAlbums({
          albums: this.stats.topAlbums,
          onOpen: (index: number) => {
            this.playAlbumAt(index);
          },
        })
      }
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(3, Number(newValue.position.y));
    })
  }

  /** 你是怎样的听众：时段柱图 + 日历 */
  @Builder
  private audienceSection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '你是怎样的听众' })
      EchoAudience({
        hours: this.stats.hourBuckets,
        days: this.stats.dayBuckets,
        monthLabel: monthRangeOf(this.monthOffset).label,
        listenDays: this.stats.listenDays,
        longestStreak: this.stats.longestStreak,
        bestDay: this.stats.bestDay,
        bestDayCount: this.stats.bestDayCount,
      })
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(4, Number(newValue.position.y));
    })
  }

  /** 单曲循环之王（本月最高的那首放了 ≥2 次才显示） */
  @Builder
  private loopKingSection() {
    if (this.stats.loopKing !== null && this.stats.loopKingCount >= 2) {
      Column({ space: 10 }) {
        EchoSectionTitle({ text: '单曲循环之王' })
        EchoSongHighlight({
          title: '单曲循环之王',
          song: this.stats.loopKing,
          countText: `连着放了 ${this.stats.loopKingCount} 遍`,
          onPlay: () => {
            this.playHighlight(this.stats.loopKing);
          },
        })
      }
      .width('100%')
    }
  }

  /** 深夜之歌（0-5 点听过才显示） */
  @Builder
  private nightSongSection() {
    if (this.stats.nightSong !== null && this.stats.nightCount > 0) {
      Column({ space: 10 }) {
        EchoSectionTitle({ text: '深夜之歌' })
        EchoSongHighlight({
          title: '深夜之歌',
          song: this.stats.nightSong,
          countText: `深夜听了 ${this.stats.nightCount} 次`,
          onPlay: () => {
            this.playHighlight(this.stats.nightSong);
          },
        })
      }
      .width('100%')
    }
  }

  /** 完播率 */
  @Builder
  private completionSection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '完播率' })
      EchoCompletionCard({
        rate: this.stats.completionRate,
        completeCount: this.stats.completeCount,
        skippedCount: this.stats.skippedCount,
        avgMinutes: this.stats.avgMinutesPerDay,
      })
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(5, Number(newValue.position.y));
    })
  }

  /** 新发现 */
  @Builder
  private discoverySection() {
    Column({ space: 10 }) {
      EchoSectionTitle({ text: '新发现' })
      EchoDiscoveryCard({ count: this.stats.newSongCount, total: this.stats.newSongTotal })
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(6, Number(newValue.position.y));
    })
  }

  /** 页头 + 三格统计 + 年月选择（空月份只留页头 + 年月切换器，不摆 0 值卡片） */
  @Builder
  private headerBlock() {
    Column({ space: 18 }) {
      EchoMonthHeader({ minutes: echoMinutes(this.stats.totalMs), ratioText: this.stats.ratioText })
      if (this.stats.hasData) {
        EchoOverviewCard({
          playCount: this.stats.playCount,
          songCount: this.stats.songCount,
          artistCount: this.stats.artistCount,
        })
      }
      EchoMonthPicker({
        yearLabels: this.yearLabels,
        yearIndex: this.yearIndex,
        monthLabels: this.monthLabels,
        monthIndex: this.monthIndex,
        onPickYear: (index: number) => {
          if (index >= 0 && index < this.yearOffsets.length) {
            this.pickOffset(this.yearOffsets[index]);
          }
        },
        onPickMonth: (index: number) => {
          if (index >= 0 && index < this.monthOffsets.length) {
            this.pickOffset(this.monthOffsets[index]);
          }
        },
      })
    }
    .width('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.recordSectionTop(0, Number(newValue.position.y));
    })
  }

  /** 窄屏：11 段单列（派音 12 段里裁掉了「新收藏」） */
  @Builder
  private narrowColumn() {
    Column({ space: 18 }) {
      this.headerBlock()
      if (this.stats.hasData) {
        this.topSongsSection()
        this.topArtistsSection()
        this.topAlbumsSection()
        this.audienceSection()
        this.loopKingSection()
        this.nightSongSection()
        this.completionSection()
        this.discoverySection()
      } else {
        EchoEmptyHint({
          text: '这个月还没有听歌记录',
          hint: '听满 30 秒的歌会出现在回响里',
        })
      }
    }
    .width('100%')
  }

  /** 宽屏：两列 1:1（左 7 段 / 右 4 段，与派音同一分组） */
  @Builder
  private wideColumns() {
    Row({ space: 18 }) {
      Column({ space: 18 }) {
        this.headerBlock()
        if (this.stats.hasData) {
          this.topSongsSection()
          this.audienceSection()
          this.loopKingSection()
          this.nightSongSection()
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 18 }) {
        if (this.stats.hasData) {
          this.topArtistsSection()
          this.topAlbumsSection()
          this.completionSection()
          this.discoverySection()
        } else {
          EchoEmptyHint({
            text: '这个月还没有听歌记录',
            hint: '听满 30 秒的歌会出现在回响里',
          })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 背景氛围层（在内容下面）：两层模糊封面交叉淡入 + 旧版那层「压暗 / 向下渐到纯黑」
      // 参数与旧版聆听回响**逐字一致**：模糊 70、每层 0.62 不透明度，上面压
      // #4D000000(0%) → #73000000(30%) → #B8000000(55%) → 纯黑(78%) → 纯黑(100%)。
      // 这层是「透明度不对 / 底部渐变到纯黑」的关键：顶部保留一点封面色相，78% 以下彻底黑。
      Column() {
        if (this.bgUrlA.length > 0) {
          Image(this.bgUrlA)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(BACKDROP_BLUR)
            .opacity(this.bgOpA * BACKDROP_OPACITY)
            .draggable(false)
        }
        if (this.bgUrlB.length > 0) {
          Image(this.bgUrlB)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(BACKDROP_BLUR)
            .opacity(this.bgOpB * BACKDROP_OPACITY)
            .draggable(false)
        }
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['#4D000000', 0.0], ['#73000000', 0.3], ['#B8000000', 0.55],
              ['#000000', 0.78], ['#000000', 1.0]],
          })
      }
      .width('100%')
      .height('100%')

      Column() {
        Scroll(this.scroller) {
          Column() {
            if (this.isWide()) {
              this.wideColumns()
            } else {
              this.narrowColumn()
            }
            // 底部占位：悬浮页签栏 + 迷你播放条
            Column().height(this.bottomInset + 120).width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: this.topInset + 8 })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            // 内容总高：判断「已经滚到底」用（滚到底 = 背景渐隐到纯黑）
            this.contentHeight = Number(newValue.height);
          })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .align(Alignment.Top)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          // 视口高度：段落判定的锚点 = 视口 45%（见 syncSectionByScroll）
          this.scrollViewportH = Number(newValue.height);
          this.syncSectionByScroll();
        })
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
          this.syncSectionByScroll();
        })
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
          // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
          BottomBar.notifyScrollDelta(this.getUIContext(), offset);
          return { offsetRemain: offset };
        })
      }
      .width('100%')
      .height('100%')

      // 顶栏渐隐：内容滚到透明标题栏下面时逐渐淡掉，避免与标题叠字。
      // 页签页壳层不画 TopFade，所以自己带一层；但**不用通用 TopFade**：它取主题的
      // `c_top_fade`（夜间 #121214），压在回响纯黑底上会留一条灰带 —— 这里用回响自己的
      // echo_top_fade / echo_top_fade_end（夜间 #000000 → 全透明），与页面底色严格同源。
      Column()
        .width('100%')
        .height(this.topInset + 10)
        .linearGradient({
          angle: 180,
          colors: [[ECHO_TOP_FADE, 0.0], [ECHO_TOP_FADE_END, 1.0]],
        })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ECHO_PAGE_BACKGROUND)
  }
}
