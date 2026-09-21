# 洛雪移动端 UI 复刻（HarmonyOS）

目标：界面与洛雪音乐移动端一致，功能可以先不接。播放链路复用了原有的
「内置搜索 → 自定义音源解析播放链接 → AVPlayer」，其余数据是内存里的演示数据。

## 页面结构

```
pages/Index.ets                 壳层：四个页签 + 底部玻璃层 + 全屏播放器 + 播放列表半模态 + 音源沙箱
views/RecommendView.ets         推荐：顶栏来源下拉框 + 排行榜横滑卡片 + 推荐歌单（栏内排序下拉框）
views/PlaylistView.ets          歌单：列表 + SongListPane（与「我的」共用）
views/ImportPlaylistSheet.ets   导入歌单：粘贴分享链接 → 解析预览 → 落成本地歌单
views/MineView.ets              我的：播放历史/收藏/平台音乐/下载管理 分段胶囊
views/SettingsView.ets          设置：搜索框、登录卡、音源/播放/下载/主题/其它 分组
views/SourceSettingsView.ets    音源设置（真功能：导入在线音源、加载、删除、日志、离线自检）
views/SearchView.ets            搜索页（真功能：一次聚合搜五平台 + 结果按平台筛选下拉框）
views/PlayerView.ets            全屏播放器：封面页/歌词页横滑双页（歌词随进度自动滚动）
views/PlayQueueSheet.ets        播放列表内容（外面的半模态是系统 bindSheet）
views/MiniBar.ets               HdsTabs 迷你栏内容：折叠=唱片圆钮，展开=迷你播放器
ui/Theme.ets / ui/Icons.ets / ui/Glass.ets / ui/Widgets.ets   设计基建
core/player/PlaySession.ets     播放会话/队列/历史（演示数据也在这里）
core/music/CoverStore.ets       封面懒解析 + 缓存（列表陆续出图）
core/music/Lyric.ets            LRC 解析与当前行定位
core/music/PlatformLyric.ets    内置平台歌词（kw/kg/tx/mg）
core/music/Inflate.ets          纯 ArkTS zlib/deflate 解压（酷我歌词用）
core/music/PlaylistLink.ets     歌单分享链接解析（五平台正则 + 短链跟随 + lxmusic 深链，见 docs/LIST_IMPORT.md）
```

## 图标：官方符号图标库

图标全部改用 HarmonyOS 官方符号图标（`SymbolGlyph` + `$r('sys.symbol.<name>')`），
不再自绘 SVG：

- 名字取自 SDK 的系统资源表 `ets-loader/sysResource.js` 的 `symbol` 段
  （本机 4042 个），不是猜的；写错名字会静默渲染成空白。
  可用 `node -e "console.log(Object.keys(require('<sdk>/ets/build-tools/ets-loader/sysResource.js').sys.symbol))"`
  导出全量清单。
- 底部导航用官方成对变体：未选中 `house` / 选中 `house_fill`（歌单
  `music_note_list(_fill)`、我的 `person(_fill)`、设置 `gearshape(_fill)`）。
- 其余：`magnifyingglass` 搜索、`record_circle` 音源、`music_note_list` 播放列表、
  `play_fill`/`pause_fill`/`backward_end_fill`/`forward_end_fill` 播放控制、
  `repeat`、`heart(_fill)`、`star_trophy` 榜单、`doc_plaintext` 分类、
  `paintbrush` 主题、`hand_thumbsup` 其它、`speaker_wave_3` 播放中指示……
- 官方图标支持 `symbolEffect` 动效，需要时可直接加在 `IconGlyph` 上。
- 全应用不再有自绘路径图标：播放页那颗播放钮也从自绘「水滴」改成了圆形底 +
  官方 `play_fill` / `pause_fill`（原来那条 `PLAY_BLOB` 路径和 `scalePath()` 已删除）。

## 华为玻璃动效 + HDS 光效

三层叠加：

1. **沉浸式系统材质**（`uiMaterial.ImmersiveMaterial`，API 26）：系统在材质层做滤镜，
   `interactive: true` 是按压形变反馈，`lightEffect` 是光感交互反馈。
   封装在 `ui/Glass.ets`，每个玻璃层同时设置材质与 `backgroundBlurStyle` 兜底。
2. **HDS 光效**（UI Design Kit `@kit.UIDesignKit`，见 `ui/Hds.ets`）：走 `hdsEffect` 的
   **着色器**路径 —— `HdsEffectBuilder().shaderEffect({...}).buildEffect()` 产出一个
   `VisualEffect`（`uiEffect.VisualEffect`，API 12 起的通用属性），挂在任意组件的
   `.visualEffect()` 上，**不需要现成控件当载体**：
   - `HdsFlowLightBackground`：`EffectType.UV_BACKGROUND_FLOW_LIGHT`，整片背景流光。
     挂在首页（`views/RecommendView.ets`）内容 Stack 的首个子节点，10 秒一圈、无限循环、
     透明度 0.5；页面底色要上移到那层 Stack —— 底色留在内容层会把流光整片盖住。
   - `HdsEdgeFlowLight`：`EffectType.DUAL_EDGE_FLOW_LIGHT`，轮廓流光。
     挂在播放页的播放钮下面（白色主光带 + 一点品牌红副光带）。
   - 两者都铺满父容器、`HitTestMode.Transparent`，不影响布局与交互；
     首页流光可在「设置 - 外观」里关掉。
