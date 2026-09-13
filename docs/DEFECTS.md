# 待办缺陷（DEFECTS）

记录已知但**尚未处理**的缺陷与待办。每条都必须能复现、能验收，写完就留着，
处理时按「验收标准」逐条勾掉，再把状态改成已修复并注明日期与提交。

## 记录规则

- 编号 `D-xxx`，按发现顺序递增，不复用。
- 每条包含：状态 / 优先级 / 发现日期 / 影响面 / 证据 / 复现 / 涉及代码 /
  待办拆解 / 参考 / 验收标准。
- 证据要写**可重跑的命令与真实响应片段**，不要只写结论；
  网络类问题必须写清时间，接口是会变的。
- 已修复的条目不要删，改成「已修复」并保留结论，避免以后重复踩。

状态取值：`待处理` / `处理中` / `已修复` / `不修复（写明原因）`。

---

## D-001 · 网易(wy)链路整体不通：搜索与歌词接口都返回 404

| 项 | 内容 |
| --- | --- |
| 状态 | **待处理** |
| 优先级 | P1（用户可见：选「网易」搜不到歌、网易来源的歌没有歌词） |
| 发现日期 | 2026-09-13 |
| 发现方式 | 直接请求真实接口（curl / Node），不是从 App 日志推断 |

### 影响面

1. **搜索**：搜索页平台选「网易」时 `searchWy()` 会拿到 `code:404`，
   代码里对非 200 只做 `continue` 重试 3 次，最后返回空数组 →
   界面显示「没有搜索结果（网易）」。**故障被伪装成「没搜到」**，
   用户与开发者都看不出是接口挂了。→ 顺带需要区分「接口不可用」与「无结果」。
2. **歌词**：内置平台歌词已覆盖 kw / kg / tx / mg，网易没有实现
   （`PlatformLyric.ets` 的 `fetchPlatformLyric()` 里没有 wy 分支），
   网易来源的歌一律显示「暂无歌词」。
3. **封面**：网易搜索结果本身带 `album.picUrl`，这条不依赖上面的问题，
   但搜索不通就都用不上。
4. **文档**：`docs/LX_SOURCE_ENGINE.md` 早期写过「五个平台内置搜索全部有效」，
   对网易不成立，已在 2026-09-13 修正为待复核；本条目跟踪真正的修复。

### 证据（2026-09-13 实测）

请求体用洛雪的 eapi 加密方式生成（`createEapiParams`，与我们代码一致）：
`params = hexUpper(AES-128-ECB/PKCS7(key='e82ckenh8dichen8', "<url>-36cd479b6b5-<json>-36cd479b6b5-<md5>"))`

| 请求 | 结果 |
| --- | --- |
| `POST http://interface.music.163.com/eapi/batch`，摘要路径 `/api/search/song/list/page` | `code:404`（带 cookie 也是 404） |
| `POST https://interface.music.163.com/eapi/batch`，同上 | `code:404` |
| `POST https://interface3.music.163.com/eapi/song/lyric/v1`，body `{id,cp,tv,lv,rv,kv,yv,ytv,yrv}` | 先 `code:400`，补 `header:{os:'pc',...}` 与 cookie 后 `code:404` |
| 同上传参，改用洛雪的加密写法（先把 payload 转 base64 再 AES，再对密文做一次 base64 解码） | 同样 `400` / `404` |

结论：不是「缺某个参数」这么简单——**两种加密写法都被拒**，连搜索路径也是 404，
更像是接口路径/客户端版本已经不接受这种 eapi 调用了。

### 复现

宿主侧（DevEco 自带 Node 即可，不需要设备）：

```bash
cd /tmp && node wy_recipe_test.js   # 本次排查用的脚本：对比两种 eapi 加密写法
# 关键点：md5("nobody"+path+"use"+text+"md5forencrypt") → AES-128-ECB → hexUpper
# 然后 POST interface.music.163.com /eapi/batch，看返回的 code
```

> 本次排查脚本放在系统临时目录（未入库）。重做时建议直接进仓库，比如
> `tools/wy_probe.js`，这样下次排查不用重写。

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `entry/src/main/ets/core/music/MusicSearch.ets:965` | `createEapiParams()` eapi 加密（本次已与另一种写法对比验证） |
| `entry/src/main/ets/core/music/MusicSearch.ets:972` | `parseWySongs()` 结果解析（解析逻辑本身未验证过，因为拿不到响应） |
| `entry/src/main/ets/core/music/MusicSearch.ets:1029` | `searchWy()`，失败被吞成空数组（见「影响面 1」） |
| `entry/src/main/ets/core/music/MusicSearch.ets:1077` | `httpPostForm()`（form 表单提交，与 wy 搜索/歌词共用） |
| `entry/src/main/ets/core/music/PlatformLyric.ets:385` | `fetchPlatformLyric()`，缺 wy 分支 |
| `entry/src/main/ets/core/music/LxCrypto.ets` | `aes128EcbPkcs7HexUpper` / `md5Hex`（eapi 依赖） |

