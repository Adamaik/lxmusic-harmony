import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxRequestOptions, LxResponse, lxRequest } from '../source/LxHttp';
import { musicCookieHeader } from './MusicAccount';
import { wyCsrfFromCookie, wyWeapiForm } from './WyWeapi';
import { asNumber, asRecord, asString, resolveJson } from './PlatformHttp';

const DOMAIN: number = 0x0001;
const TAG: string = 'WyWrite';

/**
 * 网易音乐「红心 / 我喜欢」写入
 *
 * 背景：读取链路（歌单、歌曲详情、私人推荐）都在 MusicList 里；收藏的**写**以前一直没有，
 * 这次平台同步（把本机收藏推到平台账号）需要它。用的是网易自己的写接口：
 *   `POST https://music.163.com/weapi/radio/like`
 * weapi 参数（NeteaseCloudMusicApi 的 `module/radio_like.js` 同款）：
 *   `{ alg: 'itembased', trackId: <数字 id>, like: true|false, time: '3' }`
 * 必须带登录 Cookie（`MUSIC_U`）与 `csrf_token`；weapi 的 AES/RSA 加密直接复用
 * `WyWeapi.wyWeapiForm`，HTTP 走 `core/source/LxHttp`（与 MusicList 的 httpFetch 同一层），
 * 这里不复制任何加密/请求实现。
 */

/** 红心写入接口（weapi 路径；明文路径 /api/radio/like 不认登录态） */
const WY_LIKE_URL: string = 'https://music.163.com/weapi/radio/like';

/**
 * 账号信息接口（读）：拿当前登录账号的 userId
 *
 * 「我喜欢」列表接口要 uid 参数，而 Cookie 里没有 uid（MUSIC_U 是不透明票据），
 * 所以先用这个读接口问一次。它同时也是「登录态是否还有效」的探针：code=301 即掉登录。
 */
const WY_ACCOUNT_URL: string = 'https://music.163.com/api/nuser/account/get';

/**
 * 「我喜欢（红心）」列表接口（weapi）
 *
 * 与 NeteaseCloudMusicApi 的 `module/likelist.js` 同款：`POST /weapi/song/like/get`，
 * 业务参数只有 `uid`，返回 `{ code: 200, ids: [<trackId>...] }`。**一次请求拿全量**，
 * 用它做「推之前先查远端有没有」的预检，比逐首查轻得多。
 *
 * 只读、不改账号数据；必须带登录 Cookie（MUSIC_U）与 csrf_token。
 */
const WY_LIKELIST_URL: string = 'https://music.163.com/weapi/song/like/get';

/** 读接口超时（15s，比写宽松：拉全量红心可能几千条） */
const WY_READ_TIMEOUT_MS: number = 15000;

/**
 * 写操作超时（10s）
 *
 * 写接口不像读接口那样可以慢慢等：用户点了「立即同步」，卡住时应当明确失败并让编排层
 * 继续下一首，而不是吊着（原通用 15s 偏长）。LxHttp 会把它同时当 connect/read 超时。
 */
const WY_WRITE_TIMEOUT_MS: number = 10000;

/**
 * 网易请求的 UA
 *
 * 与 MusicList.ets:2403-2411 `wyHeaders()` 里那条完全一致（那边内联在函数里、没有导出常量，
 * 所以只能照抄同一份字符串）。UA 与 Cookie 一起决定网易把请求认成「PC 客户端」还是爬虫。
 */
const WY_UA: string = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/60.0.3112.90 Safari/537.36';

/**
 * Cookie 里有没有真正的登录票据（MUSIC_U）
 *
 * 正则与 MusicAccount.ets:92 `hasWySession` 同款；那个函数是模块私有、没有导出，
 * 这里为「登录态判定」单独放一份，语义保持一致。
 */
const MUSIC_U_RE: RegExp = /(^|;\s*)MUSIC_U=[^;]/;

/** 数字歌曲 id：/weapi/radio/like 的 trackId 只吃纯数字 */
const DIGIT_ONLY_RE: RegExp = /^\d+$/;

/** 写入结果：ok 只代表平台明确接受了这次写；code 为平台原始 code（本地失败给 0/-1，见各分支） */
export interface WyWriteResult {
  ok: boolean;
  code: number;
  message: string;
}

