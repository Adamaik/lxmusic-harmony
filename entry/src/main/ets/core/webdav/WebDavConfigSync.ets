/**
 * 网盘配置同步（WebDAV）—— 取代「必须自建洛雪服务端」的换设备迁移方式
 *
 * 群反馈（2026-11-22，邦邦不吃香菜 + 小冰）：换新手机时「不同设备之间怎么导入聆听歌单」，
 * 现有同步只支持洛雪服务端 / 电脑端，普通用户没有服务器，两台手机也不能直连。小冰建议
 * 用网盘传配置文件（『阅读』的 webdav 那样）——配置只有几十 KB，网盘空间完全够。
 *
 * 分工：
 *   - 文件格式与本地数据转换在 WebDavConfigData（schema / 快照 / 解析 / 合并）；
 *   - 协议在 WebDavClient（PUT / MKCOL / GET）；
 *   - 账号与目录在 WebDavSettings（与「云端音乐」共用同一个 WebDAV 账号，不用填两遍）；
 *   - 本文件只管「什么时候传、什么时候提示、失败怎么说」。
 *
 * 三条产品约定（都是「别打扰、别覆盖」）：
 *   1. **自动同步只在应用启动 / 退出各试一次**，不常驻、不轮询；失败静默（只进日志），
 *      下次启动再试。手动按钮随时可用。
 *   2. **自动同步永不自动恢复**：网盘上的 exportedAt 比本机上次同步的更新时，只把提示
 *      写到设置页，由用户点「从网盘恢复」才动本地库。
 *   3. **恢复是合并不是替换**：重名歌单加「 (2)」，本机已有歌单一个字不动；设置项按文件
 *      里带的项覆盖（带哪项写哪项），不带的不动。
 */

import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebDavClient, describeUrlForMessage } from './WebDavClient';
import { WebDavConfig, WebDavProbeResult } from './WebDavTypes';
import { WebDavSettings } from './WebDavSettings';
import {
  ConfigMergeOutcome,
  ConfigParseResult,
  ConfigSnapshot,
  ConfigSyncFile,
  buildConfigSnapshot,
  buildFolderUrl,
  configFileUrl,
  countSongs,
  describeSettings,
  fingerprintOf,
  isRemoteNewer,
  mergePlaylists,
  applySettings,
  parseConfigFile,
} from './WebDavConfigData';
import { defaultDeviceName } from '../sync/SyncStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'WebDavConfigSync';

/** 同一段时间内只试一次：前台回调可能连着来（创建 + 获得焦点），别重复发请求 */
const MIN_ATTEMPT_GAP_MS: number = 20000;

/** 状态行（设置页那张卡直接显示它） */
export const K_CONFIG_SYNC_STATUS: string = 'config_sync_status';
/** 上次成功同步的时间（ISO，界面自己格式化） */
export const K_CONFIG_SYNC_AT: string = 'config_sync_at';
/** 「网盘上有更新的配置」这类提示（空串 = 没有） */
export const K_CONFIG_SYNC_NOTICE: string = 'config_sync_notice';

/** 恢复前的预览：给用户看清「要导入多少东西」再决定 */
export interface ConfigSyncPreview {
  ok: boolean;
  message: string;
  /** 网盘那份的导出时间（ISO） */
  exportedAt: string;
  playlists: number;
  songs: number;
  /** 设置项摘要（「音质 320K · 播放页动效 轻量」） */
  settingsText: string;
  /** 网盘那份比本机上次同步的更新（界面可以据此把按钮写成「恢复较新的配置」） */
  newer: boolean;
  file: ConfigSyncFile | null;
}

/** 上传 / 恢复的结果（message 直接给用户看） */
export interface ConfigSyncOutcome {
  ok: boolean;
  message: string;
  playlists: number;
  songs: number;
  skippedSongs: number;
  renamed: number;
}

/** 读网盘的结果：text 为 null 表示文件不存在；error 非空表示读失败或格式不认识 */
interface RemoteConfig {
  text: string | null;
  file: ConfigSyncFile | null;
  hash: string;
  error: string;
}

/**
 * 自动同步的触发点（'start' = 启动 / 回到前台，'exit' = 退到后台 / 退出）
 *
 * 两个点做的事一样（先比对再决定传不传），保留参数只为日志与以后分叉。
 */
