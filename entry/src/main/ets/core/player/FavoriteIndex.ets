/**
 * 收藏名单（纯内存，无依赖）
 *
 * 歌曲行上的爱心要跟着收藏变化自己重绘。它不能去问 PlaySession：
 * views -> core/player 的引用会把行组件和播放会话绑在一起，而且懒加载列表
 * 不会因为宿主状态变化重跑已经建好的行，光靠宿主传值也刷不动。
 *
 * 所以这里把「已收藏的条目 id」发布到 AppStorage，爱心组件用 @StorageLink
 * 把它读进 build 里自己判断实心还是空心。
 *
 * 注意：值必须是「每次重新赋一个新数组」，订阅方才会收到变化通知；
 * 就地改数组元素不会触发通知。
 */

export const K_FAVORITE_IDS: string = 'ps_favorite_ids';

/** 用最新的收藏名单整体替换（PlaySession 每次收藏变化后调用） */
export function publishFavoriteIds(next: string[]): void {
  AppStorage.setOrCreate(K_FAVORITE_IDS, next.slice());
}