3. **HDS 玻璃材质色**：描边取 `$r('sys.color.glass_material_outline_primary')`，
   亮暗模式与系统一致；取不到时退回自绘高光边。

### 悬浮控件的玻璃：照着派音抄（这才是「为什么它好看」的答案）

把派音的源码逐行读完之后，结论和我之前做的是**反的**：

- **它的顶栏圆钮根本不用玻璃、不用材质、不用光效**（`HomeTopBar.ets`）：就三个属性 ——
  `backgroundColor('#1AFFFFFF')`（10% 白）+ `borderWidth(1)` + `borderColor('#FFFFFF')`
  （纯白 1px 描边），`40×40 / borderRadius 20`。暗色下换成 `#19FFFFFF` / `#66FFFFFF`。
  **全项目没有一处 `shadow()`。**
- **它的左右筛选栏用的是系统组件** `CapsuleSegmentButtonV2`
  （`@ohos.arkui.advanced.SegmentButtonV2`，见它的 `CapsuleSegmentedSelector.ets`）：
  底是页面同色系的浅灰、选中项是强调色药丸 + 反白字。
- 玻璃只出现在**大面**上（迷你栏、hero 上的按钮）：`backgroundBlurStyle(BACKGROUND_THICK)`
  + `#26ffffff` 描边，就这些。
- 它好看的根本原因不只是"配方"，而是**平台组件用得多**：HDS 的标题栏 / 悬浮页签栏 / 半模态、
  系统 `CapsuleSegmentButtonV2` / `Chip` / `bindSheet` / 菜单 —— 圆角、间距、动效都是平台定的。

所以 listen 这边改成：

| 控件 | 现在的做法 |
| --- | --- |
| 我的页分段筛选 | 系统 `CapsuleSegmentButtonV2`（`ui/CapsuleSegment.ets`，V2 组件）——与派音同一个组件 |
| 顶栏圆钮（搜索 / 导入 / 新建 / 清空…）| 派音那颗钮的配方：10% 白底 + 纯白 1vp 描边，**去掉阴影、去掉轮廓光效** |
| 两个下拉框 | **自己画胶囊 + 系统下拉菜单**（`bindMenu` + `Menu`/`MenuItem`），不是系统 `Select`：Select 自带一套内边距与高度（≥40vp），外面再套自绘框会出现「框一种尺寸、文字按另一种尺寸排」的错位。自绘后框高（36 / 30）、圆角（18 / 15）、内边距、箭头间距全可控 |
| 标题栏 / 底部页签栏 / 半模态 | HDS 的系统材质（平台认可的表面，材质真能渲染） |

之前的「粗糙」有两层原因：一是给悬浮控件**加了阴影和自发光**，那会把它变成"实心白牌子"；
二是我一直在手画本该交给平台的组件。

### 系统材质（`.systemMaterial`）在内容区不生效这件事

`uiMaterial` / `.systemMaterial()` 是 **API 26** 的接口，而 HDS 里接受 `SystemMaterialParams` 的
只有两处：标题栏（`TitleBarStyleOptions.systemMaterialEffect`）和 `HdsTabs` 的浮动页签栏
（`HdsTabsFloatingStyle.systemMaterialEffect`），加上半模态 —— 底部导航栏之所以有材质，
是因为它是"底部页签栏"这个平台认可的表面。内容区里的普通按钮拿不到。

代码里仍然保留这条路（`immersiveMaterialFor()` + `.systemMaterial()`，能力位不支持时返回
`undefined`），能生效就生效，不生效就落在上面那层自绘玻璃上 —— 但**不要指望它**，
界面的观感是照着派音那套调的。

### 悬浮控件的玻璃：走系统材质，和底部导航栏同一套

底部导航栏那种「流光溢彩」是**系统沉浸材质**画的（折射、随底下内容提亮、按压形变、
光感反馈都在材质滤镜里）。`systemMaterial` 是 API 26 起的**通用属性**
（`uiMaterial.ImmersiveMaterial`），任何组件都能挂 —— 不是只能用在标题栏 / 底部 TabBar /
弹窗上，那是早先版本的限制，之前照那条限制自己手画磨砂，所以看着「粗糙」。

`ui/Glass.ets` 的 `GlassModifier` 现在分三层，一层层降级：

