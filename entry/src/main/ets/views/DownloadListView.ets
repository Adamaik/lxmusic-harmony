import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { I_MORE_CIRCLE, I_PLAY_CIRCLE, IconGlyph } from '../ui/Icons';
import { CoverArt } from '../ui/Widgets';
import { CoverStore } from '../core/music/CoverStore';
import { PlaySession } from '../core/player/PlaySession';
import { DownloadItem, DownloadManager, K_DOWNLOAD_VERSION } from '../core/download/DownloadManager';

/** 字节 -> 人话 */
function sizeText(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(0)} KB`;
  }
  return `${(kb / 1024).toFixed(1)} MB`;
}

/**
 * 下载管理列表（我的 - 下载管理）
 *
 * 显示每条下载的封面、歌名歌手、状态（排队中 / 进度 / 已完成体积 / 失败原因），
 * 点一行：已完成的直接播本地文件（离线可放），没下完的先提醒。
 * 右侧「更多」里可以重新下载 / 删除记录（删记录会连文件一起删）。
 * 下载目录本身在「设置 - 下载设置」里展示（系统没有跳到指定目录的能力，所以不在此放跳转入口）。
 */
@Component
export struct DownloadListPane {
  @Prop bottomInset: number = 0;
  @StorageLink(K_DOWNLOAD_VERSION) @Watch('refresh') downloadVersion: number = 0;
  @State items: DownloadItem[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = DownloadManager.getInstance().list();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 点一行：下完了就播本地文件；没下完就说明一下当前状态 */
  private playAt(item: DownloadItem): void {
    if (item.status !== 'done') {
      const label: string = item.status === 'downloading' || item.status === 'waiting'
        ? '还在下载中' : `没下完（${item.error}）`;
      this.toast(`${label}，可以在右侧「更多」里重新下载`);
      return;
    }
    void PlaySession.getInstance().setQueueAndPlay([DownloadManager.getInstance().toSong(item)], 0);
    this.toast(`播放已下载的「${item.name}」`);
  }

  private subtitle(item: DownloadItem): string {
    if (item.status === 'waiting') {
      return '排队中…';
    }
    if (item.status === 'downloading') {
      if (item.total > 0) {
        const percent: number = Math.min(99, Math.floor(item.received * 100 / item.total));
        return `下载中 ${percent}%　${sizeText(item.received)} / ${sizeText(item.total)}`;
      }
      return `下载中　已接收 ${sizeText(item.received)}`;
    }
    if (item.status === 'error') {
      return `下载失败：${item.error}`;
    }
    const size: string = sizeText(item.received);
    return size.length > 0 ? `已下载　${size}` : '已下载';
  }

  private removeWithFile(item: DownloadItem): void {
    const message: string = item.status === 'done'
      ? `会同时删掉本地文件「${item.fileName}」，确定吗？`
      : '确定删掉这条下载记录吗？';
    this.getUIContext().showAlertDialog({
      title: '删除下载',
      message: message,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: '#E33B3B',
          action: () => {
            DownloadManager.getInstance().remove(item.key);
            this.refresh();
            this.toast('已删除');
          },
        },
      ],
    });
  }

  @Builder
  rowMenu(item: DownloadItem) {
    Menu() {
      if (item.status === 'done') {
        MenuItem({ content: '播放' })
          .onClick(() => {
            this.playAt(item);
          })
      }
      if (item.status === 'error') {
        MenuItem({ content: '重新下载' })
          .onClick(() => {
            DownloadManager.getInstance().retry(item.key);
            this.refresh();
          })
      }
      MenuItem({ content: '删除' })
        .onClick(() => {
          this.removeWithFile(item);
        })
    }
    .font({ size: 16 })
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: C_DIVIDER,
      startMargin: LengthMetrics.vp(14),
      endMargin: LengthMetrics.vp(14),
    })
  }

  @Builder
  row(item: DownloadItem) {
    Row({ space: 12 }) {
      CoverArt({
        url: CoverStore.getInstance().coverFor(item.musicInfoJson, item.coverUrl),
        name: item.name,
        art: item.art,
        boxSize: 44,
        radius: 12,
        // 封面还在解析时给深色底，别先闪一张默认封面
        pending: item.coverUrl.length === 0 && item.musicInfoJson.length > 0,
      })

      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.subtitle(item))
          .fontSize(F_SUB)
          .fontColor(item.status === 'error' ? C_RED : C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        // 落盘位置没拿到系统目录时如实说明一句，不然用户去文件管理里找不到这个文件
        if (item.note.length > 0) {
          Text(item.note)
            .fontSize(11)
            .fontColor(C_RED)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 下载中：右边显示一个进度圆环，比纯文字直观
      if (item.status === 'downloading') {
        Progress({ value: item.total > 0 ? item.received : 0, total: item.total > 0 ? item.total : 1,
          type: ProgressType.Ring })
          .width(22)
          .height(22)
          .color(C_RED)
          .style({ strokeWidth: 3 })
          .backgroundColor('#E4E4E8')
      } else {
        IconGlyph({
          symbol: item.status === 'done' ? I_PLAY_CIRCLE : I_MORE_CIRCLE,
          iconSize: 22,
          color: C_TEXT_WEAK,
        })
          .bindMenu(this.rowMenu(item))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 14 })
    .height(66)
    .onClick(() => {
      this.playAt(item);
    })
  }

  build() {
    Column() {
      // 顶部一行：正在下载的条数（下载目录在「设置 - 下载设置」里展示，这里不放跳转按钮）
      if (DownloadManager.getInstance().activeCount() > 0) {
        Text(`正在下载 ${DownloadManager.getInstance().activeCount()} 首`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
          .textAlign(TextAlign.Start)
      }

      if (this.items.length === 0) {
        Column() {
          Text('还没有下载任何歌曲')
            .fontSize(15)
            .fontColor(C_TEXT_SUB)
          Text('在歌单、在线列表或播放器里点「下载」就会出现在这里')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 60 })
      } else {
        Column() {
          List() {
            ForEach(this.items, (item: DownloadItem) => {
              ListItem() {
                this.row(item)
              }
            }, (item: DownloadItem) => `${item.key}_${item.status}_${item.received}`)
          }
          .width('100%')
          .layoutWeight(1)
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)
          .divider({
            strokeWidth: 0.6,
            color: C_DIVIDER,
            startMargin: 72,
            endMargin: 0,
          })
          .scrollBar(BarState.Off)
          .padding({ bottom: this.bottomInset })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
