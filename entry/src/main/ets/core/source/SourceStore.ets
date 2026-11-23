import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceInfo } from './LxTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceStore';

const STORE_DIR: string = 'lx_sources';
const INDEX_FILE: string = 'sources.json';
/** 上次成功加载的音源（重启后自动恢复，省得每次都去音源设置里点一次） */
const ACTIVE_FILE: string = 'active_source.json';
/** 音源切换记忆：哪个源在哪个平台成功过（见 SourceRouter） */
const ROUTER_FILE: string = 'source_router.json';
/** 上一次「一键自检」的结论（见 SourceCheckup） */
const EXTRAS_FILE: string = 'source_checkup.json';
/**
 * 音源订阅：来源链接 + 订阅状态（见 SourceSubscription）
 *
 * 为什么不把「来源链接」塞进 sources.json 的 SourceInfo 里：SourceInfo 是**洛雪脚本头部
 * 字段的镜像**（name / version / author / updateUrl 都是脚本自己声明的），而「这个源是从
 * 哪个链接导进来的」是导入那一刻发生的事实，脚本本身并不知道。放进旁挂的一份记录里，
 * 好处有三：
 *   1. 老数据天然兼容 —— 没有这份文件就等于「所有源都没记下来源链接」，
 *      不需要写任何迁移代码（读不到就是空列表，界面显示「不支持订阅」）；
 *   2. 删源 / 覆盖更新都不丢订阅：记录按 id 索引，而 importSource 覆盖更新、
 *      replaceSourceScript 原地更新都保持 id 不变（见 SourceEngine）；
 *   3. 订阅的附带状态（上次检查时间、上次结论）有地方放，不必污染脚本元信息。
 */
const SUBS_FILE: string = 'source_subscriptions.json';
/** 订阅记录的格式版本：将来加减字段时按这个号做迁移；读的时候不校验版本，缺字段按默认值补 */
const SUBS_SCHEMA_VERSION: number = 1;

export interface ActiveSource {
  id: string;
  /** 加载时用的沙箱环境（mobile / desktop），恢复时要按同一个来 */
  env: string;
  loadedAt: number;
}

/**
 * 一个音源「从哪来 / 有没有订阅」的记录
 *
 * `url` 与 `subscribed` 必须是两件事，不能合并成一个开关：
 *   - `url` 是**来源链接**，导入那一刻就该记下来（用户取消订阅也不该忘），
 *     忘了它这个源就永远失去「重新拉一次最新脚本」的线索；
 *   - `subscribed` 只是「以后检查更新 / 自动检查要不要算上它」。
 * 两者分开还有个直接用处：界面上「没订阅但知道链接」的源仍然可以点单次的「检查更新」。
 */
export interface SubscriptionRecord {
  /** 音源 id（与 sources.json 里的 id 一致，覆盖更新也不变） */
  id: string;
  /** 来源链接：导入时填的那个 URL；本地文件导入、或早期版本导入的老数据，是空串 */
  url: string;
  /** 已订阅：检查全部更新、启动后的自动检查都只算上这些 */
  subscribed: boolean;
  /** 订阅（或最近一次重新导入该链接）的时刻 */
  subscribedAt: number;
  /** 上次检查更新的时刻（0 = 从没查过） */
  lastCheckedAt: number;
  /** 上次检查的结论：'update' / 'latest' / 'failed' / ''（没查过） */
  lastResult: string;
  /** 上次远端版本号（检查失败时为空串） */
  lastRemoteVersion: string;
  /** 上次结论的一句话说明（进页面就能看到，不必重新联网） */
  lastNote: string;
}

/** 订阅记录文件（source_subscriptions.json）的内容 */
export interface SubscriptionFile {
  version: number;
  items: SubscriptionRecord[];
}

/**
 * 音源持久化
 *
 * 对应洛雪的 utils/data.ts：
 *   - userApis 列表 + 每个源的脚本体，分别存储
 *
 * 差异：HarmonyOS 的 preferences 对字符串长度有限制，而源脚本可能达到数 MB，
 * 因此这里把「脚本正文」落到应用沙箱文件，索引仍然是一个 JSON 文件。
 */
export class SourceStore {
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

  private scriptPath(id: string): string {
    return `${this.dir}/script_${id}.js`;
  }

  list(): SourceInfo[] {
    if (!this.ready || !fs.accessSync(this.indexFile)) {
      return [];
    }
    try {
      const text: string = fs.readTextSync(this.indexFile);
      return JSON.parse(text) as SourceInfo[];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'failed to read source index: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  find(id: string): SourceInfo | null {
    const list: SourceInfo[] = this.list();
    for (const item of list) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  private saveIndex(list: SourceInfo[]): void {
    if (!this.ready) {
      throw new Error('音源存储未初始化');
    }
    const file = fs.openSync(this.indexFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(list));
    } finally {
      fs.closeSync(file);
    }
  }

  /** 保存脚本正文 */
  private saveScript(id: string, script: string): void {
    const file = fs.openSync(this.scriptPath(id), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, script);
    } finally {
      fs.closeSync(file);
    }
  }

