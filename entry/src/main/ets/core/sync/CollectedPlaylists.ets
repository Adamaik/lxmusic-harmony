import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CollectedPlaylists';
const FILE_NAME: string = 'collected_playlists.json';
/** 落盘结构变了就 +1，读到不认识的版本当没有 */
const DATA_VERSION: number = 2;

/**
 * 界面订阅这个 key 就能知道「收藏歌单」变了（@StorageLink + @Watch）
 *
 * 发布的是**版本号**而不是名单本身：界面关心的是「变了没有」，名单按需去
 * `list()` / `isCollected()` 取（与 core/settings/AppearanceSettings 的通知方式一致）。
 */
export const K_COLLECTED_VERSION: string = 'collected_playlist_version';

/**
 * 一条被收藏的**在线**歌单
 *
 * 收藏的是「推荐页上别人做的歌单」，所以得把列表要用的那几项一起存下来 ——
 * 它不在本地音乐库里（那是「歌单导入」干的事：把线上歌单拉成本地歌单），
 * 下次打开推荐页时也不需要为了显示这一行再请求一次平台接口。
 */
export interface CollectedPlaylist {
  /** 平台：kw / kg / mg / tx / wy */
  source: string;
  /** 线上歌单 id */
  id: string;
  name: string;
  cover: string;
  /** 「作者 · 播放量 · 曲目数」那一行说明（收藏时快照一份，列表直接显示） */
  meta: string;
}

/** 收藏记录的主键：与洛雪那套 sourceListId 同一个口径（`${平台}__${歌单id}`） */
export function collectedKeyOf(source: string, id: string): string {
  return `${source}__${id}`;
}

interface CollectedData {
  version: number;
  items?: CollectedPlaylist[];
}

/**
 * 收藏歌单（收藏**线上**歌单）
 *
 * 与「收藏的歌」是两件事：后者是洛雪的 loveList（`PlaySession.favorites`，
 * 一张内置歌单、参与同步）；这里收藏的是推荐页上**别人的**歌单，只是记下
 * 「哪个平台的哪张歌单」，点开还是走在线详情页（不落成本地歌单 —— 那是「歌单导入」）。
 *
 * 为什么是纯本地：洛雪的同步协议里没有歌单级的收藏 —— `ListData` 只有
 * defaultList / loveList / userList 三段。所以这一份存在本机，不碰协议。
 *
 * 存法照 core/settings/AppearanceSettings：一份 JSON 落应用沙箱 + 一个 AppStorage
 * 版本号给界面订阅，改完立即落盘。EntryAbility.onCreate 里 init 一次。
 */
export class CollectedPlaylists {
  private static instance: CollectedPlaylists | null = null;

