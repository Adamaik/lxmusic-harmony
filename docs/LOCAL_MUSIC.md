# 本地音乐（播放设备里的音频文件）

把设备上的音频文件导入成一个应用内的「本地音乐」列表，和在线歌曲共用同一套播放链路
（队列 / 播放历史 / 播控中心 / 播放页）。

本文记调研结论、设计取舍，以及最后实现出来的样子。

> 已实现（`core/local/LocalMusic.ets` + 我的页「本地音乐」分段页）：
> 导入（文件管理的音频聚合视图，一步到位）、元数据与内嵌封面、去重、
> 删除（单条 / 多选批量）、混进播放队列、加进歌单与收藏（非同步侧表）、
> 同步设置页注明本地歌会被抛弃。
> 没做：同名 `.lrc` 歌词、失效条目标记、空间统计页，详见文末「分期」。

## 1. 权限：先给结论

读设备里的音频，官方给了三条路，只有一条走得通：

| 路线 | 权限 | 能不能用 |
| --- | --- | --- |
| `ohos.permission.READ_AUDIO`（API 8+） | 受限开放权限（ACL），需 AGC 审批 | **不能用**。文档把可申请场景写死成「应用需要克隆、备份或同步音频类文件」，并直接给出替代方案：「其他场景下的使用方案：使用 AudioPicker 访问用户音频文件」 |
| `ohos.permission.READ_MEDIA`（API 9+） | 同上 | 同上：媒体库读写，可申请场景同样是克隆 / 备份 / 同步 |
| **Picker（`AudioViewPicker` / `DocumentViewPicker` + `mergeMode: AUDIO`）** | **无需任何权限** | **走这条**。官方为「应用要读用户音频」指定的正路就是 Picker；本工程用后者（文件管理的音频聚合视图），一次能看到全机音频，见第 3 节 |

出处：`开发指南/安全/程序访问控制/应用权限管控/应用权限列表/受限开放权限/restricted-permissions`、
`FAQ/程序框架/程序框架_Ability/HarmonyOS媒体库相关权限申请及配置/faqs-ability-163`。

还有一层：**三方应用没有「自己枚举音频媒体库」的 API**。Media Library Kit 只覆盖图片和视频
（`photoAccessHelper`），音频相关文档反复写「当需要读取和保存音频文件时，请使用
AudioViewPicker」。所以「应用自己扫描全盘音乐」在设计上就不存在 —— 能让用户看到全机音频
列表的只有 Picker 的聚合视图（那是文件管理界面在跑，不是我们拿到了权限）。

`WRITE_AUDIO`（往公共目录写音频）同样受限，场景也是克隆 / 备份 / 同步 —— 本项目不需要它
（导入是往沙箱写，不碰公共目录）。

## 2. 授权时效：为什么只能「导入」，不能「引用」

Picker 返回的 URI **只有临时权限**，而且短得超出直觉：

> 使用Picker获取的select()返回的URI权限是临时只读权限，**待退出应用后台后，获取的临时权限就会失效**。
> —— `开发指南/Core_File_Kit/用户文件/选择与保存用户文件/选择用户文件/select-user-file`

FAQ 里还有一条：应用被终止后（包括重启）该权限失效，重启后必须重新让用户选。

音乐播放器必然要退到后台（我们本来就申请了 `KEEP_BACKGROUND_RUNNING` + `audioPlayback`
长时任务），所以**「只存 URI、播放时现读」的方案必然在放歌中途掉链子**。

那能不能把临时权限变成持久的？可以，但代价是我们已经踩过一次的那个坑：

- 持久化要 `fileShare.persistPermission()`，它**需要 `ohos.permission.FILE_ACCESS_PERSIST`** ——
  又是一个受限 ACL 权限，必须在签名 Profile 的 `allowed-acls` 里声明才能生效；
- 而且持久化只是把策略写进系统数据库，**应用或设备重启后还要 `activatePermission()` 激活**才可用；
- 本项目 `module.json5` 里已经因为「自动生成的调试 Profile 没有 `allowed-acls`，
  声明了也只是摆设」把同一个权限删掉过一次（见该文件里的注释）。