type ConfigSyncTrigger = 'start' | 'exit';

export class WebDavConfigSync {
  private static instance: WebDavConfigSync | null = null;

  static getInstance(): WebDavConfigSync {
    if (WebDavConfigSync.instance === null) {
      WebDavConfigSync.instance = new WebDavConfigSync();
    }
    return WebDavConfigSync.instance;
  }

  private inited: boolean = false;
  private running: boolean = false;
  private lastAttemptMs: number = 0;

  /**
   * 在 SyncManager.init（EntryAbility.onCreate）里调用
   *
   * 注意这时 WebDavSettings 还没 init（它在 onCreate 更靠后），所以这里**不能**读配置，
   * 只登记生命周期回调并发布初始状态；真正的尝试都发生在回到前台 / 退到后台时，
   * 那时所有设置都已经读回来了。
   */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.inited = true;
    this.publishSyncedAt();
    this.publishNotice('');
    this.registerLifecycle(context);
  }

  isInited(): boolean {
    return this.inited;
  }

  /** 回到前台（SyncManager.ensureConnected 里也直接调一次：生命周期回调之外的保险） */
  onAppResumed(): void {
    this.publishSyncedAt();
    void this.tryAuto('start');
  }

  /**
   * 登记应用前后台回调
   *
   * 为什么不用 EntryAbility 里的 onForeground / onBackground：本模块不允许改 EntryAbility
   * （那是壳层的地盘），而 applicationContext 的 `applicationStateChange` 就是官方给
   * 「与壳层解耦的进程级前后台监听」用的接口 —— 语义正好是「应用启动 / 退出」，
   * 且只有一个入口（不会像 abilityLifecycle 那样每个 UIAbility 各回调一遍）。
   * 注册失败也不影响手动上传 / 恢复（只是没有自动那一次）。
   */
  private registerLifecycle(context: common.Context): void {
    try {
      const callback: ApplicationStateChangeCallback = {
        onApplicationForeground(): void {
          // 用单例而不是 this：回调对象里的 this 指不到这个类
          WebDavConfigSync.getInstance().onAppResumed();
        },
        onApplicationBackground(): void {
          WebDavConfigSync.getInstance().onAppPaused();
        },
      };
      context.getApplicationContext().on('applicationStateChange', callback);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'register lifecycle failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 退到后台 / 退出：只有本地确实比网盘新时才上传（不恢复、不打扰） */
  onAppPaused(): void {
    void this.tryAuto('exit');
  }

  // ------------------------------------------------------------ 手动操作（设置页按钮）

  /**
   * 测试连接：列一次根目录，再试建一次同步目录
   *
   * 「目录自动创建」这件事要在按钮上就能验证，不要等用户点上传才发现权限不够。
   */
  async testConnection(): Promise<string> {
    const settings = WebDavSettings.getInstance();
    if (!settings.isReady()) {
      return '设置还没准备好，稍后再试';
    }
    const config: WebDavConfig = settings.config();
    if (config.url.length === 0) {
      return '请先填服务器地址';
    }
    if (this.running) {
      return '正在同步中，请稍候';
    }
    this.running = true;
    try {
      const probe: WebDavProbeResult = await WebDavClient.getInstance().probe(config);
      if (!probe.ok) {
        return `连不上：${probe.message}`;
      }
      const folder: string = buildFolderUrl(config.url, settings.getSyncDir());
      await WebDavClient.getInstance().ensureFolder(config, folder);
      // 地址里可能带 user:pass@：只回 host + 路径，别把密码显示到界面/日志里
      return `连上了，配置目录可用：${describeUrlForMessage(folder)}`;
    } catch (e) {
      return `连不上：${describeError(e as Error)}`;
    } finally {
      this.running = false;
    }
  }

  /**
   * 手动上传（用户点了按钮：无论如何都传，但仍会先看一眼网盘有没有更新的版本并提示）
   */
  async uploadNow(): Promise<ConfigSyncOutcome> {
    const settings = WebDavSettings.getInstance();
    if (!settings.isReady()) {
      return failOutcome('设置还没准备好，稍后再试');
    }
    const config: WebDavConfig = settings.config();
    if (config.url.length === 0) {
      return failOutcome('请先填服务器地址');
    }
    if (this.running) {
      return failOutcome('正在同步中，请稍候');
    }
    this.running = true;
    this.publishStatus('正在上传配置…');
    try {
      const snapshot: ConfigSnapshot = buildConfigSnapshot(deviceNameOf());
      const hash: string = fingerprintOf(snapshot.file);
      let note: string = '';
      // 读网盘只为提示：读不到（权限 / 网络）也不该挡住上传，静默跳过这一段
      try {
        const remote: RemoteConfig = await this.fetchRemote(config);
        if (remote.file !== null && isRemoteNewer(remote.file, settings.getLastSyncedAt())) {
          note = `\n注意：网盘上原有一份更新的配置（${describeStamp(remote.file.exportedAt)}），`
            + '这次上传把它覆盖了。若那才是你要的，请在另一台设备上再传一次。';
        }
      } catch (e) {
        hilog.info(DOMAIN, TAG, 'skip remote check before upload: %{public}s', describeError(e as Error));
      }
      await this.uploadFile(config, snapshot, hash);
      // 用户手动上传 = 明确要覆盖网盘：之前「刚恢复过、别自动上传」的标记作废
      settings.clearRestoredPendingSkip();
      const message: string = this.uploadMessage(snapshot, note);
      this.publishStatus(`已上传：${snapshot.playlists} 个歌单、${snapshot.songs} 首歌`);
      this.publishNotice('');
      return {
        ok: true,
        message: message,
        playlists: snapshot.playlists,
        songs: snapshot.songs,
        skippedSongs: snapshot.skippedSongs,
        renamed: 0,
      };
    } catch (e) {
      const message: string = describeError(e as Error);
      this.publishStatus(`上传失败：${message}`);
      return failOutcome(message);
    } finally {
      this.running = false;
    }
  }

  /** 读取网盘上的配置并算出预览（不写本地任何数据） */
  async previewRemote(): Promise<ConfigSyncPreview> {
    const settings = WebDavSettings.getInstance();
    const blank: ConfigSyncPreview = {
      ok: false,
      message: '',
      exportedAt: '',
      playlists: 0,
      songs: 0,
      settingsText: '',
      newer: false,
      file: null,
    };
    if (!settings.isReady()) {
      blank.message = '设置还没准备好，稍后再试';
      return blank;
    }
    const config: WebDavConfig = settings.config();
    if (config.url.length === 0) {
      blank.message = '请先填服务器地址';
      return blank;
    }
    if (this.running) {
      blank.message = '正在同步中，请稍候';
      return blank;
    }
    this.running = true;
    this.publishStatus('正在读取网盘上的配置…');
    try {
      const remote: RemoteConfig = await this.fetchRemote(config);
      if (remote.error.length > 0) {
        this.publishStatus(remote.error);
        blank.message = remote.error;
        return blank;
      }
      const file: ConfigSyncFile | null = remote.file;
      if (remote.text === null || file === null) {
        const message: string = '网盘上还没有配置，先在这台设备上点「上传配置」';
        this.publishStatus(message);
        blank.message = message;
        return blank;
      }
      const preview: ConfigSyncPreview = {
        ok: true,
        message: '',
        exportedAt: file.exportedAt,
        playlists: file.playlists.length,
        songs: countSongs(file),
        settingsText: describeSettings(file.settings),
        newer: isRemoteNewer(file, settings.getLastSyncedAt()),
        file: file,
      };
      this.publishStatus('');
      return preview;
    } catch (e) {
      const message: string = describeError(e as Error);
      this.publishStatus(`读取失败：${message}`);
      blank.message = message;
      return blank;
    } finally {
      this.running = false;
    }
  }

  /**
   * 按预览里的文件恢复（用户已经点过确认）
   *
   * 只在这个入口写本地库和本地设置 —— 自动同步永远不会走到这里。
   */
  async restore(file: ConfigSyncFile): Promise<ConfigSyncOutcome> {
    const settings = WebDavSettings.getInstance();
    if (this.running) {
      return failOutcome('正在同步中，请稍候');
    }
    this.running = true;
    this.publishStatus('正在恢复配置…');
    try {
      const merged: ConfigMergeOutcome = mergePlaylists(file.playlists);
      let applied: number = 0;
      if (file.settings !== undefined) {
        applied = applySettings(file.settings);
      }
      const ok: boolean = merged.playlists > 0 || applied > 0;
      // 恢复成功 = 本机与网盘对齐了：记下这份的 exportedAt 与指纹，之后自动同步才不会
      // 又把用户刚恢复的这份当成「网盘上更新的」反复提示
      settings.setSyncState(file.exportedAt, fingerprintOf(file));
      if (ok) {
        // 但恢复是**合并**（重名加 (2)、跳过的歌），本地指纹必然不等于网盘那份。
        // 只写同步戳的话，下一轮 runAuto 会判成「本机改过」并把合并结果上传回去，
        // 把另一台设备的配置覆盖成带 (2) 的重复歌单。这里落一个「跳过下一轮上传」的标记。
        settings.markRestoredPendingSkip();
      }
      this.publishSyncedAt();
      let message: string = `已恢复 ${merged.playlists} 个歌单、${merged.songs} 首歌曲`;
      if (applied > 0) {
        message += `，并应用了 ${applied} 项设置`;
      }
      if (merged.renamed > 0) {
        message += `\n${merged.renamed} 个同名歌单已加后缀（本机原来的歌单没有动）`;
      }
      if (merged.skippedSongs > 0) {
        message += `\n${merged.skippedSongs} 首歌曲没能导入（未匹配或重复），已跳过`;
      }
      if (merged.emptyPlaylists > 0) {
        message += `\n${merged.emptyPlaylists} 个空歌单已忽略`;
      }
      if (ok) {
        message += '\n已恢复的是合并结果：下一轮自动同步不会自动上传，避免把网盘覆盖成重复歌单'
          + '（确认本机歌单无误后，可点「上传配置」手动覆盖）。';
      }
      this.publishStatus(ok ? message : '网盘上的配置里没有可恢复的内容');
      this.publishNotice(ok
        ? '已从网盘恢复配置。下一轮自动同步不会自动上传（本机是合并结果）；需要覆盖网盘时请点「上传配置」。'
        : '');
      return {
        ok: ok,
        message: message,
        playlists: merged.playlists,
        songs: merged.songs,
        skippedSongs: merged.skippedSongs,
        renamed: merged.renamed,
      };
    } catch (e) {
      const message: string = describeError(e as Error);
      this.publishStatus(`恢复失败：${message}`);
      return failOutcome(message);
    } finally {
      this.running = false;
    }
  }

  // ------------------------------------------------------------ 自动同步

  /**
   * 自动同步的一次尝试（启动 / 退出都走这里）
   *
   * 静默原则：没开自动同步、没配服务器、正在跑、刚跑过 —— 都直接返回；抛出的异常只进
   * 日志，界面不该因为「后台偷偷同步失败」跳提示。失败不写 lastSyncedAt，下次会重试。
   */
  private async tryAuto(trigger: ConfigSyncTrigger): Promise<void> {
    const settings = WebDavSettings.getInstance();
    if (!this.inited || this.running || !settings.isReady()) {
      return;
    }
    if (!settings.isAutoSync() || !settings.isConfigured()) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastAttemptMs < MIN_ATTEMPT_GAP_MS) {
      return;
    }
    this.lastAttemptMs = now;
    this.running = true;
    try {
      await this.runAuto(trigger, settings.config());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'auto config sync failed (%{public}s): %{public}s', trigger,
        describeError(e as Error));
    } finally {
      this.running = false;
    }
  }

  /**
   * 自动同步的判断顺序（每一步都只读本机状态，不写歌单）
   *
   *   网盘没有文件            → 上传（第一次）
   *   内容与本机完全一样      → 什么都不做，只对齐同步戳
   *   网盘比本机上次同步的新  → 只提示，不上传（不覆盖另一台设备的改动）
   *   其它（本机有改动）      → 上传
   */
  private async runAuto(trigger: ConfigSyncTrigger, config: WebDavConfig): Promise<void> {
    const settings = WebDavSettings.getInstance();
    const snapshot: ConfigSnapshot = buildConfigSnapshot(deviceNameOf());
    const localHash: string = fingerprintOf(snapshot.file);
    const remote: RemoteConfig = await this.fetchRemote(config);
    if (remote.error.length > 0) {
      // 网盘上的文件不是我们的 / 读不了：不覆盖，也不自动恢复，只把原因留在设置页
      this.publishStatus(remote.error);
      this.publishNotice('');
      return;
    }
    if (remote.text === null) {
      await this.uploadFile(config, snapshot, localHash);
      // 网盘上没有文件就没有「覆盖别人的合并副本」这回事，恢复后的跳过标记到这里失效
      settings.clearRestoredPendingSkip();
      this.publishStatus(`已自动上传：${snapshot.playlists} 个歌单、${snapshot.songs} 首歌`);
      this.publishNotice('');
      return;
    }
    const remoteFile: ConfigSyncFile | null = remote.file;
    if (remoteFile === null) {
      return;
    }
    if (remote.hash === localHash) {
      // 内容一样：只把同步戳对齐到网盘那份（以后网盘再变才算「更新」）
      settings.setSyncState(remoteFile.exportedAt, remote.hash);
      // 内容已经一致，恢复后要防的「把合并副本传上去」已经不成立
      settings.clearRestoredPendingSkip();
      this.publishSyncedAt();
      this.publishStatus('网盘配置与本机一致');
      this.publishNotice('');
      return;
    }
    if (isRemoteNewer(remoteFile, settings.getLastSyncedAt())) {
      this.publishStatus('网盘上的配置比本机新，已跳过自动上传');
      this.publishNotice(`网盘上有更新的配置（${describeStamp(remoteFile.exportedAt)}），`
        + '点下面的「从网盘恢复」可以取回来');
      return;
    }
    // 走到这里说明：内容不同，且网盘那份不比本机上次同步的新 —— 一般是本机改过。
    // 例外：刚「从网盘恢复」过（合并结果，指纹必然与网盘不同）。此时绝不能上传，
    // 否则会把另一台设备的配置覆盖成带「 (2)」的合并副本。
    // 标记**保留到用户手动上传**（或云端无文件 / 内容已一致）才清：
    // 只跳过一轮的话，下一轮自动同步仍会上传合并副本，等于把问题推后一次。
    if (settings.isRestoredPendingSkip()) {
      this.publishStatus('已从网盘恢复配置，自动同步暂停上传（避免把网盘覆盖成合并后的重复歌单）');
      this.publishNotice('已恢复网盘配置；自动同步不会上传。确认本机歌单无误后点「上传配置」手动覆盖网盘。');
      hilog.info(DOMAIN, TAG, 'skip auto upload after restore (%{public}s), pending manual upload', trigger);
      return;
    }
    await this.uploadFile(config, snapshot, localHash);
    this.publishStatus(`已自动上传：${snapshot.playlists} 个歌单、${snapshot.songs} 首歌`);
    this.publishNotice('');
    hilog.info(DOMAIN, TAG, 'auto upload done from %{public}s', trigger);
  }

  // ------------------------------------------------------------ 网络

  /** 读网盘上的配置文件（404 = text 为 null） */
  private async fetchRemote(config: WebDavConfig): Promise<RemoteConfig> {
    const settings = WebDavSettings.getInstance();
    const folder: string = buildFolderUrl(config.url, settings.getSyncDir());
    const text: string | null = await WebDavClient.getInstance().readTextOrNull(config, configFileUrl(folder));
    if (text === null) {
      return { text: null, file: null, hash: '', error: '' };
    }
    const parsed: ConfigParseResult = parseConfigFile(text);
    const file: ConfigSyncFile | null = parsed.file;
    if (file === null) {
      return { text: text, file: null, hash: '', error: parsed.error };
    }
    return { text: text, file: file, hash: fingerprintOf(file), error: '' };
  }

  /**
   * 建目录 + PUT 上传 + 记同步戳
   *
   * exportedAt 在上传这一刻重写：文件里记的应该是「最后一次写入的时间」，这样另一台设备
   * 拿它跟自己的 lastSyncedAt 比就能判断谁更新。指纹不含时间，所以先算后改不影响它。
   */
  private async uploadFile(config: WebDavConfig, snapshot: ConfigSnapshot, hash: string): Promise<void> {
    const settings = WebDavSettings.getInstance();
    // 先确认「服务器地址」本身是通的再建目录：地址写错（比如 /dav 写成 /dva）时，
    // MKCOL 会真的在服务器根上逐段建出一串目录，用户根本不知道它们从哪来的。
    const probe: WebDavProbeResult = await WebDavClient.getInstance().probe(config);
    if (!probe.ok) {
      throw new Error(probe.message);
    }
    const folder: string = buildFolderUrl(config.url, settings.getSyncDir());
    await WebDavClient.getInstance().ensureFolder(config, folder);
    snapshot.file.exportedAt = new Date().toISOString();
    const text: string = JSON.stringify(snapshot.file);
    await WebDavClient.getInstance().writeText(config, configFileUrl(folder), text);
    settings.setSyncState(snapshot.file.exportedAt, hash);
    this.publishSyncedAt();
  }

  // ------------------------------------------------------------ 状态发布

  private uploadMessage(snapshot: ConfigSnapshot, note: string): string {
    let message: string = `已上传 ${snapshot.playlists} 个歌单、共 ${snapshot.songs} 首歌曲`;
    if (snapshot.skippedSongs > 0) {
      message += `\n${snapshot.skippedSongs} 首本地/云端歌曲没有上传（换设备后路径不成立）`;
    }
    return `${message}${note}`;
  }

  private publishStatus(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      AppStorage.setOrCreate(K_CONFIG_SYNC_STATUS, text);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish status failed: %{public}s', JSON.stringify(e));
    }
  }

  private publishNotice(text: string): void {
    try {
      AppStorage.setOrCreate(K_CONFIG_SYNC_NOTICE, text);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish notice failed: %{public}s', JSON.stringify(e));
    }
  }

  private publishSyncedAt(): void {
    try {
      AppStorage.setOrCreate(K_CONFIG_SYNC_AT, WebDavSettings.getInstance().getLastSyncedAt());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish syncedAt failed: %{public}s', JSON.stringify(e));
    }
  }
}

