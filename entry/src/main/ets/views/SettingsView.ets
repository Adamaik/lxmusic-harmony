import { C_BG, C_CARD, C_DIVIDER, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB, R_CARD } from '../ui/Theme';
import { I_BRUSH, I_CACHE, I_CHEVRON_RIGHT, I_DISC, I_DOWNLOAD, I_GEAR, I_PERSON, I_REFRESH, I_THUMB_UP,
  I_VOLUME, IconGlyph } from '../ui/Icons';
import { hdsEffectSupported, hdsMaterialType } from '../ui/Hds';
import { isGlassMaterialSupported } from '../ui/Glass';
import { PageTitle } from '../ui/Widgets';

/** 设置项 */
interface SettingRowDef {
  icon: Resource;
  title: string;
  action: string;
}

const GROUP_SOURCE: SettingRowDef[] = [
  { icon: I_DISC, title: '音源设置', action: 'source' },
];

const GROUP_SYNC: SettingRowDef[] = [
  { icon: I_REFRESH, title: '同步设置', action: 'sync' },
];

const GROUP_PLAY: SettingRowDef[] = [
  { icon: I_VOLUME, title: '播放设置', action: 'play' },
  { icon: I_CACHE, title: '缓存', action: 'cache' },
  { icon: I_DOWNLOAD, title: '下载设置', action: 'download' },
];

const GROUP_THEME: SettingRowDef[] = [
  { icon: I_BRUSH, title: '主题', action: 'theme' },
];

const GROUP_OTHER: SettingRowDef[] = [
  { icon: I_THUMB_UP, title: '其它', action: 'other' },
  { icon: I_GEAR, title: '关于', action: 'about' },
];

/**
 * 设置页的一行：官方符号图标 + 标题 + 右箭头
 *
 * 这里没有用 HDS 的 HdsListItemCard，两个原因：
 *   1) 它自带卡片外边距，行铺不满内容宽度，比同页的搜索框窄一圈；
 *   2) 想用 cardWidth/cardBackgroundColor/cardBorderRadius/hoverBorderRadius 去调，
 *      结果 cardWidth 会破坏它内部的宽度测量，整行文字直接消失、卡片塌掉。
 * 所以这一行自绘，按压态用 stateStyles 自己给，保证高亮严丝合缝覆盖整行。
 * HDS 组件仍用在子页路由/标题栏、音源设置列表、SnackBar、悬浮页签等处。
 */
@Component
struct SettingRow {
  @Prop icon: Resource;
  @Prop title: string = '';
  @Prop showDivider: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Column() {
      Row({ space: 13 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(34)
            .height(34)
            .fill('#0F000000')
          IconGlyph({ symbol: this.icon, iconSize: 20, color: C_TEXT })
        }
        .width(34)
        .height(34)

        Text(this.title)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: '#C2C2C6' })
      }
      .width('100%')
      .height(63)
      .padding({ left: 14, right: 14 })
      .stateStyles({
        normal: { .backgroundColor(Color.Transparent) },
        pressed: { .backgroundColor('#14404044') },
      })
      .onClick(() => {
        this.onTap();
      })

      if (this.showDivider) {
        Divider()
          .strokeWidth(0.6)
          .color(C_DIVIDER)
          .margin({ left: 61 })
      }
    }
    .width('100%')
  }
}

/**
 * 设置页
 *
 * 顶部是系统的 Search 组件；下面依次是登录卡、音源设置、播放/下载设置、主题、其它/关于，
 * 每一组都是一张白色圆角卡（与洛雪一致）。搜索词会过滤各组里的设置项。
 */
@Component
export struct SettingsView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop sourceSummary: string = '未加载音源';
  onNavigate: (action: string) => void = () => {
  };
  @State keyword: string = '';
  @State hdsText: string = '';

  aboutToAppear(): void {
    // HDS 视效在模拟器上不可用，这里把实际生效情况摊开，免得效果对不上时无从判断
    const effect: string = hdsEffectSupported() ? '已启用' : '当前设备不支持（模拟器）';
    // 玻璃（沉浸式材质）与视效是两个独立能力位
    const glass: string = isGlassMaterialSupported() ? '系统材质可用' : '毛玻璃兜底';
    this.hdsText = `HDS 沉浸视效：${effect}　沉浸光感材质：${hdsMaterialType()}（玻璃：${glass}）`;
  }

  /** 按搜索词过滤一组设置项 */
  private filter(rows: SettingRowDef[]): SettingRowDef[] {
    const key: string = this.keyword.trim();
    if (key.length === 0) {
      return rows;
    }
    return rows.filter((row: SettingRowDef) => row.title.includes(key));
  }

  @Builder
  cardGroup(rows: SettingRowDef[]) {
    Column() {
      ForEach(this.filter(rows), (row: SettingRowDef, i: number) => {
        SettingRow({
          icon: row.icon,
          title: row.title,
          showDivider: i < this.filter(rows).length - 1,
          onTap: () => {
            this.onNavigate(row.action);
          },
        })
      }, (row: SettingRowDef) => row.action)
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  hint(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(C_TEXT_SUB)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .textAlign(TextAlign.Start)
  }

  build() {
    Column() {
      Row() {
        PageTitle({ text: '设置' })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInset + 6, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          // ------------------------------------------------ 搜索设置（系统 Search 组件）
          Search({ value: this.keyword, placeholder: '搜索设置' })
            .placeholderColor(C_TEXT_WEAK)
            .placeholderFont({ size: 15 })
            .textFont({ size: 15 })
            .height(48)
            .backgroundColor(C_CARD)
            .onChange((value: string) => {
              this.keyword = value;
            })

          // ------------------------------------------------ 登录音乐
          Row({ space: 14 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle().width(52).height(52).fill('#C9C9CE')
              IconGlyph({
              symbol: I_PERSON,
              iconSize: 34,
              color: '#FFFFFF',
            })
            }
            .width(52)
            .height(52)

            Column({ space: 5 }) {
              Text('登录音乐')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(C_TEXT)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text('网易云 / QQ / 酷狗账号，扫码或 Cookie 登录')
                .fontSize(F_SUB)
                .fontColor(C_TEXT_WEAK)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            IconGlyph({
              symbol: I_CHEVRON_RIGHT,
              iconSize: 18,
              color: '#C2C2C6',
            })
          }
          .width('100%')
          .height(88)
          .padding({ left: 16, right: 14 })
          .borderRadius(R_CARD)
          .backgroundColor(C_CARD)
          .onClick(() => {
            this.onNavigate('login');
          })

          // ------------------------------------------------ 音源
          this.cardGroup(GROUP_SOURCE)
          this.hint(`当前音源：${this.sourceSummary}`)

          // ------------------------------------------------ 同步
          this.cardGroup(GROUP_SYNC)
          this.hint('与洛雪同步服务连接后，试听列表 / 收藏 / 歌单 / 不喜欢的歌曲可与其它设备互通')

          // ------------------------------------------------ 播放 / 下载
          this.cardGroup(GROUP_PLAY)

          // ------------------------------------------------ 主题
          this.cardGroup(GROUP_THEME)
          this.hint(this.hdsText)

          // ------------------------------------------------ 其它 / 关于
          this.cardGroup(GROUP_OTHER)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.bottomInset + 16 })
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
