# 心动模式（探索页推荐）技术交接文档

> 交接对象：接手改推荐算法的外部模型（GPT）
> 仓库：`D:\harmony\listen`（鸿蒙 ArkTS，HarmonyOS 6.1 / API 23 起兼容，targetSdk 26）
> 模块：`entry/src/main/ets/core/heart/` + `entry/src/main/ets/views/ExploreView.ets`
> 本文所有结论都来自**读代码 + 真机日志**，不是猜测；每一条都给了文件与行号。

---

## 一、结论摘要（先看这 8 条）

用户反馈：**推荐类型过于单一（总是「烟嗓」一类）、点喜欢或划走讨厌都没用。**

按严重度排序，已确认的根因：

| # | 根因 | 证据位置 | 影响 |
|---|---|---|---|
| 1 | **反馈状态完全不落盘**：口味向量、亲和、黑名单、曝光、会话历史全在内存，杀进程即归零 | `HeartProfile.ets`（类注释自己写着「P2 的 HeartStore 负责落盘」，该 HeartStore **不存在**） | 「划走讨厌」只在本次会话内生效，重启后等于没划过 |
| 2 | **「听完/播放/跳过」的真实时长分档是死代码**：`feedbackOf` / `feedbackWithContext` 在整个仓库**零调用** | `HeartFeedback.ets:47,66`；全局 grep 无调用点 | ListenLog 里现成的 `playedMs/durationMs` 强信号没进模型，只有 UI 事件在喂 |
| 3 | **拉黑阈值永远到不了**：同一首在一次会话里只出现一次（`shownKeys` 去重），而拉黑要求被跳过 **2 次** | `HeartTypes.ets:38`（`HEART_BLACKLIST_SKIPS=2`）、`HeartProfile.ets:240-246`、`HeartRadio.ets:373-378` | 划走一次只减一点亲和；想「这首歌再也别出现」做不到 |
| 4 | **表示层没有音色/流派特征**：向量 = 歌名（CJK 单字+bigram / 拉丁词）＋艺人（权重 3）＋专辑（权重 2）的文本哈希，无 genre、无年代、无音频 | `HeartEncoder.ets:94-140` | 「烟嗓」「民谣」「说唱」这类偏好在模型里**根本不存在**，只能靠歌名词面与同艺人撞运气 |
| 5 | **艺人权重压过一切**：艺人 token 权重 3.0，且召回里「同艺人」是最强信号 | `HeartEncoder.ets:133`（`a:` + artist，3.0） | 推荐收敛到少数几个常听艺人 → 越听越窄 |
| 6 | **候选池太单一**：只从一个平台取 3 张榜（各 40 首）+ 2 个歌单 + 2 个艺人的作品（各 20 首），上限 400 | `HeartPool.ets:26-39,219-391` | 池子本身高度同质，「烟嗓网络歌曲」在榜单里扎堆，怎么排都是它们 |
| 7 | **探索探索不起来**：ε-greedy 只有 15%，且只在**当前榜单前 30 名**里随机 | `HeartEngine.ets:183-187` | 所谓「换个口味」，本质仍是在同一簇里挑 |
| 8 | **曝光记账在「展示」而不是「播放」**：一批 20 首在出卡时就全部 +1 exposure | `HeartEngine.ets:290`（`nextBatch` 里 `recordExposure`） | UCB 的新鲜补偿被展示消耗掉，冷门歌越来越排不上来 |

一句话总结：**这不是「参数没调好」，而是三个结构性缺口**——(a) 反馈不持久、真实播放信号没接进模型；(b) 表示层没有内容特征（音色/流派）可用；(c) 候选池与探索机制不足以保证多样性。

---

## 二、系统边界与数据流

