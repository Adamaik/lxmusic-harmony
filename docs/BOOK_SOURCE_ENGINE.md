# 听书书源引擎 · 说明

本文说明「听书」这一栏是怎么跑起来的：它用的是**阅读（Legado）的书源**，与洛雪
音源（`docs/LX_SOURCE_ENGINE.md`）是两套完全不同的协议，因此是一套独立的引擎。

---

## 1. 两套协议的根本区别

| | 音源（洛雪） | 书源（阅读） |
| --- | --- | --- |
| 载体 | `.js` 脚本 + 头部注释元信息 | `.json` 规则文档 |
| 求值方式 | 脚本自己执行，`lx.on('request')` 注册处理器 | 宿主解释**规则 DSL**（CSS / JSONPath / 正则 / `@js:`） |
| 脚本能力 | `lx.request/send/on/utils` | `java.*`、`cache`、`source`、`book`、`jsLib` |
| 声明内容 | `lx.send('inited', {sources:{kw:{...}}})` | `bookSourceUrl` + 六组 `rule*` |
| 搜索 | **协议里没有**，靠内置平台 SDK | `searchUrl` / `exploreUrl` 自己就是搜索 |
| 典型动作 | `musicUrl`（musicInfo → 播放链接） | `bookList` → 详情 → 目录 → 音频直链 |

结论：**协议层零复用**。所以书源引擎是并列新增的一套，只共用了两样东西：
`lx_utils.js`（md5 / base64 工具）与「ArkWeb 沙箱 + 宿主代理网络」这个架构。

---

## 2. 文件与职责

| 文件 | 职责 |
| --- | --- |
| `resources/rawfile/book_preload.js` | **规则求值引擎**（沙箱内）：规则 DSL、`java.*`、网络回放 |
| `components/BookSandboxHost.ets` | 沙箱宿主（1×1 透明 Web，与音源宿主是**两个独立页面**） |
| `components/BookLoginWeb.ets` | **网页登录**：整屏应用内浏览器打开站点登录页，登录后抓 Cookie |
| `core/book/BookTypes.ets` | 类型定义 + 队列载荷的还原 |
| `core/book/BookSourceStore.ets` | 书源持久化（索引 JSON + 每源原始 JSON 正文） |
| `core/book/BookHttp.ets` | 宿主网络代理 + **Cookie 罐**（`data:` URL 就地解码） |
| `core/book/BookEngine.ets` | 书源导入/删除、搜索/详情/目录/音频、**网络回放循环**、沙箱注入 |
| `core/book/BookShelf.ets` | 书架（书 + 目录 + 听到第几集） |
| `views/ListenView.ets` | 听书页：书架 / 搜索 / 书源 三个分段 |
| `views/BookDetailView.ets` | 一本书的详情 + 目录，点一集即播 |
| `tools/book_source_diagnose.js` | **全链路诊断**：宿主侧照设备实现（Cookie 罐 / 重定向 / POST 表单头），逐段严格判定 |
| `tools/book_engine_selftest.js` | 无设备自检（jsdom 顶替沙箱 + 真实书源联网跑通） |
| `tools/book_import_test.js` | 无设备自检：**导入那一段**（应用算法的复刻 + 作业拼装 + 静态守卫） |

> 三份自检分工：`book_engine_selftest.js` 验规则求值，它把书源当**已解析好的对象**喂进去；
> `book_import_test.js` 验「一份 JSON 文件怎么变成一条能搜的书源」，并复刻
> `BookEngine.buildJob` 的字符串拼接（宿主与沙箱的接口）；`book_source_diagnose.js`
> 验**整条链路**（搜索→详情→目录→音频），宿主网络比前两者都更像设备。改导入 / 请求头时跑
> `book_import_test.js`，排查「某个源为什么用不了」时跑 `book_source_diagnose.js`。

---

## 3. 核心难点：规则里的 `java.ajax` 是同步的，而宿主网络是异步的

书源的 `@js:` 规则按「同步拿响应」来写（阅读的 Rhino 里 `java.ajax(url)` 直接返回字符串），
但 WebView 里跨域 XHR 会被 CORS 拦掉，网络必须由宿主（ArkTS 用 `@ohos.net.http`）代理 ——
异步等不了同步。

