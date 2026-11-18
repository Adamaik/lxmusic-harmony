# 多音源自动切换（Source Failover）设计与实现

> 目标：用户配了多个音源时，第一个源放不了就自动换下一个；而且**下一首同平台的歌不再等第一个源超时**。
> 代码：`core/source/SourceRouter.ets`（新增）、`core/source/SourceEngine.ets`、`core/player/PlaySession.ets`、`core/settings/PlaySettings.ets`、`views/SourceSettingsView.ets`

---

## 一、问题现象（用户原话）

1. 「配了许多个音源，第一首音源无法播放时，往往不会自动切换到后面的音源」；
2. 「或者第一个音源无法播放时，自动切换到第二个。但是再播下一个同平台的歌时，又会卡半天，等第一个音源超时，然后再请求第二个」。

## 二、根本原因

| 环节 | 改动前的行为 | 造成的现象 |
|---|---|---|
| 音源加载 | 沙箱（一个 WebView）里**同一时刻只挂载一个**源脚本，`loadedSourceId` 只有一个 | 只有「当前音源」会参与解析，别的源根本不会被试 |
| 解析链路 | 只问当前这一个源，失败后再走「换平台 / 报错」 | 第一个源不行 = 整首失败，或只能靠换平台兜底 |
| 请求超时 | 单次解析上限 **60 秒**（`SourceEngine.REQUEST_TIMEOUT`），HTTP 默认 13 秒 | 源卡住时用户干等，最坏一分钟没声音 |
| 失败记忆 | 只有「平台级」冷却（`PlatformHealth`，键是 `音源id::平台`） | 能跳过坏平台，但跳过之后没别的源可用，也没记住「哪个源好用」 |

一句话：**没有「源」这一维度的调度**——只有「平台」维度，而用户手里多的是源。

## 三、算法

### 3.1 路由表：记住「哪个源在哪个平台靠谱」

`SourceRouter` 维护两张表，落在 `filesDir/lx_sources/source_router.json`：

- `routes[平台] = [{id, lastOkAt, failStreak, lastFailAt, lastError}, ...]`
- `caps[音源id] = [它声明了 musicUrl 的平台]`、`names[音源id] = 名字`

候选顺序（`candidates()`）分五段，越前越先试：

```
1. 可信段：该平台成功过且 failStreak < 2  → 按 (失败次数升序, 最近成功降序)
2. 当前已加载的源（若它确实支持这个平台）     → 省掉一次换源加载
3. 降级段：failStreak ≥ 2                  → 按最近失败时间升序（久没失败的先试）
4. 能力已知（声明支持该平台）但还没有历史结论的源
5. 能力未知（从没加载过）的源                → 排最后，加载后即知道它支不支持
```

已知**不支持**该平台的源直接不列（否则每个都要白加载一次脚本）。

### 3.2 单次解析：短预算 + 按次中止

`PlaySession.resolveWithSourceFailover()` 按候选顺序逐个试：

```
候选数 > 1 ：第一个 7s，之后每个 5s，总计 15s 预算
候选数 = 1 ：单次 25s（没有「换人」余地，不能把慢但能成功的解析判死）
```

- 超时由 `SourceEngine.getMusicUrl(..., timeoutMs)` 承担；到点不仅拒绝等待，还会
  `abortNativesOf(解析key)` —— 把**这次解析名下发起的原生 HTTP 请求**一起 abort
  （靠「原生请求 key → 归属的解析 key」的归属表实现），避免后台还在跑、迟到的回调回灌到新沙箱。
- 每个候选前先看冷却表：`PlatformHealth.isCooling(源, 平台)` 命中就跳过，不发那个必败的请求。
- 成功 → `PlatformHealth.markSuccess` + `SourceRouter.markSuccess`（回到队首，**立刻粘住**）；
  失败 → 两个表都记一笔（冷却时长由失败类型决定，见 `PlatformHealth`），继续下一个。

### 3.3 自愈（用户特别点到的三种异常）

