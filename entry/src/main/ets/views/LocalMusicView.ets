import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistSummary, SongItem, PlaySession } from '../core/player/PlaySession';
import { ImportResult, K_LOCAL_PROGRESS, K_LOCAL_VERSION, LocalMusic } from '../core/local/LocalMusic';
import { C_CARD, C_DIVIDER, C_RED, C_TEXT_SUB, C_TEXT_WEAK, F_SUB, R_CARD } from '../ui/Theme';
import { I_IMPORT, IconGlyph } from '../ui/Icons';
import { allSelectedOf, favoriteSongs, queueSongs, selectActionsOf, SelectAction, selectedSongs, SelectSession,
  toggleSelected } from '../ui/Selection';
import { SyncManager } from '../core/sync/SyncManager';
import { SongListPane } from './SongListPane';
import { AddToPlaylistSheet } from './AddToPlaylistSheet';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalMusicPane';

/** 本地音乐的多选能做什么（「移除」是红底那枚主操作） */
const LOCAL_ACTIONS: string[] = ['收藏', '加入播放列表', '加入歌单'];

/**
 * 本地音乐面板（我的 -> 本地音乐）
 *
 * 为什么是「导入」而不是「扫描本机音乐」：系统不把音乐库开放给三方应用读
 * （ohos.permission.READ_AUDIO 是受限权限，只批克隆/备份/同步场景；也没有枚举
 * 音频媒体的 API），官方给的正路是让用户用 Picker 选。选中的 URI 只有临时权限，
 * 退到后台就失效，所以选中后立刻拷一份进沙箱 —— 从此不看系统脸色。
 *
 * 导入按钮直接拉起**文件管理的音频聚合视图**（`mergeMode = AUDIO`）：一屏列出
 * 设备上所有音频，全选一次导完。不再提供别的入口，理由见 `scanDeviceAudio()`。
 * 详细调研见 docs/LOCAL_MUSIC.md。
 *
 * 多选与「我的」页其它列表一致：长按任意一行进多选（右上角那枚「选择」是另一个入口，
 * 想不起来长按的时候点它），能收藏 / 入歌单 / 入播放列表，以及移除应用内副本。
 */
@Component
export struct LocalMusicPane {
  @Prop currentId: string = '';
  @Prop bottomInset: number = 0;
  /**
   * 顶部占位：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好）
   *
   * 这一页的头部（导入 / 选择）是常驻控件，不该滚进标题栏底下，所以用一段固定占位，
   * 而不是首页那种 `contentStartOffset`。
   */
  @Prop topInset: number = 0;
  onPick: (index: number) => void = () => {
  };
  @State items: SongItem[] = [];
  /** 导入进行中（进度文案在 AppStorage 里，切走再回来还能看到） */
  @State importing: boolean = false;
  /** 多选模式（长按进）：打开后点行是勾选，行尾换成勾选圈 */
  @State selecting: boolean = false;
  /** 勾选一变就往全局会话里发布一次（顶栏与底栏都听它，见 ui/Selection.ets） */
  @State @Watch('syncSelectBar') selectedIds: string[] = [];
  /** 「加入歌单」面板 */
  @State pickerOpen: boolean = false;
  @State candidates: PlaylistSummary[] = [];
  @StorageLink(K_LOCAL_VERSION) @Watch('onLibraryChanged') libraryVersion: number = 0;
  @StorageLink(K_LOCAL_PROGRESS) progressText: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  onLibraryChanged(): void {
    this.refresh();
  }

  private refresh(): void {
    this.items = LocalMusic.getInstance().songsForUi();
    // 库变了（导入/移除）就把已经不存在的条目从勾选里摘掉，
    // 否则「移除 N」会带着幽灵条目算数
    if (this.selectedIds.length > 0) {
      const alive: string[] = [];
      for (const item of this.items) {
        alive.push(item.id);
      }
      const pruned: string[] = [];
      for (const id of this.selectedIds) {
        if (alive.includes(id)) {
          pruned.push(id);
        }
      }
      if (pruned.length !== this.selectedIds.length) {
        this.selectedIds = pruned;
      }
    }
  }

  // ------------------------------------------------------------ 多选

  private enterSelecting(): void {
    this.selecting = true;
    this.selectedIds = [];
    // @Watch 只在**值真的变了**时才回调，进多选这一下不能只靠它（本来就没勾任何歌时不变）
    this.publishSelectBar();
  }

