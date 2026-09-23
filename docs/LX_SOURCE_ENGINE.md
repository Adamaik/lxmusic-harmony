# 洛雪音乐源引擎 · HarmonyOS 移植说明

本文说明洛雪音乐「自定义音源（源规则）」核心引擎在原工程中的位置，以及它被移植到本
HarmonyOS 工程（`listen`）后的实现结构、对外 API 和测试方法。

---

## 1. 洛雪原工程里的核心引擎

洛雪的自定义音源是一个**用 JS 写的规则脚本**，因此引擎要做两件事：

1. **导入/解析源**：读取脚本头部的 `@name/@version/...` 元信息并存起来；
2. **执行源规则**：把脚本放进一个 JS 沙箱跑起来，暴露 `lx` API，脚本通过
   `lx.on('request', handler)` 注册处理器；宿主用 `request` action 问它要某个
   `musicInfo` 的播放链接，脚本用 `lx.request` 发网络请求、解析响应，最终返回 URL。

对应的关键文件（均在 `lx-music-mobile/` 下）：

| 职责 | 文件 |
| --- | --- |
| 导入源：解析头部注释、生成 id、落库 | `src/utils/data.ts`（`INFO_NAMES` 526、`matchInfo` 534、`addUserApi` 554） |
| 在线导入源（按链接下载脚本） | `src/screens/Home/Views/Setting/settings/Basic/UserApiEditModal/ScriptImportOnline.tsx` |
| 管理源：加载/销毁/状态 | `src/core/userApi.ts`（`setUserApi` 7、`importUserApi` 30） |
| 切换音源 → 生成各平台 apis | `src/core/apiSource.ts`（20） |
| 桥接层：init / request / response / log | `src/core/init/userApi/index.ts`（`handleStateChange` 74、`getMusicUrl` 封装 88、事件分发 215） |
| 原生模块 JS 封装 | `src/utils/nativeModules/userApi.ts`（`loadScript` 6、`sendAction` 33） |
| **JS 沙箱（QuickJS）** | `android/app/src/main/java/cn/toside/music/mobile/userApi/{QuickJS,UserApiModule,JavaScriptThread,JsHandler}.java` |
| **沙箱内的 `lx` API（引擎核心）** | `android/app/src/main/assets/script/user-api-preload.js` |
| 取播放链接的主链路 | `src/core/music/utils.ts`（`handleGetOnlineMusicUrl` 286、`getOnlineOtherSourceMusicUrl` 232）→ `src/core/music/online.ts`（`getMusicUrl` 42） |
| 自定义源在 `musicSdk` 里的分发 | `src/utils/musicSdk/api-source.js`（`apis()` 49，`/^user_api/` 走 `global.lx.apis`） |

### 引擎工作流程

```
① 导入源
   addUserApi(script)
     ├─ 正则取出开头 /* ... *\/ 注释块
     ├─ matchInfo() 解析 @name/@description/@version/@author/@homepage
     └─ 生成 id = user_api_<rand>_<ts>，脚本正文与元信息分别持久化

② 加载源（初始化沙箱）
   setUserApi(id) -> loadScript()
     ├─ 新建 QuickJSContext，evaluate(user-api-preload.js)
     ├─ preload 构造 globalThis.lx（request / send / on / utils）
     └─ evaluate(源脚本)
          ├─ 脚本 lx.on('request', handler) 注册处理器
          └─ 脚本 lx.send('inited', { sources: {...} }) 声明平台与音质
             -> handleInit() 过滤出 { source: { type, actions, qualitys } }
             -> 回传 init 事件，宿主得到 global.lx.apis / qualityList

③ 解析播放链接（核心）
   getMusicUrl(musicInfo, quality)
     -> handleGetOnlineMusicUrl()
        -> musicSdk[source].getMusicUrl(toOldMusicInfo(musicInfo), quality)
           -> 自定义源：global.lx.apis[source].getMusicUrl(...)
              -> sendUserApiRequest({ source, action:'musicUrl', info:{type, musicInfo} })
                 -> 原生 callJS('request', payload)
                    -> preload handleRequest()
                       -> 脚本 handler({source, action, info}) 按源规则请求并解析
                          -> lx.request(url, opts, cb)  ← 网络由原生代理（fetch）
                          -> resolve('https://...mp3')
                       -> 校验 /^https?:/ 后回传 response
                    -> 宿主 resolve -> { type, url }
```

---

## 2. HarmonyOS 侧的实现

HarmonyOS 没有可直接调用的通用 JS 引擎，所以沙箱改用 **ArkWeb** 承载同一套 preload 引擎；
`lx.request` 产生的网络请求由 ArkTS 用 `@ohos.net.http` 代理。整体是「沙箱 + 宿主代理网络」
的同一架构。