1. **系统材质**（首选，能力位在就挂）：
   `ImmersiveMaterial({ style, interactive: true, lightEffect: { color: 主题色 }, applyShadow: true })`
   - `style` 跟随外观设置的档位（`immersiveStyleOf`，跟随系统时问 `getGlobalMaterialLevel()`）；
   - `interactive` = 按压形变反馈；`lightEffect` = 光感交互反馈（动感光效的来源）。
2. **轮廓点光**（可选，`withPointLight()`）：HDS 的 `pointLight` 着色器（`SOFT` 柔光 +
   `BORDER` 只照亮轮廓），给悬浮控件边沿加一圈光，让它们「立」起来。
   圆钮、两个下拉框、我的页分段栏都开了。
3. **自绘兜底**：毛玻璃模糊 + **上亮下暗的轻渐变**（纯色底太死）+ 1vp 系统玻璃描边 +
   轻阴影。只有在设备没有材质能力位、或材质构造失败时才是唯一的一层；
   支持时它仍然先画上去 —— 材质生效会接管底色 / 描边 / 阴影，
   万一某个机型上材质在内容区不渲染，控件也不会变成一片透明。

走这一套的控件（改档位时一起变厚变薄）：顶栏圆钮（搜索 / 导入 / 新建 / 清空…）、
**两个下拉框**（首页来源、「推荐歌单」栏的排序）、**我的页分段筛选**（做成左右留边、
大圆角的浮动玻璃条，与底部导航栏同一个观感）、搜索框、页内悬浮迷你播放条、提示条。

### 材质档位（标题栏 / 页签栏 / 半模态 + 全部自绘玻璃层）

`ui/Hds.ets` 的 `buildTitleMaterial(level)` 把「跟随系统 / 弱 / 均衡 / 强」映射成
`hdsMaterial` 的 `SMOOTH / GENTLE / EXQUISITE / ADAPTIVE`，三处都调它：

| 位置 | 字段 |
| --- | --- |
| 子页面标题栏 | `titleBar()` 的 `style.systemMaterialEffect`（见 `Index.titleBarOptions`） |
| 底部悬浮页签栏 | `barFloatingStyle.systemMaterialEffect` |
| 半模态（播放列表 / 同步方式）| `bindSheet` 的 `systemMaterial` |

档位存在 `core/settings/AppearanceSettings.ets`（沙箱 JSON + AppStorage），
在「设置 - 外观」里改，改完一起变：

| 档位 | 系统材质（标题栏 / 页签栏 / 半模态） | 自绘玻璃层（`buildGlassBlur`） |
| --- | --- | --- |
| 跟随系统 | `ADAPTIVE` | `COMPONENT_THICK`（自绘层没有系统档位可跟，按均衡偏厚） |
| 弱 | `SMOOTH` | `COMPONENT_THIN` |
| 均衡 | `GENTLE` | `COMPONENT_REGULAR` |
| 强 | `EXQUISITE` | `COMPONENT_ULTRA_THICK` |

自绘层的档位是响应式的：宿主组件用 `@StorageLink(K_MATERIAL_LEVEL)` 订阅，在 build 里按当前值
取玻璃 —— 与派音「一个 `AmbientState` 驱动全应用玻璃厚度」是同一个做法。

### 子页面标题栏

`Index.titleBarOptions(title, scroller?)` 一个函数管全部 9 个子页面：

- `blurStrategy: ENABLE` + `systemMaterialEffect`：标题栏是磨砂玻璃，而不是一条死白；
- 标题与图标色取 `$r('sys.color.font_primary')`（跟随系统深浅模式）；
- 传了 `scroller` 才开 `IMMERSIVE_GRADIENT_BLUR`：在线歌单 / 歌单详情两页的封面会滚到
  标题栏底下，靠 `HdsNavDestination.bindToScrollable([scroller])` 拿滚动偏移，
  返回键从浮在封面上渐变成浮在磨砂上；白底设置页不绑滚动，直接上材质更稳。

> **模拟器不支持 HDS 沉浸视效**（官方文档明确列出：点光源效果、按压阴影、
> 双边边缘流光、背景流光、自带背景的双边流光、沉浸光感材质）。
> 但代码**不因为模拟器就把能力关掉**：`hdsEffectSupported()` 只看能力位
> （`canIUse('SystemCapability.UIDesign.HDSComponent.Core')`），能不能画出来交给平台 ——
> 早先那版额外做了「模拟器就整层跳过」，结果是哪里都没有效果，设置页还把原因写成
> 「当前设备不支持」，对不上问题。现在「设置 - 外观」底部会把能力位 / 材质类型 /
> 是否模拟器如实写出来，方便对不上时定位。

## 外观设置（设置 - 外观）

`views/AppearanceSettingsView.ets` + `core/settings/AppearanceSettings.ets`
（沙箱 `appearance_settings.json`，改完立即落盘）：

