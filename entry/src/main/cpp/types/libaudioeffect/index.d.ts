export interface ProcessAudioResult {
  ok: boolean;
  code: number;
  message: string;
  outBytes: number;
  /** 自检指标：输出/输入的「低频/高频能量比」之商。≈1.0 表示 EQ 未改变频谱；
   *  >1 相对增强低频；<1 相对增强高频。对滤波延迟不敏感。 */
  delta: number;
  /** 容器报的时长（微秒） */
  durationUs: number;
  /** 解码器实际输出的采样率 / 声道数 */
  sampleRate: number;
  channels: number;
  /** 实际输出的帧数（每声道样本数）；÷ sampleRate 就是真实时长（秒） */
  outFrames: number;
}

/** 把本地音频过 10 段 EQ 后另存为 WAV。taskId 用于取消。 */
export function processAudio(
  inputPath: string,
  outputPath: string,
  gains: number[],
  taskId: number
): Promise<ProcessAudioResult>;

/** 直接处理网络音频地址（http/https，渐进式格式），省掉整份下载。taskId 用于取消。 */
export function processAudioUrl(
  url: string,
  outputPath: string,
  gains: number[],
  taskId: number
): Promise<ProcessAudioResult>;

/**
 * 处理调用方**已打开的 fd**（文件选择器导入的 `file://` URI 走这条）。
 *
 * fd 的所有权仍归调用方：本函数不关闭它，但调用方必须保持它在 Promise 结算前有效
 * （系统解封装器一直在用它读数据）。
 */
export function processAudioFd(
  fd: number,
  outputPath: string,
  gains: number[],
  taskId: number
): Promise<ProcessAudioResult>;

/** 取消指定任务（切歌时调用）。 */
export function cancel(taskId: number): void;

/** Native 模块版本，用于自检加载是否成功。 */
export function version(): string;
