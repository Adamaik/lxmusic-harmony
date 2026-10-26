import { hilog } from '@kit.PerformanceAnalysisKit';
import { BottomBar } from '../ui/BottomBar';
import { ArtistNav } from '../ui/ArtistNav';
import { CONTENT_MAX_WIDTH } from '../ui/Layout';
import { C_RED, F_SECTION, F_SUB } from '../ui/Theme';
import { COUNTED_MS, EchoAlbum, EchoArtist, EchoCompletion, EchoSong, EchoStats, K_ECHO_VERSION,
  ListenLog } from '../core/history/ListenLog';
import { ArtistCandidate } from '../core/music/MusicArtist';
import { isSearchSupported, LxMusicInfo, LxSearchOutcome, SEARCH_PLATFORMS, searchMusic,
  searchMusicAll } from '../core/music/MusicSearch';
import { PlaySession, songFromSearch } from '../core/player/PlaySession';
import { E_CARD, E_TEXT, E_TEXT_SUB, E_TEXT_WEAK, EchoAlbumCard,
  EchoAlbumStrip, EchoArtistHero, EchoCalendar, EchoCompletionCard, EchoHourChart, EchoPickerPill,
  EchoPodiumSong, EchoRankList, EchoRankRow, EchoSongPodium, EchoSectionTitle, EchoStatsRow,
  EchoSubTitle, echoDurationText, echoShareText } from '../ui/EchoReport';

const DOMAIN: number = 0x0001;
const TAG: string = 'EchoView';

/**
 * 页头大标题（壳层订阅的那个键）
 *
 * 「10 月 · 回响」这行字画在**壳层的标题栏**里，与「推荐」「我的」同一个位置、同一档字号
 * （见 pages/Index.ets 的 homeHeader）—— 所以这一页把标题**发布**给壳层，自己不再画一遍：
 * 两处都画，屏幕上就是「回响」与「10 月 · 回响」上下叠着两个字（上一版就是这样）。
 */
export const K_ECHO_TITLE: string = 'ps_echo_title';

/** 页头大标题的文案（月份跟着选择器走，所以不能写死在 TABS 里） */
export function echoTitleOf(month: number): string {
  return month > 0 ? `${month} 月 · 回响` : '回响';
}

/**
 * 总时长那一行的字号
 *
 * 这一版把它当成整页的「主数字」：网易云年度报告那种版式，一进来先砸一个 34 号的大数
 * （截图里就是「4 分钟」），下面才是三格小统计。字号写在页面里而不是组件库里 ——
 * 它是**这一页的版面**（页首主数字），不是某个可复用组件的内部样式。
 */
const DURATION_SIZE: number = 34;
/** 领奖台摆前 3 名（截图里就是三张立体封面），第 4 名往后进榜单 */
const PODIUM_SIZE: number = 3;
/** 专辑横排最多摆 6 张：再多就横着翻不完了，6 张正好铺满一屏并露出「还有更多」的暗示 */
const ALBUM_STRIP_SIZE: number = 6;
/** 点一行去播放时，按「歌名 + 歌手」搜几条候选、取第一条（与识别页同一套） */
const PLAY_SEARCH_LIMIT: number = 10;
/** 歌曲榜 / 歌手榜最多展示的条数：超出的不显示 */
const ECHO_LIST_LIMIT: number = 50;
/**
 * 页面底色 / 中下部（「你是怎样的听众」往后）的纯黑
 *
 * 这一版的配色口径：背景是**固定的主题色氛围层**（当前段落 / 轮播中心卡的封面模糊而成），
 * 换段落时两层交叉淡入；「你是怎样的听众」那一段目标色为空，整屏渐隐成纯黑。
 */
const ECHO_BLACK: string = '#000000';
/**
 * 背景主题色的交叉淡入时长（毫秒）
 *
 * 太长会显得「颜色在慢吞吞地挪」，太短又像直接闪一下；400ms 左右正好是一眼能看出
 * 「颜色化过去」但不拖沓的量。
 */
const THEME_FADE_MS: number = 420;
/**
 * 封面模糊半径
 *
 * 要大到只剩色块（像播放页背景那样），否则背景里能看出封面的轮廓，文字压上去很脏。
 */
const BACKDROP_BLUR: number = 70;

/**
 * 回响（月度收听报告，深色沉浸版）
 *
 * 版式照网易云年度报告那种「固定深色沉浸式」重做：整页近黑渐变、亮粉强调，
 * 一进来先是总时长大字 + 三格统计（次播放 / 首歌 / 位歌手）+ 年 / 月选择，
 * 然后是三段故事线：
 *   1. 「你听了什么」——Top3 立体封面领奖台 + 第 4 名往后的榜单；
 *   2. 「最常听的歌手」——第 1 名大图卡 + 2 名往后的榜单，后面接「最常听的专辑」横排；
 *   3. 「你是怎样的听众」——听歌时段柱图、听歌日历、完播率圆环。
 *
 * 页面自己是**深色**的（浅色 token 一个都不用），但壳层标题栏是浅色主题的 —— 标题只
 * 发布不改色（见 K_ECHO_TITLE），大标题的颜色与状态栏图标由壳层统一处理。
 *
 * 数据全来自 {@link ListenLog}（一次播放一条流水）与它的聚合，页面自己不算数；
 * 流水一变（切歌、退到后台落盘、播放中每 60 秒一次的落盘、清空）就由 @StorageLink 把
 * 这一页刷一遍。与上一版比，数据层升级成了「回响与播放历史共用一套流水」，所以这里
 * 多了专辑 / 时段 / 日历 / 完播率四块聚合，页面只负责摆。
 *
 * 只算「听满 30 秒」的那几次播放（门槛在 ListenLog，不在这一页）：点开一下就切走的不算听过。
 */
