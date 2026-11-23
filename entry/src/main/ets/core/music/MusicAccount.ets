import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { asNumber, asRecord, asString, httpGetJson, httpPostJson } from './PlatformHttp';

const DOMAIN: number = 0x0001;
const TAG: string = 'MusicAccount';
const FILE_NAME: string = 'music_login.json';
/** 落盘结构变了就 +1；读到更新的版本按未登录处理（宁可用户重新登录，也不猜旧字段） */
const ACCOUNT_VERSION: number = 1;

/**
 * 音乐平台账号登录态（设置 - 登录音乐）
 *
 * **为什么要有这个文件**：网易的母带 / 沉浸声 / 杜比全景声（接口里的 `jymaster` /
 * `sky` / `dolby`）是**账号权益档**，匿名请求里根本不会上报（2026-10-21 实测：热歌 /
 * 新歌 / 黑胶VIP 三个榜各 100 首，`maxBrLevel` 最高只到 `hires`，三档权益档 0 条）。
 * 之前这个工程请求网易一律只带 `Cookie: os=pc`，没有登录态，所以「开了拓展音质也
 * 只有 FLAC」—— 数据源里就没有更高的档，协商自然不会选它。
 *
 * 存法：一份 JSON 落在应用沙箱（filesDir/music_login.json），同时把状态写进
 * AppStorage —— 设置页 / 登录页用 @StorageLink 订阅，网易请求侧直接读本单例
 * （`musicCookieHeader('wy')`）。与 PlaySettings 等设置同一套写法。
 *
 * 只存「网页登录抓回来的 Cookie 串」与展示用的昵称 / 会员标签，**不存账号密码**。
 * Cookie 等于登录态，文档里已注明属于敏感数据（见 docs/UI_REPLICA.md 的登录一节）。
 *
 * 目前只接网易（`wy`）；QQ / 酷狗后续按同一形状加平台键即可。
 */

/** 是否已登录（AppStorage key，界面订阅它） */
export const K_MUSIC_LOGGED_WY: string = 'music_login_logged_wy';
/** 已登录账号的昵称（未登录 = 空串） */
export const K_MUSIC_NICK_WY: string = 'music_login_nick_wy';
/** 会员标签：黑胶VIP / 非会员 / 未知（决定母带等权益档能不能用） */
export const K_MUSIC_VIP_WY: string = 'music_login_vip_wy';

/** QQ 音乐登录态（同一套形状，界面同样订阅这三个 key） */
export const K_MUSIC_LOGGED_TX: string = 'music_login_logged_tx';
export const K_MUSIC_NICK_TX: string = 'music_login_nick_tx';
export const K_MUSIC_VIP_TX: string = 'music_login_vip_tx';

/** 登录成功的账号信息（昵称 + 会员档，界面上给用户一个「登录对了」的确认） */
export interface MusicProfile {
  nickname: string;
  vip: string;
}

/** 落盘的一条平台登录记录 */
interface LoginEntry {
  cookie?: string;
  nickname?: string;
  vip?: string;
}

interface LoginFile {
  version?: number;
  wy?: LoginEntry;
  /** QQ 音乐（y.qq.com）的登录态 */
  tx?: LoginEntry;
}

const WY_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/**
 * 从网页抓回来的整串 Cookie 里挑出「登录态」那几项
 *
 * 网易的会话票据是 `MUSIC_U`（`MUSIC_A` 是游客票，不算登录）。抓回来的串里还混着
 * 埋点、NMTID 之类跟接口无关的项，全带上没必要，也更容易撞长度限制；这里只留
 * 会话需要的几项，`__csrf` 是写操作要用的，一起留着以后接收藏 / 歌单同步。
 */
function pickWyCookie(raw: string): string {
  const wanted: string[] = ['MUSIC_U', 'MUSIC_A', '__csrf', 'NMTID'];
  const parts: string[] = [];
  for (const pair of raw.split(';')) {
    const text: string = pair.trim();
    const eq: number = text.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const name: string = text.substring(0, eq).trim();
    if (wanted.includes(name)) {
      parts.push(text);
    }
  }
  return parts.join('; ');
}