| 异常 | 处理 |
|---|---|
| 用户**删掉了**某个源 | `SourceEngine.removeSource()` 立刻 `router.forget([id])`；启动时 `router.init()` 还会拿当前真实音源列表 `purge()` 一遍，指向已删源的记忆全部丢弃 |
| 用户**重新导入/覆盖**了源脚本 | 内容变了（`isSameScript` 为 false）就 `forget([id])`：脚本换了等于换了一套后端，能力与成功记录都作废 |
| 某个源**今天**打不通这个平台 | 连败 2 次 → 降级到队尾（仍会试，成功后立刻回首位）；失败超过 30 分钟 → 计数衰减归零，重新给一次公平机会。冷却表本身按失败类型给 30 分钟 / 5 分钟 / 2 分钟 |

### 3.4 预取的特殊处理

后台预取**不换源**：

- 若路由表说这个平台首选另一个源（`preferredFor() != 当前源`），预取直接跳过并记日志。
  换源要重新注入脚本，会打断正在播放的这次会话，不值得为「还没轮到的歌」冒险；
  等真切到这首时，播放链路会一次性把源切好，之后预取照常工作。
- 预取自身也给 8 秒预算，避免一个卡住的源长时间占着沙箱。

### 3.5 兜底

候选全部失败时：先 `restoreLoadedSource(previousId)` 把原来那个源加载回来
（`loadSource` 中途失败会把引擎停在「未初始化」，不恢复的话用户接下来连别的平台都放不了），
再把最后一个错误抛给上层 —— 上层照旧走「换平台」（`switchSourceAndResolve`）或报错。
所以**关掉开关**（`PlaySettings.isAutoSourceSwitch() == false`）时，行为与改动前完全一致。

## 四、开关与观测

- 设置 → 音源设置 → **多音源 / 自动切换音源**（默认开）。
- 日志关键字（`hilog` tag = `PlaySession` / `SourceEngine` / `SourceRouter`）：

| 关键字 | 含义 |
|---|---|
| `source %s failed on %s` | 某个源在该平台解析失败，已记账 |
| `skip cooling source %s on %s` | 冷却中，直接跳过 |
| `switch source for playback: %s` | 为播放换源（状态行会显示「正在切换到音源「X」…」） |
| `source failover budget exhausted` | 15 秒预算用完，停止换源 |
| `restored previous source after failed failover` | 全失败后已恢复原源 |
| `prefetch skipped: preferred source is %s` | 预取因首选源不同而跳过 |
| `mark failure: %s/%s streak=%d` | 路由表记一次失败 |

## 五、取舍（为什么不是别的做法）

1. **不为每个源常驻一个沙箱**：一个源脚本几 MB、一个 WebView 沙箱，内存吃不消；改成「按需加载 + 记忆」，稳定期只付一次加载成本。
2. **不做并行竞速（谁先返回用谁）**：沙箱是单线程的，注入两个脚本本身就会互相打断；而且并行请求会让「同一个 key 的回调归属」变得不可判。
3. **单源不放短超时**：慢≠坏。多源时才值得为「换人」牺牲一次可能成功的解析。
4. **预取不主动换源**：宁可慢一首，也不要为了预取打断正在放的这一首。

## 六、验证清单

- [ ] 两个源，A 对 tx 不可用（如回 403）、B 可用：播放 tx 歌 → 自动切到 B 并出声，日志出现 `switch source for playback: B`；
- [ ] 紧接着播第二首 tx：**不再调用 A**（日志无 A 的失败行，`resolve` 明显变短）；
- [ ] 把 B 删掉后播第三首：不出现对 B 的任何请求（启动 `purge` / 删源 `forget`）；
- [ ] 关掉「自动切换音源」：行为与 1.0.8 之前一致（只问当前加载的源）；
- [ ] 单源 + 慢源（解析 10 秒以上）：仍然能成功（25 秒预算）；
- [ ] 源脚本损坏：加载失败后其余平台仍可播放（`restored previous source`）。

## 七、未做（后续可选）

- 冷启动时**预热**首选源（现在首个 tx 歌仍需一次换源加载，约 1–2 秒）；
- 界面展示「每个平台当前用哪个源」（现在只在日志里）；
- 源脚本自身的 `qualitys` 差异联动（某平台只有 A 支持母带时，优先 A）。
