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

1. **搜索**：搜索页搜「网易」时 `searchWy()` 会拿到 `code:404`，
   代码里对非 200 只做 `continue` 重试 3 次，最后返回空数组 →
   界面显示「没有搜索结果（网易）」。**故障被伪装成「没搜到」**。
   → **「静默失败」这一半已修复（2026-09-21）**：接口报错现在如实抛出
   （`网易接口返回 code 404（该接口当前不可用）`），kg / tx / mg 同样处理；
   搜索页改成聚合搜索后，状态行与空态会直接写出「网易 失败」。
   接口本身仍然不通，这条待办不变。
2. **歌词**：内置平台歌词已覆盖 kw / kg / tx / mg；网易原先没有实现，
   2026-09-23 补上了 `PlatformLyric.wyLyric()` —— 改走**公开 GET** `/api/song/lyric`
   （不是 eapi），与搜索一样属于**待实测**（搜索不通时在设备上没法确认）。
3. **封面**：网易搜索结果本身带 `album.picUrl`，这条不依赖上面的问题，
   但搜索不通就都用不上。
4. **文档**：`docs/LX_SOURCE_ENGINE.md` 早期写过「五个平台内置搜索全部有效」，
   对网易不成立，已在 2026-09-13 修正为待复核；本条目跟踪真正的修复。
5. **评论**（2026-09-23 追加）：评论也只能走内置平台接口（源规则里没有「取评论」这个 action，
   见 `docs/SONG_COMMENT.md`），网易那条用的是公开 `/api/v1/resource/comments`（不是洛雪的 weapi），
   与歌词同样属于**待实测** —— 搜索不通之前没法在设备上确认，需与本条目一起回归。

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
| `entry/src/main/ets/core/music/MusicSearch.ets:1071` | `createEapiParams()` eapi 加密（本次已与另一种写法对比验证） |
| `entry/src/main/ets/core/music/MusicSearch.ets:1101` | `parseWySongs()` 结果解析（解析逻辑本身未验证过，因为拿不到响应） |
| `entry/src/main/ets/core/music/MusicSearch.ets:1165` | `searchWy()`：失败已改为抛错（见「影响面 1」），接口仍不通 |
| `entry/src/main/ets/core/music/MusicSearch.ets:1221` | `httpPostForm()`（form 表单提交，与 wy 搜索/歌词共用） |
| `entry/src/main/ets/core/music/PlatformLyric.ets` | `wyLyric()`：公开 GET `/api/song/lyric`（待实测） |
| `entry/src/main/ets/core/music/PlatformComment.ets` | 内置平台评论的 `wyComments()`（公开 `/api/v1/resource/comments`，待实测）与 `parseWyComments()` |
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
5. ~~**顺手修「静默失败」**~~ **已完成（2026-09-21）**：`searchWy()` 在接口不可用时
   抛出明确错误（`网易接口返回 code 404（该接口当前不可用）`），不再退化成空数组；
   `searchKg()` / `searchTx()` 同样按接口返回码抛错，`searchMg()` 本来就是抛错。
   `PlatformLyric` 侧保持返回空即可（界面已有「暂无歌词」）。

### 验收标准

- [ ] 搜索页搜「网易」（不筛平台），关键词能返回结果（用 3 个不同关键词各试一次）。
- [ ] 网易结果点播放能出声（走源规则解析播放链接）。
- [ ] 网易歌曲的歌词页能显示并跟随滚动（含至少 1 首带翻译的歌）。
- [x] 接口不可用时抛出可读错误，不再是「没有搜索结果」。（2026-09-21，见「影响面 1」）
- [ ] `docs/LX_SOURCE_ENGINE.md` 里 wy 的「待复核」标注可以撤掉。
- [ ] 排查脚本入库到 `tools/`，并记录最终可用的请求形态。

---

## D-002 · QQ(tx)歌单详情接口已下线：老接口 code=-1，导致 QQ 歌单页空列表

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-20） |
| 优先级 | P2（用户可见：QQ 歌单广场点进去取不到歌；「导入歌单」在 QQ 分享链接上失败） |
| 发现日期 | 2026-09-20 |
| 发现方式 | 新增的 `tools/live_list_probe.js` 直连真实接口 |

### 影响面

1. **导入歌单**：粘贴 QQ 歌单分享链接时，解析出的 `disstid` 交给
   `txPlaylistDetail()`，接口返回 `code=-1` → 面板报「QQ 歌单详情接口返回异常」。
2. **在线歌单**：推荐页里 QQ 平台点进歌单详情同样是空列表（同一个函数）。
   注意搜索、排行榜走的是别的端点，不受影响。

### 证据（2026-09-20 实测）