  getScript(id: string): string {
    const path: string = this.scriptPath(id);
    if (!fs.accessSync(path)) {
      throw new Error(`音源脚本不存在: ${id}`);
    }
    return fs.readTextSync(path);
  }

  /** 脚本是否存在（去重时读旧脚本做比对，文件不在就当内容不同） */
  hasScript(id: string): boolean {
    try {
      return fs.accessSync(this.scriptPath(id));
    } catch (e) {
      return false;
    }
  }

  add(info: SourceInfo, script: string): SourceInfo {
    const list: SourceInfo[] = this.list();
    list.push(info);
    this.saveScript(info.id, script);
    this.saveIndex(list);
    return info;
  }

  /**
   * 覆盖更新一个已存在的源：id 不变（播放列表/已加载引用不会失效），
   * 脚本正文与元信息都用新的，importedAt 刷新。
   *
   * `disabled` 与运行期记下的 `updateUrl` 不在新解析出来的元信息里，
   * 但它们是用户/脚本给出的、与「这一版脚本内容」无关的状态，覆盖时要原样带过去：
   * 不带的话，重复导入一次就会把用户停用过的源悄悄启用回来。
   */
  replace(id: string, info: SourceInfo, script: string): SourceInfo {
    const list: SourceInfo[] = this.list();
    const next: SourceInfo[] = [];
    let updated: SourceInfo = info;
    for (const item of list) {
      if (item.id === id) {
        updated = {
          id: id,
          name: info.name,
          description: info.description,
          version: info.version,
          author: info.author,
          homepage: info.homepage,
          updateUrl: (info.updateUrl !== undefined && info.updateUrl.length > 0)
            ? info.updateUrl
            : (item.updateUrl !== undefined ? item.updateUrl : ''),
          allowShowUpdateAlert: info.allowShowUpdateAlert,
          importedAt: Date.now(),
          disabled: item.disabled === true,
        };
        next.push(updated);
      } else {
        next.push(item);
      }
    }
    this.saveScript(id, script);
    this.saveIndex(next);
    return updated;
  }

  /** 改「启用/停用」状态；音源不存在时返回 false */
  setDisabled(id: string, disabled: boolean): boolean {
    const list: SourceInfo[] = this.list();
    let found: boolean = false;
    for (const item of list) {
      if (item.id === id) {
        item.disabled = disabled;
        found = true;
      }
    }
    if (found) {
      this.saveIndex(list);
    }
    return found;
  }

  /**
   * 记下脚本运行时自报的更新地址（`lx.send('showUpdateAlert', { updateUrl })`）
   *
   * 返回 true = 地址**确实变了**并已写盘。脚本每次加载都可能发这句话，
   * 地址没变就不重写索引文件、也不重复刷日志。
   */
  setUpdateUrl(id: string, url: string): boolean {
    if (url.length === 0) {
      return false;
    }
    const list: SourceInfo[] = this.list();
    let changed: boolean = false;
    for (const item of list) {
      if (item.id !== id) {
        continue;
      }
      const current: string = item.updateUrl !== undefined ? item.updateUrl : '';
      if (current !== url) {
        item.updateUrl = url;
        changed = true;
      }
    }
    if (changed) {
      this.saveIndex(list);
    }
    return changed;
  }

