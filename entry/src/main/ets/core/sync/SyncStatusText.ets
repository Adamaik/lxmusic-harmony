import { SYNC_CODE_AUTH_FAILED, SYNC_CODE_CONNECTING, SYNC_CODE_CONNECT_FAILED,
  SYNC_CODE_CONNECT_SERVICE_FAILED, SYNC_CODE_CONNECT_TIMEOUT,
  SYNC_CODE_GET_SERVICE_ID_FAILED, SYNC_CODE_HIGH_SERVICE_VERSION, SYNC_CODE_HTTP_ERROR,
  SYNC_CODE_LOW_SERVICE_VERSION,
  SYNC_CODE_MISSING_AUTH_CODE, SYNC_MSG_BLOCKED_IP } from './SyncTypes';

/**
 * 同步状态的文案层
 *
 * 协议里抛出来的都是英文常量（服务端的原话），这里统一翻译成人话，
 * 顺便区分「过程性消息」和「需要用户知道的消息」——前者不该弹提示条打扰用户。
 *
 * 另外：进到这里的 message 必须是**协议里的码**（或我们自己的码）。宿主侧那些系统原文
 * （WebSocket / HTTP 抛的 `Operation timeout` 之类）在 SyncClient 里就挡掉了，只进日志 ——
 * 否则界面上会冒出一句裸英文，看着像应用坏了（见 SYNC_CODE_CONNECT_FAILED）。
 */

/**
 * 需要弹提示条告诉用户的消息：**白名单**，只认这几条明确「要用户做点什么」的码
 *
 * 不用「除进度以外全弹」那种反选写法：同步的状态里混着服务端的原话和宿主侧的系统原文，
 * 只要有一条没见过的串漏进来，就会以一句裸英文弹到用户面前（`Operation timeout` /
 * `connect error` 都这么来过）。白名单下漏进来的串最多是安静地躺在日志里。
 *
 * 不弹的那一类（连接中 / 等待同步 / 自动重连 / 连接失败）都是**会自己恢复**的过程状态：
 * 连不上会按退避重连，几秒后就接上了，每次失败都弹一条只会让人觉得同步一直是坏的。
 * 这些状态在「设置 → 同步」页里本来就实时显示着（`describeStatus` 给的是中文）。
 */
const SYNC_NOTIFY_CODES: string[] = [
  SYNC_CODE_AUTH_FAILED,          // 认证失败
  SYNC_CODE_MISSING_AUTH_CODE,    // 缺认证码
  SYNC_MSG_BLOCKED_IP,            // IP 被封
  SYNC_CODE_CONNECT_SERVICE_FAILED, // 地址 / 端口不对
  SYNC_CODE_CONNECT_TIMEOUT,      // 握手超时（15s）
  SYNC_CODE_HTTP_ERROR,           // 对端 HTTP 返回异常（多半不是洛雪服务端）
  SYNC_CODE_GET_SERVICE_ID_FAILED,  // 对端不是洛雪同步服务
  SYNC_CODE_LOW_SERVICE_VERSION,    // 服务端要升级
  SYNC_CODE_HIGH_SERVICE_VERSION,   // 客户端要升级
  'failed',                       // 已连上之后掉线（后续会自动重连，只提醒这一次）
];

export function shouldNotifySyncMessage(message: string): boolean {
  return SYNC_NOTIFY_CODES.includes(message);
}

/**
 * 是否是「必须用户处理」的失败状态（界面据此把进度条变红、给重试 / 断开按钮）
 *
 * 连接中 / 等待同步 / 自动重连都不算失败：它们要么会自己往前走，要么有进度文案。
 * 这里只认真正停下来的那几种。与 toast 白名单分开维护：`Connect failed` 不弹 toast
 * （自动重连时会出现，避免刷屏），但界面必须把它标成失败 —— 那正是「连不上服务器」
 * 最常见的一种。
 */
const SYNC_FAILURE_CODES: string[] = [
  SYNC_CODE_AUTH_FAILED,
  SYNC_CODE_MISSING_AUTH_CODE,
  SYNC_MSG_BLOCKED_IP,
  SYNC_CODE_CONNECT_FAILED,
  SYNC_CODE_CONNECT_SERVICE_FAILED,
  SYNC_CODE_CONNECT_TIMEOUT,
  SYNC_CODE_HTTP_ERROR,
  SYNC_CODE_GET_SERVICE_ID_FAILED,
  SYNC_CODE_LOW_SERVICE_VERSION,
  SYNC_CODE_HIGH_SERVICE_VERSION,
];

export function isSyncFailureMessage(message: string): boolean {
  return SYNC_FAILURE_CODES.includes(message);
}

/** 把同步状态翻译成人话（服务端的 message 是英文常量） */
export function describeStatus(connected: boolean, message: string): string {
  if (message === SYNC_CODE_CONNECTING) {
    return '连接中…';
  }
  if (message === 'Wait syncing...') {
    return '已连接，正在同步…';
  }
  if (message === SYNC_CODE_AUTH_FAILED) {
    return '认证失败（缺少或错误的认证码）';
  }
  if (message === SYNC_CODE_MISSING_AUTH_CODE) {
    return '缺少认证码，请填写后连接';
  }
  if (message === SYNC_MSG_BLOCKED_IP) {
    return '当前 IP 已被服务端封禁';
  }
  if (message === SYNC_CODE_CONNECT_SERVICE_FAILED) {
    return '该地址不是洛雪同步服务端（/hello 响应不匹配），请核对地址和端口';
  }
  if (message === SYNC_CODE_HTTP_ERROR) {
    return '该地址不是洛雪同步服务端（HTTP 返回异常），请核对地址和端口';
  }
  if (message === SYNC_CODE_CONNECT_TIMEOUT) {
    return '连接超时：15 秒内服务器没有响应，请检查 IP、端口，以及手机是否和服务器在同一局域网，然后点「重试」';
  }
  if (message === SYNC_CODE_CONNECT_FAILED) {
    return '连不上服务器：请检查 IP 和端口是否正确、手机与服务器是否在同一网络，然后点「重试」';
  }
  if (message === SYNC_CODE_GET_SERVICE_ID_FAILED) {
    return '该地址不是洛雪同步服务端（没有返回服务端 ID），请核对地址和端口';
  }
  if (message === SYNC_CODE_LOW_SERVICE_VERSION) {
    return '服务端版本过低，请升级服务端';
  }
  if (message === SYNC_CODE_HIGH_SERVICE_VERSION) {
    return '服务端版本过高，请升级客户端';
  }
  if (message === 'failed') {
    return '同步连接已断开';
  }
  if (message.startsWith('Try reconnect')) {
    // 文案是 `Try reconnect... (3)`，取括号里的次数
    const at: number = message.indexOf('(');
    const attempt: number = at >= 0 ? Number.parseInt(message.substring(at + 1), 10) : NaN;
    return Number.isNaN(attempt)
      ? '连接已断开，正在自动重连…'
      : `连接已断开，正在自动重连（第 ${attempt} 次）…`;
  }
  if (message.length > 0) {
    // 兜底：走到这里说明是没见过的串。加个中文前缀，至少不会变成界面上的一句裸英文；
    // 万一真是新增的协议码，原文也还看得见（同步设置页的状态行就显示这行）。
    return `同步异常：${message}`;
  }
  return connected ? '已连接，同步中' : '未连接';
}
