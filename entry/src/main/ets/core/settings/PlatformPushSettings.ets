import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlatformPushSettings';
const FILE_NAME: string = 'platform_push.json';
/** 落盘结构变了就 +1；读到更新的版本整份按默认值处理 */
const SETTINGS_VERSION: number = 1;

/**
 * 每个平台最多记多少条「已推送」
 *
 * 账本只是为了「同一首歌别反复推」，不是完整历史。2000 条按 id 存约几十 KB，
 * 超出就丢最旧的（数组头部）：最近收藏的永远记得住，远古的重复推一次也没关系
 * （平台的「喜欢」是幂等的，重复设置同一个值不会出错）。
 */
const LEDGER_MAX_PER_PLATFORM: number = 2000;

/**
 * 账本落盘节流（毫秒）
 *
 * markPushed 是逐首调的（最密 250ms 一次），每次都整份写 JSON 属于无谓 IO；
 * 攒一下再写。代价是进程在这几百毫秒内被杀会丢最后几条记录 —— 下次重推一遍
 * 即可（幂等），不影响最终状态。
 */
const LEDGER_WRITE_DELAY_MS: number = 800;

/**
 * 平台同步设置 + 已推送账本
 *
 * ## 这个开关是干什么的
 * 把本机「我的收藏」**镜像**到用户自己在那两个平台的账号里（网易：喜欢；QQ：收藏），
 * 方向只有一个：本机 → 平台。开启后随收藏动作实时同步（收藏一首推一首、取消收藏就取消
 * 平台上的喜欢）；历史收藏靠设置页的「立即同步收藏」补推。
 *
 * ## 为什么默认关
 * 这条链路会拿用户 Cookie 去写别人的服务器，属于「用户明确知情后才该发生」的动作。
 * 默认关 = 用户不主动打开就一次请求都不会发（见 PlatformPush 的入口自守）。
 *
 * ## 存法
 * 一份 JSON 落在应用沙箱（filesDir/platform_push.json），同时把开关状态写进 AppStorage
 * —— 设置页用 @StorageLink 订阅，改完立刻生效，重启不丢。
 *
 * 落盘结构（与契约一致）：
 * `{version:1, enabled, wy:[], tx:[], lastSyncAt}`
 * 额外多存两个**可选**字段 `wySelected` / `txSelected`（平台勾选）：契约结构里没有它们，
 * 但勾选状态不落盘的话重启就回到默认值，等于设置项是假的；字段可选，老文件缺了按默认
 * （true）处理，不影响契约结构。
 *
 * 账本语义：记的是「这首歌在平台账号里的喜欢状态由我们维护」。
 * 写成功、或确认平台本来就有 → 记一笔；取消收藏成功、或确认平台本来没有 → 划掉一笔。
 * 划掉之后用户重新收藏会再次推送，不会因为「账本说推过」而漏掉。
 *
 * 隐私：账本里**只存歌曲 id**，不存歌名 / 歌手 / 封面，也不存任何 Cookie。
 */

/** 界面订阅这三个 key 即可拿到最新开关（@StorageLink） */
export const K_PLATFORM_PUSH_ENABLED: string = 'cfg_platform_push_enabled';
export const K_PLATFORM_PUSH_WY: string = 'cfg_platform_push_wy';
export const K_PLATFORM_PUSH_TX: string = 'cfg_platform_push_tx';

/** 已推送账本（落盘 + 运行时都用这一份形状） */
export interface PlatformPushLedger {
  version: number;
  /** 网易云：已推送过的歌曲数字 id（字符串形式，便于判重） */
  wy: string[];
  /** QQ 音乐：已推送过的歌曲数字 id（字符串形式） */
  tx: string[];
  /** 网易云：上次没推成功的歌曲 id（下次「立即同步」只重试这些 + 从未处理过的） */
  wyFailed: string[];
  /** QQ 音乐：上次没推成功的歌曲 id */
  txFailed: string[];
  /** 上次手动同步完成的时间（毫秒）；0 = 从没同步过 */
  lastSyncAt: number;
}

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的用默认值） */
interface PlatformPushData {
  version?: number;
  enabled?: boolean;
  wy?: string[];
  tx?: string[];
  lastSyncAt?: number;
  wySelected?: boolean;
  txSelected?: boolean;
  wyFailed?: string[];
  txFailed?: string[];
  /** 最近一次写失败的原始原因（持久化：hilog 会被冲掉，排障要靠它） */
  wyLastError?: string;
  txLastError?: string;
}

