import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaybackService } from './PlaybackService';
import { PlaySettings } from '../settings/PlaySettings';
import { StartupTiming } from './StartupTiming';
import { AudioEffectProcessor, EqStreamSession } from './AudioEffectProcessor';
import { K_EQ_ACTIVE, AudioEffectSettings } from '../settings/AudioEffectSettings';

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
  /**
   * 音效预处理代次：每次 preparePlayer（切歌/重播）自增。
   * EQ 预处理是异步的（下载+解码+处理，几秒），期间用户可能已经切歌；
   * 预处理回来后比对代次，不一致就丢弃结果，绝不把旧歌的 WAV 顶到新歌上。
   */
  private eqGeneration: number = 0;
  /**
   * preparePlayer 的串行锁。
   *
   * 换实例这段有「释放旧实例 → 建新实例」的读改写，中间还会 await。真机上确实出现过
   * 两条链路同时进来：`error` 回调里的回退、以及用户/自动切歌，于是 A 释放了 B 刚建好的
   * 实例，或者 A 把 B 的 avPlayer 直接覆盖掉 —— 表现是一瞬间三个 player 实例同时 dtor，
   * 紧接着就是回调引用的野指针崩溃（见 release/macrotask 的注释）。
   * 这里用一条 Promise 链把它们排队，保证同一时刻只有一条在换实例。
   */
  private prepareLock: Promise<void> = Promise.resolve();
  /**
   * 播放代次：每趟「新的播放意图」（playUrl / playUrlWithHeaders / playLocal / release）自增。
   *
   * 与 eqGeneration 分工不同：
   * - eqGeneration 只在 preparePlayer 建新实例时自增，用来丢弃过期的 EQ 产物；
   * - playEpoch 在意图发生的那一刻就自增，用来判断「这趟异步播放是否已经被切走」。
   *   release 不建实例、也不会让 eqGeneration 变化 —— 少了它，快速切歌时旧歌的 playUrl
   *   在 EQ 预处理被取消后会继续回退原声，把上一首播出来（见 playUrl 里的判断）。
   */
  private playEpoch: number = 0;
  /**
   * 这一趟建实例只是「为了让拖动生效」（见 seek / deferSeekUntilProcessed），
   * prepared 之后不要自动出声。由 prepared 回调消费后清掉。
   */
  private pauseAfterPrepare: boolean = false;
  /** 播放本地缓存文件时打开的句柄：release 时一定要关掉，否则 fd 会泄漏 */
  private fdHandle: fs.File | null = null;
  /**
   * 音效流式播放现场：EQ 边处理边写 WAV，播放器边读这个还在变长的文件。
   * 非 null 表示当前这趟播放走的是「边处理边播」。
   */
  private eqStreamSession: EqStreamSession | null = null;
  /**
   * 当前播放现场正在用的 EQ 临时产物路径（空表示这一趟没走音效）。
   * 产物是一次性的：release 时连同播放器一起收掉（见 release）。
   */
  private eqTempPath: string = '';
  private eqStreamFile: fs.File | null = null;
  /** 流式读取位置（fileSize=-1 模式下播放器不传 pos，只能自己顺序记） */
  private eqStreamPos: number = 0;
  /** 流式播放失败时要退回的原始音源（网络地址） */
  private eqRawUrl: string = '';
  private eqRawHeaders: Record<string, string> = {};
  /**
   * 流式播放失败时要退回的原始本地文件路径。
   *
   * 网络路径靠 eqRawUrl 回退；本地 / 已下载 / 沙箱缓存的歌走 playLocal，没有 URL，
   * 以前 EQ 流中途失败时这里是空的 —— 明明原文件完全能播，却只会报「播放错误」，
   * 还会被外层当成缓存坏了去删缓存（见 onError）。
   */
  private eqRawPath: string = '';
  /**
   * EQ 预处理失败是因为「这个网络地址打不开」（而不是格式不支持 / 取消）。
   *
   * 真机实测（2026-11-27）：地址缓存里的旧链接可能已失效，EQ 的 Native 解封装一拉就失败，
   * 而播放器换原声去拉同一条旧链同样失败，要等上层发现「播放器报错」才丢缓存重新解析 ——
   * 中间会误弹一次「这首暂时没能应用音效」，且多绕一圈。这里把它单独标出来，交给
   * PlaySession 立刻丢弃地址缓存、重新解析后再试一次（见 playUrl 与 PlaySession.playAt）。
   */
  private eqUrlUnopenable: boolean = false;
  /**
   * 这一趟播放有没有**真的**过上音效。
   *
   * 与「音效开关开着」不是一回事：开关开着但预处理失败（格式不被系统解码器支持、
   * 带请求头的长音频没在预缓冲窗口内下完…）时，我们会回退成原声播放 —— 这时声音里
   * 没有任何 EQ。这个标志同步到 AppStorage（K_EQ_ACTIVE），播放页的标识据此显示
   * 「已生效 / 未生效」，用户不必靠听感猜。
   */
  private eqApplied: boolean = false;
  /** 「本该加音效却没加上」每趟播放只提醒一次（否则一张坏格式的歌单会一直弹） */
  private eqSkipNotified: boolean = false;
  /** 外层挂上来的提示回调（PlaySession 负责变成一句 toast） */
  onEqSkipped: (reason: string) => void = () => {};
  /**
   * 当前播放器正在用的 MediaSource，**必须由我们持有引用**。
   *
   * 这是真机崩溃的根因：`media.createMediaSourceWithDataSource()` 建出来的对象如果只是
   * 一个局部变量，playXxx() 返回后它就没有强引用了，ArkTS 的 GC 会把它回收 →
   * 原生侧 `MediaSourceNapi` 析构 → 而 AVPlayer 还在用它读数据（数据源回调就挂在
   * 这个对象上，回调的 napi 引用跟着一起没了）。
   * 于是：先看到 `MediaDataSourceCallback: timeout 100ms`，紧接着
   * `SIGSEGV(SEGV_MAPERR)@0x6b6b...`，栈顶 `libmedia_avplayer -> napi_get_reference_value`。
   *
   * 真机日志实证：两次 `MediaSourceNapi Constructor success` 之后，在播放正常进行时
   * 突然来两条 `Destructor success`（就是 GC 收掉了没人引用的源），0.5s 后崩溃。
   * 所以这里把引用一直留到 release() 里、播放器释放之后才清。
   */
  private mediaSource: media.MediaSource | null = null;
  /** 换源后要落到的位置（-1 表示不跳）：从流式播放切回文件播放时用 */
  private pendingSeekMs: number = -1;
  /**
   * 「下一次起播」要落到的位置（-1 = 从头）
   *
   * 音效改动后的重播用它：整首重新烘一遍要几秒，而顺序数据源不能定位，
   * 所以要么等 WAV 落全再起播（保住用户的位置），要么退回从头流式起播。
   * 由 PlaySession 在重播前置好（见 replayForEq），一次性消费 —— 绝不泄漏到下一首。
   */
  private startSeekMs: number = -1;
  /**
   * startSeekMs 的设置时刻
   *
   * 兜底：万一设置之后这一趟起播根本没走到 playXxx（解析失败、用户立刻切走），
   * 这个值不能被下一个人（用户后来点的其它歌）消费掉 —— 否则会莫名其妙跳到中间。
   * 超过 30 秒就当它作废。
   */
  private startSeekAt: number = 0;
  /**
   * 这一趟起播是否已经用 pendingSeekMs **精确**落过位置
   *
   * EQ 续播走的正是这条路（等整首落全 → 普通 fd 播放 → prepared 态 seek）。
   * 而 PlaySession 的 applyResumeSeek 还会按秒级位置再跳一次，那会把已经落好的
   * 精确位置往回拉最多 1 秒（听得出来的一次小回跳）。用它去重。
   */
  private startSeekApplied: boolean = false;
  /**
   * 「处理中拖动」的守候定时器。
   *
   * 边处理边播的数据源**还在变长**（Native 边解码边写 WAV），不能定位：能读到的位置
   * 随时在变，硬 seek 只会拿到不完整/错位的数据。用户此时拖进度条不能当没看见：
   * 记下目标位置，等整首处理完（WAV 落完）自动切回普通文件播放并跳过去。
   * -1 = 没在等。
   */
  private eqSeekTimer: number = -1;
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

  /**
   * 指定「下一次起播」落到的位置（ms，<=0 表示从头）
   *
   * 只给音效改动后的重播用（见 PlaySession.replayForEq）：在 playAt 之前调用，
   * 由接下来那次 playXxx 消费掉。消费即清空，不会带到后面的歌。
   */
  setStartSeekMs(ms: number): void {
    this.startSeekMs = ms > 0 ? ms : -1;
    this.startSeekAt = Date.now();
  }

  /** 取走一次性落点（消费后清空；超过 30 秒视为过期，见 startSeekAt） */
  private takeStartSeekMs(): number {
    const ms: number = this.startSeekMs;
    const fresh: boolean = ms > 0 && Date.now() - this.startSeekAt < 30000;
    this.startSeekMs = -1;
    return fresh ? ms : -1;
  }

  /** 这一趟起播是否已经精确落过位置（见 startSeekApplied） */
  wasStartSeekApplied(): boolean {
    return this.startSeekApplied;
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

  /** 停止「等处理完再跳」的守候（切歌 / 释放 / 已经跳过去都要停） */
  private clearEqSeekTimer(): void {
    if (this.eqSeekTimer >= 0) {
      clearInterval(this.eqSeekTimer);
      this.eqSeekTimer = -1;
    }
  }

  /**
   * 处理中拖了进度条：记下目标，等 WAV 写完再切回文件播放跳过去。
   *
   * 为什么不能立刻跳：这一趟的数据源是按「总长未知」声明的（见 playEqStream），
   * 播放器在这个模式下根本不支持定位 —— 硬跳只会被丢掉，用户看到的就是「拖了没反应」。
   */
  private deferSeekUntilProcessed(targetMs: number): void {
    this.pendingSeekMs = targetMs;
    if (this.eqSeekTimer >= 0) {
      return;
    }
    this.eqSeekTimer = setInterval(() => {
      const session = this.eqStreamSession;
      if (session === null || this.avPlayer === null) {
        this.clearEqSeekTimer();
        return;
      }
      if (!session.isDone()) {
        return;
      }
      this.clearEqSeekTimer();
      // 写完了：换成普通 fd 播放，pendingSeekMs 会在 prepared 态落地。
      // 用户若是暂停着拖的，这次切换只为拿回定位能力，不能顺手出声（见 prepared）
      this.pauseAfterPrepare = this.status === 'paused';
      hilog.info(DOMAIN, TAG, 'eq done while seek pending: switch to file playback');
      void this.playLocal(session.wavPath, false);
    }, 400);
  }

  /**
   * 记下这一趟到底有没有过上音效（同步到 AppStorage，供播放页标识显示）
   *
   * 只写「真的变了」的那一次：AppStorage 的写入会触发 UI 刷新，每首歌都无脑写一遍
   * 会让播放页在起播阶段多刷几次，没必要。
   */
  private markEqApplied(applied: boolean): void {
    if (this.eqApplied === applied) {
      return;
    }
    this.eqApplied = applied;
    AppStorage.setOrCreate(K_EQ_ACTIVE, applied);
    // 这一趟真的带着音效：推子上那套值就算已经生效了，清掉「待应用」记号
    if (applied) {
      AudioEffectSettings.getInstance().markApplied();
    }
  }

  /**
   * 本该加音效、结果没加成（回退原声）时记一笔
   *
   * 这里只负责「每趟播放提醒一次」，提示文案由外层给（它才知道当前是哪首歌）。
   * 音效没开 / 增益全 0 不走这里 —— 那不是失败，是用户就没要音效。
   */
  private noteEqSkipped(reason: string): void {
    if (this.eqSkipNotified) {
      return;
    }
    // 用户本来就没要音效（开关关着 / 增益全 0 的「原声」）：不是失败，不必打扰
    if (!AudioEffectSettings.getInstance().shouldProcess()) {
      return;
    }
    this.eqSkipNotified = true;
    hilog.warn(DOMAIN, TAG, 'eq skipped this playback: %{public}s', reason);
    try {
      this.onEqSkipped(reason);
    } catch (e) {
      // 提示失败绝不能影响播放
    }
  }

  /**
   * 音效流式会话：开着音效时启动 EQ 处理，等到「够播」就把会话交出来。
   *
   * 返回 null 表示这次不走 EQ（没开 / 增益全 0 / 失败），调用方照旧用原始 URL 播。
   * 注意这里**不等整首处理完**：processor 攒够约 3 秒数据就返回，之后边播边处理 ——
   * 这是把「等整首下载+处理」压到「等几秒」的关键。
   *
   * @param resumeMs >0 时把落点交给 processor：它会额外等整首落全（有上限），
   *   这样返回的会话一定是 done 的，调用方可以用普通 fd 播放直接定位过去。
   */
  private async eqSessionOf(url: string, headers: Record<string, string>,
    resumeMs: number = 0): Promise<EqStreamSession | null> {
    const gen: number = this.eqGeneration;
    try {
      const session: EqStreamSession | null =
        await AudioEffectProcessor.getInstance().startStream(url, headers, resumeMs);
      if (this.eqGeneration !== gen) {
        // 切歌了：这次处理的结果不要了（processor 内部也会 cancel 掉 Native 任务）
        return null;
      }
      return session;
    } catch (e) {
      const msg: string = (e as Error).message;
      // 切歌取消不是「失败」：不要把它当回退理由，也不要弹「没能应用音效」——
      // 真正该做的是让调用方看到代次已变、安静退出（见 playUrl 的代次校验）。
      if (msg.indexOf('cancelled') >= 0 || msg.indexOf('canceled') >= 0) {
        return null;
      }
      /**
       * 网络地址打不开：多半是地址缓存里的旧链已经失效（网易 CDN 的链接寿命有限）。
       * 标出来交给调用方「丢缓存 + 重新解析」，这里不提示、也不当作「音效坏了」。
       */
      if (msg.indexOf('无法打开网络音频地址') >= 0) {
        this.eqUrlUnopenable = true;
        hilog.warn(DOMAIN, TAG, 'eq cannot open this url, ask caller to refresh: %{public}s', msg);
        return null;
      }
      hilog.warn(DOMAIN, TAG, 'eq preprocess failed, fallback to raw url: %{public}s', JSON.stringify(e));
      this.noteEqSkipped(`预处理失败：${msg}`);
      return null;
    }
  }

  /**
   * 用「还在变长的 WAV」起播。
   *
   * AVPlayer 的自定义数据源（AVDataSrcDescriptor）正是为这种场景设计的：
   * fileSize 给 WAV 头里声明的总长（>0 = 可定位模式，回调会带绝对 pos，见下方注释）；
   * 传 -1（总长未知）反而会让播放器自己估时长，踩过「186 秒的歌估成 54 秒、播到一半没声」的坑。
   * 但文件**还在变长**，所以流式期间我们主动不 seek；
   * 整首落盘后（session.isDone()）才切成普通 fd 播放，那时才恢复拖动能力。
   */
  private async playEqStream(session: EqStreamSession): Promise<void> {
    // 换了播放现场：上一轮「等处理完再跳」的守候作废
    this.clearEqSeekTimer();
    const epoch: number = this.playEpoch;
    const player: media.AVPlayer = await this.preparePlayer(true);
    // 建实例期间用户切歌了：这趟 EQ 流不要再往新实例上挂
    if (this.playEpoch !== epoch) {
      return;
    }
    StartupTiming.getInstance().armWatchdog();
    // preparePlayer 已经释放了上一个现场，现在登记这一份临时产物（release 时删掉它）
    this.eqTempPath = AudioEffectProcessor.getInstance().isArtifact(session.wavPath) ? session.wavPath : '';
    const file: fs.File = fs.openSync(session.wavPath, fs.OpenMode.READ_ONLY);
    this.eqStreamFile = file;
    this.eqStreamSession = session;
    this.eqStreamPos = 0;
    const fd: number = file.fd;
    /**
     * 总长度必须告诉播放器，不能传 -1。
     *
     * 踩过的坑：`fileSize = -1`（总长未知）时播放器会按「已收到的字节 + 码率」自己估一个时长，
     * 而且估出来就不改了。实测一首 186 秒的本地 FLAC 被估成 54 秒，**播到 54 秒就没声了**
     * （既不继续读、也不报完成，进度条死在 54 秒）。
     *
     * WAV 头里本来就按容器时长声明了 data 长度（见 native 的 writeWavHeader），
     * 直接把它读出来当 fileSize 交给播放器：时长、进度条、拖动都跟着正确。
     * 数据比声明的短（容器时长偏大）时读到头返回 -1，播放器照常收尾；长一点也不会少播。
     */
    const declaredBytes: number = LxPlayer.declaredWavBytes(fd);
    const descriptor: media.AVDataSrcDescriptor = {
      fileSize: declaredBytes > 0 ? declaredBytes : -1,
      /**
       * fileSize >= 0 = **可定位模式**（SDK 原文：fileSize=-1 时 seek / setSpeed / loop / replay
       * 都不可用）。这个模式下播放器按**绝对流位置**要数据，第三个参数 pos 就是它要的起点
       * （OpenHarmony 6.1 player_framework 的 media_data_source_callback.cpp：可定位模式传 3 个参数）。
       *
       * 所以必须尊重 pos：我们流式期间本来就不主动 seek（见 seek：拖进度先等写完再切普通 fd 播放），
       * 正常顺序读时 pos 恒等于 eqStreamPos，行为不变；但播放器一旦自己回退/重读（缓冲回退、
       * 未来的 loop/replay），用自记位置会**静默**返回错位数据（杂音 / 解析异常，还不报错）。
       */
      callback: (buffer: ArrayBuffer, length: number, pos?: number): number => {
        const want: number = Math.min(length, buffer.byteLength);
        // pos 是文件内绝对位置；没传（总长未知那种模式）才退回首记的读取位置
        const base: number = pos !== undefined && pos >= 0 ? pos : this.eqStreamPos;
        let got: number = 0;
        try {
          got = fs.readSync(fd, buffer, { offset: base, length: want });
        } catch (e) {
          got = 0;
        }
        if (got > 0) {
          this.eqStreamPos = base + got;
          return got;
        }
        if (session.isFailed()) {
          hilog.warn(DOMAIN, TAG, 'eq stream failed while playing: %{public}s', session.error());
          return -2;
        }
        if (session.isDone()) {
          return -1;   // 整首已写完，读到末尾
        }
        // 处理进度一时跟不上播放：报错让上层回退原始音源，好过卡住没声音
        hilog.warn(DOMAIN, TAG, 'eq stream starved at %{public}d bytes', this.eqStreamPos);
        return -2;
      },
    };
    const source: media.MediaSource | undefined = media.createMediaSourceWithDataSource(descriptor);
    if (source === undefined) {
      throw new Error('create eq data source failed');
    }
    // 必须持有引用，否则会被 GC 回收掉，播放中途数据源就断了（见 mediaSource 字段注释）
    this.mediaSource = source;
    await player.setMediaSource(source, this.playbackStrategy());
    // 走到这里 = 这一趟听到的确实是过了 EQ 的 WAV
    this.markEqApplied(true);
  }

  /**
   * 读 WAV 头里声明的总字节数（RIFF 的 data chunk 长度 + 44 字节头）。
   *
   * 读不出来就返回 0，调用方退回「总长未知」的老行为（至少不会因为解析失败放不出来）。
   * 偏移 40 是 WAV 规范里 data chunk 的尺寸字段（RIFF/WAVE/fmt(16)/data 的标准布局）。
   *
   * 关于 `fs.readSync` 的 offset：它是**文件内绝对偏移**（底层走 pread，filePointer 不动），
   * 不是「当前 filePointer + offset」。SDK 的 ReadOptions 接口注释里那句 "current filePointer
   * plus offset" 是文档 bug（那句语义属于 RandomAccessFile.readSync），**不要按它改代码** ——
   * 改了就真的会跳读。这里先按 offset=0 读头、随后 playEqStream 再按 offset=eqStreamPos 顺序读，
   * 两者互不影响。
   */
  private static declaredWavBytes(fd: number): number {
    try {
      const head: ArrayBuffer = new ArrayBuffer(44);
      const read: number = fs.readSync(fd, head, { offset: 0, length: 44 });
      if (read < 44) {
        return 0;
      }
      const view: DataView = new DataView(head);
      const riffSize: number = view.getUint32(4, true);
      const dataSize: number = view.getUint32(40, true);
      const total: number = 44 + dataSize;
      // 头得自洽：RIFF 段长度（不含前 8 字节）应覆盖整个文件，否则说明这不是我们的头
      if (dataSize <= 0 || riffSize + 8 < total) {
        return 0;
      }
      return total;
    } catch (e) {
      return 0;
    }
  }

  /** 原始音源播放（不走 EQ）；流式播放失败时的回退路径也用它 */
  private async playRawUrl(url: string, headers: Record<string, string>): Promise<void> {
    const epoch: number = this.playEpoch;
    const player: media.AVPlayer = await this.preparePlayer();
    // 建实例期间用户切歌了：别再给新实例设旧歌的 url（否则会把新歌顶掉）
    if (this.playEpoch !== epoch) {
      return;
    }
    // 原声路径：这一趟没有 EQ（可能是没开音效，也可能是回退过来的）
    this.markEqApplied(false);
    StartupTiming.getInstance().armWatchdog();
    if (Object.keys(headers).length === 0) {
      player.url = url;
      return;
    }
    try {
      const source: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
      // 同 playEqStream：源对象要一直持有，不能只做局部变量（见 mediaSource 字段注释）
      this.mediaSource = source;
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
   * 预处理之后、真正起播之前再看一眼代次。
   *
   * 为什么必须有这一步：EQ 预处理要几秒，期间用户可能已经切了歌 —— 新歌的 playUrl
   * 会 preparePlayer（generation++）把旧实例释放掉。旧歌的 await 这时才回来，若不加这道闸，
   * 它会继续 preparePlayer + 设 url，把刚起的新歌顶掉。切歌了就整个放弃这次 playUrl。
   */
  private eqWasSuperseded(gen: number): boolean {
    return this.eqGeneration !== gen;
  }

  /** 播放一个网络音频地址（先释放上一个实例） */
  async playUrl(url: string): Promise<void> {
    const gen: number = this.eqGeneration;
    const epoch: number = ++this.playEpoch;
    this.eqUrlUnopenable = false;
    this.eqSkipNotified = false;
    this.eqRawUrl = url;
    this.eqRawHeaders = {};
    this.eqRawPath = '';
    this.pendingSeekMs = -1;
    // 音效改动后的重播会带一个落点（见 setStartSeekMs）：消费掉，只影响这一趟
    const startMs: number = this.takeStartSeekMs();
    const session: EqStreamSession | null = await this.eqSessionOf(url, {}, Math.max(0, startMs));
    /**
     * 预处理期间用户切走了就整个放弃 —— 包括**不要回退原声**。
     *
     * eqWasSuperseded 只看「有没有建过新实例」；而切歌的第一步是 release()（不建实例），
     * 新歌可能还要几百毫秒到几秒解析地址，这段空窗里旧的 playUrl 回来时会误以为没人取代它，
     * 于是回退 playRawUrl 把上一首播出来（队列显示新歌、耳朵听到旧歌）。
     * playEpoch 在 release / 新播放意图发生时立刻自增，这里一并校验。
     */
    if (this.eqWasSuperseded(gen) || this.playEpoch !== epoch) {
      return;
    }
    if (session !== null) {
      try {
        if (session.isDone()) {
          // 整首已就绪：走普通 fd 播放，进度条拖动可用。这里播的是 EQ 产物本身，
          // 必须传 false，否则会拿 WAV 再去编码一次。
          if (startMs > 0) {
            this.pendingSeekMs = startMs;
          }
          await this.playLocal(session.wavPath, false);
          return;
        }
        await this.playEqStream(session);
        return;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'eq stream start failed, fallback to raw url: %{public}s',
          JSON.stringify(e));
        this.noteEqSkipped(`音效起播失败：${(e as Error).message}`);
      }
    }
    /**
     * 这一趟 EQ 预处理失败的原因是「地址打不开」：不要拿同一条地址回退原声
     * （播放器接下来照样会失败，还会先误弹一次「未生效」）。
     * 往上抛一个可识别的信号，让 PlaySession 丢地址缓存、重新解析后再来一次。
     */
    if (this.eqUrlUnopenable) {
      this.eqUrlUnopenable = false;
      throw new Error('EQ_DEAD_URL');
    }
    await this.playRawUrl(url, {});
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
    const gen: number = this.eqGeneration;
    const epoch: number = ++this.playEpoch;
    this.eqUrlUnopenable = false;
    this.eqSkipNotified = false;
    this.eqRawUrl = url;
    this.eqRawHeaders = headers;
    this.eqRawPath = '';
    this.pendingSeekMs = -1;
    const startMs: number = this.takeStartSeekMs();
    const session: EqStreamSession | null = await this.eqSessionOf(url, headers, Math.max(0, startMs));
    // 与 playUrl 同一道闸：被取代的这趟连回退原声都不做（否则会播出上一首）
    if (this.eqWasSuperseded(gen) || this.playEpoch !== epoch) {
      return;
    }
    if (session !== null) {
      try {
        if (session.isDone()) {
          if (startMs > 0) {
            this.pendingSeekMs = startMs;
          }
          await this.playLocal(session.wavPath, false);
          return;
        }
        await this.playEqStream(session);
        return;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'eq stream start failed, fallback to raw url: %{public}s',
          JSON.stringify(e));
        this.noteEqSkipped(`音效起播失败：${(e as Error).message}`);
      }
    }
    if (this.eqUrlUnopenable) {
      this.eqUrlUnopenable = false;
      throw new Error('EQ_DEAD_URL');
    }
    await this.playRawUrl(url, headers);
  }

  /**
   * 按原声播放一个网络地址，**完全跳过音效**
   *
   * 场景：EQ 预处理打不开这条地址（多半是旧链失效），丢缓存重新解析后仍然打不开。
   * 这时不能再让 EQ 拦一道 —— 直接交给播放器按原声拉，能出声就行（与改动前一致）。
   */
  async playUrlNoEq(url: string): Promise<void> {
    this.eqSkipNotified = false;
    this.eqRawUrl = url;
    this.eqRawHeaders = {};
    this.eqRawPath = '';
    await this.playRawUrl(url, {});
  }

  /**
   * 播放本地音频（AudioCache 下好的整首 / WebDAV 缓存 / 导入的本地音乐）
   *
   * @param path 沙箱绝对路径，或 Picker 给的 `file://docs/...` URI（两者都能吃 EQ）
   * @param applyEffect 是否允许走音效。默认 true —— 开着音效时，本地缓存与在线流一样吃 EQ，
   *   不然会出现「没听过的歌有音效、听过的歌反而没有」这种别扭的落差。
   *   内部播放 EQ 产物本身时必须传 false（否则会拿 WAV 再去编码一次）。
   *
   * 原文件全程只读：处理侧按只读方式打开（URI 由本侧 `fs.openSync` 打开后传 fd 给 Native），
   * 产物写到另一个临时 WAV，所以不会改动原文件，也不会碰 AudioCache 的缓存
   * （见 AudioEffectProcessor 类注释）。
   */
  async playLocal(path: string, applyEffect: boolean = true): Promise<void> {
    const epoch: number = ++this.playEpoch;
    if (applyEffect) {
      // 新的播放意图：上一次「拖动后保持暂停」的待办作废（见 pauseAfterPrepare）
      this.pauseAfterPrepare = false;
    }
    if (applyEffect && LxPlayer.canApplyEffect(path)) {
      const gen: number = this.eqGeneration;
      this.eqSkipNotified = false;
      this.eqRawUrl = '';
      this.eqRawHeaders = {};
      // 本地路径也要记下来：EQ 流中途失败时要能退回原文件（见 onError）
      this.eqRawPath = path;
      this.pendingSeekMs = -1;
      const startMs: number = this.takeStartSeekMs();
      const session: EqStreamSession | null =
        await this.eqSessionOfFile(path, Math.max(0, startMs));
      // 被取代就放弃，连回退原文件都不做（否则会把切走的那首重新放出来）
      if (this.eqWasSuperseded(gen) || this.playEpoch !== epoch) {
        return;
      }
      if (session !== null) {
        try {
          if (session.isDone()) {
            // 整首已就绪（含「续播」等完的那一趟）：普通 fd 播放，可定位
            if (startMs > 0) {
              this.pendingSeekMs = startMs;
            }
            await this.playLocalFile(session.wavPath);
            return;
          }
          await this.playEqStream(session);
          return;
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'eq on local file failed, fallback to raw file: %{public}s',
            JSON.stringify(e));
          this.noteEqSkipped(`本地文件音效起播失败：${(e as Error).message}`);
        }
      }
    }
    await this.playLocalFile(path);
  }

  /**
   * 能不能给这个路径加音效。
   *
   * 现在沙箱路径和 Picker 给的 `file://docs/...` URI 都能走：处理侧由 ArkTS 用
   * `fs.openSync` 打开、把 fd 交给 Native（见 AudioEffectProcessor.processLocal），
   * 与播放器读文件是同一条授权通道，所以 URI 的原文件也能读。
   */
  private static canApplyEffect(path: string): boolean {
    return path.length > 0;
  }

  /** 纯文件播放：不经过任何音效处理（内部播放 EQ 产物也走这里） */
  private async playLocalFile(path: string): Promise<void> {
    /**
     * 这一趟要播的可能就是**上一趟的 EQ 产物本身**（边处理边播完、用户拖动进度条时
     * 切回普通文件播放，见 seek / deferSeekUntilProcessed）。
     *
     * 坑在这里：preparePlayer 会先 release 上一个现场，而 release 会顺手删掉它登记的
     * 那份临时产物（eqTempPath）—— 要播的文件正好就是它。删完再 openSync 就是
     * ENOENT，表现成「一拖进度条歌就没了」。所以先把它从登记里摘出来（release 就
     * 不会清它），拿到新实例之后再登记回去（下一次 release 才由它负责删）。
     */
    const artifact: boolean = AudioEffectProcessor.getInstance().isArtifact(path);
    const stale: string = artifact ? this.eqTempPath : '';
    if (artifact) {
      this.eqTempPath = '';
    }
    let player: media.AVPlayer;
    try {
      player = await this.preparePlayer();
    } catch (err) {
      // 新实例没建起来：把登记还原，别让这份产物变成没人管的孤儿
      this.eqTempPath = stale;
      throw err as Error;
    }
    if (stale.length > 0 && stale !== path) {
      // 上一份产物和这一份不是同一个文件：新现场已经起来了，旧的那份现在才真没用
      AudioEffectProcessor.getInstance().discardArtifact(stale);
    }
    this.eqTempPath = artifact ? path : '';
    this.markEqApplied(artifact);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    this.fdHandle = file;
    const source: media.AVFileDescriptor = { fd: file.fd };
    player.fdSrc = source;
  }

  /** 本地文件走一次 EQ（失败返回 null，调用方回退原文件） */
  private async eqSessionOfFile(path: string, resumeMs: number = 0): Promise<EqStreamSession | null> {
    try {
      return await AudioEffectProcessor.getInstance().startStreamForFile(path, resumeMs);
    } catch (e) {
      const msg: string = (e as Error).message;
      // 同 eqSessionOf：切歌取消不是失败，安静返回
      if (msg.indexOf('cancelled') >= 0 || msg.indexOf('canceled') >= 0) {
        return null;
      }
      hilog.warn(DOMAIN, TAG, 'eq on local file failed: %{public}s', JSON.stringify(e));
      this.noteEqSkipped(`本地文件音效处理失败：${msg}`);
      return null;
    }
  }

  /** 建实例、挂监听（排队入口：保证同一时刻只有一条链路在换实例，见 prepareLock） */
  private async preparePlayer(keepEqTask: boolean = false): Promise<media.AVPlayer> {
    const prev: Promise<void> = this.prepareLock;
    let unlock: () => void = () => {};
    this.prepareLock = new Promise<void>((resolve: () => void) => {
      unlock = resolve;
    });
    await prev;
    try {
      return await this.preparePlayerUnlocked(keepEqTask);
    } finally {
      unlock();
    }
  }

  /** 建实例、挂监听；url / fdSrc 由调用方在这一步之后设置 */
  private async preparePlayerUnlocked(keepEqTask: boolean = false): Promise<media.AVPlayer> {
    // 新的一首：作废之前所有在途的 EQ 预处理结果（切歌保护）
    this.eqGeneration++;
    // 切到本地文件 / 无 EQ 的源时，也要把上一首在途的 EQ 任务取消掉，
    // 否则它会白白下载+解码完一整首，还可能往缓存里写没人要的 WAV。
    // 走流式播放时这趟任务正是我们要用的，不能取消（keepEqTask）。
    if (!keepEqTask) {
      AudioEffectProcessor.getInstance().cancelActive();
    }
    // 已经在 prepareLock 里（见 preparePlayer），直接走无锁实现，避免死锁。
    // 代次沿用当前值：这里不是「新的播放意图」，不能顶掉调用方捕获的代次。
    await this.releaseUnlocked(keepEqTask, this.playEpoch);
    this.update('loading', '正在加载音频…');
    this.durationMs = 0;
    this.currentMs = 0;
    // 新实例：位置还没落过（见 startSeekApplied）
    this.startSeekApplied = false;
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
          // 换源前的拖动位置（流式 -> 文件播放时补上，不然会从头开始）
          if (this.pendingSeekMs >= 0) {
            const targetMs: number = this.pendingSeekMs;
            this.pendingSeekMs = -1;
            try {
              hilog.info(DOMAIN, TAG, 'pending seek applied: %{public}dms', targetMs);
              player.seek(targetMs);
              this.startSeekApplied = true;
            } catch (err) {
              hilog.warn(DOMAIN, TAG, 'pending seek failed: %{public}s', JSON.stringify(err));
            }
          }
          /**
           * 这次建实例可能只是「为了让拖动生效」（见 seek / deferSeekUntilProcessed）。
           * 用户是在暂停态拖的，切完必须还是暂停 —— 无条件 play() 会让音乐自己响起来。
           */
          const keepPaused: boolean = this.pauseAfterPrepare;
          this.pauseAfterPrepare = false;
          if (keepPaused) {
            this.update('paused', '已暂停');
          } else {
            player.play().catch((err: BusinessError) => {
              this.update('error', `播放失败：${err.message}`);
            });
          }
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
      // 边处理边播这一趟失败（数据源跟不上 / 解码报错）：立刻退回原始音源，
      // 用户至少能听到没加音效的声音，而不是看着一条错误提示。
      // 本地 / 已下载 / 缓存文件没有 URL，退回的是 playLocal 记下的原始路径（eqRawPath）。
      const session = this.eqStreamSession;
      if (session !== null && (this.eqRawUrl !== '' || this.eqRawPath !== '')) {
        const rawUrl: string = this.eqRawUrl;
        const rawHeaders: Record<string, string> = this.eqRawHeaders;
        const rawPath: string = this.eqRawPath;
        this.eqStreamSession = null;
        hilog.warn(DOMAIN, TAG, 'eq stream playback failed, fallback to raw source');
        // 中途回退：标成「未生效」，别让标识还挂着「已生效」
        this.markEqApplied(false);
        this.noteEqSkipped('音效流播放中断');
        // 放到下一个宏任务再回退：这条链路会一路走到 release()/新建播放器，
        // 此刻我们还在这个播放器自己的 error 回调里（见 release 的 macrotask 注释）。
        setTimeout(() => {
          if (rawPath.length > 0) {
            // 本地文件：原文件完全可播，直接退回它（不要再报错、也别让外层删缓存）
            void this.playLocalFile(rawPath);
          } else {
            void this.playRawUrl(rawUrl, rawHeaders);
          }
        }, 0);
        return;
      }
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
    // 边处理边播这一趟的数据源**还在变长**，不能定位（不是「总长未知」——fileSize 是知道的，
    // 见 playEqStream 的注释）。整首已经处理完的话，正好借这次拖动切回普通 fd 播放，把定位能力拿回来。
    const session = this.eqStreamSession;
    if (session !== null) {
      if (session.isDone()) {
        hilog.info(DOMAIN, TAG, 'seek on finished eq stream: switch to file playback');
        // 暂停着拖进度条：切回文件播放只是为了拿到定位能力，切完必须还是暂停
        this.pauseAfterPrepare = this.status === 'paused';
        this.pendingSeekMs = target;
        void this.playLocal(session.wavPath, false);
      } else {
        // 还在处理：数据源还在变长、不能定位（不是总长未知），先记下来，写完后自动跳过去
        hilog.info(DOMAIN, TAG, 'seek deferred until eq processing done (%{public}dms)', target);
        this.deferSeekUntilProcessed(target);
      }
      return;
    }
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

  /**
   * 让出到**新的宏任务**（setTimeout 0），确保调用栈已经脱离 AVPlayer 的原生帧。
   *
   * 为什么非跳不可：本类的 release() 几乎总是从 AVPlayer 自己的回调里一路 await 进来的
   * —— `error` 回调里回退原始音源、`completed` 回调里切下一首，都走这条路。
   * `await` 只是微任务，原生侧 `napi_call_function` 的那一帧还压在栈上没返回；
   * 此刻执行 `off()` / `release()` 会把**正在被使用的那个回调引用**删掉，
   * 原生回调返回时再按引用取值就是野指针。
   *
   * 真机表现（已用 faultlog 确认）：SIGSEGV(SEGV_MAPERR) @ 0x006b6b...（堆释放填充值），
   * 栈顶是 libmedia_avplayer -> napi_call_function / napi_get_reference_value。
   * 换一个宏任务后，当前事件任务已经彻底结束，再动播放器就不会踩到正在执行的帧。
   */
  private static macrotask(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), 0);
    });
  }

  async release(keepEqTask: boolean = false): Promise<void> {
    /**
     * 与 preparePlayer 共用同一条锁：释放旧现场和建新现场不能互相插队。
     *
     * 真机上出现过「旧一次释放的尾巴落到新现场上」：release 里 await 了
     * macrotask / player.release()，回来时已经有人在建新实例，它却照着旧现场
     * 清 this.mediaSource / this.fdHandle / status —— MediaSource 的强引用被清后
     * 被 GC 回收，播放中断甚至野指针崩溃（正是本文件多处在防的那条路）。
     *
     * 注意 preparePlayerUnlocked 内部也要释放（它已经在锁里），所以那里直接调
     * releaseUnlocked，不能再进这个排队入口 —— 否则自己等自己，直接死锁。
     */
    // 代次在这里（同步、进锁之前）自增：任何在途的 playXxx 立刻作废。
    // 内部释放（preparePlayerUnlocked 里）**不能**再自增，否则会把调用方
    // 自己刚捕获的代次顶掉，它 prepare 之后的校验会误判「已被切歌」而静默不出声。
    const epoch: number = ++this.playEpoch;
    const prev: Promise<void> = this.prepareLock;
    let unlock: () => void = () => {};
    this.prepareLock = new Promise<void>((resolve: () => void) => {
      unlock = resolve;
    });
    await prev;
    try {
      await this.releaseUnlocked(keepEqTask, epoch);
    } finally {
      unlock();
    }
  }

  /** 真正释放（调用方已在 prepareLock 里：release 入口，或 preparePlayerUnlocked） */
  private async releaseUnlocked(keepEqTask: boolean, epoch: number): Promise<void> {
    const player = this.avPlayer;
    // 旧现场对象先抓到局部：await 期间新现场可能已经把字段换成自己的，
    // 清理只能对着「我这一趟抓到的旧对象」做，绝不能回头清 this.xxx。
    const oldSource = this.mediaSource;
    const oldFd = this.fdHandle;
    const streamSession = this.eqStreamSession;
    const streamFile = this.eqStreamFile;
    // 先摘引用（同步）：后续回调走到判等处直接空转，不会再驱动界面或换实例
    this.avPlayer = null;
    // 句柄先摘下：新现场若已打开自己的句柄，这里不能把它覆盖/关掉
    this.fdHandle = null;
    // 流式播放现场先收：播放器释放后这个句柄就不能再留着了
    this.eqStreamSession = null;
    this.eqStreamFile = null;
    this.eqStreamPos = 0;
    // EQ 产物是一次性临时文件：先摘下路径，等播放器和句柄都收干净再删
    const artifact: string = this.eqTempPath;
    this.eqTempPath = '';
    // 现场收了：等处理的守候也一并停掉（否则定时器会在空现场上打转）
    this.clearEqSeekTimer();
    if (player !== null) {
      // 关键：先脱离回调栈，再有任何触碰这个播放器的动作（见 macrotask 注释）
      await LxPlayer.macrotask();
      try {
        /*
         * 这里**不能**先 off() 再 release()。
         *
         * off() 会立刻把该事件的 napi 回调引用删掉，但 AVPlayer 可能已经把一次派发
         * 任务压进了主线程队列 —— 那个任务拿着已经删掉的引用去取值，就是野指针。
         * 实测栈：SIGSEGV(SEGV_MAPERR)@0x6b6b...（堆释放填充值）
         *   libmedia_avplayer -> napi_get_reference_value -> EventRunnerImpl::Run
         *
         * release() 自己会 WaitTaskQueStop 等内部任务队列停干净再销毁，比我们手工 off() 更安全；
         * 而「旧实例的事件不要理」这件事已经由各处回调开头的 `this.avPlayer !== player`
         * 判等兜住了，不依赖 off()。
         */
        await player.release();
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'release failed: %{public}s', JSON.stringify(err));
      }
    }
    // 播放器释放之后才放掉 MediaSource：反过来会让播放器读到一个已析构的源。
    // 只在我这一趟的源仍是当前源时才清 —— 新现场换上的源不能碰。
    // （这里的比较同时保证 oldSource 在 await 期间一直有强引用，不会被提前 GC。）
    if (this.mediaSource === oldSource) {
      this.mediaSource = null;
    }
    // 播放器先释放，再关本地文件句柄：反过来可能让播放器读到一个已关闭的 fd。
    // 只关我这一趟抓到的旧句柄；新现场自己的句柄由它自己负责。
    if (oldFd !== null) {
      try {
        fs.closeSync(oldFd);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'close fd failed: %{public}s', JSON.stringify(err));
      }
    }
    if (streamFile !== null) {
      try {
        fs.closeSync(streamFile);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'close eq stream fd failed: %{public}s', JSON.stringify(err));
      }
    }
    if (artifact.length > 0) {
      // 播放器与句柄都已收掉，这份临时 WAV 没用了（只删 tmp_ 前缀，不碰任何原文件）
      AudioEffectProcessor.getInstance().discardArtifact(artifact);
    }
    if (!keepEqTask) {
      // 换源了：还在跑的 EQ 任务没人要了，停掉它
      AudioEffectProcessor.getInstance().cancelActive();
    } else if (streamSession !== null && streamSession.isFailed()) {
      hilog.warn(DOMAIN, TAG, 'release with failed eq stream: %{public}s', streamSession.error());
    }
    /**
     * 状态只在「没有更新的播放意图」时收掉。
     *
     * 若这趟释放的 await 期间用户已经切歌（新歌已经把状态设成 loading / playing），
     * 这里再把 status 覆盖成 idle、把进度清零，就会打烂新现场：界面显示空闲、
     * 进度条归零，甚至新歌正在响却被标成没在播。
     */
    if (this.playEpoch !== epoch) {
      return;
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
