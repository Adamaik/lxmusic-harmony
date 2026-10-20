import { common } from '@kit.AbilityKit';
import { BottomBar } from '../ui/BottomBar';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';
import { BookShelf, ShelvedBook } from '../core/book/BookShelf';
import { BookExploreCategory, BookHit, BookSourceInfo } from '../core/book/BookTypes';
import { BookLoginWeb } from '../components/BookLoginWeb';
import { C_BG, C_CARD, C_DIVIDER, C_ICON, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK,
  F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { glassLight, immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { CapsuleSegment } from '../ui/CapsuleSegment';
import { I_BOOK, I_BOOKSHELF, I_CHEVRON_DOWN, I_CHEVRON_RIGHT, I_CLOSE, I_IMPORT, I_REFRESH,
  I_SEARCH, I_TRASH, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';
import { CONTENT_MAX_WIDTH, contentColumnsFor, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED } from '../ui/Layout';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenView';

/** 分段选择器（书架 / 发现 / 搜索 / 书源）在宽屏下的最大宽度：拉满整屏会变成一条又长又扁的带子 */
const SEGMENT_MAX_WIDTH: number = 560;

/** 四个分段：书架（我的书）/ 发现（按分类推书）/ 搜索（找书）/ 书源（导入与管理） */
const PANE_SHELF: number = 0;
const PANE_DISCOVER: number = 1;
const PANE_SEARCH: number = 2;
const PANE_SOURCE: number = 3;

/** 书源筛选里「不筛」的那一项 */
const FILTER_ALL: string = '';

/**
 * 书名行
 *
 * 听书的条目与歌曲不一样（没有歌手/专辑那一套），所以不复用 SongRow：
 * 主标题是书名，副标题是「作者 · 分类 · 集数」里能拿到的部分。
 */
@Component
export struct BookRow {
  @Prop name: string = '';
  @Prop subtitle: string = '';
  @Prop coverUrl: string = '';
  @Prop badge: string = '';
  @Prop showChevron: boolean = true;
  @Prop coverSize: number = 56;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      CoverArt({ url: this.coverUrl, name: this.name, boxSize: this.coverSize, radius: 10 })

      Column({ space: 5 }) {
        Text(this.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Row({ space: 6 }) {
          if (this.badge.length > 0) {
            Text(this.badge)
              .fontSize(10.5)
              .fontColor(C_RED)
              .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
              .backgroundColor($r('app.color.c_red_tint'))
              .borderRadius(6)
          }
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showChevron) {
        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_TEXT_WEAK })
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 10, bottom: 10 })
    .onClick(() => {
      this.onTap();
    })
    .accessibilityGroup(true)
    .accessibilityText(this.subtitle.length > 0 ? `${this.name}，${this.subtitle}` : this.name)
    .accessibilityLevel('yes')
  }
}

/** 分类卡片的配色（按分类顺序循环取，同一个源每次进来颜色不变） */
const CAT_COLORS: string[][] = [
  ['#7B6CF6', '#4E3FD6'],
  ['#3FD07A', '#17A94F'],
  ['#FF7A59', '#E2432F'],
  ['#4FA8FF', '#1E6FD9'],
  ['#FFB13D', '#E0810F'],
  ['#F26DB4', '#C22C86'],
];

function catColors(index: number): string[] {
  return CAT_COLORS[index % CAT_COLORS.length];
}

/** 分类卡片的高度：横滑那一排与卡片本身共用 */
const CAT_CARD_H: number = 84;

/**
 * 分类卡片（发现页那排横滑卡片）
 *
 * 画法照首页推荐的榜单卡片（见 views/RecommendView.ets 的 RankCard）：渐变底 + 底部压暗
 * + 白字，只是小一号 —— 分类名就两到四个字，做成长条卡片比药丸好扫，颜色也帮着记位置。
 * 点一下 = 把下面的书单换成这个分类；选中态加一圈白边。
 */
@Component
struct CategoryCard {
  @Prop title: string = '';
  @Prop colorA: string = '#7B6CF6';
  @Prop colorB: string = '#4E3FD6';
  @Prop cardWidth: number = 118;
  @Prop selected: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 160, colors: [[this.colorA, 0.0], [this.colorB, 1.0]] })
      // 底部压暗，白字才跳得出来
      Column()
        .width('100%')
        .height('60%')
        .linearGradient({ angle: 0, colors: [['#00000000', 0.0], ['#59000000', 1.0]] })
      Text(this.title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textShadow({ radius: 10, color: '#33000000', offsetX: 0, offsetY: 2 })
        .padding({ left: 11, right: 11, bottom: 10 })
    }
    .width(this.cardWidth)
    .height(CAT_CARD_H)
    .borderRadius(18)
    .clip(true)
    .border({ width: this.selected ? 2 : 0, color: '#FFFFFF' })
    .shadow({ radius: 12, color: '#1A000000', offsetX: 0, offsetY: 5 })
    .onClick(() => {
      this.onTap();
    })
    .accessibilityGroup(true)
    .accessibilityText(this.selected ? `分类 ${this.title}，已选中` : `分类 ${this.title}`)
    .accessibilityLevel('yes')
  }
}

/**
 * 听书页
 *
 * 「阅读（Legado）」书源的入口：导入书源 → 发现 / 搜索 → 打开一本书 → 播它的某一集。
 * 书源协议与音源完全不同（见 core/book/book_preload.js 的说明），所以这里是一套
 * 自己的四段式：**书架 / 发现 / 搜索 / 书源**。
 *
 * 四段放在一页里而不是拆成四个页签，是因为它们的使用频率差很多（书架天天看、
 * 书源一个月动一次），拆页签会让底栏变成五个，得不偿失。
 */