  /** 长按某一行进多选：顺手把长按的那条勾上 */
  private enterSelectingFrom(item: SongItem): void {
    this.enterSelecting();
    this.selectedIds = [item.id];
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
      this.allSelected(),
      selectActionsOf(LOCAL_ACTIONS, '移除'),
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

  private allSelected(): boolean {
    return allSelectedOf(this.selectedIds, this.items.length);
  }

  /** 全选 / 取消全选（一个按钮来回切，列表大了才有意义） */
  private toggleSelectAll(): void {
    if (this.allSelected()) {
      this.selectedIds = [];
      return;
    }
    const ids: string[] = [];
    for (const item of this.items) {
      ids.push(item.id);
    }
    this.selectedIds = ids;
  }

  private selectedItems(): SongItem[] {
    return selectedSongs(this.items, this.selectedIds);
  }

  /** 批量移除（走共用那句确认框，删的是应用内副本，设备里的原文件不动） */
  private removeSelected(): void {
    const targets: SongItem[] = this.selectedItems();
    if (targets.length === 0) {
      this.toast('先勾选要移除的歌');
      return;
    }
    confirmRemoveLocalSongs(this.getUIContext(), targets, (removed: number) => {
      this.exitSelecting();
      this.refresh();
      this.toast(`已移除 ${removed} 首`);
    });
  }

  private openPlaylistPicker(): void {
    if (this.selectedItems().length === 0) {
      this.toast('先勾选要加入歌单的歌');
      return;
    }
    this.candidates = SyncManager.getInstance().getLibrary().playlistSummaries();
    this.pickerOpen = true;
  }

  private addSelectedToPlaylist(playlist: PlaylistSummary): void {
    const targets: SongItem[] = this.selectedItems();
    const added: number = SyncManager.getInstance().getLibrary().addMusicToPlaylist(playlist.id, targets);
    this.pickerOpen = false;
    this.exitSelecting();
    this.toast(added > 0 ? `已把 ${added} 首加入「${playlist.name}」` : `「${playlist.name}」里已经有这些歌了`);
  }

  private createPlaylistAndAdd(name: string): void {
    if (name.length === 0) {
      return;
    }
    const targets: SongItem[] = this.selectedItems();
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
    if (label === '移除') {
      this.removeSelected();
      return;
    }
    const targets: SongItem[] = this.selectedItems();
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

  private toast(message: string): void {
    // 导入可能跨越「切到别的分段页」：组件已经销毁时 getUIContext 会抛，
    // 那时提示丢掉就行，别让一个 toast 把导入流程带崩
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast skipped: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 导入

  private hostContext(): common.UIAbilityContext | null {
    const context = this.getUIContext().getHostContext();
    return context === undefined ? null : context as common.UIAbilityContext;
  }

  /**
   * 导入入口（唯一的）：DocumentViewPicker + mergeMode = AUDIO
   *
   * 这个模式拉起的是**文件管理应用自己的聚合视图（音频分类页）**：一屏列出设备上
   * 所有音频文件，多选/全选由文件管理界面提供。官方指南明写这个参数
   * 「在 Phone 设备中可正常使用，在其他设备中无效果」—— 这是三方应用在手机上
   * 能做的最接近「扫描本机音乐」的事（自己扫全盘是不允许的：
   * READ_AUDIO / READ_MEDIA 都是受限权限，只批克隆/备份/同步场景）。
   *
   * 注意：mergeMode 置为非 DEFAULT 后，其它参数基本不生效（官方文档：
   * 「API 版本 26.0.0 及之后的版本当该参数置为非 DEFAULT 时，仅 fileSuffixFilters
   * 参数生效」），所以这里不再配 maxSelectNumber / fileSuffixFilters —— 聚合视图
   * 本身就只有音频，数量上限由文件管理界面自己管。
   *
   * 曾经的两条路（都撤了，记在这免得以后重复踩）：
   *   - `selectMode = FOLDER` 选文件夹：手机在 API 26 之前不支持这个参数
   *     （官方指南：「从 API 版本 26.0.0 开始，当文件类型是 FOLDER 时，Phone 设备
   *     支持该参数」），而且目录 URI 也不是 `fs.listFileSync` 能接受的参数
   *     （它只吃应用沙箱路径），两者叠加的结果是「选了文件夹却报目录里没文件」；
   *   - `AudioViewPicker`：也能用，但只是逐个多选，批量导入不如聚合视图。
   */
  private scanDeviceAudio(): void {
    const context: common.UIAbilityContext | null = this.hostContext();
    if (context === null) {
      this.toast('当前环境不支持选择文件');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.mergeMode = picker.MergeTypeMode.AUDIO;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options)
        .then((uris: string[]) => {
          void this.runImport(uris);
        })
        .catch((err: BusinessError) => {
          // 用户取消也会走到这里（错误码里带 cancel），不当成失败提示
          hilog.info(DOMAIN, TAG, 'scan audio ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'scan audio failed: %{public}s', JSON.stringify(e));
      this.toast('打不开文件管理的音频视图');
    }
  }

  private async runImport(uris: string[]): Promise<void> {
    if (uris.length === 0) {
      return;
    }
    this.importing = true;
    try {
      const result: ImportResult = await LocalMusic.getInstance().importUris(uris);
      this.toast(describeImport(result));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', JSON.stringify(e));
      this.toast('导入失败，请重试');
    } finally {
      this.importing = false;
      this.refresh();
    }
  }

  // ------------------------------------------------------------ 删除

  private confirmRemove(item: SongItem): void {
    confirmRemoveLocalSongs(this.getUIContext(), [item], (removed: number) => {
      this.refresh();
      this.toast(`已移除 ${removed} 首`);
    });
  }

  // ------------------------------------------------------------ 界面

  @Builder
  header() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Row({ space: 6 }) {
          IconGlyph({ symbol: I_IMPORT, iconSize: 17, color: Color.White })
          Text('导入音乐')
            .fontSize(14)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: 14, right: 16, top: 9, bottom: 9 })
        .borderRadius(19)
        .backgroundColor(C_RED)
        .onClick(() => {
          this.scanDeviceAudio();
        })
        .accessibilityText('导入音乐，打开文件管理的音频列表')
        .accessibilityLevel('yes')

        Blank()

        Text(this.items.length > 0 ? `${this.items.length} 首 · ${formatBytes(LocalMusic.getInstance().totalBytes())}` : '')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)

        // 多选入口：有歌才有意义
        if (this.items.length > 0) {
          Text(this.selecting ? '完成' : '选择')
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .padding({ left: 6, right: 2, top: 4, bottom: 4 })
            .onClick(() => {
              if (this.selecting) {
                this.exitSelecting();
              } else {
                this.enterSelecting();
              }
            })
            .accessibilityText(this.selecting ? '退出多选' : '进入多选')
            .accessibilityLevel('yes')
        }
      }
      .width('100%')

      if (this.importing || this.progressText.length > 0) {
        Row({ space: 10 }) {
          Text(this.progressText.length > 0 ? `正在导入 ${this.progressText}` : '正在导入…')
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
              LocalMusic.getInstance().cancelImport();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(R_CARD)
        .backgroundColor(C_CARD)
      }

      if (this.items.length === 0 && !this.importing) {
        Text('系统不允许三方应用自己扫描音乐库，所以导入走文件管理的音频列表：\n'
          + '点上面的「导入音乐」→ 一屏列出设备上的音频 → 长按任意一首选「全选」→ 确定，'
          + '一次就能把整个文件夹导进来。\n'
          + '选中的歌会拷一份到应用内，设备里的原文件不动。')
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
        emptyText: '还没有导入本地音乐',
        bottomInset: this.bottomInset,
        // 多选模式：长按进多选，点行 = 勾选，行尾换勾选圈
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
        onRemoveLocal: (item: SongItem) => {
          this.confirmRemove(item);
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

/**
 * 删除一批本地歌：删掉应用内的副本，并把收藏 / 播放历史 / 队列里的同一条一起摘掉
 *
 * 界面上有三个地方能删（本地音乐列表、播放历史、将来别处），逻辑一样，所以放在这里共用。
 * @returns 真正删掉的条数
 */
export function removeLocalSongs(items: SongItem[]): number {
  const music = LocalMusic.getInstance();
  const keys: string[] = [];
  const ids: string[] = [];
  for (const item of items) {
    const key: string = music.keyOfId(item.id);
    if (key.length > 0) {
      keys.push(key);
    }
    ids.push(item.id);
  }
  const removed: number = music.removeKeys(keys);
  if (removed > 0) {
    // 不摘掉的话，收藏 / 历史 / 队列里会留下点一下就报错的幽灵条目
    PlaySession.getInstance().dropLocalSongs(ids);
  }
  return removed;
}

/** 删除前问一句（设备里的原文件不受影响），确认后调 onDone */
export function confirmRemoveLocalSongs(context: UIContext, items: SongItem[],
  onDone: (removed: number) => void): void {
  if (items.length === 0) {
    return;
  }
  const what: string = items.length === 1 ? `「${items[0].name}」` : `这 ${items.length} 首`;
  context.showAlertDialog({
    title: '从本地音乐移除',
    message: `将删除${what}在应用内的副本（设备里的原文件不受影响）。`,
    autoCancel: true,
    buttons: [
      { value: '取消', action: () => { } },
      {
        value: '移除',
        fontColor: C_RED,
        action: () => {
          onDone(removeLocalSongs(items));
        },
      },
    ],
  });
}

/** 导入结果的一句话说明 */
function describeImport(result: ImportResult): string {
  const parts: string[] = [];
  if (result.added > 0) {
    parts.push(`已导入 ${result.added} 首`);
  }
  if (result.skipped > 0) {
    parts.push(`跳过 ${result.skipped} 首（已经导入过）`);
  }
  if (result.unsupported > 0) {
    parts.push(`${result.unsupported} 首格式不支持`);
  }
  if (result.failed > 0) {
    parts.push(`${result.failed} 首读取失败`);
  }
  if (parts.length === 0) {
    return '没有可导入的文件';
  }
  return parts.join('，');
}

/** 占用空间（界面上只要一个量级） */
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
