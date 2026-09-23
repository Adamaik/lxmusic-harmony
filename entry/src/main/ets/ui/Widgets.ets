import { C_BG, C_DIVIDER, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, C_TOP_FADE, C_TOP_FADE_END,
  F_ITEM, F_SECTION, F_SUB, R_COVER } from './Theme';
import { immersiveMaterialFor, materialFirstGlass, thinGlass } from './Glass';
import { I_CHEVRON_RIGHT, I_DOC, I_HEART, I_HEART_FILLED, I_MORE, I_TRASH, I_VOLUME, IconGlyph } from './Icons';
import { K_FAVORITE_IDS } from '../core/player/FavoriteIndex';
import { K_MATERIAL_LEVEL } from '../core/settings/AppearanceSettings';
import { LAYOUT_UNBOUNDED } from './Layout';

/**
 * 通用小组件：封面、圆形图标按钮、歌曲行
 */

/**
 * 宽屏内容列（平板 / 折叠屏展开态）
 *
 * 手机（< 600vp）铺满整屏，与改之前一模一样；宽屏把内容收成居中一列（最大
 * CONTENT_MAX_WIDTH），两侧留白 —— 否则列表与设置项会从屏幕左边缘一直拉到右边缘，
 * 一行的封面和文字隔着半个屏幕，读起来很散。
 *
 * maxWidth 传 0 表示「不限宽」（窄屏，或窗口宽度还没量到），见 ui/Layout.ets。
 *
 * `fadeTop` 给子页面用：> 0 时在这层内容上方压一条「底色 → 全透明」的渐隐，高度就是
 * 传进来的值。子页面的标题栏和首页一样是纯透明的，内容会从它底下滑过去，不给渐隐
 * 的话列表文字会直接撞在标题上。**内容要让出标题栏那一段是各页面自己的事**
 * （在滚动容器里加一段会跟着滚走的顶部占位，见各设置页里的说明）—— 这一层不能用
 * `padding` 让位：内边距会把滚动内容裁在标题栏下边缘，看起来就"像被顶栏挡住"。
 */
@Component
export struct WidePane {
  @Prop maxWidth: number = 0;
  /** 渐隐蒙版高度（vp）：0 = 不加（页签页内容自带渐隐，不需要这层） */
  @Prop fadeTop: number = 0;
  @BuilderParam content: () => void;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        Column() {
          this.content()
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: this.maxWidth > 0 ? this.maxWidth : LAYOUT_UNBOUNDED })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 收窄后两侧的留白也跟着页面底色走：子页面（设置类）本身就是这个底色，
      // 不给底色的话两侧会露出 HdsNavDestination 的默认底，中间一条灰、两边一条白
      .backgroundColor(C_BG)

      // 子页面（fadeTop > 0）：内容从透明标题栏底下滑过去时靠近顶部淡出，别把标题顶穿。
      // 页签页（fadeTop = 0）不加：它们的内容在自己的 Stack 里已经带了渐隐。
      if (this.fadeTop > 0) {
        TopFade({ fadeHeight: this.fadeTop })
      }
    }
    .width('100%')
    .height('100%')
  }
}

/** 占位封面配色（没有真实封面图时用：本地歌、还没解析出封面的搜索结果等） */
const PALETTES: string[][] = [
  ['#2B2B33', '#141417'],
  ['#3A2E1E', '#191410'],
  ['#1B2A33', '#0E1519'],
  ['#2E2233', '#150F19'],
  ['#33241F', '#1A1210'],
  ['#1F2E24', '#101813'],
];

function paletteOf(name: string): string[] {
  let sum: number = 0;
  for (let i = 0; i < name.length; i++) {
    sum = (sum * 31 + name.charCodeAt(i)) % 9973;
  }
  return PALETTES[sum % PALETTES.length];
}

function initialsOf(name: string): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    return '';
  }
  return trimmed.substring(0, 1);
}

/** 洛雪在封面加载出来之前用的那套黑色占位封面（黑底 + 白心 + 金点） */
@Component
struct HeartCover {
  @Prop boxSize: number = 48;
  @Prop radius: number = R_COVER;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: [['#17171A', 0.0], ['#0A0A0B', 1.0]] })

      Row({ space: this.boxSize * 0.045 }) {
        Circle().width(this.boxSize * 0.12).height(this.boxSize * 0.12).fill('#C9A227')
        Circle().width(this.boxSize * 0.17).height(this.boxSize * 0.17).fill('#E2BB3C')
        Circle().width(this.boxSize * 0.12).height(this.boxSize * 0.12).fill('#C9A227')
      }
      .alignItems(VerticalAlign.Bottom)
      .offset({ x: 0, y: -this.boxSize * 0.27 })

      IconGlyph({
        symbol: I_HEART_FILLED,
        iconSize: this.boxSize * 0.62,
        color: '#F4F4F6',
      })
        .offset({ x: 0, y: this.boxSize * 0.05 })
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor('#0A0A0B')
  }
}

