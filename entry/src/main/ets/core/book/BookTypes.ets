/**
 * 听书（书源）类型定义
 *
 * 书源是「阅读（Legado）」的 JSON 规则，和有声音源（洛雪 JS 脚本）是两套协议，
 * 所以这里是一套独立的类型。规则求值全部在沙箱（book_preload.js）里做，
 * 宿主只负责「导入 / 存 / 取 / 抓网络」，因此 ArkTS 侧只认识元信息与结果结构。
 */

/** 书架 / 搜索结果的来源标记（PlaySession 用它分流到书这条播放链路） */
export const BOOK_SOURCE: string = 'book';
/** 书不需要音质协商，占一个固定档位（缓存键、界面显示都要用） */
export const BOOK_QUALITY: string = 'book';

/**
 * 书源（只声明宿主真会读到的字段）
 *
 * `header` / `jsLib` / 各 rule* 都由沙箱直接吃原始 JSON，宿主不解析，
 * 所以这里不列它们 —— 少一层 ArkTS 与 JSON 的类型拉扯。
 */
export interface BookSource {
  bookSourceName?: string;
  bookSourceUrl?: string;
  bookSourceGroup?: string;
  bookSourceType?: number;
  bookSourceComment?: string;
  searchUrl?: string;
  exploreUrl?: string;
  enabled?: boolean;
  enabledExplore?: boolean;
  loginUrl?: string;
}

/** 存进索引的书源元信息 */
export interface BookSourceInfo {
  id: string;
  name: string;
  group: string;
  url: string;
  comment: string;
  /** 1 = 有声书 */
  type: number;
  /** 是否有搜索 / 发现能力（界面据此决定让不让你搜） */
  canSearch: boolean;
  canExplore: boolean;
  /** 需要登录（有 loginUrl）时才可能取到音频，界面上给个提示 */
  needLogin: boolean;
  importedAt: number;
}

/** 书源发现页的一个分类 */
export interface BookExploreCategory {
  title: string;
  url: string;
}

/** 一本书（搜索结果 / 书架条目共用） */
export interface BookHit {
  /** `来源id:书地址` 的稳定标识 */
  id: string;
  sourceId: string;
  sourceName: string;
  name: string;
  author: string;
  coverUrl: string;
  intro: string;
  kind: string;
  wordCount: string;
  status: string;
  lastChapter: string;
  /** 详情页地址 */
  bookUrl: string;
}

/** 一章（有声书里就是「一集」） */
export interface BookChapter {
  /** 在目录里的序号，从 0 开始 */
  index: number;
  name: string;
  /** 章节页地址；有些源这里直接就是音频直链 */
  url: string;
  duration: string;
}

/** 一本书的详情（含目录） */
export interface BookDetail {
  name: string;
  author: string;
  coverUrl: string;
  intro: string;
  kind: string;
  status: string;
  wordCount: string;
  tocUrl: string;
}

/** 解析出来的音频 */
export interface BookAudio {
  url: string;
  /** 直链是怎么来的：audioUrl / content / chapterUrl，排查规则时有用 */
  from: string;
}

/**
 * 书源登录弹窗里的一项（对应阅读书源 JSON 里的 `loginUi`）
 *
 * 阅读的 `loginUi` 是一段 JSON（字符串或数组），每项：
 *   - `{name, title, type:'text'|'password'}` → 一个输入框，key = name || title
 *   - `{title, type:'text', value:'…说明文字…'}` → 纯说明（没有 name，只有 value）
 *   - `{title|name, type:'button', action:'@js: …'}` → 一个按钮，点了在沙箱里跑 action
 * 这里把它规整成固定字段，界面只管渲染。
 */
export interface BookLoginUiItem {
  /** 存进登录信息表的键（没写 name 就用 title） */
  name: string;
  /** 显示出来的标题 / 按钮文字 */
  title: string;
  /** text / password / button / select */
  type: string;
  /** 输入框的默认值；纯说明项里就是说明正文 */
  value: string;
  /** 按钮点击要跑的 JS（`@js:` 规则） */
  action: string;
  /** 输入框的提示语 */
  placeholder: string;
  /** 这一项当「说明文字」渲染而不是输入框 */
  isHint: boolean;
}

/** 一次登录动作（按钮 / 检查登录）的结果 */
export interface BookLoginResult {
  /** 规则算出来的字符串（「检查登录」时就是判断结果） */
  result: string;
  /** 动作跑完后完整的登录信息表（宿主落盘） */
  login: Record<string, string>;
  /** 规则里 java.toast 说的话 */
  toasts: string[];
  /** 规则里 startBrowser 要打开的地址（登录页） */
  openUrl: string;
}

/**
 * 队列条目里 book 类歌曲的载荷
 *
 * 与在线歌用 musicInfoJson 装 musicInfo 是同一个套路：SongItem 没有多余的字段，
 * 播放时从这里还原出「哪个书源、哪一章」再去解析音频直链。
 */
export interface BookPlayPayload {
  sourceId: string;
  bookName: string;
  bookUrl: string;
  chapterIndex: number;
  chapterName: string;
  chapterUrl: string;
  coverUrl: string;
}

/** 沙箱回放循环里，一次缺失请求的描述 */
export interface BookNetRequest {
  key: string;
  url: string;
  method: string;
  body: string;
  headers: Record<string, string>;
}

/** 沙箱 `__book_run__` 的返回 */
export interface BookRunResult {
  status: string;
  urls?: BookNetRequest[];
  message?: string;
  logs?: string[];
  /** 动作结果：数组（搜索/目录）或对象（详情/音频） */
  data?: Object;
}

/** 一次书源动作的耗时与轮数（排查「为什么这么慢」） */
export interface BookRunStats {
  rounds: number;
  requests: number;
  elapsedMs: number;
}

/**
 * 从队列条目的 musicInfoJson 里还原出听书载荷
 *
 * 放在这里而不是放在书籍详情页：播放链路（PlaySession）也要用它，
 * 让 core 层去 import views 层会绕成环。
 */
export function parseBookPayload(musicInfoJson: string): BookPlayPayload | null {
  if (musicInfoJson.length === 0) {
    return null;
  }
  try {
    const payload: BookPlayPayload = JSON.parse(musicInfoJson) as BookPlayPayload;
    if (payload === null || payload === undefined) {
      return null;
    }
    if (payload.sourceId === undefined || payload.sourceId === null) {
      return null;
    }
    return payload;
  } catch (e) {
    return null;
  }
}

/** 书架里的书 id：与 BookHit.id 同一套口径（`来源id:书地址`） */
export function bookShelfId(payload: BookPlayPayload): string {
  return `${payload.sourceId}:${payload.bookUrl}`;
}
