import { K_LIBRARY_VERSION, PlaySession, SongItem } from '../core/player/PlaySession';
import { K_CURRENT_ID, K_PLAY_MODE, K_QUEUE_COUNT } from '../core/player/PlaySession';
import { SyncManager } from '../core/sync/SyncManager';
import { qualityLabel } from '../core/music/Quality';
import { platformName } from '../core/music/MusicList';
import { C_CARD, C_DIVIDER, C_FILL_SOFT, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK } from '../ui/Theme';
import {
  I_CLOSE, I_ORDER_PLAY, I_QUEUE, I_REPEAT, I_REPEAT_ONE, I_SHUFFLE, I_TRASH, I_VOLUME, IconGlyph,
} from '../ui/Icons';
import { EmptyState, SingerLink } from '../ui/Widgets';
import { SongListSource } from '../ui/SongListSource';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { DownloadItem, DownloadManager, downloadKeyOf } from '../core/download/DownloadManager';
import { isLocalSong } from '../core/local/LocalMusic';
import { isWebDavSong } from '../core/webdav/WebDavLibrary';

/**
 * 播放列表的内容
 *
 * 外层的半模态、标题栏、关闭钮、拖动条是系统的 bindSheet（见 pages/Index.ets）。
 * 队列本身用系统列表：`ListItemGroup(CARD)` 给整块白卡与行内分隔线，
 * 删歌走系统的左滑删除 `swipeAction`（划到底或点垃圾桶都能删）。
 *
 * 长按一首歌可以「收藏 / 不喜欢 / 移出队列」——收藏与不喜欢规则都是参与同步的数据，
 * 改动会即时上行到同步服务端。
 *
 * ---------------------------------------------------------------- 2026-11-23 三个用户反馈
 *
 * 一、「标题写共 250 首、列表只有 249 行」
 * 以前列表是 `aboutToAppear` 里 `queue.slice()` 的一份**快照**：队列在别处变了（播放全部、
 * 下一首播放、恢复播放现场时把当前这首插回队列……）它不会重读；而标题里的数字订阅的是
 * `K_QUEUE_COUNT`（`PlaySession.pushQueueState` 每次都会写 queue.length），是实时的。
 * 一个快照、一个实时值，两条路各算各的，于是差一条。现在列表订阅「队列条数 + 库版本 +
 * 换歌」三个信号，队列一动就重读一次，标题与列表必然读的是同一份 `PlaySession.queue`；
 * 列表重读还带「内容没变就不重载」的判断，不会因为收藏变化把正在滚动的列表整表刷一遍。
 *
 * 二、「同一首歌出现两行、两行都标着正在播放」
 * 查过了：不是 ForEach / LazyForEach 的 key 冲突（key 里带了行号，且数据源是整表重载，
 * 渲染层不会复制行）；队列里确实有两条 —— `PlaySession.addToQueue` 与恢复播放现场时
 * 插入当前歌的那条路都不按歌去重，而队列本身就是洛雪的「试听列表」，允许同一首歌被
 * 用户故意加两次（「下一首播放」点两下就是两条）。**所以这里选择「允许重复、但只有
 * 真正在播的那一行标红」**：判断「正在播放」不再比 `item.id === currentId`（同 id 的两条
 * 会一起亮），改成比队列下标 `index === currentIndex`。若产品要的是「入队即去重」，
 * 那是 `addToQueue` / 恢复现场的事（core/player/PlaySession.ets），不在本文件。
 *
 * 三、「面板底部留黑带、最后一行被切断」
 * 半模态的内容区默认只铺到手势条上面，下面那一截露出的是页面底色。现在根节点用
 * expandSafeArea 把面板底色一直铺到屏幕最底部（手势条底下也是卡片色），列表末尾那条
 * `bottomInset + 8` 的留白就是内容的安全区内边距 —— 面板不再「提前结束」。
 */
