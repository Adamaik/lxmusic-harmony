# 洛雪同步（LX Sync）鸿蒙端实现

本移植版实现了洛雪音乐的**数据同步**能力：作为客户端连接官方同步服务端
（`lx-music-sync-server`，也就是桌面端／移动端在用的那个），完成与官方客户端一样的
歌单、收藏、试听列表、「不喜欢的歌曲」同步。

协议不是逆向猜的，是对着两份上游源码逐条对齐的：

| 上游 | 用途 |
| --- | --- |
| `lx-music-mobile/src/plugins/sync/**` | 客户端行为：握手、认证、消息封装、各模块回调 |
| `lx-music-mobile/src/store/sync`、`src/core/sync.ts` | 同步状态与「同步方式选择」的交互 |
| `lx-music-sync-server/src/server/*`、`src/modules/*/sync/*` | 服务端驱动的同步流程与动作语义 |
| `message2call@0.1.3`（npm 包源码） | 线上报文格式 |

## 一、协议要点（实现依据）

### 1. 连接与认证

1. `GET /hello` → 返回 `Hello~::^-^::~v4~`；带 `Hello~::^-^::` 前缀但版本号不同则报
   「服务端版本过高/过低」。
2. `GET /id` → 返回 `OjppZDo6<serverId>`；密钥按 `serverId` 分开存。
3. `GET /ah`，两种方式：
   - **认证码**：`key = base64(md5(authCode).substring(0,16))`，
     `m = AES-128-ECB/PKCS7("lx-music auth::\n<base64(X.509 公钥)>\n<设备名>\nlx_music_mobile", key)`；
     服务端用 RSA-OAEP(SHA-1) 把 `{clientId, key, serverName}` 加密后放在响应体里返回，
     客户端用本地私钥解开并保存。
   - **已保存密钥**：`m = AES(authMsg + 设备名, key)`，头部带 `i: clientId`；
     用 AES 解响应，必须等于 `Hello~::^-^::~v4~`。
4. `WS /socket?i=<clientId>&t=<AES("lx-music connect", key)>`。
5. 认证消息第四行写 `lx_music_mobile`，服务端据此每 30s 发一次文本 `ping`（收到即重置存活计时）。

加密参数（与官方移动端原生模块一致）：

| 用途 | 算法 | 参数 |
| --- | --- | --- |
| 对称 | AES-128-ECB | PKCS7 填充，密文 base64 |
| 非对称 | RSA-2048 | OAEP，摘要 SHA-1，MGF1-SHA1 |
| 摘要 | MD5 | 小写 hex（服务端 `createHash('md5').digest('hex')`） |
| 压缩 | gzip | 仅当消息长度 > 1024，加 `cg_` 前缀，body 为 base64 |

> 注：洛雪移动端源码里写的 `AES_MODE.ECB_128_NoPadding` 实际取值是 Java 的字符串 `"AES"`，
> 即 `AES/ECB/PKCS5Padding`——所以是 PKCS7 而不是「无填充」。这点在客户端与服务端两侧是一致的。

### 2. 报文格式（`{name, path, data}`）

官方两端都用 message2call 互相调用，线上只有三种报文：

```jsonc
// 调用（我调对方）
{ "name": "onListSyncAction__3", "path": ["onListSyncAction"], "data": [ ...参数 ] }
// 请求（对方调我，path 指向方法名）
{ "name": "list_sync_get_md5__12", "path": ["list_sync_get_md5"], "data": [] }
// 应答（按原 name 回包）
{ "name": "list_sync_get_md5__12", "error": null, "data": "…md5…" }
```

鸿蒙侧没有用 Proxy（ArkTS 静态类型下显式注册更好排查），但**报文格式逐字段一致**，
所以能和官方客户端连同一个服务端。相关实现在 `SyncRpc.ets`。

### 3. 同步流程（服务端驱动，客户端只提供回调）