```
                  ┌─────────────── 画像（只用本地数据）───────────────┐
 ListenLog(最近200首) ─┐                                              │
 收藏 PlaySession      ├─→ HeartRadio.collectInterest() → HeartDoc[] ─┤
 本地曲库 LocalMusic  ─┘        （歌名/歌手/专辑/时长/是否收藏）        │
                                                                      ▼
 ┌──────── 候选池（全网，单平台）────────┐                 HeartEngine.setHistory()
 │ HeartPool.build(source):              │                          │
 │   榜单 3×40   歌单 2    艺人作品 2×20 │                          ▼
 │   → 去重(歌名+歌手) → 按新鲜度排序    │              ┌─ 编码（HeartEncoder）──┐
 │   → 上限 400 首 → HeartCache 落盘     │              │ 文本哈希 → IDF → L2归一 │
 └────────────────┬──────────────────────┘              └────────────┬───────────┘
                  │ SongItem[]                                       │
                  ▼                                                  ▼
           HeartRadio.applyLibrary() ──→ HeartEngine.setLibrary()（全库编码）
                                                  │
                                                  ▼
                              HeartEngine.nextBatch(20, 已展示ids)
                                 │ buildQueries(): K=2 长期兴趣(球面K-means)
                                 │                + 1 短期向量(最近10首,decay0.5)
                                 │ 打分 = 1.0·max余弦 + 0.6·口味EMA + 0.3·亲和
                                 │        + 0.45·新鲜 + 0.05·UCB + 噪声0.02
                                 │ 粗筛400 → 精排 → ε(0.15)在前30里随机
                                 ▼
                        ExploreCard[]（20 张，批内不重复、不连推同艺人）
                                 │
                                 ▼
                         ExploreView 一屏一张，下滑换下一张
                                 │
        ┌────────────────────────┴───────────────────────┐
        ▼                                                ▼
  UI 反馈（唯一的反馈入口）                     播放本身（ListenLog）
  · 起播 → FB_PLAY(+0.1)                        · 只写 ListenLog，供下次
  · 自然播完进下一张 → FB_COMPLETE(+0.3)          进页面时重建画像用
  · 下滑划走 → FB_SKIP(-0.6亲和, 口味反向0.08)   · **不实时进引擎**
  · 双击/点红心 → FB_LIKE(+0.8) + 写入收藏
                                 │
                                 ▼
                    HeartEngine.observe() → HeartProfile（纯内存，重启即失）
```

**关键事实：图片里所有 `HeartProfile` 状态（taste / affinity / blacklist / exposure / history）都只活在这个进程里。**
唯一落盘的是候选池 `heart_cache.json`（`HeartCache.ets`），不落画像。

---

## 三、模块地图

| 文件 | 行数 | 职责 | 关键导出 |
|---|---|---|---|
| `HeartTypes.ets` | 215 | 共享类型 + 全部调参常量 + 权重表 | `HEART_DIM/K/EPS/...`、`HeartDoc`、`HeartWeights`、`HeartPick`、`FB_*` |
| `HeartEncoder.ets` | 272 | 元数据 → 128 维向量（signed hashing + IDF + L2） | `tokenize()`、`HeartEncoder`、`normalizeText()`、`cosine()` |
| `HeartInterest.ets` | 229 | 多兴趣用户表示：球面 K-means(K=2) + 短期向量，max 池化 | `buildQueries()`、`sphericalKmeans()`、`bestCosine()` |
| `HeartProfile.ets` | 294 | 记账层：口味 EMA、艺人/专辑亲和、黑名单、曝光、UCB | `update()`、`effectiveTaste()`、`affinityBonus()`、`ucbBonus()` |
| `HeartEngine.ets` | 482 | 装库/编码、召回+粗筛、精排、ε 探索、`observe()` 回写 | `setLibrary/setHistory/setSeeds/nextBatch/nextTrack/observe` |
| `HeartFeedback.ets` | 76 | 按真实时长把一次收听分成 跳过/播放/听完 | `feedbackOf()`、`feedbackWithContext()` ⚠️**均无调用** |
| `HeartIdentity.ets` | 21 | 跨平台歌曲身份键 `歌名\u0001歌手` | `songKeyOf()` |
| `HeartPool.ets` | 410 | 建候选池（榜单/歌单/艺人）+ 新鲜度启发式 | `HeartPool.build()`、`boardFreshness()`、`pickBoards()` |
| `HeartRadio.ets` | 495 | 门面：画像采集、缓存、批量出歌、UI 反馈入口 | `HeartRadio`、`ExploreCard` |
| `HeartCache.ets` | 152 | 只缓存候选池 `heart_cache.json`（v1） | `load()/save()` |
| `views/ExploreView.ets` | 464 | 心动模式 UI（一屏一首、下滑换歌、双击喜欢） | 反馈触发点：`playCurrent/onSwipe/toggleFav/onCurrentChanged` |
| `entry/src/test/HeartMode.test.ets` | 11067 B | 主机单测（15 个用例，纯算法文件可直接跑） | 见第九节命令 |

