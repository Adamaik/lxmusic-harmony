# 回响（月度收听报告）2.0 —— 派音版式移植说明

> 日期：2026-11-15
> 来源：派音 2.0.0 `features/recommendation/src/main/ets/view/EchoReviewPage.ets`（2095 行，HEAD `8ad4f49d`）
> 结论：**整页替换**聆听原回响（原 `EchoView.ets` 1046 行 + `ui/EchoReport.ets` 1509 行已删除），
> 视觉与几何照派音，**数据口径保留聆听自己的 ListenLog**。

## 1. 文件清单

| 文件 | 状态 | 行数 | 职责 |
|---|---|---|---|
| `entry/src/main/ets/views/EchoView.ets` | **重写** | 896 | 页面：状态、月/年选择、单列/双列布局、滚动切标题、背景氛围层、点歌/跳歌手/点专辑、顶栏渐隐 |
| `entry/src/main/ets/ui/EchoMonthlyKit.ets` | **新增** | 1666 | 12 个纯视觉组件（含 3D 四点透视榜台：透明 Swiper 收手势 + 逐帧插值翻页、时段柱图、日历热力、完播率圆环） |
| `entry/src/main/ets/core/history/EchoMonthly.ets` | **新增** | 545 | 月度聚合：`MonthRange` / `MonthOption` / `Monthly*` / `buildMonthlyStats` |
| `entry/src/main/ets/core/history/ListenLog.ets` | 追加 | 1060→1094 | 仅新增 3 个只读访问器：`countedRecordsOf` / `allRecords` / `songByKey` |
| `entry/src/main/resources/{base,dark}/element/color.json` | 追加 | 46→72 | 26 个 `echo_*` 成对 token（两份同名同序） |
| `entry/src/main/ets/pages/Index.ets` | 微调 | — | 状态栏不再强制白字、`PageTitle.onDark=false`、`scrollable` 保留禁用 |
| `entry/src/main/ets/ui/Widgets.ets` | 微调 | — | `HeartCover` 增加默认关闭的 `fill` 参数（`CoverArt(fill:true)` 时铺满，其它调用零变化） |
| `entry/src/main/ets/ui/EchoReport.ets` | **删除** | -1509 | 旧固定深色组件库，已无引用（历史见 git） |

## 2. 版面（窄屏 11 段，宽屏两列 1:1）

`Header`（N 分钟 + 与上月倍数）→ 三格统计（次播放/首歌/位歌手）→ 年月 Select →
**你听了什么**（3 张封面四点透视 3D 榜台，**可左右滑动翻页**）→ **最常听的歌手**（冠军大图 + 2/3/4 名）→
**最常听的专辑**（3 张平分）→ **你是怎样的听众**（时段柱图 + 日历热力 + 三行说明）→
**单曲循环之王**（≥2 次）→ **深夜之歌**（0–5 点有量）→ **完播率**（圆环）→ **新发现**。

宽屏（`isWideWindow`）：左列 Header/三格/年月/你听了什么/听众/循环之王/深夜之歌，
右列 歌手/专辑/完播率/新发现，两列 `layoutWeight(1)`。宽屏下标题固定「N 月 · 回响」
（两列同屏，滚动切段名的「最小下标」判定会乱跳，派音同一处也有此问题）。

空月份：只画 Header + 年月选择器 + 空态两行字，不摆 0 值空卡片。

## 3. 数据口径（**与派音不同**，以聆听为准）

| 项 | 聆听 2.0 | 派音 |
|---|---|---|
| 门槛 | `playedMs ≥ COUNTED_MS(30000)` | 无门槛（按 `interval` 标称时长） |
| 总时长 | 真实出声时长 `playedMs` 累加 | `interval` 标称 `mm:ss` |
| 完播率 | 真实判定：`playedMs ≥ 时长×0.85` 算完整，`judged` 为分母 | 「本月播≥2 次的歌占比」 |
| 流水上限 | 1000 条 | 200 条 |
| 月份范围 | 近 12 个自然月 + 历史有记录月份 | `monthOffset ∈ [-11,0]` |

聚合全部在 `EchoMonthly.buildMonthlyStats()`：榜单取 `ListenLog` 已有聚合（30 秒门槛一致），
`新发现`（本月首次听到）/`深夜之歌`（0–5 点逐条计数）/`最长连续听歌天数` 用新增的只读流水访问器算。

