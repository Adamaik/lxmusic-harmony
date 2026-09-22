import { LxMusicInfo, decodeName } from './MusicSearch';
import { asNumber, asObjectArray, asRecord, asString, httpGetJson, httpPostForm, httpPostJson } from './PlatformHttp';
import { md5Hex } from './LxCrypto';

/**
 * 内置平台评论
 *
 * 为什么和歌词一样不能靠自定义源：洛雪的源协议里平台源的 action 白名单只有
 * `musicUrl`（见 lx_preload.js 的 supportActions），「给 musicInfo 拿评论」不属于源规则。
 * 洛雪自己走内置平台 SDK（`src/utils/musicSdk/{kw,kg,tx,mg,wy}/comment.js` 的
 * `musicSdk[source].comment.getComment/getHotComment`），这里把同一批接口移植到 ArkTS。
 *
 * 与歌词（`PlatformLyric.ets`）的分工完全对称：
 *   - 取词：源自带的 `lyric` 优先，内置平台歌词兜底；
 *   - 取评论：源协议里根本没有评论这个 action，所以只有内置这一条路。
 *
 * 各平台的分页方式差别很大，移植时都照着洛雪原样保留：
 *   - 酷我：`start = limit * (page - 1)`，最普通；
 *   - 酷狗：同上，外加一个把参数排序后拼 key 的 md5 签名；
 *   - QQ ：最新评论 `pagenum = page - 1`，热门评论走 musicu 的 GetHotCommentList；
 *   - 咪咕：**游标式** —— 除了 songId 还要上一页最后一条评论的 id，所以按 (歌曲, 页) 记游标；
 *   - 网易：`offset = limit * (page - 1)`，但用的是公开 GET（见 wyComments 的说明）。
 */

/** 一条评论（主评论与楼中楼共用一套结构） */
export interface LxComment {
  id: string;
  text: string;
  userName: string;
  /** 平台侧的用户 id（各平台都给加密过的值，界面上暂时不用，留着做「只看某人」之类） */
  userId: string;
  avatar: string;
  /** 已经格式化好的时间文案（「3 分钟前」/「2024-05-06」）；空串 = 平台没给时间 */
  timeStr: string;
  /** IP 归属地；空串 = 没有 */
  location: string;
  /** 点赞数；-1 = 平台没给（界面就不画这一块，而不是显示 0） */
  likedCount: number;
  /** 回复数；-1 = 平台没给 */
  replyNum: number;
  images: string[];
  /** 楼中楼：平台一般只在主评论里带前几条 */
  reply: LxComment[];
}

/** 一页评论 */
export interface CommentPage {
  comments: LxComment[];
  total: number;
  page: number;
  limit: number;
  maxPage: number;
}

/** 「热门」还是「最新」（对应洛雪评论页的两个页签） */
export type CommentKind = 'hot' | 'new';

/** 一页拉多少条（与洛雪评论页一致：两个页签都是 15） */
export const COMMENT_PAGE_SIZE: number = 15;

const COMMENT_SOURCES: string[] = ['kw', 'kg', 'mg', 'tx', 'wy'];

export function commentsSupported(source: string): boolean {
  return COMMENT_SOURCES.includes(source);
}

// ------------------------------------------------------------------ 小工具

/** 造一条空评论：各平台都往这个骨架上填，省得每处都写一遍全部字段 */
function makeComment(id: string, text: string, userName: string): LxComment {
  return {
    id: id,
    text: text,
    userName: userName,
    userId: '',
    avatar: '',
    timeStr: '',
    location: '',
    likedCount: -1,
    replyNum: -1,
    images: [],
    reply: [],
  };
}

/** 接口返回码比较：有的平台给数字、有的给字符串，统一当字符串比 */
function codeIs(value: Object | undefined, expected: string): boolean {
  return asString(value) === expected;
}

/** 平台给的是空值时算「没有点赞数」（界面不画），而不是 0 */
function likedCountOf(value: Object | undefined): number {
  return asNumber(value, -1);
}