/**
 * 专辑封面。
 * url 有值时显示网络图；否则用内置占位（黑心封面或按曲名生成的渐变块）。
 *
 * `appIcon` 为真时（全屏播放器 / 底部迷你播放器）**所有兜底都换成聆听的应用图标**：
 * 没有正在播放的歌、这首歌没有封面、封面地址失效，一律是那颗音符。播放器上与其放
 * 一块按曲名生成的渐变块（没有歌名时就是一块什么都没有的深色方块），不如放应用
 * 自己的图标 —— 至少认得出是谁在放。列表类（搜索结果、歌单曲目）不开这个开关：
 * 一屏几十张小图全变成同一个图标，反而分不出哪首是哪首。
 *
 * 这里**故意不给 Image 设 alt**：alt 是「加载中」的占位图，之前挂的是应用图标，
 * 于是封面还没下完的那一瞬间会先闪一张 App 图标（全屏播放器弹起来的时候最明显，
 * 用户反馈「很丑」）。去掉之后加载期间就是一块深色圆角底，图到了直接换上；
 * 真的加载失败（地址过期、断网）再退回黑心/首字母底，不会一直空着。
 */
@Component
export struct CoverArt {
  /** url 变化时重新给一次机会：上一首加载失败不算这一首的（见 onUrlChanged） */
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop name: string = '';
  /** 是否使用洛雪那套黑心占位封面 */
  @Prop art: boolean = false;
  /**
   * 兜底图换成聆听的应用图标（全屏播放器 / 底部迷你播放器开，列表类别开）
   *
   * 优先级在 `art` 之上：播放器上即使这首歌标了「用黑心占位」，也还是给应用图标 ——
   * 「没有封面」在播放器上只该有一种样子。
   */
  @Prop appIcon: boolean = false;
  @Prop boxSize: number = 48;
  @Prop radius: number = R_COVER;
  /**
   * 封面是否「可能还在路上」（播放器里传「还在 loading」）
   *
   * 为真且还没有地址时只给一块深色底：全屏播放器弹起来那一瞬间先闪一张默认封面、
   * 半秒后再换成真封面，比空着更难看。加载结束还没图才会走下面的兜底占位。
   */
  @Prop pending: boolean = false;
  /** 这张图加载失败 */
  @State failed: boolean = false;

  onUrlChanged(): void {
    this.failed = false;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.url.length > 0 && !this.failed) {
        Image(this.url)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            this.failed = true;
          })
      } else if (this.pending) {
        Column()
          .width('100%')
          .height('100%')
      } else if (this.appIcon) {
        // 聆听的应用图标（与锁屏媒体卡的兜底封面同一张，见 PlaybackService 的 FALLBACK_COVER_RES）。
        // Cover 而不是 Contain：图标本身带方形底，铺满才像一张「默认封面」
        Image($r('app.media.startIcon'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else if (this.art) {
        HeartCover({ boxSize: this.boxSize, radius: this.radius })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 145,
            colors: [[paletteOf(this.name)[0], 0.0], [paletteOf(this.name)[1], 1.0]],
          })
        Text(initialsOf(this.name))
          .fontSize(this.boxSize * 0.4)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D9FFFFFF')
      }
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.radius)
    .clip(true)
    .backgroundColor('#1C1C1E')
  }
}

/**
 * 空状态
 *
 * 之前每个列表各写一段灰字（字号、颜色、上下留白各不相同，有的还没图标），
 * 这里合成一处：官方符号图标 + 主文案 + 可选副文案，居中。
 * 用官方符号而不是自绘插图，与全应用「图标一律 sys.symbol」保持一致。
 */
@Component
export struct EmptyState {
  @Prop icon: Resource = I_DOC;
  @Prop text: string = '';
  /** 副文案：告诉用户「怎么才会有内容」，比单说「没有数据」有用 */
  @Prop hint: string = '';
  @Prop topPadding: number = 64;

  build() {
    Column({ space: 10 }) {
      IconGlyph({ symbol: this.icon, iconSize: 42, color: C_TEXT_WEAK })
        .accessibilityLevel('no')
      Text(this.text)
        .fontSize(F_ITEM)
        .fontColor(C_TEXT_SUB)
        .textAlign(TextAlign.Center)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .textAlign(TextAlign.Center)
          .padding({ left: 32, right: 32 })
      }
    }
    .width('100%')
    .padding({ top: this.topPadding, bottom: 24 })
    .alignItems(HorizontalAlign.Center)
  }
}

