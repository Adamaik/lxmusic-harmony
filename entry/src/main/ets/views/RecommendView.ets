import {
  LIST_PLATFORMS, LxBoardItem, LxListDetail, LxPlaylistItem, LxSortItem, OnlineRoute,
  getBoardSongs, getBoards, getRecommendPlaylists, getWyPersonalizedPlaylists, sortListOf,
} from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { BottomBar } from '../ui/BottomBar';
import {
  C_BG, C_CARD, C_CHEVRON, C_FILL_SOFT, C_FILL_SOFT_STRONG, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB,
  C_TEXT_WEAK, F_SECTION,
} from '../ui/Theme';
import {
  I_CHEVRON_RIGHT, I_PERSON, I_PLAYLIST, I_PLAY, I_STAR, I_TROPHY, IconGlyph,
} from '../ui/Icons';
import { CoverArt, FavoriteHeart, TopFade } from '../ui/Widgets';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { LxArtist, resolveArtistByName, splitSingerNames } from '../core/music/MusicArtist';
import { ArtistNav } from '../ui/ArtistNav';
import { PlaylistCard, PlaylistRow, PlaylistRowSource } from '../ui/PlaylistGrid';
import { TileCard } from '../ui/TileCard';
import { K_RECOMMEND_SOURCE } from '../core/settings/RecommendSettings';
import { K_WINDOW_WIDTH } from '../ui/Layout';
import { K_MUSIC_LOGGED_WY } from '../core/music/MusicAccount';

/**
 * 推荐页（三个胶囊各是一套版面，全部照用户给的华为音乐截图）
 *
 *   顶部（三个胶囊下都在）：**推荐歌曲** —— 可右滑的大卡，一屏露两张半，不止两首；
 *   ① 精选：**分区信息流**
 *        · 每个排序一区（标题 + 「更多」+ 三列横滑卡）
 *        · 排行榜：**多张榜一横排、可自由右滑**，每张榜一张卡（榜名 + 播放钮 + 三行 +
 *          「查看完整榜单」），**每张榜横滑到可视区才取它的歌**；
 *        · 新歌精选（几行歌 + 收藏），「更多」进新歌榜；
 *        · 歌单·漫游（两列大卡），「更多」进「全部歌单」页；
 *   ② 歌单：**歌单分类**（= 平台的排序，一横排卡）+ **歌单广场**（两列大卡，滑到底翻页）；
 *   ③ 排行榜：**官方榜**（每张榜一张白卡：榜名 + 封面 + 三行）+ **精选榜**（其余榜单两列封面卡）。
 *
 * **每个分区都能点进「全部」**：歌单区 → 「全部歌单」页（平台 × 排序的全量，翻页）；
 * 排行榜每张榜 → 榜单页（全量歌曲）；新歌精选 → 新歌榜页；歌单·漫游 → 「全部歌单」页。
 *
 * 华为首页里那些运营策展区（旋律旅程 / 数字专辑 / 热点追踪 / 影廊…）宿主没有对应接口，
 * 没有拿别的数据硬凑标题。
 *
 * **卡片形态与配色**（2026-10-21 重做）：歌手分类 / 歌单分类 / 精选榜原先按数组下标循环取
 * 6 组高饱和纯色渐变（红 / 蓝 / 紫 / 橙 / 粉 / 绿），一屏七八张彩虹块，和本应用
 * 「浅灰底 + 白卡 + 洛雪红 + 玻璃层」的主题完全不是一个语言（用户反馈「纯色和软件主题不搭」）。
 * 现在三处都改用共用组件 `ui/TileCard.ets`，只有两种形态：
 *   - **有真实封面**（榜单榜首封面）→ 封面铺满 + 底部压暗 + 白字，跟推荐歌曲大卡同一观感；
 *   - **没有封面**（平台歌单分类这种纯文字档位）→ 主题玻璃卡：白卡 + 极淡红晕染 + 深色字。
 * 选中态一律用强调红描边，颜色只剩「选中」一个语义，不再靠换配色区分。
 *
 * **懒加载与主线程纪律**（2026-10-13 实机反馈「切平台卡好久、甚至闪退」之后定的）：
 *   - 开页只取首屏要用的（推荐歌曲那一张榜），其余滚进可视区才发请求
 *     （`onVisibleAreaChange`，**不能用 `onAppear`**：外层 List 是 ForEach，开页时
 *     每一块都会回调一次）；
 *   - 一行多卡 / 两列网格都用 `LazyForEach` + 数据源，只建可视区那几张那几行；
 *   - 榜单每一张单独懒加载（横滑到哪张取哪张），且一张榜最多转前 `BOARD_SONGS_MAX` 首；
 *   - 分类卡 / 精选榜卡上的封面也单独懒加载，而且**一次只要 1 首**（见 ensureBoardCover）：
 *     卡滚进可视区才发请求，失败就落玻璃卡，绝不为了一个封面把整张榜拉回来；
 *   - 没数据时一律摆灰块骨架（尺寸照真卡给），不给「空栏 + 一句话」。
 */

/** 页面左右留白（与壳层标题栏、迷你栏同一口径） */
const PAGE_PAD: number = 16;
/** 同一行里两张卡之间的间距 */
const CARD_GAP: number = 10;
/** 行与行之间的间距（外层 List 的 space） */
const ROW_GAP: number = 18;
/** 卡片上歌名 / 副标题的字号 */
const CARD_TITLE_SIZE: number = 12.5;
const CARD_META_SIZE: number = 11;
/** 一句话文案（空档 / 失败 / 更多）的字号 */
const SUB_SIZE: number = 12.5;

/** 顶部推荐歌曲放几首（一屏露两张半，要能右滑） */
const HERO_COUNT: number = 8;
/** 官方榜摆几张榜（照华为：热歌 / 新歌 / 飙升） */
const OFFICIAL_COUNT: number = 3;
/** 官方榜优先找这三张（找不到退回平台榜单的前几张） */
const OFFICIAL_NAMES: string[] = ['热歌榜', '新歌榜', '飙升榜'];
/** 官方榜一张卡、精选页排行榜一栏，各显示几行歌 */
const OFFICIAL_SONGS: number = 3;
/** 精选页「排行榜」横滑摆几张榜（一屏两张，其余右滑） */
const TOP_LIST_BOARDS: number = 6;
/** 精选页「新歌精选」显示几首（其余进新歌榜页看） */
const NEW_SONGS: number = 4;
/**
 * 一张榜最多转成几首 SongItem
 *
 * 榜单接口一次回多少首由平台决定（酷我 rn=100、酷狗 100、QQ 300、**网易 n=1000**），
 * 以前把整张榜都 `songFromSearch` 一遍 —— 每首都要 `JSON.stringify`，几张榜几千次转换
 * 全在主线程上跑，切到网易会卡住甚至把进程撑爆。首页只需要「三行 + 一条能用的播放队列」，
 * 其余等用户点进榜单页（那里才真的需要全量）。
 */
const BOARD_SONGS_MAX: number = 50;
/** 首页向榜单接口要几首（够三行 + 一条短队列就够了，别把整张榜拉回来，见 getBoardSongs 的说明） */
const BOARD_SONGS_LIMIT: number = 20;
/** 歌单广场骨架摆几行 */
const PLAZA_BONE_ROWS: number = 2;
/** 精选页排行榜那一横排的高度（一栏卡：榜名 + 三行 + 查看完整榜单 + 内边距） */
const TOP_LIST_HEIGHT: number = 196;

/** 分类胶囊 */
const TAB_FEATURED: string = 'featured';
const TAB_PLAYLIST: string = 'playlist';
const TAB_ARTIST: string = 'artist';
const TAB_BOARD: string = 'board';

/**
 * 歌手一栏的「歌手分类」怎么来
 *
 * 平台榜单里那些**曲风**榜就是现成的分类（说唱榜 / 电音榜 / 民谣榜 / 古风音乐榜 …），
 * 拿名字匹配这几个关键词挑出来；第一张分类固定是「热门」（= 热歌榜），
 * 底下「热门歌手」就是那一榜前几首的歌手里去重出来的 —— 都是真实数据，
 * 没有为了凑版面编分类。
 */
const ARTIST_CAT_KEYS: string[] = ['说唱', '电音', '民谣', '古风', '国风', '摇滚', '古典', '爵士',
  'ACG', '欧美', '韩国', '日本', '流行', '粤语', '网络', '影视'];
/** 最多摆几张分类卡 */
const ARTIST_CAT_COUNT: number = 6;
/** 「热门歌手」最多列几位 */
const ARTIST_MAX_ROWS: number = 60;
/** 头像边长（圆）+ 一行的高度 */
const ARTIST_AVATAR: number = 52;
/** 加载中摆几行骨架 */
const ARTIST_BONE_ROWS: number = 8;

/** 分区标题右边那颗「更多」按什么口径打开（@Builder 只传字符串：回调参数在 V1 里不踏实） */
const MORE_SORT: string = 'sort';
const MORE_NEW_SONG: string = 'newSong';
const MORE_ROAM: string = 'roam';

/** 骨架块 / 行下标要用几个：[0, 1, 2, … n-1]（ForEach 只吃数组） */
function boneIndexes(n: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    out.push(i);
  }
  return out;
}

/**
 * 一张榜（官方榜卡片 / 精选页排行榜一栏 / 推荐歌曲都用它）
 *
 * **每张榜自己懒加载**：`asked` 是「问过了」（不是「拿到了」），没进过可视区就不发请求；
 * 失败也留着，免得「失败 → 重建 → 再问」转成请求风暴（想重试走下拉刷新）。
 */
class BoardColumn {
  board: LxBoardItem = { id: '', name: '', bangid: '', source: '' };
  songs: SongItem[] = [];
  asked: boolean = false;
  loading: boolean = false;
  failed: boolean = false;
  /**
   * 只给「卡面封面」用的那一张（见 ensureBoardCover）
   *
   * 精选榜 / 歌手分类卡要的只是一张图，不能为了它把整张榜取回来，所以另开一条
   * `limit=1` 的轻请求：`songs` 到货后优先用 `songs[0]` 的封面，这里只是兜底。
   */
  cover: string = '';
  /** 封面问过没有（与 `asked` 分开：整榜取歌和取封面是两条独立的请求） */
  coverAsked: boolean = false;
  coverLoading: boolean = false;
  /** 异步回来之后让这一栏重建一次（ForEach 的 key 带着它） */
  version: number = 0;
}