老接口（`c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?disstid=...`）：

```
$ node tools/live_list_probe.js --detail tx 3285516001
❌ tx  code=-1
```

新版 `musicu.fcg`（`music.srfDissInfo.aiDissInfo` / `uniform_get_Dissinfo`，POST JSON）
同一个 id：`code=0`、`req_1.code=0`、`total_song_num=50`、`songlist` 50 首，
字段与老接口的 `cdlist[0].songlist` 是同一套（`mid`/`name`/`singer[].name`/`file.size_128mp3`）。

### 涉及代码

`entry/src/main/ets/core/music/MusicList.ets` 的 `txPlaylistDetail`。

洛雪本来有两条路（`tx/songList.js` 的 `getListDetail` 与 `getListDetail2`），
但顺序是老接口优先、失败才走新版，而老接口现在是「有响应但 `code=-1`」，
按洛雪的逻辑会重试 3 次后直接失败。本实现把顺序反过来：**新版优先、老接口兜底**，
两条路的 songlist 共用同一个 `txFilterSongs`。

### 验收标准

- [x] `node tools/live_list_probe.js tx` 能取到歌曲（实测 50/50）。
- [x] 设备侧联网用例导入 QQ 歌单成功（`getPlaylistDetailAll('tx', ...)` 返回非空、
      歌单名非空）。
- [x] 老接口没有删掉：新版万一再变，仍可退回（`txPlaylistDetailLegacy`）。
- [ ] 推荐页点进 QQ 歌单详情，界面能看到歌曲（需真机回归一次）。

---

## D-003 · 下载一直落在应用内目录：DOWNLOAD 模式的返回值理解错了

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-20，用户真机实测下载成功、文件出现在「文件管理」里） |
| 优先级 | P1（用户可见：下载的歌在「文件管理」里找不到，等于下了个看不见的文件） |
| 发现日期 | 2026-09-20 |
| 发现方式 | 用户真机点「下载」后看到提示「已存到应用内目录」；对照官方 `save-user-file` 文档定位 |

### 影响面

1. 老代码把 `DocumentViewPicker.save(pickerMode = DOWNLOAD)` 的返回值当成**文件 uri**，
   用 `openSync(uri, READ_WRITE | TRUNC)` 打开；
2. 官方文档写明：DOWNLOAD 模式返回的是**目录** uri（`Download/<应用名>/`，带持久化权限），
   文件名要自己拼、文件要自己 `CREATE`：

```ts
// 官方 save-user-file「DOWNLOAD模式保存文件」
documentViewPicker.save({ pickerMode: DocumentPickerMode.DOWNLOAD }).then((r) => {
  const testFilePath = new fileUri.FileUri(r[0] + '/test.txt').path;
  const file = fileIo.openSync(testFilePath, OpenMode.CREATE | OpenMode.READ_WRITE);
});
```

3. 于是每次下载的第一次尝试都失败（目录打不开），静默退到应用内 `files/Download`：
   歌能下、能播，但**在「文件管理」里看不到**，用户也就没法把文件拷出去。
   下载前那个「保存位置」选项（手动选择/Download目录）因此形同虚设。

### 修复

`DownloadManager.openViaPicker`：拿到目录 uri → 拼文件名 → `fileUri.FileUri(...).path`
→ `openSync(CREATE | READ_WRITE)`；同时去掉 `newFileNames`（DOWNLOAD 模式下该选项不生效）。
失败时不再静默：原因（错误码 + 消息）写进 `DownloadItem.note`，列表里直接显示。

真机验证：文件出现在「文件管理」的「最近」页，按应用分组显示（分组名 = 应用名「聆听」）；
hdc 截图证据见提交说明。

### 验收标准

- [x] 真机下载一首歌，文件出现在「文件管理」里（不再只是应用内目录）。
- [x] 下载列表不再出现「已存到应用内目录」的提示。
- [x] `entry` 单测 28/28 通过（下载设置结构变化没有破坏其它链路）。
- [x] 保存位置选项已删除（用户要求），设置页只读展示「下载目录」。
      （一开始做的是「保存位置 + 打开文件夹」动作行，查证平台无跳转能力后按用户决定
      改成只展示，见 D-004。）

---

## D-004 · 无法「打开下载文件夹并定位到目录」—— 平台没有这个能力（按钮已取消）

| 项 | 内容 |
| --- | --- |
| 状态 | **不修复**（平台能力缺失，写明依据与替代做法） |
| 优先级 | P3（体验项：按钮只能打开文件管理首页，不能直达目录） |
| 发现日期 | 2026-09-20 |
| 发现方式 | 官方文档 + 本机 SDK 检索 + 真机实测（用户反馈「只是打开文件管理，没跳转」后查证） |

