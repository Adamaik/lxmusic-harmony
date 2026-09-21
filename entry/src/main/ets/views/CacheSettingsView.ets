import { C_BG, C_CARD, C_DIVIDER, C_RED, C_TEXT, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB,
  R_CARD } from '../ui/Theme';
import { I_CACHE, IconGlyph } from '../ui/Icons';
import { AudioCache, K_CACHE_VERSION } from '../core/music/AudioCache';
import { MediaCache } from '../core/music/MediaCache';

/**
 * 缓存设置
 *
 * 对应洛雪的三个地方：
 *   「设置 - 播放 - 最大缓存」  -> 播放缓存上限（这里叫播放缓存）
 *   「设置 - 其它 - 资源缓存」  -> 占用与一键清理
 *   「设置 - 其它 - 元数据缓存」-> 播放地址 / 歌词的条数与清理
 *
 * 说明一点差别：洛雪靠播放器自带的边播边缓存，上限是给播放器的；HarmonyOS 的
 * AVPlayer 没有流式缓存，所以这里是「边播边把整首下到沙箱」，上限由我们自己的
 * LRU 淘汰执行（详见 core/music/AudioCache.ets）。
 */
@Component
export struct CacheSettingsView {
  @Prop bottomInset: number = 0;
  @State limitMb: number = 0;
  @State limitText: string = '';
  @State audioBytes: number = 0;
  @State audioCount: number = 0;
  @State urlCount: number = 0;
  @State lyricCount: number = 0;
  @State picCount: number = 0;
  @StorageLink(K_CACHE_VERSION) @Watch('refresh') cacheVersion: number = 0;

  aboutToAppear(): void {
    this.syncLimitText();
    this.refresh();
  }

  /** 只刷统计：输入框里的文字不要跟着刷，否则正在敲数字时会被覆盖回去 */
  private refresh(): void {
    const audio = AudioCache.getInstance();
    this.limitMb = audio.getLimitMb();
    this.audioBytes = audio.sizeBytes();
    this.audioCount = audio.fileCount();
    const media = MediaCache.getInstance();
    this.urlCount = media.musicUrlCount();
    this.lyricCount = media.lyricCount();
    this.picCount = media.picCount();
  }

  /** 把输入框回填成已保存的上限（进页面 / 提交后调用） */
  private syncLimitText(): void {
    const mb: number = AudioCache.getInstance().getLimitMb();
    this.limitMb = mb;
    this.limitText = mb > 0 ? `${mb}` : '';
  }

  /** 上限只在提交时落盘 + 按新上限淘汰，输入过程中不要每敲一个数字就动缓存 */
  private submitLimit(): void {
    const text: string = this.limitText.trim();
    if (text.length === 0) {
      AudioCache.getInstance().setLimitMb(0);
      this.toast('已关闭播放缓存');
      this.syncLimitText();
      this.refresh();
      return;
    }
    const value: number = Number.parseInt(text, 10);
    if (Number.isNaN(value) || value < 0) {
      this.toast('请输入 0 以上的整数（MB）');
      this.syncLimitText();
      return;
    }
    AudioCache.getInstance().setLimitMb(value);
    this.toast(`播放缓存上限已设为 ${value} MB`);
    this.syncLimitText();
    this.refresh();
  }

  private clearAudio(): void {
    if (this.audioCount === 0) {
      return;
    }
    this.confirm(`确定清空播放缓存吗？共 ${sizeText(this.audioBytes)} / ${this.audioCount} 首，`
      + `清空后这些歌下次播放要重新下载。`, () => {
      AudioCache.getInstance().clear();
      this.toast('播放缓存已清空');
      this.refresh();
    });
  }

  private clearMeta(): void {
    if (this.urlCount === 0 && this.lyricCount === 0 && this.picCount === 0) {
      return;
    }
    this.confirm('确定清空元数据缓存吗？播放地址、歌词、封面地址都会重新获取。', () => {
      const media = MediaCache.getInstance();
      media.clearMusicUrls();
      media.clearLyrics();
      media.clearPics();
      this.toast('元数据缓存已清空');
      this.refresh();
    });
  }

  private confirm(message: string, onOk: () => void): void {
    this.getUIContext().showAlertDialog({
      title: '清空缓存',
      message: message,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        { value: '清空', fontColor: '#E33B3B', action: onOk },
      ],
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  sectionTitle(title: string, subtitle: string) {
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
  audioCard() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('已用空间')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(`${sizeText(this.audioBytes)} · ${this.audioCount} 首`)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('清空')
          .fontSize(F_SUB)
          .fontColor(this.audioCount > 0 ? C_RED : C_TEXT_WEAK)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.clearAudio();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('缓存上限')
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.limitMb > 0 ? '超过上限会淘汰最早播放的' : '当前未开启，播放时不会缓存到本地')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        TextInput({ text: this.limitText, placeholder: 'MB' })
          .type(InputType.Number)
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .width(88)
          .height(38)
          .backgroundColor('#F2F2F4')
          .onChange((value: string) => {
            this.limitText = value;
          })
          .onSubmit(() => {
            this.submitLimit();
          })
          .onBlur(() => {
            this.submitLimit();
          })

        Text('MB')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  metaCard() {
    Column() {
      Row({ space: 8 }) {
        Text('播放地址')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text(`${this.urlCount} 条`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 8 }) {
        Text('歌词')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text(`${this.lyricCount} 条`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 8 }) {
        Text('封面地址')
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text(`${this.picCount} 条`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 14 })

      Divider().strokeWidth(0.6).color(C_DIVIDER).margin({ left: 14 })

      Row({ space: 10 }) {
        IconGlyph({ symbol: I_CACHE, iconSize: 18, color: C_TEXT_WEAK })
        Text('清空元数据缓存')
          .fontSize(F_ITEM)
          .fontColor(C_RED)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .height(46)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        this.clearMeta();
      })
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
          this.sectionTitle('播放缓存', sizeText(this.audioBytes))
          this.audioCard()
          Text('边听边把整首下到应用沙箱，下次播放直接读本地：不联网、不受源脚本影响。'
            + '上限设 0 即关闭缓存。')
            .fontSize(11.5)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: 4, right: 4 })
            .textAlign(TextAlign.Start)
          Text('下载永远给播放让路：正在听的那首缓冲不够时缓存会停下来等（网络就那么多，'
            + '先把声音喂饱），够用了再接着下；断在半路的会留着，下次接着下，不从头重来。'
            + '上一首还在播时也会提前取下下一首，切歌时直接读本地文件。')
            .fontSize(11.5)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: 4, right: 4 })
            .textAlign(TextAlign.Start)

          this.sectionTitle('元数据缓存', '')
          this.metaCard()
          Text('播放地址、歌词、封面地址都会缓存一份（对应洛雪的 @music_url / @lyric）：'
            + '播放过的歌再次播放不必重新解析，歌词不会因为源抽风而忽然没有，'
            + '封面也不必每次启动都为整张列表重新查一遍。')
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

/** 字节 -> 人话（与洛雪 sizeFormate 的观感一致） */
function sizeText(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}
