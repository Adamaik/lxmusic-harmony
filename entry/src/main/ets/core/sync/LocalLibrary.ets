import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { K_LIBRARY_VERSION, PlaySession, LibrarySink, PlaylistSummary, SongItem } from '../player/PlaySession';
import { PlaylistLink, parseShareText } from '../music/PlaylistLink';
// 歌手拆分口径与搜索页的判重必须完全一致：两处各写一份正则，迟早有一边补了「；」
// 另一边没补，同一个歌单里「A、B」与「B/A」就会被当成两组人（见 duplicateKeyOf）
import { SINGER_SEPARATORS } from '../music/MusicSearch';
import { fromLxMusicInfo, isSyncable, toLxMusicInfo } from './SyncConvert';
import { defaultListData, SyncStore } from './SyncStore';
import { LocalMusic } from '../local/LocalMusic';
import { SongSideTable } from '../local/SideTable';
import { WebDavLibrary } from '../webdav/WebDavLibrary';
import { ADD_MUSIC_TOP, DISLIKE_NAME_ALIAS, DISLIKE_NAME_SEP, LIST_ID_LOVE, LOVE_LIST_NAME,
  LxDislikeMusicInfo, LxListCreateData,
  LxListData, LxListMusicAddData, LxListMusicMoveData, LxListMusicOverwriteData, LxListMusicRemoveData,
  LxListMusicUpdatePositionData, LxListUpdatePositionData, LxMusicInfoNew, LxMusicUpdateItem, LxSyncAction,
  LxUserListInfo, LxUserListInfoFull } from './SyncTypes';
import { toMD5 } from './SyncCrypto';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalLibrary';

/** 上行出口：把本地改动的动作发给服务端 */
export type SyncActionSink = (action: LxSyncAction, kind: string) => void;

/** 音乐库规模（设置页展示用） */
export interface LibrarySummary {
  playlists: number;
  songs: number;
}

/**
 * 加歌结果：added = 真正加入的条数（含本地/云端侧表歌），skipped = 因重复被跳过的条数
 *
 * 为什么要分两个数：以前只返回「加了几首」，调用方没法把「这首歌已经在歌单里了」
 * 讲给用户听 —— 群反馈里 QQ 的做法是「发现重复就不让加并提示」，我们至少要能提示
 * 「N 首已在歌单里，已跳过」，否则静默丢弃看起来就像点了没反应。
 */
export interface AddMusicResult {
  added: number;
  skipped: number;
}

/**
 * 一组重复歌曲（按歌名·歌手聚合，组内 >1）
 *
 * 只用于「检测并清理重复」，不改动任何数据：界面拿 keepId / duplicateIds 自己决定
 * 删不删，删除仍然走 removeMusicFromPlaylist 的上行分支。
 */
export interface DuplicateGroup {
  /** duplicateKeyOf 的结果（空串表示只能按 id 判重的条目，不参与分组） */
  key: string;
  /** 展示用歌名（组内第一条） */
  name: string;
  /** 展示用歌手（组内第一条） */
  singer: string;
  /** 组内总条数 */
  count: number;
  /** 建议保留的那条 id（列表中位置最靠前的一条） */
  keepId: string;
  /** 建议删除的那几条 id（组内除 keepId 外全部） */
  duplicateIds: string[];
}

/**
 * 本地音乐库
 *
 * 它是「参与同步的那份数据」的唯一持有者，内容按洛雪的线上格式（LxListData）保存：
 *   defaultList —— 试听列表（本移植版里就是播放队列）
 *   loveList    —— 我的收藏
 *   userList    —— 自建歌单（含歌曲）
 *   dislike     —— 不喜欢的歌曲规则（一整段文本）
 *
 * 与界面的关系是「镜像」：
 *   - 界面（PlaySession）里的展示字段还是 SongItem，改队列/收藏会通过 LibrarySink 通知这里，
 *     这里把 SongItem 转成 LxMusicInfo 后落盘、并上行同步动作；
 *   - 服务端推来的动作先改这里，再镜像回 PlaySession（并递增 K_LIBRARY_VERSION 让界面刷新）。
 *
 * 队列与试听列表：洛雪桌面端的「试听列表」就是播放队列，本移植版沿用这个含义 ——
 * 播放一份列表 = 把这份列表放进试听列表并开始播放，因此队列变化会同步为
 * list_music_overwrite('default', ...)。
 */
export class LocalLibrary implements LibrarySink {
  private static instance: LocalLibrary | null = null;

  static getInstance(): LocalLibrary {
    if (LocalLibrary.instance === null) {
      LocalLibrary.instance = new LocalLibrary();
    }
    return LocalLibrary.instance;
  }

  private store: SyncStore = new SyncStore();
  /**
   * 本地音乐库（设备里导入进来的音频）
   *
   * 它和这份同步数据是两个存储：本地歌不属于洛雪同步协议的范畴（官方客户端也只同步在线歌），
   * 但用户明确要求「本地歌也能加进歌单和收藏」，所以这里做一层非同步侧表：
   *   - 歌单 / 收藏里**属于本地歌**的那部分 key 存在 LocalMusic 里（见它的 lists）；
   *   - 读取时合并（本地歌排在前面），写入时各写各的；
   *   - 同步上行只看到 LxMusicInfoNew 那一半，协议与 md5 都不受影响。
   */
  private local: LocalMusic = LocalMusic.getInstance();
  /**
   * 云端音乐库（自己 WebDAV 服务器上的音频）
   *
   * 与本地音乐完全并列的第二种「非同步来源」，同样有自己的侧表。两张侧表的接口一致
   * （都实现 SongSideTable），所以下面所有涉及侧表的地方都按 `sideTables()` 数组统一处理，
   * 不再出现「本地歌一套、云端歌又一套」的重复代码。
   */
  private webdav: WebDavLibrary = WebDavLibrary.getInstance();
  private data: LxListData = defaultListData();
  private dislike: string = '';
  /** 本地是否已经有一份库（没有则说明是首次安装，界面就是空的） */
  private initialized: boolean = false;
  /** 正在应用远端数据 / 镜像到界面时抑制上行，避免自己发的动作绕回来 */
  private applying: boolean = false;
  /** 上行出口：连接并完成列表同步后由 SyncClient 装上，断开时清掉 */
  private actionSink: SyncActionSink | null = null;

  init(context: common.Context): void {
    this.store.init(context);
    this.load();
  }