**结论：选中文件后把音频拷贝进应用沙箱（导入式）。** 零权限、退后台不掉、跨重启有效，
代价是同一首歌在设备上占两份存储（原件 + 副本），删歌只删副本、不动原文件。

这条取舍和项目现有约定是一致的：`AudioCache` 已经在往 `files/lx_media_audio/` 落整首音频，
`playAt` 已经有一条「本地文件优先」的分支，`module.json5` 也已经为「不申请 ACL」做过一次同样的决定。

## 3. 怎么选文件（只有一个入口：文件管理的音频聚合视图）

三方应用在**手机**上能拿到的用户音频文件只有一条路：「自己扫全盘」在设计上就不存在
（见第 1 节：`READ_AUDIO` / `READ_MEDIA` 是受限权限，只批克隆 / 备份 / 同步场景）。

| 方式 | 接口 | 批量能力 |
| --- | --- | --- |
| **导入音乐**（唯一入口） | `DocumentViewPicker` + `mergeMode: MergeTypeMode.AUDIO`（API 15+） | 拉起**文件管理应用的聚合视图（音频分类页）**：一屏列出设备上所有音频文件，多选 / 全选由文件管理界面提供。官方文档：该参数「在 Phone 设备中可正常使用，在其他设备中无效果」 |

界面上的「导入音乐」是一颗直接打开的按钮（没有二级菜单）。曾经还有两个入口，都撤了：

| 撤掉的 | 原因 |
| --- | --- |
| 选文件夹（`selectMode: FOLDER`） | 手机在 API 26 之前不支持这个参数，理由见下 |
| 选择音乐文件（`AudioViewPicker`） | 能用，但只能逐个多选，批量导入不如聚合视图；留着只是多一条岔路 |

### 「选文件夹」为什么彻底不能用（2026-09-22 查清）

原来那条 `DocumentViewPicker` + `selectMode: FOLDER` 有两个独立的死因，任一条都足以让它废掉：

1. **手机根本不支持选文件夹。** 官方《选择用户文件》指南原文：
   「选择的文档类型，默认值是 FILE(文件类型)。**从 API 版本 26.0.0 开始，当文件类型是
   FOLDER 时，Phone 设备支持该参数**」；`allowsMulFolderSelection` 同样标注仅 2in1 支持。
   本工程 `compatibleSdkVersion = 6.1.0(23)`，手机系统也在 API 23 这一档，
   所以 `selectMode = FOLDER` 在当时等于没生效 —— 这是「选了文件夹却没反应」的根因。
2. **就算拿到目录 URI，也枚举不了。** `fs.listFileSync` 的参数按 SDK 文档只接受
   「应用沙箱路径」（`@ohos.file.fs.d.ts` 里 listFile / listFileSync / listFileExtSync
   都这么写，整个 fs 模块只有 `stat` / `lstat` 标了 "URIs can be passed since API version 22"）；
   公开 SDK 里也没有第三方可用的目录枚举接口（`@ohos.file.fileAccess.d.ts` 只有 37 行空壳，
   真正的 FileAccessHelper 是 systemapi）。
   而代码当时把枚举异常 catch 成空数组，界面就报「这个目录里没有找到文件」——
   把「枚举不了」说成了「目录是空的」（这是个真 bug，不只是功能缺失）。

### 查过、没采用的路（都记下来，免得以后重复调研）

| 路线 | 结论 |
| --- | --- |
| `Environment.getUserDownloadDir()` → 扫「下载」目录 | **手机不可用**：依赖 syscap `SystemCapability.FileManagement.File.Environment.FolderObtain`，只存在于 2in1 / tablet 的 device-define（手机编译器直接 28005）。下载目录那条路在本工程早就因为同一原因放弃了，见 `DownloadManager.ets` |
| `fileShare.persistPermission()` 持久化目录授权 | 同因不可用：syscap `AppFileService.FolderAuthorization` 也只有 2in1；且要受限 ACL 权限 `FILE_ACCESS_PERSIST` |
| `ohos.permission.READ_AUDIO` / `READ_MEDIA` 直读媒体库 | 受限开放权限，AGC 审批场景写死为「克隆 / 备份 / 同步音频类文件」，官方直接给出替代方案：用 AudioViewPicker |
| `mediaLibrary` 查音频资源 | SDK 里已经没有这个模块（HarmonyOS NEXT 移除）；`photoAccessHelper` 只覆盖图片 / 视频，全文没有 audio |
| 文件管理里多选 → **分享到本应用** | 技术上可行（声明 `ohos.want.action.sendData` / `sendMultiple` 收 URI），能用上文件管理自己的「全选」；代价是改 `module.json5` 并处理冷启动 / `onNewWant`。**暂不做**，留作聚合视图不好用时的备选 |
| 华为音乐 / 荣耀音乐的「一键扫描」 | 那是系统应用（有特权权限），三方照不了 |