@Component
export struct ListenView {
  /** 让出顶部标题栏（状态栏 + 标题栏） */
  @Prop topInset: number = 0;
  /** 让出底部页签栏 + 手势条 */
  @Prop bottomInset: number = 0;
  /** 纯状态栏高度（网页登录那种整屏覆盖层要自己补，不经过标题栏） */
  @Prop safeTop: number = 0;
  /** 纯手势条高度 */
  @Prop safeBottom: number = 0;
  onOpenBook: (hit: BookHit) => void = () => {
  };
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /**
   * 窗口宽度（vp）：四个分段里的列表按它算一屏几列（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），本页只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  @State pane: number = PANE_SHELF;
  @State sources: BookSourceInfo[] = [];
  /**
   * 已经登录过的书源 id
   *
   * 单独存一份 @State 而不是每次 build 里去读引擎：`ForEach` 按 id 做 diff，
   * 登录状态变了但 id 没变时**不会重建条目** —— 只读引擎的话按钮文案就永远停在
   * 「登录」。这份状态既参与渲染，也被拼进 ForEach 的 key，状态一变条目必重建。
   */
  @State loggedIds: string[] = [];
  @State shelf: ShelvedBook[] = [];
  /** 搜索 */
  @State keyword: string = '';
  @State searching: boolean = false;
  @State results: BookHit[] = [];
  @State searched: boolean = false;
  @State status: string = '';
  @State filter: string = FILTER_ALL;
  /** 发现（按分类推书）：书源 → 分类卡片 → 书单，三段状态都在这里 */
  @State discoverSources: BookSourceInfo[] = [];
  /** 当前看的是哪个书源的分类（空 = 还没有可发现的源） */
  @State categorySourceId: string = '';
  @State cats: BookExploreCategory[] = [];
  /** 当前选中的分类下标（-1 = 还没选过） */
  @State catIndex: number = -1;
  @State discoverBooks: BookHit[] = [];
  @State discoverLoading: boolean = false;
  /** 「书单」那一行右侧的小字：加载进度 / 共几本 / 没有更多了 */
  @State discoverStatus: string = '';
  /** 拉失败的原因（空 = 没出错） */
  @State discoverError: string = '';
  @State discoverPage: number = 1;
  /** 还能翻下一页（分类地址带 {{page}}，且上一页确实拿到了新书） */
  @State discoverMore: boolean = false;
  /** 书源管理：导入状态 */
  @State busy: boolean = false;
  @State sourceStatus: string = '';
  @State pasteText: string = '';
  /** 书源登录弹窗（只有声明了 loginUrl/loginUi 的源才用得上） */
  @State loginOpen: boolean = false;
  @State loginSourceId: string = '';
  @State loginSourceName: string = '';
  @State loginStatus: string = '';
  @State loginBusy: boolean = false;
  /** 网页登录（应用内浏览器打开站点登录页，登录后抓 Cookie） */
  @State loginWebOpen: boolean = false;
  @State loginWebSourceId: string = '';
  @State loginWebTitle: string = '';
  @State loginWebUrl: string = '';
  @State loginWebSite: string = '';

  aboutToAppear(): void {
    const engine = BookEngine.getInstance();
    const context = this.getUIContext().getHostContext() as common.Context;
    BookShelf.getInstance().init(context);
    void engine;
    this.refresh();
  }

  private refresh(): void {
    const engine = BookEngine.getInstance();
    this.sources = engine.listSources();
    const logged: string[] = [];
    for (const info of this.sources) {
      if (engine.hasLoginInfo(info.id)) {
        logged.push(info.id);
      }
    }
    this.loggedIds = logged;
    this.shelf = BookShelf.getInstance().list();
  }

  /**
   * 一屏放几列（宽屏多列，窄屏 1 列 = 改之前的样子）
   *
   * 口径在 ui/Layout.ets 的 contentColumnsFor：按窗口宽度算，一列至少 360vp、最多 4 列。
   * 书架、发现、搜索结果、书源四张列表都用它。
   */
  private columns(): number {
    return contentColumnsFor(this.windowWidth);
  }

  /**
   * 表单类内容（导入书源那一段）在宽屏下的最大宽度
   *
   * 列表可以多列，表单不行：窗口宽到 1400vp 还把粘贴框拉满，就是一条又长又扁的带子、
   * 两个按钮各占半个屏幕。所以这里收成与设置类页面同一个口径（CONTENT_MAX_WIDTH），
   * 窄屏不限宽。
   */
  private formMaxWidth(): number {
    return this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED;
  }

  /** 能不能搜：至少有一个带搜索能力的源 */
  private searchableSources(): BookSourceInfo[] {
    return this.sources.filter((s: BookSourceInfo) => s.canSearch);
  }

  private filterSourceIds(): string[] {
    if (this.filter !== FILTER_ALL) {
      return [this.filter];
    }
    const ids: string[] = [];
    for (const s of this.searchableSources()) {
      ids.push(s.id);
    }
    return ids;
  }

  // ------------------------------------------------------------ 搜索