### 依据

1. **官方「常见预置应用的跳转方式」**（华为开发实践，知乎/腾讯云有镜像）里，
   文件管理一行是：action「不需传值」、bundleName `com.huawei.hmos.filemanager`、
   abilityName `MainAbility`、uri「不需传值」—— 即**只能打开文件管理，不能指定目录**。
2. **官方 File Manager Service Kit**（本机 SDK `@hms.filemanagement.fileManagerService.d.ts`）
   导出的能力只有三个：`deleteToTrash` / `getFileIcon(Sync)` / `parseShortcut`（解析 `.hlink`
   快捷方式文件），没有任何「打开目录 / 跳转到路径」的接口。
3. **真机实测**（2026-09-20，`aa start` 逐条试 + 截图判定）：
   - `filemanager://openDirectory`（这是文件管理自己声明的技能，见 `bm dump -n com.huawei.hmos.files`
     的 skills：`action.system.home` + `entity.system.home` + scheme `filemanager` / host `openDirectory`）
     带 `path`（沙箱路径或 doc uri）、`uri`、`sandboxPath` 参数，以及把路径塞进 uri 查询串或路径段 ——
     六种写法都只是把文件管理拉到默认页（「最近」），不跳转；
   - `ohos.want.action.viewData` + 目录 uri + `vnd.android.document/directory`：弹出
     「选择打开方式」并列出第三方应用（奇妙下载等），文件管理**并未**声明目录类型的 viewData
     （它只声明了压缩包类型）。

### 处理方式（2026-09-20 决定）

**不提供跳转按钮**，只在「设置 - 下载设置」里把下载目录显示出来（只读），
让用户自己去「文件管理 → 下载」里找：

- 按钮即使做了也只能把文件管理拉到首页（见上面的实测），点了没跳转反而误导；
- 目录名固定为「下载/<应用名>」，显示出来就够用户定位；
- 原来加在设置页/下载管理页的「打开文件夹」入口与 `DownloadManager.openDownloadFolder()`
  已按此决定删除。

### 可选的替代（需要时再做）

- 系统文件选择器有「文件夹模式」且支持 `defaultFilePathUri` 定位到指定目录：
  能被定位到我们的下载目录并列出文件，但它是**选择器**界面（看完要按取消退出），不是文件管理；
- 应用内自带文件夹视图（列出文件 + 分享/导出/删除），完全不依赖文件管理 —— 最可控，
  目前的「我的 - 下载管理」已经是它的雏形。

---

## D-005 · 书源「从文件导入」必然失败：Picker 的 URI 被直接交给 `readTextSync`

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-27） |
| 优先级 | P0（导入是听书的唯一入库口，坏了整栏不可用） |
| 发现日期 | 2026-09-27 |
| 发现方式 | 用户真机操作：在「听书 - 书源」里选下载目录中的书源 `.json`，直接提示 `No such file or directory` |

### 影响面

「导入书源」有两个入口：**粘贴 JSON** 与**选文件**。粘贴那条一直是好的
（`tools/book_import_test.js` 里 7 个真实源逐个验过），选文件这条**必然失败** ——
书源根本进不来，后面的搜索 / 目录 / 播放全都无从谈起。**与规则引擎无关**：
同一批源在 `book_engine_selftest.js` 里离线 28 项全过、联网也能搜出结果。

### 根因

`BookEngine.importFromUri()` 把 Picker 返回的 `file://docs/...` 直接喂给 `fs.readTextSync`。
`readTextSync` 的第一个参数只认**沙箱路径**（本 SDK 的声明只收 `string`，连 fd 都不收），
URI 只有 `fs.openSync` 认 —— 于是报 `No such file or directory`。

工程里本地音乐导入（`core/local/LocalMusic.ets` 的 `importOne`）用的就是正确写法
（`fs.openSync(uri, fs.OpenMode.READ_ONLY)` 拿 fd 再读），只有书源这一处写错了。

### 证据

```bash
node tools/book_import_test.js
# 静态守卫两行：
#   ✓ 没有把 Picker URI 直接传给 readTextSync
#   ✓ importFromUri 用 openSync(uri, READ_ONLY) 打开再读
```

把守卫指向修复前的写法（`readTextSync(uri)`）会立刻变红，可当回归用。

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `core/book/BookEngine.ets` · `importFromUri()` | 修复点：`openSync(uri)` → 读字节 → `bytesToUtf8()` 解码 |
| `views/ListenView.ets` · `pickSourceFile()` | 结果提示原本写成 `!== undefined ? '' : ''`，改成如实报「已导入 N 个书源：…」 |

