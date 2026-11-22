import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_ICON_GREEN, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB, R_CARD } from '../ui/Theme';
import { I_CLOSE, I_PLUS, I_REFRESH, I_TRASH, IconGlyph } from '../ui/Icons';
import { RoundIconButton } from '../ui/Widgets';
import { LibrarySummary } from '../core/sync/LocalLibrary';
import { K_SYNC_DATA_VERSION, K_SYNC_ENABLE, K_SYNC_MESSAGE, K_SYNC_PROGRESS, K_SYNC_STAGE,
  K_SYNC_STATUS, SyncManager } from '../core/sync/SyncManager';
import { describeStatus, isSyncFailureMessage } from '../core/sync/SyncStatusText';
import { K_WEBDAV_SYNC_AUTO, WebDavSettings } from '../core/webdav/WebDavSettings';
import { ConfigSyncFile } from '../core/webdav/WebDavConfigData';
import { ConfigSyncOutcome, ConfigSyncPreview, K_CONFIG_SYNC_NOTICE, WebDavConfigSync,
  describeStamp } from '../core/webdav/WebDavConfigSync';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';

/**
 * 同步设置
 *
 * 对应洛雪「设置 - 同步」那一页：填服务器地址、开开关、认证失败时补认证码，
 * 另外把本地参与同步的数据（试听列表 / 我的收藏 / 歌单 / 不喜欢规则）摊开，
 * 方便确认「到底同步了什么」。
 */
