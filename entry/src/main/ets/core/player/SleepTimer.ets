import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackService } from './PlaybackService';
import { LxPlayer } from './LxPlayer';
import { K_PLAYER_STATUS, PlaySession } from './PlaySession';

const DOMAIN: number = 0x0001;
const TAG: string = 'SleepTimer';

/**
 * 定时关闭（设置 - 播放设置）
 *
 * 两种策略，用户的原话是「一种是播放多长时间后关闭，一种是几点几分关闭」：
 *
 *   duration —— 再放 N 分钟后关闭。**只累计真正在出声的时间**：暂停期间不走表。
 *               按字面就是「播放多久」，睡前暂停去接杯水不该把倒计时烧掉，
 *               回来接着听还能听满自己设的时长。
 *   clock    —— 到某个钟点关闭（今天没到就是今天，已经过了就是明天）。这一种走墙上时间，
 *               暂停也照样走到点关闭 —— 用户说的是「几点几分关闭 app」，不是「放多久」。
 *
 * 到点之后做三件事：
 *   1. 暂停播放（LxPlayer.pause），让 PlaySession 的监听把现场落盘；
 *   2. 停后台任务与播控中心状态（PlaybackService.stopPlayback）——
 *      不停长时任务的话进程会被系统按「后台放音」保活，kill 了也会被拉回来；
 *   3. 关掉应用（terminateSelf + killAllProcesses）。
 *
 * **不落盘**：定时器是「这一次睡前」的东西，跨重启留着只会在第二天早上莫名其妙关掉应用。
 */

/** 关闭方式：off 未设定 / duration 播放 N 分钟 / clock 指定时刻 */
export const SLEEP_MODE_OFF: string = 'off';
export const SLEEP_MODE_DURATION: string = 'duration';
export const SLEEP_MODE_CLOCK: string = 'clock';

/** 时长档（分钟），顺序与界面一致 */
export const SLEEP_PRESET_MINUTES: number[] = [15, 30, 45, 60, 90];
export const SLEEP_PRESET_LABELS: string[] = ['15 分钟', '30 分钟', '45 分钟', '60 分钟', '90 分钟'];
/** 关闭方式三档，顺序与界面一致（与上面的 SLEEP_MODE_* 一一对应） */
export const SLEEP_MODE_LABELS: string[] = ['关闭', '播放时长', '指定时刻'];
/** 默认选中 30 分钟 */
export const SLEEP_DEFAULT_MINUTES: number = 30;

/** 界面订阅这几个 key（@StorageLink）就能跟着倒计时刷新 */
export const K_SLEEP_MODE: string = 'cfg_sleep_mode';
/** 剩余秒数（向上取整；未设定时为 0） */
export const K_SLEEP_REMAIN: string = 'cfg_sleep_remain';
/** 选中的时长档（分钟），只用于界面回显 */
export const K_SLEEP_MINUTES: string = 'cfg_sleep_minutes';
/** 指定时刻的「HH:MM」，只用于界面回显（未设定时为空串） */
export const K_SLEEP_CLOCK: string = 'cfg_sleep_clock';