引擎用**回放（replay）**解决，规则一个字都不用改：

```
宿主：__book_run__(job)
        ↓
沙箱：跑规则 → java.ajax 查内存缓存
        ├─ 命中 → 返回字符串，规则继续
        └─ 未命中 → 记一笔缺失、返回空串（规则多半在 JSON.parse 处抛错）
        ↓
      本轮只要有缺失，就回 { status:'net', urls:[...] }（这一轮的结果丢掉）
        ↓
宿主：把 urls 抓回来塞进 netCache
        ↓
      拿同一份 job + 新缓存**重跑**（回到第一步）
        ↓
      某一轮没有缺失 → 结果与「同步发网络请求」完全一致
```

缓存只增不减，所以每轮至少解决一个地址，必然收敛（上限 `MAX_ROUNDS = 240`）。
一次真实目录的日志会打印 `toc 完成：N 轮 / M 次请求 / Tms`，`T` 基本就是网络耗时。

另一个好处：**CSS 选择器不用自己写**。沙箱是真实 WebView 页面，
`DOMParser` / `querySelectorAll` 都是现成的（音源那套 preload 反而禁了 `eval`、
把 DOM 当噪音；书源引擎正好相反，它需要 `eval` 与 DOM，所以两者必须分开成两个页面）。

---

## 4. 已实现的规则语法

- **取值方式**：CSS 选择器（Default）、`@css:`、JSONPath（`$.` / `$[` / `@json:`）、
  `<js></js>` 与 `@js:`、正则 AllInOne（`:` 前缀）、XPath 的一个子集
- **取值后缀**：`@text` / `@textNodes` / `@ownText` / `@html` / `@all` / 任意属性名
- **变换管道**：`规则##正则##替换`；`规则##正则##替换###` = **只取第一个匹配并在其中替换**
- **连接符号**：`||` 取第一个非空、`&&` 合并全部、`%%` 依次取数
  （不作用于 js 与正则规则，与阅读一致）
- **模板**：`{{js 表达式}}`、`{{$.id}}`、`{{bookUrl}}`；`@get:{变量}`
- **地址**：相对地址自动拼绝对；`/search.php?...` 这种相对 searchUrl 也能用；
  非 ASCII 与空格自动百分号编码（书源里写的是不编码的 `?q={{key}}`）
- **沙箱 API**：`java.ajax/connect/post/ajaxAll/timeFormat/md5Encode/md5Encode16/
  base64EncodeToString/base64Decode/hexDecodeToString/encodeURI/getString/getStringList/put/get/
  log/toast/longToast/startBrowser/androidId/isRule`、
  `cache.get/put/delete`、`source.getVariable/setVariable/getLoginInfoMap/getLoginInfo/getKey/
  put/get/putLoginInfo`、`cookie.getCookie/removeCookie/setCookie`、`getArguments`、
  `jsLib` 里的公共函数（间接 eval 到全局，换源时摘掉，避免同名串味）
- **请求/响应**：`java.connect(url, headers, body)` 与 `java.post(url, body, headers)` 返回
  `{ url, code(), headers(), body(), toString() }`；`headers()` 是响应头（头名同时给原样与
  小写两种 key，所以 `res.location` / `res.Location` 都能取到）。响应头由宿主随正文一起回灌
  （`netHeaders`）。选项里的 `charset: gbk/gb2312` 只当提示：设备侧由 `@ohos.net.http` 按
  响应的 `Content-Type` 解码（站点没声明时可能仍是乱码），测试脚本另有 GBK 兜底。
- **选项 JSON 宽松解析**：`searchUrl` / `java.ajax` 的 `url,{...}` 选项里把 key/字符串写成
  单引号（`{'method':'POST'}`）在阅读的 Gson 宽松模式下合法，引擎解析失败时会自动补一次。

### 与阅读的一处有意偏离