**去重**（导入与批量管理都靠它）：

| 手段 | 规则 | 说明 |
| --- | --- | --- |
| 指纹 | `字节数_小写文件名`（`LocalMusic.importOne`） | 同一首歌换个目录、或一次选两遍，都会被跳过；跨重启有效（`index.json` 里的 `fingerprint`，启动时重建 Set） |
| 指纹的边界 | 不是内容哈希 | 同名且字节数相同的两首不同歌会被误判为重复；同一首歌重新编码（字节数变了）不会被判重，会各留一份 |
| 非音频文件 | `isIgnorableFile`（`.lrc` / 封面图 / 说明文本） | 直接摘掉，不算「格式不支持」 |
| 同名 `.lrc` | 按音频文件名找兄弟文件 | 只授权了选中文件的路径（选文件）读不到，读不到就算了，靠在线匹配兜底 |

`DocumentViewPicker` 的其它参数（以后要用时参考）：

- `mergeMode` 置为非 `DEFAULT` 后**其它参数基本不生效**（官方：「API 版本 26.0.0 及之后的版本
  当该参数置为非 DEFAULT 时，仅 fileSuffixFilters 参数生效」），所以聚合视图只配了它；
- `fileSuffixFilters`：`['音频|.mp3,.flac,.m4a,.aac,.ogg,.wav,.amr']`，按后缀过滤；
- `maxSelectNumber`：API 20 及以前上限 500，API 21 起取消上限（建议单次不超过 1 万个）；
- `multiAuthMode` + `multiUriArray`：批量授权模式（手机可用），用于「手里已经有一批 URI，
  让用户一次确认授权」，本项目暂无来源可传；
- `constructor(context)` 要用 UIAbilityContext（无参构造会概率性拉起失败）。

格式支持（AVPlayer / AVMetadataExtractor 官方列出的音频格式）：
**m4a、aac、mp3、ogg、wav、flac、amr**。APE / WMA / DSD 不在列表里 ——
导入时按后缀过滤，遇到不支持的格式要明确提示，不能静默丢。

## 4. 元数据与封面

导入时用 `media.createAVMetadataExtractor()` 读标签：`fdSrc = { fd }` →
`fetchMetadata()`（标题 / 歌手 / 专辑 / 时长 / mimeType）→ `fetchAlbumCover()` 拿封面 PixelMap。
拿不到标签就退回文件名（`歌手 - 标题` 这种常见命名可以拆一下）。

**一条官方硬约束**（很容易踩）：

> 将资源句柄（fd）传递给 AVMetadataExtractor 实例之后，不允许通过该资源句柄做其他读写操作……
> 同一时间通过同一个资源句柄读写文件时存在竞争关系，将导致音视频元数据获取异常。

即：**读元数据的 fd 必须和播放用的 fd 是两个**，读完立刻 `release()` + `closeSync`，
绝对不能把播放器的句柄借过来用。

## 5. 数据模型与存储

复用现有的 `SongItem`，本地歌打一个平台标记：

- `source = 'local'`，`musicInfoJson` 里放一份 `LxMusicInfo` 形态的 JSON
  （`{ source: 'local', songmid: '<本地 id>', name, singer, albumName, interval, img, types: [], _types: {}, typeUrl: {}, lrc: null, otherSource: null }`）；
- 这样队列 / 歌单 / 收藏 / 播放历史 / 播控中心全部不用改（它们只认 `SongItem`）；
- `mediaKeyOf()` 会算出 `local_<id>`，与 `downloadedFile()`、`AudioCache` 的键天然自洽；
- 同步侧**已经就绪**：`SyncConvert.parseOldMusicInfo()` 里已有一条
  `if (info.source === 'local') { return null; }`，注释还写着「本地文件不在同步范围内
  （洛雪也只同步在线歌曲）」—— 本地歌进任何列表都不会被上行。