---

## 四、算法细节

### 4.1 表示层（`HeartEncoder.ets`）

输入只有四个字段：`name / singer / album / durationMs`（`HeartTypes.ets:89-113` 明确写了「没有流派、年份、artistId」）。

- `normalizeText`：小写、非字母数字与非 CJK 一律变空格、压缩空格。
- 分词（`tokenize`，`HeartEncoder.ets:128`）：
  - 歌名：CJK 逐字 + 相邻 bigram（前缀 `t:`），权重 1.0；
  - 艺人：整体一个 token（`a:`），**权重 3.0**；
  - 专辑：整体一个 token（`b:`），权重 2.0。
- 编码：FNV-1a 哈希取桶 + 符号位抵消冲突 → 乘 IDF（`fit()` 在**当前库**上现算，截断 [0.2,3]）→ L2 归一。
- 相似度 = 点积（向量已归一）。

**含义**：两首歌相似 ⟺ 共享歌名字/词 或 同艺人 或 同专辑。**没有任何内容语义**，所以「烟嗓」「清冷女声」「City Pop」无法表达；反过来「夜」「情歌」「爱」这类高频字会把不相干的歌拉到一起。

### 4.2 用户表示（`HeartInterest.ets`）

- 长期：对历史向量做球面 K-means，`K=2`（`HeartTypes.ets:22`）。
- 短期：最近 `M=10` 首，权重 `0.5^(...)`（越近越大）。
- 查询 = K 个长期中心 + 1 个短期向量；打分时取 **max**（`bestCosine`）。
- 历史来源（`HeartRadio.collectInterest`，`:236-268`）：`ListenLog.recentSongs(200)` + 收藏 + **本地曲库全部**，按 `id` 去重，然后整体喂给 `setHistory`。

⚠️ 注意：本地曲库（`LocalMusic.songsForUi()`）**全部**进历史，且与 200 首播放历史等价权重 → 如果用户导入了 100 首某种风格的文件，画像会被它主导。

### 4.3 打分与排序（`HeartEngine.ets:361-384`）

```
score = 1.00·dot        (与 K+1 个查询的最大余弦)
      + 0.60·taste      (与「口味 EMA」的余弦；口味 = 0.5·EMA + 0.5·种子锚点)
      + 0.30·affinity   (艺人亲和 + 0.5·专辑亲和，截断[0,1])
      + 0.45·fresh      (新歌：addedAt 命中 30 天窗口记 1，否则用候选来源/榜内位次推断)
      + 0.05·ucb        (曝光越少给得越多)
      + noise(±0.02)    (只打散并列)
```

- 候选 > 400 时先按 `dot` 粗筛到 400 再精排（`:202-218`）。
- `ε=0.15`：有 15% 概率在**当前榜前 30 名**里随机挑一张（`:183-187`）。
- 批内（一批 20 张）不重复、不连推同一艺人（`nextBatch`，`:247-293`）。

### 4.4 反馈（当前唯一真实入口）

