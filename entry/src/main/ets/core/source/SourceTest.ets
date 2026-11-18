import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SourceEngine } from './SourceEngine';
import { ImportResolveTestResult, LxQuality, ResolveResult, SourceInfo, SourceLog, SupportedSource } from './LxTypes';
import { parseSourceMeta, sourceMetaKey } from './LxMetadata';
import { LxMusicInfo, SEARCH_PLATFORMS, isSearchSupported, pickQuality, searchMusic } from '../music/MusicSearch';
import { AudioCache } from '../music/AudioCache';
import { MediaCache, mediaKeyOf } from '../music/MediaCache';

const DOMAIN: number = 0x0001;
const TAG: string = 'SourceTest';

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

/** 示例源里写死的测试地址（见 rawfile/demo_source.js）：自检解析出来的就是它，必然 404 */
const DEMO_TEST_URL: string = 'https://example.com/test-audio.mp3';

/**
 * 示例源声明的音质档（见 demo_source.js 的 qualitys）。
 *
 * 自检本身只用 128k 解析，但示例源生效期间点播放时，同一个固定地址可能被写到
 * 别的档上（播放页切档 / 按音乐信息协商出 320k），所以这几档一起清。
 */
const SELF_TEST_QUALITIES: string[] = ['128k', '320k', 'flac', 'flac24bit'];

/** 示例歌曲的缓存 key（`kw_demo_songmid_0001`）：只有它名下的音频文件可以放心按 key 删 */
const DEMO_CACHE_KEY: string = mediaKeyOf(DEFAULT_MUSIC_INFO_JSON);

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
 * 清掉自检留在播放缓存里的痕迹
 *
 * 键的算法与播放侧完全一致（见 PlaySession 的 `mediaKeyOf(item.musicInfoJson)`）：
 *   地址表  MediaCache 里是 `<平台>_<songmid>[_<hash>]_<音质>`（quality 由 MediaCache 自己拼）
 *   音频文件 AudioCache 里是 `<key>_<音质>.<后缀>`
 * 这里不自己拼路径，一律走 MediaCache.getMusicUrl / AudioCache.localPath 找、再按官方
 * 删除接口删（dropMusicUrl / dropPath），否则路径或命名一变就会留下孤儿文件。
 *
 * 为什么要清：示例源的地址是写死的 https://example.com/test-audio.mp3，命中它必然 404。
 * 自检本身只解析、不写缓存，但历史上自检后「当前音源」变成了示例源，用户随手点一首
 * 播放就会把这个 404 地址写进 MediaCache（音频缓存的 key 也随之出现）。不清掉的话，
 * 即使音源已修好，第一次播仍会先命中坏缓存报一次错，重试才成功。
 *
 * @param musicInfoJson 自检用的 musicInfo
 * @param resolvedUrl   本次自检解析出来的地址（解析失败传空串）
 * @returns 清掉的缓存条目数（地址条目 + 音频文件条目）
 */
function purgeSelfTestCache(musicInfoJson: string, resolvedUrl: string): number {
  const key: string = mediaKeyOf(musicInfoJson);
  if (key.length === 0) {
    return 0;
  }
  const isDemoKey: boolean = key === DEMO_CACHE_KEY;
  const media: MediaCache = MediaCache.getInstance();
  const audio: AudioCache = AudioCache.getInstance();
  let removed: number = 0;
  for (const quality of SELF_TEST_QUALITIES) {
    // 地址条目：只删「确实是示例地址」的那条。同一个 key 上如果存的是正常地址
    // （换源 / 正常播放写下的），不能因为跑了一次自检就把它丢掉
    const cached: string = media.getMusicUrl(key, quality);
    if (cached.length > 0 && (cached === resolvedUrl || cached === DEMO_TEST_URL)) {
      media.dropMusicUrl(key, quality);
      removed++;
    }
    // 音频文件：只有示例歌曲这个 key（songmid 固定 demo_songmid_0001）能按 key 删 ——
    // 音频缓存条目里看不到地址，换成别的 musicInfo 时按 key 删会误伤真实歌曲的缓存
    if (isDemoKey) {
      const local: string = audio.localPath(key, quality);
      if (local.length > 0) {
        audio.dropPath(local);
        removed++;
      }
    }
  }
  return removed;
}

