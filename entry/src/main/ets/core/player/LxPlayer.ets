import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackService } from './PlaybackService';
import { PlaySettings } from '../settings/PlaySettings';
import { StartupTiming } from './StartupTiming';

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
 * 缓冲状态变化
 *
 * buffering = 播放器正在等数据（此刻声音是断的）；
 * bufferedEndMs = 已缓冲到的位置（能播到哪儿），见 getBufferedEndMs。
 */
export type LxPlayerBufferListener = (buffering: boolean, bufferedEndMs: number) => void;

/**
 * 缓冲时长（秒）
 *
 * 单位是秒、官方取值范围 [1, 20]，所以 20 就是平台硬上限。
 * （官方《在线视频播放卡顿优化》里那句「缓冲区大小 = preferredBufferDuration × 1MB」
 * 是视频场景按码率折成字节的启发式换算，对音频不成立，别当 MB 读。）
 * 取满 20：这首 20 秒的余量吃满之后基本不用再盯网络，网络时好时坏也不会一卡一卡。
 */
const BUFFER_SECONDS: number = 20;
/**
 * 起播 / 卡顿后恢复播放的水位线（秒）
 *
 * 缓冲区里攒够这么多秒才出声/恢复。默认那条水位线在弱网下只有约 1 秒的量，
 * 结果是「响一下、卡一下、再响一下」；攒到 8 秒再恢复，代价是起播/恢复时多等一会儿，
 * 换来的是恢复之后能连续播下去（带宽够时攒 8 秒只要一两秒）。
 */
const RESUME_WATERLINE_SECONDS: number = 8;
/**
 * 「卡住了」的判定：正在播、但进度这么久没往前走（毫秒）
 *
 * 用它当缓存让路的依据之一：bufferingUpdate 那套事件在真机上只在上手阶段来一批
 * （见 docs/PLAYBACK_BUFFER.md），指望不上；进度停住是**自己就能测到**的饥饿信号。
 */
const STALL_MS: number = 3000;

/**
 * 多久问一次播放器「已经加载到哪儿」（毫秒）
 *
 * 这是进度条上那条灰段的**正路**：`getLoadedTimeRanges()` 返回播放器本地已加载的时间区间
 * （`[min, max]` 毫秒），等价于 iOS 的 `loadedTimeRanges`、web 的 `buffered`、
 * ExoPlayer 的 `getBufferedPosition()` —— 各家进度条上那条浅色段画的就是它。
 * 一秒问一次足够（进度本身也是每秒刷一次），别问太勤。
 */
const LOADED_PROBE_MS: number = 1000;

/**
 * 播放器封装（AVPlayer）
 *
 * 播放链路：内置搜索得到 musicInfo -> 导入的源规则解析出播放链接 -> 这里播放。
 * 播放的是网络音频，因此同样依赖 ohos.permission.INTERNET。
 *
 * 状态与进度的唯一来源是 AVPlayer 自己：调用方（PlaySession）不再自己造
 * 「正在播放」和假进度，否则界面会在没有声音的时候也一路走进度条。
 */
/**
 * 这批设备里有没有「耳机类」的（有线耳机 / 蓝牙 / USB）
 *
 * 拔耳机时系统上报的是断开的那几个设备，所以只要其中有一个是耳机类就认为「耳机没了」。
 * 内置扬声器/听筒不算 —— 切到外放不暂停会吵到别人，也正是这个功能要解决的问题。
 */
function isHeadsetType(deviceType: number): boolean {
  const headsets: number[] = [
    audio.DeviceType.WIRED_HEADSET,
    audio.DeviceType.WIRED_HEADPHONES,
    audio.DeviceType.BLUETOOTH_SCO,
    audio.DeviceType.BLUETOOTH_A2DP,
    audio.DeviceType.USB_HEADSET,
  ];
  return headsets.includes(deviceType);
}

function isHeadsetOf(devices: audio.AudioDeviceDescriptors): boolean {
  for (let i = 0; i < devices.length; i++) {
    if (isHeadsetType(devices[i].deviceType)) {
      return true;
    }
  }
  return false;
}

export class LxPlayer {
  private static instance: LxPlayer | null = null;

  static getInstance(): LxPlayer {
    if (LxPlayer.instance === null) {
      LxPlayer.instance = new LxPlayer();
      LxPlayer.instance.wireHeadsetOffPause();
    }
    return LxPlayer.instance;
  }

  /** 耳机断连监听是否已经挂过（只能挂一次） */
  private headsetWired: boolean = false;
  /** 音频路由管理器（拔耳机判定要复核输出设备，拿一次存着） */
  private routingManager: audio.AudioRoutingManager | null = null;
  /** 取路由管理器失败过（环境不支持）：不再反复试 */
  private routingManagerFailed: boolean = false;
  /** 拔耳机「延迟复核」的定时器 id（-1 = 没有待执行的复核） */
  private headsetRecheckTimer: number = -1;

