import { hilog } from '@kit.PerformanceAnalysisKit';
import { K_WEBDAV_PROGRESS, K_WEBDAV_VERSION, WebDavLibrary, WebDavScanResult } from '../core/webdav/WebDavLibrary';
import { K_WEBDAV_READ_TAGS, K_WEBDAV_URL, WebDavSettings, normalizeServerUrl } from '../core/webdav/WebDavSettings';
import { WebDavClient } from '../core/webdav/WebDavClient';
import { WebDavConfig, WebDavProbeResult } from '../core/webdav/WebDavTypes';
import { C_BG, C_CARD, C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB,
  R_CARD } from '../ui/Theme';
import { HintText, ToggleSetting } from '../ui/SettingWidgets';
import { describeAgo, describeScan } from './WebDavView';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavSettings';

/**
 * WebDAV 云端音乐设置
 *
 * 两件事：把「怎么连上服务器」填对（地址 / 账号 / 密码 + 一次连通性自检），
 * 以及管这份曲库的本地缓存（条数、占用、清缓存、重新扫描）。
 *
 * **连上就直接能放**：自检通过后会自动扫一次服务器（把目录里的音乐列出来），
 * 用户不点任何「导入」。换了地址、或在服务器上加了歌，点「重新扫描」即可。
 *
 * 认证只支持 HTTP Basic —— 自建服务（Nextcloud / Alist / 群晖 / Apache mod_dav）
 * 默认都支持；服务器只开 Digest 时这里会明确说出来，不做半吊子实现（见 WebDavClient）。
 *
 * 密码按项目既有约定明文落在应用沙箱里（与同步的认证码、音源脚本一致）：
 * 三方应用读不到别人的沙箱，系统也没有给普通应用「静默存一个服务凭据」的通用接口。
 */
@Component
export struct WebDavSettingsView {
  @Prop bottomInset: number = 0;
  @State host: string = '';
  @State user: string = '';
  @State password: string = '';
  @State busy: boolean = false;
  @State status: string = '';
  /** 曲库条数 / 服务器上的总大小 / 本地缓存大小（版本号变了就重算） */
  @State songCount: number = 0;
  @State songBytes: number = 0;
  @State cacheBytes: number = 0;
  @State scannedAt: number = 0;
  @StorageLink(K_WEBDAV_URL) urlValue: string = '';
  @StorageLink(K_WEBDAV_READ_TAGS) readTags: boolean = true;
  @StorageLink(K_WEBDAV_VERSION) @Watch('onLibraryChanged') libraryVersion: number = 0;
  @StorageLink(K_WEBDAV_PROGRESS) progressText: string = '';

  aboutToAppear(): void {
    const settings = WebDavSettings.getInstance();
    // 密码不发布到 AppStorage（没必要到处躺一份），所以这里现取一次当输入框初值
    this.host = settings.getUrl();
    this.user = settings.getUsername();
    this.password = settings.getPassword();
    this.refreshStats();
  }

  onLibraryChanged(): void {
    this.refreshStats();
  }