| 项 | 作用范围 |
| --- | --- |
| 玻璃材质档位 | 标题栏 / 底部页签栏 / 半模态 |
| 首页流光 | 首页 HDS 背景流光（关掉就不挂这一层，省一份着色器） |
| 播放页封面圆角 | 播放页大封面（0 直角 ~ 40 接近圆形，默认 12） |

**深浅模式故意没放进来**：自绘界面的颜色还在 `ui/Theme.ets` 的常量里，只切系统的
`setColorMode` 会出现「浅色界面 + 深色系统栏」的四不像。要开放这一项，得先把全部颜色
迁到资源（`resources/base` 与 `resources/dark` 下的同名 token，含现在散在视图里的
内联色值），再读设置里的档位去 `setColorMode`。

## 动效与无障碍（照着派音那套补齐的）

- **封面弹簧**：播放 / 暂停时封面弹一下（`views/PlayerView.ets`，stiffness 220 /
  damping 13，16ms 一帧做数值积分，约 12% 过冲后收住）。Curve 里没有带过冲的弹簧，
  所以自己积。
- **符号替换动效**：`ui/Icons.ets` 的 `IconGlyph` 加了 `replaceEffect`，播放 <-> 暂停、
  收藏 <-> 取消收藏是「长成另一个形状」，不是硬切（默认关，列表里成百上千个图标不该
  各自带动效）。
- **首页筛选收进顶栏**：来源（酷我 / 酷狗 / 咪咕 / QQ / 网易云）与排序（推荐 / 最热 / 最新…）
  原来是标题下面两排横滑胶囊，总共占掉 86vp 的高度。现在来源做成顶栏右侧的下拉框
  （系统 `Select`，位置就是原来那颗「音源设置」圆钮的位置），排序并进「推荐歌单」那一栏靠右，
  内容因此上移一屏。两个下拉框都只放真正可选项 —— `Select` 的选中态由组件自己维护，
  混进「跳页入口」这类不是选项的条目，选完会停在那一条上改不回来。
- **歌单行不再画分隔线**：封面 + 两行字自己就能分开，浅灰底上那条 `C_DIVIDER` 看着像一条白缝；
  行里的作者 / 播放量从 `C_TEXT_WEAK` 换成 `C_TEXT_SUB`（原来的灰压在同色系底上几乎看不见）。
- **空状态**：`ui/Widgets.ets` 的 `EmptyState`（官方符号 + 主文案 + 怎么才有内容的副文案），
  歌单 / 歌单详情 / 播放列表等处不再各写一段灰字。
- **无障碍**：图标钮与列表行都给了 `accessibilityText` / `accessibilityGroup`
  （之前全应用 0 处）：圆钮、歌曲行、迷你栏、播放页控制区；
  纯装饰的图标（封面上的音量指示、行尾箭头、未接功能的铃铛）标 `accessibilityLevel('no')`，
  读屏不会报出一个点不动的按钮。

## HDS 增强组件

除图标/材质/视效外，结构层也换成了 HDS 的组件（`@kit.UIDesignKit`）：

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| 子页面路由（搜索 / 音源设置） | 自绘头部 + 手动 if 切页 + 位移动画 | `HdsNavigation` + `HdsNavDestination`，标题栏与返回键由 HDS 提供（实测标题为「搜索」「音源设置」） |
| 提示条 | 自绘玻璃胶囊 + 定时器 | `HdsSnackBar.show(...)`（HDS 材质与进出动效），取不到时回退自绘 |
| 设置页 | 自绘搜索框 + 分组白卡 + 自绘行 | 搜索框换成系统 `Search`；行仍是自绘（`HdsListItemCard` 自带卡片外边距、行铺不满宽度，而能改宽度的 `cardWidth` 会把它搞崩，见下） |
| 音源设置·已导入音源 | 自绘 Row + 加载/删除按钮 | `HdsListItemCard`（`PrefixIcon` + 名称/版本 + `SuffixText`「已就绪」/`SuffixArrow`），点卡片即加载；加载/删除按钮保留在卡片下方 |
| 底部导航 | 自绘胶囊 + 自绘迷你播放器（两者同时显示，逻辑不对） | `HdsTabs` 悬浮页签 + `MiniBar`（见下节） |
| 歌曲行 / 歌单行 | 自绘 Row + 自绘分隔线 | 系统 `List` + `ListItemGroup(CARD)`（官方分组卡与分隔线）+ `ListItem.swipeAction` 官方侧滑（精选推荐=下一首播放，播放列表=删除） |
| 顶栏圆形图标钮 | 自绘 Stack + Circle | 官方 `Button({type: ButtonType.Circle})`，玻璃底仍由 `GlassModifier` 给 |
| 播放列表 | 自绘蒙层 + 自绘把手/标题/关闭钮 | 系统 `bindSheet` 半模态，标题栏/关闭钮/拖动条/背景材质全由系统提供 |

### HdsListItem / 列表这一块的三个硬约束

想用 HDS 的列表项，先知道这三条，否则会白写一遍：

