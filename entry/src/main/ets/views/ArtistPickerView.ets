import { ARTIST_PLATFORMS, ArtistCandidate, cachedArtistOf, LxArtist,
  resolveArtistByName } from '../core/music/MusicArtist';
import { platformName } from '../core/music/MusicList';
import { C_BG, C_DIVIDER, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB,
  platformTint } from '../ui/Theme';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';
import { I_CHEVRON_RIGHT, IconGlyph } from '../ui/Icons';
import { CONTENT_MAX_WIDTH, K_WINDOW_WIDTH, LAYOUT_UNBOUNDED, contentColumnsFor } from '../ui/Layout';

/**
 * 歌手列表页 —— 「挑一位歌手」的那一步
 *
 * 两处入口共用它：
 *   1. **回响的三格统计里「N 位歌手」那一格** —— 点进去就是这个月听过的歌手名单
 *      （带「听了 N 首」），名单里再点一位就是他的聚合页；
 *   2. **一首歌挂着几位歌手**（播放页那行「周杰伦、方文山」）—— 先在这儿选一位。
 *
 * 为什么是独立页面而不是弹层：这一页要能继续往里走（点一位 → 歌手页），
 * 而弹层上再压一层弹层，返回路径会变得很难说清；压进同一个导航栈则天然是
 * 「列表 → 歌手页 → 返回列表 → 返回上一页」。
 *
 * 头像是**现认出来的**：候选只带「名字 + 平台」，照片要按名字去平台搜一次才有
 * （见下面的 loadPics）。认到的结果会落盘（`MusicArtist` 的 ArtistStore），
 * 所以只有第一次打开这一页要联网，之后每次进来都是直接出图。
 *
 * 这一页**不认识路由**：点谁由 `onPick` 交回壳层（那里才知道怎么解析歌手、怎么压栈）。
 */
@Component
export struct ArtistPickerView {
  /** 页头那句说明（回响是「常听歌手」，一首歌是「选择歌手」） */
  @Prop title: string = '选择歌手';
  /** 副标题：这一份名单是怎么来的（'' = 不显示） */
  @Prop hint: string = '';
  @Prop candidates: ArtistCandidate[] = [];
  /** 让出标题栏那一段（壳层传来的「状态栏 + 标题栏」） */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;
  onPick: (candidate: ArtistCandidate) => void = () => {
  };
  /**
   * 解析出来的头像：候选键 -> 图片地址
   *
   * 候选本身只带「名字 + 平台」，照片要按名字去平台认（一次歌手搜索）才有。认到的
   * 结果会落盘（见 MusicArtist 的 ArtistStore），所以**只有第一次**打开这一页要联网，
   * 之后每次进来都是直接出图。
   */
  @State pics: Record<string, string> = {};
  /** 这一页已经销毁（异步解析回来时别再写状态） */
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.seedPics();
    void this.loadPics();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 一屏几列（宽屏多列，窄屏 1 列，见 ui/Layout.ets） */
  private columns(): number {
    return contentColumnsFor(this.windowWidth);
  }

  private candidateKey(item: ArtistCandidate): string {
    return `${item.source}_${item.name}`;
  }

  /** 候选自带的照片（调用方手里有时不用认）+ 缓存里已经认过的，先一次性铺上 */
  private seedPics(): void {
    const next: Record<string, string> = {};
    for (const item of this.candidates) {
      const known: string = item.picUrl !== undefined ? item.picUrl : '';
      if (known.length > 0) {
        next[this.candidateKey(item)] = known;
        continue;
      }
      const cached: LxArtist | null = cachedArtistOf(item.name);
      if (cached !== null && cached.picUrl.length > 0) {
        next[this.candidateKey(item)] = cached.picUrl;
      }
    }
    this.pics = next;
  }

