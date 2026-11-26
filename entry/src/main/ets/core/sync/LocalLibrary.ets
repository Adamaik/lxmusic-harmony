import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
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
 * 一次「跟随源歌单」对齐的结果
 *
 * added / removed 都是**条目条数**（不是去重后的首数）：源歌单里同一首歌出现两次、
 * 本地只留了一条时，added 会是 1；本地多留了一条时 removed 会是 1。
 */
export interface PlaylistSyncResult {
  /** 从源歌单补进来的条目数 */
  added: number;
  /** 因为源歌单里已经没有了而摘掉的条目数 */
  removed: number;
  /** 本地数据是否真的被改动（added / removed 至少一个不为 0） */
  changed: boolean;
  /**
   * 这次因为「源歌单看起来没拉全」而整体放弃（本地一个字都没动）
   *
   * 与 changed 分开是因为界面要说的话不一样：「没拉全」要提示，而「没差异」不该打扰。
   */
  aborted: boolean;
  /**
   * 因为**没有可靠的来源标记**而保留下来的条目数
   *
   * 全是「用户在本地手动加的同平台歌」：上次同步的源快照里没有它，就不可能是
   * 「源里删掉了它」，删了就是静默丢用户数据（这是 P0）。界面对这个数只做说明，不做操作。
   */
  preserved: number;
  /**
   * 需要用户确认之后才会删除的条目数（> 0 时本次**一首都没删**）
   *
   * 只有手动「从原歌单更新」会走到这里：计划先只落新增，删除等用户在弹窗里点确认，
   * 确认后调 {@link LocalLibrary.applyPendingSourceRemoval}。
   */
  pendingRemoval: number;
  /** 待确认删除的歌曲展示名（`歌名 - 歌手`，最多 SOURCE_REMOVAL_PREVIEW 条，弹窗里列给用户看） */
  pendingNames: string[];
}

/**
 * 打开歌单时最多多久回源对齐一次（10 分钟）
 *
 * 群反馈要的是「打开一次对齐一次」，不是后台轮询（那样既费流量又会被平台风控）。
 * 十分钟这个量级：用户改完源歌单再切回本应用基本都能对上，同时反复进出歌单
 * 不会把同一张歌单拉几十遍。
 */
export const SOURCE_SYNC_INTERVAL_MS: number = 10 * 60 * 1000;

/**
 * 「跟随源歌单」的自动删除闸门：一次要删的条目**超过 5 条或超过源条数的 3%** 就整体放弃
 *
 * 为什么这么紧（2026-11-23 审查结论）：旧口径是「> 30 条且 > 80%」，1050 首的歌单
 * 少 51 首仍算正常 —— 而 51 首正是「接口被砍到 999 条」那种典型的截断现场。
 * 2% 的容忍额度本来是给「平台上已下架、接口永远给不出」的那几首留的，
 * 但把它直接作用在**删除侧**，就等于允许一次静默删掉几十首。
 * 现在这个额度只留在拉取侧（playlistDetailTruncated）判断「这份是不是拉全了」，
 * 删除侧一律按「超过 5 条 / 超过 3% 就放弃」，把剩下的交给用户手动确认。
 */
const SOURCE_AUTO_REMOVE_MAX: number = 5;
/** 自动删除不得超过源条数的百分之几（超过就判「源可能没拉全」，整体放弃） */
const SOURCE_AUTO_REMOVE_RATIO_PCT: number = 3;

/** 弹窗里最多列几首「将要移除」的歌名（再多就只报总数，别把弹窗撑成一堵墙） */
const SOURCE_REMOVAL_PREVIEW: number = 5;

/** 「上次同步的源快照」落盘文件名（与 SyncStore 共用 lx_sync 目录，但**不进**同步数据） */
const SNAPSHOT_DIR: string = 'lx_sync';
const SNAPSHOT_FILE: string = 'source-snapshot.json';

/**
 * 「从链接导入」的歌单存导入链接的文件（与源侧快照同一个目录，同样**不进**同步数据）
 *
 * 为什么不把链接写进歌单本体（list.json / LxUserListInfoFull）：
 *   1. 那份数据要算 md5 与服务端、官方客户端对齐（`listDataMd5`），多一个字段就多一份
 *      协议风险 —— 别人算出来的 md5 和我们不一样，下次连同步就会弹「选择同步方式」；
 *   2. `SyncStore.normalizeUserList` 读回时只重建已知字段，未知字段会被丢掉，
 *      写进去也留不住。
 * 所以按本文件已有的先例（source-snapshot.json）走侧表：
 *   - 老数据没有这个文件 = 没有导入链接 = 普通歌单（界面上不显示「更新导入歌单」），
 *     天然向后兼容，不需要版本号迁移；
 *   - 记录只按歌单 id 存，歌单删掉时跟着清（见 saveImportLinks），id 复用时不会串。
 */
const IMPORT_LINK_FILE: string = 'import-link.json';

/**
 * 一张歌单的导入来源信息（只给「我的 - 歌单」长按菜单里的「更新导入歌单」用）
 *
 * 存在这里而不是歌单本体里的原因见 {@link IMPORT_LINK_FILE} 的说明。
 */
export interface ImportLink {
  /** 导入当时的链接（跟随短链后是最终地址；从在线歌单页直接导入时是按平台拼出来的长链接） */
  url: string;
  /** 平台 kw / kg / mg / tx / wy（与歌单的 source 一致） */
  platform: string;
  /** 记录时间（毫秒），仅用于排查 */
  importedAt: number;
}

/**
 * 某张歌单**上次同步时**源侧有哪些条目（键的多重集）
 *
 * 这是「能不能删」的**唯一依据**：本地某条同平台歌在当前源里找不到，只有当它出现在
 * 这份快照里时，才能解释成「源歌单把它删了」；快照里没有的（用户手动加进歌单的同平台歌、
 * 或者这张歌单还没同步过、没有快照）一律保留。没有来源标记就静默删除 = 丢用户数据。
 *
 * 存两份键：`ids`（平台__歌曲id）与 `names`（歌名·歌手）。平台给同一首歌换 id 时，
 * 名字那一份还能认出「它本来就在源里」，不会因为换了 id 就被当成手动加歌永久保留。
 */
interface SourceSnapshot {
  ids: string[];
  names: string[];
  /** 生成时间，仅用于排查（日志里打出来） */
  at: number;
}

/**
 * 一次「待用户确认」的删除计划
 *
 * 手动「从原歌单更新」时，只要需要删歌就先落成这个计划：本次只应用新增，
 * 删除等用户在弹窗里点「移除」。取消就直接丢掉（快照也不动，下次再问）。
 */
interface PendingRemoval {
  /** 去重后的歌曲 id（给 removeMusicFromPlaylist） */
  ids: string[];
  /** 每个 id 删几条（多重集口径，与 removeMusicFromPlaylist 的配额参数一致） */
  quota: Map<string, number>;
  /** 总条数（= 各配额之和） */
  count: number;
  /** 计划生成时源侧的快照：确认删除后写回，未确认前不写 */
  snapshotIds: string[];
  snapshotNames: string[];
}

