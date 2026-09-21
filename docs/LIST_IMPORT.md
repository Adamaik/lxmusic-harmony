# 歌单导入（第三方歌单分享链接）

把网易云 / QQ / 酷狗 / 酷我 / 咪咕的**歌单分享链接**粘贴进来，解析出平台与歌单 id，
拉全量歌曲后落成本地歌单（与洛雪桌面版「导入歌单」是同一件事）。

## 入口

| 位置 | 场景 |
| --- | --- |
| 歌单页右上角的导入钮（`sys.symbol.square_and_arrow_down`） | 粘贴整段分享内容或一条链接 |
| 在线歌单详情页的导入钮（仅 `kind=playlist`） | 平台与歌单 id 已经知道，直接带进面板 |

面板流程：粘贴 -> 解析 -> 预览（歌单名 / 作者 / 曲目数 / 前几首）-> 导入。
大歌单会显示「正在获取歌曲 x/y」，导入时若发现这个线上歌单导入过，按钮变成
「更新「<歌单名>」」，不会再建一个同名列表。

## 代码位置

| 职责 | 文件 |
| --- | --- |
| 分享文本 -> `{source, id, listId}`（含短链跟随、`lxmusic://` 深链） | `core/music/PlaylistLink.ets` |
| 歌单歌曲：一页 / 全量翻页（`getPlaylistDetail` / `getPlaylistDetailAll`） | `core/music/MusicList.ets` |
| 落成本地歌单（去重、`source` / `sourceListId`、重复导入即更新） | `core/sync/LocalLibrary.ets`（`importPlaylist` / `playlistBySourceListId`） |
| 导入面板 | `views/ImportPlaylistSheet.ets` |
| 请求头读取重定向（`maxRedirects: 0`，短链用） | `core/source/LxHttp.ets` |

## 链接规则

正则照抄洛雪各平台 `songList.js` 的 `listDetailLink`（见
`lx-music-mobile/src/utils/musicSdk/{wy,mg,kw,kg,tx}/songList.js`），
不是自己编的——这样「哪些链接算歌单链接」与官方客户端一致。

| 平台 | 认得的链接 | 对应洛雪正则 |
| --- | --- | --- |
| 网易 wy | `music.163.com/#/playlist?id=<id>`、`/playlist?id=<id>&userid=`、`/playlist/<id>/<x>/` | `listDetailLink` + `listDetailLink2` |
| QQ tx | `y.qq.com/n/ryqq/playlist/<id>`、`i.y.qq.com/.../taoge.html?id=<id>` | `/\/playlist\/(\d+)/` + `/id=(\d+)/` |
| 酷狗 kg | `kugou.com/yy/special/single/<id>.html` | `/^.+\/(\d+)\.html/` |
| 酷我 kw | `kuwo.cn/playlist_detail/<id>`、`m.kuwo.cn/h5app/playlist/<id>` | `/^.+\/playlist(?:_detail)?\/(\d+)/` |
| 咪咕 mg | `music.migu.cn/v5/#/playlist?playlistId=<id>`、`h5.nf.migu.cn/.../playlist/index.html?id=<id>`、`/v3/music/playlist/<id>` | `/^.+\/playlist\/(\d+)/` + `playlistId=(\d+)` |

另外支持两类「非链接」输入：

- 洛雪自己的分享链接：`lxmusic://songlist/open/<source>/<id|链接>`（`play` 动作参数一样），
  以及带 `?data=<JSON>` 的形式（`source` / `id` / `url` 是三个独立字段）；
- 直接给洛雪的列表标识 `${source}__${id}`，例如 `wy__2892110024`。

分享文本里有中文标点时按标点截断（`分享歌单《x》https://...，快来听`）；
但 `?` `&` `!` 是 URL 自己的字符，不能当标点截——踩过这个坑：截掉查询串之后
`playlist?id=` 就没了，解析永远失败（单测 `takesFirstUrlOutOfShareText` 守住这点）。

### 短链

`163cn.tv` / `c.migu.cn` / `t1.kugou.com` 这类短链本地正则抠不出 id，此时跟随一次
重定向再看最终地址（洛雪各平台的 `handleParseId`）。系统默认的自动重定向跟完读不到
最终地址（响应里的 `url` 只是请求地址），所以请求时 `maxRedirects: 0`，自己读 3xx 的
`Location`；有些短链不做 3xx 而是在 HTML 里跳（meta refresh / `location.replace`），
这种情况再从响应体里捞一次。

### 单曲链接

