import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceStore } from './SourceStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceRouter';

/** 记忆文件的格式版本：将来加减字段时按这个号做迁移 */
const SCHEMA_VERSION: number = 1;
/**
 * 连续失败到这个次数，就把它从「首选」降级到队尾
 *
 * 为什么是 2：一次失败可能只是网络抖了一下（用户点歌时正好在切网），
 * 连续两次失败才足以说明「这个源今天对这个平台不行了」。
 */
const DEMOTE_STREAK: number = 2;
/**
 * 失败记忆的保鲜期：失败之后超过这么久没再失败，计数就清零重新评估
 *
 * 为什么需要它：这份记忆是落盘的，如果只增不减，「昨天某个源抽风」
 * 会让它今天永远排在队尾。半小时也正好是 PlatformHealth 里认证类冷却的上限，
 * 两边口径一致。
 */
const STREAK_TTL_MS: number = 30 * 60 * 1000;
/** lastError 只存一小段：它只是日志/界面上的线索，不是错误归档 */
const ERROR_KEEP: number = 60;

/** 某个音源在某个平台上的历史结论 */
export interface SourceRoute {
  /** 音源 id */
  id: string;
  /** 最后一次成功的时刻（0 = 从没在这个平台成功过） */
  lastOkAt: number;
  /** 连续失败次数（成功即归零） */
  failStreak: number;
  /** 最后一次失败的时刻 */
  lastFailAt: number;
  /** 最后一次失败的报错短语（截断保存） */
  lastError: string;
}

interface RouterFile {
  version: number;
  /** 平台 id -> 该平台的路由表 */
  routes: Record<string, SourceRoute[]>;
  /** 音源 id -> 它在 inited 时声明了 musicUrl 的平台 */
  caps: Record<string, string[]>;
  /** 音源 id -> 平台 -> 该平台声明的音质档（"按音质选源"用） */
  quals: Record<string, Record<string, string[]>>;
  /** 音源 id -> 名字（源被删掉之后，日志里还能说清是哪一个） */
  names: Record<string, string>;
}

/**
 * 音源路由表：记住「哪个源在哪个平台成功过」，并据此排出一个尝试顺序
 *
 * 解决的是「配了好几个音源，第一个放不了，第二个能放，但每首歌都先等第一个超时」：
 * 成功过的源会被排到前面并**粘住**，下一次同平台的歌直接走它，不再重新撞墙。
 *
 * 三条自我修正规则（记忆必须会过期，否则它迟早变成新的坑）：
 *   1. **源被删掉 / 脚本被替换** → 立刻从表里清掉（见 forget / SourceEngine 的调用）；
 *   2. **连续失败 2 次** → 降级到队尾，把机会让给别的源；成功一次立刻回到首位；
 *   3. **失败超过 30 分钟** → 失败计数衰减归零，重新给一次公平的机会。
 *
 * 另外启动时会用当前的音源列表校验一遍（purge）：表里指向已经不在的源直接丢弃，
 * 避免用户删了源之后每次挑歌都先试一个不存在的 id。
 *
 * 持久化到源存储目录（与音源脚本同一个 filesDir 下的子目录），
 * 写失败只记日志：这份记忆只是加速用的缓存，坏了最多退化成「每次都从头试」。
 */
export class SourceRouter {
  private static instance: SourceRouter | null = null;

  static getInstance(): SourceRouter {
    if (SourceRouter.instance === null) {
      SourceRouter.instance = new SourceRouter();
    }
    return SourceRouter.instance;
  }

  private store: SourceStore | null = null;
  /** 平台 id -> 路由表 */
  private routes: Map<string, SourceRoute[]> = new Map<string, SourceRoute[]>();
  /** 音源 id -> 支持的平台 */
  private caps: Map<string, string[]> = new Map<string, string[]>();
  /** 音源 id -> 平台 -> 声明的音质档 */
  private quals: Map<string, Map<string, string[]>> = new Map<string, Map<string, string[]>>();
  /** 音源 id -> 名字 */
  private names: Map<string, string> = new Map<string, string>();

  /**
   * 启动时初始化：读盘 + 校验 + 衰减
   *
   * @param store       音源存储（负责落盘位置）
   * @param existingIds 当前真实存在的音源 id（用来丢掉指向已删除源的记忆）
   */
  init(store: SourceStore, existingIds: string[]): void {
    this.store = store;
    this.routes.clear();
    this.caps.clear();
    this.names.clear();
    const raw: string = store.loadRouter();
    if (raw.length > 0) {
      this.decode(raw);
    }
    const purged: number = this.purge(existingIds);
    const decayed: number = this.decayStreaks();
    if (raw.length > 0 || purged > 0 || decayed > 0) {
      hilog.info(DOMAIN, TAG,
        'router ready: platforms=%{public}d sources=%{public}d purged=%{public}d decayed=%{public}d',
        this.routes.size, this.caps.size, purged, decayed);
    }
    this.persist();
  }