/** 这一串 Cookie 里有没有真正的登录票据（`MUSIC_U`） */
function hasWySession(cookie: string): boolean {
  return /(^|;\s*)MUSIC_U=[^;]/.test(cookie);
}

// ------------------------------------------------------------------ QQ 音乐

/**
 * 桌面 Chrome UA（导出给别处复用：歌单分享短链的跟随也要它）
 *
 * 为什么这里要导出一份而不是各处再写一遍：QQ 音乐的分享短链按 UA 分流，
 * 移动 UA 有机会被跳到「下载客户端」页，桌面 UA 才 302 到歌单页。歌单导入
 * （core/music/PlaylistLink）跟短链时用的就是这一个值，以后改版本号只改这里。
 */
export const TX_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/**
 * QQ 音乐网页登录态要保留的 Cookie 项
 *
 * y.qq.com 的会话票据是 `qm_keyst`（新版）或 `qqmusic_key`（兼容旧名），账号身份在 `uin`
 * （微信登录时是 `wxuin`）；其余是写操作/风控会用到的辅助项，先留着，免得以后接「收藏 /
 * 歌单同步」再让用户重登一次。
 */
const TX_COOKIE_KEYS: string[] = [
  'uin', 'p_uin', 'qm_keyst', 'qqmusic_key', 'qqmusic_key_2',
  'p_skey', 'skey', 'wxuin', 'wxskey', 'euin',
  'psrf_musickey_createtime', 'psrf_access_token_expiresAt',
  'psrf_qqunionid', 'psrf_qqopenid',
];

/** 取某一项 Cookie 的值（没有返回空串） */
function cookieValue(cookie: string, name: string): string {
  for (const pair of cookie.split(';')) {
    const text: string = pair.trim();
    const eq: number = text.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    if (text.substring(0, eq).trim() === name) {
      return text.substring(eq + 1).trim();
    }
  }
  return '';
}

/** 从网页抓回来的整串 Cookie 里只留 QQ 音乐相关项（空值的项丢掉） */
function pickTxCookie(raw: string): string {
  const parts: string[] = [];
  for (const pair of raw.split(';')) {
    const text: string = pair.trim();
    const eq: number = text.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const name: string = text.substring(0, eq).trim();
    const value: string = text.substring(eq + 1).trim();
    if (TX_COOKIE_KEYS.includes(name) && value.length > 0) {
      parts.push(`${name}=${value}`);
    }
  }
  return parts.join('; ');
}

/** 这一串 Cookie 里有没有 QQ 音乐真正的登录票据 */
function hasTxSession(cookie: string): boolean {
  return cookieValue(cookie, 'qm_keyst').length > 0
    || cookieValue(cookie, 'qqmusic_key').length > 0;
}

/** QQ 号（数字）：`uin` 常带 `o` 前缀，微信登录时在 `wxuin` 上 */
export function txUinOf(cookie: string): string {
  let uin: string = cookieValue(cookie, 'uin');
  if (uin.length === 0) {
    uin = cookieValue(cookie, 'wxuin');
  }
  while (uin.startsWith('o')) {
    uin = uin.substring(1);
  }
  return /^\d+$/.test(uin) ? uin : '';
}

/** QQ 音乐账号信息（musicu）：comm 里必须带 authst，否则服务端回 code=1000 */
interface TxLoginComm {
  ct: number;
  cv: number;
  uin: string;
  authst: string;
}

interface TxLoginInfoReq {
  module: string;
  method: string;
  param: Record<string, Object>;
}

interface TxLoginInfoBody {
  comm: TxLoginComm;
  req_0: TxLoginInfoReq;
}

/** QQ 音乐票据：`qm_keyst` 优先，退旧名 `qqmusic_key` */
export function txMusicKeyOf(cookie: string): string {
  const key: string = cookieValue(cookie, 'qm_keyst');
  return key.length > 0 ? key : cookieValue(cookie, 'qqmusic_key');
}

/** QQ 音乐会员标签：vipType 拿不到就标「未知」，不把「没查到」说成「不是会员」 */
function txVipLabelOf(vipType: number, present: boolean): string {
  if (!present) {
    return '';
  }
  return vipType > 0 ? 'VIP' : '非会员';
}