/** 封面 / 评论图片地址的百分号解码；地址坏了不该把整页评论带崩，所以就地吞掉 */
function safeDecode(uri: string): string {
  try {
    return decodeURIComponent(uri);
  } catch (e) {
    return uri;
  }
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/** `YYYY-MM-DD`（洛雪的 dateFormat(x, 'Y-M-D')） */
function dateOnly(ms: number): string {
  const date = new Date(ms);
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

/**
 * 相对时间（照抄洛雪 `date_format_second/minute/hour` 的档位与文案）
 *
 * 一分钟内「N 秒前」、一小时内「N 分钟前」、一天内「N 小时前」，再往前只给日期。
 * 时间戳异常（0 / 未来）返回空串，界面就不显示这一块。
 */
export function relativeTime(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const differ: number = Math.trunc((Date.now() - ms) / 1000);
  if (differ < 0) {
    return '刚刚';
  }
  if (differ < 60) {
    return `${differ} 秒前`;
  }
  if (differ < 3600) {
    return `${Math.trunc(differ / 60)} 分钟前`;
  }
  if (differ < 86400) {
    return `${Math.trunc(differ / 3600)} 小时前`;
  }
  return dateOnly(ms);
}

/**
 * `YYYY-MM-DD HH:mm:ss` -> 毫秒（酷狗 / 咪咕给的是这种字符串）
 *
 * 不用 `new Date(text)`：这种非 ISO 格式在不同引擎里的解析结果不一致，
 * 手写解析至少结果可预期；解析不出来给 0，界面按「没有时间」处理。
 */
function parseDateTime(text: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(text);
  if (match === null) {
    return 0;
  }
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
    Number(match[4]), Number(match[5]), Number(match[6])).getTime();
}

/** 按平台给的秒级时间戳转毫秒（QQ 的 time 字段是秒） */
function secondsToMs(value: Object | undefined): number {
  const text: string = asString(value);
  // 洛雪只认 10 位以上的时间戳（秒）；短于此的当没有时间
  if (text.length < 10) {
    return 0;
  }
  const seconds: number = asNumber(value, 0);
  return seconds > 0 ? seconds * 1000 : 0;
}

function capPage(total: number, limit: number): number {
  return Math.ceil(total / limit) || 1;
}

// ------------------------------------------------------------------ 酷我

const KW_HEADERS: Record<string, string> = {
  'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)',
};

const KG_COMMENT_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/107.0.0.0 Safari/537.36 Edg/107.0.1418.24',
};

export function parseKwComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const comment: LxComment = makeComment(
      asString(item['id']), asString(item['msg']), asString(item['u_name']));
    comment.avatar = asString(item['u_pic']);
    comment.timeStr = relativeTime(asNumber(item['time'], 0) * 1000);
    comment.likedCount = likedCountOf(item['like_num']);
    const pic: string = asString(item['mpic']);
    if (pic.length > 0) {
      comment.images = [safeDecode(pic)];
    }
    for (const childRaw of asObjectArray(item['child_comments'])) {
      const child: Record<string, Object> = asRecord(childRaw);
      const reply: LxComment = makeComment(
        asString(child['id']), asString(child['msg']), asString(child['u_name']));
      reply.avatar = asString(child['u_pic']);
      reply.timeStr = relativeTime(asNumber(child['time'], 0) * 1000);
      reply.likedCount = likedCountOf(child['like_num']);
      const childPic: string = asString(child['mpic']);
      if (childPic.length > 0) {
        reply.images = [childPic];
      }
      comment.reply.push(reply);
    }
    out.push(comment);
  }
  return out;
}

async function kwComments(songmid: string, kind: CommentKind, page: number, limit: number): Promise<CommentPage> {
  if (songmid.length === 0) {
    throw new Error('这首歌缺少酷我歌曲 id，拿不到评论');
  }
  const type: string = kind === 'hot' ? 'get_rec_comment' : 'get_comment';
  const url: string = 'http://ncomment.kuwo.cn/com.s?f=web&type=' + type +
    '&aapiver=1&prod=kwplayer_ar_10.5.2.0&digest=15&sid=' + encodeURIComponent(songmid) +
    `&start=${limit * (page - 1)}&msgflag=1&count=${limit}&newver=3&uid=0`;
  const body: Record<string, Object> = await httpGetJson(url, KW_HEADERS, '获取评论');
  if (!codeIs(body['code'], '200')) {
    throw new Error(`获取评论失败（酷我接口返回 ${asString(body['code'])}）`);
  }
  const listKey: string = kind === 'hot' ? 'hot_comments' : 'comments';
  const countKey: string = kind === 'hot' ? 'hot_comments_counts' : 'comments_counts';
  const total: number = asNumber(body[countKey], 0);
  return {
    comments: parseKwComments(asObjectArray(body[listKey])),
    total: total,
    page: page,
    limit: limit,
    maxPage: capPage(total, limit),
  };
}

// ------------------------------------------------------------------ 酷狗

/**
 * 酷狗评论签名：把查询串按 `&` 拆开、**排序**后拼起来，前后各裹一个固定 key 再 md5
 * （照抄洛雪 `kg/util.js` 的 `signatureParams`，key 是 android 那一个）
 */