阅读把 `##` 的解析放在连接符号**之前**，于是
`A##r1##s1###||B##r2##s2###`（两条分支各自带正则替换）会被解析坏 ——
`||` 后面的部分被当成 `replaceFirst` 的判定标志丢掉。
本引擎按**作者的原意**实现：先切连接符号，每条分支各自走自己的 `##` 管道。
这样「播客听书聚合源」的 `chapterUrl`（先找 `jt=` 链接、找不到再找 `<enclosure url=`）
才真的成立。

另外两处按阅读源码对齐、但容易写错的地方：

- `{{...}}` 出现在第一个 `##` **之前**时，**替换结果本身就是值**（阅读会把规则切进
  正则模式，取值时直接返回规则串）。所以 `https://…?albumId={{$.id}}` 拿到拼好的地址、
  `{{$.title}}` 拿到书名，而不是把书名当成 CSS 选择器去查。
- 逐条目求值时，`result` 与 `src` **都是这一条**（阅读是 `analyzeRule.setContent(item)`），
  不是整个列表页 —— 所以 `@js: JSON.parse(src)` 拿到的是本条 JSON。

---

## 5. 七个书源的实测结果

自检脚本：`node tools/book_engine_selftest.js`（离线夹具 28 项）；
联网：`node tools/book_engine_selftest.js --live <源名关键字> <关键词>`

导入那一段另有一份：`node tools/book_import_test.js`（离线 16 项，含静态守卫）；
联网：`node tools/book_import_test.js --live <关键词>` —— 它走的是应用真正拼出来的作业。
注意本机若挂代理又没开，联网项会「0 条 + 请求成功 0 次」，那是网络不是规则。

| 书源 | 搜索 | 详情 | 目录 | 音频直链 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 六月听书网 | ✅ | ✅ | ✅ | ✅ | 纯 CSS 规则；该书库没有的书会「搜到 0 条」，是站点本身没有 |
| 播客听书聚合 | ✅ | ✅ | ✅ 625 章 | ✅ | iTunes 搜索 + RSS（正则列表 + `$0` + `||` 回退） |
| 悦听有声书 | ✅ | ✅ | ✅ 72 章 | ✅ | `<js>` 搜索返回 `data:` URL；`chapterUrl` 本身就是直链 |
| 275听书 | ✅ | ✅ | ✅ | ✅（个别专辑除外） | 站点每个响应都发 `PHPSESSID`，靠宿主 Cookie 罐；`盗墓笔记`（book/363）这本站点改成了 token 播放（`lrts$...`），全网都拿不到直链，规则现在**返回空**而不是把播放页当音频 |
| 书音FM | ✅ 97 条 | ✅ | ✅ 790 章 | ✅ | 搜索是 POST（302 到结果页）；音频走 ECMS 接口 + md5 token |
| 哔哩哔哩听书 | ✅ | ✅ | ✅ | ✅ | 详情要先抓 view 接口；搜索接口风控严（连点会 `-412`），过一阵恢复 |
| 喜马拉雅·简听 | ✅ 20 条 | ✅ | ✅ 340 章 | — | 目录要 `nextTocUrl` 翻几十页；站点对匿名请求把 `playUrl64` 置空，**音频必须带登录 Cookie** |

> 这份表是 2026-09-28 用 `node tools/book_source_diagnose.js` 实测出来的（关键词「盗墓笔记」）。
> 结论是：**七個源里除了「需要登录」的喜马拉雅，其余都能跑通完整链路**；
> `275听书` 的某些专辑（站点侧 token 化）拿不到音频，属于站点行为。

---

## 5.1 全链路诊断脚本（2026-09-28 新增）

`node tools/book_source_diagnose.js [--source 关键字] [--keyword 词] [--book 书地址] [--offline]`

它和 `book_engine_selftest.js` 的分工：那个验**规则求值**，喂的是解析好的对象、宿主网络
很简陋；这个验**整条链路**，宿主侧按设备的样子实现（Cookie 罐、重定向跟随、POST 表单
兜底、ArkWeb 的二次 JSON 序列化），再对 `search → bookInfo → toc → content` 每段严格判定。

严格在哪：**音频那一步必须拿到「看起来就是媒体」的地址** —— 后缀命中媒体，或 HEAD 回
`audio/*`；拿回 `text/html` 一律算失败。旧自检只看「是 http 且 HEAD<400」，一张 HTML
播放页也能「通过」，这正是用户反馈「别的书源有问题」里最容易被测试放过的一类。

