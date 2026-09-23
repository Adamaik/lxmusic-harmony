import { hilog } from '@kit.PerformanceAnalysisKit';

import { BookEngine } from '../core/book/BookEngine';
import { BookShelf, ShelvedBook } from '../core/book/BookShelf';
import { BookChapter, BookDetail, BookHit, BookPlayPayload, BOOK_QUALITY, BOOK_SOURCE,
  parseBookPayload } from '../core/book/BookTypes';
import { PlaySession, SongItem } from '../core/player/PlaySession';
import { C_BG, C_CARD, C_DIVIDER, C_ICON, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION,
  F_SUB, R_COVER } from '../ui/Theme';
import { I_CLOCK, I_DOC, I_HEART, I_HEART_FILLED, I_PLAY, I_REFRESH, I_VOLUME,
  IconGlyph } from '../ui/Icons';
import { CoverArt, EmptyState, SectionTitle } from '../ui/Widgets';

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
    .accessibilityGroup(true)
    .accessibilityText(`第 ${chapter.index + 1} 集，${chapter.name}`)
    .accessibilityLevel('yes')
  }

  build() {
    Column() {
      List() {
        ListItem() {
          this.headerCard()
        }

        ListItem() {
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

        if (this.loading) {
          ListItem() {
            Column() {
              LoadingProgress().width(38).height(38).color(C_RED)
            }
            .width('100%')
            .padding({ top: 40 })
          }
        } else if (this.chapters.length === 0) {
          ListItem() {
            EmptyState({
              icon: I_DOC,
              text: '没有读到目录',
              hint: this.status.length > 0 ? this.status : '这本书的书源规则可能已经失效，换一个书源试试。',
              topPadding: 32,
            })
          }
        } else {
          ForEach(this.chapters, (chapter: BookChapter) => {
            ListItem() {
              this.chapterRow(chapter)
            }
          }, (chapter: BookChapter) => `${chapter.index}_${chapter.url}`)
        }

        ListItem() {
          Column().height(this.bottomInset + 96)
        }
      }
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
}
