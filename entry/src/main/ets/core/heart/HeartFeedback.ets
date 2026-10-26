/**
 * 心动模式 · 反馈分档
 *
 * 这是「移植过来反而升级」的地方：heartbeat_ondevice 的数据只有 user/track/timestamp
 * 三列，**没有跳过 / 听完标签**，它自己在 HANDOFF 里把这条列为 P0 硬伤，只能拿算术
 * 记账去补。而「聆听」的 ListenLog 已经记了 playedMs（真的在出声的时长）与 AVPlayer
 * 报的真实 durationMs —— 真实标签是现成的。
 *
 * 分档口径与 ListenLog 保持一致：
 *   < 30 秒 或 < 20%   → 跳过（强负）
 *   20% ~ 85%          → 播放（弱正）
 *   >= 85%             → 听完（正，85% 即 ListenLog 的 COMPLETE_RATIO）
 *   收藏               → 收藏（强正，用户的显式信号优先于时长）
 *   近期重复播放       → 重复（最强正）
 *
 * 注意：这里刻意**不**用「切歌」当跳过信号。切歌只能说明离开，不能说明不喜欢
 * （可能是接电话、可能是主动找另一首），所以只看真正听了多久。
 */

import {
  FB_COMPLETE,
  FB_LIKE,
  FB_PLAY,
  FB_REPEAT,
  FB_SKIP,
  HEART_COMPLETE_RATIO,
  HEART_DEFAULT_DURATION_MS,
  HEART_PLAY_MS
} from './HeartTypes';

/** 完播率（0~1）；时长未知按兜底值算，保证永远算得出来而不是「算不出」 */
export function completionRatio(playedMs: number, durationMs: number): number {
  const duration: number = durationMs > 0 ? durationMs : HEART_DEFAULT_DURATION_MS;
  if (playedMs <= 0) {
    return 0;
  }
  const ratio: number = playedMs / duration;
  return ratio > 1 ? 1 : ratio;
}

/**
 * 纯时长分档（不知道收藏/重复时的兜底）
 *
 * @param playedMs 这一次真的出声的时长（毫秒）
 * @param durationMs 歌曲总时长（毫秒），未知传 0
 */
export function feedbackOf(playedMs: number, durationMs: number): number {
  const ratio: number = completionRatio(playedMs, durationMs);
  if (playedMs < HEART_PLAY_MS || ratio < 0.2) {
    return FB_SKIP;
  }
  if (ratio >= HEART_COMPLETE_RATIO) {
    return FB_COMPLETE;
  }
  return FB_PLAY;
}

/**
 * 带上下文的分档（推荐用这个）
 *
 * @param playedMs 这次出声时长
 * @param durationMs 总时长，未知 0
 * @param liked 是否已收藏
 * @param recentPlays 这首歌最近（比如近 7 天）已被播放的次数，含本次
 */
export function feedbackWithContext(playedMs: number, durationMs: number, liked: boolean,
  recentPlays: number): number {
  // 显式信号优先：收藏了就不因为这次只听了 10 秒而判成跳过
  if (liked) {
    return FB_LIKE;
  }
  if (recentPlays >= 3) {
    return FB_REPEAT;
  }
  return feedbackOf(playedMs, durationMs);
}
