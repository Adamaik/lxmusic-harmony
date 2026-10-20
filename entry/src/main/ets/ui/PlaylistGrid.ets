import { LxPlaylistItem } from '../core/music/MusicList';
import { C_TEXT } from './Theme';
import { CoverArt } from './Widgets';
import { I_PLAY, IconGlyph } from './Icons';

/**
 * 歌单大卡与它的「按行懒加载」数据源
 *
 * 两处用它：推荐页的歌单广场 / 歌单·漫游，以及「全部歌单」那一页（从分区标题右边的
 * 「更多」进来的）。两列网格的卡都一样：封面（左下压播放量角标）+ 两行歌名。
 *
 * 为什么按**行**切：LazyForEach 只认它父级那个滚动容器的可视区，所以在页面里是
 * 「外层 List 直接放 LazyForEach、每一项是一行」，行内的卡自己再平分宽度。
 * 数据源与卡抽到这里共用，行 / LazyForEach 留在各自的页面里（那是页面的滚动结构）。
 */

/** 卡片副标题：优先播放量，没有就作者 */
export function playlistMeta(item: LxPlaylistItem): string {
  if (item.playCount.length > 0) {
    return item.playCount;
  }
  return item.author;
}

/** 网格里的一行（每行最多 cols 张卡） */
export class PlaylistRow {
  items: LxPlaylistItem[] = [];
  /** 这一行的起始下标：给 ForEach 当 key 用（V1 下同 key 的条目不会重建） */
  version: number = 0;
}

/** 按 cols 个一组切行 */
export function chunkPlaylists(items: LxPlaylistItem[], cols: number): PlaylistRow[] {
  const rows: PlaylistRow[] = [];
  for (let i = 0; i < items.length; i += cols) {
    const row: PlaylistRow = new PlaylistRow();
    row.items = items.slice(i, i + cols);
    row.version = i;
    rows.push(row);
  }
  return rows;
}

/** 两列网格的数据源：按行交给 LazyForEach，只建可视区那几行 */
export class PlaylistRowSource implements IDataSource {
  private rows: PlaylistRow[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: LxPlaylistItem[], cols: number): void {
    this.rows = chunkPlaylists(items, cols);
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): PlaylistRow {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

/**
 * 歌单大卡
 *
 * 宽度由调用方给了（它是「一行 cols 张」算出来的）；封面用 `aspectRatio(1)` 撑成方的，
 * 不在这里再算一遍宽高。卡宽用 layoutWeight(1) 平分那一行，所以不足一行时要补空位。
 */
@Component
export struct PlaylistCard {
  @Prop title: string = '';
  @Prop coverUrl: string = '';
  @Prop meta: string = '';
  /** 封面兜底图（占位封面）的边长，只影响没图时的观感 */
  @Prop coverBox: number = 160;
  onOpen: () => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        CoverArt({
          url: this.coverUrl,
          name: this.title,
          art: this.coverUrl.length === 0,
          boxSize: this.coverBox,
          radius: 12,
        })
          .width('100%')
          .aspectRatio(1)

        if (this.meta.length > 0) {
          Row({ space: 4 }) {
            IconGlyph({ symbol: I_PLAY, iconSize: 11, color: '#FFFFFF' })
            Text(this.meta)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .maxLines(1)
          }
          .padding({ left: 6, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .backgroundColor('#66000000')
          .margin({ left: 8, bottom: 8 })
        }
      }
      .width('100%')

      Text(this.title)
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .lineHeight(16)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen();
    })
    .accessibilityText(`${this.title}，歌单，${this.meta}`)
    .accessibilityLevel('yes')
  }
}