### 验收标准

- [ ] 真机：从下载目录选一个书源 `.json`，提示「已导入 1 个书源：…」且书源列表出现该源。
- [ ] 导入后在同页「搜索」分段能搜出结果。
- [x] 静态守卫通过（见上）。2026-09-27

---

## D-006 · 书源请求被套用音源的 `application/json` 默认头：书音FM 的 POST 搜索拿不到结果

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-27，站点本机不可达，**待真机回归**） |
| 优先级 | P1（只影响用 POST / 挑 `Accept` 的源；这批 7 个源里是书音FM） |
| 发现日期 | 2026-09-27 |
| 发现方式 | 读代码比对：应用侧 `BookHttp.bookRequest` → `LxHttp.lxRequest` 的默认头，与自检脚本的宿主代理不一致 |

### 影响面

`bookRequest` 复用音源的 `lxRequest`，而后者为音源写死了两个默认头（`LxHttp.ets:149-150`、`177`）：

| 默认 | 对音源 | 对书源 |
| --- | --- | --- |
| `Accept: application/json` | 对 | 错 —— 书源抓的是 HTML / XML / RSS，且有些站按 `Accept` 给不同内容 |
| POST 无 Content-Type 时按 `application/json` 且 `JSON.stringify(body)` | 对 | 错 —— 书源的 POST 正文是**原样字符串**（`keyboard={{key}}&show=…`）|

这批 7 个源里只有**书音FM** 用 POST（`searchUrl` 里的 `{"method":"POST","body":"keyboard=…"}`），
且**没有一个源写 Content-Type** —— 也就是它的表单正文会被标成 JSON 发出去，
EmpireCMS 站直接回一张错误页，搜索表现为「0 条」（`docs/BOOK_SOURCE_ENGINE.md`
里记的「书音FM ⚠️ 要先给 cookie 才回结果页」，至少有一部分是这里）。

### 证据

```bash
# 只有书音用 POST，且 7 个源都没有 Content-Type：
node -e "const fs=require('fs');for(const f of fs.readdirSync('D:/harmony/听书的源').filter(x=>x.endsWith('.json'))){const s=JSON.parse(fs.readFileSync('D:/harmony/听书的源/'+f,'utf8'));const b=JSON.stringify(s);console.log(f,'POST',b.includes('POST'),'CT',/content-type/i.test(b));}"
```

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `core/book/BookHttp.ets` · `bookRequest()` | 修复点：缺 `Accept` 时补 `*/*`；POST 缺 `Content-Type` 时补 `application/x-www-form-urlencoded`（`options.headers` 会覆盖 `lxRequest` 的默认值，所以不用改音源那份）|
| `core/source/LxHttp.ets` | **未改动** —— 音源的行为一个字没变 |

### 验收标准

- [ ] 真机 / 联网：书音FM 搜一个常见书名能返回结果（书音本身还要求先带 cookie，见书源引擎文档）。
- [x] 静态守卫：`tools/book_import_test.js` 里两条请求头守卫通过。2026-09-27
- [x] `book_engine_selftest.js` 离线 28 项无回归。2026-09-27

---

## D-007 · 听书没接进下载系统：下载菜单对书集照样显示，点了必然失败

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-27，接入完成；真机回归见「验收标准」） |
| 优先级 | P1（不是「没入口」，而是**入口在、必然失败**，报的还是音源的消息） |
| 发现日期 | 2026-09-27 |
| 发现方式 | 排查播放链路时顺着 `BOOK_SOURCE` 的引用点找出来的：下载侧一处都没有 |

### 影响面

「听书」只接到了播放链路（`PlaySession` 有 4 处显式分支：播放 / 不预取 / 封面 / 无歌词），
下载与播放缓存都没接：

1. `DownloadManager.resolveUrl` 只有一条路 —— `SourceEngine.getMusicUrl(...)`，
   把书的载荷当歌去问洛雪音源；
2. 下载入口的拦截只认本地歌与云端歌（`isLocalSong` / `isWebDavSong`），**没有书的对应守卫**，
   所以队列 / 播放页 / 播放列表里书集的长按菜单**照样显示「下载」**；
3. 点下去 `downloadKeyOf` 退回 `song.id`（形如 `book_<书目id>_<集号>`，非空）→ `enqueue` 收下 →
   真正开工时抛「音源没有加载，先去『设置 - 音源设置』加载一个音源」或
   「这首歌没有可解析的歌曲信息（不是平台搜索结果）」→ 下载列表里凭空一条失败记录。

也就是说：**书集能点下载、必然失败、失败原因指向音源**，这三件事叠在一起最容易让人误判成
「音源坏了」。

