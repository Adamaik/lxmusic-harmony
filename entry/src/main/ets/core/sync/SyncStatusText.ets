import { SYNC_CODE_AUTH_FAILED, SYNC_CODE_CONNECTING, SYNC_CODE_CONNECT_SERVICE_FAILED,
  SYNC_CODE_GET_SERVICE_ID_FAILED, SYNC_CODE_HIGH_SERVICE_VERSION, SYNC_CODE_LOW_SERVICE_VERSION,
  SYNC_CODE_MISSING_AUTH_CODE, SYNC_MSG_BLOCKED_IP } from './SyncTypes';

/**
 * 同步状态的文案层
 *
 * 协议里抛出来的都是英文常量（服务端的原话），这里统一翻译成人话，
 * 顺便区分「过程性消息」和「需要用户知道的消息」——前者不该弹提示条打扰用户。
 */

/** 连接过程中的状态：设置页里已经实时显示，不需要再弹提示条 */
export function isSyncProgressMessage(message: string): boolean {
  // 「Try reconnect... (n)」也归到这里：现在会自动退避重连，每次尝试都弹一条
  // 「连接已断开」只会让人觉得同步一直在断（其实几秒后就接上了）。
  return message === SYNC_CODE_CONNECTING || message === 'Wait syncing...'
    || message.startsWith('Try reconnect');
}

/** 需要弹提示条告诉用户的消息（失败、断开、被拉黑这类） */
export function shouldNotifySyncMessage(message: string): boolean {
  return message.length > 0 && !isSyncProgressMessage(message);
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
    return '无法连接服务（地址或端口不对）';
  }
  if (message === SYNC_CODE_GET_SERVICE_ID_FAILED) {
    return '服务端未返回 ID，可能不是洛雪同步服务';
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
    return message;
  }
  return connected ? '已连接，同步中' : '未连接';
}
