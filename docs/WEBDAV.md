# 云端音乐（WebDAV：连自己的服务器放歌）

把「自己的云服务器上的音乐」接成第三种来源，与「在线歌」（音源 + 平台）和
「本地音乐」（设备里导入进来的文件）并列：**连上就直接能播放服务器目录里的音乐**，
封面与歌词自动匹配，能加进歌单与收藏，但**不参与洛雪同步**。

**没有「导入」这一步。** 填好服务器地址之后，把配置里那个目录（含子目录）扫一遍，
扫到的音频就是这个曲库 —— 点一下就能放。扫描结果是一份本地缓存（连同封面、歌词、
远端标签），所以下次进应用列表是现成的；服务器上改了东西点一下「刷新」即可。
播放本身是带认证头的流播，「边听边下」交给播放缓存，最多算一份缓存。

本文记 WebDAV 协议的调研结论、平台 API 的取舍，以及最后实现出来的样子。

> 已实现（`core/webdav/` + 「设置 - WebDAV 云端音乐」+ 「我的 - 云端音乐」）：
> 连接配置与自检、**扫描服务器目录即曲库**（递归收集 + 进度 + 可取消）、
> 远端标签 / 同目录封面 / 同目录 `.lrc`、平台匹配（封面 + 歌词，与本地音乐同一套
> 「宁缺勿错」的打分）、带认证头流播、边听边下（含预取下一首）、
> 歌单与收藏（非同步侧表）、排除同步。

## 1. WebDAV 协议：这件事到底要哪些东西

WebDAV（RFC 4918）是 HTTP 的扩展，音乐这一场景只用得上四件事：

| 要做的 | 用的方法 | 关键点 |
| --- | --- | --- |
| 列目录 | **PROPFIND** + `Depth: 1` | 请求体是 XML（要哪几个属性），响应是 `207 Multi-Status` 的 XML |
| 取文件 | **GET** | 与普通下载一样；服务器普遍支持 `Range`（播放器 seek 靠它） |
| 读标签（可选） | GET + `Range`（由平台封装） | 见第 3 节：用 `AVMetadataExtractor` 的网络源模式，不用自己解析 ID3 |
| 认证 | `Authorization: Basic ...` | 自建服务基本都是 Basic，见第 4 节 |

### PROPFIND 的报文长这样

请求体（只要四个属性，不用 `allprop` —— 免得被塞一坨用不上的）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/><D:resourcetype/><D:getcontentlength/><D:getlastmodified/>
  </D:prop>
</D:propfind>
```

响应（服务器会**把被请求的那个目录自己也列一条**，这是 Depth: 1 的惯例）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/music/</D:href>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop><D:getcontentlength/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/music/a.mp3</D:href>
    ...
  </D:response>
</D:multistatus>
```

解析时踩到的四个坑（都在 `core/webdav/WebDavXml.ets` 里处理了）：

1. **命名空间前缀五花八门**：`D:` / `d:` / `ns0:`，有的服务器完全不写前缀。所以读标签名
   一律先剥前缀再比（`localName`），解析器也开了 `ignoreNameSpace`；
2. **`<D:collection/>` 是「这是目录」的唯一标志**：`resourcetype` 里有没有它。自闭合标签
   的 START/END 事件各家解析器报得不一样，所以 START_TAG 和 END_TAG 两处都记一次；
3. **href 有三种写法**：绝对路径（`/dav/music/a.mp3`）、完整 URL（`http://host/...`）、
   相对路径。而且有的服务器（旧版 Apache、部分网盘）会把中文**原样**吐回来。
   所以 `resolveHref` 按三种情况补全，`encodeHref` 只转义真正非法的字符、并且
   **把 `%` 当安全字符**（已经转义过的序列不会再转一遍）；
4. **目录自己那条要摘掉**：按 href 的路径比（`samePath`，忽略大小写与尾斜杠），
   否则浏览时目录里会多出一行它自己。

还有一个现实问题：**认证失败时服务器返回的往往不是 XML，而是一张 HTML 登录页**。
`parsePropfind` 遇到解析不了的内容返回空数组，再由上层按状态码给出人话（见第 4 节）。

### `customMethod`：PROPFIND 在 HarmonyOS 上怎么发