@Component
export struct PlayQueueContent {
  @Prop bottomInset: number = 0;
  /**
   * 当前正在播的那首歌的 id
   *
   * 除了给 isPlaying 做核对，还挂一个 @Watch('refresh')：**换歌是队列可能被整体换掉的
   * 信号**（`setQueueAndPlay` 换完队列就紧跟着 playAt）。光靠条数变化判断会漏掉
   * 「换成另一份长度一样的队列」这种情形（数量没变，@Watch 就不会响），所以换歌时也顺手
   * 核一次列表与队列是否还对得上；对得上就直接返回，不做整表重载。
   */
  @StorageLink(K_CURRENT_ID) @Watch('refresh') currentId: string = '';
  /**
   * 队列条数：既给「共 N 首」（在 pages/Index.ets 的 bindSheet 标题里）用，也是这里重读队列的
   * 触发条件之一 —— `pushQueueState` 每改一次队列都会写它。改完会走下面的 refresh()。
   */
  @StorageLink(K_QUEUE_COUNT) @Watch('refresh') queueCount: number = 0;
  /** 播放模式：列表循环 / 单曲循环 / 顺序播放 / 随机。面板顶部那一行要用它画图标与文字 */
  @StorageLink(K_PLAY_MODE) playMode: string = 'list';
  /**
   * 歌单 / 收藏 / 播放队列的版本号（`LocalLibrary.onLocalListsChanged` 每次都加一）
   *
   * 订阅它 + @Watch：队列在别处被改（播放全部、下一首播放、清空、同步覆盖）时，
   * 本面板要重读一次 —— 见文件头「标题写共 250 首、列表只有 249 行」那段。
   */
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @State items: SongItem[] = [];
  /** 懒加载数据源：队列可能几百首，只建可见的行 */
  private source: SongListSource = new SongListSource();
  /** 最近一次触摸点：删除时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  /**
   * 把播放队列读进列表（队列一变就会被上面几个 @Watch 叫一遍）
   *
   * 为什么不能只在 aboutToAppear 读一次 —— 见文件头「标题写共 250 首、列表只有 249 行」
   * 那段：列表拿的是快照，标题拿的是实时值，两条路各算各的就会差一条。现在两处都读
   * `PlaySession.queue`：标题读它的长度（`K_QUEUE_COUNT` 由 `pushQueueState` 写），
   * 列表读它的内容，从源头上就是同一份，谁也不会多算或少算。
   *
   * 为什么三个键都订阅（条数 / 库版本 / 当前歌）：
   *   - `pushQueueState()` 每次都写 K_QUEUE_COUNT —— 队列长度一变就响；
   *   - `notifyLibrary()` → `LocalLibrary.onLocalListsChanged()` 在**同步结构真的变了**
   *     时才递增 K_LIBRARY_VERSION（收藏 / 队列都会走这条）。注意它对「本地歌、云端歌
   *     入队」这种不可上行的改动会提前返回、不递增（见那个方法的 defaultChanged 判断），
   *     所以不能只靠它；
   *   - 换歌（K_CURRENT_ID）：`setQueueAndPlay` 换完队列紧接着就 playAt，用它补上
   *     「换成另一份**长度相同**的队列」这个条数不会变的盲区。
   * 三条路都听才不会漏；refresh 自己有「内容没变就返回」的判断，多叫一次不白干。
   *
   * 内容真没变（例如只是收藏变了、版本号跟着动）时直接返回：`setItems` 是整表重载，
   * 用户在列表里正滚动时来一下会看见行重闪。判据用「条数 + 逐条 id」，几百条也就一次遍历。
   */
  private refresh(): void {
    const queue: SongItem[] = PlaySession.getInstance().queue;
    if (this.sameAsShowing(queue)) {
      return;
    }
    this.items = queue.slice();
    this.source.setItems(this.items);
  }