  private refreshStats(): void {
    const lib = WebDavLibrary.getInstance();
    this.songCount = lib.count();
    this.songBytes = lib.totalBytes();
    this.cacheBytes = lib.cacheBytes();
    this.scannedAt = lib.scanTime();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toast skipped: %{public}s', JSON.stringify(e));
    }
  }

  private currentConfig(): WebDavConfig {
    return {
      url: normalizeServerUrl(this.host),
      username: this.user.trim(),
      password: this.password,
    };
  }

  /** 把界面上填的三项存下来（改动即时生效，不用点保存） */
  private saveInputs(): void {
    const settings = WebDavSettings.getInstance();
    settings.setUrl(this.host);
    settings.setUsername(this.user);
    settings.setPassword(this.password);
  }

  /**
   * 测试连接：列一次根目录，把结果原样说出来（含失败原因）
   *
   * 连上之后**顺手扫一次** —— 这就是「连上就直接能播放目录内的所有音乐」那一步，
   * 省掉用户再去找哪个按钮。
   */
  private async testAndScan(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.saveInputs();
    if (this.currentConfig().url.length === 0) {
      this.status = '请先填服务器地址';
      return;
    }
    this.busy = true;
    this.status = '正在连接…';
    try {
      const result: WebDavProbeResult = await WebDavClient.getInstance().probe(this.currentConfig());
      if (!result.ok) {
        this.status = `连不上：${result.message}`;
        return;
      }
      this.status = result.message;
      await this.runScan();
    } catch (e) {
      this.status = `连不上：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  /** 重新扫描（服务器上加过歌 / 换过目录之后用） */
  private async rescan(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.saveInputs();
    if (this.currentConfig().url.length === 0) {
      this.status = '请先填服务器地址';
      return;
    }
    this.busy = true;
    this.status = '正在扫描云服务器…';
    try {
      await this.runScan();
    } catch (e) {
      this.status = `扫描失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private async runScan(): Promise<void> {
    const result: WebDavScanResult = await WebDavLibrary.getInstance()
      .refresh(this.currentConfig(), () => {
      });
    this.status = describeScan(result);
    this.refreshStats();
  }

  /** 清空本地缓存（封面 / 歌词 / 标签 / 匹配记录）；服务器上的文件与曲库列表都不动 */
  private confirmClearCache(): void {
    if (this.cacheBytes <= 0) {
      this.toast('本地还没有缓存');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空云端音乐的本地缓存',
      message: '将清掉封面、歌词与匹配记录，下次扫描 / 播放会重新取一遍。'
        + '服务器上的音乐文件与曲库列表都不受影响。',
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '清空',
          fontColor: C_RED,
          action: () => {
            WebDavLibrary.getInstance().clearCaches();
            this.refreshStats();
            this.toast('已清空本地缓存');
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 界面

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(F_SECTION)
      .fontWeight(FontWeight.Bold)
      .fontColor(C_TEXT)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 4, bottom: 8 })
  }

  @Builder
  serverCard() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text('服务器')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.host, placeholder: 'http://192.168.1.10:5006/dav' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.busy)
          .onChange((value: string) => {
            this.host = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('用户名')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.user, placeholder: '留空表示匿名访问' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.busy)
          .onChange((value: string) => {
            this.user = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('密码')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.password, placeholder: '部分服务需要「应用密码」' })
          .type(InputType.Password)
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.busy)
          .onChange((value: string) => {
            this.password = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  actionCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Button(this.busy ? '处理中…' : '测试连接并扫描')
          .fontSize(14)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(C_RED)
          .enabled(!this.busy)
          .onClick(() => {
            void this.testAndScan();
          })
        Button('重新扫描')
          .fontSize(14)
          .height(36)
          .layoutWeight(1)
          .backgroundColor('#EDEDF0')
          .fontColor(C_TEXT)
          .enabled(!this.busy)
          .onClick(() => {
            void this.rescan();
          })
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
            .onClick(() => {
              WebDavLibrary.getInstance().cancelScan();
            })
        }
        .width('100%')
      }

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(F_SUB)
          .fontColor(this.status.startsWith('连不上') || this.status.startsWith('扫描失败')
            ? C_RED : C_TEXT_SUB)
          .width('100%')
          .lineHeight(17)
      }
    }
    .width('100%')
  }

  @Builder
  libraryCard() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('云端曲库')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .layoutWeight(1)
        Text(this.songCount > 0 ? `${this.songCount} 首 · ${formatBytes(this.songBytes)}` : '还没有歌')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('上次扫描')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .layoutWeight(1)
        Text(describeAgo(this.scannedAt))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('本地缓存')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .layoutWeight(1)
        Text(this.cacheBytes > 0 ? formatBytes(this.cacheBytes) : '无')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')

      Button('清空本地缓存')
        .fontSize(14)
        .height(36)
        .width('100%')
        .backgroundColor('#1FE33B3B')
        .fontColor(C_RED)
        .onClick(() => {
          this.confirmClearCache();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          this.sectionTitle('服务器')
          this.serverCard()
          HintText({ text: '填 WebDAV 目录的完整地址（Nextcloud 通常是 '
            + 'https://你的域名/remote.php/dav/files/用户名/音乐目录）。'
            + '「测试连接并扫描」连上之后会把该目录（含子目录）里的音乐扫出来，直接就能播。' })

          this.actionCard()

          this.sectionTitle('扫描')
          Column() {
            Column({ space: 17 }) {
              ToggleSetting({
                label: '读取云端标签',
                value: this.readTags,
                onPick: (next: boolean) => {
                  WebDavSettings.getInstance().setReadTags(next);
                },
              })
              HintText({ text: '开启后，扫描时会逐首读取服务器上文件里的标签（歌名 / 歌手 / 专辑 / 时长），'
                + '匹配封面和歌词会准很多，代价是每首发一次请求，几十首的目录会明显慢一点。'
                + '关掉就用文件名猜（「歌手 - 歌名」这种命名能猜对），播放时照样能听。' })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 17, bottom: 17 })
          }
          .width('100%')
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          this.sectionTitle('曲库与缓存')
          this.libraryCard()
          HintText({ text: '曲库就是「上次扫描的结果」这份缓存：服务器上的文件不归这个应用管，'
            + '要拿掉什么直接在服务器上删、然后重新扫描。'
            + '云端音乐不参与洛雪同步（与本地音乐一致：同步只传在线歌曲）；'
            + '歌单与收藏里的云端歌存在「非同步侧表」里，上行时不会发出去。' })

          Column().height(this.bottomInset + 20).width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
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