| 文件 | 职责 | 对应洛雪 |
| --- | --- | --- |
| `entry/src/main/resources/rawfile/lx_utils.js` | 纯 JS 工具：md5 / base64 / buffer / AES-128-CBC / AES-128-ECB / RSA-NoPadding | 原生 `__lx_native_call__utils_*` |
| `entry/src/main/resources/rawfile/lx_preload.js` | 沙箱内 `lx` API：`request/send/on/utils/currentScriptInfo`，事件与校验逻辑 | `user-api-preload.js` |
| `entry/src/main/resources/rawfile/lx_host.html` | 空白宿主页 | — |
| `entry/src/main/resources/rawfile/demo_source.js` | 离线示例源（不联网，返回固定地址） | — |
| `entry/src/main/resources/rawfile/demo_source_http.js` | 走 `lx.request` 的示例源 | — |
| `entry/src/main/ets/core/source/LxTypes.ets` | 类型定义 | `LX.UserApi.*` |
| `entry/src/main/ets/core/source/LxMetadata.ets` | 头部注释解析、id 生成 | `data.ts` 的 `matchInfo/addUserApi` |
| `entry/src/main/ets/core/source/LxHttp.ets` | 网络代理（默认 UA、Content-Type 推断、JSON 自动解析、form/formData、binary） | `core/init/userApi/request.js` |
| `entry/src/main/ets/core/source/SourceStore.ets` | 音源持久化（索引 JSON + 脚本正文文件） | `utils/data.ts` |
| `entry/src/main/ets/core/source/SourceEngine.ets` | **核心引擎**：导入 / 加载 / 初始化 / `getMusicUrl` / 桥接消息 | `core/userApi.ts` + `core/init/userApi/index.ts` |
| `entry/src/main/ets/core/source/SourceTest.ets` | 测试方法集合（含「导入→搜索→解析」一站式） | — |
| `entry/src/main/ets/core/music/LxCrypto.ets` | 纯 ArkTS MD5（宿主侧咪咕接口签名用） | `react-native-quick-md5` |
| `entry/src/main/ets/core/music/MusicSearch.ets` | 内置搜索：酷我 / 酷狗 / 咪咕 | `src/utils/musicSdk/{kw,kg,mg}/musicSearch.js` |
| `entry/src/main/ets/core/music/PlatformHttp.ets` | 平台接口的 JSON / 文本请求小工具（歌词与评论共用） | `src/utils/request.js` 的那层封装 |
| `entry/src/main/ets/core/music/PlatformComment.ets` | 内置平台评论（kw/kg/tx/mg/wy） | `src/utils/musicSdk/*/comment.js` |
| `entry/src/main/ets/core/player/LxPlayer.ets` | 播放器封装（AVPlayer） | `react-native-track-player` |
| `entry/src/main/ets/components/SourceSandboxHost.ets` | 沙箱宿主（1x1 透明 Web + `javaScriptProxy` 桥） | `QuickJS.java` + `UserApiModule.java` |
| `entry/src/main/ets/pages/Index.ets` | 测试页面 | — |
| `tools/lx_engine_selftest.js` | 无设备 Node 自检脚本 | — |

### 沙箱与宿主的消息契约

```
ArkTS -> 沙箱（WebviewController.runJavaScript 注入）
  window.__lx_bootstrap__ = { key, rawScript, env, meta }   // 注入后引擎自删
  window.__lx_native__(key, action, dataJson)
      action: 'request'   // 宿主发起一次 musicUrl / lyric 解析
              'response'  // 宿主把 HTTP 响应回灌给沙箱里的 lx.request 回调

沙箱 -> ArkTS（javaScriptProxy: window.lxBridge.postMessage）
  action: 'init' | 'request' | 'cancelRequest' | 'response' | 'showUpdateAlert' | 'log' | 'scriptError' | 'probe'
```

`action: 'request'` 是**双向**的：沙箱 → 宿主要网络访问，宿主 → 沙箱要解析结果。

> **坑 1：`javaScriptProxy` 只暴露对象的自有属性。**
> 桥对象必须写成「对象字面量 + 自有属性」（见 `SourceSandboxHost.ets` 的 `LxBridgeObject`）。
> 如果写成 `class LxBridge { postMessage() {} }`，方法在 prototype 上，
> 沙箱里 `lxBridge.postMessage` 是 undefined，`lx.send('inited')` 的回传会静默失败，
> 最终只表现为「音源初始化超时」，极难排查。

> **坑 2：`registerJavaScriptProxy` 注册的对象要等页面下次 (re)load 才生效**
> （SDK 文档明确写了 "Registed objects will not appear in JavaScript until the page is next (re)load"）。
> 因此沙箱宿主页**只在启动时加载一次，之后换源走「页面内重置」而不是 `refresh()`**：
> `__lx_destroy__()` 清掉上一个源的状态，再重新注入 preload，源脚本用 IIFE 包裹保证作用域隔离。
> 频繁 reload 会让桥接状态变得不确定。
>
> 同时 `postMessage` 同时登记在 `methodList` 与 `asyncMethodList` 里 —— 文档说明同一方法同时出现在
> 两个列表时按**异步方法**处理，而我们的回调本来就是单向通知（无返回值），异步方式更稳。

