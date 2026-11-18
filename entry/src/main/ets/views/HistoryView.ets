import { PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { K_ECHO_VERSION, ListenLog, ListenSong, listenItemId } from '../core/history/ListenLog';
import { SyncManager } from '../core/sync/SyncManager';
// 加歌的返回值是 { added, skipped }：重复的会被跳过，提示要按真实结果说话
import { AddMusicResult } from '../core/sync/LocalLibrary';
import { C_RED } from '../ui/Theme';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  K_SELECT_END_SEQ, SelectSession, toggleSelected } from '../ui/Selection';
import { SongListPane } from './SongListPane';
import { confirmRemoveLocalSongs } from './LocalMusicView';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';

/** 播放历史的多选能做什么（本地音乐 / 云端音乐各自在自己的面板里给，这里没有「移除」） */
const HISTORY_ACTIONS: string[] = ['收藏', '加入播放列表', '加入歌单'];

/**
 * 流水里的一首歌（ListenSong）→ 列表里的条目（SongItem）
 *
 * 列表、多选、收藏 / 入歌单 / 续播那一套都是按 SongItem 走的（见 SongListPane 与
 * ui/Selection），流水里的 ListenSong 多带了专辑与总时长，转一道就好。id 用
 * listenItemId：老记录没有队列条目 id，它按「来源 + 歌名 + 歌手」拼一个稳定的值，
 * 多选与删除都按它认人。
 */
function songItemOf(song: ListenSong): SongItem {
  const item: SongItem = {
    id: listenItemId(song),
    name: song.name,
    singer: song.singer,
    coverUrl: song.coverUrl,
    art: song.art,
    source: song.source,
    quality: song.quality,
    interval: song.interval,
    musicInfoJson: song.musicInfoJson,
  };
  return item;
}

/**
 * 播放历史（「我的」页那一排快捷入口里的「最近播放」）
 *
 * 原来它是「我的」页里的一个分段，跟着分段胶囊切换；现在这一页独立成子页面
 * （与华为音乐的「最近播放」同构），分段胶囊由「我的」页那排图标代替。
 *
 * 逻辑与原分段逐条一致：长按任意一行进多选，批量收藏 / 入歌单 / 入播放列表，
 * 以及只删播放记录（收藏、下载、本地文件都不动）。
 *
 * 数据来自 core/history/ListenLog 的流水（与「回响」共用唯一一份）：按「歌名 + 歌手」
 * 去重取最近 100 首。不到 30 秒的记录也在其中 —— 30 秒门槛只用来筛回响，
 * 「最近播放」要显示真的点开听过的歌。
 */
