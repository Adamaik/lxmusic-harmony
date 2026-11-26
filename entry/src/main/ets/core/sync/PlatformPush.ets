import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SongItem } from '../player/PlaySession';
import { LocalLibrary } from './LocalLibrary';
import { FavoriteEvent, setFavoriteEventHandler } from './FavoriteEventBus';
import { asNumber, asString } from '../music/PlatformHttp';
import { PlatformPushSettings } from '../settings/PlatformPushSettings';
import { WyWriteResult, wyCanWrite, wyLike, wyLikedIds } from '../music/WyWrite';
import { txCanWrite, txFavorite, txResolveSongType } from '../music/TxWrite';
import { fetchTxLikedIds, TxLikedSong } from '../music/TxRecommend';
import { wySongsByIds } from '../music/MusicList';
import { songIdentityOf } from '../music/SongIdentity';
import { matchTrackOnPlatform, PlatformMatch } from '../music/PlatformMatch';
import { musicAccount } from '../music/MusicAccount';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlatformPush';

/** 返回给界面的「首条原因」最长多少字：错误体可能很长，截断避免把弹窗撑爆 */
const ERROR_BRIEF_MAX: number = 120;

/**
 * 远端「我喜欢」缓存有效期（毫秒）
 *
 * 自动同步每收藏一首都要「先查远端有没有」，每次都拉全量列表太重（几千首的账号
 * 一次几百 KB）。缓存住，成功写入后自己增删对应 id，10 分钟重新对一次即可。
 */
const REMOTE_CACHE_TTL_MS: number = 10 * 60 * 1000;

/**
 * 「平台登录已失效」的全局信号（AppStorage）
 *
 * 值是 ${platform}:：时间戳让同一个平台连续失效也能重复触发弹窗。
 * Index 页订阅它并弹窗引导用户重新登录；同时这里已经把该平台**自动登出**，
 * 这样用户不会带着一个「看起来已登录、实际不能写」的假登录态继续用。
 */
export const K_PLATFORM_LOGIN_EXPIRED: string = 'cfg_platform_login_expired';

/**
 * 「本机收藏 → 平台账号」的单向镜像同步
 *
 * ## 方向只有一个：本机 → 平台
 * 本机收藏是唯一事实来源。这里**从不**把平台上的收藏拉回来改本机（不增本机收藏、
 * 不删本机收藏），读取远端只用于回答一个问题：「这首是不是已经在平台上了」。
 *
 * ## 什么时候会发请求
 * 1. 用户在设置页点「立即同步」→ `pushFavorites()`：把本机收藏里尚未在平台上的歌补推上去；
 * 2. 总开关打开时，用户收藏/取消收藏一首歌 → `FavoriteEventBus` 事件 → `applyFavoriteChange()`：
 *    收藏就推「喜欢」，取消收藏就取消平台上的「喜欢」。取消收藏属于**用户的明确意图**，
 *    所以这里会真的删（与「手动补推只增不删」不冲突：手动补推永远不删，删除只由取消收藏触发）。
 * 总开关关着时，两条路都在最前面直接返回，一个请求都不发。
 *
 * ## 为什么必须先查远端
 * 平台接口对「已经红心」的歌再写一次会回 405（限流/拒绝），200 首里大半已经收藏过，
 * 全量硬推的结果就是「卡 70 秒然后全失败」。所以每一首写之前先看远端集合，已收藏的
 * 直接记进账本、不再发写请求 —— 既省请求，也不会把账号推到风控里。
 *
 * ## 账本（已推送记录）
 * `PlatformPushSettings` 里按平台存 id 列表：写成功、或确认远端已有，都记一笔，下次直接跳过。
 * 取消收藏成功（或确认远端本来就没有）就把这笔划掉，重新收藏时会再次推送。
 *
 * ## 日志纪律
 * 只记平台、计数、id 后四位，**不记歌名、不记 Cookie、不记请求头、不记响应体**。
 * 失败原因只放进返回给界面的 message（截断到 120 字），不进日志。
 */

