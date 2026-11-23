import { common } from '@kit.AbilityKit';
import { K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_ECHO_VERSION, ListenLog } from '../core/history/ListenLog';
import { BottomBar } from '../ui/BottomBar';
import { K_FAVORITE_IDS } from '../core/player/FavoriteIndex';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
import { CollectedPlaylist, CollectedPlaylists, K_COLLECTED_VERSION, collectedKeyOf } from '../core/sync/CollectedPlaylists';
import { getPlaylistDetailAll, LxListDetail, OnlineRoute, platformName,
  playlistDetailTruncated } from '../core/music/MusicList';
import { PlaylistLink, parseShareText } from '../core/music/PlaylistLink';
// ImportLink：歌单存下来的「导入链接」；只有它有记录的歌单，长按菜单才多出「更新导入歌单」
// PlaylistSyncResult：「跟随源歌单」对齐的结果（+几 / -几，以及要不要用户确认删除）
import { ImportLink, PlaylistSyncResult } from '../core/sync/LocalLibrary';
import { LOVE_LIST_NAME } from '../core/sync/SyncTypes';
import { K_LOCAL_VERSION, LocalMusic } from '../core/local/LocalMusic';
import { ExportOutcome, ImportFileOutcome, PlaylistPort } from '../core/local/PlaylistPort';
import { K_DOWNLOAD_VERSION, DownloadManager } from '../core/download/DownloadManager';
import { K_WEBDAV_VERSION, WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { C_BG, C_CARD, C_CHEVRON, C_DIVIDER, C_FILL_SOFT, C_PRESSED, C_RED, C_RED_TINT, C_TEXT,
  C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB, R_CARD } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CHEVRON_RIGHT, I_CIRCLE, I_CLOCK, I_CLOUD, I_DOC, I_DOWNLOAD, I_FOLDER,
  I_GEAR, I_HEART_FILLED, I_HELP, I_IMPORT, I_PLAYLIST, I_PLUS, IconGlyph } from '../ui/Icons';
import { CoverArt, TopFade } from '../ui/Widgets';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { ImportPlaylistSheet } from './ImportPlaylistSheet';
import { isWideWindow, K_WINDOW_WIDTH } from '../ui/Layout';

/**
 * 「我的」页那一排快捷入口
 *
 * 结构照华为音乐的「我的」：图标 + 名字 + 条数，点一下进对应的子页面（收藏进的是
 * 那张内置收藏歌单的详情）。顺序也照它：本地 / 最近播放 / 收藏 / 下载 / 云端。
 * 只收我们自己有的东西 —— 它页面上那些会员、权益兑换、关注、已购之类我们没有的，一律不做。
 */
interface MineEntry {
  icon: Resource;
  label: string;
  action: string;
}

const ENTRIES: MineEntry[] = [
  { icon: I_FOLDER, label: '本地音乐', action: 'local' },
  { icon: I_CLOCK, label: '最近播放', action: 'history' },
  { icon: I_HEART_FILLED, label: '收藏', action: 'favorites' },
  { icon: I_DOWNLOAD, label: '下载管理', action: 'downloads' },
  { icon: I_CLOUD, label: '云端音乐', action: 'cloud' },
];

/** 底部那张卡里的两行（都落到设置那一套子页面上去） */
interface MineLink {
  icon: Resource;
  label: string;
  action: string;
}

const LINKS: MineLink[] = [
  { icon: I_GEAR, label: '设置', action: 'settings' },
  { icon: I_HELP, label: '帮助和反馈', action: 'about' },
];

/**
 * 我的页
 *
 * 照华为音乐的「我的」重排：上面一排快捷入口（本地音乐 / 最近播放 / 收藏 / 下载管理 / 云端音乐），
 * 中间一张歌单卡（自建歌单 + 新建歌单 / 歌单导入 动作区 + 歌单列表），
 * 下面一张设置卡（设置 / 帮助和反馈）。
 *
 * 「收藏」指收藏的**歌**（内置那张收藏歌单，洛雪的 loveList），点进去是它的详情。
 * 「收藏歌单」（收藏别人的歌单）不在这里：那说的是推荐页上的在线歌单，
 * 所以那一段跟着推荐页走（见 views/RecommendView.ets）—— 本地自己的歌单没有收藏这回事。
 *
 * 与改之前的区别（原来这里是「播放历史 / 下载管理 / 本地音乐 / 云端音乐」四段胶囊 + 列表）：
 *   - 那四段现在各自是**子页面**（点快捷入口进去，页内自带迷你播放条），
 *     所以「歌单」「设置」两个页签也没有必要了 —— 它们的内容就在这一页里；
 *   - 歌单不再只是「进歌单页看列表」：自建歌单直接在卡里列出，长按仍是原来的
 *     「添加到收藏 / 重命名 / 删除」，卡里那块浅灰底就是新建与导入两个入口。
 */
