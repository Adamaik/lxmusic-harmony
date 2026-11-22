import { LengthMetrics } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT_STRONG, C_ON_ACCENT, C_RED, C_TEXT, C_TEXT_SUB,
  C_TEXT_WEAK, F_ITEM, F_SUB, R_CARD, platformColor, platformTint } from '../ui/Theme';
import { cardWidthOf, cardColumnsFor, K_WINDOW_WIDTH } from '../ui/Layout';
import { IconGlyph, I_PERSON } from '../ui/Icons';
import { BookLoginWeb, DESKTOP_UA } from '../components/BookLoginWeb';
import { K_MUSIC_LOGGED_TX, K_MUSIC_LOGGED_WY, K_MUSIC_NICK_TX, K_MUSIC_NICK_WY,
  K_MUSIC_VIP_TX, K_MUSIC_VIP_WY, MusicProfile, musicAccount } from '../core/music/MusicAccount';

/** 网易云的登录页（网页端；扫码 / 短信 / 账号密码都在这一页里，应用内浏览器照着走一遍即可） */
const WY_LOGIN_URL: string = 'https://music.163.com/#/login';
/** 网易云站址：登录后常跳到主站，抓 Cookie 时也扫一遍这里 */
const WY_SITE_URL: string = 'https://music.163.com';
/** QQ 音乐：主站右上角「登录」弹的官方登录页（QQ / 微信扫码都在里面） */
const TX_LOGIN_URL: string = 'https://y.qq.com/';
const TX_SITE_URL: string = 'https://y.qq.com';

/**
 * 设置 - 登录音乐
 *
 * **为什么要有这一页**：网易把母带 / 沉浸声 / 杜比全景声（接口里的 `jymaster` / `sky` /
 * `dolby`）算成**账号权益档**，匿名请求里根本不会上报（详见 core/music/MusicAccount.ets
 * 顶部那段排查结论）。所以这一页的职责只有两件：让用户把网页登录态抓回来存好，
 * 以及把「登录到底解锁了什么、没解锁什么」说清楚 —— 后者比前者更容易让人误解成
 * 「登录了就一定有母带」。
 *
 * 登录态不另存一份：页面用 @StorageLink 订阅 MusicAccount 写进 AppStorage 的三个 key，
 * 登录 / 退出后立刻刷新，重进页面也是真实状态。
 *
 * 接了两个平台：网易（`wy`）走网页登录抓 `MUSIC_U`；QQ 音乐（`tx`）抓 `qm_keyst`。
 * 酷狗先占位，等核心层按同一形状加平台键再接。
 */
@Component
export struct MusicLoginView {
  /** 内容让出标题栏那一段（壳层传来「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /** 整屏覆盖层（应用内浏览器）不经过标题栏，顶 / 底安全区要由它自己避让 */
  @Prop safeTop: number = 0;
  @Prop safeBottom: number = 0;
  /** 是否已登录（MusicAccount 落盘后写进 AppStorage，这里订阅） */
  @StorageLink(K_MUSIC_LOGGED_WY) loggedIn: boolean = false;
  @StorageLink(K_MUSIC_NICK_WY) nickname: string = '';
  @StorageLink(K_MUSIC_VIP_WY) vip: string = '';
  /** QQ 音乐登录态（同一套形状） */
  @StorageLink(K_MUSIC_LOGGED_TX) loggedInTx: boolean = false;
  @StorageLink(K_MUSIC_NICK_TX) nicknameTx: string = '';
  @StorageLink(K_MUSIC_VIP_TX) vipTx: string = '';
  /** 应用内浏览器是否打开（bindContentCover 的开关） */
  @State webOpen: boolean = false;
  /** 这次网页登录是给哪个平台（'wy' / 'tx'）：决定浏览器打开哪个登录页 */
  @State loginSource: string = 'wy';
  /** 登录 / 退出进行中：按钮禁用并显示「处理中…」，避免连点重复请求 */
  @State busy: boolean = false;
  /** 窗口宽度（vp）：宽屏下两张卡并排，与其它设置页同一套排布（0 = 还没量到，按手机一列） */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  aboutToAppear(): void {
    // EntryAbility 里已经 init 过；这里再调一次是保险：页面若被单独打开也不会读到空登录态
    musicAccount().init(this.getUIContext().getHostContext() as common.Context);
  }

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 网易云这一行的状态文案
   *
   * 昵称 / 会员档可能拉不到（账号信息接口偶尔抽风，不影响登录态本身），
   * 这时明确写「未知」，不把「没查到」说成「不是会员」。
   */
  private wyStatus(): string {
    if (!this.loggedIn) {
      return '未登录：登录后网易才会返回母带等权益音质';
    }
    const name: string = this.nickname.length > 0 ? this.nickname : '没取到昵称';
    const vip: string = this.vip.length > 0 ? this.vip : '会员档未知';
    return `已登录：${name} · ${vip}`;
  }

