/**
 * 洛雪音乐自定义音源 —— 类型定义
 *
 * 这里的结构对齐 lx-music-mobile 的 LX.UserApi.* / LX.Music.* 定义，
 * 便于直接复用官方音源脚本（源规则）。
 */

/**
 * 音质，对应洛雪 LX.Quality
 *
 * 前四档是普通音质，后四档是拓展音质（Hi-Res / 全景声 / 全景声+ / 母带）：
 * 设置里的「拓展音质」用的就是这四个值，音源声明了、并且用户开了开关才会被协商到。
 * 早先这里只写了前四档，音源传上来的拓展档类型上就对不上（见 DEFECTS D-013）。
 */
export type LxQuality = '128k' | '320k' | 'flac' | 'flac24bit' | 'hires' | 'atmos' | 'atmos_plus' | 'master';

/** 源脚本头部注释里声明的元信息（@name / @description / @version / @author / @homepage / @updateUrl） */
export interface SourceMeta {
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
  /**
   * 脚本自己声明的更新地址
   *
   * 洛雪官方头部字段里**没有**这一项（见 LxMetadata 的说明），但有一部分第三方源会在
   * 头部额外写 `@updateUrl https://.../latest.js`，也有源只在运行时通过
   * `lx.send('showUpdateAlert', { updateUrl })` 报一次。两处都收进这个字段，
   * 「检查更新」才有地址可拉（见 SourceCheckup）。
   */
  updateUrl: string;
}

/** 已导入的音源 */
export interface SourceInfo extends SourceMeta {
  id: string;
  allowShowUpdateAlert: boolean;
  importedAt: number;
  /**
   * 已被用户停用
   *
   * 停用只影响「能不能被自动选中」：`SourceEngine.listSources()` 只返回启用的源，
   * 播放/下载的换源候选自然就不含它；脚本正文、设置页里的条目都照旧保留，
   * 想用回来点一下「启用」即可（见 SourceSettingsView 的失效源快捷操作）。
   */
  disabled?: boolean;
}

/** 源脚本在 lx.send('inited') 中声明的单个平台能力 */
export interface SupportedSource {
  type: string;
  actions: string[];
  qualitys: string[];
}

/** 源脚本初始化结果 */
export interface SourceInitResult {
  sources: Record<string, SupportedSource>;
}

/** 沙箱 bootstrapping 时传给 lx_preload.js 的参数 */
export interface LxBootstrap {
  key: string;
  rawScript: string;
  meta: SourceMeta;
  /** 沙箱内 lx.env 的取值：'mobile'（默认）或 'desktop'（兼容桌面版源） */
  env: string;
}

/** lxBridge.postMessage('init', data) 的数据 */
export interface BridgeInitData {
  status: boolean;
  errorMessage?: string;
  info?: SourceInitResult | null;
}

/** lxBridge.postMessage('scriptError', data) 的数据 */
export interface ScriptErrorData {
  message?: string;
}

/** lxBridge.postMessage('showUpdateAlert', data) 的数据 */
export interface UpdateAlertData {
  name?: string;
  log?: string;
  updateUrl?: string;
}

/** musicUrl / lyric 返回的 result.data */
export interface BridgeResultData {
  type?: string;
  url?: string;
  lyric?: string;
  tlyric?: string;
  rlyric?: string;
  lxlyric?: string;
}

/** pic 返回的 result.data 是裸字符串，用单独的接口承接 */
export interface BridgePicResultData {
  source: string;
  action: string;
  data: string;
}

export interface BridgeResult {
  source: string;
  action: string;
  data: BridgeResultData;
}

/** lxBridge.postMessage('response', data) 的数据 */
export interface BridgeResponseData {
  requestKey: string;
  status: boolean;
  errorMessage?: string;
  result?: BridgeResult;
}

/** 一条源脚本日志 */
export interface SourceLog {
  time: number;
  type: string;
  message: string;
  /**
   * 该不该打断用户（弹提示条）。缺省 false，只进日志面板（音源设置里能看到）。
   *
   * 引擎的日志流大部分是自检与回退过程的留痕：「源脚本执行返回了个值」「这个接口
   * 404 了」「没注册 handler，改用 ArrayBuffer 注入重试」……它们的共同点是
   * **事情还在往下走**——脚本重试通了、音源换了、界面照样能浏览。按 type 把 warn/error
   * 全弹出来，一进应用就是一串提示条，用户记住的全是「又坏了」。
   *
   * 所以是否打断不由日志级别推断，而由写日志的地方显式声明：真正「用户必须做点什么」
   * 的（如音源有更新提示）才置 true。
   */
  alert?: boolean;
  /**
   * 完整原文（不裁剪）。
   *
   * `message` 是给面板那一行用的摘要：日志面板只有一行宽，正文/脚本返回值一律先裁到
   * 200~300 字符再入面板，否则一行就能占满整块卡片。可是"看不到全文"正是用户报的问题：
   * 音源返回 HTML 错误页、脚本返回一个几 KB 的 JSON 时，摘要里那 200 字符往往正好差在
   * 出错字段上。所以入面板的裁剪版留在 `message`，原文额外存一份在这里，
   * 只给「日志详情」和「复制全部日志」用 —— 面板的观感因此完全不变。
   *
   * 没有裁剪过的日志不需要重复存一份，缺省即等于 `message`。
   */
  full?: string;
}

/** 解析播放链接的结果，供测试方法使用 */
export interface ResolveResult {
  ok: boolean;
  url: string;
  sourceId: string;
  quality: LxQuality;
  elapsedMs: number;
  error: string;
}

/** 导入并解析的完整测试结果 */
export interface ImportResolveTestResult {
  ok: boolean
  source: SourceInfo | null;
  supported: Record<string, SupportedSource>;
  resolve: ResolveResult | null;
  logs: SourceLog[];
  error: string;
}