// ---------------------------------------------------------------- 纯函数

function deviceNameOf(): string {
  return defaultDeviceName();
}

function failOutcome(message: string): ConfigSyncOutcome {
  return { ok: false, message: message, playlists: 0, songs: 0, skippedSongs: 0, renamed: 0 };
}

/**
 * 把异常翻成一句用户能懂的话
 *
 * HTTP 状态码那几类（401 / 403 / 404 / 405 / 5xx）在 WebDavClient.assertOk 已经翻过，
 * 是中文，直接透出；这里补的是「请求根本没发出去」那类（DNS / 连接 / 超时 / 证书）。
 * 任何分支都**不打印密码**：密码只在 Authorization 头里，URL 里没有它。
 */
export function describeError(error: Error | null): string {
  if (error === null) {
    return '未知错误，稍后再试';
  }
  const raw: string = typeof error.message === 'string' ? error.message : '';
  if (raw.length === 0) {
    return '未知错误，稍后再试';
  }
  if (/[\u4e00-\u9fa5]/.test(raw)) {
    return raw;
  }
  const lower: string = raw.toLowerCase();
  if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0) {
    return '请求超时，检查网络与服务器地址';
  }
  if (lower.indexOf('resolve') >= 0 || lower.indexOf('unknown host') >= 0) {
    return '域名解析失败，检查服务器地址是否写对';
  }
  if (lower.indexOf('certificate') >= 0 || lower.indexOf('ssl') >= 0) {
    return 'HTTPS 证书不被信任（自签证书常见），换个地址或给服务器配正规证书';
  }
  if (lower.indexOf('connect') >= 0 || lower.indexOf('network') >= 0) {
    return '连不上服务器，检查地址、端口与网络';
  }
  return raw;
}

/** ISO 时间 -> 「11月23日 09:12」（解析不了就原样给） */
export function describeStamp(iso: string): string {
  const at: number = Date.parse(iso);
  if (Number.isNaN(at)) {
    return iso;
  }
  const date: Date = new Date(at);
  return `${date.getMonth() + 1}月${date.getDate()}日 ${two(date.getHours())}:${two(date.getMinutes())}`;
}

function two(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