/**
 * 「我喜欢」列表的读取结果
 *
 * ok=false 时 ids 为空集合，message 说明原因（未登录 / 网络 / 平台拒绝）。调用方
 * **不能**把「读失败」当成「远端一首都没收藏」—— 那会导致把已经红心的歌又写一遍，
 * 所以预检失败时应当整平台跳过本次推送（见 PlatformPush）。
 */
export interface WyLikedResult {
  ok: boolean;
  ids: Set<number>;
  message: string;
}

/** 一次 weapi 请求的结果：HTTP 状态 + 解析后的 JSON（body 不是 JSON 对象时为 null） */
interface WyHttpReply {
  status: number;
  body: Record<string, Object> | null;
}

/**
 * 红心接口的 weapi 业务参数
 *
 * `like` 在这里必须是布尔：接口按 JSON 布尔解析（NeteaseCloudMusicApi 的 radio_like 也是布尔），
 * 传字符串 `"true"` 有被网易判 400 的风险。用接口而不是 `Record<string, Object>` 组参，
 * 是为了让布尔在 ArkTS 类型层面就成立（Record<string, Object> 里塞布尔是否能过，各版本口径不同）。
 */
interface WyLikePayload {
  alg: string;
  trackId: string;
  like: boolean;
  time: string;
  csrf_token: string;
}

function failed(code: number, message: string): WyWriteResult {
  return { ok: false, code: code, message: message };
}

function succeeded(code: number, message: string): WyWriteResult {
  return { ok: true, code: code, message: message };
}

/** 把 catch 到的异常变成可读文本（Error 直接 JSON.stringify 会得到 `{}`，与 WyWeapi 同处理） */
function errorText(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  return JSON.stringify(e);
}

/**
 * 能写时返回当前用于请求的 Cookie 头；不能写返回空串
 *
 * 用 `musicCookieHeader('wy')`（MusicAccount.ets:551-553）而不是 `cookieOf('wy')`：
 * 前者是请求侧约定的快捷入口，未登录时给 `os=pc`、登录后自动接上 `MUSIC_U / __csrf`，
 * 与 MusicList 的 wyHeaders 完全同源，避免两处拼法跑偏。
 *
 * 写操作要求 **MUSIC_U 与 __csrf 同时存在**：只有 MUSIC_A（游客票）或没有 csrf 时，
 * 发出去也会被网易判成未登录，不如本地就拦掉、给用户明确提示。
 */
function wyWriteCookie(): string {
  const cookie: string = musicCookieHeader('wy');
  if (!MUSIC_U_RE.test(cookie)) {
    return '';
  }
  if (wyCsrfFromCookie(cookie).length === 0) {
    return '';
  }
  return cookie;
}

/** 登录态是否具备写条件（MUSIC_U 且 __csrf 非空） */
export function wyCanWrite(): boolean {
  return wyWriteCookie().length > 0;
}

/**
 * 发一次 weapi POST
 *
 * 只负责「把表单发出去、把响应变成 JSON」：
 * - 表单（`params` + `encSecKey`）交给 LxHttp 编码：它在识别到 POST + form 时会自动补
 *   `Content-Type: application/x-www-form-urlencoded`（LxHttp.ets:168-171、187-189），
 *   所以这里**不能**自己再写 Content-Type —— 写了会让 LxHttp 认为 body 已由调用方负责，
 *   反而不编码表单（见 LxHttp.ets:168 的分支条件）。
 * - HTTP 层错误不在这里抛：把状态码带回去，由 wyLike 统一映射成中文结果（网易写接口
 *   正常都回 HTTP 200、错误放在 body.code 里，但网关/代理也可能直接 4xx/5xx）。
 */
function wyPostWeapi(form: Record<string, string>, cookie: string): Promise<WyHttpReply> {
  return wyPostWeapiUrl(WY_LIKE_URL, form, cookie, WY_WRITE_TIMEOUT_MS);
}

/**
 * 按指定 URL / 超时发一次 weapi POST（写与读共用）
 *
 * `wyPostWeapi` 只是它绑定到红心接口的薄壳：读「我喜欢」用的是同一个域名、同一套
 * `params`+`encSecKey` 表单，只有路径与超时不同，不该为此再抄一份请求代码。
 */
