import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceEngine } from './SourceEngine';
import { SourceHealth, SourceRouter } from './SourceRouter';
import { LxQuality, SourceInfo, SourceMeta, SupportedSource } from './LxTypes';
import { parseSourceMeta } from './LxMetadata';
import { LxMusicInfo, isSearchSupported, searchMusic } from '../music/MusicSearch';
import { LxResponse, lxRequest } from './LxHttp';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceCheckup';

/**
 * 一键自检 / 检查更新
 *
 * 解决的是群里反复出现的那句「音源又不行了，换个源」：
 * 用户不需要知道哪个源今天还活着，也不需要一个个点过去试 ——
 * 这里用应用**真实播放同一条链路**（内置搜索拿到一首真歌 -> 当前音源解析播放地址）
 * 把每个源、每个平台都试一遍，然后：
 *   - 按「可用 / 部分平台可用 / 失效 / 无法验证」分组展示，附最后成功时间与失败原因；
 *   - 把结论写回 SourceRouter（markSuccess / markFailure），可用的源自然排到前面
 *     （排序规则仍然只在 SourceRouter.candidates 里，这里不另造一套）；
 *   - 结论落盘（SourceStore 的 source_checkup.json），下次进设置页不必重跑。
 *
 * 另外还做「检查更新」：洛雪官方头部字段里**没有** updateUrl，但有一部分源会在头部写
 * `@updateUrl`、或在运行时用 `lx.send('showUpdateAlert', {updateUrl})` 报一次（两处都已收下，
 * 见 LxMetadata / SourceEngine.handleUpdateAlert）。有地址的源可以并发拉取新脚本，
 * 比对版本后原地更新（复用导入的解析与写入逻辑，失败不影响原源）。
 */

/** 自检时用来找“真歌”的关键词：各平台曲库都有，且不是敏感内容 */
const CHECKUP_KEYWORD: string = '晴天';

/**
 * 每个源最多测几个平台
 *
 * 一个源常常声明 4~5 个平台，全测一遍要十几二十秒（每个平台一次真实解析）。
 * 只测最常用的前三个：结论已经足够区分「能用 / 部分能用 / 全挂」，
 * 也让「一键自检」的总时长可控（见下面的预算说明）。
 */
const MAX_PLATFORMS_PER_SOURCE: number = 3;

/** 平台优先级：按用户实际使用频率排，取前几个来测 */
const PLATFORM_ORDER: string[] = ['kw', 'kg', 'mg', 'tx', 'wy', 'qs'];

/** 搜索测试歌曲的超时（毫秒） */
const SEARCH_TIMEOUT_MS: number = 8000;
/** 单次解析播放地址的超时（毫秒） */
const RESOLVE_TIMEOUT_MS: number = 8000;
/** 一个平台最多试几首歌（第一首可能只是“这首歌没版权”，换一首再判死） */
const RESOLVE_CANDIDATES: number = 2;
/** 自检用的音质：128k 是所有源都声明的最低档，最不容易因为「没有母带」被误判 */
const PROBE_QUALITY: LxQuality = '128k';

/** 检查更新：下载新脚本的超时（毫秒） */
const UPDATE_TIMEOUT_MS: number = 15000;
/** 检查更新：并发数（网络请求，与沙箱无关，可以并发） */
const UPDATE_CONCURRENCY: number = 3;

/** 自检结论 */
export const VERDICT_OK: string = 'ok';
export const VERDICT_PARTIAL: string = 'partial';
export const VERDICT_DEAD: string = 'dead';
export const VERDICT_UNKNOWN: string = 'unknown';

/** 检查更新结果的文件格式版本 */
const CHECKUP_SCHEMA_VERSION: number = 1;

/** 单个平台的自检结论 */
export interface PlatformProbe {
  platform: string;
  /** 解析出播放地址了吗 */
  ok: boolean;
  /**
   * 这次结论「不算数」
   *
   * 拿不到测试歌曲（内置搜索自己挂了 / 该平台搜不到）时，我们其实没验证到音源本身，
   * 不能据此判它失效 —— 否则会把好好的源标成灰色，还把它从候选里降级。
   */
  inconclusive: boolean;
  /** 界面上一句话：成功是「歌名」，失败是原因 */
  detail: string;
  elapsedMs: number;
}