export function kgSignature(params: string): string {
  const parts: string[] = params.split('&');
  parts.sort();
  return md5Hex(`OIlwieks28dk2k092lksi2UIkp${parts.join('')}OIlwieks28dk2k092lksi2UIkp`);
}

/** 酷狗把「回复某人」写成 `[at=123]`，要换成 `@名字 `（照抄洛雪 kg/comment.js 的 replaceAt） */
function replaceAt(raw: string, atList: Object[]): string {
  let out: string = raw;
  for (const atRaw of atList) {
    const at: Record<string, Object> = asRecord(atRaw);
    const id: string = asString(at['id']);
    if (id.length === 0) {
      continue;
    }
    out = out.split(`[at=${id}]`).join(`@${asString(at['name'])} `);
  }
  return out;
}

export function parseKgComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const content: string = asString(item['content']);
    const atList: Object[] = asObjectArray(item['atlist']);
    const text: string = decodeName(atList.length > 0 ? replaceAt(content, atList) : content);

    const comment: LxComment = makeComment(asString(item['id']), text, asString(item['user_name']));
    comment.avatar = asString(item['user_pic']);
    comment.userId = asString(item['user_id']);
    comment.location = asString(item['location']);
    comment.timeStr = relativeTime(parseDateTime(asString(item['addtime'])));
    comment.likedCount = likedCountOf(asRecord(item['like'])['likenum']);
    comment.replyNum = likedCountOf(item['reply_num']);
    for (const imageRaw of asObjectArray(item['images'])) {
      const url: string = asString(asRecord(imageRaw)['url']);
      if (url.length > 0) {
        comment.images.push(url);
      }
    }

    // pcontent 是「这条其实是回复某条评论」时被引用的原文：洛雪把它当成主楼、
    // 真正的回复放 reply 里（与 QQ / 网易同一套处理）
    const parent: string = asString(item['pcontent']);
    if (parent.length === 0) {
      out.push(comment);
      continue;
    }
    const wrapper: LxComment = makeComment(
      asString(item['id']), decodeName(parent), asString(item['puser']));
    wrapper.userId = asString(item['puser_id']);
    wrapper.reply = [comment];
    out.push(wrapper);
  }
  return out;
}

async function kgComments(info: LxMusicInfo, kind: CommentKind, page: number, limit: number): Promise<CommentPage> {
  const hash: string = info.hash !== undefined ? info.hash : '';
  if (hash.length === 0) {
    throw new Error('这首歌缺少酷狗 hash，拿不到评论');
  }
  const rank: string = kind === 'hot' ? 'topliked' : 'newest';
  // 参数顺序与洛雪一致（签名算的是排序后的串，顺序其实不影响结果，但保持一致便于对照）
  const params: string = 'dfid=0&mid=16249512204336365674023395779019' +
    `&clienttime=${Date.now()}&uuid=0&extdata=${hash}` +
    '&appid=1005&code=fc4be23b4e972707f36b8a828a93ba8a' +
    `&schash=${hash}&clientver=11409&p=${page}&clienttoken=&pagesize=${limit}&ver=10&kugouid=0`;
  const url: string = `http://m.comment.service.kugou.com/r/v1/rank/${rank}?${params}&signature=${kgSignature(params)}`;
  const body: Record<string, Object> = await httpGetJson(url, KG_COMMENT_HEADERS, '获取评论');
  if (!codeIs(body['err_code'], '0')) {
    throw new Error(`获取评论失败（酷狗接口返回 err_code ${asString(body['err_code'])}）`);
  }
  const total: number = asNumber(body['count'], 0);
  return {
    comments: parseKgComments(asObjectArray(body['list'])),
    total: total,
    page: page,
    limit: limit,
    maxPage: capPage(total, limit),
  };
}

// ------------------------------------------------------------------ 咪咕

const MG_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 ' +
    '(KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
};

/**
 * 咪咕「最新评论」是游标分页：第二页要带第一页最后一条评论的 id
 * （`commentId` 参数）。游标按「歌曲 + 页码」记，换歌或重新拉第一页就清掉。
 */
let mgCursor: Record<string, Record<string, string>> = {};

function mgCursorOf(resourceId: string, page: number): string {
  const perSong: Record<string, string> | undefined = mgCursor[resourceId];
  if (perSong === undefined) {
    return '';
  }
  const id: string | undefined = perSong[String(page)];
  return id !== undefined ? id : '';
}

function mgSetCursor(resourceId: string, page: number, lastId: string): void {
  let perSong: Record<string, string> | undefined = mgCursor[resourceId];
  if (perSong === undefined) {
    perSong = {};
    mgCursor[resourceId] = perSong;
  }
  perSong[String(page)] = lastId;
}

