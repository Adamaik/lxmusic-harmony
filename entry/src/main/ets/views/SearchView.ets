import { interleave, LxAggSearchResult, LxPlatformSearch, SEARCH_PLATFORMS,
  searchMusicAll } from '../core/music/MusicSearch';
import { platformName } from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_PLAY_QUALITY } from '../core/settings/PlaySettings';
import { C_BG, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SUB } from '../ui/Theme';
import { immersiveMaterialFor, thinGlass } from '../ui/Glass';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { I_CHEVRON_DOWN, I_CLOSE, I_SEARCH, IconGlyph } from '../ui/Icons';
import { EmptyState, SectionTitle } from '../ui/Widgets';
import { SongListPane } from './PlaylistView';

/** 平台筛选项里「不筛」的那一项 */
const FILTER_ALL: string = '';
/** 每个平台取多少条：五个平台各取 30 条，聚合后最多 150 条 */
const PER_PLATFORM_LIMIT: number = 30;

/**
 * 搜索页（聚合搜索）
 *
 * 一次问所有平台（酷我/酷狗/咪咕/QQ/网易）再交错合并，不再让用户先选一个平台
 * 才能搜 —— 同一首歌常常只有其中一两个平台能拿到播放链接，先猜平台很折腾。
 * 搜完可以用右上角的下拉框只看某一个平台，不筛就是全部。
 *
 * 音质不在这里选：那是「设置 - 播放设置 - 播放音质」的事，搜索页再摆一排
 * 只会和设置页抢同一个值（以前就是两边各写一趟），按播放音质协商即可。
 *
 * 搜索结果本身不依赖音源；音源只决定「搜到的这首歌能不能解析出播放链接」。
 */
@Component
export struct SearchView {
  @Prop bottomInset: number = 0;
  @State keyword: string = '';
  /**
   * 曲目自带的音质字段来自设置里的那一份（设置 - 播放设置 - 播放音质）：
   * 它只是「这首歌有这么一档」的标记，真正协商在播放/下载时按 Quality.ets 走。
   */
  @StorageLink(K_PLAY_QUALITY) quality: string = '128k';
  @State searching: boolean = false;
  @State status: string = '输入歌名或歌手，一次搜全部平台';
  @State currentId: string = '';
  /** 平台筛选：'' = 全部（聚合），否则是平台 id */
  @State filter: string = FILTER_ALL;
  /** 交错合并后的全量结果（不筛时显示这一份） */
  @State merged: SongItem[] = [];
  /** 逐平台的结果（筛某个平台时显示对应那一份） */
  @State perPlatform: Record<string, SongItem[]> = {};
  /** 逐平台的失败原因（成功的平台不放进来） */
  @State failures: Record<string, string> = {};
  /** 当前显示的结果（= 全部 或 某个平台） */
  @State results: SongItem[] = [];
  /** 搜索是否已经出过结果（用来区分「还没搜」和「搜过但没结果」） */
  @State searched: boolean = false;
  /** 玻璃厚度档位（外观设置）：搜索框的毛玻璃跟着它变 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;

  // ------------------------------------------------------------ 数据

  /** 某个平台这次搜到几首（筛选菜单里标出来，用户好判断哪个平台值得切） */
  private countOf(source: string): number {
    const list: SongItem[] | undefined = this.perPlatform[source];
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

  /** 切筛选：只是换一份现成的列表，不重新联网搜索 */
  private applyFilter(): void {
    if (this.filter === FILTER_ALL) {
      this.results = this.merged;
      return;
    }
    const list: SongItem[] | undefined = this.perPlatform[this.filter];
    this.results = list !== undefined ? list : [];
  }

  private resetResults(): void {
    this.merged = [];
    this.perPlatform = {};
    this.failures = {};
    this.results = [];
    this.searched = false;
  }

  // ------------------------------------------------------------ 搜索

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
    this.status = `正在聚合搜索「${text}」…`;
    try {
      const result: LxAggSearchResult =
        await searchMusicAll(text, SEARCH_PLATFORMS, 1, PER_PLATFORM_LIMIT);
      // 每个平台的 musicInfo 只转一次 SongItem：同一条目在「全部」和「单个平台」
      // 两份列表里是同一个对象，收藏/在播高亮按 id 匹配才不会两边对不上
      const per: Record<string, SongItem[]> = {};
      const bad: Record<string, string> = {};
      const lists: SongItem[][] = [];
      for (let i = 0; i < result.platforms.length; i++) {
        const p: LxPlatformSearch = result.platforms[i];
        const items: SongItem[] = [];
        for (let j = 0; j < p.items.length; j++) {
          items.push(songFromSearch(p.items[j], this.quality));
        }
        per[p.source] = items;
        lists.push(items);
        if (p.error.length > 0) {
          bad[p.source] = p.error;
        }
      }
      this.perPlatform = per;
      this.failures = bad;
      this.merged = interleave(lists);
      this.searched = true;
      // 筛着某个平台又换了关键词：这次那个平台一条都没有（多半是它没通）就退回
      // 全部 —— 与其让人对着空列表，不如先把聚合结果摆出来，状态行里照样会写明
      // 是哪个平台失败了
      if (this.filter !== FILTER_ALL && this.countOf(this.filter) === 0) {
        this.filter = FILTER_ALL;
      }
      this.applyFilter();
      if (this.merged.length === 0) {
        this.status = this.failureCount() === SEARCH_PLATFORMS.length
          ? '五个平台都没搜通，检查一下网络'
          : `没有搜到「${text}」`;
      } else {
        this.status = `共 ${this.merged.length} 首 —— ${this.summaryText()}`;
      }
    } catch (e) {
      this.status = `搜索失败: ${(e as Error).message}`;
    } finally {
      this.searching = false;
    }
  }