/**
 * 会员标签
 *
 * `vipType`：11 = 黑胶 VIP（母带 / 全景声的权益来源），0 = 普通账号。
 * 接口没给就标「未知」——不把「没查到」说成「不是会员」。
 */
function vipLabelOf(vipType: number): string {
  if (vipType === 11) {
    return '黑胶VIP';
  }
  if (vipType > 0) {
    return 'VIP';
  }
  return '非会员';
}

class MusicAccountStore {
  private file: string = '';
  private inited: boolean = false;

  private wyCookie: string = '';
  private wyNick: string = '';
  private wyVip: string = '';

  private txCookie: string = '';
  private txNick: string = '';
  private txVip: string = '';

  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as LoginFile);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse music login: %{public}s', JSON.stringify(e));
      }
    }
    this.publish();
    /**
     * 启动时补拉一次账号信息：上一次登录可能只抓到了 Cookie、没拿到昵称
     * （2026-11-23 之前老接口对新登录态返回空 body，存档里 nickname 就是空串）。
     * 不补的话界面会一直停在「没取到昵称 · 会员档未知」。
     * 失败不弹提示、不改变登录态，下次启动再试。
     */
    if (hasTxSession(this.txCookie) && this.txNick.length === 0) {
      this.refreshTxProfile().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'refresh tx profile on init failed: %{public}s', e.message);
      });
    }
    if (this.wyCookie.length > 0 && this.wyNick.length === 0) {
      this.refreshWyProfile().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'refresh wy profile on init failed: %{public}s', e.message);
      });
    }
  }

  private apply(data: LoginFile): void {
    if (data.version !== undefined && data.version > ACCOUNT_VERSION) {
      return;
    }
    const wy: LoginEntry | undefined = data.wy;
    if (wy !== undefined && wy.cookie !== undefined) {
      this.wyCookie = wy.cookie;
      this.wyNick = wy.nickname !== undefined ? wy.nickname : '';
      this.wyVip = wy.vip !== undefined ? wy.vip : '';
    }
    const tx: LoginEntry | undefined = data.tx;
    if (tx !== undefined && tx.cookie !== undefined) {
      this.txCookie = tx.cookie;
      this.txNick = tx.nickname !== undefined ? tx.nickname : '';
      this.txVip = tx.vip !== undefined ? tx.vip : '';
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read music login: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const entry: LoginEntry = { cookie: this.wyCookie, nickname: this.wyNick, vip: this.wyVip };
    const txEntry: LoginEntry = { cookie: this.txCookie, nickname: this.txNick, vip: this.txVip };
    const data: LoginFile = { version: ACCOUNT_VERSION, wy: entry, tx: txEntry };
    try {
      const file = fs.openSync(this.file,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write music login: %{public}s', JSON.stringify(e));
    }
  }

  private publish(): void {
    try {
      AppStorage.setOrCreate(K_MUSIC_LOGGED_WY, this.wyCookie.length > 0);
      AppStorage.setOrCreate(K_MUSIC_NICK_WY, this.wyNick);
      AppStorage.setOrCreate(K_MUSIC_VIP_WY, this.wyVip);
      AppStorage.setOrCreate(K_MUSIC_LOGGED_TX, this.txCookie.length > 0);
      AppStorage.setOrCreate(K_MUSIC_NICK_TX, this.txNick);
      AppStorage.setOrCreate(K_MUSIC_VIP_TX, this.txVip);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to publish music login: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------------------------------------------------------- 读取

  isLoggedIn(source: string): boolean {
    return this.cookieOf(source).length > 0;
  }

  cookieOf(source: string): string {
    if (source === 'wy') {
      return this.wyCookie;
    }
    if (source === 'tx') {
      return this.txCookie;
    }
    return '';
  }

  nicknameOf(source: string): string {
    if (source === 'wy') {
      return this.wyNick;
    }
    if (source === 'tx') {
      return this.txNick;
    }
    return '';
  }

  vipOf(source: string): string {
    if (source === 'wy') {
      return this.wyVip;
    }
    if (source === 'tx') {
      return this.txVip;
    }
    return '';
  }

  /**
   * 给 HTTP 头用的 Cookie 串
   *
   * 网易：没登录时只有 `os=pc`（明文接口要求声明客户端形态，见 MusicList 的 WY_HEADERS）；
   * 登录后在后面接会话票据。**没登录不能塞空的 `MUSIC_U=`** —— 那会让接口认成
   * 「登录了一个空账号」，反而可能把公开数据也挡掉。
   *
   * QQ 音乐：没登录返回空串（它的公开接口不需要声明客户端形态，空串表示「不带头」），
   * 登录后原样带整串票据。
   */
  cookieHeader(source: string): string {
    const cookie: string = this.cookieOf(source);
    if (source === 'wy') {
      return cookie.length > 0 ? `os=pc; ${cookie}` : 'os=pc';
    }
    return cookie;
  }

  // ---------------------------------------------------------------- 写入

  /**
   * 登录：把网页抓回来的 Cookie 串存下来，并拉一次账号信息确认登录态
   *
   * 只有拿到 `MUSIC_U` 才算登录成功（网页没登完 / 只登录了游客票都会走到这里）。
   * 账号信息拉失败不影响「已登录」——接口偶尔抽风不该让用户重登一遍，昵称留空、
   * 会员标「未知」，音质协商照样会带 Cookie 去问。
   *
   * @throws 没抓到登录票据时抛错，界面据此提示「没抓到登录态」
   */
  async login(source: string, rawCookie: string): Promise<MusicProfile> {
    if (source === 'tx') {
      return await this.loginTx(rawCookie);
    }
    if (source !== 'wy') {
      throw new Error('这个平台还不支持账号登录');
    }
    const cookie: string = pickWyCookie(rawCookie);
    if (!hasWySession(cookie)) {
      throw new Error('没抓到网易的登录态（MUSIC_U）——请确认网页里已经登录成功再点完成');
    }
    this.wyCookie = cookie;
    this.wyNick = '';
    this.wyVip = '';
    const profile: MusicProfile = await this.refreshWyProfile();
    this.write();
    this.publish();
    return profile;
  }

  /** QQ 音乐登录：票据在 `qm_keyst` / `qqmusic_key`，账号身份在 `uin` */
  private async loginTx(rawCookie: string): Promise<MusicProfile> {
    const cookie: string = pickTxCookie(rawCookie);
    if (!hasTxSession(cookie)) {
      throw new Error('没抓到 QQ 音乐的登录态（qm_keyst）——请确认网页里已经登录成功再点完成');
    }
    if (txUinOf(cookie).length === 0) {
      throw new Error('没抓到你登录的 QQ 号（uin）——请确认是在 y.qq.com 上登录的');
    }
    this.txCookie = cookie;
    this.txNick = '';
    this.txVip = '';
    const profile: MusicProfile = await this.refreshTxProfile();
    this.write();
    this.publish();
    return profile;
  }

  /** 用当前 QQ 音乐 Cookie 拉一次账号信息（失败不改登录态，昵称留空） */
  async refreshTxProfile(): Promise<MusicProfile> {
    if (this.txCookie.length === 0) {
      return { nickname: '', vip: '' };
    }
    /**
     * 发起时的 Cookie：请求是异步的，这期间用户可能已经重新登录 / 退出登录。
     * 落地时 Cookie 变了就说明这份响应属于**上一个账号**，必须整份丢掉 ——
     * 否则启动时那次 fire-and-forget 的补拉会把旧昵称写回新账号（甚至写进存档）。
     */
    const cookieAtStart: string = this.txCookie;
    const uin: string = txUinOf(cookieAtStart);
    /**
     * 2026-11-23 真机实测：老接口 `fcg_get_profile_homepage` 对新登录态返回 200 + **空 body**，
     * 昵称拉不到，界面于是显示「账号信息没拉到」。改用 musicu 的 GetLoginUserInfo：
     * comm 里除了 uin 还必须带 authst（= `qm_keyst` / `qqmusic_key`），否则服务端回 code=1000。
     */
    const authst: string = txMusicKeyOf(cookieAtStart);
    const headers: Record<string, string> = {
      'User-Agent': TX_UA,
      'Referer': 'https://y.qq.com/',
      'Cookie': cookieAtStart,
      'Content-Type': 'application/json',
    };
    try {
      const reqBody: TxLoginInfoBody = {
        comm: { ct: 24, cv: 0, uin: uin, authst: authst },
        req_0: { module: 'music.UserInfo.userInfoServer', method: 'GetLoginUserInfo', param: {} },
      };
      const body: Record<string, Object> = await httpPostJson('https://u.y.qq.com/cgi-bin/musicu.fcg',
        reqBody, headers, 'QQ音乐账号');
      // Cookie 在这期间换了（重新登录 / 退出登录）：这份响应属于上一个账号，整份丢掉。
      // 不丢的话启动补拉的旧昵称会盖到新账号上（存档也会被写脏），界面显示错人。
      if (cookieAtStart !== this.txCookie) {
        hilog.info(DOMAIN, TAG, 'tx profile response dropped: cookie changed during request');
        return { nickname: this.txNick, vip: this.txVip };
      }
      const info: Record<string, Object> = asRecord(asRecord(asRecord(body['req_0'])['data'])['info']);
      const nickname: string = asString(info['nick']).length > 0
        ? asString(info['nick']) : asString(info['hostname']);
      const hasVip: boolean = info['vipType'] !== undefined || info['vipFlag'] !== undefined;
      const vipType: number = info['vipType'] !== undefined
        ? asNumber(info['vipType']) : asNumber(info['vipFlag']);
      if (nickname.length > 0) {
        this.txNick = nickname;
        this.txVip = txVipLabelOf(vipType, hasVip);
        this.write();
        this.publish();
        return { nickname: this.txNick, vip: this.txVip };
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to fetch tx profile: %{public}s', JSON.stringify(e));
    }
    return { nickname: this.txNick, vip: this.txVip };
  }

  /** 用当前 Cookie 拉一次账号信息（登录后调用；失败返回空信息，不改变登录态） */
  async refreshWyProfile(): Promise<MusicProfile> {
    if (this.wyCookie.length === 0) {
      return { nickname: '', vip: '' };
    }
    const headers: Record<string, string> = {
      'User-Agent': WY_UA,
      'Referer': 'https://music.163.com/',
      'Cookie': this.cookieHeader('wy'),
    };
    try {
      const body: Record<string, Object> = await httpGetJson(
        'https://music.163.com/api/nuser/account/get', headers, '网易账号');
      const profile: Record<string, Object> = asRecord(body['profile']);
      const nickname: string = asString(profile['nickname']);
      const vip: string = vipLabelOf(asNumber(profile['vipType']));
      if (nickname.length > 0) {
        this.wyNick = nickname;
        this.wyVip = vip;
        this.write();
        this.publish();
        return { nickname: nickname, vip: vip };
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to fetch wy profile: %{public}s', JSON.stringify(e));
    }
    return { nickname: this.wyNick, vip: this.wyVip };
  }

  /** 退出登录：清 Cookie 与账号信息（母带这类权益档会随之退回普通档） */
  logout(source: string): void {
    if (source === 'wy') {
      this.wyCookie = '';
      this.wyNick = '';
      this.wyVip = '';
      this.write();
      this.publish();
      return;
    }
    if (source === 'tx') {
      this.txCookie = '';
      this.txNick = '';
      this.txVip = '';
      this.write();
      this.publish();
    }
  }
}

const store: MusicAccountStore = new MusicAccountStore();

/** 全局单例（EntryAbility 里 init 一次；界面与请求侧都从这里取） */
export function musicAccount(): MusicAccountStore {
  return store;
}

/**
 * 请求侧用的快捷入口：`musicCookieHeader('wy')`
 *
 * 各平台请求模块（MusicList / MusicSearch / MusicArtist / PlaylistSearch）的头部里
 * 直接用它，别再自己拼 `os=pc` —— 登录后的会话票据要能一处生效、处处生效。
 */
export function musicCookieHeader(source: string): string {
  return store.cookieHeader(source);
}
