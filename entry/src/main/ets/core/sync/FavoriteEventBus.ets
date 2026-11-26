import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'FavoriteEventBus';

/**
 * 「收藏状态变了」的最小事件总线
 *
 * ## 为什么要有这一层
 * 平台同步要「收藏一首就往平台推一首、取消收藏就取消」，但播放核心
 * （`core/player/PlaySession.ets`）不该反向依赖同步模块 —— 那会形成
 * `PlaySession -> PlatformPush -> PlaySession` 的循环依赖，ArkTS 下容易出现
 * 初始化顺序问题（模块常量还没算完就被引用）。
 *
 * 所以这里只留一份**不依赖任何业务模块**的极薄总线：播放核心在收藏/取消收藏
 * 之后 `emitFavoriteEvent(...)`，同步模块在 init 时 `setFavoriteEventHandler(...)`
 * 注册一个监听。谁都没订阅时就等于没有这个功能，不会拖慢收藏动作。
 *
 * ## 载荷为什么是这三个字段
 * 平台写入只需要「条目 id（本机身份键）、来源平台、musicInfoJson（里面才有平台侧
 * 数字 id / songmid / songType）」。不带整个 SongItem 是为了让本模块不 import 播放核心，
 * 保持零依赖；同步侧自己做字段适配。
 */

/** 一次收藏状态变化（add=true 收藏，false 取消收藏） */
export interface FavoriteEvent {
  /** 条目 id（本机身份键，与 Session.favorites 里一致） */
  itemId: string;
  /** 来源平台标识（'wy' | 'tx' | 'kw' | ...；只有 wy/tx 会被平台同步处理） */
  source: string;
  /** 歌名（跨音源去重要用：同一首歌不同音源，歌名+作者一致就算同一首） */
  name: string;
  /** 歌手（同上） */
  singer: string;
  /** 洛雪结构的歌曲信息 JSON（平台写入要素都在里面） */
  musicInfoJson: string;
  /** true = 刚被收藏；false = 刚被取消收藏 */
  add: boolean;
}

/** 监听器：返回 true 表示已接收（同步模块永远返回 true，这里不用于分流） */
export type FavoriteEventHandler = (event: FavoriteEvent) => void;

/** 当前注册的监听（同一时刻只允许一个：同步模块是单例，多注册只会重复推送） */
let handler: FavoriteEventHandler | null = null;

/** 注册 / 注销监听（传 null 注销） */
export function setFavoriteEventHandler(next: FavoriteEventHandler | null): void {
  handler = next;
}

/**
 * 发布一次收藏变化
 *
 * 监听器同步调用、返回值丢弃：收藏动作不该等网络。同步模块自己内部排队串行执行，
 * 所以这里直接调不会阻塞 UI 线程上的收藏逻辑（它只往队列里塞一个任务）。
 * 监听器抛错也只是记日志，绝不能让「收藏」因为同步出错而失败。
 */
export function emitFavoriteEvent(event: FavoriteEvent): void {
  const current: FavoriteEventHandler | null = handler;
  if (current === null) {
    return;
  }
  try {
    current(event);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'favorite sync handler threw: %{public}s',
      e instanceof Error ? e.message : JSON.stringify(e));
  }
}
