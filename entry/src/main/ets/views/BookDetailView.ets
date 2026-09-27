import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';
import { BookShelf, ShelvedBook } from '../core/book/BookShelf';
import { BookChapter, BookDetail, BookHit, BookPlayPayload, BOOK_QUALITY, BOOK_SOURCE,
  parseBookPayload } from '../core/book/BookTypes';
import { DownloadManager, DownloadItem } from '../core/download/DownloadManager';
import { PlaySession, SongItem } from '../core/player/PlaySession';
import { C_BG, C_CARD, C_DIVIDER, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION,
  F_SUB, R_COVER } from '../ui/Theme';
import { I_CLOCK, I_DOC, I_DOWNLOAD, I_HEART, I_HEART_FILLED, I_PLAY, I_REFRESH, I_VOLUME,
  IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';
import { contentColumnsFor } from '../ui/Layout';

const DOMAIN: number = 0x0001;
const TAG: string = 'BookDetailView';

/**
 * 书籍详情页（听书）
 *
 * 结构照歌单详情 / 在线详情那一套：顶部一块会滚走的头图信息（封面 + 书名 + 作者 +
 * 简介），下面是章节列表。标题栏由壳层的 HdsNavDestination 提供（只留返回键，
 * 书名在头图里已经有了）。
 *
 * 「一本有声书就是一个播放队列」：点某一集 = 把整本目录灌进播放队列并从这一集开始，
 * 所以听完会自动接着下一集（PlaySession 的队列机制照旧生效）。
 */
@Component
export struct BookDetailView {
  /** 要打开的书（来自搜索结果或书架） */
  @Prop book: BookHit;
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  @Prop windowWidth: number = 0;
  onOpenPlayer: () => void = () => {
  };
  onOpenQueue: () => void = () => {
  };
  /**
   * 当前播放条目的 id（来自播放会话）
   *
   * 订阅它 + @Watch：从播放器里切集时要立刻把「正在播第几集」标出来。
   * 不订阅的话只有本页自己触发的播放会更新高亮。
   */
  @StorageLink('ps_current_id') @Watch('onCurrentChanged') currentId: string = '';

  onCurrentChanged(): void {
    this.syncPlaying();
  }

  @State detail: BookDetail | null = null;
  @State chapters: BookChapter[] = [];
  @State loading: boolean = true;
  @State status: string = '';
  @State onShelf: boolean = false;
  @State lastChapter: number = 0;
  /** 播放中那一章的序号（-1 = 没有） */
  @State playingIndex: number = -1;

  aboutToAppear(): void {
    const shelved: ShelvedBook | null = BookShelf.getInstance().find(this.book.id);
    if (shelved !== null) {
      this.onShelf = true;
      this.lastChapter = shelved.lastChapter;
      this.detail = {
        name: shelved.book.name,
        author: shelved.book.author,
        coverUrl: shelved.book.coverUrl,
        intro: shelved.book.intro,
        kind: shelved.book.kind,
        status: shelved.book.status,
        wordCount: shelved.book.wordCount,
        tocUrl: '',
      };
      if (shelved.chapters.length > 0) {
        this.chapters = shelved.chapters;
        this.loading = false;
        this.status = `目录来自书架缓存（${shelved.chapters.length} 集）`;
        this.syncPlaying();
        return;
      }
    }
    void this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.status = '正在打开…';
    try {
      const info: BookDetail = await BookEngine.getInstance().bookInfo(this.book.sourceId, this.book);
      this.detail = info;
      this.status = '正在读目录…';
      const list: BookChapter[] = await BookEngine.getInstance().toc(this.book.sourceId, this.book, info.tocUrl);
      this.chapters = list;
      if (list.length === 0) {
        this.status = '这本书没有读到目录（书源规则可能已经失效，或这本书需要登录）';
      } else {
        this.status = `共 ${list.length} 集`;
      }
      if (this.onShelf) {
        BookShelf.getInstance().updateToc(this.book.id, list);
      }
      this.syncPlaying();
    } catch (e) {
      this.status = `打开失败：${(e as Error).message}`;
      hilog.error(DOMAIN, TAG, 'open book failed: %{public}s', (e as Error).message);
    } finally {
      this.loading = false;
    }
  }

  /** 当前播放条目是不是这本书里的某一集 */
  private syncPlaying(): void {
    const payload: BookPlayPayload | null = parseBookPayload(this.currentId);
    if (payload === null || payload.sourceId !== this.book.sourceId || payload.bookUrl !== this.book.bookUrl) {
      this.playingIndex = -1;
      return;
    }
    this.playingIndex = payload.chapterIndex;
  }

  private displayName(): string {
    const detail = this.detail;
    if (detail !== null && detail.name.length > 0) {
      return detail.name;
    }
    return this.book.name;
  }

  private authorLine(): string {
    const detail = this.detail;
    const parts: string[] = [];
    const author: string = detail !== null && detail.author.length > 0 ? detail.author : this.book.author;
    if (author.length > 0) {
      parts.push(author);
    }
    const kind: string = detail !== null && detail.kind.length > 0 ? detail.kind : this.book.kind;
    if (kind.length > 0) {
      parts.push(kind);
    }
    const status: string = detail !== null && detail.status.length > 0 ? detail.status : this.book.status;
    if (status.length > 0) {
      parts.push(status);
    }
    parts.push(this.book.sourceName);
    return parts.join(' · ');
  }

  private introText(): string {
    const detail = this.detail;
    const intro: string = detail !== null && detail.intro.length > 0 ? detail.intro : this.book.intro;
    return intro;
  }

  private toggleShelf(): void {
    if (this.onShelf) {
      BookShelf.getInstance().remove(this.book.id);
      this.onShelf = false;
      this.status = '已移出书架';
      return;
    }
    BookShelf.getInstance().add(this.book, this.chapters);
    this.onShelf = true;
    this.status = `已加入书架（${this.chapters.length} 集）`;
  }

  /**
   * 播某一集
   *
   * 把整本目录铺成队列：听书是连续听的，听完一集自动接下一集才是正常预期。
   * 条目带 BOOK_SOURCE，PlaySession 会走「书」这条链路去解析音频直链
   * （与本地歌 / 云端歌并列的第三条）。
   */
  private playFrom(index: number): void {
    if (index < 0 || index >= this.chapters.length) {
      return;
    }
    const items: SongItem[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      items.push(this.toSongItem(this.chapters[i]));
    }
    this.playingIndex = index;
    if (this.onShelf) {
      BookShelf.getInstance().updateProgress(this.book.id, index);
      this.lastChapter = index;
    }
    const chapter: BookChapter = this.chapters[index];
    this.status = `正在解析：${chapter.name}`;
    void PlaySession.getInstance().setQueueAndPlay(items, index);
  }

  private toSongItem(chapter: BookChapter): SongItem {
    const payload: BookPlayPayload = {
      sourceId: this.book.sourceId,
      bookName: this.displayName(),
      bookUrl: this.book.bookUrl,
      chapterIndex: chapter.index,
      chapterName: chapter.name,
      chapterUrl: chapter.url,
      coverUrl: this.book.coverUrl,
    };
    return {
      // 队列条目 id 用「书目 id + 章节序号」，保证一本里各集互不相同、跨书不撞
      id: `${BOOK_SOURCE}_${this.book.id}_${chapter.index}`,
      name: chapter.name,
      singer: this.displayName(),
      coverUrl: this.book.coverUrl,
      art: false,
      source: BOOK_SOURCE,
      quality: BOOK_QUALITY,
      interval: chapter.duration.length > 0 ? chapter.duration : '--:--',
      musicInfoJson: JSON.stringify(payload),
    };
  }

  // ------------------------------------------------------------ 下载

  /**
   * 下载一集
   *
   * 与播放走同一套解析（下载器里有声书那条分支直接调 `BookEngine.resolveAudioOf`），
   * 所以「能放的一定能下」。下载器把有声书**串行 + 集间留间隔**（见 DownloadManager）：
   * 点「下载整本」不会把几十集的规则解析同时打给站点。
   */
  private downloadChapter(chapter: BookChapter): void {
    const manager = DownloadManager.getInstance();
    if (!manager.isReady()) {
      this.status = '下载管理还没准备好，稍后再试';
      return;
    }
    const item: SongItem = this.toSongItem(chapter);
    const state: DownloadItem | null = manager.stateOf(item.id);
    if (state !== null && state.status === 'done') {
      this.status = `「${chapter.name}」已经下载过了`;
      return;
    }
    if (state !== null && (state.status === 'waiting' || state.status === 'downloading')) {
      this.status = `「${chapter.name}」正在下载中`;
      return;
    }
    this.status = manager.enqueue(item) !== null
      ? `已加入下载：${chapter.name}`
      : `「${chapter.name}」没法下载（缺书籍信息）`;
  }

  /** 删掉这一集的下载（文件与记录一起清） */
  private removeDownload(chapter: BookChapter): void {
    DownloadManager.getInstance().remove(this.toSongItem(chapter).id);
    this.status = `已删除下载：${chapter.name}`;
  }

  /**
   * 下载整本
   *
   * **先问一句再下**（与歌单详情 / 在线详情那颗「下载全部」同一个规矩）：一本有声书
   * 几十上百集，一集要跑一遍书源规则，点一下全排进去太莽 —— 而且下载器串行跑完
   * 整本要挺久，得让用户知道自己在等什么。
   */
  private downloadAll(): void {
    if (this.chapters.length === 0) {
      this.status = '目录还没读到，稍后再试';
      return;
    }
    const count: number = this.chapters.length;
    this.getUIContext().showAlertDialog({
      title: '下载整本',
      message: `确定要下载《${this.displayName()}》的全部 ${count} 集吗？` +
        `有声书是一集一集解析的，会慢一些；进度在「我的 - 下载管理」里看。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '下载',
          fontColor: C_RED,
          action: () => {
            this.enqueueAllChapters();
          },
        },
      ],
    });
  }

  /** 确认之后的真排队（已在列表里的不重复排） */
  private enqueueAllChapters(): void {
    const songs: SongItem[] = [];
    for (const chapter of this.chapters) {
      songs.push(this.toSongItem(chapter));
    }
    const added: number = DownloadManager.getInstance().enqueueMany(songs);
    this.status = added > 0
      ? `已加入下载 ${added} 集（共 ${this.chapters.length} 集）`
      : '整本都已经在下载列表里了';
  }

  /** 长按一集的菜单：下载 / 删除下载（没下过就不显示删除） */
  @Builder
  chapterMenu(chapter: BookChapter) {
    Menu() {
      MenuItem({ content: '下载本集' })
        .onClick(() => {
          this.downloadChapter(chapter);
        })
      if (this.isDownloaded(chapter)) {
        MenuItem({ content: '删除下载' })
          .onClick(() => {
            this.removeDownload(chapter);
          })
      }
    }
  }

  private isDownloaded(chapter: BookChapter): boolean {
    const state: DownloadItem | null =
      DownloadManager.getInstance().stateOf(this.toSongItem(chapter).id);
    return state !== null && state.status === 'done';
  }

  // ------------------------------------------------------------ 界面片段

  @Builder
  headerCard() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        CoverArt({
          url: this.book.coverUrl,
          name: this.displayName(),
          boxSize: 104,
          radius: R_COVER,
        })
        Column({ space: 7 }) {
          Text(this.displayName())
            .fontSize(F_SECTION + 1)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_TEXT)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.authorLine())
            .fontSize(F_SUB)
            .fontColor(C_TEXT_SUB)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          if (this.chapters.length > 0) {
            Row({ space: 5 }) {
              IconGlyph({ symbol: I_CLOCK, iconSize: 13, color: C_TEXT_WEAK })
                .accessibilityLevel('no')
              Text(`共 ${this.chapters.length} 集`)
                .fontSize(F_SUB)
                .fontColor(C_TEXT_WEAK)
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Row({ space: 10 }) {
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Row({ space: 6 }) {
            IconGlyph({ symbol: I_PLAY, iconSize: 17, color: Color.White })
              .accessibilityLevel('no')
            Text(this.lastChapter > 0 && this.lastChapter < this.chapters.length ? '继续听' : '从头听')
              .fontSize(15)
              .fontColor(Color.White)
          }
        }
        .height(40)
        .layoutWeight(1)
        .backgroundColor(C_RED)
        .enabled(this.chapters.length > 0)
        .onClick(() => {
          const start: number = this.lastChapter > 0 && this.lastChapter < this.chapters.length ? this.lastChapter : 0;
          this.playFrom(start);
        })

        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Row({ space: 6 }) {
            IconGlyph({
              symbol: this.onShelf ? I_HEART_FILLED : I_HEART,
              iconSize: 17,
              color: this.onShelf ? C_RED : C_TEXT,
              replaceEffect: true,
            })
              .accessibilityLevel('no')
            Text(this.onShelf ? '已在书架' : '加入书架')
              .fontSize(15)
              .fontColor(this.onShelf ? C_RED : C_TEXT)
          }
        }
        .height(40)
        .layoutWeight(1)
        .backgroundColor(C_CARD)
        .onClick(() => {
          this.toggleShelf();
        })
      }
      .width('100%')

      if (this.introText().length > 0) {
        Text(this.introText())
          .fontSize(13.5)
          .fontColor(C_TEXT_SUB)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 14 })
  }

  @Builder
  chapterRow(chapter: BookChapter) {
    Row({ space: 12 }) {
      Text(`${chapter.index + 1}`)
        .fontSize(13)
        .fontColor(this.playingIndex === chapter.index ? C_RED : C_TEXT_WEAK)
        .width(34)
        .textAlign(TextAlign.Center)

      Column({ space: 4 }) {
        Text(chapter.name)
          .fontSize(F_ITEM - 0.5)
          .fontColor(this.playingIndex === chapter.index ? C_RED : C_TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        if (chapter.duration.length > 0) {
          Text(chapter.duration)
            .fontSize(F_SUB - 1)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.playingIndex === chapter.index) {
        IconGlyph({ symbol: I_VOLUME, iconSize: 18, color: C_RED })
          .accessibilityLevel('no')
      } else {
        IconGlyph({ symbol: I_PLAY, iconSize: 16, color: C_TEXT_WEAK })
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      this.playFrom(chapter.index);
    })
    .bindContextMenu(this.chapterMenu(chapter), ResponseType.LongPress)
    .accessibilityGroup(true)
    .accessibilityText(`第 ${chapter.index + 1} 集，${chapter.name}`)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      List() {
        /**
         * 整页只有一个 ListItemGroup：组头是书籍信息卡与「目录」标题行，组内每集一行，
         * 组尾是空态与底部让位。
         *
         * 套一层组是为了宽屏多列 —— List 的 `lanes` 是按条目分的，头部当普通条目丢进去
         * 宽屏下会被挤进一列（见 ui/Layout.ets 的 contentColumnsFor）；ListItemGroup 在
         * 分栏模式下自己占满整行，组内条目再按 `lanes` 排。窄屏 `lanes` 是 1，与改之前一样。
         */
        ListItemGroup({ header: this.listHeader(), footer: this.listFooter() }) {
          ForEach(this.chapters, (chapter: BookChapter) => {
            ListItem() {
              this.chapterRow(chapter)
            }
          }, (chapter: BookChapter) => `${chapter.index}_${chapter.url}`)
        }
      }
      // 宽屏一屏多列（每列至少 360vp、最多 4 列），窄屏恒为 1 列
      .lanes(contentColumnsFor(this.windowWidth))
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.6, color: C_DIVIDER, startMargin: 46, endMargin: 0 })
      .padding({ top: this.topInset })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }

  /** 列表头部：书籍信息卡 + 「目录」标题行（宽屏通栏，见 build 的说明） */
  @Builder
  listHeader() {
    Column() {
      this.headerCard()

      Row({ space: 8 }) {
        SectionTitle({ text: '目录' })
        Blank()
        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(F_SUB - 1)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '58%' })
        }
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 19, color: C_ICON })
          .onClick(() => {
            this.downloadAll();
          })
          .accessibilityText('下载整本')
          .accessibilityLevel('yes')
        IconGlyph({ symbol: I_REFRESH, iconSize: 19, color: C_ICON })
          .onClick(() => {
            void this.load();
          })
          .accessibilityText('重新读取目录')
          .accessibilityLevel('yes')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    }
    .width('100%')
  }

  /** 列表尾部：读取中 / 没读到目录的空态 + 底部让位 */
  @Builder
  listFooter() {
    Column() {
      if (this.loading) {
        Column() {
          LoadingProgress().width(38).height(38).color(C_RED)
        }
        .width('100%')
        .padding({ top: 40 })
      } else if (this.chapters.length === 0) {
        EmptyState({
          icon: I_DOC,
          text: '没有读到目录',
          hint: this.status.length > 0 ? this.status : '这本书的书源规则可能已经失效，换一个书源试试。',
          topPadding: 32,
        })
      }

      Column().height(this.bottomInset + 96).width('100%')
    }
    .width('100%')
  }
}