  // ---------------------------------------------------------------- 读

  /**
   * 这个平台按什么顺序试哪些源
   *
   * 分四段，越靠前越「值得先试」：
   *   1. 可信段：在这个平台成功过且没连着失败 → 按「失败次数少 → 最近成功过」排；
   *   2. 当前已加载的源（若调用方说它支持这个平台）：省掉一次换源加载；
   *   3. 降级段：连连失败的，排到后面（仍然会试，成功了立刻回来）；
   *   4. 能力已知但还没有历史结论的源；
   *   5. 能力未知（从没加载过、不知道支不支持这个平台）的源，排最后。
   *
   * 只返回 id 数组，不碰引擎：换源加载、超时、冷却由调用方（PlaySession）执行。
   */
  candidates(platform: string, loadedId: string, loadedSupports: boolean, allIds: string[],
    requireQuality: string = ''): string[] {
    const present: Set<string> = new Set<string>();
    for (const id of allIds) {
      present.add(id);
    }
    const routes: SourceRoute[] = this.routesOf(platform);
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    const push = (id: string): void => {
      if (id.length === 0 || seen.has(id) || !present.has(id)) {
        return;
      }
      seen.add(id);
      out.push(id);
    };

    const trusted: SourceRoute[] = [];
    const demoted: SourceRoute[] = [];
    for (const route of routes) {
      if (!present.has(route.id)) {
        continue;
      }
      if (route.failStreak >= DEMOTE_STREAK) {
        demoted.push(route);
      } else {
        trusted.push(route);
      }
    }
    trusted.sort((a: SourceRoute, b: SourceRoute): number => {
      if (a.failStreak !== b.failStreak) {
        return a.failStreak - b.failStreak;
      }
      return b.lastOkAt - a.lastOkAt;
    });
    demoted.sort((a: SourceRoute, b: SourceRoute): number => a.lastFailAt - b.lastFailAt);
    for (const route of trusted) {
      push(route.id);
    }
    if (loadedSupports) {
      push(loadedId);
    }
    for (const route of demoted) {
      push(route.id);
    }
    // 能力已知（声明了 musicUrl）但没有历史结论的源
    const known: string[] = [];
    const unknown: string[] = [];
    for (const id of allIds) {
      if (seen.has(id)) {
        continue;
      }
      const platforms: string[] | undefined = this.caps.get(id);
      if (platforms === undefined) {
        // 从没加载过：不知道它支不支持这个平台，排最后（真加载了才知道）
        unknown.push(id);
      } else if (platforms.includes(platform)) {
        known.push(id);
      }
      // 已知不支持这个平台的源直接不列：它连 action 都没有，试了也是白加载一次脚本
    }
    for (const id of known) {
      push(id);
    }
    for (const id of unknown) {
      push(id);
    }
    if (requireQuality.length === 0) {
      return out;
    }
    // 「按音质选源」：声明了目标档的源整体提到前面（组内保持原顺序 ——
    // 组内顺序本来就带着「上次成功过」「刚失败过」这些信息，不该被打乱）
    const declaring: string[] = [];
    const others: string[] = [];
    for (const id of out) {
      if (this.declaresQuality(id, platform, requireQuality)) {
        declaring.push(id);
      } else {
        others.push(id);
      }
    }
    return declaring.length > 0 ? declaring.concat(others) : out;
  }

  /** 这个平台的第一选择（没有记忆返回空串），日志/界面上用 */
  preferredFor(platform: string): string {
    const routes: SourceRoute[] = this.routesOf(platform);
    let best: SourceRoute | null = null;
    for (const route of routes) {
      if (route.failStreak >= DEMOTE_STREAK) {
        continue;
      }
      if (best === null || route.failStreak < best.failStreak ||
        (route.failStreak === best.failStreak && route.lastOkAt > best.lastOkAt)) {
        best = route;
      }
    }
    return best !== null ? best.id : '';
  }

  /** 源名字（日志里显示用；不在表里返回空串） */
  nameOf(id: string): string {
    const name: string | undefined = this.names.get(id);
    return name !== undefined ? name : '';
  }

  /** 这个源在这个平台是不是「刚刚连着失败过」 */
  isDemoted(id: string, platform: string): boolean {
    for (const route of this.routesOf(platform)) {
      if (route.id === id) {
        return route.failStreak >= DEMOTE_STREAK;
      }
    }
    return false;
  }