`--offline` 跑离线夹具（含引擎回归守卫）；`--book` 可直接指定一本书，绕开站点对搜索接口的
风控去单独验目录/音频。

---

## 5.2 这一轮修的三个引擎 bug（2026-09-28）

规则写得没错，是引擎没把书源用到的能力接上 —— 三个都表现为「某个源永远解析不出东西」：

1. **`java.md5Encode` 恒为空串**。`book_preload.js` 里写的是 `PURE.md5(...)`，但
   `lx_utils.js` 导出的是 `str2md5(str)`。于是凡是用 md5 签名的接口（书音FM 的 ECMS
   `token=`）全部算错 → 音频永远拿不到。改成优先 `str2md5`。
2. **`ruleBookInfo.init` / 目录地址只认 `<js>`，不认 `@js:`**。阅读里两者等价，
   `buildUrl` 少了 `@js:` 分支时会把规则**原样当地址**拼成一个 404
   （`https://站点/@js:(function...`）。哔哩哔哩的 `init` 正是这么写的。
3. **`java.ajax(url, headers)` 丢了第二个参数**。`connect` 收、`ajax` 不收，
   书音FM 的 ECMS 调用传的那段请求头被静默丢掉。

三条都在 `book_source_diagnose.js --offline` 里有回归守卫，改坏了会变红。

---

## 5.3 书源登录（2026-09-28 新增；网页登录同日补上）

需要登录的源（喜马拉雅的音频，见第 5 节）以前只能止步于目录 —— 应用里**没有地方**
登录。现在书源列表里凡是 `needLogin` 的源右侧有一个按钮，**按登录状态切换**：
没登录时显示「登录」（强调色，提示还差一步），登录后变成「重新登录」（弱化，但仍可点，
换号或 Cookie 过期时能重来）；同时书名旁的「需登录」角标在登录后消失。登录状态存成
`@State loggedIds` 并拼进 `ForEach` 的 key —— 只按 id 做 diff 时状态变了也不会重建条目，
文案就永远停在「登录」。点开是一个弹窗，**首选是「网页登录」**：

### 网页登录（主力方式）

点「网页登录」→ `bindContentCover` 整屏拉起应用内浏览器（`components/BookLoginWeb.ets`），
用户就在**站点自己的登录页**上登录——扫码、短信验证码、多域跳转都能走，登录成功后点
右上角「完成」，应用从 WebView 的 Cookie 罐里把 Cookie 抓走（顶栏会显示当前地址，
方便确认打开的是哪个页面）：

```
WebView 登录 → WebCookieManager.fetchCookieSync(登录页 / 站址 / 当前页) 三处各抓一次
             → 合并去重成一串 → BookEngine.saveWebLogin
             → 落盘 login_<源id>.json：写进 Cookie / cookie 键，
               以及 loginUi 里任何「名字含 cookie」的字段（喜马拉雅要的是 InfoMap['喜马拉雅Cookie']）
             → 之后两类请求都带登录态：
                 1) 宿主网络：fetchOne 把 loginCookieOf(源) 当 Cookie 头（普通搜索/目录/接口）
                 2) 规则自拼请求：规则从 infoMap 取 Cookie 自己签名（喜马拉雅就这么拿音频）
```

这样就不需要用户自己去浏览器 F12 复制 Cookie 了。应用内的 Cookie 罐同时
`saveCookieSync()` 落盘，WebView 换个页面也还是登录态。

### 打开哪个地址：别信书源的 `loginUrl`

书源里的 `loginUrl` 大多**不是登录页**，直接打开就会出现「网页登录打开的不是登录页」：

| 源 | `loginUrl` | 实际是什么 |
| --- | --- | --- |
| 喜马拉雅·简听 | `https://www.ximalaya.com/` | 会跳到手机版首页，不是登录页 |
| 播客听书聚合 | `https://passport.ximalaya.com/` | 一台 Tengine 的默认页（「Welcome to tengine!」） |
| 哔哩哔哩听书 | `https://passport.bilibili.com/login` | 这个是对的 |

