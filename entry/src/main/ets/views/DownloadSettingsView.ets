import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HintText, OptionSetting, SegPills, SettingLabel, ToggleSetting } from '../ui/SettingWidgets';
import { DownloadManager, PickDirResult } from '../core/download/DownloadManager';
import { DownloadSettings, K_DOWNLOAD_MARK_QUALITY, K_DOWNLOAD_NAME_FORMAT, K_DOWNLOAD_SAVE_MODE,
  NAME_FORMAT_LABELS, NAME_FORMATS, SAVE_MODE_LABELS, SAVE_MODES } from '../core/download/DownloadSettings';

const SAVE_MODE_INDEX: Record<string, number> = { 'manual': 0, 'app': 1 };

/**
 * 下载设置
 *
 * 参考图上的三项：
 *   文件名称格式（歌曲名 / 艺术家-标题 / 标题-艺术家）
 *   下载文件标注音质（开/关）
 *   保存位置（手动选择 / Download目录）
 *
 * 「手动选择」调系统文件选择器挑目录，选完申请长期授权（不然重启后写不进去），
 * 并用探针文件确认可写；「Download目录」是应用内 files/Download，不需要任何权限。
 * 两者都写进 DownloadSettings（沙箱 JSON + AppStorage），重启不丢。
 */
@Component
export struct DownloadSettingsView {
  @Prop bottomInset: number = 0;
  @StorageLink(K_DOWNLOAD_NAME_FORMAT) nameFormat: string = 'song';
  @StorageLink(K_DOWNLOAD_MARK_QUALITY) markQuality: boolean = true;
  @StorageLink(K_DOWNLOAD_SAVE_MODE) saveMode: string = 'app';
  @State picking: boolean = false;
  /** 最近一次选目录的逐步结果（写不进去时显示在页面上） */
  @State pickDetail: string = '';

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private formatIndex(): number {
    const index: number = NAME_FORMATS.indexOf(this.nameFormat);
    return index < 0 ? 0 : index;
  }

  private saveModeIndex(): number {
    const index: number = SAVE_MODE_INDEX[this.saveMode];
    return index === undefined ? 1 : index;
  }

  /**
   * 切换保存位置
   *
   * 手动选择：真的去选一个目录（文件选择器的文件夹模式），选完把授权持久化，
   * 之后每首歌直接往这个目录写、不再询问。任何一步失败都如实报出来（带系统错误码），
   * 不切模式、也不偷偷换地方写。
   */
  private async pickMode(mode: string): Promise<void> {
    if (mode === 'app') {
      DownloadManager.getInstance().useAppDir();
      this.toast('已改为保存到系统的 Download 目录');
      return;
    }
    if (this.picking) {
      return;
    }
    this.picking = true;
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      const result: PickDirResult = await DownloadManager.getInstance().pickSaveDir(context);
      this.pickDetail = result.detail;
      if (result.cancel) {
        this.toast('没有选择目录，保存位置保持不变');
      } else if (result.usable) {
        this.toast(`下载目录已设为「${result.label}」，之后每首会定位到这个目录保存`);
      } else {
        // 目录记下了但写不进去：把每一步的结果摊开，便于定位是授权还是写入的问题
        this.toast(`已选「${result.label}」，但写不进去：${result.detail}`);
      }
    } catch (e) {
      this.toast(`选择目录失败：${(e as BusinessError).message}`);
    } finally {
      this.picking = false;
    }
  }

  private hintText(): string {
    if (this.saveMode === 'manual') {
      const label: string = DownloadSettings.getInstance().getSaveDirLabel();
      if (label.length === 0) {
        return '还没选目录：点「手动选择」挑一个目录（系统文件选择器）。'
          + '选完记住它，之后每首下载都会定位到这个目录。';
      }
      const persistent: boolean = DownloadManager.getInstance().isManualDirPersistent();
      return `当前目录：${label}。手机系统不允许应用直接往用户目录里新建文件，`
        + '所以每首下载会弹一次系统保存对话框（已定位到这个目录、文件名已填好），确认即可。'
        + (persistent ? '该目录已记住长期授权，重启后不用重选。' : '该目录只有本次会话的授权，重启后需要重选。')
        + '想完全不询问，请用「Download目录」。';
    }
    return 'Download目录：保存到系统的 Download/应用名/ 目录，全程不弹对话框，'
      + '在「文件管理」里能直接看到；系统不支持时会退回应用内的 Download 目录。';
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 17 }) {
            OptionSetting({
              label: '文件名称格式',
              options: NAME_FORMAT_LABELS,
              activeIndex: this.formatIndex(),
              onPick: (index: number) => {
                DownloadSettings.getInstance().setNameFormat(NAME_FORMATS[index]);
              },
            })

            ToggleSetting({
              label: '下载文件标注音质',
              value: this.markQuality,
              onPick: (next: boolean) => {
                DownloadSettings.getInstance().setMarkQuality(next);
              },
            })

            Column({ space: 9 }) {
              SettingLabel({ label: '保存位置' })
              SegPills({
                labels: SAVE_MODE_LABELS,
                activeIndex: this.saveModeIndex(),
                onPick: (index: number) => {
                  void this.pickMode(SAVE_MODES[index]);
                },
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 17, bottom: 17 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          HintText({ text: this.hintText() })
          HintText({
            text: '文件名示例：「' + this.sampleName() + '」。'
              + '（应用内目录下载中的文件先写成 .part，下完才改名，中途失败不留半截歌。）'
              + '同时最多下 2 首，其余排队。',
          })
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

  /** 按当前设置拼一个示例文件名，省得用户猜「标注音质」是什么效果 */
  private sampleName(): string {
    let base: string = '夜、萤火虫和你';
    if (this.nameFormat === 'artist-title') {
      base = 'AniFace-夜、萤火虫和你';
    } else if (this.nameFormat === 'title-artist') {
      base = '夜、萤火虫和你-AniFace';
    }
    return this.markQuality ? `${base}-320k.mp3` : `${base}.mp3`;
  }
}
