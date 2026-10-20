import { hilog } from '@kit.PerformanceAnalysisKit';
import { BottomBar } from '../ui/BottomBar';
import { CoverArt, EmptyState, TopFade } from '../ui/Widgets';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT_STRONG, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK,
  F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { I_CHEVRON_DOWN, I_CHEVRON_RIGHT, IconGlyph } from '../ui/Icons';
import { ArtistNav } from '../ui/ArtistNav';
import { CONTENT_MAX_WIDTH, K_WINDOW_WIDTH } from '../ui/Layout';
import { EchoArtist, EchoSong, EchoStats, K_ECHO_VERSION, ListenLog } from '../core/history/ListenLog';
import { ArtistCandidate } from '../core/music/MusicArtist';
import { isSearchSupported, LxMusicInfo, LxSearchOutcome, SEARCH_PLATFORMS, searchMusic,
  searchMusicAll } from '../core/music/MusicSearch';
import { PlaySession, songFromSearch } from '../core/player/PlaySession';

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

/** 总时长那一行的字号（比大标题小一档，但明显比正文重） */
const DURATION_SIZE: number = 23;
/** 三格统计里数字的字号 */
const STAT_SIZE: number = 23;
/** 列表行高：封面 48 + 上下各 11 */
const ROW_HEIGHT: number = 70;
/** 点一行去播放时，按「歌名 + 歌手」搜几条候选、取第一条（与识别页同一套） */
const PLAY_SEARCH_LIMIT: number = 10;

/**
 * 时长文案
 *
 * 界面上那句「不到 1 分钟」就是它：0 到 59 秒都归这一句 —— 截图里 0 分钟的账
 * 写的正是「不到 1 分钟」，而不是「0 分钟」（月报这种东西，0 也要说得像句人话）。
 */
