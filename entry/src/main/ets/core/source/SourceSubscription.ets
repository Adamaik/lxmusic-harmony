import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceInfo } from './LxTypes';
import { SourceEngine } from './SourceEngine';
import { SourceStore, SubscriptionRecord } from './SourceStore';
import { SourceUpdateInfo, applySourceUpdate, checkSourceUpdate, checkSourceUpdates } from './SourceCheckup';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceSubscription';

/**
 * 音源订阅：记住「这个源是从哪个链接导进来的」，以后照着这条链接拉最新脚本
 *
 * 解决的是群里反复出现的那几句（11-17 aries「原来导过来的歌单一直没听，全是人机验证失败」、
 * 11-17 StarFlame「QQ 音乐的源都会失败」、11-18 小阝匋「最近音源不行了」、11-23
 * CharlotteZero「现在音源全用不了」）：各家音源脚本的接口会被厂商封，作者只能不断发新版，
 * 而用户手上只有「导入时那一条链接」和「满群翻新链接」两个选择。
 *
 * 这里补的是中间那一环：
 *   - 导入时就记下来源链接（哪怕用户没订阅），老数据没有链接就老老实实显示「不支持订阅」；
 *   - 订阅 = 「以后检查更新时算上它」，逐个去它声明的 updateUrl、没有就退回来源链接拉一遍，
 *     比对版本 / 内容后由用户点「更新」——更新走 SourceEngine.replaceSourceScript，
 *     **id 不变**，所以播放列表、已加载的引用、路由记忆的索引都不会失效；
 *   - 自动检查极其克制：每个进程生命周期最多一次、失败静默、且只在离上次检查超过
 *     12 小时才真的发请求（见 maybeAutoCheck）。
 *
 * 为什么订阅记录不放在 sources.json 的 SourceInfo 里：见 SourceStore.SUBS_FILE 的注释
 * （SourceInfo 是脚本头部字段的镜像，来源链接属于「导入」这件事，放进旁挂记录还天然兼容老数据）。
 */
export const SUB_RESULT_UPDATE: string = 'update';
export const SUB_RESULT_LATEST: string = 'latest';
export const SUB_RESULT_FAILED: string = 'failed';

/**
 * 自动检查的最小间隔：12 小时
 *
 * 一个音源作者一天发一两个版本已经算勤快，检查得比这频繁除了费流量和电没任何好处。
 * 配合「每个进程生命周期最多一次」，「进设置页就狂发请求」这件事从结构上不会发生。
 */
const AUTO_CHECK_INTERVAL_MS: number = 12 * 60 * 60 * 1000;

/**
 * 本次启动是否已经自动检查过
 *
 * 进程级变量（不是实例字段）：页面被销毁重建、换一个 SourceSubscription 实例，
 * 都不该让它再查一次。先置位再判断，失败也算「查过了」—— 要求是「失败静默」，
 * 不是「失败重试到成功」。
 */
let autoCheckedThisLaunch: boolean = false;

/** 一次「检查更新」的结果行（界面直接用；订阅与非订阅的源共用这一种结构） */
export interface SubscriptionRow {
  id: string;
  name: string;
  /** SUB_RESULT_UPDATE / SUB_RESULT_LATEST / SUB_RESULT_FAILED */
  status: string;
  localVersion: string;
  remoteVersion: string;
  /** 一句话说明：新版本号 / 「已是最新」 / 「检查失败：原因」 */
  note: string;
  /** 这次是拿来源链接查的（脚本自己没声明 updateUrl） */
  fromSourceUrl: boolean;
  /** 有新版时的完整结果（含新脚本正文，给「更新」按钮用）；否则 null */
  update: SourceUpdateInfo | null;
}

function messageOf(e: Error): string {
  if (e === null || e === undefined) {
    return '未知错误';
  }
  return e.message !== undefined && e.message.length > 0 ? e.message : '未知错误';
}

function isHttpUrl(url: string): boolean {
  return /^https?:\/\//.test(url);
}

/** 按 id 找一个已导入的音源（含停用的：停用的源照样可以订阅、检查更新） */
function findSourceById(id: string): SourceInfo | null {
  for (const item of SourceEngine.getInstance().listAllSources()) {
    if (item.id === id) {
      return item;
    }
  }
  return null;
}

export class SourceSubscription {
  private static instance: SourceSubscription | null = null;

  static getInstance(): SourceSubscription {
    if (SourceSubscription.instance === null) {
      SourceSubscription.instance = new SourceSubscription();
    }
    return SourceSubscription.instance;
  }