所以 `BookEngine.loginPageUrl` 按这个顺序解析（`LOGIN_PAGES` 是一张实测过的
「站点 → 真实登录页」表，目前有 ximalaya / bilibili 两条）：

1. 命中内置表（按 host，含子域）→ 用表里的真实登录页；
2. 源里写的地址本身「像登录页」（路径含 login / signin / passport / auth）→ 用它；
3. 否则用源里写的地址；
4. 再不行退回站址。

命中不到的新站点就退回站址，让用户自己在页面上找登录入口；确实需要的话往 `LOGIN_PAGES`
里加一条即可。

> 这一层是 `bindContentCover` 的**整屏覆盖层**，铺满窗口、不经过标题栏，所以顶栏要
> 自己避开状态栏：壳层（`Index.ets`）把纯状态栏 / 手势条高度作为 `safeTop` / `safeBottom`
> 传给听书页，再由 `BookLoginWeb` 加在顶栏与底部说明上 —— 否则「完成」会被压在状态栏
> 底下点不到。

### 手填表单已移除

早先弹窗里还有一份按书源 `loginUi` 渲染的手填表单（输入框 / 按钮）。实际用起来大多
没用：多数源没有 `loginUi`，有的填了也不对（要的是站点的真实会话），而且容易和
「网页登录」混淆。现在**只保留网页登录**一种方式。

规则侧仍然保留 `source.putLoginInfo(map)` / `source.getLoginInfo()` / `source.put/get`、
`java.toast(msg)` / `java.longToast(msg)`、`java.startBrowser(url)` 与裸 `startBrowser(url)`
（`loginCheckJs` 还会用到其中一部分），只是界面不再提供手填入口。

### 其它

- 登录信息与书源正文**分开存**：重新导入书源（`replace`）不会冲掉登录状态；删除书源时一并清掉。
- `java.getCookie(domain, name)` / `cookie.getCookie(url, name)` 会从这张表里取 Cookie，
  所以哔哩哔哩的 `loginCheckJs`（读 `SESSDATA`）在网页登录后能真正判出「已登录」。
- 弹窗底部有「检查登录」（跑 `loginCheckJs`）与「清除登录」。
- 离线回归守卫：`book_source_diagnose.js --offline`（infoMap 绑定 / putLoginInfo 回写 /
  toast / startBrowser / `java.getCookie`）与 `book_import_test.js` 的
  「静态守卫：书源登录的接线」（含网页登录的整条接线）。

---

## 6. 已知限制

1. **书源的 Cookie 罐**：宿主按「书源 + 域」收集 `Set-Cookie` 并在后续请求带上
   （`BookHttp.BookCookieJar`）。`275听书` 这类「每个响应都换 `PHPSESSID`」的站
   靠这个罐就能工作。**它不是登录**：需要账号的站点（喜马拉雅）要靠 5.3 的登录弹窗
   填 Cookie；没填之前只能跑到「目录」，拿不到音频。
2. **目录一次拉全**：阅读是滚动懒加载，这里一次拉完（上限 60 页）；超大专辑会慢。
3. **XPath 只实现了常用子集**：这批 7 个源一个都没用 XPath，所以没做全。
4. **没有预取下一集**：每一集都要现跑书源规则（可能多次网络往返），
   所以切到下一集时会重新「解析」一次。播放缓存（边听边下）没有接入 ——
   `BOOK_QUALITY` 只是占位；**离线靠「下载」这条路**（见第 8 节），
   听过但没下载的集不会落盘。
5. **`bookSourceType` 只当有声书用**：文本小说（type 0）的 `ruleContent.content`
   返回的是正文而不是音频地址，界面没有阅读器，会表现为「没解析出地址」。
6. **预览器不可用**：与音源同样，DevEco Previewer 的 `Web` 是残缺桩，
   听书沙箱在预览器里注入失败（会给出明确提示），请在模拟器/真机上验证。

---

## 7. 宿主侧的两个坑（2026-09-27 修的，见 `docs/DEFECTS.md` D-005 / D-006）

