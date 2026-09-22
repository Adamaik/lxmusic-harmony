# lxmusic-harmony

洛雪音乐（[lx-music-mobile](https://github.com/lyswhut/lx-music-mobile)）的鸿蒙移植版，
界面与播放链路用 ArkTS / ArkUI 重写，跑在 HarmonyOS 上（bundle: `com.example.listen`）。

> 本项目不包含、也不提供任何音频内容。播放地址由你自己导入的音源脚本解析，
> 版权内容请通过正规渠道获取。

## 功能

- **音源**：内置脚本引擎，在 Web 容器里执行洛雪音源脚本，支持导入 / 启用 / 离线自检
- **播放**：AVPlayer + AVSession（播控中心、锁屏与桌面歌词、投播至、系统分享），
  音质协商，拓展音质（母带 / 全景声）解析失败时自动回退到普通音质
- **弱网**：缓冲时长拉满（20 秒，即 `preferredBufferDuration` 的官方上限 [1,20]）+
  起播/恢复水位线 8 秒；播放缓存（边听边下整首）
  给播放让路、断了接着下；上一首还在播时预取下一首，切歌直接读本地文件；
  进度条上有灰色的已缓冲段，缓冲时播放钮转圈（不退音质，见 `docs/PLAYBACK_BUFFER.md`）
- **在线**：内置平台接口的排行榜 / 歌单 / 搜索 / 推荐，封面与歌词懒解析；
  搜索是**聚合搜索** —— 一次搜五个平台并按平台交错合并，结果可按平台筛选
  （不筛就是全部，见 `docs/UI_REPLICA.md`）
- **导入歌单**：粘贴网易云 / QQ / 酷狗 / 酷我 / 咪咕的歌单分享链接（含短链、洛雪
  `lxmusic://songlist` 深链），解析平台与歌单 id 后整单导入为本地歌单，
  同一个线上歌单重复导入是原地更新，见 `docs/LIST_IMPORT.md`
- **本地**：歌单 / 收藏 / 播放历史 / 播放队列，落盘沙箱并在启动时恢复
- **本地音乐**：导入设备里的音频文件 —— 「导入音乐」直接拉起文件管理的音频聚合视图
  （一屏列出全机音频，可全选，这是手机端三方应用唯一接近「扫描本机音乐」的能力；
  三方应用不能自己扫全盘，原因见 `docs/LOCAL_MUSIC.md`）；列表支持多选批量移除。
  导入后拷一份进沙箱，可离线播放、
  能加进歌单与收藏、能在播放队列里混排；歌词优先用同目录一并导入的同名 `.lrc`（精确、离线），
  否则按「歌名 + 歌手 + 时长」去平台匹配一次（宁缺勿错，配不准就不显示，可手动纠正）。
  **不参与同步**（洛雪同步协议只传在线歌，本地歌在同步时会被直接抛弃，同步设置页也这么注明）。
  见 `docs/LOCAL_MUSIC.md`
- **云端音乐（WebDAV）**：连自己的云服务器放歌 —— 填地址 / 账号 / 密码（HTTP Basic），
  **连上就把那个目录（含子目录）里的音乐扫出来直接能播，不用先导入什么**；
  播放是带认证头的**流播**（不先下完），边听边下与「预取下一首」照旧走播放缓存，
  听过的歌下次直接读本地。封面与歌词自动匹配：优先用服务器上同目录的 `cover.jpg` /
  同名 `.lrc`（精确、离线可读），没有就按「歌名 + 歌手 + 时长」去平台匹配一次
  （与本地音乐同一套「宁缺勿错」的打分，也能手动纠正）。支持加进歌单与收藏，
  **不参与同步**（与本地音乐一致）。扫描结果与封面歌词是一份本地缓存，服务器上改了
  点一下「刷新」即可。见 `docs/WEBDAV.md`
- **下载**：2 并发队列，文件名格式 / 音质标注可选，固定存进系统 `Download/<应用名>/`（在「文件管理」
  里能看到），已下载文件优先离线播放；下载目录在设置页展示（系统不提供「跳到某个目录」的能力，
  所以不设跳转按钮，详见 `docs/DEFECTS.md` D-004）
- **同步**：洛雪同步协议（握手 / 加密 / 压缩 / 列表动作），可与洛雪桌面端互通
- **设置**：播放设置 / 下载设置 / 缓存管理 / 音源管理 / 同步设置 / 外观设置
  （外观页管 HDS 玻璃材质档位、首页流光、播放页封面圆角，见 `docs/UI_REPLICA.md`）

## 如何使用
1. 自行构建签名安装
2. 通过链接加入测试群组：https://appgallery.huawei.com/link/invite-test-wap?taskId=b4a29d53aca2244132b9a2b9b5c3bc74&invitationCode=9eHG2pO3r9g

## 构建

需要 DevEco Studio（`compatibleSdkVersion` = 6.1.0(23)，`targetSdkVersion` = 26.0.0）。

本仓库**不含** `build-profile.json5`——它里面是本机签名配置（证书路径与加密密码），
不适合入库。克隆后：

1. 复制模板：`cp build-profile.template.json5 build-profile.json5`
2. 在 DevEco Studio 的 Project Structure → Signing Configs 里配置签名
   （个人调试可以直接用「Automatically generate signature」）
3. 构建：DevEco 里直接 Run，或命令行
   `devecocli build --modules entry@default --build-mode debug`

另外需要自备可用的洛雪音源脚本：仓库里只有离线自检用的 demo source
（`entry/src/main/resources/rawfile/demo_source.js`），不含任何真实音源。

## 目录

| 路径 | 说明 |
| --- | --- |
| `entry/src/main/ets/core/source` | 音源脚本引擎（Web 容器执行脚本 + 宿主 HTTP 代理） |
| `entry/src/main/ets/core/player` | 播放会话、AVPlayer 封装、播控中心 |
| `entry/src/main/ets/core/music` | 平台搜索 / 榜单 / 歌单 / 歌词 / 封面 / 缓存 |
| `entry/src/main/ets/core/local` | 本地音乐库（导入设备音频：拷贝、元数据与封面、歌单 / 收藏的非同步侧表） |
| `entry/src/main/ets/core/webdav` | 云端音乐（WebDAV：协议客户端、扫描即曲库、远端标签 / 同目录封面歌词、侧表） |
| `entry/src/main/ets/core/sync` | 洛雪同步协议与本地音乐库 |
| `entry/src/main/ets/core/download` | 下载队列与设置 |
| `entry/src/main/ets/core/settings` | 播放 / 下载设置 |
| `entry/src/main/ets/views`、`ui` | 页面与通用组件、主题 |
| `docs` | 移植过程中的设计与对照笔记 |
| `tools` | 调试用的探针脚本（`live_search_probe.js` / `live_list_probe.js` 直连平台接口，后者不需要音源） |

## 许可证

按 Apache License 2.0 发布，见 [LICENSE](LICENSE)；对上游的移植与改动说明见 [NOTICE](NOTICE)。