> **坑 3：宿主必须实现 `action: 'request'` 分支，否则「几乎所有音源都超时」。**
> 沙箱里的 `lx.request(url, options, cb)` 会以 `{requestKey, url, options}` 回调宿主，
> 宿主请求完再把 `{requestKey, error, response}` 回灌沙箱的 `requestQueue`。
> 这条链路缺任何一环，源脚本的 `musicUrl` handler 的 Promise 就永远不 resolve，
> 表现是**导入/初始化都正常**（`lx.send('inited')` 不需要网络），
> 但一播放就「音源响应超时」——尤其是「代理型」音源（脚本本身只负责再请求一个中转 API）。
> `tools/lx_engine_selftest.js` 里的「桥接分支覆盖度」用例专门守这条：
> 它会比对 preload 能发出的 action 集合与 `handleBridgeMessage` 实际处理的分支集合，
> 少一个就报错（这个用例正是为了补上漏掉的 `request` 分支而加的）。
>
> 注意 `cancelRequest` 的负载是**裸字符串**（`nativeCall(action, requestKey)` 经 `JSON.stringify`
> 后形如 `"0.123"`），不是对象，别按对象解析。

> **桥接自检**：注入引擎后会做一次 `probeBridge()`（ArkTS → 沙箱 → ArkTS）。
> `window.lxBridge` 缺失或消息送不到宿主会立刻抛出明确错误；
> 若首次自检失败，会按官方建议「显式 registerJavaScriptProxy + reload」再试一次，
> 成功后记录日志「桥接在显式注册并 reload 后可用」。

### lx.env 兼容模式

沙箱内 `lx.env` 由宿主配置（`SourceEngine.setSandboxEnv('mobile' | 'desktop')`，页面有「切换兼容模式」按钮）。
默认 `mobile`；部分桌面版源包只在 `lx.env === 'desktop'` 时才 `lx.send('inited')`，
遇到这类源可切到 desktop 后重新「导入并加载」。

### 脚本加载失败时怎么定位

ArkWeb 的 `runJavaScript` 有个坑：**脚本执行失败时返回 `null`，而不是 reject**
（SDK 文档："If the JavaScript script fails to execute or has no return value, null will be returned."）。
所以「脚本跑挂了」和「脚本跑完了但没 init」在宿主侧看起来一模一样。

为此引擎做了三件事：

1. 沙箱内提供 `__lx_debug_state__()`，回报 `{ hasHandler, inited, sendCalls, requestCount, scriptLength, env }`；
   `loadSource` 在**初始化超时的错误信息里直接带上这份状态**，并写进日志：
   - `hasHandler=false` → 脚本根本没跑起来（格式不对 / 被截断 / 执行失败）；
   - `hasHandler=true` 但 `sendCalls` 里没有 `inited` → 脚本自己没走到初始化（常见于 `lx.env` 判断）。
2. 如果脚本执行后没有注册 `request` 处理器，会自动改用
   **`runJavaScriptExt(ArrayBuffer)`**（API 12+ 支持传字节）重新注入一次并复检——
   大脚本用字符串注入更容易失败，这是官方给大脚本留的通道。
3. 日志里会打印**脚本长度 + 头部 160 字 + 尾部 160 字**，一眼就能看出它是不是标准的洛雪源脚本。

---

## 3. 接入方式（三步）

页面里放一个沙箱宿主，然后调用 `SourceEngine` 单例：

```ts
import { SourceEngine } from '../core/source/SourceEngine';
import { SourceSandboxHost } from '../components/SourceSandboxHost';

// 0. 页面 UI 树中挂载（1x1 透明，负责给引擎提供 JS 沙箱）
SourceSandboxHost()

// 1. 导入源（脚本正文 或 链接）
const engine = SourceEngine.getInstance();
const info = await engine.importFromUrl('https://example.com/my-source.js');
// 或者：const info = engine.importSource(scriptText);

// 2. 加载并初始化源（拿到它声明的平台与音质）
const supported = await engine.loadSource(info.id);
// supported = { kw: { type:'music', actions:['musicUrl'], qualitys:['128k','320k',...] }, ... }

// 3. 解析某个音乐的播放链接
const musicInfoJson = JSON.stringify({
  name: '歌曲名', singer: '歌手', source: 'kw', songmid: 'kw_xxx',
  interval: '03:45', albumName: '专辑', img: '', albumId: '',
  meta: { /* 平台相关字段（hash/strMediaMid 等） */ },
});
const playUrl = await engine.getMusicUrl(musicInfoJson, '320k', 'kw');
```

其它 API：`listSources()`、`removeSource(id)`、`getLyric(musicInfoJson, source)`、
`getStatus()`、`isInited()`、`setLogListener(fn)`。

### 完整流程：URL 导入源 → 搜索 → 播放

注意洛雪的自定义源协议里**没有搜索**（`user-api-preload.js` 的 `supportActions` 只有
`musicUrl`/`lyric`/`pic`）。洛雪的搜索来自内置平台 SDK，所以这里把 kw/kg/mg 的搜索也移植到了
宿主侧（`MusicSearch.ets`），搜索得到 musicInfo 后再交给导入的源规则去解析播放链接。