  /**
   * 挨个认人取头像
   *
   * 分批（每批 4 个）而不是一次全发：回响里一个月十几位歌手，一次并发十几个请求
   * 既容易把平台的限流触发，也让界面等最慢的那个。分批还能**认到一批就显示一批**，
   * 用户看着头像一个个出来，比整页转半天的观感好。
   */
  private async loadPics(): Promise<void> {
    const pending: ArtistCandidate[] = [];
    for (const item of this.candidates) {
      if (item.name.trim().length === 0) {
        continue;
      }
      const has: string | undefined = this.pics[this.candidateKey(item)];
      if (has === undefined || has.length === 0) {
        pending.push(item);
      }
    }
    const BATCH: number = 4;
    for (let start = 0; start < pending.length; start += BATCH) {
      if (this.disposed) {
        return;
      }
      const batch: ArtistCandidate[] = pending.slice(start, start + BATCH);
      const tasks: Promise<LxArtist | null>[] = [];
      for (const item of batch) {
        tasks.push(resolveArtistByName(item.name, item.source));
      }
      const settled: PromiseSettledResult<LxArtist | null>[] = await Promise.allSettled(tasks);
      if (this.disposed) {
        return;
      }
      const next: Record<string, string> = {};
      const keys: string[] = Object.keys(this.pics);
      for (const key of keys) {
        next[key] = this.pics[key];
      }
      for (let i = 0; i < settled.length; i++) {
        const r: PromiseSettledResult<LxArtist | null> = settled[i];
        if (r.status !== 'fulfilled' || r.value === null) {
          continue;
        }
        const pic: string = r.value.picUrl;
        if (pic.length > 0) {
          next[this.candidateKey(batch[i])] = pic;
        }
      }
      this.pics = next;
    }
  }

  /** 这一位当前该显示的照片（'' = 还没解析出来） */
  private picOf(item: ArtistCandidate): string {
    const hit: string | undefined = this.pics[this.candidateKey(item)];
    return hit !== undefined ? hit : '';
  }

  /** 行尾那行小字：附加说明 + 来源平台（哪一项没有就不写） */
  private subText(item: ArtistCandidate): string {
    const parts: string[] = [];
    if (item.note.length > 0) {
      parts.push(item.note);
    }
    // 只标真正的音乐平台：回响里本地歌 / 云端歌也会算进歌手，那两类的 source 是
    // 'local' / 'webdav'，当平台名显示出来就是一句没人看得懂的黑话
    if (ARTIST_PLATFORMS.includes(item.source)) {
      parts.push(platformName(item.source));
    }
    return parts.join(' · ');
  }

  @Builder
  row(item: ArtistCandidate) {
    Row({ space: 12 }) {
      /**
       * 头像
       *
       * 有照片就用真图（`CoverArt`）；还没解析出来 / 这位在各平台都搜不到时给一块
       * **平台色的圆底、不写字** —— 拿名字首字当头像看着像「头像是坏的」，不如空着。
       * `pending: true` 是为了压掉 CoverArt 自己的首字兜底（图加载失败时也落成空底）。
       */
      if (this.picOf(item).length > 0) {
        CoverArt({
          url: this.picOf(item),
          name: item.name,
          boxSize: 44,
          radius: 22,
          pending: true,
        })
      } else {
        Column()
          .width(44)
          .height(44)
          .borderRadius(22)
          .backgroundColor(platformTint(item.source))
      }

      Column({ space: 4 }) {
        Text(item.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.subText(item))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_TEXT_WEAK })
        .accessibilityLevel('no')
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 14 })
    .onClick(() => {
      this.onPick(item);
    })
    .accessibilityText(`${item.name}，点按查看全部歌曲`)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        SectionTitle({ text: this.title })
        Blank()
        Text(`${this.candidates.length} 位`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topInset + 4, bottom: 6 })

      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
          .textAlign(TextAlign.Start)
      }

      if (this.candidates.length === 0) {
        Column() {
          EmptyState({ text: '没有可选的歌手', topPadding: 56 })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.candidates, (item: ArtistCandidate) => {
            ListItem() {
              Column() {
                this.row(item)
                Divider()
                  .strokeWidth(0.6)
                  .color(C_DIVIDER)
                  .margin({ left: 72 })
              }
              .width('100%')
            }
          }, (item: ArtistCandidate) => `${item.source}_${item.name}`)
        }
        .lanes(this.columns())
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ bottom: this.bottomInset })
      }
    }
    .width('100%')
    .height('100%')
    // 与搜索页 / 歌手页同口径限宽：这是一列内容，铺满整屏会拉得很散
    .constraintSize({ maxWidth: this.columns() > 1 ? CONTENT_MAX_WIDTH : LAYOUT_UNBOUNDED })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(C_BG)
  }
}
