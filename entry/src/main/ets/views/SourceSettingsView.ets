import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceEngine } from '../core/source/SourceEngine';
import { MAX_SCRIPT_SIZE } from '../core/source/LxMetadata';
import { ImportResolveTestResult, SourceInfo, SourceLog } from '../core/source/LxTypes';
import { DEFAULT_MUSIC_INFO_JSON, formatTestResult, runOfflineSelfTest } from '../core/source/SourceTest';
import {
  CheckupOptions,
  CheckupProgress,
  SourceCheckupResult,
  SourceUpdateInfo,
  VERDICT_DEAD,
  VERDICT_OK,
  VERDICT_PARTIAL,
  applySourceUpdate,
  checkSourceUpdates,
  lastCheckupAt,
  loadCheckupResults,
  runSourceCheckup,
} from '../core/source/SourceCheckup';
import { SourceHealth, SourceRouter } from '../core/source/SourceRouter';
import { HdsListItemCard, IconSize, PrefixIcon, SuffixArrow, SuffixText } from '@kit.UIDesignKit';
import { I_DISC } from '../ui/Icons';
import { SEARCH_PLATFORMS, isSearchSupported } from '../core/music/MusicSearch';
import { C_BG, C_CARD, C_CHEVRON, C_DIVIDER, C_FILL_SOFT, C_FILL_SOFT_STRONG, C_ICON_GREEN, C_ICON_ORANGE, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SECTION, F_SUB, F_TAB, R_CARD } from '../ui/Theme';
import { LengthMetrics } from '@kit.ArkUI';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';
import { LogDetailView } from './LogDetailView';
import { K_AUTO_SOURCE_SWITCH, PlaySettings } from '../core/settings/PlaySettings';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceSettingsView';

const PLATFORM_NAMES: Record<string, string> = {
  'kw': '酷我',
  'kg': '酷狗',
  'mg': '咪咕',
  'tx': 'QQ',
  'wy': '网易',
  'xm': '喜马拉雅',
};

/**
 * 日志面板里的一行
 *
 * 面板只显示 `text`（时间 + 级别 + 裁过的消息，保持原来的观感），`full` 是引擎存下来的
 * 完整原文，只给「日志详情」和「复制全部日志」用 —— 两者分开是这一页的核心：
 * 用户要的是看得见全文，但面板不能因此变成一面文字墙。
 */
interface LogLine {
  /** 面板那一行：`[时间][级别] 裁剪版消息` */
  text: string;
  /** 完整原文：同一前缀 + 不裁剪的消息体 */
  full: string;
  /** 级别（详情页顶部显示） */
  type: string;
  /** 发生时间（毫秒时间戳；0 = 没有可信时间的纯文本行，如离线自检输出） */
  time: number;
}

/**
 * 音源设置
 *
 * 洛雪的「设置 - 音源设置」就是这一页：导入音源、启用/删除已导入的音源、
 * 查看音源声明的平台能力。这里把原先调试页的能力完整保留下来：
 * 导入 -> 加载 -> 声明平台 -> 沙箱环境兼容模式 -> 引擎日志 -> 离线自检。
 *
 * 导入有两条入口：粘贴链接/正文（在线拉取），或从文件导入本地脚本（见 pickSourceFile）。
 */