## 4. 配色：固定深色沉浸（不跟系统深浅色）

用户 2026-11-15 明确要求：回响是沉浸式月报，**默认纯黑底、永远深色**。因此：

- `ui/EchoMonthlyKit.ets` 顶部导出**固定深色调色板**（`ECHO_*` 常量，取值 = `dark/element/color.json` 的 `echo_*` 深色值）；
  组件与页面全部用它，**不再取 resources 的 `echo_*`**（那套是 base/dark 成对、浅色模式会翻成浅底深字）。
- 页面底色恒为 `#000000`；顶栏渐隐 `#000000 → 全透明`；背景氛围层 = 封面高斯模糊 70 + **0.62 不透明度**（旧版聆听回响口径），
  其上再压**旧版那层「压暗 / 向下渐到纯黑」**：`#4D000000(0%) → #73000000(30%) → #B8000000(55%) → #000000(78%) → #000000(100%)`
  （这层是「透明度」与「底部渐变到纯黑」的关键，缺了它就是一张发亮的模糊图）；两层交叉淡入 420ms。
- 背景**只保留两段**：歌曲/页头 = 领奖台中心卡封面；歌手段 = **最常听歌手本人的写真**
  （本工程 `artist_cache.json`：`cachedArtistOf` 同步命中，未命中 `resolveArtistByName` 在线解析后淡入；
  取不到才退回「该歌手最常听那首歌的封面」，否则会像一张专辑图）；**专辑段沿用歌手背景，不做切换**
  （用户 2026-11-15：「取消专辑的背景过渡」）；进入「听众 / 完播率 / 新发现」或滚到底时渐隐回纯黑。
- 壳层配合：回响页签下 `PageTitle.onDark = true`（白字标题）、状态栏图标白字，与固定深色页一致。
- resources 里 26 个 `echo_*` 成对 token 仍保留（供未来做真正的日夜版），本页不取用。
  `echo_on_photo_primary/secondary`、`echo_photo_scrim` 三项本来就是「不跟主题翻」的例外。

## 5. 交互

- 点歌（榜台/循环之王/深夜之歌）：**优先按记录里的平台 id + `musicInfoJson` 直接建队列播放**（与播放历史/收藏同一套装配；
  列表时长用记录里的真实 `durationMs` 还原成 `m:ss`，避免播放页首帧显示 0:00）；
  没有 id（v1 老记录）才退回「歌名 + 歌手」搜索（本工程识别页那套，先原平台再跨平台聚合）。
- **榜台翻页**（旧版回响交互，按用户要求恢复）：手指左右滑 / 点两侧卡，可在 1st / 2nd / 3rd 之间翻页；
  中心卡点击=播放，侧卡点击=翻到中间（不播放）。透明 Swiper 只当手势与进度源，卡片按连续进度在
  「中心形态（150 正方形）」与「侧卡形态（138 四点透视）」之间逐帧插值，停稳吸附。
- **背景氛围层**（旧版回响交互，按用户要求恢复）：页头/歌曲段用领奖台中心卡封面、歌手段用**歌手本人写真**
  （翻页后中心卡换了也跟着换）；**专辑段沿用歌手背景不切换**；进入「你是怎样的听众 / 完播率 / 新发现」或滚到底时
  渐隐回纯黑。参数与旧版逐字一致：模糊 70、每层 0.62 不透明度 + 压暗渐变 `#4D000000→#73000000→#B8000000→黑(78%)`。
  宽屏两列同屏只跟中心卡。
- 点歌手（大图 / 2/3/4 名）：`ArtistNav.openArtist()` 进歌手聚合页。
- 点专辑：聆听**没有专辑详情页** → 播这张专辑这个月最常听的那首。
- 年/月 Select：年 → 该年最接近当前月的有记录月份；月 → 直接切偏移；切完回顶。
- 滚动：上滑底部页签栏收成单排（`BottomBar.notifyScrollDelta`）；标题在「回响 / 你听了什么 / 你是怎样的听众 / 有趣的发现」间切换；
  顶栏自带渐隐（`echo_top_fade*`，页签页壳层不画，避免内容与标题叠字）。