  load(): void {
    this.data = this.store.loadListData();
    this.dislike = normalizeDislikeRules(this.store.loadDislikeRules());
    this.initialized = this.store.hasListData();
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  setActionSink(sink: SyncActionSink | null): void {
    this.actionSink = sink;
  }

  private emit(action: LxSyncAction, kind: string): void {
    const sink = this.actionSink;
    if (sink === null) {
      return;
    }
    try {
      sink(action, kind);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'emit %{public}s failed: %{public}s', action.action, JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 对外数据

  /** 当前同步数据（字段顺序与洛雪一致，md5 依赖它） */
  listData(): LxListData {
    const out: LxListData = {
      defaultList: this.data.defaultList,
      loveList: this.data.loveList,
      userList: buildUserLists(this.data.userList),
    };
    return out;
  }

  listDataMd5(): string {
    return toMD5(JSON.stringify(this.listData()));
  }

  dislikeRules(): string {
    return this.dislike;
  }

  dislikeMd5(): string {
    return toMD5(this.dislike.trim());
  }

  summary(): LibrarySummary {
    const playlists: number = this.data.userList.length;
    const songs: number = this.data.defaultList.length + this.data.loveList.length
      + this.sideTotal();
    return { playlists: playlists, songs: songs };
  }

  // ------------------------------------------------------------ 非同步侧表（本地 / 云端）

  /**
   * 所有非同步侧表
   *
   * 数组顺序就是列表里的展示顺序（本地在前、云端在后），与「新加的歌排最前」的既有规则
   * 不冲突：这些条目在同步数据里根本不存在，没有「和在线歌交错」的顺序可言。
   * 以后再加第三种来源（比如 SMB / Jellyfin），在这里加一项就够了。
   */
  private sideTables(): SongSideTable[] {
    return [this.local, this.webdav];
  }

  /** 某个列表里属于侧表的歌（顺序与 sideTables 一致） */
  private sideSongsOf(listId: string): SongItem[] {
    const out: SongItem[] = [];
    for (const table of this.sideTables()) {
      for (const song of table.songsByKeys(table.listKeys(listId))) {
        out.push(song);
      }
    }
    return out;
  }

  /** 某个列表里侧表条目的数量（歌单外显示的「N 首」要把这部分算进去） */
  private sideCountOf(listId: string): number {
    let sum: number = 0;
    for (const table of this.sideTables()) {
      sum += table.listCount(listId);
    }
    return sum;
  }

  /** 侧表条目总数（音乐库规模统计用） */
  private sideTotal(): number {
    let sum: number = 0;
    for (const table of this.sideTables()) {
      sum += table.count();
    }
    return sum;
  }

  /** 一批条目里属于某张侧表、且确实还在库里的 key（去重、保持顺序） */
  private sideKeysIn(table: SongSideTable, items: SongItem[]): string[] {
    const keys: string[] = [];
    for (const item of items) {
      if (item.source !== table.source) {
        continue;
      }
      const key: string = table.keyOfId(item.id);
      if (key.length > 0 && table.hasKey(key) && !keys.includes(key)) {
        keys.push(key);
      }
    }
    return keys;
  }

  /** 一批条目 id 里属于某张侧表、且还在库里的 key（去重、保持顺序） */
  private sideKeysOfIds(table: SongSideTable, ids: string[]): string[] {
    const keys: string[] = [];
    for (const id of ids) {
      const key: string = table.keyOfId(id);
      if (key.length > 0 && table.hasKey(key) && !keys.includes(key)) {
        keys.push(key);
      }
    }
    return keys;
  }

  /** 往各张侧表里加；@returns 真正加进去的总数 */
  private addToSideTables(listId: string, items: SongItem[]): number {
    let added: number = 0;
    for (const table of this.sideTables()) {
      added += table.addToList(listId, this.sideKeysIn(table, items));
    }
    return added;
  }

  /**
   * 这批条目里会被侧表挡掉的条数（加歌时算「重复跳过」用）
   *
   * 侧表的 addToList 只返回「真正加了几条」，被它挡下的那部分（key 已经在歌单里、
   * 或同一批里出现了两次）不会有人告诉界面，用户看到的就是「点了没反应」。
   * **必须在写入之前调用**：写完再数，刚加进去的 key 全成了「本来就有」。
   */
  private sideSkippedCount(listId: string, items: SongItem[]): number {
    let skipped: number = 0;
    for (const table of this.sideTables()) {
      // 已属于这张歌单的 key 先占位，后面同 key 的条目就算「本批内重复」
      const claimed: Set<string> = new Set<string>();
      for (const key of table.listKeys(listId)) {
        claimed.add(key);
      }
      for (const item of items) {
        if (item.source !== table.source) {
          continue;
        }
        const key: string = table.keyOfId(item.id);
        // 认不出 key 或条目已不在库里：addToList 收不到它，这里也不该算「跳过」
        if (key.length === 0 || !table.hasKey(key)) {
          continue;
        }
        if (claimed.has(key)) {
          skipped++;
          continue;
        }
        claimed.add(key);
      }
    }
    return skipped;
  }

  /** 从各张侧表里摘；@returns 真正被摘掉的总数 */
  private removeFromSideTables(listId: string, ids: string[]): number {
    let removed: number = 0;
    for (const table of this.sideTables()) {
      removed += table.removeFromList(listId, this.sideKeysOfIds(table, ids));
    }
    return removed;
  }

  /** 用一批条目整体覆盖各张侧表的成员 */
  private setSideTableKeys(listId: string, items: SongItem[]): void {
    for (const table of this.sideTables()) {
      table.setListKeys(listId, this.sideKeysIn(table, items));
    }
  }

  /** 歌单被删掉了：各张侧表里的引用一起清 */
  private dropSideLists(listIds: string[]): void {
    for (const table of this.sideTables()) {
      table.dropLists(listIds);
    }
  }

  // ------------------------------------------------------------ 界面镜像

  /** 把库里的数据镜像到界面（远端同步完成后调用） */
  mirrorToSession(): void {
    const session = PlaySession.getInstance();
    const queue: SongItem[] = [];
    for (const info of this.data.defaultList) {
      queue.push(fromLxMusicInfo(info));
    }
    const favorites: SongItem[] = [];
    // 收藏里的本地歌 / 云端歌排在前面（它们在同步数据里不存在，只能这么合）
    for (const song of this.sideSongsOf(LIST_ID_LOVE)) {
      favorites.push(song);
    }
    for (const info of this.data.loveList) {
      favorites.push(fromLxMusicInfo(info));
    }
    this.applying = true;
    try {
      session.adoptLibraryState(queue, favorites);
    } finally {
      this.applying = false;
    }
  }

  /** 界面上的队列 / 收藏变了：转成同步结构，并在需要时上行 */
  onLocalListsChanged(): void {
    if (this.applying) {
      return;
    }
    const session = PlaySession.getInstance();
    // 收藏里的本地歌 / 云端歌先落盘：它们不上行（同步只送在线歌），但必须存住，
    // 否则重启后收藏里那几首就没了。这一步与下面「要不要上行」无关。
    this.syncSideFavorites(session.favorites);
    const nextDefault: LxMusicInfoNew[] = musicsOf(session.queue);
    const nextLove: LxMusicInfoNew[] = musicsOf(session.favorites);

    // 会话里有歌、却一首也转不成同步结构，说明这些条目不是平台歌曲（本地歌 / 云端歌
    // 走各自的侧表，见 core/local/SideTable），或者缺 musicInfo。
    // 这种时候绝不能拿「空结果」去覆盖已有列表：本机和云端的收藏 / 试听列表会被一起清掉。
    // 按列表各判各的：一份不可用不影响另一份照常同步。
    const defaultUsable: boolean = session.queue.length === 0 || nextDefault.length > 0;
    const loveUsable: boolean = session.favorites.length === 0 || nextLove.length > 0;
    const defaultChanged: boolean = defaultUsable
      && JSON.stringify(nextDefault) !== JSON.stringify(this.data.defaultList);
    const loveChanged: boolean = loveUsable
      && JSON.stringify(nextLove) !== JSON.stringify(this.data.loveList);
    if (!defaultChanged && !loveChanged) {
      if (!defaultUsable || !loveUsable) {
        hilog.warn(DOMAIN, TAG,
          'skip unsyncable list (queue=%{public}d->%{public}d, love=%{public}d->%{public}d)',
          session.queue.length, nextDefault.length, session.favorites.length, nextLove.length);
      }
      return;
    }
    // 只写真正变了的那一份，不要顺手把另一份也覆盖掉
    if (defaultChanged) {
      this.data.defaultList = nextDefault;
    }
    if (loveChanged) {
      this.data.loveList = nextLove;
    }
    this.persist();
    // 界面上的「歌单」页订阅 K_LIBRARY_VERSION 来刷新曲目数。本地收藏 / 队列改动
    // 走的是这条路（不像远端同步那样经过 adoptLibraryState），不递增的话
    // 内置收藏歌单外面的「N 首」会停在旧值（刚收藏完显示 0 首就是这么来的）。
    this.bumpLibraryVersion();
    if (defaultChanged) {
      this.emitOverwrite('default', nextDefault);
    }
    if (loveChanged) {
      this.emitOverwrite('love', nextLove);
    }
  }

  /** 本地改动后让订阅 K_LIBRARY_VERSION 的列表页重新读一次数据 */
  private bumpLibraryVersion(): void {
    const version: number = AppStorage.get<number>(K_LIBRARY_VERSION) ?? 0;
    AppStorage.setOrCreate(K_LIBRARY_VERSION, version + 1);
  }

  /**
   * 只改了「属于本地歌的那部分」（本地歌进出歌单 / 收藏）
   *
   * 这里**不能**用 mirrorToSession()：它会把界面队列整体换成同步过的队列，
   * 而正在播的本地队列在同步数据里是不存在的 —— 结果是「往歌单里加一首本地歌，
   * 播放队列里的本地歌全没了」。同步那份数据本来也没变，只需要让列表页重读计数。
   */
  private bumpLocalChange(): void {
    this.bumpLibraryVersion();
  }

  /** 把界面收藏名单里属于各张侧表的那部分同步到各自的侧表 */
  private syncSideFavorites(favorites: SongItem[]): void {
    for (const table of this.sideTables()) {
      table.setListKeys(LIST_ID_LOVE, this.sideKeysIn(table, favorites));
    }
  }

  private emitOverwrite(listId: string, musicInfos: LxMusicInfoNew[]): void {
    const data: LxListMusicOverwriteData = { listId: listId, musicInfos: musicInfos };
    this.emit({ action: 'list_music_overwrite', data: data }, 'list');
  }

  // ------------------------------------------------------------ 歌单操作（界面入口）

  /**
   * 歌单列表（「我的 → 自建歌单」直接渲染这一份）
   *
   * **按 id 去重**：老用户的数据里可能存在两条完全同 id 的记录 —— 历史同步把同一条
   * list_create 落了两遍（实测 list.json 里就是两条同 id 的「茗秋瞳喜欢的音乐」，
   * 见 docs/UPDATE_1.0.7_TEST_RESULT.md 那条低严重问题）。同 id 就是同一张歌单，
   * 列两遍只会让用户以为自己建重了。
   *
   * 这里只做**只读的展示层去重**：不动 `this.data.userList`，所以既不删数据、也不会
   * 让同步 md5 因为去重而漂移（一漂移就会在下次连接时多弹一次「选择同步方式」）。
   * 同 id 且曲目数不同时按多的那条显示，免得去重把「N 首」显示小了。
   */
  playlistSummaries(): PlaylistSummary[] {
    const out: PlaylistSummary[] = [];
    const keptAt: Map<string, number> = new Map<string, number>();
    for (const item of this.data.userList) {
      // 曲目数要把侧表里的本地歌 / 云端歌算上，否则「歌单里有 3 首本地歌」外面显示 0 首
      const count: number = item.list.length + this.sideCountOf(item.id);
      const at: number | undefined = keptAt.get(item.id);
      if (at === undefined) {
        keptAt.set(item.id, out.length);
        out.push({ id: item.id, name: item.name, count: count });
        continue;
      }
      const kept: PlaylistSummary = out[at];
      if (count > kept.count) {
        kept.count = count;
      }
    }
    return out;
  }

  /**
   * 歌单的来源平台（本地手建的返回空串）
   *
   * 列表副标题用它标出来源：导入的歌单与手建的歌单可能同名，两条都合法，界面必须
   * 让用户分得清哪条是导入的（见 views/MineView 的 playlistMeta）。
   */
  playlistSourceOf(id: string): string {
    const item = this.findPlaylist(id);
    if (item === null || item.source === undefined) {
      return '';
    }
    return item.source;
  }

  /**
   * 这张本地歌单对应的**线上歌单标识**（`source__歌单id` 的规范化形态）
   *
   * 只有「从分享链接导入」的歌单才有；手建歌单与内置收藏歌单返回空串。
   * 「从原歌单更新」靠它回源重新拉一遍（见 views/ImportPlaylistSheet 的导入口径）。
   */
  sourceListIdOf(id: string): string {
    const item = this.findPlaylist(id);
    if (item === null || item.sourceListId === undefined) {
      return '';
    }
    return item.sourceListId;
  }

  playlistSongs(id: string): SongItem[] {
    // targetMusics 认 default / love / 用户歌单，所以内置收藏歌单也能按 id 取歌
    const musics: LxMusicInfoNew[] | null = this.targetMusics(id);
    if (musics === null) {
      return [];
    }
    const out: SongItem[] = [];
    // 侧表里的歌（本地 / 云端）排在前面：它们不在同步数据里，没有「和在线歌交错」
    // 的顺序可言；排在前面与「新加的歌排最前」的既有规则一致。
    for (const song of this.sideSongsOf(id)) {
      out.push(song);
    }
    for (const info of musics) {
      out.push(fromLxMusicInfo(info));
    }
    return out;
  }

  /**
   * 内置收藏歌单（界面「歌单」页里那个永远存在的默认歌单）
   *
   * 数据就是洛雪的 loveList —— 界面上当歌单用（能播放全部、能一首首删），
   * 协议上仍然是 loveList，与官方客户端的「我的收藏」互通。
   */
  favoritePlaylistSummary(): PlaylistSummary {
    return {
      id: LIST_ID_LOVE,
      name: LOVE_LIST_NAME,
      count: this.data.loveList.length + this.sideCountOf(LIST_ID_LOVE),
    };
  }

  /** 是不是那个不可删除 / 不可改名的内置歌单 */
  isBuiltinPlaylist(id: string): boolean {
    return id === LIST_ID_LOVE;
  }

  hasPlaylist(id: string): boolean {
    if (id === LIST_ID_LOVE) {
      return true;
    }
    for (const item of this.data.userList) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 新建歌单；返回新歌单 id
   *
   * **同名不合并**：用户有权建两张同名歌单（一张放这个歌手、一张放那张合集），
   * 静默合并会把其中一张的歌「吃掉」。同名要区分就让界面去标来源（见 playlistSourceOf）。
   *
   * 但 **id 必须唯一**：`Date.now()` 只有毫秒精度，连点两下「新建歌单」或脚本批量建
   * 会撞出同一个 id，落库后就是两条同 id 的记录 —— 界面上是两条同名，而
   * `findPlaylist` 只认第一条，第二条从此改不动也删不干净（同一类重复的根因之一）。
   */
  createPlaylist(name: string): string {
    const stamp: number = Date.now();
    let id: string = `user_list_${stamp}`;
    let seq: number = 0;
    while (this.hasPlaylist(id)) {
      seq++;
      id = `user_list_${stamp}_${seq}`;
    }
    const item: LxUserListInfoFull = {
      id: id,
      name: name,
      locationUpdateTime: Date.now(),
      list: [],
    };
    this.data.userList.push(item);
    this.persist();
    this.mirrorToSession();
    const listInfos: LxUserListInfo[] = [buildUserListInfo(item)];
    const data: LxListCreateData = { position: this.data.userList.length - 1, listInfos: listInfos };
    this.emit({ action: 'list_create', data: data }, 'list');
    return id;
  }

  /**
   * 按线上歌单标识找已经导入过的本地歌单
   *
   * 导入面板拿它判断这次是「新建」还是「更新已有歌单」。sourceListId 存的是洛雪的
   * 列表标识 `${source}__${歌单id}`（与 core/music/PlaylistLink 解析出来的一致），
   * 但老数据里可能是 `wy__<整条分享链接>`（见 normalizeSourceListId 的说明），
   * 所以比较走归一化口径 —— 否则升级后的用户会对同一张歌单再建一条同名列表。
   */
  playlistBySourceListId(sourceListId: string): PlaylistSummary | null {
    const item = this.findBySourceListId(sourceListId);
    if (item === null) {
      return null;
    }
    return { id: item.id, name: item.name, count: item.list.length + this.sideCountOf(item.id) };
  }

  /** 按归一化后的线上歌单标识找记录（`wy__2102211118` 与 `wy__https://…?id=2102211118` 视为同一条） */
  private findBySourceListId(sourceListId: string): LxUserListInfoFull | null {
    const key: string = normalizeSourceListId(sourceListId);
    if (key.length === 0) {
      return null;
    }
    for (const item of this.data.userList) {
      if (item.sourceListId === undefined) {
        continue;
      }
      if (normalizeSourceListId(item.sourceListId) === key) {
        return item;
      }
    }
    return null;
  }

  /**
   * 导入在线歌单（对应洛雪的 addSongListDetail）
   *
   * 与「新建歌单」的两点不同：
   *   1. id 由「平台 + md5(平台__歌单id)」决定，所以同一个线上歌单反复导入都是同一个
   *      本地歌单，不会冒出一堆同名列表（洛雪也是这么算 id 的）；
   *   2. 一起落 source / sourceListId，服务端与官方客户端认这两个字段，以后还能
   *      按它判断「这个歌单来自哪个平台」。
   *
   * **认领老记录**：只比 id 还不够 —— 老版本有一条入口把整条分享链接当 listId 传进来，
   * 那批记录的 id 是按 `md5('wy__https://…')` 算的，与新口径算出来的不同。所以 id 找不到
   * 时再按归一化 sourceListId 找一次，命中就原地更新那条（沿用它的 id），顺手把
   * sourceListId 迁到规范形态。这样老用户再导一次同一张歌单不会多出一条同名列表，
   * 也不会删掉任何原有数据。
   * @returns 导入后的歌单；没有任何可导入的歌时返回 null
   */
  importPlaylist(name: string, source: string, sourceListId: string,
    items: SongItem[]): PlaylistSummary | null {
    /**
     * **导入不按 id 去重**（keepDuplicates = true）。
     *
     * 群反馈 2026-11-20 15:19（CharlotteZero「歌单导入永远少一首歌」）：线上歌单里
     * 同一首歌被加了两遍是合法的，按 id 去重会把第二条悄悄吃掉，导入结果就永远比
     * 线上少一首，而且没有任何提示。洛雪原版这里也是直接 push、不去重。
     * 重复要不要清理由歌单菜单里的「检查重复歌曲」决定，导入不替用户做决定。
     * （加歌 `addMusicToPlaylist` 仍然走默认的去重口径，那里「发现重复就不加」是正确的。）
     */
    const musics: LxMusicInfoNew[] = musicsOf(items, true);
    if (musics.length === 0) {
      return null;
    }
    // id 按**归一化**后的标识算：同一张线上歌单，无论调用方给的是 `wy__2102211118`
    // 还是老的 `wy__https://…?id=2102211118`，都落到同一个本地歌单上
    const key: string = normalizeSourceListId(sourceListId);
    const id: string = `${source}_${toMD5(key)}`;
    let existing: LxUserListInfoFull | null = this.findPlaylist(id);
    if (existing === null) {
      existing = this.findBySourceListId(key);
    }
    if (existing !== null) {
      // 同一个线上歌单再导一次：原地更新（名字与歌曲都换成线上最新的）
      const targetId: string = existing.id;
      existing.name = name;
      existing.source = source;
      existing.sourceListId = key;
      existing.locationUpdateTime = Date.now();
      existing.list = musics;
      this.persist();
      this.mirrorToSession();
      this.emitOverwrite(targetId, musics);
      this.emit({ action: 'list_update', data: [buildUserListInfo(existing)] }, 'list');
      return { id: targetId, name: name, count: musics.length + this.sideCountOf(targetId) };
    }
    const item: LxUserListInfoFull = {
      id: id,
      name: name,
      source: source,
      sourceListId: key,
      locationUpdateTime: Date.now(),
      list: musics,
    };
    this.data.userList.push(item);
    this.persist();
    this.mirrorToSession();
    const data: LxListCreateData = {
      position: this.data.userList.length - 1,
      listInfos: [buildUserListInfo(item)],
    };
    this.emit({ action: 'list_create', data: data }, 'list');
    return { id: id, name: name, count: musics.length };
  }

  renamePlaylist(id: string, name: string): void {    if (this.isBuiltinPlaylist(id)) {
      // 内置收藏歌单不允许改名
      return;
    }
    const item = this.findPlaylist(id);
    if (item === null) {
      return;
    }
    item.name = name;
    item.locationUpdateTime = Date.now();
    this.persist();
    this.mirrorToSession();
    const listInfos: LxUserListInfo[] = [buildUserListInfo(item)];
    this.emit({ action: 'list_update', data: listInfos }, 'list');
  }

  removePlaylists(ids: string[]): void {
    // 内置收藏歌单不允许删除：过滤掉之后再看还有没有要删的
    const removable: string[] = [];
    for (const id of ids) {
      if (!this.isBuiltinPlaylist(id)) {
        removable.push(id);
      }
    }
    if (removable.length === 0) {
      return;
    }
    const remains: LxUserListInfoFull[] = [];
    for (const item of this.data.userList) {
      if (!removable.includes(item.id)) {
        remains.push(item);
      }
    }
    if (remains.length === this.data.userList.length) {
      return;
    }
    this.data.userList = remains;
    // 歌单没了，它在各张侧表里的引用也一起清掉（留着就是永远读不到的垃圾）
    this.dropSideLists(removable);
    this.persist();
    this.mirrorToSession();
    this.emit({ action: 'list_remove', data: removable }, 'list');
  }

  /**
   * 往歌单里加歌
   *
   * 新加的歌放在**最前面**（保持传入顺序），与洛雪的默认设置一致
   * （list.addMusicLocationType 默认就是 'top'）：刚加完就能在歌单顶部看到，
   * 不用翻到最底下确认加没加上。上行也照这个位置报，别让别的设备加到底部去。
   *
   * **判重为什么不能只看 id**：同一首歌在酷我 / QQ / 网易各有一条 id，从不同音源、
   * 不同搜索结果回来的条目 id 全不一样，只按 id 判重必然往同一个歌单里塞进两首一样的歌
   * （群反馈「歌单要加个删除重复歌曲……加歌的时候和 QQ 不一样」就是这个）。
   * 所以 id 之外再按歌名·歌手（duplicateKeyOf）兜一层，被挡下的如实计进 skipped。
   */
  addMusicToPlaylist(id: string, items: SongItem[]): AddMusicResult {
    const target = this.findPlaylist(id);
    if (target === null) {
      return { added: 0, skipped: 0 };
    }
    // 侧表歌已经在歌单里的，也算「重复跳过」；先数再写，顺序不能反（见 sideSkippedCount）
    const sideSkipped: number = this.sideSkippedCount(id, items);
    // 本地歌 / 云端歌走侧表（它们不属于同步结构，musicsOf 会把它们丢掉）
    const localAdded: number = this.addToSideTables(id, items);
    const musics: LxMusicInfoNew[] = musicsOf(items);
    if (musics.length === 0) {
      // 整批都是侧表里的歌：同步那份数据一个字都没变，只需让列表页重读计数
      if (localAdded > 0) {
        this.bumpLocalChange();
      }
      return { added: localAdded, skipped: sideSkipped };
    }
    const existed: Set<string> = new Set<string>();
    // 同曲不同 id 的兜底键：歌名·歌手（空键不可判重，只按 id 走）
    const existedKeys: Set<string> = new Set<string>();
    for (const info of target.list) {
      existed.add(info.id);
      const key: string = duplicateKeyOf(info.name, info.singer);
      if (key.length > 0) {
        existedKeys.add(key);
      }
    }
    const added: LxMusicInfoNew[] = [];
    let skipped: number = sideSkipped;
    for (const info of musics) {
      if (existed.has(info.id)) {
        skipped++;
        continue;
      }
      const key: string = duplicateKeyOf(info.name, info.singer);
      if (key.length > 0 && existedKeys.has(key)) {
        skipped++;
        continue;
      }
      existed.add(info.id);
      if (key.length > 0) {
        existedKeys.add(key);
      }
      added.push(info);
    }
    if (added.length === 0) {
      if (localAdded > 0) {
        this.bumpLocalChange();
      }
      return { added: localAdded, skipped: skipped };
    }
    target.list = added.concat(target.list);
    this.persist();
    this.mirrorToSession();
    const data: LxListMusicAddData = {
      id: id,
      musicInfos: added,
      addMusicLocationType: ADD_MUSIC_TOP,
    };
    this.emit({ action: 'list_music_add', data: data }, 'list');
    return { added: added.length + localAdded, skipped: skipped };
  }

  /**
   * 从歌单里删歌
   *
   * 内置收藏歌单也走这里（在它的详情页删歌 = 取消收藏），只是上行方式不同：
   * 收藏列表在协议里是整份覆盖（love），用户歌单是增量动作（list_music_remove）。
   */
  removeMusicFromPlaylist(id: string, songIds: string[]): void {
    if (songIds.length === 0) {
      return;
    }
    if (this.isBuiltinPlaylist(id)) {
      this.removeMusicFromLove(songIds);
      return;
    }
    const target = this.findPlaylist(id);
    if (target === null) {
      return;
    }
    // 侧表里的歌从侧表摘（同步那份数据里本来就没有它们）
    const localRemoved: number = this.removeFromSideTables(id, songIds);
    const remains: LxMusicInfoNew[] = [];
    const removedIds: string[] = [];
    for (const info of target.list) {
      if (songIds.includes(info.id)) {
        removedIds.push(info.id);
        continue;
      }
      remains.push(info);
    }
    if (remains.length === target.list.length) {
      // 只删掉了本地歌：同步那份数据一个字没变，上行也没必要
      if (localRemoved > 0) {
        this.bumpLocalChange();
      }
      return;
    }
    target.list = remains;
    this.persist();
    this.mirrorToSession();
    // 只报真正在同步数据里被删掉的那些 id（本地歌的 id 服务端并不认识）
    const data: LxListMusicRemoveData = { listId: id, ids: removedIds };
    this.emit({ action: 'list_music_remove', data: data }, 'list');
  }

  /** 从内置收藏里移除一批歌（协议上是整份 love 列表覆盖，与官方一致） */
  private removeMusicFromLove(songIds: string[]): void {
    const localRemoved: number = this.removeFromSideTables(LIST_ID_LOVE, songIds);
    const remains: LxMusicInfoNew[] = [];
    for (const info of this.data.loveList) {
      if (!songIds.includes(info.id)) {
        remains.push(info);
      }
    }
    if (remains.length === this.data.loveList.length) {
      if (localRemoved > 0) {
        this.bumpLocalChange();
      }
      return;
    }
    this.data.loveList = remains;
    this.persist();
    this.mirrorToSession();
    this.emitOverwrite(LIST_ID_LOVE, this.data.loveList);
  }

  /**
   * 找出某个歌单里的重复组（按列表顺序，keep 取最靠前的一条；没有重复返回空数组）
   *
   * 口径与加歌时的判重完全一致（duplicateKeyOf）：只有「歌名·歌手」非空的条目才参与，
   * key 为空的条目（连歌名都没有的侧表歌）宁可漏报也不并组 —— 并错了就是误删用户的歌。
   *
   * 内建收藏歌单也覆盖：它的数据在 loveList 里，playlistSongs → targetMusics 认 'love'，
   * 侧表里属于收藏的那部分也一起被 playlistSongs 合进来，不另造一份数据源。
   */
  findDuplicateGroups(id: string): DuplicateGroup[] {
    const songs: SongItem[] = this.playlistSongs(id);
    const order: string[] = [];
    const byKey: Map<string, DuplicateGroup> = new Map<string, DuplicateGroup>();
    const seenIds: Set<string> = new Set<string>();
    for (const song of songs) {
      // 老数据（同一条侧表 key 被记了两遍）会把同一首歌列两次：那是「同一行重复」，
      // 删一次就干净了，不能当成「两首重复的歌」让用户点两次删除
      if (seenIds.has(song.id)) {
        continue;
      }
      seenIds.add(song.id);
      const key: string = duplicateKeyOf(song.name, song.singer);
      if (key.length === 0) {
        continue;
      }
      const group: DuplicateGroup | undefined = byKey.get(key);
      if (group === undefined) {
        const fresh: DuplicateGroup = {
          key: key,
          name: song.name,
          singer: song.singer,
          count: 1,
          keepId: song.id,
          duplicateIds: [],
        };
        byKey.set(key, fresh);
        order.push(key);
        continue;
      }
      // 组内顺序就是列表顺序：第一条（最靠前）留着，后面的一律进 duplicateIds
      group.count++;
      group.duplicateIds.push(song.id);
    }
    const out: DuplicateGroup[] = [];
    for (const key of order) {
      const group: DuplicateGroup | undefined = byKey.get(key);
      if (group !== undefined && group.count > 1) {
        out.push(group);
      }
    }
    return out;
  }

  /**
   * 删除指定的重复条目；@returns 实际删除条数
   *
   * 内部走 removeMusicFromPlaylist 同一套分支（内建收藏歌单 = 收藏侧移除 + love 整份覆盖，
   * 用户歌单 = list_music_remove），所以上行、落盘、界面镜像都不必在这里重写一遍。
   * 调用方可能拿着旧快照来删，不在当前歌单里的 id 直接跳过，不报错。
   */
  removeDuplicateSongs(id: string, ids: string[]): number {
    if (ids.length === 0) {
      return 0;
    }
    // 只认内建收藏歌单与用户歌单：removeMusicFromPlaylist 对 'default' 之类本来就不动，
    // 这里若照单全收，返回的「删了 N 首」就是假数
    if (!this.isBuiltinPlaylist(id) && this.findPlaylist(id) === null) {
      return 0;
    }
    const present: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const song of this.playlistSongs(id)) {
      if (seen.has(song.id) || !ids.includes(song.id)) {
        continue;
      }
      seen.add(song.id);
      present.push(song.id);
    }
    if (present.length === 0) {
      return 0;
    }
    this.removeMusicFromPlaylist(id, present);
    return present.length;
  }

  /** 用整份列表覆盖歌单歌曲（界面里的「用当前播放列表替换」） */
  overwritePlaylistMusic(id: string, items: SongItem[]): void {
    const target = this.findPlaylist(id);
    if (target === null) {
      return;
    }
    // 侧表那半边一起换掉（换成新列表里属于各张侧表的条目）
    this.setSideTableKeys(id, items);
    const musics: LxMusicInfoNew[] = musicsOf(items);
    target.list = musics;
    this.persist();
    this.mirrorToSession();
    this.emitOverwrite(id, musics);
  }

  private findPlaylist(id: string): LxUserListInfoFull | null {
    for (const item of this.data.userList) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  // ------------------------------------------------------------ 不喜欢规则

  /**
   * 规范化规则文本，逐条对齐洛雪 updateDislikeInfo：
   * 每行「歌名@歌手」，分隔符转义成 #，小写去空白，去掉空条目并按首次出现顺序去重。
   */
  setDislikeRules(raw: string, emitRemote: boolean = true): void {
    const next: string = normalizeDislikeRules(raw);
    if (next === this.dislike) {
      return;
    }
    this.dislike = next;
    this.persistDislike();
    if (emitRemote) {
      this.emit({ action: 'dislike_data_overwrite', data: next }, 'dislike');
    }
  }

  addDislike(name: string, singer: string): void {
    const info: LxDislikeMusicInfo = { name: name, singer: singer };
    const line: string = `${name}${DISLIKE_NAME_SEP}${singer}`;
    this.setDislikeRules(`${this.dislike}\n${line}`, false);
    this.persistDislike();
    this.emit({ action: 'dislike_music_add', data: [info] }, 'dislike');
  }

  removeDislikeRule(rule: string): void {
    const lines: string[] = [];
    for (const line of this.dislike.split('\n')) {
      if (line.length > 0 && line !== rule) {
        lines.push(line);
      }
    }
    this.setDislikeRules(lines.join('\n'));
  }

  clearDislike(): void {
    if (this.dislike.length > 0) {
      this.dislike = '';
      this.persistDislike();
    }
    this.emit({ action: 'dislike_music_clear' }, 'dislike');
  }

  dislikeRuleList(): string[] {
    const out: string[] = [];
    for (const line of this.dislike.split('\n')) {
      if (line.length > 0) {
        out.push(line);
      }
    }
    return out;
  }

  /** 这首歌是否命中了不喜欢规则（供界面做灰显/过滤时使用） */
  isDisliked(name: string, singer: string): boolean {
    if (this.dislike.length === 0) {
      return false;
    }
    const song: string = name.toLowerCase().trim();
    const artist: string = singer.toLowerCase().trim();
    for (const line of this.dislike.split('\n')) {
      if (line.length === 0) {
        continue;
      }
      const at: number = line.indexOf(DISLIKE_NAME_SEP);
      if (at < 0) {
        if (line === song) {
          return true;
        }
        continue;
      }
      const ruleName: string = line.substring(0, at);
      const ruleSinger: string = line.substring(at + 1);
      if (ruleName.length === 0) {
        if (ruleSinger === artist) {
          return true;
        }
        continue;
      }
      if (ruleName === song && ruleSinger === artist) {
        return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------ 应用远端数据

  /** 服务端要求把我们整份列表数据换成 data（list_sync_set_list_data） */
  applyRemoteListData(data: LxListData): void {
    this.data = normalizeListData(data);
    this.initialized = true;
    this.persist();
    this.mirrorToSession();
  }

  /** 服务端推来的实时列表动作（list_sync_finished 之后） */
  applyRemoteListAction(action: LxSyncAction): void {
    this.applying = true;
    try {
      this.applyRemoteListActionInner(action);
    } finally {
      this.applying = false;
    }
    this.initialized = true;
    this.persist();
    this.mirrorToSession();
  }

  private applyRemoteListActionInner(action: LxSyncAction): void {
    switch (action.action) {
      case 'list_data_overwrite':
        this.data = normalizeListData(action.data as LxListData);
        return;
      case 'list_create': {
        const payload = action.data as LxListCreateData;
        if (payload === undefined || payload === null) {
          return;
        }
        const infos: LxUserListInfo[] = payload.listInfos !== undefined ? payload.listInfos : [];
        let position: number = payload.position !== undefined ? payload.position : this.data.userList.length;
        for (const info of infos) {
          if (this.findPlaylist(info.id) !== null) {
            continue;
          }
          const full: LxUserListInfoFull = {
            id: info.id,
            name: info.name,
            locationUpdateTime: info.locationUpdateTime !== undefined ? info.locationUpdateTime : null,
            list: [],
          };
          if (info.source !== undefined) {
            full.source = info.source;
          }
          if (info.sourceListId !== undefined) {
            full.sourceListId = info.sourceListId;
          }
          if (position < 0 || position > this.data.userList.length) {
            position = this.data.userList.length;
          }
          this.data.userList.splice(position, 0, full);
          position++;
        }
        return;
      }
      case 'list_remove': {
        const ids: string[] = action.data as string[];
        if (ids === undefined || ids === null) {
          return;
        }
        const remains: LxUserListInfoFull[] = [];
        for (const item of this.data.userList) {
          if (!ids.includes(item.id)) {
            remains.push(item);
          }
        }
        this.data.userList = remains;
        return;
      }
      case 'list_update': {
        const infos: LxUserListInfo[] = action.data as LxUserListInfo[];
        if (infos === undefined || infos === null) {
          return;
        }
        for (const info of infos) {
          const target = this.findPlaylist(info.id);
          if (target === null) {
            continue;
          }
          target.name = info.name;
          if (info.source !== undefined) {
            target.source = info.source;
          }
          if (info.sourceListId !== undefined) {
            target.sourceListId = info.sourceListId;
          }
          if (info.locationUpdateTime !== undefined) {
            target.locationUpdateTime = info.locationUpdateTime;
          }
        }
        return;
      }
      case 'list_update_position': {
        const payload = action.data as LxListUpdatePositionData;
        if (payload === undefined || payload === null) {
          return;
        }
        const ids: string[] = payload.ids !== undefined ? payload.ids : [];
        let position: number = payload.position !== undefined ? payload.position : 0;
        const moving: LxUserListInfoFull[] = [];
        for (const id of ids) {
          const target = this.findPlaylist(id);
          if (target !== null) {
            moving.push(target);
          }
        }
        if (moving.length === 0) {
          return;
        }
        const remains: LxUserListInfoFull[] = [];
        for (const item of this.data.userList) {
          if (!ids.includes(item.id)) {
            remains.push(item);
          }
        }
        if (position < 0 || position > remains.length) {
          position = remains.length;
        }
        insertAt(remains, position, moving);
        this.data.userList = remains;
        return;
      }
      case 'list_music_add': {
        const payload = action.data as LxListMusicAddData;
        if (payload === undefined || payload === null) {
          return;
        }
        this.addMusicTo(payload.id, payload.musicInfos, payload.addMusicLocationType);
        return;
      }
      case 'list_music_move': {
        const payload = action.data as LxListMusicMoveData;
        if (payload === undefined || payload === null) {
          return;
        }
        this.removeMusicFrom(payload.fromId, idsOf(payload.musicInfos));
        this.addMusicTo(payload.toId, payload.musicInfos, payload.addMusicLocationType);
        return;
      }
      case 'list_music_remove': {
        const payload = action.data as LxListMusicRemoveData;
        if (payload === undefined || payload === null) {
          return;
        }
        this.removeMusicFrom(payload.listId, payload.ids);
        return;
      }
      case 'list_music_update': {
        const updates = action.data as LxMusicUpdateItem[];
        if (updates === undefined || updates === null) {
          return;
        }
        for (const update of updates) {
          this.replaceMusicEverywhere(update.id, update.musicInfo);
        }
        return;
      }
      case 'list_music_update_position': {
        const payload = action.data as LxListMusicUpdatePositionData;
        if (payload === undefined || payload === null) {
          return;
        }
        this.moveMusicToPosition(payload.listId, payload.position, payload.ids);
        return;
      }
      case 'list_music_overwrite': {
        const payload = action.data as LxListMusicOverwriteData;
        if (payload === undefined || payload === null) {
          return;
        }
        this.overwriteMusic(payload.listId, payload.musicInfos);
        return;
      }
      case 'list_music_clear': {
        const listIds: string[] = action.data as string[];
        if (listIds === undefined || listIds === null) {
          return;
        }
        for (const listId of listIds) {
          this.overwriteMusic(listId, []);
        }
        return;
      }
      default:
        hilog.warn(DOMAIN, TAG, 'unknown list action: %{public}s', action.action);
        return;
    }
  }

  private addMusicTo(listId: string, musics: LxMusicInfoNew[], location: string): void {
    const target = this.targetMusics(listId);
    if (target === null) {
      return;
    }
    let list: LxMusicInfoNew[] = target;
    for (const info of musics) {
      list = list.filter((item: LxMusicInfoNew) => item.id !== info.id);
    }
    if (location === 'top') {
      const merged: LxMusicInfoNew[] = [];
      for (const info of musics) {
        merged.push(info);
      }
      for (const info of list) {
        merged.push(info);
      }
      this.assignMusics(listId, merged);
      return;
    }
    for (const info of musics) {
      list.push(info);
    }
    this.assignMusics(listId, list);
  }

  private removeMusicFrom(listId: string, ids: string[]): void {
    const target = this.targetMusics(listId);
    if (target === null) {
      return;
    }
    const remains: LxMusicInfoNew[] = [];
    for (const info of target) {
      if (!ids.includes(info.id)) {
        remains.push(info);
      }
    }
    this.assignMusics(listId, remains);
  }

  private overwriteMusic(listId: string, musics: LxMusicInfoNew[]): void {
    if (this.targetMusics(listId) === null) {
      return;
    }
    this.assignMusics(listId, musics);
  }

  private moveMusicToPosition(listId: string, position: number, ids: string[]): void {
    const target = this.targetMusics(listId);
    if (target === null) {
      return;
    }
    const moving: LxMusicInfoNew[] = [];
    for (const info of target) {
      if (ids.includes(info.id)) {
        moving.push(info);
      }
    }
    if (moving.length === 0) {
      return;
    }
    const remains: LxMusicInfoNew[] = [];
    for (const info of target) {
      if (!ids.includes(info.id)) {
        remains.push(info);
      }
    }
    let at: number = position;
    if (at < 0 || at > remains.length) {
      at = remains.length;
    }
    insertAt(remains, at, moving);
    this.assignMusics(listId, remains);
  }

  /** 取某个列表的歌曲数组（返回的是库内引用，调用方只能读） */
  private targetMusics(listId: string): LxMusicInfoNew[] | null {
    if (listId === 'default') {
      return this.data.defaultList;
    }
    if (listId === 'love') {
      return this.data.loveList;
    }
    const target = this.findPlaylist(listId);
    return target === null ? null : target.list;
  }

  private assignMusics(listId: string, musics: LxMusicInfoNew[]): void {
    if (listId === 'default') {
      this.data.defaultList = musics;
      return;
    }
    if (listId === 'love') {
      this.data.loveList = musics;
      return;
    }
    const target = this.findPlaylist(listId);
    if (target !== null) {
      target.list = musics;
    }
  }

  /** 歌曲信息被修订（list_music_update）：列表内、收藏、队列里同 id 的都换掉 */
  private replaceMusicEverywhere(id: string, musicInfo: LxMusicInfoNew): void {
    this.data.defaultList = replaceInList(this.data.defaultList, id, musicInfo);
    this.data.loveList = replaceInList(this.data.loveList, id, musicInfo);
    for (const item of this.data.userList) {
      item.list = replaceInList(item.list, id, musicInfo);
    }
  }

  /** 服务端要求整份替换不喜欢规则 */
  applyRemoteDislikeData(rules: string): void {
    this.applying = true;
    try {
      this.dislike = normalizeDislikeRules(rules);
    } finally {
      this.applying = false;
    }
    this.persistDislike();
  }

  /** 服务端推来的实时不喜欢动作 */
  applyRemoteDislikeAction(action: LxSyncAction): void {
    switch (action.action) {
      case 'dislike_data_overwrite':
        this.applyRemoteDislikeData(action.data as string);
        return;
      case 'dislike_music_add': {
        const infos: LxDislikeMusicInfo[] = action.data as LxDislikeMusicInfo[];
        if (infos === undefined || infos === null) {
          return;
        }
        let rules: string = this.dislike;
        for (const info of infos) {
          const name: string = info.name !== undefined && info.name !== null ? info.name : '';
          const singer: string = info.singer !== undefined && info.singer !== null ? info.singer : '';
          rules += `\n${name}${DISLIKE_NAME_SEP}${singer}`;
        }
        this.applyRemoteDislikeData(rules);
        return;
      }
      case 'dislike_music_clear':
        this.applyRemoteDislikeData('');
        return;
      default:
        hilog.warn(DOMAIN, TAG, 'unknown dislike action: %{public}s', action.action);
        return;
    }
  }

  // ------------------------------------------------------------ 落盘

  private persist(): void {
    this.store.saveListData(this.listData());
  }

  private persistDislike(): void {
    this.store.saveDislikeRules(this.dislike);
  }

  /** 列表同步完成：把当前数据当作「已上行」的基线 */
  onListSynced(): void {
    this.initialized = true;
    this.persist();
  }

  onDislikeSynced(): void {
    this.persistDislike();
  }

  getStore(): SyncStore {
    return this.store;
  }
}

// ------------------------------------------------------------------ 工具

/** 把 SongItem 列表转成同步用歌曲（丢掉不能同步的条目：本地歌 / 云端歌等非平台歌曲） */
function musicsOf(items: SongItem[], keepDuplicates: boolean = false): LxMusicInfoNew[] {
  const out: LxMusicInfoNew[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of items) {
    if (!isSyncable(item)) {
      continue;
    }
    const info: LxMusicInfoNew | null = toLxMusicInfo(item);
    if (info === null) {
      continue;
    }
    if (!keepDuplicates) {
      if (seen.has(info.id)) {
        continue;
      }
      seen.add(info.id);
    }
    out.push(info);
  }
  return out;
}

function idsOf(musics: LxMusicInfoNew[]): string[] {
  const out: string[] = [];
  if (musics === undefined || musics === null) {
    return out;
  }
  for (const info of musics) {
    out.push(info.id);
  }
  return out;
}

/** 判重键里隔开歌名与歌手的字符（与对外说明的「歌名·歌手」写法一致，只是个分隔符） */
const DUPLICATE_KEY_SEP: string = '·';

/** 一个收尾括号组：全角/半角圆括号、方括号、方头括号、尖括号都算「附注」（Live / 伴奏 / 重制版） */
const TRAILING_BRACKET_GROUP: RegExp = /[（(\[【〔<][^）)\]】〕>]*[）)\]】〕>]$/;

/** 标准化歌手拼回去用的分隔符，与 MusicSearch 的 normalizeSingers 一致 */
const SINGER_JOIN: string = '、';

/**
 * 判重用的标准化键：歌名·歌手（小写、去空白、去尾部括号组，如「晴天 (Live)」→「晴天」）
 *
 * 为什么判重落在「歌名 + 歌手」而不是条目 id：同一首歌在酷我 / QQ / 网易各有一条 id，
 * 从不同音源、不同搜索结果加进同一个歌单时 id 全不一样，只按 id 判重必然重复
 * （群反馈「歌单要加个删除重复歌曲」的根因之一）。
 *
 * 标准化规则：
 *   - 歌名、歌手都去空白并转小写 ——「晴天」「 晴天 」以及带全角空格的写法必须同键
 *     （JS 的 \s 本来就含全角空格 U+3000，不用再单列）；
 *   - 歌名去掉**尾部**括号组且允许连续多组：「晴天 (Live)」「晴天（伴奏）」「晴天(Live)(Remastered)」
 *     都归到「晴天」；括号在歌名中间的保留 —— 那是歌名本身的一部分，砍掉会把
 *     「A (B) C」和「A C」并成一回事，那是误删；
 *   - 歌手按 SINGER_SEPARATORS 拆开、各自标准化、排序后用「、」重拼，于是
 *     「周杰伦、方文山」与「方文山/周杰伦」是同一个键（口径与搜索页去重一致）；
 *   - 任一边为空就退化为只用非空的那一边；两边都空返回空串，调用方必须把空串视为
 *     **不可判重**、只用 id 判，否则所有缺歌名的条目会被并成一坨。
 *
 * 导出它是为了界面层「这首歌是不是已经在歌单里」的预检与将来的单测能复用同一口径，
 * 免得界面上写一份、库里写一份。
 */
export function duplicateKeyOf(name: string, singer: string): string {
  const song: string = normalizeDuplicateName(name);
  const artist: string = normalizeDuplicateSinger(singer);
  if (song.length === 0) {
    return artist;
  }
  if (artist.length === 0) {
    return song;
  }
  return `${song}${DUPLICATE_KEY_SEP}${artist}`;
}

/** 歌名标准化：去空白 → 小写 → 反复剥掉尾部括号组（剥完可能为空，交给调用方退化） */
function normalizeDuplicateName(name: string): string {
  if (name === undefined || name === null) {
    return '';
  }
  return stripTrailingBracketGroups(name.replace(/\s/g, '').toLowerCase());
}

/**
 * 剥掉尾部的括号组，直到尾部不再是括号组
 *
 * 循环而不是一次 replace：`/(…)$/` 去掉的最外层那组，后面可能还挂着一组
 * （「晴天 (Live) (Remastered)」）；一次只去一组会留下「晴天 (Live)」这种半成品键。
 */
function stripTrailingBracketGroups(text: string): string {
  let out: string = text;
  while (out.length > 0) {
    const next: string = out.replace(TRAILING_BRACKET_GROUP, '');
    if (next === out) {
      break;
    }
    out = next;
  }
  return out;
}

/** 歌手标准化：去空白 → 小写 → 按分隔符拆开 → 各自去重排序 → 用「、」重拼 */
function normalizeDuplicateSinger(singer: string): string {
  if (singer === undefined || singer === null) {
    return '';
  }
  const text: string = singer.replace(/\s/g, '').toLowerCase();
  if (text.length === 0) {
    return '';
  }
  if (!SINGER_SEPARATORS.test(text)) {
    return text;
  }
  const parts: string[] = text.split(SINGER_SEPARATORS);
  const cleaned: string[] = [];
  for (const part of parts) {
    if (part.length > 0 && !cleaned.includes(part)) {
      cleaned.push(part);
    }
  }
  cleaned.sort((a: string, b: string) => a.localeCompare(b));
  return cleaned.join(SINGER_JOIN);
}

function replaceInList(list: LxMusicInfoNew[], id: string, musicInfo: LxMusicInfoNew): LxMusicInfoNew[] {
  const out: LxMusicInfoNew[] = [];
  for (const info of list) {
    out.push(info.id === id ? musicInfo : info);
  }
  return out;
}

/**
 * 把 sourceListId 归一成规范的 `${平台}__${歌单id}`
 *
 * 为什么需要：老版本有一条导入入口把**整条分享链接**当 listId 传了进来，落库成了
 * `wy__https://music.163.com/playlist?id=2102211118&uct2=…`（本机 list.json 里实测就是
 * 这种，id 后缀 md5('wy__https://…') 与它完全对得上），而现在的解析器给的是
 * `wy__2102211118`。两者字面不等 —— 不归一的话，用户升级后对同一张歌单再导一次会被
 * 判成「没导入过」，又冒出一条同名歌单（就是「我的」页两条同名那条路）。
 *
 * 只做字符串层面的归一，不改任何已有数据；"链接 → 平台+id" 的规则直接复用
 * core/music/PlaylistLink 的解析器，免得平台正则出现第二份实现（酷狗 gcid、
 * 洛雪深链都由它兜住）。认不出的形态原样返回：宁可匹配不上，也不要匹配错。
 */
export function normalizeSourceListId(raw: string): string {
  const text: string = raw.trim();
  if (text.length === 0) {
    return '';
  }
  // 已经是规范形态（`wy__2102211118` / `kg__gcid_xxx`），直接用
  if (/^(kw|kg|mg|tx|wy)__[0-9A-Za-z_-]+$/.test(text)) {
    return text;
  }
  // `wy__https://…`：剥掉平台前缀，剩下的是链接
  const prefixed: RegExpMatchArray | null = text.match(/^(kw|kg|mg|tx|wy)__(.+)$/);
  const body: string = (prefixed !== null && prefixed[2] !== undefined) ? prefixed[2].trim() : text;
  if (!/^https?:\/\//i.test(body)) {
    return text;
  }
  const link: PlaylistLink | null = parseShareText(body);
  return link === null ? text : link.listId;
}

/** 按洛雪 buildUserListInfoFull 的字段顺序重建歌单信息 */
export function buildUserListInfo(item: LxUserListInfoFull): LxUserListInfo {
  const out: LxUserListInfo = {
    id: item.id,
    name: item.name,
    source: item.source,
    sourceListId: item.sourceListId,
    locationUpdateTime: item.locationUpdateTime,
  };
  return out;
}

/** 按洛雪 buildUserListInfoFull 的字段顺序重建整个歌单数组 */
function buildUserLists(list: LxUserListInfoFull[]): LxUserListInfoFull[] {
  const out: LxUserListInfoFull[] = [];
  for (const item of list) {
    const full: LxUserListInfoFull = {
      id: item.id,
      name: item.name,
      source: item.source,
      sourceListId: item.sourceListId,
      locationUpdateTime: item.locationUpdateTime,
      list: item.list,
    };
    out.push(full);
  }
  return out;
}

/** 把收到的列表数据补齐成完整结构（服务端可能省略字段） */
export function normalizeListData(input: LxListData): LxListData {
  const out: LxListData = defaultListData();
  if (input === undefined || input === null) {
    return out;
  }
  if (Array.isArray(input.defaultList)) {
    out.defaultList = input.defaultList;
  }
  if (Array.isArray(input.loveList)) {
    out.loveList = input.loveList;
  }
  if (Array.isArray(input.userList)) {
    const lists: LxUserListInfoFull[] = [];
    for (const item of input.userList) {
      if (item === null || item === undefined || item.id === undefined) {
        continue;
      }
      const full: LxUserListInfoFull = {
        id: item.id,
        name: item.name !== undefined ? item.name : item.id,
        source: item.source,
        sourceListId: item.sourceListId,
        locationUpdateTime: item.locationUpdateTime !== undefined ? item.locationUpdateTime : null,
        list: Array.isArray(item.list) ? item.list : [],
      };
      lists.push(full);
    }
    out.userList = lists;
  }
  return out;
}

/**
 * 规范化不喜欢规则（逐条对齐洛雪 updateDislikeInfo，保证 md5 与官方一致）
 *
 * 洛雪用 `let [name, singer] = item.split('@')`，只取前两段；这里保持一致。
 * 分隔符转义成 #、小写、去空白、按首次出现顺序去重，都是官方行为。
 */
export function normalizeDislikeRules(rules: string): string {
  if (rules === undefined || rules === null || rules.length === 0) {
    return '';
  }
  const list: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const item of rules.split('\n')) {
    if (item.length === 0) {
      continue;
    }
    const parts: string[] = item.split(DISLIKE_NAME_SEP);
    let name: string = parts.length > 0 ? parts[0] : '';
    let singer: string = parts.length > 1 ? parts[1] : '';
    if (name.length > 0) {
      name = replaceAll(name, DISLIKE_NAME_SEP, DISLIKE_NAME_ALIAS).toLowerCase().trim();
      if (singer.length > 0) {
        singer = replaceAll(singer, DISLIKE_NAME_SEP, DISLIKE_NAME_ALIAS).toLowerCase().trim();
        pushUnique(list, seen, `${name}${DISLIKE_NAME_SEP}${singer}`);
      } else {
        pushUnique(list, seen, name);
      }
    } else if (singer.length > 0) {
      const value: string = replaceAll(singer, DISLIKE_NAME_SEP, DISLIKE_NAME_ALIAS).toLowerCase().trim();
      pushUnique(list, seen, `${DISLIKE_NAME_SEP}${value}`);
    }
  }
  return list.join('\n');
}

function pushUnique(list: string[], seen: Set<string>, rule: string): void {
  if (rule.length === 0 || seen.has(rule)) {
    return;
  }
  seen.add(rule);
  list.push(rule);
}

function replaceAll(text: string, from: string, to: string): string {
  if (from.length === 0) {
    return text;
  }
  return text.split(from).join(to);
}

/** 在 position 处插入一批元素（不用展开运算符，ArkTS 不支持） */
function insertAt<T>(list: T[], position: number, items: T[]): void {
  let at: number = position;
  for (const item of items) {
    list.splice(at, 0, item);
    at++;
  }
}