  static getInstance(): CollectedPlaylists {
    if (CollectedPlaylists.instance === null) {
      CollectedPlaylists.instance = new CollectedPlaylists();
    }
    return CollectedPlaylists.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 收藏的在线歌单，最近收藏的在最前面 */
  private items: CollectedPlaylist[] = [];

  /**
   * 绑定沙箱目录并读回上次的收藏。
   * EntryAbility.onCreate 里调一次（与其它本地存储同一处），必须早于界面创建。
   */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        const data: CollectedData = JSON.parse(text) as CollectedData;
        if (data.version === DATA_VERSION && data.items !== undefined) {
          this.items = data.items;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse collected playlists: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  /**
   * 收藏的在线歌单（按收藏顺序，最近的在前）
   *
   * **返回一份拷贝**：界面把它放进 `@State`，同一份引用再赋一次是不会触发重绘的
   * （而 `add` 里如果是原地 `unshift`，引用就一直是同一个）。
   */
  list(): CollectedPlaylist[] {
    const out: CollectedPlaylist[] = [];
    for (const item of this.items) {
      out.push(item);
    }
    return out;
  }

  count(): number {
    return this.items.length;
  }

  isCollected(source: string, id: string): boolean {
    const key: string = collectedKeyOf(source, id);
    for (const item of this.items) {
      if (collectedKeyOf(item.source, item.id) === key) {
        return true;
      }
    }
    return false;
  }

  /** 收藏 / 取消收藏，返回操作之后是不是「已收藏」 */
  toggle(item: CollectedPlaylist): boolean {
    if (this.isCollected(item.source, item.id)) {
      this.remove(item.source, item.id);
      return false;
    }
    this.add(item);
    return true;
  }

  add(item: CollectedPlaylist): void {
    if (item.id.length === 0 || this.isCollected(item.source, item.id)) {
      return;
    }
    // 新收藏的排最前面：最近收的在上面。
    // 用 concat 造一份新数组而不是原地 unshift —— 就地改的话，界面上那份 @State
    // 拿到的还是同一个引用，重绘判定会漏掉这一改（见 list 的说明）。
    this.items = [item].concat(this.items);
    this.commit();
  }

  remove(source: string, id: string): void {
    this.removeByKey(collectedKeyOf(source, id));
  }

  /**
   * 按主键去掉一条
   *
   * 「歌单导入」把某张收藏着的线上歌单拉成本地歌单时也走它：**自建歌单与收藏歌单互斥** ——
   * 一张歌单要么在自己的库里（自建：自己建的 + 导入的），要么在收藏里，不会两边都占
   * （导入时那把主键就是 `link.listId`，与 `collectedKeyOf` 同一个口径）。
   */
  removeByKey(key: string): void {
    if (key.length === 0) {
      return;
    }
    const next: CollectedPlaylist[] = [];
    for (const item of this.items) {
      if (collectedKeyOf(item.source, item.id) !== key) {
        next.push(item);
      }
    }
    if (next.length === this.items.length) {
      return;
    }
    this.items = next;
    this.commit();
  }

  /**
   * 批量收藏（多选后一次收好几张）
   *
   * 一次落盘、一次通知：逐条调 `add` 的话每张都会写一遍文件、再让界面重绘一遍。
   * @returns 实际收进来的张数（已经在收藏里的不算）
   */
  addAll(items: CollectedPlaylist[]): number {
    const fresh: CollectedPlaylist[] = [];
    for (const item of items) {
      if (item.id.length === 0 || this.isCollected(item.source, item.id)) {
        continue;
      }
      let dup: boolean = false;
      for (const entry of fresh) {
        if (collectedKeyOf(entry.source, entry.id) === collectedKeyOf(item.source, item.id)) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        fresh.push(item);
      }
    }
    if (fresh.length === 0) {
      return 0;
    }
    this.items = fresh.concat(this.items);
    this.commit();
    return fresh.length;
  }

  /**
   * 批量取消收藏（多选后一次取消好几张）
   * @param keys `collectedKeyOf()` 得到的主键
   * @returns 实际去掉的张数
   */
  removeAll(keys: string[]): number {
    if (keys.length === 0) {
      return 0;
    }
    const next: CollectedPlaylist[] = [];
    for (const item of this.items) {
      if (!keys.includes(collectedKeyOf(item.source, item.id))) {
        next.push(item);
      }
    }
    const removed: number = this.items.length - next.length;
    if (removed === 0) {
      return 0;
    }
    this.items = next;
    this.commit();
    return removed;
  }

  // ---------------------------------------------------------------- 落盘 / 通知

  private commit(): void {
    this.write();
    this.publish();
  }

  /** 版本号 +1：界面上订阅它的那些页面重读一次（推荐页那一段、行尾的爱心） */
  private publish(): void {
    const current: number = AppStorage.get<number>(K_COLLECTED_VERSION) ?? 0;
    AppStorage.setOrCreate(K_COLLECTED_VERSION, current + 1);
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read collected playlists: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: CollectedData = {
      version: DATA_VERSION,
      items: this.items,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write collected playlists: %{public}s', JSON.stringify(e));
    }
  }
}