/** 单个音源的自检结论（落盘，界面直接用） */
export interface SourceCheckupResult {
  id: string;
  name: string;
  version: string;
  /** VERDICT_OK / PARTIAL / DEAD / UNKNOWN */
  verdict: string;
  /** 脚本能不能加载并初始化（false 时 probes 为空） */
  loaded: boolean;
  probes: PlatformProbe[];
  okPlatforms: number;
  failedPlatforms: number;
  /** 路由记忆里最后一次成功的时刻（0 = 从没成功过） */
  lastOkAt: number;
  /** 路由记忆里最近一次失败的原因（可能为空） */
  lastError: string;
  /** 一句话总结（状态行/卡片副标题用） */
  message: string;
  checkedAt: number;
}

/** 一次完整自检的报告 */
export interface CheckupReport {
  checkedAt: number;
  results: SourceCheckupResult[];
  /** 是不是被用户中途取消（结果只覆盖已测过的源） */
  cancelled: boolean;
  totalMs: number;
}

/** 进度回调（界面显示「3/5 正在检查「某某源」…」） */
export interface CheckupProgress {
  done: number;
  total: number;
  /** 当前正在处理的音源名 */
  current: string;
  /** 'load' = 正在加载脚本；'probe' = 正在测某个平台；'done' = 收尾 */
  phase: string;
}

export interface CheckupOptions {
  onProgress?: (progress: CheckupProgress) => void;
  /** 返回 true 就尽快停下（已在跑的单个请求会走完，超时上限见常量） */
  isCancelled?: () => boolean;
  /** 只检查这些音源 id（空/缺省 = 全部启用的源） */
  ids?: string[];
}

/** 落盘的自检状态（SourceStore 的 source_checkup.json） */
interface CheckupState {
  version: number;
  checkedAt: number;
  results: SourceCheckupResult[];
}

/** 检查更新的结果 */
export interface SourceUpdateInfo {
  id: string;
  name: string;
  /** 本地版本 */
  localVersion: string;
  /** 拉下来的版本 */
  remoteVersion: string;
  hasUpdate: boolean;
  /** 版本号没变但脚本内容变了（作者改了接口却没改版本号，很常见） */
  contentChanged: boolean;
  error: string;
  /** 界面上一句话说明（如「远端版本更旧」「脚本缺少头部」） */
  note: string;
  /** 拉下来的新脚本正文（hasUpdate 为 true 时才有） */
  script: string;
  /** 用的是哪个更新地址 */
  url: string;
  checkedAt: number;
}

// ------------------------------------------------------------------ 通用小工具

function messageOf(e: Error): string {
  if (e === null || e === undefined) {
    return '未知错误';
  }
  return e.message !== undefined && e.message.length > 0 ? e.message : '未知错误';
}

function truncate(text: string, max: number): string {
  const oneLine: string = text.split('\n').join(' ').trim();
  return oneLine.length > max ? `${oneLine.substring(0, max)}…` : oneLine;
}

/**
 * 给一个 Promise 套时间上限
 *
 * 只负责让调用方「不再等」，底层请求自己会超时（引擎的 getMusicUrl 传了 timeoutMs，
 * lxRequest 也有 timeout）。这样即使某个源卡死，自检也不会把页面拖住。
 */
function withTimeout<T>(work: Promise<T>, ms: number, message: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled: boolean = false;
    const timer: number = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error(message));
      }
    }, ms);
    work.then((value: T) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }
    }).catch((err: Error) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(messageOf(err)));
      }
    });
  });
}

function cancelledBy(options: CheckupOptions): boolean {
  return options.isCancelled !== undefined && options.isCancelled();
}

/** 这几种报错换一首歌再试可能有救（“这首歌没版权”与“接口全挂了”要分开） */
function mayTryAnotherSong(message: string): boolean {
  const lowered: string = message.toLowerCase();
  const hints: string[] = ['未找到', '不存在', '无版权', '没有', 'empty', '404', 'not found', '无结果'];
  for (const hint of hints) {
    if (lowered.includes(hint.toLowerCase())) {
      return true;
    }
  }
  return false;
}

/** 这几种报错说明「引擎当时的状态不对」（多半是自检期间有播放/下载切了音源），不是源本身坏了 */
function isEngineStateError(message: string): boolean {
  const hints: string[] = ['音源未加载', '未初始化', '不支持平台', '沙箱未挂载', '未实现 musicUrl'];
  for (const hint of hints) {
    if (message.includes(hint)) {
      return true;
    }
  }
  return false;
}

