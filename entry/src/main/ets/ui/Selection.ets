import { PlaySession, SongItem } from '../core/player/PlaySession';
import { C_RED, C_TEXT, C_TEXT_WEAK, F_TAB } from './Theme';
import { I_ADD_SONGLIST, I_DOWNLOAD_TO_LINE, I_HEART, I_HEART_SLASH, I_LIST_PLAY, I_MINUS_CIRCLE, I_NEXT,
  I_REMOVE_SONGLIST, I_TRASH, IconGlyph } from './Icons';

/**
 * 多选（全应用一套）
 *
 * 进多选的入口是**长按任意一行**，工具条长在系统自己该在的位置上 —— 不是页内自绘的两条：
 *
 *   - **顶栏**：`HdsNavDestination` 的标题栏。多选时左边那颗钮从「返回」变成「取消」（叉）、
 *     标题变成「已选中 N 项」、右边多一颗「全选」钮。三样都塞进 HDS 自己的槽位
 *     （`backIcon` / `title` / `menu`），位置、字号、间距、**玻璃动效**全部由框架画 ——
 *     与页面上原来那颗返回键同一套（标题栏的 `systemMaterialEffect`），不自己画玻璃：
 *     内容区里自绘的玻璃在沉浸光感的生效范围之外，材质根本不渲染（见 ui/Glass.ets）。
 *
 *   - **底栏**：页面本来就有的那条悬浮胶囊（迷你播放条那条，`Tabs.barFloatingStyle`）。
 *     多选时它**顶掉迷你播放条**，内容换成这里的 {@link SelectionActions} —— 胶囊的
 *     圆角、边距、离底距离、材质一个字都不改，所以底栏长得跟迷你条一模一样。
 *
 * 上下两条要读同一份状态，所以这里放一个全局会话（{@link SelectSession}）：当前在多选的
 * 那个页面把「勾了几首 / 操作项 / 三个回调」写进来，会话再把
 * {@link K_SELECT_ACTIVE} / {@link K_SELECT_COUNT} / {@link K_SELECT_ALL} 三个订阅值发布出去，
 * 顶栏（pages/Index.ets）与底栏各自 `@StorageLink` 它就够了 —— 同一时刻只可能有一个页面在多选。
 *
 * 能做什么各页面不一样（历史能删记录、本地音乐能移除副本、下载管理连文件一起删、
 * 云端音乐只能收藏和入库），所以操作项与文案由宿主给，这里只管长相与分发：
 * 底栏一行「图标 + 文案」，红字那项是主操作（删除 / 移除 / 取消收藏这类）。
 */

/** 当前有多选在进行（顶栏据此换成「取消 + 已选中 N 项 + 全选」，底栏据此换成操作条） */
export const K_SELECT_ACTIVE: string = 'select_bar_active';
/** 已勾选条数（顶栏的标题、底栏主操作的可用态都看它） */
export const K_SELECT_COUNT: string = 'select_bar_count';
/** 是不是已经全选（顶栏那颗钮的读屏文案在「全选 / 取消全选」之间切） */
export const K_SELECT_ALL: string = 'select_bar_all';

/** 底栏的一项操作：文案（各页面自己的）+ 图标（按文案认）+ 是不是主操作 */
export interface SelectAction {
  label: string;
  icon: Resource;
  primary: boolean;
}

/**
 * 多选会话（全局唯一）
 *
 * 只存两类东西：**操作项**（底栏要画的那几项）与**三个回调**（顶栏的取消 / 全选、
 * 底栏某一项）。勾选状态本身不在这里 —— 它在各页面自己的 `selectedIds` 里。
 */
export class SelectSession {
  private static instance: SelectSession | undefined;
  /** 底栏要画的操作项（由当前在多选的那个页面给） */
  actions: SelectAction[] = [];
  /** 顶栏左上那颗「取消」 */
  onCancel: () => void = () => {
  };
  /** 顶栏右上那颗「全选 / 取消全选」 */
  onToggleAll: () => void = () => {
  };
  /** 底栏某一项（按下标分发，与 `actions` 同序） */
  onAction: (index: number) => void = () => {
  };

  static getInstance(): SelectSession {
    if (SelectSession.instance === undefined) {
      SelectSession.instance = new SelectSession();
    }
    return SelectSession.instance;
  }

  /** 当前是不是有多选在进行（页面被弹掉时用来兜一下，见 {@link end}） */
  isActive(): boolean {
    const active: boolean | undefined = AppStorage.get<boolean>(K_SELECT_ACTIVE);
    return active === true;
  }