/**
 * 一组重复歌曲里的一条（一条 = 歌单里的一行，不是「一首歌」）
 *
 * 面板要用它逐条展示、让用户点选「保留哪一条」，所以这里带的是**展示字段的快照**：
 * 面板不去回查库（那会重新读一遍整张歌单），也不额外请求任何网络数据 ——
 * 时长 / 平台 / 音质本来就在 SongItem 里。
 */
export interface DuplicateEntry {
  /** 这一行的歌曲 id（同 id 可以在组里出现多行：线上歌单本来就能把同一首加两遍） */
  id: string;
  name: string;
  singer: string;
  /** mm:ss；没有就是空串 */
  interval: string;
  /** 平台 kw/kg/mg/tx/wy，或本地 / 云盘的 source */
  source: string;
  /** 音质（如 320k / flac），没有就是空串 */
  quality: string;
}

/**
 * 一组重复歌曲（按歌名·歌手聚合，组内 >1）
 *
 * 只用于「检测并清理重复」，不改动任何数据：界面拿 keepId / duplicateIds / entries
 * 自己决定删不删，删除仍然走 removeMusicFromPlaylist 的上行分支。
 */
export interface DuplicateGroup {
  /** duplicateKeyOf 的结果（空串表示只能按 id 判重的条目，不参与分组） */
  key: string;
  /** 展示用歌名（组内第一条） */
  name: string;
  /** 展示用歌手（组内第一条） */
  singer: string;
  /** 组内总条数（= entries.length） */
  count: number;
  /** 默认建议保留的那条 id（列表中位置最靠前的一条） */
  keepId: string;
  /**
   * 默认建议删除的那几行 id（组内除第一条外全部）
   *
   * **可能含重复 id**：组里同一首歌被加了两遍时，两行 id 相同，删一行就得告诉库里
   * 「这个 id 只删 1 个副本」（见 removeDuplicateSongs 的配额口径）。
   */
  duplicateIds: string[];
  /** 组内每一行（列表顺序），面板据此让用户改「保留哪一条」 */
  entries: DuplicateEntry[];
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
  /**
   * 每张歌单「上次回源对齐的**尝试**时间」（毫秒）
   *
   * 只放内存：重启应用后第一次打开歌单会再对一次 —— 这正是用户想要的「打开就同步」，
   * 不是需要跨进程保留的状态。失败也记时间，见 beginSyncToSource。
   */
  private sourceSyncAt: Map<string, number> = new Map<string, number>();
  /** 正在回源对齐的歌单 id（同一张歌单同时只允许一个请求，见 beginSyncToSource） */
  private sourceSyncing: Set<string> = new Set<string>();
  /**
   * 应用上下文：只为「源侧快照」落盘用（SyncStore 不暴露写文件的口子，
   * 而快照绝不能塞进 list.json —— 那份数据要算 md5 与服务端对齐）
   */
  private context: common.Context | null = null;
  /** 每张歌单上次同步时的源侧键快照，懒加载（见 ensureSnapshots） */
  private snapshots: Map<string, SourceSnapshot> = new Map<string, SourceSnapshot>();
  private snapshotsLoaded: boolean = false;
  /**
   * 每张歌单「从链接导入」时的链接（懒加载，见 ensureImportLinks）
   *
   * 只有「导入过的歌单」有记录；自建歌单、老版本导入的歌单都没有 —— 界面据此决定
   * 长按菜单里要不要显示「更新导入歌单」。
   */
  private importLinks: Map<string, ImportLink> = new Map<string, ImportLink>();
  private importLinksLoaded: boolean = false;
  /** 手动同步里「等用户确认才删」的计划（同一张歌单同时只留一份） */
  private pendingRemovals: Map<string, PendingRemoval> = new Map<string, PendingRemoval>();

  init(context: common.Context): void {
    this.context = context;
    this.store.init(context);
    this.load();
  }