  /** 这个源失败几次了（调试/日志用） */
  failStreakOf(id: string, platform: string): number {
    for (const route of this.routesOf(platform)) {
      if (route.id === id) {
        return route.failStreak;
      }
    }
    return 0;
  }

  // ---------------------------------------------------------------- 写

  /** 记住「这个源声明支持哪些平台、每个平台声明了哪些音质档」（每次成功加载后调用） */
  recordCapability(id: string, name: string, qualitysOf: Record<string, string[]>): void {
    if (id.length === 0) {
      return;
    }
    const platforms: string[] = Object.keys(qualitysOf);
    this.caps.set(id, platforms);
    const byPlatform: Map<string, string[]> = new Map<string, string[]>();
    for (const platform of platforms) {
      byPlatform.set(platform, qualitysOf[platform]);
    }
    this.quals.set(id, byPlatform);
    if (name.length > 0) {
      this.names.set(id, name);
    }
    this.persist();
  }

  /**
   * 这个源在这个平台上声明了某个音质档吗
   *
   * 「按音质选源」用：用户选了母带，就该优先找声明了母带的源。
   * 没加载过的源没有这份信息 —— 返回 false（宁可按老顺序试，也不要瞎猜）。
   */
  declaresQuality(id: string, platform: string, quality: string): boolean {
    const byPlatform: Map<string, string[]> | undefined = this.quals.get(id);
    if (byPlatform === undefined) {
      return false;
    }
    const list: string[] | undefined = byPlatform.get(platform);
    return list !== undefined && list.includes(quality);
  }

  /**
   * 有没有**任意一个已知源**在这个平台声明了某一档
   *
   * 播放链路用它决定「值不值得为这一档先按高档去查缓存/解析」：
   * 一个都没声明的话，硬按母带去查只会白白错过普通档的缓存。
   */
  declaredByAny(platform: string, quality: string): boolean {
    let found: boolean = false;
    this.quals.forEach((byPlatform: Map<string, string[]>) => {
      if (found) {
        return;
      }
      const list: string[] | undefined = byPlatform.get(platform);
      if (list !== undefined && list.includes(quality)) {
        found = true;
      }
    });
    return found;
  }

  /**
   * 某个源在这个平台成功了一次
   *
   * 成功是**最强证据**：失败计数清零、时间戳刷新，立刻回到队首。
   */
  markSuccess(id: string, platform: string): void {
    if (id.length === 0 || platform.length === 0) {
      return;
    }
    const route: SourceRoute = this.ensureRoute(platform, id);
    route.lastOkAt = Date.now();
    route.failStreak = 0;
    route.lastError = '';
    this.persist();
  }

  /**
   * 某个源在这个平台失败了一次
   *
   * 只累计失败次数与原因，不在这里做「永久拉黑」：降级是排序层面的，
   * 冷却时长由 PlatformHealth 决定，两者互不替代。
   */
  markFailure(id: string, platform: string, message: string): void {
    if (id.length === 0 || platform.length === 0) {
      return;
    }
    const route: SourceRoute = this.ensureRoute(platform, id);
    route.failStreak = route.failStreak + 1;
    route.lastFailAt = Date.now();
    const oneLine: string = message.split('\n').join(' ').trim();
    route.lastError = oneLine.length > ERROR_KEEP ? oneLine.substring(0, ERROR_KEEP) : oneLine;
    hilog.info(DOMAIN, TAG, 'mark failure: %{public}s/%{public}s streak=%{public}d',
      this.nameOf(id).length > 0 ? this.nameOf(id) : id, platform, route.failStreak);
    this.persist();
  }

  /**
   * 把这些音源从记忆里彻底抹掉（源被删掉 / 脚本被替换时调用）
   *
   * 脚本换了内容等于换了一套后端：它上次声明支持哪些平台、在哪些平台成功过，
   * 都不该继续沿用。
   */
  forget(ids: string[]): void {
    if (ids.length === 0) {
      return;
    }
    let changed: boolean = false;
    for (const id of ids) {
      if (this.caps.delete(id)) {
        changed = true;
      }
      if (this.quals.delete(id)) {
        changed = true;
      }
      if (this.names.delete(id)) {
        changed = true;
      }
      this.routes.forEach((routes: SourceRoute[], platform: string) => {
        const next: SourceRoute[] = routes.filter((route: SourceRoute) => route.id !== id);
        if (next.length !== routes.length) {
          changed = true;
          this.routes.set(platform, next);
        }
      });
    }
    if (changed) {
      hilog.info(DOMAIN, TAG, 'forget sources: %{public}s', ids.join(','));
      this.persist();
    }
  }

