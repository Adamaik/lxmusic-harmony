import { LengthMetrics } from '@kit.ArkUI';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_ICON_GREEN, C_RED, C_RED_TINT,
  C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { HintText } from '../ui/SettingWidgets';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { K_PLATFORM_PUSH_ENABLED, PlatformPushSettings } from '../core/settings/PlatformPushSettings';
import { PlatformPush } from '../core/sync/PlatformPush';
import { wyCanWrite } from '../core/music/WyWrite';
import { txCanWrite } from '../core/music/TxWrite';

const PLATFORM_WY: string = 'wy';
const PLATFORM_TX: string = 'tx';

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 毫秒时间戳 -> 「2026-11-27 01:30」；0 / 非法 = 还没同步过 */
function formatSyncStamp(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '还没同步过';
  }
  const date: Date = new Date(ms);
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} `
    + `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

/**
 * 平台同步（实验性）
 *
 * 把本机收藏镜像到对应平台账号的收藏（网易云 / QQ 音乐）：收藏一首就推一首，
 * 取消收藏就把平台侧对应的「喜欢」也取消。走的是非官方接口，有风控风险，
 * 所以这一页的设计原则是「把风险说清楚、把控制权留给用户」：
 *   - 总开关**默认关**，开启要二次确认（发什么 / 发给谁 / 什么时候发 / 怎么停）；
 *   - 方向只有一个：本机 → 平台，**从不**把平台收藏拉回来改本机；
 *   - 推送前先查平台侧「我喜欢」，已经在平台上的歌不会再写一遍；
 *   - 只同步「收藏」这一个状态：不传播放记录、不改歌单；
 *   - 同步记录（已推送过哪些歌）只存本机，用来避免重复推送。
 *
 * 数据与编排都不在这一页：设置走 PlatformPushSettings（AppStorage + 落盘），
 * 推送走 PlatformPush.pushFavorites()（手动补推）与收藏事件（自动推送），
 * 登录态走 WyWrite / TxWrite 的 canWrite 判定。
 */