存储：

| 项 | 位置 |
| --- | --- |
| 音频副本 | `files/local_music/`，一个 id 一个文件，保留原后缀 |
| 索引 | `files/local_music/index.json`（歌单级元数据 + 文件映射） |
| 封面 | 走现有 `CoverStore` 那套（导入时把 PixelMap 编码存下来） |

**不能放进 `AudioCache` 的 `lx_media_audio/`**：那是个 LRU 淘汰目录，
`AudioCache.clear()` / 容量回收会直接删里面的文件 —— 用户导入的歌是资产，不是缓存。

索引每条记：`id`、文件名、标题、歌手、专辑、时长、字节数、导入时间、来源文件名、去重指纹，
以及歌词用的那几个字段（见第 9 节）。

## 6. 播放链路改造点（已实现）

`PlaySession.playAt()`（`core/player/PlaySession.ets`）原本的顺序是：

```
音源检查（未加载直接报错返回）-> ensurePlayable -> 用户下载 > 播放缓存 > 网络
```

现在在音源检查**之前**插了一条**本地直路**（`playLocalItem()`）：

```
let item = this.queue[index]
if (item.source === 'local') {           // 本地歌：不联网、不看音源脸色
   校验文件还在 -> LxPlayer.playLocal(沙箱路径) -> return
}
if (!engine.isInited()) { ... }          // 原来的音源检查往后挪了
```

理由是本地播放本来就不该依赖音源是否加载：原来的检查会让「没导音源」的用户连自己手机里的歌都放不了。
文件不在（清过应用数据 / 手动删了副本）时报「文件已经不在了，请重新导入」，不静默失败。

其它会误伤本地歌的现成逻辑，逐个加了 `source === 'local'` 早退：

| 位置 | 不加会怎样 |
| --- | --- |
| `prefetchNext()` | 它只按 `musicInfoJson.length === 0` 判空，本地歌的 JSON 非空 → 会拿 `source:'local'` 去问源脚本要链接 |
| `loadLyric()` | 会给本地歌去问平台歌词，白跑一趟还留下「加载中」状态 |
| `loadCover()` | 会拿 `source:'local'` 去请求封面 |
| `DownloadManager.enqueue()` | 会把它排进下载队列，然后解析失败留下一条 error 记录 |
| `ensurePlayable()` / `pickQuality()` | 用不着改：前者在直路之后才走；后者在「没有音质档」时原样返回 `fallback`（已由单测钉住） |

界面侧：播放页的音质标签对本地歌显示「本地」，下载钮弹「已经在本机了」；
歌单详情 / 播放队列 / 歌曲列表的行菜单对本地歌不显示「下载」，也不把它算进「下载全部」；
进度条的灰色缓冲段走 `pushBuffered()` 里已有的「本地文件 → 整条画满」分支。

## 7. 融入现有功能（逐项）

| 功能 | 结果 | 动到的地方 |
| --- | --- | --- |
| 播放队列 / 上一首下一首 / 随机播放 | 支持 | 无（`SongItem` 通用） |
| 播放历史 | 支持 | 无（`recordHistory` 自动进） |
| 播放页 / 迷你栏 / 灰段 | 支持 | 无（本地文件整条画满） |
| 播控中心 / 锁屏 | 支持 | 无（AVSession 只看 `SongItem`） |
| 封面 | 支持（内嵌封面） | 导入时用 AVMetadataExtractor 提取 |
| 洛雪同步 | 天然排除（会被直接抛弃） | 无（`source === 'local'` 分支本来就在 `SyncConvert` 里）；同步设置页加了说明文字 |
| 音质标签 / 下载 | 不适用 | 按 `source === 'local'` 显示「本地」/ 不显示下载项 |
| 歌词 | 先不支持 | 可扩展：导入时找同名 `.lrc` 一并拷 |
| 播放缓存 / 下一首预取 | 不适用 | 本地歌不入 `AudioCache`、不预取 |
| **加入歌单 / 收藏** | **支持** | 非同步侧表，见下 |
| 试听列表（= 播放队列）的同步 | 不含本地歌 | 见「已知限制 1」 |

