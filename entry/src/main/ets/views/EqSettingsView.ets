import { LengthMetrics } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { C_BG, C_CARD, C_DIVIDER, C_FILL_SOFT, C_ON_ACCENT, C_RED, C_RED_TINT, C_SEG_BG,
  C_SEG_UNSELECTED, C_SLIDER_TRACK, C_TEXT, C_TEXT_WEAK, R_CARD } from '../ui/Theme';
import { HintText, ToggleSetting } from '../ui/SettingWidgets';
import { AudioEffectSettings, EQ_BAND_LABELS, EQ_GAIN_MAX, EQ_GAIN_MIN, EQ_PRESETS, EqPreset,
  K_EQ_DIRTY, K_EQ_ENABLED, K_EQ_GAINS, K_EQ_PRESET } from '../core/settings/AudioEffectSettings';
import { EqCustomPreset, EqImportResult, EqPresetStore, EQ_PRESET_NAME_MAX,
  K_EQ_CUSTOM_PRESETS } from '../core/settings/EqPresetStore';
import { cardColumnsFor, cardWidthOf, K_WINDOW_WIDTH } from '../ui/Layout';

/** 导入文件大小上限：音效 JSON 只有几 KB，超过这个数说明选错文件了 */
const MAX_IMPORT_BYTES: number = 1024 * 1024;

/**
 * 音效设置（设置 - 音效设置）
 *
 * 为什么单独开一页，而不是塞在播放设置那张卡里：10 段 EQ 要的是**一屏放得下的操作面**
 * —— 一条能看出形状的响应曲线 + 十段能精确拖动的推子 + 九枚预设。挤在设置页的卡片里
 * （内容宽只有三百来 vp）时，预设胶囊一行要放十枚、推子一屏只有十行紧贴在一起，
 * 怎么排都局促。单独成页之后，曲线能画到 118 高、每段推子 40 高、预设可以换行，
 * 才像一台均衡器而不是一堆控件。
 *
 * 入口在设置页顶部那张「播放设置 / 音效设置 / 缓存 …」的列表里，单独一行
 * （排在「播放设置」下面、「缓存」上面，见 SettingsView 的 GROUP_PLAY）；开关也搬到了本页，
 * 不再在设置列表上给快捷开关 —— 音效改的是声音本身，进去调才是完整的操作。
 *
 * 页面本身不改播放逻辑：所有值都写进 AudioEffectSettings（AppStorage + 落盘），
 * 播放侧订阅变更后从头重播当前曲目（见 PlaySession.requestEqReplay）。
 */
@Component
export struct EqSettingsView {
  /** 内容让出标题栏那一段（壳层传来的「状态栏 + 标题栏」）：见滚动内容里的顶部占位 */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 0;

  @StorageLink(K_EQ_ENABLED) eqEnabled: boolean = false;
  @StorageLink(K_EQ_PRESET) eqPreset: string = 'off';
  @StorageLink(K_EQ_GAINS) eqGains: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  /** 推子改过但还没点「应用」 */
  @StorageLink(K_EQ_DIRTY) eqDirty: boolean = false;
  /** 窗口宽度（vp）：宽屏下开关卡与预设卡并排、推子卡独占整行（0 = 还没量到，按手机一列） */
  @StorageLink(K_WINDOW_WIDTH) windowWidth: number = 0;

  // ------------------------------------------------------------ 我的音效（自定义预设）

  /** 已保存的自定义音效：EqPresetStore 每次变更都会把 list() 的 JSON 字符串重新发布到这里 */
  @StorageLink(K_EQ_CUSTOM_PRESETS) customPresetsJson: string = '[]';
  /** 命名保存的输入面板是否展开（bindSheet） */
  @State nameOpen: boolean = false;
  /** 输入框草稿名（打开面板时默认填「我的音效 N」） */
  /** 输入框内容（**不预填**默认名：预填的话用户一输入就变成「我的音效 1Bass」这种拼接名） */
  @State draftName: string = '';
  /** 输入框为空时采用的默认名（作为占位提示显示，保存时兜底） */
  @State suggestedName: string = '';
  /** 多选导出模式：每行前出现选择圈，底部出现「全选 / 导出(N) / 取消」 */
  @State exportMode: boolean = false;
  /** 已勾选的名字（列表可能因删除 / 导入变化，用时再按现存名字过滤） */
  @State checkedNames: string[] = [];

  /** 预设胶囊的平均宽度够不够一行放四个（宽屏时卡片更宽，一排能放更多） */
  private chipsGap(): number {
    return 8;
  }

  /**
   * 预设按三列切行
   *
   * 不做「自动换行」是因为九枚胶囊按内容宽度换行会落成 4/4/1 —— 最后一行孤零零一枚，
   * 看着像排坏了。固定三列 + 等宽，就是整整齐齐的 3×3。
   */
  private presetRows(): EqPreset[][] {
    const rows: EqPreset[][] = [];
    for (let i = 0; i < EQ_PRESETS.length; i += 3) {
      rows.push(EQ_PRESETS.slice(i, i + 3));
    }
    return rows;
  }