```ts
import { searchMusic, pickQuality, isSearchSupported } from '../core/music/MusicSearch';
import { LxPlayer } from '../core/player/LxPlayer';

const engine = SourceEngine.getInstance();

// 1. 通过链接导入源并初始化
const info = await engine.importFromUrl('https://example.com/lx-source.js');
const supported = await engine.loadSource(info.id);          // { kw: {...}, kg: {...}, ... }

// 2. 搜索（平台需既在源声明里、又被内置搜索支持）
const platform = Object.keys(supported).find(k => isSearchSupported(k)) ?? 'kw';
const results = await searchMusic('晴天', platform, 1, 30);   // LxMusicInfo[]

// 3. 按源声明 + 曲目可用音质挑一个音质，再用源规则解析播放链接
const item = results[0];
const quality = pickQuality('320k', supported[platform].qualitys, item);
const url = await engine.getMusicUrl(JSON.stringify(item), quality, item.source);

// 4. 播放
await LxPlayer.getInstance().playUrl(url);
```

#### 宿主侧播放链路的五个关键点

1. **没有 musicInfo 的条目要先补搜索。** 条目可能来自当前音源脚本不支持的平台
   （`musicInfo` 补不上），`PlaySession.playAt()` 遇到这种条目会走 `ensurePlayable()` →
   `resolveItem()`：在「当前源声明的平台 ∩ 内置搜索支持的平台」上按 `歌名 + 歌手` 搜一次，
   取最像的一条（先全等，再去掉空格/括号后包含匹配），转成带 musicInfo 的 `SongItem`
   替换队列里这一条。少了这一步就是「点了播放没声音」。
2. **音质要和源协商。** 设置里选的播放音质源不一定支持，`negotiateQuality()` 在
   「`supported[platform].qualitys`」∩「该曲目的 `_types`」里按 flac24bit → 128k
   从高到低挑一个。`pickQuality()`（`MusicSearch.ets`）只从 320k 往下找，曲目缺
   128k 时会返回源并不支持的 128k，所以播放链路用自己这版更宽松的协商。
3. **状态 / 进度必须由 AVPlayer 驱动。** `LxPlayer` 支持多路订阅：
   `addStateListener` / `addTimeListener`（`timeUpdate`、`durationUpdate`）/
   `addCompletionListener`（`stateChange` 到 `completed`）。`PlaySession.wirePlayer()`
   把它们接到 AppStorage 的 `K_PLAYER_STATUS` / `K_PROGRESS` / `K_DURATION`；播放页
   进度条拖动走 `PlaySession.seek()` → `AVPlayer.seek()`。另外设了
   `audioRendererInfo = { usage: STREAM_USAGE_MUSIC, rendererFlags: 0 }`（只能在 idle 态、
   `prepare()` 之前设），否则部分设备落到系统提示音通道，听感同样是「没声音」。
4. **切歌先停旧歌，界面不「先变后执行」。** `playAt()` 的第一件事是
   `await LxPlayer.release()` 把上一首停掉、进度归零、清掉旧歌词，再去解析新歌；
   期间状态是 `loading`，播放页与迷你栏显示转圈，进度条冻结且不可拖，只有 AVPlayer
   真的进到 `playing` 才显示播放中、进度才开始走。`toggle()` 也不再自己写
   「已暂停/正在播放」，一切以 AVPlayer 的 `stateChange` 为准。
   每次切歌领一个 `playToken`，解析要几秒，期间用户又点了别的歌就丢弃旧链路
   （否则晚回来的旧结果会把新歌覆盖掉）。
5. **封面与歌词都是异步补的，不挡出声。** 解析出 musicInfo 后立刻起两条旁路：
   `loadCover()` 与 `loadLyric()`，各自回来再回填（见下节）。

#### 封面

搜索结果里 tx / wy / mg 自带封面；**kw / kg 的搜索响应里没有封面字段**
（LX 自己也是 `img: null`），所以要按平台接口现取，本工程照抄了 LX 的实现：

| 平台 | 接口 | 参考 |
| --- | --- | --- |
| kw | `GET http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid={songmid}`，直接返回图片地址文本 | `kw/pic.js` |
| kg | `POST http://media.store.kugou.com/v1/get_res_privilege`（带 `KG-RC` / `KG-THash` 头），`data[0].info.image` 的 `{size}` 替换成 `imgsize[0]` | `kg/pic.js` |

这些都在 `MusicSearch.ets` 的 `fetchMusicPic()` 里。源脚本若自己实现了 `pic` action，
则作为兜底再问一次（`SourceEngine.getPic()`，pic 的 `result.data` 是裸字符串）。

`CoverStore.ets` 负责「列表里几十行不能同步等网络」的问题：`coverFor(json, fallback)`
同步返回已有封面或空串，同时把缺的排进队列（并发 3，失败不重试），
每解析好一批就把 `K_COVER_VERSION` +1，订阅了它的列表（`SongListPane` / `SongRow` /
播放列表 / 推荐页）就会重画一次，封面是「陆续出现」的。