  // ------------------------------------------------------------ 构建

  /** 平台筛选下拉菜单（菜单项带上这个平台搜到几首） */
  @Builder
  filterMenu() {
    Menu() {
      MenuItem({ content: `全部平台（${this.merged.length}）` })
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
          this.keyword = value;
        })
        .onSubmit(() => {
          this.doSearch();
        })
      if (this.keyword.length > 0) {
        IconGlyph({
          symbol: I_CLOSE,
          iconSize: 16,
          color: C_TEXT_WEAK,
        })
          .onClick(() => {
            this.keyword = '';
            this.resetResults();
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
            this.doSearch();
          })
          .accessibilityText('搜索')
          .accessibilityLevel('yes')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })

      // ---------------------------------------------------- 结果栏：标题 + 平台筛选
      Row({ space: 8 }) {
        SectionTitle({ text: '搜索结果' })
        Blank()
        if (this.merged.length > 0) {
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

      // ---------------------------------------------------- 结果
      if (this.searching) {
        Column() {
          LoadingProgress().width(38).height(38).color(C_RED)
        }
        .width('100%')
        .padding({ top: 60 })
      } else if (this.results.length === 0) {
        // 空态：没搜过 / 搜了没结果 / 筛出来的平台是空，三种说法不一样
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
          // 聚合结果里同一首歌会有好几条（各平台各一条），行上标出平台才好选
          showSource: true,
          bottomInset: this.bottomInset,
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
    .height('100%')
    .backgroundColor(C_BG)
  }

  private emptyText(): string {
    if (!this.searched) {
      return '搜一首歌试试';
    }
    if (this.filter !== FILTER_ALL) {
      return `${platformName(this.filter)} 没有结果`;
    }
    return '没有搜到结果';
  }

  private emptyHint(): string {
    if (!this.searched) {
      return '一次搜酷我、酷狗、咪咕、QQ、网易五个平台，搜完可以只看某个平台。';
    }
    if (this.failureCount() > 0) {
      return `本次 ${this.summaryText()}。失败的平台多半是网络或接口变了，可以只切到通了的平台看。`;
    }
    return '换个关键词试试，或者少写几个字。';
  }
}
