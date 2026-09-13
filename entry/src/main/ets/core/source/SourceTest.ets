import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { SourceEngine } from './SourceEngine';
import { ImportResolveTestResult, LxQuality, ResolveResult, SourceInfo, SourceLog, SupportedSource } from './LxTypes';
import { LxMusicInfo, SEARCH_PLATFORMS, isSearchSupported, pickQuality, searchMusic } from '../music/MusicSearch';

/**
 * 音源引擎测试方法集合
 *
 * 两个层次：
 *   1) 离线自检 runOfflineSelfTest()：用工程内置的 demo_source.js（不访问网络），
 *      验证「导入 -> 初始化 -> 解析播放链接」整条链路，可在无网络环境跑通。
 *   2) 真实音源 runImportAndResolveTest(sourceUrl)：通过链接导入真实音源，
 *      再用给定的 musicInfo 解析出真实播放链接。
 */

/** musicInfo 中我们关心的字段 */
interface MusicInfoLite {
  source?: string;
  name?: string;
  singer?: string;
}

interface DemoQualityInfo {
  type: string;
  size: string;
}

/** 测试用 musicInfo（洛雪旧版结构，与源脚本 request.info.musicInfo 一致） */
interface DemoMusicInfo {
  name: string;
  singer: string;
  source: string;
  songmid: string;
  interval: string;
  albumName: string;
  img: string;
  albumId: string;
  types: DemoQualityInfo[];
  _types: Record<string, DemoQualityInfo>;
  meta: Record<string, string>;
}

export const DEFAULT_MUSIC_INFO_JSON: string = JSON.stringify({
  name: '示例歌曲',
  singer: '示例歌手',
  source: 'kw',
  songmid: 'demo_songmid_0001',
  interval: '03:45',
  albumName: '示例专辑',
  img: '',
  albumId: 'demo_album_0001',
  types: [{ type: '128k', size: '3.5M' }, { type: '320k', size: '8.2M' }] as DemoQualityInfo[],
  _types: { '128k': { type: '128k', size: '3.5M' }, '320k': { type: '320k', size: '8.2M' } } as Record<string, DemoQualityInfo>,
  meta: { 'testUrl': 'https://example.com/test-audio.mp3' } as Record<string, string>,
} as DemoMusicInfo);

/** 构造一个测试用 musicInfo JSON */
export function buildMusicInfoJson(
  name: string,
  singer: string,
  source: string,
  songmid: string,
  extra?: Record<string, string>
): string {
  const obj: Record<string, Object> = {
    'name': name,
    'singer': singer,
    'source': source,
    'songmid': songmid,
    'interval': '',
    'albumName': '',
    'img': '',
    'albumId': '',
  };
  if (extra !== undefined) {
    obj['meta'] = extra;
  }
  return JSON.stringify(obj);
}

function readSourceFromMusicInfo(musicInfoJson: string): string {
  try {
    const obj = JSON.parse(musicInfoJson) as MusicInfoLite;
    return obj.source !== undefined ? obj.source : '';
  } catch (e) {
    return '';
  }
}

function readBundledDemoScript(context: common.Context): string {
  const decoder = util.TextDecoder.create('utf-8');
  const script: string = decoder.decodeToString(context.resourceManager.getRawFileContentSync('demo_source.js'));
  if (script.trim().length === 0) {
    throw new Error('内置示例源读取为空：当前环境（如 DevEco Previewer 预览器）mock 了 rawfile 读取，请在模拟器或真机上运行离线自检。');
  }
  return script;
}

/**
 * 离线自检：内置示例源 + 默认 musicInfo，不依赖外部网络。
 * 成功时 resolve 出示例源里写死的测试地址，证明整条链路可用。
 */
export async function runOfflineSelfTest(context: common.Context, musicInfoJson?: string): Promise<ImportResolveTestResult> {
  const script: string = readBundledDemoScript(context);
  const json: string = musicInfoJson !== undefined ? musicInfoJson : DEFAULT_MUSIC_INFO_JSON;
  return doImportAndResolve(script, json, '128k', 'kw');
}

/**
 * 通过链接导入真实音源并解析播放链接。
 *
 * @param sourceUrl    音源脚本的 http(s) 链接
 * @param musicInfoJson 目标音乐的旧版 musicInfo JSON
 * @param quality      目标音质，默认 128k
 * @param source       平台 id，缺省从 musicInfoJson.source 读取
 */