`@ohos.net.http` 的 `RequestMethod` 枚举里**没有 PROPFIND**（只有 OPTIONS/GET/HEAD/
POST/PUT/DELETE/TRACE/CONNECT）。API 23 起 `RequestOptions` 多了一个 `customMethod`，
官方注释里直接写了用途：

> Custom request method. For example, when the WebDAV extension protocol is implemented,
> **customMethod** has a higher priority than **method**.

本工程 `compatibleSdkVersion = 6.1.0(23)`，正好可用，所以走这条路（比伪造一个枚举值可靠）：

```ts
const response = await request.request(url, {
  method: http.RequestMethod.POST,   // 被 customMethod 盖掉，只用来满足类型
  customMethod: 'PROPFIND',
  header: { Depth: '1', 'Content-Type': 'application/xml; charset=utf-8', Authorization: ... },
  extraData: PROPFIND_BODY,
  expectDataType: http.HttpDataType.STRING,
});
```

### 目录一定要带尾斜杠

对集合（collection）发 PROPFIND 时 URL 必须以 `/` 结尾，否则不少服务器会
301 到带斜杠的地址、而这个重定向对扩展方法不一定被跟随。所以配置里存的地址
末尾斜杠去掉（`normalizeServerUrl`），请求时再补上（`withTrailingSlash`）。

## 2. 带认证头播放：AVPlayer 的哪条路能挂请求头

这是整个功能最关键的一处。项目原来的网络播放是：

```ts
player.url = url;        // 裸字符串，没有任何地方能挂 Authorization
```

WebDAV 一定要求认证，而 `player.url` 挂不上头。官方给「带请求头的媒体源」的形态是：

```ts
const source: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
await player.setMediaSource(source, this.playbackStrategy());
```

三个好处：

1. **能带任意请求头**（`createMediaSourceWithUrl(url, headers)` 的第二个参数就是它）；
2. **可以在设源的同时给出播放策略**，所以不必再走「先设源、等进入 initialized、
   再补 `setPlaybackStrategy`」那两步（原来的 `prepareWithStrategy` 就是为这个绕路写的）。
   两处用的策略合并成了一个 `LxPlayer.playbackStrategy()`，保证值一致；
3. 状态机不变：`setMediaSource` 在 idle 态把播放器推进 initialized，后面的
   `prepare` / `play` 仍由原来的 `stateChange` 回调驱动。

失败的退路：`setMediaSource` 抛错时退回不带头的 `player.url`（匿名可读的服务器照样能放），
真的放不出来由播放器的错误回调报上去 —— 不让「这台设备/版本不支持」变成「完全放不了」。

另外，`AVMetadataExtractor` 也有一个带头的网络源入口（API 20）：

```ts
extractor.setUrlSource(url, headers);      // 只支持 fetchMetadata / 缩略图
const meta = await extractor.fetchMetadata();
```

**它能读远端标签（歌名/歌手/专辑/时长），但读不到内嵌封面** —— 官方写明网络源只支持
「network metadata」和缩略图。这一点决定了封面的方案（见第 5 节）。

## 3. 曲库就是「一次扫描的结果」

没有导入这一步，所以要回答的是：**服务器上的目录怎么变成一份能播的列表**。

```
设置里填地址 → 测试连接（列一次根目录）→ 扫一遍 → 直接能播
```

扫描分两步，先快后慢：

1. **列目录**（PROPFIND，递归到 5 层）：拿到全部音频，按 URL 与上一次的结果对齐 ——
   还是同一首就把它的封面 / 歌词 / 标签 / 匹配记录**接过去**；新的一首也不问任何东西，
   歌名先按 `歌手 - 歌名` 的文件名惯例拆。这一步结束列表就已经能用了（能点、能播）。
2. **补缓存**（逐目录）：同目录的封面图（整目录共用一张，只下一次）、同名 `.lrc`、
   以及远端标签（歌名 / 歌手 / 专辑 / 时长，让平台匹配准很多）。每补完一批落盘一次，
   中途取消 / 失败都留下已完成的部分。

于是「服务器上的目录」与「本地这份缓存」的关系是：

