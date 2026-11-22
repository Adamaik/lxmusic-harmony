import { DuplicateEntry, DuplicateGroup } from '../core/sync/LocalLibrary';
import { C_CARD, C_DIVIDER, C_FILL_SOFT, C_RED, C_RED_TINT, C_TEXT, C_TEXT_SUB, C_TEXT_WEAK, F_ITEM,
  F_SUB } from '../ui/Theme';
import { platformLabel } from '../core/local/LyricMatch';
import { LOCAL_SOURCE } from '../core/local/LocalMusic';
import { WEBDAV_SOURCE } from '../core/webdav/WebDavTypes';

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
 * 去重口径（歌名 + 歌手，版本后缀不同 = 不同歌曲）全在库里，面板不参与判断：
 * 这里只把每组除「用户选中的那一条」之外的 id 拼平交出去，避免两处各写一套「算不算同一首」。
 *
 * **每组可改保留哪一条**：默认保留列表最靠前那条（与库里的 keepId 一致），点组里任意一条
 * 就改成保留它。所以面板必须知道组里的**每一行**，而不是只拿到 keepId —— 那就是
 * DuplicateGroup.entries 的用途（行级 id + 时长 / 平台 / 音质，全部是已有字段，不请求网络）。
 */
@Component
export struct DuplicateSongsSheet {
  /** 库里算出来的重复分组（组内已带每一行，见 DuplicateGroup.entries） */
  @Prop groups: DuplicateGroup[] = [];
  /** 歌单名：只用于标题与确认后的提示，让用户知道自己清的是哪张歌单 */
  @Prop playlistName: string = '';
  @Prop bottomInset: number = 0;
  /** 确认清理：交出所有组里要删的歌曲 id（已拼平；同 id 出现两次 = 删两个副本） */
  onConfirm: (ids: string[]) => void = () => {
  };
  /** 取消 / 关闭 */
  onClose: () => void = () => {
  };

  /**
   * 每组当前选中「保留」的行下标（与 groups 同序）
   *
   * 用下标而不是 id：同 id 两行时 id 一样，只有下标能区分「留哪一行」。
   * 改选择时整体换一个新数组（@State 只认赋值，原地改元素不会触发刷新）。
   */
  @State keep: number[] = [];

  aboutToAppear(): void {
    const next: number[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      next.push(0);
    }
    this.keep = next;
  }

  /** 第 groupIndex 组当前保留第几条；越界一律退回 0（默认保留最靠前那条） */
  private keptIndex(groupIndex: number): number {
    if (groupIndex < 0 || groupIndex >= this.groups.length) {
      return 0;
    }
    const group: DuplicateGroup = this.groups[groupIndex];
    const raw: number = groupIndex < this.keep.length ? this.keep[groupIndex] : 0;
    return raw >= 0 && raw < group.entries.length ? raw : 0;
  }

  /** 点组里的某一条 = 这一组改成保留它 */
  private select(groupIndex: number, entryIndex: number): void {
    const next: number[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      next.push(i === groupIndex ? entryIndex : this.keptIndex(i));
    }
    this.keep = next;
  }

  /**
   * 某一组要删的 id：组内除选中那条以外全部
   *
   * 同 id 两行时这里会出现同一个 id 两次 —— 库里的 removeDuplicateSongs 按「ids 里某个 id
   * 出现几次就删几个副本」处理，所以「留一行删一行」成立，不会把两行一起删掉。
   */
  private deleteIdsOf(group: DuplicateGroup, kept: number): string[] {
    const out: string[] = [];
    for (let i = 0; i < group.entries.length; i++) {
      if (i !== kept) {
        out.push(group.entries[i].id);
      }
    }
    return out;
  }

  /** 可清理条数 = 每组留下的那一条之外的全部行数 */
  private removeCount(): number {
    let total: number = 0;
    for (const group of this.groups) {
      if (group.entries.length > 1) {
        total += group.entries.length - 1;
      }
    }
    return total;
  }

  /** 把所有组「要删的 id」拼成一串：宿主只认一串 id */
  private confirmIds(): string[] {
    const ids: string[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      for (const id of this.deleteIdsOf(this.groups[i], this.keptIndex(i))) {
        ids.push(id);
      }
    }
    return ids;
  }

