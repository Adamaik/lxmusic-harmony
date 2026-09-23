import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT_STRONG, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { I_CHECK_CIRCLE, I_CIRCLE, I_MORE_CIRCLE, I_PLAY_CIRCLE, IconGlyph } from '../ui/Icons';
import { CoverArt } from '../ui/Widgets';
import { CoverStore } from '../core/music/CoverStore';
import { PlaySession } from '../core/player/PlaySession';
import { DownloadItem, DownloadManager, K_DOWNLOAD_VERSION } from '../core/download/DownloadManager';
import { allSelectedOf, pruneSelected, selectActionsOf, SelectAction, SelectSession, toggleSelected } from '../ui/Selection';

/** 下载管理的多选能做什么 */
const DOWNLOAD_ACTIONS: string[] = ['重新下载'];

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
 * 长按任意一行进多选，可以一次重试或删除多条。
 * 下载目录本身在「设置 - 下载设置」里展示（系统没有跳到指定目录的能力，所以不在此放跳转入口）。
 */
@Component
export struct DownloadListPane {
  @Prop bottomInset: number = 0;
  /**
   * 顶部占位：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好）
   *
   * 列表是从标题栏下方开始的（这一页没有会滚动的头部），所以一段固定占位就够，
   * 不需要首页那种 `contentStartOffset`。
   */
  @Prop topInset: number = 0;
  @StorageLink(K_DOWNLOAD_VERSION) @Watch('refresh') downloadVersion: number = 0;
  @State items: DownloadItem[] = [];
  /** 多选（长按进）：勾选的是下载记录的 key */
  @State selecting: boolean = false;
  /** 勾选一变就往全局会话里发布一次（顶栏与底栏都听它，见 ui/Selection.ets） */
  @State @Watch('syncSelectBar') selectedIds: string[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = DownloadManager.getInstance().list();
    // 记录删了/重下以后把失效的勾选摘掉，免得「删除 3 条」里混着已经不在的
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.items) {
        alive.push(item.key);
      }
      const pruned: string[] = pruneSelected(this.selectedIds, alive);
      if (pruned.length !== this.selectedIds.length) {
        this.selectedIds = pruned;
      }
    }
  }

  // ------------------------------------------------------------ 多选

  private isSelected(key: string): boolean {
    return this.selectedIds.indexOf(key) >= 0;
  }

  private enterSelecting(item: DownloadItem): void {
    this.selecting = true;
    this.selectedIds = [item.key];
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

  /** 把「勾了几项 / 能做什么」交给全局会话：顶栏与底栏据此绘制 */
  private publishSelectBar(): void {
    SelectSession.getInstance().show(
      this.selectedIds.length,
      allSelectedOf(this.selectedIds, this.items.length),
      selectActionsOf(DOWNLOAD_ACTIONS, '删除'),
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
    if (actions[index].label === '删除') {
      this.removeSelected();
      return;
    }
    this.retrySelected();
  }

  private toggleSelect(item: DownloadItem): void {
    this.selectedIds = toggleSelected(this.selectedIds, item.key);
  }

  private toggleSelectAll(): void {
    if (allSelectedOf(this.selectedIds, this.items.length)) {
      this.selectedIds = [];
      return;
    }
    const keys: string[] = [];
    for (const item of this.items) {
      keys.push(item.key);
    }
    this.selectedIds = keys;
  }

  private selected(): DownloadItem[] {
    const out: DownloadItem[] = [];
    for (const item of this.items) {
      if (this.isSelected(item.key)) {
        out.push(item);
      }
    }
    return out;
  }

  /** 重试勾选里「失败」的那些（排队中 / 正在下的不重来，避免把已经下一半的丢掉） */
  private retrySelected(): void {
    const manager = DownloadManager.getInstance();
    let retried: number = 0;
    for (const item of this.selected()) {
      if (item.status === 'error') {
        manager.retry(item.key);
        retried++;
      }
    }
    if (retried === 0) {
      this.toast('勾选的里面没有失败的下载');
      return;
    }
    this.exitSelecting();
    this.refresh();
    this.toast(`已重新排队 ${retried} 首`);
  }

  /** 删勾选的那些（已下完的连文件一起删） */
  private removeSelected(): void {
    const targets: DownloadItem[] = this.selected();
    if (targets.length === 0) {
      this.toast('先勾选要删除的下载');
      return;
    }
    let files: number = 0;
    for (const item of targets) {
      if (item.status === 'done') {
        files++;
      }
    }
    const message: string = files > 0
      ? `会同时删掉这 ${targets.length} 条记录和其中 ${files} 个已下载的文件，确定吗？`
      : `确定删掉这 ${targets.length} 条下载记录吗？`;
    this.getUIContext().showAlertDialog({
      title: '删除下载',
      message: message,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            const manager = DownloadManager.getInstance();
            for (const item of targets) {
              manager.remove(item.key);
            }
            this.exitSelecting();
            this.refresh();
            this.toast(`已删除 ${targets.length} 条`);
          },
        },
      ],
    });
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
      // 「边听边存」= 开了「缓存时自动下载」后排进来的，不是用户点的下载
      return item.auto ? '排队中…（边听边存）' : '排队中…';
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
    const parts: string[] = [];
    const size: string = sizeText(item.received);
    parts.push(size.length > 0 ? `已下载　${size}` : '已下载');
    if (item.auto) {
      parts.push('边听边存');
    }
    // 标签嵌入结果跟着体积一起显示：用户一眼能看出封面歌词有没有写进文件
    if (item.tagNote.length > 0) {
      parts.push(item.tagNote);
    }
    return parts.join('　·　');
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
          fontColor: C_RED,
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
      // 长按进多选是主入口，这一项是给「想不起来长按」的人留的
      MenuItem({ content: '多选' })
        .onClick(() => {
          this.enterSelecting(item);
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

      // 多选：行尾换成勾选圈（下到一半的那条这时也先不显示进度环）
      if (this.selecting) {
        IconGlyph({
          symbol: this.isSelected(item.key) ? I_CHECK_CIRCLE : I_CIRCLE,
          iconSize: 22,
          color: this.isSelected(item.key) ? C_RED : C_TEXT_WEAK,
        })
          .accessibilityLevel('no')
      } else if (item.status === 'downloading') {
        // 下载中：右边显示一个进度圆环，比纯文字直观
        Progress({ value: item.total > 0 ? item.received : 0, total: item.total > 0 ? item.total : 1,
          type: ProgressType.Ring })
          .width(22)
          .height(22)
          .color(C_RED)
          .style({ strokeWidth: 3 })
          .backgroundColor(C_FILL_SOFT_STRONG)
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
      if (this.selecting) {
        this.toggleSelect(item);
        return;
      }
      this.playAt(item);
    })
    // 长按进多选（行菜单还在右边那颗「更多」上）
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.enterSelecting(item);
      }
    }))
  }

  build() {
    Column() {
      // 多选的工具条不在这里 —— 顶栏那条由壳层画，底栏那条在 PanePage 的悬浮栏里
      Column().height(this.topInset).width('100%')

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
