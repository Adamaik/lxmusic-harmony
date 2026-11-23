import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaySettings } from '../settings/PlaySettings';
import { PlatformHealth } from '../player/PlatformHealth';
import { SEARCH_PLATFORMS } from '../music/MusicSearch';
import { pickQuality } from '../music/Quality';
import { SourceEngine } from './SourceEngine';
import { SourceRouter } from './SourceRouter';
import { LxQuality, SourceInfo } from './LxTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceFailover';

/**
 * 单次解析的预算（毫秒）
 *
 * 多候选时第一个源给 7 秒、之后每个 5 秒：用户能忍的「点了没声音」大概十秒上下，
 * 到点就中止、换下一个（以前要等满 SourceEngine 的 60 秒上限）。
 * 只有**一个**候选时给 25 秒：这时候没有「换人」的余地，慢不等于坏 ——
 * 很多音源是代理型的，脚本里还要再串几个请求。
 */
const FIRST_TIMEOUT_MS: number = 7000;
const NEXT_TIMEOUT_MS: number = 5000;
const SINGLE_TIMEOUT_MS: number = 25000;
const BUDGET_MS: number = 15000;

/**
 * 「最后兜底」那一次请求的预算（毫秒）
 *
 * 为什么要单独给一个：关掉「自动切换音源」时走的是 `single()` 那条路，
 * 它用的是引擎自己的上限（几十秒），慢一点的代理型音源最终是能出地址的；
 * 开着自动切换时，每个源只给 5~7 秒，慢源会被当成坏源杀掉。
 * 于是出现群里反馈的那句 ——「点了自动切换，反而放不了了」（2026-11-19 14:06）、
 * 「能用的源他也要转一会，是不是自动切源认为它不能播放，直接换源了」（同日 14:10）。
 *
 * 兜底这一次的语义是：**保证「开着自动切换」的成功率不低于「关着」**。
 * 所以给它和 `SINGLE_TIMEOUT_MS` 同量级的时间，且只跑一次、只在所有候选都失败后跑。
 */
const LAST_CHANCE_TIMEOUT_MS: number = 25000;

/**
 * 这个错算不算「慢」，而不是「坏」
 *
 * 我们自己是按预算中断请求的（超时），音源脚本内部的网络请求也会抛 timeout / abort。
 * 这类错误只能说明「这次没赶上」，不能说明「这个源不能用」—— 所以：
 *   - **不记** PlatformHealth 的冷却（那条记下去是 5 分钟，会把一个只是慢的源
 *     在整张歌单上晾五分钟，正是「开着自动切换反而全放不了」的成因之一）；
 *   - 仍然记 SourceRouter 的降级（让它在**本次**平台内排到后面去）。
 */
function isSlowFailure(message: string): boolean {
  const lower: string = message.toLowerCase();
  const words: string[] = ['timeout', 'timed out', '超时', 'abort', 'aborted', 'cancel', '取消'];
  for (const word of words) {
    if (lower.includes(word)) {
      return true;
    }
  }
  return false;
}

/** 换源过程中的回调（播放链路要更新状态行与耗时日志，下载链路只要日志） */
export interface FailoverHooks {
  /** 用户切歌/取消：返回 true 就停止换源（已失败的源不记账） */
  isCancelled?: () => boolean;
  /** 即将换到某个源（播放链路用来更新「正在切换到音源「X」…」） */
  onSwitch?: (sourceId: string, name: string) => void;
  /** 某个源失败（播放链路用来记一笔耗时节点） */
  onAttemptFailed?: (sourceId: string, index: number, message: string) => void;
  /**
   * 这次解析是不是「用户正在等的播放」
   *
   * 决定换源时谁让谁：播放不能让（用户就等这一下），下载要让（后台任务，晚点再下没关系）。
   */
  isPlayback?: boolean;
  /**
   * 这次解析要**跳过**的音源 id
   *
   * 用在「地址解析成功但放不出来」的场景：那个源给的链已经 404 了，重新解析时必须把它
   * 排除掉，否则它会立刻再给一条同样失效的地址（同一批接口出来的链接寿命一样长）。
   */
  skipSources?: string[];
}

export interface FailoverOutcome {
  url: string;
  /** 实际解析出地址的音源 id */
  sourceId: string;
  /** 实际用的音质档（换源后会按该源声明的档位重新协商，可能与调用方给的不同） */
  quality: string;
}

function cancelled(hooks: FailoverHooks): boolean {
  return hooks.isCancelled !== undefined && hooks.isCancelled();
}

/**
 * 解析播放地址：配了多个音源时按路由表逐个试
 *
 * **播放与下载共用这一个实现** —— 取流能力是同源的：能放的源当然也能下。
 * 播放只是多挂了状态行与耗时日志的回调（见 FailoverHooks）。
 *
 * 顺序与规则：
 *   1. 候选顺序来自 SourceRouter（上次在这个平台成功过的源排最前，连败两次的排到队尾）；
 *   2. 正在冷却的源直接跳过（见 PlatformHealth），省掉一次注定失败的往返；
 *   3. 每个源单独一个短预算，到点就中止它名下的网络请求、换下一个；
 *   4. 成功即记账（路由表回首位 + 解除冷却），失败则累计降级；
 *   5. 全部失败才抛最后一个错误，并尽力把原先加载的源恢复回来。
 *
 * 关掉「自动切换音源」或平台不在内置搜索范围内（本地 / WebDAV / 听书）时，
 * 退化成「只问当前加载的那个源」——与加这项功能之前完全一致。
 */