| | 存在哪 | 谁来改 |
| --- | --- | --- |
| 曲库列表 | `files/webdav_music/index.json` | 每次扫描重建（按 URL 对齐，不是重新造） |
| 封面 / 歌词 | `files/webdav_music/`（`covers/` 与 `<key>.lrc`） | 扫描时补；不再被引用的会被回收 |
| 歌单 / 收藏里的成员 | 同一份 `index.json` 的 `lists`（非同步侧表） | 用户在界面上加 / 删 |

**为什么 key 要由 URL 派生（不是随机序号）**：歌单 / 收藏里存的就是这个 key，
播放缓存的文件名也按它算。要是每次扫描都换一批新 key，用户加进歌单的云端歌
在下一次刷新后就会「查不到」，等于丢歌。所以 `stableKeyOf(url)` 用两个 FNV-1a
拼到 64 位量级（单个 32 位哈希在几千首规模上撞车概率约千分之几，而 key 撞车
意味着两首歌互相认错），真撞了还有一层「加后缀」兜底。

**为什么扫描不到不等于删除**（`pruneUnseen`）：一次扫描可能不全（触到上限、某个目录
超时、网络抖），要是顺手把没扫到的条目连同歌单引用一起清掉，用户会莫名其妙地丢歌。
所以只有「这次没扫到 **且** 没有被任何歌单 / 收藏引用」才会被清 —— 没有引用又没扫到的
（服务器上真删了、或改名了）留着只是垃圾。被引用的那些留着，最坏情况是歌单里有一条
点开报「已经不在云端」，服务器恢复了下次扫描就正常了。

扫描有明确的边界，并且**如实报告**：最多下探 5 层、最多 300 个目录 / 5000 首，
触到上限就说「目录太多，只扫了一部分」；有目录读不到（权限 / 超时）也报数量；
扫到但格式不支持（ape / wma）同样报出来 —— 不假装扫完了，也不让用户以为「少了几首」。

## 4. 为什么是「流播 + 边听边下」，而不是先下载再播

三条路都试过一遍，结论：

| 方案 | 结论 |
| --- | --- |
| **带认证头直接流播（采用）** | 起播最快，seek 由 AVPlayer 用 Range 自己做；缓冲水位沿用项目原有的 20 秒 + 8 秒恢复线 |
| 先整首下到沙箱再播 | 起播要等整首，几十 MB 的歌在弱网下要等很久；但**作为补充仍然保留** —— 边听边下就是这个 |
| 把 URL 交给系统/外部播放器 | 用户要的是「在这个应用里放」，不做 |

**边听边下直接复用了 `AudioCache`**：它本来就是「整首下到 `files/lx_media_audio/`
（LRU 淘汰）、下次播放直接读本地文件、切歌前预取下一首」那一套。只需要给它补一件事 ——
下载请求要能带自定义头：

- `DownloadTask` 多了 `headers` 字段（默认 `{}`）；
- `cacheSong / prefetchSong / enqueue` 多了一个可选的 `headers` 参数；
- 分块 Range 请求那里把 `task.headers` 合并进去。

于是云端歌和在线歌共用同一条缓存链路：听过的歌下次读本地文件（不联网、不看网络脸色），
预取下一首也照旧。缓存键就是条目 id（`webdav_<key>`），与 `mediaKeyOf(musicInfoJson)`
天然一致（见第 7 节）。

**不放进 `DownloadManager`**：那条路要问音源要链接（`SourceEngine.getMusicUrl`），
云端歌没有音源身份。所以 `enqueue()` 里拦一道，界面上也不显示「下载」这一项
（与本地音乐同一处处理）。

## 5. 认证：只做 HTTP Basic，且把失败翻译成人话

自建 WebDAV 服务（Nextcloud / Alist / 群晖 / Apache mod_dav / nginx-dav）默认都支持
Basic。服务器只开 Digest 时会返回 `401` + `WWW-Authenticate: Digest ...`，
这时给一句明确的话，不做半吊子实现：

> 服务器只支持 Digest 认证，本应用目前只支持 HTTP Basic（Nextcloud / Alist / 群晖一般都能用 Basic）

状态码一律翻译成人话（`WebDavClient.assertOk`），因为让用户看 `405` 等于没说：

