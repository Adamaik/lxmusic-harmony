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
  isSourceCheckupRunning,
  lastCheckupAt,
  loadCheckupResults,
  runSourceCheckup,
} from '../core/source/SourceCheckup';
import { SourceHealth, SourceRouter } from '../core/source/SourceRouter';
import {
  SUB_RESULT_FAILED,
  SUB_RESULT_UPDATE,
  SourceSubscription,
  SubscriptionRow,
} from '../core/source/SourceSubscription';
import { SubscriptionRecord } from '../core/source/SourceStore';
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

  // ------------------------------------------------------------ 音源订阅

  /**
   * 订阅记录（来源链接 + 订阅状态）
   *
   * 进页面读一次盘、改了就刷，渲染时只查这个数组：卡片是逐条渲染的，如果在 builder 里
   * 现去读文件，一次滚动就要读几十遍盘（见 SourceSubscription.list 的实现）。
   */
  @State subscriptions: SubscriptionRecord[] = [];
  /** 「检查全部更新 / 单源检查更新」的结果行：有更新 / 已是最新 / 检查失败 */
  @State subRows: SubscriptionRow[] = [];
  @State checkingAllUpdates: boolean = false;
  /** 正在单源检查的那个音源 id（按钮显示「检查中…」） */
  @State checkingOneId: string = '';
  /** 正在应用更新的那个订阅 id */
  @State updatingSubId: string = '';

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
    // 订阅要自己的存储初始化（只需一个 Context）；自动检查跟着进页面这一次机会走，
    // 但「最多每进程一次、12 小时内不重复、失败静默」都在 SourceSubscription 里把关
    this.initSubscription();
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
    // 页面被销毁重建后 this.checking 会丢（自检还在后台跑），以模块级状态为准：
    // 两批自检同时跑只会把彼此的脚本顶掉
    if (isSourceCheckupRunning()) {
      this.toast('自检正在后台进行，等它结束再试');
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
      // 同一个音源在订阅记录里的结论也要一起翻新：这条路径与「检查全部更新」走的是
      // 同一个 replaceSourceScript，不翻的话卡片上会一直挂着「上次查到有新版本」
      SourceSubscription.getInstance().markUpdated(info.id, info.version);
      this.refreshSubscriptions();
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
          const fresh: SourceInfo = applySourceUpdate(pending[i]);
          // 订阅记录的结论跟着翻新（见 updateOne 里的同一处说明）
          SourceSubscription.getInstance().markUpdated(fresh.id, fresh.version);
          ok += 1;
        } catch (e) {
          failed += 1;
          hilog.warn(DOMAIN, TAG, 'update source failed: %{public}s', (e as Error).message);
        }
      }
      this.updates = [];
      this.refreshSources();
      this.refreshSubscriptions();
      this.status = `更新完成：成功 ${ok} 个${failed > 0 ? `，失败 ${failed} 个（原音源未改动）` : ''}`;
    } finally {
      this.updating = false;
    }
  }

  // ------------------------------------------------------------ 音源订阅

  /**
   * 初始化订阅存储，并做「每次启动最多一次」的自动检查
   *
   * 自动检查的三个克制点由 SourceSubscription.maybeAutoCheck 把关（每进程一次、
   * 距上次检查不足 12 小时不发请求、失败静默）；这里只负责把结果接住：
   *   - 有结果就把它当成这一次的检查结论摆出来（进页面就能看到），
   *   - **不弹 toast、不改状态行为「失败」**：用户什么都没点，不该被提醒打扰。
   */
  private initSubscription(): void {
    const sub: SourceSubscription = SourceSubscription.getInstance();
    try {
      sub.init(this.getContext());
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'init subscription failed: %{public}s', (e as Error).message);
    }
    this.refreshSubscriptions();
    void sub.maybeAutoCheck().then((rows: SubscriptionRow[]) => {
      if (rows.length === 0) {
        return;
      }
      this.subRows = rows;
      this.refreshSubscriptions();
      let fresh: number = 0;
      for (const row of rows) {
        if (row.status === SUB_RESULT_UPDATE) {
          fresh += 1;
        }
      }
      if (fresh > 0) {
        this.status = `自动检查了 ${rows.length} 个订阅音源，其中 ${fresh} 个有新版本（可在「音源订阅」里更新）`;
      }
    }).catch((e: Error) => {
      hilog.info(DOMAIN, TAG, 'auto subscription check failed: %{public}s', e.message);
    });
  }

  private refreshSubscriptions(): void {
    const sub: SourceSubscription = SourceSubscription.getInstance();
    // 兜底再初始化一次：aboutToAppear 里如果拿不到 HostContext（组件树还没挂好），
    // 订阅存储就一直是未就绪状态，整个功能会静悄悄消失。刷新发生在用户真实操作之后，
    // 这时 Context 一定在，补一次 init 就能救回来（init 本身是幂等的）
    if (!sub.isReady()) {
      try {
        sub.init(this.getContext());
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'retry init subscription failed: %{public}s', (e as Error).message);
      }
    }
    this.subscriptions = sub.list();
  }

  private subRecordOf(id: string): SubscriptionRecord | null {
    for (const item of this.subscriptions) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  /** 来源链接（空串 = 没有：本地文件导入，或早期版本导入时没记下来） */
  private sourceUrlOf(id: string): string {
    const record: SubscriptionRecord | null = this.subRecordOf(id);
    return record !== null ? record.url : '';
  }

  private isSubscribed(id: string): boolean {
    const record: SubscriptionRecord | null = this.subRecordOf(id);
    return record !== null && record.subscribed && record.url.length > 0;
  }

  /** 这个源支持订阅吗（= 记下了来源链接） */
  private canSubscribe(id: string): boolean {
    return /^https?:\/\//.test(this.sourceUrlOf(id));
  }

  /** 能不能查更新：脚本自己声明了 updateUrl，或者我们知道它的来源链接 */
  private hasUpdateAddress(item: SourceInfo): boolean {
    const declared: string = item.updateUrl !== undefined ? item.updateUrl : '';
    if (/^https?:\/\//.test(declared)) {
      return true;
    }
    return this.canSubscribe(item.id);
  }

  /**
   * 卡片上那行小字：说清「订阅状态 / 为什么不能订阅」
   *
   * 「不能用」和「不知道能不能用」是两种完全不同的状态：没有来源链接的源不是坏了，
   * 只是我们不知道它的发布地址 —— 这一句必须写出来，否则用户只会觉得功能坏了。
   */
  private subStateText(item: SourceInfo): string {
    if (this.canSubscribe(item.id)) {
      return this.isSubscribed(item.id)
        ? '已订阅：会跟着来源链接更新'
        : '未订阅：可以订阅它，以后跟随来源链接更新';
    }
    return '没有来源链接（本地文件导入，或早期版本导入时没记），不支持订阅';
  }

  private subscribedCountOf(): number {
    let count: number = 0;
    for (const item of this.subscriptions) {
      if (item.subscribed && item.url.length > 0) {
        count += 1;
      }
    }
    return count;
  }

  /** 上次检查发现「有新版本」但还没更新的订阅数（不联网，只读记录） */
  private pendingUpdateCountOf(): number {
    let count: number = 0;
    for (const item of this.subscriptions) {
      if (item.subscribed && item.lastResult === SUB_RESULT_UPDATE) {
        count += 1;
      }
    }
    return count;
  }

  /** 本次结果里还能点「更新」的行数（有脚本正文才算，光知道有新版本不算） */
  private subRowUpdateCount(): number {
    let count: number = 0;
    for (const row of this.subRows) {
      if (row.update !== null) {
        count += 1;
      }
    }
    return count;
  }

  private lastSubCheckAt(): number {
    let newest: number = 0;
    for (const item of this.subscriptions) {
      if (item.lastCheckedAt > newest) {
        newest = item.lastCheckedAt;
      }
    }
    return newest;
  }

  private subSummaryText(): string {
    if (this.subscriptions.length === 0) {
      return '还没有记录到来源链接';
    }
    const parts: string[] = [`${this.subscribedCountOf()} 个已订阅`];
    const pending: number = this.pendingUpdateCountOf();
    if (pending > 0) {
      parts.push(`${pending} 个上次查到有新版本`);
    }
    return parts.join(' / ');
  }

  /** 没有来源链接的源有几个（音源订阅卡片底部那句提示用） */
  private linklessCount(): number {
    let count: number = 0;
    for (const item of this.sources) {
      if (!this.canSubscribe(item.id)) {
        count += 1;
      }
    }
    return count;
  }

  private toggleSubscribe(item: SourceInfo): void {
    if (!this.canSubscribe(item.id)) {
      // 老数据 / 本地文件导入：这里只能给出「怎么办」，不能假装订上了
      this.toast('这个源没有来源链接，无法订阅；把原链接重新导入一次即可补上');
      return;
    }
    const sub: SourceSubscription = SourceSubscription.getInstance();
    if (this.isSubscribed(item.id)) {
      sub.unsubscribe(item.id);
      this.status = `已取消订阅「${item.name}」（来源链接保留，随时可以订回来）`;
    } else if (sub.subscribe(item.id)) {
      this.status = `已订阅「${item.name}」：以后点「检查全部更新」会去来源链接拉最新脚本`;
    } else {
      this.toast('订阅失败，请把原链接重新导入一次');
    }
    this.refreshSubscriptions();
  }

  /**
   * 检查全部订阅的更新
   *
   * 与上面那个「检查更新」的分工：那个只查**脚本声明了 updateUrl** 的源（洛雪官方口径），
   * 这个查**用户订阅过**的源，并且在没有 updateUrl 时退回「导入时的那条链接」——
   * 这正是群里那些「源又不行了」的源能自己变新的关键。
   */
  private async checkAllSubscribed(): Promise<void> {
    if (this.checkingAllUpdates || this.checkingUpdates || this.checking || this.busy) {
      return;
    }
    const sub: SourceSubscription = SourceSubscription.getInstance();
    if (!sub.isReady()) {
      this.toast('订阅记录读写不可用，暂时无法检查订阅更新');
      return;
    }
    const count: number = sub.subscribedCount();
    if (count === 0) {
      this.toast('还没有订阅任何音源：先在下面某个音源那一行点「订阅」');
      return;
    }
    this.checkingAllUpdates = true;
    this.subRows = [];
    this.status = `正在检查 ${count} 个订阅音源的更新…`;
    try {
      const rows: SubscriptionRow[] = await sub.checkSubscribed((done: number, total: number) => {
        this.status = `正在检查订阅更新：${done}/${total}…`;
      }, () => false);
      this.subRows = rows;
      let hasUpdate: number = 0;
      let latest: number = 0;
      let failed: number = 0;
      for (const row of rows) {
        if (row.status === SUB_RESULT_UPDATE) {
          hasUpdate += 1;
        } else if (row.status === SUB_RESULT_FAILED) {
          failed += 1;
        } else {
          latest += 1;
        }
      }
      const parts: string[] = [];
      if (hasUpdate > 0) {
        parts.push(`${hasUpdate} 个有更新`);
      }
      if (latest > 0) {
        parts.push(`${latest} 个已是最新`);
      }
      if (failed > 0) {
        parts.push(`${failed} 个检查失败`);
      }
      this.status = `订阅更新检查完成：${parts.length > 0 ? parts.join(' / ') : '没有取到结果'}`;
      this.refreshSubscriptions();
    } catch (e) {
      this.status = `检查订阅更新失败: ${(e as Error).message}`;
    } finally {
      this.checkingAllUpdates = false;
    }
  }

  /** 单源检查更新（音源卡片上的「检查更新」；没订阅但知道链接的源也能查） */
  private async checkSourceUpdateOf(item: SourceInfo): Promise<void> {
    if (this.checkingOneId.length > 0 || this.checkingAllUpdates || this.checking || this.busy) {
      this.toast('正在检查其它更新，等这一下结束');
      return;
    }
    this.checkingOneId = item.id;
    this.status = `正在检查「${item.name}」有没有新版本…`;
    try {
      const row: SubscriptionRow = await SourceSubscription.getInstance().checkOne(item.id);
      // 单源结论并进订阅区那张结果表：有更新时用户就地能点「更新」，不用再跑一遍全量检查
      const rows: SubscriptionRow[] = this.subRows.filter((one: SubscriptionRow) => one.id !== row.id);
      rows.unshift(row);
      this.subRows = rows;
      this.status = `「${item.name}」${row.note}`;
      this.refreshSubscriptions();
    } catch (e) {
      this.status = `检查「${item.name}」的更新失败: ${(e as Error).message}`;
    } finally {
      this.checkingOneId = '';
    }
  }

  /**
   * 应用一条订阅更新
   *
   * 走 SourceSubscription.applyRow -> SourceEngine.replaceSourceScript：**id 不变**，
   * 播放列表里的引用、当前加载着的音源都还在（删了重导会让它们全部失效）。
   * 失败抛错就什么都不写，原音源保持不动。
   */
  private applySubRow(row: SubscriptionRow): void {
    if (row.update === null || this.updatingSubId.length > 0) {
      return;
    }
    this.updatingSubId = row.id;
    try {
      const info: SourceInfo | null = SourceSubscription.getInstance().applyRow(row);
      if (info === null) {
        this.status = `「${row.name}」这次没有可用的新脚本，未做改动`;
        return;
      }
      this.status = `已把「${info.name}」更新到 ${this.versionText(info.version)}（点「加载」后新脚本才生效）`;
      this.toast(`已更新「${info.name}」`);
      this.subRows = this.subRows.filter((one: SubscriptionRow) => one.id !== row.id);
      this.refreshSources();
      this.refreshSubscriptions();
    } catch (e) {
      this.status = `更新「${row.name}」失败: ${(e as Error).message}（原音源未改动）`;
    } finally {
      this.updatingSubId = '';
    }
  }

  /** 把本次结果里所有「有更新」的订阅一次更新掉（同样走原地替换） */
  private updateAllSubRows(): void {
    if (this.updatingSubId.length > 0) {
      return;
    }
    const pending: SubscriptionRow[] = this.subRows.filter((row: SubscriptionRow) => row.update !== null);
    if (pending.length === 0) {
      return;
    }
    const sub: SourceSubscription = SourceSubscription.getInstance();
    const done: Set<string> = new Set<string>();
    let ok: number = 0;
    let failed: number = 0;
    for (const row of pending) {
      try {
        sub.applyRow(row);
        done.add(row.id);
        ok += 1;
      } catch (e) {
        failed += 1;
        hilog.warn(DOMAIN, TAG, 'update subscription source failed: %{public}s', (e as Error).message);
      }
    }
    // 只摘掉真的更新成功的那几条：失败的行要留在表里，用户才能看见原因并重试
    this.subRows = this.subRows.filter((row: SubscriptionRow) => !done.has(row.id));
    this.refreshSources();
    this.refreshSubscriptions();
    this.status = `更新完成：成功 ${ok} 个${failed > 0 ? `，失败 ${failed} 个（原音源未改动）` : ''}`;
  }

  /** 结果行的一句话：新版本号 → / 已是最新 / 检查失败的原因 */
  private subRowStatusText(row: SubscriptionRow): string {
    if (row.status === SUB_RESULT_FAILED) {
      return row.note;
    }
    if (row.status === SUB_RESULT_UPDATE) {
      return `${this.versionText(row.localVersion)} → ${this.versionText(row.remoteVersion)}　${row.note}`;
    }
    return row.note.length > 0 ? row.note : '已是最新';
  }

  private subRowColor(row: SubscriptionRow): Resource {
    if (row.status === SUB_RESULT_UPDATE) {
      return C_ICON_ORANGE;
    }
    if (row.status === SUB_RESULT_FAILED) {
      return C_RED;
    }
    return C_TEXT_WEAK;
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
        /**
         * 记下这次导入用的链接，并默认订阅
         *
         * 这是「音源订阅」唯一的信息来源：引擎只认脚本内容，不知道 URL（洛雪的口径里
         * 音源就是一段脚本）；而用户手上真正有的、能拿来说「以后照着这个更新」的，
         * 恰恰只有这条链接。放在这里而不是引擎里，也因为导入成功才该记：
         * 下载失败时列表里根本没这条源，记了就是孤儿记录。
         */
        if (SourceSubscription.getInstance().rememberImportedUrl(info.id, input)) {
          this.refreshSubscriptions();
        }
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
    // 删源时 SourceStore.remove 会顺手清掉它的订阅记录（见那边的 pruneSubscriptions），
    // 这里只需要把界面这一份刷新过来；订阅结果表里也把那一条摘掉
    this.subRows = this.subRows.filter((row: SubscriptionRow) => row.id !== id);
    this.refreshSubscriptions();
    this.status = '已删除该音源';
    this.refreshSources();
  }

  private toggleSandboxEnv(): void {
    // 自检正在把各个源依次装进同一个沙箱：这时改 lx.env 会被下一次 loadSource 覆盖，
    // 用户以为切了、实际没生效。直接拦住，别做「悄悄被还原」的事。
    if (this.checking || this.busy) {
      this.toast(this.checking ? '自检进行中，等它结束再切换兼容模式' : '正在加载音源，等这一下结束再切换');
      return;
    }
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
    if (this.checking || isSourceCheckupRunning()) {
      // 离线自检也要往同一个沙箱里装示例源，会把自检正在测的源顶掉、两边结论都不可信
      this.toast('一键自检进行中，等它结束再做离线自检（或先点「停止自检」）');
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
    /**
     * 根容器从 `Column` 换成 `Stack` —— 多出来的那一层就是「标题栏自己的不透明底色」
     *
     * 原来这里是 `Column { Scroll }`，页面里没有任何东西给顶部那条标题栏铺底：壳层
     * （pages/Index.ets 的 subTitleBarStyle）把 HDS 标题栏刷成了**纯透明**
     * （backgroundColor: Color.Transparent + maskExtraHeight: 0），页面上只靠 WidePane
     * 那条 TopFade 渐变遮一下。而那条渐变是「页面底色 -> 全透明」，到标题栏下沿时已经
     * 透掉九成，于是列表一往上滚就把字压到「音源设置」标题和状态栏上（11-17 23:37 的
     * 那张列表被标题压住、11-18 11:07 那张顶部残留「加载」「删除」字样的截图）。
     *
     * 换成 Stack 后：底下那层照旧铺满、照旧从透明标题栏底下穿过去（沉浸式观感不变，
     * 顶部占位也照旧跟着内容滚走），上面再垫一块与页面底色相同的实心 Column 当标题栏
     * 底色（见 build 末尾）。HDS 标题栏是独立图层、永远画在页面内容之上，所以标题与
     * 返回键不会被这块底压住 —— 被它挡住的只有本该被挡住的、穿过去的那部分列表内容。
     *
     * 没有改成「给容器加 padding / 把 Scroll 挤到标题栏下面」：那样会把滚动内容裁在
     * 标题栏下边缘（本文件顶部占位那段注释说的就是这件事），而且内容再也滚不到标题栏
     * 底下，与项目里其它设置页的观感不一致。
     */
    Stack({ alignContent: Alignment.TopStart }) {
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
          // 这一段内容裁在标题栏下边缘，看起来就"像被顶栏挡住"（首页就是这么做的）。
          // 多出来的那 6vp 是留给标题栏底部那块实心底的缝（见 build 末尾）：不滚动的时候
          // 第一行正好落在实心底下方 6vp 处、不会被它切掉，滚起来才会从它底下穿过去。
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

                /**
                 * 检查全部更新（订阅入口，页面顶部）
                 *
                 * 与上面「检查更新」的分工写清在这里，免得用户以为两个按钮是重复的：
                 *   - 「检查更新」只查**脚本自己声明了 updateUrl** 的源（洛雪官方口径，老入口）；
                 *   - 「检查全部更新」查**用户订阅过**的源，并在脚本没声明地址时退回
                 *     「导入时的那条链接」—— 群里那些「源又不行了、只能满群找新链接」的源，
                 *     绝大多数根本没写 updateUrl，能自己变新靠的就是这一条链接。
                 *
                 * 为什么单独占一行而不挤进上面那两个按钮里：三个按钮并排时手机上每个只剩
                 * 八十来 vp，「检查全部更新」六个字会被挤成一团；而且这是本次新增的主入口，
                 * 值得让人一眼看见。
                 */
                Button(this.checkingAllUpdates ? '正在检查订阅更新…' : '检查全部更新')
                  .fontSize(13)
                  .height(36)
                  .width('100%')
                  .backgroundColor(C_FILL_SOFT_STRONG)
                  .fontColor(C_TEXT)
                  .enabled(!this.checkingAllUpdates && !this.checking && !this.busy)
                  .onClick(() => {
                    this.checkAllSubscribed();
                  })

                /**
                 * 订阅检查的结果表：有更新 / 已是最新 / 检查失败，逐条列出来
                 *
                 * 「已是最新」和失败的也要列：用户点了一次「检查全部更新」，想看的是每一个
                 * 订阅的去向；只列有更新的那几个，失败与没查的会被误当成也是最新。
                 */
                if (this.subRows.length > 0) {
                  Column({ space: 6 }) {
                    Row() {
                      Text('本次检查结果')
                        .fontSize(F_TAB)
                        .fontColor(C_TEXT_WEAK)
                        .layoutWeight(1)
                        .textAlign(TextAlign.Start)
                      // 只在这一轮真拿到了新脚本时才给「全部更新」：上次会话残留的
                      // 「有新版本」是没有脚本正文的，点了也写不了（见 subRowUpdateCount）
                      if (this.subRowUpdateCount() > 0) {
                        Text(this.updatingSubId.length > 0 ? '更新中…' : `全部更新（${this.subRowUpdateCount()}）`)
                          .fontSize(F_TAB)
                          .fontColor(C_RED)
                          .padding({ left: 8, right: 2, top: 2, bottom: 2 })
                          .onClick(() => {
                            this.updateAllSubRows();
                          })
                      }
                    }
                    .width('100%')
                    ForEach(this.subRows, (row: SubscriptionRow) => {
                      Row({ space: 8 }) {
                        Column({ space: 2 }) {
                          Text(row.name)
                            .fontSize(13)
                            .fontColor(C_TEXT)
                            .width('100%')
                            .textAlign(TextAlign.Start)
                          Text(`${this.subRowStatusText(row)}${row.fromSourceUrl ? '　· 按来源链接' : ''}`)
                            .fontSize(11)
                            .fontColor(this.subRowColor(row))
                            .width('100%')
                            .textAlign(TextAlign.Start)
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                        if (row.update !== null) {
                          Text(this.updatingSubId === row.id ? '更新中…' : '更新')
                            .fontSize(12.5)
                            .fontColor(this.updatingSubId === row.id ? C_TEXT_WEAK : C_RED)
                            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
                            .onClick(() => {
                              this.applySubRow(row);
                            })
                        }
                      }
                      .width('100%')
                    }, (row: SubscriptionRow) => `${row.id}_${row.status}_${row.remoteVersion}`)
                  }
                  .width('100%')
                  .padding(10)
                  .borderRadius(10)
                  .backgroundColor(C_FILL_SOFT)
                }

                // 一个地址都没有时说明清楚：这不是按钮坏了，是脚本没给地址、我们也不知道来源链接。
                // 条件里带上「一个来源链接都没有」：只要订过任何一个源，「检查全部更新」就还能用，
                // 这时再说「无法自动检查」就是假话。
                if (this.sources.length > 0 && this.sourcesWithUpdateUrl().length === 0
                  && this.linklessCount() === this.sources.length) {
                  Text('这些音源既没有声明更新地址（头部 @updateUrl / 运行时 showUpdateAlert），'
                    + '也没有记下来源链接（本地文件导入，或早期版本导入时没记），无法自动检查更新：'
                    + '把音源链接重新导入一次就能补上来源链接，之后就能订阅并跟着更新。')
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

                  /**
                   * 订阅 / 检查更新（只有「知道更新地址」的源才出现这一行）
                   *
                   * 为什么做成小字而不是第四个按钮：这一行说的是「以后怎么自己变新」，
                   * 不是「现在怎么用」，跟上面三个按钮不是一个层级；一行小字刚好装下
                   * 状态 + 两个动作，也不会把卡片撑高。
                   *
                   * 没有来源链接的源这里什么都不显示（老数据里这是多数），
                   * 统一在下面「音源订阅」卡片里解释一句「为什么不能订阅、怎么补」，
                   * 否则每张卡片下面都挂一行「不支持订阅」会把页面变成一张抱怨清单。
                   */
                  if (this.canSubscribe(item.id) || this.hasUpdateAddress(item)) {
                    Row({ space: 10 }) {
                      Text(this.subStateText(item))
                        .fontSize(11)
                        .fontColor(C_TEXT_WEAK)
                        .layoutWeight(1)
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.canSubscribe(item.id)) {
                        Text(this.isSubscribed(item.id) ? '取消订阅' : '订阅')
                          .fontSize(11.5)
                          .fontColor(C_RED)
                          .padding({ left: 8, right: 2, top: 2, bottom: 2 })
                          .onClick(() => {
                            this.toggleSubscribe(item);
                          })
                      }
                      if (this.hasUpdateAddress(item)) {
                        Text(this.checkingOneId === item.id ? '检查中…' : '检查更新')
                          .fontSize(11.5)
                          .fontColor(this.checkingOneId === item.id ? C_TEXT_WEAK : C_TEXT)
                          .padding({ left: 8, right: 2, top: 2, bottom: 2 })
                          .onClick(() => {
                            this.checkSourceUpdateOf(item);
                          })
                      }
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                  }

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
              }, (item: SourceInfo) => `${item.id}_${item.disabled === true ? 'off' : 'on'}_${this.verdictOf(item)}`
                + `_${this.isSubscribed(item.id) ? 'sub' : 'nosub'}`)
            }
            .width('100%')
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 音源订阅
          /**
           * 订阅：把「导入时的那条链接」变成「以后能一键跟新的地址」
           *
           * 群里的原话（11-17 aries「导过来的原来歌单全是人机验证失败」、11-23
           * CharlotteZero「现在音源全用不了」、🐉「说维护」）背后是同一件事：音源脚本
           * 被厂商封了，作者发了新版，但版本只在群里流通 —— 用户既不知道该去哪找，
           * 也不知道手上这份是不是旧的。上面「一键自检」只回答「现在还能不能用」，
           * 这一段回答的是「它过期了怎么自己变新」。
           *
           * 这一段只讲「哪些源订了、为什么有的源订不了」；动作与结果表都放在上面
           * 「已导入音源」卡片里（页面顶部一进来就能看到，点完立刻看到结论）。
           * 逐源卡片本来就挤了加载/停用/删除三个按钮，订阅这种事再往每张卡上堆入口
           * 就彻底没法看了，所以独立成段、只留状态与解释。
           *
           * 一个音源都没有时这一段仍然显示：新用户恰恰最需要知道「导入的链接会被记住、
           * 以后能跟着更新」，而这段里已经写清「还没有记录到来源链接」，不会造成误解。
           */
          Column({ space: 10 }) {
            this.sectionCard('音源订阅')
            Column({ space: 8 }) {
              Row() {
                Text(this.subSummaryText())
                  .fontSize(F_SUB)
                  .fontColor(C_TEXT_SUB)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Start)
                if (this.lastSubCheckAt() > 0 && !this.checkingAllUpdates) {
                  Text(`上次检查 ${this.shortTime(this.lastSubCheckAt())}`)
                    .fontSize(F_TAB)
                    .fontColor(C_TEXT_WEAK)
                }
              }
              .width('100%')

              // 入口放在页面顶部（「已导入音源」卡片里，紧挨「一键自检」）：这一段只解释
              // 「订阅是什么、为什么订阅值得点」，动作统一在上面那一个按钮上，不在这里
              // 再放一个同名按钮 —— 一页两个「检查全部更新」只会让人不知道该点哪个
              Text('订阅记下的就是导入时用的那条链接。订了之后，上方「检查全部更新」会去脚本声明的'
                + '更新地址拉新版，脚本没声明就退回这条链接；确认是新版后由你点「更新」——'
                + '原地替换，音源 id 不变，播放列表和正在用的音源都不会失效。'
                + '自动检查最多每次启动一次、12 小时内不重复，失败不打扰。')
                .fontSize(F_TAB)
                .fontColor(C_TEXT_WEAK)
                .width('100%')
                .textAlign(TextAlign.Start)

              // 老数据普遍没有来源链接（早期版本导入时根本没记）：这里不能只显示「不支持订阅」，
              // 得给出下一步动作，否则用户会以为功能坏了
              if (this.sources.length > 0 && this.linklessCount() > 0) {
                Text(`${this.linklessCount()} 个音源没有来源链接（本地文件导入，或早期版本导入时没记下来），`
                  + '所以无法订阅：把那条音源链接重新粘贴到上面「导入音源」再导一次就能补上'
                  + '（脚本版本没变会原地更新，不会多出一条；作者已发新版时会多出一条，删掉旧的那条即可）。')
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
                  .enabled(!this.busy && !this.checking)
                  .onClick(() => {
                    this.toggleSandboxEnv();
                  })
                Button(this.busy ? '自检中…' : '一键离线自检')
                  .fontSize(13)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor(C_FILL_SOFT_STRONG)
                  .fontColor(C_TEXT)
                  .enabled(!this.busy && !this.checking)
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
      // Stack 里没有「主轴」可分，layoutWeight 不起作用：这里直接铺满整页高度，
      // 内容照样能滚到标题栏底下（只是会被上面那块实心底挡住，见下面）
      .width('100%')
      .height('100%')
      .align(Alignment.Top)

      /**
       * 标题栏（状态栏 + 标题栏）自己的不透明底色
       *
       * 高度就取壳层传进来的 `topInset`：Index.ets 里给这一页传的是
       * `HDS_TITLE_BAR_HEIGHT + this.topInset`，即「状态栏高度 + 标题栏高度」，
       * 所以这块底正好盖满顶部那一条，一点不差。它挡的是两样东西：
       *   1. 滚动内容穿到标题 / 状态栏上（截图 B 里那一截「加载」「删除」残留文字）；
       *   2. 页面刚进来、上一页还没退干净时从透明标题栏透出来的旧内容
       *      （截图 A 里透在标题背后的「音源」字样与图标）。
       *
       * 取色用 `C_BG` 而不是写死色值：`c_bg` 在 resources/base 与 resources/dark 各有一份，
       * 深浅模式自动换（写死的话深色下就是一块白）。它和 TopFade 的起色 `c_top_fade`
       * 本来就是同一个值（见 element/color.json），所以这块底与外面那条渐隐蒙版之间
       * 不会出现色差接缝。
       *
       * 不设 hitTestBehavior（保持默认拦截触摸）：这就是一条不透明的标题栏，点在它上面
       * 不该落到被它挡住、根本看不见的列表行上（否则会出现「点了个寂寞，某个按钮却响应了」）。
       */
      Column()
        .width('100%')
        .height(this.topInset)
        .backgroundColor(C_BG)
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