  /** QQ 音乐这一行的状态文案：登录后能用平台的私人推荐（每日 30 首 / 私人雷达 / 猜你喜欢） */
  private txStatus(): string {
    if (!this.loggedInTx) {
      return '未登录：登录后可用 QQ 音乐的私人推荐（每日推荐 / 私人雷达 / 猜你喜欢）';
    }
    const name: string = this.nicknameTx.length > 0 ? this.nicknameTx : '没取到昵称';
    const vip: string = this.vipTx.length > 0 ? this.vipTx : '会员档未知';
    return `已登录：${name} · ${vip}`;
  }

  /** 打开应用内浏览器：把站点自己的登录页装进来，扫码 / 短信 / 跳转都能走 */
  private openWebLogin(source: string): void {
    if (this.busy) {
      return;
    }
    this.loginSource = source;
    this.webOpen = true;
  }

  /**
   * 网页登录关闭
   *
   * Cookie 为空 = 用户点了取消 / 还没登完就退出，只提示、不改登录态；
   * 非空则交给 MusicAccount 校验（里面会查 `MUSIC_U`，拿不到就抛中文错误）。
   */
  private onWebLoginClosed(cookie: string): void {
    this.webOpen = false;
    const text: string = cookie !== undefined && cookie !== null ? cookie.trim() : '';
    if (text.length === 0) {
      this.toast('没抓到 Cookie，可能还没登录成功');
      return;
    }
    void this.finishLogin(text);
  }