1. **`HdsListItem` 只有一个 `@BuilderParam` 时才允许用尾随闭包。** 它实际有两个
   （`customItemBuilder` 和 `menuBuilder`），所以 `HdsListItem({...}) { 行内容 }`
   这种写法会直接编译报错：「must have one and only one property decorated with
   `@BuilderParam`」。想塞自定义行内容只能用 `customItemBuilder:` 传值，
   而那条路是之前闪退过的（系统 HSP 调用回调时丢 this）。
   **结论**：`HdsListItem` 只用「不带子组件、靠 `hdsListItemCard` 描述整行」的形态
   （设置页、音源设置页就是这么用的）；需要自定义行内容（比如带自绘封面占位图的歌曲行）
   就用系统的 `ListItem` + 自己的内容。
2. **`ListItemGroup` 的子组件只能是 `ListItem`**（编译期就拦），
   所以 `HdsListItem` 不能放进 `ListItemGroup`。要官方的「分组卡片」就用
   `ListItemGroup({style: ListItemGroupStyle.CARD})` 包系统 `ListItem`。
3. **`List` 的子组件只能是 `ListItem` / `ListItemGroup` / `ForEach`**，
   搜索框这类非列表组件要套一层 `ListItem`。

官方列表的滑删用系统 `ListItem.swipeAction`（HDS 的 `HdsSwipeActionOptions` 只在
`HdsListItem` 上生效，受第 1 条限制）：

```ts
ListItem() { ... }
  .swipeAction({
    end: { builder: () => { this.deleteAction(index) }, onAction: () => { this.deleteAt(index) } },
  })
```

### HdsActionBar 试过，不合适

播放页底部那排功能入口试过 `HdsActionBar` + `ActionBarButton`（API 也摸清了：
`ActionBarButton` 是 `@ObservedV2` 类，必须 `new ActionBarButton({...})`，
字段 `baseIcon` / `iconSize: LengthMetrics.vp(n)` / `iconFillColor: ColorMetrics.resourceColor(...)`；
`actionBarStyle` 可以覆盖底色/模糊），但**它按「主按钮 + 左右两组」排布，不会把 N 个图标等分铺满**，
实测四个图标挤在左侧、底部还多留一块空白，把底色抹成透明也没用。所以这行回到自绘的四等分格。
结论：**需要等分铺满的一排图标，别用 HdsActionBar。**

### 底部：HdsTabs 悬浮页签 + MiniBar

洛雪底部那套「左边点出页签栏、右边点唱片出播放器」的交互，正好就是 HDS 悬浮页签
（6.1.0(23) 起支持）的设计：悬浮页签栏右边跟一条**迷你栏**，两者高度相等，
一个展开另一个就收起来，点击由 HDS 自己处理（回调里 `mode == USER_CLICK`）。

三个硬性前提（官方约束，少一个就不是悬浮样式）：

```ts
.barPosition(BarPosition.End)
.vertical(false)
.barOverlap(true)
```

悬浮样式只接受两种页签样式：`BottomTabBarStyle` 和 `CustomBuilder`。这里用官方的
`BottomTabBarStyle`，图形仍是官方符号图标（选中态用实心变体），颜色走
`TabBarSymbol` 的 `SymbolGlyphModifier` 与 `labelStyle`：

```ts
new BottomTabBarStyle(
  {
    normal: new SymbolGlyphModifier(I_HOME).fontColor([C_ICON]).fontSize(23),
    selected: new SymbolGlyphModifier(I_HOME_FILL).fontColor([C_RED]).fontSize(23),
  } as TabBarSymbol,
  '推荐'
).labelStyle({ selectedColor: C_RED, unselectedColor: '#4A4A4C' })
```

迷你栏的内容只有一份 builder，展开/折叠由它根据当前形态决定画多细：

```ts
.barFloatingStyle({
  // 页签栏和迷你栏分别贴左右两边，中间的空隙 = 剩余宽度，所以页签栏要给足宽度
  barWidth: { smallWidth: 280, mediumWidth: 340, largeWidth: 440 },
  barSideMargin: 12,
  barBottomMargin: this.bottomInset + 10,
  gradientMask: { maskColor: '#66F1F1F2', maskHeight: 104 },   // 内容从页签栏底下淡出
  systemMaterialEffect: { materialType: hdsMaterial.MaterialType.IMMERSIVE,
                          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
  miniBar: {
    miniBarBuilder: () => this.miniBarBuilder(),   // 必须用箭头函数包一层，理由见下
    miniBarWidth: { smallWidth: 286, mediumWidth: 300, largeWidth: 328 },  // 展开上限 328vp
    miniBarStyle: HdsBarStyle.COLLAPSE,
    onBarStyleChange: (mini, tab, miniW, tabW, mode) => {
      AppStorage.setOrCreate(K_MINI_EXPANDED, mini === HdsBarStyle.EXPAND);
    },
  },
})
```

