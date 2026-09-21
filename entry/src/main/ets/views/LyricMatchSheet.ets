import { hilog } from '@kit.PerformanceAnalysisKit';
import { LxMusicInfo } from '../core/music/MusicSearch';
import { LyricCandidate, MATCH_PLATFORMS, platformLabel, scoreCandidate, searchCandidates } from
  '../core/local/LyricMatch';
import { C_DIVIDER, C_RED, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM, F_SUB } from '../ui/Theme';

const DOMAIN: number = 0x0001;
const TAG: string = 'LyricMatchSheet';

/** 一条搜索结果（带它来自哪个平台、以及有多像这首歌） */
interface Candidate {
  source: string;
  info: LxMusicInfo;
  score: number;
}

/**
 * 「匹配歌词」面板（手动纠正）
 *
 * 为什么必须有它：本地歌没有平台身份，只能拿歌名 + 歌手 + 时长去猜（见 core/local/LyricMatch）。
 * 猜这件事一定有猜错的时候 —— 同名歌、翻唱、纯音乐、Live 版都会踩到，而**配错的歌词比没有歌词
 * 更难解释**（用户看到的是理直气壮的错词）。所以自动匹配做成了宁缺勿错，配不准就不显示；
 * 用户觉得该有词的时候，就来这里搜一次、自己挑正确的那条。
 *
 * 搜索按 MATCH_PLATFORMS 逐个平台来，边搜边出结果（一个平台搜不到不影响别的）；
 * 结果按相似度排序，每行标出来自哪个平台。
 */
@Component
export struct LyricMatchSheet {
  /** 本地歌的歌名 / 歌手：关键词的初始值 */
  @Prop songName: string = '';
  @Prop singer: string = '';
  /** 本地歌的时长（毫秒，0 = 未知），用来给结果排序 */
  @Prop durationMs: number = 0;
  @Prop bottomInset: number = 0;
  onPick: (info: LxMusicInfo, source: string) => void = () => {
  };
  @State keyword: string = '';
  @State searching: boolean = false;
  /** 已经搜过一轮（用来区分「还没搜」和「搜了但没有」） */
  @State searched: boolean = false;
  @State candidates: Candidate[] = [];

  aboutToAppear(): void {
    this.keyword = this.singer.length > 0 ? `${this.songName} ${this.singer}` : this.songName;
    void this.search();
  }

  /** 逐个平台搜，边搜边把结果并进列表（搜不到的、接口不通的都跳过） */
  private async search(): Promise<void> {
    const keyword: string = this.keyword.trim();
    if (keyword.length === 0 || this.searching) {
      return;
    }
    this.searching = true;
    this.searched = true;
    this.candidates = [];
    try {
      for (const platform of MATCH_PLATFORMS) {
        let results: LxMusicInfo[] = [];
        try {
          results = await searchCandidates(keyword, platform);
        } catch (e) {
          hilog.info(DOMAIN, TAG, 'search on %{public}s failed: %{public}s',
            platform, (e as Error).message);
          continue;
        }
        const fresh: Candidate[] = [];
        for (const info of results) {
          const scored: LyricCandidate = scoreCandidate(info, this.songName, this.singer, this.durationMs);
          // 歌名完全不像的（归一化后毫无交集）不列出来，免得一屏全是无关的歌
          if (scored.score <= 0) {
            continue;
          }
          fresh.push({ source: platform, info: info, score: scored.score });
        }
        this.candidates = this.merge(this.candidates, fresh);
      }
    } finally {
      this.searching = false;
    }
  }

  /** 并入新结果：按相似度排序，同名同歌手的只留第一条 */
  private merge(current: Candidate[], fresh: Candidate[]): Candidate[] {
    const out: Candidate[] = current.slice();
    for (const item of fresh) {
      let exists: boolean = false;
      for (const one of out) {
        if (one.info.name === item.info.name && one.info.singer === item.info.singer) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        out.push(item);
      }
    }
    out.sort((a: Candidate, b: Candidate) => b.score - a.score);
    return out.slice(0, 40);
  }

  build() {
    Column() {
      Text(`匹配歌词：${this.songName}`)
        .fontSize(F_ITEM)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      Text('本地歌没有平台身份，这里按歌名与歌手去平台上搜；选中的那条会记住，下次直接用它取词。')
        .fontSize(F_SUB)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .padding({ top: 4, bottom: 8 })
        .textAlign(TextAlign.Start)

      Row({ space: 8 }) {
        TextInput({ text: this.keyword, placeholder: '歌名 歌手' })
          .placeholderColor(C_TEXT_WEAK)
          .placeholderFont({ size: 14 })
          .fontSize(14)
          .height(44)
          .backgroundColor('#F2F2F4')
          .layoutWeight(1)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            void this.search();
          })
        Button('搜索')
          .fontSize(F_SUB)
          .height(44)
          .backgroundColor(C_RED)
          .enabled(this.keyword.trim().length > 0 && !this.searching)
          .onClick(() => {
            void this.search();
          })
      }
      .width('100%')

      if (this.searching) {
        Text(this.candidates.length > 0 ? `正在搜索… 已有 ${this.candidates.length} 条` : '正在搜索…')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_SUB)
          .width('100%')
          .padding({ top: 12 })
          .textAlign(TextAlign.Start)
      } else if (this.searched && this.candidates.length === 0) {
        Text('没有搜到相近的歌。换个关键词（比如只留歌名）再试一次。')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ top: 12 })
          .textAlign(TextAlign.Start)
      }

      List() {
        ForEach(this.candidates, (item: Candidate) => {
          ListItem() {
            Column({ space: 3 }) {
              Text(item.info.name)
                .fontSize(F_ITEM)
                .fontColor(C_TEXT)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
              Row({ space: 8 }) {
                Text(item.info.singer)
                  .fontSize(F_SUB)
                  .fontColor(C_TEXT_WEAK)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Start)
                if (item.info.interval.length > 0) {
                  Text(item.info.interval)
                    .fontSize(F_SUB)
                    .fontColor(C_TEXT_WEAK)
                }
                Text(platformLabel(item.source))
                  .fontSize(11)
                  .fontColor(C_TEXT_SUB)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(7)
                  .backgroundColor('#F2F2F4')
              }
              .width('100%')
            }
            .width('100%')
            .padding({ top: 9, bottom: 9 })
            .onClick(() => {
              this.onPick(item.info, item.source);
            })
          }
        }, (item: Candidate) => `${item.source}_${item.info.songmid}_${item.info.name}`)
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 6 })
      .divider({ strokeWidth: 0.6, color: C_DIVIDER })

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }
}
