# lxmusic-harmony

洛雪音乐（[lx-music-mobile](https://github.com/lyswhut/lx-music-mobile)）的鸿蒙移植版，
界面与播放链路用 ArkTS / ArkUI 重写，跑在 HarmonyOS 上（bundle: `com.example.listen`）。

> 本项目不包含、也不提供任何音频内容。播放地址由你自己导入的音源脚本解析，
> 版权内容请通过正规渠道获取。

## 功能

- **音源**：内置脚本引擎，在 Web 容器里执行洛雪音源脚本，支持导入 / 启用 / 离线自检
- **播放**：AVPlayer + AVSession（播控中心、锁屏与桌面歌词、投播至、系统分享），
  音质协商，拓展音质（母带 / 全景声）解析失败时自动回退到普通音质
- **在线**：内置平台接口的排行榜 / 歌单 / 搜索 / 推荐，封面与歌词懒解析
- **本地**：歌单 / 收藏 / 播放历史 / 播放队列，落盘沙箱并在启动时恢复
- **下载**：2 并发队列，文件名格式 / 音质标注 / 保存位置可选，已下载文件优先离线播放
- **同步**：洛雪同步协议（握手 / 加密 / 压缩 / 列表动作），可与洛雪桌面端互通
- **设置**：播放设置 / 下载设置 / 缓存管理 / 音源管理 / 同步设置

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
| `entry/src/main/ets/core/sync` | 洛雪同步协议与本地音乐库 |
| `entry/src/main/ets/core/download` | 下载队列与设置 |
| `entry/src/main/ets/core/settings` | 播放 / 下载设置 |
| `entry/src/main/ets/views`、`ui` | 页面与通用组件、主题 |
| `docs` | 移植过程中的设计与对照笔记 |
| `tools` | 调试用的探针脚本（需自行填音源后用 Node 跑） |

## 许可证

按 Apache License 2.0 发布，见 [LICENSE](LICENSE)；对上游的移植与改动说明见 [NOTICE](NOTICE)。