  private async doSearch(): Promise<void> {
    const word: string = this.keyword.trim();
    if (word.length === 0) {
      this.status = '先输入书名或主播名';
      return;
    }
    const ids: string[] = this.filterSourceIds();
    if (ids.length === 0) {
      this.status = '还没有可用的书源，先到「书源」分段导入一个';
      this.pane = PANE_SOURCE;
      return;
    }
    this.searching = true;
    this.searched = true;
    this.results = [];
    const merged: BookHit[] = [];
    const failures: string[] = [];
    let done: number = 0;
    for (const id of ids) {
      const info: BookSourceInfo | null = BookEngine.getInstance().getSource(id);
      this.status = `正在搜「${word}」…（${done + 1}/${ids.length}）`;
      try {
        const hits: BookHit[] = await BookEngine.getInstance().search(id, word, 1);
        for (const hit of hits) {
          merged.push(hit);
        }
      } catch (e) {
        const name: string = info !== null ? info.name : id;
        failures.push(`${name}：${(e as Error).message}`);
        hilog.warn(DOMAIN, TAG, 'search failed on %{public}s: %{public}s', id, (e as Error).message);
      }
      done++;
    }
    this.results = merged;
    this.searching = false;
    if (merged.length === 0 && failures.length > 0) {
      this.status = `都没搜到。${failures[0]}`;
    } else if (merged.length === 0) {
      this.status = '没有搜到结果，换个关键词试试';
    } else if (failures.length > 0) {
      this.status = `共 ${merged.length} 条（${failures.length} 个书源没成功）`;
    } else {
      this.status = `共 ${merged.length} 条结果`;
    }
  }

  private resetSearch(): void {
    this.keyword = '';
    this.results = [];
    this.searched = false;
    this.status = '';
  }

  // ------------------------------------------------------------ 发现（按分类推书）

  /**
   * 能用「发现」的书源
   *
   * 只按 `canExplore`（exploreUrl 非空）筛，**不去真的解析分类表** —— 那要为每个源
   * 跑一遍解析，而用户一次只看一个源。分类表在切到那个源时再取。
   */
  private explorableSources(): BookSourceInfo[] {
    return this.sources.filter((s: BookSourceInfo) => s.canExplore);
  }

  /**
   * 进发现分段
   *
   * 源列表每次进来都重建（只读本地索引，不联网），导入 / 删除书源立刻反映；
   * 但**只有还没选过源时才自动选第一个并拉书** —— 否则每次切回来都重新联网，
   * 明明上次的书单还在。
   */
  private onDiscoverEnter(): void {
    this.discoverSources = this.explorableSources();
    if (this.discoverSources.length === 0) {
      this.categorySourceId = '';
      this.cats = [];
      this.catIndex = -1;
      this.discoverBooks = [];
      this.discoverStatus = '';
      this.discoverError = '';
      return;
    }
    let keep: boolean = false;
    for (const s of this.discoverSources) {
      if (s.id === this.categorySourceId && this.cats.length > 0) {
        keep = true;
        break;
      }
    }
    if (keep) {
      return;
    }
    this.switchSource(this.discoverSources[0].id);
  }

  /** 换一个书源：分类表是本地解析（不联网），拿到就自动拉第一个分类的书 */
  private switchSource(sourceId: string): void {
    this.categorySourceId = sourceId;
    this.catIndex = -1;
    this.cats = [];
    this.discoverBooks = [];
    this.discoverPage = 1;
    this.discoverMore = false;
    this.discoverStatus = '';
    this.discoverError = '';
    try {
      this.cats = BookEngine.getInstance().exploreCategories(sourceId);
    } catch (e) {
      this.discoverError = `读不到这个书源的发现分类：${(e as Error).message}`;
      return;
    }
    if (this.cats.length === 0) {
      // `@js:` 那种自己生成分类表的写法引擎还不认（要跑沙箱），这个源就不出现在发现页
      this.discoverError = '这个书源的发现规则不是静态分类表（可能是 @js 动态生成的），发现页暂时用不了它。';
      return;
    }
    void this.loadCategory(0, 1);
  }

  /**
   * 拉一个分类的书（page > 1 时追加到现有列表 = 「加载更多」）
   *
   * **必须串行**：书源规则都跑在同一个沙箱页面里，`CUR_SOURCE` 是沙箱里的单个全局
   * （见 book_preload.js）—— 并发下发多个作业会互相串味。
   */
  private async loadCategory(index: number, page: number): Promise<void> {
    if (index < 0 || index >= this.cats.length) {
      return;
    }
    const cat: BookExploreCategory = this.cats[index];
    const first: boolean = page <= 1;
    this.catIndex = index;
    this.discoverLoading = true;
    this.discoverError = '';
    if (first) {
      this.discoverBooks = [];
      this.discoverPage = 1;
    }
    this.discoverStatus = `正在加载「${cat.title}」…`;
    try {
      const hits: BookHit[] =
        await BookEngine.getInstance().explore(this.categorySourceId, cat.url, page);
      const fresh: BookHit[] = this.dedupe(hits, first ? [] : this.discoverBooks);
      this.discoverBooks = first ? fresh : this.discoverBooks.concat(fresh);
      this.discoverPage = page;
      // 这一页一本新的都没拿到（翻到底了，或分类地址里根本没有 {{page}}）就不再给「加载更多」
      this.discoverMore = fresh.length > 0 && cat.url.indexOf('{{page}}') >= 0;
      if (this.discoverBooks.length === 0) {
        this.discoverStatus = '';
      } else if (!first && fresh.length === 0) {
        this.discoverStatus = `已加载全部 ${this.discoverBooks.length} 本`;
      } else {
        this.discoverStatus = this.discoverMore
          ? `共 ${this.discoverBooks.length} 本`
          : `共 ${this.discoverBooks.length} 本（没有更多了）`;
      }
    } catch (e) {
      this.discoverError = `「${cat.title}」没加载出来：${(e as Error).message}`;
      this.discoverMore = false;
      this.discoverStatus = '';
      hilog.warn(DOMAIN, TAG, 'explore failed on %{public}s: %{public}s',
        this.categorySourceId, (e as Error).message);
    } finally {
      this.discoverLoading = false;
    }
  }

