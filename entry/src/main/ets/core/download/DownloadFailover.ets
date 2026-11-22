import { hilog } from '@kit.PerformanceAnalysisKit';
import { SEARCH_PLATFORMS } from '../music/MusicSearch';
import { PlaySettings } from '../settings/PlaySettings';
import { SourceEngine } from '../source/SourceEngine';
import { SourceInfo } from '../source/LxTypes';
import { SourceRouter } from '../source/SourceRouter';
import { FailoverHooks } from '../source/SourceFailover';

const DOMAIN: number = 0x0001;
const TAG: string = 'DownloadFailover';

/**
 * 一次下载最多试几个音源（含第一个）
 *
 * 播放链路同一首最多换 3 次（见 PlaySession.retryAfterPlayFailure 的 `failRetry >= 3`），
 * 下载对齐这个口径：3 个源都下不动就该如实报错，别让一个后台任务把音源轮着扫一遍。
 * 上限只限制「换源的轮数」，不限制单次解析内部按路由表逐个试 —— 那部分由
 * SourceFailover 自己的预算（BUDGET_MS）兜着。
 */
export const MAX_DOWNLOAD_SOURCES: number = 3;

/**
 * 只有这几种状态码才算「这个源在这个平台上给不出地址」
 *
 * 其余 4xx 一律**不进共享路由表**：
 *   - 401：Cookie / 令牌过期，换个源确实能下，但源本身没坏；
 *   - 403：音质 / 版权 / CDN 防盗链（Referer 不对也是 403），播放侧往往还是好的；
 *   - 429：限流，等一下就能用。
 * 以前把任意 4xx 都记进 SourceRouter，两次下载失败就能把一个「播放明明正常」的源
 * 降级 30 分钟 —— 用户会觉得播放莫名其妙开始换源。
 */
const ROUTER_DEAD_CODES: number[] = [404, 410, 451];

/**
 * 这个拉流结果算不算「地址本身废了」（用于写共享路由表）
 *
 * 4xx 基本都是链接过期、被防盗链拒掉、源那边下架：**换一个源**才是有效的下一步，
 * 在同一个源上重试只会再拿到同一批寿命一样长的链接。5xx / 超时 / 停滞属于服务端或
 * 网络抖动，换源也可能有用（播放侧就是这么判的：只看结果、不看错误类型），
 * 所以调用方对两类都换源，只是日志与提示的措辞不同。
 */
export function isDeadAddressFailure(code: number, message: string): boolean {
  if (ROUTER_DEAD_CODES.includes(code)) {
    return true;
  }
  // 异常里只有文本时（requestInStream 抛错）按词边界认一下，别把 4041 这种码算进去
  return /\b(404|410|451)\b/.test(message);
}

/**
 * 下载任务的换源进度
 *
 * 与播放链路共用同一套「选源」实现（`SourceFailover.resolveUrlWithSourceFailover`，
 * 候选顺序来自 `SourceRouter`）—— 这里**只管记账**，不另写一套顺序：
 *
 *   - `bad`：已经判定下不动的音源，解析时作为 `skipSources` 传下去。不排除的话，
 *     重新解析会立刻从同一个源再给一条同样失效的地址（同一批接口出来的链接寿命一样长）。
 *   - `switchCount`：真的换过几次源，界面上显示「已换源重试 N 次」。
 *   - `used`：这次地址是哪个源给的，拉流失败时据此记账。
 *
 * 状态跟着下载记录落盘（`DownloadItem.triedSources` / `failovers`），所以自动重试
 * 再跑一次时不会再从已经废掉的源开始。
 */
export class DownloadFailover {
  /** 平台 id（qq / wy / kg…），与 SourceRouter 的口径一致 */
  private platform: string;
  /** 已判定下不动的音源 id，按失败顺序 */
  private bad: string[];
  /** 已经换源的次数（第一次用的源不算） */
  private switchCount: number;
  /** 当前这条地址是哪个源给的（解析成功后由调用方告知） */
  private used: string;

  constructor(platform: string, tried: string[], switches: number) {
    this.platform = platform;
    this.bad = [];
    if (tried !== undefined && tried !== null) {
      for (const id of tried) {
        if (id.length > 0 && !this.bad.includes(id)) {
          this.bad.push(id);
        }
      }
    }
    this.switchCount = switches > 0 ? switches : 0;
    this.used = '';
  }

  /** 已判定下不动的音源（副本：落盘用，外部改不到内部状态） */
  badList(): string[] {
    return this.bad.slice();
  }

