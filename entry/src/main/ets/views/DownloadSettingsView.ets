import { C_BG, C_CARD, R_CARD } from '../ui/Theme';
import { HintText, OptionSetting, SettingLabel, ToggleSetting } from '../ui/SettingWidgets';
import { DownloadManager } from '../core/download/DownloadManager';
import { DownloadSettings, K_DOWNLOAD_DIR_URI, K_DOWNLOAD_MARK_QUALITY, K_DOWNLOAD_NAME_FORMAT,
  NAME_FORMAT_LABELS, NAME_FORMATS } from '../core/download/DownloadSettings';

/**
 * 下载设置
 *
 * 三项：
 *   文件名称格式（歌曲名 / 艺术家-标题 / 标题-艺术家）
 *   下载文件标注音质（开/关）
 *   下载目录（**只展示，不可改也不提供跳转**）
 *
 * 保存位置固定为应用自己的下载目录（系统 Download/<应用名>/，全程不弹对话框），
 * 所以这里不再让用户选，也不放「打开文件夹」按钮 —— 系统没有「跳到文件管理某个目录」
 * 的能力（依据见 docs/DEFECTS.md D-004），按钮只能把文件管理拉到首页，反而误导。
 * 把目录名字显示出来，用户自己去「文件管理」里找即可。
 */
@Component
export struct DownloadSettingsView {
  @Prop bottomInset: number = 0;
  @StorageLink(K_DOWNLOAD_NAME_FORMAT) nameFormat: string = 'song';
  @StorageLink(K_DOWNLOAD_MARK_QUALITY) markQuality: boolean = true;
  /** 公共下载目录 uri：写进去过一次才有值（下载成功后订阅它刷新） */
  @StorageLink(K_DOWNLOAD_DIR_URI) dirUri: string = '';

  private formatIndex(): number {
    const index: number = NAME_FORMATS.indexOf(this.nameFormat);
    return index < 0 ? 0 : index;
  }

  /** 下载目录的展示名（`下载/<应用名>`；还没下载过时说明文件在应用内目录） */
  private folderLabel(): string {
    return DownloadManager.getInstance().folderLabel();
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

            // 下载目录：只读展示（不可改、不给跳转入口），与上面两项同一个「标题 + 当前值」样式
            SettingLabel({ label: '下载目录', value: this.folderLabel() })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 17, bottom: 17 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)

          HintText({ text: this.hintText() })
          HintText({
            text: '文件名示例：「' + this.sampleName() + '」。'
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

  private hintText(): string {
    if (this.dirUri.length === 0) {
      return '歌曲统一保存在应用自己的下载目录里，全程不弹对话框。'
        + '下载一首之后，这里会显示它在「文件管理」里的位置。';
    }
    return `歌曲统一保存在「${this.folderLabel()}」，全程不弹对话框。`
      + '这是应用自己的目录，位置固定、不能改；文件管理里打开「下载」就能看到它，'
      + '也可以在那儿复制或分享下载好的文件。';
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