/** 从 musicInfoJson 里取出来的推送要素（字段名对齐 core/music/MusicSearch.ets 的 LxMusicInfo） */
interface PushSongInfo {
  /** 平台标识（json 里也有一份，用于自洽校验） */
  source: string;
  /** 洛雪的 songmid：tx 是 mid（字母数字），wy 是数字 id */
  songmid: string;
  /** 数字 id：tx 由接口的 item.id 写入，wy 通常没有（用 songmid 兜） */
  songId: string;
  /** QQ 曲型；洛雪老结构里没有这个字段，有就复用，没有就向平台解析 */
  songType: number;
}

export class PlatformPush {
  private static instance: PlatformPush | null = null;

  static getInstance(): PlatformPush {
    if (PlatformPush.instance === null) {
      PlatformPush.instance = new PlatformPush();
    }
    return PlatformPush.instance;
  }

  private inited: boolean = false;

  /**
   * 串行队列：自动推送（收藏事件）与手动补推都排在这一条链上
   *
   * 并发没有意义：两段 250ms 频控互相穿插会让实际间隔减半，还容易把账号推到限流。
   * 用 Promise 链实现「一次只跑一个任务」，简单且不需要额外锁。
   */
  private chain: Promise<void> = Promise.resolve();

  /** 网易远端「我喜欢」缓存 */
  private wyRemote: Set<number> | null = null;
  private wyRemoteAt: number = 0;
  /** 网易远端已收藏歌曲的身份集合（跨音源去重） */
  private wyIdentities: Set<string> | null = null;
  /** QQ 远端「我喜欢」缓存 */
  private txRemote: Set<number> | null = null;
  private txRemoteAt: number = 0;
  /** QQ 远端已收藏歌曲的身份集合（跨音源去重；QQ 列表本身带歌名/歌手，不用再补请求） */
  private txIdentities: Set<string> | null = null;

