import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RecognitionResult } from './RecognitionTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'RecognitionHistory';
const FILE_NAME: string = 'recognition_history.json';
/** 落盘结构变了就 +1，读到不认识的版本按空历史处理 */
const VERSION: number = 1;
/** 最多留几条：新的插在最前，满了从尾巴上丢 */
export const HISTORY_MAX: number = 50;

/**
 * 听歌识曲的识别历史
 *
 * 与搜索历史（core/music/SearchHistory）同一套存法：一份 JSON 落在应用沙箱
 * （filesDir/recognition_history.json），新的在前、最多 {@link HISTORY_MAX} 条。
 *
 * 页面进入时读一次、识别成功 / 删除 / 清空时再读写一遍，所以这里不发 AppStorage ——
 * 只有识别页读写它，页面自己用返回值刷新显示就够（不像播放设置那样有多个界面订阅）。
 */
/**
 * 落盘结构
 *
 * items 存的是 RecognitionResult.toRecord() 出来的**普通对象**，不是类的实例：
 * 直接 JSON.stringify 一个 class 数组虽然也能落盘，但读回来时类型上会与
 * `Record<string, Object>` 对不上（class 没有索引签名），显式转一道最清楚。
 */
interface RecognitionHistoryData {
  version?: number;
  items?: Array<Record<string, Object>>;
}

export class RecognitionHistory {
  private static instance: RecognitionHistory | null = null;

  static getInstance(): RecognitionHistory {
    if (RecognitionHistory.instance === null) {
      RecognitionHistory.instance = new RecognitionHistory();
    }
    return RecognitionHistory.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 内存里的那份；init 时从文件读回来 */
  private items: RecognitionResult[] = [];

  /** 绑定沙箱目录并读回历史。EntryAbility.onCreate 里调一次 */
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
      const data: RecognitionHistoryData = JSON.parse(text) as RecognitionHistoryData;
      if (data.version !== VERSION) {
        return;
      }
      const items: Array<Record<string, Object>> | undefined = data.items;
      if (items === undefined || items === null) {
        return;
      }
      for (const one of items) {
        const restored: RecognitionResult = RecognitionResult.fromRecord(one);
        // 老文件里可能混进字段不全的条目（id / 歌名都没有就展示不了），顺手滤掉
        if (restored.id.length > 0 && restored.title.length > 0) {
          this.items.push(restored);
        }
      }
      hilog.info(DOMAIN, TAG, 'recognition history ready, %{public}d item(s)', this.items.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse recognition history failed: %{public}s', JSON.stringify(e));
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read recognition history failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const records: Array<Record<string, Object>> = [];
    for (const item of this.items) {
      records.push(item.toRecord());
    }
    const data: RecognitionHistoryData = {
      version: VERSION,
      items: records,
    };
    try {
      const handle = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(handle.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(handle);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'write recognition history failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 识别历史，新的在前（返回副本，调用方随便改） */
  list(): RecognitionResult[] {
    return this.items.slice();
  }

  /** 记一次成功识别，返回记完的历史（界面拿去刷新显示） */
  add(result: RecognitionResult): RecognitionResult[] {
    const next: RecognitionResult[] = [result];
    for (const one of this.items) {
      // 同一首歌重复识别到不堆一屏（按来源 + 来源内 id 判重）
      if (one.providerTrackId !== result.providerTrackId) {
        next.push(one);
      }
    }
    this.items = next.length > HISTORY_MAX ? next.slice(0, HISTORY_MAX) : next;
    this.write();
    return this.list();
  }

  /** 删掉一条（行尾菜单里删） */
  remove(id: string): RecognitionResult[] {
    const next: RecognitionResult[] = [];
    for (const one of this.items) {
      if (one.id !== id) {
        next.push(one);
      }
    }
    if (next.length === this.items.length) {
      return this.list();
    }
    this.items = next;
    this.write();
    return this.list();
  }

  /** 清空历史 */
  clear(): void {
    if (this.items.length === 0) {
      return;
    }
    this.items = [];
    this.write();
  }
}