| 触发（`ExploreView.ets`） | 方法 | 落到引擎 | 具体效果 |
|---|---|---|---|
| 卡片起播 `playCurrent()` | `radio.played(id)` → `FB_PLAY` | `observe()` | 历史 push、`plays+1`、艺人/专辑亲和 +0.1；**不动口味向量** |
| 自动进下一张（自然播完）`onCurrentChanged` | `radio.completed(id)` → `FB_COMPLETE` | `observe()` | 亲和 +0.3、口味 EMA 半学习率(α=0.05) |
| 下滑划走 `onSwipe`（且当前卡未收藏） | `radio.dislike(id)` → `FB_SKIP` | `observe()` | 亲和 −0.6、口味反向推 0.08、`skips+1`；**不进历史** |
| 双击封面 / 红心 `toggleFav()` | `like()` / `unlike()` | `observe(FB_LIKE)` / `profile.unlike` | 写入/移除收藏；亲和 ±0.8；口味 EMA(α=0.1) |
| 播放器里收藏/取消 | `syncLikes()` | 同上 | 与收藏对账 |

`observe()`（`HeartEngine.ets:423-443`）里还有一条重要规则：**跳过的歌不进历史向量**（避免「我不想听」被当成「我在听这类」）。

### 4.5 候选池（`HeartPool.ets`）

固定四个入口（顺序即去重优先序）：
1. **榜单 3 张 × 40 首**：按榜名打分挑「最像新歌」的（新歌/飙升/抖音热歌 > 热歌/TOP500 > 经典/怀旧 > 未知），榜内位置越靠前新鲜度越高（`freshOfRank`）。
2. **推荐歌单 2 个**：在「最新/新歌/热歌」分类下取，按歌单名剔除「经典/怀旧/含早年份」的专辑盘；整盘给低新鲜度 0.15。
3. **艺人作品 2 人 × 20 首**：取画像里出现次数最多的 2 位艺人，低新鲜度 0.15。
4. （搜索入口在注释里提到，实际 `build()` 未使用）

池子上限 400，按「歌名+歌手」去重、整池按新鲜度稳定排序。
**平台只有一个**：`RecommendSettings.getSource()`（默认酷我，可在标题栏切换），**不跨平台混池**。

### 4.6 冷启动与缓存

- 进页面：`prepareCached()`（同步读 `heart_cache.json`，毫秒级出歌）→ 后台 `refresh()` 重新建池并落盘。
- 缓存命中时 `freshBoost` 不落盘，用「池内位次」近似还原（`HeartRadio.ets:39-57`）：前 25% 线性衰减。
- 缓存只有候选池；画像每次进页面从本地数据重建。

---

## 五、为什么「喜欢 / 划走讨厌」感觉没用（端到端解释）

1. **重启即失忆**（根因 1）：所有反馈记账在内存，`HeartProfile` 没有任何序列化入口；`HeartEngine` 每次 `new`（`ExploreView.ets:60` 每个页面实例一个 `HeartRadio`）。
2. **划走的作用被稀释**：一次 skip 只做三件事——艺人/专辑亲和 −0.6、口味反向 0.08、`skips+1`。而拉黑要 2 次、同一首本会话只出现一次（`shownKeys`）→ **拉黑实际上永不触发**；下次进页面重建画像，连那 −0.6 也归零。
3. **喜欢的持久路径绕了一大圈**：like 真正持久的只有「写进收藏」；下次进页面时收藏经 `collectInterest` 进历史/种子，才影响排序。而候选池**不因喜欢而扩充**（池子只由榜单/歌单/艺人入口决定），所以喜欢不会带来同类新歌。
4. **真实播放信号没接进来**：`HeartFeedback` 的分档函数零调用；`ListenLog` 的 `playedMs/durationMs`（>=85% 完播、<20% 跳过）从未实时反馈给引擎。引擎只知道「起播了」，不知道「你听了 3 秒就切了」。
5. **划走判定还依赖「是否收藏」**（`ExploreView.onSwipe`）：已收藏的歌被划走不算 dislike——可以理解，但会让「我收藏了但现在不想听」的负反馈完全丢失。

---

## 六、为什么类型单一（「总是烟嗓」）