  /** 去掉已有的（按 BookHit.id：`来源id:书地址`） */
  private dedupe(incoming: BookHit[], existing: BookHit[]): BookHit[] {
    const seen: Set<string> = new Set();
    for (const hit of existing) {
      seen.add(hit.id);
    }
    const out: BookHit[] = [];
    for (const hit of incoming) {
      if (seen.has(hit.id)) {
        continue;
      }
      seen.add(hit.id);
      out.push(hit);
    }
    return out;
  }

  // ------------------------------------------------------------ 书源导入

  private importText(text: string): void {
    this.busy = true;
    try {
      const imported: BookSourceInfo[] = BookEngine.getInstance().importSources(text);
      this.refresh();
      this.sourceStatus = `已导入 ${imported.length} 个书源：${imported[0].name}${imported.length > 1 ? ' 等' : ''}`;
      this.pasteText = '';
    } catch (e) {
      this.sourceStatus = `导入失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  /** 从文件导入（选一个 .json 书源文件） */
  private async pickSourceFile(): Promise<void> {
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.Context);
      const uris: string[] = await documentPicker.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return;
      }
      this.busy = true;
      this.sourceStatus = '正在读取书源文件…';
      try {
        const imported: BookSourceInfo[] = BookEngine.getInstance().importFromUri(uris[0]);
        this.refresh();
        this.sourceStatus = `已导入 ${imported.length} 个书源：${imported[0].name}${imported.length > 1 ? ' 等' : ''}`;
      } catch (e) {
        this.sourceStatus = `导入失败：${(e as Error).message}`;
      } finally {
        this.busy = false;
      }
    } catch (e) {
      this.sourceStatus = `选择文件失败：${(e as Error).message}`;
    }
  }

  private removeSource(id: string): void {
    BookEngine.getInstance().removeSource(id);
    // 书架里来自这个源的书一起清掉，免得点开发现源没了
    BookShelf.getInstance().dropBySource(id);
    if (this.filter === id) {
      this.filter = FILTER_ALL;
    }
    this.refresh();
    this.sourceStatus = '已删除该书源';
  }

  // ------------------------------------------------------------ 书源登录

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 打开应用内浏览器，让用户在站点自己的登录页上登录 */
  private openWebLogin(): void {
    const engine = BookEngine.getInstance();
    const url: string = engine.loginPageUrl(this.loginSourceId);
    if (!/^https?:/i.test(url)) {
      this.loginStatus = '这个书源没有可打开的登录页（缺 loginUrl / bookSourceUrl）';
      return;
    }
    const info: BookSourceInfo | null = engine.getSource(this.loginSourceId);
    this.loginWebSourceId = this.loginSourceId;
    this.loginWebTitle = this.loginSourceName;
    this.loginWebUrl = url;
    this.loginWebSite = info !== null ? info.url : '';
    this.loginOpen = false;
    this.loginWebOpen = true;
  }

  /** 应用内浏览器关闭：把抓到的 Cookie 存进登录信息 */
  private onWebLoginClosed(cookie: string): void {
    this.loginWebOpen = false;
    const text: string = cookie !== undefined && cookie !== null ? cookie.trim() : '';
    if (text.length === 0) {
      this.loginStatus = '没抓到 Cookie（可能还没登录成功）';
      return;
    }
    BookEngine.getInstance().saveWebLogin(this.loginWebSourceId, text);
    this.loginStatus = `已抓取本站 Cookie（${text.length} 字符）并保存`;
    this.refresh();
    this.toast('登录信息已保存');
  }

  private isLoggedIn(info: BookSourceInfo): boolean {
    return this.loggedIds.includes(info.id);
  }

  /** 打开某个书源的登录弹窗（只做网页登录，不再有手填表单） */
  private openLogin(info: BookSourceInfo): void {
    this.loginSourceId = info.id;
    this.loginSourceName = info.name;
    this.loginStatus = this.isLoggedIn(info) ? '已保存登录信息，可直接重新登录或清除' : '';
    this.loginBusy = false;
    this.loginOpen = true;
  }

  /** 跑 `loginCheckJs` 看是否真的登录上了 */
  private async checkLoginNow(): Promise<void> {
    const engine = BookEngine.getInstance();
    this.loginBusy = true;
    try {
      const text: string = await engine.checkLogin(this.loginSourceId);
      if (text.length === 0) {
        this.loginStatus = '这个书源没有提供登录检查';
      } else if (text === 'false' || text === '0') {
        this.loginStatus = '还没登录（检查未通过）';
      } else {
        this.loginStatus = `登录检查：${text}`;
      }
      this.refresh();
    } catch (e) {
      this.loginStatus = `检查失败：${(e as Error).message}`;
    } finally {
      this.loginBusy = false;
    }
  }

  private clearLoginNow(): void {
    BookEngine.getInstance().clearLoginInfo(this.loginSourceId);
    this.loginStatus = '已清除登录信息';
    this.refresh();
    this.toast('已清除登录信息');
  }

  // ------------------------------------------------------------ 片段构建

  @Builder
  searchField() {
    Row({ space: 8 }) {
      IconGlyph({ symbol: I_SEARCH, iconSize: 18, color: C_TEXT_SUB })
        .accessibilityLevel('no')
      TextInput({ text: this.keyword, placeholder: '书名 / 主播' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 15 })
        .fontSize(15)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(28)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          void this.doSearch();
        })
      if (this.keyword.length > 0) {
        IconGlyph({ symbol: I_CLOSE, iconSize: 16, color: C_TEXT_WEAK })
          .onClick(() => {
            this.resetSearch();
          })
          .accessibilityText('清空关键词')
          .accessibilityLevel('yes')
      }
    }
    .layoutWeight(1)
    .height(44)
    .padding({ left: 14, right: 12 })
    .attributeModifier(thinGlass(23, false, '', this.materialLevel))
    .systemMaterial(immersiveMaterialFor(this.materialLevel))
    // 边沿那圈光：鸿蒙7 是空效果（光感归材质），鸿蒙6 落成 HDS 轮廓点光（普通光效）
    .visualEffect(glassLight())
  }

  /** 书源筛选胶囊（全部 / 某个源） */
  @Builder
  sourceFilterPill() {
    Row({ space: 3 }) {
      Text(this.filterLabel())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.filter === FILTER_ALL ? C_TEXT : C_RED)
        .maxLines(1)
      IconGlyph({
        symbol: I_CHEVRON_DOWN,
        iconSize: 13,
        color: this.filter === FILTER_ALL ? C_TEXT_SUB : C_RED,
      })
        .accessibilityLevel('no')
    }
    .height(30)
    .padding({ left: 12, right: 8 })
    .attributeModifier(thinGlass(15, false, '', this.materialLevel))
    .systemMaterial(immersiveMaterialFor(this.materialLevel))
    // 边沿那圈光：鸿蒙7 是空效果（光感归材质），鸿蒙6 落成 HDS 轮廓点光（普通光效）
    .visualEffect(glassLight())
    .bindMenu(this.sourceFilterMenu())
    .accessibilityText(`搜索范围：${this.filterLabel()}，点按切换`)
    .accessibilityLevel('yes')
  }

  private filterLabel(): string {
    if (this.filter === FILTER_ALL) {
      return `全部书源（${this.searchableSources().length}）`;
    }
    const info: BookSourceInfo | null = BookEngine.getInstance().getSource(this.filter);
    return info !== null ? info.name : '全部书源';
  }

  @Builder
  sourceFilterMenu() {
    Menu() {
      MenuItem({ content: `全部书源（${this.searchableSources().length}）` })
        .onClick(() => {
          this.filter = FILTER_ALL;
        })
      ForEach(this.searchableSources(), (info: BookSourceInfo) => {
        MenuItem({ content: info.name })
          .onClick(() => {
            this.filter = info.id;
          })
      }, (info: BookSourceInfo) => info.id)
    }
  }

  // ------------------------------------------------------------ 书架分段

  @Builder
  shelfPane() {
    if (this.shelf.length === 0) {
      EmptyState({
        icon: I_BOOKSHELF,
        text: '书架还是空的',
        hint: this.sources.length === 0
          ? '先到「书源」分段导入一个听书书源（阅读/Legado 的 JSON 书源），然后就能搜索并加入书架了。'
          : '到「搜索」分段找一本书，打开后点「加入书架」就会出现在这里。',
        topPadding: 56,
      })
    } else {
      List() {
        ForEach(this.shelf, (item: ShelvedBook) => {
          ListItem() {
            BookRow({
              name: item.book.name,
              subtitle: this.shelfSubtitle(item),
              coverUrl: item.book.coverUrl,
              badge: item.book.sourceName,
              onTap: () => {
                this.onOpenBook(item.book);
              },
            })
          }
        }, (item: ShelvedBook) => item.book.id)
        ListItem() {
          Column().height(this.bottomInset + 96)
        }
      }
      .lanes(this.columns())
      .width('100%')
      .layoutWeight(1)
.scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 84, endMargin: 0 })
      .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
        // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
        BottomBar.notifyScrollDelta(this.getUIContext(), offset);
        return { offsetRemain: offset };
      })
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
        // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
        BottomBar.notifyScrollDelta(this.getUIContext(), offset);
        return { offsetRemain: offset };
      })
    }
  }

  private shelfSubtitle(item: ShelvedBook): string {
    const parts: string[] = [];
    if (item.book.author.length > 0) {
      parts.push(item.book.author);
    }
    if (item.chapters.length > 0) {
      parts.push(`共 ${item.chapters.length} 集`);
      if (item.lastChapter > 0) {
        parts.push(`听到第 ${item.lastChapter + 1} 集`);
      }
    } else {
      parts.push('目录未拉取');
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------ 搜索分段

  @Builder
  searchPane() {
    Column() {
      Row({ space: 10 }) {
        this.searchField()
        Text(this.searching ? '搜索中' : '搜索')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.searching ? C_TEXT_WEAK : C_RED)
          .onClick(() => {
            void this.doSearch();
          })
          .accessibilityText('搜索')
          .accessibilityLevel('yes')
      }
      .width('100%')
      // 宽屏下搜索框不跟着铺满（与「搜索」页同一条口径）：1400vp 宽的一条输入框又长又扁
      .constraintSize({ maxWidth: this.formMaxWidth() })
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Row({ space: 8 }) {
        SectionTitle({ text: '搜索结果' })
        Blank()
        if (this.searchableSources().length > 1) {
          this.sourceFilterPill()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 4 })

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
          .textAlign(TextAlign.Start)
      }

      if (this.searching) {
        Column() {
          LoadingProgress().width(38).height(38).color(C_RED)
        }
        .width('100%')
        .padding({ top: 48 })
      } else if (this.results.length === 0) {
        EmptyState({
          icon: this.searched ? I_SEARCH : I_BOOK,
          text: this.searched ? '没有搜到结果' : '搜一本书试试',
          hint: this.searched
            ? '换个书名或主播名，或者把搜索范围切到某一个书源上。'
            : '输入书名或主播名，一次问所有已导入的听书书源。',
          topPadding: 48,
        })
      } else {
        List() {
          ForEach(this.results, (hit: BookHit) => {
            ListItem() {
              BookRow({
                name: hit.name,
                subtitle: [hit.author, hit.kind, hit.status].filter((s: string) => s.length > 0).join(' · '),
                coverUrl: hit.coverUrl,
                badge: hit.sourceName,
                onTap: () => {
                  this.onOpenBook(hit);
                },
              })
            }
          }, (hit: BookHit) => hit.id)
          ListItem() {
            Column().height(this.bottomInset + 96)
          }
        }
        .lanes(this.columns())
        .width('100%')
        .layoutWeight(1)
.scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 84, endMargin: 0 })
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
          // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
          BottomBar.notifyScrollDelta(this.getUIContext(), offset);
          return { offsetRemain: offset };
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ------------------------------------------------------------ 发现分段

  /**
   * 发现分段：书源胶囊 + 一排横滑分类卡片 + 书单
   *
   * 画法照首页推荐页（views/RecommendView.ets）：**来源胶囊 + 横滑卡片 + 下面的列表**。
   * 上一版这里是几十上百个分类胶囊挤成一片药丸墙 —— 导一个书源合集进来就是近百个，
   * 既看不出是什么、也翻不到底。分类卡片横滑（一屏扫得完、颜色帮着记位置），
   * 换源交给「分类」那一行右侧的下拉胶囊（几个源，不是几十个分类）。
   */
  @Builder
  discoverPane() {
    if (this.discoverSources.length === 0) {
      EmptyState({
        icon: I_BOOK,
        text: '没有可发现的分类',
        hint: this.sources.length === 0
          ? '先到「书源」分段导入一个听书书源，这里就会按分类推书。'
          : '已导入的书源都没有发现（exploreUrl）规则，只有搜索能用。',
        topPadding: 56,
      })
    } else {
      Column() {
        Row({ space: 8 }) {
          SectionTitle({ text: '分类' })
          Blank()
          if (this.discoverSources.length > 1) {
            this.discoverSourcePill()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 10 })

        if (this.cats.length > 0) {
          List({ space: 10 }) {
            ForEach(this.cats, (cat: BookExploreCategory, index: number) => {
              ListItem() {
                CategoryCard({
                  title: cat.title,
                  colorA: catColors(index)[0],
                  colorB: catColors(index)[1],
                  cardWidth: this.catCardWidth(),
                  selected: this.catIndex === index,
                  onTap: () => {
                    void this.loadCategory(index, 1);
                  },
                })
              }
              // 选中态拼进 key：ForEach 对 key 没变的条目**不会重跑生成器**，
              // 只靠 @Prop 传不过去，选中的白边就永远不出现（与书源列表那颗登录按钮同理）
            }, (cat: BookExploreCategory, index: number) =>
              `${index}_${cat.title}_${this.catIndex === index ? 'on' : 'off'}`)
          }
          .scrollBar(BarState.Off)
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(CAT_CARD_H)
          .padding({ left: 16, right: 16 })
        }

        Row({ space: 8 }) {
          SectionTitle({ text: '书单' })
          Blank()
          if (this.discoverStatus.length > 0) {
            Text(this.discoverStatus)
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.cats.length > 0 ? 22 : 4, bottom: 6 })

        if (this.cats.length === 0) {
          EmptyState({
            icon: I_BOOK,
            text: '这个书源没有可用的分类',
            hint: this.discoverError.length > 0 ? this.discoverError : '换个书源看看。',
            topPadding: 40,
          })
        } else if (this.discoverLoading && this.discoverBooks.length === 0) {
          Column() {
            LoadingProgress().width(38).height(38).color(C_RED)
          }
          .width('100%')
          .padding({ top: 44 })
        } else if (this.discoverBooks.length === 0 && this.discoverError.length > 0) {
          Column({ space: 10 }) {
            Text(this.discoverError)
              .fontSize(13.5)
              .fontColor(C_TEXT_SUB)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .padding({ left: 26, right: 26 })
            Text('点击重试')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_RED)
              .padding({ left: 18, right: 18, top: 8, bottom: 8 })
              .borderRadius(18)
              .backgroundColor(C_RED_TINT)
              .onClick(() => {
                void this.loadCategory(this.catIndex, 1);
              })
          }
          .width('100%')
          .padding({ top: 36, bottom: 20 })
        } else if (this.discoverBooks.length === 0) {
          EmptyState({
            icon: I_BOOK,
            text: '这个分类没有书',
            hint: '换个分类看看，或者到「搜索」分段按书名找。',
            topPadding: 40,
          })
        } else {
          List() {
            ForEach(this.discoverBooks, (hit: BookHit) => {
              ListItem() {
                BookRow({
                  name: hit.name,
                  subtitle: [hit.author, hit.kind, hit.status].filter((s: string) => s.length > 0).join(' · '),
                  coverUrl: hit.coverUrl,
                  badge: hit.sourceName,
                  onTap: () => {
                    this.onOpenBook(hit);
                  },
                })
              }
            }, (hit: BookHit) => hit.id)
            ListItem() {
              Column().height(this.bottomInset + 96)
            }
          }
          .lanes(this.columns())
          .width('100%')
          .layoutWeight(1)
.scrollBar(BarState.Off)
          .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 84, endMargin: 0 })
          .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
            // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
            BottomBar.notifyScrollDelta(this.getUIContext(), offset);
            return { offsetRemain: offset };
          })
        }

        // 「加载更多」钉在列表下面：放进 List 里的话，宽屏多列时它会单独占掉一个格子
        if (this.discoverMore && this.discoverBooks.length > 0) {
          Text(this.discoverLoading ? '加载中…' : '加载更多')
            .fontSize(14.5)
            .fontColor(this.discoverLoading ? C_TEXT_WEAK : C_RED)
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(46)
            .onClick(() => {
              if (!this.discoverLoading) {
                void this.loadCategory(this.catIndex, this.discoverPage + 1);
              }
            })
            .accessibilityText('加载更多')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 发现页的书源胶囊（与搜索那颗筛选胶囊同一副样子，管的是「看哪个源的分类」） */
  @Builder
  discoverSourcePill() {
    Row({ space: 3 }) {
      Text(this.discoverSourceName())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .maxLines(1)
      IconGlyph({ symbol: I_CHEVRON_DOWN, iconSize: 13, color: C_TEXT_SUB })
        .accessibilityLevel('no')
    }
    .height(30)
    .padding({ left: 12, right: 8 })
    .attributeModifier(thinGlass(15, false, '', this.materialLevel))
    .systemMaterial(immersiveMaterialFor(this.materialLevel))
    // 边沿那圈光：鸿蒙7 是空效果（光感归材质），鸿蒙6 落成 HDS 轮廓点光（普通光效）
    .visualEffect(glassLight())
    .bindMenu(this.discoverSourceMenu())
    .accessibilityText(`发现来源：${this.discoverSourceName()}，点按切换`)
    .accessibilityLevel('yes')
  }

  private discoverSourceName(): string {
    for (const s of this.discoverSources) {
      if (s.id === this.categorySourceId) {
        return s.name;
      }
    }
    return this.discoverSources.length > 0 ? this.discoverSources[0].name : '';
  }

  @Builder
  discoverSourceMenu() {
    Menu() {
      ForEach(this.discoverSources, (info: BookSourceInfo) => {
        MenuItem({ content: info.name })
          .onClick(() => {
            if (info.id !== this.categorySourceId) {
              this.switchSource(info.id);
            }
          })
      }, (info: BookSourceInfo) => info.id)
    }
  }

  /** 分类卡片的宽度：手机上约莫两张半，宽屏放宽一点（与首页榜单那排同一口径） */
  private catCardWidth(): number {
    return this.columns() > 1 ? 132 : 118;
  }

  // ------------------------------------------------------------ 书源分段

  @Builder
  sourcePane() {
    Column() {
      Row({ space: 8 }) {
        SectionTitle({ text: '导入书源' })
        Blank()
        IconGlyph({ symbol: I_REFRESH, iconSize: 19, color: C_ICON })
          .onClick(() => {
            this.refresh();
            this.sourceStatus = '已刷新';
          })
          .accessibilityText('刷新书源列表')
          .accessibilityLevel('yes')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      /**
       * 导入区（粘贴框 + 两个按钮 + 结果提示）
       *
       * 宽屏下这三样收成一条（见 formMaxWidth）：列表可以多列，表单拉满整屏就不好用了。
       * 外面套一层容器而不是给每个控件各加一处约束，是因为「限宽」这件事只该写一遍。
       */
      Column() {
        TextArea({ text: this.pasteText, placeholder: '把阅读（Legado）书源的 JSON 粘在这里' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(13)
          .height(110)
          .width('100%')
          .backgroundColor(C_CARD)
          .borderRadius(R_CARD)
          .padding(12)
          .onChange((value: string) => {
            this.pasteText = value;
          })

        Row({ space: 10 }) {
          Button(this.busy ? '处理中…' : '导入 JSON')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .enabled(!this.busy)
            .onClick(() => {
              this.importText(this.pasteText);
            })
          Button('导入文件')
            .fontSize(14)
            .height(36)
            .layoutWeight(1)
            .enabled(!this.busy)
            .onClick(() => {
              void this.pickSourceFile();
            })
        }
        .width('100%')
        .padding({ top: 10, bottom: 6 })

        if (this.sourceStatus.length > 0) {
          Text(this.sourceStatus)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .width('100%')
            .padding({ bottom: 6 })
            .textAlign(TextAlign.Start)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: this.formMaxWidth() })

      Row({ space: 8 }) {
        SectionTitle({ text: `已导入（${this.sources.length}）` })
        Blank()
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      if (this.sources.length === 0) {
        EmptyState({
          icon: I_IMPORT,
          text: '还没有听书书源',
          hint: '听书用的是阅读（Legado）的 JSON 书源。把书源文件拖进来，或粘贴 JSON 后点「导入 JSON」。',
          topPadding: 28,
        })
      } else {
        List() {
          ForEach(this.sources, (info: BookSourceInfo) => {
            ListItem() {
              Row({ space: 12 }) {
                Column({ space: 5 }) {
                  Row({ space: 6 }) {
                    Text(info.name)
                      .fontSize(F_ITEM)
                      .fontColor(C_TEXT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    // 「需登录」只在**还没登录**时提示；登录后由右侧按钮的「重新登录」表达状态
                    if (info.needLogin && !this.isLoggedIn(info)) {
                      Text('需登录')
                        .fontSize(10.5)
                        .fontColor(C_TEXT_SUB)
                        .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
                        .backgroundColor($r('app.color.c_fill_soft_strong'))
                        .borderRadius(6)
                    }
                  }
                  .width('100%')
                  Text(this.sourceLine(info))
                    .fontSize(F_SUB)
                    .fontColor(C_TEXT_SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (info.needLogin) {
                  // 按登录状态切换：没登录时是「登录」（强调色，提示还有一步），
                  // 登录后变「重新登录」（弱化，但仍可点，换号 / Cookie 过期要能重来）
                  Text(this.isLoggedIn(info) ? '重新登录' : '登录')
                    .fontSize(12.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.isLoggedIn(info) ? C_TEXT_SUB : C_RED)
                    .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                    .backgroundColor($r('app.color.c_fill_soft_strong'))
                    .borderRadius(14)
                    .onClick(() => {
                      this.openLogin(info);
                    })
                    .accessibilityText(this.isLoggedIn(info)
                      ? `已登录书源 ${info.name}，点按可重新登录`
                      : `登录书源 ${info.name}`)
                    .accessibilityLevel('yes')
                }

                IconGlyph({ symbol: I_TRASH, iconSize: 20, color: C_TEXT_WEAK })
                  .padding({ left: 6, right: 6, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.removeSource(info.id);
                  })
                  .accessibilityText(`删除书源 ${info.name}`)
                  .accessibilityLevel('yes')
              }
              .width('100%')
              .padding({ left: 16, right: 12, top: 12, bottom: 12 })
            }
          }, (info: BookSourceInfo) => `${info.id}|${this.isLoggedIn(info) ? 'in' : 'out'}`)
          ListItem() {
            Column().height(this.bottomInset + 96)
          }
        }
        .lanes(this.columns())
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 16, endMargin: 0 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    // 网页登录挂在书源分段自己的节点上：登录弹窗（bindSheet）已经在最外层节点上，
    // 同一节点再叠一个覆盖层会互相干扰
    .bindContentCover($$this.loginWebOpen, this.loginWebCover(), {
      modalTransition: ModalTransition.NONE,
    })
  }

  private sourceLine(info: BookSourceInfo): string {
    const caps: string[] = [];
    if (info.canSearch) {
      caps.push('搜索');
    }
    if (info.canExplore) {
      caps.push('发现');
    }
    const suffix: string = caps.length > 0 ? caps.join('/') : '无搜索';
    return `${info.group.length > 0 ? info.group + ' · ' : ''}${suffix} · ${info.url}`;
  }

  /**
   * 书源登录弹窗
   *
   * 只有一种登录方式：**应用内打开站点自己的登录页**（扫码 / 短信 / 跳转都能走），
   * 登录完成后抓 Cookie。之前那套按 `loginUi` 手填表单已经去掉 —— 大多数源要么
   * 根本没有 `loginUi`，要么填了也不对（要的是站点的真实会话）。
   */
  @Builder
  loginSheet() {
    Column({ space: 12 }) {
      Text(this.loginSourceName)
        .fontSize(F_ITEM)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Button('网页登录')
        .fontSize(15)
        .height(44)
        .width('100%')
        .enabled(!this.loginBusy)
        .onClick(() => {
          this.openWebLogin();
        })
      Text('在应用内打开该站点的登录页，登录成功后点右上角「完成」，应用会自动抓取本站 Cookie。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.loginStatus.length > 0) {
        Text(this.loginStatus)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Row({ space: 10 }) {
        Button(this.loginBusy ? '处理中…' : '检查登录')
          .fontSize(14)
          .height(38)
          .layoutWeight(1)
          .enabled(!this.loginBusy)
          .onClick(() => {
            void this.checkLoginNow();
          })
        Button('清除登录')
          .fontSize(14)
          .height(38)
          .layoutWeight(1)
          .enabled(!this.loginBusy)
          .onClick(() => {
            this.clearLoginNow();
          })
      }
      .width('100%')

      Column().height(this.bottomInset + 12)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 网页登录：整屏的应用内浏览器（书源自己的登录页）
   *
   * 用 `bindContentCover` 而不是半模态：登录页要占满屏、要能滚动、还要弹系统键盘，
   * 半模态高度受限会很难用。关掉时把抓到的 Cookie 交回来落盘。
   */
  @Builder
  loginWebCover() {
    BookLoginWeb({
      title: this.loginWebTitle,
      loginUrl: this.loginWebUrl,
      siteUrl: this.loginWebSite,
      safeTop: this.safeTop,
      safeBottom: this.safeBottom,
      onClose: (cookie: string) => {
        this.onWebLoginClosed(cookie);
      },
    })
  }

  build() {
    Column() {
      Row() {
        CapsuleSegment({
          labels: ['书架', '发现', '搜索', '书源'],
          selectedIndex: this.pane,
          compact: false,
          onSelect: (index: number) => {
            this.pane = index;
            if (index === PANE_SHELF || index === PANE_SOURCE) {
              this.refresh();
            } else if (index === PANE_DISCOVER) {
              this.refresh();
              this.onDiscoverEnter();
            }
          },
        })
      }
      .width('100%')
      // 宽屏下分段选择器不跟着铺满：四个选项拉过整屏就成了一条又长又扁的带子（限宽见 SEGMENT_MAX_WIDTH）
      .constraintSize({ maxWidth: this.columns() > 1 ? SEGMENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
      .padding({ left: 16, right: 16, top: 6, bottom: 10 })

      if (this.pane === PANE_SHELF) {
        this.shelfPane()
      } else if (this.pane === PANE_DISCOVER) {
        this.discoverPane()
      } else if (this.pane === PANE_SEARCH) {
        this.searchPane()
      } else {
        this.sourcePane()
      }
    }
    .width('100%')
    .height('100%')
    // 靠左排：宽屏下分段选择器与导入区都是「限宽后还剩一截」，居中的话左边会空出一大段，
    // 与下面列表的左缩进对不上（列表本来就是靠左铺满的）
    .alignItems(HorizontalAlign.Start)
    .padding({ top: this.topInset })
    .backgroundColor(C_BG)
    .bindSheet($$this.loginOpen, this.loginSheet(), {
      preferType: SheetType.BOTTOM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      detentSelection: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '书源登录' },
    })
  }
}
