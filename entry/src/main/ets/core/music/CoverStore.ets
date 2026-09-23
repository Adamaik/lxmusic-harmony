import { LxMusicInfo, fetchMusicPic } from './MusicSearch';
import { MediaCache } from './MediaCache';
import { SourceEngine } from '../source/SourceEngine';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CoverStore';

/**
 * 封面缓存 / 懒解析
 *
 * 搜索结果里 tx / wy / mg 自带封面，kw / kg 没有，要单独请求平台接口；
 * 有些源脚本自己实现了 `pic` action，则优先用源给的结果。取封面是网络请求，
 * 列表里几十行不可能同步拿，所以这里做「先返回已有/空、后台排队解析、
 * 好了一批就通知界面重画」：
 *
 *   coverFor(json, fallback)  同步取（没有就返回空并排进队列）
 *   request(json, onReady)    播放页用，解析好了回调一次
 *
 * 并发限制在 3，失败的不再重试（避免对同一批行反复发请求）。
 */

/** 封面版本号：每解析好一批 +1，界面订阅它来重画列表 */
export const K_COVER_VERSION: string = 'cover_version';

/** musicInfoJson 解析结果的缓存上限（满了挤掉最早的一批，而不是清空重来） */
const INFO_CACHE_MAX: number = 400;
const INFO_CACHE_DROP: number = 100;
/**
 * 待解析队列上限
 *
 * 列表里几百行同时问封面时，不设上限会把请求排成几百个，
 * 每个都要发网络请求（还可能走源脚本），堆久了进程扛不住。
 * 超出的直接不入队 —— 那一行先显示占位封面，列表重画时会再问一次。
 */
const QUEUE_MAX: number = 60;

interface CoverTask {
  key: string;
  musicInfoJson: string;
}

/**
 * 封面位图缓存上限（按封面地址先进先出）
 *
 * 不是「给所有列表行都存一张」：列表行按地址加载就够，这份缓存只服务那些**会被反复重建**
 * 的封面（底栏那颗迷你栏封面每切一次页签就重建一次）。十来张足够，位图占的是内存。
 */
const PIXEL_CACHE_MAX: number = 12;
/** 解码边长（px）：迷你栏封面 44–56vp，三倍屏也就 168px，给 240 足够且省内存 */
const PIXEL_SIDE: number = 240;
/** 单张封面的下载上限：封面本来就是小图，遇到异常大的文件不如下去按地址加载 */
const PIXEL_BYTES_MAX: number = 2 * 1024 * 1024;
/** 封面请求用的 UA：部分图床对空 UA 会直接拒绝（与下载链路同一份口径） */
const UA: string = 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99 Mobile Safari/537.36';

/**
 * 是不是「内置平台」来源（kw / kg / tx / mg / wy）
 *
 * 只有这些平台才有「搜索结果不带封面、要按接口现查」这回事，也才可能被源脚本的
 * `pic` action 兜住。`local`（设备里导入的）与 `webdav`（云服务器上的）两个来源的
 * 封面各有出处（内嵌标签 / 同目录图片 + 平台匹配），不该走到这里。
 */
function isPlatformSource(source: string): boolean {
  return source === 'kw' || source === 'kg' || source === 'tx' || source === 'mg' || source === 'wy';
}

/** 是不是网络封面（http/https）：只有网络图要自己去下字节，本地图直接按路径解 */
function isNetworkUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

/** 沙箱路径：createImageSource 只吃路径，带 file:// 前缀的要去掉 */
function localPathOf(url: string): string {
  return url.startsWith('file://') ? url.substring('file://'.length) : url;
}

/**
 * 下一张封面的原始字节（给位图解码用）；失败 / 太大都返回 null，不抛
 *
 * 与下载链路（`core/download/DownloadTags.ets` 的 `fetchBinary`）同一个写法：带 UA、
 * 带超时、结束就 destroy。封面是网络图（平台接口给的是地址，不是本地文件），
 * 所以不能走 `image.createImageSource(uri)` —— 那个只吃沙箱路径。
 */