**「加入歌单 / 收藏」是唯一动到数据结构的一项。** 现状：`LocalLibrary` 的
`userList[].list` 与 `loveList` **只存同步形态的 `LxMusicInfoNew[]`**，写入走
`musicsOf()`（`core/sync/LocalLibrary.ets`），而它会把 `isSyncable() === false`
的条目直接丢掉 —— 本地歌加进去会被静默吞掉，不是"同步时不上行"这么简单。

**已按「乙」实现：给列表加一层非同步侧表。**

- 侧表放在 `LocalMusic` 里（`files/local_music/index.json` 的 `lists`：
  歌单 id → 该歌单里的本地歌 key 列表，收藏用 `love` 那个键）；
- 读取时合并：`playlistSongs()` / `mirrorToSession()` 把本地歌排在**前面**
  （与「新加的歌排最前」一致；本地歌在同步数据里不存在，没有和在线歌交错的顺序可言）；
- 写入时各写各的：只有本地歌时**不**走 `mirrorToSession()`，避免它用「同步过的队列」
  把正在播的本地队列换掉（见 `bumpLocalChange()` 的注释）；
- 上行只看到 `LxMusicInfoNew` 那半边，协议与 md5 都不受影响。
- 删本地歌 / 删歌单时，侧表里的引用一起清（`LocalMusic.removeKeys` / `dropLists`），
  不留打不开的幽灵条目。

**侧表为什么单独存**：参与同步的那份数据要按 `listData()` 的 JSON 算 md5 与服务端比对快照，
往里塞任何字段都会改掉 md5。侧表在另一个文件里，同步链路完全看不见它。

## 8. 实现出来的样子

| 职责 | 位置 |
| --- | --- |
| 本地音乐库（导入、索引、封面、去重、删除、歌单侧表） | `entry/src/main/ets/core/local/LocalMusic.ets` |
| 我的页「本地音乐」分段页（导入入口 / 进度 / 列表 / 删除） | `entry/src/main/ets/views/LocalMusicView.ets` |
| 播放直路与各处早退 | `entry/src/main/ets/core/player/PlaySession.ets`（`playLocalItem`） |
| 歌单 / 收藏的合并与侧表维护 | `entry/src/main/ets/core/sync/LocalLibrary.ets` |
| 下载入口的全部拦截 | `core/download/DownloadManager.ets`（`enqueue` 里拦一道）+ 四处菜单 |

落盘布局：

```
files/local_music/
  index.json        { version, songs: [...], lists: { <歌单id>: [key...] } }
  <key>.mp3         导入时拷贝的音频副本（保留原后缀）
  <key>.lrc         同目录下的同名歌词（有就一起拷进来）
  covers/<key>.jpg  从内嵌标签里取出的封面（JPEG 质量 80）
```

索引里每条还带这几个和歌词有关的字段：`lrc`（歌词文件名）、`matchJson` / `matchSource`
（在线匹配到的平台歌曲与平台）、`matchAt`（上次自动匹配的时刻，0 = 没试过）。

几个实现上的取舍：

- **导入是「先拷文件、后写索引」**，所以启动时会 `sweepOrphans()` 清掉没有索引的副本
  （拷到一半被杀进程留下的），以及索引里有、文件却不在的条目；
- **读标签用单独的 fd**：官方明确说同一个句柄同时给播放器和提取器会「存在竞争关系」，
  所以导入时对**拷贝后的文件**另开一个句柄，读完立刻 release + close；
- **逐个串行导入**并让出事件循环，进度写进 AppStorage（`local_progress`），
  界面显示「正在导入 12/340 歌名」并可以取消；
- **去重指纹 = 文件字节数 + 文件名（小写）**，同一份文件重复选到就跳过并报数；
- **格式过滤**只放 AVPlayer 官方支持的 m4a / aac / mp3 / ogg / wav / flac / amr，
  其余（ape / wma / dsf…）报「格式不支持」，不静默丢；
- 界面上音质标签对本地歌显示「本地」，下载入口一律不出现（`DownloadManager.enqueue`
  里还有一道兜底）。

已知限制：

