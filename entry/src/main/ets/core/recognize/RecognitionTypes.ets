/**
 * 听歌识曲的领域类型
 *
 * 一次识别的流程是「录一段 → 多引擎并发识别 → 归并排序」，这中间要传的东西有三样：
 *   1. 界面状态（{@link RecognitionStatus}）—— 录到哪一步了、成没成；
 *   2. 候选歌（{@link RecognitionResult}）—— 识别出来的歌，带来源与来源内的歌曲 id；
 *   3. 逐引擎的回执（{@link EngineReport} / {@link EngineResultGroup}）—— 哪个引擎
 *      命中了、哪个引擎报错了，界面据此分组展示，也方便排查「为什么这次没认出来」。
 *
 * 迁移自派音的 features/player 识别模块，类型与语义保持不变。
 */

/** 识别流程的状态（界面文案与按钮可用性都按它切） */
export enum RecognitionStatus {
  Idle = 'idle',
  RequestingPermission = 'requestingPermission',
  Capturing = 'capturing',
  Recognizing = 'recognizing',
  Matched = 'matched',
  NotMatched = 'notMatched',
  PermissionDenied = 'permissionDenied',
  NoAudio = 'noAudio',
  NetworkError = 'networkError',
  Error = 'error',
}

/** 单个引擎这次跑成什么样（给界面画「酷狗：命中 / 网易云：未匹配」那一行） */
export class EngineReport {
  engine: string = '';
  /** matched / notMatched / error，与 RecognitionStatus 的对应档位同名字符串 */
  status: string = '';

  static create(engine: string, status: string): EngineReport {
    const report = new EngineReport();
    report.engine = engine;
    report.status = status;
    return report;
  }
}

/** 单个引擎的完整候选列表（命中或报错二选一） */
export class EngineResultGroup {
  engine: string = '';
  results: RecognitionResult[] = [];
  /** 非空表示这个引擎这次失败了，原因直接展示给用户 */
  error: string = '';

  static create(engine: string, results: RecognitionResult[], error: string): EngineResultGroup {
    const group = new EngineResultGroup();
    group.engine = engine;
    group.results = results;
    group.error = error;
    return group;
  }
}

/**
 * 识别出来的一首歌
 *
 * `providerTrackId` 是「来源前缀 + 来源内的歌曲 id」（如 `kg:ABCD...` / `wy:123456`），
 * 前缀决定播放时去哪个平台找（见 views/RecognizeView 的播放逻辑）。
 */
export class RecognitionResult {
  id: string = '';
  title: string = '';
  artist: string = '';
  album: string = '';
  coverUrl: string = '';
  provider: string = '';
  providerTrackId: string = '';
  /** 识别到的时间（毫秒），历史列表按它排 */
  recognizedAt: number = 0;

  static create(title: string, artist: string, album: string, coverUrl: string,
    providerTrackId: string, recognizedAt: number): RecognitionResult {
    const result = new RecognitionResult();
    result.id = `rec_${providerTrackId}:${recognizedAt}`;
    result.title = title;
    result.artist = artist;
    result.album = album;
    result.coverUrl = coverUrl;
    result.providerTrackId = providerTrackId;
    result.recognizedAt = recognizedAt;
    return result;
  }

  toRecord(): Record<string, Object> {
    return {
      'id': this.id,
      'title': this.title,
      'artist': this.artist,
      'album': this.album,
      'coverUrl': this.coverUrl,
      'provider': this.provider,
      'providerTrackId': this.providerTrackId,
      'recognizedAt': this.recognizedAt,
    };
  }

  static fromRecord(record: Record<string, Object>): RecognitionResult {
    const result = new RecognitionResult();
    result.id = record['id'] as string;
    result.title = record['title'] as string;
    result.artist = record['artist'] as string;
    result.album = record['album'] as string;
    result.coverUrl = record['coverUrl'] as string;
    result.provider = record['provider'] as string;
    result.providerTrackId = record['providerTrackId'] as string;
    result.recognizedAt = record['recognizedAt'] as number;
    return result;
  }
}