  /** 现在列表里摆着的，是不是就是这一份队列（条数 + 顺序 + 每条 id 都一致） */
  private sameAsShowing(queue: SongItem[]): boolean {
    if (queue.length !== this.items.length) {
      return false;
    }
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id !== this.items[i].id) {
        return false;
      }
    }
    return true;
  }

  private deleteAt(index: number): void {
    PlaySession.getInstance().removeAt(index);
    // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
    dustBus.spray(this.dustX, this.dustY);
    this.refresh();
  }

  private rememberTouch(event: TouchEvent): void {
    const point: DustPoint | null = dustPointOf(event);
    if (point !== null) {
      this.dustX = point.x;
      this.dustY = point.y;
    }
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // ------------------------------------------------------------ 顶部操作行（照华为音乐）

  private modeIcon(): Resource {
    if (this.playMode === 'single') {
      return I_REPEAT_ONE;
    }
    if (this.playMode === 'order') {
      return I_ORDER_PLAY;
    }
    if (this.playMode === 'shuffle') {
      return I_SHUFFLE;
    }
    return I_REPEAT;
  }

  private modeText(): string {
    if (this.playMode === 'single') {
      return '单曲循环';
    }
    if (this.playMode === 'order') {
      return '顺序播放';
    }
    if (this.playMode === 'shuffle') {
      return '随机播放';
    }
    return '列表循环';
  }

  /** 点一下换一种播放模式（与播放页那颗循环钮是同一个开关） */
  private cycleMode(): void {
    const mode: string = PlaySession.getInstance().cyclePlayMode();
    this.toast(this.modeTextOf(mode));
  }

  private modeTextOf(mode: string): string {
    if (mode === 'single') {
      return '单曲循环';
    }
    if (mode === 'order') {
      return '顺序播放';
    }
    if (mode === 'shuffle') {
      return '随机播放';
    }
    return '列表循环';
  }

  /** 清空整个播放列表（华为音乐是同位置一个垃圾桶，这里给一次确认，避免误触把队列清掉） */
  private clearQueue(): void {
    if (this.items.length === 0) {
      return;
    }
    const session = PlaySession.getInstance();
    this.getUIContext().showAlertDialog({
      title: '清空播放列表',
      message: `将从播放列表移除 ${this.items.length} 首歌（正在播放的这一首也会停止）。\n已下载与收藏不受影响。`,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '清空',
        fontColor: C_RED,
        action: () => {
          session.clearQueue();
          this.refresh();
          this.toast('播放列表已清空');
        },
      },
    });
  }

  private toggleFavorite(item: SongItem): void {
    const session = PlaySession.getInstance();
    if (session.isFavorite(item.id)) {
      session.removeFavorite(item.id);
      this.toast(`已取消收藏「${item.name}」`);
      return;
    }
    if (session.addFavorite(item)) {
      this.toast(`已收藏「${item.name}」`);
    }
  }

  /** 下载：交给下载管理排队 */
  private download(item: SongItem): void {
    // 本地歌已经在本机了（菜单里也不显示这一项，这里只作兜底）
    if (isLocalSong(item)) {
      this.toast(`「${item.name}」已经在本机了`);
      return;
    }
    // 云端歌的下载由播放缓存负责，不排进下载队列
    if (isWebDavSong(item)) {
      this.toast(`「${item.name}」是云端音乐，播放时会自动缓存`);
      return;
    }
    const manager = DownloadManager.getInstance();
    const state: DownloadItem | null = manager.stateOf(downloadKeyOf(item));
    if (state !== null && state.status === 'done') {
      this.toast(`「${item.name}」已经下载过了`);
      return;
    }
    if (state !== null && (state.status === 'waiting' || state.status === 'downloading')) {
      this.toast(`「${item.name}」正在下载中`);
      return;
    }
    if (manager.enqueue(item) !== null) {
      this.toast(`已加入下载：${item.name}`);
    } else {
      this.toast('这首歌没法下载（缺少歌曲信息）');
    }
  }

  private dislike(item: SongItem): void {
    SyncManager.getInstance().getLibrary().addDislike(item.name, item.singer);
    this.toast(`已加入「不喜欢的歌曲」：${item.name}`);
  }

  @Builder
  rowMenu(item: SongItem, index: number) {
    Menu() {
      MenuItem({
        content: PlaySession.getInstance().isFavorite(item.id) ? '取消收藏' : '收藏',
      })
        .onClick(() => {
          this.toggleFavorite(item);
        })
      // 本地歌已经在本机了、云端歌由播放缓存负责，下载这一项对它们都没有意义
      if (!isLocalSong(item) && !isWebDavSong(item)) {
        MenuItem({ content: '下载' })
          .onClick(() => {
            this.download(item);
          })
      }
      MenuItem({ content: '不喜欢的歌曲' })
        .onClick(() => {
          this.dislike(item);
        })
      MenuItem({ content: '移出播放列表' })
        .onClick(() => {
          this.deleteAt(index);
        })
    }
  }

  /** 左滑露出来的删除块 */
  @Builder
  deleteAction(index: number) {
    Row() {
      IconGlyph({ symbol: I_TRASH, iconSize: 21, color: '#FFFFFF' })
    }
    .width(76)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(C_RED)
    .onClick(() => {
      this.deleteAt(index);
    })
  }

  /**
   * 一行歌曲（照华为音乐播放列表的排法）
   *
   * 华为音乐那边一行是两行文字、**没有封面图**：
   *   第一行：歌名（正在播放的那首是红色，后面跟一排跳动的音量条图标）
   *   第二行：小标签（VIP / 空间音频这类）+「歌手 - 专辑」灰字
   *   最右：一个细的 ×（从列表里移除），没有圆圈、没有常驻垃圾桶
   * 行与行之间是内缩的分割线。
   *
   * 我们这边没有专辑字段，第二行就用「音质档 + 平台」两个小标签 + 歌手名，信息量对等；
   * 移除键沿用 ×，左滑删除与长按菜单都保留（那两个是额外能力，不占版面）。
   */
  @Builder
  chip(text: string) {
    Text(text)
      .fontSize(10)
      .fontColor(C_TEXT_SUB)
      .maxLines(1)
      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
      .backgroundColor(C_FILL_SOFT)
      .borderRadius(4)
  }

  /**
   * 这一行是不是「正在播放」的那一行
   *
   * 以前直接比 `item.id === this.currentId`。用户反馈的两行同时标红就是这么来的：队列里
   * 同一首歌出现两条（队列 = 洛雪的「试听列表」，允许「下一首播放」把同一首加两次，
   * 恢复播放现场时也可能把当前这歌再插一条），两条的 id 一样，两行就一起变红、一起显示
   * 音量条，看起来像列表坏了。
   *
   * 现在按**队列下标**判断：`items` 就是 `PlaySession.queue` 的一份顺序副本（见 refresh），
   * 行的 index 与 queue 的下标一一对应，currentIndex 只有一个值，所以无论队列里有几份
   * 同一首歌，也只会有一行亮。`currentId` 仍然读一下：它是这个组件订阅的「换歌」信号，
   * 同时顺手核一行 id —— 万一队列被别处整体换掉而这里还没来得及重读，宁可一行都不亮，
   * 也不要标错行。
   */
  private isPlaying(item: SongItem, index: number): boolean {
    return index === PlaySession.getInstance().currentIndex
      && this.currentId.length > 0
      && item.id === this.currentId;
  }

  @Builder
  songRow(item: SongItem, index: number) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Text(item.name)
            .fontSize(17)
            .fontColor(this.isPlaying(item, index) ? C_RED : C_TEXT)
            .fontWeight(this.isPlaying(item, index) ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
          if (this.isPlaying(item, index)) {
            // 正在播放：与华为音乐一样在歌名右侧放一排音量条
            IconGlyph({ symbol: I_VOLUME, iconSize: 16, color: C_RED })
          }
        }
        .width('100%')

        Row({ space: 6 }) {
          this.chip(qualityLabel(item.quality))
          if (platformName(item.source).length > 0) {
            this.chip(platformName(item.source))
          }
          if (item.singer.length > 0) {
            // 歌手名：点它进这位歌手的聚合页（共用组件，见 ui/Widgets.ets 的 SingerLink）
            Column() {
              SingerLink({ singer: item.singer, source: item.source })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      IconGlyph({ symbol: I_CLOSE, iconSize: 18, color: C_TEXT_WEAK })
        .padding({ left: 6, top: 8, bottom: 8, right: 2 })
        .onClick(() => {
          this.deleteAt(index);
        })
    }
    .width('100%')
    .height(74)
    .padding({ left: 20, right: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      PlaySession.getInstance().playAt(index);
    })
    .onTouch((event: TouchEvent) => {
      this.rememberTouch(event);
    })
    .bindContextMenu(this.rowMenu(item, index), ResponseType.LongPress)
  }

  build() {
    Column() {
      /**
       * 顶部操作行（照华为音乐播放列表）
       *
       * 左边是当前播放模式（图标 + 文字，点一下换一种），右边一个垃圾桶清空整个列表。
       * 华为音乐在同一位置就是这两样，没有「全选 / 删除多选」那种工具条。
       */
      Row() {
        Row({ space: 8 }) {
          IconGlyph({ symbol: this.modeIcon(), iconSize: 20, color: C_TEXT })
          Text(this.modeText())
            .fontSize(15)
            .fontColor(C_TEXT)
        }
        .padding({ top: 8, bottom: 8 })
        .onClick(() => {
          this.cycleMode();
        })
        Blank()
        IconGlyph({ symbol: I_TRASH, iconSize: 20, color: C_TEXT_SUB })
          .padding({ left: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.clearQueue();
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 20, right: 20 })
      .opacity(this.items.length === 0 ? 0.4 : 1)

      if (this.items.length === 0) {
        Column() {
          EmptyState({
            icon: I_QUEUE,
            text: '播放列表是空的',
            hint: '在歌单或搜索结果里点一首歌，就会进到这里',
          })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 不再套 `ListItemGroup(CARD)`：华为音乐这一页是「直接铺在面板上的一列行」，
        // 没有白卡、也没有每行一张封面，行与行之间只有一条内缩的分割线。
        List() {
          LazyForEach(this.source, (item: SongItem, index: number) => {
            ListItem() {
              this.songRow(item, index)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.deleteAction(index);
                },
                onAction: () => {
                  this.deleteAt(index);
                },
              },
            })
          }, (item: SongItem, index: number) => `${index}_${item.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 0, right: 0 })
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 20, endMargin: 20 })
        // 多备几行，别到要用的时候才建。半模态从半屏拖到满屏时视口是一口气长高的，
        // 显示区外的行默认「进了视口才创建」，新露出来的下半屏会先空一拍。
        // 根治在 `scrollSizeMode: CONTINUOUS`（见 pages/Index.ets 的 bindSheet 说明），
        // 这里用缓存把「刚长出来的那几行」提前备好，两处配合才不会有空窗期。
        // 行高 74：半屏约露 4 行、满屏约 8 行，长高那一下最多要补 4 行，缓存 6 行够用。
        .cachedCount(6)
      }

      /**
       * 内容底部的安全区留白
       *
       * 这一条不是「凑高度」，它就是列表最后一行与手势条之间的那段空隙：面板本身已经用
       * 根节点的 expandSafeArea 铺到屏幕最底部（手势条底下也是面板底色），内容这边必须
       * 自己把这段让出来，否则最后一行的 × 与手势条叠在一起、看着像被切掉。
       * bottomInset 由 pages/Index.ets 从窗口的导航指示条避让区读出来传进来
       * （读不到时为 0，此时只留 8vp 的呼吸位，不会把行顶到屏幕边）。
       */
      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    // 面板本体是半模态（半透明材质），纯文字行压在模糊的封面/页面上会发虚、不好读 ——
    // 华为音乐那一页是「一整片近实色」。这里铺 c_card（浅色纯白 / 深色 #1C1C1F），
    // 与 bindSheet 的 backgroundColor 同色（见 pages/Index.ets），标题栏与列表连成一片。
    .backgroundColor(C_CARD)
    // 把面板底色铺到屏幕最底部（bug：面板底部留出一条页面底色的黑带）。
    //
    // bindSheet 的内容区默认止步于手势条上方：面板下边缘就画在那儿，再往下露出的是页面
    // 背景（深色主题下就是一条黑带），看着像「面板提前结束了、列表被切断」。内容根节点扩进
    // 系统安全区之后，这块面板底色会一直画到屏幕物理底边（手势条底下也是卡片色），与华为
    // 音乐一致；而**排版没有变** —— 列表后面那条 bottomInset + 8 的留白仍然在内容底部，
    // 所以行不会被手势条压住。只扩 BOTTOM：顶部是系统标题栏 / 拖动条的地盘，不归这里管。
    //
    // 这也是本项目「背景层负责延伸、内容负责避让」的老规矩（见 docs/UI_REPLICA.md 里
    // 页面把背景铺进状态栏那段）：延伸靠 expandSafeArea，避让靠 bottomInset。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
