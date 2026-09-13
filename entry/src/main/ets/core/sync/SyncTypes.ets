/**
 * 洛雪同步协议的数据类型
 *
 * 与 lx-music-sync-server / lx-music-mobile 的约定逐字对齐：
 *   - 线上消息：message2call 的 `{name, path, data}` 调用 / `{name, error, data}` 应答；
 *   - 歌曲：`LX.Music.MusicInfoOnline`（id/name/singer/source/interval/meta）；
 *   - 列表：`LX.Sync.List.ListData`（defaultList / loveList / userList）；
 *   - 不喜欢：一整段纯文本规则（每行「歌名@歌手」）。
 * 只有格式一致，才能和官方桌面端、移动端连同一个服务端互相同步。
 */

// ------------------------------------------------------------------ 连接

/** 服务端 /ah 认证成功后下发的身份信息（LX.Sync.KeyInfo） */
export interface SyncKeyInfo {
  clientId: string;
  key: string;
  serverName: string;
  /** 官方客户端有这两个字段，服务端会原样保存，我们照收照存 */
  iv?: string;
  deviceName?: string;
}

/** 服务器地址解析结果（对应洛雪 parseUrl） */
export interface SyncUrlInfo {
  href: string;
  httpProtocol: string;
  wsProtocol: string;
  hostPath: string;
}

/** 同步状态（对应 LX.Sync.Status 的 status/message 部分） */
export interface SyncStatus {
  status: boolean;
  message: string;
}

/** /ah 接口返回 */
export interface SyncHttpResult {
  code: number;
  text: string;
}

/** RSA 密钥对（base64 的 DER：公钥 X.509、私钥 PKCS#8） */
export interface RsaKeyPairB64 {
  publicKey: string;
  privateKey: string;
}

// ------------------------------------------------------------------ 歌曲

/** 音质大小（LX meta._qualitys 的值，注意没有 type 字段） */
export interface LxQualitySize {
  size: string | null;
  /** 酷狗的音质条目额外带 hash */
  hash?: string;
}

/** 同步用的歌曲 meta（LX.Music.MusicInfoMeta_online） */
export interface LxMusicMeta {
  /** 平台歌曲 ID；咪咕为 copyrightId */
  songId: string | number;
  albumName: string;
  picUrl?: string | null;
  qualitys?: Object[];
  _qualitys?: Record<string, LxQualitySize>;
  albumId?: string | number;
  /** kg */
  hash?: string;
  /** tx */
  strMediaMid?: string;
  id?: string | number;
  albumMid?: string;
  /** mg */
  copyrightId?: string;
  lrcUrl?: string;
  mrcUrl?: string;
  trcUrl?: string;
}

/** 同步用的在线歌曲（LX.Music.MusicInfoOnline） */
export interface LxMusicInfoNew {
  id: string;
  name: string;
  singer: string;
  source: string;
  interval: string | null;
  meta: LxMusicMeta;
}

// ------------------------------------------------------------------ 歌单

/** 歌单信息（LX.List.UserListInfo） */
export interface LxUserListInfo {
  id: string;
  name: string;
  source?: string;
  sourceListId?: string;
  locationUpdateTime: number | null;
}

/** 带歌曲的歌单（LX.List.UserListInfoFull） */
export interface LxUserListInfoFull {
  id: string;
  name: string;
  source?: string;
  sourceListId?: string;
  locationUpdateTime: number | null;
  list: LxMusicInfoNew[];
}

/** 同步的列表数据（LX.Sync.List.ListData） */
export interface LxListData {
  defaultList: LxMusicInfoNew[];
  loveList: LxMusicInfoNew[];
  userList: LxUserListInfoFull[];
}

/** 同步动作（服务端与客户端双向使用，data 按 action 各自解释） */
export interface LxSyncAction {
  action: string;
  data?: Object;
}

/** 歌曲更新动作的载荷（list_music_update） */
export interface LxMusicUpdateItem {
  id: string;
  musicInfo: LxMusicInfoNew;
}

/** list_create 的载荷 */
export interface LxListCreateData {
  position: number;
  listInfos: LxUserListInfo[];
}

/** list_music_add 的载荷 */
export interface LxListMusicAddData {
  id: string;
  musicInfos: LxMusicInfoNew[];
  addMusicLocationType: string;
}

/** list_music_remove 的载荷 */
export interface LxListMusicRemoveData {
  listId: string;
  ids: string[];
}

/** list_music_move 的载荷 */
export interface LxListMusicMoveData {
  fromId: string;
  toId: string;
  musicInfos: LxMusicInfoNew[];
  addMusicLocationType: string;
}

/** list_music_overwrite 的载荷 */
export interface LxListMusicOverwriteData {
  listId: string;
  musicInfos: LxMusicInfoNew[];
}

/** list_music_update_position 的载荷 */
export interface LxListMusicUpdatePositionData {
  listId: string;
  position: number;
  ids: string[];
}

/** list_update_position 的载荷 */
export interface LxListUpdatePositionData {
  position: number;
  ids: string[];
}

/** 不喜欢规则里的一条（dislike_music_add 的条目） */
export interface LxDislikeMusicInfo {
  name: string;
  singer: string;
}