两个实现要点：

1. **builder 一定要用箭头函数包**：`miniBarBuilder: () => this.miniBarBuilder()`。
   直接传 `this.miniBarBuilder`（方法引用）会丢 `this`，HDS 在自己的上下文里调用时
   就复现上面那个 `observeComponentCreation2 of undefined` 闪退。官方示例也是箭头写法。
2. **形态用 AppStorage 传，不靠 builder 重跑**：`onBarStyleChange` 把结果写进
   `K_MINI_EXPANDED`，迷你栏内容组件（`views/MiniBar.ets`）用 `@StorageLink` 订阅，
   这样即使 HDS 不重新调用 builder，内容也会跟着展开/折叠切换。

页签栏和迷你栏的宽度分档都按 HdsTabs 自身宽度算（<440vp 用 `smallWidth`，
440~600 用 `mediumWidth`，更大用 `largeWidth`），手机竖屏落在 `smallWidth`。

### 播放列表：官方半模态

```ts
.bindSheet($$this.queueOpen, this.queueSheet(), {
  preferType: SheetType.BOTTOM,
  detents: [SheetSize.MEDIUM, SheetSize.LARGE],
  detentSelection: SheetSize.MEDIUM,   // 默认半屏；往下拖会先吸回这一档，再拖才关闭
  dragBar: true, showClose: true,
  blurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
  systemMaterial: { materialType: hdsMaterial.MaterialType.IMMERSIVE,
                    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE },
  title: { title: '播放列表', subtitle: `共 ${this.queueCount} 首` },
})
```

- `isShow` 用 `$$` 双向绑定：用户下滑或点系统关闭钮时 `queueOpen` 自动变 false。
- 高度用两档 `detents`：默认停在 `MEDIUM`（半屏），往上能拖到 `LARGE`，
  往下拖会先吸回 `MEDIUM` 这个中间档、只有继续往下拖才会关闭——这是系统半模态自带的吸附。
- 本 SDK 的 `SheetOptions` **没有** `backgroundColor` 和 `onDisappear`，背景靠
  `blurStyle` / `systemMaterial`（都是官方材质）；`radius` 只接受
  `LengthMetrics | BorderRadiuses`，给数字会编译报错，所以干脆用系统默认圆角。
- 内容（`views/PlayQueueSheet.ets` 的 `PlayQueueContent`）只画队列本身：
  标题、关闭钮、拖动条都不再自绘。

`HdsListItemCard` 的用法（不需要自己排版）：

```ts
HdsListItemCard({
  prefixItem: new PrefixIcon({ iconSize: IconSize.SYSTEM_ICON, iconValue: { symbol: $r('sys.symbol.record_circle') } }),
  textItem: { primaryText: { text: '音源设置' } },
  suffixItem: new SuffixArrow({ color: '#C2C2C6' }),
  cardHeight: 63,
  onClick: () => { ... },
})
```

> **坑（会闪退）**：不要用 `PrefixCustomBuilder` / `HdsListItem` 的 `customItemBuilder`
> 传成员 `@Builder`。HDS 组件是系统 HSP（`hdsBaseComponent.js`），回调 builder 时是在
> 它自己的 JS 上下文里调用，成员 builder 拿不到组件的渲染上下文，直接在渲染期崩：
>
> ```
> TypeError: Cannot read property observeComponentCreation2 of undefined
>   at iconTile entry (views/SettingsView.ets:66)
>   at create (…/hdsBaseComponent.js:1292)
> ```
>
> 要用自定义前缀/后缀，目前只能传**全局** `@Builder` 函数（本次未验证），
> 或者干脆用 HDS 的内置前缀/后缀。`onClick` 这种普通回调是安全的。
>
> 另外 `TextModifier` 是**类**不是接口，要 `extends TextModifier` 而不是 `implements`，
> 否则报 `arkts-implements-only-iface`。

### 两个 HDS 布局坑

1. **`HdsListItemCard` 的按压高亮很难调，且它的尺寸选项会把它搞坏。**
   - 它的按压高亮是按「一行一张卡」设计的：塞进自绘的分组白卡里，
     卡片圆角与按压高亮圆角对不上，表现是**按下去的高亮盖不满整行、四周露白边**。
   - 想用 `cardWidth` / `cardBackgroundColor` / `cardBorderRadius` / `hoverBorderRadius`
     去修，实测**只要给 `cardWidth: '100%'`，它内部的宽度测量就被破坏**：
     整行文字消失、卡片塌成一条，整个设置页全崩（用户实测截图确认）。
   **结论**：设置页这种「分组白卡 + 行内分隔线」的列表，行自己画、按压态用
   `stateStyles` 给；`HdsListItemCard` 只用在白卡底由外层自绘容器提供、
   且不需要调按压样式的场景（音源设置页的已导入音源列表就是这么用的）。
