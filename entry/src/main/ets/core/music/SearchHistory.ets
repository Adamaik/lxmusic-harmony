import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'SearchHistory';
const FILE_NAME: string = 'search_history.json';
/** 落盘结构变了就 +1，读到不认识的版本按空历史处理 */
const VERSION: number = 1;

/** 最多留几条（与洛雪一致：新的插在最前，满了从尾巴上丢） */
export const HISTORY_MAX: number = 15;

/**
 * 搜索历史（搜索页空着的时候显示的那些词）
 *
 * 与洛雪的 `getSearchHistory / addHistoryWord / removeHistoryWord / clearHistoryList`
 * 是一回事：新的词插到最前、同一个词再搜一次就提前（不产生重复）、最多留 15 个。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/search_history.json）。搜索是低频操作
 * （一次搜索写一次），不做节流。这里**不发 AppStorage**：只有搜索页读写它，
 * 页面自己拿 `list()` 的返回值更新显示就够了（不像播放设置那样有多个界面订阅）。
 */
interface SearchHistoryData {
  version?: number;
  words?: string[];
}

export class SearchHistory {
  private static instance: SearchHistory | null = null;

  static getInstance(): SearchHistory {
    if (SearchHistory.instance === null) {
      SearchHistory.instance = new SearchHistory();
    }
    return SearchHistory.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 内存里的那份；init 时从文件读回来 */
  private words: string[] = [];

  /** 绑定沙箱目录并读回历史。EntryAbility.onCreate 里调一次（搜索页直接用同步接口） */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length === 0) {
      return;
    }
    try {
      const data: SearchHistoryData = JSON.parse(text) as SearchHistoryData;
      if (data.version !== VERSION) {
        return;
      }
      const words: string[] | undefined = data.words;
      if (words === undefined || words === null) {
        return;
      }
      for (const word of words) {
        if (typeof word === 'string' && word.trim().length > 0 && !this.words.includes(word)) {
          this.words.push(word);
        }
      }
      hilog.info(DOMAIN, TAG, 'search history ready, %{public}d word(s)', this.words.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse search history failed: %{public}s', JSON.stringify(e));
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read search history failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: SearchHistoryData = { version: VERSION, words: this.words };
    try {
      const handle = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write search history failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 历史词，新的在前（返回副本，调用方随便改） */
  list(): string[] {
    return this.words.slice();
  }

  /**
   * 记一次搜索。返回记完的历史（界面拿去刷新显示）
   *
   * 已经存在的词会被提到最前（重复搜同一个词不会堆一屏），空串不记。
   */
  add(word: string): string[] {
    const trimmed: string = word.trim();
    if (trimmed.length === 0) {
      return this.list();
    }
    const next: string[] = [trimmed];
    for (const one of this.words) {
      if (one !== trimmed) {
        next.push(one);
      }
    }
    this.words = next.length > HISTORY_MAX ? next.slice(0, HISTORY_MAX) : next;
    this.write();
    return this.list();
  }

  /** 删掉一个词（长按历史词时调） */
  remove(word: string): string[] {
    const next: string[] = [];
    for (const one of this.words) {
      if (one !== word) {
        next.push(one);
      }
    }
    if (next.length === this.words.length) {
      return this.list();
    }
    this.words = next;
    this.write();
    return this.list();
  }

  /** 清空历史 */
  clear(): void {
    if (this.words.length === 0) {
      return;
    }
    this.words = [];
    this.write();
  }
}