```
连接成功
  └─ 服务端调 getEnabledFeatures('server', {list:1, dislike:1})
       └─ 客户端回 { list: {skipSnapshot:false}, dislike: {skipSnapshot:false} }
  └─ 每个启用的模块依次：
       list_sync_get_md5          → 客户端算「本地列表 JSON 的 md5」
       若与服务端快照 key 不同：
         list_sync_get_sync_mode  → 客户端弹「同步方式」选择框，回传用户选的那一项
         list_sync_get_list_data  → 客户端交出本地数据
         list_sync_set_list_data  → 服务端把合并结果写回客户端
         list_sync_finished       → 客户端把该模块标记为就绪
       （dislike 模块同名流程，数据是一整段文本规则）
  └─ 服务端调 finished() → 客户端置「已连接」状态
之后进入实时阶段：
  本地改动 → onListSyncAction / onDislikeSyncAction → 服务端（并广播给同账号其它设备）
  其它设备的改动 → 服务端调客户端的 onListSyncAction / onDislikeSyncAction
```

关键点：**合并算法在服务端**（按用户选的方式做 merge/overwrite，见
`lx-music-sync-server/src/modules/list/sync/sync.ts`），客户端不需要重写合并逻辑，
只需要如实上报本地数据、如实应用服务端下发的结果和动作。

两个容易踩的点（实测确认）：

- **首次连接不会问「同步方式」**：服务端按 `clientId` 记着上次同步的快照 key，
  没有快照时直接走 `handleSyncList`：谁那边是空的就以另一边为准，只有两边都有数据
  才会问方式。所以「服务端为空 + 本机有数据」会直接把本机数据推上去，不弹框。
- **md5 分支只在有快照之后才走**：第二次起服务端会调 `list_sync_get_md5`，
  与本机数据算出的 md5 相同就直接 `finished`（不再询问、不再传数据）。
  这也说明「列表数据的 JSON 字段顺序」必须和服务端一致，否则每次连接都会被判为「不一致」，
  反复弹框合并——映射层照抄官方 `toNewMusicInfo` 的书写顺序就是为了这件事。

## 二、鸿蒙侧实现

代码在 `entry/src/main/ets/core/sync/`：

| 文件 | 职责 |
| --- | --- |
| `SyncTypes.ets` | 协议常量与全部数据类型（KeyInfo / ListData / 动作 / 同步方式选项） |
| `SyncCrypto.ets` | AES（复用 `LxCrypto` 的纯 ArkTS 实现）、RSA（系统 CryptoArchitectureKit）、MD5 |
| `SyncGzip.ets` | 系统 zlib 的 GZip 封装（文件形态，用缓存目录中转）+ `cg_` 打包/解包 |
| `SyncRpc.ets` | message2call 兼容的极简 RPC（调用/请求/应答三态） |
| `SyncStore.ets` | 落盘：服务器地址、各 serverId 的身份密钥、音乐库、不喜欢规则 |
| `SyncConvert.ets` | 内部歌曲 ↔ 同步用歌曲的映射（照抄 `toNewMusicInfo`/`toOldMusicInfo`） |
| `LocalLibrary.ets` | 本地音乐库：数据持有、动作应用、上行动作生成 |
| `SyncClient.ets` | 认证、WebSocket、心跳/重连、注册并实现服务端要调的那批方法 |
| `SyncManager.ets` | 对外门面：开关、地址、状态、同步方式选择交互 |

界面：

| 文件 | 说明 |
| --- | --- |
| `views/SyncSettingsView.ets` | 设置 → 同步设置：开关、服务器地址（含历史）、认证码、设备名、状态、同步内容摘要、不喜欢规则增删 |
| `views/SyncModeSheet.ets` | 服务端要求选择同步方式时弹出的选择框（文案与官方一致） |

接进现有界面的地方：

- `PlaySession`：新增 `LibrarySink`，队列/收藏的本地改动通知音乐库；
  新增 `adoptLibraryState()`，服务端改动整体替换界面状态并递增 `K_LIBRARY_VERSION`。
- 「我的 → 收藏」＝ 洛雪的 `loveList`；长按可取消收藏，清空按钮会同步。
- 「歌单」＝ 洛雪的 `userList`；`+` 新建、长按重命名/删除、点击把歌单歌曲装入队列播放。
- 「播放列表」＝ 洛雪的 `defaultList`（试听列表）；长按可收藏／加入不喜欢／移出队列。