/** 顶栏右侧那种白色玻璃圆钮 */
@Component
export struct RoundIconButton {  @Prop icon: Resource;
  @Prop boxSize: number = 40;
  @Prop iconSize: number = 20;
  @Prop color: ResourceColor = C_ICON;
  @Prop filled: boolean = true;
  /** 读屏用的说明（这个钮里只有图形，读屏读不出「搜索」「音源」这类含义） */
  @Prop label: string = '';
  /**
   * 这颗钮是否画在**沉浸光感的生效范围**里（Navigation 标题栏 / 底部 TabBar）
   *
   * 为真时不再自绘玻璃底：那些位置系统材质真的会渲染，而材质层级在 backgroundColor /
   * backgroundBlurStyle 之下，自绘一层底就把它盖住了（官方 FAQ 的「背景色或背景模糊
   * 遮挡材质效果」）。材质不可用的设备上自动退回自绘，不会变成透明钮。
   */
  @Prop materialFirst: boolean = false;
  onTap: () => void = () => {
  };
  /** 玻璃厚度档位（外观设置）：订阅它，改档位时全部悬浮圆钮一起变厚变薄 */
  @StorageLink(K_MATERIAL_LEVEL) materialLevel: number = 0;

  build() {
    // 用官方的圆形 Button 承载（带系统按压/焦点态），玻璃底由 GlassModifier 给：
    // 内容区里只能自绘（普通组件不在沉浸光感生效范围内），标题栏里则交给系统材质
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      IconGlyph({
              symbol: this.icon,
              iconSize: this.iconSize,
              color: this.color,
            })
    }
    .width(this.boxSize)
    .height(this.boxSize)
    // 派音那颗悬浮圆钮的配方：极淡的白底 + 纯白 1vp 描边，没有阴影、没有光效。
    // 玻璃感来自「透出背后的内容」这一件事，而不是加阴影或者描边发亮。
    .attributeModifier(this.materialFirst
      ? materialFirstGlass(this.boxSize / 2, this.materialLevel)
      : thinGlass(this.boxSize / 2, false, '', this.materialLevel))
    // 系统沉浸材质（和底部导航栏同一族的观感）。挂在组件上而不是 AttributeModifier 里：
    // 属性修改器里能调哪些接口有讲究，直接挂更稳。设备没有能力位时这里是 undefined，
    // 等于不设材质，界面就落在上面那层自绘玻璃上。
    .systemMaterial(immersiveMaterialFor(this.materialLevel))
    .onClick(() => {
      this.onTap();
    })
    .accessibilityText(this.label)
    .accessibilityLevel(this.label.length > 0 ? 'yes' : 'auto')
  }
}

/**
 * 顶栏渐隐蒙版
 *
 * 首页标题栏是纯透明的（华为音乐那一套），内容会从标题底下穿过去。不加这一层的话，
 * 行文字会直接撞在「推荐」两个字后面，很脏。这一层从页面底色渐隐到全透明，压在
 * **滚动内容之上、标题栏之下**（标题栏是 HDS 的独立图层，永远在这之上），
 * 于是内容越靠近顶部越淡，而标题、来源胶囊、搜索钮始终清晰。
 *
 * 铺满宽度、不拦触摸：它只是一层视觉遮罩，不该影响滚动与点击。
 */
@Component
export struct TopFade {
  /** 蒙版高度（vp）。调用方按「状态栏 + 标题栏 + 一点余量」给。
   *  不能叫 `height` —— 那个名字和组件基类自带的同名属性冲突，编译会报 not assignable。 */
  @Prop fadeHeight: number = 120;

  build() {
    Column()
      .width('100%')
      .height(this.fadeHeight)
      .linearGradient({
        // 180 = 从上往下，0.0 落在顶边：顶边是底色本身，越往下越透
        angle: 180,
        colors: [[C_TOP_FADE, 0.0], [C_TOP_FADE_END, 1.0]],
      })
      .hitTestBehavior(HitTestMode.Transparent)
  }
}

/** 列表里的一行歌曲 */
@Component
export struct SongRow {
  @Prop name: string = '';
  @Prop singer: string = '';
  @Prop coverUrl: string = '';
  @Prop coverArt: boolean = false;
  @Prop coverSize: number = 48;
  @Prop playing: boolean = false;
  @Prop showMore: boolean = false;
  @Prop showChevron: boolean = false;
  @Prop showDelete: boolean = false;
  onTap: () => void = () => {
  };
  onMore: () => void = () => {
  };
  onDelete: () => void = () => {
  };