/** 这些状态都算「在出声的路上」：换歌的 loading 不该把倒计时冻住 */
function isPlaybackActive(): boolean {
  const status: string = AppStorage.get<string>(K_PLAYER_STATUS) ?? 'idle';
  return status === 'playing' || status === 'buffering' || status === 'loading';
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export class SleepTimer {
  private static instance: SleepTimer | null = null;

  static getInstance(): SleepTimer {
    if (SleepTimer.instance === null) {
      SleepTimer.instance = new SleepTimer();
    }
    return SleepTimer.instance;
  }

  private context: common.UIAbilityContext | null = null;
  private appContext: common.ApplicationContext | null = null;

  private mode: string = SLEEP_MODE_OFF;
  /** 剩余毫秒：唯一的时间真相，界面显示与到点判定都读它 */
  private remainMs: number = 0;
  /** 上一跳的时间戳：按差值扣时间，避免 setInterval 的累积漂移 */
  private lastTickAt: number = 0;
  private timerId: number = -1;
  private minutes: number = SLEEP_DEFAULT_MINUTES;
  private clockHour: number = 0;
  private clockMinute: number = 0;
  /** 指定时刻对应的绝对时间戳：用来判断落在今天还是明天 */
  private clockAt: number = 0;
  /** 到点关闭是否已经走到一半（防止暂停/关闭过程中的重入） */
  private firing: boolean = false;

  /**
   * 要一个 UIAbility 的 Context：关应用得靠 terminateSelf。
   *
   * EntryAbility.onCreate 里调一次即可，之后设置页与倒计时都走本单例。
   */
  init(context: common.UIAbilityContext): void {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    this.appContext = context.getApplicationContext();
  }

  getMode(): string {
    return this.mode;
  }

  getRemainMs(): number {
    return this.remainMs;
  }

  /** 选中的时长档（分钟） */
  getMinutes(): number {
    return this.minutes;
  }

  /** 指定时刻（返回 [时, 分]；未设定时给当前时间） */
  getClock(): number[] {
    const now: Date = new Date();
    if (this.mode === SLEEP_MODE_CLOCK) {
      return [this.clockHour, this.clockMinute];
    }
    return [now.getHours(), now.getMinutes()];
  }

  /**
   * 「再放 N 分钟后关闭」。
   *
   * 重复点同一档不会重置倒计时 —— 设置页每一下点击都会走到这里，若重置，
   * 用户多点一次就白等一轮。想重新计时先「关闭」再设。
   */
  startDuration(minutes: number, restart: boolean = false): void {
    const safe: number = Math.max(1, Math.round(minutes));
    if (this.mode === SLEEP_MODE_DURATION && this.minutes === safe && !restart) {
      return;
    }
    this.mode = SLEEP_MODE_DURATION;
    this.minutes = safe;
    this.remainMs = safe * 60 * 1000;
    this.startTicker();
    this.publish();
    hilog.info(DOMAIN, TAG, 'sleep timer armed: duration %{public}d min', safe);
  }

  /**
   * 「到 HH:MM 关闭」。
   *
   * 今天这个点还没到就是今天，已经过了（含此刻整分）就是明天 —— 半夜设 07:00 指的是明早。
   */
  startClock(hour: number, minute: number): void {
    const h: number = Math.min(23, Math.max(0, Math.floor(hour)));
    const m: number = Math.min(59, Math.max(0, Math.floor(minute)));
    const now: Date = new Date();
    const target: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0, 0);
    if (target.getTime() <= now.getTime() + 1000) {
      target.setDate(target.getDate() + 1);
    }
    this.mode = SLEEP_MODE_CLOCK;
    this.clockHour = h;
    this.clockMinute = m;
    this.clockAt = target.getTime();
    this.remainMs = target.getTime() - now.getTime();
    this.startTicker();
    this.publish();
    hilog.info(DOMAIN, TAG, 'sleep timer armed: clock %{public}s (+%{public}d ms)',
      this.clockTargetLabel(), this.remainMs);
  }

  /** 取消：不关应用，只是把定时器撤掉 */
  cancel(): void {
    if (this.mode === SLEEP_MODE_OFF) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'sleep timer cancelled');
    this.mode = SLEEP_MODE_OFF;
    this.remainMs = 0;
    this.stopTicker();
    this.publish();
  }

  /** 「23:30」这种给界面看的时刻 */
  clockLabel(): string {
    return `${pad2(this.clockHour)}:${pad2(this.clockMinute)}`;
  }

  /**
   * 目标时刻的人话：「今天 23:30」/「明天 07:00」
   *
   * 只写 HH:MM 会让人半夜设 07:00 时以为是 7 分钟后（其实是明早），所以带上今天/明天。
   */
  clockTargetLabel(): string {
    if (this.clockAt <= 0) {
      return this.clockLabel();
    }
    const target: Date = new Date(this.clockAt);
    const now: Date = new Date();
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const targetDay: Date = new Date(target.getFullYear(), target.getMonth(), target.getDate());
    const days: number = Math.round((targetDay.getTime() - today.getTime()) / (24 * 3600 * 1000));
    const dayLabel: string = days <= 0 ? '今天' : (days === 1 ? '明天' : `${days} 天后`);
    return `${dayLabel} ${this.clockLabel()}`;
  }

  /** 「还剩 12:34」里那一段；超过一小时写成 1:02:03 */
  remainLabel(): string {
    const total: number = Math.max(0, Math.ceil(this.remainMs / 1000));
    const hours: number = Math.floor(total / 3600);
    const minutes: number = Math.floor((total % 3600) / 60);
    const seconds: number = total % 60;
    if (hours > 0) {
      return `${hours}:${pad2(minutes)}:${pad2(seconds)}`;
    }
    return `${pad2(minutes)}:${pad2(seconds)}`;
  }

  private startTicker(): void {
    this.lastTickAt = Date.now();
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => this.tick(), 1000);
  }

  private stopTicker(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private tick(): void {
    if (this.mode === SLEEP_MODE_OFF || this.firing) {
      return;
    }
    const now: number = Date.now();
    const delta: number = Math.max(0, now - this.lastTickAt);
    this.lastTickAt = now;
    if (this.mode === SLEEP_MODE_CLOCK) {
      // 钟点走墙上时间：暂停、熄屏都不影响
      this.remainMs = Math.max(0, this.remainMs - delta);
    } else if (isPlaybackActive()) {
      // 播放时长只认「真的在出声」的那部分时间
      this.remainMs = Math.max(0, this.remainMs - delta);
    }
    this.publish();
    if (this.remainMs <= 0) {
      this.fire().catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'sleep timer fire failed: %{public}s', err.message);
      });
    }
  }

  /** 到点了：停播 -> 收后台任务 -> 关应用 */
  private async fire(): Promise<void> {
    if (this.firing) {
      return;
    }
    this.firing = true;
    this.stopTicker();
    this.mode = SLEEP_MODE_OFF;
    this.remainMs = 0;
    this.publish();
    hilog.info(DOMAIN, TAG, 'sleep timer fired, stopping playback and closing app');
    try {
      await LxPlayer.getInstance().pause();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pause on sleep failed: %{public}s', JSON.stringify(e));
    }
    try {
      // 停长时任务与播控中心状态：不先撤掉，进程会被当成「正在后台放音」保活
      PlaybackService.getInstance().stopPlayback();
      PlaySession.getInstance().persistPlayState(true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stop playback service failed: %{public}s', JSON.stringify(e));
    }
    // 留一点时间让上面两步的异步回调落地（暂停回调里还有落盘），再关界面
    setTimeout(() => this.closeApp(), 400);
  }

  private closeApp(): void {
    const context = this.context;
    if (context === null) {
      hilog.warn(DOMAIN, TAG, 'no ability context, cannot close app');
      return;
    }
    context.terminateSelf().then(() => {
      const appContext = this.appContext;
      if (appContext === null) {
        return;
      }
      // terminateSelf 只是把界面收掉；用户要的是「关掉 app」，进程也一并退出。
      // 个别机型/版本上这个接口会被拒（非系统应用），失败就算了 —— 界面已经收了。
      appContext.killAllProcesses(true).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'killAllProcesses failed: %{public}s', err.message);
      });
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', err.message);
    });
  }

  private publish(): void {
    AppStorage.setOrCreate(K_SLEEP_MODE, this.mode);
    AppStorage.setOrCreate(K_SLEEP_REMAIN, Math.max(0, Math.ceil(this.remainMs / 1000)));
    AppStorage.setOrCreate(K_SLEEP_MINUTES, this.minutes);
    AppStorage.setOrCreate(K_SLEEP_CLOCK, this.mode === SLEEP_MODE_CLOCK ? this.clockTargetLabel() : '');
  }
}