### 数据映射

同步用歌曲是洛雪的 `MusicInfoOnline` 形态（`id / name / singer / source / interval / meta`），
而本移植版的播放链路吃的是内置 SDK 形态（`songmid / types / _types / …`，存在 `musicInfoJson` 里）。
两者互转严格照抄官方 `src/utils/index.ts` 的 `toNewMusicInfo` / `toOldMusicInfo`，
**包括字段书写顺序**——因为服务端的快照 key 是「列表数据 JSON 字符串的 md5」，
顺序一致，同一份数据算出的 md5 才会一致，重连时才会被判为「已是最新」而跳过合并。

各平台的平台私有字段也照着搬：`kg` 用 `meta.hash` 且 `id = songmid_hash`；
`tx` 用 `strMediaMid / albumMid / meta.id`；`mg` 用 `copyrightId` 等。
`_qualitys` 的值不带 `type` 字段（官方的取值只有 `size`，酷狗另有 `hash`），这一点也照做了。

### 同步不了的数据

演示数据（`musicInfoJson` 为空）和 `source === 'local'` 的条目**不参与同步**：
上行前会被过滤掉，因此首次安装界面上的演示歌单/收藏不会污染服务端。

## 三、本地验证

### 1. 起一个官方同步服务端（Node）

```bash
# 取源码
curl -sL https://github.com/lyswhut/lx-music-sync-server/archive/refs/heads/master.tar.gz | tar xz
cd lx-music-sync-server-master
npm install

# 配置 config.js：至少一个用户（name + password 就是 App 里填的认证码）
#   users: [ { name: 'tester', password: '123456' } ]

# 跑起来（ts-node 直接跑源码，不需要 build）
PORT=9527 BIND_IP=0.0.0.0 node -r ts-node/register -r tsconfig-paths/register ./src/index.ts
```

自检（应分别返回 `Hello~::^-^::~v4~` 与 `OjppZDo6…`）：

```bash
curl http://127.0.0.1:9527/hello
curl http://127.0.0.1:9527/id
```

### 2. App 侧

1. `devecocli run`（或 DevEco 直接跑）装到模拟器／真机。
2. 设置 → 同步设置 → 服务器地址填 `http://<主机IP>:9527`，认证码填 `123456`，
   打开「启用同步」→ 首次会走认证码流程建立身份，之后改用保存的密钥。
3. 状态应依次出现「连接中… → 已连接，正在同步… → 已连接，同步中」。
   若两端数据不同，会弹出「同步方式」选择框，选完即完成一次合并。
4. 之后在 App 里改收藏／建歌单／加不喜欢，在另一台设备（洛雪桌面端或移动端）
   连同一服务端即可看到变化；反向亦同。

模拟器访问主机：DevEco 模拟器通常可用 `10.0.2.2`；不行就用主机局域网 IP。

### 3. 排查入口

```bash
# 客户端日志（TAG: SyncManager / SyncClient / SyncRpc / SyncGzip / SyncStore / LocalLibrary）
devecocli log --level I --keyword Sync
# 服务端日志（源码目录下 logs/ 里按天分文件，含 connection / sync 记录）
```

落盘数据在应用沙箱 `filesDir/lx_sync/`：`config.json`（地址/开关/设备名）、
`keys.json`（按 serverId 的身份）、`list.json`（洛雪线上格式的列表数据）、
`dislike.json`。`list.json` 就是「会被同步出去的那份数据」，可直接查看核对。

## 四、已知限制

- **同步方式选择框**是自绘底部面板（`bindSheet`），未做官方那种「完全覆盖」勾选框的
  两段式交互，但六种 list 方式与服务端的取值完全一致。
- **试听列表与播放队列合并为一份数据**：本移植版没有独立的「试听列表」页，
  沿用洛雪桌面端「试听列表就是播放队列」的含义，因此换播放队列会同步为
  `list_music_overwrite('default', …)`。若以后加了独立试听列表页，应把这层映射拆开。
