import { LxMusicInfo, fetchMusicPic } from './MusicSearch';
import { MediaCache } from './MediaCache';
import { SourceEngine } from '../source/SourceEngine';

/**
 * 封面缓存 / 懒解析
 *
 * 搜索结果里 tx / wy / mg 自带封面，kw / kg 没有，要单独请求平台接口；
 * 有些源脚本自己实现了 `pic` action，则优先用源给的结果。取封面是网络请求，
 * 列表里几十行不可能同步拿，所以这里做「先返回已有/空、后台排队解析、
 * 好了一批就通知界面重画」：
 *
 *   coverFor(json, fallback)  同步取（没有就返回空并排进队列）
 *   request(json, onReady)    播放页用，解析好了回调一次
 *
 * 并发限制在 3，失败的不再重试（避免对同一批行反复发请求）。
 */

/** 封面版本号：每解析好一批 +1，界面订阅它来重画列表 */
export const K_COVER_VERSION: string = 'cover_version';

/** musicInfoJson 解析结果的缓存上限（满了挤掉最早的一批，而不是清空重来） */
const INFO_CACHE_MAX: number = 400;
const INFO_CACHE_DROP: number = 100;
/**
 * 待解析队列上限
 *
 * 列表里几百行同时问封面时，不设上限会把请求排成几百个，
 * 每个都要发网络请求（还可能走源脚本），堆久了进程扛不住。
 * 超出的直接不入队 —— 那一行先显示占位封面，列表重画时会再问一次。
 */
const QUEUE_MAX: number = 60;

interface CoverTask {
  key: string;
  musicInfoJson: string;
}

export class CoverStore {
  private static instance: CoverStore | null = null;

  static getInstance(): CoverStore {
    if (CoverStore.instance === null) {
      CoverStore.instance = new CoverStore();
    }
    return CoverStore.instance;
  }

  private cache: Map<string, string> = new Map();
  private failed: Set<string> = new Set();
  /** musicInfoJson -> 解析结果，避免列表重画时反复 parse */
  private infoCache: Map<string, LxMusicInfo> = new Map();
  /** 已入队 / 正在解析的 key，避免重复排队 */
  private pending: Set<string> = new Set();
  private waiters: Map<string, ((url: string) => void)[]> = new Map();
  private queue: CoverTask[] = [];
  private active: number = 0;
  private maxActive: number = 3;
  private flushTimer: number = 0;
  private keyOf(source: string, songmid: string): string {
    return `${source}_${songmid}`;
  }

  /** musicInfoJson 会很小但会被反复解析（列表每次重画都要问一次封面），这里缓存一下 */
  private infoOf(musicInfoJson: string): LxMusicInfo | null {
    if (musicInfoJson.length === 0) {
      return null;
    }
    const hit: LxMusicInfo | undefined = this.infoCache.get(musicInfoJson);
    if (hit !== undefined) {
      return hit;
    }
    try {
      const info: LxMusicInfo = JSON.parse(musicInfoJson) as LxMusicInfo;
      // 满了挤掉最早的一批：直接 clear 会让后面的条目反复重新解析（几百首的歌单上很明显）
      if (this.infoCache.size >= INFO_CACHE_MAX) {
        let drop: number = INFO_CACHE_DROP;
        for (const key of this.infoCache.keys()) {
          if (drop <= 0) {
            break;
          }
          this.infoCache.delete(key);
          drop--;
        }
      }
      this.infoCache.set(musicInfoJson, info);
      return info;
    } catch (e) {
      return null;
    }
  }

  /**
   * 列表行用：已经有封面就直接返回，没有就返回空串（占位封面）并把这首排进解析队列。
   * @param musicInfoJson 该条目的 musicInfo（演示条目为空串）
   * @param fallback      搜索结果里自带的封面（非空就直接用，不再请求）
   */
  coverFor(musicInfoJson: string, fallback: string): string {
    if (fallback.length > 0) {
      return fallback;
    }
    const info: LxMusicInfo | null = this.infoOf(musicInfoJson);
    if (info === null) {
      return '';
    }
    const key: string = this.keyOf(info.source, info.songmid);
    const hit: string | undefined = this.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    // 内存没命中就查磁盘缓存：封面地址是按平台接口现查的，不缓存的话每次启动
    // 都要为列表里每一行重新请求一遍
    const saved: string = MediaCache.getInstance().getPic(key);
    if (saved.length > 0) {
      this.cache.set(key, saved);
      return saved;
    }
    this.enqueue(info, musicInfoJson);
    return '';
  }