export class PlatformPushSettings {
  private static instance: PlatformPushSettings | null = null;

  static getInstance(): PlatformPushSettings {
    if (PlatformPushSettings.instance === null) {
      PlatformPushSettings.instance = new PlatformPushSettings();
    }
    return PlatformPushSettings.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 默认值
  /** 总开关默认关：用户不主动打开，就不会拿他的 Cookie 去写平台 */
  private enabled: boolean = false;
  /**
   * 平台勾选默认都开
   *
   * 注意这是**两个平台各自的**勾选，与总开关是「与」的关系：总开关关着时勾选什么都不会发请求。
   * 默认都开是为了用户打开总开关后「按预期一次同步两个平台」，不想同步的平台自己去关。
   */
  private wySelected: boolean = true;
  private txSelected: boolean = true;
  /** 最近一次失败原因（落盘，设置页与排障用） */
  private wyLastError: string = '';
  private txLastError: string = '';
  /** 已推送账本（内存） */
  private ledger: PlatformPushLedger = {
    version: SETTINGS_VERSION, wy: [], tx: [], wyFailed: [], txFailed: [], lastSyncAt: 0,
  };
  /** 节流写的定时器（-1 = 没有排着的） */
  private writeTimer: number = -1;

  /**
   * 绑定沙箱目录并读回上次的开关与账本。
   * EntryAbility.onCreate 里调一次，且必须早于界面创建（设置页用 @StorageLink 订阅）。
   * 幂等：重复调用直接返回。
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
        this.apply(JSON.parse(text) as PlatformPushData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse platform push settings: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read platform push settings: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * 立即落盘（开关、勾选、清空账本走这里；账本追加走 scheduleWrite 节流）
   *
   * 未 init 时直接跳过：设置项仍能改内存与 AppStorage，只是这次不落盘。
   */
  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: PlatformPushData = {
      version: SETTINGS_VERSION,
      enabled: this.enabled,
      wy: this.ledger.wy,
      tx: this.ledger.tx,
      lastSyncAt: this.ledger.lastSyncAt,
      wySelected: this.wySelected,
      txSelected: this.txSelected,
      wyFailed: this.ledger.wyFailed,
      txFailed: this.ledger.txFailed,
      wyLastError: this.wyLastError,
      txLastError: this.txLastError,
    };
    try {
      const file: fs.File = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write platform push settings: %{public}s', JSON.stringify(e));
    }
  }

  /** 账本追加用的节流写：攒 LEDGER_WRITE_DELAY_MS 再落一次盘 */
  private scheduleWrite(): void {
    if (!this.inited || this.writeTimer >= 0) {
      return;
    }
    this.writeTimer = setTimeout(() => {
      this.writeTimer = -1;
      this.write();
    }, LEDGER_WRITE_DELAY_MS);
  }

  /** 有排着的节流写就撤销（立即落盘前调用，避免两次写同一份状态） */
  private cancelScheduledWrite(): void {
    if (this.writeTimer >= 0) {
      clearTimeout(this.writeTimer);
      this.writeTimer = -1;
    }
  }

  private apply(data: PlatformPushData): void {
    const version: number = data.version === undefined ? 0 : data.version;
    if (version > SETTINGS_VERSION) {
      // 比本版更新：字段含义可能已经变了，整份按默认处理
      return;
    }
    if (data.enabled !== undefined) {
      this.enabled = data.enabled;
    }
    if (data.wySelected !== undefined) {
      this.wySelected = data.wySelected;
    }
    if (data.txSelected !== undefined) {
      this.txSelected = data.txSelected;
    }
    if (data.wy !== undefined) {
      this.ledger.wy = trimLedger(data.wy);
    }
    if (data.tx !== undefined) {
      this.ledger.tx = trimLedger(data.tx);
    }
    if (data.wyFailed !== undefined) {
      this.ledger.wyFailed = trimLedger(data.wyFailed);
    }
    if (data.txFailed !== undefined) {
      this.ledger.txFailed = trimLedger(data.txFailed);
    }
    if (data.wyLastError !== undefined) {
      this.wyLastError = data.wyLastError;
    }
    if (data.txLastError !== undefined) {
      this.txLastError = data.txLastError;
    }
    const last: number | undefined = data.lastSyncAt;
    if (last !== undefined && last > 0) {
      this.ledger.lastSyncAt = last;
    }
  }

