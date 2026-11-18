/**
 * 平台健康度：记住「某个音源下的某个平台」刚刚失败过，冷却期内别再白撞
 *
 * 为什么需要它：星海那类音源对 QQ 音乐（tx）是**整个平台**直接回 403「仅对认证用户开放」，
 * 而不是个别歌取不到流。我们原来的链路是「每首歌都先老实请求原平台 → 失败 → 再换源」，
 * 于是一张 500 首全是 tx 的旧歌单就要撞 500 次墙：每一次都要等一次完整的网络往返失败，
 * 用户感知到的就是「切歌总要卡一下，resolve 里大半是这次失败」。
 *
 * 这里只做一件事：把「刚失败过」这件事记下来，且**按失败原因决定记多久**：
 *   1. 稳定拒绝（卡密 / 认证 / 403 / unauthorized / license / 人机验证 / captcha）
 *      → 30 分钟。这类是后端在明确说「不给你」，立刻重试没有任何意义；
 *   2. 临时性故障（timeout / resolve / refused / reset / 断网）
 *      → 5 分钟。网络抖一下很快会好，记太久会误伤正常播放；
 *   3. 其它认不出的错 → 2 分钟。态度上保守：宁可多试一次，也别把能用的平台晾着。
 *
 * 键是 `音源id::平台id`（`SourceEngine.getLoadedSourceId()` 那一份）：
 * 换个音源就等于换了一套后端，上一个音源的失败结论不该污染新音源，所以自带隔离。
 *
 * 纯内存、不落盘：这是一份「此刻的临时状况」，重启后重新观察即可；
 * 持久化反而会让「昨天某个平台抽风」在今天开机后继续挡住用户。
 */
const COOLDOWN_AUTH_MS: number = 30 * 60 * 1000;
const COOLDOWN_NET_MS: number = 5 * 60 * 1000;
const COOLDOWN_OTHER_MS: number = 2 * 60 * 1000;

/** 稳定拒绝类关键字（统一按小写比对，中文关键字不受大小写影响） */
const AUTH_KEYWORDS: string[] = ['卡密', '认证', '403', 'license', 'unauthorized', '人机验证', 'captcha'];
/** 临时性故障关键字：只冷却一小会儿 */
const NET_KEYWORDS: string[] = ['timeout', 'resolve', 'refused', 'reset', '断网'];

/** 一次失败归类出来的结果（冷却多久 + 给用户看的短语） */
interface CooldownVerdict {
  /** 冷却时长（毫秒） */
  ms: number;
  /** 冷却原因短语，会出现在 toast 里，所以要是「用户能看懂的一句话」 */
  reason: string;
}

/**
 * 按报错原文归类（规则见文件头注释）
 *
 * 只做关键字归类，不看平台：同一句「403」在哪个平台上都是同一个意思。
 * 消息为空也要能给出结论（走兜底 2 分钟），否则调用方还得自己判空。
 */
function verdictOf(message: string): CooldownVerdict {
  const lower: string = message.toLowerCase();
  for (const word of AUTH_KEYWORDS) {
    if (lower.includes(word)) {
      return { ms: COOLDOWN_AUTH_MS, reason: '需要卡密或授权' };
    }
  }
  for (const word of NET_KEYWORDS) {
    if (lower.includes(word)) {
      return { ms: COOLDOWN_NET_MS, reason: '网络异常' };
    }
  }
  return { ms: COOLDOWN_OTHER_MS, reason: '该平台暂时不可用' };
}

export class PlatformHealth {
  private static instance: PlatformHealth | null = null;

  static getInstance(): PlatformHealth {
    if (PlatformHealth.instance === null) {
      PlatformHealth.instance = new PlatformHealth();
    }
    return PlatformHealth.instance;
  }

  /** `音源id::平台id` -> 冷却到期时间戳（毫秒）；没有这个键 = 没失败过 */
  private expireAt: Map<string, number> = new Map<string, number>();
  /** `音源id::平台id` -> 冷却原因短语（与 expireAt 同生命周期） */
  private reasonText: Map<string, string> = new Map<string, string>();

  private keyOf(sourceId: string, platform: string): string {
    return `${sourceId}::${platform}`;
  }

  /**
   * 记一次失败（内部按消息归类决定冷却时长）
   *
   * 同一个键再次失败只是**刷新**到期时间，不会叠加：平台一直坏着的时候，
   * 我们希望它一直处于冷却，而不是越攒越久把人锁死。
   */
  markFailure(sourceId: string, platform: string, message: string): void {
    // 音源还没加载完（loadedSourceId 为空）时的失败没有归属，记下来只会变成一条谁都查不到的孤儿记录
    if (sourceId.length === 0 || platform.length === 0) {
      return;
    }
    const verdict: CooldownVerdict = verdictOf(message);
    const key: string = this.keyOf(sourceId, platform);
    this.expireAt.set(key, Date.now() + verdict.ms);
    this.reasonText.set(key, verdict.reason);
  }

  /** 是否在冷却中（取地址前问这一句，命中就直接换源） */
  isCooling(sourceId: string, platform: string): boolean {
    return this.coolingSecondsLeft(sourceId, platform) > 0;
  }

  /** 冷却原因短语（给用户看，如「需要卡密或授权」「网络异常」）；不在冷却返回空串 */
  coolingReason(sourceId: string, platform: string): string {
    if (!this.isCooling(sourceId, platform)) {
      return '';
    }
    const reason: string | undefined = this.reasonText.get(this.keyOf(sourceId, platform));
    return reason !== undefined ? reason : '该平台暂时不可用';
  }

  /**
   * 成功一次就立刻解除该平台冷却
   *
   * 幂等：平时（根本没在冷却）调用是空操作，所以调用方不必先问 isCooling。
   * 「成功」只认**真的问过平台并拿到了地址**——缓存命中不算（见 PlaySession 的说明）。
   */
  markSuccess(sourceId: string, platform: string): void {
    if (sourceId.length === 0 || platform.length === 0) {
      return;
    }
    const key: string = this.keyOf(sourceId, platform);
    this.expireAt.delete(key);
    this.reasonText.delete(key);
  }

  /**
   * 冷却剩余秒数（0 = 不在冷却），调试与日志用
   *
   * 顺手删掉已经过期的键：冷却表是纯内存的，不清的话听一整天会攒下一堆早就不生效的记录。
   * 这是唯一一个有副作用的查询，但副作用只影响内存占用，不影响调用方看到的结论。
   */
  coolingSecondsLeft(sourceId: string, platform: string): number {
    if (sourceId.length === 0 || platform.length === 0) {
      return 0;
    }
    const key: string = this.keyOf(sourceId, platform);
    const until: number | undefined = this.expireAt.get(key);
    if (until === undefined) {
      return 0;
    }
    const left: number = until - Date.now();
    if (left <= 0) {
      this.expireAt.delete(key);
      this.reasonText.delete(key);
      return 0;
    }
    // 向上取整：还剩 300 毫秒时报「1 秒」比报「0 秒」（看起来像没冷却）更贴近真实
    return Math.ceil(left / 1000);
  }
}