  /**
   * 摘下耳机 / 断开蓝牙耳机 → 自动暂停
   *
   * 群反馈（2026-11-16 16:01，小冰）：「感觉可以加个摘掉耳机暂停的」。
   * 系统不会替应用暂停（只是把声音改从扬声器出），所以得自己听音频路由的设备变化：
   * 断开的是耳机类设备（有线 / 蓝牙 / USB）并且正在播放时，调一次 pause。
   *
   * 只在设置开着时暂停；挂载失败（老系统没有 getRoutingManager）只记日志，不影响播放。
   */
  private wireHeadsetOffPause(): void {
    if (this.headsetWired) {
      return;
    }
    const manager: audio.AudioRoutingManager | null = this.routingManagerOf();
    if (manager === null) {
      return;
    }
    this.headsetWired = true;
    const onChange: (action: audio.DeviceChangeAction) => void =
      (action: audio.DeviceChangeAction): void => {
        if (action.type !== audio.DeviceChangeType.DISCONNECT) {
          return;
        }
        if (!PlaySettings.getInstance().isAutoPauseHeadsetOff()) {
          return;
        }
        if (!isHeadsetOf(action.deviceDescriptors)) {
          return;
        }
        if (this.status !== 'playing') {
          return;
        }
        /*
         * 事件说的只是「这一批设备断开了」，**不等于**「用户把耳机摘了」。
         * 灭屏、蓝牙在 A2DP 与 SCO 之间来回切、通话建立、系统重新排一次输出路由，
         * 都会整批上报一次 DISCONNECT，而事件里带着的恰恰是原来那副耳机 ——
         * 只按事件列表判断，就会在还戴着耳机、声音根本没跑到外放的时候把音乐停掉。
         * 所以再问一次系统「当下首选输出设备是谁」：还有一个**别的**耳机类设备在输出，
         * 就不暂停。
         */
        if (this.stillOutputsToHeadset(action.deviceDescriptors)) {
          /*
           * 还有一种「复核早于路由更新」的情形：拔耳机后系统改输出是异步的，
           * 这一拍问到的首选输出仍然是那副刚拔掉的耳机（id 相同）。
           * 上面的判定已经把这批刚断开的设备剔除了，所以这里剩下的「还在输出」
           * 是真的还有另一副耳机；但路由表本身也可能还没刷完，于是再等 400ms 复核一次，
           * 那一次仍判「没有耳机在输出」就照常暂停 —— 宁可晚停 0.4 秒，也不要漏停。
           */
          this.scheduleHeadsetRecheck(action.deviceDescriptors);
          return;
        }
        hilog.info(DOMAIN, TAG, 'headset disconnected, pause playback');
        this.pauseAfterHeadsetOff();
      };
    try {
      // 只订阅**输出**设备：麦克风（输入）的插拔跟「声音跑到外放」没有关系，
      // 之前用 ALL_DEVICES_FLAG 时，输入侧的变化也会进到这个回调里来
      manager.on('deviceChange', audio.DeviceFlag.OUTPUT_DEVICES_FLAG, onChange);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wire headset-off pause failed: %{public}s',
        JSON.stringify(e));
    }
  }

  /** 拔耳机后的暂停（失败只记日志，不影响播放） */
  private pauseAfterHeadsetOff(): void {
    this.pause().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'pause after headset off failed: %{public}s', err.message);
    });
  }

  /**
   * 路由更新是异步的：第一次复核说「还有耳机在输出」时，隔 400ms 再问一次。
   *
   * 只保留一个待执行的复核（同一批断开事件会连报好几次）；到期时如果播放已经停了
   * （用户自己按了暂停 / 换了首歌）就什么都不做。
   */
  private scheduleHeadsetRecheck(gone: audio.AudioDeviceDescriptors): void {
    if (this.headsetRecheckTimer >= 0) {
      return;
    }
    this.headsetRecheckTimer = setTimeout(() => {
      this.headsetRecheckTimer = -1;
      if (this.status !== 'playing') {
        return;
      }
      if (this.stillOutputsToHeadset(gone)) {
        hilog.info(DOMAIN, TAG, 'headset reported disconnected, but it is still the output; keep playing');
        return;
      }
      hilog.info(DOMAIN, TAG, 'headset disconnected (recheck), pause playback');
      this.pauseAfterHeadsetOff();
    }, 400);
  }

  /** 音频路由管理器：拿一次存着；环境不支持时只记一次失败，不反复试 */
  private routingManagerOf(): audio.AudioRoutingManager | null {
    if (this.routingManager !== null) {
      return this.routingManager;
    }
    if (this.routingManagerFailed) {
      return null;
    }
    try {
      this.routingManager = audio.getAudioManager().getRoutingManager();
    } catch (e) {
      this.routingManagerFailed = true;
      hilog.warn(DOMAIN, TAG, 'getRoutingManager failed: %{public}s', JSON.stringify(e));
      return null;
    }
    return this.routingManager;
  }

  /**
   * 当下真正在出声的是不是**另一副**耳机类设备
   *
   * `gone` 是刚刚上报 DISCONNECT 的那批设备：查询结果里必须把它们剔除再看。
   * 不剔除的话，拔耳机的那一刻「首选输出」往往还挂着刚拔掉的那副（路由更新是异步的），
   * 于是复核会误判成「耳机还在」，一次都不停 —— 声音直接跑到外放上。
   *
   * 查询失败（老系统 / 偶发系统错误）返回 false，也就是**沿用旧行为**（暂停）：
   * 宁可偶发多停一次（用户按一下播放就回来），也不要让「摘下耳机自动暂停」这个功能失效。
   */
  private stillOutputsToHeadset(gone: audio.AudioDeviceDescriptors): boolean {
    const manager: audio.AudioRoutingManager | null = this.routingManagerOf();
    if (manager === null) {
      return false;
    }
    // 刚断开的设备 id：同一副设备在「首选输出」里再出现，不算「还有耳机在输出」
    const goneIds: Set<number> = new Set<number>();
    for (let i = 0; i < gone.length; i++) {
      goneIds.add(gone[i].id);
    }
    try {
      const info: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0,
      };
      const current: audio.AudioDeviceDescriptors =
        manager.getPreferredOutputDeviceForRendererInfoSync(info);
      for (let i = 0; i < current.length; i++) {
        const device: audio.AudioDeviceDescriptor = current[i];
        if (!isHeadsetType(device.deviceType)) {
          continue;
        }
        if (goneIds.has(device.id)) {
          continue;
        }
        return true;
      }
      return false;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'query preferred output device failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  private avPlayer: media.AVPlayer | null = null;
  /** 播放本地缓存文件时打开的句柄：release 时一定要关掉，否则 fd 会泄漏 */
  private fdHandle: fs.File | null = null;
  private status: LxPlayerStatus = 'idle';
  private message: string = '';
  private durationMs: number = 0;
  private currentMs: number = 0;
  /**
   * 期望的播放速率（1 = 原速）
   *
   * AVPlayer 的速率是**跟着实例走**的：每次 preparePlayer 建的新实例都是 1.0x，
   * 所以这里存「用户想要多少」，在 prepared 态重新落地一次（见 applySpeed）。
   * 默认 1.0x —— 音乐链路从不改它，行为与改动前完全一致。
   */
  private speedRate: number = 1;

  private stateListeners: LxPlayerStateListener[] = [];
  private timeListeners: LxPlayerTimeListener[] = [];
  private completionListeners: LxPlayerCompletionListener[] = [];
  private bufferListeners: LxPlayerBufferListener[] = [];
  /** 播放器此刻是不是在等数据（AVPlayer 的 BUFFERING_START/END） */
  private buffering: boolean = false;
  /** 缓冲区余量（ms）：已缓冲数据还能播多久（CACHED_DURATION 的原值） */
  private cachedMs: number = 0;
  /**
   * 已缓冲到的位置（ms），本首歌内只增不减
   *
   * 算法照抄官方实践样例（媒体开发实践 - 基于AVPlayer播放网络视频实践）：
   *   bufferedEnd = max(bufferedEnd, 当前进度 + CACHED_DURATION)
   * CACHED_DURATION 是「已缓冲数据还能播多久」（前量），加上当前进度才是「能播到哪儿」；
   * 而它是个预估值、会来回波动，缓冲终点在实心上却只会往前 —— 所以取 max。
   * 不取 max 的后果是实打实的：事件一停（比如播放器下够了就不再上报），
   * 拿旧的前量跟着播放头一路加，进度条上那条灰段就会永远比已播长「固定一截」，是假的。
   */
  private bufferedEndMs: number = 0;
  /**
   * 播放器**本地已加载到**哪儿（ms）：`getLoadedTimeRanges()` 里最远那段区间的右端
   *
   * 和 bufferedEndMs 的区别：那个是事件上报推出来的（会漏、会停），这个是主动问来的，
   * 而且正是业界进度条上那条灰段的数据源。
   */
  private loadedEndMs: number = 0;
  /** 上一次问「加载到哪儿」的时刻（节流） */
  private loadedProbeAt: number = 0;
  /** 这台设备/版本还能不能问 getLoadedTimeRanges（API 26 起；不支持就不再问） */
  private loadedProbeOk: boolean = true;
  /** 最近一次播放进度往前走的时刻：判断「卡住」用（见 STALL_MS） */
  private lastProgressAt: number = 0;
  /**
   * 被别的应用抢走焦点期间由系统暂停（INTERRUPT_HINT_PAUSE 之后、RESUME 之前）
   *
   * 和「用户自己按的暂停」分开记：只有这个标记为真，打断结束才自动接着放 ——
   * 用户主动停的不该在别的声音结束后自己响起来，见 PlaySettings.K_AUTO_RESUME_AFTER_INTERRUPT。
   */
  private focusPaused: boolean = false;
  /**
   * 打断引起的这一次暂停已经发出、但播放器还没真进 paused
   *
   * 系统的 RESUME 可能比它先到（提示音很短的时候就是这样），见 resumeAfterInterrupt。
   */
  private interruptPauseIssued: boolean = false;
  /** 打断已经结束、但当时暂停还没落地：等播放器真进 paused 再恢复（见 applyPendingResume） */
  private resumeWhenPaused: boolean = false;
  /** 音频会话管理器：「与其他应用同时播放」靠它激活混音会话（见 applyConcurrency） */
  private sessionManager: audio.AudioSessionManager | null = null;
  /** 取会话管理器失败（例如环境不支持）后不再反复重试 */
  private sessionManagerFailed: boolean = false;

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

  addBufferListener(listener: LxPlayerBufferListener): void {
    if (!this.bufferListeners.includes(listener)) {
      this.bufferListeners.push(listener);
    }
  }

  removeBufferListener(listener: LxPlayerBufferListener): void {
    const next: LxPlayerBufferListener[] = [];
    for (const item of this.bufferListeners) {
      if (item !== listener) {
        next.push(item);
      }
    }
    this.bufferListeners = next;
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

  /** 播放器此刻是不是在等数据（声音是断的） */
  isBuffering(): boolean {
    return this.buffering;
  }

  /** 缓冲区余量（ms）：已缓冲的数据还能连续播多久 */
  getCachedMs(): number {
    return this.cachedMs;
  }

  /**
   * 已缓冲到的位置（ms）：进度条上那条灰段该画到哪儿
   *
   * 取三者最靠前：播放器已加载区间（正路，见 loadedEndMs）、事件上报推出来的位置、
   * 以及当前播放进度（缓冲终点不可能落在播放头后面，灰段短于白段没法看）。
   * 本地播放没有加载区间也不会变，调用方按整首处理，不走这里。
   */
  getBufferedEndMs(): number {
    let end: number = this.loadedEndMs > this.bufferedEndMs ? this.loadedEndMs : this.bufferedEndMs;
    return end > this.currentMs ? end : this.currentMs;
  }

  /**
   * 问一下播放器「本地加载到哪儿了」
   *
   * 每秒一次（跟进度同一个节奏），只取区间里最远的那个右端；只增不减（回退 seek 时
   * 已加载的数据仍然在本地，不该往回收）。失败一次就关掉这条路退回事件那套 ——
   * 这台设备是 API 26 支持，但低版本设备上这个方法是空的。
   */
  private probeLoadedRange(): void {
    if (!this.loadedProbeOk) {
      return;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || (this.status !== 'playing' && this.status !== 'paused')) {
      return;
    }
    const now: number = Date.now();
    if (now - this.loadedProbeAt < LOADED_PROBE_MS) {
      return;
    }
    this.loadedProbeAt = now;
    try {
      player.getLoadedTimeRanges().then((ranges: Array<media.Range>) => {
        if (this.avPlayer !== player) {
          return;
        }
        let end: number = 0;
        for (const range of ranges) {
          if (range.max > end) {
            end = range.max;
          }
        }
        if (end > this.loadedEndMs) {
          this.loadedEndMs = end;
          this.emitBufferState();
        }
      }).catch((err: BusinessError) => {
        this.loadedProbeOk = false;
        hilog.warn(DOMAIN, TAG, 'getLoadedTimeRanges failed, fallback to events: %{public}s',
          `${err.code} ${err.message}`);
      });
    } catch (err) {
      this.loadedProbeOk = false;
      hilog.warn(DOMAIN, TAG, 'getLoadedTimeRanges unavailable on this device');
    }
  }

  /** 把当前缓冲状态再播一遍给订阅方（加载区间变了，但 buffering / 事件值没变时用） */
  private emitBufferState(): void {
    const listeners: LxPlayerBufferListener[] = this.bufferListeners.slice();
    for (const listener of listeners) {
      listener(this.buffering, this.getBufferedEndMs());
    }
  }

  /**
   * 现在能不能把带宽让给后台的播放缓存 / 自动下载
   *
   * 顺序上「播放优先」，但只看**真的**说明播放器在挨饿的信号，不设固定门槛：
   *   - 正在起播 / 切歌（`loading`）→ 不让，它要抢首屏缓冲；
   *   - 播放器在等数据（`buffering`）、且进度确实没往前走 → 不让；
   *   - 在播、但进度已经 STALL_MS 没动 → 不让（自己测出来的卡顿）；
   *   - 其余（正常播 / 暂停 / 停止 / 空闲 / 出错）→ 让，后台按网络能给的速度下。
   *
   * 判断以**播放进度**为准，不信 `buffering` 这个标志本身：真机上
   * `BUFFERING_START` 会上报、`BUFFERING_END` 会漏（见 docs/PLAYBACK_BUFFER.md 里
   * 缓冲水位那段的实测），一漏 `buffering` 就整首歌停在 true —— 那时进度明明在走，
   * 却把整首歌的后台下载全挡住了，表现就是「听了两首之后不再下载」。进度在走就说明
   * 没卡，让路不该再拦。
   *
   * 曾经这里还有过两版"人工节奏"，都删了：一是「缓冲区余量 ≥ 30 秒才让」——
   * 真机只报到 13 秒，那条线永远不成立，结果是整首都不下缓存；二是「起播后先让 4 秒」——
   * 表现为进度条那条灰段开头干等几秒，像坏了。缓存该多快就多快，只在播放挨饿时让路。
   */
  canUseBandwidthForCache(): boolean {
    if (this.status === 'loading') {
      return false;
    }
    // 进度最近还在往前走（= 真的在出声），就不认为播放器在挨饿
    const progressing: boolean = this.lastProgressAt !== 0
      && Date.now() - this.lastProgressAt < STALL_MS;
    if (this.buffering && !progressing) {
      return false;
    }
    if (this.status === 'playing' && !progressing) {
      return false;
    }
    return true;
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

  /**
   * 缓冲状态变了：通知订阅方（界面转圈、进度条灰段、缓存调度让路都看它）
   *
   * cachedMs > 0 时顺手把「缓冲终点」往前推（只增不减，见 bufferedEndMs）。
   * START/END 事件带的是上一次的前量，算出来的终点不会超过已记录的，所以不会虚增。
   */
  private updateBuffer(buffering: boolean, cachedMs: number): void {
    if (this.buffering === buffering && this.cachedMs === cachedMs) {
      return;
    }
    this.buffering = buffering;
    this.cachedMs = cachedMs;
    if (cachedMs > 0) {
      const candidate: number = this.currentMs + cachedMs;
      if (candidate > this.bufferedEndMs) {
        this.bufferedEndMs = candidate;
      }
    }
    const listeners: LxPlayerBufferListener[] = this.bufferListeners.slice();
    for (const listener of listeners) {
      listener(this.buffering, this.getBufferedEndMs());
    }
  }

  /**
   * 记一条缓冲水位的日志（只记「往前长了 1 秒以上」的）
   *
   * 上手那一下会连着来几十条 500ms 级的事件（真机实测 120ms 内来了 25 条），
   * 全记会把日志冲爆、还可能触发 hilog 流控把别的日志丢掉，所以只记有意义的增量。
   */
  private logBufferGrowth(cachedMs: number): void {
    const end: number = this.currentMs + cachedMs;
    if (end < this.bufferedEndMs + 1000) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'bufferingUpdate: cached %{public}dms, at %{public}dms -> end %{public}dms',
      cachedMs, this.currentMs, end);
  }

  private emitTime(currentMs: number, durationMs: number): void {
    if (currentMs !== this.currentMs) {
      // 进度真的往前走了：记一下，缓存让路靠它判断「有没有卡住」
      this.lastProgressAt = Date.now();
    }
    this.currentMs = currentMs;
    if (durationMs > 0) {
      this.durationMs = durationMs;
    }
    // 进度按秒节流回写，锁屏进度条靠 AVPlaybackState 自带的时间戳自行外推
    PlaybackService.getInstance().updatePosition(currentMs);
    // 顺带问一下播放器本地加载到哪儿了（进度条那条灰段的真实来源）
    this.probeLoadedRange();
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
    // 起播计时的后半段从这里开始（前半段是 PlaySession 取地址，见 StartupTiming）。
    // 看门狗一起挂上：地址是死链或播放器卡在 prepare 时 stateChange 一声不吭，
    // 不挂它的话这次起播连一条日志都不会留下。
    StartupTiming.getInstance().armWatchdog();
    // state 为 idle 时设置 url 会进入 initialized，随后由 stateChange 驱动 prepare/play
    player.url = url;
  }

  /**
   * 播放一个**需要请求头**的网络音频地址（WebDAV 这类要 Basic 认证的源）
   *
   * 为什么不用 `player.url`：url 是裸字符串，没有任何地方能挂 `Authorization`，
   * 而 WebDAV 服务器一定要求认证。官方给的带请求头的形态是
   * `media.createMediaSourceWithUrl(url, headers)` + `setMediaSource(src, strategy)`，
   * 而且它允许**设源的同时把播放策略一起给**（缓冲水位那两项），所以我们不必再走
   * 「initialized 态里补 setPlaybackStrategy」那一步（见 prepareWithStrategy）。
   *
   * 失败时不阻断：退回不带头的 `player.url`（匿名可读的服务器照样能放），
   * 真的放不出来由播放器的错误回调报上去。
   */
  async playUrlWithHeaders(url: string, headers: Record<string, string>): Promise<void> {
    const player: media.AVPlayer = await this.preparePlayer();
    try {
      const source: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
      await player.setMediaSource(source, this.playbackStrategy());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setMediaSource with headers failed, fallback to url: %{public}s',
        JSON.stringify(err));
      if (this.avPlayer !== player) {
        return;
      }
      try {
        player.url = url;
      } catch (e) {
        this.update('error', `播放失败：${(e as BusinessError).message}`);
      }
    }
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
    // 换了实例：缓冲水位从零开始（上一次的转圈状态也要收掉、灰段也要从头长）
    this.bufferedEndMs = 0;
    // 打断标记是跟着这一首/这个实例走的，新实例从头开始记
    this.focusPaused = false;
    this.interruptPauseIssued = false;
    this.resumeWhenPaused = false;
    this.updateBuffer(false, 0);

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
          // 播放策略只能在 initialized 态设、且必须在 prepare 之前，
          // 所以这里先把 prepare 往后放一拍（见 applyPlaybackStrategy）
          void this.prepareWithStrategy(player);
          break;
        case 'prepared': {
          // 两处都要在首次 play() 之前落地：焦点模式只能在 prepared/playing/paused/completed
          // 设（prepared 是唯一「能设又还没出声」的时机，见 applyInterruptMode）；
          // 音频会话则每次起播都要补一次（系统会在没有流跑之后超时回收，见 applyConcurrency）
          const withOthers: boolean = PlaySettings.getInstance().isPlayWithOthers();
          this.applyInterruptMode(player, withOthers);
          this.applyConcurrency(withOthers);
          // 倍速：新实例默认是 1.0x，出声前把用户要的速率补上（听书 1.5x 换集后不掉回原速）
          this.applySpeed(player);
          player.play().catch((err: BusinessError) => {
            this.update('error', `播放失败：${err.message}`);
          });
          break;
        }
        case 'playing':
          // AVPlayer 真正开始出声音了：这里就是「点击到出声」的终点，把起播耗时打出去。
          // 只在「从没在播」的时候打：暂停后接着播、seek 之后续播都不算一次新的起播，
          // 每次进 playing 都打一条的话日志里全是假的起播耗时。
          if (this.status !== 'playing') {
            StartupTiming.getInstance().markPlaying();
          }
          this.update('playing', '正在播放');
          /*
           * 倍速补一次：用户在「起播 / 缓冲」窗口里切了倍速（那时 status 还是 loading，
           * setSpeed 只记账）时，prepared 里的那次 applySpeed 早就执行过了，这一次
           * playing 才是唯一能把新速率落到这个实例上的时机。
           * 已按条目归位（见 PlaySession.playAt）：音乐条目 speedRate 就是 1.0x，
           * 这里再设一次仍是 1.0x，不会把听书的倍速带到音乐上。
           */
          this.applySpeed(player);
          break;
        case 'paused':
          // 这次暂停已经落地：打断期间就先结束了的恢复请求（见 resumeAfterInterrupt）到这里补上
          this.interruptPauseIssued = false;
          this.update('paused', '已暂停');
          this.applyPendingResume();
          break;
        case 'completed':
          this.update('stopped', '播放完成');
          this.emitCompleted();
          break;
        case 'stopped':
          this.update('stopped', '已停止');
          break;
        case 'error':
          // 失败也要把耗时打出来：排障时最需要看的恰恰是失败那几次等了多久
          StartupTiming.getInstance().markFailed('播放器错误态');
          this.update('error', '播放器进入错误状态');
          break;
        default:
          break;
      }
    });
    // 缓冲水位：只在网络播放时有回调。BUFFERING_START/END 是「声音断了 / 续上了」，
    // CACHED_DURATION 是余量还能播多久 —— 界面转圈和后台缓存让路都靠这几个值。
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.avPlayer !== player) {
        return;
      }
      switch (infoType) {
        case media.BufferingInfoType.BUFFERING_START:
          this.updateBuffer(true, this.cachedMs);
          break;
        case media.BufferingInfoType.BUFFERING_END:
          this.updateBuffer(false, this.cachedMs);
          break;
        case media.BufferingInfoType.CACHED_DURATION:
          // 官方实践样例也是这么打的：缓冲条不对时，先看这几个数
          this.logBufferGrowth(value);
          this.updateBuffer(this.buffering, value);
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
      // 与 stateChange 的 error 分支同一件事，两条都可能来；StartupTiming 自己保证只记一次
      StartupTiming.getInstance().markFailed(`播放错误 ${err.code}`);
      this.update('error', `播放错误：${err.message}`);
    });
    // 音频焦点被打断 / 打断结束：这是「与其他应用同时播放」之外的另一半 ——
    // 那个管的是要不要被打断，这个管的是被打断之后接不接着放（见 onAudioInterrupt）
    player.on('audioInterrupt', (info: audio.InterruptEvent) => {
      if (this.avPlayer !== player) {
        return;
      }
      this.onAudioInterrupt(info);
    });
    return player;
  }

  /**
   * 播放策略（缓冲水位）
   *
   * 抽出来是因为有两个设置点：走 `player.url` 时只能在 initialized 态用
   * `setPlaybackStrategy` 补（见 prepareWithStrategy），走 `setMediaSource` 时
   * 可以随源一起给（见 playUrlWithHeaders）。两处的值必须一致，所以只有这一份。
   */
  private playbackStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: BUFFER_SECONDS,
      preferredBufferDurationForPlaying: RESUME_WATERLINE_SECONDS,
    };
  }

  /**
   * 设好播放策略再 prepare
   *
   * `setPlaybackStrategy` 只能在 initialized 态调用，而 prepare 会把它推离这个状态，
   * 所以两件事必须按顺序来（setMediaSource 那条路虽然也能带策略，但它要求源与策略同时给，
   * 而我们走的是 player.url，策略只能这样补上）。
   * 设策略失败不阻断播放：个别设备/版本不支持时退回系统默认，别让用户直接听不成。
   */
  private async prepareWithStrategy(player: media.AVPlayer): Promise<void> {
    const strategy: media.PlaybackStrategy = this.playbackStrategy();
    try {
      await player.setPlaybackStrategy(strategy);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setPlaybackStrategy failed, use default: %{public}s',
        JSON.stringify(err));
    }
    if (this.avPlayer !== player) {
      return;
    }
    try {
      await player.prepare();
    } catch (err) {
      this.update('error', `准备音频失败：${(err as BusinessError).message}`);
    }
  }

  async pause(): Promise<void> {
    // 用户 / 系统播控中心发来的暂停是**明确意图**：把「等这次暂停落地就接着放」的
    // 待办清掉，否则打断期间用户自己按了暂停，等播放器进 paused 时又被自动放起来。
    this.resumeWhenPaused = false;
    await this.doPause();
  }

  /** 真正调播放器暂停（打断路径也走它，见 pauseOnInterrupt） */
  private async doPause(): Promise<void> {
    const player = this.avPlayer;
    if (player !== null && this.status === 'playing') {
      await player.pause();
    }
  }

  /**
   * 设置播放速率（1 = 原速；听书倍速用它）
   *
   * 两件事：
   *   1. 记下期望值 —— 换集 / 切音质都会重建 AVPlayer 实例，新实例一定是 1.0x，
   *      要在 prepared 态重新设一次（见 preparePlayer 的 stateChange）；
   *   2. 当前实例已经能设就立刻设 —— 用户在播着的时候改倍速要马上听出来。
   *
   * 只在 prepared / playing / paused / completed 态可设（SDK 原文），所以其它状态
   * 只记账、不调用，免得抛 5400102。
   */
  setSpeed(rate: number): void {
    this.speedRate = rate > 0 ? rate : 1;
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    // 起播 / 缓冲窗口（loading）：这一刻 setSpeed 会抛 5400102，所以只记账，
    // 由 prepared 与 playing 两处回调各补一次（见 preparePlayer 的 stateChange）。
    if (this.status !== 'playing' && this.status !== 'paused') {
      return;
    }
    this.applySpeed(player);
  }

  /** 期望的播放速率（1 = 原速） */
  getSpeed(): number {
    return this.speedRate;
  }

  /**
   * 速率 -> 系统枚举
   *
   * AVPlayer.setSpeed 只收 `media.PlaybackSpeed`（不是任意小数），可选档位就是
   * 0.50 / 0.75 / 1.00 / 1.25 / 1.50 / 2.00 这几档（后两档 API 12 起，本工程最低 23）。
   * 传进来的值已经由 BookPlaySettings 夹到这几档，这里再兜一次，宁可回到 1.0x 也不抛错。
   */
  private speedEnumOf(rate: number): media.PlaybackSpeed {
    if (rate <= 0.6) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (rate <= 0.85) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (rate <= 1.1) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (rate <= 1.35) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (rate <= 1.7) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  /** 把期望速率落到播放器上（失败只记日志：设不了就退回原速，别影响出声） */
  private applySpeed(player: media.AVPlayer): void {
    try {
      player.setSpeed(this.speedEnumOf(this.speedRate));
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setSpeed failed, keep default speed: %{public}s',
        JSON.stringify(err));
    }
  }

  /**
   * 「与其他应用同时播放」——两件事，缺一不可
   *
   * 1. AVPlayer 的音频焦点模式（applyInterruptMode）：按 SDK 原文，SHARE_MODE 是
   *    「几条流共用一个中断单元」、INDEPENDENT_MODE 是「每条流各有各的中断单元」——
   *    它管的是**本应用内**几条流之间的关系，跨应用不归它管。
   * 2. 应用级音频会话（applyConcurrency）：只有激活会话、把并发模式声明成
   *    CONCURRENCY_MIX_WITH_OTHERS（「和其他音频并发，即混音」），别的应用才真的
   *    不会把我们按默认焦点策略暂停掉。少了这一步，开关拨成什么样都拦不住抖音。
   *
   * 焦点模式只能在 prepared/playing/paused/completed 态设、且首次 play() 之前设才生效，
   * 所以那一半的生效点是 preparePlayer 的 prepared 回调（见 applyInterruptMode）；
   * 会话那半边不受播放器状态限制，这里也一并走一遍（关开关时要能立刻撤销）。
   */
  setPlayWithOthers(value: boolean): void {
    // 会话是应用级的：关掉开关时哪怕此刻没在播，也得把混音会话撤下来，否则「独占」是假的
    this.applyConcurrency(value);
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

  /**
   * 「与其他应用同时播放」真正生效的那一半：激活音频会话 + 声明与其他应用混音
   *
   * 不激活会话时走系统默认并发策略（CONCURRENCY_DEFAULT）：抖音一出声，系统按焦点策略
   * 把我们的流强制暂停（INTERRUPT_FORCE + INTERRUPT_HINT_PAUSE），界面就停在「已暂停」——
   * 这就是「开着同时播放还是被掐掉」的原因。声明成 CONCURRENCY_MIX_WITH_OTHERS 之后，
   * 两条流各响各的，系统不再因为我们「该让路」而停我们。
   *
   * 会话在「本应用没有音频流在跑」之后会被系统超时回收，所以每次起播（prepared）都要补一次；
   * 用户关掉开关时主动撤销。取管理器/激活失败都不阻断播放：退回系统默认策略，还是能听。
   */
  private applyConcurrency(withOthers: boolean): void {
    const manager: audio.AudioSessionManager | null = this.sessionManagerOf();
    if (manager === null) {
      return;
    }
    try {
      if (!withOthers) {
        if (manager.isAudioSessionActivated()) {
          manager.deactivateAudioSession().catch((err: BusinessError) => {
            hilog.warn(DOMAIN, TAG, 'deactivateAudioSession failed: %{public}s', JSON.stringify(err));
          });
        }
        return;
      }
      if (manager.isAudioSessionActivated()) {
        return;
      }
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS,
      };
      manager.activateAudioSession(strategy).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'activateAudioSession failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'apply audio session failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 音频会话管理器（拿一次存着；环境不支持时只记一次失败，不反复试） */
  private sessionManagerOf(): audio.AudioSessionManager | null {
    if (this.sessionManager !== null) {
      return this.sessionManager;
    }
    if (this.sessionManagerFailed) {
      return null;
    }
    try {
      this.sessionManager = audio.getAudioManager().getSessionManager();
    } catch (err) {
      this.sessionManagerFailed = true;
      hilog.warn(DOMAIN, TAG, 'getSessionManager failed: %{public}s', JSON.stringify(err));
      return null;
    }
    return this.sessionManager;
  }

  /**
   * 音频焦点被打断 / 打断结束
   *
   * 官方《音频焦点介绍》与 FAQ「播放视频时被打断导致播放状态异常」里那两条必须做的事：
   *   1. 收到强制暂停（INTERRUPT_HINT_PAUSE）时，**系统只是把声音停了，AVPlayer 自己的
   *      状态不会跟着变**，应用要主动 pause() 一次把状态对齐 —— 否则界面和播控中心会停在
   *      「正在播放」，恢复时还得连着点两次播放键；
   *   2. 打断结束（INTERRUPT_HINT_RESUME）一定是共享类型，系统不替应用恢复，
   *      要接着放只能应用自己 play() —— 这一条就是「被打断结束后自动重新播放」那个开关。
   *
   * STOP 是彻底失去焦点（之后不会再收到 RESUME），只把标记清掉、不恢复；
   * DUCK / UNDUCK 是「降音量 / 恢复音量」，系统自己就做了，这里不用管。
   */
  private onAudioInterrupt(info: audio.InterruptEvent): void {
    switch (info.hintType) {
      case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
        this.focusPaused = true;
        this.pauseOnInterrupt();
        return;
      case audio.InterruptHint.INTERRUPT_HINT_STOP:
        // 彻底失焦：清掉标记，之后不管什么时机都不「自己响起来」
        this.focusPaused = false;
        this.pauseOnInterrupt();
        return;
      case audio.InterruptHint.INTERRUPT_HINT_RESUME:
        this.resumeAfterInterrupt();
        return;
      default:
        return;
    }
  }

  /** 系统已经把声音停了：把我们的状态也对齐（pause 内部只在 playing 态才真的调） */
  private pauseOnInterrupt(): void {
    if (this.status === 'playing') {
      this.interruptPauseIssued = true;
    }
    this.doPause().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'pause for audio interrupt failed: %{public}s', err.message);
    });
  }

  /**
   * 打断结束：只有「本来就播着、被系统暂停了、开关也开着」才接着放
   *
   * 用户自己按的暂停不会有 RESUME（暂停时焦点已经释放了），所以这里不必再区分；
   * 但打断期间用户可能已经自己按了播放、或切了歌（旧实例已释放）—— 那就不归这里管。
   */
  private resumeAfterInterrupt(): void {
    const interrupted: boolean = this.focusPaused;
    this.focusPaused = false;
    if (!interrupted || !PlaySettings.getInstance().isAutoResumeAfterInterrupt()) {
      return;
    }
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status === 'paused') {
      this.playAfterInterrupt(player);
      return;
    }
    /**
     * 打断短到「RESUME 比那次暂停落地还早」：此刻还停在 playing，而我们发出的
     * pause 正在路上。不把这次恢复记下来，等暂停落地后就再没人叫它播了 ——
     * 表现就是被一声很普通的提示音**永久**停住（群反馈「放着放着就暂停」）。
     * 所以记一笔，等播放器真进 paused 时再补（见 applyPendingResume）。
     */
    if (this.status === 'playing' && this.interruptPauseIssued) {
      this.resumeWhenPaused = true;
    }
  }

  /** 播放器已经进 paused，而打断那时就先结束了：在这里把播放补回来 */
  private applyPendingResume(): void {
    if (!this.resumeWhenPaused) {
      return;
    }
    this.resumeWhenPaused = false;
    const player = this.avPlayer;
    if (player === null) {
      return;
    }
    if (this.status !== 'playing' && this.status !== 'paused') {
      // loading / error / stopped：不是「被打断停下的」那一种，不擅自出声
      return;
    }
    this.playAfterInterrupt(player);
  }

  /** 打断结束后的那一次 play：失败只记日志（下一次用户操作会重新走完整链路） */
  private playAfterInterrupt(player: media.AVPlayer): void {
    if (!PlaySettings.getInstance().isAutoResumeAfterInterrupt()) {
      return;
    }
    player.play().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'resume after audio interrupt failed: %{public}s', JSON.stringify(err));
    });
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
        player.off('bufferingUpdate');
        player.off('error');
        // 音频焦点监听也要解：漏了它，旧实例上的打断回调会一直挂着（虽然有 avPlayer 判等兜住，
        // 但释放后还留一份闭包没有意义，且真机上打断事件比 stateChange 更频繁）
        player.off('audioInterrupt');
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
    this.bufferedEndMs = 0;
    this.loadedEndMs = 0;
    this.loadedProbeAt = 0;
    this.lastProgressAt = 0;
    // 待执行的「拔耳机延迟复核」属于旧现场：换实例后不能让它把新的一集停掉
    if (this.headsetRecheckTimer >= 0) {
      clearTimeout(this.headsetRecheckTimer);
      this.headsetRecheckTimer = -1;
    }
    // 打断的现场也跟着实例走：旧实例上的「等 paused 就恢复」不能留到新实例上
    this.focusPaused = false;
    this.interruptPauseIssued = false;
    this.resumeWhenPaused = false;
    // 释放不经过 stateChange：在这里把缓冲状态收掉，界面才不会一直转圈
    this.updateBuffer(false, 0);
  }
}
