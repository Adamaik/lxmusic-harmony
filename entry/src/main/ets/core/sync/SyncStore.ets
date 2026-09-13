import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxListData, LxMusicInfoNew, LxUserListInfoFull, SyncKeyInfo } from './SyncTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SyncStore';

const STORE_DIR: string = 'lx_sync';
const CONFIG_FILE: string = 'config.json';
const KEYS_FILE: string = 'keys.json';
const LIST_FILE: string = 'list.json';
const DISLIKE_FILE: string = 'dislike.json';

/** 同步开关 / 服务器地址 / 设备名 */
export interface SyncConfig {
  enable: boolean;
  host: string;
  deviceName: string;
  hostHistory: string[];
}

function defaultConfig(): SyncConfig {
  return { enable: false, host: '', deviceName: '', hostHistory: [] };
}

export function defaultListData(): LxListData {
  return { defaultList: [], loveList: [], userList: [] };
}

/**
 * 同步相关的本地存储
 *
 * 对应洛雪 utils/data.ts 里 syncHost / syncAuthKey 那几项，外加音乐库本身。
 * HarmonyOS 的 preferences 不适合存可能很大的列表数据，因此统一落到应用沙箱文件
 * （与 SourceStore 的做法一致）。列表数据按洛雪的线上格式保存，这样：
 *   1) 重连时计算 md5 的 JSON 与收到的报文同构，能与服务端的快照 key 对上；
 *   2) 文件本身就是「同步数据」的可读副本，排查问题直接看它即可。
 */
export class SyncStore {
  private dir: string = '';
  private ready: boolean = false;

  init(context: common.Context): void {
    this.dir = `${context.filesDir}/${STORE_DIR}`;
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
      this.ready = true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'create store dir failed: %{public}s', JSON.stringify(e));
      this.ready = false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  private path(file: string): string {
    return `${this.dir}/${file}`;
  }

  private readText(file: string): string | null {
    if (!this.ready) {
      return null;
    }
    try {
      const target: string = this.path(file);
      if (!fs.accessSync(target)) {
        return null;
      }
      return fs.readTextSync(target);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read %{public}s failed: %{public}s', file, JSON.stringify(e));
      return null;
    }
  }