规则引擎没问题，但「导入」与「请求」这两段宿主代码一开始踩了两个坑，表现都是
**「导入进去解析不了」** —— 一个是文件进不来，一个请求发错了。都很容易再踩：

1. **Picker 的 URI 只能 `openSync`，不能 `readTextSync`**。`BookEngine.importFromUri()`
   原先把 `file://docs/...` 直接交给 `readTextSync`，报 `No such file or directory`。
   正确写法照 `LocalMusic.importOne()`：`fs.openSync(uri, OpenMode.READ_ONLY)` 拿 fd，
   读字节再按 UTF-8 解（这个 SDK 的 `readTextSync` 连 fd 都不收）。
2. **书源请求不能套用音源的默认头**。`bookRequest` 复用音源的 `lxRequest`，而后者
   默认 `Accept: application/json`、POST 无 Content-Type 时按 JSON 序列化正文；
   书源抓的是 HTML / XML，POST 正文是原样表单串，于是书音FM 的搜索必然 0 条。
   现在 `bookRequest` 自己兜底 `Accept: */*` 与 `application/x-www-form-urlencoded`
   （`options.headers` 会覆盖 `lxRequest` 的默认值，音源那份没动）。

这两条都有静态守卫在 `tools/book_import_test.js` 里，改坏了会变红。

---

## 8. 下载（接进 `DownloadManager`）

2026-09-27 接入。听书是**第三条下载链路**，与平台歌 / 洛雪音源并列：

| 环节 | 做法 |
| --- | --- |
| 解析 | `DownloadManager.resolveUrl` 按 `item.source === BOOK_SOURCE` 分支到 `resolveBookUrl`，它调的是**播放用的同一个** `BookEngine.resolveAudioOf` —— 能放的一定能下、能下的一定能放 |
| 请求头 | 解析结果连请求头一起返回（`ResolvedAudio`），下载请求用 `requestInStream(..., { header })` 带上书源的 `audioHeaders`（有声书 CDN 常校验 Referer） |
| 键 | `downloadKeyOf` 退回**条目 id**（书载荷算不出 `mediaKey`）。这个 id 就是 `book_<书目id>_<集号>`，与播放链路同一个 —— `downloadedFile(item.id)` 才对得上 |
| 文件名 | 固定 `书名-章节名`，不套「歌曲名 / 艺术家-标题」那三种格式，也不缀音质（`-book` 没意义） |
| 标签 | **不写**：ID3 / flac 元数据是音乐那套（歌名/歌手/歌词），书这边没东西可写；m4a 写标签见 `docs/DOWNLOAD_TAGS.md`（记为暂不做）。所以不调 `collectDownloadTags`（否则还会拿书名去平台白搜一轮） |
| 扩展名 | 先认链接后缀（m4a/mp3 都在 `KNOWN_EXTS` 里），认不出按 `EXT_BY_QUALITY['book'] = m4a` |
| 限速 | 有声书**串行**（`nextWaiting` 里一次只放一集进并发位）+ 集间 `BOOK_TASK_GAP_MS`。下一集要抓页面 + 跑一遍规则，整本几十集并发就是对站点的扫描 |
| 离线播放 | `PlaySession.playBookItem` **先查 `downloadedFile(item.id)`**，命中就 `playLocal`；这一步放在「书源还在不在」的检查**之前**，所以书源删了、站点改版、断网，下载过的照听 |
| 整本 | 详情页目录行那颗下载键 → 先弹确认（照歌单详情「下载全部」的规矩）→ `enqueueMany` 整本排队 |
| 自动下载 | 有声书**不参与**「缓存时自动下载」：那条设置是给播放缓存配套的，书没有播放缓存；真按它排就是听一集偷偷下一集。手动下载不受影响 |

界面入口：书籍详情页长按某一集 → 「下载本集」/「已下载的显示删除下载」；
目录行右侧 → 「下载整本」。进度都在「我的 - 下载管理」里看。

守卫：`node tools/book_import_test.js` 里的「契约：有声书条目的下载键与载荷」与
「静态守卫：接线留在哪几处」两节（下载键必须等于播放 id、已下载必须优先于书源检查等）。
