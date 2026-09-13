import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'PlayStateStore';
const FILE_NAME: string = 'play_state.json';

/**
 * 播放现场的落盘
 *
 * 只做「文本进、文本出」：具体存什么由 PlaySession 决定（当前这首歌、进度、
 * 播放模式、播放历史）。这样这里不需要认识 SongItem，也就不会和 PlaySession
 * 形成循环引用（PlaySession 依赖它，它不能再依赖 PlaySession）。
 *
 * 对应洛雪：它把播放现场存在本地（playList / playIndex / playState），重启后接着上次；
 * 本移植版此前没有这一步，重启就把「正在播放」丢了。
 */
export class PlayStateStore {
  private file: string = '';
  private ready: boolean = false;

  init(context: common.Context): void {
    this.file = `${context.filesDir}/${FILE_NAME}`;
    this.ready = true;
  }

  isReady(): boolean {
    return this.ready;
  }

  /** 读上次的现场；没存过或读坏了都返回空串 */
  read(): string {
    if (!this.ready) {
      return '';
    }
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read play state: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  write(text: string): void {
    if (!this.ready) {
      return;
    }
    const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }
}