/** 平台显示名（与设置页同一套，日志里用） */
function platformLabel(platform: string): string {
  if (platform === 'kw') {
    return '酷我';
  }
  if (platform === 'kg') {
    return '酷狗';
  }
  if (platform === 'mg') {
    return '咪咕';
  }
  if (platform === 'tx') {
    return 'QQ';
  }
  if (platform === 'wy') {
    return '网易';
  }
  if (platform === 'qs') {
    return '汽水';
  }
  return platform;
}

/**
 * 版本号比较（只做「谁更新」这一个判断）
 *
 * 音源版本号写法并不统一（`1.2.1` / `v2.0` / `2024.10.1`），按点/连字符切段逐段比数字，
 * 数字相同就比字符串，拿不到数字的段一律当 0。返回 >0 表示 a 比 b 新。
 * 这比「字符串不相等就算有更新」稳：作者把版本写回退（或远端是旧镜像）时不会误报。
 */
export function compareVersion(a: string, b: string): number {
  const clean = (value: string): string => {
    const trimmed: string = value.trim();
    return trimmed.length > 0 && (trimmed.charAt(0) === 'v' || trimmed.charAt(0) === 'V')
      ? trimmed.substring(1)
      : trimmed;
  };
  const left: string[] = clean(a).split(/[.\-_+ ]/);
  const right: string[] = clean(b).split(/[.\-_+ ]/);
  const count: number = Math.max(left.length, right.length);
  for (let i = 0; i < count; i++) {
    const l: string = i < left.length ? left[i] : '0';
    const r: string = i < right.length ? right[i] : '0';
    const ln: number = Number.parseInt(l, 10);
    const rn: number = Number.parseInt(r, 10);
    const lNum: number = Number.isNaN(ln) ? 0 : ln;
    const rNum: number = Number.isNaN(rn) ? 0 : rn;
    if (lNum !== rNum) {
      return lNum > rNum ? 1 : -1;
    }
    if (lNum === 0 && rNum === 0 && l !== r) {
      // 都不是数字（如 `beta` / `rc1`）：按字符串比，保证至少是稳定且可解释的
      return l > r ? 1 : -1;
    }
  }
  return 0;
}

// ------------------------------------------------------------------ 单平台探针

/**
 * 测一个平台：内置搜索找一首真歌 -> 让**当前已加载的音源**解析它的播放地址
 *
 * 为什么不用 SourceTest 的现成函数：那些函数是「导入一个在线源再测」，每次都会新导入
 * 一条记录；批量自检要对**列表里已有的源**逐个测，而且必须复用同一个已加载的沙箱。
 *
 * 为什么要先搜索：musicInfo 的字段（songmid / hash / strMediaMid / copyrightId…）
 * 各平台不一样，凭空造一个必然被源脚本判成「参数不对」而误判失效。用应用真实搜索出来的
 * 歌曲，与用户点播放时走的是同一条数据链路。
 */
async function probePlatform(platform: string): Promise<PlatformProbe> {
  const engine: SourceEngine = SourceEngine.getInstance();
  const started: number = Date.now();
  let songs: LxMusicInfo[] = [];
  try {
    songs = await withTimeout(
      searchMusic(CHECKUP_KEYWORD, platform, 1, 5),
      SEARCH_TIMEOUT_MS,
      `搜索超时（${Math.round(SEARCH_TIMEOUT_MS / 1000)} 秒）`,
    );
  } catch (e) {
    // 搜索是应用自己的接口，它挂了说明不了音源好坏：不计入失效
    return {
      platform: platform,
      ok: false,
      inconclusive: true,
      detail: `拿不到测试歌曲，无法验证：${truncate(messageOf(e as Error), 60)}`,
      elapsedMs: Date.now() - started,
    };
  }
  if (songs.length === 0) {
    return {
      platform: platform,
      ok: false,
      inconclusive: true,
      detail: `搜索没有结果，无法验证（${platformLabel(platform)} 的搜索接口可能自身不可用）`,
      elapsedMs: Date.now() - started,
    };
  }
  const attempts: number = Math.min(songs.length, RESOLVE_CANDIDATES);
  let lastError: string = '';
  for (let i = 0; i < attempts; i++) {
    const song: LxMusicInfo = songs[i];
    try {
      const url: string = await engine.getMusicUrl(JSON.stringify(song), PROBE_QUALITY, platform, RESOLVE_TIMEOUT_MS);
      if (url.length === 0) {
        throw new Error('音源返回了空地址');
      }
      return {
        platform: platform,
        ok: true,
        inconclusive: false,
        detail: `「${song.name}」解析成功`,
        elapsedMs: Date.now() - started,
      };
    } catch (e) {
      lastError = messageOf(e as Error);
      // 自检途中如果用户开始播放/下载，换源会把沙箱里的脚本换成别家的，这时报的
      // 「音源未加载 / 不支持该平台」是自检自己的现场被改了，不能算到源头上
      if (isEngineStateError(lastError)) {
        return {
          platform: platform,
          ok: false,
          inconclusive: true,
          detail: `自检期间音源被切换，这次结果不算数：${truncate(lastError, 50)}`,
          elapsedMs: Date.now() - started,
        };
      }
      // 只有「这首歌本身取不到」才值得换一首再试；超时/脚本报错再试一遍只是白白多等
      if (!mayTryAnotherSong(lastError)) {
        break;
      }
    }
  }
  return {
    platform: platform,
    ok: false,
    inconclusive: false,
    detail: truncate(lastError, 80),
    elapsedMs: Date.now() - started,
  };
}

