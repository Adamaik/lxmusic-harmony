import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { EQ_BANDS, EQ_GAIN_MAX, EQ_GAIN_MIN } from './AudioEffectSettings';

const DOMAIN: number = 0x0001;
const TAG: string = 'EqPresetStore';
const FILE_NAME: string = 'eq_presets.json';

/** 导出 / 落盘文件里的格式标识：换格式就换它，别复用 */
export const EQ_PRESET_FORMAT: string = 'listen-eq-presets';
/** 文件格式版本；importJson 兼容 <= 本值，更大的报「来自更新版本的聆听」 */
export const EQ_PRESET_VERSION: number = 1;
/**
 * AppStorage 键：值是 list() 的 JSON 字符串
 *
 * 界面用 @StorageLink(K_EQ_CUSTOM_PRESETS) 订阅即可跟着保存 / 删除 / 导入刷新；
 * 初值是 '[]'（init 时 publish 一次，没读过盘也是空列表，@StorageLink 不会拿到 undefined）。
 */
export const K_EQ_CUSTOM_PRESETS: string = 'cfg_eq_custom_presets';
/** 最多存多少套自定义预设（导入时超出按 skipped 丢弃；同名覆盖不受这个上限影响） */
export const EQ_PRESET_MAX: number = 200;
/** 预设名最大长度（trim 后 1..20 字符；界面输入框可以直接拿它做 MaxLength） */
export const EQ_PRESET_NAME_MAX: number = 20;

/** 一套用户命名的自定义音效预设 */
export interface EqCustomPreset {
  /** 用户命名，trim 后 1..20 字符；同名（trim 后完全相同）视为同一套，保存 / 导入按名字覆盖 */
  name: string;
  /** 恰好 10 项，整数 -10..10（与 EQ_BANDS 一一对应；有限数越界 clamp，非有限数整条丢弃） */
  gains: number[];
  /** 首次创建的时刻（毫秒时间戳）：list() 按它升序排，老的在上面 */
  createdAt: number;
}

/** 一次导入的统计结果；error 非空表示整包没导进去（格式 / 版本问题，一条都没动） */
export interface EqImportResult {
  /** 新名字追加了几套 */
  added: number;
  /** 同名但增益不同、被导入覆盖了几套 */
  updated: number;
  /** 同名同增益 / 非法条目 / 超过上限被丢弃的条数 */
  skipped: number;
  /** 中文错误原因；空串 = 导入流程正常走完 */
  error: string;
}

/** 落盘 / 导出共用的文件结构（exportedAt 只在导出时写，落盘不需要） */
interface EqPresetFile {
  format: string;
  version: number;
  exportedAt?: string;
  presets: EqCustomPreset[];
}

// ---------------------------------------------------------------- 校验 / 副本

/** 单段增益收敛到 AudioSuite 能接受的 [-10, 10] 并取整数（与 AudioEffectSettings 的 clamp 同口径） */
function clampGain(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(EQ_GAIN_MIN, Math.min(EQ_GAIN_MAX, Math.round(value)));
}

/** 名字规范化：trim 后 1..20 字符才算合法，否则返回空串（调用方据此判非法） */
function sanitizeName(raw: string): string {
  const name: string = typeof raw === 'string' ? raw.trim() : '';
  if (name.length < 1 || name.length > EQ_PRESET_NAME_MAX) {
    return '';
  }
  return name;
}

/**
 * 增益规范化：必须恰好 10 项、每项都是有限数
 *
 * 有限数越界 → clamp 到 [-10, 10]（别处导入的曲线可能超出 AudioSuite 区间）；
 * 出现 NaN / Infinity、缺项或多一项 → 整条预设丢弃：半套曲线比没有更糟。
 */
function sanitizeGains(raw: number[]): number[] | null {
  if (!Array.isArray(raw) || raw.length !== EQ_BANDS.length) {
    return null;
  }
  const gains: number[] = [];
  for (const value of raw) {
    if (!Number.isFinite(value)) {
      return null;
    }
    gains.push(clampGain(value));
  }
  return gains;
}

/** 两组 10 段增益是否完全一致（保存去重 / 导入判重都用它） */
function gainsEqual(left: number[], right: number[]): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) {
      return false;
    }
  }
  return true;
}