### 处理方式（2026-09-27 接入）

按第三条下载链路接进去（与平台歌 / 洛雪音源并列），细节与取舍见
`docs/BOOK_SOURCE_ENGINE.md` 第 8 节。要点：

| 环节 | 做法 |
| --- | --- |
| 解析 | `resolveUrl` 加 `BOOK_SOURCE` 分支 → `resolveBookUrl`，调用**播放用的同一个** `BookEngine.resolveAudioOf` |
| 请求头 | 解析结果带出 `audioHeaders`，`requestInStream(..., { header })` 带上（CDN 校验 Referer） |
| 键 | 退回条目 id（书载荷算不出 mediaKey），与播放链路同一个 id |
| 文件名 | `书名-章节名`，不缀音质 |
| 标签 | 不写（音乐那套对书没有意义；m4a 本来就写不了） |
| 限速 | 有声书串行 + 集间 1s（下一集要抓页面 + 跑规则） |
| 离线 | `playBookItem` 先查 `downloadedFile(item.id)`，命中就播本地；**放在书源检查之前** |
| 自动下载 | 有声书不参与「缓存时自动下载」（那条设置是给播放缓存配套的，书没有播放缓存） |
| 界面 | 长按某集 → 下载本集 / 删除下载；目录行 → 下载整本（先确认） |

### 证据

```bash
node tools/book_import_test.js
# 「契约：有声书条目的下载键与载荷」与「静态守卫：接线留在哪几处」两节
# 结果：42 通过 / 0 失败
```

下载键必须等于播放 id 这一条是**真的**行为检查（脚本里按 `mediaKeyOf` / `downloadKeyOf`
的原口径复算了一遍），断了就是「下完了播放却找不到文件」。

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `core/download/DownloadManager.ets` | `resolveUrl` 分流 + `resolveBookUrl`、`ResolvedAudio`（带请求头）、`runTask` 带 header / 不凑标签 / `bookPace`、`nextWaiting` 串行、`buildFileName` 书名-章节名、`EXT_BY_QUALITY['book']` |
| `core/player/PlaySession.ets` | `playBookItem` 加「已下载优先」（在书源检查之前） |
| `views/BookDetailView.ets` | 长按菜单「下载本集 / 删除下载」、目录行「下载整本」（`showAlertDialog` 先确认） |

### 验收标准

- [ ] 真机：书籍详情页长按某一集 →「下载本集」→ 「我的 - 下载管理」里出现该集，下完能在文件管理里看到 `书名-章节名.m4a`。
- [ ] 下完的集**断网**也能播（或把书源删掉再播，应走本地文件）。
- [ ] 「下载整本」先弹确认；确认后是一集一集来（同时只有一集在跑），不是一次性并发。
- [ ] 播放页 / 队列里书集的长按菜单，点了下载不再出现「音源没有加载」那类失败记录。
- [x] `tools/book_import_test.js` 的下载契约与静态守卫通过。2026-09-27

---

## D-008 · 按歌手搜索：同一首歌重复一大堆，同时真正该看到的歌又少一大堆

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-28，改成洛雪那套「合并 → 去重 → 相关度排序 → 翻页」；真机回归见「验收标准」） |
| 优先级 | P1（搜索页是主入口，用户能直接看到重复与缺失） |
| 发现日期 | 2026-09-28 |
| 发现方式 | 用真实酷我接口跑了一遍搜索结果，把「改之前」的交错合并与「改之后」的合并结果对出来 |

### 影响面

搜索页把五个平台的结果**按「每个平台轮流取一条」交错拼接**，既不排序也不去重，
而且只拉第一页：

1. **重复**：同一首歌在五个平台各有一条，交错后连着出现五遍。搜「周杰伦」时列表
   前五行是「夜曲 / 夜曲 / 夜曲 / 夜曲 / 夜曲」。
2. **缺失**：每平台只取 30 条、没有翻页。酷我给「周杰伦」报的 `TOTAL` 是 **3295**，
   也就是能看到 30 首、看不到 3265 首。
3. 顺带：`songFromSearch` 对缺 songmid 的条目用**递增序号**当 id，而搜索页切平台筛选 /
   翻页都会重新转换一遍，同一首歌每转一次 id 就变一个，在播高亮与爱心会跟着飘。

### 处理方式（2026-09-28）

照洛雪 `store/search/music/action.js` 的 `setLists` + `utils/common.js` 重做：

