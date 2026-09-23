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
| `core/book/BookTypes.ets` | 类型定义 + 队列载荷的还原 |
| `core/book/BookSourceStore.ets` | 书源持久化（索引 JSON + 每源原始 JSON 正文） |
| `core/book/BookHttp.ets` | 宿主网络代理 + **Cookie 罐**（`data:` URL 就地解码） |
| `core/book/BookEngine.ets` | 书源导入/删除、搜索/详情/目录/音频、**网络回放循环**、沙箱注入 |
| `core/book/BookShelf.ets` | 书架（书 + 目录 + 听到第几集） |
| `views/ListenView.ets` | 听书页：书架 / 搜索 / 书源 三个分段 |
| `views/BookDetailView.ets` | 一本书的详情 + 目录，点一集即播 |
| `tools/book_engine_selftest.js` | 无设备自检（jsdom 顶替沙箱 + 真实书源联网跑通） |

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
- **沙箱 API**：`java.ajax/connect/ajaxAll/timeFormat/md5Encode/md5Encode16/
  base64EncodeToString/base64Decode/encodeURI/getString/getStringList/put/get/log`、
  `cache.get/put/delete`、`source.getVariable/setVariable/getLoginInfoMap`、
  `jsLib` 里的公共函数（间接 eval 到全局，换源时摘掉，避免同名串味）

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

| 书源 | 搜索 | 详情 | 目录 | 音频直链 | 备注 |
| --- | --- | --- | --- | --- | --- |
| 六月听书网 | ✅ | ✅ | ✅ | ✅ 实测 200 | 纯 CSS 规则；该书库没有的书会「搜到 0 条」，是站点本身没有 |
| 播客听书聚合 | ✅ 16 条 | ✅ | ✅ 38 章 | ✅ 实测 200 | iTunes 搜索 + RSS（正则列表 + `$0` + `||` 回退） |
| 悦听有声书 | ✅ | ✅ | ✅ 411 章 | ✅ 实测 200 | `<js>` 搜索返回 `data:` URL；`chapterUrl` 本身就是直链 |
| 275听书 | ✅ 7 条 | ✅ | ⚠️ | ✅ | jsLib 生效；该站详情页与规则预期的目录结构有出入，条目偏少 |
| 书音FM | ⚠️ | — | — | — | 搜索是 POST，站点要先给 cookie 才回结果页（见下） |
| 哔哩哔哩听书 | ⚠️ | ⚠️ | — | — | 需要登录；且接口有风控（连续请求会 `-412 request was banned`）；其 `ruleBookInfo.status` 本身是坏 JS |
| 喜马拉雅·简听 | ✅ 16 条 | ✅ | ⚠️ | — | 目录要 `nextTocUrl` 翻几十页；音频必须带登录 Cookie（`source.getLoginInfoMap()`） |

---

## 6. 已知限制

1. **书源的 Cookie 罐**：宿主按「书源 + 域」收集 `Set-Cookie` 并在后续请求带上
   （`BookHttp.BookCookieJar`），但**没有做登录**。需要登录的源（哔哩哔哩、喜马拉雅）
   只能跑到「目录」，拿不到音频；书音FM 这种「先给提示页、带 cookie 再给结果」的站
   需要连续两跳才生效，目前搜索可能只拿到提示页。
2. **目录一次拉全**：阅读是滚动懒加载，这里一次拉完（上限 60 页）；超大专辑会慢。
3. **XPath 只实现了常用子集**：这批 7 个源一个都没用 XPath，所以没做全。
4. **没有预取下一集**：每一集都要现跑书源规则（可能多次网络往返），
   所以切到下一集时会重新「解析」一次；播放缓存也没有接入（`BOOK_QUALITY` 只是占位）。
5. **`bookSourceType` 只当有声书用**：文本小说（type 0）的 `ruleContent.content`
   返回的是正文而不是音频地址，界面没有阅读器，会表现为「没解析出地址」。
6. **预览器不可用**：与音源同样，DevEco Previewer 的 `Web` 是残缺桩，
   听书沙箱在预览器里注入失败（会给出明确提示），请在模拟器/真机上验证。