  /** 最后一行不满三个时补的空位（占住三分之一宽度，药丸不会被拉宽） */
  private fillers(count: number): number[] {
    const holes: number[] = [];
    for (let i = count; i < 3; i++) {
      holes.push(i);
    }
    return holes;
  }

  // ------------------------------------------------------------ 我的音效：数据与工具

  private store(): EqPresetStore {
    return EqPresetStore.getInstance();
  }

  /**
   * 已保存的自定义音效列表
   *
   * 数据源是 @StorageLink 订阅的那份 JSON（EqPresetStore 每次变更都会重新发布），
   * 这样保存 / 删除 / 导入后本页自动刷新。解析失败（老数据 / 被手改坏）按空列表处理，
   * 不让一个坏字段把整页卡死。
   */
  private customPresets(): EqCustomPreset[] {
    try {
      const parsed: EqCustomPreset[] = JSON.parse(this.customPresetsJson) as EqCustomPreset[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  /** 勾选集合里仍然存在的名字（删除 / 导入后列表变了，勾选集合可能带着旧名字） */
  private checkedExisting(): string[] {
    const names: string[] = [];
    for (const preset of this.customPresets()) {
      if (this.checkedNames.includes(preset.name)) {
        names.push(preset.name);
      }
    }
    return names;
  }

  /** 默认名字：第一个还没被占用的「我的音效 N」（N 从 1 起，避免一保存就覆盖旧存档） */
  private defaultPresetName(): string {
    const taken: Set<string> = new Set<string>();
    for (const preset of this.customPresets()) {
      taken.add(preset.name);
    }
    let seq: number = 1;
    while (taken.has(`我的音效 ${seq}`)) {
      seq++;
    }
    return `我的音效 ${seq}`;
  }

  /** 列表行的小字摘要：取前三个非 0 段，「31Hz +5 · 1k -5」 */
  private gainsSummary(gains: number[]): string {
    const parts: string[] = [];
    let nonZero: number = 0;
    for (let i = 0; i < gains.length; i++) {
      const gain: number = gains[i] ?? 0;
      if (gain === 0) {
        continue;
      }
      nonZero++;
      if (parts.length < 3) {
        const label: string = EQ_BAND_LABELS[i] ?? '';
        parts.push(`${label}Hz ${gain > 0 ? '+' : ''}${gain}`);
      }
    }
    if (parts.length === 0) {
      return '十段全 0 dB';
    }
    const text: string = parts.join(' · ');
    return nonZero > parts.length ? `${text} …` : text;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** 取页面宿主 Context（picker 构造要用）；拿不到返回 null，调用方安全返回 */
  private hostContext(): common.Context | null {
    try {
      const context = this.getUIContext().getHostContext() as common.Context | undefined;
      return context === undefined ? null : context;
    } catch (e) {
      return null;
    }
  }

  // ------------------------------------------------------------ 我的音效：保存 / 应用 / 删除

  private openSaveSheet(): void {
    // 默认名只当占位提示：用户想改名直接输入即可，不会被拼成「我的音效 1XXX」那种名字
    this.suggestedName = this.defaultPresetName();
    this.draftName = '';
    this.nameOpen = true;
  }

  /**
   * 确认保存当前十段增益
   *
   * 存的是 this.eqGains（界面上的当前值），**包含还没按「应用」的调整** ——
   * 用户的心智是「先调好再存」。存完不自动应用：应用是另一件事（点列表行才应用），
   * 两者语义分开，免得「存一下」就把正在放的歌重播一遍。
   */
  private confirmSave(): void {
    // 输入框留空 = 用默认名（「我的音效 N」）：不逼用户先删一遍预填内容
    const name: string = this.draftName.trim().length > 0
      ? this.draftName.trim() : this.suggestedName.trim();
    if (name.length === 0) {
      this.toast('名字不能为空');
      return;
    }
    if (name.length > EQ_PRESET_NAME_MAX) {
      this.toast(`名字最多 ${EQ_PRESET_NAME_MAX} 个字`);
      return;
    }
    const existed: boolean = this.customPresets()
      .some((preset: EqCustomPreset) => preset.name === name);
    const saved: EqCustomPreset | null = this.store().save(name, this.eqGains.slice());
    if (saved === null) {
      // 名字与增益在进这里之前都已经校验过，拿不到结果只可能是存储没就绪或已满上限
      this.toast('保存失败：本地存储还没准备好，或已达 200 套上限');
      return;
    }
    this.nameOpen = false;
    this.toast(existed ? `已更新「${saved.name}」` : `已保存「${saved.name}」`);
  }

  /** 整行点击 = 应用（走与选预设同一条路，会重播当前曲）；不修改「我的音效」里的存档 */
  private applyCustom(preset: EqCustomPreset): void {
    AudioEffectSettings.getInstance().selectCustomGains(preset.gains);
    this.toast(`已应用「${preset.name}」`);
  }

  /** 删除前二次确认：删了就找不回来（增益能重新保存，但名字与先后顺序会丢） */
  private confirmRemove(name: string): void {
    this.getUIContext().showAlertDialog({
      title: '删除音效',
      message: `确定删除「${name}」？删除后不可恢复。`,
      autoCancel: true,
      buttons: [
        { value: '取消', action: () => { } },
        {
          value: '删除',
          fontColor: C_RED,
          action: () => {
            const removed: boolean = this.store().remove(name);
            if (!removed) {
              this.toast('没找到这个音效（可能已被删除）');
              return;
            }
            this.checkedNames = this.checkedNames.filter((item: string) => item !== name);
            this.toast(`已删除「${name}」`);
            // store 的变更已经同步发布，这里用 store.list() 判断而不是本页 @StorageLink，
            // 免得同一次回调里读到的还是旧值
            if (this.store().list().length === 0) {
              this.exitExportMode();
            }
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 我的音效：多选导出 / 导入

  private enterExportMode(): void {
    this.checkedNames = [];
    this.exportMode = true;
  }

  private exitExportMode(): void {
    this.exportMode = false;
    this.checkedNames = [];
  }

  private toggleChecked(name: string): void {
    this.checkedNames = this.checkedNames.includes(name)
      ? this.checkedNames.filter((item: string) => item !== name)
      : this.checkedNames.concat([name]);
  }

  private toggleCheckAll(): void {
    const all: EqCustomPreset[] = this.customPresets();
    this.checkedNames = this.checkedExisting().length === all.length
      ? []
      : all.map((preset: EqCustomPreset) => preset.name);
  }

  /**
   * 导出勾选的音效为 JSON 文件
   *
   * 走项目里既有的「系统保存对话框 + 直接写返回 uri」写法（见 core/local/PlaylistPort.exportToFile）：
   * save() 返回的就是可写的目标 uri，不需要先往 cacheDir 写临时文件再多一步清理。
   * 用户取消（返回空数组 / 抛取消错误）静默返回；真失败给中文原因。
   */
  private async exportChecked(): Promise<void> {
    const names: string[] = this.checkedExisting();
    if (names.length === 0) {
      this.toast('先勾选要导出的音效');
      return;
    }
    let text: string = '';
    try {
      text = this.store().exportJson(names);
    } catch (e) {
      this.toast(`导出失败：${(e as Error).message}`);
      return;
    }
    if (text.length === 0) {
      this.toast('没有可导出的音效');
      return;
    }
    const context: common.Context | null = this.hostContext();
    if (context === null) {
      this.toast('界面还没准备好，稍后再试');
      return;
    }
    let uri: string = '';
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [`我的音效-${names.length}个.json`];
      const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      const error = e as BusinessError;
      if (isPickerCancel(error)) {
        return;
      }
      this.toast(`打不开系统保存对话框（${error.code}）`);
      return;
    }
    try {
      writeTextToUri(uri, text);
    } catch (e) {
      this.toast('写入文件失败，请换个保存位置再试');
      return;
    }
    this.exitExportMode();
    this.toast(`已导出 ${names.length} 个音效，可用文件管理/QQ 发送给他人`);
  }

  /** 从 JSON 文件导入：合并规则与计数由 EqPresetStore 决定（同名同增益跳过、同名不同增益覆盖、新名字新增） */
  private async importFromFile(): Promise<void> {
    const context: common.Context | null = this.hostContext();
    if (context === null) {
      this.toast('界面还没准备好，稍后再试');
      return;
    }
    let uri: string = '';
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      const error = e as BusinessError;
      if (isPickerCancel(error)) {
        return;
      }
      this.toast(`打不开系统文件选择器（${error.code}）`);
      return;
    }
    let text: string = '';
    try {
      text = readTextFromUri(uri);
    } catch (e) {
      this.toast(`读不了这个文件：${(e as Error).message}`);
      return;
    }
    const result: EqImportResult = this.store().importJson(text);
    if (result.error.length > 0) {
      this.toast(result.error);
      return;
    }
    if (result.added === 0 && result.updated === 0 && result.skipped === 0) {
      this.toast('文件里没有可用的音效');
      return;
    }
    this.toast(`新增 ${result.added} · 更新 ${result.updated} · 跳过 ${result.skipped}`);
  }

  // ------------------------------------------------------------ 我的音效：UI

  /**
   * 「我的音效」卡（放在预设卡与十段推子卡之间）
   *
   * 三件事：保存当前增益（命名）、点一行应用、多选导出 / 导入 JSON。
   * 空列表也不隐藏整块 —— 留一行引导，用户才知道这里能存自己的音效。
   */
  @Builder
  customPresetCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('我的音效')
          .fontSize(15)
          .fontColor(C_TEXT)
        if (this.customPresets().length > 0) {
          Text(`${this.customPresets().length} 个`)
            .fontSize(10.5)
            .fontColor(C_TEXT_WEAK)
        }
        Blank()
        if (!this.exportMode) {
          Text('导入')
            .fontSize(11.5)
            .fontColor(C_TEXT)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor(C_SEG_BG)
            .accessibilityText('从文件导入音效')
            .onClick(() => {
              void this.importFromFile();
            })
          if (this.customPresets().length > 0) {
            Text('导出')
              .fontSize(11.5)
              .fontColor(C_TEXT)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor(C_SEG_BG)
              .accessibilityText('多选导出音效')
              .onClick(() => {
                this.enterExportMode();
              })
          }
          Text('保存当前')
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_ON_ACCENT)
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .borderRadius(12)
            .backgroundColor(C_RED)
            .accessibilityText('把当前十段增益保存为我的音效')
            .onClick(() => {
              this.openSaveSheet();
            })
        }
      }
      .width('100%')

      if (this.customPresets().length === 0) {
        Text('把当前十段推子调好后，点「保存当前」存成自己的音效')
          .fontSize(12.5)
          .fontColor(C_TEXT_WEAK)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ top: 6, bottom: 4 })
      } else {
        Column() {
          /**
           * key 里带上增益：同名覆盖保存 / 导入覆盖时 createdAt 不变，
           * 只用「名字 + 时间」当 key 的话 ForEach 会把行当成同一项、摘要不刷新。
           */
          ForEach(this.customPresets(), (preset: EqCustomPreset, index: number) => {
            this.customPresetRow(preset, index)
          }, (preset: EqCustomPreset) => `${preset.name}_${preset.createdAt}_${preset.gains.join(',')}`)
        }
        .width('100%')

        if (this.exportMode) {
          Row({ space: 10 }) {
            Text(this.checkedExisting().length === this.customPresets().length ? '取消全选' : '全选')
              .fontSize(11.5)
              .fontColor(C_TEXT)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor(C_SEG_BG)
              .accessibilityText('全选或取消全选')
              .onClick(() => {
                this.toggleCheckAll();
              })
            Blank()
            Text(`导出(${this.checkedExisting().length})`)
              .fontSize(11.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_ON_ACCENT)
              .padding({ left: 11, right: 11, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor(C_RED)
              .accessibilityText(`导出选中的 ${this.checkedExisting().length} 个音效`)
              .onClick(() => {
                void this.exportChecked();
              })
            Text('取消')
              .fontSize(11.5)
              .fontColor(C_TEXT_WEAK)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick(() => {
                this.exitExportMode();
              })
          }
          .width('100%')
          .margin({ top: 2 })
        }
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    .borderRadius(R_CARD)
    .backgroundColor(C_CARD)
  }

  /** 一条音效的名字 + 增益摘要（正常态与选择态共用） */
  @Builder
  presetLabels(preset: EqCustomPreset) {
    Column({ space: 3 }) {
      Text(preset.name)
        .fontSize(14)
        .fontColor(C_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
      Text(this.gainsSummary(preset.gains))
        .fontSize(11)
        .fontColor(C_TEXT_WEAK)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一条自定义音效：名字 + 增益摘要
   *
   * 两种态分开写而不是「整行挂 onClick、删除按钮再拦冒泡」：ArkUI 的 ClickEvent 没有
   * stopPropagation（SDK 里只有 TouchEvent / MouseEvent 有），嵌套点击会同时触发。
   * 所以正常态把点击放在名字区（占满剩余宽度）、删除按钮独立；选择态没有删除按钮，整行可点。
   */
  @Builder
  customPresetRow(preset: EqCustomPreset, index: number) {
    Column() {
      if (index > 0) {
        Divider().strokeWidth(0.6).color(C_DIVIDER)
      }
      if (this.exportMode) {
        Row({ space: 10 }) {
          // 选择圈：勾上是红底白勾，没勾是空心圆
          Text(this.checkedNames.includes(preset.name) ? '✓' : '')
            .fontSize(11)
            .fontColor(C_ON_ACCENT)
            .textAlign(TextAlign.Center)
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor(this.checkedNames.includes(preset.name) ? C_RED : C_SEG_BG)
            .border({
              width: this.checkedNames.includes(preset.name) ? 0 : 1,
              color: C_SEG_UNSELECTED,
            })
          Column() {
            this.presetLabels(preset)
          }
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(54)
        .onClick(() => {
          this.toggleChecked(preset.name);
        })
      } else {
        Row({ space: 10 }) {
          // 名字 + 摘要这一整块（占满剩余宽度）点击 = 应用这套音效（会重播当前曲）
          Column() {
            this.presetLabels(preset)
          }
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.applyCustom(preset);
          })
          Text('删除')
            .fontSize(11.5)
            .fontColor(C_RED)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(11)
            .backgroundColor(C_RED_TINT)
            .accessibilityText(`删除音效 ${preset.name}`)
            .onClick(() => {
              this.confirmRemove(preset.name);
            })
        }
        .width('100%')
        .height(54)
      }
    }
    .width('100%')
  }

  /** 命名输入面板（bindSheet）：默认名已填好，用户改完点保存 */
  @Builder
  nameSheet() {
    Column({ space: 12 }) {
      Text(`给这套增益起个名字（最多 ${EQ_PRESET_NAME_MAX} 个字）`)
        .fontSize(14)
        .fontColor(C_TEXT_WEAK)
        .width('100%')
        .textAlign(TextAlign.Start)
      TextInput({
        text: this.draftName,
        placeholder: this.suggestedName.length > 0 ? `默认：${this.suggestedName}` : '例如：耳机人声增强',
      })
        .placeholderColor(C_TEXT_WEAK)
        .placeholderFont({ size: 14 })
        .fontSize(14)
        .height(46)
        .maxLength(EQ_PRESET_NAME_MAX)
        .backgroundColor(C_FILL_SOFT)
        .onChange((value: string) => {
          this.draftName = value;
        })
        .onSubmit(() => {
          this.confirmSave();
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_FILL_SOFT)
          .fontColor(C_TEXT)
          .onClick(() => {
            this.nameOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(C_RED)
          .enabled(this.draftName.trim().length > 0)
          .onClick(() => {
            this.confirmSave();
          })
      }
      .width('100%')

      Column().height(this.bottomInset + 8).width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  build() {
    Column() {
      Scroll() {
        Flex({
          // 断点与设置页一致（Layout.cardColumnsFor：≥ 966vp 才排两列，最多两列）。
          // 不要自己写死宽度阈值——各页的卡片流都是这一套口径，写歪了窗口一变化就露馅。
          direction: cardColumnsFor(this.windowWidth) > 1 ? FlexDirection.Row : FlexDirection.Column,
          wrap: cardColumnsFor(this.windowWidth) > 1 ? FlexWrap.Wrap : FlexWrap.NoWrap,
          // 高度差得多（开关卡只有两行、推子卡十行），居中的话短卡会飘在半空
          alignItems: ItemAlign.Start,
          space: { main: LengthMetrics.vp(14), cross: LengthMetrics.vp(14) },
        }) {
          // 顶部占位：第一行落在透明标题栏下方，但它跟着内容一起滚走
          Column().height(this.topInset + 6).width('100%')

          // ------------------------------------------------ 开关
          Column({ space: 12 }) {
            Column({ space: 8 }) {
              ToggleSetting({
                label: '音效（EQ）',
                value: this.eqEnabled,
                onPick: (next: boolean) => {
                  AudioEffectSettings.getInstance().setEnabled(next);
                },
              })
              HintText({
                text: this.eqEnabled
                  ? '开着的时候，每首歌在起播前先过一次 EQ：起播多等约 0.3~0.5 秒，之后就是普通播放。'
                  : '音效现在关着：下面的调节会存下来，打开这个开关才开始生效。',
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 10 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 预设
          Column({ space: 12 }) {
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Text('预设')
                  .fontSize(15)
                  .fontColor(C_TEXT)
                if (this.eqPreset === 'custom') {
                  Text('自定义')
                    .fontSize(10.5)
                    .fontColor(C_RED)
                    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                    .borderRadius(8)
                    .backgroundColor(C_RED_TINT)
                }
                Blank()
              }
              .width('100%')

              Column({ space: this.chipsGap() }) {
                ForEach(this.presetRows(), (row: EqPreset[], rowIndex: number) => {
                  Row({ space: 8 }) {
                    ForEach(row, (preset: EqPreset) => {
                      Text(preset.label)
                        .fontSize(13.5)
                        .fontWeight(this.eqPreset === preset.key ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor(this.eqPreset === preset.key ? C_ON_ACCENT : C_SEG_UNSELECTED)
                        .textAlign(TextAlign.Center)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .height(36)
                        .layoutWeight(1)
                        .borderRadius(18)
                        .backgroundColor(this.eqPreset === preset.key ? C_RED : C_SEG_BG)
                        .animation({ duration: 180, curve: Curve.EaseInOut })
                        .onClick(() => {
                          AudioEffectSettings.getInstance().selectPreset(preset.key);
                        })
                    }, (preset: EqPreset) => preset.key)
                    // 最后一行不满三个：补空位，别让剩下的胶囊被拉得比上面宽
                    ForEach(this.fillers(row.length), (hole: number) => {
                      Blank().layoutWeight(1)
                    }, (hole: number) => `eq_preset_hole_${rowIndex}_${hole}`)
                  }
                  .width('100%')
                }, (row: EqPreset[], rowIndex: number) => `eq_preset_row_${rowIndex}`)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 14 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '「原声」= 十段全 0，等于不做处理；「自定义」是自己拖过推子之后的状态。'
                + '选预设立刻生效；手动调的值要按右上角「应用」才生效。',
            })
          }
          .width(cardWidthOf(this.windowWidth))

          // ------------------------------------------------ 我的音效（自定义预设）
          // 整行铺满：一行一条音效（名字 + 摘要），跟两张窄卡并排会把名字挤断
          this.customPresetCard()

          // ------------------------------------------------ 十段推子
          Column({ space: 12 }) {
            Column({ space: 4 }) {
              Row({ space: 6 }) {
                Text('10 段均衡器')
                  .fontSize(15)
                  .fontColor(C_TEXT)
                Text('Hz / dB')
                  .fontSize(10.5)
                  .fontColor(C_TEXT_WEAK)
                Blank()
                /**
                 * 应用：把自己拖出来的这套增益交给播放侧（重播一次，和选预设一样快）
                 *
                 * 为什么不是自动：一次调整常常要动好几段推子，段段都重播会把一首歌
                 * 打回开头七八次。调完统一按一下，只重播一次。
                 * 没改动时按钮变灰写「已应用」，按了也不打断播放。
                 */
                Row({ space: 5 }) {
                  if (this.eqDirty) {
                    Column()
                      .width(5)
                      .height(5)
                      .borderRadius(2.5)
                      .backgroundColor(C_ON_ACCENT)
                  }
                  Text(this.eqDirty ? '应用' : '已应用')
                    .fontSize(11.5)
                    .fontWeight(this.eqDirty ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(this.eqDirty ? C_ON_ACCENT : C_TEXT_WEAK)
                }
                .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(this.eqDirty ? C_RED : C_SEG_BG)
                .animation({ duration: 160, curve: Curve.EaseInOut })
                .accessibilityText(this.eqDirty ? '应用音效设置' : '音效设置已应用')
                .onClick(() => {
                  AudioEffectSettings.getInstance().applyGains();
                })
              }
              .width('100%')
              .height(30)

              EqCurve({ gains: this.eqGains })
                // 曲线底边别贴着第一段推子：两块内容要能看出是「图」和「操作」两层
                .margin({ top: 4, bottom: 8 })

              ForEach(EQ_BAND_LABELS, (label: string, index: number) => {
                EqBandRow({
                  label: label,
                  gain: this.eqGains[index] ?? 0,
                  onPick: (gain: number, done: boolean) => {
                    // 拖动过程只改内存，松手才落盘（见 setBandGain 的 commit 参数）
                    AudioEffectSettings.getInstance().setBandGain(index, gain, done);
                  },
                })
              }, (label: string, index: number) => `eq_band_${index}`)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(R_CARD)
            .backgroundColor(C_CARD)

            HintText({
              text: '左端 31 Hz 是低频（鼓、贝斯），右端 16 kHz 是高频（镲片、齿音）；'
                + '每段往右抬、往左压，中点是 0 dB 不增不减。点轨道直接跳到该位置，'
                + '横向拖动连续调；调完按右上角「应用」，当前这首会从头重新处理一遍。',
            })
          }
          // 十段推子卡在宽屏下独占整行：十行推子要的是整行宽度，跟两张窄卡并排会挤得没法拖
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 16 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    /**
     * 命名输入面板
     *
     * 本页没有输入弹层先例，沿用项目里既有的 bindSheet 写法（见 views/MineView.ets 的新建 /
     * 重命名面板）：底部半屏 sheet + TextInput + 取消 / 保存，比自绘覆盖物少一层层级管理。
     */
    .bindSheet($$this.nameOpen, this.nameSheet(), {
      preferType: SheetType.BOTTOM,
      detents: [SheetSize.MEDIUM],
      detentSelection: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      title: { title: '保存为我的音效' },
    })
  }
}

/**
 * 一段 EQ 推子（横向、双极：-10 ~ +10 dB，0 dB 在中点）
 *
 * 为什么要自己画外观：这一段是**双极**的。系统 Slider 的进度条只能从 min 一路填到当前值
 * —— 增益全是 0 时它照样把半根轨道涂成红色，十段堆在一起就是十条长度相近的红线，
 * 既看不出「哪段加、哪段减」，一眼扫过去还特别拥挤。这里画的是「淡轨道 + 从中点向两侧
 * 长出去的红色填充 + 一枚圆钮」，抬哪段压哪段一看就懂。
 *
 * 但**手势仍然交给一枚透明的系统 Slider**（轨道、选中段、圆钮全设成透明，只留触摸）。
 * 原因是自绘 PanGesture 在可滚动页面里会被外层 Scroll 抢走：实测横向拖动时页面跟着滚，
 * 推子纹丝不动。Slider 是框架自己的控件，抢手势的优先级与外层滚动是配好的，
 * 放在任何滚动列表里都可靠。
 *
 * 两套坐标要对齐：Slider 在 OutSet/blockSize=KNOB 时，圆钮中心从 KNOB/2 走到 宽-KNOB/2，
 * 这里画圆钮也用同一个映射（见 knobX），所以看到的圆钮就在手指底下。
 */
@Component
struct EqBandRow {
  @Prop label: string = '';
  @Prop gain: number = 0;
  /** 拖动中 done=false，松手 / 点击 done=true */
  onPick: (gain: number, done: boolean) => void = () => {
  };

  private static readonly KNOB: number = 13;
  private static readonly H: number = 40;

  /** 轨道区可用宽度；首帧为 0，等 onAreaChange 填上再画内容 */
  @State private bandWidth: number = 0;

  private usable(): number {
    return Math.max(1, this.bandWidth - EqBandRow.KNOB);
  }

  private ratio(gain: number): number {
    return (gain - EQ_GAIN_MIN) / (EQ_GAIN_MAX - EQ_GAIN_MIN);
  }

  /** 圆钮左上角（与 Slider 的块位置同一条映射） */
  private knobX(gain: number): number {
    return this.ratio(gain) * this.usable();
  }

  /** 轨道中点（0 dB 的位置） */
  private center(): number {
    return this.bandWidth / 2;
  }

  /** 填充条左端：正增益从中点往右长，负增益往左长 */
  private fillX(): number {
    const knobCenter: number = this.knobX(this.gain) + EqBandRow.KNOB / 2;
    return knobCenter >= this.center() ? this.center() : knobCenter;
  }

  private fillW(): number {
    const knobCenter: number = this.knobX(this.gain) + EqBandRow.KNOB / 2;
    return Math.abs(knobCenter - this.center());
  }

  build() {
    Row({ space: 10 }) {
      Text(this.label)
        .fontSize(12)
        .fontColor(C_TEXT_WEAK)
        .width(30)
        .textAlign(TextAlign.End)

      Stack() {
        // 淡轨道
        Row()
          .width('100%')
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(C_SLIDER_TRACK)
          .position({ x: 0, y: (EqBandRow.H - 3) / 2 })

        if (this.bandWidth > 0) {
          // 0 dB 中线：抬还是压，看填充长在中点的哪一侧
          Row()
            .width(1)
            .height(13)
            .backgroundColor(C_TEXT_WEAK)
            .opacity(0.45)
            .position({ x: this.center() - 0.5, y: (EqBandRow.H - 13) / 2 })

          if (this.fillW() >= 1) {
            Row()
              .width(this.fillW())
              .height(3)
              .borderRadius(1.5)
              .backgroundColor(C_RED)
              .position({ x: this.fillX(), y: (EqBandRow.H - 3) / 2 })
          }

          Row()
            .width(EqBandRow.KNOB)
            .height(EqBandRow.KNOB)
            .borderRadius(EqBandRow.KNOB / 2)
            .backgroundColor(C_RED)
            .position({ x: this.knobX(this.gain), y: (EqBandRow.H - EqBandRow.KNOB) / 2 })
        }

        // 只负责手势的透明滑块：轨道与圆钮都藏起来，外观由上面几层画
        Slider({
          value: this.gain,
          min: EQ_GAIN_MIN,
          max: EQ_GAIN_MAX,
          step: 1,
          style: SliderStyle.OutSet,
        })
          .width('100%')
          .height(EqBandRow.H)
          .blockSize({ width: EqBandRow.KNOB, height: EqBandRow.KNOB })
          .blockColor(Color.Transparent)
          .trackThickness(3)
          .trackColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .onChange((value: number, mode: SliderChangeMode) => {
            // 拖动过程只改内存，松手 / 点击才落盘（见 setBandGain 的 commit 参数）
            const done: boolean = mode === SliderChangeMode.End || mode === SliderChangeMode.Click;
            if (value !== this.gain || done) {
              this.onPick(value, done);
            }
          })
      }
      .layoutWeight(1)
      .height(EqBandRow.H)
      .onAreaChange((_old: Area, area: Area) => {
        const w: number = Number.parseFloat(area.width.toString());
        if (!Number.isNaN(w) && Math.abs(w - this.bandWidth) > 0.5) {
          this.bandWidth = w;
        }
      })

      Text(`${this.gain > 0 ? '+' : ''}${this.gain}`)
        .fontSize(12)
        .fontColor(this.gain === 0 ? C_TEXT_WEAK : C_TEXT)
        .width(28)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(EqBandRow.H)
  }
}

/**
 * 10 段均衡器的响应曲线
 *
 * 用 Path 而不是 Canvas：Canvas 的 fillStyle 只吃色值字符串，取不到资源色，
 * 深色模式下必然画错（本项目的色全是 token）。Path 的 fill / stroke 接受 ResourceColor，
 * 深浅模式自动跟着走。
 *
 * 只是概览：横轴 10 个点对应 10 段中心频率，纵轴是增益，中间那条线是 0 dB。
 */
@Component
struct EqCurve {
  @Prop gains: number[] = [];
  @State private curveWidth: number = 0;

  private static readonly H: number = 118;
  /** 上下留白：增益拉满时线不要贴边 */
  private static readonly PAD: number = 12;

  /**
   * commands 里的坐标是**物理像素**，而组件的宽高是 vp
   *
   * 实测踩到的坑：按 vp 写 commands 时，曲线只画出左边三分之一（1 vp ≈ 2.7 px，
   * 画出来就是 1/2.7 大）。这里统一乘一次密度，让命令里的单位与组件盒子对齐。
   */
  private density(): number {
    return this.getUIContext().vp2px(1);
  }

  /** 折线（不闭合，给描边用）：两端各补一个边界点，铺满整条宽度 */
  private linePath(): string {
    const n: number = this.gains.length;
    if (this.curveWidth <= 0 || n < 2) {
      return '';
    }
    const k: number = this.density();
    const mid: number = EqCurve.H / 2;
    const amp: number = mid - EqCurve.PAD;
    let d: string = '';
    // i 从 -1 到 n：-1 补在 x=0，n 补在 x=右边缘，这样曲线是「贴边」的，
    // 下面的填充也就是一条竖直边，而不是从首末点斜着收口（那样像个水桶）
    for (let i = -1; i <= n; i++) {
      const at: number = Math.min(n - 1, Math.max(0, i));
      const g: number = Math.max(EQ_GAIN_MIN, Math.min(EQ_GAIN_MAX, this.gains[at] ?? 0));
      const x: number = (i < 0 ? 0 : (i >= n ? this.curveWidth : (this.curveWidth * (i + 0.5)) / n)) * k;
      const y: number = (mid - (g / EQ_GAIN_MAX) * amp) * k;
      d += `${i < 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`;
    }
    return d;
  }

  /** 同一条线再收口到底边，给那层很淡的红填充用 */
  private areaPath(): string {
    const line: string = this.linePath();
    if (line.length === 0) {
      return '';
    }
    const k: number = this.density();
    return `${line}L${(this.curveWidth * k).toFixed(1)} ${(EqCurve.H * k).toFixed(1)}`
      + `L0 ${(EqCurve.H * k).toFixed(1)}Z`;
  }

  build() {
    Stack() {
      if (this.curveWidth > 0) {
        Path()
          .width('100%')
          .height(EqCurve.H)
          .commands(this.areaPath())
          .fill(C_RED_TINT)
          // Path 不给 stroke 时默认会描一圈黑边，把填充的形状勾出来就脏了
          .stroke(Color.Transparent)
        Path()
          .width('100%')
          .height(EqCurve.H)
          .commands(this.linePath())
          .fill(Color.Transparent)
          .stroke(C_RED)
          .strokeWidth(2)
          .strokeLineJoin(LineJoinStyle.Round)
      }

      // 0 dB 基准线
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(C_SLIDER_TRACK)
        .position({ x: 0, y: EqCurve.H / 2 })

      Row()
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height(EqCurve.H)
    .onAreaChange((_old: Area, area: Area) => {
      const w: number = Number.parseFloat(area.width.toString());
      if (!Number.isNaN(w) && Math.abs(w - this.curveWidth) > 0.5) {
        this.curveWidth = w;
      }
    })
  }
}

// ---------------------------------------------------------------- 我的音效：文件读写
// 与 core/local/PlaylistPort 的导入 / 导出同一套做法：picker 给的 uri 走沙箱外的 provider，
// `readTextSync` 只认沙箱路径，所以读用 openSync + stat + readSync + TextDecoder，写直接写 uri。

/** 读出 picker uri 的全文（UTF-8，去掉 BOM） */
function readTextFromUri(uri: string): string {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const size: number = fs.statSync(file.fd).size;
    if (size <= 0) {
      throw new Error('文件是空的');
    }
    if (size > MAX_IMPORT_BYTES) {
      throw new Error('文件太大，不像是音效文件');
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    let read: number = fs.readSync(file.fd, buffer);
    // readSync 不保证一次读满（picker uri 可能来自网盘 / 文档服务的流式实现），循环补齐再解析
    while (read > 0 && read < size) {
      const rest: ArrayBuffer = new ArrayBuffer(size - read);
      const got: number = fs.readSync(file.fd, rest);
      if (got <= 0) {
        break;
      }
      new Uint8Array(buffer).set(new Uint8Array(rest, 0, got), read);
      read += got;
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const text: string = decoder.decodeToString(new Uint8Array(buffer, 0, read));
    return text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 关闭失败不影响已经读到的内容，静默
      }
    }
  }
}

/** 往 picker 返回的目标 uri 里写文本（先截断，避免旧内容留在尾部） */
function writeTextToUri(uri: string, text: string): void {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 同上：写已经完成，关闭失败不影响结果
      }
    }
  }
}

/** 用户取消：不同系统版本有的给空数组、有的抛 BusinessError（与 PlaylistPort.isCancel 同一判据） */
function isPickerCancel(error: BusinessError): boolean {
  if (error === null || error === undefined) {
    return false;
  }
  const message: string = error.message !== undefined ? error.message.toLowerCase() : '';
  return error.code === 13900042 || message.includes('cancel') || message.includes('取消');
}