  /** 绑定沙箱目录，并把收藏事件接进来（EntryAbility.onCreate 里调一次） */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    PlatformPushSettings.getInstance().init(context);
    setFavoriteEventHandler((event: FavoriteEvent) => {
      this.enqueueFavoriteChange(event);
    });
    this.inited = true;
  }

  /** 清空「已推送」账本（设置页的「停止并清除同步记录」），开关与勾选保持不动 */
  clearLedger(): void {
    PlatformPushSettings.getInstance().clearLedger();
  }

  // ------------------------------------------------------------ 自动推送（收藏事件）



  /**
   * 收藏事件入队（不阻塞收藏动作）
   *
   * 关着总开关时连入队都不做：用户没开这个功能，就不该因为我们多挂一条 Promise 链。
   */
  private enqueueFavoriteChange(event: FavoriteEvent): void {
    const settings: PlatformPushSettings = PlatformPushSettings.getInstance();
    if (!settings.isEnabled()) {
      return;
    }
    if (event.source !== 'wy' && event.source !== 'tx') {
      return;   // 其它平台的歌没法写到这两个账号里
    }
    this.chain = this.chain.then(() => this.applyFavoriteChange(event)).then(() => {
    }, (e: Object) => {
      hilog.warn(DOMAIN, TAG, 'auto favorite push failed: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
    });
  }

  /**
   * 收藏 / 取消收藏的自动推送
   *
   * 口径（用户定的）：**每收藏一首，就往两个勾选平台各推一遍**，不看这首歌原本来自哪个平台。
   *   - 同源（本机这条就是该平台的歌）：直接用它自己的数字 id，零搜索；
   *   - 跨源（网易的歌要写进 QQ，或反过来）：先按「歌名 + 作者」在目标平台搜索，
   *     只有**严格一致**的那一首才写；找不到就跳过（写错歌比不写更糟）。
   * 取消收藏同理：先定位目标平台的同一首，确认它在远端收藏里，再取消。
   */
  private async applyFavoriteChange(event: FavoriteEvent): Promise<void> {
    const settings: PlatformPushSettings = PlatformPushSettings.getInstance();
    if (!settings.isEnabled()) {
      return;   // 排队期间用户关了开关
    }
    const identity: string = songIdentityOf(event.name, event.singer);
    if (settings.isSelected('wy')) {
      await this.applyOne('wy', event, identity);
    }
    if (settings.isSelected('tx')) {
      await this.applyOne('tx', event, identity);
    }
  }

  /** 对单个平台执行一次收藏 / 取消收藏（含跨平台搜索匹配、远端预检、账本与冷却判定） */
  private async applyOne(platform: string, event: FavoriteEvent, identity: string): Promise<void> {
    const settings: PlatformPushSettings = PlatformPushSettings.getInstance();
    if (!settings.isEnabled() || !settings.isSelected(platform)) {
      return;
    }
    // 目标平台的数字 id：同源直接取，跨源先搜索匹配
    let numId: number = 0;
    let songType: number = 0;
    let songMid: string = '';
    if (event.source === platform) {
      const info: PushSongInfo | null = parsePushSong(event.musicInfoJson);
      if (info === null) {
        return;
      }
      numId = platform === 'wy'
        ? numericIdOf(info.songId.length > 0 ? info.songId : info.songmid)
        : numericIdOf(info.songId);
      songType = info.songType;
      songMid = info.songmid;
    } else {
      const match: PlatformMatch = await matchTrackOnPlatform(platform, event.name, event.singer);
      numId = match.songId;
      songType = match.songType;
      songMid = match.songmid;   // QQ 写「我喜欢」要 songType，解析它需要 mid
      if (numId <= 0) {
        hilog.info(DOMAIN, TAG, 'auto %{public}s skip: no exact match in platform', platform);
      settings.setLastError(platform, '曲库里没找到「歌名 + 主歌手」一致的版本，已跳过');
        return;   // 平台上没有同一首：跳过，不记账（以后也不会冤枉它）
      }
    }
    if (numId <= 0) {
      return;
    }
    const key: string = `${numId}`;
    // 账本优先：已经成功过的歌不再发任何请求（收藏事件可能因为 WebDAV 恢复等重复出现）
    if (event.add && settings.wasPushed(platform, key) && !settings.wasFailed(platform, key)) {
      return;
    }

    const ids: Set<number> | null = platform === 'wy'
      ? await this.ensureWyRemote() : await this.ensureTxRemote();
    if (ids === null) {
      hilog.warn(DOMAIN, TAG, 'auto %{public}s skipped: remote likelist unreadable', platform);
      if (event.add) {
        settings.markFailed(platform, key);
      }
      return;
    }
    if (event.add) {
      if (ids.has(numId)) {
        settings.markPushed(platform, key);
        hilog.info(DOMAIN, TAG, 'auto %{public}s already liked: id tail %{public}s',
          platform, idTail(key));
        return;
      }
      // 跨音源去重：远端已有「歌名+作者」相同的另一版（例如 QQ 上是另一版），也跳过
      const identities: Set<string> | null = platform === 'wy'
        ? await this.ensureWyIdentities() : this.txIdentities;
      if (identity.length > 0 && identities !== null && identities.has(identity)) {
        settings.markPushed(platform, key);
        hilog.info(DOMAIN, TAG, 'auto %{public}s skip by identity: id tail %{public}s',
          platform, idTail(key));
        return;
      }
    } else {
      if (!ids.has(numId)) {
        settings.unmarkPushed(platform, key);   // 远端本来就没有：零写请求
        return;
      }
    }
    // QQ 的写入要求 songType；跨源匹配时用搜索结果里的类型，同源时可能还要解析
    // songType：-1 = 不知道（去解析）；0 = 普通歌曲，是**合法值**，不能当未知而跳过
    if (platform === 'tx' && event.add && songType < 0 && songMid.length > 0) {
      songType = await txResolveSongType(songMid);
    }
    if (platform === 'tx' && event.add && songType < 0) {
      hilog.warn(DOMAIN, TAG, 'auto tx like skipped: songType unresolved, id tail %{public}s',
        idTail(key));
      settings.setLastError('tx', '解析不出 songType（QQ 歌曲类型），已跳过');
      settings.markFailed('tx', key);
      return;
    }
    let ok: boolean = false;
    let code: number = 0;
    let message: string = '';
    if (platform === 'wy') {
      const written: WyWriteResult = await wyLike(key, event.add);
      ok = written.ok;
      code = written.code;
      message = written.message;
    } else {
      const written = await txFavorite(key, songType, event.add);
      ok = written.ok;
      code = written.code;
      message = written.message;
    }
    if (ok) {
      settings.setLastError(platform, '');   // 成功了就把上一次的失败提示清掉
      this.applyRemoteDelta(platform, numId, event.add);
      if (event.add) {
        settings.markPushed(platform, key);
      } else {
        settings.unmarkPushed(platform, key);
      }
      hilog.info(DOMAIN, TAG, 'auto %{public}s %{public}s ok: id tail %{public}s',
        platform, event.add ? 'like' : 'unlike', idTail(key));
      return;
    }
    hilog.warn(DOMAIN, TAG, 'auto %{public}s %{public}s failed: id tail %{public}s code=%{public}d',
      platform, event.add ? 'like' : 'unlike', idTail(key), code);
    if (this.isLoginExpired(platform, code, message)) {
      this.handleLoginExpired(platform, message);
      return;
    }
    settings.setLastError(platform, message.length > 0 ? message : `写入失败（code=${code}）`);
    if (event.add) {
      settings.markFailed(platform, key);
    }

  }
  // ------------------------------------------------------------ 远端集合与缓存

  /** 网易远端 id 集合 -> 歌名+作者身份集合（批量取详情；取不到给 null，只按 id 判重） */
  private async wyIdentitiesOf(ids: Set<number>): Promise<Set<string> | null> {
    const out: Set<string> = new Set<string>();
    if (ids.size === 0) {
      return out;
    }
    const list: string[] = [];
    for (const id of ids) {
      list.push(`${id}`);
    }
    try {
      const songs = await wySongsByIds(list);
      for (const song of songs) {
        const identity: string = songIdentityOf(song.name, song.singer);
        if (identity.length > 0) {
          out.add(identity);
        }
      }
      hilog.info(DOMAIN, TAG, 'wy liked identities: %{public}d', out.size);
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wy liked identities failed: %{public}s',
        e instanceof Error ? e.message : JSON.stringify(e));
      return null;
    }
  }

  /** QQ 远端曲目 -> 歌名+作者身份集合（列表自带名字，不用再补请求） */
  private txIdentitiesOf(songs: TxLikedSong[]): Set<string> {
    const out: Set<string> = new Set<string>();
    for (const song of songs) {
      const identity: string = songIdentityOf(song.name, song.singer);
      if (identity.length > 0) {
        out.add(identity);
      }
    }
    return out;
  }

  /** 自动推送用：拿网易远端集合（有缓存且未过期就直接用） */
  private async ensureWyRemote(): Promise<Set<number> | null> {
    if (this.wyRemote !== null && Date.now() - this.wyRemoteAt < REMOTE_CACHE_TTL_MS) {
      return this.wyRemote;
    }
    if (!this.canWriteWy()) {
      return null;
    }
    const liked = await wyLikedIds();
    if (!liked.ok) {
      // 读也失败：如果是登录失效（301），同样要自动登出并提示重新登录
      if (this.isLoginExpired('wy', 0, liked.message)) {
        this.handleLoginExpired('wy', liked.message);
      }
      return null;
    }
    this.wyRemote = liked.ids;
    this.wyRemoteAt = Date.now();
    this.wyIdentities = null;   // 远端集合变了：身份集合下次按需重建
    return liked.ids;
  }

  /** 自动推送用：拿 QQ 远端集合 */
  private async ensureTxRemote(): Promise<Set<number> | null> {
    if (this.txRemote !== null && Date.now() - this.txRemoteAt < REMOTE_CACHE_TTL_MS) {
      return this.txRemote;
    }
    if (!this.canWriteTx()) {
      return null;
    }
    const liked = await fetchTxLikedIds();
    if (!liked.ok) {
      if (this.isLoginExpired('tx', 0, liked.message)) {
        this.handleLoginExpired('tx', liked.message);
      }
      return null;
    }
    this.txRemote = liked.ids;
    this.txRemoteAt = Date.now();
    this.txIdentities = this.txIdentitiesOf(liked.songs);   // QQ 列表自带名字，直接建身份集合
    return liked.ids;
  }

  /**
   * 自动推送用：拿网易远端「已收藏歌曲身份集合」（按需构建：要把 500+ 个 id 的详情拉回来）
   *
   * 只在「候选 id 不在远端」时才需要它做跨音源去重，所以不放进 ensureWyRemote 里
   * —— 大多数收藏事件都命中 id、根本用不到这一层，不该为此每次都多打几个请求。
   */
  private async ensureWyIdentities(): Promise<Set<string> | null> {
    if (this.wyIdentities !== null) {
      return this.wyIdentities;
    }
    if (this.wyRemote === null) {
      return null;
    }
    const identities: Set<string> | null = await this.wyIdentitiesOf(this.wyRemote);
    if (identities !== null) {
      this.wyIdentities = identities;
    }
    return identities;
  }

  /** 写成功后同步更新缓存里的集合（加/删一个 id），避免下一次事件读到过期数据 */
  private applyRemoteDelta(platform: string, id: number, add: boolean): void {
    const ids: Set<number> | null = platform === 'wy' ? this.wyRemote : this.txRemote;
    if (ids === null) {
      return;
    }
    if (add) {
      ids.add(id);
      return;
    }
    ids.delete(id);
  }

  // ------------------------------------------------------------ 工具

  /** 串行执行：所有写平台的动作都排在同一条 Promise 链上 */
  private runExclusive<T>(task: () => Promise<T>): Promise<T> {
    const next: Promise<T> = this.chain.then(() => task());
    this.chain = next.then(() => {
    }, () => {
    });
    return next;
  }

  /**
   * 这个失败是不是「登录已失效」
   *
   * 网易：code 301（登录失效）；
   * QQ：code 1000 / 104400 / 104401（参考实现同样把这几个当登录失效），
   * 或者响应文案里直接写了「登录失效 / 重新登录」。
   * 读接口不校验登录态，所以典型表现是「能读不能写」，必须靠写返回码来发现。
   */
  private isLoginExpired(platform: string, code: number, message: string): boolean {
    if (platform === 'wy' && code === 301) {
      return true;
    }
    if (platform === 'tx' && (code === 1000 || code === 104400 || code === 104401)) {
      return true;
    }
    if (message.length === 0) {
      return false;
    }
    return message.indexOf('登录已失效') >= 0 || message.indexOf('重新登录') >= 0;
  }

  /**
   * 登录失效的统一处理：**自动登出该平台** + 记原因 + 发全局信号让界面弹窗
   *
   * 为什么自动登出：留着过期 Cookie 只会让用户以为「已登录」，然后每次同步都失败。
   * 登出后登录页会显示未登录，用户重扫一次就好；重新登录成功后账本里的失败记录
   * 会在下次收藏时自然重试（成功账本不受影响）。
   */
  private handleLoginExpired(platform: string, message: string): void {
    const settings: PlatformPushSettings = PlatformPushSettings.getInstance();
    const name: string = platform === 'wy' ? '网易云音乐' : 'QQ 音乐';
    const text: string = message.length > 0 ? message : `${name}登录已失效，请重新登录`;
    hilog.warn(DOMAIN, TAG, '%{public}s login expired, logging out: %{public}s', platform, text);
    try {
      musicAccount().logout(platform);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'logout %{public}s failed: %{public}s', platform,
        e instanceof Error ? e.message : JSON.stringify(e));
    }
    settings.setLastError(platform, `${name}登录已失效，已自动退出登录，请在「设置 - 登录音乐」重新登录`);
    try {
      AppStorage.setOrCreate(K_PLATFORM_LOGIN_EXPIRED, `${platform}:${Date.now()}`);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish login-expired signal failed');
    }
  }
  /** 网易能不能写（未登录 / Cookie 不全 = false）；实现抛错也按不可写处理 */
  private canWriteWy(): boolean {
    try {
      return wyCanWrite();
    } catch (e) {
      return false;
    }
  }

  /** QQ 能不能写；同上 */
  private canWriteTx(): boolean {
    try {
      return txCanWrite();
    } catch (e) {
      return false;
    }
  }
}

