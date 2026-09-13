/**
 * 洛雪音乐自定义音源 —— 类型定义
 *
 * 这里的结构对齐 lx-music-mobile 的 LX.UserApi.* / LX.Music.* 定义，
 * 便于直接复用官方音源脚本（源规则）。
 */

/** 音质，对应洛雪 LX.Quality */
export type LxQuality = '128k' | '320k' | 'flac' | 'flac24bit';

/** 源脚本头部注释里声明的元信息（@name / @description / @version / @author / @homepage） */
export interface SourceMeta {
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
}

/** 已导入的音源 */
export interface SourceInfo extends SourceMeta {
  id: string;
  allowShowUpdateAlert: boolean;
  importedAt: number;
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