export async function runImportAndResolveTest(
  sourceUrl: string,
  musicInfoJson: string,
  quality?: LxQuality,
  source?: string
): Promise<ImportResolveTestResult> {
  const engine = SourceEngine.getInstance();
  engine.clearLogs();
  let info: SourceInfo | null = null;
  let supported: Record<string, SupportedSource> = {};
  try {
    info = await engine.importFromUrl(sourceUrl);
    supported = await engine.loadSource(info.id);
  } catch (e) {
    return {
      ok: false,
      source: info,
      supported: supported,
      resolve: null,
      logs: engine.getLogs(),
      error: (e as Error).message,
    };
  }
  const targetSource: string =
    source !== undefined ? source
      : (readSourceFromMusicInfo(musicInfoJson).length > 0 ? readSourceFromMusicInfo(musicInfoJson) : Object.keys(supported)[0]);
  const q: LxQuality = quality !== undefined ? quality : '128k';
  const resolve: ResolveResult = await doResolve(musicInfoJson, q, targetSource);
  return {
    ok: resolve.ok,
    source: info,
    supported: supported,
    resolve: resolve,
    logs: engine.getLogs(),
    error: resolve.error,
  };
}

/** 直接用一段源脚本文本做导入 + 解析 */
export async function runScriptImportAndResolveTest(
  script: string,
  musicInfoJson: string,
  quality?: LxQuality,
  source?: string
): Promise<ImportResolveTestResult> {
  return doImportAndResolve(script, musicInfoJson, quality !== undefined ? quality : '128k', source);
}

async function doImportAndResolve(
  script: string,
  musicInfoJson: string,
  quality: LxQuality,
  source?: string
): Promise<ImportResolveTestResult> {
  const engine = SourceEngine.getInstance();
  engine.clearLogs();
  let info: SourceInfo | null = null;
  let supported: Record<string, SupportedSource> = {};
  try {
    info = engine.importSource(script);
    supported = await engine.loadSource(info.id);
  } catch (e) {
    return {
      ok: false,
      source: info,
      supported: supported,
      resolve: null,
      logs: engine.getLogs(),
      error: (e as Error).message,
    };
  }
  const fromMusicInfo: string = readSourceFromMusicInfo(musicInfoJson);
  const targetSource: string =
    source !== undefined ? source : (fromMusicInfo.length > 0 ? fromMusicInfo : Object.keys(supported)[0]);
  const resolve: ResolveResult = await doResolve(musicInfoJson, quality, targetSource);
  return {
    ok: resolve.ok,
    source: info,
    supported: supported,
    resolve: resolve,
    logs: engine.getLogs(),
    error: resolve.error,
  };
}

async function doResolve(musicInfoJson: string, quality: LxQuality, source: string): Promise<ResolveResult> {
  const engine = SourceEngine.getInstance();
  const started: number = Date.now();
  try {
    const url: string = await engine.getMusicUrl(musicInfoJson, quality, source);
    return {
      ok: true,
      url: url,
      sourceId: source,
      quality: quality,
      elapsedMs: Date.now() - started,
      error: '',
    };
  } catch (e) {
    return {
      ok: false,
      url: '',
      sourceId: source,
      quality: quality,
      elapsedMs: Date.now() - started,
      error: (e as Error).message,
    };
  }
}

/** 把测试结果格式化成便于打印的文本 */
export function formatTestResult(result: ImportResolveTestResult): string {
  const lines: string[] = [];
  lines.push(`结果: ${result.ok ? '成功' : '失败'}`);
  if (result.source !== null) {
    lines.push(`音源: ${result.source.name} (${result.source.id}) v${result.source.version}`);
  }
  const platformKeys: string[] = Object.keys(result.supported);
  if (platformKeys.length > 0) {
    lines.push(`支持平台: ${platformKeys.join(', ')}`);
  }
  if (result.resolve !== null) {
    lines.push(`平台: ${result.resolve.sourceId} / 音质: ${result.resolve.quality} / 耗时: ${result.resolve.elapsedMs}ms`);
    lines.push(`播放链接: ${result.resolve.url.length > 0 ? result.resolve.url : '(空)'}`);
  }
  if (result.error.length > 0) {
    lines.push(`错误: ${result.error}`);
  }
  const recent: SourceLog[] = result.logs.slice(-10);
  for (const log of recent) {
    lines.push(`  [${log.type}] ${log.message}`);
  }
  return lines.join('\n');
}