@Component
export struct SourceSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onBack: () => void = () => {
  };
  @State sourceInput: string = '';
  @State status: string = '等待操作';
  @State busy: boolean = false;
  @State sources: SourceInfo[] = [];
  @State loadedId: string = '';
  @State supportedText: string = '-';
  @State sandboxEnv: string = 'mobile';
  @State logs: LogLine[] = [];
  /**
   * 「日志详情」半模态的开关与内容
   *
   * 内容拆成三个基本类型字段而不是存一个 LogLine：@Prop 传的是值，
   * 换一条日志时三个字段一起变，详情页必然重建，不会出现"点第二条还显示第一条"的残留。
   */
  @State detailOpen: boolean = false;
  @State detailText: string = '';
  @State detailType: string = '';
  @State detailTime: number = 0;
  @State testUrl: string = '';
  private logListener: ((log: SourceLog) => void) | null = null;

  // ------------------------------------------------------------ 一键自检 / 检查更新

  /** 上一次自检的结论（按 id 对应，进页面就从磁盘读，不必重跑） */
  @State checkResults: SourceCheckupResult[] = [];
  /** 上一次自检的时间（0 = 从没跑过） */
  @State lastCheckAt: number = 0;
  @State checking: boolean = false;
  @State checkDone: number = 0;
  @State checkTotal: number = 0;
  /** 当前正在自检的音源名（进度文案用） */
  @State checkCurrent: string = '';
  /** 用户点了「停止」：在源/平台边界生效（见 SourceCheckup.runSourceCheckup） */
  private checkCancelled: boolean = false;
  /** 检查更新：找到的有更新的源 */
  @State updates: SourceUpdateInfo[] = [];
  @State checkingUpdates: boolean = false;
  @State updating: boolean = false;

  /**
   * 窗口宽度（vp）：宽屏下这几段并排（0 = 还没量到，按手机一列）
   *
   * 由壳层写进 AppStorage（见 pages/Index.ets 的 publishLayout），这里只订阅。
   */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;
  /** 多音源自动切换（见 PlaySettings.K_AUTO_SOURCE_SWITCH） */
  @StorageLink(K_AUTO_SOURCE_SWITCH) autoSwitch: boolean = true;

  /** 宽屏（够两列才并排，见 ui/Layout.ets 的 cardColumnsFor） */
  private cardsSideBySide(): boolean {
    return cardColumnsFor(this.windowWidth) > 1;
  }

  aboutToAppear(): void {
    const engine = SourceEngine.getInstance();
    this.sandboxEnv = engine.getSandboxEnv();
    this.refreshSources();
    this.checkResults = loadCheckupResults();
    this.lastCheckAt = lastCheckupAt();
    this.logListener = (log: SourceLog) => {
      // 面板这行只留时分秒（保持原来那一行的长度），完整日期在详情页里给
      const time: string = new Date(log.time).toLocaleTimeString();
      const prefix: string = `[${time}][${log.type}] `;
      // 没有 full 的日志（引擎未裁剪、或老逻辑推送过来的）全文就等于消息本身
      const fullText: string = log.full !== undefined ? log.full : log.message;
      const line: LogLine = {
        text: `${prefix}${log.message}`,
        full: `${prefix}${fullText}`,
        type: log.type,
        time: log.time,
      };
      const next: LogLine[] = this.logs.slice();
      next.push(line);
      // 面板最多显示最近 60 条（与引擎自己的 maxLogs 无关，那是不落盘的完整环形缓冲）
      this.logs = next.slice(-60);
    };
    engine.setLogListener(this.logListener);
  }

  aboutToDisappear(): void {
    SourceEngine.getInstance().setLogListener(null);
  }

  private getContext(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  /**
   * 刷新列表
   *
   * 用 listAllSources() 而不是 listSources()：后者只给「启用中的源」（播放/下载的候选集合），
   * 而这一页必须把停用的源也列出来 —— 否则停用之后用户就再也找不到它，没法启用回来。
   */
  private refreshSources(): void {
    const engine = SourceEngine.getInstance();
    this.sources = engine.listAllSources();
    this.loadedId = engine.getLoadedSourceId();
    const supported: string[] = Object.keys(engine.getSupportedSources());
    this.supportedText = supported.length > 0 ? supported.map((p: string) => this.platformName(p)).join(' / ') : '-';
  }

  // ------------------------------------------------------------ 自检结论的展示口径

  /** 某个源上一次的自检结论（没有就是 null） */
  private resultOf(id: string): SourceCheckupResult | null {
    for (const item of this.checkResults) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  /** 有结论就用结论，没有就看路由记忆：界面上永远给一个「已知的状态」 */
  private verdictOf(item: SourceInfo): string {
    const result: SourceCheckupResult | null = this.resultOf(item.id);
    if (result !== null) {
      return result.verdict;
    }
    const health: SourceHealth = SourceRouter.getInstance().healthOf(item.id);
    if (health.failStreak >= 2) {
      return VERDICT_DEAD;
    }
    if (health.lastOkAt > 0 && health.failStreak === 0) {
      return VERDICT_OK;
    }
    return 'unknown';
  }

  private verdictText(verdict: string): string {
    if (verdict === VERDICT_OK) {
      return '可用';
    }
    if (verdict === VERDICT_PARTIAL) {
      return '部分可用';
    }
    if (verdict === VERDICT_DEAD) {
      return '失效';
    }
    return '未验证';
  }

  private verdictColor(verdict: string): Resource {
    if (verdict === VERDICT_OK) {
      return C_ICON_GREEN;
    }
    if (verdict === VERDICT_PARTIAL) {
      return C_ICON_ORANGE;
    }
    if (verdict === VERDICT_DEAD) {
      return C_RED;
    }
    return C_TEXT_WEAK;
  }

  /** 「12-01 10:30」这种短时间（跨年才带年份，够用且省宽度） */
  private shortTime(at: number): string {
    if (at <= 0) {
      return '从未';
    }
    const date: Date = new Date(at);
    const now: Date = new Date();
    const month: string = `${date.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${date.getDate()}`.padStart(2, '0');
    const hour: string = `${date.getHours()}`.padStart(2, '0');
    const minute: string = `${date.getMinutes()}`.padStart(2, '0');
    if (date.getFullYear() !== now.getFullYear()) {
      return `${date.getFullYear()}-${month}-${day}`;
    }
    return `${month}-${day} ${hour}:${minute}`;
  }

  /** 卡片副标题：自检结论的细节 / 路由记忆里的最后成功与失败原因 */
  private subtitleOf(item: SourceInfo): string {
    const result: SourceCheckupResult | null = this.resultOf(item.id);
    if (result !== null) {
      // 自检结论优先，但「最后成功时间」仍然值得带上：失效的源上次是什么时候好过，
      // 是用户判断「要不要等作者修 / 直接删」的关键信息
      return result.lastOkAt > 0
        ? `${result.message}　（最后成功 ${this.shortTime(result.lastOkAt)}）`
        : result.message;
    }
    const health: SourceHealth = SourceRouter.getInstance().healthOf(item.id);
    if (health.lastFailAt > 0 && health.lastError.length > 0) {
      const platform: string = health.failedPlatform.length > 0 ? this.platformName(health.failedPlatform) : '';
      const okPart: string = health.lastOkAt > 0 ? `最后成功 ${this.shortTime(health.lastOkAt)} · ` : '';
      return `${okPart}上次失败（${platform.length > 0 ? platform : '未知平台'}）：${health.lastError}`;
    }
    if (health.lastOkAt > 0) {
      return `最后成功：${this.shortTime(health.lastOkAt)}`;
    }
    return '还没有使用记录，跑一次「一键自检」就能确定它还能不能用';
  }

  /** 顶部汇总：N 个可用 / M 个失效（还有几个没验证） */
  private summaryText(): string {
    let ok: number = 0;
    let partial: number = 0;
    let dead: number = 0;
    let unknown: number = 0;
    let disabled: number = 0;
    for (const item of this.sources) {
      if (item.disabled === true) {
        disabled += 1;
        continue;
      }
      const verdict: string = this.verdictOf(item);
      if (verdict === VERDICT_OK) {
        ok += 1;
      } else if (verdict === VERDICT_PARTIAL) {
        partial += 1;
      } else if (verdict === VERDICT_DEAD) {
        dead += 1;
      } else {
        unknown += 1;
      }
    }
    const parts: string[] = [`${ok} 个可用`];
    if (partial > 0) {
      parts.push(`${partial} 个部分可用`);
    }
    if (dead > 0) {
      parts.push(`${dead} 个失效`);
    }
    if (unknown > 0) {
      parts.push(`${unknown} 个未验证`);
    }
    if (disabled > 0) {
      parts.push(`${disabled} 个已停用`);
    }
    return parts.join(' / ');
  }

  /** 有没有源声明了更新地址（没有的话「检查更新」按钮要说明为什么没用） */
  private sourcesWithUpdateUrl(): string[] {
    const ids: string[] = [];
    for (const item of this.sources) {
      const url: string = item.updateUrl !== undefined ? item.updateUrl : '';
      if (/^https?:\/\//.test(url)) {
        ids.push(item.id);
      }
    }
    return ids;
  }

  private async startCheckup(): Promise<void> {
    if (this.checking || this.busy) {
      return;
    }
    if (this.sources.length === 0) {
      this.toast('还没有导入任何音源');
      return;
    }
    // 只自检「启用中」的源：停用的源本来就该被自动选源跳过，没必要替它耗一个探测预算
    const enabled: SourceInfo[] = SourceEngine.getInstance().listSources();
    if (enabled.length === 0) {
      this.toast('没有启用中的音源，先启用一个再自检');
      return;
    }
    if (SourceEngine.getInstance().hasPendingResolve()) {
      this.toast('正在解析播放地址，等这一下结束再自检');
      return;
    }
    this.checkCancelled = false;
    this.checking = true;
    this.checkDone = 0;
    this.checkTotal = enabled.length;
    this.checkCurrent = '';
    this.status = '正在自检全部音源（会自动切换音源，结束后还原）…';
    try {
      const options: CheckupOptions = {
        isCancelled: () => this.checkCancelled,
        onProgress: (progress: CheckupProgress) => {
          this.checkDone = progress.done;
          this.checkTotal = progress.total;
          this.checkCurrent = progress.current;
        },
      };
      const report = await runSourceCheckup(options);
      this.checkResults = loadCheckupResults();
      this.lastCheckAt = report.checkedAt;
      this.status = `${report.cancelled ? '自检已停止（结果不完整）' : '自检完成'}：${this.summaryText()}`
        + `，耗时 ${Math.round(report.totalMs / 1000)} 秒`;
      this.refreshSources();
    } catch (e) {
      this.status = `自检失败: ${(e as Error).message}`;
    } finally {
      this.checking = false;
      this.checkCurrent = '';
    }
  }

  private cancelCheckup(): void {
    this.checkCancelled = true;
    this.status = '正在停止自检（当前这个平台测完就停）…';
  }

  private toggleDisabled(item: SourceInfo): void {
    if (this.checking) {
      this.toast('自检进行中，等它结束再改启用状态');
      return;
    }
    const disabled: boolean = item.disabled === true;
    this.refreshSourcesFromList(SourceEngine.getInstance().setSourceDisabled(item.id, !disabled));
    this.status = disabled ? `已启用「${item.name}」，下次播放就会重新参与选源` : `已停用「${item.name}」`;
  }

  private refreshSourcesFromList(list: SourceInfo[]): void {
    this.sources = list;
    const engine = SourceEngine.getInstance();
    this.loadedId = engine.getLoadedSourceId();
    this.supportedText = Object.keys(engine.getSupportedSources()).length > 0
      ? Object.keys(engine.getSupportedSources()).map((p: string) => this.platformName(p)).join(' / ')
      : '-';
  }

  // ------------------------------------------------------------ 检查更新

  private async startUpdateCheck(): Promise<void> {
    if (this.checkingUpdates || this.checking || this.busy) {
      return;
    }
    const ids: string[] = this.sourcesWithUpdateUrl();
    if (ids.length === 0) {
      this.toast('这些音源都没有声明更新地址，无法自动检查（可在群里问作者要新版链接后重新导入）');
      return;
    }
    this.checkingUpdates = true;
    this.updates = [];
    this.status = `正在检查 ${ids.length} 个音源的更新（并发 3）…`;
    try {
      const found: SourceUpdateInfo[] = await checkSourceUpdates(ids, (done: number, total: number) => {
        this.status = `正在检查更新：${done}/${total}…`;
      }, () => false);
      const updates: SourceUpdateInfo[] = [];
      let failed: number = 0;
      for (const item of found) {
        if (item.hasUpdate) {
          updates.push(item);
        } else if (item.error.length > 0) {
          failed += 1;
        }
      }
      this.updates = updates;
      this.status = updates.length > 0
        ? `发现 ${updates.length} 个音源有新版本${failed > 0 ? `（${failed} 个检查失败）` : ''}`
        : `都是最新版本${failed > 0 ? `（${failed} 个检查失败，可能是更新地址打不开）` : ''}`;
    } catch (e) {
      this.status = `检查更新失败: ${(e as Error).message}`;
    } finally {
      this.checkingUpdates = false;
    }
  }

  private updateOne(update: SourceUpdateInfo): void {
    if (this.updating) {
      return;
    }
    this.updating = true;
    try {
      const info: SourceInfo = applySourceUpdate(update);
      const remains: SourceUpdateInfo[] = this.updates.filter((item: SourceUpdateInfo) => item.id !== update.id);
      this.updates = remains;
      this.refreshSources();
      this.status = `已把「${info.name}」更新到 ${this.versionText(info.version)}（点「加载」后新脚本才生效）`;
      this.toast(`已更新「${info.name}」`);
    } catch (e) {
      this.status = `更新「${update.name}」失败: ${(e as Error).message}（原音源未改动）`;
    } finally {
      this.updating = false;
    }
  }

  private async updateAll(): Promise<void> {
    if (this.updating || this.updates.length === 0) {
      return;
    }
    this.updating = true;
    const pending: SourceUpdateInfo[] = this.updates.slice();
    let ok: number = 0;
    let failed: number = 0;
    try {
      for (let i = 0; i < pending.length; i++) {
        this.status = `正在更新音源：${i + 1}/${pending.length}…`;
        try {
          applySourceUpdate(pending[i]);
          ok += 1;
        } catch (e) {
          failed += 1;
          hilog.warn(DOMAIN, TAG, 'update source failed: %{public}s', (e as Error).message);
        }
      }
      this.updates = [];
      this.refreshSources();
      this.status = `更新完成：成功 ${ok} 个${failed > 0 ? `，失败 ${failed} 个（原音源未改动）` : ''}`;
    } finally {
      this.updating = false;
    }
  }

  private platformName(id: string): string {
    const name: string = PLATFORM_NAMES[id];
    return name !== undefined ? name : id;
  }

  /** 脚本头里的 @version 常常自带 v（v1.2.1），别再补一个变成 vv1.2.1 */
  private versionText(version: string): string {
    if (version.length === 0) {
      return '未知版本';
    }
    return version.charAt(0).toLowerCase() === 'v' ? version : `v${version}`;
  }

  private async importAndLoad(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.checking) {
      // 自检正在把各个源依次装进同一个沙箱：这时候再导一个源会把它顶掉，两边结论都不可信
      this.toast('自检进行中，等它结束再导入（或先点「停止自检」）');
      return;
    }
    const input: string = this.sourceInput.trim();
    if (input.length === 0) {
      this.status = '请先粘贴音源脚本链接（或脚本正文）';
      return;
    }
    const engine = SourceEngine.getInstance();
    this.busy = true;
    this.status = '导入中…';
    try {
      let info: SourceInfo;
      if (/^https?:\/\//.test(input)) {
        info = await engine.importFromUrl(input);
      } else {
        info = engine.importSource(input);
      }
      this.status = `已导入「${info.name}」，正在初始化沙箱…`;
      this.refreshSources();
      await this.loadSource(info.id);
    } catch (e) {
      this.status = `导入失败: ${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  private async loadSource(id: string): Promise<void> {
    const engine = SourceEngine.getInstance();
    this.busy = true;
    this.status = '正在加载音源…';
    try {
      await engine.loadSource(id);
      this.refreshSources();
      this.loadedId = id;
      const playable: string[] = [];
      for (const platform of Object.keys(engine.getSupportedSources())) {
        if (isSearchSupported(platform)) {
          playable.push(this.platformName(platform));
        }
      }
      this.status = playable.length > 0
        ? `音源已就绪，可播放平台：${playable.join(' / ')}`
        : `音源已加载，但它声明的平台都不在可播放范围内（可播放：${SEARCH_PLATFORMS.map(
          (p: string) => this.platformName(p)).join('/')}）`;
    } catch (e) {
      this.status = `加载失败: ${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 点卡片/「加载」：停用的源先启用再加载
   *
   * 停用只是「不参与自动选源」，不是「不能用」——用户明确点了它，就说明想用它，
   * 这时候悄悄加载一个停用的源只会让人困惑（列表上还写着已停用，播放候选里又没有）。
   */
  private async loadOrEnable(item: SourceInfo): Promise<void> {
    if (this.checking) {
      this.toast('自检进行中，等它结束再切换音源');
      return;
    }
    if (item.disabled === true) {
      this.refreshSourcesFromList(SourceEngine.getInstance().setSourceDisabled(item.id, false));
    }
    await this.loadSource(item.id);
  }

  private removeSource(id: string): void {
    if (this.checking) {
      this.toast('自检进行中，等它结束再删除音源');
      return;
    }
    const engine = SourceEngine.getInstance();
    this.sources = engine.removeSource(id);
    // 自检结论也要跟着丢掉，否则删掉又新建同 id 的源时会显示上一份结论（虽然 id 不会重用）
    const remains: SourceCheckupResult[] = [];
    for (const item of this.checkResults) {
      if (item.id !== id) {
        remains.push(item);
      }
    }
    this.checkResults = remains;
    this.status = '已删除该音源';
    this.refreshSources();
  }

  private toggleSandboxEnv(): void {
    const engine = SourceEngine.getInstance();
    const next: string = engine.getSandboxEnv() === 'mobile' ? 'desktop' : 'mobile';
    engine.setSandboxEnv(next);
    this.sandboxEnv = next;
    this.status = `已把沙箱环境切换为 ${next}，请重新点「加载」`;
  }

  /** 按 id 找音源名（状态行要说清「还原成了哪个」，只给 id 用户认不出来） */
  private sourceNameOf(id: string): string {
    for (const item of this.sources) {
      if (item.id === id) {
        return item.name;
      }
    }
    return id;
  }

  private async runSelfTest(): Promise<void> {
    if (this.busy) {
      return;
    }
    const engine = SourceEngine.getInstance();
    // 自检会把示例源临时装进沙箱，结束后由 SourceTest 负责还原（见 runOfflineSelfTest）。
    // 这里记下自检前的音源，回来比对一次：坏音源不能被悄悄留下，状态行要如实说清
    const beforeId: string = engine.getLoadedSourceId();
    this.busy = true;
    this.status = '离线自检中…';
    try {
      const result: ImportResolveTestResult = await runOfflineSelfTest(this.getContext(), DEFAULT_MUSIC_INFO_JSON);
      const restored: boolean = engine.getLoadedSourceId() === beforeId;
      const restoredText: string = restored
        ? (beforeId.length > 0 ? `当前音源仍是「${this.sourceNameOf(beforeId)}」` : '自检前未加载音源，现仍未加载')
        : '原音源未保留，请在下方重新点「加载」';
      this.status = `${result.ok ? '离线自检通过' : '离线自检失败'} · ${restoredText}`;
      this.testUrl = result.resolve !== null ? result.resolve.url : '';
      // 自检输出是纯文本行，没有级别与逐行时间：整段共用一个时间戳，
      // 每行原文就是它自己（自检本来就按行输出，没有"被裁掉的全文"这回事）
      const report: string = formatTestResult(result);
      const now: number = Date.now();
      const selfTestLines: LogLine[] = [];
      for (const one of report.split('\n')) {
        selfTestLines.push({ text: one, full: one, type: 'selftest', time: now });
      }
      this.logs = selfTestLines;
      // 自检可能顺手删掉了「本次新导入的示例源」，列表要跟着刷新，
      // 顺便把 loadedId 同步成引擎里真实的当前音源
      this.refreshSources();
    } catch (e) {
      this.status = `离线自检异常: ${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }

  // ------------------------------------------------------------ 日志的查看与复制

  /** 打开某条日志的半模态详情（里面是完整原文） */
  private openLogDetail(line: LogLine): void {
    this.detailText = line.full;
    this.detailType = line.type;
    this.detailTime = line.time;
    this.detailOpen = true;
  }

  /**
   * 复制全部日志（含全文）
   *
   * 拼的是每条的 `full` 而不是面板上的 `text`：面板那行都裁过，逐条复制等于把
   * 「看不到全文」换个地方再来一遍。整段按行拼，贴到聊天/工单里直接可读。
   */
  private copyAllLogs(): void {
    if (this.logs.length === 0) {
      this.toast('还没有日志可复制');
      return;
    }
    const lines: string[] = [];
    for (const line of this.logs) {
      lines.push(line.full);
    }
    this.copyText(lines.join('\n'), `已复制 ${this.logs.length} 条日志（含全文）`);
  }

  /**
   * 写系统剪贴板
   *
   * 用 BasicServicesKit 的 pasteboard（与「关于」页复制群号、听歌识曲复制结果是同一套做法，
   * 项目里没有更上层的封装）。失败不静默：详情页文本本身可长按选中，提示用户手动复制，
   * 别让人以为已经复制成功了。
   */
  private copyText(text: string, tip: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast(tip);
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'copy logs failed: %{public}s', err.message);
        this.toast('写入剪贴板失败，可长按日志手动复制');
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'copy logs threw: %{public}s', (e as BusinessError).message);
      this.toast('写入剪贴板失败，可长按日志手动复制');
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  sectionCard(title: string) {
    Text(title)
      .fontSize(F_SECTION)
      .fontWeight(FontWeight.Bold)
      .fontColor(C_TEXT)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 4, bottom: 8 })
  }

  /**
   * 日志卡片的小标题行：标题 + 「复制全部」
   *
   * 不复用 sectionCard：那一枚是「标题独占一行」，而日志需要在自己的标题行右边挂一个入口。
   * 字号/字重/颜色/左内边距与 sectionCard 逐项一致，宽屏并排时不会和其它卡片错位。
   */
  @Builder
  logHeader() {
    Row() {
      Text('引擎日志')
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT)
      Blank()
      // 没有日志时不显示：空态保持原样，不给一个点了也没反应的入口
      if (this.logs.length > 0) {
        Text('复制全部')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .padding({ left: 10, right: 4, top: 2, bottom: 2 })
          .onClick(() => {
            this.copyAllLogs();
          })
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, bottom: 8 })
  }

  /**
   * 日志详情半模态的内容
   *
   * 只把当前这一条传下去：详情组件不持有日志列表，宿主点哪条它就显示哪条。
   * 半模态的标题栏/关闭钮/拖动条由系统的 bindSheet 提供（见 build 末尾）。
   */
  @Builder
  logDetailSheet() {
    LogDetailView({
      content: this.detailText,
      type: this.detailType,
      time: this.detailTime,
      bottomInset: this.bottomInset,
      onCopy: (text: string) => {
        this.copyText(text, '已复制这条日志的全文');
      },
    })
  }

  build() {
    Column() {
      // 标题栏与返回键由 HdsNavDestination 提供，这里不再自绘头部
      Scroll() {
        /**
         * 各段的排布用 Flex 而不是 Column：**宽屏并排、窄屏一列**
         *
         * 窄屏是 `direction: Column` + 不换行 + main 间距 16，与原来的 `Column({ space: 16 })`
         * 逐像素一样；宽屏换成 `Row` + 换行，每段 48% 宽（见 ui/Layout.ets 的 cardWidthOf），
         * 自动一行两段。每段（小标题 + 它的卡）包在一个 Column 里当**一个单元**：
         * 不包的话小标题会跟别段的卡排在一格上。
         */
        Flex({
          direction: this.cardsSideBySide() ? FlexDirection.Row : FlexDirection.Column,
          wrap: this.cardsSideBySide() ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 各段高矮差得多（已导入音源可能好几条、日志几十行），居中的话短的会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(16) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走 —— 用容器内边距会把
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）
          Column().height(this.topInset + 6).width('100%')
          Text(this.status)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 4 })

          // ------------------------------------------------ 导入音源
          Column({ space: 10 }) {
            this.sectionCard('导入音源')
            Column({ space: 10 }) {
              TextArea({
                text: this.sourceInput,
                placeholder: '粘贴音源脚本链接，例如 https://example.com/lx-source.js',
              })
                .height(72)
                .width('100%')
                .fontSize(12.5)
                .backgroundColor(C_FILL_SOFT)
                .borderRadius(10)
                .onChange((value: string) => {
                  this.sourceInput = value;
                })
              Row({ space: 10 }) {
                Button(this.busy ? '处理中…' : '导入并加载')
                  .fontSize(14)
                  .height(40)
                  .layoutWeight(1)
                  .backgroundColor(C_RED)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.importAndLoad();
                  })
                Button('导入音源文件')
                  .fontSize(14)
                  .height(40)
                  .layoutWeight(1)
                  .backgroundColor(C_FILL_SOFT_STRONG)
                  .fontColor(C_TEXT)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.pickSourceFile();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(14)
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 已导入音源
          Column({ space: 10 }) {
            this.sectionCard('已导入音源')
            Column({ space: 10 }) {
              /**
               * 顶部汇总 + 两个入口
               *
               * 「一键自检」要解决的就是群里那句「音源又不行了、你换一个试试」：
               * 用户不需要知道哪个源今天还活着，跑一次就看到「N 个可用 / M 个失效」，
               * 失效的直接停用就行（停用后自动选源不会再试它，见 SourceEngine.listSources）。
               */
              Column({ space: 8 }) {
                Row() {
                  Text(this.sources.length > 0 ? this.summaryText() : '还没有导入任何音源')
                    .fontSize(F_SUB)
                    .fontColor(C_TEXT_SUB)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
                  if (this.lastCheckAt > 0 && !this.checking) {
                    Text(`上次自检 ${this.shortTime(this.lastCheckAt)}`)
                      .fontSize(F_TAB)
                      .fontColor(C_TEXT_WEAK)
                  }
                }
                .width('100%')

                // 进度：自检会把音源逐个加载进沙箱，慢是正常的，所以必须看得见、停得掉
                if (this.checking) {
                  Progress({
                    value: this.checkDone,
                    total: this.checkTotal > 0 ? this.checkTotal : 1,
                    type: ProgressType.Linear,
                  })
                    .width('100%')
                    .height(4)
                    .color(C_RED)
                  Text(this.checkCurrent.length > 0
                    ? `正在检查 ${Math.min(this.checkDone + 1, this.checkTotal)}/${this.checkTotal}：${this.checkCurrent}`
                    : '正在准备…')
                    .fontSize(F_TAB)
                    .fontColor(C_TEXT_WEAK)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }

                Row({ space: 10 }) {
                  Button(this.checking ? '停止自检' : '一键自检')
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(this.checking ? C_RED_TINT : C_RED)
                    .fontColor(this.checking ? C_RED : Color.White)
                    .enabled(this.sources.length > 0 && !this.busy)
                    .onClick(() => {
                      if (this.checking) {
                        this.cancelCheckup();
                      } else {
                        this.startCheckup();
                      }
                    })
                  Button(this.checkingUpdates ? '检查中…' : '检查更新')
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(C_FILL_SOFT_STRONG)
                    .fontColor(C_TEXT)
                    .enabled(!this.checkingUpdates && !this.checking && !this.busy)
                    .onClick(() => {
                      this.startUpdateCheck();
                    })
                }
                .width('100%')

                // 没有更新地址时说明清楚：这不是按钮坏了，是脚本没提供地址
                if (this.sources.length > 0 && this.sourcesWithUpdateUrl().length === 0) {
                  Text('「检查更新」需要脚本声明更新地址（头部 @updateUrl，或运行时 showUpdateAlert）；'
                    + '当前这些源都没有，拿到新版链接后重新导入即可覆盖旧版。')
                    .fontSize(F_TAB)
                    .fontColor(C_TEXT_WEAK)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(R_CARD)
              .backgroundColor(C_CARD)

              // 有新版时的批量更新条
              if (this.updates.length > 0) {
                Column({ space: 6 }) {
                  Row() {
                    Text(`发现 ${this.updates.length} 个音源有新版本`)
                      .fontSize(F_SUB)
                      .fontColor(C_ICON_ORANGE)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Start)
                    Text(this.updating ? '更新中…' : '全部更新')
                      .fontSize(F_SUB)
                      .fontColor(C_RED)
                      .padding({ left: 8, top: 2, bottom: 2 })
                      .onClick(() => {
                        this.updateAll();
                      })
                  }
                  .width('100%')
                  ForEach(this.updates, (update: SourceUpdateInfo) => {
                    Row({ space: 8 }) {
                      Column({ space: 2 }) {
                        Text(update.name)
                          .fontSize(13)
                          .fontColor(C_TEXT)
                          .width('100%')
                          .textAlign(TextAlign.Start)
                        Text(`${this.versionText(update.localVersion)} → ${this.versionText(update.remoteVersion)}`
                          + `${update.note.length > 0 ? `　${update.note}` : ''}`)
                          .fontSize(11)
                          .fontColor(C_TEXT_WEAK)
                          .width('100%')
                          .textAlign(TextAlign.Start)
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)
                      Text('更新')
                        .fontSize(12.5)
                        .fontColor(C_RED)
                        .padding({ left: 8, right: 4, top: 4, bottom: 4 })
                        .onClick(() => {
                          this.updateOne(update);
                        })
                    }
                    .width('100%')
                  }, (update: SourceUpdateInfo) => `${update.id}_${update.remoteVersion}`)
                }
                .width('100%')
                .padding(12)
                .borderRadius(R_CARD)
                .backgroundColor(C_RED_TINT)
              }

              ForEach(this.sources, (item: SourceInfo) => {
                Column({ space: 8 }) {
                  // 一条音源就是一张 HDS 列表卡：官方符号图标 + 名称/版本，
                  // 点卡片即加载；右侧「已就绪」用 HDS 的 SuffixText。
                  // 白卡底由外层自绘容器给（HdsListItemCard 的 cardWidth/cardBackgroundColor
                  // 会破坏它内部的宽度测量，导致整行文字消失，别用）。
                  Column() {
                    HdsListItemCard({
                      prefixItem: new PrefixIcon({
                        iconSize: IconSize.SYSTEM_ICON,
                        iconValue: { symbol: I_DISC },
                      }),
                      textItem: {
                        primaryText: { text: item.name },
                        secondaryText: {
                          text: `${this.versionText(item.version)}　${item.author.length > 0 ? item.author : '未知作者'}`,
                        },
                      },
                      suffixItem: this.loadedId === item.id
                        ? new SuffixText({ text: '已就绪' })
                        : new SuffixArrow({ color: C_CHEVRON }),
                      cardHeight: 68,
                      onClick: () => {
                        this.loadOrEnable(item);
                      },
                    })
                  }
                  .width('100%')
                  .borderRadius(R_CARD)
                  .backgroundColor(C_CARD)
                  .clip(true)

                  /**
                   * 状态行：可用/部分可用/失效 + 一句人话的原因
                   *
                   * 「失效」不是猜的：来自上一次自检（真实解析过播放地址），
                   * 或者路由表里「连续两次失败」的既有口径。没有记录就写「未验证」，
                   * 不硬猜一个结论吓人。
                   */
                  Row({ space: 6 }) {
                    Text(this.verdictText(this.verdictOf(item)))
                      .fontSize(10.5)
                      .fontColor(this.verdictColor(this.verdictOf(item)))
                      .backgroundColor(C_FILL_SOFT)
                      .borderRadius(5)
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                    if (item.disabled === true) {
                      Text('已停用')
                        .fontSize(10.5)
                        .fontColor(C_TEXT_WEAK)
                        .backgroundColor(C_FILL_SOFT)
                        .borderRadius(5)
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                    }
                    Text(this.subtitleOf(item))
                      .fontSize(11)
                      .fontColor(C_TEXT_WEAK)
                      .layoutWeight(1)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Row({ space: 10 }) {
                    Button(item.disabled === true ? '启用并加载' : '加载')
                      .fontSize(13)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(C_FILL_SOFT_STRONG)
                      .fontColor(C_TEXT)
                      .onClick(() => {
                        this.loadOrEnable(item);
                      })
                    Button(item.disabled === true ? '启用' : '停用')
                      .fontSize(13)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(C_FILL_SOFT_STRONG)
                      .fontColor(C_TEXT)
                      .onClick(() => {
                        this.toggleDisabled(item);
                      })
                    Button('删除')
                      .fontSize(13)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(C_RED_TINT)
                      .fontColor(C_RED)
                      .onClick(() => {
                        this.removeSource(item.id);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                // 失效 / 停用的源整体压暗：一眼能分出「哪些别指望了」
                .opacity(item.disabled === true || this.verdictOf(item) === VERDICT_DEAD ? 0.6 : 1)
              }, (item: SourceInfo) => `${item.id}_${item.disabled === true ? 'off' : 'on'}_${this.verdictOf(item)}`)
            }
            .width('100%')
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 多音源
          /**
           * 只放一个开关 + 一句解释。
           *
           * 为什么值得单开一段：这条链路的行为（会不会换源、换过之后下次走哪个）
           * 用户看不见，一旦出现「怎么老是先卡一下」就很费解；把开关与规则写在这里，
           * 出问题时至少知道自己关得掉、也知道我们记得什么。
           */
          Column({ space: 10 }) {
            this.sectionCard('多音源')
            Column({ space: 6 }) {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text('自动切换音源')
                    .fontSize(15)
                    .fontColor(C_TEXT)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  Text('当前音源取不到播放地址时，自动换用其它已导入的音源；'
                    + '在某个平台成功过的源会被记住，下次同平台的歌直接走它，'
                    + '连败两次的源先排到后面。')
                    .fontSize(11.5)
                    .fontColor(C_TEXT_WEAK)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: this.autoSwitch })
                  .selectedColor(C_RED)
                  .onChange((isOn: boolean) => {
                    PlaySettings.getInstance().setAutoSourceSwitch(isOn);
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(14)
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 运行状态
          Column({ space: 10 }) {
            this.sectionCard('运行状态')
            Column({ space: 10 }) {
              this.infoLine('已声明平台', this.supportedText)
              Divider().strokeWidth(0.6).color(C_DIVIDER)
              this.infoLine('沙箱环境', `lx.env = ${this.sandboxEnv}`)
              Divider().strokeWidth(0.6).color(C_DIVIDER)
              Row({ space: 10 }) {
                Button('切换兼容模式')
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(C_FILL_SOFT_STRONG)
                  .fontColor(C_TEXT)
                  .onClick(() => {
                    this.toggleSandboxEnv();
                  })
                Button(this.busy ? '自检中…' : '一键离线自检')
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(C_FILL_SOFT_STRONG)
                  .fontColor(C_TEXT)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.runSelfTest();
                  })
              }
              .width('100%')
              if (this.testUrl.length > 0) {
                Text(this.testUrl)
                  .fontSize(11.5)
                  .fontColor(C_ICON_GREEN)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .copyOption(CopyOptions.LocalDevice)
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 日志
          Column({ space: 10 }) {
            this.logHeader()
            Column({ space: 3 }) {
              if (this.logs.length === 0) {
                Text('暂无日志')
                  .fontSize(11.5)
                  .fontColor(C_TEXT_WEAK)
              }
              ForEach(this.logs, (line: LogLine, i: number) => {
                // 面板这一行照旧是裁剪版（观感不变）；点一下才进详情看完整原文
                Text(line.text)
                  .fontSize(11)
                  .fontColor(C_TEXT_SUB)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .copyOption(CopyOptions.LocalDevice)
                  .onClick(() => {
                    this.openLogDetail(line);
                  })
              }, (line: LogLine, i: number) => `${i}_${line.text}`)
              // 入口要能被发现：不写这一句，用户只会以为日志还是原来那样只能看一半
              if (this.logs.length > 0) {
                Text('点任一条查看完整内容，长按可选中复制')
                  .fontSize(F_TAB)
                  .fontColor(C_TEXT_WEAK)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .margin({ top: 6 })
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.bottomInset + 20 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    /**
     * 日志详情：系统的半模态（与本项目其它面板一致，见 views/AddToPlaylistSheet.ets）。
     *
     * 挂在页面根节点上而不是日志卡片上：卡片在 Scroll 里，跟着内容滚走，
     * 半模态会跟着一起被裁。detents 给两档、默认拉到 LARGE —— 全文常常比一半屏幕高，
     * 先展开省得用户自己再拖一次；仍然保留 MEDIUM，方便回到半屏对照上面的面板。
     */
    .bindSheet($$this.detailOpen, this.logDetailSheet(), {
      preferType: SheetType.BOTTOM,
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      detentSelection: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      title: { title: '日志详情' },
    })
  }

  @Builder
  infoLine(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(C_TEXT_SUB)
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  // ------------------------------------------------------------ 从文件导入

  /**
   * 从文件导入音源：拉起文件管理选一个脚本文件，读成文本后走和「粘贴正文」同一条路
   *
   * 选文件用 DocumentViewPicker（与「导入音乐」选音频文件是同一套做法）；后缀过滤给 .js，
   * 洛雪的源就是 js 脚本。用户在文件管理里取消不会进 then，这里也不报错 —— 取消不是失败。
   */
  private pickSourceFile(): void {
    if (this.busy) {
      return;
    }
    if (this.checking) {
      this.toast('自检进行中，等它结束再导入');
      return;
    }
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['音源脚本 (.js)|.js'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.getContext());
      documentPicker.select(options)
        .then((uris: string[]) => {
          if (uris.length === 0) {
            return;
          }
          void this.importSourceFile(uris[0]);
        })
        .catch((err: BusinessError) => {
          // 用户取消也走这里（错误码里带 cancel），不当成失败提示
          hilog.info(DOMAIN, TAG, 'pick source file ended: %{public}s', err.message);
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'open document picker failed: %{public}s', JSON.stringify(e));
      this.status = '打不开文件选择器，当前环境可能不支持选择文件';
    }
  }

  private async importSourceFile(uri: string): Promise<void> {
    const name: string = fileNameOf(uri);
    this.busy = true;
    this.status = `正在读取「${name}」…`;
    try {
      const text: string = readScriptFile(uri);
      if (text.trim().length === 0) {
        this.status = `「${name}」是空文件，没有可导入的脚本`;
        return;
      }
      const info: SourceInfo = SourceEngine.getInstance().importSource(text);
      this.status = `已导入「${info.name}」，正在初始化沙箱…`;
      this.refreshSources();
      // 加载这一步自己管 busy 与状态文案，与「导入并加载」共用
      await this.loadSource(info.id);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'import source file failed (%{public}s): %{public}s', name, JSON.stringify(e));
      this.status = `导入文件「${name}」失败: ${(e as Error).message}`;
    } finally {
      this.busy = false;
    }
  }
}

/**
 * 读出用户选中的音源脚本
 *
 * picker 给的是文件管理那边的 uri（`file://docs/...`），用 fs.openSync 直接打开即可
 * （与「导入音乐」读音频文件是同一套做法），再按 UTF-8 解成文本。
 *
 * 大小上限跟引擎用同一个常量：引擎本来就以「源脚本过大」拒收超过 MAX_SCRIPT_SIZE 的正文，
 * 这里提前按文件大小拦下来，选错一个大文件时不会先把整个文件读进内存。
 */
function readScriptFile(uri: string): string {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const size: number = fs.statSync(file.fd).size;
    if (size <= 0) {
      return '';
    }
    if (size > MAX_SCRIPT_SIZE) {
      throw new Error(`文件太大（${Math.round(size / 1024)} KB），音源脚本不会这么大`);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const read: number = fs.readSync(file.fd, buffer);
    const decoder = util.TextDecoder.create('utf-8');
    const text: string = decoder.decodeToString(new Uint8Array(buffer, 0, read));
    // 带 BOM 的脚本会把一个不可见字符顶在正文最前面，交给引擎前先摘掉
    return text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close source file failed: %{public}s', JSON.stringify(e));
      }
    }
  }
}

/** uri 上的文件名（只用于提示；取不到就显示整条 uri） */
function fileNameOf(uri: string): string {
  const cut: number = uri.lastIndexOf('/');
  const raw: string = cut >= 0 ? uri.substring(cut + 1) : uri;
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}