  /** 组内那句说明：「保留 1 首，清理 N 首」—— 让人确认前知道每组会少几首 */
  private groupHint(group: DuplicateGroup): string {
    const remove: number = group.entries.length > 1 ? group.entries.length - 1 : 0;
    return `保留 1 首，清理 ${remove} 首`;
  }

  /** 平台 / 来源标签：本地歌与云盘歌也是「来源」，不能直接显示 local / webdav 这种黑话 */
  private sourceLabel(source: string): string {
    if (source === LOCAL_SOURCE) {
      return '本地';
    }
    if (source === WEBDAV_SOURCE) {
      return '云盘';
    }
    return platformLabel(source);
  }

  /** 条目右下的那行小字：序号 · 来源 · 时长 · 音质（有的才显示，全是已有字段） */
  private entryMeta(entry: DuplicateEntry, index: number): string {
    const parts: string[] = [`第 ${index + 1} 条`];
    const label: string = this.sourceLabel(entry.source);
    if (label.length > 0) {
      parts.push(label);
    }
    if (entry.interval.length > 0) {
      parts.push(entry.interval);
    }
    if (entry.quality.length > 0) {
      parts.push(entry.quality);
    }
    return parts.join(' · ');
  }

  @Builder
  entryRow(entry: DuplicateEntry, entryIndex: number, groupIndex: number) {
    Row({ space: 10 }) {
      // 选择圈：选中（= 保留）的是实心红点，其余是空心圈 —— 一眼看出这一组会留哪条
      Column() {
        if (this.keptIndex(groupIndex) === entryIndex) {
          Column()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(Color.White)
        }
      }
      .width(20)
      .height(20)
      .borderRadius(10)
      .justifyContent(FlexAlign.Center)
      .borderWidth(1.2)
      .borderColor(this.keptIndex(groupIndex) === entryIndex ? C_RED : C_DIVIDER)
      .backgroundColor(this.keptIndex(groupIndex) === entryIndex ? C_RED : Color.Transparent)

      Column({ space: 2 }) {
        // 组内歌名只有大小写 / 括号宽度差异时也照样显示：这是用户判断「是不是同一首」的依据
        Text(entry.name)
          .fontSize(F_ITEM)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.entryMeta(entry, entryIndex))
          .fontSize(F_SUB)
          .fontColor(C_TEXT_WEAK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.keptIndex(groupIndex) === entryIndex ? '保留' : '删除')
        .fontSize(F_SUB)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.keptIndex(groupIndex) === entryIndex ? C_RED : C_TEXT_SUB)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(10)
        .backgroundColor(this.keptIndex(groupIndex) === entryIndex ? C_RED_TINT : C_FILL_SOFT)
    }
    .width('100%')
    .height(48)
    .padding({ left: 4, right: 4 })
    .onClick(() => {
      this.select(groupIndex, entryIndex);
    })
  }

  @Builder
  groupCard(group: DuplicateGroup, groupIndex: number) {
    Column({ space: 2 }) {
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

        // 这一组里同名的有几条：一眼看出「这首歌重复得太厉害」的那几组
        Text(`×${group.entries.length}`)
          .fontSize(F_SUB)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_RED)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(10)
          .backgroundColor(C_RED_TINT)
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      // 组内每一行都可点：点哪条就把「保留」挪到哪条（默认第一条）
      ForEach(group.entries, (entry: DuplicateEntry, entryIndex: number) => {
        this.entryRow(entry, entryIndex, groupIndex)
      }, (entry: DuplicateEntry, entryIndex: number) =>
      `${group.key}_${entryIndex}_${entry.id}_${this.keptIndex(groupIndex)}`)
    }
    .width('100%')
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
        ? '点一下每条里想保留的那一首，确认后其余同名单曲会删除'
        : `「${this.playlistName}」里点一下想保留的那一首，确认后删除每组其余条目，确认前不会改动歌单`)
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
          ForEach(this.groups, (group: DuplicateGroup, groupIndex: number) => {
            ListItem() {
              this.groupCard(group, groupIndex)
            }
          }, (group: DuplicateGroup, groupIndex: number) =>
          `${group.key}_${group.entries.length}_${this.keptIndex(groupIndex)}`)
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
          : `保留所选，删除其余 ${this.removeCount()} 首`)
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