/** list() / 导出用的副本：调用方（页面、同步）改不到内部那一份 */
function copyPreset(preset: EqCustomPreset): EqCustomPreset {
  return {
    name: preset.name,
    gains: preset.gains.slice(),
    createdAt: preset.createdAt,
  };
}

/**
 * 一条预设的清洗（读盘 / 导入共用）
 *
 * 名字与增益非法就整条丢弃；createdAt 非法记 0（排序算最早）——不因为一个坏时间戳
 * 把一条本来能用的预设也丢掉。文件可能来自别的设备或手工编辑，一律不猜。
 */
function sanitizePreset(raw: EqCustomPreset): EqCustomPreset | null {
  if (raw === null || raw === undefined) {
    return null;
  }
  const name: string = sanitizeName(typeof raw.name === 'string' ? raw.name : '');
  const gains: number[] | null = sanitizeGains(raw.gains);
  if (name.length === 0 || gains === null) {
    return null;
  }
  const createdAt: number = typeof raw.createdAt === 'number' && Number.isFinite(raw.createdAt) &&
    raw.createdAt >= 0 ? raw.createdAt : 0;
  const preset: EqCustomPreset = { name: name, gains: gains, createdAt: createdAt };
  return preset;
}

/**
 * 自定义音效预设的存储（音效设置页「保存 / 导出 / 导入」的数据层）
 *
 * 只管数据：命名保存、查找、导出 JSON 文本、导入合并、落盘、AppStorage 发布。
 * 真正把一组增益套到播放上的是 AudioEffectSettings.selectCustomGains（会重播当前曲目），
 * 这里不碰播放器、不认识界面。
 *
 * 与内置九套预设（EQ_PRESETS）分开存：内置的是代码常量，**不**写进这个文件；
 * 用户自定义的才是本机用户数据。这个文件坏了 / 缺了不影响内置预设可用。
 */
export class EqPresetStore {
  private static instance: EqPresetStore | null = null;

  static getInstance(): EqPresetStore {
    if (EqPresetStore.instance === null) {
      EqPresetStore.instance = new EqPresetStore();
    }
    return EqPresetStore.instance;
  }

  private file: string = '';
  private inited: boolean = false;
  /** 内存里的预设（保持创建 / 文件顺序；对外 list() 会再按 createdAt 排序） */
  private presets: EqCustomPreset[] = [];