// ------------------------------------------------------------------ 单源自检

/**
 * 自检一个音源
 *
 * 会把这个源加载进沙箱（全局单例），调用方必须在整批结束后还原现场
 * （见 runSourceCheckup 的 finally，走 engine.restoreSourceSnapshot）。
 */
async function checkOneSource(item: SourceInfo, index: number, total: number,
  options: CheckupOptions): Promise<SourceCheckupResult> {
  const engine: SourceEngine = SourceEngine.getInstance();
  const router: SourceRouter = SourceRouter.getInstance();
  const health: SourceHealth = router.healthOf(item.id);
  const progress = (phase: string, current: string): void => {
    if (options.onProgress !== undefined) {
      options.onProgress({ done: index, total: total, current: current, phase: phase });
    }
  };

  progress('load', item.name);
  let supportedPlatforms: string[] = [];
  try {
    const declared: Record<string, SupportedSource> = await engine.loadSource(item.id);
    supportedPlatforms = Object.keys(declared);
  } catch (e) {
    // 连脚本都加载不起来：这才是真正的「失效」，按它已知的平台记失败
    const reason: string = truncate(messageOf(e as Error), 90);
    const known: string[] = health.platforms;
    for (const platform of known) {
      router.markFailure(item.id, platform, `自检加载失败：${reason}`);
    }
    return {
      id: item.id,
      name: item.name,
      version: item.version,
      verdict: VERDICT_DEAD,
      loaded: false,
      probes: [],
      okPlatforms: 0,
      failedPlatforms: known.length,
      lastOkAt: router.healthOf(item.id).lastOkAt,
      lastError: reason,
      message: `脚本加载失败：${reason}`,
      checkedAt: Date.now(),
    };
  }

  // 只测「声明了 musicUrl 且应用有内置搜索」的平台，按常用度取前几个
  const targets: string[] = [];
  for (const platform of PLATFORM_ORDER) {
    if (targets.length >= MAX_PLATFORMS_PER_SOURCE) {
      break;
    }
    if (supportedPlatforms.includes(platform) && isSearchSupported(platform)) {
      targets.push(platform);
    }
  }

  const probes: PlatformProbe[] = [];
  let cancelled: boolean = false;
  for (const platform of targets) {
    if (cancelledBy(options)) {
      cancelled = true;
      break;
    }
    progress('probe', `${item.name} · ${platformLabel(platform)}`);
    const probe: PlatformProbe = await probePlatform(platform);
    probes.push(probe);
    // 结论立刻写回路由表：可用的排前、失效的排后（排序规则仍在 SourceRouter 里）
    if (!probe.inconclusive) {
      if (probe.ok) {
        router.markSuccess(item.id, platform);
      } else {
        router.markFailure(item.id, platform, `自检：${probe.detail}`);
      }
    }
  }

  let okPlatforms: number = 0;
  let failedPlatforms: number = 0;
  let inconclusiveCount: number = 0;
  for (const probe of probes) {
    if (probe.inconclusive) {
      inconclusiveCount += 1;
    } else if (probe.ok) {
      okPlatforms += 1;
    } else {
      failedPlatforms += 1;
    }
  }

  let verdict: string = VERDICT_UNKNOWN;
  let message: string = '';
  if (okPlatforms > 0 && failedPlatforms === 0 && inconclusiveCount === 0) {
    verdict = VERDICT_OK;
    message = `可用（${probes.map((p: PlatformProbe) => platformLabel(p.platform)).join(' / ')}）`;
  } else if (okPlatforms > 0) {
    verdict = VERDICT_PARTIAL;
    const failedNames: string[] = [];
    for (const probe of probes) {
      if (!probe.inconclusive && !probe.ok) {
        failedNames.push(platformLabel(probe.platform));
      }
    }
    message = failedNames.length > 0
      ? `部分平台可用：${failedNames.join(' / ')} 取不到播放地址`
      : `可用，但 ${inconclusiveCount} 个平台没能验证`;
  } else if (failedPlatforms > 0) {
    verdict = VERDICT_DEAD;
    let firstReason: string = '';
    for (const probe of probes) {
      if (!probe.inconclusive && !probe.ok) {
        firstReason = probe.detail;
        break;
      }
    }
    message = `失效：${firstReason}`;
  } else {
    verdict = VERDICT_UNKNOWN;
    message = targets.length === 0
      ? '这个源没有可自检的平台（未声明内置搜索支持的平台）'
      : '没能验证：测试歌曲搜索不可用';
  }
  if (cancelled) {
    message = `${message}（自检已取消，结果不完整）`;
  }

  const after: SourceHealth = router.healthOf(item.id);
  return {
    id: item.id,
    name: item.name,
    version: item.version,
    verdict: verdict,
    loaded: true,
    probes: probes,
    okPlatforms: okPlatforms,
    failedPlatforms: failedPlatforms,
    lastOkAt: after.lastOkAt,
    lastError: after.lastError,
    message: message,
    checkedAt: Date.now(),
  };
}

