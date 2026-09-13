import { SongItem } from '../core/player/PlaySession';

/**
 * 歌曲列表的懒加载数据源
 *
 * SongListPane 原来用 `Column + ForEach` 把整列一次性建出来：收藏里几百首时，
 * 每行都要建封面与文字节点，而且**每行的封面解析还会各发一次网络请求**；
 * 列表每次重画又把这些行全建一遍 —— 页面卡住，请求堆多了进程也扛不住（闪退）。
 *
 * 换成 `List + LazyForEach` 之后，只有屏幕上可见的那几行会被创建（含封面解析），
 * 滚动时按需创建、滑出即回收。这类「可能几百上千条」的列表都应该走它。
 */
export class SongListSource implements IDataSource {
  private items: SongItem[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: SongItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SongItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}
