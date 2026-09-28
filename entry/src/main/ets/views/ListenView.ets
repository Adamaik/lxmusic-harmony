import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';
import { BookShelf, ShelvedBook } from '../core/book/BookShelf';
import { BookHit, BookSourceInfo } from '../core/book/BookTypes';
import { BookLoginWeb } from '../components/BookLoginWeb';
import { C_BG, C_CARD, C_DIVIDER, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM,
  F_SUB, R_CARD } from '../ui/Theme';
import { glassLight, immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { CapsuleSegment } from '../ui/CapsuleSegment';
import { I_BOOK, I_BOOKSHELF, I_CHEVRON_DOWN, I_CHEVRON_RIGHT, I_CLOSE, I_IMPORT, I_REFRESH,
  I_SEARCH, I_TRASH, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';
import { CONTENT_MAX_WIDTH, contentColumnsFor, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED } from '../ui/Layout';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenView';

/** 分段选择器（书架 / 搜索 / 书源）在宽屏下的最大宽度：拉满整屏会变成一条又长又扁的带子 */
const SEGMENT_MAX_WIDTH: number = 560;

/** 三个分段：书架（我的书）/ 搜索（找书）/ 书源（导入与管理） */
const PANE_SHELF: number = 0;
const PANE_SEARCH: number = 1;
const PANE_SOURCE: number = 2;

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

/**
 * 听书页
 *
 * 「阅读（Legado）」书源的入口：导入书源 → 搜索 / 发现 → 打开一本书 → 播它的某一集。
 * 书源协议与音源完全不同（见 core/book/book_preload.js 的说明），所以这里是一套
 * 自己的三段式：**书架 / 搜索 / 书源**。
 *
 * 三段放在一页里而不是拆成三个页签，是因为它们的使用频率差很多（书架天天看、
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
   * 窗口宽度（vp）：三个分段里的列表按它算一屏几列（0 = 还没量到，按手机一列）
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
   * 书架、搜索结果、书源三张列表都用它。
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
      }
    }
    .width('100%')
    .layoutWeight(1)
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
          labels: ['书架', '搜索', '书源'],
          selectedIndex: this.pane,
          compact: false,
          onSelect: (index: number) => {
            this.pane = index;
            if (index === PANE_SHELF || index === PANE_SOURCE) {
              this.refresh();
            }
          },
        })
      }
      .width('100%')
      // 宽屏下分段选择器不跟着铺满：三个选项拉过整屏就成了一条又长又扁的带子（限宽见 SEGMENT_MAX_WIDTH）
      .constraintSize({ maxWidth: this.columns() > 1 ? SEGMENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
      .padding({ left: 16, right: 16, top: 6, bottom: 10 })

      if (this.pane === PANE_SHELF) {
        this.shelfPane()
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
