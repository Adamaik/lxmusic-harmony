import { LxMusicInfo } from './MusicSearch';
import { SupportedSource } from '../source/LxTypes';
import { SourceEngine } from '../source/SourceEngine';
import { PlaySettings } from '../settings/PlaySettings';

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

export function isExtendedQuality(quality: string): boolean {
  return EXTENDED_ORDER.includes(quality);
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