@Component
export struct EchoView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 内容底部要留出的空间：悬浮页签栏 + 迷你条（由壳层算好） */
  @Prop bottomInset: number = 0;
  /** 流水版本号：变了就重算这一页 */
  @StorageLink(K_ECHO_VERSION) @Watch('onLogChanged') logVersion: number = 0;
  /** 选中的年月：进来默认当月 */
  @State year: number = 0;
  @State month: number = 0;
  @State stats: EchoStats = new EchoStats();
  /** 这个月听过的歌（ListenLog 已按「次数降序、次数同则总时长降序」排好） */
  @State songs: EchoSong[] = [];
  /** 这个月听过的歌手（已按播放次数降序） */
  @State artists: EchoArtist[] = [];
  /** 这个月听过的专辑（已按播放次数降序） */
  @State albums: EchoAlbum[] = [];
  /** 24 个小时各听了几次（柱图） */
  @State hours: number[] = [];
  /** 当月每天听了几次，下标 0 = 1 号（日历） */
  @State days: number[] = [];
  /**
   * 下面四组是**派生数据**：组件库要的数据形状 / 整句文案，都在 refresh 里一次算好
   *
   * 为什么不放在 build 里现算：@Builder 里不能声明局部变量，一段段三元与 for 循环塞进
   * UI 描述里既没法读也没法测；而且派生数组换了新对象才会触发子组件重刷（原地改不算），
   * 统一在 refresh 里「重建 + 整体赋值」正好对上这个刷新口径。
   */
  @State podium: EchoPodiumSong[] = [];
  @State songRows: EchoRankRow[] = [];
  @State artistRows: EchoRankRow[] = [];
  @State albumCards: EchoAlbumCard[] = [];
  /** 完播率卡片：数字与四行文案 */
  @State completionRate: number = 0;
  @State completionPercent: string = '—';
  @State completionMain: string = '';
  @State completionComplete: string = '';
  @State completionSkip: string = '';
  @State completionFoot: string = '';
  /** 听歌日历下面那两行说明 */
  @State calendarHint: string = '';
  @State calendarBest: string = '';
  /**
   * 背景主题色氛围（**两层交叉淡入**）
   *
   * 月报的背景跟着内容走：最上面的歌曲榜用「轮播当前中间那张封面」，滚到歌手段换成
   * 冠军歌手的封面、专辑段换成专辑封面，最后「你是怎样的听众」是纯黑（两层都收掉）。
   * 所以背景是**固定**在页面上的（不随内容滚），换段落 / 轮播切封面时用两层模糊图
   * 交叉淡入淡出 —— 直接换 URL 会闪一下，两层各自调 opacity 才像「颜色化过去」。
   */
  @State bgUrlA: string = '';
  @State bgUrlB: string = '';
  @State bgOpA: number = 0;
  @State bgOpB: number = 0;
  /**
   * 当前段落：songs（歌曲榜）/ artist（歌手）/ album（专辑）/ analysis（听众分析）
   *
   * 由**滚动位置**驱动（见 syncSectionByScroll）：取「视口 45% 高度处」落在哪一段，
   * 背景就换成那一段的主题封面。不要用 onVisibleAreaChange 的「露出过半」——
   * 歌曲榜能有 50 行、高度远超一屏，比例永远到不了 0.5，整页背景就切不过去。
   */
  @State sectionKey: string = 'songs';
  /** 轮播当前中心那张的下标（0 = 第 1 名）：切封面时背景要跟着换 */
  @State podiumActive: number = 0;
  /** 滚动容器（要拿 currentOffset 判断段落） */
  private scroller: Scroller = new Scroller();
  /** Scroll 视口高度（vp）：判定锚点 = 视口 45% */
  private scrollViewportH: number = 0;
  /** reportSections 根节点在滚动内容里的起始 y（vp），由它自己的 onAreaChange 写入 */
  private sectionBase: number = 0;
  /** 每段相对 reportSections 根节点的起始 y（vp） */
  private sectionOffsets: Map<string, number> = new Map<string, number>();
  /** 段落从上到下的顺序（判定时取「最后一个起点在锚点之上的段」） */
  private sectionOrder: string[] = ['songs', 'artist', 'album', 'analysis'];
  /** 下一次主题封面写哪一层（两层轮换；只在方法里用，不参与界面刷新） */
  private nextIsB: boolean = true;
  /** 上一次应用的主题地址（同一个值不重复做动画） */
  private themeApplied: string = '';
  /** 第一次应用主题直接给结果、不做动画（页面刚进来时不要闪一下黑） */
  private themeInited: boolean = false;
  /** 年选择器的档：有记录的年份 + 今年（新的在前） */
  @State years: number[] = [];
  /** 月选择器的档：选中年份里能选的月份（新的在前，今年只到当月） */
  @State monthOptions: number[] = [];
  /** 正在按名字去搜的那一首（防连点） */
  @State playingKey: string = '';

  aboutToAppear(): void {
    const now = new Date();
    this.year = now.getFullYear();
    this.month = now.getMonth() + 1;
    this.refresh();
  }

  /** 流水在别处变了（播放器落盘 / 清空）：重算这一页 */
  onLogChanged(): void {
    this.refresh();
  }

  // ------------------------------------------------------------ 数据

  private refresh(): void {
    const log: ListenLog = ListenLog.getInstance();
    this.stats = log.statsOf(this.year, this.month);
    // 歌曲榜 / 歌手榜最多 50 条：超出的不显示（数据仍然全量聚合，只是展示截断）
    this.songs = log.songsOf(this.year, this.month).slice(0, ECHO_LIST_LIMIT);
    this.artists = log.artistsOf(this.year, this.month).slice(0, ECHO_LIST_LIMIT);
    this.albums = log.albumsOf(this.year, this.month);
    this.hours = log.hoursOf(this.year, this.month);
    this.days = log.daysOf(this.year, this.month);
    this.years = this.yearOptions();
    this.monthOptions = this.monthOptionsOf(this.year);
    this.rebuildLists();
    this.rebuildCompletion(log.completionOf(this.year, this.month));
    this.rebuildCalendar();
    // 背景主题：换月 / 数据变了就按「当前段落 + 轮播当前那张」重新取一次封面
    this.applyTheme(this.themeCoverOfSection());
    // 标题画在壳层的标题栏里，跟着选中的月份走（见 K_ECHO_TITLE）；
    // 值没变就别写 AppStorage，免得白刷一遍壳层
    const title: string = echoTitleOf(this.month);
    if (AppStorage.get<string>(K_ECHO_TITLE) !== title) {
      AppStorage.setOrCreate(K_ECHO_TITLE, title);
    }
  }

  /** 年选择器：今年永远在里面（当月还没听歌时也得能选到当月），其余按有记录的年份补 */
  private yearOptions(): number[] {
    const currentYear: number = new Date().getFullYear();
    const years: number[] = [currentYear];
    for (const key of ListenLog.getInstance().months()) {
      if (!years.includes(key.year)) {
        years.push(key.year);
      }
    }
    // 新的在前：排序函数写成闭包，别依赖外部状态
    years.sort((left: number, right: number): number => right - left);
    return years;
  }

  /** 某年能选的月份：往下的 12 个月；今年只到当月（将来的月份没有账可看） */
  private monthOptionsOf(year: number): number[] {
    const now = new Date();
    const top: number = year === now.getFullYear() ? now.getMonth() + 1 : 12;
    const months: number[] = [];
    for (let month = top; month >= 1; month--) {
      months.push(month);
    }
    return months;
  }

  /**
   * 当前段落该用哪张封面当背景主题色
   *
   *   - songs：跟着**轮播当前中间那张**走（用户左右滑动切封面时，背景也要跟着换）；
   *     中间那张没封面就退到这个月第一张有封面的歌，再退到冠军歌手的封面；
   *   - artist：冠军歌手的封面（歌手没有写真，用他最常听那首歌的封面，见 ListenLog.artistsOf）；
   *   - album：最常听专辑的封面；
   *   - analysis：空串 —— 背景渐隐到纯黑（截图里「你是怎样的听众」就是纯黑底）。
   */
  private themeCoverOfSection(): string {
    if (this.sectionKey === 'artist') {
      return this.artists.length > 0 ? this.artists[0].coverUrl : '';
    }
    if (this.sectionKey === 'album') {
      return this.albums.length > 0 ? this.albums[0].coverUrl : '';
    }
    if (this.sectionKey === 'analysis') {
      return '';
    }
    if (this.podiumActive >= 0 && this.podiumActive < this.songs.length) {
      const current: EchoSong = this.songs[this.podiumActive];
      if (current.coverUrl.length > 0) {
        return current.coverUrl;
      }
    }
    for (const song of this.songs) {
      if (song.coverUrl.length > 0) {
        return song.coverUrl;
      }
    }
    return this.artists.length > 0 ? this.artists[0].coverUrl : '';
  }

  /**
   * 把背景主题切到某张封面
   *
   * 两层轮换 + 交叉淡入：新封面写进「当前不在显示的那一层」，然后把两层透明度对调，
   * 这样换色是渐变的、不会闪；目标为空串时只把现有那层渐隐到 0，露出的就是纯黑底。
   * 第一次（页面刚进来）直接给结果不做动画。
   */
  private applyTheme(cover: string): void {
    if (cover === this.themeApplied) {
      return;
    }
    this.themeApplied = cover;
    if (!this.themeInited) {
      this.themeInited = true;
      this.bgUrlA = cover;
      this.bgOpA = cover.length > 0 ? 1 : 0;
      this.bgOpB = 0;
      return;
    }
    if (cover.length === 0) {
      // 渐隐到纯黑：两层都收到 0，下一张封面来了再淡入
      animateTo({ duration: THEME_FADE_MS, curve: Curve.EaseInOut }, () => {
        this.bgOpA = 0;
        this.bgOpB = 0;
      });
      return;
    }
    // 写进「看不见的那一层」，再对调透明度
    if (this.nextIsB) {
      this.bgUrlB = cover;
    } else {
      this.bgUrlA = cover;
    }
    const writingB: boolean = this.nextIsB;
    this.nextIsB = !writingB;
    animateTo({ duration: THEME_FADE_MS, curve: Curve.EaseInOut }, () => {
      if (writingB) {
        this.bgOpB = 1;
        this.bgOpA = 0;
      } else {
        this.bgOpA = 1;
        this.bgOpB = 0;
      }
    });
  }

  /**
   * 记下某一段相对（reportSections 根节点）的起始位置
   *
   * 只存相对值、不存绝对值：绝对值要在滚动时现算（内容坐标 = 顶部占位 + 根节点偏移 +
   * 段偏移），这样不依赖 onAreaChange 的触发顺序 —— 用 globalPosition 反推会依赖
   * 「Scroll 的全局坐标先测到」，两者顺序不保证。
   */
  private recordSectionTop(section: string, area: Area): void {
    this.sectionOffsets.set(section, Number(area.position.y));
    this.syncSectionByScroll();
  }

  /**
   * 按滚动位置决定背景主题属于哪一段
   *
   * 判定锚点取视口 45% 处：锚点落到哪一段，就用哪一段的主题封面。段落顺序固定
   * songs → artist → album → analysis，取「最后一个起点在锚点之上的段」。
   * 这样即使某一段有几十行、高度远超一屏，也能在它滚进视口中部时正确切过去；
   * 滚到底部时自然进入 analysis（主题为空 → 渐变成纯黑）。
   */
  private syncSectionByScroll(): void {
    if (this.scrollViewportH <= 0) {
      return;
    }
    const offsetY: number = this.scroller.currentOffset().yOffset;
    const anchor: number = offsetY + this.scrollViewportH * 0.45;
    let target: string = 'songs';
    for (const key of this.sectionOrder) {
      const rel: number | undefined = this.sectionOffsets.get(key);
      if (rel !== undefined && anchor >= this.topInset + 14 + this.sectionBase + rel) {
        target = key;
      }
    }
    if (target !== this.sectionKey) {
      this.sectionKey = target;
      this.applyTheme(this.themeCoverOfSection());
    }
  }

  /**
   * 轮播换了中心卡（用户左右滑动 / 点侧卡）：背景跟着换成那张封面的主题色
   *
   * 只在这一段（歌曲榜）是当前段时才换 —— 用户已经滚到下面的段落时，滑轮播
   * 不应该把背景抢回歌曲主题。
   */
  private onPodiumActive(index: number): void {
    this.podiumActive = index;
    if (this.sectionKey === 'songs') {
      this.applyTheme(this.themeCoverOfSection());
    }
  }

  private pickYear(year: number): void {
    this.year = year;
    const months: number[] = this.monthOptionsOf(year);
    this.monthOptions = months;
    // 换到「今年」时，原来选的月份可能还没到（比如原来在 12 月、现在只是 10 月），往前收一档
    if (!months.includes(this.month)) {
      this.month = months.length > 0 ? months[0] : 1;
    }
    // 换年月回到页面顶部，背景主题也回到歌曲榜
    this.sectionKey = 'songs';
    this.podiumActive = 0;
    this.refresh();
  }

  private pickMonth(month: number): void {
    if (this.month === month) {
      return;
    }
    this.month = month;
    // 换年月回到页面顶部，背景主题也回到歌曲榜
    this.sectionKey = 'songs';
    this.podiumActive = 0;
    this.refresh();
  }

  /**
   * 把原始聚合数据翻成组件库要的三种行 / 卡
   *
   * 名次直接用数组下标 + 偏移算（数据层已经排好序，页面不再排一遍）：
   *   - 歌：领奖台是 1~3 名，榜单从第 4 名起；
   *   - 歌手：第 1 名是大图卡，榜单从第 2 名起。
   */
  private rebuildLists(): void {
    // —— 歌：Top3 领奖台
    const podium: EchoPodiumSong[] = [];
    const podiumTop: number = this.songs.length < PODIUM_SIZE ? this.songs.length : PODIUM_SIZE;
    for (let i = 0; i < podiumTop; i++) {
      const song: EchoSong = this.songs[i];
      const item: EchoPodiumSong = {
        rank: i + 1,
        name: song.name,
        singer: song.singer,
        coverUrl: song.coverUrl,
        art: song.art,
        plays: song.plays,
        // 占比用「这首歌的次数 / 这个月总次数」：榜单之间可以横向比
        share: echoShareText(song.plays, this.stats.playCount),
      };
      podium.push(item);
    }
    this.podium = podium;

    // —— 歌：第 4 名往后
    const songRows: EchoRankRow[] = [];
    for (let i = PODIUM_SIZE; i < this.songs.length; i++) {
      const song: EchoSong = this.songs[i];
      const row: EchoRankRow = {
        rank: i + 1,
        name: song.name,
        sub: song.singer,
        count: `${song.plays} 次`,
      };
      songRows.push(row);
    }
    this.songRows = songRows;

    // —— 歌手：第 2 名往后（第 1 名单独是大图卡）
    const artistRows: EchoRankRow[] = [];
    for (let i = 1; i < this.artists.length; i++) {
      const artist: EchoArtist = this.artists[i];
      const row: EchoRankRow = {
        rank: i + 1,
        name: artist.name,
        // 歌手行不给副标题：名字本身就是全部信息，再塞「N 首」会和右边的次数重叠
        sub: '',
        count: `${artist.plays} 次`,
      };
      artistRows.push(row);
    }
    this.artistRows = artistRows;

    // —— 专辑：前 6 张横排
    const albumCards: EchoAlbumCard[] = [];
    const albumTop: number = this.albums.length < ALBUM_STRIP_SIZE ? this.albums.length : ALBUM_STRIP_SIZE;
    for (let i = 0; i < albumTop; i++) {
      const album: EchoAlbum = this.albums[i];
      const card: EchoAlbumCard = {
        name: album.name,
        coverUrl: album.coverUrl,
        art: album.art,
        meta: `${album.plays} 次`,
      };
      albumCards.push(card);
    }
    this.albumCards = albumCards;
  }

  /**
   * 完播率卡片
   *
   * 口径在数据层（EchoCompletion）：judged = 当月「听满 30 秒」的播放次数，complete =
   * 完整听完的次数（playedMs / 歌曲时长 ≥ 0.85），skipped = judged - complete。
   * 时长是**系统自己记的**（AVPlayer 上报的真实时长，见 ListenRecord.durationMs）；
   * 老记录没有时长时数据层会用全库平均时长兜底，所以这里永远算得出一个百分比，
   * 不会再出现「音源没给时长，暂时算不出完播率」。
   */
  private rebuildCompletion(completion: EchoCompletion): void {
    const judged: number = completion.judged;
    const complete: number = completion.complete;
    const skipped: number = completion.skipped;
    const days: number = completion.days;
    const rate: number = judged > 0 ? Math.round(complete / judged * 100) : 0;
    this.completionRate = rate;
    this.completionPercent = `${rate}%`;
    this.completionMain = '的歌被听到了最后';
    this.completionComplete = `完整听完 ${complete} 次`;
    this.completionSkip = `中途切走 ${skipped} 次`;
    // 平均每个听歌日：总时长 / 有听歌的天数（days 是「有听歌的天数」，不是当月天数）
    this.completionFoot = days > 0 ? `平均每个听歌日 ${echoDurationText(completion.totalMs / days)}` : '';
  }

  /**
   * 听歌日历下面那两行说明
   *
   * hint 说「这个月一共几天、其中几天在听歌」；best 找次数最多的那一天。
   * 一天都没听时 best 给空串（别画「0 月 0 日听得最多」这种假话），hint 照常
   * —— 空月份也想知道「30 天里 0 天在听歌」这件事。
   */
  private rebuildCalendar(): void {
    const total: number = this.days.length;
    let listening: number = 0;
    let bestIndex: number = -1;
    let bestCount: number = 0;
    for (let i = 0; i < this.days.length; i++) {
      const count: number = this.days[i];
      if (count > 0) {
        listening++;
      }
      // 并列最多时取最早的一天：日历是从左往右读的，先出现的更自然
      if (count > bestCount) {
        bestCount = count;
        bestIndex = i;
      }
    }
    this.calendarHint = `${total} 天里有 ${listening} 天在听歌`;
    this.calendarBest = bestIndex >= 0
      ? `${this.month} 月 ${bestIndex + 1} 日听得最多 —— ${bestCount} 次`
      : '';
  }

  private confirmClear(): void {
    this.getUIContext().showAlertDialog({
      title: '清空收听记录',
      message: '清空之后「回响」里的月度统计与记录就都没了，这个动作没法撤销。',
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => {
        } },
        {
          value: '清空',
          fontColor: C_RED,
          action: () => {
            ListenLog.getInstance().clear();
            this.refresh();
            this.toast('收听记录已清空');
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 播放 / 跳转

  /**
   * 点一行 → 播放这一首
   *
   * 与识别页同一个路子：回响里存的是「歌名 + 歌手 + 来源」，没有可以直接取流的 id
   * （那是**播放记录**，不是搜索结果），所以按名字在它原来的平台上搜一遍、取第一条；
   * 那个平台没版权或者搜不到，再跨平台聚合找一遍。
   */
  private async playSong(song: EchoSong): Promise<void> {
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
    if (index < 0 || index >= this.songs.length) {
      return;
    }
    void this.playSong(this.songs[index]);
  }

  /**
   * 点一张专辑 → 播这张专辑里这个月听过的第一首歌
   *
   * 回响里没有专辑 id（流水只记了专辑名），所以拿专辑名去**这个月听过的歌**里对第一首
   * 同专辑的 —— 对不上就不响应（宁可不响，也别随便播一首不在这张专辑里的歌）。
   */
  private playAlbumAt(index: number): void {
    if (index < 0 || index >= this.albums.length) {
      return;
    }
    const album: EchoAlbum = this.albums[index];
    for (const song of this.songs) {
      if (song.albumName === album.name) {
        void this.playSong(song);
        return;
      }
    }
  }

  /** 点第 index 位歌手（0 = 第 1 名）→ 他的聚合页 */
  private openArtistAt(index: number): void {
    if (index < 0 || index >= this.artists.length) {
      return;
    }
    const artist: EchoArtist = this.artists[index];
    const candidate: ArtistCandidate = {
      source: artist.source,
      name: artist.name,
      // 行尾小字写「N 首」：名单页据此说明「这位在这个月里听过几首」
      note: `${artist.songCount} 首`,
    };
    ArtistNav.getInstance().openArtist(candidate);
  }

  /**
   * 点「位歌手」那一格：把这个月听过的歌手整份名单交给壳层的歌手列表页
   * （见 ui/ArtistNav.ets）
   */
  private openArtists(): void {
    const candidates: ArtistCandidate[] = [];
    for (const artist of this.artists) {
      candidates.push({
        source: artist.source,
        name: artist.name,
        note: `${artist.songCount} 首`,
      });
    }
    ArtistNav.getInstance().openList('这个月听过的歌手',
      `${this.year} 年 ${this.month} 月 · 共 ${this.artists.length} 位`, candidates);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 构建

  @Builder
  yearMenu() {
    Menu() {
      ForEach(this.years, (item: number) => {
        MenuItem({ content: `${item} 年` })
          .onClick(() => {
            this.pickYear(item);
          })
      }, (item: number) => `y${item}`)
    }
  }

  @Builder
  monthMenu() {
    Menu() {
      ForEach(this.monthOptions, (item: number) => {
        MenuItem({ content: `${item} 月` })
          .onClick(() => {
            this.pickMonth(item);
          })
      }, (item: number) => `m${item}`)
    }
  }

  /**
   * 有记录时的正文：三段故事线
   *
   * 名次、次数、占比都是数据层排好 / 页面算好的，这里只负责摆 —— 点歌走 playSongAt，
   * 点歌手上聚合页，点专辑播这张专辑里这个月的第一首。空月份不进来（见 build 里的空态）。
   */
  @Builder
  reportSections() {
    /**
     * 外面这层 Column 只做两件事：给构建函数一个**唯一根节点**（@Builder 的函数体按
     * build() 的语法规则写，并列多个根节点在不同 SDK 版本上支持不一致，包一层最稳），
     * 以及让所有小节共享同一个 100% 宽的容器。子项全是 width 100%，版面不变。
     *
     * 里面每一段都包一层 Column 挂 onVisibleAreaChange：哪一段有一半露出来，背景主题
     * 就换成那一段的封面（见 onSectionVisible）—— 这是「翻到歌手段背景跟着换」的入口。
     */
    Column() {
      // ---------------------------------------------------- 你听了什么
      Column() {
        EchoSectionTitle({ text: '你听了什么', topMargin: 34 })
        EchoSubTitle({ text: '最常听的歌', topMargin: 20 })
        EchoSongPodium({
          items: this.podium,
          onPick: (index: number) => {
            this.playSongAt(index);
          },
          // 轮播中心卡换了（左右滑 / 点侧卡）→ 背景跟着换成那张封面（见 onPodiumActive）
          onActive: (index: number) => {
            this.onPodiumActive(index);
          },
        })
          .margin({ top: 16 })
        if (this.songRows.length > 0) {
          EchoRankList({
            rows: this.songRows,
            // 歌曲榜是一整块：4 名往后的行数常常十几条，散在渐变上会显得碎
            card: true,
            onPick: (index: number) => {
              // rows 从第 4 名起（下标 0 对应 songs[3]），所以这里要补上领奖台那 3 首
              this.playSongAt(index + PODIUM_SIZE);
            },
          })
            .margin({ top: 10 })
        }
      }
      .width('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.recordSectionTop('songs', newValue);
        this.syncSectionByScroll();
      })

      // ---------------------------------------------------- 最常听的歌手
      if (this.artists.length > 0) {
        Column() {
          EchoSectionTitle({ text: '最常听的歌手', topMargin: 34 })
          /**
           * 冠军大图与 2 名以后的榜单拼成**一个连续图形**（截图里它们是一张卡：
           * 上半是大图、下半接着排名行，中间没有缝、也没有两张卡的圆角互相怼着）。
           * 做法：外层只给一次卡底与圆角并裁切，大图传 radius 0（顶角由外层裁出来），
           * 榜单走 card:false（透明、不带自己的圆角），于是两块天然接在一起。
           */
          Column() {
            EchoArtistHero({
              name: this.artists[0].name,
              coverUrl: this.artists[0].coverUrl,
              art: this.artists[0].art,
              meta: `${this.artists[0].plays} 次播放 · ${echoShareText(this.artists[0].plays, this.stats.playCount)}`,
              radius: 0,
              onPick: () => {
                this.openArtistAt(0);
              },
            })
            if (this.artistRows.length > 0) {
              EchoRankList({
                rows: this.artistRows,
                // 透明榜单：卡底与外层圆角都由外面这一层给，接在大图下面就是同一张卡
                card: false,
                onPick: (index: number) => {
                  // rows 从第 2 名起（下标 0 对应 artists[1]）
                  this.openArtistAt(index + 1);
                },
              })
            }
          }
          .width('100%')
          .backgroundColor(E_CARD)
          .borderRadius(20)
          .clip(true)
          .margin({ top: 16 })
        }
        .width('100%')
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.recordSectionTop('artist', newValue);
          this.syncSectionByScroll();
        })
      }

      // ---------------------------------------------------- 最常听的专辑
      // 这里是**子标题**级别（与「最常听的歌」同一档）：专辑是前面歌 / 歌手那条线的补充，
      // 不给它再开一个大节标题，否则「你是怎样的听众」之前会冒出第三层结构
      if (this.albumCards.length > 0) {
        Column() {
          EchoSubTitle({ text: '最常听的专辑', topMargin: 26 })
          EchoAlbumStrip({
            items: this.albumCards,
            onPick: (index: number) => {
              this.playAlbumAt(index);
            },
          })
            .margin({ top: 12 })
        }
        .width('100%')
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.recordSectionTop('album', newValue);
          this.syncSectionByScroll();
        })
      }

      // ---------------------------------------------------- 你是怎样的听众
      // 这一段背景是纯黑（themeCoverOfSection 对 analysis 返回空串，氛围层渐隐到 0）
      Column() {
        EchoSectionTitle({ text: '你是怎样的听众', topMargin: 36 })
        EchoSubTitle({ text: '听歌时段', topMargin: 20 })
        EchoHourChart({ counts: this.hours })
          .margin({ top: 12 })
        EchoSubTitle({ text: '听歌日历', topMargin: 26 })
        EchoCalendar({
          counts: this.days,
          hint: this.calendarHint,
          bestText: this.calendarBest,
        })
          .margin({ top: 12 })
        EchoSubTitle({ text: '完播率', topMargin: 26 })
        EchoCompletionCard({
          rate: this.completionRate,
          percentText: this.completionPercent,
          mainText: this.completionMain,
          completeText: this.completionComplete,
          skipText: this.completionSkip,
          footText: this.completionFoot,
        })
          .margin({ top: 12 })
      }
      .width('100%')
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.recordSectionTop('analysis', newValue);
        this.syncSectionByScroll();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 根节点相对滚动内容的偏移：段落的绝对位置 = 顶部占位 + 这个偏移 + 段自身的相对位置
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.sectionBase = Number(newValue.position.y);
      this.syncSectionByScroll();
    })
  }

  /**
   * 背景主题氛围层（固定在页面上，不随内容滚）
   *
   * 两层模糊封面交叉淡入（切换逻辑见 applyTheme）：当前段落 / 轮播中心卡换了封面，
   * 就淡到新的那一张。上面再压一层「上保留色相、往下渐到纯黑」—— 文字都压在深色区，
   * 读得清；目标为空（「你是怎样的听众」段）时两层都收到 0，露出的就是纯黑底。
   */
  @Builder
  backdropLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.bgUrlA.length > 0) {
        Image(this.bgUrlA)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(BACKDROP_BLUR)
          .opacity(this.bgOpA * 0.62)
          .draggable(false)
      }
      if (this.bgUrlB.length > 0) {
        Image(this.bgUrlB)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(BACKDROP_BLUR)
          .opacity(this.bgOpB * 0.62)
          .draggable(false)
      }
      // 压暗 + 向下渐到纯黑：顶部留一点封面的色相，30% 后开始收，78% 之后彻底黑
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
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------------------------------------------------- 页面底色
      // 纯黑垫底：氛围层没图 / 渐隐到 0 时露出的就是它（「你是怎样的听众」段整屏纯黑）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(ECHO_BLACK)

      // 主题色氛围层：固定铺满页面（不随内容滚），随段落 / 轮播中心卡交叉淡入（见 applyTheme）
      this.backdropLayer()

      /**
       * 内容铺满整页、从透明标题栏下面穿过去（与「推荐」「我的」等页面一致）
       *
       * 标题栏是透明的，滚动内容会从「10 月 · 回响」底下滑过；靠近顶部时由下面那条
       * 「深色半透明 → 透明」的渐隐吃掉 —— 这就是其它页 TopFade 的观感。这一页顶部
       * 底色是封面的模糊色、没有固定色可渐，所以渐隐用半透明黑压暗而不是铺底色
       * （铺系统材质模糊会变成一条灰白色的带子，之前就是这么翻车的）。
       */
      Column() {
        Scroll(this.scroller) {
          Column() {
              // 顶部占位：让出透明标题栏那一段（大标题在标题栏里，内容从它下面开始）
              Column().height(this.topInset + 14).width('100%')

              Column() {
                // 「10 月 · 回响」这个标题不在这里画：它由壳层的标题栏承载（见 K_ECHO_TITLE），
                // 与「推荐」「我的」同一个位置。这一页从总时长大字开始
                Text(echoDurationText(this.stats.totalMs))
                  .fontSize(DURATION_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(E_TEXT)
                  .width('100%')
                  .textAlign(TextAlign.Start)

                // 三格统计：次播放 / 首歌 / 位歌手（「位歌手」那一格点进这个月的歌手名单）
                EchoStatsRow({
                  playCount: this.stats.playCount,
                  songCount: this.stats.songCount,
                  artistCount: this.stats.artistCount,
                  onArtists: () => {
                    this.openArtists();
                  },
                })
                  .margin({ top: 18 })

                // 年 / 月两颗胶囊 +（有数据时）右上角「清空」
                Row({ space: 10 }) {
                  Row() {
                    EchoPickerPill({ text: `${this.year} 年` })
                  }
                  .bindMenu(this.yearMenu())
                  .accessibilityText(`年份：${this.year} 年，点按切换`)
                  .accessibilityLevel('yes')

                  Row() {
                    EchoPickerPill({ text: `${this.month} 月` })
                  }
                  .bindMenu(this.monthMenu())
                  .accessibilityText(`月份：${this.month} 月，点按切换`)
                  .accessibilityLevel('yes')

                  Blank()

                  if (this.songs.length > 0) {
                    Text('清空')
                      .fontSize(F_SUB)
                      .fontColor(E_TEXT_SUB)
                      .padding({ left: 8, right: 4, top: 8, bottom: 8 })
                      .onClick(() => {
                        this.confirmClear();
                      })
                      .accessibilityText('清空收听记录')
                      .accessibilityLevel('yes')
                  }
                }
                .width('100%')
                .margin({ top: 22 })

                if (this.songs.length === 0) {
                  /**
                   * 空月份：整页深色引导，不摆空卡片
                   *
                   * 一段留白 + 两行字（照截图的分量）：这个月没听歌时，三格数字 / 年月选择
                   * 都还在（还能翻到别的月），但下面没有任何榜单可摆 —— 摆一排 0 和空卡
                   * 只会让人以为页面坏了。
                   */
                  Column({ space: 8 }) {
                    Text('这个月还没有收听记录')
                      .fontSize(F_SECTION)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(E_TEXT)
                    // 「听满 30 秒」这个门槛不在页面里写死：跟着数据层的 COUNTED_MS 走，
                    // 以后门槛改了这句引导自动是对的
                    Text(`听满 ${Math.round(COUNTED_MS / 1000)} 秒的歌会出现在回响里`)
                      .fontSize(F_SUB)
                      .fontColor(E_TEXT_WEAK)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Center)
                  .margin({ top: 56 })
                } else {
                  this.reportSections()
                }

                Column().height(this.bottomInset + 16).width('100%')
              }
              .width('100%')
              /**
               * 宽屏下这一页收成居中的一列，窄屏铺满 —— 两种情况下都留 16 的左右内边距
               *
               * 口径与设置类表单一致（见 ui/Layout.ets 的 CONTENT_MAX_WIDTH）：月报是一张
               * 报告，一共几屏内容，平板上拉满 1400vp 的话大数字孤零零挂在最左边。
               * 外层的 Column 用 HorizontalAlign.Center 让限宽后的这一列居中。
               */
              .padding({ left: 16, right: 16 })
              .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Top)
        // 视口高度：判定锚点用它（段落位置取相对坐标，见 recordSectionTop）
        .onAreaChange((oldValue: Area, newValue: Area) => {
          this.scrollViewportH = Number(newValue.height);
          this.syncSectionByScroll();
        })
        // 背景主题跟着滚动实时判定（滚到歌手段 → 歌手封面；滚到底 → 纯黑）
        .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
          this.syncSectionByScroll();
        })
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
          // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
          BottomBar.notifyScrollDelta(this.getUIContext(), offset);
          return { offsetRemain: offset };
        })
        .width('100%')
      }
      .width('100%')
      .height('100%')

      /**
       * 顶栏渐隐（与其它页一致的观感：内容滑到标题下面会逐渐淡掉直到看不见）
       *
       * 其它页用「页面底色 → 透明」的 TopFade；这一页顶部是封面的模糊色、没有固定色
       * 可渐，于是用「深色半透明黑 → 全透明」：只压暗、不铺底色 —— 标题区仍是主题色
       * 氛围，内容越靠近顶部越淡。**不要换成系统材质模糊**：浅色模式下材质是白灰的，
       * 压在深色背景上就是一条灰白色带子（之前那版就是这么错的）。
       * 压在滚动内容之上、标题栏之下；hitTestBehavior 透明，不拦滚动与点击。
       */
      Column()
        .width('100%')
        .height(this.topInset + 18)
        .linearGradient({
          angle: 180,
          colors: [['#B3000000', 0.0], ['#73000000', 0.55], ['#00000000', 1.0]],
        })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    // 兜底底色：氛围层还没画出来的那一帧、或封面取不到时，露出来的也是纯黑，
    // 而不是壳层 WidePane 的浅色底
    .backgroundColor(ECHO_BLACK)
  }
}