function wyPostWeapiUrl(url: string, form: Record<string, string>, cookie: string,
  timeoutMs: number): Promise<WyHttpReply> {
  return new Promise<WyHttpReply>((resolve, reject) => {
    const headers: Record<string, string> = {
      'User-Agent': WY_UA,
      'Referer': 'https://music.163.com/',
      'Origin': 'https://music.163.com',
      'Cookie': cookie,
    };
    const options: LxRequestOptions = {
      method: 'post',
      headers: headers,
      form: form,
      timeout: timeoutMs,
    };
    lxRequest(url, options, (resp: LxResponse) => {
      const reply: WyHttpReply = {
        status: resp.statusCode,
        body: resolveJson(resp),
      };
      resolve(reply);
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/**
 * 平台回复里的「风控 / 频控」措辞判定
 *
 * 网易的风控回复并不总是带业务码：实测有一种是
 * `{code: null, message: "检测到您的网络环境存在风险，请稍后再试"}`。
 * 这里按措辞识别（宁可当成风控：停手只会慢一点，继续试则可能把账号打进更长的封禁）。
 */
function looksLikeRiskControl(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  const hints: string[] = ['风险', '频繁', '稍后再试', '稍候', '异常环境', '安全验证'];
  for (const hint of hints) {
    if (text.indexOf(hint) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 取平台响应里的 `msg`（只用于日志/提示，不含 Cookie、不含请求体）
 *
 * 之前只记了 `code`，结果 405 与「响应里没有 code」两种失败在日志上分不清，
 * 排查只能靠猜。补上 msg 之后，平台自己给的原因（例如「操作频繁」）就能直接看到。
 */
function wyMsgOf(body: Record<string, Object> | null): string {
  if (body === null) {
    return '';
  }
  const msg: string = asString(body['msg']);
  if (msg.length > 0) {
    return msg;
  }
  return asString(body['message']);
}

/**
 * 发一次 GET（读接口用）：只负责取回状态码 + JSON
 *
 * 与 `wyPostWeapi` 同一套头（UA / Referer / Cookie）。读接口用 GET 是因为
 * `/api/nuser/account/get` 这类账号接口在真实客户端里就是 GET，换成 POST 会 405。
 */
function wyGetJson(url: string, cookie: string): Promise<WyHttpReply> {
  return new Promise<WyHttpReply>((resolve, reject) => {
    const headers: Record<string, string> = {
      'User-Agent': WY_UA,
      'Referer': 'https://music.163.com/',
      'Cookie': cookie,
    };
    const options: LxRequestOptions = {
      method: 'get',
      headers: headers,
      timeout: WY_READ_TIMEOUT_MS,
    };
    lxRequest(url, options, (resp: LxResponse) => {
      const reply: WyHttpReply = {
        status: resp.statusCode,
        body: resolveJson(resp),
      };
      resolve(reply);
    }, (message: string) => {
      reject(new Error(`请求失败：${message}`));
    });
  });
}

/**
 * 取当前登录账号的 userId（「我喜欢」列表接口的必需参数）；拿不到给 0
 *
 * 只读接口：`/api/nuser/account/get` 在有登录 Cookie 时返回 `profile.userId`，
 * 未登录/掉登录时返回 `code: 301`（此时给 0，由调用方整平台跳过）。
 */
export async function wyUserId(): Promise<number> {
  const cookie: string = wyWriteCookie();
  if (cookie.length === 0) {
    return 0;
  }
  try {
    const reply: WyHttpReply = await wyGetJson(WY_ACCOUNT_URL, cookie);
    if (reply.body === null) {
      hilog.warn(DOMAIN, TAG, 'wy account: response is not json (http %{public}d)', reply.status);
      return 0;
    }
    const profile: Record<string, Object> = asRecord(reply.body['profile']);
    let uid: number = asNumber(profile['userId'], 0);
    if (uid <= 0) {
      // 少数版本把 id 放在 account.id
      uid = asNumber(asRecord(reply.body['account'])['id'], 0);
    }
    return uid > 0 ? uid : 0;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy account failed: %{public}s', errorText(e));
    return 0;
  }
}

/** 响应里 `ids` 数组 -> 数字集合（丢非法值） */
function wyIdSetOf(raw: Object | undefined): Set<number> {
  const out: Set<number> = new Set<number>();
  if (!Array.isArray(raw)) {
    return out;
  }
  for (const item of raw as Object[]) {
    const id: number = asNumber(item, 0);
    if (id > 0) {
      out.add(id);
    }
  }
  return out;
}

/**
 * 拉一次「我喜欢」的全量 trackId（推送前预检：远端已有的歌不再写）
 *
 * 语义要点：
 * - **ok=false 不能当成「远端为空」**：读失败时调用方必须整平台跳过，否则会把已经红心
 *   的歌再写一遍（既是无效请求，也更容易触发平台频控）；
 * - code=301 → 登录失效，message 直接告诉用户去重新登录。
 */
export async function wyLikedIds(): Promise<WyLikedResult> {
  const empty: Set<number> = new Set<number>();
  const cookie: string = wyWriteCookie();
  if (cookie.length === 0) {
    return { ok: false, ids: empty, message: '请先登录网易云音乐（需要完整登录态）' };
  }
  const uid: number = await wyUserId();
  if (uid <= 0) {
    return { ok: false, ids: empty, message: '取不到网易云账号 id（登录可能已失效）' };
  }
  const csrf: string = wyCsrfFromCookie(cookie);
  const payload: Record<string, string> = { 'uid': `${uid}`, 'csrf_token': csrf };
  let form: Record<string, string> = {};
  try {
    form = wyWeapiForm(payload);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy likelist encrypt failed: %{public}s', errorText(e));
    return { ok: false, ids: empty, message: `加密失败：${errorText(e)}` };
  }
  let reply: WyHttpReply = { status: 0, body: null };
  try {
    reply = await wyPostWeapiUrl(WY_LIKELIST_URL, form, cookie, WY_READ_TIMEOUT_MS);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy likelist request failed: %{public}s', errorText(e));
    return { ok: false, ids: empty, message: `网络异常：${errorText(e)}` };
  }
  if (reply.status < 200 || reply.status >= 300) {
    hilog.warn(DOMAIN, TAG, 'wy likelist http status: %{public}d', reply.status);
    return { ok: false, ids: empty, message: `网易接口返回 HTTP ${reply.status}` };
  }
  if (reply.body === null) {
    hilog.warn(DOMAIN, TAG, 'wy likelist: response is not json (http %{public}d)', reply.status);
    return { ok: false, ids: empty, message: '网易「我喜欢」接口返回格式异常' };
  }
  const code: number = asNumber(reply.body['code'], -1);
  if (code === 301) {
    hilog.warn(DOMAIN, TAG, 'wy likelist unauthorized: code=301');
    return { ok: false, ids: empty, message: '登录已失效，请重新登录网易云音乐' };
  }
  if (code !== 200) {
    hilog.warn(DOMAIN, TAG, 'wy likelist refused: code=%{public}d msg=%{public}s',
      code, wyMsgOf(reply.body));
    return { ok: false, ids: empty, message: `平台拒绝读取（code=${code}）` };
  }
  const ids: Set<number> = wyIdSetOf(reply.body['ids']);
  hilog.info(DOMAIN, TAG, 'wy likelist: %{public}d liked id(s)', ids.size);
  return { ok: true, ids: ids, message: '' };
}

/**
 * 把一首歌设为喜欢/取消喜欢；trackId 为数字歌曲 id 字符串
 *
 * 参数与错误映射：
 * - trackId 不是纯数字 → 本地失败（不请求）：id 形态不对时，平台侧也会给 code=400，
 *   但本地拦掉能少一次网络往返、错误也更清楚；
 * - 未登录 / 缺 csrf → 本地失败：「请先登录网易云音乐」；
 * - HTTP 非 2xx → 失败（写操作不做自动重试，避免重复写入）；
 * - body.code === 200 → ok；301 → 登录失效；其它 code → 「平台拒绝写入（code=N）」。
 *
 * 注意：本函数**不做**频控与批量，调用方（平台同步编排）负责每首之间的间隔；
 * 也不打印 Cookie / params。
 */
export async function wyLike(trackId: string, like: boolean): Promise<WyWriteResult> {
  const id: string = trackId.trim();
  if (!DIGIT_ONLY_RE.test(id)) {
    hilog.warn(DOMAIN, TAG, 'wy like rejected locally: non-numeric trackId');
    return failed(0, '歌曲 id 不合法，无法写入红心');
  }
  const cookie: string = wyWriteCookie();
  if (cookie.length === 0) {
    hilog.warn(DOMAIN, TAG, 'wy like rejected locally: no MUSIC_U/__csrf');
    return failed(0, '请先登录网易云音乐（需要完整登录态）后再同步红心');
  }
  const csrf: string = wyCsrfFromCookie(cookie);
  /**
   * weapi 业务参数。
   *
   * `wyWeapiForm` 的入参类型是 `Record<string, string>`（WyWeapi.ets:78），但它的实现只做
   * `JSON.stringify(data)`（WyWeapi.ets:79）——运行时值与声明类型无关。
   * 所以先按接口组参（保住 `like` 的布尔），再经 `Object` 中转做一次
   * `as Record<string, string>`（与工程里 `JSON.parse(...) as Record<...>` 同款写法，
   * 见 LxHttp.ets:100 / PlatformHttp.ets:68）。不复制、不改写任何加密实现。
   */
  const payload: WyLikePayload = {
    'alg': 'itembased',
    'trackId': id,
    'like': like,
    'time': '3',
    'csrf_token': csrf,
  };
  const raw: Object = payload;
  const data: Record<string, string> = raw as Record<string, string>;
  let form: Record<string, string> = {};
  try {
    form = wyWeapiForm(data);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy like encrypt failed: %{public}s', errorText(e));
    return failed(0, `红心写入失败（加密）：${errorText(e)}`);
  }
  let reply: WyHttpReply = { status: 0, body: null };
  try {
    reply = await wyPostWeapi(form, cookie);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'wy like request failed: %{public}s', errorText(e));
    return failed(0, `网络异常，红心写入未完成：${errorText(e)}`);
  }
  if (reply.status < 200 || reply.status >= 300) {
    hilog.warn(DOMAIN, TAG, 'wy like http status: %{public}d', reply.status);
    return failed(reply.status, `网易接口返回 HTTP ${reply.status}，红心未确认`);
  }
  const body: Record<string, Object> | null = reply.body;
  if (body === null) {
    hilog.warn(DOMAIN, TAG, 'wy like response is not a json object (http %{public}d)', reply.status);
    return failed(0, '网易红心接口返回格式异常（登录可能已失效）');
  }
  const code: number = asNumber(body['code'], -1);
  if (code === 200) {
    hilog.info(DOMAIN, TAG, 'wy like ok: like=%{public}s', like ? 'true' : 'false');
    return succeeded(code, like ? '已加入「我喜欢的音乐」' : '已取消喜欢');
  }
  if (code === 301) {
    hilog.warn(DOMAIN, TAG, 'wy like unauthorized: code=301');
    return failed(code, '登录已失效，请重新登录网易云音乐');
  }
  if (code < 0) {
    // 这里只打字段名与几个常见的「非 code 形态」提示字段：响应体可能带用户相关数据，
    // 不打全量；字段名足够区分「风控壳 / 跳转壳 / 加密壳」。
    hilog.warn(DOMAIN, TAG, 'wy like response has no code (http %{public}d, keys %{public}s)',
      reply.status, Object.keys(body).join(','));
    const noCodeMessage: string = wyMsgOf(body);
    hilog.warn(DOMAIN, TAG, 'wy like no-code message: %{public}s', noCodeMessage);
    // 实测的一种形态：`{code: null, message: "检测到您的网络环境存在风险，请稍后再试"}`
    // —— 没有可用业务码，但 message 明确是风控。这种必须按「平台在拦」处理（停手 + 冷却），
    // 否则会把它当成「格式异常」一首首重试，越试风控越重。
    if (looksLikeRiskControl(noCodeMessage)) {
      return failed(460, `网易风控：${noCodeMessage}`);
    }
    return failed(0, '网易红心接口返回格式异常（响应里没有 code）');
  }
  // 405 = 平台频控/风控限流；460 = 明确的风控拦截；250 = 要求先做一次验证。
  // 这三种都是「平台不让写」，重试没用，编排层看到同一个 code 连续出现就该整批停下。
  const msg: string = wyMsgOf(body);
  hilog.warn(DOMAIN, TAG, 'wy like refused: code=%{public}d msg=%{public}s', code, msg);
  if (looksLikeRiskControl(msg)) {
    return failed(460, `网易风控：${msg}`);
  }
  if (code === 405) {
    return failed(code, '网易限流（code=405），请稍后再试');
  }
  if (code === 460) {
    return failed(code, '网易风控拦截（code=460）');
  }
  if (code === 250) {
    return failed(code, '网易要求验证（code=250）');
  }
  const detail: string = msg.length > 0 ? `：${msg}` : '';
  return failed(code, `平台拒绝写入（code=${code}${detail}）`);
}