function durationText(ms: number): string {
  const minutes: number = Math.floor(ms / 60000);
  if (minutes < 1) {
    return '不到 1 分钟';
  }
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const hours: number = Math.floor(minutes / 60);
  const rest: number = minutes % 60;
  return rest === 0 ? `${hours} 小时` : `${hours} 小时 ${rest} 分钟`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 这一条是哪天几点听的（列表行副标题里那半截） */
function listenedAtText(at: number): string {
  const date = new Date(at);
  return `${date.getDate()} 日 ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/**
 * 三格统计里的一格：数字 + 说明（次播放 / 首歌 / 位歌手）
 *
 * `more` 是「这一格能点进去」的意思：只有「位歌手」那一格通往歌手名单，
 * 所以只有它带那枚小尖角 —— 不给一个看起来能点、其实点不动的样子。
 */
@Component
struct EchoStat {
  @Prop value: number = 0;
  @Prop label: string = '';
  @Prop more: boolean = false;

  build() {
    Column({ space: 6 }) {
      Text(`${this.value}`)
        .fontSize(STAT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
      Row({ space: 2 }) {
        Text(this.label)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        if (this.more) {
          IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 11, color: C_TEXT_WEAK })
            .accessibilityLevel('no')
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 回响（月度收听记录）
 *
 * 照着无界音乐那一栏做的：大标题「10 月 · 回响」，下面是这个月的总时长、三格统计
 * （次播放 / 首歌 / 位歌手）、两颗年月选择器，再下面是这个月听过的歌。
 * 没有记录的月份只给一句「还没有收听记录 / 听满 30 秒的歌会出现在这里」，不摆空卡片。
 *
 * 歌手这一维的入口就是三格里的**「位歌手」那一格**：点它进这个月的歌手名单
 * （`ListenLog.artistsOf` 聚合出来的人 + 各听了几首），名单里再点一位就是他的聚合页。
 * 这一页**不再**另摆一张「常听歌手」卡：月报的主角是总时长与听过的歌，多一块卡片
 * 既占了歌单的位置，也和那三格里的「位歌手」是同一份数据、说了两遍。
 *
 * 数据全来自 {@link ListenLog}（一次播放一条流水）与它的聚合，页面自己不算数；
 * 流水一变（切歌、退到后台落盘、播放中每 60 秒一次的落盘）就由 @StorageLink 把这一页刷一遍。
 *
 * 只算「听满 30 秒」的那几次播放（门槛在 ListenLog，不在这一页）：点开一下就切走的不算听过。
 */
@Component
export struct EchoView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 内容底部要留出的空间：悬浮页签栏 + 迷你条（由壳层算好） */
  @Prop bottomInset: number = 0;
  /** 窗口宽度（vp）：宽屏下这一页收成居中的一列（月报不是列表，拉满整屏没法读） */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;
  /** 流水版本号：变了就重算这一页 */
  @StorageLink(K_ECHO_VERSION) @Watch('onLogChanged') logVersion: number = 0;
  /** 选中的年月：进来默认当月 */
  @State year: number = 0;
  @State month: number = 0;
  @State stats: EchoStats = new EchoStats();
  @State songs: EchoSong[] = [];
  /** 这个月听过的歌手（按听得多少排）：顶部「位歌手」那一格点进去的名单 */
  @State artists: EchoArtist[] = [];
  /** 年选择器的档：有记录的年份 + 今年（新的在前） */
  @State years: number[] = [];
  /** 月选择器的档：选中年份里能选的月份（新的在前，今年只到当月） */
  @State monthOptions: number[] = [];
  /** 正在按名字去搜的那一首（防连点） */
  @State playingKey: string = '';
  private pageScroller: Scroller = new Scroller();

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
    const log = ListenLog.getInstance();
    this.stats = log.statsOf(this.year, this.month);
    this.songs = log.songsOf(this.year, this.month);
    this.artists = log.artistsOf(this.year, this.month);
    this.years = this.yearOptions();
    this.monthOptions = this.monthOptionsOf(this.year);
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

  private pickYear(year: number): void {
    this.year = year;
    const months: number[] = this.monthOptionsOf(year);
    this.monthOptions = months;
    // 换到「今年」时，原来选的月份可能还没到（比如原来在 12 月、现在只是 10 月），往前收一档
    if (!months.includes(this.month)) {
      this.month = months.length > 0 ? months[0] : 1;
    }
    this.refresh();
  }

  private pickMonth(month: number): void {
    if (this.month === month) {
      return;
    }
    this.month = month;
    this.refresh();
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

  // ------------------------------------------------------------ 播放

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

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 构建

  /** 年月选择器那种灰胶囊（点一下弹出菜单） */
  @Builder
  pickerPill(text: string) {
    Row({ space: 4 }) {
      Text(text)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
      IconGlyph({ symbol: I_CHEVRON_DOWN, iconSize: 14, color: C_TEXT_SUB })
    }
    .height(40)
    .padding({ left: 16, right: 12 })
    .borderRadius(20)
    .backgroundColor(C_FILL_SOFT_STRONG)
  }

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

  /** 列表里的一行：封面 + 歌名 + 「歌手 · 哪天听的」+ 听了几次 / 一共多久 */
  @Builder
  songRow(song: EchoSong) {
    Row({ space: 11 }) {
      CoverArt({
        url: song.coverUrl,
        name: song.name,
        art: song.art,
        boxSize: 48,
      })

      Column({ space: 4 }) {
        Text(song.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(song.singer.length > 0
          ? `${song.singer} · ${listenedAtText(song.lastAt)}`
          : listenedAtText(song.lastAt))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 4 }) {
        // 听了不止一遍才写次数：一首只听过一次的行，右边多一个「×1」是废话
        if (song.plays > 1) {
          Text(`×${song.plays}`)
            .fontSize(F_SUB)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_RED)
        }
        Text(durationText(song.totalMs))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 14, right: 14 })
    .onClick(() => {
      void this.playSong(song);
    })
    // 整行当一个节点：读屏读「歌名，歌手，听了几次」，而不是把封面、文字逐个念一遍
    .accessibilityGroup(true)
    .accessibilityText(song.singer.length > 0 ? `${song.name}，${song.singer}` : song.name)
    .accessibilityLevel('yes')
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

  /** 这个月听过的歌（一张卡，行间细分割线） */
  @Builder
  songCard() {
    Column() {
      ForEach(this.songs, (song: EchoSong, index: number) => {
        Column() {
          if (index > 0) {
            Divider()
              .strokeWidth(0.6)
              .color(C_DIVIDER)
              .margin({ left: 73 })
          }
          this.songRow(song)
        }
        .width('100%')
        // key 带上次数与时长：流水一变（正听着的那首在涨）同一首歌的数字也要重排，
        // 光用「歌名 + 歌手」当 key 的话 ForEach 认成同一行，数字会留在旧值上
      }, (song: EchoSong) => `${song.name}\u0001${song.singer}\u0001${song.plays}\u0001${song.totalMs}`)

      Column().height(6).width('100%')
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll(this.pageScroller) {
          Column() {
            // 顶部占位：让出透明标题栏那一段（大标题在标题栏里，内容从它下面开始）
            Column().height(this.topInset + 16).width('100%')

            Column() {
              // 「10 月 · 回响」这个标题不在这里画：它由壳层的标题栏承载（见 K_ECHO_TITLE），
              // 与「推荐」「我的」同一个位置。这一页从总时长开始
              Text(durationText(this.stats.totalMs))
                .fontSize(DURATION_SIZE)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_TEXT)
                .width('100%')
                .textAlign(TextAlign.Start)

              /**
               * 三格统计：平分一行、各自左对齐（截图里三个数是等距铺开的）
               *
               * 「位歌手」那一格是这一页唯一的歌手入口：点它进这个月的歌手名单
               * （见 openArtists），名单里再点一位就是他的聚合页。
               * 前两格（次播放 / 首歌）没有下一层，所以只有这一格带小尖角、也就只有它能点。
               */
              Row() {
                EchoStat({ value: this.stats.playCount, label: '次播放' })
                  .layoutWeight(1)
                EchoStat({ value: this.stats.songCount, label: '首歌' })
                  .layoutWeight(1)
                Column() {
                  EchoStat({
                    value: this.stats.artistCount,
                    label: '位歌手',
                    more: this.artists.length > 0,
                  })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .onClick(() => {
                  this.openArtists();
                })
                .accessibilityText(`这个月听过 ${this.stats.artistCount} 位歌手，点按查看名单`)
                .accessibilityLevel('yes')
              }
              .width('100%')
              .margin({ top: 18 })

              Row({ space: 10 }) {
                Row() {
                  this.pickerPill(`${this.year} 年`)
                }
                .bindMenu(this.yearMenu())
                .accessibilityText(`年份：${this.year} 年，点按切换`)
                .accessibilityLevel('yes')

                Row() {
                  this.pickerPill(`${this.month} 月`)
                }
                .bindMenu(this.monthMenu())
                .accessibilityText(`月份：${this.month} 月，点按切换`)
                .accessibilityLevel('yes')

                Blank()

                if (this.songs.length > 0) {
                  Text('清空')
                    .fontSize(F_SUB)
                    .fontColor(C_TEXT_SUB)
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
                // 空态不进卡、也不带图标：截图里它就是页面上的一段留白 + 两行字
                EmptyState({
                  text: '还没有收听记录',
                  hint: '听满 30 秒的歌会出现在这里',
                  topPadding: 56,
                  showIcon: false,
                })
              } else {
                Column() {
                  this.songCard()
                }
                .width('100%')
                .margin({ top: 22 })
              }

              Column().height(this.bottomInset + 16).width('100%')
            }
            .width('100%')
            /**
             * 宽屏下这一页收成居中的一列，窄屏铺满 —— 两种情况下都留 16 的左右内边距
             *
             * 内边距这一条与所有页面一致（第一版漏了它，整块内容贴着屏幕边，
             * 看上去像被裁掉了一截、标题与统计全怼在左缘）；宽屏收窄的口径见下。
             * 与列表页（铺满、按窗口多列）不同：这是一张月报，一共就三格数字加一张歌单，
             * 平板上拉满 1400vp 的话「不到 1 分钟」孤零零挂在最左边、右边一大片空。
             * 表单类页面也是这个口径（见 ui/Layout.ets 的 CONTENT_MAX_WIDTH）。
             */
            .padding({ left: 16, right: 16 })
            .constraintSize({ maxWidth: CONTENT_MAX_WIDTH })
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Top)
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
          // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
          BottomBar.notifyScrollDelta(this.getUIContext(), offset);
          return { offsetRemain: offset };
        })
        .width('100%')
      }
      .width('100%')
      .height('100%')

      // 顶栏渐隐：大标题从透明标题栏底下穿过时靠近顶部淡出
      TopFade({ fadeHeight: this.topInset + 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
