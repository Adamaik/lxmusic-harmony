import { dedupeSongs, LxMusicInfo, LxSearchOutcome, SEARCH_PLATFORMS,
  searchMusicAll } from '../core/music/MusicSearch';
import { hotSearchWords, suggestMusic } from '../core/music/MusicSuggest';
import { SearchHistory } from '../core/music/SearchHistory';
import { platformName } from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_PLAY_QUALITY } from '../core/settings/PlaySettings';
import { C_BG, C_DIVIDER, C_FILL_SOFT, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK,
  F_SUB } from '../ui/Theme';
import { glassLight, immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { I_CHEVRON_DOWN, I_CLOSE, I_SEARCH, I_TRASH, IconGlyph } from '../ui/Icons';
import { EmptyState, SectionTitle } from '../ui/Widgets';
import { SongListPane } from './SongListPane';
import { CONTENT_MAX_WIDTH, contentColumnsFor, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED } from '../ui/Layout';

/** 平台筛选项里「不筛」的那一项 */
const FILTER_ALL: string = '';
/** 每个平台每页取多少条：与洛雪一样 30 条一页，翻页靠列表滚到底 */
const PER_PLATFORM_LIMIT: number = 30;
/**
 * 输入停顿多久才去要联想词
 *
 * 打字过程中每个字符都发一次请求既浪费也会让列表乱跳；洛雪那边是 200ms，
 * 这里留宽一点（手机网络下够用了）。
 */
const SUGGEST_DEBOUNCE_MS: number = 250;

/**
 * 搜索页（聚合搜索 + 历史 / 联想 / 热搜）
 *
 * 一次问所有平台（酷我/酷狗/咪咕/QQ/网易），合起来按与关键词的相似度重排、去重，
 * 再让用户往下翻 —— 与洛雪 store/search/music/action.js 的 setLists 同一套做法。
 *
 * 为什么不按平台交错拼接（改之前的样子）：按歌手搜索时五个平台各回 30 条，交错后
 * 同一首歌连着出现五遍（重复一大堆），而且只取第一页 —— 酷我搜「周杰伦」报的
 * 总数是 3295 首，能看到的只有 30 首（缺一大堆）。现在列表滚到底会自动拉下一页。
 *
 * 搜完可以用右上角的下拉框只看某一个平台，不筛就是全部。
 *
 * 页面的三个状态（按输入框里的内容切换，见 pane 的选择）：
 *   1. **没输入** —— 搜索历史（落盘，长按删单个、右上角清空）+ 热门搜索（多平台合并）；
 *   2. **输入了但还没搜** —— 联想词列表（`core/music/MusicSuggest`）：打「晴天」能列出
 *      《晴天 - 周杰伦》《晴天 - Lucky小爱》这类**不同歌手 / 不同版本**，点一行直接搜；
 *   3. **搜过（输入框里还是那次搜的词）** —— 搜索结果，也就是下面这一整套。
 *
 * 音质不在这里选：那是「设置 - 播放设置 - 播放音质」的事，搜索页再摆一排
 * 只会和设置页抢同一个值（以前就是两边各写一趟），按播放音质协商即可。
 *
 * 搜索结果本身不依赖音源；音源只决定「搜到的这首歌能不能解析出播放链接」。
 */
@Component
export struct SearchView {
  @Prop bottomInset: number = 0;
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」），见根容器上的说明 */
  @Prop topInset: number = 0;
  @State keyword: string = '';
  /**
   * 曲目自带的音质字段来自设置里的那一份（设置 - 播放设置 - 播放音质）：
   * 它只是「这首歌有这么一档」的标记，真正协商在播放/下载时按 Quality.ets 走。
   */
  @StorageLink(K_PLAY_QUALITY) quality: string = '128k';
  @State searching: boolean = false;
  @State loadingMore: boolean = false;
  @State status: string = '输入歌名或歌手，一次搜全部平台';
  @State currentId: string = '';
  /** 平台筛选：'' = 全部（聚合），否则是平台 id */
  @State filter: string = FILTER_ALL;
  /**
   * 已经搜到的原始结果（musicInfo），翻页时往后接。
   *
   * 存 musicInfo 而不是直接存 SongItem：切筛选、翻页都要按同一套规则重新去重，
   * 而「是不是同一首歌」的判断在 core/music/MusicSearch（dedupeSongs），
   * 界面这边只管拼接和转成可播放条目。
   */
  @State mergedInfos: LxMusicInfo[] = [];
  /** 逐平台的累计结果（筛某个平台时显示对应那一份） */
  @State platformInfos: Record<string, LxMusicInfo[]> = {};
  /** 逐平台的失败原因（成功的平台不放进来） */
  @State failures: Record<string, string> = {};
  /** 当前显示的结果（= 全部 或 某个平台） */
  @State results: SongItem[] = [];
  /** 搜索是否已经出过结果（用来区分「还没搜」和「搜过但没结果」） */
  @State searched: boolean = false;
  /**
   * 「搜索结果现在显示的是哪个词」
   *
   * 与输入框里的 `keyword` 分开记：输入框里的字一变（用户又在敲了），就该回到联想词，
   * 而不是把上一次的结果晾在下面。两者相等时才显示结果那一栏。
   */
  @State searchedText: string = '';
  /** 搜索历史（新的在前） */
  @State history: string[] = [];
  /** 热门搜索词（多平台合并，本次会话只取一次） */
  @State hots: string[] = [];
  /** 联想词（随输入变化） */
  @State suggestions: string[] = [];
  /** 正在取联想词（用来区分「还没回来」和「确实没有」） */
  @State suggesting: boolean = false;
  /** 已经拿到第几页 / 一共几页（翻页用，见 hasMore） */
  @State page: number = 0;
  @State maxPage: number = 0;
  /** 联想词的防抖定时器（0 = 没有待跑的） */
  private suggestTimer: number = 0;
  /**
   * 联想请求的序号
   *
   * 打字很快时会有多个请求同时在飞，回来的顺序不定；只认最后一次发出去的那一个，
   * 否则「晴」的结果可能盖掉「晴天」的。
   */
  private suggestToken: number = 0;
  /** 玻璃厚度档位（外观设置）：搜索框的毛玻璃跟着它变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;
  /**
   * 窗口宽度（vp）：宽屏下搜索结果一屏多列（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  aboutToAppear(): void {
    this.history = SearchHistory.getInstance().list();
    void this.loadHots();
  }

  aboutToDisappear(): void {
    if (this.suggestTimer !== 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = 0;
    }
  }

  /** 一屏几列（宽屏多列，窄屏 1 列 = 改之前的样子，见 ui/Layout.ets） */
  private columns(): number {
    return contentColumnsFor(this.windowWidth);
  }

  // ------------------------------------------------------------ 数据

  /** 某个平台这次搜到几首（筛选菜单里标出来，用户好判断哪个平台值得切） */
  private countOf(source: string): number {
    const list: LxMusicInfo[] | undefined = this.platformInfos[source];
    return list !== undefined ? list.length : 0;
  }

  private failureCount(): number {
    let count: number = 0;
    for (let i = 0; i < SEARCH_PLATFORMS.length; i++) {
      if (this.failures[SEARCH_PLATFORMS[i]] !== undefined) {
        count++;
      }
    }
    return count;
  }

  /** 状态行的说明：每个平台各搜到几首，谁没通 */
  private summaryText(): string {
    const parts: string[] = [];
    for (let i = 0; i < SEARCH_PLATFORMS.length; i++) {
      const id: string = SEARCH_PLATFORMS[i];
      parts.push(this.failures[id] !== undefined
        ? `${platformName(id)} 失败`
        : `${platformName(id)} ${this.countOf(id)}`);
    }
    return parts.join(' · ');
  }

  private filterLabel(): string {
    return this.filter === FILTER_ALL ? '全部平台' : platformName(this.filter);
  }

  /** 还有没有下一页：某个平台的总页数还没走完 */
  private hasMore(): boolean {
    return this.page > 0 && this.page < this.maxPage;
  }

  private toItems(infos: LxMusicInfo[]): SongItem[] {
    const items: SongItem[] = [];
    for (const info of infos) {
      items.push(songFromSearch(info, this.quality));
    }
    return items;
  }

  /** 切筛选：只是换一份现成的列表，不重新联网搜索 */
  private applyFilter(): void {
    if (this.filter === FILTER_ALL) {
      this.results = this.toItems(this.mergedInfos);
      return;
    }
    const list: LxMusicInfo[] | undefined = this.platformInfos[this.filter];
    this.results = list !== undefined ? this.toItems(list) : [];
  }

  private resetResults(): void {
    this.mergedInfos = [];
    this.platformInfos = {};
    this.failures = {};
    this.results = [];
    this.searchedText = '';
    this.page = 0;
    this.maxPage = 0;
  }

  // ------------------------------------------------------------ 历史 / 联想 / 热搜

  private async loadHots(): Promise<void> {
    if (this.hots.length > 0) {
      return;
    }
    try {
      this.hots = await hotSearchWords();
    } catch (e) {
      // 热搜词取不到就不显示这一栏（不影响历史与搜索）
      this.hots = [];
    }
  }

  /**
   * 输入变了：排一次联想（防抖）
   *
   * 清空输入时立刻把联想词收掉并取消还没跑的那次请求，免得「删光了字下面还挂着一串联想」。
   */
  private onKeywordChanged(value: string): void {
    this.keyword = value;
    const text: string = value.trim();
    if (this.suggestTimer !== 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = 0;
    }
    if (text.length === 0) {
      this.suggestToken++;
      this.suggestions = [];
      this.suggesting = false;
      return;
    }
    // 防抖这段时间也显示「正在联想…」：否则先闪一下「按回车搜索」再变成联想列表
    this.suggesting = true;
    this.suggestTimer = setTimeout(() => {
      this.suggestTimer = 0;
      void this.fetchSuggest(text);
    }, SUGGEST_DEBOUNCE_MS);
  }

  private async fetchSuggest(text: string): Promise<void> {
    this.suggestToken++;
    const token: number = this.suggestToken;
    this.suggesting = true;
    let words: string[] = [];
    try {
      words = await suggestMusic(text);
    } catch (e) {
      words = [];
    }
    if (this.suggestToken !== token) {
      // 期间又敲了字：这次的结果作废（新的那次会覆盖显示）
      return;
    }
    this.suggesting = false;
    this.suggestions = words;
  }

  /** 点历史 / 热搜 / 联想，或者回车：都从这里发起搜索 */
  private runSearch(text: string): void {
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    // 联想列表用完就收（搜完下面就是结果列表了）
    this.suggestToken++;
    this.suggestions = [];
    this.keyword = trimmed;
    // 搜过的词记进历史（与洛雪一样在发起时就记，接口失败也不影响）
    this.history = SearchHistory.getInstance().add(trimmed);
    void this.doSearch();
  }

  /** 长按历史词：删掉这一个 */
  private removeHistory(word: string): void {
    this.history = SearchHistory.getInstance().remove(word);
    this.toast(`已删除「${word}」`);
  }

  private clearHistory(): void {
    if (this.history.length === 0) {
      return;
    }
    SearchHistory.getInstance().clear();
    this.history = [];
    this.toast('已清空搜索历史');
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 搜索

  /**
   * 把一页结果并进现有状态。
   *
   * 逐平台列表也要累计：筛到某个平台后继续下拉，看到的是「这个平台的第一页 + 第二页…」，
   * 与洛雪每个来源各存一份 listInfo 是一个意思。
   */
  private applyOutcome(outcome: LxSearchOutcome, append: boolean): void {
    const per: Record<string, LxMusicInfo[]> = {};
    if (append) {
      for (const key of Object.keys(this.platformInfos)) {
        per[key] = this.platformInfos[key];
      }
    }
    for (const p of outcome.platforms) {
      const before: LxMusicInfo[] | undefined = per[p.source];
      const joined: LxMusicInfo[] = before !== undefined ? before.concat(p.items) : p.items;
      // 翻页时同一首歌可能在两页都出现，拼完再按同一套规则去一次重
      per[p.source] = dedupeSongs(joined);
    }
    const bad: Record<string, string> = {};
    if (append) {
      for (const key of Object.keys(this.failures)) {
        bad[key] = this.failures[key];
      }
    }
    for (const p of outcome.platforms) {
      if (p.error.length > 0) {
        bad[p.source] = p.error;
      }
    }
    this.platformInfos = per;
    this.failures = bad;
    // 这一页已经按相关度排过序，翻页就接在后面（洛雪也是「旧列表 + 这一页」），
    // 不重排整张表：那会让已经翻过的内容乱跳
    this.mergedInfos = dedupeSongs(
      append ? this.mergedInfos.concat(outcome.items) : outcome.items);
    this.page = outcome.page;
    this.maxPage = outcome.maxPage;
  }

  private async doSearch(): Promise<void> {
    if (this.searching) {
      return;
    }
    const text: string = this.keyword.trim();
    if (text.length === 0) {
      this.status = '请输入歌名或歌手';
      return;
    }
    this.searching = true;
    this.resetResults();
    // 记下「结果对应的是哪个词」：输入框里的字一变就回到联想词那一栏（见 pane）
    this.searchedText = text;
    this.status = `正在聚合搜索「${text}」…`;
    try {
      const outcome: LxSearchOutcome =
        await searchMusicAll(text, SEARCH_PLATFORMS, 1, PER_PLATFORM_LIMIT);
      this.applyOutcome(outcome, false);
      // 筛着某个平台又换了关键词：这次那个平台一条都没有（多半是它没通）就退回
      // 全部 —— 与其让人对着空列表，不如先把聚合结果摆出来，状态行里照样会写明
      // 是哪个平台失败了
      if (this.filter !== FILTER_ALL && this.countOf(this.filter) === 0) {
        this.filter = FILTER_ALL;
      }
      this.applyFilter();
      if (this.mergedInfos.length === 0) {
        this.status = this.failureCount() === SEARCH_PLATFORMS.length
          ? '五个平台都没搜通，检查一下网络'
          : `没有搜到「${text}」`;
      } else {
        this.status = `共 ${this.mergedInfos.length} 首 —— ${this.summaryText()}`;
      }
    } catch (e) {
      this.status = `搜索失败: ${(e as Error).message}`;
    } finally {
      this.searching = false;
    }
  }

  /** 列表滚到底 / 点尾部那一行：再拉一页 */
  private async loadMore(): Promise<void> {
    if (this.searching || this.loadingMore || !this.hasMore()) {
      return;
    }
    // 翻的是「当前这份结果对应的那个词」（searchedText），不是输入框里现在敲的字：
    // 用户改了输入框就会切回联想那一栏，那时列表不可见，这里也就不会被调到
    const text: string = this.searchedText;
    if (text.length === 0) {
      return;
    }
    this.loadingMore = true;
    const next: number = this.page + 1;
    try {
      const outcome: LxSearchOutcome =
        await searchMusicAll(text, SEARCH_PLATFORMS, next, PER_PLATFORM_LIMIT);
      this.applyOutcome(outcome, true);
      this.applyFilter();
      this.status = `共 ${this.mergedInfos.length} 首 —— ${this.summaryText()}`;
    } catch (e) {
      this.status = `加载更多失败：${(e as Error).message}`;
    } finally {
      this.loadingMore = false;
    }
  }

  /** 列表尾部那一行：翻页进度（普通歌单没有这一段，见 SongListPane.footerStatus） */
  private footerStatus(): string {
    if (this.results.length === 0) {
      return '';
    }
    if (this.loadingMore) {
      return '正在加载更多…';
    }
    if (this.hasMore()) {
      return '上拉加载更多';
    }
    return `共 ${this.results.length} 首`;
  }

  // ------------------------------------------------------------ 构建

  /** 平台筛选下拉菜单（菜单项带上这个平台搜到几首） */
  @Builder
  filterMenu() {
    Menu() {
      MenuItem({ content: `全部平台（${this.mergedInfos.length}）` })
        .onClick(() => {
          this.filter = FILTER_ALL;
          this.applyFilter();
        })
      ForEach(SEARCH_PLATFORMS, (id: string) => {
        MenuItem({
          content: this.failures[id] !== undefined
            ? `${platformName(id)}（失败）`
            : `${platformName(id)}（${this.countOf(id)}）`,
        })
          .onClick(() => {
            this.filter = id;
            this.applyFilter();
          })
      }, (id: string) => id)
    }
  }

  @Builder
  searchField() {
    Row({ space: 8 }) {
      IconGlyph({
        symbol: I_SEARCH,
        iconSize: 18,
        color: C_TEXT_SUB,
      })
        .accessibilityLevel('no')
      TextInput({ text: this.keyword, placeholder: '歌名 / 歌手' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 15 })
        .fontSize(15)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(28)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          // 每敲一个字都走这里：排一次联想（见 onKeywordChanged）
          this.onKeywordChanged(value);
        })
        .onSubmit(() => {
          // 回车 = 直接搜输入框里这个词
          this.runSearch(this.keyword);
        })
      if (this.keyword.length > 0) {
        IconGlyph({
          symbol: I_CLOSE,
          iconSize: 16,
          color: C_TEXT_WEAK,
        })
          .onClick(() => {
            // 只清输入框与联想词：上一次的结果留着（再把同一个词敲回来时还在，
            // 省得为看一眼结果重搜一遍）
            this.onKeywordChanged('');
            this.status = '输入歌名或歌手，一次搜全部平台';
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

  /** 结果栏右端那个筛选胶囊：自己画 + 系统下拉菜单（与推荐页的两个下拉框同款） */
  @Builder
  filterPill() {
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
    .bindMenu(this.filterMenu())
    .accessibilityText(`搜索来源：${this.filterLabel()}，点按切换`)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      // ---------------------------------------------------- 搜索栏（标题栏由 HDS 提供）
      Row({ space: 10 }) {
        this.searchField()

        Text(this.searching ? '搜索中' : '搜索')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.searching ? C_TEXT_WEAK : C_RED)
          .onClick(() => {
            this.runSearch(this.keyword);
          })
          .accessibilityText('搜索')
          .accessibilityLevel('yes')
      }
      .width('100%')
      // 宽屏下搜索框不跟着铺满：1400vp 宽的一条输入框又长又扁，看着不像能打字的地方
      // （限宽口径与设置页的表单一致，见 ui/Layout.ets 的 CONTENT_MAX_WIDTH）
      .constraintSize({ maxWidth: this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })

      // ---------------------------------------------------- 三选一：历史+热搜 / 联想 / 结果
      if (this.keyword.trim().length === 0) {
        this.discoverPane()
      } else if (this.keyword.trim() !== this.searchedText) {
        this.suggestPane()
      } else {
        this.resultPane()
      }
    }
    .width('100%')
    .height('100%')
    // 靠左排：宽屏下搜索栏是「限宽后还剩一截」，居中的话左边空一截、与结果列对不上
    .alignItems(HorizontalAlign.Start)
    /**
     * 让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）
     *
     * 这一页**没有**跟着首页做成「内容从透明标题栏底下滑过去」：它的搜索栏是钉在顶部的
     * 固定控件，不是滚动内容的一部分 —— 搜索栏和下面的结果列表都不该钻到标题底下去
     * （搜索框滑走、或者结果行压在「搜索」两个字下面都不是想要的）。所以这里用普通
     * 内边距让位，标题栏背后露出来的就是页面底色本身，与这一页其余部分同色。
     */
    .padding({ top: this.topInset })
    .backgroundColor(C_BG)
  }

  // ------------------------------------------------------------ 历史 + 热门（没输入时）

  /**
   * 空搜索框时的那一屏：搜索历史 + 热门搜索
   *
   * 两块都可能没有（新装的机器没历史、接口也没通），那就退回原来的空态提示 ——
   * 不能留一片空白让人不知道能干什么。
   */
  @Builder
  discoverPane() {
    Scroll() {
      Column({ space: 24 }) {
        if (this.history.length > 0) {
          Column({ space: 2 }) {
            Row({ space: 8 }) {
              SectionTitle({ text: '搜索历史' })
              Blank()
              IconGlyph({ symbol: I_TRASH, iconSize: 17, color: C_TEXT_WEAK })
                .onClick(() => {
                  this.clearHistory();
                })
                .accessibilityText('清空搜索历史')
                .accessibilityLevel('yes')
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.history, (word: string) => {
                this.wordChip(word, true)
              }, (word: string) => `h_${word}`)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        if (this.hots.length > 0) {
          Column({ space: 2 }) {
            SectionTitle({ text: '热门搜索' })
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.hots, (word: string) => {
                this.wordChip(word, false)
              }, (word: string) => `t_${word}`)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        if (this.history.length === 0 && this.hots.length === 0) {
          EmptyState({
            icon: I_SEARCH,
            text: '搜一首歌试试',
            hint: '一次搜酷我、酷狗、咪咕、QQ、网易五个平台，结果合起来按相关度排；'
              + '输入歌名时还会给出不同歌手 / 不同版本的联想词。',
            topPadding: 56,
          })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 6, bottom: this.bottomInset + 20 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ maxWidth: this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
  }

  /**
   * 一个词胶囊
   *
   * 历史词长按删除（洛雪也是长按删），热门词长按什么都不做 —— 手势统一挂着，
   * 由 removable 决定按下时删不删。
   */
  @Builder
  wordChip(word: string, removable: boolean) {
    Text(word)
      .fontSize(13)
      .fontColor(C_TEXT)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 240 })
      .padding({ left: 13, right: 13, top: 7, bottom: 7 })
      .backgroundColor(C_FILL_SOFT)
      .borderRadius(16)
      .margin({ right: 9, top: 9 })
      .onClick(() => {
        this.runSearch(word);
      })
      // 长按才删（热门词不删）：手势统一挂着，靠 removable 决定按下时做不做
      .gesture(LongPressGesture().onAction(() => {
        if (removable) {
          this.removeHistory(word);
        }
      }))
      .accessibilityText(removable ? `${word}，长按删除` : word)
      .accessibilityLevel('yes')
  }

  // ------------------------------------------------------------ 联想词（输入中）

  /**
   * 输入过程中的联想列表
   *
   * 每一行直接就是一条搜索词（`歌名 - 歌手` 也是），点一下就用它去搜 ——
   * 同一首歌有不同歌手唱过、或者有伴奏 / 现场版时，「点哪条」比「改关键词再搜」省事。
   */
  @Builder
  suggestPane() {
    Column() {
      Row() {
        SectionTitle({ text: '联想搜索' })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })

      if (this.suggestions.length > 0) {
        List() {
          ForEach(this.suggestions, (word: string) => {
            ListItem() {
              this.suggestRow(word)
            }
          }, (word: string) => `s_${word}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({
          strokeWidth: 0.6,
          color: C_DIVIDER,
          startMargin: 42,
          endMargin: 16,
        })
        .padding({ bottom: this.bottomInset })
      } else {
        // 还没回来 / 这个平台组合确实没有联想词：给一句明确的话，别让人以为卡住了
        Text(this.suggesting ? '正在联想…' : `按回车或点「搜索」搜「${this.keyword.trim()}」`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ maxWidth: this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
  }

  /** 一行联想词：放大镜 + 词（点一下直接搜） */
  @Builder
  suggestRow(word: string) {
    Row({ space: 12 }) {
      IconGlyph({ symbol: I_SEARCH, iconSize: 16, color: C_TEXT_WEAK })
        .accessibilityLevel('no')
      Text(word)
        .fontSize(15)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height(46)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      this.runSearch(word);
    })
    .accessibilityText(`${word}，点按搜索`)
    .accessibilityLevel('yes')
  }

  // ------------------------------------------------------------ 搜索结果

  @Builder
  resultPane() {
    Column() {
      // 结果栏：标题 + 平台筛选
      Row({ space: 8 }) {
        SectionTitle({ text: '搜索结果' })
        Blank()
        if (this.mergedInfos.length > 0) {
          this.filterPill()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })

      Text(this.status)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.results.length > 0 ? 6 : 0 })
        .textAlign(TextAlign.Start)

      if (this.searching) {
        Column() {
          LoadingProgress().width(38).height(38).color(C_RED)
        }
        .width('100%')
        .padding({ top: 60 })
      } else if (this.results.length === 0) {
        // 空态：搜了没结果 / 筛出来的平台是空，两种说法不一样
        EmptyState({
          icon: I_SEARCH,
          text: this.emptyText(),
          hint: this.emptyHint(),
          topPadding: 56,
        })
      } else {
        // SongListPane 自己是可滚动的懒加载列表，别再套 Scroll（嵌套滚动也会打架）
        SongListPane({
          items: this.results,
          currentId: this.currentId,
          emptyText: '',
          // 聚合结果去重后同一首歌只会留一条（各平台谁排前面就留谁），行上标出平台
          // 才看得出来这条来自哪个站
          showSource: true,
          bottomInset: this.bottomInset,
          footerStatus: this.footerStatus(),
          onReachEnd: () => {
            void this.loadMore();
          },
          onPick: (index: number) => {
            if (index < 0 || index >= this.results.length) {
              return;
            }
            this.currentId = this.results[index].id;
            PlaySession.getInstance().setQueueAndPlay(this.results, index);
            this.status = `已加入播放列表并开始解析：${this.results[index].name}`;
          },
        })
          .layoutWeight(1)
          .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  private emptyText(): string {
    if (this.filter !== FILTER_ALL) {
      return `${platformName(this.filter)} 没有结果`;
    }
    return '没有搜到结果';
  }

  private emptyHint(): string {
    if (this.failureCount() > 0) {
      return `本次 ${this.summaryText()}。失败的平台多半是网络或接口变了，可以只切到通了的平台看。`;
    }
    return '换个关键词试试，或者少写几个字。';
  }
}