#### 歌词

- 取词顺序：**源自带的 `lyric`（若声明且带时间轴）→ 内置平台歌词（kw/kg/tx/mg）**
  （详见上面「歌词：内置平台歌词是主力」）。
- 解析：`core/music/Lyric.ets` 的 `parseLyric()` 解标准 LRC（`[mm:ss.xx]`，一行多标签、
  `[offset:]` 都支持），翻译按时间对齐到原文行；没有时间标签的纯文本歌词保留成
  `time = -1` 的行，界面就不跟随高亮。
- 显示：播放页歌词页是 `List` + `Scroller`，进度（AVPlayer 的 `timeUpdate`）变化时
  用 `activeLyricIndex()` 二分出当前行，`scrollToIndex(index + 1, true, CENTER)` 滚到
  正中；首尾各垫一个 200 高的占位行，短歌词也能居中。点某一行可以跳到那一句。
  切歌时 `clearLyric()` 先把旧词清掉，`lyricToken` 挡住晚回来的旧歌词。

#### 音源去重

洛雪每次导入都生成新的 `user_api_<rand>_<ts>` 并追加，同一个源导入两次就会出现两条
一模一样的记录。本工程用 `sourceMetaKey()`（`LxMetadata.ets`，键 = 名字 + 版本 + 作者）：

- `SourceEngine.importSource()` 命中已有 key 时不再追加：脚本内容相同 → 跳过；
  内容不同 → `SourceStore.replace()` 原地覆盖（id 不变，已加载引用与播放列表不受影响）；
- `SourceEngine.prepare()` 启动时调 `dedupeStored()` 清理历史遗留的重复项。

#### 歌词：内置平台歌词是主力（与洛雪一致）

平台源的 `actions` 白名单里**只有 `musicUrl`**（`lx_preload.js` / 官方
`user-api-preload.js` 的 `supportActions`，`handleInit` 取的是交集），也就是说
「拿歌词」本来就不属于源规则。洛雪自己走的是内置平台 SDK
（`src/utils/musicSdk/*/lyric.js` 的 `musicSdk[source].getLyric`），所以这里同样
移植了内置歌词（`core/music/PlatformLyric.ets`），**不依赖任何源、开箱有词**：

| 平台 | 接口 | 处理 | 参考 |
| --- | --- | --- | --- |
| kw | `GET mlyric.kuwo.cn/mobi.s?f=web&type=lyric&lrcx=1&rid={songmid}` | 响应是 `TP=content\r\n\r\n` + **zlib 流** → 解压 → base64 → 循环 XOR `yeelion` → 明文 LRC | `kw/decodeLyric.js`、`kw/lyric.js` |
| kg | `GET lyrics.kugou.com/search` → `GET lyrics.kugou.com/download?fmt=lrc` | `content` 是 **base64 的明文 LRC**；返回 `fmt=krc`（加密格式）时放弃 | `kg/lyric.js` |
| tx | `GET c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?...&nobase64=1`（需 `Referer`） | 直接返回明文 LRC，数字实体要解码 | 洛雪 tx/lyric.js 里注释掉的旧路径 |
| mg | `POST c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2`（form `resourceId`）拿 `lrcUrl` → `GET lrcUrl` | 明文 LRC；只有 `mrcUrl`（加密）的新歌放弃 | `mg/lyric.js` + `mg/musicInfo.js` |
| wy | eapi `/api/song/lyric/v1` | **取不到**：直接请求返回 404（连它的搜索接口也 404），先不实现 | — |

- **kw 需要自己解 zlib**：HarmonyOS 的 `@ohos.zlib` 只有文件级 zip/gzip 解压，没有
  内存 inflate，所以 `core/music/Inflate.ets` 按 RFC 1951 实现了一份（动态/固定
  Huffman、stored block 都支持），并用酷我真实响应逐字节验证过。
- kw 的歌词带逐字标签（`<1022,-1022>`），展示前剥掉；同一时间点出现两句时按
  `kw/lyric.js` 的 `sortLrcArr` 把后一句当成翻译挪到上一句的时间上。
- **源的歌词仍然优先**：本工程把 preload 的 `supportActions` 从「只给 musicUrl」
  放宽成 `['musicUrl','lyric','pic']`（这是**与官方 preload 的一处有意偏离**），
  于是源若声明了 `lyric`/`pic`，`SourceEngine.getLyric()/getPic()` 就能用上；
  源没实现、或返回的词没有时间轴时，再落到上面的内置平台歌词。
- 四个平台的接口都用真实请求 + 真实数据验证过：解码出来的 LRC 行数、时间轴单调性、
  当前行定位（`activeLyricIndex`）都在宿主侧用同源代码跑通过。

#### 评论

同一个道理：源协议的 action 白名单里也没有「取评论」，所以评论同样只走内置平台接口
（`core/music/PlatformComment.ets`），与导入的音源无关。入口在播放页底部工具栏与会话
「更多」菜单里。平台接口的差异（酷狗的签名、咪咕的游标翻页、QQ 的两套接口、网易改用公开
GET 等）、与洛雪的差异、以及**尚未在设备上实测**这件事，都写在 `docs/SONG_COMMENT.md`。

