import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'UiHintStore';
const FILE_NAME: string = 'ui_hints.json';
/** 落盘结构变了就 +1，读到不认识的版本按「都没看过」处理 */
const HINTS_VERSION: number = 1;

/** 落盘结构（字段全部可选：老文件里可能缺字段，缺的按「没看过」处理） */
interface UiHintsData {
  version?: number;
  onlineMultiHint?: boolean;
}

/**
 * 「这条提示给用户看过了」的记录（界面提示的一次性开关）
 *
 * 现在只有一项：在线榜单 / 在线歌单页那句「长按任意歌曲可多选」。
 *
 * 为什么要落盘：多选只能靠长按进，界面上**没有任何按钮**写着这件事（顶栏那套
 * 「取消 + 已选中 N 项 + 全选」要先进了多选才出现），所以需要主动提示一次；
 * 而这种提示的价值只在第一次 —— 第二次开始就是打扰。记在内存（AppStorage）里
 * 杀进程就丢，用户每次启动都要被弹一遍，所以必须落到沙箱。
 *
 * 为什么由**页面**自己在 aboutToAppear 里 init，而不像其它设置那样在
 * EntryAbility.onCreate 里 init 一次：这条提示只有进到在线列表才用得上，
 * 把它塞进启动路径只是给冷启动多一次同步读文件的机会。init 是幂等的，
 * 第一个进来的页面调用即可。
 */
export class UiHintStore {
  private static instance: UiHintStore | null = null;

  static getInstance(): UiHintStore {
    if (UiHintStore.instance === null) {
      UiHintStore.instance = new UiHintStore();
    }
    return UiHintStore.instance;
  }

  private file: string = '';
  private inited: boolean = false;

  // ---------------------------------------------------------------- 状态
  /** 在线列表的「长按可多选」提示看过了没有 */
  private onlineMultiSeen: boolean = false;

  /**
   * 绑定沙箱目录并读回上次的记录。
   *
   * 调用方传自己的 context 即可（页面里是 `this.getUIContext().getHostContext()`）。
   * 拿不到目录时只记日志、不抛：提示功能本身不该因为一次读盘失败把页面拖挂，
   * 这时本进程内仍按「没看过」处理，照弹，只是这次不落盘。
   */
  init(context: common.Context): void {
    if (this.inited) {
      return;
    }
    try {
      this.file = `${context.filesDir}/${FILE_NAME}`;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'no filesDir, ui hints will not persist: %{public}s', JSON.stringify(e));
      return;
    }
    this.inited = true;
    const text: string = this.read();
    if (text.length > 0) {
      try {
        this.apply(JSON.parse(text) as UiHintsData);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'failed to parse ui hints: %{public}s', JSON.stringify(e));
      }
    }
  }

  private read(): string {
    try {
      if (!fs.accessSync(this.file)) {
        return '';
      }
      return fs.readTextSync(this.file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to read ui hints: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  private write(): void {
    if (!this.inited) {
      return;
    }
    const data: UiHintsData = {
      version: HINTS_VERSION,
      onlineMultiHint: this.onlineMultiSeen,
    };
    try {
      const file = fs.openSync(this.file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'failed to write ui hints: %{public}s', JSON.stringify(e));
    }
  }

  private apply(data: UiHintsData): void {
    if (data.version !== HINTS_VERSION) {
      return;
    }
    const seen: boolean | undefined = data.onlineMultiHint;
    if (seen !== undefined) {
      this.onlineMultiSeen = seen;
    }
  }

  // ---------------------------------------------------------------- 读写

  hasSeenOnlineMultiHint(): boolean {
    return this.onlineMultiSeen;
  }

  /**
   * 记下「这条提示已经弹过」并落盘。
   *
   * 调用方要在 showToast 之后**同一个同步块里**立刻调，不要挂在 toast 的消失回调或
   * 用户点关闭上：这条提示是纯通知、没有关闭按钮，想等「用户确实看到了」就永远等不到；
   * 一旦等交互，用户在提示显示期间杀掉应用，下次进来又会弹 —— 那就不是「只打扰一次」了。
   * 代价是极端情况下（刚弹就被杀）用户少看一次，这比反复弹要好。
   */
  markOnlineMultiHintSeen(): void {
    if (this.onlineMultiSeen) {
      return;
    }
    this.onlineMultiSeen = true;
    this.write();
  }
}
