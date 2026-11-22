import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo } from './MusicSearch';
import { SupportedSource } from '../source/LxTypes';
import { SourceEngine } from '../source/SourceEngine';
import { EXTEND_QUALITY_LABELS, EXTEND_QUALITYS, MAIN_QUALITY_LABELS, MAIN_QUALITYS, PlaySettings } from '../settings/PlaySettings';

const DOMAIN: number = 0x0001;
const TAG: string = 'Quality';

/**
 * 播放音质协商
 *
 * 抽出来单独放一个模块的原因：播放链路（PlaySession）和下载链路（DownloadManager）
 * 都要「按设置里选的音质挑一个这首歌 + 这个源都支持的档」，两边必须用同一套规则，
 * 否则会出现「在线放的是 320k、下载下来却是 128k」这种事。
 *
 * 只吃基本类型（musicInfoJson / source / fallback），不吃 SongItem —— 这样调用方
 * 不必为了传个歌曲对象而互相 import，不会绕出模块循环。
 */

/** 主音质从高到低（用户选的那档不可用时按这个顺序往下退） */
const MAIN_ORDER: string[] = ['flac24bit', 'flac', '320k', '128k'];

/** 拓展音质档（多数平台要会员）：解析失败时会退回普通音质，见 fallbackQuality */
const EXTENDED_ORDER: string[] = ['hires', 'atmos', 'atmos_plus', 'master'];

/**
 * 曲目元数据里**会**带拓展档的平台（网易云）
 *
 * 网易把母带 / 沉浸声 / 杜比全景声报在 `privilege.maxBrLevel` 上（jymaster / sky / dolby），
 * 所以对网易来说「这首歌的 `_types` 里有没有这一档」是可信的，按曲目判断能少一次必然失败的请求。
 *
 * 其余平台（QQ 音乐最典型）**报不出来**：QQ 的搜索 / 歌单接口 `file` 里只有
 * size_128mp3 / size_320mp3 / size_flac / size_hires（外加 size_dolby / size_ape / size_360ra
 * 这些和本工程的档位对不上的字段），根本没有母带、全景声的位置 —— 一首歌有没有母带，
 * 曲目数据看不出来，只有音源（也就是源后端）知道。
 *
 * 落雪那边同样是这个口径：音质档位由**音源声明的 qualitys** 决定，不看曲目元数据。
 * 所以这些平台一律以「音源声明支持」为准，取不到链接时照旧走 fallbackQuality 降档，
 * 不会把能放的歌变成放不了。
 */
const METADATA_EXTENDED_PLATFORMS: string[] = ['wy'];

/** 这个平台的拓展音质档是否只能由音源声明来判断（曲目元数据里没有这些档） */
function extendedBySourceOnly(source: string): boolean {
  return !METADATA_EXTENDED_PLATFORMS.includes(source);
}

/**
 * 这一档能不能用
 *
 * 普通档：曲目数据里有就算能用（元数据对普通档一直是准的）。
 * 拓展档：曲目数据里有，或者「这个平台报不出拓展档 + 音源声明了支持这一档」。
 */
function qualityUsable(quality: string, available: string[], supported: string[], sourceOnlyExtend: boolean): boolean {
  if (supported.length > 0 && !supported.includes(quality)) {
    return false;
  }
  if (available.includes(quality)) {
    return true;
  }
  return sourceOnlyExtend && supported.length > 0 && EXTENDED_ORDER.includes(quality);
}

/**
 * 本地音乐 / 云端音乐在 K_CURRENT_QUALITY 里不是音质档，而是这两个标记
 * （见 LocalMusic 造条目、WebDavTypes 的 WEBDAV_QUALITY）：它们的音质由文件本身决定，
 * 没有档可切。
 */
export const LOCAL_QUALITY_MARK: string = 'local';
export const CLOUD_QUALITY_MARK: string = 'webdav';

/**
 * 完整音质阶梯（从高到低）：拓展档在上，普通档在下
 *
 * 顺序取自「拓展档高于 24Bit，24Bit 高于 FLAC…」这一条产品口径，
 * 与 {@link MAIN_ORDER} / {@link EXTENDED_ORDER} 是同一套档位，只是排成一条可逐级下退的梯子。
 * 除了 {@link lowerQuality} 逐级下退，{@link qualityFallbackNote} 也用它判断
 * 「实际档位是不是真的比目标档低」——两处必须用同一份顺序，所以提到文件靠上的位置。
 */