/**
 * 从 musicInfoJson 取推送要素
 *
 * 用 Record + asString/asNumber 而不是强类型解析：洛雪老结构（core/music/MusicSearch.ets 的
 * LxMusicInfo）里没有 songType 这种平台写入才用的字段，老数据可能缺字段类型也不严格，
 * 统一按「取不到就给默认」处理最稳。
 *
 * 返回 null 表示这条不该计入「解析失败」以外的任何东西 —— 调用方计 skipped。
 */
function parsePushSong(json: string): PushSongInfo | null {
  if (json === undefined || json === null || json.length === 0) {
    return null;
  }
  try {
    const raw: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    if (raw === null || raw === undefined) {
      return null;
    }
    const source: string = asString(raw['source']);
    const songmid: string = asString(raw['songmid']);
    const songId: string = asString(raw['songId']);
    // -1 = 没带这个字段（老数据）；0 是合法值，不能当默认值用
    const songType: number = asNumber(raw['songType'], -1);
    // 连 id 都取不到：这条推不了（本地歌 / 云端歌的「壳」也在这一类里）
    if (source.length === 0 || (songmid.length === 0 && songId.length === 0)) {
      return null;
    }
    return { source: source, songmid: songmid, songId: songId, songType: songType };
  } catch (e) {
    return null;
  }
}