function fetchCoverBytes(url: string): Promise<ArrayBuffer | null> {
  return new Promise<ArrayBuffer | null>((resolve: (value: ArrayBuffer | null) => void) => {
    const request: http.HttpRequest = http.createHttp();
    const done = (bytes: ArrayBuffer | null): void => {
      try {
        request.destroy();
      } catch (e) {
        // 已经结束的请求 destroy 报错无所谓
      }
      resolve(bytes);
    };
    request.request(url, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': UA },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 8000,
      readTimeout: 15000,
    }).then((response: http.HttpResponse) => {
      const body: string | Object | ArrayBuffer = response.result;
      if (response.responseCode !== http.ResponseCode.OK || !(body instanceof ArrayBuffer)) {
        done(null);
        return;
      }
      const bytes: ArrayBuffer = body as ArrayBuffer;
      done(bytes.byteLength > 0 && bytes.byteLength <= PIXEL_BYTES_MAX ? bytes : null);
    }).catch((e: Object) => {
      hilog.info(DOMAIN, TAG, 'cover bytes fetch failed: %{public}s', JSON.stringify(e));
      done(null);
    });
  });
}

export class CoverStore {
  private static instance: CoverStore | null = null;

  static getInstance(): CoverStore {
    if (CoverStore.instance === null) {
      CoverStore.instance = new CoverStore();
    }
    return CoverStore.instance;
  }

  private cache: Map<string, string> = new Map();
  private failed: Set<string> = new Set();
  /** 已解好的封面位图（按封面地址）；这份只给「会被反复重建」的封面用，见 pixelFor */
  private pixels: Map<string, image.PixelMap> = new Map();
  /** 正在解的地址（同一张不并发解两次） */
  private pixelBusy: Set<string> = new Set();
  /** 解不出来的地址（网络失败 / 格式不认 / 太大）：不再重试，免得每次重建都去下一遍 */
  private pixelFailed: Set<string> = new Set();
  /** musicInfoJson -> 解析结果，避免列表重画时反复 parse */
  private infoCache: Map<string, LxMusicInfo> = new Map();
  /** 已入队 / 正在解析的 key，避免重复排队 */
  private pending: Set<string> = new Set();
  private waiters: Map<string, ((url: string) => void)[]> = new Map();
  private queue: CoverTask[] = [];
  private active: number = 0;
  private maxActive: number = 3;
  private flushTimer: number = 0;
  private keyOf(source: string, songmid: string): string {
    return `${source}_${songmid}`;
  }

