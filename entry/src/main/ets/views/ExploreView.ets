/**
 * 探索 · 心动模式刷歌页（底部页签）
 *
 * 交互（照抖音，单向不可回退）：
 *   - 进页面 / 每次换歌：自动播放当前这首
 *   - **竖向 Swiper** 翻页：下滑到下一首；翻过去就回不来（往上滑会被强制拉回当前页）
 *   - 下滑 = 跳过这首 = 不喜欢（回写强负反馈）
 *   - 双击封面 = 喜欢（收藏 + 强正反馈），单击 = 播放/暂停
 *   - 一首放完播放器自动切下一首时，页面跟着走，并把上一首记成「自然播完」而非跳过
 *
 * 为什么用 Swiper 而不是在根容器上挂 PanGesture：
 *   这套页面在 HdsTabs → TabContent 里，根容器的 PanGesture 实测拿不到事件
 *   （无论下滑多长都不触发）。Swiper 是框架自己在管的翻页容器，项目里
 *   EchoView / PlayerView 都用它，滑动可靠；「不能回翻」在 onChange 里做，
 *   发现用户往回滑就把下标强制拨回来。
 *
 * 数据分工见 core/heart/HeartRadio：画像来自本地历史 + 收藏 + 本地曲库，
 * 候选来自全网目录层（榜单 / 推荐歌单 / 艺人作品）召回的几百首；批次只在后台懒加载，
 * 界面不显示「第几批 / 共几首」。
 */

import { K_FAVORITE_IDS } from '../core/player/FavoriteIndex';
import { K_CURRENT_ID, K_PLAYER_STATUS, PlaySession, SongItem } from '../core/player/PlaySession';
import { ListenTracker } from '../core/history/ListenTracker';
import { ExploreCard, HeartRadio } from '../core/heart/HeartRadio';
import { CoverStore } from '../core/music/CoverStore';
import { C_RED, F_SUB } from '../ui/Theme';
import { CoverArt, EmptyState } from '../ui/Widgets';
import { I_CHEVRON_DOWN, I_DISC, I_HEART_FILLED, I_PAUSE, I_PLAY } from '../ui/Icons';

/** 一批多少首（只在后台懒加载时用，界面不显示） */
const BATCH_SIZE: number = 20;
/** 滑到还剩几首时提前续批 */
const REFILL_AHEAD: number = 3;
/** 双击喜欢后那颗大红心停留多久（毫秒） */
const HEART_FLASH_MS: number = 650;

