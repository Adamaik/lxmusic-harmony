import { K_HISTORY_VERSION, PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { SyncManager } from '../core/sync/SyncManager';
import { C_RED } from '../ui/Theme';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  SelectSession, toggleSelected } from '../ui/Selection';
import { SongListPane } from './SongListPane';
import { confirmRemoveLocalSongs } from './LocalMusicView';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';

/** 播放历史的多选能做什么（本地音乐 / 云端音乐各自在自己的面板里给，这里没有「移除」） */
const HISTORY_ACTIONS: string[] = ['收藏', '加入播放列表', '加入歌单'];

/**
 * 播放历史（「我的」页那一排快捷入口里的「最近播放」）
 *
 * 原来它是「我的」页里的一个分段，跟着分段胶囊切换；现在这一页独立成子页面
 * （与华为音乐的「最近播放」同构），分段胶囊由「我的」页那排图标代替。
 *
 * 逻辑与原分段逐条一致：长按任意一行进多选，批量收藏 / 入歌单 / 入播放列表，
 * 以及只删播放记录（收藏、下载、本地文件都不动）。
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
  @State pickerOpen: boolean = false;
  @State candidates: PlaylistSummary[] = [];
  @StorageLink(K_HISTORY_VERSION) @Watch('onHistoryChanged') historyVersion: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  /** 播放历史在别处（比如播放器）被改动时同步过来 */
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

  private refresh(): void {
    this.history = PlaySession.getInstance().history;
  }

  // ------------------------------------------------------------ 多选

  private enterSelecting(item: SongItem): void {
    this.selecting = true;
    this.selectedIds = [item.id];
    // @Watch 只在**值真的变了**时才回调，进多选这一下不能只靠它（同一条二次长按就不变）
    this.publishSelectBar();
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
            const removed: number = PlaySession.getInstance().removeHistory(ids);
            this.exitSelecting();
            this.refresh();
            this.toast(`已删除 ${removed} 条播放记录`);
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
    const added: number = SyncManager.getInstance().getLibrary().addMusicToPlaylist(playlist.id, targets);
    this.pickerOpen = false;
    this.exitSelecting();
    this.toast(added > 0 ? `已把 ${added} 首加入「${playlist.name}」` : `「${playlist.name}」里已经有这些歌了`);
  }

  private createPlaylistAndAdd(name: string): void {
    if (name.length === 0) {
      return;
    }
    const targets: SongItem[] = this.selected();
    const library = SyncManager.getInstance().getLibrary();
    const id: string = library.createPlaylist(name);
    library.addMusicToPlaylist(id, targets);
    this.pickerOpen = false;
    this.exitSelecting();
    this.toast(`已新建歌单「${name}」并加入 ${targets.length} 首`);
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