@Component
export struct HistoryView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 列表底部要留出的空间：页内那条迷你条 + 手势条（由壳层算好） */
  @Prop bottomInset: number = 0;
  @Prop currentId: string = '';
  @State history: SongItem[] = [];
  /** 多选：勾选一变就往全局会话里发布一次（顶栏与底栏都听它，见 ui/Selection.ets） */
  @State selecting: boolean = false;
  @State @Watch('syncSelectBar') selectedIds: string[] = [];
  /**
   * 多选被全局收尾的序号（见 ui/Selection.ets 的 K_SELECT_END_SEQ）
   *
   * 不依赖 onCancel 回调：壳层点叉 / 会话被别处 end 时，序号 +1，这里无条件把自己
   * 的多选状态清掉。真机上「顶栏退了、行尾还是勾选圈」就是回调链断掉的现场。
   */
  @StorageLink(K_SELECT_END_SEQ) @Watch('onSelectEnded') selectEndSeq: number = 0;
  @State pickerOpen: boolean = false;
  @State candidates: PlaylistSummary[] = [];
  @StorageLink(K_ECHO_VERSION) @Watch('onHistoryChanged') historyVersion: number = 0;

  aboutToAppear(): void {
    // 页面刚出现 ⇒ 两边都不在多选：上一份页面实例可能把「已选中 N 项」留在全局会话里
    // （壳层标题栏照那份状态画，就会出现退不掉的残影，见 ui/Selection.ets 的 end() 注释）。
    // 先收掉再读数据，代价是一次幂等的状态赋值。
    this.selecting = false;
    this.selectedIds = [];
    SelectSession.getInstance().end();
    this.refresh();
  }

  /** 流水变了（播放器收尾一条 / 别处删了记录 / 清空）就重读一次 */
  onHistoryChanged(): void {
    this.refresh();
    // 历史变了就把已经不在列表里的勾选摘掉，否则「删除 3 条」会带着幽灵条目算数
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.history) {
        alive.push(item.id);
      }
      const pruned: string[] = pruneSelected(this.selectedIds, alive);
      if (pruned.length !== this.selectedIds.length) {
        this.selectedIds = pruned;
      }
    }
  }

  /**
   * 从流水读最近 100 首（按「歌名 + 歌手」去重、新的在前）
   *
   * 以前直接拿 PlaySession.history；现在历史与回响共用 ListenLog 那一份流水，
   * 这里不再需要自己维护一份去重列表。
   */
  private refresh(): void {
    this.history = ListenLog.getInstance().recentSongs(100)
      .map((song: ListenSong): SongItem => songItemOf(song));
  }

  // ------------------------------------------------------------ 多选

  private enterSelecting(item: SongItem): void {
    this.selecting = true;
    this.selectedIds = [item.id];
    // @Watch 只在**值真的变了**时才回调，进多选这一下不能只靠它（同一条二次长按就不变）
    this.publishSelectBar();
  }

  /** 全局多选已收尾：无条件复位本地状态（回调可能根本没被调到） */
  private onSelectEnded(): void {
    if (this.selecting) {
      this.selecting = false;
      this.selectedIds = [];
    }
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selectedIds = [];
    SelectSession.getInstance().end();
  }

  /** 勾选数一变就把工具条的状态重发一遍（顶栏的标题、底栏主操作的可用态都在听） */
  private syncSelectBar(): void {
    if (!this.selecting) {
      return;
    }
    this.publishSelectBar();
  }

  /** 把「勾了几首 / 能做什么」交给全局会话：顶栏与底栏据此绘制 */
  private publishSelectBar(): void {
    SelectSession.getInstance().show(
      this.selectedIds.length,
      allSelectedOf(this.selectedIds, this.history.length),
      selectActionsOf(HISTORY_ACTIONS, '删除记录'),
      () => {
        this.exitSelecting();
      },
      () => {
        this.toggleSelectAll();
      },
      (index: number) => {
        this.onAction(index);
      });
  }

  /** 页面被弹掉时把工具条一起收走（不然它会留在下一层页面上） */
  aboutToDisappear(): void {
    SelectSession.getInstance().end();
  }

  private toggleSelect(item: SongItem): void {
    this.selectedIds = toggleSelected(this.selectedIds, item.id);
  }

  private toggleSelectAll(): void {
    if (allSelectedOf(this.selectedIds, this.history.length)) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.history) {
      ids.push(item.id);
    }
    this.selectedIds = ids;
  }

  private selected(): SongItem[] {
    return selectedSongs(this.history, this.selectedIds);
  }

  private toast(message: string): void {
    if (message.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 只删历史记录：收藏、下载、本地文件（如果这条是本地歌）都不动 */
  private removeSelectedHistory(): void {
    const targets: SongItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选要删掉的记录');
      return;
    }
    const ids: string[] = [];
    for (const item of targets) {
      ids.push(item.id);
    }
    this.getUIContext().showAlertDialog({
      title: '删除播放记录',
      message: `从播放历史里删掉这 ${ids.length} 条？收藏、下载与本地文件都不受影响。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            // 删的是流水里这首歌的全部记录（按历史行 id 认），否则去重后它还会冒出来
            const removed: number = ListenLog.getInstance().removeSongs(ids);
            this.exitSelecting();
            this.refresh();
            this.toast(removed > 0 ? `已删除 ${removed} 条播放记录` : '没有可删除的记录');
          },
        },
      ],
    });
  }

  private openPlaylistPicker(): void {
    if (this.selected().length === 0) {
      this.toast('先勾选要加入歌单的歌');
      return;
    }
    this.candidates = SyncManager.getInstance().getLibrary().playlistSummaries();
    this.pickerOpen = true;
  }

  private addSelectedToPlaylist(playlist: PlaylistSummary): void {
    const targets: SongItem[] = this.selected();
    const result: AddMusicResult = SyncManager.getInstance().getLibrary()
      .addMusicToPlaylist(playlist.id, targets);
    this.pickerOpen = false;
    this.exitSelecting();
    this.reportAdded(playlist.name, result, targets.length);
  }

  /**
   * 加歌之后那句提示，按**真实结果**说话
   *
   * 库里会把「已经在歌单里的」那些跳过并返回 { added, skipped }，所以不能只看 `added > 0`：
   * 部分重复时不说清楚，用户会以为全进去了。
   *   - 全进去：原口径「已把 N 首加入」
   *   - 进去一部分：「已加入 N 首，M 首已在歌单里」
   *   - 全被跳过：「这 N 首都已经在「X」里了」（原文案不提数量，容易被当成失败）
   *   - 只勾了一首：一句「里已经有这首歌了」最自然，不必报数
   */
  private reportAdded(playlistName: string, result: AddMusicResult, total: number): void {
    if (total === 1) {
      this.toast(result.added > 0
        ? `已添加到「${playlistName}」`
        : `「${playlistName}」里已经有这首歌了`);
      return;
    }
    if (result.added <= 0) {
      this.toast(`这 ${total} 首都已经在「${playlistName}」里了`);
      return;
    }
    if (result.skipped > 0) {
      this.toast(`已加入 ${result.added} 首，${result.skipped} 首已在歌单里`);
      return;
    }
    this.toast(`已把 ${result.added} 首加入「${playlistName}」`);
  }

  private createPlaylistAndAdd(name: string): void {
    if (name.length === 0) {
      return;
    }
    const targets: SongItem[] = this.selected();
    const library = SyncManager.getInstance().getLibrary();
    const id: string = library.createPlaylist(name);
    // 新歌单里不可能有重复，但仍读返回值取数：万一有歌曲信息不全被挡下，报的数才对得上
    const result: AddMusicResult = library.addMusicToPlaylist(id, targets);
    this.pickerOpen = false;
    this.exitSelecting();
    if (result.added <= 0) {
      this.toast(`已新建歌单「${name}」，但这些歌没能加进去`);
      return;
    }
    this.toast(result.added === 1
      ? `已新建歌单「${name}」并添加`
      : `已新建歌单「${name}」并加入 ${result.added} 首`);
  }

  /**
   * 批量操作：按**会话里那一项的叫法**分发（底栏按下标回调，这里翻译回它是什么）
   *
   * 不按下标硬编码：底栏的排列是「各页面的操作 + 红字那枚主操作放最后」
   * （见 ui/Selection.ets 的 selectActionsOf），下标会随操作项数量变。
   */
  private onAction(index: number): void {
    const actions: SelectAction[] = SelectSession.getInstance().actions;
    if (index < 0 || index >= actions.length) {
      return;
    }
    const label: string = actions[index].label;
    if (label === '删除记录') {
      this.removeSelectedHistory();
      return;
    }
    const targets: SongItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选歌曲');
      return;
    }
    if (label === '收藏') {
      this.toast(favoriteSongs(targets));
      return;
    }
    if (label === '加入播放列表') {
      this.toast(queueSongs(targets, false));
      return;
    }
    this.openPlaylistPicker();
  }

  @Builder
  playlistPickerSheet() {
    AddToPlaylistSheet({
      songName: `已选 ${this.selectedIds.length} 首`,
      candidates: this.candidates,
      bottomInset: this.bottomInset,
      onPick: (playlist: PlaylistSummary) => {
        this.addSelectedToPlaylist(playlist);
      },
      onCreate: (name: string) => {
        this.createPlaylistAndAdd(name);
      },
    })
  }

  build() {
    Column() {
      // 顶部占位：第一行落在透明标题栏下方，但它跟着列表一起滚
      // （多选的工具条不在这里 —— 顶栏那条由壳层画，底栏那条在 PanePage 的悬浮栏里）
      Column().height(this.topInset).width('100%')

      SongListPane({
        items: this.history,
        currentId: this.currentId,
        emptyText: '还没有播放记录',
        bottomInset: this.bottomInset,
        // 长按进多选（多选状态在本页，工具条挂在上面）
        selectable: true,
        selecting: this.selecting,
        selectedIds: this.selectedIds,
        onToggleSelect: (item: SongItem) => {
          this.toggleSelect(item);
        },
        onRequestSelect: (item: SongItem) => {
          this.enterSelecting(item);
        },
        onPick: (index: number) => {
          const list: SongItem[] = this.history;
          if (index >= 0 && index < list.length) {
            PlaySession.getInstance().setQueueAndPlay(list, index);
          }
        },
        // 播放历史里也会有本地歌（刚从本地音乐放过的），行菜单里的「从本地音乐移除」
        // 要真的能用，不能点了没反应（云端歌不需要这一项：服务器上的文件不归应用管）
        onRemoveLocal: (item: SongItem) => {
          confirmRemoveLocalSongs(this.getUIContext(), [item], (removed: number) => {
            this.refresh();
            if (removed > 0) {
              this.getUIContext().getPromptAction().showToast({ message: `已移除 ${removed} 首` });
            }
          });
        },
      })
        .layoutWeight(1)
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.pickerOpen, this.playlistPickerSheet(), {
      preferType: SheetType.BOTTOM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      detentSelection: SheetSize.MEDIUM,
      dragBar: true,
      showClose: true,
      title: { title: '添加到歌单' },
    })
  }
}