@Component
export struct SyncSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @State host: string = '';
  @State authCode: string = '';
  @State deviceName: string = '';
  @State statusText: string = '未连接';
  @State summaryText: string = '';
  @State busy: boolean = false;
  @State dislikeRules: string[] = [];
  /** 最近一次触摸点：删规则时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;
  @State newName: string = '';
  @State newSinger: string = '';
  @State hostHistory: string[] = [];
  // ---- 网盘同步（WebDAV）：账号与目录在这里也能填，与「云音乐」页共用同一份设置
  @State davHost: string = '';
  @State davUser: string = '';
  @State davPassword: string = '';
  /** 已保存过密码时输入框留空 = 不修改（密码不进 AppStorage，也不回显） */
  @State davPasswordSaved: boolean = false;
  @State davDir: string = '';
  @State davBusy: boolean = false;
  @State davStatus: string = '';
  /** 上次成功同步的时间（ISO；空串 = 还没同步过） */
  @State davLastSync: string = '';
  @StorageLink(K_WEBDAV_SYNC_AUTO) davAuto: boolean = false;
  @StorageLink(K_CONFIG_SYNC_NOTICE) davNotice: string = '';
  @StorageLink(K_SYNC_ENABLE) @Watch('onSyncStateChanged') enable: boolean = false;
  @StorageLink(K_SYNC_STATUS) @Watch('onSyncStateChanged') connected: boolean = false;
  @StorageLink(K_SYNC_MESSAGE) @Watch('onSyncStateChanged') statusMessage: string = '';
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('onSyncStateChanged') dataVersion: number = 0;
  @StorageLink(K_SYNC_PROGRESS) @Watch('onSyncStateChanged') progress: number = 0;
  @StorageLink(K_SYNC_STAGE) @Watch('onSyncStateChanged') stage: string = '';
  /**
   * 窗口宽度（vp）：宽屏下这几张卡并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  aboutToAppear(): void {
    const manager = SyncManager.getInstance();
    const config = manager.getConfig();
    this.host = config.host;
    this.deviceName = manager.deviceName();
    this.hostHistory = manager.hostHistory();
    this.refresh();
    this.refreshDav();
  }

  onSyncStateChanged(): void {
    this.refresh();
  }

  /** 是否处于「停下来等用户处理」的失败态（据此把进度条变红并给重试 / 断开） */
  private failed(): boolean {
    return this.enable && !this.connected && isSyncFailureMessage(this.statusMessage);
  }

  /** 进度条上方那行字：失败时显示具体原因，别让用户只看到一个百分比 */
  private progressTitle(): string {
    if (this.failed()) {
      return describeStatus(false, this.statusMessage);
    }
    if (this.stage.length > 0) {
      return this.stage;
    }
    return this.connected ? '已连接，等待变化' : '未连接';
  }

  private refresh(): void {
    const manager = SyncManager.getInstance();
    const library = manager.getLibrary();
    this.statusText = describeStatus(this.connected, this.statusMessage);
    const summary: LibrarySummary = library.summary();
    this.summaryText = `试听列表 ${library.listData().defaultList.length} 首 · ` +
      `收藏 ${library.listData().loveList.length} 首 · 歌单 ${summary.playlists} 个`;
    this.dislikeRules = library.dislikeRuleList();
    this.hostHistory = manager.hostHistory();
  }

  private async toggleSync(on: boolean): Promise<void> {
    const manager = SyncManager.getInstance();
    this.busy = true;
    try {
      if (on) {
        await manager.enable(this.host);
        this.statusText = '已开启，正在连接…';
      } else {
        await manager.disable();
        this.statusText = '已关闭同步';
      }
    } catch (e) {
      // 异常里是协议码（英文），给用户看要走 describeStatus；原文只进日志
      const message: string = (e as Error).message;
      this.statusText = describeStatus(false, message);
    } finally {
      this.busy = false;
    }
  }

  private async connectWithCode(): Promise<void> {
    const code: string = this.authCode.trim();
    if (code.length === 0) {
      this.statusText = '请先填写认证码';
      return;
    }
    const manager = SyncManager.getInstance();
    this.busy = true;
    try {
      manager.updateHost(this.host);
      await manager.connectWithCode(code);
      this.authCode = '';
    } catch (e) {
      this.statusText = describeStatus(false, (e as Error).message);
    } finally {
      this.busy = false;
    }
  }

  private async reconnect(): Promise<void> {
    const manager = SyncManager.getInstance();
    this.busy = true;
    try {
      manager.updateHost(this.host);
      await manager.reconnect();
    } catch (e) {
      this.statusText = describeStatus(false, (e as Error).message);
    } finally {
      this.busy = false;
    }
  }

  /** 失败态里的「断开同步」：关掉开关并断开，进度与错误一起清掉 */
  private async disconnectSync(): Promise<void> {
    const manager = SyncManager.getInstance();
    this.busy = true;
    try {
      await manager.disable();
      this.statusText = '已关闭同步';
    } catch (e) {
      this.statusText = `断开失败：${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private addDislikeRule(): void {
    const name: string = this.newName.trim();
    const singer: string = this.newSinger.trim();
    if (name.length === 0 && singer.length === 0) {
      return;
    }
    SyncManager.getInstance().getLibrary().addDislike(name, singer);
    this.newName = '';
    this.newSinger = '';
    this.refresh();
  }

  private removeDislikeRule(rule: string): void {
    SyncManager.getInstance().getLibrary().removeDislikeRule(rule);
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

  private clearDislikeRules(): void {
    SyncManager.getInstance().getLibrary().clearDislike();
    this.refresh();
  }

  // ------------------------------------------------------------ 网盘同步（WebDAV）

  /** 从设置单例读一遍（密码只读「有没有存过」，不回显） */
  private refreshDav(): void {
    const settings = WebDavSettings.getInstance();
    this.davHost = settings.getUrl();
    this.davUser = settings.getUsername();
    this.davPasswordSaved = settings.getPassword().length > 0;
    this.davDir = settings.getSyncDir();
    this.davLastSync = settings.getLastSyncedAt();
  }

  /**
   * 把这一段的输入存进设置
   *
   * 密码只在**这次真的填了**的时候写：输入框留空表示沿用已保存的那个，不能因为用户
   * 没重填就把密码清掉。存完把输入框清空，占位符变「已保存，留空不修改」。
   */
  private saveDavInputs(): void {
    const settings = WebDavSettings.getInstance();
    settings.setUrl(this.davHost);
    settings.setUsername(this.davUser);
    settings.setSyncDir(this.davDir);
    if (this.davPassword.length > 0) {
      settings.setPassword(this.davPassword);
      this.davPassword = '';
      this.davPasswordSaved = true;
    }
  }

  /** 测试连接：列一次根目录，再试建一次同步目录（目录不存在会自动创建） */
  private async testDav(): Promise<void> {
    if (this.davBusy) {
      return;
    }
    this.saveDavInputs();
    this.davBusy = true;
    this.davStatus = '正在连接…';
    try {
      this.davStatus = await WebDavConfigSync.getInstance().testConnection();
    } catch (e) {
      this.davStatus = `连不上：${(e as Error).message}`;
    } finally {
      this.davBusy = false;
    }
  }

  /** 手动上传：把歌单 + 播放设置写到网盘（用户明确点了，失败要给出原因） */
  private async uploadDav(): Promise<void> {
    if (this.davBusy) {
      return;
    }
    this.saveDavInputs();
    this.davBusy = true;
    this.davStatus = '正在上传配置…';
    try {
      const outcome: ConfigSyncOutcome = await WebDavConfigSync.getInstance().uploadNow();
      this.davStatus = outcome.message;
      this.davLastSync = WebDavSettings.getInstance().getLastSyncedAt();
      this.toast(outcome.ok ? '已上传到网盘' : outcome.message);
    } catch (e) {
      this.davStatus = `上传失败：${(e as Error).message}`;
    } finally {
      this.davBusy = false;
    }
  }

  /**
   * 从网盘恢复：先取回来算一份预览，弹框让用户看清再决定
   *
   * 「先预览、再确认」是这次同步的核心约定：不点「恢复」就不动本地库，也不静默双写。
   */
  private async restoreDav(): Promise<void> {
    if (this.davBusy) {
      return;
    }
    this.saveDavInputs();
    this.davBusy = true;
    this.davStatus = '正在读取网盘上的配置…';
    try {
      const preview: ConfigSyncPreview = await WebDavConfigSync.getInstance().previewRemote();
      const remoteFile: ConfigSyncFile | null = preview.file;
      if (!preview.ok || remoteFile === null) {
        this.davStatus = preview.message;
        return;
      }
      // 闭包里只用这个非空的局部量：直接捕获 remoteFile 会因为它带 null 而每处都要判一次
      const target: ConfigSyncFile = remoteFile;
      const when: string = describeStamp(preview.exportedAt);
      const newer: string = preview.newer ? '（比本机上次同步的更新）' : '';
      this.davStatus = `网盘上有一份配置：${preview.playlists} 个歌单、${preview.songs} 首歌`;
      this.getUIContext().showAlertDialog({
        title: '从网盘恢复配置',
        message: `导出时间：${when}${newer}\n\n`
          + `将导入 ${preview.playlists} 个歌单、共 ${preview.songs} 首歌曲\n`
          + `设置：${preview.settingsText}\n\n`
          + '重名歌单会加「 (2)」后缀，本机现有歌单不会被覆盖；本地音乐与云端音乐不会随配置迁移。',
        autoCancel: true,
        buttons: [
          { value: '取消', action: () => {
          } },
          {
            value: '恢复',
            fontColor: C_RED,
            action: () => {
              void this.doRestore(target);
            },
          },
        ],
      });
    } catch (e) {
      this.davStatus = `读取失败：${(e as Error).message}`;
    } finally {
      this.davBusy = false;
    }
  }

  /** 用户点了确认之后才真正合并（合并期间再挡一次重复点击） */
  private async doRestore(file: ConfigSyncFile): Promise<void> {
    if (this.davBusy) {
      return;
    }
    this.davBusy = true;
    this.davStatus = '正在恢复配置…';
    try {
      const outcome: ConfigSyncOutcome = await WebDavConfigSync.getInstance().restore(file);
      this.davStatus = outcome.message;
      this.davLastSync = WebDavSettings.getInstance().getLastSyncedAt();
      // 歌单数变了：上面那张「同步内容」的统计要跟着重读
      this.refresh();
      this.toast(outcome.ok ? '已从网盘恢复配置' : outcome.message);
    } catch (e) {
      this.davStatus = `恢复失败：${(e as Error).message}`;
    } finally {
      this.davBusy = false;
    }
  }

  /** 自动同步开关（打开后启动 / 退出各试一次，失败静默） */
  private toggleDavAuto(on: boolean): void {
    this.saveDavInputs();
    WebDavSettings.getInstance().setAutoSync(on);
    if (!on) {
      this.davStatus = '已关闭自动同步（手动上传 / 恢复仍然可用）';
    } else if (!WebDavSettings.getInstance().isConfigured()) {
      this.davStatus = '自动同步已打开，但要先填服务器地址';
    } else {
      this.davStatus = '自动同步已打开：应用启动 / 退出时各试一次';
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 没有 UI 上下文时（比如预加载）静默：状态行里已经有同样的字
    }
  }

  @Builder
  sectionCard(title: string, subtitle: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, bottom: 6 })
  }

  @Builder
  infoCard() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('启用同步')
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.statusText)
            .fontSize(F_SUB)
            .fontColor(this.failed() ? C_RED : (this.connected ? C_ICON_GREEN : C_TEXT_WEAK))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.enable })
          .selectedColor(C_RED)
          .enabled(!this.busy)
          .onChange((isOn: boolean) => {
            void this.toggleSync(isOn);
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 12 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('服务端')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.host, placeholder: 'http://192.168.1.10:9527' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          // 失败态下必须能改地址：卡住的常见原因就是 IP / 端口填错了（比如填了另一台手机），
          // 只能改地址再点「重试」，否则用户被锁在错误地址上只能先关掉同步。
          .enabled(this.failed() ? !this.busy : (!this.enable && !this.busy))
          .onChange((value: string) => {
            this.host = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('认证码')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.authCode, placeholder: '服务端配置的认证码' })
          .type(InputType.Password)
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.busy)
          .onChange((value: string) => {
            this.authCode = value;
          })
        Button('连接')
          .fontSize(F_SUB)
          .height(32)
          .backgroundColor(C_RED)
          .enabled(!this.busy)
          .onClick(() => {
            void this.connectWithCode();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('本机设备名')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.deviceName)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        RoundIconButton({ icon: I_REFRESH, boxSize: 36, iconSize: 18, label: '刷新同步状态', onTap: () => {
          void this.reconnect();
        } })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      /**
       * 「同步不是手机直连」这条必须写在界面上
       *
       * 之前只在群里解释过：用户看到「服务端」输入框，很自然会把另一台手机的 IP 填进来，
       * 然后卡在 2% 完全不知道错在哪。这句话放在地址输入框这张卡里，开同步前就能看到。
       */
      Column({ space: 4 }) {
        Text('同步需要先在一台电脑（或服务器）上运行「洛雪音乐服务端」或打开「洛雪音乐电脑端」，'
          + '把它的地址和端口填在上面的「服务端」里。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('两台手机不能直接互相同步 —— 手机上并没有同步服务端，直连是连不上的。'
          + '认证码在服务端配置里，没设置就留空。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 连接 / 同步进度：失败时整条变红、给出原因和「重试 / 断开同步」 */
  @Builder
  progressCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.progressTitle())
          .fontSize(F_SUB)
          .fontColor(this.failed() ? C_RED : C_TEXT_SUB)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        if (this.failed()) {
          Text('连接失败')
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .backgroundColor(C_RED_TINT)
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        } else if (this.progress > 0) {
          Text(`${this.progress}%`)
            .fontSize(F_SUB)
            .fontColor(this.progress >= 100 ? C_ICON_GREEN : C_RED)
        }
      }
      .width('100%')

      // 失败时把条拉满并变红：停在 2% 的一小截红条看起来像「还在慢慢连」，
      // 满格红条才是「已经停了、要你处理」的视觉信号（百分比此时不显示）
      Progress({ value: this.failed() ? 100 : this.progress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .color(this.failed() ? C_RED : (this.progress >= 100 ? C_ICON_GREEN : C_RED))
        .backgroundColor(C_FILL_SOFT)
        .style({ strokeWidth: 6 })

      if (this.failed()) {
        Row({ space: 10 }) {
          Button('重试')
            .fontSize(F_SUB)
            .height(32)
            .backgroundColor(C_RED)
            .enabled(!this.busy)
            .onClick(() => {
              void this.reconnect();
            })
          Button('断开同步')
            .fontSize(F_SUB)
            .height(32)
            .backgroundColor(C_FILL_SOFT)
            .fontColor(C_TEXT)
            .enabled(!this.busy)
            .onClick(() => {
              void this.disconnectSync();
            })
        }
        .width('100%')
      }

      if (this.failed()) {
        // 失败时再把「不是手机直连」说一遍：用户此刻最可能做的就是把另一台手机的 IP 填进来
        Text('提示：同步需要洛雪音乐服务端或洛雪音乐电脑端，两台手机不能直连。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  @Builder
  hostHistoryCard() {
    Column() {
      Text('最近使用')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 6 })
      ForEach(this.hostHistory, (item: string, index: number) => {
        Column() {
          Row({ space: 10 }) {
            Text(item)
              .fontSize(14)
              .fontColor(C_TEXT)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
            IconGlyph({ symbol: I_CLOSE, iconSize: 15, color: C_TEXT_WEAK })
          }
          .width('100%')
          .height(46)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.host = item;
            SyncManager.getInstance().updateHost(item);
          })
          if (index < this.hostHistory.length - 1) {
            Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 16 })
          }
        }
        .width('100%')
      }, (item: string) => item)
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  dislikeCard() {
    Column() {
      Row({ space: 8 }) {
        Text('不喜欢的歌曲')
          .fontSize(F_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        if (this.dislikeRules.length > 0) {
          Text(`清空`)
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .onClick(() => {
              this.clearDislikeRules();
            })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 6 })

      if (this.dislikeRules.length === 0) {
        Text('暂无规则。规则来自同步服务端，也可以在下面手动添加。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 12 })
          .textAlign(TextAlign.Start)
      } else {
        ForEach(this.dislikeRules, (rule: string, index: number) => {
          Column() {
            Row({ space: 10 }) {
              Text(describeDislikeRule(rule))
                .fontSize(14)
                .fontColor(C_TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
              IconGlyph({ symbol: I_TRASH, iconSize: 17, color: C_TEXT_WEAK })
                .onClick(() => {
                  this.removeDislikeRule(rule);
                })
                .onTouch((event: TouchEvent) => {
                  this.rememberTouch(event);
                })
            }
            .width('100%')
            .height(46)
            .padding({ left: 14, right: 14 })
            if (index < this.dislikeRules.length - 1) {
              Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })
            }
          }
          .width('100%')
        }, (rule: string, index: number) => `${index}_${rule}`)
      }

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 8 }) {
        TextInput({ text: this.newName, placeholder: '歌名' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor(C_FILL_SOFT)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.newName = value;
          })
        TextInput({ text: this.newSinger, placeholder: '歌手' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor(C_FILL_SOFT)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.newSinger = value;
          })
        IconGlyph({ symbol: I_PLUS, iconSize: 20, color: C_RED })
          .onClick(() => {
            this.addDislikeRule();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /**
   * 网盘同步（WebDAV）
   *
   * 与上面那张卡的分工：上面是洛雪服务端同步（要自己搭服务端 / 开电脑端），这张是
   * **普通用户能用的**换设备路径 —— 一个 WebDAV 网盘账号 + 一个目录就够。
   *
   * 账号直接复用「设置 - 云端音乐」那一份（WebDavSettings）：同一个人同一台网盘，
   * 没必要填两遍；这里也能改，改的是同一个落盘文件。
   */
  @Builder
  davSyncCard() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('网盘同步（WebDAV）')
            .fontSize(F_SECTION)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.davAuto ? '自动同步：启动 / 退出各试一次' : '换手机时把歌单和设置搬过去')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.davAuto })
          .selectedColor(C_RED)
          .enabled(!this.davBusy)
          .onChange((isOn: boolean) => {
            this.toggleDavAuto(isOn);
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 12 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('服务器')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.davHost, placeholder: 'https://dav.example.com/dav' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.davBusy)
          .onChange((value: string) => {
            this.davHost = value;
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
        TextInput({ text: this.davUser, placeholder: '网盘账号（可留空匿名）' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.davBusy)
          .onChange((value: string) => {
            this.davUser = value;
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
        TextInput({
          text: this.davPassword,
          placeholder: this.davPasswordSaved ? '已保存，留空不修改' : '网盘密码 / 应用专用密码',
        })
          .type(InputType.Password)
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.davBusy)
          .onChange((value: string) => {
            this.davPassword = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Text('目录')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
        TextInput({ text: this.davDir, placeholder: 'listen-config（不存在会自动创建）' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 13 })
          .fontSize(13)
          .backgroundColor('#00000000')
          .layoutWeight(1)
          .enabled(!this.davBusy)
          .onChange((value: string) => {
            this.davDir = value;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 8 }) {
        Button('测试连接')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(C_FILL_SOFT)
          .fontColor(C_TEXT)
          .enabled(!this.davBusy)
          .onClick(() => {
            void this.testDav();
          })
        Button('上传配置')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(C_RED)
          .enabled(!this.davBusy)
          .onClick(() => {
            void this.uploadDav();
          })
        Button('从网盘恢复')
          .fontSize(13)
          .height(34)
          .layoutWeight(1)
          .backgroundColor(C_FILL_SOFT)
          .fontColor(C_TEXT)
          .enabled(!this.davBusy)
          .onClick(() => {
            void this.restoreDav();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })

      if (this.davStatus.length > 0) {
        Text(this.davStatus)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 8 })
          .textAlign(TextAlign.Start)
      }

      if (this.davNotice.length > 0) {
        Column() {
          Text(this.davNotice)
            .fontSize(F_SUB)
            .fontColor(C_RED)
            .backgroundColor(C_RED_TINT)
            .borderRadius(6)
            .width('100%')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 8 })
      }

      Text(this.davLastSync.length > 0
        ? `上次同步：${describeStamp(this.davLastSync)}`
        : '还没有同步过')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 10 })
        .textAlign(TextAlign.Start)

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Column({ space: 4 }) {
        Text('不需要洛雪服务端：两台设备填同一个网盘账号（Nextcloud / Alist / 群晖 / 坚果云等'
          + '支持 WebDAV 的都行），配置文件只有几十 KB。这里填的账号与「设置 - 云端音乐」'
          + '是同一份；不点那边的「重新扫描」就不会去列你的音乐目录。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('同步内容是歌单（含曲目）与播放设置（音质 / 歌词 / 动效等）；本地音乐和云端音乐'
          + '的歌不会跟着走 —— 换设备后它们的路径不成立。收藏与试听列表仍走上面的洛雪同步。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('自动同步失败不会打扰你（下次启动再试）；网盘上有更新的配置时只提示、'
          + '不会覆盖本机，点「从网盘恢复」并确认后才写入，重名歌单加后缀。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 12 })
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  build() {
    Column() {
      Scroll() {
        /**
         * 卡片的排布用 Flex 而不是 Column：**宽屏并排、窄屏一列**
         *
         * 窄屏是 `direction: Column` + 不换行 + main 间距 14，与原来的 `Column({ space: 14 })`
         * 逐像素一样；宽屏换成 `Row` + 换行，每张卡 48% 宽（见 ui/Layout.ets 的 cardWidthOf），
         * 自动一行两张。卡下面那些说明跟它的卡包在一个 Column 里当**一个单元**：说明文字
         * 本身铺满宽度，不包起来会把换行打断，两张卡就并不到一排去。
         * 「同步中」那张与「服务端历史」那张是条件渲染，连整个单元一起判，免得宽屏下
         * 留下一格空位把后面的卡挤到下一行去。
         */
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')

          Column({ space: 14 }) {
            this.infoCard()
          }
          .width(cardWidthOf(this.windowWidth))

          if (this.enable) {
            Column({ space: 14 }) {
              this.progressCard()
            }
            .width(cardWidthOf(this.windowWidth))
          }

          // 网盘同步（WebDAV）：与洛雪服务端同步并列的第二条换设备路径
          Column({ space: 14 }) {
            this.davSyncCard()
          }
          .width(cardWidthOf(this.windowWidth))

          Column({ space: 6 }) {
            this.sectionCard('同步内容', this.summaryText)
            Text('试听列表 = 本机的播放队列；收藏与歌单会与同一服务端的其它设备（洛雪桌面端 / 移动端）互通。')
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .width('100%')
              .padding({ left: 4, right: 4 })
              .textAlign(TextAlign.Start)
            Text('注意：本地歌曲无法同步 —— 同步协议只传在线歌曲，本地音乐（从设备导入的音频）'
              + '在同步时会被直接抛弃：不会上传到服务端，也不会从其它设备同步过来'
              + '（歌单 / 收藏里的本地歌曲只留在本机，详见 docs/LOCAL_MUSIC.md）。')
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .width('100%')
              .padding({ left: 4, right: 4 })
              .textAlign(TextAlign.Start)
          }
          .width(cardWidthOf(this.windowWidth))

          if (this.hostHistory.length > 0) {
            Column({ space: 14 }) {
              this.hostHistoryCard()
            }
            .width(cardWidthOf(this.windowWidth))
          }

          Column({ space: 14 }) {
            this.dislikeCard()
          }
          .width(cardWidthOf(this.windowWidth))

          Text('协议与洛雪官方一致：/hello + /id + /ah 认证、WebSocket 长连接、'
            + '列表与「不喜欢的歌曲」两个模块，均可在设置里选择同步方式。')
            .fontSize(11.5)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: 4, right: 4 })
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 16 })
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

/** '歌名@歌手' / '歌名' / '@歌手' 的展示形式 */
function describeDislikeRule(rule: string): string {
  const at: number = rule.indexOf('@');
  if (at < 0) {
    return `歌名：${rule}`;
  }
  const name: string = rule.substring(0, at);
  const singer: string = rule.substring(at + 1);
  if (name.length === 0) {
    return `歌手：${singer}`;
  }
  if (singer.length === 0) {
    return `歌名：${name}`;
  }
  return `${name} — ${singer}`;
}