  /**
   * 进多选 / 刷新多选
   *
   * 进多选时调一次，之后**每次勾选变化都再调一次**（回调与操作项每次重给一遍，
   * 幂等，不区分「第一次」和「后续」—— 各页面就一处调用点，不会漏）。
   */
  show(count: number, allSelected: boolean, actions: SelectAction[],
    onCancel: () => void, onToggleAll: () => void, onAction: (index: number) => void): void {
    this.actions = actions;
    this.onCancel = onCancel;
    this.onToggleAll = onToggleAll;
    this.onAction = onAction;
    AppStorage.setOrCreate(K_SELECT_ACTIVE, true);
    AppStorage.setOrCreate(K_SELECT_COUNT, count);
    AppStorage.setOrCreate(K_SELECT_ALL, allSelected);
  }

  /**
   * 退出多选：顶栏与底栏一起恢复原样
   *
   * 页面被弹掉（aboutToDisappear）时也要调 —— 不然工具条会留在下一层页面上。
   */
  end(): void {
    if (!this.isActive()) {
      return;
    }
    this.actions = [];
    this.onCancel = () => {
    };
    this.onToggleAll = () => {
    };
    this.onAction = () => {
    };
    AppStorage.setOrCreate(K_SELECT_ACTIVE, false);
    AppStorage.setOrCreate(K_SELECT_COUNT, 0);
    AppStorage.setOrCreate(K_SELECT_ALL, false);
  }
}

/** 批量操作清单：页面自己的文案数组 + 红字那枚主操作（留空 = 这次多选没有主操作） */
export function selectActionsOf(labels: string[], primaryLabel: string = ''): SelectAction[] {
  const out: SelectAction[] = [];
  for (const label of labels) {
    out.push({ label: label, icon: iconOfLabel(label), primary: false });
  }
  if (primaryLabel.length > 0) {
    out.push({ label: primaryLabel, icon: iconOfLabel(primaryLabel), primary: true });
  }
  return out;
}

/**
 * 底栏那颗图标按**文案**认
 *
 * 各页面的批量操作就那么几件，一张表全覆盖；文案是各页面自己的（`HISTORY_ACTIONS`
 * 这类常量），这里不改它们，只负责配上图标 —— 认不出来的一律给垃圾桶（剩下能走到
 * 这里的只有「删除」这一族）。
 */
function iconOfLabel(label: string): Resource {
  switch (label) {
    case '收藏':
      return I_HEART;
    case '取消收藏':
      return I_HEART_SLASH;
    case '加入歌单':
    case '添加到歌单':
      return I_ADD_SONGLIST;
    case '加入播放列表':
    case '添加到播放列表':
      return I_LIST_PLAY;
    case '下一个播放':
      return I_NEXT;
    case '下载':
    case '重新下载':
      return I_DOWNLOAD_TO_LINE;
    case '移除':
      return I_MINUS_CIRCLE;
    case '从歌单中删除':
      return I_REMOVE_SONGLIST;
    default:
      return I_TRASH;
  }
}

/**
 * 底栏那条窄（56vp 高、最多要放下 6 项），长文案在栏里换成短的
 *
 * **只换显示**：分发的还是各页面自己的原文案（它们按下标 / 按文案分发），所以这里
 * 不叫「改文案」，叫「栏里的字号排不下 7 个字」。
 */
export function shortLabelOf(label: string): string {
  switch (label) {
    case '加入歌单':
    case '添加到歌单':
      return '歌单';
    case '加入播放列表':
    case '添加到播放列表':
      return '播放列表';
    case '下一个播放':
      return '下一首';
    case '从歌单中删除':
      return '移除';
    case '删除记录':
      return '删除';
    default:
      return label;
  }
}

/**
 * 底栏那颗悬浮胶囊里的内容：一行「图标 + 文案」，最多 6 项，均分整条
 *
 * **只放内容，不给任何底** —— 胶囊的圆角、底色、材质、离底距离全由宿主的 Tabs
 * 悬浮栏画（多选时它顶掉迷你播放条，见各页面的 `miniBarTabBar`）。在这里再叠一层
 * 自绘玻璃就把材质盖住了：沉浸光感的层级在 `backgroundColor` / `backgroundBlurStyle`
 * 之下（ui/Glass.ets 里写了这条）。
 */
@Component
export struct SelectionActions {
  /** 有多选才画（宿主要么按它切内容，要么根本不挂这个组件） */
  @StorageLink(K_SELECT_ACTIVE) active: boolean = false;
  /** 一首都没勾时主操作是灰的 */
  @StorageLink(K_SELECT_COUNT) count: number = 0;