| 状态码 | 提示 |
| --- | --- |
| 401 | 服务器要求登录，请填用户名和密码 / 用户名或密码不对 |
| 403 | 这个账号没有读取该目录的权限 |
| 404 | 服务器上说这个地址不存在，检查一下路径（注意大小写） |
| 405 / 501 | 服务器不支持 WebDAV 的 PROPFIND，确认地址指向的是 WebDAV 服务 |
| 5xx | 服务器出错（HTTP xxx） |

用户名与密码**都留空时不发 `Authorization`**：Alist 之类默认匿名可读，
带一个空凭据反而会被拒。

密码按项目既有约定**明文落在应用沙箱**（`files/webdav_settings.json`），与同步的认证码
（`core/sync/SyncStore` 的 `keys.json`）、音源脚本一致：三方应用读不到别人的沙箱，
系统也没有给普通应用「静默存一个自己的服务凭据」的通用接口（Asset Store Kit 是给
**用户**凭据用的，会弹系统授权框，不适合这里的静默重连）。密码**不发布到 AppStorage**，
只有设置页在 `aboutToAppear` 里现取一次当输入框初值。

## 6. 封面与歌词：和本地音乐一样，但来源换了一半

| | 本地音乐 | 云端音乐 |
| --- | --- | --- |
| 元数据（歌名/歌手/专辑/时长） | 导入时读**内嵌标签** | 扫描时读**远端标签**（`setUrlSource`），读不到退回文件名（`歌手 - 歌名`） |
| 封面 | 导入时取**内嵌封面** | ①**同目录的图片**（`cover/folder/front/album/artwork/thumb` + `jpg/jpeg/png/webp/bmp`，其次与歌曲同名的图）②平台匹配 |
| 歌词 | ①同目录一起导入的 `.lrc` ②平台匹配 ③手动纠正 | ①**服务器上同目录的 `.lrc`**（扫描时一并取回）②平台匹配 ③手动纠正 |

封面为什么不能像本地那样读内嵌的：官方写明 `AVMetadataExtractor` 的**网络源只能读
metadata，读不到内嵌封面**（第 2 节）。于是改成「音乐库的惯例命名」：一个专辑一个目录 +
一张 `cover.jpg` 是最普遍的存法，所以**封面按目录取、一整个目录共用一张**，
同一个 URL 只下载一次。

封面文件名用**目录 URL 的短哈希**（`f<hash>.jpg`）而不是每首歌一个：同一目录里的歌天然
共享，删掉其中一首也不会把别人的封面删掉。不再被任何歌引用的封面由 `sweepOrphans` 统一清
（这就是云端曲库的 `sweepOrphans` 与本地那份的差别：**音频在服务器上，本地没有副本可检查**，
所以它只管封面与歌词的引用回收）。

同目录 `.lrc` 的两种写法都认：`song.lrc`（标准）与 `song.mp3.lrc`（有些抓词工具这么存）。

### 平台匹配：一次匹配，封面与歌词共用

云端文件同样没有平台身份，只有标签或文件名，所以拿「歌名 + 歌手 + 时长」去内置平台搜索里
找一首对应的歌 —— **打分逻辑原封不动复用本地音乐那套**（`core/local/LyricMatch`，
策略是「宁缺勿错」：配错的歌词比没有歌词更难解释）。匹配结果落盘在曲库索引里
（`matchJson` / `matchSource` / `matchAt`），**只搜一次**，之后取词 / 取图都用它。

封面与歌词会同时来问同一个匹配结果（`loadCover` 先、`loadLyric` 后），所以
`PlaySession.webDavMatches` 里留的是**在飞的 Promise**，后来者等同一个结果 ——
否则第二条路会看到「已经在搜了」就放弃，表现成「封面有了、歌词没了」。

平台封面的地址也存进曲库索引（`remoteCover`），不在 `CoverStore` 里转手：`CoverStore`
的封面是「按平台接口现查、缓存在 MediaCache」，而云端歌的封面优先级是**同目录图 >
平台图**，这份优先级得由曲库自己说了算。同时给 `CoverStore.coverFor / request` 加了一道
来源判断：只有内置平台（kw/kg/tx/mg/wy）才走「现查封面」，`local` / `webdav` 直接返回，
免得拿这两个来源去问平台接口和源脚本、白跑一趟还被记成「解析失败」。

