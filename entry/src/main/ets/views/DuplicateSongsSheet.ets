import { DuplicateGroup } from '../core/sync/LocalLibrary';
import { C_CARD, C_DIVIDER, C_FILL_SOFT, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM,
  F_SUB } from '../ui/Theme';

/**
 * 「检查重复歌曲」的结果面板
 *
 * 由歌单详情页的 ⋮ 菜单打开：宿主先调 `LocalLibrary.findDuplicateGroups` 扫一遍，
 * 一组都没有就直接 toast，不弹这个面板；有重复才把它递进来。
 *
 * **面板只负责「确认」，不自己动库**：真正删除由宿主调 `removeDuplicateSongs`，
 * 这样宿主删完能顺手 `refresh()` 并弹一句「已清理 N 首」—— 面板这时已经被系统收掉了，
 * 再往自己的状态上写也没有意义（与 ImportPlaylistSheet 里「先收忙碌态再回调」同一个道理）。
 *
 * 去重口径（歌名 + 歌手，忽略大小写与括号后缀）全在库里，面板不参与判断：
 * 这里只把每组的 `duplicateIds` 拼平交出去，避免两处各写一套「算不算同一首」。
 */
@Component
export struct DuplicateSongsSheet {
  /** 库里算出来的重复分组（每组已指定保留哪一首：keepId） */
  @Prop groups: DuplicateGroup[] = [];
  /** 歌单名：只用于标题与确认后的提示，让用户知道自己清的是哪张歌单 */
  @Prop playlistName: string = '';
  @Prop bottomInset: number = 0;
  /** 确认清理：交出所有组里要删的歌曲 id（已拼平） */
  onConfirm: (ids: string[]) => void = () => {
  };
  /** 取消 / 关闭 */
  onClose: () => void = () => {
  };

  /**
   * 可清理条数 = 每组删掉「保留那首」之后剩下的
   *
   * 用 duplicateIds 的长度而不是 count - 1：count 是库里给整组算的，
   * 与 duplicateIds 万一对不上（比如同组里有两条同 id 的脏数据），删除条数必须以
   * 真正会传下去的那份 id 为准，界面上报的数才不会跟实际删的对不上。
   */
  private removeCount(): number {
    let total: number = 0;
    for (const group of this.groups) {
      total += group.duplicateIds.length;
    }
    return total;
  }

  /** 把所有组的 duplicateIds 拼成一串：宿主只认一串 id */
  private confirmIds(): string[] {
    const ids: string[] = [];
    for (const group of this.groups) {
      for (const id of group.duplicateIds) {
        ids.push(id);
      }
    }
    return ids;
  }

  /** 组内那句说明：「保留 1 首，清理 N 首」—— 让人确认前知道每组会少几首 */
  private groupHint(group: DuplicateGroup): string {
    const remove: number = group.duplicateIds.length;
    return `保留 1 首，清理 ${remove} 首`;
  }

  @Builder
  groupRow(group: DuplicateGroup) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(group.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Row({ space: 6 }) {
          if (group.singer.length > 0) {
            Text(group.singer)
              .fontSize(F_SUB)
              .fontColor(C_TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.groupHint(group))
            .fontSize(F_SUB)
            .fontColor(C_TEXT_WEAK)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 这一组里同名的有几首：一眼看出「这首歌重复得太厉害」的那几组
      Text(`×${group.count}`)
        .fontSize(F_SUB)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_RED)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(10)
        .backgroundColor(C_RED_TINT)
    }
    .width('100%')
    .height(58)
    .padding({ left: 4, right: 4 })
  }

  build() {
    Column({ space: 10 }) {
      // 汇总：组数 / 将删除首数 / 每组保留几首，一条说清（面板顶部第一眼就能看见）
      Text(`共 ${this.groups.length} 组 / 将删除 ${this.removeCount()} 首（每组保留 1 首）`)
        .fontSize(F_ITEM)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(this.playlistName.length === 0
        ? '确认后会把每组里多出来的同名单曲删掉，保留的那首不受影响'
        : `确认后会把「${this.playlistName}」里每组多出来的同名单曲删掉，每组保留第 1 首，确认前不会改动歌单`)
        .fontSize(F_SUB)
        .fontColor(C_TEXT_SUB)
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.groups.length === 0) {
        Text('没有发现重复歌曲')
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .padding({ top: 18, bottom: 6 })
          .textAlign(TextAlign.Start)
      } else {
        List() {
          ForEach(this.groups, (group: DuplicateGroup) => {
            ListItem() {
              this.groupRow(group)
            }
          }, (group: DuplicateGroup) => `${group.key}_${group.keepId}_${group.count}`)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 4 })
        .divider({ strokeWidth: 0.6, color: C_DIVIDER })
      }

      // 主操作（红底反白，与工程里删除类主操作同一个口径）：文案把「删几首」直接写出来，
      // 别让用户在确认那一下还要自己算
      Row() {
        Text(this.removeCount() === 0
          ? '没有可清理的重复歌曲'
          : `保留每组第一首，删除其余 ${this.removeCount()} 首`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor(C_RED)
      .opacity(this.removeCount() === 0 ? 0.4 : 1)
      .onClick(() => {
        const ids: string[] = this.confirmIds();
        if (ids.length === 0) {
          return;
        }
        this.onConfirm(ids);
      })

      // 次操作：取消。走宿主给的 onClose，由宿主收面板（面板自己不关，避免两边抢状态）
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor(C_TEXT)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(23)
      .backgroundColor(C_FILL_SOFT)
      .onClick(() => {
        this.onClose();
      })

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 12 })
    .backgroundColor(C_CARD)
  }
}