网易/QQ 的单曲、专辑、歌手链接也带 `id=`，不挡住就会拿单曲 id 去当歌单 id
（表现是「接口返回异常」）。所以命中 `/song`、`songDetail`、`play_detail`、`/album`、
`/mv`、`/singer` 这几种路径时直接判为不是歌单，并给出
「这是<平台>的单曲链接，不是歌单链接」的提示。

## 导入语义

对齐洛雪 `views/songList/Detail/action.ts` 的 `addSongListDetail`：

- 本地歌单 id = `<平台>_<md5(平台__歌单id)>`。同一个线上歌单反复导入都是同一个本地歌单，
  不会堆出一串同名列表；
- 一并写 `source` 与 `sourceListId`（`sourceListId` = `${source}__${id}`，与解析出的
  `listId` 一致）。这两个字段在洛雪同步协议里本来就有，服务端与官方客户端都认；
- 再次导入同一个线上歌单 = 原地更新（改名 + 用线上最新歌曲覆盖），并上行
  `list_update` + `list_music_overwrite`；
- 歌曲去重按洛雪的 id 规则（`core/music/MusicId.ets`），与同步结构一致，
  所以导入的歌能正常同步、收藏红心也能对上。

> 洛雪原版这里有个小毛病：判断重复时拿 `${source}__${id}` 去比 `sourceListId`，
> 但存进去的是裸 `id`，所以那个判断永远不成立（重复导入会新建列表）。
> 本实现按「存什么就比什么」来，两边都用 `${source}__${id}`。

## 全量翻页

`getPlaylistDetailAll` 一页页拉到拉不动为止，终止条件是「这一页没有带来新歌」：

| 平台 | 一次给多少 | 行为 |
| --- | --- | --- |
| 酷我 kw | 1000（`pn`/`rn`） | 正常翻页 |
| 咪咕 mg | 30（`pageNo`/`pageSize`） | 真的在翻页，100 首 = 4 次请求 |
| 网易 wy | 一次给全（`n=1000`，且只回可播放曲目） | 第二页原样再给一份 -> 判定无新歌即停 |
| 酷狗 kg / QQ tx | 一次给全 | 同上 |

页数上限 40（咪咕 ≈1200 首），避免接口异常时无限翻。

## 验证方式

```bash
# 1) 纯解析逻辑（离线，随单测跑）
#    entry/src/test/PlaylistLink.test.ets
devecocli test --modules entry --scope playlistLinkTest

# 2) 各平台歌单详情接口的真实可用性（PC 侧直连，不需要音源）
node tools/live_list_probe.js          # 五个平台各跑一遍
node tools/live_list_probe.js kw wy    # 只跑指定平台
node tools/live_list_probe.js --detail tx 3285516001   # 指定 id
```

`live_list_probe.js` 会先走一遍各平台「歌单广场」拿一张真实歌单 id，再用这张 id 走详情接口，
所以不需要事先知道 id。2026-09-20 实测（`kw/kg/mg/tx/wy` 五个平台全部取到歌曲）：

```
✅ kw  id=3677488020  「爱的故事翻篇，被爱的人不用道歉」 total=121 取到=121
✅ kg  id=3339907     「乡村之旅：安静惬意·与自然同在」 total=30  取到=26
✅ mg  id=234118228   total=100 取到=30（一页 30 首，翻页在 App 里做）
✅ tx  id=3285516001  「韩流先锋 | 被冠以国民称号的韩国艺人」 total=50 取到=50
✅ wy  id=18129092448 「绿茵摇滚诗：英格兰世界杯回响」 total=26 取到=10
```

设备侧还临时跑过一遍联网用例（解析 -> 拉全量 -> 转 SongItem -> `importPlaylist` 两次，
断言同一个线上歌单只对应一个本地歌单），5/5 通过；这类用例依赖外网、接口会变，
不适合长期放在单测里，验证完即删。

## 已知限制

- **酷狗用户歌单**（`kugou.com/songlist/xxx/?uid=` 这种）不支持：它走的是另一套接口
  （`global_collection_id` / `gcid_`），内置歌单详情只有「精选集」（specialid）那条路。
- **网易**只返回当前可播放的曲目（`privileges` 里没版权的会少），`total` 仍按 `trackIds` 计，
  所以预览里的「N 首」可能比实际导入的多。另见 `DEFECTS.md` 的 D-001（网易端点整体待复核）。
- **咪咕**一页 30 首，几百首的歌单要发十几次请求，导入会有明显等待（面板里有进度提示）。
- 榜单（`bangid`）不提供导入入口：它和歌单 id 不是一回事，导成本地歌单后没法按源刷新。