  remove(ids: string[]): SourceInfo[] {
    const list: SourceInfo[] = this.list();
    const remains: SourceInfo[] = [];
    for (const item of list) {
      if (ids.includes(item.id)) {
        const path: string = this.scriptPath(item.id);
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'failed to delete script %{public}s', item.id);
        }
      } else {
        remains.push(item);
      }
    }
    this.saveIndex(remains);
    // 脚本和索引都清掉之后，订阅记录也得跟着清：否则音源设置页会留下一行指向
    // 已经不存在的音源的订阅（「检查全部更新」每次都要为它白跑一遍网络请求）。
    // 放在 remove 里而不是让每个调用方记得调：删源有两条路径（设置页删除、
    // 启动时清理历史重复音源），漏一条就会攒出这种孤儿记录。
    this.pruneSubscriptions(ids);
    return remains;
  }

  // ------------------------------------------------------------ 上次加载的音源

  private activePath(): string {
    return `${this.dir}/${ACTIVE_FILE}`;
  }

  /** 记下「这次用的是哪个源」；写失败只记日志，不影响加载本身 */
  saveActive(id: string, env: string): void {
    if (!this.ready) {
      return;
    }
    const active: ActiveSource = { id: id, env: env, loadedAt: Date.now() };
    try {
      const path: string = this.activePath();
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(active));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to save active source: %{public}s', JSON.stringify(e));
    }
  }

  loadActive(): ActiveSource | null {
    if (!this.ready) {
      return null;
    }
    try {
      const path: string = this.activePath();
      if (!fs.accessSync(path)) {
        return null;
      }
      return JSON.parse(fs.readTextSync(path)) as ActiveSource;
    } catch (e) {
      return null;
    }
  }

  clearActive(): void {
    if (!this.ready) {
      return;
    }
    try {
      const path: string = this.activePath();
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to clear active source: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 音源路由记忆

  private routerPath(): string {
    return `${this.dir}/${ROUTER_FILE}`;
  }

  /**
   * 读「哪个源在哪个平台成功过」的持久化记忆（见 SourceRouter）
   *
   * 读不到 / 解析失败都返回空串：这份记忆只是加速用的缓存，
   * 损坏了大不了重新观察一遍，绝不能让它把音源功能带坏。
   */
  loadRouter(): string {
    if (!this.ready) {
      return '';
    }
    try {
      const path: string = this.routerPath();
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read router state: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /** 写路由记忆；写失败只记日志（下个平台结论会再写一次） */
  saveRouter(json: string): void {
    if (!this.ready) {
      return;
    }
    try {
      const file = fs.openSync(this.routerPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to save router state: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 自检结果

  private extrasPath(): string {
    return `${this.dir}/${EXTRAS_FILE}`;
  }

  /**
   * 读「上一次一键自检的结果」（见 SourceCheckup）
   *
   * 和路由记忆一样：读不到 / 解析失败都返回空串，坏了就当没自检过。
   * 这份缓存只是「进页面就能看到上次结论」，绝不能因为它把音源设置页带崩。
   */
  loadExtras(): string {
    if (!this.ready) {
      return '';
    }
    try {
      const path: string = this.extrasPath();
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read checkup state: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /** 写自检结果；写失败只记日志（下次自检会再写一次） */
  saveExtras(json: string): void {
    if (!this.ready) {
      return;
    }
    try {
      const file = fs.openSync(this.extrasPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to save checkup state: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 订阅与来源链接

  private subsPath(): string {
    return `${this.dir}/${SUBS_FILE}`;
  }

  /**
   * 读订阅记录（读不到 / 解析失败一律返回空数组）
   *
   * 和路由记忆、自检结论同一个口径：这份数据坏了只该退化成「所有源都显示没订阅」，
   * 绝不能把音源设置页带崩。老文件 / 手改过的文件都可能缺字段，这里逐条补齐默认值，
   * 上层拿到的永远是填满的 SubscriptionRecord，不用到处判 undefined。
   *
   * 注意这里**不校验 version**：订阅只是「记住链接、记下上次结论」，不像自检结论那样
   * 有严格的字段语义，加减字段时按缺省值补就够了，为它写一套迁移代码不值当。
   */
  loadSubscriptions(): SubscriptionRecord[] {
    if (!this.ready) {
      return [];
    }
    try {
      const path: string = this.subsPath();
      if (!fs.accessSync(path)) {
        return [];
      }
      const parsed: SubscriptionFile = JSON.parse(fs.readTextSync(path)) as SubscriptionFile;
      if (parsed === null || parsed === undefined || parsed.items === undefined) {
        return [];
      }
      const list: SubscriptionRecord[] = [];
      for (const raw of parsed.items) {
        if (raw === null || raw === undefined || raw.id === undefined || raw.id.length === 0) {
          continue;
        }
        list.push({
          id: raw.id,
          url: raw.url !== undefined ? raw.url : '',
          subscribed: raw.subscribed === true,
          subscribedAt: raw.subscribedAt !== undefined ? raw.subscribedAt : 0,
          lastCheckedAt: raw.lastCheckedAt !== undefined ? raw.lastCheckedAt : 0,
          lastResult: raw.lastResult !== undefined ? raw.lastResult : '',
          lastRemoteVersion: raw.lastRemoteVersion !== undefined ? raw.lastRemoteVersion : '',
          lastNote: raw.lastNote !== undefined ? raw.lastNote : '',
        });
      }
      return list;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read subscriptions: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  /** 写订阅记录；写失败只记日志（下次检查还会再写一次） */
  saveSubscriptions(list: SubscriptionRecord[]): void {
    if (!this.ready) {
      return;
    }
    const content: SubscriptionFile = { version: SUBS_SCHEMA_VERSION, items: list };
    try {
      const file = fs.openSync(this.subsPath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(content));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to save subscriptions: %{public}s', JSON.stringify(e));
    }
  }

  /** 删掉若干个音源的订阅记录（音源被删除时调用，见 remove） */
  private pruneSubscriptions(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    const list: SubscriptionRecord[] = this.loadSubscriptions();
    const remains: SubscriptionRecord[] = [];
    let removed: number = 0;
    for (const item of list) {
      if (ids.includes(item.id)) {
        removed += 1;
      } else {
        remains.push(item);
      }
    }
    // 没有命中就不重写文件：remove 在「删重复音源」时也走这里，别为它多写一次盘
    if (removed > 0) {
      this.saveSubscriptions(remains);
    }
  }
}
