import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxPlayer, LxPlayerStatus } from '../player/LxPlayer';
import { PlaySession, SongItem } from '../player/PlaySession';
import { intervalMs, ListenLog, ListenRecord, ListenSong } from './ListenLog';

const DOMAIN: number = 0x0001;
const TAG: string = 'ListenTracker';
/**
 * 播放中每隔这么久把「正在听」那条的时长落一次盘
 *
 * 不每次事件都写：整份流水是一个 JSON，写一次是整文件重写（见 ListenLog.write），
 * 60 秒一次在「别丢太多」与「别老写盘」之间够用；真正不丢的是收尾那一次
 * （切歌 / 停止 / 退到后台都会收尾）。
 */
const CHECKPOINT_MS: number = 60000;

/**
 * 从 musicInfo JSON 里读专辑名
 *
 * 队列条目（SongItem）本身没有专辑字段，但真实搜索结果转成的 musicInfo 里有
 * （洛雪那套 `albumName`）；本地歌 / 云端歌的 musicInfo 也是同一个结构（见
 * core/local/LocalMusic 与 core/webdav/WebDavLibrary）。读不到就当空串 ——
 * 回响的专辑榜会把空专辑名的歌跳过，不影响其它榜。
 */
function albumOf(item: SongItem): string {
  if (item.musicInfoJson.length === 0) {
    return '';
  }
  try {
    const info: Record<string, Object> = JSON.parse(item.musicInfoJson) as Record<string, Object>;
    const album: Object = info['albumName'];
    return typeof album === 'string' ? album : '';
  } catch (e) {
    return '';
  }
}

/** 队列条目 → 流水里的歌曲快照（一次性把历史与回响要用到的字段都带全） */
function songOf(item: SongItem): ListenSong {
  const song: ListenSong = {
    id: item.id,
    name: item.name,
    singer: item.singer,
    coverUrl: item.coverUrl,
    art: item.art,
    source: item.source,
    quality: item.quality,
    interval: item.interval,
    musicInfoJson: item.musicInfoJson,
    albumName: albumOf(item),
    durationMs: intervalMs(item.interval),
  };
  return song;
}

/**
 * 收听时长的记账（回响与播放历史共用的数据来源）
 *
 * 盯着播放器算两件事：**这一首听了多久**、**这一条什么时候收尾**。
 * 收尾后记录**全部留在流水里**（不到 1 秒的残片除外）：播放历史要显示「听过但没
 * 听够」的歌，回响那边再按「听满 30 秒」自己筛（见 ListenLog.countedOf）——
 * 30 秒门槛只在一个地方定义，不再出现两套口径。
 *
 * 记账口径：
 *   - 只算「真的在出声」的时间：`playing` 才走表，暂停 / 缓冲 / 加载都停表，
 *     所以拖动进度条、卡顿等待都不会算进时长（这也是「总时长」能当收听时长看的原因）；
 *   - 一首的开播时刻取第一次真的出声的时刻，而不是点下去的时刻 —— 解析取链接要几秒，
 *     点下去就计时的话，解析失败的那次也会留下一条。
 *
 * 为什么挂在 LxPlayer 而不是 PlaySession 里：PlaySession 是「会话逻辑」（队列、切歌、
 * 取链接），记账是另一件事，单独一处更好读；LxPlayer 的监听本来就是多播
 * （addStateListener / addTimeListener…），多一个订阅方不影响 PlaySession 自己那套。
 * 唯一要向 PlaySession 借的是「当前是哪首歌」—— 元数据（歌名 / 歌手 / 封面）只有它那里有。
 */
export class ListenTracker {
  private static instance: ListenTracker | null = null;

  static getInstance(): ListenTracker {
    if (ListenTracker.instance === null) {
      ListenTracker.instance = new ListenTracker();
    }
    return ListenTracker.instance;
  }

  private openId: string = '';
  private lastId: string = '';
  private lastRecord: ListenRecord | null = null;
  private consumed: ListenRecord | null = null;

  /** 只读实际出声时长；同一条流水最多用于一次推荐收尾。 */
  takeFeedback(id: string, since: number): ListenRecord | null {
    const active = this.open !== null && this.openId === id;
    const row = active ? this.open : (this.lastId === id ? this.lastRecord : null);
    if (row === null || row === this.consumed || row.startedAt < since) {
      return null;
    }
    this.consumed = row;
    const elapsed = active && this.playingSince > 0 ? Math.max(0, Date.now() - this.playingSince) : 0;
    const snapshot: ListenRecord = {
      startedAt: row.startedAt, songKey: row.songKey, durationMs: row.durationMs,
      playedMs: row.playedMs + elapsed
    };
    return snapshot;
  }

  private wired: boolean = false;
  /** 正在听的那一条（已经进了流水，时长就地往上加） */
  private open: ListenRecord | null = null;
  /** 正在听的那一首的判据（歌名 + 歌手），用来认「换歌了」 */
  private openKey: string = '';
  /** 这一轮「连续出声」的起点（毫秒）；0 = 此刻没在出声 */
  private playingSince: number = 0;
  /** 上一次落盘的时刻（播放中定时落盘用，见 CHECKPOINT_MS） */
  private lastWriteAt: number = 0;