1. **队列里的本地歌不参与同步**。试听列表（= 播放队列）是同步结构，本地歌进不去；
   播放一份含本地歌的列表时，如果触发了队列镜像（比如远端列表推送），队列会回到
   同步那一份 —— 本地歌会从队列里消失，但**歌单 / 收藏里的不会丢**（它们在侧表里）。
2. **「选择文件夹」已去掉**（2026-09-22）：手机在 API 26 之前不支持 FOLDER 选择，
   加上目录 URI 枚举不了，入口与 `pickFolder/listFolder` 一并删除；批量导入改走
   导入改走文件管理的音频聚合视图（可全选），见第 3 节。
3. 本地歌没有平台音质可选 —— 设计如此，不是 bug。
4. 在线匹配依赖平台搜索接口的可用性（内置搜索里网易那个端点就一直标着「待复核」），
   所以是五个平台依次试，某个平台不通不影响其它平台；全都不可用时就没有歌词，
   这时只能靠同名 `.lrc` 或手动匹配。

## 9. 歌词

本地歌的歌词按这个顺序找（`PlaySession.loadLocalLyric` / `matchLocalLyric`）：

| 顺序 | 来源 | 特点 |
| --- | --- | --- |
| 1 | 导入时一起拷进来的同名 `.lrc` | **精确匹配**，离线可用，不会配错 |
| 2 | 之前匹配好的平台歌词（`matchJson`） | 直接取词并缓存，不再搜索 |
| 3 | 按设置自动匹配一次（`core/local/LyricMatch`） | 要联网，每首歌只搜一次 |
| 4 | 都没有 | 就显示没有歌词，而不是显示错的 |

`.lrc` 靠导入时顺带拷一份：对每个音频文件，在同一目录找同名的 `.lrc` / `.LRC`
（`song.mp3` → `song.lrc`）。选文件这条路只授权了选中的那一个文件，兄弟文件多半读不到，
读不到就靠在线匹配兜底。歌词文件可能是 GBK —— `fs.readTextSync` 只支持 utf-8，
所以是读原始字节后先用 UTF-8 解、解出 U+FFFD 再用 GBK 解一遍。

### 在线匹配为什么是「宁缺勿错」

本地歌没有平台身份，只有歌名 / 歌手 / 时长，所以要拿它们去内置平台搜索里找一首对应的
在线歌（五个平台逐个体试，搜索与取词两条链都是宿主侧内置的，不依赖导入的音源）。

「猜」一定会有猜错的时候：同名歌、翻唱、纯音乐、Live 版都会踩到，而**配错的歌词比没有歌词
更难解释** —— 用户看到的是理直气壮的错词。所以打分的接受条件收得很紧
（`LyricMatch.scoreCandidate`）：

- 歌名归一化后**完全一致**（小写、去空白、去括号字符，与 `PlaySession.normalizeName` 同口径），
  并且歌手有交集**或**时长差在 3 秒内 —— 满足才自动采用；
- 歌名只是**包含关系**时（`普通朋友(live)` vs `普通朋友`），要求歌手与时长**都**对上；
- 时长差超过 20 秒直接判出局（现场版、串烧、加长版）；
- 歌名一致但歌手与时长都不知道（标签全缺）→ **不采用**。这一条最容易让人犹豫，
  但只靠歌名挑第一条迟早配错，这种情况交给用户手动选。

匹配结果会落盘（`matchJson` / `matchSource`），下次直接用它取词；「搜过一次」也记下来
（`matchAt`），避免每放一次就联网搜一遍。但**只有平台真的应答过才算搜过**：全平台都请求
失败（断网）时不记，否则第一次播放恰好没网的用户以后有网也不会再匹配，等于永久没有歌词。

### 手动纠正（必须有）

自动匹配再严也会有拿不准的时候，所以播放页的「更多」里给本地歌加了「匹配歌词」：
逐平台搜、边搜边出结果，按相似度排序并标出来自哪个平台，点一条就记住并立刻重新取词
（`LyricMatchSheet` + `PlaySession.refreshLyric`）。面板是自绘的，不用 `bindSheet` ——
播放器本身就是系统半模态，再叠系统弹层容易打架（见 PlayerView 开头的说明）。

### 开关