@Component
export struct MineView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 内容底部要留出的空间：悬浮页签栏 + 手势条（由壳层算好） */
  @Prop bottomInset: number = 0;
  /** 去某个子页面（本地音乐 / 播放历史 / 下载 / 云端 / 设置 / 关于），路由由壳层实现 */
  onNavigate: (action: string) => void = () => {
  };
  /** 点歌单 → 打开歌单详情（与壳层那套路由同一个入口） */
  onOpenPlaylist: (playlist: PlaylistSummary) => void = () => {
  };
  /** 收藏歌单那一段点开的还是**在线**歌单，路由也交给壳层（在线详情页） */
  onOpenOnline: (route: OnlineRoute) => void = () => {
  };
  @State playlists: PlaylistSummary[] = [];
  /** 歌单卡当前那一段：0 = 自建歌单（自己建的 + 导入的），1 = 收藏歌单（收来的在线歌单） */
  @State playlistTab: number = 0;
  /**
   * 收藏的在线歌单（按收藏顺序，最近的在前）
   *
   * 入口在推荐页（行尾爱心 / 长按多选），这里只是**列表**：和「自建歌单」并排两段，
   * 两边**互斥** —— 同一张歌单不会两段都出现（收藏来的都是线上歌单，本来就不在自建里；
   * 反过来导入过的不再让收，见 core/sync/CollectedPlaylists 的说明）。
   * 与「收藏的歌」（那个内置歌单）没有任何关系，两者是不同的东西。
   */
  @State collected: CollectedPlaylist[] = [];
  /** 内置那张收藏歌单（我的收藏）里的歌数 —— 快捷入口「收藏」下面那行数字 */
  @State favoriteCount: number = 0;
  @State localCount: number = 0;
  @State historyCount: number = 0;
  @State downloadCount: number = 0;
  @State cloudCount: number = 0;
  /** 新建 / 重命名共用的小面板：editingId 为空表示新建 */
  @State editOpen: boolean = false;
  @State editingId: string = '';
  @State editName: string = '';
  /** 「导入歌单」面板（粘贴第三方歌单分享链接） */
  @State importOpen: boolean = false;
  /**
   * 自建歌单的「多选导出」状态
   *
   * 群反馈（2026-11-22）的诉求是「多选几个歌单，一次性导出一个文件」，
   * 所以选择态只作用于自建歌单段：勾中的 id 存在这里，导完自动退出选择态。
   */
  @State selecting: boolean = false;
  @State selectedIds: string[] = [];
  /** 正在读写文件：防连点（保存 / 选择对话框同一时间只能有一个） */
  @State transferring: boolean = false;
  /**
   * 正在「更新导入歌单」的歌单 id（空串 = 没在更新）
   *
   * 更新是一次网络全量拉取 + 对齐，可能十几秒：这段时间里同一张歌单不能再点
   * （两份旧快照互相覆盖会重复加歌、甚至互相删），菜单项也要显示成「正在更新…」给点反馈。
   */
  @State updatingPlaylist: string = '';
  /** 最近一次触摸点：删除歌单时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;
  /**
   * 各个库的版本号：任何一个变了，卡片上的条数与歌单列表就重算一次
   *
   * 全部挂同一个 `refresh`：这一页的数据来自六个不同的模块（同步库 / 播放会话 /
   * 本地音乐 / 下载管理 / 云端曲库 / 收听流水），谁变了都得重新读一遍，没必要各写一个分支。
   */
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('refresh') syncVersion: number = 0;
  @StorageLink(K_ECHO_VERSION) @Watch('refresh') historyVersion: number = 0;
  @StorageLink(K_FAVORITE_IDS) @Watch('refresh') favoriteIds: string[] = [];
  @StorageLink(K_LOCAL_VERSION) @Watch('refresh') localVersion: number = 0;
  @StorageLink(K_DOWNLOAD_VERSION) @Watch('refresh') downloadVersion: number = 0;
  @StorageLink(K_WEBDAV_VERSION) @Watch('refresh') webdavVersion: number = 0;
  /** 收藏歌单在别处被改了（推荐页的爱心 / 多选）时重读一次那一段 */
  @StorageLink(K_COLLECTED_VERSION) @Watch('refresh') collectedVersion: number = 0;
  /**
   * 窗口宽度（vp）：宽屏下三张卡换一种排法（见 isWide）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），本页只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  /**
   * 是不是宽屏（平板 / 折叠屏展开态）
   *
   * 这一页的内容是**卡片**（快捷入口 / 歌单 / 设置），不是一列歌曲行 —— 所以宽屏下
   * 不是"一行放几列"，而是把「歌单卡」与「设置卡」并排：歌单卡里是一张张歌单、
   * 需要更宽，设置卡只有两行、窄一点就够（见 build 里的分栏）。
   */
  private isWide(): boolean {
    return isWideWindow(this.windowWidth);
  }

  private refresh(): void {
    const library = SyncManager.getInstance().getLibrary();
    this.playlists = library.playlistSummaries();
    // 歌单在别处被删了（同步 / 长按删除）时，勾选里不能留着已经不存在的 id：
    // 留着会让「已选 N 个」比实际能导出的多，全选/取消全选的判断也会错
    if (this.selectedIds.length > 0) {
      const alive: Set<string> = new Set<string>();
      for (const item of this.playlists) {
        alive.add(item.id);
      }
      const kept: string[] = [];
      for (const id of this.selectedIds) {
        if (alive.has(id)) {
          kept.push(id);
        }
      }
      if (kept.length !== this.selectedIds.length) {
        this.selectedIds = kept;
      }
    }
    if (this.playlists.length === 0 && this.selecting) {
      this.selecting = false;
      this.selectedIds = [];
    }
    this.collected = CollectedPlaylists.getInstance().list();
    this.favoriteCount = library.favoritePlaylistSummary().count;
    this.localCount = LocalMusic.getInstance().songsForUi().length;
    // 最近播放的条数与历史页同一个口径：流水按「歌名 + 歌手」去重后的最近 100 首
    // （原来读 PlaySession.history；那份历史已搬进 ListenLog，与回响共用）
    this.historyCount = ListenLog.getInstance().recentSongs(100).length;
    this.downloadCount = DownloadManager.getInstance().list().length;
    this.cloudCount = WebDavLibrary.getInstance().songsForUi().length;
  }

  /** 快捷入口下面那行条数 */
  private countOf(action: string): number {
    if (action === 'local') {
      return this.localCount;
    }
    if (action === 'history') {
      return this.historyCount;
    }
    if (action === 'favorites') {
      return this.favoriteCount;
    }
    if (action === 'downloads') {
      return this.downloadCount;
    }
    return this.cloudCount;
  }

  // ------------------------------------------------------------ 歌单：新建 / 重命名 / 删除

  private openCreate(): void {
    this.editingId = '';
    this.editName = '';
    this.editOpen = true;
  }

  private openRename(item: PlaylistSummary): void {
    this.editingId = item.id;
    this.editName = item.name;
    this.editOpen = true;
  }

  private submitEdit(): void {
    const name: string = this.editName.trim();
    if (name.length === 0) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    if (this.editingId.length === 0) {
      library.createPlaylist(name);
    } else {
      library.renamePlaylist(this.editingId, name);
    }
    this.editOpen = false;
    this.refresh();
  }

  private removePlaylist(item: PlaylistSummary): void {
    this.getUIContext().showAlertDialog({
      title: '删除歌单',
      message: `确定要删除「${item.name}」吗？删除会同步到其它设备。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            SyncManager.getInstance().getLibrary().removePlaylists([item.id]);
            // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
            dustBus.spray(this.dustX, this.dustY);
            this.refresh();
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 歌单：更新导入歌单

  /**
   * 这张歌单的导入链接（没有 = 自建歌单，或升级前导入、侧表里没记录的老歌单）
   *
   * 长按菜单靠它决定要不要显示「更新导入歌单」：需求只要求「从链接导入的歌单」有这一项，
   * 自建歌单不显示。判断只认侧表，不去猜「有 source 就算导入过」——猜错会给手建歌单
   * 凭空长出一个用不了的入口。
   */
  private importLinkOf(item: PlaylistSummary): ImportLink | null {
    return SyncManager.getInstance().getLibrary().importLinkOf(item.id);
  }

  /**
   * 「更新导入歌单」：拿当初存的导入链接重新拉一遍曲目，把本地歌单对齐成最新
   *
   * 这里**不另写一套删除逻辑**，整条链路复用歌单详情页「从原歌单更新」用的那一套：
   *   - 拉取：getPlaylistDetailAll（真翻页，大歌单也能拉全）；
   *   - 对齐：LocalLibrary.syncWithSource(manual = true) —— 新增直接补进来，
   *           「源里删掉的」不会立刻删，而是落成「待确认删除」计划，用户点「删除」才真删
   *           （manual 路径的语义，见 syncWithSource 的注释）；
   *   - 防重入：beginSyncToSource / endSyncToSource，与打开歌单时的自动对齐互斥。
   *
   * 入口放长按菜单，是为了「不进歌单也能更新」——这也是需求要的那个操作路径。
   */
  private async updateImportedPlaylist(item: PlaylistSummary): Promise<void> {
    if (this.updatingPlaylist.length > 0) {
      this.toast('正在更新歌单，稍候');
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    const link: ImportLink | null = library.importLinkOf(item.id);
    if (link === null) {
      return;
    }
    /**
     * 用**当初存的导入链接**重新解析平台与歌单 id：保存的链接通常已经跟成带 id 的地址，
     * 这里不联网；万一解析不出来（老数据 / 链接格式变了），退回歌单里已存的 sourceListId ——
     * 它本来就是同一个线上歌单的标识，口径见 LocalLibrary.normalizeSourceListId。
     */
    const parsed: PlaylistLink | null = parseShareText(link.url);
    const source: string = parsed !== null ? parsed.source : link.platform;
    const sourceListId: string = parsed !== null ? parsed.listId : library.sourceListIdOf(item.id);
    if (source.length === 0 || sourceListId.length === 0) {
      this.toast('这个歌单缺少导入来源，没法更新');
      return;
    }
    if (!library.beginSyncToSource(item.id)) {
      this.toast('这张歌单正在同步，稍候');
      return;
    }
    this.updatingPlaylist = item.id;
    try {
      this.toast('正在从导入链接拉取最新内容…');
      const detail: LxListDetail = await getPlaylistDetailAll(source, sourceListId);
      // 只拿到一部分时整体放弃：拿半份源歌单去对齐，会把「没拉到的」当成「源里删了」
      if (playlistDetailTruncated(detail, source)) {
        this.toast('源歌单没拉全（可能被接口限流），已保留本地内容');
        return;
      }
      const quality: string = PlaySession.getInstance().quality;
      const items: SongItem[] = [];
      for (const music of detail.list) {
        items.push(songFromSearch(music, quality));
      }
      if (items.length === 0) {
        this.toast('源歌单现在是空的，已保留本地内容');
        return;
      }
      const result: PlaylistSyncResult = library.syncWithSource(item.id, items, true);
      if (result.aborted) {
        // 一条都对不上：更像 sourceListId 指错了歌单，按源删本地等于清空歌单，不动
        this.refresh();
        this.toast('源歌单变化太大，这次先不同步（可能是接口没返回全）');
        return;
      }
      if (result.pendingRemoval > 0) {
        // 新增已经落库，删除等用户在弹窗里确认
        this.refresh();
        this.confirmImportRemoval(item, result);
        return;
      }
      if (!result.changed) {
        this.toast('已是最新，和导入链接里的歌单一致');
        return;
      }
      this.refresh();
      const parts: string[] = [];
      if (result.added > 0) {
        parts.push(`+${result.added}`);
      }
      if (result.removed > 0) {
        parts.push(`-${result.removed}`);
      }
      this.toast(`已更新「${item.name}」：${parts.join(' / ')}`);
    } catch (e) {
      this.toast(`更新失败：${(e as Error).message}`);
    } finally {
      library.endSyncToSource(item.id);
      this.updatingPlaylist = '';
    }
  }

  /**
   * 「导入链接里的歌单少了这些歌」的确认弹窗
   *
   * 与歌单详情页那套（PlaylistDetailView.confirmSourceRemoval）同一口径：列出歌名、
   * 用户点「删除」才真的移除，点「保留」什么都不动（快照不刷，下次更新还会问）。
   * 那边的方法是页面私有，入口也不同（这里是长按菜单），所以在本页写一份同样口径的。
   */
  private confirmImportRemoval(item: PlaylistSummary, result: PlaylistSyncResult): void {
    const library = SyncManager.getInstance().getLibrary();
    const lines: string[] = [];
    for (const name of result.pendingNames) {
      lines.push(`· ${name}`);
    }
    if (result.pendingRemoval > result.pendingNames.length) {
      lines.push(`· 等共 ${result.pendingRemoval} 首`);
    }
    const head: string = result.added > 0 ? `已先补进 ${result.added} 首新歌。` : '';
    this.getUIContext().showAlertDialog({
      title: '导入链接里的歌单少了这些歌',
      message: `${head}源歌单里已经没有这 ${result.pendingRemoval} 首了：\n${lines.join('\n')}\n要从本地歌单里一起删掉吗？（选「保留」不动本地）`,
      autoCancel: true,
      buttons: [
        {
          value: '保留',
          action: () => {
            library.discardPendingSourceRemoval(item.id);
          },
        },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            const removed: number = library.applyPendingSourceRemoval(item.id);
            this.refresh();
            this.toast(`已移除 ${removed} 首`);
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 歌单导出 / 导入文件

  /** 文件对话框要的应用上下文（与本地音乐导入同一套取法） */
  private hostContext(): common.Context | null {
    const context = this.getUIContext().getHostContext();
    return context === undefined ? null : context as common.Context;
  }

  /** 「选择」/「完成」：退出选择态时清空勾选，避免下次进来还留着上次的 id */
  private toggleSelecting(): void {
    this.selecting = !this.selecting;
    if (!this.selecting) {
      this.selectedIds = [];
    }
  }

  private isPicked(id: string): boolean {
    return this.selectedIds.includes(id);
  }

  /** 点一行：选择态勾选 / 取消，普通态进歌单详情 */
  private togglePick(id: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (const item of this.selectedIds) {
      if (item === id) {
        found = true;
      } else {
        next.push(item);
      }
    }
    if (!found) {
      next.push(id);
    }
    this.selectedIds = next;
  }

  /** 全选 / 取消全选 */
  private toggleSelectAll(): void {
    if (this.selectedIds.length === this.playlists.length) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.playlists) {
      ids.push(item.id);
    }
    this.selectedIds = ids;
  }

  /** 单张歌单：长按菜单里的「导出为文件」 */
  private exportOne(item: PlaylistSummary): void {
    void this.runExport([item.id], item.name);
  }

  /** 多选导出：一个文件里装多张歌单 */
  private exportSelected(): void {
    if (this.selectedIds.length === 0) {
      this.toast('先勾选要导出的歌单');
      return;
    }
    const day: string = new Date().toISOString().substring(0, 10);
    void this.runExport(this.selectedIds, `聆听歌单-${day}`);
  }

  /**
   * 导出到用户选的位置
   *
   * 取消保存不提示（用户主动取消，弹一句「已取消」反而多余）；成功才退出选择态 ——
   * 失败时勾选还在，用户可以直接重试，不必重新选一遍歌单。
   */
  private async runExport(ids: string[], suggestedName: string): Promise<void> {
    if (this.transferring) {
      return;
    }
    const context: common.Context | null = this.hostContext();
    if (context === null) {
      this.toast('当前环境不支持保存文件');
      return;
    }
    this.transferring = true;
    try {
      const result: ExportOutcome =
        await PlaylistPort.getInstance().exportToFile(context, ids, suggestedName);
      if (!result.canceled) {
        this.toast(result.message);
      }
      if (result.ok) {
        this.selecting = false;
        this.selectedIds = [];
      }
    } catch (e) {
      this.toast('导出失败，请重试');
    } finally {
      this.transferring = false;
    }
  }

  /** 「导入文件」：选一个聆听导出的 JSON，建成新歌单 */
  private async importPlaylistFile(): Promise<void> {
    if (this.transferring) {
      return;
    }
    const context: common.Context | null = this.hostContext();
    if (context === null) {
      this.toast('当前环境不支持选择文件');
      return;
    }
    this.transferring = true;
    try {
      const result: ImportFileOutcome = await PlaylistPort.getInstance().importFromFile(context);
      if (!result.canceled) {
        this.toast(result.message);
      }
      if (result.ok) {
        this.refresh();
      }
    } catch (e) {
      this.toast('导入失败，请重试');
    } finally {
      this.transferring = false;
    }
  }

  /** 把整张歌单的歌批量加进收藏（收藏是参与同步的数据，只上行一次） */
  private addPlaylistToFavorites(item: PlaylistSummary): void {
    const songs: SongItem[] = SyncManager.getInstance().getLibrary().playlistSongs(item.id);
    if (songs.length === 0) {
      this.toast(`「${item.name}」还没有歌曲`);
      return;
    }
    const added: number = PlaySession.getInstance().addFavorites(songs);
    this.toast(added > 0
      ? `已把「${item.name}」的 ${added} 首歌添加到${LOVE_LIST_NAME}`
      : `「${item.name}」里的歌都已经在${LOVE_LIST_NAME}里了`);
  }

  // ------------------------------------------------------------ 收藏歌单（收来的在线歌单）

  /** 收藏段里的一行点开：走在线详情页（收藏只是记一下，不把它拉成本地歌单） */
  private openCollected(entry: CollectedPlaylist): void {
    const route: OnlineRoute = {
      kind: 'playlist',
      source: entry.source,
      id: entry.id,
      name: entry.name,
      cover: entry.cover,
    };
    this.onOpenOnline(route);
  }

  /** 收藏段那一行的第二行说明：先标平台（收来的歌单可能不在当前推荐来源上），再接收藏时那份说明 */
  private collectedMeta(entry: CollectedPlaylist): string {
    const platform: string = platformName(entry.source);
    return entry.meta.length > 0 ? `${platform} · ${entry.meta}` : platform;
  }

  /**
   * 自建歌单那一行的第二行说明：`平台 · N 首`（导入的）/ `N 首`（自己手建的）
   *
   * 为什么带平台：导入的歌单与手建的歌单可能**同名**（把线上歌单导进来之后，又照名字
   * 手建了一个），两条都是用户的数据，不能替他合并。标出来源，用户就能分清哪条是
   * 导入的（点进去是线上那份的本地副本）、哪条是自己建的。本地手建没有平台，照旧只显示「N 首」。
   */
  private playlistMeta(item: PlaylistSummary): string {
    const source: string = SyncManager.getInstance().getLibrary().playlistSourceOf(item.id);
    const platform: string = source.length > 0 ? platformName(source) : '';
    return platform.length > 0 ? `${platform} · ${item.count} 首` : `${item.count} 首`;
  }

  /** 取消收藏一张（只去掉收藏这一位，什么都不动） */
  private uncollect(entry: CollectedPlaylist): void {
    CollectedPlaylists.getInstance().remove(entry.source, entry.id);
    this.refresh();
    this.toast(`已取消收藏「${entry.name}」`);
  }

  /** 记住这次触摸的位置：删除歌单时拿它当粒子飘散的起点 */
  private rememberTouch(event: TouchEvent): void {
    const point: DustPoint | null = dustPointOf(event);
    if (point !== null) {
      this.dustX = point.x;
      this.dustY = point.y;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 界面

  /**
   * 快捷入口卡（照华为音乐那一排：图标在上面，名字与条数在下面）
   *
   * 四个入口平分宽度，不做横向滚动：数量是固定的四样，平分比「露出半截」更好点。
   */
  @Builder
  quickCard() {
    Row() {
      ForEach(ENTRIES, (entry: MineEntry) => {
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Center }) {
            // 图标底：淡红方块 + 红图形（与设置页的圆底色是同一套语汇，形状随这排入口改成圆角方）
            Column()
              .width(44)
              .height(44)
              .borderRadius(15)
              .backgroundColor(C_RED_TINT)
            IconGlyph({ symbol: entry.icon, iconSize: 23, color: C_RED })
          }
          .width(44)
          .height(44)

          Text(entry.label)
            .fontSize(F_SUB + 0.5)
            .fontColor(C_TEXT)
            .maxLines(1)
          Text(`${this.countOf(entry.action)}`)
            .fontSize(11)
            .fontColor(C_TEXT_WEAK)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .borderRadius(14)
        .stateStyles({
          normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(C_PRESSED) },
        })
        .onClick(() => {
          this.onNavigate(entry.action);
        })
        .accessibilityText(`${entry.label}，共 ${this.countOf(entry.action)} 首`)
        .accessibilityLevel('yes')
      }, (entry: MineEntry) => entry.action)
    }
    .width('100%')
    .padding({ top: 16, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  /**
   * 歌单卡里那块浅灰底的「动作区」
   *
   * 三格并排：新建歌单 / 歌单导入（粘贴分享链接）/ 导入文件（换设备迁移用的 JSON）。
   * 后两项容易混，文案上刻意区分开：一个「歌单导入」是线上歌单链接，一个「导入文件」是本机 JSON。
   * 参数只用一个下标（@Builder 的参数按值传，回调统一走本页的方法）。
   */
  @Builder
  cardAction(index: number) {
    Column({ space: 6 }) {
      IconGlyph({
        symbol: index === 0 ? I_PLUS : (index === 1 ? I_IMPORT : I_DOC),
        iconSize: 23,
        color: C_TEXT,
      })
      Text(index === 0 ? '新建歌单' : (index === 1 ? '歌单导入' : '导入文件'))
        .fontSize(F_SUB + 0.5)
        .fontColor(C_TEXT)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(C_PRESSED) },
    })
    .onClick(() => {
      if (index === 0) {
        this.openCreate();
      } else if (index === 1) {
        this.importOpen = true;
      } else {
        void this.importPlaylistFile();
      }
    })
    .accessibilityText(index === 0 ? '新建歌单' : (index === 1 ? '导入歌单' : '从文件导入歌单'))
    .accessibilityLevel('yes')
  }

  /**
   * 多选导出工具条（选择态才出现）
   *
   * 放在动作区的位置上：进选择态后「新建 / 导入」这些入口先让位，屏幕上只有
   * 「全选 / 导出所选」两件事，避免勾到一半误点到别处。
   */
  @Builder
  exportBar() {
    Row({ space: 12 }) {
      Text(`已选 ${this.selectedIds.length} 个`)
        .fontSize(F_SUB)
        .fontColor(C_TEXT)
      Blank()
      Text(this.selectedIds.length === this.playlists.length ? '取消全选' : '全选')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .onClick(() => {
          this.toggleSelectAll();
        })
      Text(this.transferring ? '正在导出…' : '导出所选')
        .fontSize(F_SUB)
        .fontColor(Color.White)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(16)
        .backgroundColor(C_RED)
        .opacity(this.transferring || this.selectedIds.length === 0 ? 0.5 : 1)
        .onClick(() => {
          if (!this.transferring) {
            this.exportSelected();
          }
        })
        .accessibilityText('导出所选歌单为 JSON 文件')
        .accessibilityLevel('yes')
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 14 })
    .borderRadius(16)
    .backgroundColor(C_FILL_SOFT)
  }

  /** 歌单行：图形占位封面 + 名字 + 曲目数 + 右箭头（长按是重命名 / 删除那套菜单） */
  @Builder
  playlistRow(item: PlaylistSummary, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(0.6)
          .color(C_DIVIDER)
          .margin({ left: 72 })
      }

      Row({ space: 12 }) {
        // 选择态：行首多一枚勾选圈；普通态保留歌单占位封面
        if (this.selecting) {
          IconGlyph({
            symbol: this.isPicked(item.id) ? I_CHECK_CIRCLE : I_CIRCLE,
            iconSize: 22,
            color: this.isPicked(item.id) ? C_RED : C_TEXT_WEAK,
          })
            .accessibilityLevel('no')
        }

        // 歌单没有封面图，用一块淡底 + 歌单图形占位（位置与华为音乐那排封面一致）
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(46)
            .height(46)
            .borderRadius(14)
            .backgroundColor(C_RED_TINT)
          IconGlyph({ symbol: I_PLAYLIST, iconSize: 22, color: C_RED })
        }
        .width(46)
        .height(46)

        Column({ space: 4 }) {
          Text(item.name)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.playlistMeta(item))
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 勾选态不画右箭头：这一行现在是「选它」，不是「进去」
        if (!this.selecting) {
          IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
            .accessibilityLevel('no')
        }
      }
      .width('100%')
      .height(70)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        if (this.selecting) {
          this.togglePick(item.id);
        } else {
          this.onOpenPlaylist(item);
        }
      })
      .onTouch((event: TouchEvent) => {
        this.rememberTouch(event);
      })
      .bindContextMenu(this.rowMenu(item), ResponseType.LongPress)
    }
    .width('100%')
  }

  @Builder
  rowMenu(item: PlaylistSummary) {
    Menu() {
      // 单张导出：换设备迁移的最小入口（多选导出在卡片头部的「选择」里）
      MenuItem({ content: '导出为文件' })
        .onClick(() => {
          this.exportOne(item);
        })
      MenuItem({ content: '添加到收藏' })
        .onClick(() => {
          this.addPlaylistToFavorites(item);
        })
      /**
       * 只有「从链接导入」的歌单才多这一项：拿当初存的导入链接重新拉一遍曲目。
       * 自建歌单 / 老版本导入（没有记录）没有这一项 —— 见 importLinkOf。
       */
      if (this.importLinkOf(item) !== null) {
        MenuItem({ content: this.updatingPlaylist === item.id ? '正在更新…' : '更新导入歌单' })
          .onClick(() => {
            void this.updateImportedPlaylist(item);
          })
      }
      MenuItem({ content: '重命名' })
        .onClick(() => {
          this.openRename(item);
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          this.removePlaylist(item);
        })
    }
  }

  /** 收藏歌单那一段的行：在线封面 + 名字 + 平台·说明 + 右箭头（长按可取消收藏） */
  @Builder
  collectedRow(entry: CollectedPlaylist, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(0.6)
          .color(C_DIVIDER)
          .margin({ left: 72 })
      }

      Row({ space: 12 }) {
        CoverArt({
          url: entry.cover,
          name: entry.name,
          art: entry.cover.length === 0,
          boxSize: 46,
          radius: 14,
        })

        Column({ space: 4 }) {
          Text(entry.name)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.collectedMeta(entry))
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
          .accessibilityLevel('no')
      }
      .width('100%')
      .height(70)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        this.openCollected(entry);
      })
      .bindContextMenu(this.collectedMenu(entry), ResponseType.LongPress)
    }
    .width('100%')
  }

  /** 收藏歌单那一段的行菜单：只有「取消收藏歌单」（那只记着平台 + 歌单 id，别的不动） */
  @Builder
  collectedMenu(entry: CollectedPlaylist) {
    Menu() {
      MenuItem({ content: '取消收藏歌单' })
        .onClick(() => {
          this.uncollect(entry);
        })
    }
  }

  /**
   * 歌单卡：自建歌单 | 收藏歌单 两段
   *
   * 头部两个标题点一下就换段（当前那段加黑）。两段**互斥** —— 同一张歌单不会两边都出现：
   *   - 自建歌单 = 自己建的 + 从线上导入的（都在本地库里，见 LocalLibrary）；
   *   - 收藏歌单 = 在**在线歌单页**上点「收藏歌单」收下来的（只有平台 + 歌单 id，纯本地）。
   * 已经导入到自建里的那张不再让收（在线歌单页会拦），反过来收藏着的被导入时会把收藏
   * 记录摘掉 —— 两边都堵住，所以不会重复。与快捷入口那个「收藏」（收藏的**歌**）无关。
   */
  @Builder
  playlistCard() {
    Column() {
      Row({ space: 6 }) {
        Text('自建歌单')
          .fontSize(F_SECTION)
          .fontWeight(this.playlistTab === 0 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.playlistTab === 0 ? C_TEXT : C_TEXT_SUB)
          .onClick(() => {
            this.playlistTab = 0;
          })
        Text(`${this.playlists.length}`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Text('|')
          .fontSize(F_SECTION)
          .fontColor(C_DIVIDER)
          .padding({ left: 2, right: 2 })
        Text('收藏歌单')
          .fontSize(F_SECTION)
          .fontWeight(this.playlistTab === 1 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.playlistTab === 1 ? C_TEXT : C_TEXT_SUB)
          .onClick(() => {
            this.playlistTab = 1;
            // 换段就退出选择态：勾着自建歌单去收藏段，导出按钮还在，容易误操作
            if (this.selecting) {
              this.toggleSelecting();
            }
          })
        Text(`${this.collected.length}`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Blank()
        // 多选导出入口：只在自建歌单段、且有歌单时出现
        if (this.playlistTab === 0 && this.playlists.length > 0) {
          Text(this.selecting ? '完成' : '选择')
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .padding({ left: 6, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.toggleSelecting();
            })
            .accessibilityText(this.selecting ? '完成选择' : '选择多个歌单导出')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 14 })

      if (this.playlistTab === 1) {
        if (this.collected.length === 0) {
          Column({ space: 6 }) {
            IconGlyph({ symbol: I_HEART_FILLED, iconSize: 28, color: C_TEXT_WEAK })
              .accessibilityLevel('no')
            Text('还没有收藏的歌单')
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
            Text('在推荐页点开一张歌单，点里面的「收藏歌单」就会收进来')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
          }
          .width('100%')
          .padding({ top: 16, bottom: 28 })
          .alignItems(HorizontalAlign.Center)
        } else {
          ForEach(this.collected, (entry: CollectedPlaylist, index: number) => {
            this.collectedRow(entry, index > 0)
          }, (entry: CollectedPlaylist) => collectedKeyOf(entry.source, entry.id))
        }
      } else {
        /**
         * 动作区（新建歌单 / 歌单导入 / 导入文件）
         *
         * 左右必须离卡片边留出一段：这里**外面套一层带内边距的容器**，而不是给这条
         * `width('100%')` 再叠 `margin` —— 百分比宽度是按父容器算的，叠上外边距就比卡片还宽，
         * 右边被 `clip(true)` 切掉、左边贴着边，看着就是「这条没留边」。
         *
         * 选择态下这块换成「全选 / 导出所选」：入口让位，屏幕上只剩导出这一件事。
         */
        if (this.selecting) {
          Column() {
            this.exportBar()
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })
        } else {
          Column() {
            Row() {
              this.cardAction(0)
              this.cardAction(1)
              this.cardAction(2)
            }
            .width('100%')
            .height(64)
            .borderRadius(16)
            .backgroundColor(C_FILL_SOFT)
            .clip(true)
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })
        }

        if (this.playlists.length === 0) {
          Text('还没有歌单，点上面的「新建歌单」建一个；也可以用「歌单导入」粘贴分享链接，或用「导入文件」导入另一台设备导出的歌单文件')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: 14, right: 14, top: 4, bottom: 18 })
            .textAlign(TextAlign.Start)
        } else {
          /**
           * key 里带条数与名字：ForEach 对 key 没变的条目不会重跑生成器，改名 / 加歌后
           * 行上的文字会停在旧值（与推荐页那条注释同一个坑）。
           * 前面再带下标：历史数据里同 id 同名的两条记录 key 会重复，重复 key 的渲染结果
           * 是未定义的（可能丢行、可能重复画）。
           */
          ForEach(this.playlists, (item: PlaylistSummary, index: number) => {
            this.playlistRow(item, index > 0)
          }, (item: PlaylistSummary, index: number) => `${index}_${item.id}_${item.count}_${item.name}`)
        }
      }
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 设置卡：设置 / 帮助和反馈（与华为音乐底部那张卡同构） */
  @Builder
  linksCard() {
    Column() {
      ForEach(LINKS, (row: MineLink, index: number) => {
        Column() {
          if (index > 0) {
            Divider()
              .strokeWidth(0.6)
              .color(C_DIVIDER)
              .margin({ left: 50 })
          }

          Row({ space: 14 }) {
            IconGlyph({ symbol: row.icon, iconSize: 22, color: C_TEXT })
            Text(row.label)
              .fontSize(F_ITEM)
              .fontColor(C_TEXT)
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
              .accessibilityLevel('no')
          }
          .width('100%')
          .height(58)
          .padding({ left: 14, right: 14 })
          .stateStyles({
            normal: { .backgroundColor(Color.Transparent) },
            pressed: { .backgroundColor(C_PRESSED) },
          })
          .onClick(() => {
            this.onNavigate(row.action);
          })
          .accessibilityText(row.label)
          .accessibilityLevel('yes')
        }
        .width('100%')
      }, (row: MineLink) => row.action)
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      Text(this.editingId.length === 0 ? '新建歌单' : '重命名歌单')
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .width('100%')
        .textAlign(TextAlign.Start)
      TextInput({ text: this.editName, placeholder: '歌单名称' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 14 })
        .fontSize(14)
        .height(46)
        .backgroundColor(C_FILL_SOFT)
        .onChange((value: string) => {
          this.editName = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_FILL_SOFT)
          .fontColor(C_TEXT)
          .onClick(() => {
            this.editOpen = false;
          })
        Button('确定')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_RED)
          .onClick(() => {
            this.submitEdit();
          })
      }
      .width('100%')

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  @Builder
  importSheet() {
    ImportPlaylistSheet({
      bottomInset: this.bottomInset,
      onDone: (message: string) => {
        this.importOpen = false;
        this.toast(message);
      },
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column({ space: 14 }) {
            // 顶部占位：第一张卡落在透明标题栏下方，但它跟着内容一起滚走
            // （用容器内边距会把这一段裁在标题栏下缘，看着像「被顶栏挡住」）
            Column().height(this.topInset + 6).width('100%')

            this.quickCard()
            /**
             * 宽屏：歌单卡与设置卡**并排**；窄屏照旧一上一下
             *
             * 这一页不像推荐页那样是"一列歌曲行"，而是三张卡 —— 所以宽屏下要排的是卡片的
             * 位置：快捷入口那一排横着铺满，剩下两张中歌单卡占宽的一份（里面是一张张歌单，
             * 行更长），设置卡只有两行、窄一点就够。2:1 的比例照华为音乐平板上的版式。
             */
            if (this.isWide()) {
              Row({ space: 14 }) {
                Column() {
                  this.playlistCard()
                }
                .layoutWeight(2)

                Column() {
                  this.linksCard()
                }
                .layoutWeight(1)
              }
              .width('100%')
              // 顶对齐：两张卡高度差得远（歌单卡可能几十行），居中的话设置卡会飘在半空
              .alignItems(VerticalAlign.Top)
            } else {
              this.playlistCard()
              this.linksCard()
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: this.bottomInset + 16 })
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
      .bindSheet($$this.editOpen, this.editSheet(), {
        preferType: SheetType.BOTTOM,
        detents: [SheetSize.MEDIUM],
        detentSelection: SheetSize.MEDIUM,
        dragBar: true,
        showClose: false,
        title: { title: this.editingId.length === 0 ? '新建歌单' : '重命名' },
      })

      // 顶栏渐隐：卡片从透明标题栏底下穿过时靠近顶部淡出，别顶穿「我的」两个字
      TopFade({ fadeHeight: this.topInset + 10 })

      // 导入面板：挂在另一个 1x1 节点上（上面那个节点已经占了新建面板）
      Column()
        .width(1)
        .height(1)
        .bindSheet($$this.importOpen, this.importSheet(), {
          preferType: SheetType.BOTTOM,
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.LARGE,
          dragBar: true,
          showClose: true,
          title: { title: '导入歌单' },
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
