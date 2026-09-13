import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackService } from './PlaybackService';
import { PlaySettings } from '../settings/PlaySettings';

const DOMAIN: number = 0x0001;
const TAG: string = 'LxPlayer';

export type LxPlayerStatus = 'idle' | 'loading' | 'playing' | 'paused' | 'stopped' | 'error';

/** 播放状态变化（error 时 message 是失败原因） */
export type LxPlayerStateListener = (status: LxPlayerStatus, message: string) => void;
/** 播放进度（毫秒），由 AVPlayer 的 timeUpdate / durationUpdate 驱动 */
export type LxPlayerTimeListener = (currentMs: number, durationMs: number) => void;
/** 一首播完 */
export type LxPlayerCompletionListener = () => void;

/**
 * 播放器封装（AVPlayer）
 *
 * 播放链路：内置搜索得到 musicInfo -> 导入的源规则解析出播放链接 -> 这里播放。
 * 播放的是网络音频，因此同样依赖 ohos.permission.INTERNET。
 *
 * 状态与进度的唯一来源是 AVPlayer 自己：调用方（PlaySession）不再自己造
 * 「正在播放」和假进度，否则界面会在没有声音的时候也一路走进度条。
 */
export class LxPlayer {
  private static instance: LxPlayer | null = null;

  static getInstance(): LxPlayer {
    if (LxPlayer.instance === null) {
      LxPlayer.instance = new LxPlayer();
    }
    return LxPlayer.instance;
  }

  private avPlayer: media.AVPlayer | null = null;
  /** 播放本地缓存文件时打开的句柄：release 时一定要关掉，否则 fd 会泄漏 */
  private fdHandle: fs.File | null = null;
  private status: LxPlayerStatus = 'idle';
  private message: string = '';
  private durationMs: number = 0;
  private currentMs: number = 0;

  private stateListeners: LxPlayerStateListener[] = [];
  private timeListeners: LxPlayerTimeListener[] = [];
  private completionListeners: LxPlayerCompletionListener[] = [];

  // ------------------------------------------------------------ 订阅

  addStateListener(listener: LxPlayerStateListener): void {
    if (!this.stateListeners.includes(listener)) {
      this.stateListeners.push(listener);
    }
  }

  removeStateListener(listener: LxPlayerStateListener): void {
    const next: LxPlayerStateListener[] = [];
    for (const item of this.stateListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.stateListeners = next;
  }

  addTimeListener(listener: LxPlayerTimeListener): void {
    if (!this.timeListeners.includes(listener)) {
      this.timeListeners.push(listener);
    }
  }

  removeTimeListener(listener: LxPlayerTimeListener): void {
    const next: LxPlayerTimeListener[] = [];
    for (const item of this.timeListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.timeListeners = next;
  }

  addCompletionListener(listener: LxPlayerCompletionListener): void {
    if (!this.completionListeners.includes(listener)) {
      this.completionListeners.push(listener);
    }
  }

  removeCompletionListener(listener: LxPlayerCompletionListener): void {
    const next: LxPlayerCompletionListener[] = [];
    for (const item of this.completionListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.completionListeners = next;
  }

  // ------------------------------------------------------------ 查询

  getStatus(): LxPlayerStatus {
    return this.status;
  }

  getMessage(): string {
    return this.message;
  }

  getDurationMs(): number {
    return this.durationMs;
  }

  getCurrentMs(): number {
    return this.currentMs;
  }

  isPlaying(): boolean {
    return this.status === 'playing';
  }

  private update(status: LxPlayerStatus, message: string): void {
    this.status = status;
    this.message = message;
    // 同步给系统媒体卡（锁屏 / 控制中心）：状态一变就刷，同时顺带把后台播放任务立起来
    PlaybackService.getInstance().updateState(status, this.currentMs, this.durationMs);
    const listeners: LxPlayerStateListener[] = this.stateListeners.slice();
    for (const listener of listeners) {
      listener(status, message);
    }
  }

  private emitTime(currentMs: number, durationMs: number): void {
    this.currentMs = currentMs;
    if (durationMs > 0) {
      this.durationMs = durationMs;
    }
    // 进度按秒节流回写，锁屏进度条靠 AVPlaybackState 自带的时间戳自行外推
    PlaybackService.getInstance().updatePosition(currentMs);
    const listeners: LxPlayerTimeListener[] = this.timeListeners.slice();
    for (const listener of listeners) {
      listener(currentMs, this.durationMs);
    }
  }

  private emitCompleted(): void {
    const listeners: LxPlayerCompletionListener[] = this.completionListeners.slice();
    for (const listener of listeners) {
      listener();
    }
  }

  // ------------------------------------------------------------ 播放控制

  /** 播放一个网络音频地址（先释放上一个实例） */
  async playUrl(url: string): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    // state 为 idle 时设置 url 会进入 initialized，随后由 stateChange 驱动 prepare/play
    player.url = url;
  }

  /**
   * 播放本地缓存文件（AudioCache 下好的整首）
   *
   * 用 fdSrc 而不是 file:// 路径：沙箱文件的绝对路径在不同版本上对 AVPlayer 的
   * 可见性不一样，fd 是明确支持的形态。句柄存起来，release 时释放播放器后再关。
   */
  async playLocal(path: string): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    this.fdHandle = file;
    const source: media.AVFileDescriptor = { fd: file.fd };
    player.fdSrc = source;
  }

  /** 建实例、挂监听；url / fdSrc 由调用方在这一步之后设置 */
  private async preparePlayer(): Promise<media.AVPlayer> {
    await this.release();
    this.update('loading', '正在加载音频…');
    this.durationMs = 0;
    this.currentMs = 0;

    const player: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = player;
    try {
      // 不设的话部分设备会落到提示音/系统音通道上，听感上就是「没声音」。
      // 这个属性只能在 idle 态设置，而且必须在 prepare 之前。
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0,
      };
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set audioRendererInfo failed: %{public}s', JSON.stringify(err));
    }

    player.on('stateChange', (state: media.AVPlayerState) => {
      // 已被新实例替换或已释放的旧回调直接忽略
      if (this.avPlayer !== player) {
        return;
      }
      switch (state) {
        case 'initialized':
          player.prepare().catch((err: BusinessError) => {
            this.update('error', `准备音频失败：${err.message}`);
          });
          break;
        case 'prepared':
          // 音频焦点模式要在首次 play() 之前设，prepared 正好是唯一能设又还没出声的时机
          this.applyInterruptMode(player, PlaySettings.getInstance().isPlayWithOthers());
          player.play().catch((err: BusinessError) => {
            this.update('error', `播放失败：${err.message}`);
          });
          break;
        case 'playing':
          this.update('playing', '正在播放');
          break;
        case 'paused':
          this.update('paused', '已暂停');
          break;
        case 'completed':
          this.update('stopped', '播放完成');
          this.emitCompleted();
          break;
        case 'stopped':
          this.update('stopped', '已停止');
          break;
        case 'error':
          this.update('error', '播放器进入错误状态');
          break;
        default:
          break;
      }
    });
    player.on('durationUpdate', (duration: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      if (duration > 0) {
        this.emitTime(this.currentMs, duration);
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      this.emitTime(time, this.durationMs);
    });
    player.on('error', (err: BusinessError) => {
      if (this.avPlayer !== player) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'playback error: %{public}s', `${err.code} ${err.message}`);
      this.update('error', `播放错误：${err.message}`);
    });
    return player;
  }

