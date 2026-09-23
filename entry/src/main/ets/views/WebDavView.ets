import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { K_WEBDAV_PROGRESS, K_WEBDAV_VERSION, WebDavLibrary, WebDavScanResult } from '../core/webdav/WebDavLibrary';
import { WebDavSettings } from '../core/webdav/WebDavSettings';
import { C_CARD, C_DIVIDER, C_RED, C_TEXT_SUB, C_TEXT_WEAK, F_SUB, R_CARD } from '../ui/Theme';
import { I_REFRESH, IconGlyph } from '../ui/Icons';
import { allSelectedOf, favoriteSongs, pruneSelected, queueSongs, selectActionsOf, SelectAction, selectedSongs,
  SelectSession, toggleSelected } from '../ui/Selection';
import { SyncManager } from '../core/sync/SyncManager';
import { SongListPane } from './SongListPane';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavPane';

/**
 * 云端音乐的多选能做什么
 *
 * 没有「删除」：列表是服务器那台机器的一份缓存，文件不归这个应用管，要拿掉什么
 * 直接在服务器上删、回来刷新一下（本地缓存那点东西在「设置 - WebDAV」里清）。
 */
const CLOUD_ACTIONS: string[] = ['收藏', '加入播放列表', '加入歌单'];

/**
 * 云端音乐面板（我的 -> 云端音乐）
 *
 * 没有「导入」这一步：配置好服务器地址之后，进这一页就把那个目录（含子目录）
 * 扫一遍，扫到的音频直接列出来，点一下就能放。
 *
 * 与本地音乐面板的差别（详见 docs/WEBDAV.md）：
 *   - 音频**不落沙箱**：服务器随时可请求，播放时带 Authorization 头直接流播；
 *   - 列表是**服务器的一份缓存**，所以有「刷新」，也没有「移除」——
 *     服务器上的文件不归这个应用管，要拿掉什么直接在服务器上删，刷新一下就没了；
 *   - 元数据来自远端标签与同目录的封面 / 歌词，没有这些就按平台匹配。
 */
@Component
export struct WebDavPane {
  @Prop currentId: string = '';
  @Prop bottomInset: number = 0;
  /**
   * 顶部占位：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好）
   *
   * 这一页的头部（刷新 / 选择 / 扫描状态）是常驻控件，不该滚进标题栏底下，
   * 所以用一段固定占位，而不是首页那种 `contentStartOffset`。
   */
  @Prop topInset: number = 0;
  onPick: (index: number) => void = () => {
  };
  /** 去「设置 - WebDAV 云端音乐」配服务器（未配置时的空状态要有个去处） */
  onOpenSettings: () => void = () => {
  };
  @State items: SongItem[] = [];
  @State scanning: boolean = false;
  /** 一句状态说明（扫完的结果 / 上次扫描时间 / 未配置的引导） */
  @State status: string = '';
  /** 多选（长按进）：收藏 / 入歌单 / 入播放列表 */
  @State selecting: boolean = false;
  /** 勾选一变就往全局会话里发布一次（顶栏与底栏都听它，见 ui/Selection.ets） */
  @State @Watch('syncSelectBar') selectedIds: string[] = [];
  @State pickerOpen: boolean = false;
  @State candidates: PlaylistSummary[] = [];
  @StorageLink(K_WEBDAV_VERSION) @Watch('onLibraryChanged') libraryVersion: number = 0;
  @StorageLink(K_WEBDAV_PROGRESS) progressText: string = '';

  aboutToAppear(): void {
    this.refresh();
    // 连上就直接能放：配置好了、但还没扫过（或换了服务器地址）时自动扫一次，
    // 用户不用先点一下「刷新」
    this.autoScanIfNeeded();
  }

  onLibraryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = WebDavLibrary.getInstance().songsForUi();
    // 重扫之后把已经不存在的勾选摘掉
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.items) {
        alive.push(item.id);
      }
      const pruned: string[] = pruneSelected(this.selectedIds, alive);
      if (pruned.length !== this.selectedIds.length) {
        this.selectedIds = pruned;
      }
    }
  }

  // ------------------------------------------------------------ 多选

  private enterSelectingFrom(item: SongItem): void {
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
      allSelectedOf(this.selectedIds, this.items.length),
      selectActionsOf(CLOUD_ACTIONS),
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
    if (allSelectedOf(this.selectedIds, this.items.length)) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.items) {
      ids.push(item.id);
    }
    this.selectedIds = ids;
  }

  private selected(): SongItem[] {
    return selectedSongs(this.items, this.selectedIds);
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

  private toast(message: string): void {
    if (message.length === 0) {
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: message });
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

  private autoScanIfNeeded(): void {
    const settings = WebDavSettings.getInstance();
    if (!settings.isConfigured()) {
      this.status = '还没有配置服务器，先到设置里填地址与账号';
      return;
    }
    const lib = WebDavLibrary.getInstance();
    if (lib.scanRoot() === settings.getUrl() && lib.scanTime() > 0) {
      // 扫过了，直接用缓存
      this.status = `上次扫描：${describeAgo(lib.scanTime())}`;
      return;
    }
    void this.scan();
  }

  // ------------------------------------------------------------ 扫描

  private async scan(): Promise<void> {
    if (this.scanning) {
      return;
    }
    const settings = WebDavSettings.getInstance();
    if (!settings.isConfigured()) {
      this.status = '还没有配置服务器，先到设置里填地址与账号';
      return;
    }
    this.scanning = true;
    this.status = '正在扫描云服务器…';
    try {
      const result: WebDavScanResult = await WebDavLibrary.getInstance()
        .refresh(settings.config(), () => {
        });
      this.status = describeScan(result);
    } catch (e) {
      this.status = `扫描失败：${(e as Error).message}`;
      hilog.warn(DOMAIN, TAG, 'scan failed: %{public}s', (e as Error).message);
    } finally {
      this.scanning = false;
      this.refresh();
    }
  }

  // ------------------------------------------------------------ 界面

  /** 主按钮的文案：没配服务器 → 去设置；没扫过 → 连接并扫描；扫过 → 刷新 */
  private actionLabel(): string {
    const settings = WebDavSettings.getInstance();
    if (!settings.isConfigured()) {
      return '去设置';
    }
    const lib = WebDavLibrary.getInstance();
    return lib.scanTime() > 0 ? '刷新' : '连接并扫描';
  }

  @Builder
  header() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Row({ space: 6 }) {
          IconGlyph({ symbol: I_REFRESH, iconSize: 17, color: Color.White })
          Text(this.actionLabel())
            .fontSize(14)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: 14, right: 16, top: 9, bottom: 9 })
        .borderRadius(19)
        .backgroundColor(C_RED)
        .onClick(() => {
          if (!WebDavSettings.getInstance().isConfigured()) {
            this.onOpenSettings();
            return;
          }
          void this.scan();
        })
        .accessibilityText('扫描云服务器上的音乐')
        .accessibilityLevel('yes')

        Blank()

        Text(this.items.length > 0
          ? `${this.items.length} 首 · ${formatBytes(WebDavLibrary.getInstance().totalBytes())}`
          : '')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)

        // 多选入口：有歌才有意义（长按任意一行也行）
        if (this.items.length > 0) {
          Text(this.selecting ? '完成' : '选择')
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .padding({ left: 6, right: 2, top: 4, bottom: 4 })
            .onClick(() => {
              if (this.selecting) {
                this.exitSelecting();
              } else {
                this.selecting = true;
                this.selectedIds = [];
              }
            })
            .accessibilityText(this.selecting ? '退出多选' : '进入多选')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')

      // 多选的工具条不在这里 —— 顶栏那条由壳层画，底栏那条在 PanePage 的悬浮栏里。
      // 云端歌只能收藏 / 入库，删不掉（文件在服务器上）
      if (this.progressText.length > 0) {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(C_RED)
          Text(this.progressText)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('取消')
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .padding({ left: 8, right: 4 })
            .onClick(() => {
              WebDavLibrary.getInstance().cancelScan();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(R_CARD)
        .backgroundColor(C_CARD)
      }

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .lineHeight(17)
      }

      if (this.items.length === 0 && this.progressText.length === 0 && !this.scanning) {
        Text('云端音乐 = 自己 WebDAV 服务器上的音乐。填好服务器地址后扫一遍，'
          + '目录里的音乐就直接能播 —— 不用先导入什么。\n'
          + '封面与歌词会自动匹配（服务器上有同名 .lrc / 封面图就用它们），'
          + '听过的歌会缓存在本机，也能加进歌单与收藏。\n'
          + '这一份不参与洛雪同步（与本地音乐一致：同步只传在线歌曲）。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .lineHeight(18)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
  }

  build() {
    Column() {
      Column().height(this.topInset).width('100%')

      this.header()

      Divider()
        .strokeWidth(0.6)
        .color(C_DIVIDER)
        .margin({ left: 16, right: 16 })

      SongListPane({
        items: this.items,
        currentId: this.currentId,
        emptyText: '云端曲库还是空的',
        bottomInset: this.bottomInset,
        // 多选：长按进，点行 = 勾选
        selectable: true,
        selecting: this.selecting,
        selectedIds: this.selectedIds,
        onToggleSelect: (item: SongItem) => {
          this.toggleSelect(item);
        },
        onRequestSelect: (item: SongItem) => {
          this.enterSelectingFrom(item);
        },
        onPick: (index: number) => {
          this.onPick(index);
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

// ------------------------------------------------------------ 工具

/** 扫描结果的一句话说明（如实报「只扫了一部分」和「格式不支持」） */
export function describeScan(result: WebDavScanResult): string {
  if (result.total === 0 && result.unsupported === 0) {
    return result.failedFolders > 0
      ? `有 ${result.failedFolders} 个目录读不到，没有找到可播放的音频`
      : '这个目录里没有找到音频文件';
  }
  const parts: string[] = [`共 ${result.total} 首`];
  if (result.added > 0) {
    parts.push(`新增 ${result.added} 首`);
  }
  if (result.dropped > 0) {
    parts.push(`移除 ${result.dropped} 首`);
  }
  if (result.unsupported > 0) {
    parts.push(`${result.unsupported} 首格式不支持`);
  }
  if (result.truncated) {
    parts.push('目录太多，只扫了一部分');
  }
  if (result.failedFolders > 0) {
    parts.push(`${result.failedFolders} 个目录读不到`);
  }
  return parts.join('，');
}

/** 「刚刚 / 5 分钟前 / 3 小时前 / 2 天前」 */
export function describeAgo(at: number): string {
  if (at <= 0) {
    return '还没扫过';
  }
  const diff: number = Date.now() - at;
  if (diff < 60 * 1000) {
    return '刚刚';
  }
  const minutes: number = Math.floor(diff / (60 * 1000));
  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }
  const hours: number = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours} 小时前`;
  }
  return `${Math.floor(hours / 24)} 天前`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${Math.round(kb)} KB`;
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}