  /** 校验并落盘登录态；成功 / 失败都给出明确 toast，不让按钮点完没反应 */
  private async finishLogin(rawCookie: string): Promise<void> {
    this.busy = true;
    const source: string = this.loginSource;
    const label: string = source === 'tx' ? 'QQ 音乐' : '网易云音乐';
    try {
      const profile: MusicProfile = await musicAccount().login(source, rawCookie);
      if (profile.nickname.length > 0) {
        const vip: string = profile.vip.length > 0 ? profile.vip : '会员档未知';
        this.toast(`已登录${label}：${profile.nickname}（${vip}）`);
      } else {
        // 账号信息没拉到不影响「已登录」：音质协商 / 私人推荐照样带 Cookie 去问
        this.toast(`已登录${label}（账号信息没拉到，不影响使用）`);
      }
    } catch (e) {
      this.toast(`登录失败：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  /** 退出先问一声：退出会让母带这类权益档退回普通档，属于用户能感知的变化 */
  private confirmLogout(source: string): void {
    if (this.busy) {
      return;
    }
    const isTx: boolean = source === 'tx';
    const label: string = isTx ? 'QQ 音乐' : '网易云音乐';
    const message: string = isTx
      ? '退出后请求不再带你的 QQ 音乐登录态：私人推荐（每日推荐 / 私人雷达 / 猜你喜欢）会不可用；'
        + '搜索、歌单、榜单、播放这些公开接口照旧能用。随时可以再登回来。'
      : '退出后请求不再带你的登录态，母带 / 沉浸声 / 杜比这类账号权益档会跟着消失；'
        + '搜索、歌单、榜单这些公开接口照旧能用。随时可以再登回来。';
    this.getUIContext().showAlertDialog({
      title: `退出${label}登录？`,
      message: message,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '退出',
          fontColor: C_RED,
          action: () => {
            this.busy = true;
            musicAccount().logout(source);
            this.busy = false;
            this.toast(isTx ? '已退出 QQ 音乐登录，私人推荐会不可用' : '已退出网易云音乐登录，权益音质会退回普通档');
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 界面片段

  /** 一个平台账号行：状态两行 + 右侧登录 / 退出按钮（网易云与 QQ 音乐共用） */
  @Builder
  accountRow(source: string, name: string, status: string, logged: boolean) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(platformTint(source))
        IconGlyph({ symbol: I_PERSON, iconSize: 22, color: platformColor(source) })
      }
      .width(40)
      .height(40)

      Column({ space: 4 }) {
        Text(name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
        Text(status)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(this.busy ? '处理中…' : (logged ? '退出登录' : '登录'))
        .fontSize(13)
        .height(30)
        .padding({ left: 14, right: 14 })
        // 已登录是「撤销一个已生效的状态」，弱化成次要文字色；未登录才是要用户动手的主按钮
        .fontColor(logged ? C_TEXT_SUB : C_ON_ACCENT)
        .backgroundColor(logged ? C_FILL_SOFT_STRONG : C_RED)
        .enabled(!this.busy)
        .opacity(this.busy ? 0.6 : 1)
        .onClick(() => {
          if (logged) {
            this.confirmLogout(source);
          } else {
            this.openWebLogin(source);
          }
        })
        .accessibilityText(logged ? `退出${name}登录` : `登录${name}`)
        .accessibilityLevel('yes')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  /** 还没接的平台：整行置灰、不给点击，右侧只说明「敬请期待」 */
  @Builder
  pendingRow(name: string, source: string) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(platformTint(source))
        IconGlyph({ symbol: I_PERSON, iconSize: 22, color: C_TEXT_WEAK })
      }
      .width(40)
      .height(40)

      Column({ space: 4 }) {
        Text(name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
        Text('账号体系还没接，先不占坑')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('敬请期待')
        .fontSize(12)
        .fontColor(C_TEXT_WEAK)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor(C_FILL_SOFT_STRONG)
        .borderRadius(13)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .opacity(0.65)
  }

  /**
   * 网页登录整屏覆盖层
   *
   * 用 `bindContentCover` 而不是半模态：登录页要占满屏、能滚动、还要弹系统键盘。
   * 关掉时把抓到的 Cookie 串交回来（可能为空串），由 onWebLoginClosed 判断是取消还是登录。
   *
   * 两个平台的登录页都用桌面 UA 打开（`DESKTOP_UA`）：WebView 默认带移动 UA，站点会把
   * 请求判成手机端、302 到手机版页面 —— QQ 音乐那个手机版页面
   * （`i2.y.qq.com/n3/other/pages/myqq/index.html`）整页只有一个「下载APP」，没有登录入口；
   * 网易云的移动 UA 页面同样是「打开 App」的引导，扫码 / 短信登录都进不去。
   * 换桌面 UA 后 y.qq.com 返回的是右上角带「登录」的 PC 版首页（点进去是官方扫码 / 账号登录），
   * 网易云返回的是带扫码 / 短信登录的 PC 版页面。
   */
  @Builder
  loginWebCover() {
    BookLoginWeb({
      title: this.loginSource === 'tx' ? 'QQ 音乐' : '网易云音乐',
      loginUrl: this.loginSource === 'tx' ? TX_LOGIN_URL : WY_LOGIN_URL,
      siteUrl: this.loginSource === 'tx' ? TX_SITE_URL : WY_SITE_URL,
      // 桌面 UA：不传的话 WebView 用默认移动 UA，站点会把请求判成手机端、跳到没有登录入口的手机版页面
      userAgent: DESKTOP_UA,
      // 自动点开「登录」：y.qq.com 顶部那个「登录」没有 href，点击靠页面 JS 开弹窗，
      // ArkWeb 默认把 window.open 拦掉 → 点了没反应。开启后由组件注入脚本替用户点，并把弹窗装回本 WebView
      autoLogin: true,
      safeTop: this.safeTop,
      safeBottom: this.safeBottom,
      onClose: (cookie: string) => {
        this.onWebLoginClosed(cookie);
      },
    })
  }

  build() {
    Column() {
      Scroll() {
        /**
         * 与其它设置页同一套骨架：顶部占位 + 卡片；宽屏两张卡并排、窄屏一列。
         * 每张「卡 + 它下面那行说明」包成一个 Column 当一个单元，并排时不会互相插队。
         */
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，跟着内容一起滚走（用容器内边距会像被顶栏挡住）
          Column().height(this.topInset + 6).width('100%')

          // ------------------------------------------------ 说明卡：登录到底解锁什么
          Column({ space: 14 }) {
            Column({ space: 10 }) {
              Text('登录能解锁什么')
                .fontSize(F_ITEM)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_TEXT)
                .width('100%')
                .textAlign(TextAlign.Start)

              Text('网易把母带、沉浸声、杜比全景声（接口里的 jymaster / sky / dolby）当成账号权益：'
                + '不登录时接口压根不会报这几档，最高只到 FLAC 那类无损。'
                + '登录后请求会带上你的账号，网易才愿意把它们一起报出来 —— '
                + '之前「开了拓展音质还是只有 FLAC」，根子就在这儿。')
                .fontSize(F_SUB)
                .fontColor(C_TEXT_SUB)
                .lineHeight(19)
                .width('100%')
                .textAlign(TextAlign.Start)

              Text('但报出来不等于一定放得动：这首歌的音源自己没声明支持这一档，或者账号没有对应权益，'
                + '播放时还是会自动退回低一档。登录解决的是「平台愿不愿意给」，'
                + '歌本身有没有这一档，得看音源。')
                .fontSize(F_SUB)
                .fontColor(C_TEXT_SUB)
                .lineHeight(19)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            Text('只保存网页登录抓回来的 Cookie（相当于本机的一张登录凭证），不保存账号密码，'
              + '也不会发到别处；不想用了点「退出登录」就清掉。')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
              .width('100%')
              .padding({ left: 4, right: 4 })
              .textAlign(TextAlign.Start)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 平台列表
          Column({ space: 14 }) {
            Column() {
              this.accountRow('wy', '网易云音乐', this.wyStatus(), this.loggedIn)

              Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

              this.accountRow('tx', 'QQ 音乐', this.txStatus(), this.loggedInTx)

              Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

              this.pendingRow('酷狗音乐', 'kg')
            }
            .width('100%')
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
            .clip(true)

            Text('网易云登录主要是为了母带 / 沉浸声 / 杜比这类账号权益档；'
              + 'QQ 音乐登录是为了平台的私人推荐（每日推荐 / 私人雷达 / 猜你喜欢）与账号歌单。'
              + '两者互不影响，可以只登其中一个。')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
              .width('100%')
              .padding({ left: 4, right: 4 })
              .textAlign(TextAlign.Start)
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
    // 网页登录挂在页面根节点上：覆盖层铺满窗口，不经过标题栏（safeTop / safeBottom 已交给 BookLoginWeb）
    .bindContentCover($$this.webOpen, this.loginWebCover(), {
      modalTransition: ModalTransition.NONE,
    })
  }
}
