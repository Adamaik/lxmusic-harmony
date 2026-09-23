import { K_HISTORY_VERSION, K_LIBRARY_VERSION, PlaySession, PlaylistSummary, SongItem } from '../core/player/PlaySession';
import { K_FAVORITE_IDS } from '../core/player/FavoriteIndex';
import { K_SYNC_DATA_VERSION, SyncManager } from '../core/sync/SyncManager';
import { CollectedPlaylist, CollectedPlaylists, K_COLLECTED_VERSION, collectedKeyOf } from '../core/sync/CollectedPlaylists';
import { OnlineRoute, platformName } from '../core/music/MusicList';
import { LOVE_LIST_NAME } from '../core/sync/SyncTypes';
import { K_LOCAL_VERSION, LocalMusic } from '../core/local/LocalMusic';
import { K_DOWNLOAD_VERSION, DownloadManager } from '../core/download/DownloadManager';
import { K_WEBDAV_VERSION, WebDavLibrary } from '../core/webdav/WebDavLibrary';
import { C_BG, C_CARD, C_CHEVRON, C_DIVIDER, C_FILL_SOFT, C_PRESSED, C_RED, C_RED_TINT, C_TEXT,
  C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SECTION, F_SUB, R_CARD } from '../ui/Theme';
import { I_CHEVRON_RIGHT, I_CLOCK, I_CLOUD, I_DOWNLOAD, I_FOLDER, I_GEAR, I_HEART_FILLED, I_HELP,
  I_IMPORT, I_PLAYLIST, I_PLUS, IconGlyph } from '../ui/Icons';
import { CoverArt, TopFade } from '../ui/Widgets';
import { dustBus, DustPoint, dustPointOf } from '../ui/Dust';
import { ImportPlaylistSheet } from './ImportPlaylistSheet';

/**
 * 「我的」页那一排快捷入口
 *
 * 结构照华为音乐的「我的」：图标 + 名字 + 条数，点一下进对应的子页面（收藏进的是
 * 那张内置收藏歌单的详情）。顺序也照它：本地 / 最近播放 / 收藏 / 下载 / 云端。
 * 只收我们自己有的东西 —— 它页面上那些会员、权益兑换、关注、已购之类我们没有的，一律不做。
 */
interface MineEntry {
  icon: Resource;
  label: string;
  action: string;
}

const ENTRIES: MineEntry[] = [
  { icon: I_FOLDER, label: '本地音乐', action: 'local' },
  { icon: I_CLOCK, label: '最近播放', action: 'history' },
  { icon: I_HEART_FILLED, label: '收藏', action: 'favorites' },
  { icon: I_DOWNLOAD, label: '下载管理', action: 'downloads' },
  { icon: I_CLOUD, label: '云端音乐', action: 'cloud' },
];

/** 底部那张卡里的两行（都落到设置那一套子页面上去） */
interface MineLink {
  icon: Resource;
  label: string;
  action: string;
}

const LINKS: MineLink[] = [
  { icon: I_GEAR, label: '设置', action: 'settings' },
  { icon: I_HELP, label: '帮助和反馈', action: 'about' },
];

/**
 * 我的页
 *
 * 照华为音乐的「我的」重排：上面一排快捷入口（本地音乐 / 最近播放 / 收藏 / 下载管理 / 云端音乐），
 * 中间一张歌单卡（自建歌单 + 新建歌单 / 歌单导入 动作区 + 歌单列表），
 * 下面一张设置卡（设置 / 帮助和反馈）。
 *
 * 「收藏」指收藏的**歌**（内置那张收藏歌单，洛雪的 loveList），点进去是它的详情。
 * 「收藏歌单」（收藏别人的歌单）不在这里：那说的是推荐页上的在线歌单，
 * 所以那一段跟着推荐页走（见 views/RecommendView.ets）—— 本地自己的歌单没有收藏这回事。
 *
 * 与改之前的区别（原来这里是「播放历史 / 下载管理 / 本地音乐 / 云端音乐」四段胶囊 + 列表）：
 *   - 那四段现在各自是**子页面**（点快捷入口进去，页内自带迷你播放条），
 *     所以「歌单」「设置」两个页签也没有必要了 —— 它们的内容就在这一页里；
 *   - 歌单不再只是「进歌单页看列表」：自建歌单直接在卡里列出，长按仍是原来的
 *     「添加到收藏 / 重命名 / 删除」，卡里那块浅灰底就是新建与导入两个入口。
 */
