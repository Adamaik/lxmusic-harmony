/** 识别服务（酷狗 / 网易云）请求失败：网络不通、非 2xx、返回体解析不了都归它 */
export class RecognitionNetworkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RecognitionNetworkError';
  }
}
