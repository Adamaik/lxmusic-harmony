import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookSource, BookSourceInfo } from './BookTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookSourceStore';

const STORE_DIR: string = 'book_sources';
const INDEX_FILE: string = 'sources.json';

/**
 * 书源持久化
 *
 * 与音源（SourceStore）同一个套路：索引是一个 JSON，每个源的**原始 JSON 正文**
 * 单独落一个文件。区别是书源本来就是 JSON，所以不需要「抠注释头」这一步，
 * 元信息直接从 JSON 字段里取。
 */
export class BookSourceStore {
  private dir: string = '';
  private indexFile: string = '';
  private ready: boolean = false;

  init(context: common.Context): void {
    this.dir = `${context.filesDir}/${STORE_DIR}`;
    this.indexFile = `${this.dir}/${INDEX_FILE}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to create store dir: %{public}s', JSON.stringify(e));
      this.ready = false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  private sourcePath(id: string): string {
    return `${this.dir}/source_${id}.json`;
  }

  list(): BookSourceInfo[] {
    if (!this.ready || !fs.accessSync(this.indexFile)) {
      return [];
    }
    try {
      return JSON.parse(fs.readTextSync(this.indexFile)) as BookSourceInfo[];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to read source index: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  find(id: string): BookSourceInfo | null {
    for (const item of this.list()) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  private saveIndex(list: BookSourceInfo[]): void {
    const file = fs.openSync(this.indexFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(list));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 书源的原始 JSON 正文（直接交给沙箱，宿主不改写） */
  getRaw(id: string): string {
    const path: string = this.sourcePath(id);
    if (!fs.accessSync(path)) {
      throw new Error(`书源不存在：${id}`);
    }
    return fs.readTextSync(path);
  }

  private saveRaw(id: string, raw: string): void {
    const file = fs.openSync(this.sourcePath(id), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, raw);
    } finally {
      fs.closeSync(file);
    }
  }

  add(info: BookSourceInfo, raw: string): BookSourceInfo {
    const list: BookSourceInfo[] = this.list();
    list.push(info);
    this.saveRaw(info.id, raw);
    this.saveIndex(list);
    return info;
  }

  /** 同名同站的源再导入一次：原地覆盖，id 不变（书架里的引用不会失效） */
  replace(id: string, info: BookSourceInfo, raw: string): BookSourceInfo {
    const list: BookSourceInfo[] = this.list();
    const next: BookSourceInfo[] = [];
    for (const item of list) {
      if (item.id === id) {
        next.push({
          id: id,
          name: info.name,
          group: info.group,
          url: info.url,
          comment: info.comment,
          type: info.type,
          canSearch: info.canSearch,
          canExplore: info.canExplore,
          needLogin: info.needLogin,
          importedAt: Date.now(),
        });
      } else {
        next.push(item);
      }
    }
    this.saveRaw(id, raw);
    this.saveIndex(next);
    return info;
  }

  remove(id: string): BookSourceInfo[] {
    const remains: BookSourceInfo[] = [];
    for (const item of this.list()) {
      if (item.id === id) {
        try {
          const path: string = this.sourcePath(id);
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'failed to delete source file %{public}s', id);
        }
      } else {
        remains.push(item);
      }
    }
    this.saveIndex(remains);
    return remains;
  }
}

/** 从书源 JSON 里取一个字符串字段（缺省 / 类型不对一律给空串） */
export function sourceText(source: BookSource, key: string): string {
  let value: Object | undefined = undefined;
  if (key === 'bookSourceName') {
    value = source.bookSourceName;
  } else if (key === 'bookSourceUrl') {
    value = source.bookSourceUrl;
  } else if (key === 'bookSourceGroup') {
    value = source.bookSourceGroup;
  } else if (key === 'bookSourceComment') {
    value = source.bookSourceComment;
  } else if (key === 'searchUrl') {
    value = source.searchUrl;
  } else if (key === 'exploreUrl') {
    value = source.exploreUrl;
  }
  if (value === undefined || value === null) {
    return '';
  }
  return typeof value === 'string' ? value as string : String(value);
}
