import { ArtistCandidate } from '../core/music/MusicArtist';

/**
 * 「点歌手名 → 歌手聚合页」的统一入口
 *
 * 为什么做成单例而不是一层层传回调：会显示歌手名的地方太多了 ——
 * 播放页那一行、每一个歌曲列表行（搜索 / 歌单 / 历史 / 本地 / 下载 / 云端 共用
 * `SongListPane`）、回响的常听歌手。如果每处都接一个 `onOpenArtist` 参数，
 * 就得从壳层一路穿到最里层的组件，十几个调用点各改一遍，而且以后再加一个列表页
 * 又要再穿一次。
 *
 * 这里跟项目里既有的做法一致：`PlaySession.getInstance().setQueueAndPlay(...)`、
 * `SyncManager.getInstance()`、`DownloadManager.getInstance()` 也都是「组件直接调单例」，
 * 不靠参数传递。
 *
 * 分工：本类只负责「有人点了歌手名」这件事，**怎么开页面是壳层的事** ——
 * 页面栈、路由参数、播放页那个全屏模态要不要先收起来，只有 `pages/Index.ets` 知道。
 * 壳层启动时用 `register()` 把处理函数交进来；没注册时（比如某个页面被单独预览）
 * 这里什么都不做，不会崩。
 */
export type ArtistOpenHandler = (source: string, singer: string) => void;

/** 打开「歌手列表」页（回响的常听歌手走这一条） */
export type ArtistListHandler = (title: string, hint: string, candidates: ArtistCandidate[]) => void;

export class ArtistNav {
  private static instance: ArtistNav | null = null;

  static getInstance(): ArtistNav {
    if (ArtistNav.instance === null) {
      ArtistNav.instance = new ArtistNav();
    }
    return ArtistNav.instance;
  }

  private handler: ArtistOpenHandler | null = null;
  private listHandler: ArtistListHandler | null = null;

  /** 壳层注册（pages/Index.ets 的 aboutToAppear）；重复注册以后一次为准 */
  register(handler: ArtistOpenHandler): void {
    this.handler = handler;
  }

  /** 同上：注册「开歌手列表页」那一条（回响用） */
  registerList(handler: ArtistListHandler): void {
    this.listHandler = handler;
  }

  /**
   * 点了一位歌手名
   *
   * @param source 这首歌的来源平台（用来去哪个平台认人，认不到会自动换别的平台）
   * @param singer 歌手那一行的原文，可能是「周杰伦、方文山」这种多位
   */
  open(source: string, singer: string): void {
    if (this.handler === null || singer.trim().length === 0) {
      return;
    }
    this.handler(source, singer);
  }

  /**
   * 直接点一位确定名字的歌手（回响的常听歌手列表用）
   *
   * 与 `open` 的区别只是「名字已经是一位了」，不必再拆一遍 —— 走同一条处理链，
   * 所以壳层那边的逻辑（先解析再开页、解析不到给提示）只有一份。
   */
  openArtist(candidate: ArtistCandidate): void {
    this.open(candidate.source, candidate.name);
  }

  /** 这一行歌手名能不能点（没名字、或壳层没注册就不该有可点的样子） */
  canOpen(singer: string): boolean {
    return this.handler !== null && singer.trim().length > 0;
  }

  /**
   * 打开一份歌手名单（回响的「常听歌手」）
   *
   * @param title 页头标题（「常听歌手」）
   * @param hint  副标题（「2026 年 10 月 · 共 12 位」这种），'' = 不显示
   */
  openList(title: string, hint: string, candidates: ArtistCandidate[]): void {
    if (this.listHandler === null || candidates.length === 0) {
      return;
    }
    this.listHandler(title, hint, candidates);
  }
}