### 「读取云端标签」是个开关

扫描的第二步补标签是**每首一次网络请求**，几十首的目录会明显慢一点，所以给了开关
（设置 - WebDAV 云端音乐 - 读取云端标签，默认开）：

- 开着：匹配封面与歌词准很多（时长是打分里很关键的一条）；
- 关掉：用文件名猜，播放时照样能听。

补信息按**目录**推进，每个目录补完就落盘一次，中途取消 / 失败都留下已完成的部分；
进度写进 AppStorage（`webdav_progress`），界面上是「正在读取云端信息 12/340 歌名」+ 取消。
读取标签带 12 秒超时（`AVMetadataExtractor.fetchMetadata` 在网络源上没有超时参数，
服务器半死不活时会一直挂着，扫描几百首时不能让它挂住整条队列）。

## 7. 界面

**「我的 - 云端音乐」**：一颗主按钮 + 列表。

- 没配服务器 → 按钮是「去设置」（跳到设置子页，空状态里也有一句引导）；
- 配了但没扫过 → 按钮是「连接并扫描」，而且**进这一页会自动扫一次** ——
  这就是「连上就直接能播放」那一步，不用用户去找按钮；
- 扫过 → 按钮是「刷新」，按钮右边显示「N 首 · 总大小」，下面一行是上次扫描的时间。

列表就是扫描结果，点一下即可播放（进正常的播放队列 / 播放页 / 播控中心）。
**没有「移除」**：服务器上的文件不归这个应用管，要拿掉什么直接在服务器上删、
回来点「刷新」就没了。所以这一段的「清空」按钮也不显示（标题右边那个垃圾桶），
本地缓存那点东西在设置页里清。

**「设置 - WebDAV 云端音乐」**：服务器地址 / 用户名 / 密码（改动即时生效）、
「测试连接并扫描」（连上就顺手扫一次）、「重新扫描」、读取云端标签开关、
曲库与缓存（条数 / 服务器上的总大小 / 上次扫描 / 本地缓存占用 / 清空本地缓存）。

音频格式白名单**复用本地音乐那份**（`LocalMusic.isSupportedAudioFile` /
`isUnsupportedAudioFile`）：AVPlayer / AVMetadataExtractor 官方支持的
m4a / aac / mp3 / ogg / wav / flac / amr 只能有一处定义。`.lrc`、封面图、
`desktop.ini` 这些不是歌曲，静默跳过；ape / wma / dsf 这些明知放不了、但确实是音频的，
报「格式不支持」，不静默丢。

## 8. 与现有链路的接口：三个不变式

云端歌在运行时就是一条 `SongItem`（`source = 'webdav'`，`quality = 'webdav'`），
`musicInfoJson` 里放一份我们自己造的 `LxMusicInfo` 形态的壳
（`{ source:'webdav', songmid:<key>, name, singer, albumName, interval, img, types:[], _types:{}, typeUrl:{}, lrc:null, otherSource:null }`）。
队列 / 歌单 / 收藏 / 播放历史 / 播控中心 / 迷你栏 / 播放页全都不用改，它们只认 `SongItem`。

**不变式一：`mediaKeyOf(musicInfoJson) === SongItem.id`。**
`source='webdav'` + `songmid=<key>` 算出来是 `webdav_<key>`，与条目 id 前缀一致。
播放缓存（`AudioCache`）与下载索引都按这个键找文件，不一致就会出现「缓存了却读不到」。
这条与本地音乐是同一个不变式，测试里钉着（`entry/src/test/WebDav.test.ets`）。

**不变式二：`isSyncable()` 必须是 false。**
`SyncConvert.parseOldMusicInfo` 里原本有一条 `source === 'local' → null`，现在扩成
`local | webdav`。云端歌的 `musicInfo` 是我们自己造的壳，服务端不认识，上行只会往别人的
列表里塞打不开的东西。同步设置页也注明了这一点。

**不变式三：歌单 / 收藏走非同步侧表。**
`LocalLibrary` 里参与同步的那份数据要按 `listData()` 的 JSON 算 md5 与服务端比对，
`musicsOf()` 又会把不可同步的条目直接丢掉 —— 所以「不属于在线歌的歌单成员」必须另存。