- **歌单排序**（`list_update_position`）只实现接收，界面还没有拖拽排序入口。
- **不喜欢规则**界面只支持「按歌名/歌手添加、单条删除、清空」，没有做命中后的歌曲灰显。
- 未使用服务端的**快照（snapshot）机制**：与官方移动端一致，上报 `skipSnapshot: false`，
  每次连接由服务端用 md5 判断是否需要合并。
- 心跳只用服务端的文本 `ping` 做存活判断（收到第一个 ping 后才开始计时），
  WS 层的 ping/pong 由系统协议栈处理。

## 五、回归方法

纯逻辑（AES/MD5/Base64/编解码转换）按项目既有做法可以在主机上跑：
把对应 `.ets` 复制成 `.ts`，用 DevEco 自带 Node 执行
`node --experimental-strip-types <script>.ts`，与 `node:crypto` 的向量对比。

## 六、已完成的验证（2026-09-13）

### 1. 加密层与 `node:crypto` 逐字节对齐（主机，已完成）

用 `node --experimental-strip-types` 直接跑 `LxCrypto.ets`（复制成 `.ts`），
对多种长度（含中文、1000 字节）的明文做双向验证：

| 检查 | 结果 |
| --- | --- |
| 本实现加密的 base64 === Node `aes-128-ecb`（默认 PKCS7） | 全部一致 |
| 本实现加密 → Node 解密 | 还原一致 |
| Node 加密 → 本实现 `aes128EcbPkcs7DecryptBytes` 解密 | 还原一致 |
| `md5Hex` === Node `createHash('md5').digest('hex')` | 全部一致（含空串、中文、列表 JSON） |

服务端用的就是 Node 的 `aes-128-ecb`，所以这条等价于「本实现的对称加密与服务端同算法同结果」。

### 2. 真实服务端上的完整同步（主机，已完成）

起真实的 `lx-music-sync-server`（ts-node 跑源码，`users: [{name:'tester', password:'123456'}]`），
用**手写的 message2call 报文**（与 `SyncRpc.ets` 同一套 `{name, path, data}` 格式，
刻意不使用官方客户端或 message2call 库）跑两轮连接：

- `/hello`、`/id`、认证码认证（RSA-OAEP/SHA-1 成功解出 `{clientId, key, serverName}`）、
  已保存密钥认证 —— 全部通过。
- 第一次连接（服务端为空、本机有歌单/收藏/不喜欢规则）：
  `getEnabledFeatures → list_sync_get_list_data → list_sync_finished →
   dislike_sync_get_list_data → dislike_sync_get_sync_mode → dislike_sync_get_list_data →
   dislike_sync_finished → finished`，数据被服务端接收并落盘。
- 第二次连接（本机数据 = 服务端下发的数据）：
  `getEnabledFeatures → list_sync_get_md5 → list_sync_finished →
   dislike_sync_get_md5 → dislike_sync_finished → finished`
  —— **md5 命中，跳过合并，也没有再询问同步方式**。
  这证明本实现算出的 md5（列表 JSON 的字段顺序、不喜欢规则的规范化）与官方服务端的口径一致。

### 3. 尚未在设备上验证的部分

以下依赖 HarmonyOS 运行时，主机侧无法覆盖，需要在真机/模拟器上跑一次（见第三节步骤）：

- `cryptoFramework` 的 `convertKey(null, <PKCS#8 DER 私钥>)` 是否被接受，
  以及 `RSA2048|PKCS1_OAEP|SHA1|MGF1_SHA1` 变换字符串在设备上的实际可用性
  （OpenHarmony 的 `crypto_rsa_cipher_test.cpp` 里有 `RSA1024|PKCS1_OAEP|SHA1|MGF1_SHA1` 的用例，
  解析器是通用的，但没有 RSA2048+SHA1 的现成用例）。
- 系统 `zlib` 的 GZip 文件接口（`gzopen/gzread/gzwrite`）在设备上的读写行为。
- `@kit.NetworkKit` 的 WebSocket 是否自动应答 WS 层 ping（决定长连接能否长期稳定）。
- 界面接线（同步设置页、同步方式选择框、歌单/收藏/播放列表的增删触发上行）。

`devecocli log --level I --keyword Sync` 可以一次看到这几个模块的日志。