1. **表示层里没有音色**（根因 4）：向量看不到人声质地、编曲、流派。想推「不烟嗓」的歌，模型没有任何维度可依。
2. **艺人 token 权重 3 主导相似度**（根因 5）：只要历史里有几位常听艺人，`dot` 就会被「同艺人」刷满。
3. **候选池单平台 + 三张榜**（根因 6）：热门榜/飙升榜本身同质化严重，且没有「流派均衡」约束——池子里 60% 是什么，推出来就是什么。
4. **兴趣只有 K=2 簇**（`HEART_K=2`）：用户的多类口味被压成两类，`max` 池化只会更偏向最强的那一类。
5. **探索只在头部 30 名里随机**（根因 7）：ε 探索没有真正跨出当前兴趣簇。
6. **历史里塞进了全部本地曲库**（4.2）：若本地库风格集中，会直接压偏画像。
7. **新鲜度权重 0.45** 会持续把「新歌榜」的歌往前推，而新歌榜在中文平台里恰恰常被网络歌曲/烟嗓类占据（`HeartTypes.ets:134-142` 的注释已预判过这个风险）。

---

## 七、建议改造方向（给 GPT 的实施清单）

> 目标（按用户预期）：**划走要真的不再出现；喜欢要真的带来同类新歌；推荐要能「换口味」而不是同簇微调。**

### P0（必须先做，否则调参无意义）

**P0-1 把反馈画像落盘**
- 新增 `HeartStore`（沙盒 JSON，形如 `heart_profile.json`，带 version）：
  - 落盘：`taste`（Float32Array → number[]）、`artistAff`、`albumAff`、`skips`、`blacklist`、`exposure`、`steps`、`recentObserved`（跨会话的最近 N 首 id/身份键，用于去重与拉黑计数）。
  - 时机：`observe()` 之后节流落盘（如 2s 防抖）+ 页面退出/`onPageHide` + `EntryAbility.onBackground`。
  - 载入：`HeartRadio` 构造或 `prepareCached()` 时读回，`HeartProfile` 需要新增 `restore(state)` / `serialize()`。
- 验收：划走一首 → 杀进程 → 重进探索页 → 该歌不再出现；日志打印 `heart store restored: steps=N blacklist=M`。
- 注意：ArkTS 无 `Float32Array` 直接 JSON 序列化，需 `Array.from()`/手写数组；文件读写参考 `HeartCache.ets` 与 `ListenLog`。

**P0-2 接上真实播放信号**
- 在播放器/ListenTracker 收尾处（切歌、退后台、销毁前）调用 `feedbackWithContext(playedMs, durationMs, liked, recentPlays)`，把结果交给当前 `HeartRadio` 实例（需要单例或事件总线——现在 `ExploreView` 里是 `new HeartRadio()`，**必须改成单例**，否则播放器拿不到同一个实例）。
- 修正 `ExploreView` 的反馈口径：
  - 起播不要立刻记 `FB_PLAY`（那是「我点了」不是「我在听」）；改为真实时长分档；
  - 已收藏的歌被划走也应产生一个弱负反馈（例如 `FB_PLAY` 的撤销或单独的 `FB_UNINTERESTED`），由产品确认。
- 验收：听 3 秒切走 → 日志出现 `feedback skip`，且该艺人亲和下降。

**P0-3 让「划走」真的能封禁**
- 拉黑阈值改成 **1 次**（或「同一艺人连续划走 2 次 → 该艺人降权」），并与 P0-1 的持久化配合。
- 增加「不想听这个艺人」的入口（长按/菜单），比只封单曲有效得多。
- 验收：划走一次后该歌在同会话不再出现；重启后仍不出现。

### P1（多样性）

**P1-1 跨平台混池**：`RecommendSettings` 只有一个 source；建议建池时并行取 2~3 个平台的榜（同一首歌按身份去重），池子天然更多样。注意并发请求与超时，参考 `HeartPool.build` 的 try/catch 风格。

