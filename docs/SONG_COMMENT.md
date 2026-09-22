# 歌曲评论 · 落雪的做法与本工程的移植

本文说明**落雪音乐是怎么打开歌曲评论区的**，以及这套东西移植到本工程（`listen`）后的
实现结构、平台接口细节、与落雪的差异和验证方法。

对应关系：评论与歌词是同一类东西 —— 都不属于音源（源规则）的能力，只能走内置平台接口。
所以这里的结构、坑、限制都和 `docs/LX_SOURCE_ENGINE.md` 里的「内置平台歌词」一节高度一致，
读的时候可以对照着看。

---

## 1. 落雪是怎么做的

### 1.1 入口：播放页「更多」菜单里的一项

| 位置 | 文件 | 说明 |
| --- | --- | --- |
| 竖屏（手机主用） | `src/screens/PlayDetail/Vertical/Player/components/MoreBtn/CommentBtn.tsx` | 播放页右下角「更多」底部菜单里的一项，点了就 `navigations.pushCommentScreen(componentId)` |
| 横屏 | `src/screens/PlayDetail/Horizontal/components/CommentBtn.tsx` | 横向布局的工具栏上直接给一颗评论钮，同样 `pushCommentScreen` |
| 路由 | `src/navigation/navigation.ts:306` | `pushCommentScreen()` 压栈一个独立的 `COMMENT_SCREEN`（`lxm.CommentScreen`） |

也就是说落雪**不是弹层**，而是把评论当成一个普通页面 push 进导航栈（有返回键、有标题）。

### 1.2 评论页：两个页签 + 两条分页列表

`screens/Comment/index.tsx`：

- 顶部 `Header`（`components/Header.tsx`）：返回箭头 + 标题「「歌名」的评论」；
- 一行页签：**热门** / **最新**，页签文字里带条数（`热门 (123)`）；
- 页签右边一颗**刷新**钮（`available_updates` 图标）；
- 两个页签各是一个 `PagerView` 页，左右可滑；
- `musicInfo.source == 'local'`（本地歌）时**整页不加载**，直接显示「该歌曲不支持获取评论」。

两个页签的实现几乎一模一样，各一份（`CommentHot.tsx` / `CommentNew.tsx`）：
`limit = 15`，维护 `{ page, total, maxPage, isEnd, isLoading, isLoadError }`，
列表组件 `components/List.tsx` 暴露 `setList/getList/setStatus`，
状态机是 `loading / refreshing / end / error / idle`，`onEndReached` 触发下一页，
底部按状态显示「加载中 / 没有更多了 / 加载失败（点击重试）」。

列表项是 `components/CommentFloor.tsx`：

- 头像（失败退回内置默认头像）+ 昵称 + 时间 + IP 属地（`IP属地：xx`）+ 点赞数（有才显示）；
- 正文（`CommentText.tsx`：超过约 160 字折叠，给「展开评论 / 收起评论」）；
- 图片（`CommentImage.tsx`：**先给一个虚线框，点「显示图片」才真正加载**，省流量）；
- 楼中楼：`comment.reply` 递归渲染同一个 `CommentFloor`，缩进一层、上面一条虚线。

### 1.3 数据：内置平台 SDK，五个平台各一套

统一入口是 `screens/Comment/utils.ts`：

```js
getNewComment(musicInfo, page, limit)  -> music[source].comment.getComment(toOldMusicInfo(musicInfo), page, limit)
getHotComment(musicInfo, page, limit)  -> music[source].comment.getHotComment(...)
filterList(list)                       // 按 id 去重（翻页边界会重复）
```

失败重试最多 3 次，**「取消请求」不重试**（那是用户划走时的主动中断）。

真正的实现在 `src/utils/musicSdk/<平台>/comment.js`，各平台分页方式差别很大：

| 平台 | 最新评论 | 热门评论 | 备注 |
| --- | --- | --- | --- |
| 酷我 kw | `GET ncomment.kuwo.cn/com.s?type=get_comment&sid=&start=limit*(page-1)&count=` | 同接口 `type=get_rec_comment` | 总数在 `comments_counts` / `hot_comments_counts`（字符串） |
| 酷狗 kg | `GET m.comment.service.kugou.com/r/v1/rank/newest?...&signature=` | `.../rank/topliked` | `signature` = md5(固定 key + **参数排序后拼接** + 固定 key) |
| QQ tx | `POST c.y.qq.com/.../fcg_global_comment_h5.fcg`（form，`pagenum=page-1`） | `POST u.y.qq.com/cgi-bin/musicu.fcg` 的 `music.globalComment.CommentRead/GetHotCommentList` | 两套字段名完全不同（小写 vs 首字母大写）；正文有 `[em]e400846[/em]` 表情码、昵称前有一个隐藏字符 |
| 咪咕 mg | `GET app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0?queryType=1&commentId=<上一页最后一条的 id>` | 同接口 `queryType=2&hotCommentStart=` | **游标式翻页**：没有上一页的游标就翻不动 |
| 网易 wy | `POST music.163.com/weapi/comment/resource/comments/get`（weapi 加密，带 cursor） | `weapi/v1/resource/hotcomments/{id}` | 正文里是 `[大笑]` 这类标签，要换成 emoji |