const QUALITY_LADDER: string[] = [
  'master', 'atmos_plus', 'atmos', 'hires', 'flac24bit', 'flac', '320k', '128k',
];

/**
 * 本次**实际生效**的音质档（AppStorage key）
 *
 * 为什么要跟 `K_CURRENT_QUALITY` 分开：
 *   - `K_CURRENT_QUALITY`（PlaySession 里那个）是「这一次按哪一档去要地址」，
 *     它在解析**开始之前**就写进去了 —— 本质上是**目标档**：可能因为音源没声明、
 *     会员没权限、换源、容器解不了而降档，真正放出声的那一档更低；
 *   - 这里是「地址真的拿到了、播放器真的在放」的那一档，只在解析成功 / 降档成功 /
 *     改走本地缓存这些**落定**的时刻写。
 * 界面按它显示，才不会出现「设置里选了母带、其实在放 FLAC」的困惑
 * （群反馈 2026-11-18 22:07、11-19 09:28 / 15:24）。
 *
 * 取值口径与 `K_CURRENT_QUALITY` 完全一致：真档位字符串，或 local / webdav 标记。
 * 空串 = 这一首还没解析出结果（界面退回当前档显示，不要显示成空白）。
 */
export const K_ACTUAL_QUALITY: string = 'ps_actual_quality';

/**
 * 用户设置里的「目标档位」
 *
 * 开了拓展音质就是选的那一档（母带 / 全景声+ …），否则是「播放音质」那档。
 * 它是**设置项**的当前值，与正在放的那一首无关（每首歌能协商到的档不一样）。
 */
export function targetQuality(): string {
  const settings = PlaySettings.getInstance();
  return settings.isExtendQuality() ? settings.getExtendQualityType() : settings.getQuality();
}

/**
 * 界面上该显示的那一档
 *
 * 实际生效的优先；还没解析出来（空串，比如刚切歌、还在取地址）时退回当前档，
 * 免得音质钮在一瞬间变成空白。
 */
export function displayQuality(actual: string, current: string): string {
  return actual.length > 0 ? actual : current;
}

/**
 * 「实际档位低于用户设置的目标档位」时的一句轻提示，例如「源不支持 母带」
 *
 * 什么时候返回空串（也就是不提示）：
 *   - 实际 / 目标有一个还没确定；
 *   - 两者相同；
 *   - 本地 / 云端文件（音质由文件本身决定，谈不上「支不支持」）；
 *   - 认不出的档，或实际并不比目标低（用户自己往下切过档，设置已经跟着改了）。
 *
 * 只作为**面板里的一行小字**用：降档本身不弹 toast（那是骚扰），用户主动点开
 * 音质面板时才解释一句就够。
 */
export function qualityFallbackNote(actual: string, target: string): string {
  if (actual.length === 0 || target.length === 0 || actual === target) {
    return '';
  }
  if (isFileQuality(actual) || isFileQuality(target)) {
    return '';
  }
  const actualIndex: number = QUALITY_LADDER.indexOf(actual);
  const targetIndex: number = QUALITY_LADDER.indexOf(target);
  if (actualIndex < 0 || targetIndex < 0 || actualIndex <= targetIndex) {
    return '';
  }
  return `源不支持 ${qualityLabel(target)}`;
}

export function isExtendedQuality(quality: string): boolean {
  return EXTENDED_ORDER.includes(quality);
}

/** 这一档是「本地 / 云端文件」那种标记（不是真的音质档） */
export function isFileQuality(quality: string): boolean {
  return quality === LOCAL_QUALITY_MARK || quality === CLOUD_QUALITY_MARK;
}

/**
 * 音质档 -> 界面上的短标签
 *
 * 128K / 320K / FLAC / 24Bit，拓展档是 Hi-Res / 全景声 / 全景声+ / 母带，
 * 本地与云端那两个标记也一并认（播放页那颗音质钮要显示它们）。
 * 认不出来的档原样返回：宁可显示一个原始字符串，也不要显示成空白。
 */
