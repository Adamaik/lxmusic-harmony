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

export interface ActiveSource {
  id: string;
  /** 加载时用的沙箱环境（mobile / desktop），恢复时要按同一个来 */
  env: string;
  loadedAt: number;
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
}
