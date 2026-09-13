import { K_HISTORY_VERSION, PlaySession, SongItem } from '../core/player/PlaySession';
import { C_BG } from '../ui/Theme';
import { I_TRASH } from '../ui/Icons';
import { PageTitle, RoundIconButton, SegmentedTabs } from '../ui/Widgets';
import { SongListPane } from './PlaylistView';
import { DownloadListPane } from './DownloadListView';
import { DownloadManager } from '../core/download/DownloadManager';

const TABS: string[] = ['播放历史', '平台音乐', '下载管理'];

/**
 * 我的页
 *
 * 标题右侧是清空按钮；下面是分段胶囊（播放历史/平台音乐/下载管理），
 * 再下面是当前分段对应的列表。
 *
 * 收藏不在这里 —— 它已经搬到「歌单」页，作为那个永远存在的内置歌单。
 */
@Component
export struct MineView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onOpenQueue: () => void = () => {
  };
  @State segmentIndex: number = 0;
  @State history: SongItem[] = [];
  @State currentId: string = '';
  @StorageLink(K_HISTORY_VERSION) @Watch('onHistoryChanged') historyVersion: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  /** 播放历史在别处（比如播放器）被改动时同步过来 */
  onHistoryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.history = PlaySession.getInstance().history;
  }

  private currentList(): SongItem[] {
    if (this.segmentIndex === 0) {
      return this.history;
    }
    return [];
  }

  private emptyText(): string {
    if (this.segmentIndex === 1) {
      return '还没有从平台导入过音乐';
    }
    return '这里还是空的';
  }

  private clearCurrent(): void {
    if (this.segmentIndex === 0) {
      PlaySession.getInstance().clearHistory();
      this.refresh();
      return;
    }
    if (this.segmentIndex === 2) {
      // 下载管理：只清「已完成 / 失败」的记录（正在下的留着），文件一并删掉
      const removed: number = DownloadManager.getInstance().clearFinished();
      if (removed > 0) {
        this.getUIContext().getPromptAction().showToast({ message: `已清空 ${removed} 条下载记录` });
      }
    }
  }

  private confirmClear(): void {
    const list: SongItem[] = this.currentList();
    if (list.length === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空列表',
      message: `确定要清空「${TABS[this.segmentIndex]}」吗？`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        { value: '清空', fontColor: '#E33B3B', action: () => { this.clearCurrent(); } },
      ],
    });
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        PageTitle({ text: '我的' })
        Blank()
        RoundIconButton({ icon: I_TRASH, boxSize: 40, iconSize: 20, onTap: () => { this.confirmClear(); } })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInset + 6, bottom: 12 })

      Row() {
        SegmentedTabs({
          labels: TABS,
          activeIndex: this.segmentIndex,
          onChanged: (i: number) => {
            this.segmentIndex = i;
            this.refresh();
          },
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 下载管理是另一套数据（带进度 / 状态），用自己的列表
      if (this.segmentIndex === 2) {
        DownloadListPane({ bottomInset: this.bottomInset })
          .layoutWeight(1)
          .width('100%')
      } else {
        // SongListPane 自己就是可滚动的懒加载列表（收藏可能几百首），
        // 所以这里不再套 Scroll/Column，直接让它占满剩余空间
        SongListPane({
          items: this.currentList(),
          currentId: this.currentId,
          emptyText: this.emptyText(),
          bottomInset: this.bottomInset,
          onPick: (index: number) => {
            const list: SongItem[] = this.currentList();
            if (index >= 0 && index < list.length) {
              this.currentId = list[index].id;
              PlaySession.getInstance().setQueueAndPlay(list, index);
            }
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
}