/**
 * 字符串 -> 正整数 id；不是纯数字就是 0
 *
 * **必须校验纯数字**：QQ 的 songmid 是 `0039MnYb0qxYhV` 这种 mid，`parseInt` 会返回 39 ——
 * 直接把错误 id 推给平台。所以这里逐字符检查，顺便挡住超长数字（超过 15 位已经超出
 * Number 的安全整数范围，推出去也是错的）。
 */
function numericIdOf(raw: string): number {
  if (raw.length === 0 || raw.length > 15) {
    return 0;
  }
  for (let i = 0; i < raw.length; i++) {
    const code: number = raw.charCodeAt(i);
    if (code < 48 || code > 57) {
      return 0;
    }
  }
  const value: number = parseInt(raw, 10);
  if (isNaN(value) || value <= 0) {
    return 0;
  }
  return value;
}

/** 错误原因压成一行并截断（错误体可能很长，也可能带换行） */
function briefError(message: string): string {
  const oneLine: string = message.replace(/[\r\n\t]+/g, ' ').trim();
  if (oneLine.length <= ERROR_BRIEF_MAX) {
    return oneLine;
  }
  return `${oneLine.substring(0, ERROR_BRIEF_MAX)}…`;
}

/** id 后四位（日志用：既能对上具体哪首，又不至于把完整 id 写进日志） */
function idTail(key: string): string {
  if (key.length <= 4) {
    return key;
  }
  return key.substring(key.length - 4);
}
