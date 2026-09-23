import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookChapter, BookHit } from './BookTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookShelf';

const SHELF_FILE: string = 'book_shelf.json';

/**
 * 书架里的一本书
 *
 * 目录一起存下来：听书是「一章一章顺着听」的用法，每次打开都重新拉一遍目录
 * 既慢又容易被站点限流。`tocFetchedAt` 让界面能提示「目录是几点拉到的」，
 * 想刷新时手动刷。
 */
export interface ShelvedBook {
  book: BookHit;
  chapters: BookChapter[];
  /** 目录最后一次拉取的时间；0 = 还没拉过 */
  tocFetchedAt: number;
  /** 上次听到第几章（续播用） */
  lastChapter: number;
  addedAt: number;
}

/** 书架：用户收藏起来要听的书（与「搜索历史」不同，这是显式的收藏） */
export class BookShelf {
  private static instance: BookShelf | null = null;

  static getInstance(): BookShelf {
    if (BookShelf.instance === null) {
      BookShelf.instance = new BookShelf();
    }
    return BookShelf.instance;
  }

  private path: string = '';
  private ready: boolean = false;
  private cache: ShelvedBook[] = [];

  init(context: common.Context): void {
    this.path = `${context.filesDir}/${SHELF_FILE}`;
    try {
      this.ready = true;
      this.cache = this.read();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to init shelf: %{public}s', JSON.stringify(e));
      this.ready = false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  private read(): ShelvedBook[] {
    try {
      if (!fs.accessSync(this.path)) {
        return [];
      }
      return JSON.parse(fs.readTextSync(this.path)) as ShelvedBook[];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to read shelf: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  private write(): void {
    if (!this.ready) {
      return;
    }
    try {
      const file = fs.openSync(this.path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(this.cache));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to write shelf: %{public}s', JSON.stringify(e));
    }
  }

  /** 书架列表（最近加入的在前） */
  list(): ShelvedBook[] {
    this.cache = this.read();
    const sorted: ShelvedBook[] = this.cache.slice();
    sorted.sort((a: ShelvedBook, b: ShelvedBook) => b.addedAt - a.addedAt);
    return sorted;
  }

  has(bookId: string): boolean {
    for (const item of this.read()) {
      if (item.book.id === bookId) {
        return true;
      }
    }
    return false;
  }

  /** 加入书架：带目录一起存（目录可能还没拉，先给空数组，之后 updateToc 补） */
  add(book: BookHit, chapters: BookChapter[]): void {
    const list: ShelvedBook[] = this.read();
    for (let i = 0; i < list.length; i++) {
      if (list[i].book.id === book.id) {
        list[i].book = book;
        if (chapters.length > 0) {
          list[i].chapters = chapters;
          list[i].tocFetchedAt = Date.now();
        }
        this.cache = list;
        this.write();
        return;
      }
    }
    list.push({
      book: book,
      chapters: chapters,
      tocFetchedAt: chapters.length > 0 ? Date.now() : 0,
      lastChapter: 0,
      addedAt: Date.now(),
    });
    this.cache = list;
    this.write();
  }

  remove(bookId: string): void {
    const remains: ShelvedBook[] = this.read().filter((item: ShelvedBook) => item.book.id !== bookId);
    this.cache = remains;
    this.write();
  }

  /** 目录更新（手动刷新目录后回填） */
  updateToc(bookId: string, chapters: BookChapter[]): void {
    const list: ShelvedBook[] = this.read();
    for (const item of list) {
      if (item.book.id === bookId) {
        item.chapters = chapters;
        item.tocFetchedAt = Date.now();
      }
    }
    this.cache = list;
    this.write();
  }

  /** 记一下听到哪儿了（续播） */
  updateProgress(bookId: string, chapterIndex: number): void {
    const list: ShelvedBook[] = this.read();
    for (const item of list) {
      if (item.book.id === bookId) {
        item.lastChapter = chapterIndex;
      }
    }
    this.cache = list;
    this.write();
  }

  find(bookId: string): ShelvedBook | null {
    for (const item of this.read()) {
      if (item.book.id === bookId) {
        return item;
      }
    }
    return null;
  }

  /** 把书源信息里的书按 id 清掉（删掉书源时，书架里来自它的书一起清） */
  dropBySource(sourceId: string): void {
    const remains: ShelvedBook[] = this.read().filter((item: ShelvedBook) => item.book.sourceId !== sourceId);
    this.cache = remains;
    this.write();
  }
}