内置搜索已覆盖 5 个平台，移植自洛雪的 `src/utils/musicSdk/*/musicSearch.js`：

| 平台 | 是否需要签名 | 参考实现 |
| --- | --- | --- |
| 酷我 kw | 无 | `kw/musicSearch.js` |
| 酷狗 kg | 无（结果带 `hash`） | `kg/musicSearch.js` |
| 咪咕 mg | md5 签名 | `mg/musicSearch.js` |
| QQ tx | zzcSign（SHA-1 派生） | `tx/musicSearch.js` + `tx/utils/crypto.js` |
| 网易 wy | eapi（md5 + AES-128-ECB/PKCS7） | `wy/musicSearch.js` + `wy/utils/crypto.js` |
| 喜马拉雅 xm | —— | **洛雪里整块被注释掉的死代码**，无实现可移植 |

> ⚠️ **待复核（已登记为 `docs/DEFECTS.md` D-001）**：2026-09 直接请求网易的 eapi 端点
> （搜索 `/api/search/song/list/page` 与歌词 `/api/song/lyric/v1`）都返回 `code:404`，
> 换 https、带 cookie、换另一种 eapi 加密写法都一样；**wy 这条链路目前是不通的**，
> 需要对着网易现有接口重做（其余四个平台的搜索/歌词本次都实测可用）。
> 处理步骤、实测证据与验收标准都写在 D-001 里。

搜索结果的字段与洛雪旧版 musicInfo 一致，可直接 `JSON.stringify` 交给源规则。
tx 结果额外带 `songId/albumMid/strMediaMid`（tx 源取流需要），wy 结果音质按洛雪
`privilege` 的 switch **穿透**规则生成（`maxbr=999000` 会同时给出 flac/320k/128k）。

### tx / wy 的签名细节（都在 `LxCrypto.ets` 里，与 `node:crypto` 对齐）

- **tx `createZzcSign`**：`sha1(text)` 取 hex，按洛雪给定的两组下标各取一段，
  再把 20 个固定值与 hash 的字节两两 XOR，base64 后去掉 `\ / + =`，拼成
  `zzc<part1><b64><part2>` 再转小写。洛雪的下标表里有个**越界下标 40**，
  原版靠 `Array.join` 把 `undefined` 变成空串，这里显式跳过越界下标以保持同样输出。
  请求体是带 `searchid` 随机数的 JSON，**键顺序必须与洛雪一致**（签名算的就是这个串）。
- **wy `createEapiParams`**（⚠️ 这条链路目前不通，见 `docs/DEFECTS.md` **D-001**）：
  `digest = md5("nobody"+url+"use"+text+"md5forencrypt")`，
  `data = url + "-36cd479b6b5-" + text + "-36cd479b6b5-" + digest`，
  `params = hexUpper(AES-128-ECB/PKCS7(key='e82ckenh8dichen8', data))`。
- ⚠️ **一个容易抄错的地方**：洛雪的 `AES_MODE.ECB_128_NoPadding` 取值是 Java 的
  `"AES"`，而 `Cipher.getInstance("AES")` 默认是 **ECB/PKCS5Padding** ——所以 ECB
  路径实际是**带填充**的。沙箱 `lx_utils.js` 里原先按真正的 NoPadding 实现，
  已修正为 PKCS7（同时保留 `ECB_NoPadding` 供需要真 NoPadding 的场景）。

---

## 4. 源脚本（源规则）协议速查

```js
/*!
 * @name 音源名称（≤24 字）
 * @description 说明（≤36 字）
 * @version 1.0.0
 * @author 作者
 * @homepage https://...
 */

// 注册处理器：宿主发来的每一次解析请求都会走到这里
lx.on('request', (request) => {
  // request = { source: 'kw', action: 'musicUrl'|'lyric'|'pic', info: { type, musicInfo } }
  return new Promise((resolve, reject) => {
    lx.request('https://api.example.com/geturl?id=' + request.info.musicInfo.songmid,
      { method: 'get', headers: { 'User-Agent': '...' }, timeout: 15000 },
      (err, resp, body) => {
        if (err) return reject(err);
        resolve(resp.body.data.url);   // action=musicUrl 时必须返回 http(s) 字符串
      });
  });
});

// 声明能力（平台 id: kw/kg/tx/wy/mg）
lx.send('inited', {
  sources: {
    kw: { type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac', 'flac24bit'] },
  },
});
```

可用工具：`lx.utils.crypto.md5/aesEncrypt/rsaEncrypt/randomBytes`、
`lx.utils.buffer.from/bufToString`、`setTimeout/clearTimeout`。

---

## 5. 测试方法

### 方法一：无设备引擎自检（推荐先跑）

```bash
cd D:/harmony/listen
node tools/lx_engine_selftest.js
```

