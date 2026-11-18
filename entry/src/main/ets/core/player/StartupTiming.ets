import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 起播耗时拆段（「点击到出声」到底慢在哪一段）
 *
 * 用户反馈「在线听要很久才播放」，但下载本身很快 —— 说明网络不背这个锅，
 * 时间花在**点下去到真正出声之间**的两段上：
 *
 *   resolve：从开始取播 URL 到拿到一条可播放的地址（缓存命中时这一段是 0）
 *   buffer ：从调用 LxPlayer.playUrl(url) 到 AVPlayer 真的进了 playing 态
 *
 * 这两段分别属于 PlaySession（解析）与 LxPlayer（起播），中间还夹着若干次
 * 「换歌就把上一次丢掉」的早退，所以计时状态必须**跨这两个类共享**，
 * 也就落到这个单例上：两边都只跟它说话，自己不记时间戳。
 *
 * 两条纪律（都是为了让这段埋点绝对不改变播放行为）：
 *   1. 只记时间、只打日志。任何一步出问题都不能抛错，也不能拖住调用方；
 *   2. 一次起播只出一条日志。每次 begin() 领一个号，旧的号（用户又点了别的歌、
 *      或上一次起播的回调迟到）一律丢弃，不会把两首歌的数混在一行里。
 *
 * 日志形如：
 *   起播耗时 resolve=1234ms buffer=567ms 源=tx 音质=320k 命中缓存=false 曲目=晴天
 * 失败 / 超时也照打（buffer 记 -1 或已等待的毫秒数，末尾多一个「结果=」），
 * 否则排障时只能看到成功的那几次，看不到残值。
 */

const DOMAIN: number = 0x0001;
/** 单独的 TAG：与 PlaySession / LxPlayer 的日志并排出现，一眼能看出这行是「起播耗时」 */
const TAG: string = 'StartupTiming';

/**
 * 起播看门狗（毫秒）
 *
 * prepared / playing 一直不来（源给的地址是个死链、或者播放器卡在 prepare），
 * stateChange 就不会有任何回调，这条起播就没有日志了。挂一个一次性定时器兜住这种
 * 「什么都不发生」的情况，**每个播放器实例只挂一个、且在终态里清掉**，
 * 不是全局轮询（不影响播放，也不占用后台）。
 */
const WATCHDOG_MS: number = 20000;

/** 一次起播的现场快照（begin 时定下来，之后各段只往里填时间） */
interface StartupAttempt {
  /** 这一次起播的号：回调迟到时代号已经变了，就别再打日志 */
  seq: number;
  /** 开始取播放地址的时刻（毫秒时间戳） */
  resolveStartAt: number;
  /** 开始往播放器里送地址的时刻；0 = 还没走到 LxPlayer */
  bufferStartAt: number;
  /** 取地址耗时；-1 = 没取到 */
  resolveMs: number;
  /** 这次是不是命中了播放地址缓存 */
  cacheHit: boolean;
  source: string;
  quality: string;
  trackName: string;
  /** 中途发生过的事（换源、降档），写进日志末尾，排障时是最关键的那半句 */
  notes: string[];
}

export class StartupTiming {
  private static instance: StartupTiming | null = null;

  static getInstance(): StartupTiming {
    if (StartupTiming.instance === null) {
      StartupTiming.instance = new StartupTiming();
    }
    return StartupTiming.instance;
  }

  /** 当前这次起播的号；0 = 没有正在进行的起播 */
  private seq: number = 0;
  private attempt: StartupAttempt | null = null;
  /** 看门狗句柄（每个播放器实例一个，见 WATCHDOG_MS） */
  private watchdog: number = -1;

  /**
   * 开始取播放地址（在「解析条目 + 协商音质 + 取链接」这一整段之前调）
   *
   * 换源 / 降档都发生在这一段里面，所以它们只往这次起播上加备注，不会另起一次计时 ——
   * 用户感知的「点了之后等了多久」本来就是一个整体。
   */
  begin(source: string, quality: string, trackName: string): void {
    // 上一次起播的看门狗还挂着的话先收掉：它到点会拿**新的**这次起播去报「超时」，
    // 结果就是一首刚点下去的歌被一条早该结束的计时打了差评
    this.disarmWatchdog();
    // 上一次起播还没出声就被这次顶掉（用户切了歌）：先把它的残值打出来，
    // 否则日志里只会剩下成功的那几次，慢的那些反而看不见
    this.flushAborted('被新的起播顶替');
    this.seq += 1;
    this.attempt = {
      seq: this.seq,
      resolveStartAt: Date.now(),
      bufferStartAt: 0,
      resolveMs: -1,
      cacheHit: false,
      source: source,
      quality: quality,
      trackName: trackName,
      notes: [],
    };
  }