「设置 - 播放设置 - 本地音乐自动匹配歌词」默认开，可以关掉（关掉后仍可手动匹配）：
它每首本地歌会发一次平台搜索请求，虽然只发一次，但这是个联网行为，该让用户能拒绝。

## 10. 风险与待验证

| 事项 | 状态 |
| --- | --- |
| ~~FOLDER 模式返回的目录 URI 能不能用 `fs.listFileSync` 枚举~~ | **已查清（2026-09-22）**：手机在 API 26 之前 `selectMode = FOLDER` 本身不生效（官方指南），且目录 URI 也不是 `listFileSync` 能接受的参数。入口已去掉，见第 3 节 |
| 聚合视图能不能全选 | **待真机验证**：`mergeMode = AUDIO` 官方标注手机可用，但聚合视图里多选 / 全选的具体交互要装到手机上确认；不好用就改走「文件管理多选 → 分享到本应用」，见第 3 节的备选表 |
| 大库导入耗时 | 已处理：逐个串行导入 + 进度 + 可取消，界面不会卡住 |
| 元数据 fd 与播放 fd 冲突 | 已处理：读标签用单独的句柄（第 4 节的官方约束） |
| 重复导入同一文件 | 已处理：指纹去重（字节数 + 文件名） |
| 副本丢失（清应用数据 / 手动删） | 启动时 `sweepOrphans()` 会把「索引里有、文件不在」的条目清掉；**没有**在界面上标失效（见分期） |
| 空间占用 | 不做 LRU（导入是用户显式行为）；「我的 - 本地音乐」顶部显示「N 首 · X MB」，清空走标题栏的删除钮 |
| Phone 只能选一个目录 | `allowsMulFolderSelection` 在手机上无效，一次一个目录 |

## 11. 分期

- **P0 已完成**：导入（文件管理的音频聚合视图）→ 沙箱副本
  + `index.json` → 元数据与封面 → 去重 →
  「我的」页「本地音乐」分段页（导入钮 + 进度 + 列表 + 单条删除 + 多选全选/批量移除）→ `playAt` 本地直路
  （在音源检查之前）→ 各处早退 → 空状态引导（说明为什么必须导入）。
- **P1 已完成**：本地歌加入歌单 / 收藏（非同步侧表）、歌词（同名 `.lrc` 一并导入 +
  在线匹配 + 手动纠正 + 开关）。
  还剩：失效条目的界面标记、空间统计页。
- **P2**（可选）：等 `FILE_ACCESS_PERSIST` 的 ACL 批下来后，改成「引用式」以省掉那份拷贝 ——
  届时 `persistPermission` + 重启后 `activatePermission` 要一起做，别只做一半。

## 附：相关文件

| 职责 | 文件 |
| --- | --- |
| 本地音乐库（新增） | `entry/src/main/ets/core/local/LocalMusic.ets` |
| 「我的 - 本地音乐」面板（新增） | `entry/src/main/ets/views/LocalMusicView.ets` |
| 在线歌词匹配（打分与「宁缺勿错」的判定） | `entry/src/main/ets/core/local/LyricMatch.ets` |
| 手动纠正面板 | `entry/src/main/ets/views/LyricMatchSheet.ets` |
| 用例（钉住 cacheKey / 同步排除 / 音质回退 / 后缀过滤 / 匹配接受条件） | `entry/src/test/LocalMusic.test.ets`、`entry/src/test/LyricMatch.test.ets` |
| 播放会话（本地直路 `playLocalItem` 与各处早退） | `entry/src/main/ets/core/player/PlaySession.ets` |
| AVPlayer 封装（`playLocal` 走 `fdSrc`） | `entry/src/main/ets/core/player/LxPlayer.ets` |
| 列表存储（合并侧表、维护计数） | `entry/src/main/ets/core/sync/LocalLibrary.ets` |
| 同步形态转换（`source === 'local'` 排除，本来就有） | `entry/src/main/ets/core/sync/SyncConvert.ets` |
| 下载拦截（`enqueue` 里拦一道） | `entry/src/main/ets/core/download/DownloadManager.ets` |
| 播放缓存目录（**不要混用**：那是 LRU 淘汰目录） | `entry/src/main/ets/core/music/AudioCache.ets` |
| 权限声明与 ACL 取舍的记录 | `entry/src/main/module.json5` |