| 环节 | 做法 | 洛雪对应 |
| --- | --- | --- |
| 合并 | 各平台这一页的结果合成一份列表 | `arrPush` |
| 去重 | 先按稳定 id（同平台重复返回的同一条），再按「歌名 + 歌手集合（时长 ±5 秒）」——同一首歌在几个平台都有时只留先问的那个平台那一份 | `deduplicationList`（洛雪只按 id；跨平台那一层是本次多做的，见下） |
| 排序 | 按 `similar(关键词, "歌名 歌手")` 二分插入后降序 | `handleSortList` / `sortInsert` / `similar` |
| 翻页 | 各平台连 `total`/`allPage` 一起回，列表滚到底拉下一页，页与页往后接不重排 | `listInfos[source].maxPage` / `OnlineList.onLoadMore` |

跨平台那一层去重是**有意多做的**：洛雪的聚合列表里同一首歌在几个平台就是几条
（它要用户自己挑一个能解析的源）。聆听的播放链路会自动换源
（`PlaySession.ensurePlayable` → `resolveItem`：条目所在平台解析不了就按「歌名 + 歌手」
在音源支持且有内置搜索的平台上重搜），所以留一条就够，多留的只会把列表塞满重复行。
内置音源（`resources/rawfile/lx_preload.js`）对 kw/kg/tx/wy/mg 都声明了 `musicUrl`，
留下的任一条都能直接解析。

### 证据（2026-09-28 实测）

```bash
node tools/search_merge_probe.js 周杰伦     # 真实酷我接口 + 新合并规则的 JS 复刻
node tools/search_merge_probe.js 晴天
```

```
关键词「周杰伦」

1) 翻页：
  ok   接口报出总数与总页数 -> TOTAL=3295 allPage=110
  ok   第 2 页与第 1 页不重合 -> page1=30 条, page2=30 条

2) 改之前的「交错合并且不去重」：
  ok   同一首歌连着占满前几行（这就是「重复一大堆」） -> 夜曲 | 夜曲 | 夜曲 | 夜曲 | 夜曲

3) 新的「合并 + 去重」：
  ok   150 条聚合后不再有跨平台重复 -> 150 -> 30
  ok   留下的是先问的平台那一份（kw） -> 非 kw 的条数=0

4) 相关度排序：
  ok   相似度单调不升
  ok   最像的排在最前面 -> 0.600
   前 8 条：
     0.600  枫 - 周杰伦 [04:35]
     0.500  夜曲 - 周杰伦 [03:46]
     ...

全部通过
```

搜「晴天」时还看到平台自己就重复返回了两条《晴天 - 周杰伦》（mid 228908 与 385945441，
时长 269 / 268 秒），合并规则把多余的那条也并掉了（150 -> 29）；这说明跨平台那层去重
是有效的，不是只把「五个平台各一条」压成一条。

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `core/music/MusicSearch.ets` | `similar` / `sortInsert` / `sortByRelevance`（照洛雪）、`searchIdOf` / `songKeyOf` / `dedupeSongs`、`searchMusicPage`（带 total/allPage）、`searchMusicAll` 改为返回 `LxSearchOutcome`（去重 + 排序 + maxPage）；各平台 `search*` 改为返回 `LxSearchPage`；删掉 `interleave` |
| `views/SearchView.ets` | 存原始 musicInfo、逐平台累计、`loadMore`（滚到底拉下一页）、尾部状态行；空态与提示文案 |
| `views/SongListPane.ets` | 新增 `footerStatus` / `onReachEnd`（不设就与改之前一模一样，其余三个列表不受影响） |
| `core/music/MusicId.ets` | `musicIdOf` 转调 `MusicSearch.searchIdOf`（id 规则只留一处） |
| `core/player/PlaySession.ets` | `songFromSearch` 缺 songmid 时改用「平台 + 歌名 + 歌手」当 id（不再用递增序号） |

### 验收标准

- [ ] 真机：搜索页搜一个歌手名（如「周杰伦」），列表里**没有连着重复的同一首歌**。
- [ ] 真机：结果列表滚到底会自动加载下一页，首数从 30 一路往上涨（而不是停在 30）。
- [ ] 真机：最像关键词的歌排在最前面（搜「晴天」时《晴天》在第一名附近）。
- [ ] 真机：切「酷我 / 酷狗 / …」筛选后继续下拉，看到的是该平台的第一页 + 第二页…。
- [ ] 真机：点任意一条能出声（留下的那份来自酷我，若音源解析不了会按歌名 + 歌手自动换源）。
- [x] 算法在真实接口数据上验证（`tools/search_merge_probe.js`，见「证据」）。2026-09-28

---

## D-009 · 「缓存时自动下载」听两三首之后不再下载；下载那份重启后读不到