@Component
export struct MineView {
  /** 内容起始偏移：让出透明标题栏那一段（状态栏 + 标题栏，由壳层算好） */
  @Prop topInset: number = 0;
  /** 内容底部要留出的空间：悬浮页签栏 + 手势条（由壳层算好） */
  @Prop bottomInset: number = 0;
  /** 去某个子页面（本地音乐 / 播放历史 / 下载 / 云端 / 设置 / 关于），路由由壳层实现 */
  onNavigate: (action: string) => void = () => {
  };
  /** 点歌单 → 打开歌单详情（与壳层那套路由同一个入口） */
  onOpenPlaylist: (playlist: PlaylistSummary) => void = () => {
  };
  /** 收藏歌单那一段点开的还是**在线**歌单，路由也交给壳层（在线详情页） */
  onOpenOnline: (route: OnlineRoute) => void = () => {
  };
  @State playlists: PlaylistSummary[] = [];
  /** 歌单卡当前那一段：0 = 自建歌单（自己建的 + 导入的），1 = 收藏歌单（收来的在线歌单） */
  @State playlistTab: number = 0;
  /**
   * 收藏的在线歌单（按收藏顺序，最近的在前）
   *
   * 入口在推荐页（行尾爱心 / 长按多选），这里只是**列表**：和「自建歌单」并排两段，
   * 两边**互斥** —— 同一张歌单不会两段都出现（收藏来的都是线上歌单，本来就不在自建里；
   * 反过来导入过的不再让收，见 core/sync/CollectedPlaylists 的说明）。
   * 与「收藏的歌」（那个内置歌单）没有任何关系，两者是不同的东西。
   */
  @State collected: CollectedPlaylist[] = [];
  /** 内置那张收藏歌单（我的收藏）里的歌数 —— 快捷入口「收藏」下面那行数字 */
  @State favoriteCount: number = 0;
  @State localCount: number = 0;
  @State historyCount: number = 0;
  @State downloadCount: number = 0;
  @State cloudCount: number = 0;
  /** 新建 / 重命名共用的小面板：editingId 为空表示新建 */
  @State editOpen: boolean = false;
  @State editingId: string = '';
  @State editName: string = '';
  /** 「导入歌单」面板（粘贴第三方歌单分享链接） */
  @State importOpen: boolean = false;
  /** 最近一次触摸点：删除歌单时在这里撒一把粒子（普通字段，不引起重绘） */
  private dustX: number = 0;
  private dustY: number = 0;
  /**
   * 各个库的版本号：任何一个变了，卡片上的条数与歌单列表就重算一次
   *
   * 全部挂同一个 `refresh`：这一页的数据来自五个不同的模块（同步库 / 播放会话 /
   * 本地音乐 / 下载管理 / 云端曲库），谁变了都得重新读一遍，没必要各写一个分支。
   */
  @StorageLink(K_LIBRARY_VERSION) @Watch('refresh') libraryVersion: number = 0;
  @StorageLink(K_SYNC_DATA_VERSION) @Watch('refresh') syncVersion: number = 0;
  @StorageLink(K_HISTORY_VERSION) @Watch('refresh') historyVersion: number = 0;
  @StorageLink(K_FAVORITE_IDS) @Watch('refresh') favoriteIds: string[] = [];
  @StorageLink(K_LOCAL_VERSION) @Watch('refresh') localVersion: number = 0;
  @StorageLink(K_DOWNLOAD_VERSION) @Watch('refresh') downloadVersion: number = 0;
  @StorageLink(K_WEBDAV_VERSION) @Watch('refresh') webdavVersion: number = 0;
  /** 收藏歌单在别处被改了（推荐页的爱心 / 多选）时重读一次那一段 */
  @StorageLink(K_COLLECTED_VERSION) @Watch('refresh') collectedVersion: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const library = SyncManager.getInstance().getLibrary();
    this.playlists = library.playlistSummaries();
    this.collected = CollectedPlaylists.getInstance().list();
    this.favoriteCount = library.favoritePlaylistSummary().count;
    this.localCount = LocalMusic.getInstance().songsForUi().length;
    this.historyCount = PlaySession.getInstance().history.length;
    this.downloadCount = DownloadManager.getInstance().list().length;
    this.cloudCount = WebDavLibrary.getInstance().songsForUi().length;
  }

  /** 快捷入口下面那行条数 */
  private countOf(action: string): number {
    if (action === 'local') {
      return this.localCount;
    }
    if (action === 'history') {
      return this.historyCount;
    }
    if (action === 'favorites') {
      return this.favoriteCount;
    }
    if (action === 'downloads') {
      return this.downloadCount;
    }
    return this.cloudCount;
  }

  // ------------------------------------------------------------ 歌单：新建 / 重命名 / 删除

  private openCreate(): void {
    this.editingId = '';
    this.editName = '';
    this.editOpen = true;
  }

  private openRename(item: PlaylistSummary): void {
    this.editingId = item.id;
    this.editName = item.name;
    this.editOpen = true;
  }

  private submitEdit(): void {
    const name: string = this.editName.trim();
    if (name.length === 0) {
      return;
    }
    const library = SyncManager.getInstance().getLibrary();
    if (this.editingId.length === 0) {
      library.createPlaylist(name);
    } else {
      library.renamePlaylist(this.editingId, name);
    }
    this.editOpen = false;
    this.refresh();
  }

  private removePlaylist(item: PlaylistSummary): void {
    this.getUIContext().showAlertDialog({
      title: '删除歌单',
      message: `确定要删除「${item.name}」吗？删除会同步到其它设备。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            SyncManager.getInstance().getLibrary().removePlaylists([item.id]);
            // 删除给一点粒子飘散（在触摸点撒，不在支持的系统上自动不做）
            dustBus.spray(this.dustX, this.dustY);
            this.refresh();
          },
        },
      ],
    });
  }

  /** 把整张歌单的歌批量加进收藏（收藏是参与同步的数据，只上行一次） */
  private addPlaylistToFavorites(item: PlaylistSummary): void {
    const songs: SongItem[] = SyncManager.getInstance().getLibrary().playlistSongs(item.id);
    if (songs.length === 0) {
      this.toast(`「${item.name}」还没有歌曲`);
      return;
    }
    const added: number = PlaySession.getInstance().addFavorites(songs);
    this.toast(added > 0
      ? `已把「${item.name}」的 ${added} 首歌添加到${LOVE_LIST_NAME}`
      : `「${item.name}」里的歌都已经在${LOVE_LIST_NAME}里了`);
  }

  // ------------------------------------------------------------ 收藏歌单（收来的在线歌单）

  /** 收藏段里的一行点开：走在线详情页（收藏只是记一下，不把它拉成本地歌单） */
  private openCollected(entry: CollectedPlaylist): void {
    const route: OnlineRoute = {
      kind: 'playlist',
      source: entry.source,
      id: entry.id,
      name: entry.name,
      cover: entry.cover,
    };
    this.onOpenOnline(route);
  }

  /** 收藏段那一行的第二行说明：先标平台（收来的歌单可能不在当前推荐来源上），再接收藏时那份说明 */
  private collectedMeta(entry: CollectedPlaylist): string {
    const platform: string = platformName(entry.source);
    return entry.meta.length > 0 ? `${platform} · ${entry.meta}` : platform;
  }

  /** 取消收藏一张（只去掉收藏这一位，什么都不动） */
  private uncollect(entry: CollectedPlaylist): void {
    CollectedPlaylists.getInstance().remove(entry.source, entry.id);
    this.refresh();
    this.toast(`已取消收藏「${entry.name}」`);
  }

  /** 记住这次触摸的位置：删除歌单时拿它当粒子飘散的起点 */
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

  // ------------------------------------------------------------ 界面

  /**
   * 快捷入口卡（照华为音乐那一排：图标在上面，名字与条数在下面）
   *
   * 四个入口平分宽度，不做横向滚动：数量是固定的四样，平分比「露出半截」更好点。
   */
  @Builder
  quickCard() {
    Row() {
      ForEach(ENTRIES, (entry: MineEntry) => {
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Center }) {
            // 图标底：淡红方块 + 红图形（与设置页的圆底色是同一套语汇，形状随这排入口改成圆角方）
            Column()
              .width(44)
              .height(44)
              .borderRadius(15)
              .backgroundColor(C_RED_TINT)
            IconGlyph({ symbol: entry.icon, iconSize: 23, color: C_RED })
          }
          .width(44)
          .height(44)

          Text(entry.label)
            .fontSize(F_SUB + 0.5)
            .fontColor(C_TEXT)
            .maxLines(1)
          Text(`${this.countOf(entry.action)}`)
            .fontSize(11)
            .fontColor(C_TEXT_WEAK)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .borderRadius(14)
        .stateStyles({
          normal: { .backgroundColor(Color.Transparent) },
          pressed: { .backgroundColor(C_PRESSED) },
        })
        .onClick(() => {
          this.onNavigate(entry.action);
        })
        .accessibilityText(`${entry.label}，共 ${this.countOf(entry.action)} 首`)
        .accessibilityLevel('yes')
      }, (entry: MineEntry) => entry.action)
    }
    .width('100%')
    .padding({ top: 16, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  /**
   * 歌单卡里那块浅灰底的「动作区」（照华为音乐：新建歌单 / 歌单导入 并排）
   *
   * 参数只用一个下标（@Builder 的参数按值传，回调统一走本页的方法）。
   */
  @Builder
  cardAction(index: number) {
    Column({ space: 6 }) {
      IconGlyph({ symbol: index === 0 ? I_PLUS : I_IMPORT, iconSize: 23, color: C_TEXT })
      Text(index === 0 ? '新建歌单' : '歌单导入')
        .fontSize(F_SUB + 0.5)
        .fontColor(C_TEXT)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .stateStyles({
      normal: { .backgroundColor(Color.Transparent) },
      pressed: { .backgroundColor(C_PRESSED) },
    })
    .onClick(() => {
      if (index === 0) {
        this.openCreate();
      } else {
        this.importOpen = true;
      }
    })
    .accessibilityText(index === 0 ? '新建歌单' : '导入歌单')
    .accessibilityLevel('yes')
  }

  /** 歌单行：图形占位封面 + 名字 + 曲目数 + 右箭头（长按是重命名 / 删除那套菜单） */
  @Builder
  playlistRow(item: PlaylistSummary, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(0.6)
          .color(C_DIVIDER)
          .margin({ left: 72 })
      }

      Row({ space: 12 }) {
        // 歌单没有封面图，用一块淡底 + 歌单图形占位（位置与华为音乐那排封面一致）
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width(46)
            .height(46)
            .borderRadius(14)
            .backgroundColor(C_RED_TINT)
          IconGlyph({ symbol: I_PLAYLIST, iconSize: 22, color: C_RED })
        }
        .width(46)
        .height(46)

        Column({ space: 4 }) {
          Text(item.name)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(`${item.count} 首`)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
          .accessibilityLevel('no')
      }
      .width('100%')
      .height(70)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        this.onOpenPlaylist(item);
      })
      .onTouch((event: TouchEvent) => {
        this.rememberTouch(event);
      })
      .bindContextMenu(this.rowMenu(item), ResponseType.LongPress)
    }
    .width('100%')
  }

  @Builder
  rowMenu(item: PlaylistSummary) {
    Menu() {
      MenuItem({ content: '添加到收藏' })
        .onClick(() => {
          this.addPlaylistToFavorites(item);
        })
      MenuItem({ content: '重命名' })
        .onClick(() => {
          this.openRename(item);
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          this.removePlaylist(item);
        })
    }
  }

  /** 收藏歌单那一段的行：在线封面 + 名字 + 平台·说明 + 右箭头（长按可取消收藏） */
  @Builder
  collectedRow(entry: CollectedPlaylist, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(0.6)
          .color(C_DIVIDER)
          .margin({ left: 72 })
      }

      Row({ space: 12 }) {
        CoverArt({
          url: entry.cover,
          name: entry.name,
          art: entry.cover.length === 0,
          boxSize: 46,
          radius: 14,
        })

        Column({ space: 4 }) {
          Text(entry.name)
            .fontSize(F_ITEM)
            .fontColor(C_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Text(this.collectedMeta(entry))
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
          .accessibilityLevel('no')
      }
      .width('100%')
      .height(70)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        this.openCollected(entry);
      })
      .bindContextMenu(this.collectedMenu(entry), ResponseType.LongPress)
    }
    .width('100%')
  }

  /** 收藏歌单那一段的行菜单：只有「取消收藏歌单」（那只记着平台 + 歌单 id，别的不动） */
  @Builder
  collectedMenu(entry: CollectedPlaylist) {
    Menu() {
      MenuItem({ content: '取消收藏歌单' })
        .onClick(() => {
          this.uncollect(entry);
        })
    }
  }

  /**
   * 歌单卡：自建歌单 | 收藏歌单 两段
   *
   * 头部两个标题点一下就换段（当前那段加黑）。两段**互斥** —— 同一张歌单不会两边都出现：
   *   - 自建歌单 = 自己建的 + 从线上导入的（都在本地库里，见 LocalLibrary）；
   *   - 收藏歌单 = 在**在线歌单页**上点「收藏歌单」收下来的（只有平台 + 歌单 id，纯本地）。
   * 已经导入到自建里的那张不再让收（在线歌单页会拦），反过来收藏着的被导入时会把收藏
   * 记录摘掉 —— 两边都堵住，所以不会重复。与快捷入口那个「收藏」（收藏的**歌**）无关。
   */
  @Builder
  playlistCard() {
    Column() {
      Row({ space: 6 }) {
        Text('自建歌单')
          .fontSize(F_SECTION)
          .fontWeight(this.playlistTab === 0 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.playlistTab === 0 ? C_TEXT : C_TEXT_SUB)
          .onClick(() => {
            this.playlistTab = 0;
          })
        Text(`${this.playlists.length}`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Text('|')
          .fontSize(F_SECTION)
          .fontColor(C_DIVIDER)
          .padding({ left: 2, right: 2 })
        Text('收藏歌单')
          .fontSize(F_SECTION)
          .fontWeight(this.playlistTab === 1 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.playlistTab === 1 ? C_TEXT : C_TEXT_SUB)
          .onClick(() => {
            this.playlistTab = 1;
          })
        Text(`${this.collected.length}`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
        Blank()
      }
      .width('100%')
      .height(54)
      .padding({ left: 14, right: 14 })

      if (this.playlistTab === 1) {
        if (this.collected.length === 0) {
          Column({ space: 6 }) {
            IconGlyph({ symbol: I_HEART_FILLED, iconSize: 28, color: C_TEXT_WEAK })
              .accessibilityLevel('no')
            Text('还没有收藏的歌单')
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
            Text('在推荐页点开一张歌单，点里面的「收藏歌单」就会收进来')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
          }
          .width('100%')
          .padding({ top: 16, bottom: 28 })
          .alignItems(HorizontalAlign.Center)
        } else {
          ForEach(this.collected, (entry: CollectedPlaylist, index: number) => {
            this.collectedRow(entry, index > 0)
          }, (entry: CollectedPlaylist) => collectedKeyOf(entry.source, entry.id))
        }
      } else {
        /**
         * 动作区（新建歌单 / 歌单导入）
         *
         * 左右必须离卡片边留出一段：这里**外面套一层带内边距的容器**，而不是给这条
         * `width('100%')` 再叠 `margin` —— 百分比宽度是按父容器算的，叠上外边距就比卡片还宽，
         * 右边被 `clip(true)` 切掉、左边贴着边，看着就是「这条没留边」。
         */
        Column() {
          Row() {
            this.cardAction(0)
            this.cardAction(1)
          }
          .width('100%')
          .height(64)
          .borderRadius(16)
          .backgroundColor(C_FILL_SOFT)
          .clip(true)
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: 10 })

        if (this.playlists.length === 0) {
          Text('还没有歌单，点上面的「新建歌单」建一个，或者用「歌单导入」粘贴一张分享链接')
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .padding({ left: 14, right: 14, top: 4, bottom: 18 })
            .textAlign(TextAlign.Start)
        } else {
          ForEach(this.playlists, (item: PlaylistSummary, index: number) => {
            this.playlistRow(item, index > 0)
          }, (item: PlaylistSummary) => `${item.id}_${item.count}_${item.name}`)
        }
      }
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  /** 设置卡：设置 / 帮助和反馈（与华为音乐底部那张卡同构） */
  @Builder
  linksCard() {
    Column() {
      ForEach(LINKS, (row: MineLink, index: number) => {
        Column() {
          if (index > 0) {
            Divider()
              .strokeWidth(0.6)
              .color(C_DIVIDER)
              .margin({ left: 50 })
          }

          Row({ space: 14 }) {
            IconGlyph({ symbol: row.icon, iconSize: 22, color: C_TEXT })
            Text(row.label)
              .fontSize(F_ITEM)
              .fontColor(C_TEXT)
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            IconGlyph({ symbol: I_CHEVRON_RIGHT, iconSize: 18, color: C_CHEVRON })
              .accessibilityLevel('no')
          }
          .width('100%')
          .height(58)
          .padding({ left: 14, right: 14 })
          .stateStyles({
            normal: { .backgroundColor(Color.Transparent) },
            pressed: { .backgroundColor(C_PRESSED) },
          })
          .onClick(() => {
            this.onNavigate(row.action);
          })
          .accessibilityText(row.label)
          .accessibilityLevel('yes')
        }
        .width('100%')
      }, (row: MineLink) => row.action)
    }
    .width('100%')
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
    .clip(true)
  }

  @Builder
  editSheet() {
    Column({ space: 12 }) {
      Text(this.editingId.length === 0 ? '新建歌单' : '重命名歌单')
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .width('100%')
        .textAlign(TextAlign.Start)
      TextInput({ text: this.editName, placeholder: '歌单名称' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 14 })
        .fontSize(14)
        .height(46)
        .backgroundColor(C_FILL_SOFT)
        .onChange((value: string) => {
          this.editName = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_FILL_SOFT)
          .fontColor(C_TEXT)
          .onClick(() => {
            this.editOpen = false;
          })
        Button('确定')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_RED)
          .onClick(() => {
            this.submitEdit();
          })
      }
      .width('100%')

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  @Builder
  importSheet() {
    ImportPlaylistSheet({
      bottomInset: this.bottomInset,
      onDone: (message: string) => {
        this.importOpen = false;
        this.toast(message);
      },
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column({ space: 14 }) {
            // 顶部占位：第一张卡落在透明标题栏下方，但它跟着内容一起滚走
            // （用容器内边距会把这一段裁在标题栏下缘，看着像「被顶栏挡住」）
            Column().height(this.topInset + 6).width('100%')

            this.quickCard()
            this.playlistCard()
            this.linksCard()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: this.bottomInset + 16 })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .align(Alignment.Top)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.editOpen, this.editSheet(), {
        preferType: SheetType.BOTTOM,
        detents: [SheetSize.MEDIUM],
        detentSelection: SheetSize.MEDIUM,
        dragBar: true,
        showClose: false,
        title: { title: this.editingId.length === 0 ? '新建歌单' : '重命名' },
      })

      // 顶栏渐隐：卡片从透明标题栏底下穿过时靠近顶部淡出，别顶穿「我的」两个字
      TopFade({ fadeHeight: this.topInset + 10 })

      // 导入面板：挂在另一个 1x1 节点上（上面那个节点已经占了新建面板）
      Column()
        .width(1)
        .height(1)
        .bindSheet($$this.importOpen, this.importSheet(), {
          preferType: SheetType.BOTTOM,
          detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.LARGE,
          dragBar: true,
          showClose: true,
          title: { title: '导入歌单' },
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