一些共同的形状：三个平台（kg / tx / wy）都有「这条其实是**回复**某条评论」的情况，
平台上把被引用的原文放在一个单独的字段里；落雪统一翻成「主楼 = 被引用的原文，`reply` = 这条回复」，
所以列表里看到的楼中楼结构是客户端拼出来的，不是平台直接给的。

### 1.4 两处交互细节

- **切歌不会自动换评论**：`refreshComment()` 发现还是同一首歌时只弹一句
  「这已经是「X」的评论啦」，不重新拉 —— 避免用户以为自己点了没反应。
- **本地歌没有评论**：`source == 'local'` 直接给「该歌曲不支持获取评论」，连接口都不打。

---

## 2. 本工程的实现

结论先说：**源规则里根本没有「取评论」这个 action**（`lx_preload.js` 的 `supportActions`
只有 `musicUrl / lyric / pic`），所以评论只能和歌词一样走**内置平台接口**，
与导入的音源无关 —— 换什么源都不影响能不能看评论。

| 文件 | 职责 | 对应落雪 |
| --- | --- | --- |
| `entry/src/main/ets/core/music/PlatformComment.ets` | **数据层**：kw/kg/tx/mg/wy 的 `getComment`/`getHotComment` 移植 + 时间格式化 + 去重 | `src/utils/musicSdk/*/comment.js` + `screens/Comment/utils.ts` |
| `entry/src/main/ets/core/music/PlatformHttp.ets` | 平台接口的 JSON / 文本请求小工具（从 `PlatformLyric.ets` 提出来共用） | `src/utils/request.js` 的那层封装 |
| `entry/src/main/ets/views/CommentSheet.ets` | **评论页**：页签、分页列表、评论行、楼中楼 | `src/screens/Comment/`（index + CommentHot/New + components/*） |
| `entry/src/main/ets/views/PlayerView.ets` | 入口：底部工具栏的评论钮 + 「更多」菜单里的「查看评论」 | `PlayDetail/**/CommentBtn.tsx` |
| `entry/src/main/ets/ui/Icons.ets` | `I_COMMENT`（`sys.symbol.message`，对话气泡） | 洛雪内置的 `comment` 图标 |

### 2.1 数据流

```
播放页点评论钮（或「更多 - 查看评论」）
  -> CommentSheet 先解析「这首歌在平台上的身份」
       PlaySession.platformIdentityOf(item)      三种来源统一入口（见 2.2）
  -> PlatformComment.fetchComments(info, 'hot'|'new', page, 15)
       -> kwComments / kgComments / mgComments / txComments / wyComments
       -> 解析成 LxComment[]（时间已格式化成「3 分钟前」/「2024-05-06」）
  -> List 渲染；上拉到底再拉下一页，失败给错误文案 + 点击重试