/** 「通过链接导入源 -> 搜索音乐 -> 解析播放链接」的一站式测试结果 */
export interface SearchResolveTestResult {
  ok: boolean;
  source: SourceInfo | null;
  keyword: string;
  platform: string;
  /** 搜索到的结果数量 */
  total: number;
  first: LxMusicInfo | null;
  resolve: ResolveResult | null;
  error: string;
}

/**
 * 一站式测试：通过链接导入音源，搜索关键词，并对第一条结果解析播放链接。
 * 与页面上的操作流程完全一致，便于在代码里做端到端验证。
 *
 * @param sourceUrl 音源脚本链接
 * @param keyword   搜索关键词
 * @param platform  指定搜索平台（kw/kg/mg），缺省取音源支持的第一个可搜索平台
 * @param quality   期望音质，缺省 320k
 */
export async function runSearchAndResolveTest(
  sourceUrl: string,
  keyword: string,
  platform?: string,
  quality?: LxQuality,
): Promise<SearchResolveTestResult> {
  const engine = SourceEngine.getInstance();
  engine.clearLogs();
  let info: SourceInfo | null = null;
  let target: string = platform !== undefined ? platform : '';
  try {
    info = await engine.importFromUrl(sourceUrl);
    const supported: Record<string, SupportedSource> = await engine.loadSource(info.id);
    if (target.length === 0) {
      for (const key of Object.keys(supported)) {
        if (isSearchSupported(key)) {
          target = key;
          break;
        }
      }
    }
    if (target.length === 0) {
      return {
        ok: false,
        source: info,
        keyword: keyword,
        platform: '',
        total: 0,
        first: null,
        resolve: null,
        error: `音源未声明可搜索平台（可搜索：${SEARCH_PLATFORMS.join('/')}）`,
      };
    }
  } catch (e) {
    return {
      ok: false,
      source: info,
      keyword: keyword,
      platform: target,
      total: 0,
      first: null,
      resolve: null,
      error: (e as Error).message,
    };
  }

  let results: LxMusicInfo[] = [];
  try {
    results = await searchMusic(keyword, target, 1, 30);
  } catch (e) {
    return {
      ok: false,
      source: info,
      keyword: keyword,
      platform: target,
      total: 0,
      first: null,
      resolve: null,
      error: `搜索失败：${(e as Error).message}`,
    };
  }
  if (results.length === 0) {
    return {
      ok: false,
      source: info,
      keyword: keyword,
      platform: target,
      total: 0,
      first: null,
      resolve: null,
      error: '没有搜索到结果',
    };
  }

  const first: LxMusicInfo = results[0];
  const supportedMap: Record<string, SupportedSource> = engine.getSupportedSources();
  let supportedQualitys: string[] = [];
  for (const key of Object.keys(supportedMap)) {
    if (key === first.source) {
      supportedQualitys = supportedMap[key].qualitys;
    }
  }
  const q: string = pickQuality(quality !== undefined ? quality : '320k', supportedQualitys, first);
  const resolve: ResolveResult = await doResolve(JSON.stringify(first), q as LxQuality, first.source);
  return {
    ok: resolve.ok,
    source: info,
    keyword: keyword,
    platform: target,
    total: results.length,
    first: first,
    resolve: resolve,
    error: resolve.error,
  };
}

/** 格式化「搜索 + 解析」测试结果 */
export function formatSearchTestResult(result: SearchResolveTestResult): string {
  const lines: string[] = [];
  lines.push(`结果: ${result.ok ? '成功' : '失败'}`);
  if (result.source !== null) {
    lines.push(`音源: ${result.source.name} (${result.source.id})`);
  }
  lines.push(`关键词: ${result.keyword} / 平台: ${result.platform} / 命中: ${result.total}`);
  if (result.first !== null) {
    lines.push(`首条: ${result.first.name} - ${result.first.singer} (${result.first.albumName}) ${result.first.interval}`);
  }
  if (result.resolve !== null) {
    lines.push(`音质: ${result.resolve.quality} / 耗时: ${result.resolve.elapsedMs}ms`);
    lines.push(`播放链接: ${result.resolve.url.length > 0 ? result.resolve.url : '(空)'}`);
  }
  if (result.error.length > 0) {
    lines.push(`错误: ${result.error}`);
  }
  return lines.join('\n');
}