/**
 * 「热门歌手」里的一位
 *
 * `artist` 是懒解析出来的（头像、别名、歌曲数都在里面）：行滚进可视区才去问一次，
 * 认不到就保持空（行照样能点，点开时由歌手页那条链自己再认一次）。
 */
class ArtistRow {
  name: string = '';
  artist: LxArtist | null = null;
  asked: boolean = false;
  version: number = 0;
}

/** 精选页里「按排序的一个歌单区」 */
class SortSection {
  sortId: string = '';
  title: string = '';
  page: number = 0;
  loading: boolean = false;
  failed: boolean = false;
  /** 问过没有（同上：不是「拿到了」） */
  asked: boolean = false;
  items: LxPlaylistItem[] = [];
  source: PlaylistSource = new PlaylistSource();
  version: number = 0;
}

/** 精选页一个排序区里那行横滑卡的数据源（一页几十张，只建可视区那几张） */
class PlaylistSource implements IDataSource {
  private items: LxPlaylistItem[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: LxPlaylistItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): LxPlaylistItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

/** 顶部推荐歌曲那条横滑列表的数据源 */
class SongSource implements IDataSource {
  private items: SongItem[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: SongItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SongItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

@Component
export struct RecommendView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onOpenOnline: (route: OnlineRoute) => void = () => {
  };
  /** 打开「全部歌单」页（分区标题右边「更多」） */
  onOpenSquare: (source: string, sortId: string, name: string) => void = () => {
  };
  /** 当前推荐来源（标题栏里那颗来源胶囊改的就是它） */
  @StorageLink(K_RECOMMEND_SOURCE) @Watch('onPlatformChanged') platform: string = 'kw';
  /** 窗口宽度（vp）：决定一屏几张卡、网格几列；0 = 还没量到，按手机档 */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  @State sorts: LxSortItem[] = sortListOf('kw');
  @State tab: string = TAB_FEATURED;
  /** 平台榜单一张榜一条（懒加载，见 BoardColumn 的说明） */
  @State boardColumns: BoardColumn[] = [];
  /** 顶部推荐歌曲（= 第一张 flagship 榜的前几首） */
  @State hero: SongItem[] = [];
  /** 精选页的排序分区 */
  @State sortSections: SortSection[] = [];
  /** 歌手一栏：「歌手分类」= boardColumns 的下标表（0 号固定是「热门」= 热歌榜） */
  @State artistCats: number[] = [];
  @State artistCatIndex: number = 0;
  /** 当前分类下「热门歌手」那几行 */
  @State artistRows: ArtistRow[] = [];
  /** 歌单广场选中的分类（= sorts 的下标） */
  @State catIndex: number = 0;
  /**
   * 歌单分类卡上的封面（下标与 sorts 对齐；空串 = 还没取到，走玻璃卡）
   *
   * 见 loadCatCovers 的说明：分类本身没有封面，用该分类下第一张歌单的封面顶上。
   */
  @State catCovers: string[] = [];
  @State plaza: LxPlaylistItem[] = [];
  @State plazaPage: number = 0;
  @State plazaLoading: boolean = false;
  @State plazaLoaded: boolean = false;
  @State plazaNoMore: boolean = false;
  @State plazaError: string = '';
  @State refreshing: boolean = false;
  @State error: string = '';
  /**
   * 网易登录态：登录后才有「私人推荐 / 私人雷达」这类账号歌单
   *
   * 这一块只在「推荐来源 = 网易云」且已登录时出现（接口 `recommend/resource`
   * 匿名直接回 301，见 MusicList.getWyPersonalizedPlaylists 的说明）。
   * 登录 / 退出可能发生在本页停留期间（去设置页登录再回来），所以要 Watch 清缓存重取。
   */
  @StorageLink(K_MUSIC_LOGGED_WY) @Watch('onLoginChanged') wyLogged: boolean = false;
  @State wyRec: LxPlaylistItem[] = [];
  @State wyRecAsked: boolean = false;
  @State wyRecFailed: boolean = false;
  /**
   * 封面懒解析好后版本号会变，订阅它把歌行重画一遍
   *
   * 榜单接口回来的歌**很多是没有封面的**（酷狗榜单 `img` 直接给空串），列表里要用
   * `CoverStore.coverFor` 现解：先拿占位、解好了再重画（与仓库里其它歌曲列表同一套）。
   * 不这么做的话，酷狗的歌外面永远是一张占位图，点开播放才由播放页去解出来。
   */
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;
  /** 歌单广场 / 歌单·漫游那两列网格的数据源 */
  private plazaRows: PlaylistRowSource = new PlaylistRowSource();
  /** 顶部推荐歌曲那条横滑列表的数据源（常驻，不能每帧 new 一个） */
  private heroSource: SongSource = new SongSource();
  /** 推荐歌曲用哪张榜（热歌榜优先，见 pickOfficialIndexes） */
  private heroIndex: number = 0;
  private plazaAsked: boolean = false;
  /** 分类卡封面是否已经有一轮在取了（同一时刻只跑一轮） */
  private catCoversAsked: boolean = false;

  aboutToAppear(): void {
    this.sorts = sortListOf(this.platform);
    if (this.boardColumns.length === 0) {
      void this.reload();
    }
  }

  /** 换平台：一切重来（排序、分区、榜单、广场都是这个平台的口径） */
  private onPlatformChanged(): void {
    if (!LIST_PLATFORMS.includes(this.platform)) {
      return;
    }
    this.sorts = sortListOf(this.platform);
    void this.reload();
  }

  /**
   * 拉首屏：建好所有块的壳（不发请求），只取「推荐歌曲」那一张榜
   *
   * 其余榜单 / 排序分区 / 广场都在各自滚进可视区时才发请求。
   */
  private async reload(): Promise<void> {
    this.error = '';
    this.hero = [];
    this.heroSource.setItems(this.hero);
    this.plaza = [];
    this.plazaRows.setItems(this.plaza, this.gridCols());
    this.plazaPage = 0;
    this.plazaLoaded = false;
    this.plazaNoMore = false;
    this.plazaError = '';
    this.plazaAsked = false;
    this.catIndex = 0;
    this.catCovers = [];
    this.catCoversAsked = false;
    // 私人推荐跟平台 / 登录态绑着：换平台或下拉刷新都重新取（问过标记一起清）
    this.wyRec = [];
    this.wyRecAsked = false;
    this.wyRecFailed = false;
    // 刷新后那块 ListItem 不一定再触发一次 onVisibleAreaChange（它本来就在可视区），
    // 所以这里主动补一次取数；未登录 / 非网易来源时 ensureWyRec 自己会跳过
    if (this.platform === 'wy' && this.wyLogged) {
      this.ensureWyRec();
    }

    const sections: SortSection[] = [];
    for (const sort of this.sorts) {
      const section: SortSection = new SortSection();
      section.sortId = sort.id;
      section.title = `${sort.name}歌单`;
      sections.push(section);
    }
    this.sortSections = sections;

    const columns: BoardColumn[] = [];
    for (const board of getBoards(this.platform)) {
      const column: BoardColumn = new BoardColumn();
      column.board = board;
      columns.push(column);
    }
    this.boardColumns = columns;
    this.heroIndex = this.pickOfficialIndexes()[0];
    this.artistCats = this.artistCatIndexes();
    this.artistCatIndex = 0;
    this.artistRows = [];
    this.refreshing = false;
    // 分类卡封面与「推荐歌曲」并发去取（互不依赖，别让首屏等它）
    void this.loadCatCovers();
    await this.loadBoardColumn(this.heroIndex);
  }

  // ------------------------------------------------------------ 网易私人推荐（登录态）

  /**
   * 登录状态变了：把私人推荐清掉重取
   *
   * 登录 / 退出都可能发生在用户去「设置 - 登录音乐」再回来的这段时间里；旧数据
   * （尤其是退出后还挂着的私人歌单）不能继续显示。重新登录后立即取一次，不必等滚动。
   */
  private onLoginChanged(): void {
    this.wyRec = [];
    this.wyRecAsked = false;
    this.wyRecFailed = false;
    if (this.platform === 'wy' && this.wyLogged) {
      this.ensureWyRec();
    }
  }

  /** 私人推荐那一块露出来了才取：未登录 / 非网易来源一个请求都不发 */
  private ensureWyRec(): void {
    if (this.platform !== 'wy' || !this.wyLogged || this.wyRecAsked) {
      return;
    }
    this.wyRecAsked = true;
    void this.loadWyRec();
  }

  /**
   * 拉网易私人推荐歌单（每日推荐 / 私人雷达那一类）
   *
   * 失败只把这一块标成「取不到」：它是首页的加分项，接口挂了不能让整页跟着报错。
   * 登录过期是最常见的失败原因，所以失败文案直接提示去「设置 - 登录音乐」重登。
   */
  private async loadWyRec(): Promise<void> {
    try {
      this.wyRec = await getWyPersonalizedPlaylists();
      // 成功也留一行：能区分「接口通了但返回空列表」和「请求失败」两种不同问题
      console.info(`wy personal recommend ok: ${this.wyRec.length}`);
    } catch (e) {
      this.wyRecFailed = true;
      // 失败原因留在日志里：code 301 = 登录态失效（要重登），其它 code / 加密异常另查。
      // Error 直接 JSON.stringify 会得到 {}，所以取 message。
      const message: string = e instanceof Error ? e.message : JSON.stringify(e);
      console.error(`wy personal recommend failed: ${message}`);
    }
  }

  /** 官方榜要哪几张榜（按 OFFICIAL_NAMES 找，缺的用平台榜单前几张补齐）：在 boardColumns 里的下标 */
  private pickOfficialIndexes(): number[] {
    const out: number[] = [];
    for (const name of OFFICIAL_NAMES) {
      for (let i = 0; i < this.boardColumns.length; i++) {
        const board: LxBoardItem = this.boardColumns[i].board;
        if (board.name.indexOf(name) >= 0 && !out.includes(i)) {
          out.push(i);
          break;
        }
      }
    }
    for (let i = 0; i < this.boardColumns.length; i++) {
      if (out.length >= OFFICIAL_COUNT) {
        break;
      }
      if (!out.includes(i)) {
        out.push(i);
      }
    }
    return out;
  }

  /** 官方榜那三栏（排行榜页的卡片） */
  private officialColumns(): BoardColumn[] {
    const out: BoardColumn[] = [];
    for (const index of this.pickOfficialIndexes()) {
      if (index >= 0 && index < this.boardColumns.length) {
        out.push(this.boardColumns[index]);
      }
    }
    return out;
  }

  /** 精选页「排行榜」横滑的那几张榜 */
  private topListColumns(): BoardColumn[] {
    return this.boardColumns.slice(0, TOP_LIST_BOARDS);
  }

  /**
   * 精选榜（官方榜之外剩下的榜单）第 row 行的榜单：**返回 boardColumns 的下标**
   *
   * 返回下标而不是 `LxBoardItem`：卡片要按它在 boardColumns 里的位置去懒加载封面
   * （见 ensureBoardCover），拿对象还得反查下标，不如直接给。
   */
  private hotBoardsOfRow(row: number): number[] {
    const official: number[] = this.pickOfficialIndexes();
    const rest: number[] = [];
    for (let i = 0; i < this.boardColumns.length; i++) {
      if (!official.includes(i)) {
        rest.push(i);
      }
    }
    const cols: number = this.gridCols();
    return rest.slice(row * cols, row * cols + cols);
  }

  /** 精选榜一共几行 */
  private hotRowIndexes(): number[] {
    const count: number = this.boardColumns.length - this.pickOfficialIndexes().length;
    return boneIndexes(Math.max(0, Math.ceil(count / this.gridCols())));
  }

  /**
   * 精选榜每一行的 ForEach key（带上这一行第一张榜的 id + **各列的 version**）
   *
   * 只带 bangid 不够：封面是异步回来的，版本号不变的话卡面不会重建，封面永远出不来。
   */
  private hotRowKey(row: number): string {
    const ats: number[] = this.hotBoardsOfRow(row);
    if (ats.length === 0) {
      return `hotrow_${row}_empty`;
    }
    const first: BoardColumn = this.boardColumns[ats[0]];
    const versions: string = ats.map((at: number) => `${this.boardColumns[at].version}`).join('_');
    return `hotrow_${row}_${first.board.bangid}_${versions}`;
  }

  /** 精选榜一张卡的 ForEach key（带这张榜的 version：封面回来之后卡面才会重建） */
  private hotTileKey(at: number): string {
    const column: BoardColumn = this.boardColumns[at];
    return `hot_${column.board.bangid}_${column.version}`;
  }

  /** 精选页「新歌精选」用哪一栏（新歌榜优先，没有就官方榜第一栏）；-1 = 这个平台没有 */
  private newSongIndex(): number {
    for (let i = 0; i < this.boardColumns.length; i++) {
      if (this.boardColumns[i].board.name.indexOf('新歌榜') >= 0) {
        return i;
      }
    }
    const official: number[] = this.pickOfficialIndexes();
    return official.length > 0 ? official[0] : -1;
  }

  private newSongColumn(): BoardColumn | null {
    const index: number = this.newSongIndex();
    return index >= 0 && index < this.boardColumns.length ? this.boardColumns[index] : null;
  }

  /** 新歌榜那一栏确认取不到了（还没到货不算） */
  private newSongFailed(): boolean {
    const index: number = this.newSongIndex();
    if (index < 0 || index >= this.boardColumns.length) {
      return false;
    }
    const column: BoardColumn = this.boardColumns[index];
    return column.asked && !column.loading && column.failed;
  }

  /** 「新歌精选」要放的那几首（新歌榜的前几首；其余进新歌榜页看） */
  private newSongList(): SongItem[] {
    const column: BoardColumn | null = this.newSongColumn();
    if (column === null) {
      return [];
    }
    return column.songs.slice(0, NEW_SONGS);
  }

  // ------------------------------------------------------------ 歌手一栏

  /** 「歌手分类」的榜单下标表：第一张是「热门」（热歌榜），后面是名字带曲风关键词的榜 */
  private artistCatIndexes(): number[] {
    const out: number[] = [];
    if (this.heroIndex >= 0 && this.heroIndex < this.boardColumns.length) {
      out.push(this.heroIndex);
    }
    for (let i = 0; i < this.boardColumns.length; i++) {
      if (out.length >= ARTIST_CAT_COUNT) {
        break;
      }
      if (out.includes(i)) {
        continue;
      }
      const name: string = this.boardColumns[i].board.name;
      for (const key of ARTIST_CAT_KEYS) {
        if (name.indexOf(key) >= 0) {
          out.push(i);
          break;
        }
      }
    }
    return out;
  }

  /** 歌手一栏当前分类那张榜在 boardColumns 里的下标（-1 = 没有） */
  private artistBoardIndex(): number {
    if (this.artistCatIndex < 0 || this.artistCatIndex >= this.artistCats.length) {
      return -1;
    }
    return this.artistCats[this.artistCatIndex];
  }

  /** 分类卡上显示的名字（第一张叫「热门」，其余用榜单自己的名字） */
  private artistCatName(index: number): string {
    if (index === 0) {
      return '热门';
    }
    const at: number = index < this.artistCats.length ? this.artistCats[index] : -1;
    if (at < 0 || at >= this.boardColumns.length) {
      return '';
    }
    const name: string = this.boardColumns[at].board.name;
    return name.endsWith('榜') ? name.substring(0, name.length - 1) : name;
  }

  /** 第 index 张歌手分类卡对应哪张榜（boardColumns 下标；越界 / -1 = 没有，卡面落玻璃卡） */
  private artistCatBoardAt(index: number): number {
    if (index < 0 || index >= this.artistCats.length) {
      return -1;
    }
    const at: number = this.artistCats[index];
    return at >= 0 && at < this.boardColumns.length ? at : -1;
  }

  /** 第 index 张歌手分类卡的封面（对应榜的第一首封面；没有就空串 → 玻璃卡） */
  private artistCatCover(index: number): string {
    const at: number = this.artistCatBoardAt(index);
    return at >= 0 ? this.boardCover(this.boardColumns[at]) : '';
  }

  /**
   * 歌手分类卡的 ForEach key：带对应榜的 version（封面回来才重建）+ **选中态**
   *
   * 选中态也得拼进 key：ForEach 对 key 没变的条目**不会重跑生成器**，`selected` 这个
   * @Prop 传不进去，红边就永远不出现（与 ListenView 分类卡那条注释同一个坑）。
   */
  private artistCatKey(index: number): string {
    const at: number = this.artistCatBoardAt(index);
    const version: number = at >= 0 ? this.boardColumns[at].version : 0;
    const on: string = this.artistCatIndex === index ? 'on' : 'off';
    return `acat_${index}_${at}_${version}_${on}`;
  }

  /** 歌手一栏露出来了：先把这一榜的歌取回来（去重歌手要等它到） */
  private ensureArtistRows(): void {
    const at: number = this.artistBoardIndex();
    if (at >= 0) {
      this.ensureBoardSongs(at);
    }
    if (this.artistRows.length === 0) {
      this.buildArtistRows();
    }
  }

  /** 换分类：重新算这一榜的歌手 */
  private switchArtistCat(index: number): void {
    if (index === this.artistCatIndex) {
      return;
    }
    this.artistCatIndex = index;
    this.artistRows = [];
    this.ensureArtistRows();
  }

  /**
   * 当前分类的「热门歌手」：拿这一榜的歌，把歌手名拆开去重
   *
   * 已经解析过的那几位从旧表里带过来，换分类再换回来不会重新联网认一遍。
   */
  private buildArtistRows(): void {
    const at: number = this.artistBoardIndex();
    if (at < 0 || at >= this.boardColumns.length) {
      this.artistRows = [];
      return;
    }
    const songs: SongItem[] = this.boardColumns[at].songs;
    const rows: ArtistRow[] = [];
    const names: string[] = [];
    for (const song of songs) {
      for (const name of splitSingerNames(song.singer)) {
        if (names.includes(name) || rows.length >= ARTIST_MAX_ROWS) {
          continue;
        }
        names.push(name);
        const row: ArtistRow = new ArtistRow();
        row.name = name;
        for (const old of this.artistRows) {
          if (old.name === name && old.artist !== null) {
            row.artist = old.artist;
            row.asked = true;
            break;
          }
        }
        rows.push(row);
      }
    }
    this.artistRows = rows;
  }

  /** 这一行滚进可视区了：没认过才去认一次（认过就落盘，见 resolveArtistByName） */
  private ensureArtistRow(index: number): void {
    if (index < 0 || index >= this.artistRows.length) {
      return;
    }
    const row: ArtistRow = this.artistRows[index];
    if (row.asked) {
      return;
    }
    row.asked = true;
    void this.resolveArtistRow(index, row.name);
  }

  private async resolveArtistRow(index: number, name: string): Promise<void> {
    const artist: LxArtist | null = await resolveArtistByName(name, this.platform);
    // 这一行可能已经被换分类换掉了：按下标回填前先确认还是同一位
    if (index < 0 || index >= this.artistRows.length || this.artistRows[index].name !== name) {
      return;
    }
    this.artistRows[index].artist = artist;
    this.artistRows[index].version = this.artistRows[index].version + 1;
    this.artistRows = this.artistRows.slice();
  }

  /** 行右边那颗小胶囊的字：认到歌手就给歌曲数，没有就空着 */
  private artistPill(row: ArtistRow): string {
    if (row.artist !== null && row.artist.songNum > 0) {
      return `${row.artist.songNum} 首`;
    }
    return '';
  }

  /** 点一行：开歌手页（认人、认不到给提示都交给壳层那条链，见 ui/ArtistNav.ets） */
  private openArtistRow(row: ArtistRow): void {
    ArtistNav.getInstance().open(this.platform, row.name);
  }

  // ------------------------------------------------------------ 榜单取数

  /** 这张榜滚到可视区了：没问过才问（横滑到哪张取哪张） */
  private ensureBoardSongs(index: number): void {
    if (index < 0 || index >= this.boardColumns.length) {
      return;
    }
    const column: BoardColumn = this.boardColumns[index];
    if (column.asked || column.loading) {
      return;
    }
    column.asked = true;
    void this.loadBoardColumn(index);
  }

  /** 取这张榜的前几首（失败只在卡片里说一句） */
  private async loadBoardColumn(index: number): Promise<void> {
    if (index < 0 || index >= this.boardColumns.length) {
      return;
    }
    const column: BoardColumn = this.boardColumns[index];
    column.loading = true;
    column.failed = false;
    try {
      const detail: LxListDetail = await getBoardSongs(column.board.source, column.board.bangid, 1,
        column.board.name, BOARD_SONGS_LIMIT);
      const quality: string = PlaySession.getInstance().quality;
      const songs: SongItem[] = [];
      // 只转前 BOARD_SONGS_MAX 首（整张榜最多 1000 首，见那个常量的说明）
      const wanted: number = Math.min(detail.list.length, BOARD_SONGS_MAX);
      for (let i = 0; i < wanted; i++) {
        songs.push(songFromSearch(detail.list[i], quality));
      }
      column.songs = songs;
      if (index === this.heroIndex) {
        this.hero = songs.slice(0, HERO_COUNT);
        this.heroSource.setItems(this.hero);
      }
    } catch (e) {
      column.failed = true;
      if (index === this.heroIndex) {
        this.error = '推荐内容没取回来，检查一下网络再试';
      }
    } finally {
      column.loading = false;
      column.version = column.version + 1;
      this.boardColumns = this.boardColumns.slice();
      // 这一榜正是歌手一栏在看的分类：歌到了就重算一遍歌手行
      if (this.artistBoardIndex() === index) {
        this.buildArtistRows();
      }
    }
  }

  // ------------------------------------------------------------ 卡面封面（只取一首）

  /**
   * 这张卡露出来了：没有封面才去补一张
   *
   * 与 `ensureBoardSongs` 分开：整榜取歌是「点进榜单 / 看三行歌」才需要的重活，
   * 精选榜和歌手分类卡只要一张图。已经有歌了就直接用 `songs[0]` 的封面，
   * 不再多发一次请求（见 boardCover）。
   */
  private ensureBoardCover(index: number): void {
    if (index < 0 || index >= this.boardColumns.length) {
      return;
    }
    const column: BoardColumn = this.boardColumns[index];
    if (column.songs.length > 0 || column.cover.length > 0) {
      return;
    }
    if (column.coverAsked || column.coverLoading) {
      return;
    }
    // 问过了（不是拿到了）：失败也记着，免得「失败 → 重建 → 再问」转成请求风暴
    column.coverAsked = true;
    void this.loadBoardCover(index);
  }

  /**
   * 只为卡面取**一首**歌，用它的封面
   *
   * 走 `getBoardSongs(..., limit = 1)`：各平台榜单接口一次回的量差很远（酷我 100、
   * 酷狗 100、QQ 300、网易 1000），为了一个卡面把整张榜拉回来正是之前卡死那个坑
   * （见 MusicList.ets 里 getBoardSongs 的说明）。失败就保持空 —— 卡面自动落成玻璃卡，
   * 不弹错、不重试。
   */
  private async loadBoardCover(index: number): Promise<void> {
    if (index < 0 || index >= this.boardColumns.length) {
      return;
    }
    const column: BoardColumn = this.boardColumns[index];
    column.coverLoading = true;
    try {
      const detail: LxListDetail = await getBoardSongs(column.board.source, column.board.bangid, 1,
        column.board.name, 1);
      if (detail.list.length > 0) {
        const song: SongItem = songFromSearch(detail.list[0], PlaySession.getInstance().quality);
        // 封面可能还要走 CoverStore 现解（酷狗榜单 img 常给空串，见 songCover）
        column.cover = this.songCover(song);
      }
    } catch (e) {
      column.cover = '';
    } finally {
      column.coverLoading = false;
      column.version = column.version + 1;
      this.boardColumns = this.boardColumns.slice();
    }
  }

  /** 卡面该用哪张封面：整榜的歌已经到了就顺手用第一首，否则用专门取回来的那张 */
  private boardCover(column: BoardColumn): string {
    if (column.songs.length > 0) {
      return this.songCover(column.songs[0]);
    }
    return column.cover;
  }

  // ------------------------------------------------------------ 精选页的排序分区

  /** 这个排序区滚到可视区了：没问过才问 */
  private ensureSortSection(index: number): void {
    if (index < 0 || index >= this.sortSections.length) {
      return;
    }
    const section: SortSection = this.sortSections[index];
    if (section.asked || section.loading) {
      return;
    }
    section.asked = true;
    void this.loadSortSection(section, 1);
  }

  private async loadSortSection(section: SortSection, page: number): Promise<void> {
    section.loading = true;
    section.failed = false;
    this.sortSections = this.sortSections.slice();
    try {
      const list: LxPlaylistItem[] = await getRecommendPlaylists(this.platform, section.sortId, page);
      section.items = list;
      section.page = page;
      section.source.setItems(section.items);
    } catch (e) {
      section.failed = true;
    } finally {
      section.loading = false;
      section.version = section.version + 1;
      this.sortSections = this.sortSections.slice();
    }
  }

  // ------------------------------------------------------------ 歌单广场

  /**
   * 取「歌单分类」那几张卡的封面
   *
   * 群反馈（2026-11-19 14:47，佐手牵佑手）：「这块怎么没有封面显示？」，
   * 接着说「就用歌单里第一首歌的封面不行吗？有个封面观感好点」。
   *
   * 分类本身只是平台的排序档位（推荐 / 最热 / 最新），接口没有给封面，所以用
   * **该档位下第一张歌单的封面**：广场第一页里现成就有 `img`，不必为了封面再去取
   * 那张歌单的详情拿第一首歌（那是「取详情」级别的代价，为一张卡面不值）。
   *
   * 逐档顺序取、每档只取第一页，取不到就留空（继续走玻璃卡，功能一点不受影响）。
   * 当前选中的那一档广场本来就要取，直接用它的第一张，不重复请求。
   */
  private async loadCatCovers(): Promise<void> {
    if (this.catCoversAsked) {
      return;
    }
    this.catCoversAsked = true;
    const platform: string = this.platform;
    const sorts: LxSortItem[] = this.sorts.slice();
    try {
      for (let i = 0; i < sorts.length; i++) {
        // 平台 / 分类在取的过程中变了就作废（换平台已经清过表并重新发起）
        if (this.platform !== platform || this.sorts.length !== sorts.length) {
          return;
        }
        if (this.catCoverOf(i).length > 0) {
          continue;
        }
        if (i === this.catIndex && this.plaza.length > 0) {
          this.setCatCover(i, this.plaza[0].img);
          continue;
        }
        try {
          const list: LxPlaylistItem[] = await getRecommendPlaylists(platform, sorts[i].id, 1);
          if (this.platform === platform && list.length > 0) {
            this.setCatCover(i, list[0].img);
          }
        } catch (e) {
          // 这一档取不到就留空：卡面退回玻璃卡，不影响点选
        }
      }
    } finally {
      this.catCoversAsked = false;
    }
  }

  private catCoverOf(index: number): string {
    if (index < 0 || index >= this.catCovers.length) {
      return '';
    }
    return this.catCovers[index];
  }

  private setCatCover(index: number, img: string): void {
    if (index < 0 || index >= this.sorts.length || img.length === 0 || this.catCoverOf(index) === img) {
      return;
    }
    const next: string[] = this.catCovers.slice();
    while (next.length <= index) {
      next.push('');
    }
    next[index] = img;
    this.catCovers = next;
  }

  /** 广场 / 漫游那块滚到可视区才取第一页 */
  private ensurePlaza(): void {
    if (this.plazaAsked) {
      return;
    }
    this.plazaAsked = true;
    void this.loadPlaza(1, false);
  }

  /** 换分类：重新取第一页 */
  private switchCat(index: number): void {
    if (index === this.catIndex) {
      return;
    }
    this.catIndex = index;
    this.plaza = [];
    this.plazaRows.setItems(this.plaza, this.gridCols());
    this.plazaPage = 0;
    this.plazaNoMore = false;
    this.plazaError = '';
    void this.loadPlaza(1, false);
  }

  /** 拉广场某一页（append = 上拉翻页） */
  private async loadPlaza(page: number, append: boolean): Promise<void> {
    if (this.plazaLoading || this.sorts.length === 0) {
      return;
    }
    this.plazaLoading = true;
    try {
      const list: LxPlaylistItem[] =
        await getRecommendPlaylists(this.platform, this.sorts[this.catIndex].id, page);
      if (list.length === 0 && append) {
        this.plazaNoMore = true;
      } else {
        this.plaza = append ? this.plaza.concat(list) : list;
        this.plazaRows.setItems(this.plaza, this.gridCols());
        this.plazaPage = page;
        this.plazaNoMore = list.length === 0;
        // 第一页顺手把这一档分类卡的封面填上（白拿的，不多打请求）
        if (!append && list.length > 0) {
          this.setCatCover(this.catIndex, list[0].img);
        }
      }
    } catch (e) {
      this.plazaError = (e as Error).message;
    } finally {
      this.plazaLoading = false;
      this.plazaLoaded = true;
    }
  }

  /** 列表滚到底：继续翻广场的下一页 */
  private loadMorePlaza(): void {
    if (this.tab === TAB_BOARD || !this.plazaAsked || this.plazaNoMore || this.plazaLoading) {
      return;
    }
    void this.loadPlaza(this.plazaPage + 1, true);
  }

  // ------------------------------------------------------------ 交互与数据辅助

  private openPlaylist(item: LxPlaylistItem): void {
    const route: OnlineRoute = {
      kind: 'playlist',
      source: item.source,
      id: item.id,
      name: item.name,
      cover: item.img,
    };
    this.onOpenOnline(route);
  }

  private openBoard(board: LxBoardItem): void {
    const route: OnlineRoute = {
      kind: 'board',
      source: board.source,
      id: board.bangid,
      name: board.name,
      cover: '',
    };
    this.onOpenOnline(route);
  }

  /**
   * 放某一栏的歌（推荐歌曲 / 排行榜每栏 / 官方榜卡片 / 新歌精选都走它）
   *
   * 队列就是已经取到的那一批（见 BOARD_SONGS_MAX）；想听整张榜点榜名进榜单页。
   */
  private playSongs(songs: SongItem[], index: number): void {
    if (index < 0 || index >= songs.length) {
      return;
    }
    void PlaySession.getInstance().setQueueAndPlay(songs, index);
  }

  /** 收藏 / 取消收藏（与在线列表页同一套：落库在 PlaySession） */
  private toggleFavorite(song: SongItem): void {
    const session = PlaySession.getInstance();
    if (session.isFavorite(song.id)) {
      session.removeFavorite(song.id);
      return;
    }
    session.addFavorite(song);
  }

  /** 歌行要画的那张封面：有就给、没有就排进懒解析队列（解好后 coverVersion 变了会重画） */
  private songCover(song: SongItem): string {
    return CoverStore.getInstance().coverFor(song.musicInfoJson, song.coverUrl);
  }

  /** 卡片角标 / 副标题：优先播放量，没有就作者 */
  private cardMeta(item: LxPlaylistItem): string {
    if (item.playCount.length > 0) {
      return item.playCount;
    }
    return item.author;
  }

  /** 整页有没有拿到过内容（判空态用：分区空壳也照样在数组里） */
  private hasContent(): boolean {
    return this.hero.length > 0 || this.plaza.length > 0;
  }

  /** 网格几列（手机上恒为 2 列，与华为音乐那套一致；宽屏多列） */
  private gridCols(): number {
    if (this.windowWidth >= 840) {
      return 4;
    }
    if (this.windowWidth >= 600) {
      return 3;
    }
    return 2;
  }

  private contentWidth(): number {
    return this.windowWidth > 0 ? this.windowWidth : 360;
  }

  /** 网格里一张卡的宽度（一屏 cols 张，减掉左右留白与卡间距） */
  private gridCardWidth(): number {
    const cols: number = this.gridCols();
    const usable: number = this.contentWidth() - PAGE_PAD * 2 - CARD_GAP * (cols - 1);
    return Math.max(120, usable / cols);
  }

  /** 这一行最后一张卡不给右间距（列间距靠 margin 撑） */
  private laneGap(index: number): number {
    return index % this.gridCols() === this.gridCols() - 1 ? 0 : CARD_GAP;
  }

  /** 顶部推荐歌曲那张大卡的宽度（一屏露两张半） */
  private heroCardWidth(): number {
    const wanted: number = this.contentWidth() * 0.56;
    return Math.max(150, Math.min(240, wanted));
  }

  /** 精选页排序区一屏几张卡（手机上 3 张，与华为那排一致） */
  private sortCards(): number {
    if (this.windowWidth >= 840) {
      return 5;
    }
    if (this.windowWidth >= 600) {
      return 4;
    }
    return 3;
  }

  private sortCardWidth(): number {
    const n: number = this.sortCards();
    const usable: number = this.contentWidth() - PAGE_PAD * 2 - CARD_GAP * (n - 1);
    return Math.max(96, usable / n);
  }

  /** 精选页排行榜一栏的宽度（一屏露两张） */
  private topListWidth(): number {
    const usable: number = this.contentWidth() - PAGE_PAD * 2 - CARD_GAP;
    return Math.max(150, usable / 2);
  }

  /** 分区标题右边那颗「更多」点了 */
  private runSectionMore(kind: string, index: number): void {
    if (kind === MORE_SORT) {
      if (index >= 0 && index < this.sortSections.length) {
        const section: SortSection = this.sortSections[index];
        this.onOpenSquare(this.platform, section.sortId, section.title);
      }
      return;
    }
    if (kind === MORE_NEW_SONG) {
      const column: BoardColumn | null = this.newSongColumn();
      if (column !== null) {
        this.openBoard(column.board);
      }
      return;
    }
    if (kind === MORE_ROAM && this.sorts.length > 0) {
      this.onOpenSquare(this.platform, this.sorts[this.catIndex].id, this.sorts[this.catIndex].name);
    }
  }

  // ------------------------------------------------------------ 构建

  /** 骨架块：还没加载出来时占位的一小块灰（尺寸照真卡给，数据到了不跳） */
  @Builder
  bone(width: Length, height: number | string, radius: number) {
    Column()
      .width(width)
      .height(height)
      .borderRadius(radius)
      .backgroundColor(C_FILL_SOFT_STRONG)
  }

  /** 区标题（照截图：纯粗体一行，前面不带小色块） */
  @Builder
  sectionTitle(text: string, top: number) {
    Text(text)
      .fontSize(F_SECTION)
      .fontWeight(FontWeight.Bold)
      .fontColor(C_TEXT)
      .width('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: top, bottom: 10 })
  }

  /** 区标题 + 右侧「更多 ›」（进了这一区的全部内容页） */
  @Builder
  sectionTitleMore(text: string, top: number, kind: string, index: number) {
    Row({ space: 6 }) {
      Text(text)
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Row({ space: 1 }) {
        Text('更多')
          .fontSize(SUB_SIZE)
          .fontColor(C_TEXT_SUB)
        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 12, color: C_CHEVRON })
      }
      .height(26)
      .padding({ left: 4, right: 2 })
      .onClick(() => {
        this.runSectionMore(kind, index);
      })
      .accessibilityText(`${text}，更多`)
      .accessibilityLevel('yes')
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: top, bottom: 10 })
  }