  /** 绑定沙箱目录并读回预设。EntryAbility.onCreate 里调一次；幂等 */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      this.apply(text);
    }
    // 初值 / 读回来的列表都同步到 AppStorage
    this.publish();
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read eq presets: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * 读盘并逐条校验
   *
   * format / version 对不上就整份不用（内置预设不受影响），单条坏记录丢掉；
   * 同名只保留**先读到**的那一份（文件顺序即创建顺序），最多留 EQ_PRESET_MAX 套。
   */
  private apply(text: string): void {
    let data: EqPresetFile;
    try {
      data = JSON.parse(text) as EqPresetFile;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to parse eq presets: %{public}s', JSON.stringify(e));
      return;
    }
    if (data === null || data === undefined) {
      return;
    }
    if (data.format !== EQ_PRESET_FORMAT) {
      hilog.warn(DOMAIN, TAG, 'eq presets file has unexpected format, ignored');
      return;
    }
    if (typeof data.version !== 'number' || data.version > EQ_PRESET_VERSION) {
      hilog.warn(DOMAIN, TAG, 'eq presets file version is newer or invalid, ignored');
      return;
    }
    if (!Array.isArray(data.presets)) {
      return;
    }
    const kept: EqCustomPreset[] = [];
    const seen: Set<string> = new Set();
    const entries: EqCustomPreset[] = data.presets;
    for (const one of entries) {
      const clean: EqCustomPreset | null = sanitizePreset(one);
      if (clean === null) {
        continue;
      }
      if (seen.has(clean.name)) {
        continue;
      }
      seen.add(clean.name);
      kept.push(clean);
      if (kept.length >= EQ_PRESET_MAX) {
        break;
      }
    }
    this.presets = kept;
    hilog.info(DOMAIN, TAG, 'eq presets ready, %{public}d preset(s)', this.presets.length);
  }

  /** 按名字找内部下标（调用方已保证名字是 sanitizeName 过的） */
  private indexOf(name: string): number {
    for (let i = 0; i < this.presets.length; i++) {
      if (this.presets[i].name === name) {
        return i;
      }
    }
    return -1;
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    // 按 list() 的顺序写（createdAt 升序）：文件自己就是稳定的，读回来顺序不变
    const data: EqPresetFile = {
      format: EQ_PRESET_FORMAT,
      version: EQ_PRESET_VERSION,
      presets: this.list(),
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
      hilog.warn(DOMAIN, TAG, 'failed to write eq presets: %{public}s', JSON.stringify(e));
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_EQ_CUSTOM_PRESETS, JSON.stringify(this.list()));
    } catch (e) {
      // 与其它设置类一致：AppStorage 不可用也不能让数据操作失败
      hilog.warn(DOMAIN, TAG, 'failed to publish eq presets: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读

  /**
   * 全部自定义预设（副本）
   *
   * 按 createdAt 升序（老的在上，新存的在下面 —— 与页面列表的直觉一致），
   * 同一毫秒按名字兜底，保证顺序稳定；未 init 返回空数组。
   */
  list(): EqCustomPreset[] {
    const out: EqCustomPreset[] = [];
    for (const preset of this.presets) {
      out.push(copyPreset(preset));
    }
    out.sort((left: EqCustomPreset, right: EqCustomPreset): number => {
      if (left.createdAt !== right.createdAt) {
        return left.createdAt - right.createdAt;
      }
      return left.name.localeCompare(right.name);
    });
    return out;
  }

  /**
   * 有没有和这组增益完全相同的已存预设
   *
   * 传进来的增益先按保存口径规范化（clamp / 取整）再比，避免「界面上 -10.0 与存进去的 -10」
   * 因浮点误差判不等；未 init 或增益非法返回 null。
   */
  findEqual(gains: number[]): EqCustomPreset | null {
    if (!this.inited) {
      return null;
    }
    const clean: number[] | null = sanitizeGains(gains);
    if (clean === null) {
      return null;
    }
    for (const preset of this.presets) {
      if (gainsEqual(preset.gains, clean)) {
        return copyPreset(preset);
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- 写

  /**
   * 保存一套自定义预设
   *
   * 同名（trim 后）视为同一套：覆盖增益、**保留首次创建时间**（列表位置不跳，
   * 用户不会因为「覆盖保存」发现它突然跑到最上面）。新增时 createdAt = 现在。
   *
   * 非法输入（名字空 / 超 20 字、增益不是 10 段有限数）返回 null，不动现有数据；
   * 已满 EQ_PRESET_MAX 套时新增也返回 null（覆盖同名不受限），界面用 list().length 提示上限。
   *
   * @returns 保存后的预设副本（含规范化后的名字 / 增益 / createdAt）；非法返回 null
   */
  save(name: string, gains: number[]): EqCustomPreset | null {
    if (!this.inited) {
      return null;
    }
    const cleanName: string = sanitizeName(name);
    const cleanGains: number[] | null = sanitizeGains(gains);
    if (cleanName.length === 0 || cleanGains === null) {
      return null;
    }
    const found: number = this.indexOf(cleanName);
    let saved: EqCustomPreset;
    if (found >= 0) {
      saved = { name: cleanName, gains: cleanGains, createdAt: this.presets[found].createdAt };
      this.presets[found] = saved;
    } else {
      if (this.presets.length >= EQ_PRESET_MAX) {
        return null;
      }
      saved = { name: cleanName, gains: cleanGains, createdAt: Date.now() };
      this.presets.push(saved);
    }
    this.write();
    this.publish();
    return copyPreset(saved);
  }

  /** 删掉一套预设（按 trim 后的名字）；返回是否真的删了。未 init / 名字不存在都返回 false */
  remove(name: string): boolean {
    if (!this.inited) {
      return false;
    }
    const cleanName: string = sanitizeName(name);
    if (cleanName.length === 0) {
      return false;
    }
    const found: number = this.indexOf(cleanName);
    if (found < 0) {
      return false;
    }
    this.presets.splice(found, 1);
    this.write();
    this.publish();
    return true;
  }

  // ---------------------------------------------------------------- 导出 / 导入

  /**
   * 把选中的几套预设导出成可分享的 JSON 文本
   *
   * 固定格式：`{ format, version, exportedAt, presets: [{ name, gains, createdAt }] }`，
   * 用 2 空格缩进 —— 文本要贴给别人，人可读比省字节重要。exportedAt 只给「哪一刻导的」
   * 看，导入端不依赖它；未知字段在导入时一律忽略。
   *
   * names 为空 / 一个都没匹配 / 未 init 时返回空串，不抛异常：调用方（页面）
   * 用「空串 = 没东西可导」提示即可，少一层 try/catch。
   */
  exportJson(names: string[]): string {
    if (!this.inited || !Array.isArray(names) || names.length === 0) {
      return '';
    }
    const picked: EqCustomPreset[] = [];
    const seen: Set<string> = new Set();
    for (const raw of names) {
      const name: string = sanitizeName(typeof raw === 'string' ? raw : '');
      if (name.length === 0 || seen.has(name)) {
        continue;
      }
      const found: number = this.indexOf(name);
      if (found < 0) {
        continue;
      }
      seen.add(name);
      picked.push(copyPreset(this.presets[found]));
    }
    if (picked.length === 0) {
      return '';
    }
    const file: EqPresetFile = {
      format: EQ_PRESET_FORMAT,
      version: EQ_PRESET_VERSION,
      exportedAt: new Date().toISOString(),
      presets: picked,
    };
    return JSON.stringify(file, null, 2);
  }

  /**
   * 导入一份预设 JSON 并合并进本机
   *
   * 合并规则（按 trim 后的名字认同一套）：
   *   - 同名 + 增益完全一致 → skipped（重复导入不会刷出重复条目）；
   *   - 同名 + 增益不同     → 用导入的那份覆盖（含它的 createdAt）→ updated；
   *   - 新名字             → 追加 → added；已满 EQ_PRESET_MAX 后新名字按 skipped 丢弃
   *                         （覆盖同名不受上限影响）。
   * 坏条目（名字 / 增益 / 时间戳非法）跳过并计入 skipped；整包格式或版本不对则 error 非空、
   * 一条都不动。只有真的 added / updated 才落盘 + 发布（只是重复导入不会有任何写盘）。
   *
   * 兼容性：version <= EQ_PRESET_VERSION 都收；version 更大报「来自更新版本的聆听」，
   * 不去猜新格式字段；未知字段忽略（只读 format / version / presets）。
   */
  importJson(text: string): EqImportResult {
    const result: EqImportResult = { added: 0, updated: 0, skipped: 0, error: '' };
    if (!this.inited) {
      result.error = '本地存储还没准备好，稍后再试';
      return result;
    }
    const raw: string = typeof text === 'string' ? text.trim() : '';
    if (raw.length === 0) {
      result.error = '导入内容为空';
      return result;
    }
    let data: EqPresetFile;
    try {
      data = JSON.parse(raw) as EqPresetFile;
    } catch (e) {
      result.error = '导入内容不是有效的 JSON';
      return result;
    }
    if (data === null || data === undefined) {
      result.error = '导入内容为空';
      return result;
    }
    if (data.format !== EQ_PRESET_FORMAT) {
      result.error = '不是「聆听」的音效预设文件';
      return result;
    }
    if (typeof data.version !== 'number' || data.version <= 0) {
      result.error = '预设文件缺少版本号，无法导入';
      return result;
    }
    if (data.version > EQ_PRESET_VERSION) {
      result.error = `这些预设来自更新版本的聆听（版本 ${data.version}），请先升级应用`;
      return result;
    }
    if (!Array.isArray(data.presets)) {
      result.error = '预设文件里没有预设列表';
      return result;
    }
    const entries: EqCustomPreset[] = data.presets;
    for (const one of entries) {
      const clean: EqCustomPreset | null = sanitizePreset(one);
      if (clean === null) {
        result.skipped += 1;
        continue;
      }
      const found: number = this.indexOf(clean.name);
      if (found >= 0) {
        if (gainsEqual(this.presets[found].gains, clean.gains)) {
          result.skipped += 1;
          continue;
        }
        this.presets[found] = clean;
        result.updated += 1;
        continue;
      }
      if (this.presets.length >= EQ_PRESET_MAX) {
        result.skipped += 1;
        continue;
      }
      this.presets.push(clean);
      result.added += 1;
    }
    if (result.added > 0 || result.updated > 0) {
      this.write();
      this.publish();
    }
    return result;
  }
}