export function qualityLabel(quality: string): string {
  if (quality === LOCAL_QUALITY_MARK) {
    return '本地';
  }
  if (quality === CLOUD_QUALITY_MARK) {
    return '云端';
  }
  const main: number = MAIN_QUALITYS.indexOf(quality);
  if (main >= 0) {
    return MAIN_QUALITY_LABELS[main];
  }
  const extend: number = EXTEND_QUALITYS.indexOf(quality);
  if (extend >= 0) {
    return EXTEND_QUALITY_LABELS[extend];
  }
  return quality;
}

/**
 * 当前这首歌**可以切换过去**的音质档，从高到低
 *
 * = 「这首歌提供了这一档」（musicInfo 的 `_types`）∩「音源声明支持这一档」。
 * 平台报不出拓展档时（QQ 音乐等，见 extendedBySourceOnly）拓展档只看音源声明 ——
 * 否则 QQ 的母带永远列不出来，源给得了也只能干瞪眼。
 * 拓展档（母带 / 全景声…）只在「设置 - 播放设置」里开了拓展音质时才列进来 ——
 * 没开的时候选它只会解析失败，与其让用户点了没反应，不如不列。
 *
 * 返回空数组表示**没有可切的档**：本地 / 云端文件（音质由文件本身决定）、
 * 还没有 musicInfo 的歌、以及只在旧档上待着的歌。调用方据此决定是给一份列表
 * 还是一句说明。
 *
 * 注意「正在放的那一档」不一定在这个列表里：协商有放宽的余地（源没声明音质列表时
 * 会先用平台给的档），此时它只是「当前」，不是「可选」——界面上单独显示当前值即可。
 */
export function switchableQualitys(musicInfoJson: string, source: string, current: string): string[] {
  if (musicInfoJson.length === 0 || isFileQuality(current)) {
    return [];
  }
  const available: string[] = availableQualitys(musicInfoJson);
  if (available.length === 0) {
    return [];
  }
  const supported: string[] = sourceQualitys(source);
  const extendOn: boolean = PlaySettings.getInstance().isExtendQuality();
  const sourceOnlyExtend: boolean = extendOn && extendedBySourceOnly(source);
  // 候选顺序：拓展档（高 -> 低）在前，普通档（高 -> 低）在后，与面板里从上到下的顺序一致
  const order: string[] = [];
  if (extendOn) {
    for (let i = EXTENDED_ORDER.length - 1; i >= 0; i--) {
      order.push(EXTENDED_ORDER[i]);
    }
  }
  for (const quality of MAIN_ORDER) {
    order.push(quality);
  }
  const out: string[] = [];
  for (const quality of order) {
    if (qualityUsable(quality, available, supported, sourceOnlyExtend)) {
      out.push(quality);
    }
  }
  hilog.info(DOMAIN, TAG, 'switchable %{public}s: [%{public}s] available=[%{public}s] supported=[%{public}s]',
    source, out.join(','), available.join(','), supported.join(','));
  return out;
}

/** 这首歌自带的音质档（搜索结果 / 同步回来的 _types） */
export function availableQualitys(musicInfoJson: string): string[] {
  if (musicInfoJson.length === 0) {
    return [];
  }
  try {
    const info: LxMusicInfo = JSON.parse(musicInfoJson) as LxMusicInfo;
    if (info._types === undefined) {
      return [];
    }
    return Object.keys(info._types);
  } catch (e) {
    return [];
  }
}

/** 当前音源为这个平台声明支持的音质档（源没说就是空数组，表示不限制） */
export function sourceQualitys(source: string): string[] {
  const map: Record<string, SupportedSource> = SourceEngine.getInstance().getSupportedSources();
  const sourceInfo: SupportedSource | undefined = map[source];
  return sourceInfo === undefined ? [] : sourceInfo.qualitys;
}

/**
 * 挑音质
 *
 * 候选顺序来自「设置 - 播放设置」：先在拓展音质（开了的话，从用户选的那档往下）里找，
 * 再在普通音质（同样从用户选的那档往下）里找。每一档都要求「这首歌提供该档」且
 * 「音源声明支持该档」——直接用用户选的高档去问不支持它的源，源会解析失败。
 * 例外是拓展档：平台元数据报不出来时（见 extendedBySourceOnly）只要求音源声明支持，
 * 拿不到链接再靠 fallbackQuality 降档。
 * 信息不足（没有 musicInfo）时返回 fallback（调用方给的原音质）。
 */