export async function resolveUrlWithSourceFailover(
  musicInfoJson: string,
  platform: string,
  quality: string,
  hooks: FailoverHooks = {},
  wantQuality: string = '',
): Promise<FailoverOutcome> {
  const engine: SourceEngine = SourceEngine.getInstance();
  const router: SourceRouter = SourceRouter.getInstance();
  const health: PlatformHealth = PlatformHealth.getInstance();

  const single = async (): Promise<FailoverOutcome> => {
    const loadedId: string = engine.getLoadedSourceId();
    const picked: string = pickQuality(musicInfoJson, platform, quality);
    const url: string = await engine.getMusicUrl(musicInfoJson, picked as LxQuality, platform);
    return { url: url, sourceId: loadedId, quality: picked };
  };
  if (!PlaySettings.getInstance().isAutoSourceSwitch() || !SEARCH_PLATFORMS.includes(platform)) {
    return await single();
  }

  const sources: SourceInfo[] = engine.listSources();
  const allIds: string[] = [];
  for (const info of sources) {
    allIds.push(info.id);
  }
  const loadedId: string = engine.getLoadedSourceId();
  const loadedSupports: boolean = loadedId.length > 0 && engine.supportsAction(platform, 'musicUrl');
  let candidates: string[] = router.candidates(platform, loadedId, loadedSupports, allIds, wantQuality);
  const skip: string[] = hooks.skipSources !== undefined ? hooks.skipSources : [];
  if (skip.length > 0) {
    const kept: string[] = [];
    for (const id of candidates) {
      if (!skip.includes(id)) {
        kept.push(id);
      }
    }
    // 全被排除掉就只好照原样试一遍：宁可再撞一次，也不能因为这条规则把歌判死
    if (kept.length > 0) {
      candidates = kept;
      hilog.info(DOMAIN, TAG, 'skip sources [%{public}s] on %{public}s', skip.join(','), platform);
    }
  }
  if (candidates.length === 0) {
    // 一个源都没有（或都被判定为不支持这个平台）：照老路子走，让引擎给出准确报错
    return await single();
  }
  // 有没有源声明了用户要的那一档：有的话第一轮只试它们，
  // 别把时间花在「明摆着给不了母带」的源上（比如当前加载的这个）
  let declaringTotal: number = 0;
  for (const id of candidates) {
    if (wantQuality.length > 0 && router.declaresQuality(id, platform, wantQuality)) {
      declaringTotal += 1;
    }
  }
  let triedDeclaring: number = 0;

  const previousId: string = loadedId;
  const deadline: number = Date.now() + BUDGET_MS;
  const firstBudget: number = candidates.length > 1 ? FIRST_TIMEOUT_MS : SINGLE_TIMEOUT_MS;
  let lastError: Error = new Error('没有可用的音源');
  for (let i = 0; i < candidates.length; i++) {
    if (cancelled(hooks)) {
      throw lastError;
    }
    if (Date.now() >= deadline) {
      hilog.info(DOMAIN, TAG, 'failover budget exhausted, platform=%{public}s', platform);
      break;
    }
    const id: string = candidates[i];
    if (health.isCooling(id, platform)) {
      hilog.info(DOMAIN, TAG, 'skip cooling source %{public}s on %{public}s', id, platform);
      continue;
    }
    const declares: boolean = wantQuality.length > 0 && router.declaresQuality(id, platform, wantQuality);
    if (wantQuality.length > 0 && !declares && triedDeclaring < declaringTotal) {
      // 还有「声明了这一档」的源没试完：先别在这个给不了的源上花时间
      hilog.info(DOMAIN, TAG, 'skip %{public}s: does not declare %{public}s', id, wantQuality);
      continue;
    }
    if (declares) {
      triedDeclaring += 1;
    }
    const budget: number = i === 0 ? firstBudget : NEXT_TIMEOUT_MS;
    try {
      if (id !== engine.getLoadedSourceId() || !engine.isInited()) {
        // 换源要重新注入脚本，会打断此刻还在等回调的解析：
        //   - 播放：不能让，用户就在等这一下（打断的可能是别人的下载/预取，重来即可）；
        //   - 下载：让位，等那次解析结束再换，别把正在起播的歌打断。
        if (hooks.isPlayback !== true && engine.hasPendingResolve()) {
          hilog.info(DOMAIN, TAG, 'skip switching to %{public}s: another resolve pending', id);
          continue;
        }
        if (hooks.onSwitch !== undefined) {
          hooks.onSwitch(id, router.nameOf(id));
        }
        await engine.loadSource(id);
        if (cancelled(hooks)) {
          throw lastError;
        }
      }
      if (!engine.supportsAction(platform, 'musicUrl')) {
        throw new Error(`音源「${router.nameOf(id)}」不支持 ${platform} 平台`);
      }
      // 换完源之后重新协商一次音质：每个源声明的档位不一样，
      // 同一个 musicInfo 在这个源上能拿母带、在那个源上只能拿 320K
      const attemptQuality: string = declares ? wantQuality
        : pickQuality(musicInfoJson, platform, quality);
      const url: string = await engine.getMusicUrl(musicInfoJson, attemptQuality as LxQuality, platform, budget);
      if (attemptQuality !== quality || !declares) {
        hilog.info(DOMAIN, TAG, 'resolved with quality %{public}s on %{public}s', attemptQuality, id);
      }
      health.markSuccess(id, platform);
      router.markSuccess(id, platform);
      return { url: url, sourceId: id, quality: attemptQuality };
    } catch (e) {
      lastError = e as Error;
      if (cancelled(hooks)) {
        // 用户已经切歌：这次失败不该记到源头上
        throw lastError;
      }
      hilog.warn(DOMAIN, TAG, 'source %{public}s failed on %{public}s: %{public}s',
        id, platform, lastError.message);
      if (hooks.onAttemptFailed !== undefined) {
        hooks.onAttemptFailed(id, i, lastError.message);
      }
      // 「慢」和「坏」要分开记账，见 isSlowFailure 的说明：
      // 超时只让它在本次平台内排到后面，不该吃 5 分钟的平台冷却。
      if (!isSlowFailure(lastError.message)) {
        health.markFailure(id, platform, lastError.message);
      } else {
        hilog.info(DOMAIN, TAG, 'source %{public}s timed out on %{public}s (slow, not broken)',
          id, platform);
      }
      router.markFailure(id, platform, lastError.message);
    }
  }
  // 所有候选都失败了 —— 但这不等于这首歌放不出来，见 lastChance 的注释。
  const last: FailoverOutcome | null =
    await lastChance(previousId, musicInfoJson, platform, quality);
  if (last !== null) {
    router.markSuccess(last.sourceId, platform);
    health.markSuccess(last.sourceId, platform);
    return last;
  }
  await restoreLoadedSource(previousId);
  throw lastError;
}

