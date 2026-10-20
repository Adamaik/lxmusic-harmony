import { UIContext } from '@kit.ArkUI';
import { cacheDownload } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'ImageCache';

/**
 * 图片（封面 / 头像）的缓存配置
 *
 * 为什么要有这一个文件：**鸿蒙默认并不缓存图片**。
 *   - `request.cacheDownload` 的网络字节缓存，内存那层默认是 **0**（等于没开），
 *     文件那层默认 100MB；`Image` 组件加载网络图走的就是这套缓存
 *     （`ImageError.downloadInfo` 报的就是它的下载信息，见 component/image.d.ts）。
 *   - `UIContext.setImageCacheCount` / `setImageRawDataCacheSize` 是 ArkUI 自己那两层
 *     （解码后的位图 + 解码前的原始数据），SDK 原文写着
 *     "if not set, the application will not cache any decoded image" —— 不设就一份都不留。
 *
 * 两层都没配的话，表现就是：列表滚过去再滚回来，封面重新读文件、重新解码；
 * 每次进页面都在转圈。这里把三层一起开起来，**全应用生效**（歌单封面、搜索结果的
 * 封面、歌手头像、播放页大图都是同一个 `Image`），不是只给歌手头像开小灶。
 *
 * 与项目里那两层缓存的分工（别搞混）：
 *   - `CoverStore` + `MediaCache` 缓存的是**地址**（"这首 kw 的歌，封面在哪"），
 *     解决「每次都要现查接口」；
 *   - `AudioCache` 缓存的是**音频文件本体**（边听边下）；
 *   - 本文件配的是**图片字节 + 解码结果**，解决「每次都要重新下载 / 解码」。
 *
 * 容量怎么定的：
 *   - 内存（字节层）64MB：一个月的封面来回滚也放得下，且不会跟播放缓存抢太多；
 *   - 文件层 256MB：系统默认 100MB，而封面是音乐应用最主要的一类静态资源，
 *     100MB 只够几百张就 LRU 淘汰了 —— 上调是拿磁盘换流量。满了由系统按 LRU 淘汰，
 *     不需要（也没有）自己设 TTL：图片地址是稳定的，服务端还有 Cache-Control；
 *     真要"过期时间"得走 `cacheDownload.download()` 的 CacheStrategy（那是预取用的，
 *     这里没预取，Image 第一次显示时顺手就缓存了）。
 *   - ArkUI 两层：80 张解码位图、64MB 原始数据。解码后的位图最占地方（一张 1080²
 *     的图约 4.6MB），80 张足够覆盖"列表来回滚 + 播放页大图"这种同时可见的量。
 */
/** 系统网络字节缓存的内存层（默认 0 = 没开） */
const BYTE_MEMORY_BYTES: number = 64 * 1024 * 1024;
/** 系统网络字节缓存的文件层（系统默认 100MB） */
const BYTE_FILE_BYTES: number = 256 * 1024 * 1024;
/** ArkUI：最多留多少张**解码后**的图 */
const DECODED_COUNT: number = 80;
/** ArkUI：解码前的原始数据留多少字节 */
const RAW_BYTES: number = 64 * 1024 * 1024;

let byteApplied: boolean = false;
let uiApplied: boolean = false;

/**
 * 开系统的网络图片缓存（内存层 + 文件层）
 *
 * 不依赖 UIContext，`EntryAbility.onCreate` 里就能调。幂等：重复调用只生效一次。
 * 失败只记日志 —— 缓存没开顶多慢一点，不该把启动搞崩。
 */
export function applyImageByteCache(): void {
  if (byteApplied) {
    return;
  }
  byteApplied = true;
  try {
    cacheDownload.setMemoryCacheSize(BYTE_MEMORY_BYTES);
    cacheDownload.setFileCacheSize(BYTE_FILE_BYTES);
    hilog.info(DOMAIN, TAG, 'image byte cache on: memory=%{public}d file=%{public}d',
      BYTE_MEMORY_BYTES, BYTE_FILE_BYTES);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'enable image byte cache failed: %{public}s', JSON.stringify(e));
  }
}

/**
 * 开 ArkUI 的图片内存缓存（解码后 + 原始数据）
 *
 * 要一个 UIContext：`EntryAbility.onWindowStageCreate` 里从主窗口拿
 * （`windowStage.getMainWindowSync().getUIContext()`）。幂等。
 */
export function applyImageUiCache(ui: UIContext): void {
  if (uiApplied) {
    return;
  }
  uiApplied = true;
  try {
    ui.setImageCacheCount(DECODED_COUNT);
    ui.setImageRawDataCacheSize(RAW_BYTES);
    hilog.info(DOMAIN, TAG, 'image ui cache on: decoded=%{public}d raw=%{public}d',
      DECODED_COUNT, RAW_BYTES);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'enable image ui cache failed: %{public}s', JSON.stringify(e));
  }
}