  /** 播放页用：解析好了回调一次（失败不回调） */
  request(musicInfoJson: string, onReady: (url: string) => void): void {
    const info: LxMusicInfo | null = this.infoOf(musicInfoJson);
    if (info === null) {
      return;
    }
    const key: string = this.keyOf(info.source, info.songmid);
    const hit: string | undefined = this.cache.get(key);
    if (hit !== undefined) {
      onReady(hit);
      return;
    }
    const saved: string = MediaCache.getInstance().getPic(key);
    if (saved.length > 0) {
      this.cache.set(key, saved);
      onReady(saved);
      return;
    }
    if (this.failed.has(key)) {
      return;
    }
    const list: ((url: string) => void)[] | undefined = this.waiters.get(key);
    if (list === undefined) {
      this.waiters.set(key, [onReady]);
    } else {
      list.push(onReady);
    }
    this.enqueue(info, musicInfoJson);
  }

  private enqueue(info: LxMusicInfo, musicInfoJson: string): void {
    const key: string = this.keyOf(info.source, info.songmid);
    if (key.length <= 1 || this.cache.has(key) || this.failed.has(key) || this.pending.has(key)) {
      return;
    }
    // 队列已经很长了就先不排（那一行显示占位封面，列表重画时会再问一次）
    if (this.queue.length >= QUEUE_MAX) {
      return;
    }
    this.pending.add(key);
    this.queue.push({ key: key, musicInfoJson: musicInfoJson });
    this.pump();
  }

  private pump(): void {
    while (this.active < this.maxActive && this.queue.length > 0) {
      const task: CoverTask | undefined = this.queue.shift();
      if (task !== undefined) {
        this.run(task);
      }
    }
  }

  private async run(task: CoverTask): Promise<void> {
    this.active++;
    let url: string = '';
    try {
      const info: LxMusicInfo | null = this.infoOf(task.musicInfoJson);
      if (info !== null) {
        url = await fetchMusicPic(info);
        if (url.length === 0) {
          url = await this.fetchFromSource(info, task.musicInfoJson);
        }
      }
    } catch (e) {
      url = '';
    }
    this.active--;
    this.pending.delete(task.key);
    if (url.length > 0) {
      this.cache.set(task.key, url);
      // 落到磁盘缓存，下次启动不用为这几百行重新请求封面地址
      MediaCache.getInstance().savePic(task.key, url);
      this.notify(task.key, url);
      this.bumpVersion();
    } else {
      this.failed.add(task.key);
      this.notify(task.key, '');
    }
    this.pump();
  }

  /** 平台接口拿不到时，问源脚本的 pic action（只有源声明了 pic 才问） */
  private async fetchFromSource(info: LxMusicInfo, musicInfoJson: string): Promise<string> {
    const engine = SourceEngine.getInstance();
    if (!engine.isInited() || !engine.supportsAction(info.source, 'pic')) {
      return '';
    }
    try {
      const url: string = await engine.getPic(musicInfoJson, info.source);
      return url;
    } catch (e) {
      return '';
    }
  }

  private notify(key: string, url: string): void {
    const list: ((url: string) => void)[] | undefined = this.waiters.get(key);
    if (list === undefined) {
      return;
    }
    this.waiters.delete(key);
    for (const callback of list) {
      callback(url);
    }
  }

  /** 一批解析完再通知一次界面，别每张图都刷一遍列表 */
  private bumpVersion(): void {
    if (this.flushTimer !== 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = 0;
      const version: number = AppStorage.get<number>(K_COVER_VERSION) ?? 0;
      AppStorage.setOrCreate(K_COVER_VERSION, version + 1);
    }, 120);
  }
}
