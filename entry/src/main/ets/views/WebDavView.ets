import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../core/player/PlaySession';
import { K_WEBDAV_PROGRESS, K_WEBDAV_VERSION, WebDavLibrary, WebDavScanResult } from '../core/webdav/WebDavLibrary';
import { WebDavSettings } from '../core/webdav/WebDavSettings';
import { C_CARD, C_DIVIDER, C_RED, C_TEXT_SUB, C_TEXT_WEAK, F_SUB, R_CARD } from '../ui/Theme';
import { I_REFRESH, IconGlyph } from '../ui/Icons';
import { SongListPane } from './PlaylistView';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavPane';

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
  onPick: (index: number) => void = () => {
  };
  /** 去「设置 - WebDAV 云端音乐」配服务器（未配置时的空状态要有个去处） */
  onOpenSettings: () => void = () => {
  };
  @State items: SongItem[] = [];
  @State scanning: boolean = false;
  /** 一句状态说明（扫完的结果 / 上次扫描时间 / 未配置的引导） */
  @State status: string = '';
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
      }
      .width('100%')

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
        onPick: (index: number) => {
          this.onPick(index);
        },
      })
        .layoutWeight(1)
        .width('100%')
    }
    .width('100%')
    .height('100%')
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