**P1-2 流派/风格维度的替代信号**（没有 genre 字段的现状下）：
- 用**歌单名/榜单名**当弱标签：把候选按来源入口打上 `styleHint`（如「抖音热歌」「经典老歌」），在打分里加「与用户历史来源分布的 KL 惩罚」；
- 或在编码器里给歌名加 **IDF 之外的主题词典**（小词表：烟嗓/民谣/说唱/古风/电音…命中即加分/减分）；
- 更好但更重：用外部模型离线给曲目打风格标签（需要网络与存储，超出当前端侧约束）。

**P1-3 提高探索强度并做「换一批」按钮**：
- `ε` 从 0.15 提到 0.25~0.3，随机范围从「前 30」扩到「跨簇」（例如从 `dot` 最低但 `fresh` 高的 20% 里挑）；
- UI 加「换一批」/「换个口味」入口（现在只有下拉换一批，且换的是同一排序的下 20 首）。

**P1-4 曝光记账移到播放时**：`recordExposure` 从 `nextBatch` 移到 `observe(FB_PLAY/FB_COMPLETE)`，让 UCB 表达「真的被听过几次」。

**P1-5 候选池加入流派均衡约束**：建池后按来源/艺人聚合，限制单一艺人/单一入口占比（例如任一艺人 ≤ 3 首、任一入口 ≤ 50%），并保证至少 N 个不同「来源入口」的代表。

### P2（表示层升级，工作量大，先别动）

- 音频特征（BPM、能量、音色）在鸿蒙端**拿不到 PCM**（`HeartEncoder` 注释已否定），只能在服务端/离线做；
- 文本塔换更强的 embedding 需要模型文件与推理，当前架构刻意零依赖，除非明确允许引入。

---

## 八、硬约束与坑（改之前必读）

1. **纯算法文件不许 import `@kit.*`**：`HeartTypes / HeartEncoder / HeartInterest / HeartProfile / HeartEngine / HeartFeedback / HeartIdentity` 必须保持零依赖，否则 `entry/src/test` 的主机单测跑不起来（项目约定，见 `HeartTypes.ets:13-16`）。
2. **ArkTS 限制**：不允许匿名对象字面量当类型（要建 class）、`Float32Array` 不能直接 JSON、`Map.forEach` 顺序不保证（别依赖）。
3. **单例问题**：`ExploreView.ets:60` 是 `private radio: HeartRadio = new HeartRadio()`（每实例一份）。要做「播放器 → 推荐」的实时反馈，必须把 `HeartRadio` 改成单例（`getInstance()`），并注意页面销毁时不要 `reset()` 掉全局状态。
4. **缓存格式有版本号**：`HeartCache.CACHE_VERSION=1`、`RecommendSettings.SETTINGS_VERSION=1`；改结构必须 +1 并写迁移或直接丢弃。
5. **性能预算**：全库编码对 400 首 < 100ms；`scoreBoard` 粗筛 400 后精排。若把池子扩到上千首，注意 `nextBatch` 内 `candidates()` 每次全量遍历 + 排序的耗时。
6. **不要动播放链路**：`SongItem` 是播放队列形状接口，加字段会波及落盘/同步；新鲜度等推荐专用信息一律走 `HeartDoc`（`HeartPool.ets:189-205` 有先例）。
7. **UI 触点固定**：`ExploreView` 的 4 个反馈点（起播/划走/双击喜欢/自然播完）是唯一入口；改口径就在这里改。
8. **日志**：`hilog` DOMAIN `0x0001`；推荐相关 TAG：`HeartPool`（池子汇总一行）、`HeartRadio`、`HeartEngine`、`SourceRouter` 等。池子汇总日志示例：`池子 N 首｜榜单 a 首｜歌单 b 首｜艺人 c 首｜平均新鲜度 x.xx`。

---

## 九、交接清单

**先读**（按顺序）：
1. `HeartTypes.ets`（常量与权重表，决定手感）
2. `HeartEncoder.ets`（表示层——决定「像不像」）
3. `HeartEngine.ets:361-384`（打分公式）
4. `HeartProfile.ets:150-216`（反馈怎么改画像）
5. `HeartRadio.ets:236-268, 396-487`（画像采集与反馈入口）
6. `ExploreView.ets:101-241, 252-272`（UI 触发点）