// ------------------------------------------------------------------ 批量自检

/**
 * 一键自检（并发说明见下）
 *
 * **为什么是串行而不是并发 3**：源脚本都跑在同一个 ArkWeb 沙箱里，加载一个源会重置
 * 沙箱上下文（引擎的 loadSource 一进来就清 supported / 重新注入脚本）。并发加载两个源
 * 会让它们互相把脚本顶掉，结论不可信、还可能把正在播放的解析打断。所以「跨源并发」
 * 在架构上不成立；这里并发的是**一个源内部的网络请求**（探针内部），并且每个请求都有
 * 上限：搜索 8 秒、单次解析 8 秒、每个源最多 3 个平台 —— 单个源最坏约 45 秒，
 * 期间界面能看进度、能取消（取消在源/平台边界生效，不会卡死）。
 *
 * 自检前会记下当前音源，结束后按原样还原（engine.restoreSourceSnapshot）：
 * 自检绝不能把用户正在用的源换成「最后一个被测的源」。
 */
export async function runSourceCheckup(options: CheckupOptions): Promise<CheckupReport> {
  const engine: SourceEngine = SourceEngine.getInstance();
  const startedAt: number = Date.now();
  const previousId: string = engine.getLoadedSourceId();
  const previousEnv: string = engine.getSandboxEnv();
  const all: SourceInfo[] = engine.listSources();
  const filter: string[] = options.ids !== undefined ? options.ids : [];
  const targets: SourceInfo[] = [];
  for (const item of all) {
    if (filter.length === 0 || filter.includes(item.id)) {
      targets.push(item);
    }
  }
  const results: SourceCheckupResult[] = [];
  let cancelled: boolean = false;
  try {
    for (let i = 0; i < targets.length; i++) {
      if (cancelledBy(options)) {
        cancelled = true;
        break;
      }
      const item: SourceInfo = targets[i];
      if (options.onProgress !== undefined) {
        options.onProgress({ done: i, total: targets.length, current: item.name, phase: 'load' });
      }
      try {
        const one: SourceCheckupResult = await checkOneSource(item, i, targets.length, options);
        results.push(one);
      } catch (e) {
        // 单个源自检炸了不能带走整批：记一条「失效」继续下一个
        const reason: string = truncate(messageOf(e as Error), 90);
        hilog.warn(DOMAIN, TAG, 'checkup of %{public}s failed: %{public}s', item.id, reason);
        results.push({
          id: item.id,
          name: item.name,
          version: item.version,
          verdict: VERDICT_DEAD,
          loaded: false,
          probes: [],
          okPlatforms: 0,
          failedPlatforms: 0,
          lastOkAt: SourceRouter.getInstance().healthOf(item.id).lastOkAt,
          lastError: reason,
          message: `自检异常：${reason}`,
          checkedAt: Date.now(),
        });
      }
      if (options.onProgress !== undefined) {
        options.onProgress({
          done: i + 1, total: targets.length, current: item.name, phase: 'probe',
        });
      }
    }
  } finally {
    try {
      await engine.restoreSourceSnapshot(previousId, previousEnv);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'restore source after checkup failed: %{public}s', messageOf(e as Error));
    }
  }
  const report: CheckupReport = {
    checkedAt: Date.now(),
    results: results,
    cancelled: cancelled,
    totalMs: Date.now() - startedAt,
  };
  if (results.length > 0) {
    saveCheckupReport(report);
  }
  if (options.onProgress !== undefined) {
    options.onProgress({ done: results.length, total: targets.length, current: '', phase: 'done' });
  }
  return report;
}

