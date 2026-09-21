/**
 * 随机播放的「抽签袋」
 *
 * 随机播放的规则是「一轮之内不重复」：把队列下标当成一个袋子，本轮放过的从袋子里拿走，
 * 只从剩下的里抽；袋子空了（整条队列放完一轮）就重开一轮，但第一签不能又是刚放完的那首。
 *
 * 单独抠成一个类是为了两件事：
 *   1. 预取要在切歌之前就抽一签（不然预取的和真正播的不是同一首，白下），
 *      而「抽」有「记不记进本轮」两种语义 —— 预取的那一签随时会因为用户手动切歌而作废，
 *      不能算数，所以抽签要能只抽不记（pick 的 mark 参数）。这套语义容易写错，
 *      放在这里可以单独测（见 entry/src/test/ShuffleBag.test.ets）。
 *   2. PlaySession 里只剩「什么时候抽、抽完给谁」，随机播放本身不掺在播放流程里。
 *
 * 队列换了（version 变）就整体作废重开一轮 —— 对应「除非换了播放列表，否则不重复」。
 */
export class ShuffleBag {
  /** 本轮已经放过的下标 */
  private played: Set<number> = new Set<number>();
  /** 这份记录属于哪一版队列（PlaySession 的 queueVersion） */
  private version: number = -1;

  /**
   * 抽一签：本轮还没放过的下标
   *
   * mark = true 表示「这一首马上要播了」，记进本轮的已放（下一轮才会再轮到它）；
   * mark = false 用于预取：只看看是谁、不占名额（用户中途手动切歌时这一签会作废）。
   *
   * 返回 -1 表示队列是空的。
   */
  pick(total: number, version: number, current: number, mark: boolean): number {
    if (total <= 0) {
      return -1;
    }
    this.align(total, version, current);
    if (this.played.size >= total) {
      // 一轮放完了：重开一轮，但第一签不能又是刚放完的这首
      this.played.clear();
      if (current >= 0 && current < total) {
        this.played.add(current);
      }
    }
    const pool: number[] = [];
    for (let i = 0; i < total; i++) {
      if (!this.played.has(i)) {
        pool.push(i);
      }
    }
    if (pool.length === 0) {
      // 只有一首歌（或池子被清空后只剩当前这首）：就它自己
      return current >= 0 && current < total ? current : 0;
    }
    const picked: number = pool[Math.floor(Math.random() * pool.length)];
    if (mark) {
      this.played.add(picked);
    }
    return picked;
  }

  /** 记下「这一首已经放了」（上一首/下一首往回退时用：退回的那首马上要播） */
  markPlayed(index: number): void {
    this.played.add(index);
  }

  /** 与队列对齐：队列换过就重开一轮，正在播的这首算已放（免得随机到它自己） */
  private align(total: number, version: number, current: number): void {
    if (this.version !== version) {
      this.played.clear();
      this.version = version;
    }
    if (current >= 0 && current < total) {
      this.played.add(current);
    }
  }
}