  async pause(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null && this.status === 'playing') {
      await player.pause();
    }
  }

  /**
   * 「与其他应用同时播放」——对应 AVPlayer 的音频焦点模式
   *
   * 系统默认是 SHARE_MODE（0）：几个流共享一个中断单元，别的应用一出声就把我们打断。
   * 允许同时播放就是 INDEPENDENT_MODE（1）：各自的流互不打断，混在一起响，
   * 这也是导航类应用要「压着音乐播」时用的模式。
   * 属性只能在 prepared/playing/paused/completed 态设置，且首次 play() 之后才设就不算数，
   * 所以真正生效点是 preparePlayer 的 prepared 回调（见 applyInterruptMode）。
   */
  setPlayWithOthers(value: boolean): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status !== 'playing' && this.status !== 'paused') {
      return;
    }
    this.applyInterruptMode(player, value);
  }

  private applyInterruptMode(player: media.AVPlayer, withOthers: boolean): void {
    try {
      player.audioInterruptMode = withOthers
        ? audio.InterruptMode.INDEPENDENT_MODE
        : audio.InterruptMode.SHARE_MODE;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'set audioInterruptMode failed: %{public}s', JSON.stringify(err));
    }
  }

  async resume(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null && this.status === 'paused') {
      await player.play();
    }
  }

  /** 拖动进度条：毫秒（AVPlayer.seek 返回 void，只在 prepared/playing/paused/completed 态可用） */
  seek(ms: number): void {
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status !== 'playing' && this.status !== 'paused') {
      return;
    }
    const target: number = ms > 0 ? Math.floor(ms) : 0;
    try {
      player.seek(target);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'seek failed: %{public}s', JSON.stringify(err));
    }
  }

  async stop(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null) {
      await player.stop();
    }
  }

  async release(): Promise<void> {
    const player = this.avPlayer;
    this.avPlayer = null;
    if (player !== null) {
      try {
        player.off('stateChange');
        player.off('durationUpdate');
        player.off('timeUpdate');
        player.off('error');
        await player.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'release failed: %{public}s', JSON.stringify(err));
      }
    }
    // 播放器先释放，再关本地文件句柄：反过来可能让播放器读到一个已关闭的 fd
    const handle = this.fdHandle;
    this.fdHandle = null;
    if (handle !== null) {
      try {
        fs.closeSync(handle);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'close fd failed: %{public}s', JSON.stringify(err));
      }
    }
    this.status = 'idle';
    this.message = '';
    this.durationMs = 0;
    this.currentMs = 0;
  }
}