| 项 | 内容 |
| --- | --- |
| 状态 | **已修复**（2026-09-29：改成「下载目录一份 + 应用内缓存一份」两条链路，并补上超时 / 重试 / 心跳 / 日志 / 授权提示；真机回归见「验收标准」） |
| 优先级 | P0（开关开着却在静默失效，且原设计把缓存那份删了，等于两份都保不住） |
| 发现日期 | 2026-09-29 |
| 发现方式 | 用户反馈「一边播一边下，一开始会下，播了 2 首之后又不会了；而且下载下来的真能当缓存吗」。逐行读链路 + 顺着两处「没有超时的等待」定位 |

### 影响面

1. **播两三首之后不再下载**。自动下载走 `DownloadManager`，并发位只有 2 个
   （`MAX_ACTIVE`），而自动排进来的条目开工前要过 `LxPlayer.canUseBandwidthForCache()`
   这道让路闸。三处会让它**永久**卡住：
   - `openViaPicker()` 里的 `picker.save()` **没有超时**：不返回就永远占着一个并发位，
     两个位都被占住之后后面所有自动下载都停在「排队中…（边听边存）」；
   - 下载体只有 `readTimeout: 300000`（5 分钟）兜底：一个卡死的连接能霸占并发位 5 分钟；
   - 让路判断只看 `buffering` 这个标志，而真机上 `BUFFERING_END` 会漏
     （`docs/PLAYBACK_BUFFER.md` 里有实测记录）：一漏整首歌都不让路，这首歌就不下了 ——
     表现正是「有时下、有时不下」。
2. **失败不重试**。解析链接（音源沙箱，60 秒超时）或下载非 200 直接标成 error，
   要用户手点重试。快速切歌时音源沙箱容易被抢，很容易撞上。
3. **这段链路几乎没有日志**：`DownloadManager` 全文件只有 ready / done 两条 info，
   让路跳过与任务开工都不打，没法从日志区分「没排上 / 在让路 / 卡死」。
4. **下载那份重启后读不到，而且被误报成「文件找不到了」**。公共目录给的是会话级授权
   （`module.json5` 里特意没声明 `FILE_ACCESS_PERSIST`），重启后 `loadIndex` 用
   `fs.accessSync` 判定，读不到就把记录标成 error『文件找不到了（可能被清理过）』——
   文件明明还在「文件管理」里。
5. **原设计只有一份**：交给下载器时 `AudioCache.dropKey()` 把沙箱那份删掉，于是
   第 4 条一旦发生，**离线那一份就一起没了**（沙箱备份已删）。

### 处理方式（2026-09-29）

**一、改成两份并存（用户明确要求）**

| | 关（默认） | 开 |
| --- | --- | --- |
| 沙箱 `files/lx_media_audio/` | 有，受「缓存上限」LRU 约束 | **照旧有**，同样受上限约束（上限设 0 一样关掉并清空） |
| 下载文件夹 `Download/<应用名>/` | 无 | 另有一份整首：不受上限约束、长期保留、在下载管理里删 |

- `PlaySession` 的播放 / 预取路径：`isAutoDownload()` 时先 `queueAutoDownload()`，
  **不再 return**，接着照旧 `cacheSong()` / `prefetchSong()`（`PlaySession.autoDownload`
  改名 `queueAutoDownload`，去掉 `dropKey`）。
- `AudioCache`：`isEnabled` / `enforceLimit` / 单首上限全部回到「只看缓存上限」，
  `dropKey()` 删除（它的唯一理由就是「只留一份」）。

**二、稳健性**

| 问题 | 做法 |
| --- | --- |
| picker 不返回占死并发位 | `withTimeout(picker.save(), 8000)`：超时按失败走 → 退回应用内目录，歌照样下得来 |
| 连接卡死占位 5 分钟 | 数据心跳看门狗（`STALL_LIMIT_MS = 30s`，每 5s 查一次）：没数据就 `request.destroy()` 掐断，正常收尾 |
| 抖动即永久失败 | `failOrRetry()`：可重试的失败放回 `waiting` 再排一次（`MAX_RETRY = 1`）；4xx / 配置类错误不重试 |
| 让路闸被卡住的 `buffering` 挡住 | `canUseBandwidthForCache()` 改以**播放进度**为准（进度还在走就不算挨饿） |
| 重启后误报「文件找不到了」 | `loadIndex` 区分：公共目录那条留 `done` + note 说明「本次启动没读取授权」；应用内目录那条读不到才是真没了 |
| 看不到发生了什么 | 补日志：`auto task defers`（让路，带播放器状态与 active）、`task start` / `task end`（带耗时与 active，保证成对）、`retry n/N` |
| 重下同名文件留尾巴 | 打开保存目标时带 `TRUNC`（新内容比旧文件短时会拼出坏文件） |