@Component
export struct PlatformSyncView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  /** 总开关（PlatformPushSettings 发布；默认 false） */
  @StorageLink(K_PLATFORM_PUSH_ENABLED) @Watch('onPushEnabledChanged') pushEnabled: boolean = false;
  /** 窗口宽度（vp）：宽屏下这几张卡并排（0 = 还没量到，按手机一列） */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  /**
   * 滑块自己的显示态
   *
   * 开启要弹二次确认：手指拨过去的那一刻先把滑块显示成「开」，确认后才真正 setEnabled；
   * 取消 / 点弹窗外 / 返回键都要拨回去（与 CacheSettingsView 的「缓存时自动下载」同一套做法）。
   */
  @State switchOn: boolean = false;
  /** 两个平台是否勾选（PlatformPushSettings 的 isSelected/setSelected 只落盘，这里镜像给界面） */
  @State wySelected: boolean = true;
  @State txSelected: boolean = true;
  /** 两个平台的登录态：未登录时即使勾选也推不成功，页面上要提前说清楚 */
  @State wyLogged: boolean = false;
  @State txLogged: boolean = false;
  /** 状态区：上次同步时间文案 / 已推送首数 / 最近失败原因 */
  @State lastSyncText: string = '还没同步过';
  @State pushedTotal: number = 0;
  /** 最近一次失败原因（网易/QQ 各一条；空串 = 没有） */
  @State lastErrorText: string = '';

  private settings(): PlatformPushSettings {
    return PlatformPushSettings.getInstance();
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** 总开关被别处（StorageLink）改动时，滑块跟着走 */
  onPushEnabledChanged(): void {
    this.switchOn = this.pushEnabled;
  }

  private refresh(): void {
    this.switchOn = this.pushEnabled;
    const store: PlatformPushSettings = this.settings();
    try {
      this.wySelected = store.isSelected(PLATFORM_WY);
      this.txSelected = store.isSelected(PLATFORM_TX);
      this.lastSyncText = formatSyncStamp(store.lastSyncAt());
      this.pushedTotal = store.pushedCount();
      this.lastErrorText = this.lastErrorLabelOf(store);
    } catch (e) {
      // 设置还没 init（正常启动时 EntryAbility 已 init）：保持默认值，页面不崩
    }
    this.refreshLogin();
  }

  private refreshLogin(): void {
    try {
      this.wyLogged = wyCanWrite();
    } catch (e) {
      this.wyLogged = false;
    }
    try {
      this.txLogged = txCanWrite();
    } catch (e) {
      this.txLogged = false;
    }
  }

  /** 最近失败原因文案（把两个平台的最近一条拼起来；排障时用户不用翻日志） */
  private lastErrorLabelOf(store: PlatformPushSettings): string {
    const parts: string[] = [];
    const wy: string = store.lastErrorOf('wy');
    if (wy.length > 0) {
      parts.push(`网易：${wy}`);
    }
    const tx: string = store.lastErrorOf('tx');
    if (tx.length > 0) {
      parts.push(`QQ：${tx}`);
    }
    return parts.join(' · ');
  }

  /** 某个平台是否勾选 / 是否已登录（@Builder 参数按值传递不单独触发刷新，行内一律按 this 现读） */
  private selectedOf(platform: string): boolean {
    return platform === PLATFORM_WY ? this.wySelected : this.txSelected;
  }

  private loggedOf(platform: string): boolean {
    return platform === PLATFORM_WY ? this.wyLogged : this.txLogged;
  }

  // ------------------------------------------------------------ 总开关（开启要二次确认）

  private onEnabledChange(on: boolean): void {
    /**
     * 程序化同步开关状态时也会走到这里（确认后 StorageLink 回写、取消后拨回都算）。
     * 这里用「与当前持久化状态一致」当作「不是用户在拨」，直接同步显示态返回，
     * 否则会出现「确认开启 → 属性回写 → 又弹一次确认」的循环。
     */
    if (on === this.pushEnabled) {
      this.switchOn = this.pushEnabled;
      return;
    }
    this.switchOn = on;
    if (!on) {
      this.disableNow();
      return;
    }
    this.confirmEnable();
  }

  private disableNow(): void {
    try {
      this.settings().setEnabled(false);
      this.switchOn = false;
      this.toast('平台同步已关闭');
    } catch (e) {
      this.toast(`关闭失败：${(e as Error).message}`);
    }
  }

  /**
   * 开启前的二次确认
   *
   * 把「发什么、发给谁、什么时候发、怎么停」四件事一次说清：开启后是**实时**同步
   * （收藏/取消收藏各发一次），不是定时任务；方向只有本机 → 平台。
   * 取消 / 点弹窗外 / 返回键都要把滑块拨回去（cancel 回调同样处理）。
   */
  private confirmEnable(): void {
    this.getUIContext().showAlertDialog({
      title: '开启平台同步（实验性）',
      message: '开启后会自动同步：你每收藏一首歌，就把它的「喜欢」写进对应平台账号'
        + '（网易云 / QQ 音乐）；取消收藏时，也会把平台上的「喜欢」取消。\n\n'
        + '· 发什么：只同步「收藏」这一个状态，不传播放记录、不改歌单、不动其它设置；\n'
        + '· 方向：只有本机 → 平台，平台上的收藏不会被拉回本机；\n'
        + '· 不重复写：推送前先查平台侧已有收藏，已经在平台上的歌不再写一遍；\n'
        + '· 频率：只在收藏 / 取消收藏时实时发，没有定时任务，也没有手动补推；\n'
        + '· 停止：关掉本开关即可，之后不再发任何请求；\n'
        + '· 风险：走的是非官方接口，可能触发平台风控，甚至导致账号受限，请自行判断是否开启。',
      autoCancel: true,
      buttons: [
        {
          value: '取消',
          action: () => {
            this.switchOn = false;
          },
        },
        {
          value: '同意并开启',
          fontColor: C_RED,
          action: () => {
            try {
              this.settings().setEnabled(true);
              this.switchOn = true;
              this.toast('平台同步已开启：之后新收藏会自动写入两个平台');
            } catch (e) {
              this.switchOn = false;
              this.toast(`开启失败：${(e as Error).message}`);
            }
          },
        },
      ],
      // 点弹窗外 / 按返回键也算取消，同样把滑块拨回去
      cancel: () => {
        this.switchOn = false;
      },
    });
  }

  // ------------------------------------------------------------ 平台勾选

  private onPlatformPick(platform: string, on: boolean): void {
    if (platform === PLATFORM_WY) {
      this.wySelected = on;
    } else {
      this.txSelected = on;
    }
    try {
      this.settings().setSelected(platform, on);
    } catch (e) {
      this.toast(`保存平台勾选失败：${(e as Error).message}`);
    }
  }

  // ------------------------------------------------------------ 清除记录

  /**
   * 停止并清除同步记录
   *
   * 关掉总开关（「停止」自动同步）并清掉本机「已推送过哪些歌」的记录；
   * 平台上已经写进去的收藏**不会**被删除（只有「取消收藏」这一个动作会删平台收藏）。
   */
  private confirmClearLedger(): void {
    this.getUIContext().showAlertDialog({
      title: '停止并清除同步记录',
      message: '会关掉总开关（之后收藏 / 取消收藏都不再同步），并清空本机记录的「已推送过哪些歌」；'
        + '下次再开启后，收藏里的歌会重新尝试推送。\n\n'
        + '平台上已经写进去的收藏不会被删除 —— 只有你取消收藏某首歌时，才会去取消平台上的喜欢。',
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '停止并清除',
          fontColor: C_RED,
          action: () => {
            try {
              // 账本由 PlatformPushSettings 管（PlatformPush.clearLedger 只是它的转发），
              // 这里直接清账本，再关总开关 = 「停止并清除」
              this.settings().clearLedger();
              this.settings().setEnabled(false);
              this.switchOn = false;
              this.refresh();
              this.toast('已停止同步并清除本机推送记录（平台上的收藏保留）');
            } catch (e) {
              this.toast(`清除失败：${(e as Error).message}`);
            }
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ UI

  /** 顶部风险说明：实验性 / 非官方接口 / 风控 / 只同步收藏 */
  @Builder
  riskCard() {
    Column({ space: 8 }) {
      Text('实验性功能 · 请先读这段')
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_RED)
        .width('100%')
        .textAlign(TextAlign.Start)
      Text('这是实验性功能：通过非官方接口，把「收藏」写入你的平台账号（网易云 / QQ 音乐）。'
        + '非官方接口可能触发平台风控，甚至导致账号受限 —— 请自行判断是否开启。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .lineHeight(19)
        .width('100%')
        .textAlign(TextAlign.Start)
      Text('只同步「收藏」这一个状态：不传播放记录、不改你的歌单、不碰其它任何设置。'
        + '收藏一首就推一首，取消收藏会把平台侧对应的「喜欢」一起取消。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .lineHeight(19)
        .width('100%')
        .textAlign(TextAlign.Start)
      Text('方向只有「本机 → 平台」：平台上的收藏不会被拉回本机，也不会改动本机收藏。'
        + '推送前会先查平台侧已有的收藏，已经在平台上的歌不会重复写。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .lineHeight(19)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_RED_TINT)
  }

  /** 总开关卡 */
  @Builder
  switchCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('同步收藏到平台账号')
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.pushEnabled
            ? '已开启：收藏 / 取消收藏会实时同步到勾选平台'
            : '默认关闭；开启前会先让你确认一次（发什么 / 发给谁 / 怎么停）')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.switchOn })
          .selectedColor(C_RED)
          .onChange((isOn: boolean) => {
            this.onEnabledChange(isOn);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  /** 一个平台：名字 + 登录态 + 勾选开关（状态都用 this 现读，见 selectedOf / loggedOf） */
  @Builder
  platformRow(platform: string, label: string) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(label)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
          Text(this.loggedOf(platform) ? '已登录' : '未登录')
            .fontSize(10.5)
            .fontColor(this.loggedOf(platform) ? C_ICON_GREEN : C_RED)
            .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
            .borderRadius(8)
            .backgroundColor(this.loggedOf(platform) ? C_FILL_SOFT : C_RED_TINT)
        }
        Text(this.loggedOf(platform)
          ? '收藏 / 取消收藏会同步到这个账号（先查已收藏，不重复写）'
          : '请先到「设置 - 登录音乐」登录这个平台；未登录时勾选也推不成功')
          .fontSize(11.5)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.selectedOf(platform) })
        .selectedColor(C_RED)
        .onChange((isOn: boolean) => {
          this.onPlatformPick(platform, isOn);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  /** 平台勾选卡 + 未登录提示 */
  @Builder
  platformCard() {
    Column() {
      this.platformRow(PLATFORM_WY, '网易云音乐')
      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })
      this.platformRow(PLATFORM_TX, 'QQ 音乐')
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 同步状态 + 清除记录（没有手动补推：只随收藏动作自动同步） */
  @Builder
  runCard() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('同步状态')
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.pushEnabled
            ? '自动同步中：新收藏会同时写进两个平台，取消收藏也会同步取消'
            : '总开关关着，先在左边打开才会同步')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider().strokeWidth(0.6).color(C_DIVIDER)
      Row({ space: 8 }) {
        Text('上次同步')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Blank()
        Text(this.lastSyncText)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('已推送')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Blank()
        Text(`${this.pushedTotal} 首`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
      }
      .width('100%')

      // 最近失败原因：风控 / 登录失效都直接写出来，用户不用去翻日志
      if (this.lastErrorText.length > 0) {
        Column({ space: 4 }) {
          Text('最近失败')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.lastErrorText)
            .fontSize(11.5)
            .fontColor(C_RED)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
      }

      Divider().strokeWidth(0.6).color(C_DIVIDER)

      // 危险操作：停止同步 + 清本机记录（不动平台上的收藏）
      Text('停止并清除同步记录')
        .fontSize(F_SUB)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_RED)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ top: 2 })
        .accessibilityText('停止平台同步并清除本机同步记录')
        .onClick(() => {
          this.confirmClearLedger();
        })
      Text('只清本机「已推送过哪些歌」的记录并关闭总开关；平台上已写入的收藏不会删。')
        .fontSize(11.5)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  build() {
    Column() {
      Scroll() {
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 卡片高度差得远（风险说明 vs 两行开关），居中的话短卡会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走
          Column().height(this.topInset + 6).width('100%')

          // 风险说明：整行铺满，进页面第一眼就该看到
          this.riskCard()

          // 总开关 + 平台勾选
          Column({ space: 14 }) {
            this.switchCard()
            this.platformCard()
            HintText({
              text: '未登录的平台请先到「设置 - 登录音乐」登录；'
                + '登录状态在这一页只做展示，未登录时同步会在结果里报失败。',
            })
          }
          .width(cardWidthOf(this.windowWidth))

          // 状态 + 清除记录
          Column({ space: 14 }) {
            this.runCard()
            HintText({
              text: '推送记录只保存在本机（每个平台只存歌曲 id，不存歌名），用来避免同一首反复写；'
                + '清除后下次会重新尝试。开启总开关后，收藏 / 取消收藏会随动作实时同步。',
            })
          }
          .width(cardWidthOf(this.windowWidth))
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