  /** 清空全部记忆（设置里「重置音源切换记忆」用） */
  reset(): void {
    this.routes.clear();
    this.caps.clear();
    this.quals.clear();
    this.names.clear();
    this.persist();
  }

  // ---------------------------------------------------------------- 内部

  private routesOf(platform: string): SourceRoute[] {
    const routes: SourceRoute[] | undefined = this.routes.get(platform);
    return routes !== undefined ? routes : [];
  }

  private ensureRoute(platform: string, id: string): SourceRoute {
    const routes: SourceRoute[] = this.routesOf(platform);
    for (const route of routes) {
      if (route.id === id) {
        return route;
      }
    }
    const created: SourceRoute = {
      id: id,
      lastOkAt: 0,
      failStreak: 0,
      lastFailAt: 0,
      lastError: '',
    };
    routes.push(created);
    this.routes.set(platform, routes);
    return created;
  }

  /** 丢掉指向「已经不存在的音源」的记忆，返回丢弃条数 */
  private purge(existingIds: string[]): number {
    const present: Set<string> = new Set<string>();
    for (const id of existingIds) {
      present.add(id);
    }
    let dropped: number = 0;
    const emptyPlatforms: string[] = [];
    this.routes.forEach((routes: SourceRoute[], platform: string) => {
      const next: SourceRoute[] = routes.filter((route: SourceRoute) => present.has(route.id));
      dropped += routes.length - next.length;
      if (next.length === 0) {
        emptyPlatforms.push(platform);
      } else {
        this.routes.set(platform, next);
      }
    });
    for (const platform of emptyPlatforms) {
      this.routes.delete(platform);
    }
    this.caps.forEach((_platforms: string[], id: string) => {
      if (!present.has(id)) {
        this.caps.delete(id);
        this.quals.delete(id);
        this.names.delete(id);
        dropped += 1;
      }
    });
    return dropped;
  }

  /** 失败记忆的保鲜期：太久没再失败的计数归零，返回衰减条数 */
  private decayStreaks(): number {
    const now: number = Date.now();
    let decayed: number = 0;
    this.routes.forEach((routes: SourceRoute[]) => {
      for (const route of routes) {
        if (route.failStreak > 0 && now - route.lastFailAt > STREAK_TTL_MS) {
          route.failStreak = 0;
          route.lastError = '';
          decayed += 1;
        }
      }
    });
    return decayed;
  }

  private decode(raw: string): void {
    try {
      const file: RouterFile = JSON.parse(raw) as RouterFile;
      if (file.version !== SCHEMA_VERSION) {
        // 版本不认识就当没有：这是缓存，不是用户数据，宁可重新观察
        hilog.info(DOMAIN, TAG, 'router state version %{public}d, ignore', file.version);
        return;
      }
      if (file.routes !== undefined) {
        const platforms: string[] = Object.keys(file.routes);
        for (const platform of platforms) {
          this.routes.set(platform, file.routes[platform]);
        }
      }
      if (file.caps !== undefined) {
        const ids: string[] = Object.keys(file.caps);
        for (const id of ids) {
          this.caps.set(id, file.caps[id]);
        }
      }
      if (file.names !== undefined) {
        const ids: string[] = Object.keys(file.names);
        for (const id of ids) {
          this.names.set(id, file.names[id]);
        }
      }
      if (file.quals !== undefined) {
        const ids: string[] = Object.keys(file.quals);
        for (const id of ids) {
          const byPlatform: Record<string, string[]> = file.quals[id];
          const map: Map<string, string[]> = new Map<string, string[]>();
          const platforms: string[] = Object.keys(byPlatform);
          for (const platform of platforms) {
            map.set(platform, byPlatform[platform]);
          }
          this.quals.set(id, map);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to parse router state: %{public}s', JSON.stringify(e));
    }
  }

  private persist(): void {
    if (this.store === null) {
      return;
    }
    const routes: Record<string, SourceRoute[]> = {};
    this.routes.forEach((value: SourceRoute[], key: string) => {
      routes[key] = value;
    });
    const caps: Record<string, string[]> = {};
    this.caps.forEach((value: string[], key: string) => {
      caps[key] = value;
    });
    const names: Record<string, string> = {};
    this.names.forEach((value: string, key: string) => {
      names[key] = value;
    });
    const quals: Record<string, Record<string, string[]>> = {};
    this.quals.forEach((byPlatform: Map<string, string[]>, id: string) => {
      const one: Record<string, string[]> = {};
      byPlatform.forEach((value: string[], platform: string) => {
        one[platform] = value;
      });
      quals[id] = one;
    });
    const file: RouterFile = {
      version: SCHEMA_VERSION, routes: routes, caps: caps, quals: quals, names: names,
    };
    this.store.saveRouter(JSON.stringify(file));
  }
}