## 6. 与派音的有意差异

1. 数据口径按聆听（见 §3）。
2. 「新收藏」段**裁掉**：聆听收藏（`PlaySession.favorites`）没有时间戳，无法按月统计。
3. 标题栏：不移植 HDS，沿用壳层 `PageTitle` + `AppStorage` 标题键（`K_ECHO_TITLE`）。
4. 点专辑行为改为「播该专辑最常听那首」（无专辑详情页）。
5. `echo_placeholder_background` 已进资源但组件库未用（封面占位统一走 `CoverArt` 的占位样式）。
6. **榜台可翻页 + 动态背景**：派音 2.0 原文是静态三卡、背景为死代码（0 处 Swiper/手势）；这两项是**旧版聆听回响**的交互，
   按用户 2026-11-15 实机反馈「123 无法翻页」恢复并合并到派音版式上（视觉仍是四点透视，动画是新增的插值实现）。

## 7. 构建与验证

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
cd D:\harmony\listen
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p product=default -p module=entry@default --no-daemon assembleHap
```

已实测：整页替换后 `hvigor clean` + 全量 `assembleHap` **BUILD SUCCESSFUL**（CompileArkTS 13.4s / 总 20.5s），
产出 `entry-default-signed.hap`（约 7.78MB）；回响相关文件 0 error，告警仅「`showToast` 可能抛异常」一条（与 `MineView`/`OnlineListView` 同款既有告警）。
**真机验收仍需确认**（本机无连接设备）：3D 榜台左右留白 16vp、右卡内容非镜像、日间可读性、
滚动切标题、宽屏双列不重叠、侧卡点击热区。

## 8. 移植过程中修掉的缺陷（相对派音原实现）

| # | 缺陷 | 位置 | 处理 |
|---|---|---|---|
| 1 | `ForEach` 的 key 用固定下标 ⇒ 切月后**时段柱图 / 日历热力 / 榜单次数不刷新**（ArkUI 在 key 不变时复用节点、不重跑 builder） | 派音同款写法；本工程 `EchoMonthlyKit.ets` 4 处 | key 并入数值：`hour_<hour>_<count>`、`day_<day>_<count>`、`artist_<i>_<name>_<plays>`、`album_<i>_<name>_<plays>` |
| 2 | 同名歌手 / 同名专辑撞 `ForEach` key ⇒ 丢项 | `EchoMonthlyKit.ets` | key 带 index |
| 3 | 专辑不足 3 张时 `layoutWeight(1)` 把单张封面拉成 ~300vp 方块 | `EchoMonthlyKit.ets` `EchoTopAlbums` | 固定 3 个等宽槽位，不足补空位 |
| 4 | `CoverArt(fill:true)` + `art:true` 时黑心占位只画 `boxSize` 方块（深底里套小黑心） | `Widgets.ets` `HeartCover` | 新增 `fill` 参数（默认 false，行为不变） |
| 5 | 派音「新收藏」段缺 `time < range.end` 上界 | — | 本工程该段按契约裁掉，不复现 |
| 6 | 派音 `playCount` 因历史去重不是真实播放次数 | — | 本工程直接用 `playedMs ≥ 30s` 的流水条数，口径真实 |

## 9. 真机验收清单（本机无连接设备，交付时未做真机冒烟）

1. 夜间 / 日间页面顶部均无渐变带色差（顶栏渐隐已改用 `echo_top_fade*`，与页面底色同值）。
2. 滚动时内容被顶栏渐隐吃掉，且顶栏区域仍可正常滚动与点击（`hitTestBehavior: Transparent`）。
3. 回响点歌直连秒开；播放页与媒体中心时长显示 `m:ss` 而非 `0:00`；下月完播率正常累计。
4. 切月三连（本月→上月→回本月）：时段柱高、日历热力、榜单次数、封面全部刷新（`ForEach` key 已并入数值）。
5. 转屏 / 分屏：标题归位（宽屏固定「N 月 · 回响」）、两列各 1:1 且左右留白 16vp；空月份只剩页头 + 年月切换器 + 空态。
6. 3D 榜台：三卡左右留白均 16vp、右卡内容非镜像、点击左右卡能播对应排名的歌。