// ------------------------------------------------------------------ 自检结果落盘

function parseCheckupState(raw: string): CheckupState | null {
  if (raw.length === 0) {
    return null;
  }
  try {
    const state: CheckupState = JSON.parse(raw) as CheckupState;
    if (state.version !== CHECKUP_SCHEMA_VERSION || state.results === undefined) {
      return null;
    }
    return state;
  } catch (e) {
    return null;
  }
}

/** 读上一次自检的结论（没有就返回空数组） */
export function loadCheckupResults(): SourceCheckupResult[] {
  const state: CheckupState | null = parseCheckupState(SourceEngine.getInstance().loadCheckupState());
  return state !== null ? state.results : [];
}

export function lastCheckupAt(): number {
  const state: CheckupState | null = parseCheckupState(SourceEngine.getInstance().loadCheckupState());
  return state !== null ? state.checkedAt : 0;
}

/**
 * 保存本次自检结果：按 id 合并
 *
 * 不整份覆盖：取消自检时只测了前几个源，覆盖会把其余的结论抹成「没测过」，
 * 用户看到的颜色反而比取消前更糟。
 */
function saveCheckupReport(report: CheckupReport): void {
  const engine: SourceEngine = SourceEngine.getInstance();
  const previous: CheckupState | null = parseCheckupState(engine.loadCheckupState());
  const merged: SourceCheckupResult[] = [];
  const updated: Set<string> = new Set<string>();
  if (previous !== null) {
    for (const item of previous.results) {
      let replaced: boolean = false;
      for (const fresh of report.results) {
        if (fresh.id === item.id) {
          merged.push(fresh);
          updated.add(fresh.id);
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        merged.push(item);
      }
    }
  }
  for (const fresh of report.results) {
    if (!updated.has(fresh.id)) {
      merged.push(fresh);
    }
  }
  const state: CheckupState = {
    version: CHECKUP_SCHEMA_VERSION,
    checkedAt: report.checkedAt,
    results: merged,
  };
  engine.saveCheckupState(JSON.stringify(state));
}

// ------------------------------------------------------------------ 检查更新

/** 下载脚本正文（不导入） */
function downloadScript(url: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    lxRequest(url, { method: 'get', timeout: UPDATE_TIMEOUT_MS, rawText: true }, (resp: LxResponse) => {
      if (!resp.ok && resp.statusCode >= 400) {
        reject(new Error(`下载失败（HTTP ${resp.statusCode}）`));
        return;
      }
      const body: string | Object | number[] = resp.body;
      if (typeof body === 'string') {
        const text: string = body as string;
        if (text.trim().length === 0) {
          reject(new Error('下载回来的内容是空的'));
          return;
        }
        resolve(text);
        return;
      }
      reject(new Error('下载回来的内容不是脚本文本'));
    }, (message: string) => {
      reject(new Error(`下载失败：${message}`));
    });
  });
}

function findSource(id: string): SourceInfo | null {
  for (const item of SourceEngine.getInstance().listAllSources()) {
    if (item.id === id) {
      return item;
    }
  }
  return null;
}

/**
 * 检查一个源有没有新版本
 *
 * 只在「脚本声明过更新地址」时才有得查：
 *   1. 头部 `@updateUrl`（第三方源的扩展写法，见 LxMetadata）；
 *   2. 运行时 `lx.send('showUpdateAlert', { updateUrl })`（引擎已记下，见 handleUpdateAlert）。
 * 两种都没有时返回 error 说明，不弹错、不影响原源。
 */