**建议按此顺序改**：P0-1 落盘 → P0-2 真实信号 → P0-3 拉黑 → P1-4 曝光 → P1-1 混池 → P1-3 探索 → P1-5 均衡 → P1-2 风格信号。

**验证方式**：
- 主机单测（hypium，纯算法、秒级）：用例在 `entry/src/test/HeartMode.test.ets`（15 个），
  在 DevEco 里直接跑该测试类，或用 `hvigorw test`（具体入口以项目既有配置为准，
  见 `docs/UI_REPLICA.md` 关于 `entry/src/test` 与 `entry/src/ohosTest` 的说明）。
  新增画像/落盘/拉黑逻辑请补用例（注意用 `HeartOptions.seed` 固定随机，保证可复现）。
- 真机：`hdc` 装包 → 探索页划 5 首 → 杀进程 → 重进 → 检查日志 `heart store restored` 与「同一首不再出现」；再看 `HeartPool` 汇总行确认池子构成。

**验收标准（产品口径）**：
1. 连续划走 3 首同类型歌后，第 4 首不再是同类型/同艺人（可人工判断）；
2. 双击喜欢 3 首同类歌后，后续能出现同类**新歌**（不是收藏过的那几首）；
3. 杀进程重启后上面两条依然成立；
4. 推荐理由（卡片底部小字）与实际打分明细一致（`HeartPick.explain()` 已在用真实分项）。

---

## 十、附录

### 10.1 关键常量（`HeartTypes.ets`）

| 常量 | 值 | 含义 / 备注 |
|---|---|---|
| `HEART_DIM` | 128 | 向量维度（64/128/256 实测饱和点） |
| `HEART_K` | 2 | 长期兴趣簇数（仓库实测 K=1~2 最准，牺牲多样性） |
| `HEART_SHORT_M` / `HEART_SHORT_DECAY` | 10 / 0.5 | 短期窗口与衰减 |
| `HEART_EPS` | 0.15 | ε 探索比例 |
| `HEART_NOISE` | 0.02 | 打散抖动 |
| `HEART_EXCLUDE_ARTISTS` / `HEART_EXCLUDE_RECENT` | 3 / 6 | 最近 N 艺人/曲目不进候选 |
| `HEART_BLACKLIST_SKIPS` | 2 | 跳几次拉黑（**当前实际永不触发**） |
| `HEART_FRESH_DAYS` | 30 | 新歌窗口 |
| `HEART_HISTORY_MAX` | 500 | 历史向量上限 |
| `TASTE_ALPHA` / `ANCHOR_BLEND` / `SKIP_PUSH` | 0.1 / 0.5 / 0.08 | 口味学习率 / 种子锚点 / 跳过反向推 |
| 权重 | dot 1.0 / taste 0.6 / affinity 0.3 / fresh 0.45 / ucb 0.05 | 线性加权 |
| 池子 | 3 榜×40 + 2 歌单 + 2 艺人×20，上限 400 | `HeartPool.ets:26-39` |

### 10.2 反馈分档口径（`HeartFeedback.ets`，待接上）

| 条件 | 档位 | 数值 |
|---|---|---|
| 已收藏 | `FB_LIKE` | 3 |
| 近 7 天播放 ≥3 次 | `FB_REPEAT` | 4 |
| 播放 <30s 或完播率 <20% | `FB_SKIP` | 0 |
| 完播率 ≥85% | `FB_COMPLETE` | 2 |
| 其余 | `FB_PLAY` | 1 |

### 10.3 一句话给 GPT 的起点

> 请在 `core/heart/` 内实现：①`HeartStore` 持久化画像与拉黑（P0）；②把 `feedbackWithContext` 接到真实播放收尾并让 `HeartRadio` 成为单例（P0）；③划走一次即拉黑（P0）；④曝光记账改到播放时（P1）；⑤候选池跨平台混池并加「单一艺人/入口占比」约束（P1）。保持纯算法文件零 `@kit` 依赖，并按第九节的验收标准补主机单测。
