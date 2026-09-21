import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem, PlaySession } from '../core/player/PlaySession';
import { ImportResult, K_LOCAL_PROGRESS, K_LOCAL_VERSION, LocalMusic } from '../core/local/LocalMusic';
import { C_CARD, C_DIVIDER, C_RED, C_TEXT_SUB, C_TEXT_WEAK, F_SUB, R_CARD } from '../ui/Theme';
import { I_IMPORT, IconGlyph } from '../ui/Icons';
import { SongListPane } from './PlaylistView';

const DOMAIN: number = 0x0001;
const TAG: string = 'LocalMusicPane';

/** 单次导入的上限（Picker 在 API 20 及以前也是 500） */
const MAX_PICK: number = 500;

/**
 * 本地音乐面板（我的 -> 本地音乐）
 *
 * 为什么是「导入」而不是「扫描本机音乐」：系统不把音乐库开放给三方应用读
 * （ohos.permission.READ_AUDIO 是受限权限，只批克隆/备份/同步场景；也没有枚举
 * 音频媒体的 API），官方给的正路是让用户用 Picker 选。选中的 URI 只有临时权限，
 * 退到后台就失效，所以选中后立刻拷一份进沙箱 —— 从此不看系统脸色。
 * 详细调研见 docs/LOCAL_MUSIC.md。
 */
@Component
export struct LocalMusicPane {
  @Prop currentId: string = '';
  @Prop bottomInset: number = 0;
  onPick: (index: number) => void = () => {
  };
  @State items: SongItem[] = [];
  /** 导入进行中（进度文案在 AppStorage 里，切走再回来还能看到） */
  @State importing: boolean = false;
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

  @Builder
  importMenu() {
    Menu() {
      MenuItem({ content: '选择音乐文件' })
        .onClick(() => {
          this.pickFiles();
        })
      MenuItem({ content: '选择音乐文件夹' })
        .onClick(() => {
          this.pickFolder();
        })
    }
    .font({ size: 16 })
  }

  /** 选文件：AudioViewPicker（音频专用，可多选） */
  private pickFiles(): void {
    const context: common.UIAbilityContext | null = this.hostContext();
    if (context === null) {
      this.toast('当前环境不支持选择文件');
      return;
    }
    try {
      const options: picker.AudioSelectOptions = new picker.AudioSelectOptions();
      options.maxSelectNumber = MAX_PICK;
      const audioPicker: picker.AudioViewPicker = new picker.AudioViewPicker(context);
      audioPicker.select(options)
        .then((uris: string[]) => {
          void this.runImport(uris);
        })
        .catch((err: BusinessError) => {
          // 用户取消也会走到这里（错误码里带 cancel），不当成失败提示
          hilog.info(DOMAIN, TAG, 'pick files ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pick files failed: %{public}s', JSON.stringify(e));
      this.toast('打开文件选择器失败');
    }
  }

  /**
   * 选文件夹：DocumentViewPicker 的 FOLDER 模式，再把目录里的文件列出来
   *
   * 手机端一次只能选一个目录（allowsMulFolderSelection 在 Phone 上无效）。
   * 目录 URI 能不能用 fs.listFileSync 枚举，官方文档没有明说 —— 失败时明确告诉
   * 用户改用「选择音乐文件」，不要静默什么都不发生（真机验证项，见 docs/LOCAL_MUSIC.md）。
   */
  private pickFolder(): void {
    const context: common.UIAbilityContext | null = this.hostContext();
    if (context === null) {
      this.toast('当前环境不支持选择文件夹');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.selectMode = picker.DocumentSelectMode.FOLDER;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      documentPicker.select(options)
        .then((results: string[]) => {
          if (results.length === 0) {
            return;
          }
          const uris: string[] = this.listFolder(results[0]);
          if (uris.length === 0) {
            this.toast('这个目录里没有找到文件，请改用「选择音乐文件」');
            return;
          }
          void this.runImport(uris);
        })
        .catch((err: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'pick folder ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'pick folder failed: %{public}s', JSON.stringify(e));
      this.toast('打开文件夹选择器失败');
    }
  }

  /** 目录 URI -> 目录里的文件 URI（不含子目录） */
  private listFolder(dirUri: string): string[] {
    const out: string[] = [];
    try {
      const names: string[] = fs.listFileSync(dirUri);
      for (const name of names) {
        out.push(`${dirUri}/${name}`);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list folder failed: %{public}s', JSON.stringify(e));
      return [];
    }
    return out;
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
        .bindMenu(this.importMenu())

        Blank()

        Text(this.items.length > 0 ? `${this.items.length} 首 · ${formatBytes(LocalMusic.getInstance().totalBytes())}` : '')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
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
        Text('系统不允许应用直接读取设备里的音乐库，所以本地音乐需要手动导入：'
          + '从上面的按钮选文件或文件夹，选中的音乐会拷一份到应用内（原文件不动）。')
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