  /** 把内存里的值同步到 AppStorage，设置页据此渲染 */
  private publish(): void {
    try {
      AppStorage.setOrCreate(K_PLATFORM_PUSH_ENABLED, this.enabled);
      AppStorage.setOrCreate(K_PLATFORM_PUSH_WY, this.wySelected);
      AppStorage.setOrCreate(K_PLATFORM_PUSH_TX, this.txSelected);
    } catch (e) {
      // AppStorage 在 Ability 生命周期里通常可用；环境不支持时设置页会用 @StorageLink 的
      // 默认值，设置仍能改、能落盘。
      hilog.warn(DOMAIN, TAG, 'failed to publish platform push settings: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  /** 总开关（默认 false） */
  isEnabled(): boolean {
    return this.enabled;
  }

  /** 某个平台是否被勾选（'wy' | 'tx'；未知平台给 false） */
  isSelected(platform: string): boolean {
    if (platform === 'wy') {
      return this.wySelected;
    }
    if (platform === 'tx') {
      return this.txSelected;
    }
    return false;
  }

  /** 某平台某首歌是否已经推送过 */
  wasPushed(platform: string, key: string): boolean {
    if (key.length === 0) {
      return false;
    }
    return this.listOf(platform).includes(key);
  }

  /** 上次手动同步完成时间（毫秒；0 = 从没同步过） */
  lastSyncAt(): number {
    return this.ledger.lastSyncAt;
  }

  /** 两个平台账本加起来一共记了多少首（设置页展示用） */
  pushedCount(): number {
    return this.ledger.wy.length + this.ledger.tx.length;
  }

  /** 记下最近一次失败原因（持久化，重启后还在；hilog 排障容易被冲掉） */
  setLastError(platform: string, message: string): void {
    const text: string = message.length > 240 ? message.substring(0, 240) : message;
    if (platform === 'wy') {
      this.wyLastError = text;
    } else if (platform === 'tx') {
      this.txLastError = text;
    } else {
      return;
    }
    this.cancelScheduledWrite();
    this.write();
  }

  /** 最近一次失败原因（空串 = 没有记录） */
  lastErrorOf(platform: string): string {
    return platform === 'wy' ? this.wyLastError : (platform === 'tx' ? this.txLastError : '');
  }

  /** 失败账本里有多少条（设置页展示用） */
  failedCount(): number {
    return this.ledger.wyFailed.length + this.ledger.txFailed.length;
  }

  /** 从数组里移除一个值（不存在就什么也不做） */
  private removeFrom(list: string[], key: string): void {
    const index: number = list.indexOf(key);
    if (index >= 0) {
      list.splice(index, 1);
    }
  }

  /** 失败账本（库内引用，写入方只能通过 markFailed / markPushed / clearLedger） */
  private failedListOf(platform: string): string[] {
    if (platform === 'wy') {
      return this.ledger.wyFailed;
    }
    if (platform === 'tx') {
      return this.ledger.txFailed;
    }
    return [];
  }

  // ---------------------------------------------------------------- 写入

  /** 总开关：落盘 + publish 到 AppStorage */
  setEnabled(on: boolean): void {
    if (this.enabled === on) {
      return;
    }
    this.enabled = on;
    this.cancelScheduledWrite();
    this.write();
    AppStorage.setOrCreate(K_PLATFORM_PUSH_ENABLED, on);
  }

  /** 平台勾选：落盘 + publish（未知平台忽略） */
  setSelected(platform: string, on: boolean): void {
    if (platform === 'wy') {
      if (this.wySelected === on) {
        return;
      }
      this.wySelected = on;
      this.cancelScheduledWrite();
      this.write();
      AppStorage.setOrCreate(K_PLATFORM_PUSH_WY, on);
      return;
    }
    if (platform === 'tx') {
      if (this.txSelected === on) {
        return;
      }
      this.txSelected = on;
      this.cancelScheduledWrite();
      this.write();
      AppStorage.setOrCreate(K_PLATFORM_PUSH_TX, on);
      return;
    }
    hilog.warn(DOMAIN, TAG, 'ignore unknown platform: %{public}s', platform);
  }

  /** 记一笔「已推送到某平台」；超出上限丢最旧的（账本头部）。同时清掉失败标记 */
  markPushed(platform: string, key: string): void {
    if (key.length === 0) {
      return;
    }
    this.removeFrom(this.failedListOf(platform), key);
    const list: string[] = this.listOf(platform);
    if (list.includes(key)) {
      return;
    }
    list.push(key);
    while (list.length > LEDGER_MAX_PER_PLATFORM) {
      list.shift();
    }
    this.scheduleWrite();
  }

  /**
   * 记一笔「这次没推成功」
   *
   * 用途：下次同一首再次触发时（收藏 / 取消收藏）会重试；也用于页面展示「待重试」。
   */
  markFailed(platform: string, key: string): void {
    if (key.length === 0) {
      return;
    }
    this.removeFrom(this.listOf(platform), key);
    const failed: string[] = this.failedListOf(platform);
    if (failed.includes(key)) {
      return;
    }
    failed.push(key);
    while (failed.length > LEDGER_MAX_PER_PLATFORM) {
      failed.shift();
    }
    this.scheduleWrite();
  }

  /** 某平台某首歌上次是不是失败了 */
  wasFailed(platform: string, key: string): boolean {
    if (key.length === 0) {
      return false;
    }
    return this.failedListOf(platform).includes(key);
  }
  /**
   * 划掉一笔「已推送」（取消收藏成功后调用）
   *
   * 语义：这首歌在平台上已经**不再**是我们维护的收藏状态了 —— 用户取消收藏时我们真的把
   * 平台上的「喜欢」删掉了，账本里就不能还记着它。留着的话，用户下次重新收藏会走
   * 「已经推过 → 静默跳过」，平台那边就再也补不回去了（账本把真实状态记错了）。
   */
  unmarkPushed(platform: string, key: string): void {
    if (key.length === 0) {
      return;
    }
    const list: string[] = this.listOf(platform);
    const index: number = list.indexOf(key);
    if (index < 0) {
      return;
    }
    list.splice(index, 1);
    this.scheduleWrite();
  }

  /** 清空已推送记录（两个平台一起清）；开关、勾选与「上次同步时间」都保留不动 */
  clearLedger(): void {
    this.ledger.wy = [];
    this.ledger.tx = [];
    this.ledger.wyFailed = [];
    this.ledger.txFailed = [];
    this.cancelScheduledWrite();
    this.write();
  }

  /** 记下这次手动同步的完成时间并落盘 */
  setLastSyncAt(ms: number): void {
    this.ledger.lastSyncAt = ms > 0 ? ms : 0;
    this.cancelScheduledWrite();
    this.write();
  }

  /**
   * 取某平台的账本数组（返回库内引用，写入方只能通过 markPushed / clearLedger）
   *
   * 未知平台返回一个即用即弃的空数组：调用方 include/push 都不会崩，也不会脏数据。
   */
  private listOf(platform: string): string[] {
    if (platform === 'wy') {
      return this.ledger.wy;
    }
    if (platform === 'tx') {
      return this.ledger.tx;
    }
    return [];
  }
}

/**
 * 读回来的账本裁剪：只留字符串 id、去重、超上限丢最旧
 *
 * 手改过的 JSON / 旧版本数据都可能带进非字符串元素或重复项，这里一次性洗干净，
 * 后面所有判重都只面对干净的 string[]。
 */
function trimLedger(input: string[] | undefined): string[] {
  const out: string[] = [];
  if (!Array.isArray(input)) {
    return out;
  }
  for (const raw of input) {
    if (typeof raw !== 'string') {
      continue;
    }
    // ArkTS 不支持 delete / 展开去重那一套，直接线性判重（2000 条，可接受）
    if (out.includes(raw)) {
      continue;
    }
    out.push(raw);
  }
  while (out.length > LEDGER_MAX_PER_PLATFORM) {
    out.shift();
  }
  return out;
}