export function pickQuality(musicInfoJson: string, source: string, fallback: string): string {
  const available: string[] = availableQualitys(musicInfoJson);
  if (available.length === 0) {
    return fallback;
  }
  const supported: string[] = sourceQualitys(source);
  const candidates: string[] = PlaySettings.getInstance().qualityCandidates();
  const sourceOnlyExtend: boolean = PlaySettings.getInstance().isExtendQuality() && extendedBySourceOnly(source);
  for (const quality of candidates) {
    if (qualityUsable(quality, available, supported, sourceOnlyExtend)) {
      hilog.info(DOMAIN, TAG, 'pick %{public}s -> %{public}s (available=[%{public}s] supported=[%{public}s])',
        source, quality, available.join(','), supported.join(','));
      return quality;
    }
  }
  // 源没声明音质列表时放宽一档：能用平台给的数据就先用了
  if (supported.length === 0) {
    for (const quality of candidates) {
      if (available.includes(quality)) {
        return quality;
      }
    }
  }
  for (const quality of MAIN_ORDER) {
    if (available.includes(quality) && (supported.length === 0 || supported.includes(quality))) {
      return quality;
    }
  }
  for (const quality of MAIN_ORDER) {
    if (available.includes(quality)) {
      return quality;
    }
  }
  return fallback;
}

/**
 * 拓展音质解析失败时的退路：回到「播放音质」选的那档往下找第一个能用的档。
 *
 * 协商阶段只能判断「这首歌/这个源有没有这一档」，判断不了「这个账号有没有会员」：
 * 母带、全景声这类拿不到链接是常态，所以真失败时再退一次，别让开了拓展音质
 * 变成有几首歌直接放不了。返回空串表示没有再试的意义（本来用的就是普通音质）。
 */
export function fallbackQuality(musicInfoJson: string, source: string, used: string): string {
  if (!isExtendedQuality(used)) {
    return '';
  }
  const available: string[] = availableQualitys(musicInfoJson);
  const supported: string[] = sourceQualitys(source);
  for (const quality of PlaySettings.getInstance().mainQualityCandidates()) {
    if (available.includes(quality) && (supported.length === 0 || supported.includes(quality))) {
      return quality;
    }
  }
  return '';
}

/**
 * 降一档：返回**严格低于** `used`、且「这首歌 + 这个源」能用的第一个档；没有就返回空串
 *
 * 与 {@link fallbackQuality} 的分工：
 *   - `fallbackQuality` 只处理「拓展档 → 普通档」这一跳（母带没权限时的退路）；
 *   - 这里处理**逐级下退**，普通档之间也能降（flac24bit → flac → 320k → 128k）。
 *
 * 为什么需要它（2026-11-19 真机反馈）：播放失败不只有「源拿不到链接」，还有
 * 「链接拿到了、但播放器解不了这个容器」——实机报错是
 * `Unsupported Format: CONTAINER_ERR-unsupport interface, unsupport container format type`。
 * 这种情况**换源常常拿到同一种格式**（同一个后端同一批转码产物），降一档才是有意义的下一步；
 * 用户原话也是「它不会自动降音质，所以无法播放」「这个回退没成功」。
 */
export function lowerQuality(musicInfoJson: string, source: string, used: string): string {
  const from: number = QUALITY_LADDER.indexOf(used);
  if (from < 0) {
    return '';
  }
  const available: string[] = availableQualitys(musicInfoJson);
  const supported: string[] = sourceQualitys(source);
  const extendOn: boolean = PlaySettings.getInstance().isExtendQuality();
  const sourceOnlyExtend: boolean = extendOn && extendedBySourceOnly(source);
  for (let i = from + 1; i < QUALITY_LADDER.length; i++) {
    const quality: string = QUALITY_LADDER[i];
    // 用户没开拓展音质时，别再往拓展档上退（往下退也不会经过它们，这里只是兜底）
    if (!extendOn && EXTENDED_ORDER.includes(quality)) {
      continue;
    }
    if (qualityUsable(quality, available, supported, sourceOnlyExtend)) {
      return quality;
    }
  }
  return '';
}