/** 咪咕的用户头像有三档，取能得到的那一档 */
function mgAvatar(user: Record<string, Object>): string {
  let avatar: string = asString(user['middleIcon']);
  if (avatar.length === 0) {
    avatar = asString(user['bigIcon']);
  }
  if (avatar.length === 0) {
    avatar = asString(user['smallIcon']);
  }
  return avatar;
}

export function parseMgComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const user: Record<string, Object> = asRecord(item['user']);
    const comment: LxComment = makeComment(asString(item['commentId']),
      asString(item['commentInfo']), asString(user['nickName']));
    comment.avatar = mgAvatar(user);
    comment.userId = asString(user['userId']);
    comment.timeStr = relativeTime(parseDateTime(asString(item['commentTime'])));
    comment.likedCount = likedCountOf(asRecord(item['opNumItem'])['thumbNum']);
    comment.replyNum = likedCountOf(item['replyTotalCount']);
    for (const replyRaw of asObjectArray(item['replyComments'])) {
      const replyData: Record<string, Object> = asRecord(replyRaw);
      const replyUser: Record<string, Object> = asRecord(replyData['user']);
      const reply: LxComment = makeComment(asString(replyData['replyId']),
        asString(replyData['replyInfo']), asString(replyUser['nickName']));
      reply.avatar = mgAvatar(replyUser);
      reply.userId = asString(replyUser['userId']);
      reply.timeStr = relativeTime(parseDateTime(asString(replyData['replyTime'])));
      comment.reply.push(reply);
    }
    out.push(comment);
  }
  return out;
}

/** 咪咕评论用的 resourceId：搜索结果的 songmid 就是 songId（洛雪 mg/songId.js 同口径） */
function mgResourceId(info: LxMusicInfo): string {
  if (info.songId !== undefined && info.songId.length > 0) {
    return info.songId;
  }
  return info.songmid;
}

async function mgComments(info: LxMusicInfo, kind: CommentKind, page: number, limit: number): Promise<CommentPage> {
  const resourceId: string = mgResourceId(info);
  if (resourceId.length === 0) {
    throw new Error('这首歌缺少咪咕歌曲 id，拿不到评论');
  }
  const base: string = 'https://app.c.nf.migu.cn/MIGUM3.0/user/comment/stack/v1.0' +
    `?pageSize=${limit}&resourceId=${encodeURIComponent(resourceId)}&resourceType=2`;
  let url: string;
  if (kind === 'hot') {
    url = `${base}&queryType=2&hotCommentStart=${(page - 1) * limit}`;
  } else {
    if (page === 1) {
      // 第一页顺手把这首歌的游标清掉：重新进来时不该拿上一次的游标去翻页
      const empty: Record<string, string> = {};
      mgCursor[resourceId] = empty;
    }
    const cursor: string = mgCursorOf(resourceId, page);
    if (page > 1 && cursor.length === 0) {
      // 没有上一页的游标就翻不动了（洛雪在这里直接报错，我们同样如实抛）
      throw new Error('咪咕评论需要按顺序翻页，请先加载上一页');
    }
    url = `${base}&queryType=1&commentId=${encodeURIComponent(cursor)}`;
  }
  const body: Record<string, Object> = await httpGetJson(url, MG_HEADERS, '获取评论');
  if (!codeIs(body['code'], '000000')) {
    throw new Error(`获取评论失败（咪咕接口返回 ${asString(body['code'])}）`);
  }
  const data: Record<string, Object> = asRecord(body['data']);
  if (kind === 'hot') {
    const total: number = asNumber(data['cfgHotCount'], 0);
    return {
      comments: parseMgComments(asObjectArray(data['hotComments'])),
      total: total,
      page: page,
      limit: limit,
      maxPage: capPage(total, limit),
    };
  }
  const total: number = asNumber(data['commentNums'], 0);
  const comments: LxComment[] = parseMgComments(asObjectArray(data['comments']));
  // 记下这一页最后一条的 id，供第 page+1 页当游标
  mgSetCursor(resourceId, page + 1, comments.length > 0 ? comments[comments.length - 1].id : '');
  return { comments: comments, total: total, page: page, limit: limit, maxPage: capPage(total, limit) };
}

// ------------------------------------------------------------------ QQ 音乐

const TX_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/113.0.0.0 Safari/537.36 Edg/113.0.0.0',
  'referer': 'https://y.qq.com/',
  'origin': 'https://y.qq.com',
};

/** QQ 老 fcg 接口（最新评论）与补 songId 用的老式 UA，照抄洛雪 */
const TX_FCG_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
};