  /** 真的换过几次源 */
  switchTotal(): number {
    return this.switchCount;
  }

  /** 当前地址的来源 */
  usedSourceId(): string {
    return this.used;
  }

  /** 记下这次地址是哪个源给的 */
  setUsed(id: string): void {
    this.used = id;
  }

  /**
   * 记一个「这个源不行」
   *
   * 空 id 忽略：只加载了一个源、或者引擎还没报出 id 时，别把空串塞进排除表。
   */
  markBad(id: string): void {
    if (id.length === 0 || this.bad.includes(id)) {
      return;
    }
    this.bad.push(id);
    hilog.info(DOMAIN, TAG, 'source %{public}s marked bad on %{public}s (%{public}d source(s) tried)',
      id, this.platform, this.bad.length);
  }

  /** 开始一次换源（计数 +1，界面上的「已换源重试 N 次」跟着走） */
  beginSwitch(): void {
    this.switchCount += 1;
  }

  /**
   * 还有没有下一个源可以换
   *
   * 四个前提缺一不可：
   *   1. 设置里开着「自动切换音源」（关掉就退回老行为：同一个源重试）；
   *   2. 平台在内置搜索范围内（本地 / WebDAV / 听书这类没有多源可换）；
   *   3. 还没试满 MAX_DOWNLOAD_SOURCES 个源；
   *   4. 路由表里确实还排着一个没试过的源。
   */
  canSwitch(): boolean {
    if (!PlaySettings.getInstance().isAutoSourceSwitch()) {
      return false;
    }
    if (!SEARCH_PLATFORMS.includes(this.platform)) {
      return false;
    }
    if (this.bad.length >= MAX_DOWNLOAD_SOURCES) {
      return false;
    }
    return this.nextSourceId().length > 0;
  }

  /**
   * 下一个该换到的源（按路由表的顺序，跳过已经废掉的）
   *
   * 顺序**不在这里定**：`SourceRouter.candidates` 已经把「上次在这个平台成功过的源排最前、
   * 连败两次的排到队尾」算好了，播放链路用的是同一份结果。
   */
  nextSourceId(): string {
    const router: SourceRouter = SourceRouter.getInstance();
    const engine: SourceEngine = SourceEngine.getInstance();
    const sources: SourceInfo[] = engine.listSources();
    const allIds: string[] = [];
    for (const info of sources) {
      allIds.push(info.id);
    }
    const loadedId: string = engine.getLoadedSourceId();
    const loadedSupports: boolean = loadedId.length > 0 && engine.supportsAction(this.platform, 'musicUrl');
    // 音质不在这里卡：各源声明的档位不同，真正的协商交给 SourceFailover/Quality
    const ordered: string[] = router.candidates(this.platform, loadedId, loadedSupports, allIds, '');
    for (const id of ordered) {
      if (!this.bad.includes(id)) {
        return id;
      }
    }
    return '';
  }

  /** 下一个源的显示名（日志用；取不到就空串） */
  nextSourceName(): string {
    const id: string = this.nextSourceId();
    return id.length > 0 ? SourceRouter.getInstance().nameOf(id) : '';
  }

  /**
   * 交给 SourceFailover 的钩子
   *
   * 只挂两件事：排除已经废掉的源；把换源途中失败的每一个源都记下来（这样「已尝试 N 个音源」
   * 和下一轮的 skipSources 都是准的）。**不设 isPlayback**：下载是后台任务，换源要重新注入
   * 脚本时应该给正在起播的歌让位（与 SourceFailover 里的约定一致）。
   */
  hooks(): FailoverHooks {
    const self: DownloadFailover = this;
    return {
      skipSources: this.badList(),
      onAttemptFailed: (sourceId: string, index: number, message: string): void => {
        hilog.warn(DOMAIN, TAG, 'source #%{public}d %{public}s failed on %{public}s: %{public}s',
          index, sourceId, self.platform, message);
        self.markBad(sourceId);
      },
    };
  }

  /** 列表里显示的「已换源重试 N 次」；没换过就是空串 */
  note(): string {
    return this.switchCount > 0 ? `已换源重试 ${this.switchCount} 次` : '';
  }

  /**
   * 失败原因后面的补白：「已尝试 N 个音源」
   *
   * 一个源都没试过（比如音源根本没加载）时不加 —— 那种情况跟音源数量无关，
   * 加上反而误导用户以为换源白试了。
   */
  attemptSummary(): string {
    return this.bad.length > 0 ? `（已尝试 ${this.bad.length} 个音源）` : '';
  }
}
