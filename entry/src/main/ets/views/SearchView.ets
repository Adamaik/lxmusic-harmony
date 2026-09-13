import { LxMusicInfo, SEARCH_PLATFORMS, searchMusic } from '../core/music/MusicSearch';
import { platformName } from '../core/music/MusicList';
import { PlaySession, SongItem, songFromSearch } from '../core/player/PlaySession';
import { K_PLAY_QUALITY, MAIN_QUALITYS } from '../core/settings/PlaySettings';
import { C_BG, C_CARD, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_SUB } from '../ui/Theme';
import { GlassModifier, thinGlass } from '../ui/Glass';
import { I_CLOSE, I_SEARCH, IconGlyph } from '../ui/Icons';
import { SongListPane } from './PlaylistView';

const QUALITYS: string[] = MAIN_QUALITYS;

/**
 * 搜索页
 *
 * 搜索是宿主内置能力（酷我/酷狗/咪咕/QQ/网易五个平台），不依赖音源；
 * 音源只决定「搜到的这首歌能不能解析出播放链接」。
 */
@Component
export struct SearchView {
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;
  onBack: () => void = () => {
  };
  @State keyword: string = '';
  @State platform: string = 'kw';
  /**
   * 音质用设置里的那一份（设置 - 播放设置 - 播放音质）：
   * 以前这里自己存一个默认 128k，与设置页各说各话，选了设置也不认。
   */
  @StorageLink(K_PLAY_QUALITY) quality: string = '128k';
  @State searching: boolean = false;
  @State status: string = '输入歌名或歌手，选一个平台后搜索';
  @State results: SongItem[] = [];
  @State currentId: string = '';
  private searchGlass: GlassModifier = thinGlass(23);

  private async doSearch(): Promise<void> {
    if (this.searching) {
      return;
    }
    const text: string = this.keyword.trim();
    if (text.length === 0) {
      this.status = '请输入搜索关键词';
      return;
    }
    this.searching = true;
    this.results = [];
    this.status = `正在搜索「${text}」…`;
    try {
      const list: LxMusicInfo[] = await searchMusic(text, this.platform, 1, 30);
      const items: SongItem[] = [];
      for (const info of list) {
        items.push(songFromSearch(info, this.quality));
      }
      this.results = items;
      this.status = list.length > 0
        ? `搜索到 ${list.length} 首（${platformName(this.platform)}）`
        : `没有搜索结果（${platformName(this.platform)}）`;
    } catch (e) {
      this.status = `搜索失败: ${(e as Error).message}`;
    } finally {
      this.searching = false;
    }
  }

  build() {
    Column() {
      // ---------------------------------------------------- 搜索栏（标题栏由 HDS 提供）
      Row({ space: 10 }) {
        Row({ space: 8 }) {
          IconGlyph({
              symbol: I_SEARCH,
              iconSize: 18,
              color: '#8A8A8E',
            })
          TextInput({ text: this.keyword, placeholder: '歌名 / 歌手' })
            .placeholderColor(C_TEXT_WEAK)
            .placeholderFont({ size: 15 })
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .padding(0)
            .height(28)
            .layoutWeight(1)
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              this.keyword = value;
            })
            .onSubmit(() => {
              this.doSearch();
            })
          if (this.keyword.length > 0) {
            IconGlyph({
              symbol: I_CLOSE,
              iconSize: 16,
              color: '#B0B0B6',
            })
              .onClick(() => {
                this.keyword = '';
                this.results = [];
              })
          }
        }
        .layoutWeight(1)
        .height(44)
        .padding({ left: 14, right: 12 })
        .attributeModifier(this.searchGlass)

        Text(this.searching ? '搜索中' : '搜索')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.searching ? C_TEXT_WEAK : C_RED)
          .onClick(() => {
            this.doSearch();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })

      // ---------------------------------------------------- 平台 / 音质
      Scroll() {
        Row({ space: 8 }) {
          ForEach(SEARCH_PLATFORMS, (item: string) => {
            Text(platformName(item))
              .fontSize(13.5)
              .fontWeight(this.platform === item ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.platform === item ? Color.White : '#3A3A3C')
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.platform === item ? C_RED : C_CARD)
              .animation({ duration: 180, curve: Curve.EaseInOut })
              .onClick(() => {
                this.platform = item;
              })
          }, (item: string) => item)

          Divider()
            .vertical(true)
            .height(18)
            .strokeWidth(0.8)
            .color('#D8D8DC')
            .margin({ left: 2, right: 2 })

          ForEach(QUALITYS, (item: string) => {
            Text(item)
              .fontSize(13.5)
              .fontColor(this.quality === item ? C_RED : C_TEXT_SUB)
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .onClick(() => {
                this.quality = item;
              })
          }, (item: string) => `q_${item}`)
        }
        .padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(36)

      Text(this.status)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 4 })
        .textAlign(TextAlign.Start)

      // ---------------------------------------------------- 结果
      // SongListPane 自己是可滚动的懒加载列表，别再套 Scroll（嵌套滚动也会打架）
      if (this.searching) {
        Column() {
          LoadingProgress().width(38).height(38).color(C_RED)
        }
        .width('100%')
        .padding({ top: 60 })
      }
      SongListPane({
        items: this.results,
        currentId: this.currentId,
        emptyText: '',
        bottomInset: this.bottomInset,
        onPick: (index: number) => {
          if (index < 0 || index >= this.results.length) {
            return;
          }
          this.currentId = this.results[index].id;
          PlaySession.getInstance().setQueueAndPlay(this.results, index);
          this.status = `已加入播放列表并开始解析：${this.results[index].name}`;
        },
      })
        .layoutWeight(1)
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