  load(): void {
    this.data = this.store.loadListData();
    this.dislike = normalizeDislikeRules(this.store.loadDislikeRules());
    this.initialized = this.store.hasListData();
    // 导入链接侧表在启动时读一次：长按菜单要按它决定显示哪几项，
    // 放到界面构建时再读就成了一次主线程文件 IO（文件很小，但没必要）
    this.ensureImportLinks();
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

  // ------------------------------------------------------------ 配置同步（收藏导出 / 并入）

  /**
   * 收藏的合成口径（favoriteSongs() 与 addFavorites() 共用，**只此一份**）
   *
   * 收藏里有两种条目：
   *   - 本地歌 / 云端歌：只存在于各自的侧表（见 sideSongsOf / LIST_ID_LOVE），同步数据里没有；
   *   - 在线歌：洛雪的 loveList。
   * 顺序与界面一致：侧表歌在前（本地在前、云端在后），在线歌按 loveList 原顺序。
   */
  private favoriteSongsOf(): SongItem[] {
    const out: SongItem[] = [];
    for (const song of this.sideSongsOf(LIST_ID_LOVE)) {
      out.push(song);
    }
    for (const info of this.data.loveList) {
      out.push(fromLxMusicInfo(info));
    }
    return out;
  }

  /**
   * 导出一份收藏名单（与 mirrorToSession() 里合成 favorites 的口径完全一致）
   *
   * 口径必须是同一份，否则「导出 → 换机恢复」会丢歌（实现见 favoriteSongsOf）。
   * 未加载过本地库（首次安装 / init 之前）时安全返回空数组。
   */
  favoriteSongs(): SongItem[] {
    if (!this.initialized) {
      return [];
    }
    return this.favoriteSongsOf();
  }

  /**
   * 把一批在线歌并入收藏（配置同步「恢复收藏」用），返回真正新增的条数
   *
   * 判重口径与 onLocalListsChanged() 完全一致：只看同步结构的 id（musicIdOf 算出来的
   * `${source}_${songmid}`、酷狗是 `${songmid}_${hash}`）。同一首歌从不同平台回来 id 不同，
   * 协议上本来就是两条，这里也照协议来 —— 不再按歌名·歌手兜底（那是「加歌到歌单」的界面口径）。
   *
   * 只收在线歌：本地歌 / 云端歌在同步结构里不存在，musicsOf 会把它们丢掉；收藏里属于
   * 侧表的那部分由 syncSideFavorites 负责，本方法不碰。也不改动播放队列（刷新时把当前队列
   * 原样传回 adoptLibraryState，见下）。
   *
   * 一条都没新增时不落盘、不刷新：配置同步是周期性的，没变化就不该写文件、抖界面。
   *
   * **不 emitOverwrite / 不上行洛雪动作**：这次跨设备搬运由 WebDAV 配置文件负责。
   * 但本地数据必须落盘（persist）—— 否则重启就丢，等于白搬。
   *
   * 刷新刻意**不走 mirrorToSession()**：那个方法会按 defaultList 重建界面播放队列，
   * 而恢复配置时用户可能正播着一个本地 / 临时队列（不在洛雪同步数据里），一换就把正在听的
   * 队列顶掉。这里只换收藏：把当前队列原样传回 adoptLibraryState，队列条目一个字都不动。
   */
  addFavorites(items: SongItem[]): number {
    if (items === undefined || items === null || items.length === 0) {
      return 0;
    }
    // 只留能进同步结构的在线歌；本批内部的重复 id 也在这里被吃掉
    const musics: LxMusicInfoNew[] = musicsOf(items);
    if (musics.length === 0) {
      return 0;
    }
    if (musics.length < items.length) {
      hilog.info(DOMAIN, TAG, 'addFavorites: skipped %{public}d non-online/duplicate item(s)',
        items.length - musics.length);
    }
    // 已经在收藏里的（按 id）先占位，判据与 onLocalListsChanged 一致
    const existed: Set<string> = new Set<string>();
    for (const info of this.data.loveList) {
      existed.add(info.id);
    }
    const added: LxMusicInfoNew[] = [];
    for (const info of musics) {
      if (existed.has(info.id)) {
        continue;
      }
      existed.add(info.id);
      added.push(info);
    }
    if (added.length === 0) {
      return 0;   // 全都在收藏里了：不写盘、不刷新
    }
    // 新加的排最前（保持传入顺序），与「往歌单里加歌」的既有规则一致（ADD_MUSIC_TOP）；
    // 收藏里原有的条目顺序一个都不动
    this.data.loveList = added.concat(this.data.loveList);
    // 落盘：走本文件既有的持久化入口（list.json，与洛雪同步的是同一份数据）
    this.persist();
    // 落过库了就不再是「首次安装」，与 load() / onListSynced() 的口径一致
    this.initialized = true;
    // 刷新界面：**只换收藏，队列原样传回去**（理由见方法注释，避免顶掉正在播的队列）。
    // adoptLibraryState 内部有 adoptingLibrary 守卫，不会反过来触发上行。
    this.applying = true;
    try {
      const session: PlaySession = PlaySession.getInstance();
      session.adoptLibraryState(session.queue, this.favoriteSongsOf());
    } finally {
      this.applying = false;
    }
    this.bumpLibraryVersion();
    return added.length;
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

  /**
   * 这张歌单「从链接导入」时存下的链接；自建歌单 / 老版本导入的歌单返回 null
   *
   * 「我的 - 歌单」的长按菜单靠它决定要不要多出「更新导入歌单」：**只有这里有记录才显示**。
   * 老数据（升级前导入的歌单）在侧表里没有记录，按需求当普通歌单处理 ——
   * 不去猜「有 sourceListId 就算导入过」，因为猜错了会给手建歌单凭空长出一个用不了的入口。
   */
  importLinkOf(id: string): ImportLink | null {
    this.ensureImportLinks();
    const link: ImportLink | undefined = this.importLinks.get(id);
    if (link === undefined) {
      return null;
    }
    // 返回副本：调用方拿去展示 / 重新解析，改不到库里这份
    return { url: link.url, platform: link.platform, importedAt: link.importedAt };
  }

  /**
   * 记录（或覆盖）一张歌单的导入链接
   *
   * 同一个线上歌单再导一次时 id 不变，直接覆盖成这次用的链接：用户换了分享方式
   * （短链 / 长链）重导，侧表里留的就该是最近一次真正用过的那个。
   */
  private recordImportLink(id: string, url: string, platform: string): void {
    const clean: string = url.trim();
    if (clean.length === 0 || platform.length === 0) {
      return;
    }
    this.ensureImportLinks();
    // 对象字面量先落到显式类型的变量上：ArkTS 不允许字面量直接从参数位置推断类型
    const entry: ImportLink = { url: clean, platform: platform, importedAt: Date.now() };
    this.importLinks.set(id, entry);
    this.saveImportLinks();
  }

  // ------------------------------------------------------------ 导入链接（落盘）

  /**
   * 懒加载导入链接侧表
   *
   * 与源侧快照同一套做法：读不出来 / 读坏了都只是「没有导入链接」，绝不抛错 ——
   * 侧表坏了不该让歌单本身打不开。
   */
  private ensureImportLinks(): void {
    if (this.importLinksLoaded) {
      return;
    }
    this.importLinksLoaded = true;
    const ctx: common.Context | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const target: string = `${ctx.filesDir}/${SNAPSHOT_DIR}/${IMPORT_LINK_FILE}`;
      if (!fs.accessSync(target)) {
        return;
      }
      const text: string = fs.readTextSync(target);
      const raw: Record<string, ImportLink> = JSON.parse(text) as Record<string, ImportLink>;
      for (const key of Object.keys(raw)) {
        const entry: ImportLink | undefined = raw[key];
        if (entry === undefined || entry === null) {
          continue;
        }
        const url: string = typeof entry.url === 'string' ? entry.url.trim() : '';
        const platform: string = typeof entry.platform === 'string' ? entry.platform.trim() : '';
        if (url.length === 0 || platform.length === 0) {
          continue;
        }
        const normalized: ImportLink = {
          url: url,
          platform: platform,
          importedAt: typeof entry.importedAt === 'number' ? entry.importedAt : 0,
        };
        this.importLinks.set(key, normalized);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load import link failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 落盘导入链接侧表，顺手清掉**已经不存在**的歌单的记录
   *
   * 为什么要清：本地歌单 id 是 `user_list_<时间戳>`，删了再建有可能撞回同一个 id
   * （同毫秒连点两下时），记录留着就会让新建的自建歌单莫名多出「更新导入歌单」，
   * 甚至按上一条歌单的链接把歌拉进来 —— 串数据比少一个入口严重得多。
   */
  private saveImportLinks(): void {
    this.ensureImportLinks();
    const ctx: common.Context | null = this.context;
    if (ctx === null) {
      return;
    }
    // 只保留还活着的歌单的链接
    const alive: Map<string, ImportLink> = new Map<string, ImportLink>();
    for (const item of this.data.userList) {
      const link: ImportLink | undefined = this.importLinks.get(item.id);
      if (link !== undefined) {
        alive.set(item.id, link);
      }
    }
    this.importLinks = alive;
    try {
      const dir: string = `${ctx.filesDir}/${SNAPSHOT_DIR}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const out: Record<string, ImportLink> = {};
      for (const item of this.data.userList) {
        const link: ImportLink | undefined = alive.get(item.id);
        if (link !== undefined) {
          out[item.id] = link;
        }
      }
      const handle = fs.openSync(`${dir}/${IMPORT_LINK_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(out));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save import link failed: %{public}s', JSON.stringify(e));
    }
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
   * @param importUrl 导入时用的链接（空串 = 没有链接可存，比如以后有别的入口直接给 id）。
   *   非空时记进导入链接侧表（见 IMPORT_LINK_FILE），「我的 - 歌单」长按菜单据此
   *   显示「更新导入歌单」。**不进歌单本体**：那份数据参与同步 md5，不能加字段。
   */
  importPlaylist(name: string, source: string, sourceListId: string,
    items: SongItem[], importUrl: string = ''): PlaylistSummary | null {
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
      // 刚按源歌单写了一遍，十分钟内不必再回源对齐（打开歌单时的自动同步会看这个时间戳）
      this.sourceSyncAt.set(targetId, Date.now());
      // 这次导入用的链接覆盖旧的：「更新导入歌单」以后按最近一次真正用过的链接回源
      this.recordImportLink(targetId, importUrl, source);
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
    // 刚导入就是源歌单的完整快照：十分钟内打开它不必立刻再拉一遍
    this.sourceSyncAt.set(id, Date.now());
    this.recordImportLink(id, importUrl, source);
    return { id: id, name: name, count: musics.length };
  }

  // ------------------------------------------------------------ 跟随源歌单（打开即对齐）

  /**
   * 打开歌单时是否该回源对齐一次
   *
   * 群反馈（2026-11-20 15:19，CharlotteZero）：「他的导入好像是实时的」「我 qq 里面删除，
   * 他这边也自动删除」，小冰补「打开一次同步一次？多就加，少就删」。所以要的是
   * **打开时对齐**，不是后台轮询 —— 节流就落在这里：同一张歌单距上次**尝试**
   * （不管成败）超过 SOURCE_SYNC_INTERVAL_MS 才再拉一次。
   */
  shouldSyncToSource(id: string): boolean {
    if (this.sourceSyncing.has(id)) {
      return false;
    }
    const last: number | undefined = this.sourceSyncAt.get(id);
    if (last === undefined) {
      return true;
    }
    return Date.now() - last >= SOURCE_SYNC_INTERVAL_MS;
  }

  /**
   * 占坑：同一张歌单同一时刻只允许一个回源请求
   *
   * 手动「从原歌单更新」与打开歌单的自动对齐走同一条链路，两边同时跑就是把同一张歌单
   * 拉两遍，而且各自拿着**旧快照**去对齐对方刚改过的列表 —— 轻则重复加歌，重则互相删掉。
   *
   * **顺手把「上次尝试时间」记成现在**：失败也要记，否则离线时每进出一次歌单就重试一遍。
   * @returns true = 拿到了这次同步的执行权，必须配对调用 endSyncToSource
   */
  beginSyncToSource(id: string): boolean {
    if (this.sourceSyncing.has(id)) {
      return false;
    }
    this.sourceSyncAt.set(id, Date.now());
    this.sourceSyncing.add(id);
    return true;
  }

  /** 放开占坑（放 finally 里调，失败路径也要走） */
  endSyncToSource(id: string): void {
    this.sourceSyncing.delete(id);
  }

  /**
   * 把「源歌单当前的内容」对齐到本地这张歌单
   *
   * 语义就是「跟随源歌单」（派音 / 洛雪那套）：源里有的补进来，源里已经删掉的摘掉，
   * 其余内容原样不动。四条硬约束：
   *
   *   1. **只动本来就从这张源歌单导入的那部分**：只处理 `source === 歌单的 source`
   *      的在线歌。别的平台的手动加歌、本地歌 / 云端歌 / 听书条目一律不参与 ——
   *      它们本来就不在源歌单里，「源里没有」不构成删除理由（误删本地条目是最坏的后果）。
   *      侧表（LocalMusic / WebDavLibrary）的成员本来就不在 target.list 里，天然不受影响。
   *   2. **多重集对齐，不按 id 去重**：上一批特意允许歌单里有合法重复（导入时同一首歌
   *      出现两次就存两条）。所以「源里有 N 条 → 本地留 N 条」，多退少补，
   *      绝不因为「这个 id 已经有了」把第二条吃掉。
   *   3. **没有来源标记就不删（P0）**：同平台的歌也可能是用户手动加进来的（他在网易歌单里
   *      从网易再加一首），从条目本身看不出它「来自源歌单」。所以删除只认
   *      {@link SourceSnapshot}：只有「上次同步时源里有过、这次源里没有」的条目才允许删，
   *      快照里没有的一律 preserved。没有快照时（第一次对齐 / 老用户升级上来）本次只加不删，
   *      对齐完把快照存下来，下一次才有删除依据。
   *   4. **拉不全就整体放弃 / 删之前先问**：自动路径一次删超过 5 条或超过源条数 3% 就返回
   *      aborted 且一个字都不改；源歌单与本地**一条都对不上**时也放弃（那更像整张换掉 /
   *      指错歌单，按源删本地等于清空用户歌单）。手动路径不设条数闸门，但**先不删**：
   *      返回 pendingRemoval 与待删清单，由界面确认后走 applyPendingSourceRemoval。
   *
   * 匹配口径：先 `source + songId`（compositeMatchIdOf），对不上的再按「歌名·歌手」
   * （duplicateKeyOf，与加歌判重、重复检测完全同一套口径）兜一层 —— 平台偶尔会给同一首歌
   * 换 id（重新上架 / 版权变动），只按 id 比就会把它算成「删一条 + 加一条」，
   * 用户的播放次数、排序位置都会跟着丢。
   *
   * @param sourceSongs 刚从源歌单拉回来的全量歌曲（顺序即源歌单顺序）
   * @param manual true = 用户点「从原歌单更新」：要删歌时**先不删**，落成待确认计划
   *               （见 applyPendingSourceRemoval）；false = 打开歌单时的后台对齐
   */
  syncWithSource(listId: string, sourceSongs: SongItem[], manual: boolean): PlaylistSyncResult {
    const unchanged: PlaylistSyncResult = {
      added: 0, removed: 0, changed: false, aborted: false, preserved: 0,
      pendingRemoval: 0, pendingNames: [],
    };
    // 上一轮留下的「待确认删除」先作废：这一轮的差异要按最新的源重新算
    this.pendingRemovals.delete(listId);
    const target = this.findPlaylist(listId);
    if (target === null) {
      return unchanged;
    }
    const platform: string = target.source !== undefined && target.source !== null ? target.source : '';
    if (platform.length === 0) {
      return unchanged;
    }
    // 源歌单的条目：**保留重复**（keepDuplicates = true），多重集口径的前提
    const incoming: LxMusicInfoNew[] = musicsOf(sourceSongs, true);
    if (incoming.length === 0) {
      // 源是空的：一律不动。宁可这次不同步，也不能按空结果把本地删干净
      hilog.warn(DOMAIN, TAG, 'source list %{public}s returned empty, skip align', listId);
      return unchanged;
    }

    // ---- 本地：只挑出「同平台的在线歌」，并记下它们各自的匹配键
    const localItems: LxMusicInfoNew[] = [];
    const localIdKeys: string[] = [];
    const localNameKeys: string[] = [];
    for (const info of target.list) {
      if (info.source !== platform) {
        continue;
      }
      localItems.push(info);
      localIdKeys.push(compositeMatchIdOf(info));
      localNameKeys.push(duplicateKeyOf(info.name, info.singer));
    }
    if (localItems.length === 0) {
      // 本地这条歌单里一首同平台的歌都没有（可能全是本地歌 / 别的平台）：不猜，什么都不做
      return unchanged;
    }

    // ---- 源侧索引：每个匹配键对应「源里的第几条」，用来做一对一（多重集）配对
    // 顺手把这次的源侧键收集成快照（同步成功后落盘），下次判断「源里是不是真删了」用
    const nextIds: string[] = [];
    const nextNames: string[] = [];
    const claimed: boolean[] = [];
    const srcIds: Map<string, number[]> = new Map<string, number[]>();
    const srcNames: Map<string, number[]> = new Map<string, number[]>();
    for (let i = 0; i < incoming.length; i++) {
      claimed.push(false);
      const info: LxMusicInfoNew = incoming[i];
      const idKey: string = compositeMatchIdOf(info);
      pushIndex(srcIds, idKey, i);
      nextIds.push(idKey);
      const nameKey: string = duplicateKeyOf(info.name, info.singer);
      if (nameKey.length > 0) {
        pushIndex(srcNames, nameKey, i);
        nextNames.push(nameKey);
      }
    }

    /**
     * 上次同步的源侧快照：**删除的唯一依据**
     *
     * 没有这份快照（第一次对齐 / 老版本升级上来）时一律当「没有来源标记」：
     * 本次只加不删，对齐完把快照存下来，从下一次开始才有删除的依据。
     */
    this.ensureSnapshots();
    const prev: SourceSnapshot | undefined = this.snapshots.get(listId);
    let prevIds: Map<string, number> = new Map<string, number>();
    let prevNames: Map<string, number> = new Map<string, number>();
    if (prev !== undefined) {
      prevIds = countKeys(prev.ids);
      prevNames = countKeys(prev.names);
    }

    // ---- 第一轮：本地每条歌按 id 去源里认领一条（同一 id 的第 N 条认领源里的第 N 条）
    const kept: boolean[] = [];
    let matchedCount: number = 0;
    for (let i = 0; i < localItems.length; i++) {
      const at: number = takeUnclaimed(srcIds.get(localIdKeys[i]), claimed);
      if (at >= 0) {
        claimed[at] = true;
        kept.push(true);
        matchedCount++;
      } else {
        kept.push(false);
      }
    }
    // ---- 第二轮：按「歌名·歌手」兜（平台给同一首歌换了 id 时别当成一删一加）
    for (let i = 0; i < localItems.length; i++) {
      if (kept[i] || localNameKeys[i].length === 0) {
        continue;
      }
      const at: number = takeUnclaimed(srcNames.get(localNameKeys[i]), claimed);
      if (at >= 0) {
        claimed[at] = true;
        kept[i] = true;
        matchedCount++;
      }
    }

    /**
     * 快照配额：**已经对上的条目也要消耗配额**
     *
     * 源里 1 条 A、本地 2 条 A（一条导入 + 一条手动加）时，第一条认领后若不消耗，
     * 第二条就会把「源里确实有过 A」的配额再用一次而被删掉 —— 那正是要修的那个 P0。
     * id 与「歌名·歌手」两份配额独立扣减，所以下面两行都要走一遍（不能短路）。
     */
    for (let i = 0; i < localItems.length; i++) {
      if (!kept[i]) {
        continue;
      }
      takeCount(prevIds, localIdKeys[i]);
      takeCount(prevNames, localNameKeys[i]);
    }

    // ---- 差异：本地没被认领的，**只有快照能证明它来自源**时才算「源里已经删掉」
    const removalQuota: Map<string, number> = new Map<string, number>();
    const removalIds: string[] = [];
    const removalNames: string[] = [];
    let removedCount: number = 0;
    let preserved: number = 0;
    for (let i = 0; i < localItems.length; i++) {
      if (kept[i]) {
        continue;
      }
      const info: LxMusicInfoNew = localItems[i];
      // 两份配额都要扣：只要有一份还剩下「它本来就在源里」的凭据，就可以删
      const hadId: boolean = takeCount(prevIds, localIdKeys[i]);
      const hadName: boolean = takeCount(prevNames, localNameKeys[i]);
      if (!hadId && !hadName) {
        // 没有来源标记 = 用户手动加进这张歌单的同平台歌（或这张歌单还没有快照）：保留
        preserved++;
        continue;
      }
      removedCount++;
      removalQuota.set(info.id, (removalQuota.get(info.id) ?? 0) + 1);
      if (!removalIds.includes(info.id)) {
        removalIds.push(info.id);
      }
      if (removalNames.length < SOURCE_REMOVAL_PREVIEW) {
        removalNames.push(removalLabelOf(info));
      }
    }
    // 源里没被本地认领的 = 源里新增的（顺序即源歌单顺序，统一放到最前面，与加歌规则一致）
    const additions: LxMusicInfoNew[] = [];
    for (let i = 0; i < incoming.length; i++) {
      if (!claimed[i]) {
        additions.push(incoming[i]);
      }
    }
    if (removedCount === 0 && additions.length === 0) {
      // 无差异：源头拉全了（上面的闸门没拦住），把快照刷成这次的源，下次删除才有依据
      this.setSnapshot(listId, nextIds, nextNames);
      return unchanged;
    }
    // 一条都对不上：更像是「源歌单被整张换掉 / sourceListId 指到了别的歌单」，而不是正常增删。
    // 这种时候按源删本地 = 清空用户歌单，收益远小于代价，宁可这次不对齐（下次再对）。
    if (matchedCount === 0) {
      hilog.warn(DOMAIN, TAG, 'align %{public}s aborted: no overlap with source (%{public}d)',
        listId, localItems.length);
      return { added: 0, removed: 0, changed: false, aborted: true, preserved: preserved,
        pendingRemoval: 0, pendingNames: [] };
    }
    /**
     * 自动路径的删除闸门：本次要删的条目**超过 5 条、或超过源条数的 3%** 就不删
     *
     * 旧口径是「> 30 条且 > 80%」，1050 首少 51 首仍算正常 —— 而 51 首正是「接口被砍到
     * 999 条」的典型截断现场。收紧到 5 条 / 3% 之后，任何「成规模」的删除都不会由
     * 后台自动完成，只能由用户点「从原歌单更新」并确认。
     *
     * **但新增照做**：新增是纯增量，加进去不会丢任何东西；如果连新增一起放弃，
     * 「源里删了 4 首、又加了 3 首」会让这张歌单以后永远收不到新歌（每次都超过 3% 被拦）。
     * 快照也不在这里更新：源可能真没拉全，留着旧快照下次才好继续判断。
     */
    if (!manual && removedCount > 0) {
      const ratioLimit: number = Math.ceil(incoming.length * SOURCE_AUTO_REMOVE_RATIO_PCT / 100);
      if (removedCount > SOURCE_AUTO_REMOVE_MAX || removedCount > ratioLimit) {
        hilog.warn(DOMAIN, TAG,
          'align %{public}s: skip removal %{public}d of %{public}d (auto limit %{public}d)',
          listId, removedCount, incoming.length, ratioLimit);
        hilog.warn(DOMAIN, TAG, 'align %{public}s: keep local, apply %{public}d additions only',
          listId, additions.length);
        this.applySourceAdditions(listId, additions);
        return { added: additions.length, removed: 0, changed: additions.length > 0, aborted: true,
          preserved: preserved, pendingRemoval: 0, pendingNames: [] };
      }
    }

    // ---- 落地：先删后加。删除复用 removeMusicFromPlaylist 的配额口径（上行 / 落盘 /
    // 界面镜像都在那里），加歌**不能**走 addMusicToPlaylist —— 那个按 id 判重，
    // 源里出现两次的同一首歌会被吃掉一条（见约束 2）。
    let appliedRemovals: number = 0;
    let pendingRemoval: number = 0;
    if (removedCount > 0) {
      if (manual) {
        /**
         * 手动路径：**先不删**。把「删哪些、删几条」落成计划，新增照常应用（纯增量不丢东西），
         * 由界面弹窗列给用户确认；确认后走 applyPendingSourceRemoval，取消走 discard。
         */
        const plan: PendingRemoval = {
          ids: removalIds,
          quota: removalQuota,
          count: removedCount,
          snapshotIds: nextIds,
          snapshotNames: nextNames,
        };
        this.pendingRemovals.set(listId, plan);
        pendingRemoval = removedCount;
      } else {
        this.removeMusicFromPlaylist(listId, removalIds, removalQuota);
        appliedRemovals = removedCount;
      }
    }
    this.applySourceAdditions(listId, additions);
    // 有「待确认删除」时快照先不刷：用户可能取消，取消了下次还得能认出这些条目本来在源里
    if (pendingRemoval === 0) {
      this.setSnapshot(listId, nextIds, nextNames);
    }
    return {
      added: additions.length,
      removed: appliedRemovals,
      changed: appliedRemovals > 0 || additions.length > 0,
      aborted: false,
      preserved: preserved,
      pendingRemoval: pendingRemoval,
      pendingNames: pendingRemoval > 0 ? removalNames : [],
    };
  }

  /**
   * 把「源里新增的条目」放到歌单最前面（与 addMusicToPlaylist 的位置规则一致）
   *
   * 两处共用：正常对齐的落地，以及「删除被闸门拦下、但新增还要照做」的自动路径。
   */
  private applySourceAdditions(listId: string, additions: LxMusicInfoNew[]): void {
    if (additions.length === 0) {
      return;
    }
    // 删除那一步换掉了 list 数组，必须重新取一次引用
    const after = this.findPlaylist(listId);
    if (after === null) {
      return;
    }
    after.list = additions.concat(after.list);
    this.persist();
    this.mirrorToSession();
    const data: LxListMusicAddData = {
      id: listId,
      musicInfos: additions,
      addMusicLocationType: ADD_MUSIC_TOP,
    };
    this.emit({ action: 'list_music_add', data: data }, 'list');
  }

  /**
   * 应用「待确认的删除」
   *
   * 只给手动「从原歌单更新」用：用户在弹窗里点了「移除」才调。删完把源快照刷成这次的源
   * （这是用户明确认过的状态）。返回真正删掉的条目数。
   */
  applyPendingSourceRemoval(listId: string): number {
    const plan: PendingRemoval | undefined = this.pendingRemovals.get(listId);
    if (plan === undefined) {
      return 0;
    }
    this.pendingRemovals.delete(listId);
    this.removeMusicFromPlaylist(listId, plan.ids, plan.quota);
    this.setSnapshot(listId, plan.snapshotIds, plan.snapshotNames);
    return plan.count;
  }

  /**
   * 放弃「待确认的删除」：本地一首都不动
   *
   * 但快照要刷成**这次的源**：用户已经明确选了「保留」，这些歌从此不再算「源里删掉的」，
   * 否则十分钟后打开歌单时，后台自动同步又会按旧快照把它们删掉（≤5 条能直接穿过闸门）——
   * 那等于把用户刚才的「保留」当没发生过。
   */
  discardPendingSourceRemoval(listId: string): void {
    const plan: PendingRemoval | undefined = this.pendingRemovals.get(listId);
    this.pendingRemovals.delete(listId);
    if (plan !== undefined) {
      this.setSnapshot(listId, plan.snapshotIds, plan.snapshotNames);
    }
  }

  /** 这张歌单是不是有一次「等确认才删」的对齐结果（界面用来决定要不要弹窗） */
  hasPendingSourceRemoval(listId: string): boolean {
    return this.pendingRemovals.has(listId);
  }

  // ------------------------------------------------------------ 源侧快照（落盘）

  /**
   * 懒加载源侧快照
   *
   * 放磁盘而不是只放内存：重启后第一次打开歌单就没有快照的话，那次「只加不删」
   * 会把源里真删掉的条目永久留下来（下一次它的键已不在快照里，再也无法判成「源里删了」）。
   */
  private ensureSnapshots(): void {
    if (this.snapshotsLoaded) {
      return;
    }
    this.snapshotsLoaded = true;
    const ctx: common.Context | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const target: string = `${ctx.filesDir}/${SNAPSHOT_DIR}/${SNAPSHOT_FILE}`;
      if (!fs.accessSync(target)) {
        return;
      }
      const text: string = fs.readTextSync(target);
      const raw: Record<string, SourceSnapshot> = JSON.parse(text) as Record<string, SourceSnapshot>;
      for (const key of Object.keys(raw)) {
        const entry: SourceSnapshot | undefined = raw[key];
        if (entry === undefined || entry === null) {
          continue;
        }
        const ids: string[] = Array.isArray(entry.ids) ? entry.ids : [];
        const names: string[] = Array.isArray(entry.names) ? entry.names : [];
        if (ids.length === 0 && names.length === 0) {
          continue;
        }
        this.snapshots.set(key, {
          ids: ids,
          names: names,
          at: typeof entry.at === 'number' ? entry.at : 0,
        });
      }
    } catch (e) {
      // 快照读坏了不是致命问题：当没有快照处理（本次只加不删），下次同步会重写一份
      hilog.warn(DOMAIN, TAG, 'load source snapshot failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 刷新某张歌单的源侧快照并落盘 */
  private setSnapshot(listId: string, ids: string[], names: string[]): void {
    const snap: SourceSnapshot = { ids: ids, names: names, at: Date.now() };
    this.snapshots.set(listId, snap);
    this.saveSnapshots();
  }

  /** 把快照写回沙箱（顺手清掉已经删掉的歌单，别让文件无限长） */
  private saveSnapshots(): void {
    const ctx: common.Context | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const dir: string = `${ctx.filesDir}/${SNAPSHOT_DIR}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const alive: Map<string, SourceSnapshot> = new Map<string, SourceSnapshot>();
      const out: Record<string, SourceSnapshot> = {};
      for (const item of this.data.userList) {
        const snap: SourceSnapshot | undefined = this.snapshots.get(item.id);
        if (snap === undefined) {
          continue;
        }
        alive.set(item.id, snap);
        out[item.id] = snap;
      }
      this.snapshots = alive;
      const handle = fs.openSync(`${dir}/${SNAPSHOT_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(out));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save source snapshot failed: %{public}s', JSON.stringify(e));
    }
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
    // 导入链接侧表同理：歌单删了，记录必须跟着走（本地歌单 id 可能被复用，留着会串）
    this.saveImportLinks();
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
   *
   * @param keepDuplicates true = **不做重复判定**，按传入的条目原样追加
   *
   *   只给「换机导入歌单」用：导出刻意保留了歌单里的重复条目（同一首歌两行），
   *   导入时如果还按 id / 歌名判重，那些重复会被静默吃掉 —— 用户换台手机，歌单就少了几首。
   *   默认 false，其余所有调用（添加单曲、批量添加到歌单）行为不变。
   */
  addMusicToPlaylist(id: string, items: SongItem[], keepDuplicates: boolean = false): AddMusicResult {
    const target = this.findPlaylist(id);
    if (target === null) {
      return { added: 0, skipped: 0 };
    }
    // 侧表歌已经在歌单里的，也算「重复跳过」；先数再写，顺序不能反（见 sideSkippedCount）
    const sideSkipped: number = this.sideSkippedCount(id, items);
    // 本地歌 / 云端歌走侧表（它们不属于同步结构，musicsOf 会把它们丢掉）
    const localAdded: number = this.addToSideTables(id, items);
    // keepDuplicates 时连**这一批内部**的重复也要留着（musicsOf 默认会按 id 去重）
    const musics: LxMusicInfoNew[] = musicsOf(items, keepDuplicates);
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
      if (!keepDuplicates) {
        if (existed.has(info.id)) {
          skipped++;
          continue;
        }
        const nameKey: string = duplicateKeyOf(info.name, info.singer);
        if (nameKey.length > 0 && existedKeys.has(nameKey)) {
          skipped++;
          continue;
        }
      }
      existed.add(info.id);
      const key: string = duplicateKeyOf(info.name, info.singer);
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
   *
   * `quota` 只给「检查重复歌曲」用：按 id 的删除天生一删删掉该 id 的所有行，而歌单里
   * 同一首歌可以被加两遍（导入刻意保留，见 importPlaylist）。传了配额就只删「这个 id
   * 的 N 个副本」；不传保持原有语义（这个 id 在歌单里有几行就删几行），其它调用点一个字
   * 都不用改。
   */
  removeMusicFromPlaylist(id: string, songIds: string[], quota?: Map<string, number>): void {
    if (songIds.length === 0) {
      return;
    }
    if (this.isBuiltinPlaylist(id)) {
      this.removeMusicFromLove(songIds, quota);
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
    // 每个 id 已经删掉几行：配额缺省（-1）表示不限，与按 id 全删的旧行为一致
    const taken: Map<string, number> = new Map<string, number>();
    for (const info of target.list) {
      if (!songIds.includes(info.id)) {
        remains.push(info);
        continue;
      }
      const limit: number = quota === undefined ? -1 : (quota.get(info.id) ?? 0);
      const used: number = taken.get(info.id) ?? 0;
      if (limit < 0 || used < limit) {
        taken.set(info.id, used + 1);
        // 上行只报 id：同 id 删两行时不必把 id 在数组里重复两遍
        if (!removedIds.includes(info.id)) {
          removedIds.push(info.id);
        }
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
  private removeMusicFromLove(songIds: string[], quota?: Map<string, number>): void {
    const localRemoved: number = this.removeFromSideTables(LIST_ID_LOVE, songIds);
    const remains: LxMusicInfoNew[] = [];
    const taken: Map<string, number> = new Map<string, number>();
    for (const info of this.data.loveList) {
      if (!songIds.includes(info.id)) {
        remains.push(info);
        continue;
      }
      const limit: number = quota === undefined ? -1 : (quota.get(info.id) ?? 0);
      const used: number = taken.get(info.id) ?? 0;
      if (limit < 0 || used < limit) {
        taken.set(info.id, used + 1);
        continue;
      }
      remains.push(info);
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
   * **不再跳过同 id 的第二行**：歌单导入刻意保留了「线上歌单把同一首加了两遍」的合法
   * 重复（见 importPlaylist 的 keepDuplicates），若这里按 id 去重，那种重复就完全报不出来
   * （群反馈「有些歌曲没重复」的另一半原因）。两行同 id 时它们是组里的两条 entries，
   * 删除按「副本数」删（removeDuplicateSongs 的配额），不会一删删两行。
   *
   * 内建收藏歌单也覆盖：它的数据在 loveList 里，playlistSongs → targetMusics 认 'love'，
   * 侧表里属于收藏的那部分也一起被 playlistSongs 合进来，不另造一份数据源。
   */
  findDuplicateGroups(id: string): DuplicateGroup[] {
    const songs: SongItem[] = this.playlistSongs(id);
    const order: string[] = [];
    const byKey: Map<string, DuplicateGroup> = new Map<string, DuplicateGroup>();
    for (const song of songs) {
      const key: string = duplicateKeyOf(song.name, song.singer);
      if (key.length === 0) {
        continue;
      }
      const entry: DuplicateEntry = {
        id: song.id,
        name: song.name,
        singer: song.singer,
        interval: song.interval,
        source: song.source,
        quality: song.quality,
      };
      const group: DuplicateGroup | undefined = byKey.get(key);
      if (group === undefined) {
        const fresh: DuplicateGroup = {
          key: key,
          name: song.name,
          singer: song.singer,
          count: 1,
          keepId: song.id,
          duplicateIds: [],
          entries: [entry],
        };
        byKey.set(key, fresh);
        order.push(key);
        continue;
      }
      // 组内顺序就是列表顺序：第一条（最靠前）默认留着，后面的一律进 duplicateIds
      group.count++;
      group.entries.push(entry);
      group.duplicateIds.push(song.id);
    }
    const out: DuplicateGroup[] = [];
    for (const key of order) {
      const group: DuplicateGroup | undefined = byKey.get(key);
      if (group !== undefined && group.entries.length > 1) {
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
   *
   * **ids 里同一个 id 出现几次 = 删几个副本**：歌单里同一首歌被加了两遍时两行同 id，
   * 面板要能「留一行删一行」。配额先按歌单里实际有几行夹紧，保证返回的删除条数不是假数；
   * 这样上层不必传「第几行」之类的位置信息，仍然只是一串 id。
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
    // 歌单里每个 id 实际有几行：配额不能超过它，否则「删了 N 首」与实际不符
    const stock: Map<string, number> = new Map<string, number>();
    for (const song of this.playlistSongs(id)) {
      stock.set(song.id, (stock.get(song.id) ?? 0) + 1);
    }
    const quota: Map<string, number> = new Map<string, number>();
    const ordered: string[] = [];
    let removed: number = 0;
    for (const raw of ids) {
      const left: number = stock.get(raw) ?? 0;
      if (left <= 0) {
        continue;
      }
      stock.set(raw, left - 1);
      const want: number = (quota.get(raw) ?? 0) + 1;
      quota.set(raw, want);
      removed++;
      if (want === 1) {
        ordered.push(raw);
      }
    }
    if (ordered.length === 0) {
      return 0;
    }
    this.removeMusicFromPlaylist(id, ordered, quota);
    return removed;
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
        // 整份列表被远端覆盖了：侧表里属于「已经不存在的歌单」的导入链接一并清掉
        this.saveImportLinks();
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
        // 远端删了歌单：它的导入链接记录也一起清掉（同 removePlaylists 的理由）
        this.saveImportLinks();
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

/**
 * 「跟随源歌单」匹配用的主键：`平台__歌曲id`
 *
 * 为什么不用裸 id：歌单里可能同时有不同平台的歌（用户手动加的），id 命名空间各平台
 * 互不相干，裸 id 撞上的概率不为零。带上来源才符合「source + songId」这个口径。
 */
function compositeMatchIdOf(info: LxMusicInfoNew): string {
  return `${info.source}__${info.id}`;
}

/** 往 Map<string, number[]> 的桶里追加一个下标（没有桶就先建一个） */
function pushIndex(map: Map<string, number[]>, key: string, index: number): void {
  const bucket: number[] | undefined = map.get(key);
  if (bucket === undefined) {
    map.set(key, [index]);
    return;
  }
  bucket.push(index);
}

/**
 * 从桶里取出「第一条还没被认领」的下标；都认领完了返回 -1
 *
 * 这就是多重集配对的全部奥秘：同一个键在源里有 N 条、本地有 M 条时，
 * 前 min(N, M) 条一一配对，多出来的 N-M 条算新增、M-N 条算删除。
 * 桶的大小通常是 1（没有重复），所以这个扫描实际上不花时间。
 */
function takeUnclaimed(bucket: number[] | undefined, claimed: boolean[]): number {
  if (bucket === undefined) {
    return -1;
  }
  for (const index of bucket) {
    if (!claimed[index]) {
      return index;
    }
  }
  return -1;
}

/** 标准化歌手拼回去用的分隔符，与 MusicSearch 的 normalizeSingers 一致 */
const SINGER_JOIN: string = '、';

/**
 * 把「键的多重集」数组折成「键 -> 还剩几个」的记账表
 *
 * 源快照必须按多重集存：歌单里同一首歌出现两次是合法的，用 Set 会把第二条吃掉，
 * 于是「源里删了一条重复」永远算不出来。空键直接跳过（不可判重的条目只按 id 走）。
 */
function countKeys(keys: string[]): Map<string, number> {
  const out: Map<string, number> = new Map<string, number>();
  for (const key of keys) {
    if (key.length === 0) {
      continue;
    }
    out.set(key, (out.get(key) ?? 0) + 1);
  }
  return out;
}

/**
 * 从记账表里取走一个额度；取到返回 true，取不到返回 false
 *
 * 这就是「这条确实来自源」的凭据：同一个键在源里出现过几次，就只有几条本地条目
 * 能凭它被判成「源里已经删了」。额度耗尽之后再遇到同键的条目，一律当成用户手动加的。
 */
function takeCount(bucket: Map<string, number>, key: string): boolean {
  if (key.length === 0) {
    return false;
  }
  const left: number | undefined = bucket.get(key);
  if (left === undefined || left <= 0) {
    return false;
  }
  if (left === 1) {
    bucket.delete(key);
  } else {
    bucket.set(key, left - 1);
  }
  return true;
}

/** 弹窗里一条「将要移除」的展示文案：`歌名 - 歌手`，没有歌手就只写歌名 */
function removalLabelOf(info: LxMusicInfoNew): string {
  return info.singer.length > 0 ? `${info.name} - ${info.singer}` : info.name;
}

/**
 * 全角括号 / 书名号折成半角，只为让**同一种写法**的不同宽度落到同一个键
 *
 * 只换符号、不换内容也不删内容：「歌（Live）」与「歌 (Live)」本来就是一回事，
 * 不折的话会漏报；而「歌」与「歌 (Live)」必须保持不同（见 duplicateKeyOf 的说明）。
 */
const BRACKET_FOLD: Record<string, string> = {
  '（': '(',
  '）': ')',
  '【': '(',
  '】': ')',
  '〔': '(',
  '〕': ')',
  '［': '(',
  '］': ')',
  '｛': '{',
  '｝': '}',
  '〈': '<',
  '〉': '>',
  '《': '<',
  '》': '>',
};

/**
 * 判重用的标准化键：歌名·歌手（小写、去空白、括号全半角统一，**不剥离版本后缀**）
 *
 * 为什么判重落在「歌名 + 歌手」而不是条目 id：同一首歌在酷我 / QQ / 网易各有一条 id，
 * 从不同音源、不同搜索结果加进同一个歌单时 id 全不一样，只按 id 判重必然重复
 * （群反馈「歌单要加个删除重复歌曲」的根因之一）。
 *
 * 标准化规则：
 *   - 歌名、歌手都去空白并转小写 ——「晴天」「 晴天 」以及带全角空格的写法必须同键
 *     （JS 的 \s 本来就含全角空格 U+3000，不用再单列）；
 *   - 括号只统一全/半角（见 BRACKET_FOLD），**内容原样保留**：
 *     「晴天 (Live)」「晴天（伴奏）」「晴天 (Acoustic Ver.)」各自是一个键，
 *     与「晴天」**不是**同一首 —— 版本后缀（Live / 伴奏 / Remix / 重制版）本来就代表
 *     不同的录音，合并了就是误删（群反馈 2026-11-20 15:11「重复歌曲检测不太对」的根因：
 *     旧口径把尾部括号组整个剥掉，于是《歌》与《歌 (Live)》《歌 (Remix)》被判成同一组）；
 *   - 歌手按 SINGER_SEPARATORS 拆开、各自标准化、排序后用「、」重拼，于是
 *     「周杰伦、方文山」与「方文山/周杰伦」是同一个键（口径与搜索页去重一致）——
 *     这一半是对的，保持不动；
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

/** 歌名标准化：去空白 → 小写 → 括号全半角统一（只有全空白的歌名会是空串，交给调用方退化） */
function normalizeDuplicateName(name: string): string {
  if (name === undefined || name === null) {
    return '';
  }
  return foldBracketChars(name.replace(/\s/g, '').toLowerCase());
}

/** 把全角括号逐个换成半角，其余字符原样保留 */
function foldBracketChars(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const mapped: string | undefined = BRACKET_FOLD[ch];
    out += mapped === undefined ? ch : mapped;
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