  build() {
    Row({ space: 11 }) {
      CoverArt({
        url: this.coverUrl,
        name: this.name,
        art: this.coverArt,
        boxSize: this.coverSize,
        radius: R_COVER,
      })

      Column({ space: 4 }) {
        Text(this.name)
          .fontSize(F_ITEM)
          .fontColor(this.playing ? C_RED : C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.singer.length > 0) {
          Text(this.singer)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.playing) {
        IconGlyph({
              symbol: I_VOLUME,
              iconSize: 19,
              color: C_RED,
            })
          // 纯装饰（含义已经由歌名变红表达），读屏跳过它
          .accessibilityLevel('no')
      }
      if (this.showDelete) {
        IconGlyph({
              symbol: I_TRASH,
              iconSize: 20,
              color: C_TEXT_WEAK,
            })
          .onClick(() => {
            this.onDelete();
          })
          .accessibilityText(`从歌单移除 ${this.name}`)
          .accessibilityLevel('yes')
      }
      if (this.showMore) {
        IconGlyph({
              symbol: I_MORE,
              iconSize: 20,
              color: C_TEXT_WEAK,
            })
          .onClick(() => {
            this.onMore();
          })
          .accessibilityText(`${this.name} 的更多操作`)
          .accessibilityLevel('yes')
      }
      if (this.showChevron) {
        IconGlyph({
              symbol: I_CHEVRON_RIGHT,
              iconSize: 18,
              color: C_TEXT_WEAK,
            })
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 14 })
    .height(this.coverSize + 22)
    .onClick(() => {
      this.onTap();
    })
    // 整行当成一个节点：读屏读「歌名，歌手」，而不是把封面、文字、图标逐个念一遍
    .accessibilityGroup(true)
    .accessibilityText(this.singer.length > 0 ? `${this.name}，${this.singer}` : this.name)
    .accessibilityLevel('yes')
  }
}

/**
 * 行尾的爱心收藏按钮
 *
 * 收藏状态直接来自 AppStorage 里的收藏名单，不在组件里另存一份、也不靠宿主传
 * 「是否已收藏」：列表用的是 LazyForEach，宿主重绘不会重跑已经建好的行，传值刷不动。
 *
 * 关键点：这里必须把名单读进 build 里用（isLiked 在 build 执行时读 favoriteIds）。
 * ArkUI 的增量刷新是「重绘 build 里读过的状态变量所在的节点」，只声明一个
 * @StorageLink 而不读它，收藏变化不会触发重绘 —— 表现就是「收藏成功了，
 * 爱心却不变色」（之前那版就踩了这个坑）。
 * 点一下收藏、变实心红；再点一下取消收藏、变回空心。
 */
@Component
export struct FavoriteHeart {
  /** 这首歌的条目 id（与 PlaySession.favorites 里的一致） */
  @Prop songId: string = '';
  @Prop iconSize: number = 22;
  /** 已收藏时的颜色（播放器里在深色底上，颜色由调用方给） */
  @Prop colorOn: ResourceColor = C_RED;
  /** 未收藏时的颜色 */
  @Prop colorOff: ResourceColor = C_TEXT_WEAK;
  /** 收藏 / 取消收藏都由宿主决定怎么落库、怎么提示 */
  onToggle: () => void = () => {
  };
  @StorageLink(K_FAVORITE_IDS) favoriteIds: string[] = [];

  private isLiked(): boolean {
    return this.favoriteIds.indexOf(this.songId) >= 0;
  }

  build() {
    Row() {
      IconGlyph({
        symbol: this.isLiked() ? I_HEART_FILLED : I_HEART,
        iconSize: this.iconSize,
        color: this.isLiked() ? this.colorOn : this.colorOff,
        // 收藏 <-> 取消收藏是同一颗心的两种状态，用符号替换动效过渡，不是硬切
        replaceEffect: true,
      })
    }
    // 图标本身太窄，撑出足够大的点击区；子组件的点击会吃掉整行的点击（不会误触播放）
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .onClick(() => {
      this.onToggle();
    })
    .accessibilityText(this.isLiked() ? '取消收藏' : '收藏')
    .accessibilityLevel('yes')
  }
}

/** 页面大标题 */
@Component
export struct PageTitle {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(29)
      .fontWeight(FontWeight.Bold)
      .fontColor(C_TEXT)
  }
}

/** 分组标题（精选推荐 / 榜单） */
@Component
export struct SectionTitle {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(F_SECTION)
      .fontWeight(FontWeight.Bold)
      .fontColor(C_TEXT)
  }
}

/** 列表分割线（左缩进到文字处） */
export function songDivider(coverSize: number): DividerStyle {
  return {
    strokeWidth: 0.6,
    color: C_DIVIDER,
    startMargin: coverSize + 27,
    endMargin: 0,
  } as DividerStyle;
}
