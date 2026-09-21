import { PlaylistLink, linkOf, resolveShareText } from '../core/music/PlaylistLink';
import {
  LxListDetail,
  LxListInfo,
  PlaylistDetailProgress,
  getPlaylistDetail,
  getPlaylistDetailAll,
  platformName,
} from '../core/music/MusicList';
import { PlaySession, PlaylistSummary, SongItem, songFromSearch } from '../core/player/PlaySession';
import { SyncManager } from '../core/sync/SyncManager';
import { C_CARD, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';
import { I_DOWNLOAD, IconGlyph } from '../ui/Icons';
import { CoverArt } from '../ui/Widgets';

/** 预览里最多列几首：够确认「解析对了没有」，又不至于把面板撑满 */
const PREVIEW_SONGS: number = 6;

/**
 * 「导入歌单」面板
 *
 * 两条入口共用：
 *   1. 歌单页右上角的导入钮 —— 粘贴第三方歌单的分享内容（整段分享文本或一条链接），
 *      由 core/music/PlaylistLink 认出平台与歌单 id；
 *   2. 在线歌单详情页的导入钮 —— 平台与 id 已经知道，直接带进来（presetSource/presetId）。
 *
 * 流程与洛雪一致：解析出平台+id 后先取一页做预览（歌单名/作者/曲目数），
 * 用户确认再拉全量歌曲落成本地歌单（core/sync/LocalLibrary.importPlaylist）。
 * 同一个线上歌单导入过的话，这里会变成「更新已有歌单」——不会重复建列表。
 */
@Component
export struct ImportPlaylistSheet {
  @Prop bottomInset: number = 0;
  /** 从在线歌单详情页进来时带着平台与歌单 id，省掉粘贴解析这一步 */
  @Prop presetSource: string = '';
  @Prop presetId: string = '';
  /** 进入时已知的歌单名（在线详情页有） */
  @Prop presetName: string = '';
  /** 导入 / 更新完成，由宿主弹提示 */
  onDone: (message: string) => void = () => {
  };
  @State shareText: string = '';
  @State busy: boolean = false;
  /** 过程提示（正在解析 / 正在获取歌曲 x/y） */
  @State status: string = '';
  @State error: string = '';
  @State link: PlaylistLink | null = null;
  @State info: LxListInfo = { name: '', img: '', desc: '', author: '', playCount: '' };
  @State total: number = 0;
  @State preview: SongItem[] = [];
  /** 要导入成的歌单名（默认取线上歌单名，可改） */
  @State listName: string = '';
  /** 同一个线上歌单已经导入过：这次是更新而不是新建 */
  @State existing: PlaylistSummary | null = null;

  aboutToAppear(): void {
    if (this.presetSource.length > 0 && this.presetId.length > 0) {
      this.link = linkOf(this.presetSource, this.presetId);
      this.status = `正在读取${platformName(this.presetSource)}歌单…`;
      void this.loadPreview();
      return;
    }
    this.status = '支持网易云 / QQ / 酷狗 / 酷我 / 咪咕的歌单分享链接';
  }

  private toastable(message: string): void {
    this.error = message;
    this.status = '';
  }

  /** 解析粘贴的分享内容：先本地正则，抠不出来再跟随短链 */
  private async parse(): Promise<void> {
    if (this.busy) {
      return;
    }
    const text: string = this.shareText.trim();
    if (text.length === 0) {
      this.error = '请先粘贴歌单分享内容';
      return;
    }
    this.busy = true;
    this.error = '';
    this.status = '正在解析链接…';
    this.link = null;
    this.preview = [];
    this.total = 0;
    this.existing = null;
    this.listName = '';
    try {
      const link: PlaylistLink = await resolveShareText(text);
      this.link = link;
      this.status = `已识别：${platformName(link.source)} · 歌单 id ${link.id}`;
      await this.loadPreview();
    } catch (e) {
      this.toastable((e as Error).message);
    } finally {
      this.busy = false;
    }
  }

  /** 取第一页做预览，并查一下这个线上歌单是不是已经导入过 */
  private async loadPreview(): Promise<void> {
    const link: PlaylistLink | null = this.link;
    if (link === null) {
      return;
    }
    try {
      const detail: LxListDetail = await getPlaylistDetail(link.source, link.id, 1);
      const quality: string = PlaySession.getInstance().quality;
      const items: SongItem[] = [];
      for (const music of detail.list) {
        items.push(songFromSearch(music, quality));
      }
      this.info = detail.info;
      this.total = detail.total > 0 ? detail.total : items.length;
      this.preview = items.slice(0, PREVIEW_SONGS);
      if (this.listName.length === 0) {
        this.listName = this.defaultName();
      }
      this.existing = SyncManager.getInstance().getLibrary().playlistBySourceListId(link.listId);
      if (items.length === 0) {
        this.toastable('这个歌单里没有取到歌曲（可能是私密歌单、已失效，或该平台接口暂时不可用）');
      }
    } catch (e) {
      this.toastable(`获取歌单失败：${(e as Error).message}`);
    }
  }

  /** 歌单名：线上名字 > 进入时已知的名字 > 兜底 */
  private defaultName(): string {
    if (this.info.name.length > 0) {
      return this.info.name;
    }
    if (this.presetName.length > 0) {
      return this.presetName;
    }
    return '导入的歌单';
  }

  /** 拉全量歌曲并落库（同一个线上歌单再导一次就是原地更新） */
  private async doImport(): Promise<void> {
    const link: PlaylistLink | null = this.link;
    if (link === null || this.busy) {
      return;
    }
    const name: string = this.listName.trim().length > 0 ? this.listName.trim() : this.defaultName();
    this.busy = true;
    this.error = '';
    this.status = '正在获取歌单歌曲…';
    try {
      const detail: LxListDetail = await getPlaylistDetailAll(link.source, link.id,
        (progress: PlaylistDetailProgress) => {
          this.status = progress.total > 0
            ? `正在获取歌曲 ${progress.loaded}/${progress.total}…`
            : `正在获取歌曲 ${progress.loaded} 首…`;
        });
      const quality: string = PlaySession.getInstance().quality;
      const items: SongItem[] = [];
      for (const music of detail.list) {
        items.push(songFromSearch(music, quality));
      }
      if (items.length === 0) {
        this.toastable('这个歌单里没有歌曲，没法导入');
        return;
      }
      const updated: boolean = this.existing !== null;
      const summary: PlaylistSummary | null = SyncManager.getInstance().getLibrary()
        .importPlaylist(name, link.source, link.listId, items);
      if (summary === null) {
        this.toastable('这些歌曲没法导入（缺少歌曲信息）');
        return;
      }
      this.existing = summary;
      this.status = '';
      // 先收掉忙碌态再回调：宿主收到回调就会关面板（面板随即销毁），
      // 之后别再往自己的状态上写
      this.busy = false;
      this.onDone(updated
        ? `已用线上数据更新「${summary.name}」共 ${summary.count} 首`
        : `已导入「${summary.name}」共 ${summary.count} 首`);
    } catch (e) {
      this.toastable(`导入失败：${(e as Error).message}`);
    } finally {
      this.busy = false;
    }
  }

  private canImport(): boolean {
    return this.link !== null && !this.busy && this.info.name.length > 0;
  }

  @Builder
  linkInput() {
    Column({ space: 10 }) {
      Text('把歌单分享内容整段粘贴进来（长按输入框可粘贴），会自动识别平台与歌单')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .textAlign(TextAlign.Start)
      TextArea({
        text: this.shareText,
        placeholder: '例如：分享歌单《周杰伦》https://music.163.com/#/playlist?id=123456',
      })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 13.5 })
        .fontSize(13.5)
        .height(88)
        .borderRadius(12)
        .backgroundColor('#F2F2F4')
        .onChange((value: string) => {
          this.shareText = value;
        })
      Row({ space: 12 }) {
        Button(this.busy ? '解析中…' : '解析歌单')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .backgroundColor(C_RED)
          .enabled(!this.busy && this.shareText.trim().length > 0)
          .onClick(() => {
            void this.parse();
          })
        Button('清空')
          .height(42)
          .fontSize(15)
          .backgroundColor('#E8E8EA')
          .fontColor(C_TEXT)
          .enabled(!this.busy && this.shareText.length > 0)
          .onClick(() => {
            this.shareText = '';
            this.link = null;
            this.preview = [];
            this.error = '';
            this.status = '';
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  /** 解析结果：封面 + 名字 + 作者 + 曲目数（确认没解析错） */
  @Builder
  previewCard() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        CoverArt({
          url: this.info.img,
          name: this.info.name,
          art: this.info.img.length === 0,
          boxSize: 62,
          radius: 14,
        })
        Column({ space: 5 }) {
          Text(this.info.name)
            .fontSize(F_ITEM)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          Row({ space: 8 }) {
            Text(this.link === null ? '' : platformName(this.link.source))
              .fontSize(11.5)
              .fontColor(C_RED)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(8)
              .backgroundColor('#14E33B3B')
            if (this.info.author.length > 0) {
              Text(this.info.author)
                .fontSize(F_SUB)
                .fontColor(C_TEXT_SUB)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
          Text(`${this.total} 首`)
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      if (this.preview.length > 0) {
        Column({ space: 4 }) {
          ForEach(this.preview, (item: SongItem, index: number) => {
            Text(`${index + 1}. ${item.name}${item.singer.length > 0 ? ` - ${item.singer}` : ''}`)
              .fontSize(12.5)
              .fontColor(C_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
          }, (item: SongItem, index: number) => `pv_${index}_${item.id}`)
          if (this.total > this.preview.length) {
            Text(`… 其余 ${this.total - this.preview.length} 首导入时一并拉取`)
              .fontSize(12)
              .fontColor(C_TEXT_WEAK)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .width('100%')
        .padding({ top: 2 })
      }

      TextInput({ text: this.listName, placeholder: '导入成的歌单名' })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 14 })
        .fontSize(14)
        .height(44)
        .backgroundColor('#F2F2F4')
        .onChange((value: string) => {
          this.listName = value;
        })

      if (this.existing !== null) {
        Text(`「${this.existing.name}」已经导入过这个歌单，导入会用它替换线上最新数据（不会新建列表）`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor(C_CARD)
  }

  build() {
    Column({ space: 12 }) {
      if (this.presetId.length === 0) {
        this.linkInput()
      } else {
        Text(`把这张${platformName(this.presetSource)}在线歌单导入到「我的歌单」`)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(F_SUB)
          .fontColor(C_RED)
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Scroll() {
        Column({ space: 12 }) {
          if (this.link !== null && this.info.name.length > 0) {
            this.previewCard()
          }
          if (this.busy) {
            Row({ space: 10 }) {
              LoadingProgress().width(20).height(20).color(C_RED)
              Text('正在处理，大歌单需要一点时间…')
                .fontSize(F_SUB)
                .fontColor(C_TEXT_WEAK)
            }
            .width('100%')
          }
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')

      Row({ space: 10 }) {
        IconGlyph({ symbol: I_DOWNLOAD, iconSize: 19, color: Color.White })
        Text(this.existing !== null ? `更新「${this.existing.name}」` : '导入到我的歌单')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor(C_RED)
      .opacity(this.canImport() ? 1 : 0.4)
      .onClick(() => {
        void this.doImport();
      })

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
    .backgroundColor(C_CARD)
  }
}