/** QQ 评论里的表情码（`[em]e400846[/em]`），照抄洛雪 tx/comment.js 的 emojis 表 */
const TX_EMOJIS: Record<string, string> = {
  'e400846': '😘', 'e400874': '😴', 'e400825': '😃', 'e400847': '😙', 'e400835': '😍',
  'e400873': '😳', 'e400836': '😎', 'e400867': '😭', 'e400832': '😊', 'e400837': '😏',
  'e400875': '😫', 'e400831': '😉', 'e400855': '😡', 'e400823': '😄', 'e400862': '😨',
  'e400844': '😖', 'e400841': '😓', 'e400830': '😈', 'e400828': '😆', 'e400833': '😋',
  'e400822': '😀', 'e400843': '😕', 'e400829': '😇', 'e400824': '😂', 'e400834': '😌',
  'e400877': '😷', 'e400132': '🍉', 'e400181': '🍺', 'e401067': '☕️', 'e400186': '🥧',
  'e400343': '🐷', 'e400116': '🌹', 'e400126': '🍃', 'e400613': '💋', 'e401236': '❤️',
  'e400622': '💔', 'e400637': '💣', 'e400643': '💩', 'e400773': '🔪', 'e400102': '🌛',
  'e401328': '🌞', 'e400420': '👏', 'e400914': '🙌', 'e400408': '👍', 'e400414': '👎',
  'e401121': '✋', 'e400396': '👋', 'e400384': '👉', 'e401115': '✊', 'e400402': '👌',
  'e400905': '🙈', 'e400906': '🙉', 'e400907': '🙊', 'e400562': '👻', 'e400932': '🙏',
  'e400644': '💪', 'e400611': '💉', 'e400185': '🎁', 'e400655': '💰', 'e400325': '🐥',
  'e400612': '💊', 'e400198': '🎉', 'e401685': '⚡️', 'e400631': '💝', 'e400768': '🔥',
  'e400432': '👑',
};

const TX_EMOJI_TAG: RegExp = /\[em\](e\d+)\[\/em\]/g;

/** 正文里的表情码换成 emoji、`\n`（字面上的反斜杠 n）换成真换行 */
function txText(raw: string): string {
  const replaced: string = raw.replace(TX_EMOJI_TAG, (_tag: string, code: string): string => {
    const emoji: string | undefined = TX_EMOJIS[code];
    return emoji !== undefined ? emoji : '';
  });
  return replaced.split('\\n').join('\n');
}

/** QQ 的昵称前面带一个不可见的控制字符（洛雪统一 substring(1) 去掉） */
function txNick(raw: string): string {
  return raw.length > 1 ? raw.substring(1) : '';
}

export function parseTxComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const rootText: string = asString(item['rootcommentcontent']);
    const isRoot: boolean = asString(item['rootcommentid']) === asString(item['commentid']);
    const comment: LxComment = makeComment(
      `${asString(item['rootcommentid'])}_${asString(item['commentid'])}`,
      txText(rootText), txNick(asString(item['rootcommentnick'])));
    comment.avatar = asString(item['avatarurl']);
    comment.userId = asString(item['encrypt_rootcommentuin']);
    comment.likedCount = likedCountOf(item['praisenum']);
    // 时间只跟着「本条」走：被引用进来的原文不报时间（洛雪同款判断）
    if (isRoot) {
      comment.timeStr = relativeTime(secondsToMs(item['time']));
    }
    for (const replyRaw of asObjectArray(item['middlecommentcontent'])) {
      const replyData: Record<string, Object> = asRecord(replyRaw);
      const reply: LxComment = makeComment(
        `sub_${asString(item['rootcommentid'])}_${asString(replyData['subcommentid'])}`,
        txText(asString(replyData['subcommentcontent'])),
        txNick(asString(replyData['replynick'])));
      reply.avatar = asString(replyData['avatarurl']);
      reply.userId = asString(replyData['encrypt_replyuin']);
      reply.likedCount = likedCountOf(replyData['praisenum']);
      comment.reply.push(reply);
    }
    out.push(comment);
  }
  return out;
}

/**
 * 热门评论（musicu 的 GetHotCommentList）
 *
 * 与「最新」的字段名完全不同（首字母大写），所以单独一套解析。
 */