  /** 订阅播放器事件。EntryAbility.onCreate 里调一次（越早越好，第一首也要记上） */
  init(): void {
    if (this.wired) {
      return;
    }
    this.wired = true;
    const player = LxPlayer.getInstance();
    // 三个回调都只关心「发生了什么」：时长从墙上时钟算（见 pauseClock），
    // 播放器的进度值用不上，所以形参一个都不接
    player.addStateListener((status: LxPlayerStatus): void => {
      this.onState(status);
    });
    player.addBufferListener((buffering: boolean): void => {
      this.onBuffer(buffering);
    });
    player.addTimeListener((currentMs: number, durationMs: number): void => {
      this.onTime(durationMs);
    });
    hilog.info(DOMAIN, TAG, 'listen tracker wired');
  }

  /**
   * 收尾：把这轮听到现在的时长结清、该留的留下
   *
   * 由 EntryAbility 在**退到后台**与**销毁前**调：那一刻系统随时可能把进程收走，
   * 不结清的话正在听的这一首会白听（PlaySession 也是在同一时刻把播放现场落盘的）。
   */
  settle(): void {
    this.pauseClock();
    this.commit();
  }

  // ---------------------------------------------------------------- 事件

  private onState(status: LxPlayerStatus): void {
    const playing: boolean = status === 'playing' && !LxPlayer.getInstance().isBuffering();
    if (playing) {
      // 上一首的账先用它自己那条结清，再给这一首开表
      this.pauseClock();
      this.commitIfSongChanged();
      this.openForCurrent();
      this.resumeClock();
      return;
    }
    this.pauseClock();
    if (status === 'paused') {
      // 暂停那一刻把已听时长落盘并通知界面：不加这一步的话，暂停后切到回响 / 最近播放
      // 看到的还是上一次落盘的数字（播放中每 60 秒才落一次），正在听的这首也要等
      // 切歌后才在历史里出现。暂停是低频事件，多写一次文件的代价可以忽略。
      ListenLog.getInstance().checkpoint();
      return;
    }
    if (status === 'idle' || status === 'stopped' || status === 'error') {
      // 真的停了（不是暂停）：这一首到此为止
      this.commitIfSongChanged();
    }
  }

  private onBuffer(buffering: boolean): void {
    if (buffering) {
      // 等数据的这几秒没声音，不算听
      this.pauseClock();
      return;
    }
    if (LxPlayer.getInstance().isPlaying()) {
      this.resumeClock();
    }
  }

  /**
   * 播放进度回调
   *
   * @param durationMs AVPlayer 报的这首歌真实时长（毫秒，0 = 还没拿到）
   *
   * 时长一定要记在流水上：完播率是「系统自己记录、自己算」的指标，不能依赖音源给没给
   * `interval`（很多音源 / 本地文件没有时长字段）。AVPlayer 在解析出文件后就会报真实
   * 时长，这里取「目前见到的最大值」写进正在听的这一条（流媒体时长可能先给 0 再补上，
   * 偶尔也会有抖动，只增不减最稳）。
   */
  private onTime(durationMs: number): void {
    if (this.open !== null && durationMs > 0 && durationMs > this.open.durationMs) {
      this.open.durationMs = durationMs;
    }
    if (this.playingSince === 0 || this.open === null) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastWriteAt < CHECKPOINT_MS) {
      return;
    }
    // 走表的时间先记进这一条，再落盘；表接着走（把起点挪到现在）
    this.open.playedMs += now - this.playingSince;
    this.playingSince = now;
    this.lastWriteAt = now;
    ListenLog.getInstance().checkpoint();
  }

  // ---------------------------------------------------------------- 记账

  /** 开始走表（已经在走就什么也不做，免得漏掉一段时间） */
  private resumeClock(): void {
    if (this.playingSince === 0) {
      this.playingSince = Date.now();
    }
  }

  /** 停表：把这一轮走出来的时间记进正在听的那一条 */
  private pauseClock(): void {
    if (this.playingSince === 0) {
      return;
    }
    const elapsed: number = Date.now() - this.playingSince;
    this.playingSince = 0;
    if (this.open !== null) {
      this.open.playedMs += elapsed;
    }
  }

  /** 给当前这首歌开一条「正在听」（已经开着同一首就不动） */
  private openForCurrent(): void {
    const item: SongItem | null = PlaySession.getInstance().current;
    if (item === null) {
      return;
    }
    const key: string = `${item.name}\u0001${item.singer}`;
    if (this.open !== null && this.openKey === key) {
      return;
    }
    this.lastWriteAt = Date.now();
    hilog.info(DOMAIN, TAG, 'begin listening record: %{public}s', item.name);
    this.open = ListenLog.getInstance().begin(songOf(item));
    this.openKey = key;
    this.openId = item.id;
  }

  /** 当前这首歌已经不是正在听的那一首时收尾（切歌 / 播完 / 停了） */
  private commitIfSongChanged(): void {
    if (this.open === null) {
      return;
    }
    const item: SongItem | null = PlaySession.getInstance().current;
    const key: string = item === null ? '' : `${item.name}\u0001${item.singer}`;
    if (key === this.openKey) {
      return;
    }
    this.commit();
  }

  /** 收尾正在听的那一条：不到 1 秒的残片摘掉，其余留在流水里（见 ListenLog.close） */
  private commit(): void {
    const record: ListenRecord | null = this.open;
    if (record !== null) {
      this.lastId = this.openId;
      this.lastRecord = record;
    }
    this.openId = '';
    this.open = null;
    this.openKey = '';
    if (record === null) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'close listening record: %{public}s played=%{public}dms',
      record.songKey, record.playedMs);
    ListenLog.getInstance().close(record);
  }
}