@Component
export struct ExploreView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  /**
   * 本页是不是**当前页签**（由壳层 pages/Index.ets 按 activeTabKey 传进来）
   *
   * 这一页本来是「一进来就自动起播」的（心动模式），但页签内容会被框架提前挂载：
   * 冷启动时「探索」虽然不可见、也会走一遍 aboutToAppear，于是它抢先把心动那首播出来，
   * 把用户正在听的歌顶掉（群里报的「第一次进软件点开我的，稳定触发探索里的歌」）。
   * 现在自动起播只在「真的切到探索」且「本来没在放任何东西」时才发生，
   * 见 maybeAutoPlay。
   */
  @Prop @Watch('onActiveChanged') active: boolean = false;
  @State cards: ExploreCard[] = [];
  /** 当前是第几张；只增不减 —— 翻过去的回不来 */
  @State index: number = 0;
  @State loading: boolean = false;
  /** 双击喜欢后的短暂红心 */
  @State heartFlash: boolean = false;
  @StorageLink(K_FAVORITE_IDS) @Watch('onFavoritesChanged') favIds: string[] = [];
  @StorageLink(K_CURRENT_ID) @Watch('onCurrentChanged') currentId: string = '';
  @StorageLink(K_PLAYER_STATUS) playerStatus: string = 'idle';
  private radio: HeartRadio = new HeartRadio();
  private swiper: SwiperController = new SwiperController();
  /** 自己拨动 Swiper 时不要被 onChange 当成用户滑动 */
  private ownedId: string = '';
  private ownedSince: number = 0;

  private seedFromCurrent(): void {
    const current = PlaySession.getInstance().current;
    if (!this.active || current === null || current.id === this.ownedId) { return; }
    this.radio.setSessionSeed(current);
    if (this.cards.length > this.index) {
      this.cards = this.cards.slice(0, this.index).concat(this.radio.rerankUpcoming(this.cards.slice(this.index)));
    }
  }

  private finishCurrent(swiped: boolean): void {
    const card = this.card();
    if (card === null || card.item.id !== this.ownedId) { return; }
    const record = ListenTracker.getInstance().takeFeedback(this.ownedId, this.ownedSince);
    this.ownedId = '';
    if (record !== null) {
      this.radio.finishListen(card.item, record.playedMs, record.durationMs, swiped);
    }
  }

  private snapping: boolean = false;

  aboutToAppear(): void {
    // 1) 先同步读缓存：有缓存就立刻出歌（**不在这里起播**，见 maybeAutoPlay）
    this.seedFromCurrent();
    const cached: number = this.radio.prepareCached();
    if (cached > 0) {
      this.loading = false;
      this.cards = this.radio.batch(BATCH_SIZE);
    } else {
      this.loading = true;
    }
    // 2) 后台再拉一批新的替换池子（成功才落盘；失败就继续用缓存）
    this.radio.refresh().then((fresh: number) => {
      if (fresh <= 0) {
        this.loading = false;
        return;
      }
      if (this.cards.length === 0) {
        // 首次没有缓存：刷新完才出第一批
        this.loading = false;
        this.cards = this.radio.batch(BATCH_SIZE);
        this.jumpTo(0);
      }
      this.maybeAutoPlay();
    }).catch(() => {
      this.loading = false;
    });
    this.maybeAutoPlay();
  }

  /** 页签切换：切到探索这一栏时才考虑自动起播 */
  private onActiveChanged(): void {
    this.seedFromCurrent();
    this.maybeAutoPlay();
  }

  /**
   * 心动模式的「自动起播」——只在**两个条件同时成立**时才真的播
   *
   * 1. `active`：本页是当前页签。页签内容会被框架提前挂载（冷启动时「探索」不可见也会
   *    aboutToAppear），条件不放宽就会被判成「一进软件就自动放歌」，还会顶掉用户的播放；
   * 2. 播放器**不是在放**：只在 `idle/stopped/paused` 时接手。正在放的歌不许被打断 ——
   *    这是群里反馈的那个 bug 的另一半（用户听着歌切页签，歌被换掉了）。
   *    「暂停」不算在放：上次退出留下的暂停态很常见，用户主动点进探索时应该直接开始心动模式。
   */
  private maybeAutoPlay(): void {
    if (!this.active || this.cards.length === 0) {
      return;
    }
    if (this.playerStatus === 'playing' || this.playerStatus === 'loading') {
      return;
    }
    this.playCurrent();
  }

  private card(): ExploreCard | null {
    if (this.index < 0 || this.index >= this.cards.length) {
      return null;
    }
    return this.cards[this.index];
  }

  /** 无声地把 Swiper 拨到某页（不触发「用户滑动」的处理） */
  private jumpTo(target: number): void {
    if (target < 0 || target >= this.cards.length || target === this.index) {
      return;
    }
    this.snapping = true;
    this.index = target;
    this.swiper.changeIndex(target);
    this.snapping = false;
  }

  /** 播放当前这张（换歌时 setQueueAndPlay 本身就打断了上一首） */
  private playCurrent(): void {
    const card: ExploreCard | null = this.card();
    if (card === null) {
      return;
    }
    const queue: SongItem[] = [];
    for (let i = 0; i < this.cards.length; i++) {
      queue.push(this.cards[i].item);
    }
    this.ownedSince = Date.now();
    this.ownedId = card.item.id;
    PlaySession.getInstance().setQueueAndPlay(queue, this.index);
    this.radio.played(card.item.id);
  }

  /**
   * 点播放钮
   *
   * 关键：**只有在放的正是这一张时才去 toggle**。以前这里无条件 `PlaySession.toggle()`，
   * 于是「别处正在放别的歌」时点探索页的播放钮，暂停/继续的其实是别人的歌 ——
   * 用户看到的是「点了探索的歌，响的是另一首，或者干脆把另一首暂停了」。
   *
   * 现在：不是这一张 → 直接切到这一张播；就是这一张 → 才做播放/暂停切换。
   * 图标仍然按全局播放状态画（别处有歌在放时显示暂停），这与用户预期一致。
   */
  private togglePlay(): void {
    const card: ExploreCard | null = this.card();
    if (card === null) {
      return;
    }
    if (this.currentId !== card.item.id) {
      // 正在放的不是这张：切歌（不碰别人的播放状态，setQueueAndPlay 本身就是打断并重排）
      this.playCurrent();
      return;
    }
    PlaySession.getInstance().toggle();
  }

  private playing(): boolean {
    return this.playerStatus === 'playing';
  }

  private isFav(item: SongItem): boolean {
    return this.radio.isLiked(item);
  }

  /** 收藏列表变了（播放器里取消收藏等）：画像同步扣掉那一笔正反馈 */
  private onFavoritesChanged(): void {
    this.radio.syncLikes();
  }

  /**
   * 用户翻页（Swiper 回调）
   *
   * - 往后滑：上一首没被喜欢过 = 不喜欢 → 强负反馈；前进、自动播、后台续批
   * - 往前滑：**不允许回翻**，立刻把 Swiper 拨回当前页
   */
  private onSwipe(next: number): void {
    if (this.snapping || next === this.index) {
      return;
    }
    if (next < this.index) {
      // 用户想回翻：拨回当前页
      this.snapping = true;
      const current: number = this.index;
      this.swiper.changeIndex(current);
      this.snapping = false;
      return;
    }
    this.finishCurrent(true);
    const upcoming = this.radio.rerankUpcoming(this.cards.slice(next));
    this.cards = this.cards.slice(0, next).concat(upcoming);
    this.index = next;
    this.playCurrent();
    if (this.cards.length - this.index <= REFILL_AHEAD) {
      this.refill();
    }
  }

  /** 后台懒加载下一批：剩余不多时悄悄续上，界面不显示批次 */
  private refill(): void {
    if (!this.radio.isReady || this.radio.exhausted) {
      return;
    }
    const more: ExploreCard[] = this.radio.batch(BATCH_SIZE);
    if (more.length > 0) {
      this.cards = this.cards.concat(more);
    }
  }

  /** 播放器切歌时跟上页面（自然播完 = 中等正反馈，不是跳过） */
  private onCurrentChanged(): void {
    if (this.currentId.length === 0) {
      return;
    }
    const next: number = this.indexOfCard(this.currentId);
    if (next === this.index || this.currentId === this.ownedId) { return; }
    const owned = this.ownedId.length > 0;
    this.finishCurrent(false);
    if (next > this.index) {
      if (owned) {
        this.ownedId = this.currentId;
        this.ownedSince = 0;
        this.radio.played(this.currentId);
      }
      this.jumpTo(next);
    }
  }

  private indexOfCard(id: string): number {
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].item.id === id) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 双击：喜欢 / 取消喜欢
   *
   * 收藏与算法回写都交给 HeartRadio：它按「歌名+歌手」认歌，
   * 所以同一首歌在别的音源已经收藏过时不会重复加，也不会误判成"没收藏"。
   */
  private toggleFav(): void {
    const card: ExploreCard | null = this.card();
    if (card === null) {
      return;
    }
    if (this.radio.isLiked(card.item)) {
      this.radio.unlike(card.item);
      return;
    }
    this.radio.like(card.item);
    this.heartFlash = true;
    setTimeout(() => {
      this.heartFlash = false;
    }, HEART_FLASH_MS);
  }

  private coverOf(item: SongItem): string {
    return CoverStore.getInstance().coverFor(item.musicInfoJson, item.coverUrl);
  }

  // ---------------------------------------------------------------- 视图

  /** 背景：封面铺满 + 压暗（与播放页同一套深色底） */
  @Builder
  backdrop(item: SongItem) {
    Stack() {
      if (this.coverOf(item).length > 0) {
        Image(this.coverOf(item))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(48)
          .opacity(0.5)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#141418')
      }
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#66000000', 0.0], ['#B3000000', 0.5], ['#F2000000', 1.0]]
        })
    }
    .width('100%')
    .height('100%')
  }

  /** 播放钮：白色圆底 + 深色图标（与播放页主钮同一套观感） */
  @Builder
  playButton() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width(68)
        .height(68)
        .borderRadius(34)
        .backgroundColor('#F4F4F6')
        .shadow({ radius: 24, color: '#4DFFFFFF', offsetX: 0, offsetY: 0 })
      SymbolGlyph(this.playing() ? I_PAUSE : I_PLAY)
        .fontSize(26)
        .fontColor(['#17171A'])
    }
    .width(68)
    .height(68)
    .onClick(() => {
      this.togglePlay();
    })
    .accessibilityText(this.playing() ? '暂停' : '播放')
    .accessibilityLevel('yes')
  }

  /** 一张卡：封面 / 歌名 / 歌手 / 推荐理由 / 播放钮；双击封面 = 喜欢 */
  @Builder
  cardPage(card: ExploreCard) {
    Stack({ alignContent: Alignment.Center }) {
      this.backdrop(card.item)

      Column({ space: 14 }) {
        CoverArt({
          url: this.coverOf(card.item),
          name: card.item.name,
          art: card.item.art,
          boxSize: 252,
          radius: 20,
        })
          .shadow({ radius: 30, color: '#66000000', offsetX: 0, offsetY: 10 })
          .gesture(
            GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 }).onAction(() => {
                this.toggleFav();
              }),
              TapGesture({ count: 1 }).onAction(() => {
                this.togglePlay();
              }))
          )

        Column({ space: 6 }) {
          Text(card.item.name)
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
          Text(card.item.singer)
            .fontSize(14.5)
            .fontColor('#B3FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(card.reason())
            .fontSize(F_SUB)
            .fontColor('#8CFFFFFF')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Center)

        this.playButton()

        Text('双击封面喜欢')
          .fontSize(11.5)
          .fontColor('#66FFFFFF')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      // 上下让位：顶端是导航标题与「下滑换下一首」提示，底端是迷你播放条
      .padding({ left: 24, right: 24, top: this.topInset + 96, bottom: this.bottomInset + 96 })

      if (this.heartFlash) {
        SymbolGlyph(I_HEART_FILLED)
          .fontSize(96)
          .fontColor([C_RED])
          .opacity(0.85)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 空态：没有候选时的引导 */
  @Builder
  emptyPage() {
    Column() {
      EmptyState({
        icon: I_DISC,
        text: this.loading ? '正在找歌…' : '这次没取到候选',
        hint: this.loading
          ? '按你的历史与收藏，正在从全网找你可能喜欢的歌（第一次会慢几秒）'
          : '稍后下滑重试；若平台接口异常，也可能只是这一轮没取回来',
        topPadding: this.topInset + 140,
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0C0C0E')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.cards.length === 0) {
        this.emptyPage()
      } else {
        // 竖向 Swiper 接管滑动：下滑换下一首（框架级翻页，不依赖根容器手势）
        Swiper(this.swiper) {
          ForEach(this.cards, (card: ExploreCard) => {
            this.cardPage(card)
          }, (card: ExploreCard) => card.item.id)
        }
        .vertical(true)
        .loop(false)
        .indicator(false)
        .duration(260)
        .curve(Curve.Friction)
        .index(this.index)
        .width('100%')
        .height('100%')
        .onChange((next: number) => {
          this.onSwipe(next);
        })
      }

      // 顶端提示：下滑换下一首（不挡手势、不挡点击）
      if (this.cards.length > 0) {
        Column({ space: 2 }) {
          SymbolGlyph(I_CHEVRON_DOWN)
            .fontSize(16)
            .fontColor(['#99FFFFFF'])
          Text('下滑换下一首')
            .fontSize(12)
            .fontColor('#99FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ top: this.topInset + 6 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0C0C0E')
  }
}