export function parseTxHotComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const comment: LxComment = makeComment(`${asString(item['SeqNo'])}_${asString(item['CmId'])}`,
      txText(asString(item['Content'])), asString(item['Nick']));
    comment.avatar = asString(item['Avatar']);
    comment.userId = asString(item['EncryptUin']);
    comment.location = asString(item['Location']);
    comment.likedCount = likedCountOf(item['PraiseNum']);
    comment.timeStr = relativeTime(secondsToMs(item['PubTime']));
    const pic: string = asString(item['Pic']);
    if (pic.length > 0) {
      comment.images = [pic];
    }
    for (const replyRaw of asObjectArray(item['SubComments'])) {
      const replyData: Record<string, Object> = asRecord(replyRaw);
      const reply: LxComment = makeComment(
        `sub_${asString(replyData['SeqNo'])}_${asString(replyData['CmId'])}`,
        txText(asString(replyData['Content'])), asString(replyData['Nick']));
      reply.avatar = asString(replyData['Avatar']);
      reply.userId = asString(replyData['EncryptUin']);
      reply.likedCount = likedCountOf(replyData['PraiseNum']);
      reply.timeStr = relativeTime(secondsToMs(replyData['PubTime']));
      const replyPic: string = asString(replyData['Pic']);
      if (replyPic.length > 0) {
        reply.images = [replyPic];
      }
      comment.reply.push(reply);
    }
    out.push(comment);
  }
  return out;
}

/** 已经解析过的 QQ songId（歌单/分享链进来时可能只有 songmid），按 songmid 记住 */
let txSongIds: Record<string, string> = {};

/**
 * QQ musicu 的请求体
 *
 * ArkTS 不允许「没有声明类型的对象字面量」，所以每个请求体都得有接口
 * （与 MusicList.ets 里歌单那几个 Tx*Payload 同一套写法）。
 */
interface TxComm {
  ct: string | number;
  cv: string | number;
  uin: string | number;
  format?: string;
  inCharset?: string;
  outCharset?: string;
  notice?: number;
  platform?: string;
  needNewCode?: number;
}

interface TxSongDetailParam {
  song_type: number;
  song_mid: string;
}

interface TxSongDetailReq {
  module: string;
  method: string;
  param: TxSongDetailParam;
}

interface TxSongDetailPayload {
  comm: TxComm;
  req: TxSongDetailReq;
}

interface TxHotParam {
  BizType: number;
  BizId: string;
  LastCommentSeqNo: string;
  PageSize: number;
  PageNum: number;
  HotType: number;
  WithAirborne: number;
  PicEnable: number;
}

interface TxHotReq {
  module: string;
  method: string;
  param: TxHotParam;
}

interface TxHotPayload {
  comm: TxComm;
  req: TxHotReq;
}

/** 补 QQ 的 songId */
async function txSongId(info: LxMusicInfo): Promise<string> {
  if (info.songId !== undefined && info.songId.length > 0) {
    return info.songId;
  }
  const cached: string | undefined = txSongIds[info.songmid];
  if (cached !== undefined && cached.length > 0) {
    return cached;
  }
  if (info.songmid.length === 0) {
    throw new Error('这首歌缺少 QQ 歌曲 id，拿不到评论');
  }
  // 评论接口要的是数字 songId，而条目里可能只存了 songmid（比如歌单导入那条路）。
  // 用洛雪 tx/musicInfo.js 的 get_song_detail_yqq 换一次，结果按 songmid 缓存。
  const payload: TxSongDetailPayload = {
    comm: { ct: '19', cv: '1859', uin: '0' },
    req: {
      module: 'music.pf_song_detail_svr',
      method: 'get_song_detail_yqq',
      param: { song_type: 0, song_mid: info.songmid },
    },
  };
  const body: Record<string, Object> = await httpPostJson('https://u.y.qq.com/cgi-bin/musicu.fcg',
    payload, TX_FCG_HEADERS, '获取歌曲信息');
  const track: Record<string, Object> = asRecord(asRecord(asRecord(body['req'])['data'])['track_info']);
  const songId: string = asString(track['id']);
  if (songId.length === 0) {
    throw new Error('拿不到这首歌的 QQ songId，评论取不了');
  }
  txSongIds[info.songmid] = songId;
  return songId;
}