  /**
   * 订阅记录自己持有的一份 SourceStore
   *
   * SourceEngine 内部那个 store 是私有的（引擎没打算把存储层暴露出去，也不该为一个
   * 可选功能去改它），而订阅数据必须落在**同一个音源目录**里 —— 删音源时由
   * SourceStore.remove 顺手清掉对应订阅记录（见那边的 pruneSubscriptions），
   * 这样无论从哪条路径删源都不会留下孤儿订阅。
   *
   * 两个实例只读各自的文件（引擎读 sources.json，这里只读 source_subscriptions.json），
   * 不共享内存、也不会互相覆盖。
   */
  private store: SourceStore = new SourceStore();
  private inited: boolean = false;

  /**
   * 初始化（幂等）：只需要一个 Context 用来定位 filesDir
   *
   * 由音源设置页在 aboutToAppear 里调 —— 订阅是这一页的能力，别的页面不碰它。
   * 初始化失败（沙箱目录建不出来）时后续操作全部退化成空结果，不抛错：
   * 音源设置页的其它功能不该因为订阅不可用而用不了。
   */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    try {
      this.store.init(context);
      this.inited = this.store.isReady();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'init subscriptions failed: %{public}s', messageOf(e as Error));
      this.inited = false;
    }
  }

  isReady(): boolean {
    return this.inited && this.store.isReady();
  }

  // ------------------------------------------------------------ 读

  /** 全部记录（含未订阅、含只有链接的） */
  list(): SubscriptionRecord[] {
    if (!this.isReady()) {
      return [];
    }
    return this.store.loadSubscriptions();
  }

  recordOf(id: string): SubscriptionRecord | null {
    for (const item of this.list()) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  /** 来源链接（没有就空串：本地文件导入，或早期版本导入的老数据） */
  urlOf(id: string): string {
    const record: SubscriptionRecord | null = this.recordOf(id);
    return record !== null ? record.url : '';
  }

  isSubscribed(id: string): boolean {
    const record: SubscriptionRecord | null = this.recordOf(id);
    return record !== null && record.subscribed && record.url.length > 0;
  }

  /** 这个源支持订阅吗（= 记下来源链接了吗） */
  canSubscribe(id: string): boolean {
    return isHttpUrl(this.urlOf(id));
  }

  /** 已订阅的源 id（检查全部更新 / 自动检查的集合） */
  subscribedIds(): string[] {
    const ids: string[] = [];
    for (const item of this.list()) {
      if (item.subscribed && isHttpUrl(item.url)) {
        ids.push(item.id);
      }
    }
    return ids;
  }

  subscribedCount(): number {
    return this.subscribedIds().length;
  }

  /** 所有订阅记录里最近一次检查的时刻（0 = 从没查过） */
  lastCheckedAt(): number {
    let newest: number = 0;
    for (const item of this.list()) {
      if (item.lastCheckedAt > newest) {
        newest = item.lastCheckedAt;
      }
    }
    return newest;
  }

  /** 上次检查发现「有新版本」但还没更新的订阅数（进页面时的提示用，不联网） */
  pendingUpdateCount(): number {
    let count: number = 0;
    for (const item of this.list()) {
      if (item.subscribed && item.lastResult === SUB_RESULT_UPDATE) {
        count += 1;
      }
    }
    return count;
  }

  /**
   * 这个源该去哪个地址拉新版：脚本声明的 updateUrl 优先，其次来源链接
   *
   * 两处都收过（见 SourceCheckup 的说明）：作者写了 updateUrl 就说明那才是发布新版的
   * 正式地址；没写时才退回「当初从哪导入的」这条链接 —— 大量第三方源正是在固定链接上
   * 原地更新的。
   */
  updateAddressOf(info: SourceInfo): string {
    const declared: string = info.updateUrl !== undefined ? info.updateUrl : '';
    if (isHttpUrl(declared)) {
      return declared;
    }
    return this.urlOf(info.id);
  }

  // ------------------------------------------------------------ 写

  /**
   * 导入成功后记下这条链接，并**默认订阅**
   *
   * 为什么默认就订阅：用户把链接粘进来那一刻，已经明确表示「我要这个源」，
   * 再让他到一个新出现的「订阅」按钮上点第二下，等于把一个救命的功能藏起来
   * （群里「根本不知道能自动更新」的那类反馈就是这么来的）。想停随时点「取消订阅」，
   * 取消订阅**不会**删掉来源链接（见 SubscriptionRecord 的注释）。
   *
   * 覆盖更新同一条链接导入的源时，id 不变（SourceEngine.importSource 的去重逻辑），
   * 所以这里按 id 原地更新链接即可。
   */
  rememberImportedUrl(id: string, url: string): boolean {
    if (!this.isReady() || !isHttpUrl(url)) {
      return false;
    }
    const list: SubscriptionRecord[] = this.store.loadSubscriptions();
    const now: number = Date.now();
    let found: boolean = false;
    for (const item of list) {
      if (item.id === id) {
        item.url = url;
        item.subscribed = true;
        item.subscribedAt = now;
        found = true;
      }
    }
    if (!found) {
      list.push({
        id: id,
        url: url,
        subscribed: true,
        subscribedAt: now,
        lastCheckedAt: 0,
        lastResult: '',
        lastRemoteVersion: '',
        lastNote: '',
      });
    }
    this.store.saveSubscriptions(list);
    return true;
  }

  /** 订阅（来源链接必须存在；没有链接的源不支持订阅，返回 false 由界面解释） */
  subscribe(id: string): boolean {
    if (!this.isReady()) {
      return false;
    }
    const list: SubscriptionRecord[] = this.store.loadSubscriptions();
    let ok: boolean = false;
    for (const item of list) {
      if (item.id === id && isHttpUrl(item.url)) {
        item.subscribed = true;
        if (item.subscribedAt <= 0) {
          item.subscribedAt = Date.now();
        }
        ok = true;
      }
    }
    if (ok) {
      this.store.saveSubscriptions(list);
    }
    return ok;
  }

  /** 取消订阅：只关开关，来源链接留着（以后还能一键订回来，也能单次「检查更新」） */
  unsubscribe(id: string): void {
    if (!this.isReady()) {
      return;
    }
    const list: SubscriptionRecord[] = this.store.loadSubscriptions();
    let changed: boolean = false;
    for (const item of list) {
      if (item.id === id && item.subscribed) {
        item.subscribed = false;
        changed = true;
      }
    }
    if (changed) {
      this.store.saveSubscriptions(list);
    }
  }

  /** 把一次检查结论写进记录（进页面不用重新联网就能看到上次查到什么） */
  private markChecked(row: SubscriptionRow): void {
    if (!this.isReady()) {
      return;
    }
    const list: SubscriptionRecord[] = this.store.loadSubscriptions();
    let found: boolean = false;
    for (const item of list) {
      if (item.id === row.id) {
        item.lastCheckedAt = Date.now();
        item.lastResult = row.status;
        item.lastRemoteVersion = row.remoteVersion;
        item.lastNote = row.note;
        found = true;
      }
    }
    if (found) {
      this.store.saveSubscriptions(list);
    }
  }

  /**
   * 一次更新完成：结论从「有新版本」翻成「已是最新」，待更新数才会跟着减少
   *
   * 公开是因为「检查更新」（老的 updateUrl 路径）也在更新同一个音源：
   * 它走的是同一个 replaceSourceScript，订阅记录里的结论当然也要一起翻新，
   * 否则卡片上会一直挂着「上次查到有新版本」。
   */
  markUpdated(id: string, version: string): void {
    if (!this.isReady()) {
      return;
    }
    const list: SubscriptionRecord[] = this.store.loadSubscriptions();
    let found: boolean = false;
    for (const item of list) {
      if (item.id === id) {
        item.lastCheckedAt = Date.now();
        item.lastResult = SUB_RESULT_LATEST;
        item.lastRemoteVersion = version;
        item.lastNote = version.length > 0 ? `已更新到 ${version}` : '已更新';
        found = true;
      }
    }
    if (found) {
      this.store.saveSubscriptions(list);
    }
  }

  // ------------------------------------------------------------ 检查与更新

  /** 把 checkSourceUpdate 的结果翻成界面行 */
  private rowOf(update: SourceUpdateInfo): SubscriptionRow {
    let status: string = SUB_RESULT_LATEST;
    let note: string = update.note;
    if (update.error.length > 0) {
      status = SUB_RESULT_FAILED;
      note = `检查失败：${update.error}`;
    } else if (update.hasUpdate) {
      status = SUB_RESULT_UPDATE;
      note = update.note.length > 0 ? update.note : `发现新版本 ${update.remoteVersion}`;
    } else if (note.length === 0) {
      note = '已是最新';
    }
    const row: SubscriptionRow = {
      id: update.id,
      name: update.name,
      status: status,
      localVersion: update.localVersion,
      remoteVersion: update.remoteVersion,
      note: note,
      fromSourceUrl: update.fromSourceUrl,
      // 只有「确实拉到了一份能用的新脚本」才给「更新」按钮：
      // 检查失败 / 远端更旧 / 内容没变时都没有 script 可写，按钮点了也只会把源写坏
      update: update.hasUpdate && update.error.length === 0 ? update : null,
    };
    return row;
  }

  /**
   * 检查**已订阅**的源的更新（并发 ≤3，网络请求，不碰沙箱）
   *
   * 结果按订阅集合的原顺序返回（checkSourceUpdates 内部是并发完成的，顺序不固定；
   * 这里显式按 ids 重排，界面每次的排列才稳定，用户不会以为「列表自己在跳」）。
   */
  async checkSubscribed(onProgress?: (done: number, total: number) => void,
    isCancelled?: () => boolean): Promise<SubscriptionRow[]> {
    const ids: string[] = this.subscribedIds();
    if (ids.length === 0) {
      return [];
    }
    const found: SourceUpdateInfo[] = await checkSourceUpdates(ids, onProgress, isCancelled,
      (id: string) => {
        const info: SourceInfo | null = findSourceById(id);
        return info !== null ? this.updateAddressOf(info) : this.urlOf(id);
      });
    const rows: SubscriptionRow[] = [];
    for (const id of ids) {
      let matched: SourceUpdateInfo | null = null;
      for (const one of found) {
        if (one.id === id) {
          matched = one;
          break;
        }
      }
      // 取消检查时可能整个源都没轮到：不留半条记录（否则界面会说「已是最新」，那是假话）
      if (matched === null) {
        continue;
      }
      const row: SubscriptionRow = this.rowOf(matched);
      this.markChecked(row);
      rows.push(row);
    }
    return rows;
  }

  /** 检查单个源（音源卡片上的「检查更新」；没订阅但知道链接的源也能查） */
  async checkOne(id: string): Promise<SubscriptionRow> {
    const info: SourceInfo | null = findSourceById(id);
    const fallback: string = info !== null ? this.updateAddressOf(info) : this.urlOf(id);
    const update: SourceUpdateInfo = await checkSourceUpdate(id, fallback);
    const row: SubscriptionRow = this.rowOf(update);
    this.markChecked(row);
    return row;
  }

  /**
   * 应用一次更新：原地替换脚本（id 不变）
   *
   * 走 SourceCheckup.applySourceUpdate -> SourceEngine.replaceSourceScript，
   * 与「检查更新」共用同一条写入路径：绝不删了重导 —— 那样 id 会变，
   * 播放列表里的引用、路由记忆、当前正在用的音源全都跟着失效。
   * 失败会抛错，原音源不动。
   */
  applyRow(row: SubscriptionRow): SourceInfo | null {
    if (row.update === null) {
      return null;
    }
    const info: SourceInfo = applySourceUpdate(row.update);
    this.markUpdated(row.id, info.version);
    return info;
  }

  /**
   * 启动后的自动检查：最多每个进程一次、失败静默
   *
   * 三个克制点，缺一不可：
   *   1. **每进程一次**：页面来回进出不会再触发；
   *   2. **距上次检查不足 12 小时就不发请求**：频繁重启应用也不会一直查；
   *   3. **失败只进 hilog**：用户没点任何东西，界面顶部不该突然冒出一行「检查失败」。
   *
   * 而且**只检查、不自动更新**：自动把沙箱里的脚本换掉，可能正好换在用户点播放的那一刻，
   * 换来的新脚本还可能更坏（作者自己也可能发了个坏版本）。新版必须由用户点一下才生效。
   */
  async maybeAutoCheck(): Promise<SubscriptionRow[]> {
    if (autoCheckedThisLaunch) {
      return [];
    }
    autoCheckedThisLaunch = true;
    const ids: string[] = this.subscribedIds();
    if (ids.length === 0) {
      return [];
    }
    const newest: number = this.lastCheckedAt();
    if (newest > 0 && Date.now() - newest < AUTO_CHECK_INTERVAL_MS) {
      return [];
    }
    try {
      const rows: SubscriptionRow[] = await this.checkSubscribed();
      hilog.info(DOMAIN, TAG, 'auto check of %{public}d subscriptions done', rows.length);
      return rows;
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'auto check skipped: %{public}s', messageOf(e as Error));
      return [];
    }
  }
}
