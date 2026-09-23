import { K_LIBRARY_VERSION, PlaySession, SongItem } from '../core/player/PlaySession';
import { K_CURRENT_ID, K_QUEUE_COUNT } from '../core/player/PlaySession';
import { CoverStore, K_COVER_VERSION } from '../core/music/CoverStore';
import { SyncManager } from '../core/sync/SyncManager';
import { C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SUB } from '../ui/Theme';
import { I_QUEUE, I_TRASH, I_VOLUME, IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { isWebDavSong } from '../core/webdav/WebDavLibrary';

/**
 * 播放列表的内容
 *
 * 外层的半模态、标题栏、关闭钮、拖动条是系统的 bindSheet（见 pages/Index.ets）。
 * 队列本身用系统列表：`ListItemGroup(CARD)` 给整块白卡与行内分隔线，
 * 删歌走系统的左滑删除 `swipeAction`（划到底或点垃圾桶都能删）。
 *
 * 长按一首歌可以「收藏 / 不喜欢 / 移出队列」——收藏与不喜欢规则都是参与同步的数据，
 * 改动会即时上行到同步服务端。
 */
@Component
export struct PlayQueueContent {
  @Prop bottomInset: number = 0;
  @StorageLink(K_CURRENT_ID) currentId: string = '';
  @StorageLink(K_QUEUE_COUNT) queueCount: number = 0;
  @StorageLink(K_COVER_VERSION) coverVersion: number = 0;
  /** 收藏被同步服务端改动时刷新一下行内的爱心状态 */
  @StorageLink(K_LIBRARY_VERSION) libraryVersion: number = 0;
  @State items: SongItem[] = [];
  /** 懒加载数据源：队列可能几百首，只建可见的行 */
  private source: SongListSource = new SongListSource();
  /** 最近一次触摸点：删除时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = PlaySession.getInstance().queue.slice();
    this.source.setItems(this.items);
  }

  private deleteAt(index: number): void {
    PlaySession.getInstance().removeAt(index);
    // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
    dustBus.spray(this.dustX, this.dustY);
    this.refresh();
  }

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

  private toggleFavorite(item: SongItem): void {
    const session = PlaySession.getInstance();
    if (session.isFavorite(item.id)) {
      session.removeFavorite(item.id);
      this.toast(`已取消收藏「${item.name}」`);
      return;
    }
    if (session.addFavorite(item)) {
      this.toast(`已收藏「${item.name}」`);
    }
  }

  /** 下载：交给下载管理排队 */
  private download(item: SongItem): void {
    // 本地歌已经在本机了（菜单里也不显示这一项，这里只作兜底）
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    // 云端歌的下载由播放缓存负责，不排进下载队列
    if (isWebDavSong(item)) {
      this.toast(`「${item.name}」是云端音乐，播放时会自动缓存`);
      return;
    }
    const manager = DownloadManager.getInstance();
    const state: DownloadItem | null = manager.stateOf(downloadKeyOf(item));
    if (state !== null && state.status === 'done') {
      this.toast(`「${item.name}」已经下载过了`);
      return;
    }
    if (state !== null && (state.status === 'waiting' || state.status === 'downloading')) {
      this.toast(`「${item.name}」正在下载中`);
      return;
    }
    if (manager.enqueue(item) !== null) {
      this.toast(`已加入下载：${item.name}`);
    } else {
      this.toast('这首歌没法下载（缺少歌曲信息）');
    }
  }

  private dislike(item: SongItem): void {
    SyncManager.getInstance().getLibrary().addDislike(item.name, item.singer);
    this.toast(`已加入「不喜欢的歌曲」：${item.name}`);
  }

  @Builder
  rowMenu(item: SongItem, index: number) {
    Menu() {
      MenuItem({
        content: PlaySession.getInstance().isFavorite(item.id) ? '取消收藏' : '收藏',
      })
        .onClick(() => {
          this.toggleFavorite(item);
        })
      // 本地歌已经在本机了、云端歌由播放缓存负责，下载这一项对它们都没有意义
      if (!isLocalSong(item) && !isWebDavSong(item)) {
        MenuItem({ content: '下载' })
          .onClick(() => {
            this.download(item);
          })
      }
      MenuItem({ content: '不喜欢的歌曲' })
        .onClick(() => {
          this.dislike(item);
        })
      MenuItem({ content: '移出播放列表' })
        .onClick(() => {
          this.deleteAt(index);
        })
    }
  }

  /** 左滑露出来的删除块 */
  @Builder
  deleteAction(index: number) {
    Row() {
      IconGlyph({ symbol: I_TRASH, iconSize: 21, color: '#FFFFFF' })
    }
    .width(76)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(C_RED)
    .onClick(() => {
      this.deleteAt(index);
    })
  }

  @Builder
  songRow(item: SongItem, index: number) {
    Row({ space: 12 }) {
      CoverArt({
        url: CoverStore.getInstance().coverFor(item.musicInfoJson, item.coverUrl),
        name: item.name,
        art: item.art,
        boxSize: 44,
        radius: 12,
      })
      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(16)
          .fontColor(this.currentId === item.id ? C_RED : C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (item.singer.length > 0) {
          Text(item.singer)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.currentId === item.id) {
        IconGlyph({ symbol: I_VOLUME, iconSize: 19, color: C_RED })
      }
      IconGlyph({ symbol: I_TRASH, iconSize: 19, color: C_TEXT_SUB })
        .onClick(() => {
          this.deleteAt(index);
        })
    }
    .width('100%')
    .height(66)
    .padding({ left: 16, right: 16 })
    .onClick(() => {
      PlaySession.getInstance().playAt(index);
    })
    .onTouch((event: TouchEvent) => {
      this.rememberTouch(event);
    })
    .bindContextMenu(this.rowMenu(item, index), ResponseType.LongPress)
  }

  build() {
    Column() {
      if (this.items.length === 0) {
        Column() {
          EmptyState({
            icon: I_QUEUE,
            text: '播放列表是空的',
            hint: '在歌单或搜索结果里点一首歌，就会进到这里',
          })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ListItemGroup({ style: ListItemGroupStyle.CARD }) {
            LazyForEach(this.source, (item: SongItem, index: number) => {
              ListItem() {
                this.songRow(item, index)
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.deleteAction(index);
                  },
                  onAction: () => {
                    this.deleteAt(index);
                  },
                },
              })
            }, (item: SongItem, index: number) => `${index}_${item.id}`)
          }
          .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 72 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
      }

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
