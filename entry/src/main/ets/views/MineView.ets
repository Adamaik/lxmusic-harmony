import { K_HISTORY_VERSION, PlaySession, SongItem } from '../core/player/PlaySession';
import { LocalMusic } from '../core/local/LocalMusic';
import { C_BG } from '../ui/Theme';
import { I_TRASH } from '../ui/Icons';
import { PageTitle, RoundIconButton } from '../ui/Widgets';
import { CapsuleSegment } from '../ui/CapsuleSegment';
import { SongListPane } from './PlaylistView';
import { DownloadListPane } from './DownloadListView';
import { LocalMusicPane, confirmRemoveLocalSongs, removeLocalSongs } from './LocalMusicView';
import { WebDavPane } from './WebDavView';
import { WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { DownloadManager } from '../core/download/DownloadManager';

const TABS: string[] = ['播放历史', '下载管理', '本地音乐', '云端音乐'];

/**
 * 我的页
 *
 * 标题右侧是清空按钮；下面是分段胶囊（播放历史 / 下载管理 / 本地音乐 / 云端音乐），
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
  /** 去设置里的某个子页（云端音乐未配置时的「去设置」走它，由 Index 实现路由） */
  onNavigate: (action: string) => void = () => {
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

  /** 当前分段有多少条（决定清空按钮要不要弹确认） */
  private currentCount(): number {
    if (this.segmentIndex === 2) {
      return LocalMusic.getInstance().count();
    }
    if (this.segmentIndex === 3) {
      return WebDavLibrary.getInstance().count();
    }
    return this.currentList().length;
  }

  /**
   * 这个分段有没有「清空」这回事
   *
   * 云端音乐没有：曲库是服务器的一份缓存，服务器上的文件不归这个应用管，
   * 要拿掉什么直接在服务器上删、回面板刷新一下即可（本地缓存那点东西在设置页里清）。
   */
  private showClear(): boolean {
    return this.segmentIndex !== 3;
  }

  private emptyText(): string {
    return '这里还是空的';
  }

  private clearCurrent(): void {
    if (this.segmentIndex === 0) {
      PlaySession.getInstance().clearHistory();
      this.refresh();
      return;
    }
    if (this.segmentIndex === 1) {
      // 下载管理：只清「已完成 / 失败」的记录（正在下的留着），文件一并删掉
      const removed: number = DownloadManager.getInstance().clearFinished();
      if (removed > 0) {
        this.getUIContext().getPromptAction().showToast({ message: `已清空 ${removed} 条下载记录` });
      }
      return;
    }
    if (this.segmentIndex === 2) {
      // 本地音乐：删掉应用内的副本（设备里的原文件不动），收藏 / 队列里的同一条也一起摘掉
      const removed: number = removeLocalSongs(LocalMusic.getInstance().songsForUi());
      this.getUIContext().getPromptAction().showToast({ message: `已移除 ${removed} 首本地音乐` });
    }
  }

  private confirmClear(): void {
    if (this.currentCount() === 0) {
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
        if (this.showClear()) {
          RoundIconButton({ icon: I_TRASH, boxSize: 40, iconSize: 20, label: '清空播放记录', onTap: () => { this.confirmClear(); } })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInset + 6, bottom: 12 })

      // 分段筛选交给系统的 CapsuleSegmentButtonV2（见 ui/CapsuleSegment.ets）
      Row() {
        CapsuleSegment({
          labels: TABS,
          selectedIndex: this.segmentIndex,
          onSelect: (i: number) => {
            this.segmentIndex = i;
            this.refresh();
          },
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      // 下载管理 / 本地音乐 / 云端音乐是另一套数据（带进度 / 状态 / 扫描入口），各有自己的列表
      if (this.segmentIndex === 1) {
        DownloadListPane({ bottomInset: this.bottomInset })
          .layoutWeight(1)
          .width('100%')
      } else if (this.segmentIndex === 2) {
        LocalMusicPane({
          currentId: this.currentId,
          bottomInset: this.bottomInset,
          onPick: (index: number) => {
            const list: SongItem[] = LocalMusic.getInstance().songsForUi();
            if (index >= 0 && index < list.length) {
              this.currentId = list[index].id;
              PlaySession.getInstance().setQueueAndPlay(list, index);
            }
          },
        })
          .layoutWeight(1)
          .width('100%')
      } else if (this.segmentIndex === 3) {
        // 云端音乐（WebDAV）：面板里自己扫服务器（连上就能放），未配置时给「去设置」
        WebDavPane({
          currentId: this.currentId,
          bottomInset: this.bottomInset,
          onPick: (index: number) => {
            const list: SongItem[] = WebDavLibrary.getInstance().songsForUi();
            if (index >= 0 && index < list.length) {
              this.currentId = list[index].id;
              PlaySession.getInstance().setQueueAndPlay(list, index);
            }
          },
          onOpenSettings: () => {
            this.onNavigate('webdav');
          },
        })
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