用 Node 模拟 ArkWeb 沙箱 + 宿主网络代理，真实加载 `lx_utils.js` / `lx_preload.js` /
示例源，校验 51 项：md5/AES/RSA 与 `node:crypto` 一致、`inited` 解析、离线源解析出
播放链接、`lx.request` 回环与参数透传、`lx.env` 透传、**同一页面连续加载两个源
（页面内重置 + IIFE 隔离，不 reload）**、**桥接分支覆盖度**（preload 会发出的 action
必须都被 `handleBridgeMessage` 处理，防止再次出现「漏掉 request 分支」那类 bug）等。
全程不联网、不需要设备。

每个用例都在独立的 `vm` context 里跑，并用 IIFE 包裹源脚本，
与设备上 `SourceEngine.loadSource()` 的做法保持一致。

### 方法二：页面手动测试（需设备/模拟器）

> ⚠️ **不要用 Previewer（预览器）跑音源功能**。预览器把 `rawfile`、`fs`、`TextDecoder` 等
> 都换成了 mock，且 `Web` 组件是残缺桩（例如 `Web.horizontalScrollBarAccess` 未实现，
> 调用会直接抛 `TypeError: undefined is not callable` 并让页面渲染失败）。宿主组件已移除
> 纯外观类属性并加了异常兜底，预览器现在只会降级（音源不可用），不会崩页面；但**沙箱真正
> 跑起来必须在模拟器或真机上**。

运行 App → 测试页：

- **离线自检**：点「一键离线自检」即可 —— 它自己会读内置示例源，不需要再手动载入脚本。
  成功后「播放链接」应显示 `https://example.com/test-audio.mp3`。
- **真实音源（完整流程）**：导入音源有两条入口 —— 把音源脚本**链接**粘进输入框点
  「导入并加载」，或点「导入音源文件」选设备上的 `.js` 脚本（本地文件同样会走沙箱初始化）。
  加载好之后在「② 搜索音乐」输入关键词 →「搜索」→ 结果列表点「播放」。
  页面会显示源规则解析出的播放链接，并由 AVPlayer 播放。

### 方法三：代码调用测试方法

```ts
import {
  runOfflineSelfTest, runImportAndResolveTest, runSearchAndResolveTest,
  formatTestResult, formatSearchTestResult, buildMusicInfoJson,
} from '../core/source/SourceTest';

// ① 离线：内置示例源 + 默认 musicInfo
const r1 = await runOfflineSelfTest(getContext(this) as common.Context);
console.info(formatTestResult(r1));

// ② 真实音源：链接导入 + 指定 musicInfo 解析
const musicInfo = buildMusicInfoJson('歌曲名', '歌手', 'kw', 'kw_songmid');
const r2 = await runImportAndResolveTest('https://example.com/real-source.js', musicInfo, '320k', 'kw');
console.info(formatTestResult(r2));

// ③ 一站式：链接导入源 -> 搜索关键词 -> 解析首条结果的播放链接
const r3 = await runSearchAndResolveTest('https://example.com/real-source.js', '晴天', 'kw', '320k');
console.info(formatSearchTestResult(r3));
```

### 方法四：主机单元测试（纯逻辑）

```bash
node "C:/Program Files/Huawei/DevEco Studio/tools/node/node.exe" \
  "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.js" test
```

共 23 项，覆盖：
- `LxMetadata.test.ets`：源脚本头部元信息解析、缺注释报错、id 生成、名称截断；
- `MusicSearch.test.ets`：MD5 已知向量、咪咕签名（与 `node:crypto` 手算值一致）、
  酷我/酷狗/咪咕搜索结果解析（含去重、`hash`、HTML 实体、图片补全）、音质选择；
- `TxWySearch.test.ets`：SHA-1 已知向量、纯 ArkTS base64、AES-128-ECB/PKCS7 向量、
  tx `zzcSign` 与请求体（含越界下标与键顺序）、wy `eapi` 参数（与 node 手算值一致）、
  tx/wy 搜索结果解析（含 wy 的音质穿透规则）。

> 备注：主机单测环境里 `util.Base64Helper` 不可用（属于设备 API），所以 base64 用的是
> 纯 ArkTS 实现，测试也因此能真正跑起来。

### 方法五：联网活体验证（本机有外网时）

设备上能不能放歌，最终取决于「第三方音源的中转服务」是否还活着，而这一点本地单测覆盖不到。
所以有两个联网探针，直接打真实接口：

```bash
# 1) 五个平台的内置搜索是否还有效（签名/请求体/解析）
node tools/live_search_probe.js 晴天

# 2) 把一个真实音源脚本跑进真正的 lx_preload.js 沙箱，
#    宿主侧用真实网络代理 lx.request，最后调用 musicUrl 看能否拿到播放链接
node tools/live_source_probe.js ./.probe/qdy.js kw 听妈妈的话
node tools/live_source_probe.js ./.probe/qdy.js wy 听妈妈的话 '{"songmid":"3381007912"}'
```