2. **HDS 标题栏是层叠在内容之上的，而且默认是沉浸的（会顶到状态栏里去）。**
   - 官方文档 Constraints 一节：「标题栏默认采用层叠布局（位于内容区上层）」，
     它**不会**把内容往下推。所以 `HdsNavDestination` 里的内容必须自己让出这段高度，
     否则首行文字会被标题栏压住。见 `ui/Hds.ets` 的 `HDS_TITLE_BAR_HEIGHT`
     （60vp，经验值，标题栏没暴露高度接口）。
   - 标题栏自带的「沉浸」意味着**返回键和标题会直接叠在状态栏文字上**（用户实测截图确认）。
     修法是给 `titleBar` 开官方开关 `avoidLayoutSafeArea: true`
     （官方 API 文档：「是否需要标题栏主动避让安全区」），让标题栏内容自己退到状态栏下方；
     内容层的让位高度相应变成 `HDS_TITLE_BAR_HEIGHT + topInset`。
   - **前提**是窗口用 `setWindowLayoutFullScreen(true)`，不能用 `setFullScreen(true)`：
     后者会把状态栏彻底隐藏、避让高度归零，此时 `avoidLayoutSafeArea` 怎么设都没用
     （华为论坛同款问题，官方回帖确认的根因）。
     背景层负责延伸进状态栏（根 Stack 的 `expandSafeArea`），标题栏内容负责避让，两者分开管。

**还没换的**：`SongListPane`（「我的」页与搜索结果里共用的歌曲列表）仍是自绘行——
它的父容器是 Scroll，要换成官方 List 得连父级一起改；播放页进度条那行、封面页的
信息行、状态提示条也仍是自绘。主页签的标题栏还是自绘大标题（`hideTitleBar(true)`）。

## 踩过的坑（ArkTS）

1. **8 位色值是 `#AARRGGBB`，不是 CSS 的 `#RRGGBBAA`**。
   `'#FFFFFF8C'`（本意 55% 白）会被解析成 **不透明的黄**（A=FF, R=FF, G=FF, B=8C），
   表现是按钮/进度条/文字整片发黄。写半透明色一定要把透明度放前面。
2. **`Path().commands()` 的坐标单位是 px，不是 vp**。
   直接写 24x24 的 SVG 路径会得到 24px 的小图（约为目标尺寸的 1/3），
   要按 `vp2px(目标尺寸)/24` 缩放；`Shape.viewPort` 搭配不带宽高的 `Path`
   时缩比也不对。**现在已不用自绘路径**（图标全走 sys.symbol，播放钮走 `Circle` +
   官方播放图形），这条留着是为了以后真要用 `Path()` 时别踩。
3. **自定义组件的成员名不能和 `CustomComponent` 的成员重名**：
   `size` / `width` / `height` / `tabIndex` 都会编译报错，换成 `boxSize` /
   `cardWidth` / `activeTab` 这类名字。
4. **`Shape` 是容器的子集**：`justifyContent` 这类 Flex 属性在 Stack/Shape 上不存在。
5. **自定义组件的成员名不能和 `CustomComponent` 冲突**：除 `size`/`width`/`height`/
   `tabIndex` 外，`deviceInfo.model` 这种字段也不存在，设备信息要用
   `productModel` / `marketName` / `hardwareModel`。
6. 页面标题的避让：根节点用 `expandSafeArea([SafeAreaType.SYSTEM],[TOP,BOTTOM])`
   铺满整屏，再按 `getWindowAvoidArea` 读到的避让高度做留白；读到 0 说明系统已经
   避让过，此时要按 0 处理，否则会双重留白（标题被推得很低）。

## 搜索页：聚合搜索 + 平台筛选

搜索页不再先让人选一个平台再搜，而是**一次问五个平台**（`searchMusicAll()`，
`Promise.allSettled` 并发，单个平台超时/接口变了不让整次搜索失败）：

- 结果按「每个平台轮流取一条」交错合并（`interleave()`）。直接拼接是「30 条酷我 +
  30 条酷狗」，要滚过一整个平台才看得到另一个；交错后前几行就能横向比较同一首歌
  在各平台的结果——同一首歌常常只有一两个平台能拿到播放链接，这才是聚合的用处。
- 结果栏右端一个**平台筛选下拉框**（和推荐页两个下拉框同款：自己画的胶囊 +
  `bindMenu` 系统菜单）。菜单项带着各平台这次搜到几首（搜到 0 首或失败也照实写），
  切换只换现成的列表，不重新联网。不筛 = 全部平台的聚合结果。
  筛选会记住（换关键词也还在那个平台）；但筛的平台这次一条都没有（多半没通）时
  自动退回「全部」，免得人对着空列表看不出别的平台有结果。
- 结果行上带**平台标签**（品牌色小胶囊，`platformColor/platformTint`）：
  聚合结果里同一首歌有好几条，不标出来分不清哪条是哪个站。