### 待办拆解

1. **先定性**：抓一份当前网易客户端/网页版真实的搜索请求，确认现在用的
   接口路径、客户端类型（eapi / weapi / linuxapi / 网页 api）与必填字段。
   - 起点参考：`Binaryify/NeteaseCloudMusicApi` 的 `module/search.js`、
     `module/lyric_new.js`，以及 `util/crypto.js` 的 eapi 实现。
2. **核对加密细节**：`header` 是否必填、`os` 取值、是否必须带
   `MUSIC_U` / `__csrf` / `deviceId` cookie；AES 填充到底是 PKCS5 还是 NoPadding
   （我们文档记的是「`ECB_128_NoPadding` 实为 PKCS5」，需以真实可用的实现为准）。
3. **换路径**：若 `/api/search/song/list/page` 已废弃，改用可用路径
   （如 v1/cloudsearch 系列），同步改 `parseWySongs()` 的解析字段。
4. **歌词**：搜索通了之后，在 `PlatformLyric.ets` 加 `wyLyric()`，
   返回明文 LRC（`lrc.lyric` / `tlyric.lyric`），复用现有的 `parseLyric`。
5. **顺手修「静默失败」**：`searchWy()` 在接口不可用时应抛出明确错误
   （如「网易接口返回 404，可能已变更，请查看 docs/DEFECTS.md D-001」），
   不要退化成空数组；`PlatformLyric` 侧保持返回空即可（界面已有「暂无歌词」）。

### 验收标准

- [ ] 搜索页选「网易」，关键词能返回结果（用 3 个不同关键词各试一次）。
- [ ] 网易结果点播放能出声（走源规则解析播放链接）。
- [ ] 网易歌曲的歌词页能显示并跟随滚动（含至少 1 首带翻译的歌）。
- [ ] 接口不可用时抛出可读错误，不再是「没有搜索结果」。
- [ ] `docs/LX_SOURCE_ENGINE.md` 里 wy 的「待复核」标注可以撤掉。
- [ ] 排查脚本入库到 `tools/`，并记录最终可用的请求形态。

---

## 其他待办（不是缺陷，按需排期）

- **歌词逐字（`lxlyric`）**：洛雪的富文本歌词（逐字时间轴）目前未使用，
  只用了 `lyric`/`tlyric`。`lx_preload.js` 已经在回传 `lxlyric`，
  `PlatformLyric` 侧丢弃了。
- **设计债**：`SongListPane`（「我的」与搜索结果共用的歌曲列表）仍是自绘行，
  它的父容器是 `Scroll`，换成官方 `List` 需要连父级一起改；主页签大标题也仍是自绘。
- **占位功能**：歌单排序、新建歌单、播放页的铃声/下载/更多等入口目前只弹提示。
- **咪咕/网易封面**：mg 搜索结果自带 `img`，wy 也自带（但搜索不通）；
  kw/kg 已有内置取图，其余平台暂未补。

---

## 附：本次已验证可用的链路（别动坏）

以下都是 2026-09-13 用真实请求**实测通过**的，后续改动请回归：

| 能力 | 形态 | 验证方式 |
| --- | --- | --- |
| 搜索 kw | `GET search.kuwo.cn/r.s?...` 明文 JSON | 真实请求 |
| 搜索 kg | `GET songsearch.kugou.com/song_search_v2?...` 明文 JSON | 真实请求 |
| 搜索 mg | `GET jadeite.migu.cn/.../searchAll?...`（md5 签名） | 真实请求 |
| 搜索 tx | `POST u.y.qq.com/cgi-bin/musics.fcg?sign=<zzcSign>` | 真实请求 |
| 歌词 kw | `GET mlyric.kuwo.cn/mobi.s?...&lrcx=1` → inflate → base64 → XOR `yeelion` | 真实响应 + 同源代码解码（42 行，时间轴单调） |
| 歌词 kg | `GET lyrics.kugou.com/search` → `download?fmt=lrc` → base64 → 明文 LRC | 真实响应 + 同源代码解码 |
| 歌词 tx | `GET c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?...&nobase64=1`（需 Referer） | 真实响应 + 同源代码解码 |
| 歌词 mg | `POST c.musicapp.migu.cn/.../resourceinfo.do`（form `resourceId`）拿 `lrcUrl` → 明文 LRC | 真实响应 + 同源代码解码 |
| 封面 kw | `GET artistpicserver.kuwo.cn/pic.web?...&rid={songmid}` | 照抄 LX `kw/pic.js` |
| 封面 kg | `POST media.store.kugou.com/v1/get_res_privilege`（需 `KG-RC`/`KG-THash`） | 照抄 LX `kg/pic.js` |

回归办法（无需设备）：把 `entry/src/main/ets/core/music/*.ets` 里对应的纯逻辑文件
复制成 `.ts`，用 DevEco 自带 Node 跑
`node --experimental-strip-types <script>.ts`，对真实响应做断言。
`docs/LX_SOURCE_ENGINE.md` 里有各接口的详细说明。