  // -------------------------------------------------- 顶部推荐歌曲

  /**
   * 首块之前那段留白的高度：让出透明标题栏 + 状态栏
   *
   * 为什么要一个**真实的占位行**，而不是 List 的 `contentStartOffset`：那个属性只在
   * 首次布局时取一次值，而 `topInset` 是壳层异步量出来的（pages/Index.ets 的
   * readAvoidArea 排在一个 500ms 的 setTimeout 里，首帧还是 0）。冷启动时 List 就按
   * `0 + 6` 排好了，等 topInset 到齐也不会重排 —— 整页内容钉在标题栏下面，看起来就是
   * 「推荐」大标题与「推荐歌曲」叠在一起（实测 s0 / s9 / s23 三张跨 9 分钟都是错位，
   * 重启偶尔正常）。换成真实节点后，高度一变就重排，首帧与后续帧必然一致。
   *
   * 减掉 ROW_GAP：List 的 `space` 会在占位行与第一块之间再加一段，不减就比原设计
   * 多出 18vp 的空白（视觉会整体下移）。
   */
  private heroTopSpacer(): number {
    const height: number = this.topInset + 6 - ROW_GAP;
    return height > 0 ? height : 0;
  }

  /**
   * 推荐歌曲那一行
   *
   * 可右滑（横向 List，一屏露两张半），每张：封面铺满 + 底部压暗 + 左下歌名 / 歌手
   * + 右下播放钮。点卡片就从这一首放起（队列就是这条里的歌）。
   */
  @Builder
  heroRow() {
    Column() {
      this.sectionTitle('推荐歌曲', 6)
      if (this.hero.length === 0) {
        Row({ space: CARD_GAP }) {
          ForEach(boneIndexes(2), () => {
            this.bone(this.heroCardWidth(), this.heroCardWidth(), 14)
          }, (i: number) => `herobone_${i}`)
        }
        .width('100%')
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      } else {
        List({ space: CARD_GAP }) {
          LazyForEach(this.heroSource, (song: SongItem, index: number) => {
            ListItem() {
              this.heroCard(song, index)
            }
          }, (song: SongItem, index: number) => `hero_${index}_${song.id}`)
        }
        .scrollBar(BarState.Off)
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(this.heroCardWidth())
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
    }
    .width('100%')
  }

  @Builder
  heroCard(song: SongItem, index: number) {
    Stack({ alignContent: Alignment.BottomStart }) {
      CoverArt({
        url: this.songCover(song),
        name: song.name,
        art: false,
        boxSize: this.heroCardWidth(),
        radius: 0,
      })
        .width('100%')
        .height('100%')

      Column()
        .width('100%')
        .height('58%')
        .linearGradient({ angle: 0, colors: [['#00000000', 0.0], ['#99000000', 1.0]] })

      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Text(song.name)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(song.singer)
            .fontSize(CARD_META_SIZE)
            .fontColor('#CCFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.playBadge(32)
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 11 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width(this.heroCardWidth())
    .height(this.heroCardWidth())
    .borderRadius(14)
    .clip(true)
    .onClick(() => {
      this.playSongs(this.hero, index);
    })
    .accessibilityText(`${song.name}，${song.singer}，播放`)
    .accessibilityLevel('yes')
  }

  /**
   * 播放圆钮（白底深三角）
   *
   * 圆底一律用 Column + 圆角画（`Circle().fill(资源色)` 取不到资源会退回黑色，
   * 同 SettingsView / AboutView 里那条）。
   */
  @Builder
  playBadge(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor('#E6FFFFFF')
      IconGlyph({ symbol: I_PLAY, iconSize: size * 0.52, color: '#1A1A1A' })
    }
    .width(size)
    .height(size)
  }

  /** 封面上的小播放钮（深底白三角） */
  @Builder
  playBadgeOnCover(size: number) {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(size)
        .height(size)
        .borderRadius(size / 2)
        .backgroundColor('#66000000')
      IconGlyph({ symbol: I_PLAY, iconSize: size * 0.56, color: '#FFFFFF' })
    }
    .width(size)
    .height(size)
  }

  /**
   * 封面 + 压在**左下角**的播放钮（官方榜卡片的封面用）
   *
   * 摆放用「再套一层铺满的 Stack、靠它的 alignContent(BottomStart) 定位」，
   * **不要用子组件的 `.align(...)`** —— 实测不生效，钮会落在卡片正中压住文字
   * （2026-10-13 实机截图反馈的就是这个）。
   */
  @Builder
  coverWithPlay(coverUrl: string, title: string, size: number, badge: number, songs: SongItem[]) {
    Stack({ alignContent: Alignment.Center }) {
      CoverArt({
        url: coverUrl,
        name: title,
        art: coverUrl.length === 0,
        boxSize: size,
        radius: 8,
      })
        .width(size)
        .height(size)
      Stack({ alignContent: Alignment.BottomStart }) {
        if (songs.length > 0) {
          this.playBadgeOnCover(badge)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 5, bottom: 5 })
    }
    .width(size)
    .height(size)
  }

  // -------------------------------------------------- 分类胶囊

  /**
   * 分类胶囊行
   *
   * 四颗胶囊（精选 / 歌单 / 歌手 / 排行榜）在 360vp 的手机上正好卡着边，
   * 所以这里**用横向 List 而不是 Row**：窄屏或大字号设置下右滑就能看全，不会顶出去。
   */
  @Builder
  chipRow() {
    List({ space: 10 }) {
      ListItem() {
        this.chip(TAB_FEATURED, '精选', I_STAR)
      }
      ListItem() {
        this.chip(TAB_PLAYLIST, '歌单', I_PLAYLIST)
      }
      ListItem() {
        this.chip(TAB_ARTIST, '歌手', I_PERSON)
      }
      ListItem() {
        this.chip(TAB_BOARD, '排行榜', I_TROPHY)
      }
    }
    .scrollBar(BarState.Off)
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(40)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }

  @Builder
  chip(key: string, label: string, icon: Resource) {
    Row({ space: 5 }) {
      IconGlyph({
        symbol: icon,
        iconSize: 14,
        color: this.tab === key ? C_BG : C_TEXT_SUB,
      })
      Text(label)
        .fontSize(13.5)
        .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === key ? C_BG : C_TEXT_SUB)
    }
    .height(32)
    // 上下各 4：与胶囊行的高度（40）对上，四颗胶囊在横向 List 里垂直居中
    .margin({ top: 4, bottom: 4 })
    .padding({ left: 12, right: 12 })
    .borderRadius(16)
    // 选中那颗是深色实心胶囊（照截图），没选中的是浅灰底
    .backgroundColor(this.tab === key ? C_TEXT : C_FILL_SOFT)
    .onClick(() => {
      this.tab = key;
    })
    .accessibilityText(`${label}${this.tab === key ? '，已选中' : ''}`)
    .accessibilityLevel('yes')
  }

