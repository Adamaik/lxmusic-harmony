import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';
import { BookShelf, ShelvedBook } from '../core/book/BookShelf';
import { BookHit, BookSourceInfo } from '../core/book/BookTypes';
import { C_BG, C_CARD, C_DIVIDER, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM,
  F_SUB, R_CARD } from '../ui/Theme';
import { immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { CapsuleSegment } from '../ui/CapsuleSegment';
import { I_BOOK, I_BOOKSHELF, I_CHEVRON_DOWN, I_CHEVRON_RIGHT, I_CLOSE, I_IMPORT, I_REFRESH,
  I_SEARCH, I_TRASH, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenView';

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
  onOpenBook: (hit: BookHit) => void = () => {
  };
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;

  @State pane: number = PANE_SHELF;
  @State sources: BookSourceInfo[] = [];
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

  aboutToAppear(): void {
    const engine = BookEngine.getInstance();
    const context = this.getUIContext().getHostContext() as common.Context;
    BookShelf.getInstance().init(context);
    void engine;
    this.refresh();
  }

  private refresh(): void {
    this.sources = BookEngine.getInstance().listSources();
    this.shelf = BookShelf.getInstance().list();
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
        const text: string = BookEngine.getInstance().importFromUri(uris[0]) !== undefined ? '' : '';
        // importFromUri 已经完成导入，这里只刷新与提示
        this.refresh();
        this.sourceStatus = '书源文件已导入';
        void text;
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
                    if (info.needLogin) {
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
          }, (info: BookSourceInfo) => info.id)
          ListItem() {
            Column().height(this.bottomInset + 96)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 16, endMargin: 0 })
      }
    }
    .width('100%')
    .layoutWeight(1)
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
    .padding({ top: this.topInset })
    .backgroundColor(C_BG)
  }
}