export async function checkSourceUpdate(id: string): Promise<SourceUpdateInfo> {
  const engine: SourceEngine = SourceEngine.getInstance();
  const info: SourceInfo | null = findSource(id);
  const empty: SourceUpdateInfo = {
    id: id,
    name: info !== null ? info.name : id,
    localVersion: info !== null ? info.version : '',
    remoteVersion: '',
    hasUpdate: false,
    contentChanged: false,
    error: '',
    note: '',
    script: '',
    url: '',
    checkedAt: Date.now(),
  };
  if (info === null) {
    empty.error = '音源不存在';
    return empty;
  }
  const url: string = info.updateUrl !== undefined ? info.updateUrl : '';
  if (!/^https?:\/\//.test(url)) {
    empty.error = '该音源没有声明更新地址';
    return empty;
  }
  empty.url = url;
  let script: string = '';
  try {
    script = await withTimeout(downloadScript(url), UPDATE_TIMEOUT_MS + 2000, '下载新脚本超时');
  } catch (e) {
    empty.error = truncate(messageOf(e as Error), 80);
    return empty;
  }
  if (script.trim().length === 0) {
    empty.error = '更新地址返回了空内容';
    return empty;
  }
  let remoteVersion: string = '';
  try {
    const remote: SourceMeta = parseSourceMeta(script);
    remoteVersion = remote.version;
  } catch (e) {
    // 拿回来的可能是 HTML 错误页 / 跳转页：绝不能拿它覆盖掉能用的脚本
    empty.error = '更新地址给的不是洛雪音源脚本（缺少头部注释块）';
    return empty;
  }
  const localScript: string = engine.readSourceScript(id);
  const versionCmp: number = compareVersion(remoteVersion, info.version);
  const contentChanged: boolean = script !== localScript;
  const result: SourceUpdateInfo = {
    id: id,
    name: info.name,
    localVersion: info.version,
    remoteVersion: remoteVersion,
    hasUpdate: false,
    contentChanged: contentChanged,
    error: '',
    note: '',
    script: script,
    url: url,
    checkedAt: Date.now(),
  };
  if (versionCmp > 0) {
    result.hasUpdate = true;
    result.note = `新版本 ${remoteVersion}`;
  } else if (versionCmp < 0) {
    result.note = `远端版本更旧（${remoteVersion}），已忽略`;
  } else if (contentChanged) {
    // 版本号没变但内容变了：作者改了接口但忘了改版本，这种情况很常见
    result.hasUpdate = true;
    result.note = `版本号未变（${remoteVersion}），但脚本内容有变化`;
  } else {
    result.note = '已是最新';
  }
  return result;
}

/**
 * 批量检查更新（并发 ≤3）
 *
 * 与自检不同，这里**没有沙箱参与**（只是下载 + 解析头部 + 比版本），所以可以真并发。
 * 三个并发足够把常见 3~5 个源的等待压到一轮，又不会让手机网络排队太长。
 */
export async function checkSourceUpdates(ids: string[],
  onProgress?: (done: number, total: number) => void,
  isCancelled?: () => boolean): Promise<SourceUpdateInfo[]> {
  const results: SourceUpdateInfo[] = [];
  const total: number = ids.length;
  let nextIndex: number = 0;
  let done: number = 0;
  const worker = async (): Promise<void> => {
    while (nextIndex < ids.length) {
      if (isCancelled !== undefined && isCancelled()) {
        return;
      }
      const index: number = nextIndex;
      nextIndex += 1;
      const outcome: SourceUpdateInfo = await checkSourceUpdate(ids[index]);
      results.push(outcome);
      done += 1;
      if (onProgress !== undefined) {
        onProgress(done, total);
      }
    }
  };
  const workers: Promise<void>[] = [];
  const workerCount: number = Math.min(UPDATE_CONCURRENCY, ids.length);
  for (let i = 0; i < workerCount; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}

/**
 * 应用一次更新：用新脚本原地替换（id 不变，列表里不会多出一条）
 *
 * 替换只发生在**新脚本解析成功之后**（checkSourceUpdate 已经校验过头部），
 * 下载失败 / 内容不是脚本时调用方不会走到这里，原源因此不会被写坏。
 */
export function applySourceUpdate(update: SourceUpdateInfo): SourceInfo {
  return SourceEngine.getInstance().replaceSourceScript(update.id, update.script);
}