  /** 在备注里补一句（换源、降档这类「中途改过主意」都记在这里） */
  note(text: string): void {
    const attempt: StartupAttempt | null = this.attempt;
    if (attempt === null || text.length === 0) {
      return;
    }
    attempt.notes.push(text);
  }

  /**
   * 地址要送进播放器了：结算 resolve 段并开始 buffer 段
   *
   * `cacheHit` 传进来的是「这条地址是否来自缓存」；换源后那条地址一定不是缓存里的，
   * 调用方自己判断（见 PlaySession.playAt）。命中缓存时 resolve 记 0 —— 这一段本来
   * 就没有耗时，记成真实耗时反而看不出「缓存救了多久」。
   */
  beginBuffer(source: string, quality: string, cacheHit: boolean): void {
    const attempt: StartupAttempt | null = this.attempt;
    if (attempt === null) {
      return;
    }
    attempt.source = source;
    attempt.quality = quality;
    attempt.cacheHit = cacheHit;
    if (attempt.resolveMs < 0) {
      attempt.resolveMs = cacheHit ? 0 : Date.now() - attempt.resolveStartAt;
    }
    attempt.bufferStartAt = Date.now();
  }

  /**
   * 起播完成（AVPlayer 进了 playing）——出唯一的那一条日志
   *
   * 平台 / 音质用这次起播记下来的那份（beginBuffer 时由 PlaySession 给的），
   * 播放器自己不知道这首歌是从哪个平台来的。
   */
  markPlaying(): void {
    const attempt: StartupAttempt | null = this.attempt;
    if (attempt === null || attempt.bufferStartAt === 0) {
      return;
    }
    const bufferMs: number = Date.now() - attempt.bufferStartAt;
    this.emit(attempt, bufferMs, '成功');
  }

  /** 起播失败（播放器报错 / 一直不出声）：把已经等到的毫秒数打出来，然后结束这次计时 */
  markFailed(reason: string): void {
    const attempt: StartupAttempt | null = this.attempt;
    if (attempt === null) {
      return;
    }
    const bufferMs: number = attempt.bufferStartAt === 0
      ? -1
      : Date.now() - attempt.bufferStartAt;
    this.emit(attempt, bufferMs, reason.length > 0 ? reason : '失败');
  }

  /**
   * 这次起播还没出声就被顶掉了（用户切了别的歌）
   *
   * 私有：只有 begin() 会调，而且必须在发新号**之前**调（emit 要拿旧号做校验）。
   * 为什么不在 LxPlayer.release() 里结算：release 除了「真的切歌」还会在每次
   * preparePlayer 开头被调一次（换新实例前先释放旧的），照那里结算的话
   * 每一首歌刚起播就会被判成「中途放弃」。
   */
  private flushAborted(reason: string): void {
    const attempt: StartupAttempt | null = this.attempt;
    if (attempt === null) {
      return;
    }
    const bufferMs: number = attempt.bufferStartAt === 0
      ? -1
      : Date.now() - attempt.bufferStartAt;
    // 解析还没结算就放弃的，按「已经花掉的时间」记，别把它丢了
    if (attempt.resolveMs < 0) {
      attempt.resolveMs = Date.now() - attempt.resolveStartAt;
    }
    this.emit(attempt, bufferMs, reason);
  }

  /** 起播看门狗：到点还在等，就把已经等到的毫秒数打出来（只打一次） */
  armWatchdog(): void {
    this.disarmWatchdog();
    this.watchdog = setTimeout(() => {
      this.watchdog = -1;
      this.markFailed('超时');
    }, WATCHDOG_MS);
  }

  /** 收掉看门狗（出日志时、以及开下一次起播时调，免得它对着下一首误报「超时」） */
  disarmWatchdog(): void {
    if (this.watchdog !== -1) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
  }

  /** 打出那一行日志，并把这次起播结束掉（之后迟到的回调都不再有 attempt 可写） */
  private emit(attempt: StartupAttempt, bufferMs: number, result: string): void {
    // 号对不上 = 已经有新的一次起播，这条是迟到的残报，丢掉
    if (attempt.seq !== this.seq) {
      return;
    }
    this.attempt = null;
    this.disarmWatchdog();
    const bufferText: string = bufferMs < 0 ? '未开始' : `${bufferMs}ms`;
    const notes: string = attempt.notes.length > 0 ? ` 备注=${attempt.notes.join('|')}` : '';
    hilog.info(DOMAIN, TAG,
      '起播耗时 resolve=%{public}dms buffer=%{public}s 源=%{public}s 音质=%{public}s 命中缓存=%{public}s 曲目=%{public}s 结果=%{public}s%{public}s',
      attempt.resolveMs, bufferText, attempt.source, attempt.quality,
      attempt.cacheHit ? 'true' : 'false', attempt.trackName, result, notes);
  }
}