```

`fetchComments()` 的失败是**抛出**的，不吞成空数组：评论页要能分清「真的没人评论」（空态）
和「接口挂了」（错误 + 重试）。这一点与歌词不同 —— 歌词取不到只是「暂无歌词」，
没有可操作的下一步；评论是用户主动点进来的，得给个交代。

### 2.2 三种播放来源怎么适配

播放来源有三种，评论在**每一种上都能用**，区别只在「这首歌的平台身份从哪来」：

| 播放来源 | 平台身份从哪来 | 说明 |
| --- | --- | --- |
| **音源音乐**（在线歌） | 条目自带的 `musicInfoJson`（搜索 / 歌单 / 榜单 / 分享链接的结果本身就是平台数据） | 瞬时拿到，不联网 |
| **本地音乐** | `LocalMusic.matchOf(key)` —— 匹配到的那首平台歌曲（与取歌词**同一份**结果，见 `docs/LOCAL_MUSIC.md`） | 没有匹配时**按需匹配一次** |
| **WebDAV 云端音乐** | `WebDavLibrary.matchOf(key)` | 同上 |
| 下载到本机再播放的歌 | 仍是它自己的平台身份 | 下载只换了播放的文件路径（`downloadedFile`），条目没有被改写成「本地歌」，所以评论照旧 |

关键在最后两行的「按需匹配」，这是与取歌词**不同的地方**：取歌词那条路在
「本地已经有 `.lrc`」「服务器同目录有 `.lrc`」时根本不会走到匹配
（`loadLocalLyric` / `loadWebDavLyric` 直接返回），而评论对本地文件毫无兴趣 ——
它**一定要平台身份**。所以 `PlaySession.platformIdentityOf()` 会补一次匹配，并且：

- 仍受「自动匹配歌词」开关约束（不替用户多联网）；
- `matchTried` 记过的歌不再搜 —— 不会出现「看一次评论就联网搜一轮」；
- 歌词与评论可能同时来问同一首歌，加了「在飞的 Promise」去重（与云端歌的
  `webDavMatch` 同一套），不会为同一首歌连搜两轮；
- 界面上分两阶段提示：「正在匹配这首歌的平台版本…」→「正在加载评论…」；
- 匹配不到时给**可操作**的提示（去「更多 - 匹配歌词」手动选一条正确的），
  而不是干巴巴一句「看不到评论」。

### 2.3 与落雪的差异（都是为了贴合本工程的结构）

1. **入口在底部工具栏，不在「更多」里独占**。落雪竖屏只在「更多」菜单里放评论；
   本工程把「更多」菜单里那项**保留**（`查看评论`），同时把底部工具栏的评论钮也接上。
   那颗钮原位是系统铃铛图标、**本来就没接功能**（点不动、读屏也跳过），
   换成评论气泡之后底部四个入口都是能用的。
2. **评论页是自绘覆盖物，不是路由页**。播放器本身是**系统的半模态**（`bindSheet`，
   见 `pages/Index.ets` 与 `PlayerView.ets` 开头的说明），再往上压系统弹层容易打架，
   所以和「更多」「匹配歌词」一样在播放器里自绘一层铺满的内容（深色，跟播放器一套配色）。
3. **切歌就收起评论页**。落雪是提示一句「这已经是「X」的评论啦」等用户自己刷新；
   本工程在播放器里监听 `K_CURRENT_ID`，换歌直接收起 —— 那一层铺满整个播放器、
   显示的又永远是「当前这首」的评论，留着容易让人以为看到的是新歌的评论。
4. **本地歌 / 云端歌也能看评论**。落雪对这些歌一律「该歌曲不支持获取评论」；
   本工程的本地歌本来就有「匹配平台歌曲」这条链路（取歌词用的同一条，见
   `docs/LOCAL_MUSIC.md`），评论直接复用它，**没有匹配时还会按需补一次**（见 2.2）。
   没匹配上时给的是可操作的提示：「先在『更多 - 匹配歌词』里匹配一次」。
5. **图片直接显示**，不学落雪的「点一下才加载」。评论图一般就一两张，
   省流量的收益不值得多一次点击（也省掉了异步量原始尺寸那段）。
6. **时间只做相对时间**：`N 秒前 / N 分钟前 / N 小时前 / YYYY-MM-DD`，与落雪的
   `dateFormat2` 同一套档位和文案；平台没给时间就不显示（不显示成 1970）。
7. **网易走公开 GET**，不用 weapi 加密。理由与歌词完全相同（见
   `PlatformLyric.wyLyric` 的注释与 `docs/DEFECTS.md` D-001）：eapi 那条链路整体不通，
   而 `music.163.com` 的公开 `/api/` 面是可用的。⚠️ 这条属于**待实测**，见第 4 节。

### 2.4 平台接口实现里的坑（都在 `PlatformComment.ets` 里带注释）

| 坑 | 处理 |
| --- | --- |
| 酷狗的签名要**排序参数** | `kgSignature()`：`&` 拆开 → 排序 → 拼 → 前后裹固定 key → md5（`md5Hex`） |
| 各平台返回码类型不一致 | `codeIs()` 统一当字符串比（酷我给 `'200'`、QQ 给 `0`、咪咕给 `'000000'`、酷狗给 `err_code: 0`） |
| 咪咕是游标翻页 | 按「歌曲 + 页码」记 `commentId` 游标（`mgCursor`），第一页先清掉；没有上一页游标时如实报错，不乱猜 |
| QQ 评论要数字 `songId`，条目里可能只有 `songmid` | `txSongId()`：用 `pf_song_detail_svr/get_song_detail_yqq` 换一次并按 songmid 缓存 |
| QQ / 网易的时间是**秒**，酷狗 / 咪咕给的是 `'YYYY-MM-DD HH:mm:ss'` 字符串 | `secondsToMs()` / `parseDateTime()` 两个入口分开处理（不用 `new Date(字符串)`，那种非 ISO 格式各引擎解析不一致） |
| 「这条其实是回复」的结构 | kg 用 `pcontent`、tx 用 `rootcommentcontent`+`middlecommentcontent`、wy 用 `beReplied`，统一翻成「主楼 + reply」 |
| 表情 | QQ 是 `[em]e400846[/em]`（查表换 emoji）、网易是 `[大笑]`（查表换 emoji）、酷狗是 `[at=123]`（换成 `@名字`） |
| 翻页边界重复 | `dedupeComments()` 按 id 去重（对应落雪的 `filterList`） |

---

## 3. 怎么验证

### 3.1 手动（需要设备 / 模拟器）

1. 播放一首**来自 kw / kg / tx / mg 的歌**（搜索页搜一首点播放即可）；
2. 播放页底部工具栏点**评论气泡**（或「更多 - 查看评论」）；
3. 预期：先看到「正在加载评论…」，随后列出评论；页签文字带条数；下拉到列表底部会
   继续加载（`上拉加载更多` → `正在加载更多…` → `共 N 条`）；右上角刷新钮能重拉第一页。

分平台多试几首，注意：

- **咪咕**：只有顺序翻页能拿到后续页（游标式），直接跳页会报「请先加载上一页」（预期行为）；
- **QQ**：老歌可能没有 `songId`，会先打一次 `get_song_detail_yqq`（多一点点延迟）；
- **本地音乐**（三种来源都要试）：
  - 没匹配过、且开着「自动匹配歌词」：先显示「正在匹配这首歌的平台版本…」，
    匹配成功后直接列出评论；
  - 匹配不到（或关了自动匹配）：显示「这首歌还没匹配到平台上的版本」+ 操作指引，
    按指引去「更多 - 匹配歌词」手动选一条，再回来就能看到评论；
  - **本地歌自带 `.lrc` 的情形要专门试一首**：这是本次特意补的按需匹配（见 2.2），
    取歌词那条路在这种情况下不会去匹配，评论必须自己补一次；
- **WebDAV 云端音乐**：与本地音乐同一套（`matchOf` + 按需匹配）；
- **下载到本机再播放的歌**：评论照旧（下载不改变条目的平台身份）；
- **没有评论 / 接口挂了 / 平台不支持** 是三种不同界面：分别是
  「还没有人评论」、「具体错误 + 点击重试」、「这个平台看不到评论」。

### 3.2 纯逻辑（不需要设备）

`PlatformComment.ets` 里把各平台的解析器都导出了，可以直接对真实响应做断言
（与 `MusicSearch.ets` 导出 `parseKwResult` 等同一套做法）：

`parseKwComments` / `parseKgComments` / `parseMgComments` / `parseTxComments` /
`parseTxHotComments` / `parseWyComments` / `kgSignature` / `relativeTime` / `dedupeComments`。

回归办法见 `docs/DEFECTS.md` 末尾：把纯逻辑文件复制成 `.ts`，用 DevEco 自带的 Node 跑
`node --experimental-strip-types <script>.ts`，喂真实响应片段做断言。

---

## 4. 已知限制 / 待实测

> **重要**：这份实现写完时**没有在设备上联网验证过**（只过了静态检查与整包构建）。
> 各平台的接口是照洛雪原样移植的，但「接口现在是否还接受这种调用」必须在设备上确认。
> 下表是预期状态，实测后请把结论补进来（与 `docs/DEFECTS.md` 的记录规则一致）。

| 平台 | 预期 | 备注 |
| --- | --- | --- |
| kw | 可用 | 接口是 `http://`（明文），与现有的 kw 搜索/歌词同一个域名族 |
| kg | 可用 | 签名算法与搜索用的 `signatureParams` 同源 |
| tx | 可用 | 最新/热门两个接口都在用；热门那条走 musicu，与歌单详情同一个端点 |
| mg | 可用 | 游标翻页要顺序来 |
| wy | **待实测** | 评论走的是公开 `/api/v1/resource/comments`（不是洛雪的 weapi）。wy 的搜索链路本身还没修通（`docs/DEFECTS.md` **D-001**），评论要和它一起回归 |

还有两处**没做**（用得上再加）：

- 评论**点赞 / 回复 / 发评论**：落雪移动端也只有看，没有发（要登录态）；
- 评论**图片点开看大图**：现在是固定方框内 `Contain` 显示，没有大图查看器。