/**
 * 最后兜底：用**原来加载的那个源 + 长预算**再试一次
 *
 * 这一条是为了让「开着自动切换」不比「关着」更差。关着的时候走 `single()`，
 * 拿当前源、给足时间、直接请求 —— 很多"慢但能用"的源在那条路上是成功的；
 * 开着的时候每个源只有 5~7 秒，慢源被逐个判死，最后反而放不出来。
 *
 * 三个刻意的选择：
 *   1. **忽略冷却**（不查 health.isCooling）：这是最后一次机会，宁可再撞一次墙；
 *   2. **不换源**：只用 previousId（进来时已经加载着的那个），因为换源要重新注入脚本，
 *      而这会儿用户已经等了一段时间，再折腾一次注入只会更慢；
 *   3. **失败就返回 null**，不抛错 —— 调用方照旧抛原来那个错，报错口径不变。
 */
async function lastChance(previousId: string, musicInfoJson: string, platform: string,
  quality: string): Promise<FailoverOutcome | null> {
  const engine: SourceEngine = SourceEngine.getInstance();
  if (previousId.length === 0) {
    return null;
  }
  try {
    if (engine.getLoadedSourceId() !== previousId || !engine.isInited()) {
      await engine.loadSource(previousId);
    }
    if (!engine.supportsAction(platform, 'musicUrl')) {
      return null;
    }
    const picked: string = pickQuality(musicInfoJson, platform, quality);
    const url: string = await engine.getMusicUrl(musicInfoJson, picked as LxQuality, platform,
      LAST_CHANCE_TIMEOUT_MS);
    if (url.length === 0) {
      return null;
    }
    hilog.info(DOMAIN, TAG, 'last chance resolved on %{public}s (%{public}s)',
      previousId, platform);
    return { url: url, sourceId: engine.getLoadedSourceId(), quality: picked };
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'last chance failed on %{public}s: %{public}s',
      previousId, (e as Error).message);
    return null;
  }
}

/**
 * 换源链路全部失败后，把原来那个源加载回来（best effort）
 *
 * loadSource 一进来就把引擎标成「未初始化」，中途失败（脚本报错 / 沙箱没挂）会让
 * 引擎停在半个状态：这时候连别的平台的歌都解析不了。恢复失败只记日志 ——
 * 用户还能去音源设置里手动加载，不该因为这次恢复再抛一个错。
 */
async function restoreLoadedSource(previousId: string): Promise<void> {
  const engine: SourceEngine = SourceEngine.getInstance();
  if (engine.isInited() || previousId.length === 0) {
    return;
  }
  if (engine.getLoadedSourceId() === previousId) {
    return;
  }
  try {
    await engine.loadSource(previousId);
    hilog.info(DOMAIN, TAG, 'restored previous source after failed failover: %{public}s', previousId);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'failed to restore previous source %{public}s: %{public}s',
      previousId, (e as Error).message);
  }
}