  /** 底栏要显示的那几项（会话里的操作项换成长文案的短写） */
  private labels(): string[] {
    const out: string[] = [];
    for (const action of SelectSession.getInstance().actions) {
      out.push(shortLabelOf(action.label));
    }
    return out;
  }

  private iconAt(index: number): Resource {
    const list: SelectAction[] = SelectSession.getInstance().actions;
    return index >= 0 && index < list.length ? list[index].icon : I_TRASH;
  }

  private tintAt(index: number): ResourceColor {
    const list: SelectAction[] = SelectSession.getInstance().actions;
    if (index < 0 || index >= list.length) {
      return C_TEXT;
    }
    if (!list[index].primary) {
      return C_TEXT;
    }
    // 主操作（删除 / 移除 / 取消收藏）用红字：本应用里「主操作」一贯是这个红
    return this.count > 0 ? C_RED : C_TEXT_WEAK;
  }

  @Builder
  actionItem(label: string, index: number) {
    Column({ space: 3 }) {
      IconGlyph({
        symbol: this.iconAt(index),
        iconSize: 20,
        color: this.tintAt(index),
      })
        .accessibilityLevel('no')
      Text(label)
        .fontSize(F_TAB)
        .fontColor(this.tintAt(index))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      SelectSession.getInstance().onAction(index);
    })
    .accessibilityText(label)
    .accessibilityLevel('yes')
  }

  build() {
    Row() {
      if (this.active) {
        ForEach(this.labels(), (label: string, index: number) => {
          this.actionItem(label, index)
        }, (label: string, index: number) => `${index}_${label}`)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }
}

// ------------------------------------------------------------ 勾选状态

/**
 * 勾选 / 取消勾选一条
 *
 * 返回新数组而不是原地改：调用方把它赋回 `@State`，界面才会重绘。
 */
export function toggleSelected(ids: string[], id: string): string[] {
  const next: string[] = [];
  let hit: boolean = false;
  for (const current of ids) {
    if (current === id) {
      hit = true;
    } else {
      next.push(current);
    }
  }
  if (!hit) {
    next.push(id);
  }
  return next;
}

/**
 * 列表变了以后把已经不存在的勾选摘掉
 *
 * 不摘的话「移除 3 首」会带着幽灵条目算数（删掉的那条还在勾选里）。
 */
export function pruneSelected(ids: string[], aliveIds: string[]): string[] {
  const next: string[] = [];
  for (const id of ids) {
    if (aliveIds.includes(id)) {
      next.push(id);
    }
  }
  return next;
}

export function allSelectedOf(ids: string[], total: number): boolean {
  return total > 0 && ids.length === total;
}

/** 按勾选顺序取出整条数据（列表里已经找不到的条目不算） */
export function selectedSongs(items: SongItem[], ids: string[]): SongItem[] {
  const out: SongItem[] = [];
  for (const item of items) {
    if (ids.includes(item.id)) {
      out.push(item);
    }
  }
  return out;
}

// ------------------------------------------------------------ 歌曲的批量操作

/** 批量收藏；返回一句给用户看的话（收藏是参与同步的数据，走 addFavorites 只上行一次） */
export function favoriteSongs(songs: SongItem[]): string {
  const added: number = PlaySession.getInstance().addFavorites(songs);
  if (songs.length === 1) {
    return added > 0 ? `已添加到收藏：${songs[0].name}` : `「${songs[0].name}」已经在收藏里了`;
  }
  return added > 0 ? `已收藏 ${added} 首` : '这些歌都已经在收藏里了';
}

/** 批量加入播放列表；asNext 为真时按勾选顺序插到当前播放的后面 */
export function queueSongs(songs: SongItem[], asNext: boolean): string {
  if (songs.length === 0) {
    return '';
  }
  const session = PlaySession.getInstance();
  const hasCurrent: boolean = session.currentIndex >= 0 && session.currentIndex < session.queue.length;
  const next: boolean = asNext && hasCurrent;
  if (next) {
    // 一次一首地插到当前歌后面，倒着插才跟勾选顺序一致
    for (let i = songs.length - 1; i >= 0; i--) {
      session.addToQueue(songs[i], true);
    }
  } else {
    for (const song of songs) {
      session.addToQueue(song);
    }
  }
  if (songs.length === 1) {
    return next ? `已设为下一首播放：${songs[0].name}` : `已添加到播放列表：${songs[0].name}`;
  }
  return next ? `已设为接下来播放 ${songs.length} 首` : `已添加 ${songs.length} 首到播放列表`;
}