  /** musicInfoJson 会很小但会被反复解析（列表每次重画都要问一次封面），这里缓存一下 */
  private infoOf(musicInfoJson: string): LxMusicInfo | null {
    if (musicInfoJson.length === 0) {
      return null;
    }
    const hit: LxMusicInfo | undefined = this.infoCache.get(musicInfoJson);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const info: LxMusicInfo = JSON.parse(musicInfoJson) as LxMusicInfo;
      // 满了挤掉最早的一批：直接 clear 会让后面的条目反复重新解析（几百首的歌单上很明显）
      if (this.infoCache.size >= INFO_CACHE_MAX) {
        let drop: number = INFO_CACHE_DROP;
        for (const key of this.infoCache.keys()) {
          if (drop <= 0) {
            break;
          }
          this.infoCache.delete(key);
          drop--;
        }
      }
      this.infoCache.set(musicInfoJson, info);
      return info;
    } catch (e) {
      return null;
    }
  }

  /**
   * 列表行用：已经有封面就直接返回，没有就返回空串（占位封面）并把这首排进解析队列。
   * @param musicInfoJson 该条目的 musicInfo（没有 musicInfo 的条目为空串）
   * @param fallback      搜索结果里自带的封面（非空就直接用，不再请求）
   */
  coverFor(musicInfoJson: string, fallback: string): string {
    if (fallback.length > 0) {
      return fallback;
    }
    const info: LxMusicInfo | null = this.infoOf(musicInfoJson);
    if (info === null) {
      return '';
    }
    // 本地歌 / 云端歌的封面不归这里管：它们的封面是「内嵌标签」或「同目录图片 +
    // 平台匹配」取好的，已经放在 item.coverUrl 里（上面的 fallback 分支就返回了）。
    // 走到这里说明确实没有封面 —— 直接返回空串（占位图），别拿 source='local'
    // 或 'webdav' 去问平台接口和源脚本，那只会白跑一趟还被记成「解析失败」。
    if (!isPlatformSource(info.source)) {
      return '';
    }
    const key: string = this.keyOf(info.source, info.songmid);
    const hit: string | undefined = this.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    // 内存没命中就查磁盘缓存：封面地址是按平台接口现查的，不缓存的话每次启动
    // 都要为列表里每一行重新请求一遍
    const saved: string = MediaCache.getInstance().getPic(key);
    if (saved.length > 0) {
      this.cache.set(key, saved);
      return saved;
    }
    this.enqueue(info, musicInfoJson);
    return '';
  }

  /** 播放页用：解析好了回调一次（失败不回调） */
  request(musicInfoJson: string, onReady: (url: string) => void): void {
    const info: LxMusicInfo | null = this.infoOf(musicInfoJson);
    if (info === null) {
      return;
    }
    // 同 coverFor：本地歌 / 云端歌的封面由它们各自的库负责，这里不管
    if (!isPlatformSource(info.source)) {
      return;
    }
    const key: string = this.keyOf(info.source, info.songmid);
    const hit: string | undefined = this.cache.get(key);
    if (hit !== undefined) {
      onReady(hit);
      return;
    }
    const saved: string = MediaCache.getInstance().getPic(key);
    if (saved.length > 0) {
      this.cache.set(key, saved);
      onReady(saved);
      return;
    }
    if (this.failed.has(key)) {
      return;
    }
    const list: ((url: string) => void)[] | undefined = this.waiters.get(key);
    if (list === undefined) {
      this.waiters.set(key, [onReady]);
    } else {
      list.push(onReady);
    }
    this.enqueue(info, musicInfoJson);
  }

  /**
   * 内存里已解好的封面位图；没有就返回 undefined 并在后台解一张
   *
   * 为什么要自己存一份解好的位图：`Image(地址)` 是**异步**加载的，节点一被重建
   * （切换底部页签时 HDS 会把迷你栏整个重建一遍、列表回收重排也是一样）就会先露一段
   * 「还没有图」的空窗，那块垫底（`CoverArt` 里是 `#1C1C1E`）就被看见 —— 用户看到的就是
   * 「封面先黑一下，然后再亮起来」。`Image(位图)` 是**同步**绘制：位图在内存里，
   * 重建多少次都直接画出来，没有那段空窗。
   *
   * 这个接口是尽力而为的：第一次仍然按地址加载（调用方拿到 undefined 就照旧画地址），
   * 解好之后的重建才命中这份位图；网络失败 / 解不开 / 文件太大都只是回到原来的行为。
   * 官方文档对 `Image` 的 `syncLoad` 也写了「加载时闪烁就设 true，同步加载时不显示占位图」
   * —— 但那是拿主线程做加载（我们的封面是网络图，主线程上等一次网络请求更糟），
   * 所以这里选「先同步解好、之后同步画」。
   */
  pixelFor(url: string): image.PixelMap | undefined {
    if (url.length === 0 || this.pixelFailed.has(url)) {
      return undefined;
    }
    const hit: image.PixelMap | undefined = this.pixels.get(url);
    if (hit !== undefined) {
      return hit;
    }
    void this.decodePixel(url);
    return undefined;
  }

  /**
   * 提前解一张封面（切歌时调一次）
   *
   * 迷你栏在**每次切换页签**时都会被重建，所以当前这首的封面最好在用户切页签之前就解好：
   * 那样第一次重建就已经能命中位图，连一次「按地址加载」都不用等。
   */
  preloadPixel(url: string): void {
    if (url.length > 0) {
      void this.decodePixel(url);
    }
  }

  /** 解一张封面：下载原始字节（本地文件除外）→ 解成指定尺寸的位图 → 记进缓存。失败不再重试 */
  private async decodePixel(url: string): Promise<void> {
    if (url.length === 0 || this.pixelBusy.has(url) || this.pixels.has(url) || this.pixelFailed.has(url)) {
      return;
    }
    this.pixelBusy.add(url);
    let source: image.ImageSource | null = null;
    try {
      if (isNetworkUrl(url)) {
        const bytes: ArrayBuffer | null = await fetchCoverBytes(url);
        if (bytes === null) {
          this.pixelFailed.add(url);
          return;
        }
        source = image.createImageSource(bytes);
      } else {
        // 本地文件的封面（本地音乐那张图）：直接按沙箱路径解，不用下载。
        // createImageSource 只吃沙箱路径，所以把 file:// 前缀摘掉
        source = image.createImageSource(localPathOf(url));
      }
      const options: image.DecodingOptions = {
        desiredSize: { width: PIXEL_SIDE, height: PIXEL_SIDE },
      };
      const pixel: image.PixelMap = await source.createPixelMap(options);
      this.rememberPixel(url, pixel);
    } catch (e) {
      this.pixelFailed.add(url);
      hilog.info(DOMAIN, TAG, 'cover bitmap decode skipped: %{public}s', JSON.stringify(e));
    } finally {
      this.pixelBusy.delete(url);
      if (source !== null) {
        try {
          await source.release();
        } catch (e) {
          // 释放失败无所谓：ImageSource 只是解码用的临时对象，位图已经拿到了
        }
      }
    }
  }

  /** 记进位图缓存；超上限就挤掉最早的一张（并把它的内存放掉） */
  private rememberPixel(url: string, pixel: image.PixelMap): void {
    if (this.pixels.has(url)) {
      void pixel.release();
      return;
    }
    while (this.pixels.size >= PIXEL_CACHE_MAX) {
      for (const oldest of this.pixels.keys()) {
        const dropped: image.PixelMap | undefined = this.pixels.get(oldest);
        this.pixels.delete(oldest);
        if (dropped !== undefined) {
          void dropped.release();
        }
        break;
      }
    }
    this.pixels.set(url, pixel);
  }

  private enqueue(info: LxMusicInfo, musicInfoJson: string): void {
    const key: string = this.keyOf(info.source, info.songmid);
    if (key.length <= 1 || this.cache.has(key) || this.failed.has(key) || this.pending.has(key)) {
      return;
    }
    // 队列已经很长了就先不排（那一行显示占位封面，列表重画时会再问一次）
    if (this.queue.length >= QUEUE_MAX) {
      return;
    }
    this.pending.add(key);
    this.queue.push({ key: key, musicInfoJson: musicInfoJson });
    this.pump();
  }

  private pump(): void {
    while (this.active < this.maxActive && this.queue.length > 0) {
      const task: CoverTask | undefined = this.queue.shift();
      if (task !== undefined) {
        this.run(task);
      }
    }
  }

  private async run(task: CoverTask): Promise<void> {
    this.active++;
    let url: string = '';
    try {
      const info: LxMusicInfo | null = this.infoOf(task.musicInfoJson);
      if (info !== null) {
        url = await fetchMusicPic(info);
        if (url.length === 0) {
          url = await this.fetchFromSource(info, task.musicInfoJson);
        }
      }
    } catch (e) {
      url = '';
    }
    this.active--;
    this.pending.delete(task.key);
    if (url.length > 0) {
      this.cache.set(task.key, url);
      // 落到磁盘缓存，下次启动不用为这几百行重新请求封面地址
      MediaCache.getInstance().savePic(task.key, url);
      this.notify(task.key, url);
      this.bumpVersion();
    } else {
      this.failed.add(task.key);
      this.notify(task.key, '');
    }
    this.pump();
  }

  /** 平台接口拿不到时，问源脚本的 pic action（只有源声明了 pic 才问） */
  private async fetchFromSource(info: LxMusicInfo, musicInfoJson: string): Promise<string> {
    const engine = SourceEngine.getInstance();
    if (!engine.isInited() || !engine.supportsAction(info.source, 'pic')) {
      return '';
    }
    try {
      const url: string = await engine.getPic(musicInfoJson, info.source);
      return url;
    } catch (e) {
      return '';
    }
  }

  private notify(key: string, url: string): void {
    const list: ((url: string) => void)[] | undefined = this.waiters.get(key);
    if (list === undefined) {
      return;
    }
    this.waiters.delete(key);
    for (const callback of list) {
      callback(url);
    }
  }

  /** 一批解析完再通知一次界面，别每张图都刷一遍列表 */
  private bumpVersion(): void {
    if (this.flushTimer !== 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = 0;
      const version: number = AppStorage.get<number>(K_COVER_VERSION) ?? 0;
      AppStorage.setOrCreate(K_COVER_VERSION, version + 1);
    }, 120);
  }
}