  // -------------------------------------------------- ① 精选：分区信息流

  /** 精选页一个排序区：标题 + 更多 + 三列横滑卡 */
  @Builder
  sortSectionBlock(section: SortSection, index: number) {
    Column() {
      this.sectionTitleMore(section.title, index === 0 ? 6 : 4, MORE_SORT, index)

      if (section.items.length === 0) {
        // 没取过 / 正在取：摆一排灰卡（尺寸与真卡一致）；失败 / 确实为空才给一句话
        if (section.asked && section.failed) {
          Text('这一档暂时取不到')
            .fontSize(SUB_SIZE)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 2, bottom: 12 })
        } else if (section.asked && !section.loading) {
          Text('这个平台暂时没有内容')
            .fontSize(SUB_SIZE)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 2, bottom: 12 })
        } else {
          Row({ space: CARD_GAP }) {
            ForEach(boneIndexes(this.sortCards()), () => {
              Column({ space: 6 }) {
                this.bone(this.sortCardWidth(), this.sortCardWidth(), 10)
                this.bone(this.sortCardWidth(), 16, 4)
                this.bone(this.sortCardWidth() * 0.5, 12, 4)
              }
              .width(this.sortCardWidth())
              .alignItems(HorizontalAlign.Start)
            }, (i: number) => `sortbone_${i}`)
          }
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD })
        }
      } else {
        List({ space: CARD_GAP }) {
          LazyForEach(section.source, (item: LxPlaylistItem) => {
            ListItem() {
              this.sortCard(item)
            }
          }, (item: LxPlaylistItem) => item.id)
        }
        .scrollBar(BarState.Off)
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(this.sortCardWidth() + 44)
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
    }
    .width('100%')
    /**
     * 这一区滚进可视区才去取它那一页（这就是「只加载屏幕上正在显示的」）：
     * 用 onVisibleAreaChange 而不是 onAppear —— 外层 List 是 ForEach，开页时
     * 每一块都会回调一次，那就等于没有懒加载。
     */
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureSortSection(index);
      }
    })
  }

  /** 精选页排序区里的一张歌单卡：封面（右下压播放量）+ 两行歌名 */
  @Builder
  sortCard(item: LxPlaylistItem) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        CoverArt({
          url: item.img,
          name: item.name,
          art: item.img.length === 0,
          boxSize: this.sortCardWidth(),
          radius: 10,
        })
          .width(this.sortCardWidth())
          .height(this.sortCardWidth())

        if (this.cardMeta(item).length > 0) {
          Text(this.cardMeta(item))
            .fontSize(10)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor('#66000000')
            .margin({ right: 6, bottom: 6 })
        }
      }
      .width(this.sortCardWidth())
      .height(this.sortCardWidth())

      Text(item.name)
        .fontSize(CARD_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .lineHeight(16)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width(this.sortCardWidth())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openPlaylist(item);
    })
    .accessibilityText(`${item.name}，歌单，${this.cardMeta(item)}`)
    .accessibilityLevel('yes')
  }

  /**
   * 精选页的「排行榜」：多张榜一横排，**可自由右滑**
   *
   * 每张榜**自己懒加载**（横滑到可视区才取它的歌，见 ensureBoardSongs）：一上来就把
   * 十几张榜的歌全取回来（每张最多上千首）正是之前卡死那个坑。
   */
  @Builder
  topListSection() {
    Column() {
      this.sectionTitle('排行榜', 4)
      if (this.boardColumns.length === 0) {
        Row({ space: CARD_GAP }) {
          this.topListColumnBone()
          this.topListColumnBone()
        }
        .width('100%')
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      } else {
        List({ space: CARD_GAP }) {
          ForEach(this.topListColumns(), (column: BoardColumn, index: number) => {
            ListItem() {
              this.topListColumn(column, index)
            }
          }, (column: BoardColumn) => `top_${column.board.bangid}_${column.version}`)
        }
        .scrollBar(BarState.Off)
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(TOP_LIST_HEIGHT)
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
    }
    .width('100%')
  }

  /** 排行榜一栏：榜名 + 播放钮 + 三行 + 查看完整榜单 */
  @Builder
  topListColumn(column: BoardColumn, index: number) {
    Column() {
      Row({ space: 6 }) {
        Text(column.board.name)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick(() => {
            this.openBoard(column.board);
          })
          .accessibilityText(`${column.board.name}，查看完整榜单`)
          .accessibilityLevel('yes')
        if (column.songs.length > 0) {
          Stack({ alignContent: Alignment.Center }) {
            Column().width(24).height(24).borderRadius(12).backgroundColor(C_RED)
            IconGlyph({ symbol: I_PLAY, iconSize: 13, color: '#FFFFFF' })
          }
          .width(24)
          .height(24)
          .onClick(() => {
            this.playSongs(column.songs, 0);
          })
          .accessibilityText(`播放${column.board.name}`)
          .accessibilityLevel('yes')
        }
      }
      .width('100%')

      Column() {
        if (column.songs.length === 0) {
          Text(column.failed ? '榜单暂时取不到' : '正在加载…')
            .fontSize(CARD_META_SIZE)
            .fontColor(C_TEXT_WEAK)
            .padding({ top: 8, bottom: 4 })
        } else {
          ForEach(column.songs.slice(0, OFFICIAL_SONGS), (song: SongItem, i: number) => {
            Row({ space: 7 }) {
              Text(`${i + 1}`)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(i === 0 ? C_RED : C_TEXT)
                .width(13)
                .textAlign(TextAlign.Center)
              Text(song.name)
                .fontSize(CARD_TITLE_SIZE)
                .fontColor(C_TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.playSongs(column.songs, i);
            })
            .accessibilityText(`${song.name}，${song.singer}`)
            .accessibilityLevel('yes')
          }, (song: SongItem, i: number) => `${column.board.bangid}_${column.version}_${i}_${song.id}`)

          Text('查看完整榜单')
            .fontSize(CARD_META_SIZE)
            .fontColor(C_RED)
            .padding({ top: 4, bottom: 2 })
            .onClick(() => {
              this.openBoard(column.board);
            })
            .accessibilityText(`${column.board.name}，查看完整榜单`)
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
    }
    .width(this.topListWidth())
    .height(TOP_LIST_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(14)
    .backgroundColor(C_CARD)
    /**
     * 每张榜自己懒加载：横滑到它才取歌。`onVisibleAreaChange` 的可见性是相对窗口算的，
     * 横向滚出屏幕的卡片同样会回调，所以横滑列表也能用它做懒加载。
     */
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureBoardSongs(index);
      }
    })
  }

  /** 排行榜一栏的骨架 */
  @Builder
  topListColumnBone() {
    Column() {
      this.bone(76, 15, 4)
      Column({ space: 12 }) {
        ForEach(boneIndexes(OFFICIAL_SONGS), () => {
          this.bone('100%', 13, 4)
        }, (i: number) => `topbone_${i}`)
      }
      .width('100%')
      .padding({ top: 12 })
    }
    .width(this.topListWidth())
    .height(TOP_LIST_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(14)
    .backgroundColor(C_CARD)
  }

  /** 精选页的「新歌精选」：几行歌（封面 + 播放 + 歌名/歌手 + 收藏），更多进新歌榜 */
  @Builder
  newSongSection() {
    Column() {
      this.sectionTitleMore('新歌精选', 4, MORE_NEW_SONG, -1)

      if (this.newSongIndex() < 0) {
        Text('这个平台没有新歌榜')
          .fontSize(SUB_SIZE)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 2, bottom: 12 })
      } else if (this.newSongList().length === 0) {
        if (this.newSongFailed()) {
          Text('榜单暂时取不到')
            .fontSize(SUB_SIZE)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 2, bottom: 12 })
        } else {
          // 还没到货：摆骨架（不是「没有新歌榜」——之前漏了触发，
          // 从排行榜那一排快速滑过去就会误报，见下面 onVisibleAreaChange）
          ForEach(boneIndexes(NEW_SONGS), () => {
            Row({ space: 12 }) {
              this.bone(48, 48, 8)
              Column({ space: 8 }) {
                this.bone('70%', 13, 4)
                this.bone('40%', 11, 4)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 9, bottom: 9 })
          }, (i: number) => `newsongbone_${i}`)
        }
      } else {
        ForEach(this.newSongList(), (song: SongItem, index: number) => {
          this.newSongRow(song, index)
        }, (song: SongItem, index: number) => `newsong_${index}_${song.id}`)
      }
    }
    .width('100%')
    // 这一块自己也要触发新歌榜的取数：滚得快时排行榜那一排可能没进过可视区
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureBoardSongs(this.newSongIndex());
      }
    })
  }

  @Builder
  newSongRow(song: SongItem, index: number) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        CoverArt({
          url: this.songCover(song),
          name: song.name,
          art: false,
          boxSize: 48,
          radius: 8,
        })
          .width(48)
          .height(48)
        Stack({ alignContent: Alignment.Center }) {
          Column().width(22).height(22).borderRadius(11).backgroundColor('#66000000')
          IconGlyph({ symbol: I_PLAY, iconSize: 12, color: '#FFFFFF' })
        }
        .width(22)
        .height(22)
      }
      .width(48)
      .height(48)
      .onClick(() => {
        this.playSongs(this.newSongList(), index);
      })
      .accessibilityText(`播放${song.name}`)
      .accessibilityLevel('yes')

      Column({ space: 3 }) {
        Text(song.name)
          .fontSize(14.5)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(song.singer)
          .fontSize(CARD_META_SIZE)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      FavoriteHeart({
        songId: song.id,
        iconSize: 22,
        colorOn: C_RED,
        colorOff: C_TEXT_WEAK,
        onToggle: () => {
          this.toggleFavorite(song);
        },
      })
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 8, bottom: 8 })
  }

  /** 精选页「歌单·漫游」的标题（内容得直接挂在 List 上才是懒的，见 featuredBody） */
  @Builder
  roamTitle() {
    Column() {
      this.sectionTitleMore('歌单·漫游', 4, MORE_ROAM, -1)
    }
    .width('100%')
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensurePlaza();
      }
    })
  }

  // -------------------------------------------------- ①' 歌手：分类 + 热门歌手

  /** 歌手一栏的标题 + 分类卡（封面卡 / 玻璃卡，点哪张换哪一档） */
  @Builder
  artistHead() {
    Column() {
      this.sectionTitle('歌手分类', 4)

      List({ space: CARD_GAP }) {
        ForEach(this.artistCats, (at: number, index: number) => {
          ListItem() {
            this.artistCatCard(index)
          }
        }, (at: number, index: number) => this.artistCatKey(index))
      }
      .scrollBar(BarState.Off)
      .listDirection(Axis.Horizontal)
      .width('100%')
      .height(120)
      .padding({ left: PAGE_PAD, right: PAGE_PAD })

      this.sectionTitle('热门歌手', 8)
    }
    .width('100%')
    // 这一栏露出来了就先把它那一榜的歌取回来（歌手是从歌里去重出来的）
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureArtistRows();
      }
    })
  }

  /**
   * 一张歌手分类卡（2026-10-21 重做：纯色渐变块 → 封面卡 / 玻璃卡，见文件头「卡片形态」）
   *
   * 卡面用该分类对应榜单的第一首封面，走 `limit=1` 的轻请求（见 ensureBoardCover）；
   * 封面还没回来 / 取不到就自动落成主题玻璃卡，版面不跳，也不会为了一个封面拉整张榜。
   */
  @Builder
  artistCatCard(index: number) {
    Column() {
      TileCard({
        title: this.artistCatName(index),
        coverUrl: this.artistCatCover(index),
        cardWidth: 112,
        cardHeight: 112,
        radius: 12,
        selected: this.artistCatIndex === index,
        showPlay: false,
        onTap: () => {
          this.switchArtistCat(index);
        },
      })
    }
    // 这一张露出来了才去补封面（横向 List 滚出屏幕的卡同样会回调，见 topListColumn 那段说明）
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureBoardCover(this.artistCatBoardAt(index));
      }
    })
  }

  /** 一位歌手一行：圆头像 + 名字（+ 别名）+ 歌曲数胶囊 + 箭头 */
  @Builder
  artistRowView(row: ArtistRow, index: number) {
    Row({ space: 14 }) {
      CoverArt({
        url: row.artist !== null ? row.artist.picUrl : '',
        name: row.name,
        art: false,
        boxSize: ARTIST_AVATAR,
        radius: ARTIST_AVATAR / 2,
      })
        .width(ARTIST_AVATAR)
        .height(ARTIST_AVATAR)

      Column({ space: 3 }) {
        Text(row.name)
          .fontSize(15)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (row.artist !== null && row.artist.alias.length > 0) {
          Text(row.artist.alias)
            .fontSize(CARD_META_SIZE)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.artistPill(row).length > 0) {
        Text(this.artistPill(row))
          .fontSize(CARD_META_SIZE)
          .fontColor(C_TEXT_SUB)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(14)
          .backgroundColor(C_FILL_SOFT)
      }
      IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 14, color: C_CHEVRON })
    }
    .width('100%')
    .height(70)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .onClick(() => {
      this.openArtistRow(row);
    })
    .accessibilityText(`${row.name}，打开歌手页`)
    .accessibilityLevel('yes')
    // 这一行滚进可视区才去认人（头像 / 别名 / 歌曲数都靠它；认过就落盘）
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureArtistRow(index);
      }
    })
  }

  /** 歌手行的骨架 */
  @Builder
  artistBone() {
    ForEach(boneIndexes(ARTIST_BONE_ROWS), () => {
      Row({ space: 14 }) {
        this.bone(ARTIST_AVATAR, ARTIST_AVATAR, ARTIST_AVATAR / 2)
        Column({ space: 8 }) {
          this.bone('45%', 14, 4)
          this.bone('30%', 11, 4)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(70)
      .padding({ left: PAGE_PAD, right: PAGE_PAD })
    }, (i: number) => `artistbone_${i}`)
  }

  // -------------------------------------------------- ② 歌单：分类 + 广场

  /** 歌单分类（一横排卡，点哪张下面广场就是哪一档） */
  @Builder
  catRow() {
    Column() {
      this.sectionTitle('歌单分类', 4)
      List({ space: CARD_GAP }) {
        ForEach(this.sorts, (sort: LxSortItem, index: number) => {
          ListItem() {
            this.catCard(sort, index)
          }
          // 选中态拼进 key：ForEach 对 key 没变的条目不会重跑生成器，只靠 @Prop 传不过去，
          // 点哪张都不出红边（见 ListenView 分类卡那条注释）。
          // 封面同样要拼进去：封面是**后到**的（loadCatCovers），key 不变就永远停在玻璃卡上。
        }, (sort: LxSortItem, index: number) => {
          const cover: string = this.catCoverOf(index);
          const mark: string = cover.length > 0 ? cover.substring(Math.max(0, cover.length - 24)) : 'none';
          return `cat_${index}_${sort.id}_${this.catIndex === index ? 'on' : 'off'}_${mark}`;
        })
      }
      .scrollBar(BarState.Off)
      .listDirection(Axis.Horizontal)
      .width('100%')
      .height(120)
      .padding({ left: PAGE_PAD, right: PAGE_PAD })
    }
    .width('100%')
  }

  /**
   * 一张歌单分类卡（2026-10-21 重做：纯色渐变块 → 主题玻璃卡，见文件头「卡片形态」）
   *
   * 平台的「排序」只是纯文字档位，本身没有封面：取到该档位下第一张歌单的封面铺上，
   * 还没取到 / 取不到时继续走玻璃卡（`coverUrl: ''`，见 loadCatCovers）。
   */
  @Builder
  catCard(sort: LxSortItem, index: number) {
    TileCard({
      title: sort.name,
      coverUrl: this.catCoverOf(index),
      cardWidth: 112,
      cardHeight: 112,
      radius: 12,
      selected: this.catIndex === index,
      showPlay: false,
      onTap: () => {
        this.switchCat(index);
      },
    })
  }

  // -------------------------------------------------- ③ 排行榜：官方榜 + 精选榜

  /** 官方榜那一块（标题 + 每张榜一张白卡 + 精选榜标题） */
  @Builder
  officialSection() {
    Column() {
      this.sectionTitle('官方榜', 4)

      if (this.boardColumns.length === 0) {
        ForEach(boneIndexes(OFFICIAL_COUNT), () => {
          this.officialCardBone()
        }, (i: number) => `offbone_${i}`)
      } else {
        ForEach(this.officialColumns(), (column: BoardColumn, index: number) => {
          this.officialCard(column, index)
        }, (column: BoardColumn) => `off_${column.board.bangid}_${column.version}`)
      }

      this.sectionTitle('精选榜', 6)
    }
    .width('100%')
  }

  /** 官方榜一张卡：榜名 + 封面（左下角播放钮）+ 三行歌 */
  @Builder
  officialCard(column: BoardColumn, index: number) {
    Column() {
      Row({ space: 8 }) {
        Text(column.board.name)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 13, color: C_CHEVRON })
      }
      .width('100%')
      .onClick(() => {
        this.openBoard(column.board);
      })
      .accessibilityText(`${column.board.name}，查看完整榜单`)
      .accessibilityLevel('yes')

      Row({ space: 12 }) {
        Column() {
          this.coverWithPlay(
            column.songs.length > 0 ? this.songCover(column.songs[0]) : '',
            column.board.name,
            64,
            22,
            column.songs,
          )
        }
        .onClick(() => {
          this.playSongs(column.songs, 0);
        })
        .accessibilityText(`播放${column.board.name}`)
        .accessibilityLevel('yes')

        Column() {
          if (column.songs.length === 0) {
            Text(column.failed ? '榜单暂时取不到' : '正在加载…')
              .fontSize(CARD_META_SIZE)
              .fontColor(C_TEXT_WEAK)
              .padding({ top: 6, bottom: 6 })
          } else {
            ForEach(column.songs.slice(0, OFFICIAL_SONGS), (song: SongItem, i: number) => {
              Row({ space: 8 }) {
                Text(`${i + 1}`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(i === 0 ? C_RED : C_TEXT)
                  .width(14)
                  .textAlign(TextAlign.Center)
                Text(song.name)
                  .fontSize(CARD_TITLE_SIZE)
                  .fontColor(C_TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(song.singer)
                  .fontSize(CARD_META_SIZE)
                  .fontColor(C_TEXT_WEAK)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 96 })
              }
              .width('100%')
              .padding({ top: 7, bottom: 7 })
              .onClick(() => {
                this.playSongs(column.songs, i);
              })
              .accessibilityText(`${song.name}，${song.singer}`)
              .accessibilityLevel('yes')
            }, (song: SongItem, i: number) =>
              `offrow_${column.board.bangid}_${column.version}_${i}_${song.id}`)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(C_CARD)
    .margin({ left: PAGE_PAD, right: PAGE_PAD, bottom: 12 })
    // 这张榜滚进可视区才取它的歌（与精选页那排共用一个闸，见 ensureBoardSongs）
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureBoardSongs(index);
      }
    })
  }

  /** 官方榜卡片的骨架 */
  @Builder
  officialCardBone() {
    Column() {
      this.bone(96, 16, 4)
      Row({ space: 12 }) {
        this.bone(64, 64, 8)
        Column({ space: 9 }) {
          this.bone('100%', 14, 4)
          this.bone('100%', 14, 4)
          this.bone('100%', 14, 4)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ top: 12 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(C_CARD)
    .margin({ left: PAGE_PAD, right: PAGE_PAD, bottom: 12 })
  }

  /**
   * 精选榜一张封面卡（2026-10-21 重做：纯色渐变块 → 封面卡）
   *
   * 卡面用这张榜首的第一首封面，走 `limit=1` 的轻请求（见 ensureBoardCover）；
   * 没封面 / 还没回来就自动落成主题玻璃卡，所以卡面永远不会是空块。
   * 播放钮由 TileCard 收在右下角跟着文字走，不再像旧渐变卡那样单独用 Stack 定位。
   */
  @Builder
  hotBoardTile(at: number, index: number) {
    Column() {
      TileCard({
        title: this.boardColumns[at].board.name,
        coverUrl: this.boardCover(this.boardColumns[at]),
        cardWidth: this.gridCardWidth(),
        cardHeight: this.gridCardWidth(),
        radius: 14,
        selected: false,
        showPlay: this.boardCover(this.boardColumns[at]).length > 0,
        onTap: () => {
          this.openBoard(this.boardColumns[at].board);
        },
      })
    }
    // 卡间距挂在外层（TileCard 自带宽度）；这一张露出来了才去补封面
    .margin({ right: this.laneGap(index) })
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensureBoardCover(at);
      }
    })
  }

  // -------------------------------------------------- 歌单广场（两列网格）

  /** 广场骨架：两列几行灰卡 */
  @Builder
  plazaBone() {
    Column({ space: ROW_GAP }) {
      ForEach(boneIndexes(PLAZA_BONE_ROWS), () => {
        Row({ space: CARD_GAP }) {
          ForEach(boneIndexes(this.gridCols()), () => {
            Column({ space: 8 }) {
              this.bone('100%', this.gridCardWidth(), 12)
              this.bone('100%', 16, 4)
              this.bone('65%', 12, 4)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }, (i: number) => `plazabone_${i}`)
        }
        .width('100%')
      }, (i: number) => `plazarowbone_${i}`)
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }

  /** 广场一行（两列卡；不足一行时补空位，否则一张孤卡会被撑成整行宽） */
  @Builder
  plazaRow(row: PlaylistRow) {
    Row({ space: CARD_GAP }) {
      ForEach(row.items, (item: LxPlaylistItem) => {
        PlaylistCard({
          title: item.name,
          coverUrl: item.img,
          meta: this.cardMeta(item),
          coverBox: this.gridCardWidth(),
          onOpen: () => {
            this.openPlaylist(item);
          },
        })
      }, (item: LxPlaylistItem) => `${row.version}_${item.id}`)
      ForEach(boneIndexes(this.gridCols() - row.items.length), () => {
        Column().layoutWeight(1)
      }, (i: number) => `plazagap_${i}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }

  // -------------------------------------------------- 各胶囊的正文

  // -------------------------------------------------- 网易私人推荐

  /**
   * 网易云登录后的「私人推荐」
   *
   * 位置在分类胶囊下面、精选正文第一块：私人推荐 / 私人雷达这类歌单只有登录账号后
   * 网易才会给（匿名接口直接回 301），和平台公开榜单不是一个数据口径，所以单独一块，
   * 不并进「歌单分类 / 歌单广场」。未登录或推荐来源不是网易时整块不渲染。
   */
  @Builder
  wyPrivateSection() {
    Column() {
      this.sectionTitle('私人推荐', 4)

      if (this.wyRec.length === 0) {
        if (this.wyRecFailed) {
          Text('私人推荐暂时取不到（登录可能已过期，去「设置 - 登录音乐」重新登录试试）')
            .fontSize(CARD_META_SIZE)
            .fontColor(C_TEXT_WEAK)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: 12 })
        } else {
          Row({ space: CARD_GAP }) {
            ForEach(boneIndexes(this.gridCols()), () => {
              this.bone(this.gridCardWidth(), this.gridCardWidth(), 12)
            }, (i: number) => `wyrecbone_${i}`)
          }
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD })
        }
      } else {
        List({ space: CARD_GAP }) {
          ForEach(this.wyRec, (item: LxPlaylistItem) => {
            ListItem() {
              PlaylistCard({
                title: item.name,
                coverUrl: item.img,
                meta: this.cardMeta(item),
                coverBox: this.gridCardWidth(),
                onOpen: () => {
                  this.openPlaylist(item);
                },
              })
            }
            .width(this.gridCardWidth())
          }, (item: LxPlaylistItem) => `wyrec_${item.id}`)
        }
        .scrollBar(BarState.Off)
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(this.gridCardWidth() + 50)
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
    }
    .width('100%')
  }

  /** ① 精选：分区信息流 */
  @Builder
  featuredBody() {
    // 每个排序一区
    ForEach(this.sortSections, (section: SortSection, index: number) => {
      ListItem() {
        this.sortSectionBlock(section, index)
      }
    }, (section: SortSection) => `sort_${section.sortId}_${section.version}`)

    // 排行榜（多张榜横滑，各自懒加载）
    ListItem() {
      this.topListSection()
    }

    // 新歌精选（更多进新歌榜）
    ListItem() {
      this.newSongSection()
    }

    // 歌单·漫游（两列大卡；与歌单页的广场同一批数据，不额外请求）
    ListItem() {
      this.roamTitle()
    }
    if (this.plaza.length === 0) {
      ListItem() {
        this.plazaBone()
      }
    } else {
      LazyForEach(this.plazaRows, (row: PlaylistRow) => {
        ListItem() {
          this.plazaRow(row)
        }
      }, (row: PlaylistRow, index: number) => `roamrow_${index}_${row.version}`)
    }
  }

  /** ①' 歌手：分类 + 热门歌手 */
  @Builder
  artistBody() {
    ListItem() {
      this.artistHead()
    }

    if (this.artistRows.length === 0) {
      ListItem() {
        if (this.artistBoardIndex() < 0) {
          Text('这个平台没有歌手榜')
            .fontSize(SUB_SIZE)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 2, bottom: 12 })
        } else {
          this.artistBone()
        }
      }
    } else {
      // 一行一个 ListItem：外层 List 只管建可视区那几行（头像是网络图，不能一次开一屏）
      ForEach(this.artistRows, (row: ArtistRow, index: number) => {
        ListItem() {
          this.artistRowView(row, index)
        }
      }, (row: ArtistRow, index: number) => `artist_${index}_${row.name}_${row.version}`)
    }
  }

  /** ② 歌单：分类 + 广场 */
  @Builder
  playlistBody() {
    ListItem() {
      this.catRow()
    }

    ListItem() {
      this.sectionTitle('歌单广场', 4)
    }
    .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
      if (isVisible) {
        this.ensurePlaza();
      }
    })

    if (this.plaza.length === 0) {
      ListItem() {
        if (this.plazaLoaded && this.plazaError.length > 0) {
          Text(this.plazaError)
            .fontSize(13.5)
            .fontColor(C_TEXT_WEAK)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 6, bottom: 10 })
        } else {
          this.plazaBone()
        }
      }
    } else {
      LazyForEach(this.plazaRows, (row: PlaylistRow) => {
        ListItem() {
          this.plazaRow(row)
        }
      }, (row: PlaylistRow, index: number) => `plazarow_${index}_${row.version}`)
    }
  }

  /** ③ 排行榜：官方榜卡片 + 精选榜封面卡 */
  @Builder
  boardBody() {
    ListItem() {
      this.officialSection()
    }

    ForEach(this.hotRowIndexes(), (row: number) => {
      ListItem() {
        Row({ space: CARD_GAP }) {
          ForEach(this.hotBoardsOfRow(row), (at: number, index: number) => {
            this.hotBoardTile(at, index)
          }, (at: number) => this.hotTileKey(at))
        }
        .width('100%')
        .padding({ left: PAGE_PAD, right: PAGE_PAD })
      }
    }, (row: number) => this.hotRowKey(row))
  }

  // -------------------------------------------------- 尾巴

  /** 空态 / 失败态 / 翻页提示 + 底部让位 */
  @Builder
  tailBlock() {
    Column() {
      if (!this.hasContent()) {
        Column({ space: 10 }) {
          if (this.error.length > 0) {
            Text(this.error)
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
                void this.reload();
              })
          } else {
            Text('正在加载…')
              .fontSize(14.5)
              .fontColor(C_TEXT_SUB)
          }
        }
        .width('100%')
        .padding({ left: 32, right: 32, top: 20, bottom: 10 })
      } else if (this.tab === TAB_PLAYLIST) {
        Text(this.plazaLoading ? '正在加载更多…' : (this.plazaNoMore ? '没有更多了' : '上拉加载更多'))
          .fontSize(13)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
      }
      // 悬浮页签栏 + 迷你栏压在这里，最后一行不该被它们盖住
      Column().height(this.bottomInset + 12).width('100%')
    }
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Refresh({ refreshing: $$this.refreshing }) {
          /**
           * 整页用 List（不是 Scroll）：只有 List 能让内容从透明标题栏底下穿过、
           * 而不是被顶栏整块裁掉（起始那一段留白用下面那个占位行让出来）。
           */
          List({ space: ROW_GAP }) {
            /**
             * 顶部留白：让出透明标题栏 + 状态栏
             *
             * 必须是**占位行**，不能用 `contentStartOffset` —— 那个属性只在首次布局
             * 取值，topInset 后到时不会重排（详见 heroTopSpacer 的说明）。
             */
            ListItem() {
              Column()
                .height(this.heroTopSpacer())
                .width('100%')
            }

            // ------------------------------------------------ 顶部推荐歌曲
            ListItem() {
              this.heroRow()
            }

            // ------------------------------------------------ 分类胶囊
            ListItem() {
              this.chipRow()
            }

            // ------------------------------------------------ 网易私人推荐（登录后才有）
            if (this.platform === 'wy' && this.wyLogged && this.tab === TAB_FEATURED) {
              ListItem() {
                this.wyPrivateSection()
              }
              .onVisibleAreaChange([0.0, 0.05], (isVisible: boolean) => {
                if (isVisible) {
                  this.ensureWyRec();
                }
              })
            }

            // ------------------------------------------------ 各胶囊的正文
            if (this.tab === TAB_FEATURED) {
              this.featuredBody()
            } else if (this.tab === TAB_PLAYLIST) {
              this.playlistBody()
            } else if (this.tab === TAB_ARTIST) {
              this.artistBody()
            } else {
              this.boardBody()
            }

            // ------------------------------------------------ 尾巴
            ListItem() {
              this.tailBlock()
            }
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .onReachEnd(() => {
            this.loadMorePlaza();
          })
        .onScrollFrameBegin((offset: number): OnScrollFrameBeginHandlerResult => {
          // 列表上滑 → 底栏收成单排；下滑 → 回到两排（照派音，见 ui/BottomBar.ets）
          BottomBar.notifyScrollDelta(this.getUIContext(), offset);
          return { offsetRemain: offset };
        })
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          void this.reload();
        })
      }
      .width('100%')
      .height('100%')

      /** 顶栏渐隐：内容从透明标题栏底下穿过时淡出，标题才不被列表文字顶穿 */
      TopFade({ fadeHeight: this.topInset + 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
