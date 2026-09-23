import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_ICON_GREEN, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB, R_CARD } from '../ui/Theme';
import { I_CLOSE, I_PLUS, I_REFRESH, I_TRASH, IconGlyph } from '../ui/Icons';
import { RoundIconButton } from '../ui/Widgets';
import { LibrarySummary } from '../core/sync/LocalLibrary';
import { K_SYNC_DATA_VERSION, K_SYNC_ENABLE, K_SYNC_MESSAGE, K_SYNC_PROGRESS, K_SYNC_STAGE,
  K_SYNC_STATUS, SyncManager } from '../core/sync/SyncManager';
import { SYNC_CODE_AUTH_FAILED, SYNC_CODE_MISSING_AUTH_CODE } from '../core/sync/SyncTypes';
import { describeStatus } from '../core/sync/SyncStatusText';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';

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
  @StorageLink(K_SYNC_ENABLE) @Watch('onSyncStateChanged') enable: boolean = false;
  @StorageLink(K_SYNC_STATUS) @Watch('onSyncStateChanged') connected: boolean = false;
  @StorageLink(K_SYNC_MESSAGE) @Watch('onSyncStateChanged') statusMessage: string = '';
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('onSyncStateChanged') dataVersion: number = 0;
  @StorageLink(K_SYNC_PROGRESS) @Watch('onSyncStateChanged') progress: number = 0;
  @StorageLink(K_SYNC_STAGE) @Watch('onSyncStateChanged') stage: string = '';

  aboutToAppear(): void {
    const manager = SyncManager.getInstance();
    const config = manager.getConfig();
    this.host = config.host;
    this.deviceName = manager.deviceName();
    this.hostHistory = manager.hostHistory();
    this.refresh();
  }

  onSyncStateChanged(): void {
    this.refresh();
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
      const message: string = (e as Error).message;
      this.statusText = message.length > 0 ? message : '连接失败';
      if (message === SYNC_CODE_AUTH_FAILED || message === SYNC_CODE_MISSING_AUTH_CODE) {
        this.statusText = '认证失败：请在下面填入服务端配置的认证码后点「连接」';
      }
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
      this.statusText = `认证失败：${(e as Error).message}`;
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
      this.statusText = `连接失败：${(e as Error).message}`;
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
            .fontColor(this.connected ? C_ICON_GREEN : C_TEXT_WEAK)
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
          .enabled(!this.enable && !this.busy)
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
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 连接 / 同步进度：开着同步就显示，同步完成停在 100% */
  @Builder
  progressCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.stage.length > 0 ? this.stage : (this.connected ? '已连接，等待变化' : '未连接'))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        if (this.progress > 0) {
          Text(`${this.progress}%`)
            .fontSize(F_SUB)
            .fontColor(this.progress >= 100 ? C_ICON_GREEN : C_RED)
        }
      }
      .width('100%')

      Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .color(this.progress >= 100 ? C_ICON_GREEN : C_RED)
        .backgroundColor(C_FILL_SOFT)
        .style({ strokeWidth: 6 })
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

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')
          this.infoCard()

          if (this.enable) {
            this.progressCard()
          }

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
          .width('100%')

          if (this.hostHistory.length > 0) {
            this.hostHistoryCard()
          }

          this.dislikeCard()

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