async function txComments(info: LxMusicInfo, kind: CommentKind, page: number, limit: number): Promise<CommentPage> {
  const songId: string = await txSongId(info);
  if (kind === 'hot') {
    const payload: TxHotPayload = {
      comm: {
        cv: 4747474, ct: 24, format: 'json', inCharset: 'utf-8', outCharset: 'utf-8',
        notice: 0, platform: 'yqq.json', needNewCode: 1, uin: 0,
      },
      req: {
        module: 'music.globalComment.CommentRead',
        method: 'GetHotCommentList',
        param: {
          BizType: 1, BizId: songId, LastCommentSeqNo: '', PageSize: limit,
          PageNum: page - 1, HotType: 1, WithAirborne: 0, PicEnable: 1,
        },
      },
    };
    const body: Record<string, Object> = await httpPostJson('https://u.y.qq.com/cgi-bin/musicu.fcg',
      payload, TX_HEADERS, '获取热门评论');
    const req: Record<string, Object> = asRecord(body['req']);
    if (!codeIs(body['code'], '0') || !codeIs(req['code'], '0')) {
      throw new Error(`获取热门评论失败（QQ 接口返回 ${asString(body['code'])}/${asString(req['code'])}）`);
    }
    const list: Record<string, Object> = asRecord(asRecord(req['data'])['CommentList']);
    const total: number = asNumber(list['Total'], 0);
    return {
      comments: parseTxHotComments(asObjectArray(list['Comments'])),
      total: total,
      page: page,
      limit: limit,
      maxPage: capPage(total, limit),
    };
  }

  const form: Record<string, string> = {
    'uin': '0', 'format': 'json', 'cid': '205360772', 'reqtype': '2', 'biztype': '1',
    'topid': songId, 'cmd': '8', 'needmusiccrit': '1',
    'pagenum': String(page - 1), 'pagesize': String(limit),
  };
  const body: Record<string, Object> = await httpPostForm(
    'http://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg',
    form, TX_FCG_HEADERS, '获取评论');
  if (!codeIs(body['code'], '0')) {
    throw new Error(`获取评论失败（QQ 接口返回 ${asString(body['code'])}）`);
  }
  const comment: Record<string, Object> = asRecord(body['comment']);
  const total: number = asNumber(comment['commenttotal'], 0);
  return {
    comments: parseTxComments(asObjectArray(comment['commentlist'])),
    total: total,
    page: page,
    limit: limit,
    maxPage: capPage(total, limit),
  };
}

// ------------------------------------------------------------------ 网易

const WY_HEADERS: Record<string, string> = {
  'Referer': 'https://music.163.com/',
};

/** 网易把表情写成 `[大笑]` 这种标签，照抄洛雪 wy/comment.js 的表换成 emoji */
const WY_EMOJIS: string[][] = [
  ['大笑', '😃'], ['可爱', '😊'], ['憨笑', '☺️'], ['色', '😍'], ['亲亲', '😙'],
  ['惊恐', '😱'], ['流泪', '😭'], ['亲', '😚'], ['呆', '😳'], ['哀伤', '😔'],
  ['呲牙', '😁'], ['吐舌', '😝'], ['撇嘴', '😒'], ['怒', '😡'], ['奸笑', '😏'],
  ['汗', '😓'], ['痛苦', '😖'], ['惶恐', '😰'], ['生病', '😨'], ['口罩', '😷'],
  ['大哭', '😂'], ['晕', '😵'], ['发怒', '👿'], ['开心', '😄'], ['鬼脸', '😜'],
  ['皱眉', '😞'], ['流感', '😢'], ['爱心', '❤️'], ['心碎', '💔'], ['钟情', '💘'],
  ['星星', '⭐️'], ['生气', '💢'], ['便便', '💩'], ['强', '👍'], ['弱', '👎'],
  ['拜', '🙏'], ['牵手', '👫'], ['跳舞', '👯‍♀️'], ['禁止', '🙅‍♀️'], ['这边', '💁‍♀️'],
  ['爱意', '💏'], ['示爱', '👩‍❤️‍👨'], ['嘴唇', '👄'], ['狗', '🐶'], ['猫', '🐱'],
  ['猪', '🐷'], ['兔子', '🐰'], ['小鸡', '🐤'], ['公鸡', '🐔'], ['幽灵', '👻'],
  ['圣诞', '🎅'], ['外星', '👽'], ['钻石', '💎'], ['礼物', '🎁'], ['男孩', '👦'],
  ['女孩', '👧'], ['蛋糕', '🎂'], ['18', '🔞'], ['圈', '⭕'], ['叉', '❌'],
];

function wyText(raw: string): string {
  let out: string = raw;
  for (const pair of WY_EMOJIS) {
    out = out.split(`[${pair[0]}]`).join(pair[1]);
  }
  return out;
}

/** 一条网易评论 -> LxComment；`withTime` 为假表示它只是被引用进来的原文 */
function wyOne(raw: Object, withTime: boolean): LxComment {
  const item: Record<string, Object> = asRecord(raw);
  const user: Record<string, Object> = asRecord(item['user']);
  const comment: LxComment = makeComment(asString(item['commentId']),
    wyText(asString(item['content'])), asString(user['nickname']));
  comment.avatar = asString(user['avatarUrl']);
  comment.userId = asString(user['userId']);
  comment.likedCount = likedCountOf(item['likedCount']);
  if (withTime) {
    comment.timeStr = relativeTime(asNumber(item['time'], 0));
    comment.location = asString(asRecord(item['ipLocation'])['location']);
  }
  return comment;
}