  private writeText(file: string, text: string): void {
    if (!this.ready) {
      throw new Error('同步存储未初始化');
    }
    const target: string = this.path(file);
    const handle = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(handle.fd, text);
    } finally {
      fs.closeSync(handle);
    }
  }

  // ------------------------------------------------------------ 配置

  loadConfig(): SyncConfig {
    const text: string | null = this.readText(CONFIG_FILE);
    const config: SyncConfig = defaultConfig();
    if (text === null) {
      config.deviceName = defaultDeviceName();
      return config;
    }
    try {
      const raw = JSON.parse(text) as SyncConfig;
      config.enable = raw.enable === true;
      config.host = typeof raw.host === 'string' ? raw.host : '';
      config.deviceName = (typeof raw.deviceName === 'string' && raw.deviceName.length > 0)
        ? raw.deviceName : defaultDeviceName();
      config.hostHistory = Array.isArray(raw.hostHistory) ? raw.hostHistory : [];
      return config;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse config failed: %{public}s', JSON.stringify(e));
      config.deviceName = defaultDeviceName();
      return config;
    }
  }

  saveConfig(config: SyncConfig): void {
    try {
      this.writeText(CONFIG_FILE, JSON.stringify(config));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save config failed: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 身份密钥（按 serverId 存）

  loadKey(serverId: string): SyncKeyInfo | null {
    const text: string | null = this.readText(KEYS_FILE);
    if (text === null) {
      return null;
    }
    try {
      const keys = JSON.parse(text) as Record<string, SyncKeyInfo>;
      const info: SyncKeyInfo | undefined = keys[serverId];
      return info === undefined ? null : info;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse keys failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  saveKey(serverId: string, info: SyncKeyInfo): void {
    let keys: Record<string, SyncKeyInfo> = {};
    const text: string | null = this.readText(KEYS_FILE);
    if (text !== null) {
      try {
        keys = JSON.parse(text) as Record<string, SyncKeyInfo>;
      } catch (e) {
        keys = {};
      }
    }
    keys[serverId] = info;
    try {
      this.writeText(KEYS_FILE, JSON.stringify(keys));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save keys failed: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 音乐库（洛雪线上格式）

  /** 是否已经落过一份音乐库：用来区分「首次安装（界面上的演示数据先留着）」 */
  hasListData(): boolean {
    if (!this.ready) {
      return false;
    }
    try {
      return fs.accessSync(this.path(LIST_FILE));
    } catch (e) {
      return false;
    }
  }

  loadListData(): LxListData {
    const data: LxListData = defaultListData();
    const text: string | null = this.readText(LIST_FILE);
    if (text === null) {
      return data;
    }
    try {
      const raw = JSON.parse(text) as LxListData;
      data.defaultList = normalizeMusics(raw.defaultList);
      data.loveList = normalizeMusics(raw.loveList);
      data.userList = normalizeUserList(raw.userList);
      return data;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse list data failed: %{public}s', JSON.stringify(e));
      return data;
    }
  }

  saveListData(data: LxListData): void {
    try {
      this.writeText(LIST_FILE, JSON.stringify(data));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save list data failed: %{public}s', JSON.stringify(e));
    }
  }

  // ------------------------------------------------------------ 不喜欢规则

  loadDislikeRules(): string {
    const text: string | null = this.readText(DISLIKE_FILE);
    if (text === null) {
      return '';
    }
    try {
      const raw = JSON.parse(text) as Record<string, string>;
      return typeof raw['rules'] === 'string' ? raw['rules'] : '';
    } catch (e) {
      return '';
    }
  }

  saveDislikeRules(rules: string): void {
    try {
      this.writeText(DISLIKE_FILE, JSON.stringify({ rules: rules }));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save dislike rules failed: %{public}s', JSON.stringify(e));
    }
  }
}

/** 设备名：优先市场名，其次产品型号，最后落一个可读兜底 */
export function defaultDeviceName(): string {
  try {
    const market: string = deviceInfo.marketName;
    if (market !== undefined && market.length > 0) {
      return market;
    }
    const model: string = deviceInfo.productModel;
    if (model !== undefined && model.length > 0) {
      return model;
    }
    const brand: string = deviceInfo.brand;
    if (brand !== undefined && brand.length > 0) {
      return `${brand} HarmonyOS`;
    }
  } catch (e) {
    // 某些设备上 deviceInfo 取不到，走兜底
  }
  return 'HarmonyOS';
}

function normalizeMusics(input: LxMusicInfoNew[] | undefined): LxMusicInfoNew[] {
  if (!Array.isArray(input)) {
    return [];
  }
  const out: LxMusicInfoNew[] = [];
  for (const item of input) {
    if (item !== null && item !== undefined && typeof item.id === 'string' && item.id.length > 0) {
      out.push(item);
    }
  }
  return out;
}

function normalizeUserList(input: LxUserListInfoFull[] | undefined): LxUserListInfoFull[] {
  if (!Array.isArray(input)) {
    return [];
  }
  const out: LxUserListInfoFull[] = [];
  for (const item of input) {
    if (item === null || item === undefined || typeof item.id !== 'string' || item.id.length === 0) {
      continue;
    }
    const list: LxUserListInfoFull = {
      id: item.id,
      name: typeof item.name === 'string' ? item.name : item.id,
      locationUpdateTime: typeof item.locationUpdateTime === 'number' ? item.locationUpdateTime : null,
      list: normalizeMusics(item.list),
    };
    if (typeof item.source === 'string') {
      list.source = item.source;
    }
    if (typeof item.sourceListId === 'string') {
      list.sourceListId = item.sourceListId;
    }
    out.push(list);
  }
  return out;
}
