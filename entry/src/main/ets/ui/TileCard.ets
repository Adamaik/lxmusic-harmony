/**
 * 横滑卡（分类卡 / 精选榜卡共用）：**有封面铺封面，没封面落成主题玻璃卡**
 *
 * 2026-10-21 重做。之前推荐页「歌手分类 / 歌单分类 / 精选榜」和听书「分类」都按
 * 数组下标循环取 6 组高饱和纯色渐变（红 / 蓝 / 紫 / 橙 / 粉 / 绿），一屏七八张
 * 彩虹块，和本应用「浅灰底 + 白卡 + 洛雪红 + 玻璃层」这套主题完全不是一个语言
 * （用户反馈「纯色和软件主题不搭」）。现在统一成两种形态：
 *
 *   - **有真实封面**（榜单榜首封面）→ **封面铺满整张方形卡** + 底部压暗 + 白字，
 *     与推荐歌曲大卡同一个观感。注意：`CoverArt` 默认按 `boxSize` 画正方形，整张卡
 *     要用它得开 `fill: true`，否则封面只占左侧一块、右边露出卡底与压暗层，
 *     就是「方块图 + 灰条」那种怪形状（2026-10-21 实机截图反馈）。
 *   - **没有封面**（听书分类、平台的歌单分类这种纯文字档位）→ 主题玻璃卡：
 *     白卡底 + 极淡的红色晕染 + 首字水印 + 深色字。
 *
 * 两种形态都由 `color.json` 的 token 画（深浅模式自动换），封面上的白字 / 压暗
 * 与深浅模式无关，和播放页封面上的那几层白字同理。
 *
 * 选中态一律用强调红表示（描 2vp 红边；玻璃卡再叠一层淡红底 + 红字），
 * 不再「换一种颜色」；这样颜色只剩一个语义 = 选中。
 *
 * 圆角、字重、播放钮摆法照现有卡片：播放钮压左下角时要用「铺满的 Stack +
 * alignContent(BottomStart)」定位，直接给子组件 `.align()` 实测不生效
 * （见 views/RecommendView.ets 里 coverWithPlay 那段说明）。这里的播放钮在
 * 卡面右下角，跟着文字走，所以用 Row 收在底部。
 */
import { C_CARD, C_RED, C_RED_TINT, C_TEXT } from './Theme';
import { I_PLAY, IconGlyph } from './Icons';
import { CoverArt } from './Widgets';

@Component
export struct TileCard {
  /** 卡面文字：分类名 / 榜名 */
  @Prop title: string = '';
  /** 封面地址；空字符串 = 走玻璃卡 */
  @Prop coverUrl: string = '';
  @Prop cardWidth: number = 118;
  @Prop cardHeight: number = 84;
  @Prop radius: number = 16;
  /** 选中态（描红边；玻璃卡另有淡红底 + 红字） */
  @Prop selected: boolean = false;
  /** 卡面右下角压一颗白三角播放钮（榜单卡用，分类卡不显示） */
  @Prop showPlay: boolean = false;
  onTap: () => void = () => {
  };

  private hasCover(): boolean {
    return this.coverUrl.length > 0;
  }

  /** 玻璃卡右上角那颗首字水印：纯装饰，取名字的第一个字 */
  private mark(): string {
    return this.title.length > 0 ? this.title.substring(0, 1) : '';
  }

  private titleColor(): ResourceColor {
    if (this.hasCover()) {
      return Color.White;
    }
    return this.selected ? C_RED : C_TEXT;
  }

  private titleSize(): number {
    return this.hasCover() ? 16 : 14;
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.hasCover()) {
        CoverArt({
          url: this.coverUrl,
          name: this.title,
          art: false,
          boxSize: this.cardHeight,
          radius: 0,
          fill: true,
        })
          .width('100%')
          .height('100%')
        // 底部压暗，白字才跳得出来（与推荐歌曲大卡同款）
        Column()
          .width('100%')
          .height('66%')
          .linearGradient({ angle: 0, colors: [['#00000000', 0.0], ['#A6000000', 1.0]] })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.selected ? C_RED_TINT : C_CARD)
        // 极淡的红色晕染（左上 → 透明），给白卡一点层次，不再是死白一块
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({ angle: 135, colors: [[C_RED_TINT, 0.0], ['#00000000', 1.0]] })
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(this.mark())
            .fontSize(this.cardHeight * 0.56)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_RED)
            .opacity(0.10)
            .maxLines(1)
        }
        .width('100%')
        .height('100%')
        .padding({ right: 9, top: 2 })
      }

      Row({ space: 6 }) {
        Text(this.title)
          .fontSize(this.titleSize())
          .fontWeight(FontWeight.Bold)
          .fontColor(this.titleColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .textShadow({
            radius: this.hasCover() ? 10 : 0,
            color: this.hasCover() ? '#33000000' : '#00000000',
            offsetX: 0,
            offsetY: this.hasCover() ? 2 : 0,
          })
        if (this.showPlay) {
          IconGlyph({ symbol: I_PLAY, iconSize: 15, color: '#FFFFFF' })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 11, right: 10, bottom: 9 })
    }
    .width(this.cardWidth)
    .height(this.cardHeight)
    .borderRadius(this.radius)
    .clip(true)
    .border({ width: this.selected ? 2 : 0, color: C_RED })
    .shadow({ radius: 8, color: '#0F000000', offsetX: 0, offsetY: 3 })
    .onClick(() => {
      this.onTap();
    })
    .accessibilityGroup(true)
    .accessibilityText(this.selected ? `${this.title}，已选中` : this.title)
    .accessibilityLevel('yes')
  }
}