第 2 个探针与设备上的链路完全一致（源脚本 → `lx.request` → 宿主代理 → 回灌沙箱），
所以它能提前暴露「源脚本本身能不能用」和「沙箱契约对不对」。

**2026-09 实测结论**（用上述探针）：

| 音源 | 结果 |
| --- | --- |
| 五个平台内置搜索 | kw / kg / mg / tx / wy **全部有效**（tx 的 zzcSign 与 wy 的 eapi 都被服务端接受） |
| Huibq（`lxmusicapi.onrender.com`） | **已失效**：HTTP 503 `text/html`「Service Suspended」→ 脚本报 `unknow error` |
| 全豆要聚合音源 qdy | **kw / wy 可用**（解析出 `audio/mpeg` 真实音频，4MB 左右）；tx / kg / mg 的多条链路返回 403/404/`code:201` |
| ikun / flower / grass | 域名无法解析 / 初始化即报「服务器异常」 |
| 独家音源（`88.lxmusic.*`） | 接口可达但返回 403 block ip |

> 这就是洛雪架构的固有现实：洛雪本身**不内置任何 `getMusicUrl`**（各平台目录里没有
> `musicUrl.js`，公开 commit 也删掉了试听接口），播放能力完全来自第三方音源。
> 第三方中转服务随时会挂，所以「换个源」是常态而不是本工程的 bug。
> 只要源可用，本工程就能正确解析并播放——qdy 的 kw/wy 已经端到端验证过。

### 构建验证

```bash
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
node "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" ^
  "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" assembleHap
```

---

## 6. 与洛雪的差异 / 已知限制

1. **沙箱实现**：洛雪用 QuickJS（无 DOM、只暴露 `__lx_native_call__*`）；这里用 ArkWeb，
   已在 preload 中移除 `fetch/XMLHttpRequest/WebSocket/localStorage...` 并禁用 `eval`，
   网络强制走宿主代理 `lx.request`，但隔离强度仍弱于 QuickJS。若要更强隔离，
   可换用独立 Web 调试域/隔离世界或接入原生 QuickJS NAPI。
2. **binary 响应**：洛雪返回 Buffer 对象；这里返回字节数组（`number[]`），
   `lx.utils.buffer.bufToString(bytes, 'base64')` 可直接使用。多数音源的 `musicUrl`
   不走 binary。
3. **musicInfo 来源 / 内置搜索范围**：自定义音源只负责「给定 musicInfo → 播放链接」。
   本工程已移植 **kw / kg / mg / tx / wy** 五个平台的内置搜索（含 tx 的 zzcSign、
   wy 的 eapi 加密），喜马拉雅 xm 在洛雪里是整块注释掉的死代码，没有实现可移植。
   搜索出的结果直接就是旧版 musicInfo，无需再经 `toNewMusicInfo/toOldMusicInfo` 转换。
4. **musicInfo 字段要「该没有的就没有」**：洛雪里 kw / mg / tx / wy 的 musicInfo
   **根本没有 `hash` 字段**，只有 kg 有。源脚本普遍写 `musicInfo.hash ?? musicInfo.songmid`，
   如果把 `hash` 写成空串，`??` 不会回退，songId 变成空串，接口直接报参数错误。
   所以 `LxMusicInfo.hash` 是可选字段，`createInfo()` 只在 hash 非空时才写入
   （单元测试用 `JSON.stringify(info).includes('"hash"')` 守住这一点）。
5. **封面 `pic` action**：引擎已支持消息契约，但暂未封装成 `getPic()` 便捷方法
   （`lyric` 已封装为 `getLyric()`）。
6. **`xm` 平台**：洛雪 `supportedActions` 里包含 `xm`，但 `allSources` 过滤列表不含它，
   行为与洛雪一致。
7. **换源走「页面内重置」而不是 `refresh()`**：只加载一次沙箱页，
   换源时调 `__lx_destroy__()` 清状态再重新注入 preload，源脚本用 IIFE 包裹保证隔离
   （原因见「坑 2」）。换源时会 `abortHttpRequests()` 中断上一个源尚未返回的网络请求。
8. **Previewer（预览器）限制**：预览器的 `Web` 是残缺桩，rawfile / fs / TextDecoder 均为 mock，
   因此音源引擎在预览器里不可用；宿主组件已移除纯外观类属性（滚动条/图片/缩放）并加了异常兜底，
   预览器现在不会崩页面，界面会提示「当前环境 rawfile 被 mock，音源沙箱不可用」。请在模拟器 /
   真机上验证音源功能，预览器只用来看布局。

## 7. 权限

`entry/src/main/module.json5` 已声明 `ohos.permission.INTERNET`，用于：

- 下载音源脚本（`importFromUrl`）；
- 代理源脚本的网络请求（`lx.request`）；
- 内置搜索（酷我接口目前仍是 `http://`，本 SDK 的 stage model 未限制明文流量）；
- AVPlayer 播放在线音频。

若后续 SDK 收紧明文 HTTP，需要把酷我搜索改成 `https://search.kuwo.cn/r.s?...`，
或按 stage model 的网络配置声明允许明文域。
