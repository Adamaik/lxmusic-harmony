import { C_FILL_SOFT, C_FILL_SOFT_STRONG, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SUB, F_TAB, R_CARD } from '../ui/Theme';

/**
 * 引擎日志详情
 *
 * 日志面板一行只放得下裁到 200 字符的摘要（见 core/source/SourceEngine.ets 的
 * describeResponse），用户反馈的「看不到全文」就出在这里：原文以前根本没保留。
 * 现在引擎把原文存进 SourceLog.full，这一页负责把它摊开看。
 *
 * 承载方式是半模态（宿主 SourceSettingsView 里的 bindSheet），与「添加到歌单」等
 * 面板同一套做法：标题栏/关闭钮/拖动条由系统的 bindSheet 给，这里只画内容。
 *
 * 只负责展示与发起复制：写粘贴板、弹提示由宿主做（宿主已经有 toast 与失败兜底），
 * 免得这个组件自己再依赖一遍 BasicServicesKit。
 */
@Component
export struct LogDetailView {
  /** 这条日志的完整文本（已带 [时间][级别] 前缀，由宿主拼好） */
  @Prop content: string = '';
  /** 级别，只用于详情页顶部那枚标记 */
  @Prop type: string = '';
  /** 日志发生时间（毫秒时间戳；0 表示没有时间信息，如离线自检的文本） */
  @Prop time: number = 0;
  @Prop bottomInset: number = 0;
  /** 复制全文（具体怎么写粘贴板由宿主决定） */
  onCopy: (text: string) => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.type.length > 0 ? `[${this.type}]` : '[log]')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
        // 时间戳 0 是离线自检那种纯文本行，没有可信的发生时间，宁可不显示也不编一个
        Text(formatLogTime(this.time))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Blank()
        Button('复制全文')
          .fontSize(F_SUB)
          .height(32)
          .backgroundColor(C_FILL_SOFT_STRONG)
          .fontColor(C_TEXT)
          .enabled(this.content.length > 0)
          .onClick(() => {
            this.onCopy(this.content);
          })
      }
      .width('100%')

      /**
       * 全文可能很长（几 KB 的 JSON / 整页 HTML 错误页）：
       * 必须包在能滚动的区域里，否则底部内容会被半模态直接裁掉 —— 那就又变成"看不到全文"。
       */
      Scroll() {
        Text(this.content)
          .fontSize(11.5)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
          // 与面板里的日志行一致：长按选中后可直接用系统的复制菜单
          .copyOption(CopyOptions.LocalDevice)
      }
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .padding(12)
      .borderRadius(R_CARD)
      .backgroundColor(C_FILL_SOFT)

      // 字符数直接摆出来：用户判断"是不是还在被裁"靠的就是它跟原文长度对不对得上
      Text(`共 ${this.content.length} 字符 · 长按可选中复制，「复制全文」写入剪贴板`)
        .fontSize(F_TAB)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .textAlign(TextAlign.Start)

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }
}

/**
 * 详情页顶部的时间：面板里只有时分秒（`toLocaleTimeString`），排查时往往要精确到日期，
 * 所以详情页给完整的一行；0 或非法值返回空串，调用处据此不显示。
 */
function formatLogTime(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const date: Date = new Date(ms);
  const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}