原来这张侧表只有本地音乐一张（`LocalMusic.lists`）。这次把公共面抽成了接口
（`core/local/SideTable.ets` 的 `SongSideTable`），`LocalMusic` 与 `WebDavLibrary` 各实现一份，
`LocalLibrary` 按一个数组统一读写：

```ts
private sideTables(): SongSideTable[] {
  return [this.local, this.webdav];
}
```

合并读取（本地在前、云端在后）、曲目数计数、加 / 删 / 覆盖、删歌单清引用、收藏侧表同步，
全都变成对数组的循环。以后再加第三种来源（SMB / Jellyfin…），在 `sideTables()` 里加一项
就够了，不必再改所有合并点。

播放链路上插了一条**云端直路**，位置与本地直路一致 —— 都在音源检查**之前**：

```
let item = this.queue[index]
if (item.source === 'local')  { 读沙箱文件 -> return }
if (item.source === 'webdav') { 带认证头流播 -> return }     // 新增
if (!engine.isInited()) { ... }                              // 原来的音源检查往后挪了
```

理由同样直接：用云端曲库不该被「有没有导入音源」绑架。其它会误伤的地方逐个加了早退：
`prefetchNext`（云端歌走自己的预取）、`loadCover` / `loadLyric`（走云端那套匹配）、
`pushBuffered`（走缓存的歌按整首画满）、`DownloadManager.enqueue`、以及界面上四处
「下载」入口。播放页的音质标签对云端歌显示「云端」，「匹配歌词」入口对本地歌与云端歌
都出现（手动纠正那条路两边共用）。

## 9. 实现出来的样子

| 职责 | 位置 |
| --- | --- |
| 类型与常量（`webdav_` 前缀、`webdav` 音质标记…） | `entry/src/main/ets/core/webdav/WebDavTypes.ets` |
| PROPFIND 的 XML / href 处理（纯函数） | `entry/src/main/ets/core/webdav/WebDavXml.ets` |
| 协议客户端（PROPFIND / GET / 远端标签 / 递归收集 / 状态码翻译） | `entry/src/main/ets/core/webdav/WebDavClient.ets` |
| 云端曲库（索引、封面、歌词、匹配记录、非同步侧表） | `entry/src/main/ets/core/webdav/WebDavLibrary.ets` |
| 连接设置（地址 / 账号 / 密码，沙箱落盘） | `entry/src/main/ets/core/webdav/WebDavSettings.ets` |
| 非同步侧表的公共面（本地 / 云端共用） | `entry/src/main/ets/core/local/SideTable.ets` |
| 设置子页（连接自检 / 重新扫描 / 读取标签开关 / 缓存管理） | `entry/src/main/ets/views/WebDavSettingsView.ets` |
| 「我的 - 云端音乐」分段页（列表 + 刷新 + 扫描进度） | `entry/src/main/ets/views/WebDavView.ets` |
| 播放直路（`playWebDavItem`）与各处早退 | `core/player/PlaySession.ets` |
| 带请求头的播放（`playUrlWithHeaders`） | `core/player/LxPlayer.ets` |
| 缓存下载的自定义头（`DownloadTask.headers`） | `core/music/AudioCache.ets` |
| 侧表合并 / 计数 / 维护 | `core/sync/LocalLibrary.ets` |
| 同步排除（`local` 与 `webdav` 两个来源） | `core/sync/SyncConvert.ets` |
| 用例（XML 解析 / id 不变式 / 稳定 key / 同步排除 / 同目录封面歌词的挑选 / 地址规范化） | `entry/src/test/WebDav.test.ets` |

落盘布局：

```
files/webdav_music/
  index.json         { version, root, scannedAt, truncated,
                       songs: [...], lists: { <歌单id>: [key...] } }
  <key>.lrc          从服务器同目录取回来的歌词（统一转成 UTF-8 存）
  covers/f<hash>.jpg 同目录封面（一整个目录共用一张，文件名是目录 URL 的短哈希）
files/webdav_settings.json   { version, url, username, password, readTags }
```

