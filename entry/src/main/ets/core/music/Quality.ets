import { LxMusicInfo } from './MusicSearch';
import { SupportedSource } from '../source/LxTypes';
import { SourceEngine } from '../source/SourceEngine';
import { EXTEND_QUALITY_LABELS, EXTEND_QUALITYS, MAIN_QUALITY_LABELS, MAIN_QUALITYS, PlaySettings } from '../settings/PlaySettings';

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
 * 本地音乐 / 云端音乐在 K_CURRENT_QUALITY 里不是音质档，而是这两个标记
 * （见 LocalMusic 造条目、WebDavTypes 的 WEBDAV_QUALITY）：它们的音质由文件本身决定，
 * 没有档可切。
 */
export const LOCAL_QUALITY_MARK: string = 'local';
export const CLOUD_QUALITY_MARK: string = 'webdav';

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
  // 候选顺序：拓展档（高 -> 低）在前，普通档（高 -> 低）在后，与面板里从上到下的顺序一致
  const order: string[] = [];
  if (PlaySettings.getInstance().isExtendQuality()) {
    for (let i = EXTENDED_ORDER.length - 1; i >= 0; i--) {
      order.push(EXTENDED_ORDER[i]);
    }
  }
  for (const quality of MAIN_ORDER) {
    order.push(quality);
  }
  const out: string[] = [];
  for (const quality of order) {
    if (available.includes(quality) && (supported.length === 0 || supported.includes(quality))) {
      out.push(quality);
    }
  }
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
 * 信息不足（没有 musicInfo）时返回 fallback（调用方给的原音质）。
 */
export function pickQuality(musicInfoJson: string, source: string, fallback: string): string {
  const available: string[] = availableQualitys(musicInfoJson);
  if (available.length === 0) {
    return fallback;
  }
  const supported: string[] = sourceQualitys(source);
  const candidates: string[] = PlaySettings.getInstance().qualityCandidates();
  for (const quality of candidates) {
    if (available.includes(quality) && (supported.length === 0 || supported.includes(quality))) {
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