/**
 * 离线自检：内置示例源 + 默认 musicInfo，不依赖外部网络。
 * 成功时 resolve 出示例源里写死的测试地址，证明整条链路可用。
 *
 * 隔离：示例源的播放地址是写死的 https://example.com/test-audio.mp3，它绝不能变成
 * 「当前音源」——否则之后所有播放 404，且 loadSource 会把 active_source.json 写成
 * 示例源，重启后自动恢复的还是它。所以这里先快照自检前正在用的音源（id + 沙箱环境 +
 * 已有音源列表），结束后原样还原，并顺手把示例地址 / 示例歌曲留在缓存里的条目清掉。
 */
export async function runOfflineSelfTest(context: common.Context, musicInfoJson?: string): Promise<ImportResolveTestResult> {
  const engine = SourceEngine.getInstance();
  // 快照：恢复时要按同一个 env 重新初始化；knownIds 用来判断示例源是不是本次新导入的
  const previousId: string = engine.getLoadedSourceId();
  const previousEnv: string = engine.getSandboxEnv();
  const knownIds: string[] = engine.listSources().map((item: SourceInfo) => item.id);
  const json: string = musicInfoJson !== undefined ? musicInfoJson : DEFAULT_MUSIC_INFO_JSON;
  // 读到脚本之后才真的会改沙箱状态：读之前抛错（预览器 mock rawfile）不必还原
  let touched: boolean = false;
  // 自检前正在用的源如果本身就是示例源（老版本自检留下的现场），不能把它当成要还原的
  // 目标：那等于把用户继续钉在一个只会返回 404 地址的音源上，自检等于没修
  let previousIsDemo: boolean = false;
  let demoId: string = '';
  /** 内置示例源的身份键（名字+版本+作者）：finally 里清「历史残留条目」也用它 */
  let demoKey: string = '';
  let resolvedUrl: string = '';
  try {
    const script: string = readBundledDemoScript(context);
    touched = true;
    // 身份用「名字+版本+作者」（与导入去重同一个键）判断，不看 id：id 是随机生成的
    demoKey = sourceMetaKey(parseSourceMeta(script));
    for (const item of engine.listSources()) {
      if (item.id === previousId) {
        previousIsDemo = sourceMetaKey(item) === demoKey;
      }
    }
    const result: ImportResolveTestResult = await doImportAndResolve(script, json, '128k', 'kw');
    if (result.source !== null) {
      demoId = result.source.id;
    }
    if (result.resolve !== null) {
      resolvedUrl = result.resolve.url;
    }
    return result;
  } finally {
    if (touched) {
      try {
        purgeSelfTestCache(json, resolvedUrl);
      } catch (e) {
        // 清理失败不能连带把「还原音源」也跳过：坏缓存还有播放侧兜底
        // （PlaySession 命中缓存地址失败时会丢弃并重试，见其 error 分支），
        // 而「当前音源被换成示例源 / last-active 被写成示例源」才是致命的
        hilog.warn(DOMAIN, TAG, 'purge self-test cache failed: %{public}s', JSON.stringify(e));
      }
      // 无论自检成功还是失败都要还原：失败路径同样已经导入/加载过示例源。
      // previousIsDemo 时传空 id，按「自检前没有音源」还原（清现场 + 删 last-active）
      await engine.restoreSourceSnapshot(previousIsDemo ? '' : previousId, previousEnv);
      // 删掉示例源这条记录：本次新导入的，或者自检前就残留的（previousIsDemo）。
      // 自检前就在、但身份不是示例源的（重复导入命中别的同名脚本）保持原样
      if (demoId.length > 0 && (previousIsDemo || !knownIds.includes(demoId))) {
        try {
          engine.removeSource(demoId);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'remove demo source failed: %{public}s', JSON.stringify(e));
        }
      }
      // 顺带清掉**历史残留**的示例源条目：老版本的自检会把内置示例源写进音源列表，
      // 之后它就一直躺在那里制造噪音（真机实测：列表里留着一条 v1.0.0 的「示例音源」）。
      // 身份键与内置脚本一致 ⇒ 只可能是内置示例源，不会是用户自己的源；正在用的那个跳过。
      if (demoKey.length > 0) {
        const listed: SourceInfo[] = engine.listSources();
        for (const item of listed) {
          if (item.id === previousId || sourceMetaKey(item) !== demoKey) {
            continue;
          }
          try {
            engine.removeSource(item.id);
            hilog.info(DOMAIN, TAG, '已清理历史残留的示例音源：%{public}s', item.id);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, '清理残留示例音源失败：%{public}s', JSON.stringify(e));
          }
        }
      }
    }
  }
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