- **音质选择从搜索页撤掉了**：它和「设置 - 播放设置 - 播放音质」写的是同一个值
  （两边各写一趟，还各自有个默认值），留在搜索页只是多一个入口；现在搜索页只负责
  搜索，音质统一听设置的。
- 状态行与空态会说清楚「哪个平台没通」（`本次 酷我 30 · 酷狗 失败 · …`），
  失败的平台可以单独切过去看，而不是笼统地报一句「搜索失败」。

## 数据与功能边界

- 演示数据（播放历史、歌单、精选推荐、播放队列、排行榜卡片）在
  `PlaySession.seed()` 里，内容与截图一致。
- 搜索是**真功能**：推荐页右上角放大镜 / 搜索结果可直接播放（走原有音源链路）。
- **演示歌单里的歌也能真出声**：这些条目只有歌名/歌手、没有 musicInfo，所以
  `PlaySession.ensurePlayable()` 会先按「歌名 + 歌手」在当前音源声明且内置搜索支持的
  平台上搜一次，拿到真实 musicInfo 后再交给源规则解析播放链接，并把队列里这条替换成
  真实条目（封面、时长跟着变真实）。解析结果按歌名缓存在 `resolveCache` 里，不会每次重搜。
- **音质按源声明协商**：设置里选的音质不一定被音源支持，`negotiateQuality()` 会在
  「源声明的 qualitys」∩「这首歌提供的 `_types`」里从高到低挑一个；直接把用户选的音质
  丢给源，遇到不支持该音质的源就会解析失败（表现出来就是点了没反应）。
- **进度 / 时长 / 播放态全部来自 AVPlayer**：`LxPlayer` 把 `timeUpdate` / `durationUpdate` /
  `stateChange` 通过订阅回调交给 `PlaySession` 回写 AppStorage，播完自动下一首挂在
  `completed` 上。以前是 `PlaySession` 每秒 +1 自己造进度，所以没声音时界面照样走进度条，
  看起来「在放」其实没声。
- **交互不「先变后执行」**：切歌时先 `LxPlayer.release()` 停掉旧歌、进度清零、清旧歌词，
  再解析新歌；解析/缓冲期间是 `loading`，播放钮与迷你栏显示转圈、进度条冻结且不可拖，
  只有 AVPlayer 真进到 `playing` 才显示播放中并开始走进度。`toggle()` 也不再自己写
  「已暂停/正在播放」，全部等 AVPlayer 的 `stateChange`。切歌还有 `playToken`：
  解析期间又点了别的歌，旧链路的结果会被丢弃，不会覆盖新歌。
- **封面**：搜索结果里 tx/wy/mg 自带封面；kw/kg 没有，按平台接口现取
  （`kw/pic.web`、`kg/get_res_privilege`，与 LX 的 `kw/pic.js`、`kg/pic.js` 一致），
  源脚本实现了 `pic` action 时作为兜底。`CoverStore` 负责懒解析：列表先画占位，
  解析好一批就把 `K_COVER_VERSION` +1，订阅它的列表重画一次，封面陆续出现。
  播放页与迷你栏用 `K_CURRENT_COVER`，当前这首歌解析好就回填。
- **歌词**：**内置平台歌词是主力**（kw/kg/tx/mg，`core/music/PlatformLyric.ets`）——
  平台源的 action 白名单本来就只有 `musicUrl`，洛雪也是用内置 SDK 取词的，所以不该
  指望源。kw 的接口是 zlib 流（自己实现了 inflate）→ base64 → XOR `yeelion`；
  kg 是 `download?fmt=lrc` 的 base64 明文；tx 是 `fcg_query_lyric_new?nobase64=1`
  的明文 LRC；mg 是 `resourceinfo` 拿 `lrcUrl` 再取明文。源若声明了 `lyric` 则优先用源的（本工程有意放宽了 preload 的
  action 白名单，官方只允许 musicUrl），源没有或没时间轴再落到内置。
  取到词后 `parseLyric()` 解析 LRC，播放页歌词页用 `List` + `scrollToIndex(CENTER)`
  跟随真实进度自动居中滚动，点某一行可跳到那一句；两个平台都取不到时显示「暂无歌词」。
  （wy 目前取不到：它的 eapi 端点连搜索接口都返回 404，需要单独重做。）
- **没有加载音源时不再假装播放**：点播放会提示「请先在音源设置导入并加载一个音源」，
  而不是进入「演示模式」空转。
- **音源去重**：同一个「名字 + 版本 + 作者」重复导入只保留一条——脚本内容相同直接跳过，
  内容变了就覆盖更新且 id 不变；启动时还会清理历史遗留的重复项。
  （`SourceMeta` 的 `@version` 常自带 `v`，展示时不再补一个 v，避免出现 `vv1.2.1`。）
- 音源设置页保留了此前调试页的全部能力（URL 导入、加载、平台声明、沙箱
  `lx.env` 兼容模式切换、引擎日志、一键离线自检）。