### 涉及代码

| 位置 | 说明 |
| --- | --- |
| `core/download/DownloadManager.ets` | `PICKER_TIMEOUT_MS` / `STALL_LIMIT_MS` / `STALL_CHECK_MS` / `MAX_RETRY`、`withTimeout`、`retryableResolveFailure` / `retryableNetworkFailure`、`failOrRetry`、看门狗、`pump` / `startTask` 日志、`openViaPicker` 超时 + TRUNC、`loadIndex` 授权提示、`retries` 字段 |
| `core/music/AudioCache.ets` | 上限恢复对沙箱缓存常态生效（`isEnabled` / `enforceLimit` / 单首上限）；删除 `dropKey` |
| `core/player/LxPlayer.ets` | `canUseBandwidthForCache()` 以播放进度为准 |
| `core/player/PlaySession.ets` | `autoDownload` → `queueAutoDownload`（不再删沙箱缓存、不再 return），播放与预取两条路径都「两份并存」 |
| `views/CacheSettingsView.ets` | 确认弹窗 / 开关副标题 / 上限行 / 底部说明按「两份」重写 |

### 验收标准

- [ ] 真机：开着开关连听 5 首以上，5 首都出现在「我的 - 下载管理」里并下完
      （不再停在「排队中…（边听边存）」）；`task start` 与 `task end` 条数相等，
      `task end` 里的 `active` 最后回到 0。
- [ ] 真机：边听边下时正在听的那首不卡顿（让路那批日志能解释「为什么还没开工」）。
- [ ] 真机：断网 / 弱网下失败的条目会自己再试一次（`retry 1/1`），不是立刻变「下载失败」。
- [ ] 真机：同一首歌下载后，沙箱缓存里也有一份（缓存设置的占用与条数会涨）；
      把缓存上限调小到装不下时会淘汰它，而下载文件夹那份还在。
- [ ] 真机：把缓存上限设 0 → 沙箱那份被清空，下载文件夹那份不受影响。
- [ ] 真机：重启应用后，「下载管理」里公开目录那条显示「已下载」+ 授权说明（不再是
      「文件找不到了」），且**本次会话点它能播放**（重启后首次会联网，第二次起读本地）。
- [ ] 真机：下载目录不可用时（拒绝授权等），自动退回应用内目录并给出 note。

---

## 其他待办（不是缺陷，按需排期）

- **歌词逐字（`lxlyric`）**：洛雪的富文本歌词（逐字时间轴）目前未使用，
  只用了 `lyric`/`tlyric`。`lx_preload.js` 已经在回传 `lxlyric`，
  `PlatformLyric` 侧丢弃了。
- **设计债**：`SongListPane`（「我的」与搜索结果共用的歌曲列表）仍是自绘行，
  它的父容器是 `Scroll`，换成官方 `List` 需要连父级一起改；主页签大标题也仍是自绘。
- **占位功能**：播放页底部工具栏那颗铃铛（通知）原先只是个占位 —— 点不动、读屏也跳过。
  2026-09-23 已换成**评论入口**（见 `docs/SONG_COMMENT.md`），底部四个入口现在都是能用的。
  「歌单排序」那颗钮已经删掉（点下去只弹「暂未接入」，摆在那里是误导；
  本地歌单的拖拽排序在 `docs/LX_SYNC.md` 里记着还没做），「新建歌单」是真的能用。
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

2026-09-20 追加（歌单导入链路，`node tools/live_list_probe.js` 实测通过）：

| 能力 | 形态 | 验证方式 |
| --- | --- | --- |
| 歌单详情 kw | `GET nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=<id>` | 真实请求，121/121 首 |
| 歌单详情 kg | `GET www2.kugou.kugou.com/yueku/v9/special/single/<id>-5-9999.html` 取 hash，再 `POST gateway.kugou.com/v2/album_audio/audio` 换歌曲信息 | 真实请求，26/30 首（4 个 hash 换不到） |
| 歌单详情 mg | `GET app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?playlistId=<id>`（一页 30 首） | 真实请求，30/100，翻页在 App 里做 |
| 歌单详情 tx | `POST u.y.qq.com/cgi-bin/musicu.fcg`（`music.srfDissInfo.aiDissInfo`） | 真实请求，50/50，见 D-002 |
| 歌单详情 wy | `GET music.163.com/api/v6/playlist/detail?id=<id>&n=1000` | 真实请求，10/26（只回可播放曲目） |
| 分享链接解析 | 五平台 `listDetailLink` 正则 + 短链跟随（`maxRedirects: 0` 读 `Location`） | 单测 `playlistLinkTest`：15 条真实分享文本 |