/** 添加歌曲到歌单的位置（LX.AddMusicLocationType） */
export const ADD_MUSIC_TOP: string = 'top';
export const ADD_MUSIC_BOTTOM: string = 'bottom';

/** 洛雪内置收藏列表（loveList）：界面把它当一个内置歌单用，协议上仍是 loveList */
export const LIST_ID_LOVE: string = 'love';
/** 内置收藏歌单的展示名 —— 与官方客户端叫法一致 */
export const LOVE_LIST_NAME: string = '我的收藏';

// ------------------------------------------------------------------ 协议常量

/** 握手 / 认证 / 心跳相关的固定串，必须与官方实现逐字一致 */
export const SYNC_HELLO_MSG: string = 'Hello~::^-^::~v4~';
export const SYNC_ID_PREFIX: string = 'OjppZDo6';
export const SYNC_AUTH_MSG: string = 'lx-music auth::';
export const SYNC_MSG_AUTH_FAILED: string = 'Auth failed';
export const SYNC_MSG_BLOCKED_IP: string = 'Blocked IP';
export const SYNC_MSG_CONNECT: string = 'lx-music connect';
/** 认证时在第四行声明自己是移动端，服务端会因此给连接发文本 ping */
export const SYNC_CLIENT_TYPE: string = 'lx_music_mobile';

export const SYNC_CODE_AUTH_FAILED: string = 'Auth failed';
export const SYNC_CODE_MISSING_AUTH_CODE: string = 'Missing auth code';
export const SYNC_CODE_GET_SERVICE_ID_FAILED: string = 'Get service id failed';
export const SYNC_CODE_CONNECT_SERVICE_FAILED: string = 'Connect service failed';
export const SYNC_CODE_CONNECTING: string = 'Connecting...';
export const SYNC_CODE_LOW_SERVICE_VERSION: string =
  'Sync server version too low, please upgrade server to latest';
export const SYNC_CODE_HIGH_SERVICE_VERSION: string =
  'Sync server version too high, please upgrade app to latest';

export const SYNC_CLOSE_NORMAL: number = 1000;
export const SYNC_CLOSE_FAILED: number = 4100;

/** 各模块的能力版本：与服务端不一致时该模块不参与同步 */
export const FEATURE_VERSION: Record<string, number> = { 'list': 1, 'dislike': 1 };

/** 不喜欢规则的分隔符（与洛雪 SPLIT_CHAR 一致） */
export const DISLIKE_NAME_SEP: string = '@';
export const DISLIKE_NAME_ALIAS: string = '#';

/** 服务端把客户端选择的方式翻转后使用（洛雪 TRANS_MODE），客户端只需回传用户选的那一项 */
export const SYNC_LIST_MODES: string[] = [
  'merge_local_remote',
  'merge_remote_local',
  'overwrite_local_remote',
  'overwrite_remote_local',
  'overwrite_local_remote_full',
  'overwrite_remote_local_full',
  'cancel',
];

/** 同步方式选择框要给用户看的信息 */
export interface SyncModeOption {
  value: string;
  title: string;
  desc: string;
}

export const LIST_MODE_OPTIONS: SyncModeOption[] = [
  {
    value: 'merge_local_remote',
    title: '「本机列表」合并「远程列表」',
    desc: '两边的列表合并到一起，重复的歌曲去掉（去掉的是被合并方的），不同的歌曲添加。',
  },
  {
    value: 'merge_remote_local',
    title: '「远程列表」合并「本机列表」',
    desc: '两边的列表合并到一起，重复的歌曲去掉（去掉的是被合并方的），不同的歌曲添加。',
  },
  {
    value: 'overwrite_local_remote',
    title: '「本机列表」覆盖「远程列表」',
    desc: '远程中 ID 相同的列表被本机列表替换（ID 不同的合并进来）。',
  },
  {
    value: 'overwrite_remote_local',
    title: '「远程列表」覆盖「本机列表」',
    desc: '本机中 ID 相同的列表被远程列表替换（ID 不同的合并进来）。',
  },
  {
    value: 'overwrite_local_remote_full',
    title: '「本机列表」完全覆盖「远程列表」',
    desc: '远程的所有列表被移除，然后替换成本机的列表。',
  },
  {
    value: 'overwrite_remote_local_full',
    title: '「远程列表」完全覆盖「本机列表」',
    desc: '本机的所有列表被移除，然后替换成远程的列表。',
  },
];

export const DISLIKE_MODE_OPTIONS: SyncModeOption[] = [
  {
    value: 'merge_local_remote',
    title: '「本机规则」合并「远程规则」',
    desc: '合并两边「不喜欢的歌曲」规则并去重。',
  },
  {
    value: 'merge_remote_local',
    title: '「远程规则」合并「本机规则」',
    desc: '合并两边「不喜欢的歌曲」规则并去重。',
  },
  {
    value: 'overwrite_local_remote',
    title: '「本机规则」覆盖「远程规则」',
    desc: '远程的规则被替换成本机的规则。',
  },
  {
    value: 'overwrite_remote_local',
    title: '「远程规则」覆盖「本机规则」',
    desc: '本机的规则被替换成远程的规则。',
  },
];

export const SYNC_MODE_CANCEL: SyncModeOption = {
  value: 'cancel',
  title: '取消同步',
  desc: '不使用该模块的同步功能。',
};
