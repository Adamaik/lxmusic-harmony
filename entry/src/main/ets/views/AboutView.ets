import { bundleManager, common, Want } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { C_BG, C_CARD, C_DIVIDER, C_ICON_BLUE, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB,
  R_CARD } from '../ui/Theme';
import { HintText } from '../ui/SettingWidgets';
import { I_CHECK_CIRCLE, I_COPY, I_EXTERNAL, I_GROUP, IconGlyph } from '../ui/Icons';

const DOMAIN: number = 0x0001;
const TAG: string = 'AboutView';

/** 项目主页（点开交给系统浏览器；地址按用户给的原样展示，带 .git 也能正常打开） */
const REPO_URL: string = 'https://github.com/Adamaik/lxmusic-harmony.git';
const AUTHOR: string = 'adamaik';
/** 协议名按官方写法给出，中文说明里再说一次「阿帕奇 2.0」 */
const LICENSE: string = 'Apache License 2.0';
const QQ_GROUP: string = '985841125';
/** 「已复制」这种临时反馈停留多久（毫秒） */
const COPIED_HINT_MS: number = 1800;

/**
 * 版本号取自安装包信息
 *
 * 不写死在界面里：`AppScope/app.json5` 的 versionName 一改这里跟着变，
 * 免得出现「界面写着 1.0.0、装的是 1.1.0」这种对不上的情况。
 */
function readVersionName(): string {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.versionName;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'read version failed: %{public}s', (e as BusinessError).message);
    return '';
  }
}

/**
 * 关于（设置 - 关于）
 *
 * 三块：应用本身（图标 / 名称 / 版本）、关于软件（作者 / 协议 / 仓库地址）、
 * 以及反馈渠道（作者与用户群）。能点的都做成可点的：仓库地址交给系统浏览器打开，
 * 群号点一下就复制 —— 这类信息最常被用到的动作就是「复制走」。
 */
@Component
export struct AboutView {
  @Prop bottomInset: number = 0;
  @State version: string = '';
  /** 群号刚复制过（给一个短暂的「已复制」反馈） */
  @State copied: boolean = false;
  private copiedTimer: number = 0;

  aboutToAppear(): void {
    this.version = readVersionName();
  }

  aboutToDisappear(): void {
    if (this.copiedTimer !== 0) {
      clearTimeout(this.copiedTimer);
      this.copiedTimer = 0;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 打开项目主页
   *
   * 这里**不用** `UIAbilityContext.openLink()`：那个接口要求应用在 module.json5 里
   * 声明并校验过域名归属（域名没验证过会报 16000019「没有匹配的应用」），
   * 传一个任意 https 地址是打不开的。用一个「浏览网页」的隐式 Want 让系统去挑浏览器，
   * 是通用且稳定的做法。
   *
   * 失败不静默：把地址原样弹出来，用户至少能自己复制去搜。
   */
  private openRepo(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: REPO_URL,
    };
    context.startAbility(want).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'open repo failed: %{public}s', err.message);
      this.toast(`没能打开浏览器，地址是：${REPO_URL}`);
    });
  }

  /** 复制群号（复制失败也要让群号看得见，所以失败时把群号弹出来） */
  private copyGroup(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, QQ_GROUP);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copied = true;
        this.toast(`群号已复制：${QQ_GROUP}`);
        if (this.copiedTimer !== 0) {
          clearTimeout(this.copiedTimer);
        }
        this.copiedTimer = setTimeout(() => {
          this.copied = false;
          this.copiedTimer = 0;
        }, COPIED_HINT_MS);
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'copy group failed: %{public}s', err.message);
        this.toast(`群号：${QQ_GROUP}`);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'copy group threw: %{public}s', (e as BusinessError).message);
      this.toast(`群号：${QQ_GROUP}`);
    }
  }

  /** 应用卡片：图标 + 名称 + 版本与一句话说明 */
  @Builder
  appCard() {
    Row({ space: 15 }) {
      Image($r('app.media.startIcon'))
        .width(62)
        .height(62)
        .borderRadius(15)
        .draggable(false)

      Column({ space: 6 }) {
        Text('聆听')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.version.length > 0
          ? `v${this.version} · 洛雪音乐（LX Music）的鸿蒙移植版`
          : '洛雪音乐（LX Music）的鸿蒙移植版')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(2)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 20, bottom: 20 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  /** 键值一行（作者 / 开源协议） */
  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(F_ITEM)
        .fontColor(C_TEXT)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      Text(value)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(56)
    .padding({ left: 18, right: 18 })
  }

  /** 项目主页：上面一行小字标签，下面是完整地址（点开浏览器） */
  @Builder
  repoRow() {
    Column({ space: 5 }) {
      Text('项目主页')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .textAlign(TextAlign.Start)
      Row({ space: 6 }) {
        Text(REPO_URL)
          .fontSize(13.5)
          .fontColor(C_ICON_BLUE)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
        IconGlyph({ symbol: I_EXTERNAL, iconSize: 15, color: C_ICON_BLUE })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 18, right: 16, top: 14, bottom: 15 })
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor('#14404044') },
    })
    .onClick(() => {
      this.openRepo();
    })
    .accessibilityText(`打开项目主页 ${REPO_URL}`)
    .accessibilityLevel('yes')
  }

  @Builder
  aboutCard() {
    Column() {
      this.infoRow('作者', AUTHOR)
      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 18 })
      this.infoRow('开源协议', LICENSE)
      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 18 })
      this.repoRow()
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 反馈渠道：用户群（点一下复制群号） */
  @Builder
  feedbackCard() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle().width(34).height(34).fill('#0F000000')
        IconGlyph({ symbol: I_GROUP, iconSize: 19, color: C_TEXT })
      }
      .width(34)
      .height(34)

      Column({ space: 3 }) {
        Text('聆听用户反馈 Q 群')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.copied ? '已复制到剪贴板' : '点击复制群号')
          .fontSize(11.5)
          .fontColor(this.copied ? C_RED : C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(QQ_GROUP)
        .fontSize(15.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)

      IconGlyph({
        symbol: this.copied ? I_CHECK_CIRCLE : I_COPY,
        iconSize: 16,
        color: this.copied ? C_RED : C_ICON_BLUE,
      })
    }
    .width('100%')
    .height(70)
    .padding({ left: 16, right: 16 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .stateStyles({
      normal: { .backgroundColor(C_CARD) },
      pressed: { .backgroundColor('#14404044') },
    })
    .onClick(() => {
      this.copyGroup();
    })
    .accessibilityText(`复制用户群号 ${QQ_GROUP}`)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          this.appCard()

          this.aboutCard()
          HintText({ text: '该软件在 GitHub 上以阿帕奇 2.0 协议开源，欢迎 Star、提 Issue 或提 PR。' })

          this.feedbackCard()
          HintText({ text: '有改进建议或者功能需求，欢迎向作者反馈：在 GitHub 仓库里提 Issue，或加入用户群聊一聊。' })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 20 })
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