索引每条记：`key`（由 URL 派生的稳定标识）、服务器 URL、父目录、文件名、
封面（本地图 / 平台图两个字段）、歌词文件名、匹配结果（`matchJson` / `matchSource` /
`matchAt`）、歌名歌手专辑时长、字节数、`seenAt` / `seen`（上次扫描有没有见到）、
`tagsDone`（标签问过了，避免每次扫描重问）。

## 10. 已知限制与风险

| 事项 | 状态 |
| --- | --- |
| 只支持 HTTP Basic | 有意为之：自建服务基本都支持；Digest 会明确提示（第 4 节） |
| 加密存储密码 | 未做：按项目既有约定明文落沙箱（第 4 节），设置页里说明了 |
| 远端文件被删 / 改名 | 刷新后列表里就没了；若它还在某个歌单 / 收藏里，点开报「已经不在云端曲库里了」（这是有意的，见第 3 节 `pruneUnseen`） |
| 服务器不支持 PROPFIND（只开放了 GET） | 明确报错（405/501），不做「猜目录」的兜底 |
| 递归收集的上限 | 5 层 / 300 目录 / 5000 首，触到就如实说明只扫了一部分 |
| 大目录的扫描耗时 | 列表先出（只列目录），随后逐目录补封面 / 歌词 / 标签 + 进度 + 可取消；不想要就关掉「读取云端标签」 |
| 换了服务器地址 | 进「云端音乐」页会发现扫描根地址与配置不一致，自动重扫一次 |
| `playUrlWithHeaders` 在个别设备/版本上不支持 | 退回不带头的 `url`；匿名可读的服务器能放，需要认证的会由播放器报错 |
| 平台匹配依赖平台搜索接口 | 与本地音乐同样的风险：某个平台不通不影响其它平台；全都不通时靠同目录 `.lrc` 或手动匹配 |
| 队列里的云端歌不参与同步 | 与本地音乐同一处已知限制：队列（= 试听列表）是同步结构，镜像时会丢；歌单 / 收藏里的不会丢（在侧表里） |
| 真机验证 | **未做**：本机 ohpm 环境有问题（`ERR_REQUIRE_ESM`），只做了静态检查；真机要重点验「带认证头流播」与远端标签读取 |

## 11. 分期

- **P0 已完成**：连接配置与自检、扫描服务器目录即曲库（递归 + 进度 + 可取消）、
  远端标签 / 同目录封面 / 同目录 `.lrc`、带认证头流播、边听边下与预取、
  播放链路的直路与各处早退、排除同步。
- **P1 已完成**：平台匹配（封面 + 歌词，复用本地那套打分）、手动纠正（播放页
  「匹配歌词」）、加进歌单与收藏（非同步侧表）、「我的 - 云端音乐」分段页与刷新、
  缓存管理与「读取云端标签」开关。
- **P2**（可选）：WebDAV 之外再支持更常见的网盘协议（SMB / Jellyfin / Subsonic）——
  侧表已经抽成接口，曲库那一层照着 `WebDavLibrary` 再写一份即可；
  子目录筛选（现在是一口气把配置目录下的所有音乐都列出来）；
  失效条目的界面标记；凭据改走 Asset Store Kit（需要接受一次系统授权）。

## 附：相关文件

| 职责 | 文件 |
| --- | --- |
| 协议客户端与 XML 解析 | `core/webdav/WebDavClient.ets`、`core/webdav/WebDavXml.ets` |
| 曲库与类型 | `core/webdav/WebDavLibrary.ets`、`core/webdav/WebDavTypes.ets` |
| 连接设置 | `core/webdav/WebDavSettings.ets` |
| 界面 | `views/WebDavSettingsView.ets`、`views/WebDavView.ets` |
| 播放与缓存 | `core/player/PlaySession.ets`（`playWebDavItem`）、`core/player/LxPlayer.ets`（`playUrlWithHeaders`）、`core/music/AudioCache.ets`（`DownloadTask.headers`） |
| 侧表与同步排除 | `core/local/SideTable.ets`、`core/sync/LocalLibrary.ets`、`core/sync/SyncConvert.ets` |
| 与本地音乐的对照 | `docs/LOCAL_MUSIC.md` |
| 路由与页面挂载 | `pages/Index.ets`（`PAGE_WEBDAV`）、`views/MineView.ets`（分段页「云端音乐」）、`views/SettingsView.ets`（设置项） |