/**
 * 网易：「这条其实是回复别人」时，`beReplied[0]` 装的是被引用的原文。
 * 洛雪把它翻成「主楼 = 原文，reply = 这条回复」，这里同一套处理。
 */
export function parseWyComments(rawList: Object[]): LxComment[] {
  const out: LxComment[] = [];
  for (const raw of rawList) {
    const item: Record<string, Object> = asRecord(raw);
    const data: LxComment = wyOne(item, true);
    const repliedRaw: Object[] = asObjectArray(item['beReplied']);
    if (repliedRaw.length === 0) {
      out.push(data);
      continue;
    }
    const replied: LxComment = wyOne(repliedRaw[0], false);
    replied.id = data.id;
    replied.reply = [data];
    out.push(replied);
  }
  return out;
}

/**
 * 网易：公开的 `/api/v1/resource/comments/R_SO_4_{id}`（无需登录、无需 weapi 加密）
 *
 * 洛雪走的是 `weapi/comment/resource/comments/get`（要 weapi 的 AES+RSA），
 * 而本工程已经因为 wy 的 eapi 链路整体不通（见 docs/DEFECTS.md D-001）改用公开接口取歌词
 * （`PlatformLyric.wyLyric` 的 `/api/song/lyric`），评论沿用同一套路子 —— 同样打
 * music.163.com 的公开 `/api/` 面，只是路径是评论那两个。
 * ⚠️ 与歌词一样属于**待实测**：wy 搜索链路本身还没修通，这条要等 D-001 处理完一起回归。
 */
async function wyComments(songmid: string, kind: CommentKind, page: number, limit: number): Promise<CommentPage> {
  if (songmid.length === 0) {
    throw new Error('这首歌缺少网易歌曲 id，拿不到评论');
  }
  const rid: string = `R_SO_4_${songmid}`;
  const offset: number = limit * (page - 1);
  const path: string = kind === 'hot'
    ? 'https://music.163.com/api/v1/resource/hotcomments/' + encodeURIComponent(rid)
    : 'https://music.163.com/api/v1/resource/comments/' + encodeURIComponent(rid);
  const body: Record<string, Object> = await httpGetJson(
    `${path}?limit=${limit}&offset=${offset}`, WY_HEADERS, '获取评论');
  if (!codeIs(body['code'], '200')) {
    throw new Error(`获取评论失败（网易接口返回 ${asString(body['code'])}）`);
  }
  const listKey: string = kind === 'hot' ? 'hotComments' : 'comments';
  const total: number = asNumber(body['total'], 0);
  return {
    comments: parseWyComments(asObjectArray(body[listKey])),
    total: total,
    page: page,
    limit: limit,
    maxPage: capPage(total, limit),
  };
}

// ------------------------------------------------------------------ 入口

/**
 * 按平台取一页评论
 *
 * 失败一律抛出（不吞成空列表）：评论页要能区分「真的没人评论」和「接口挂了」，
 * 前者显示空态、后者显示错误与重试。这一点与歌词不同 —— 歌词取不到就只是「暂无歌词」，
 * 没有可操作的下一步，评论则是用户主动点进来的，得给个交代。
 */
export async function fetchComments(info: LxMusicInfo, kind: CommentKind, page: number,
  limit: number = COMMENT_PAGE_SIZE): Promise<CommentPage> {
  if (!commentsSupported(info.source)) {
    throw new Error('该平台暂不支持查看评论');
  }
  if (info.source === 'kw') {
    return await kwComments(info.songmid, kind, page, limit);
  }
  if (info.source === 'kg') {
    return await kgComments(info, kind, page, limit);
  }
  if (info.source === 'mg') {
    return await mgComments(info, kind, page, limit);
  }
  if (info.source === 'tx') {
    return await txComments(info, kind, page, limit);
  }
  return await wyComments(info.songmid, kind, page, limit);
}

/** 同一首歌同一页去重（平台会在翻页边界重复返回，洛雪的 filterList 就是干这个的） */
export function dedupeComments(list: LxComment[]): LxComment[] {
  const seen: string[] = [];
  const out: LxComment[] = [];
  for (const comment of list) {
    if (seen.includes(comment.id)) {
      continue;
    }
    seen.push(comment.id);
    out.push(comment);
  }
  return out;
}
