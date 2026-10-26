/**
 * 更新公告的数据
 *
 * 一条公告 = 一次发版（或一次成规模的更新）：日期 + 一句话主题 + 若干条目。
 *
 * **数组顺序就是展示顺序：新的在上面、老的在下面。** 界面上是从第一条往下连成一条
 * 时间线（见 views/ChangelogView.ets），所以新增一条时往数组**头部**插一个对象，
 * 不要按日期去排 —— 排一次序就等于把「发布顺序」这个真相丢掉一次。
 *
 * 公告跟着安装包走：没有后端可拉，也不必拉。用户装的是哪个版本，就自然只能看到
 * 这个版本之前（含）的公告，不会出现「公告里写了还没装上的功能」。
 *
 * 日期只写 yyyy-MM-dd 这一种形式，界面上要的「10月27日」「周二」都由下面的函数算，
 * 不要在数据里手写星期（写错一次没人会去核对，但错的那个会一直挂在时间线上）。
 */

export interface ChangelogEntry {
  /** 日期：yyyy-MM-dd（展示顺序 = 数组顺序，见文件头） */
  date: string;
  /** 这一版的一句话主题（时间线上日期下面那行） */
  title: string;
  /** 逐条更新内容，界面上一条一行 */
  items: string[];
}

/** 从新到旧（头部是最新一条） */
export const CHANGELOG: ChangelogEntry[] = [
  {
    date: '2026-10-27',
    title: '探索页 · 心动推荐',
    items: [
      '底部导航新增「探索」页：进来就自动播放，下滑换下一首，翻过去的不再回头（像刷短视频）。',
      '下滑跳过的歌算「不喜欢」，双击封面或点一下红心算「喜欢」，推荐会跟着你的反馈一直调整。',
      '推荐画像只用本机的播放历史与收藏来建；候选歌从全网来（榜单、推荐歌单、艺人作品），再按画像排序。',
      '新增离线缓存：进页面先用上次的候选秒出歌，后台再静默换一批，不用盯着转圈等。',
      '跨音源去重：歌名和歌手一致就当作同一首歌 —— 换个平台推的同一首不再重复出现，收藏状态也互通。',
      '「帮助和反馈」里新增更新公告：从新到旧连成一条时间线，每次更新做了什么都能回看。',
    ],
  },
  {
    date: '2026-10-21',
    title: '第五版：回响 · 歌手页 · 歌单广场',
    items: [
      '新增「回响」：按月的听歌报告，常听歌手、歌曲榜、收听时段与完成度都在里面。',
      '新增歌手页与歌手列表：搜索结果里、正在播的歌里的歌手名都能点进去。',
      '新增歌单广场：按分类逛推荐歌单，可以收藏，也可以导入成自己的歌单。',
      '播放记录改为逐次落盘，应用被杀掉也不丢；封面单独缓存，列表滚动不再反复拉图。',
      '第五版累计的界面与播放细节调整（迷你播放器、推荐页、我的页、在线列表等）。',
    ],
  },
  {
    date: '2026-09-29',
    title: '听歌识曲上线',
    items: [
      '新增听歌识曲：录一段音频去识别，酷狗 + 网易云双引擎，识别记录可回看。',
      '新增书源登录：听书源需要登录时，直接在应用内置网页里登。',
      '聚合搜索补上搜索建议。',
      '听书设置独立成页。',
    ],
  },
  {
    date: '2026-09-27',
    title: '听书：导入与下载修好',
    items: [
      '修好听书导入与沙箱在真机上的两处问题。',
      '听书接进下载系统：单集、整本都能下，播放时离线优先。',
    ],
  },
  {
    date: '2026-09-24',
    title: '多选改版 · 我的页重构',
    items: [
      '多选改成顶栏 + 底栏两条（照华为音乐）。',
      '「我的」页重构：快捷入口 + 歌单卡 + 设置卡。',
      '新增听书引擎（书源脚本）与下载写标签。',
    ],
  },
  {
    date: '2026-09-22',
    title: '聚合搜索 · 玻璃光效界面',
    items: [
      '搜索改成聚合搜索：一次搜遍各平台，同一首歌合并成一条。',
      '界面换成玻璃光效（系统材质 + 高光描边），深浅模式各一套。',
      '新增本地音乐导入与歌单导入。',
    ],
  },
  {
    date: '2026-09-14',
    title: '首个版本',
    items: [
      '洛雪音乐（LX Music）的鸿蒙移植版：音源脚本引擎、全网搜索与歌单、歌词与封面。',
      '播放会话、播控中心、迷你播放器与全屏播放器。',
      '洛雪歌单同步与设置页。',
    ],
  },
];

/** 拆分 yyyy-MM-dd（算星期与中文日期都要用） */
interface Ymd {
  year: number;
  month: number;
  day: number;
}

function ymdOf(iso: string): Ymd {
  const parts: string[] = iso.split('-');
  if (parts.length < 3) {
    return { year: 1970, month: 1, day: 1 };
  }
  return { year: parseInt(parts[0], 10), month: parseInt(parts[1], 10), day: parseInt(parts[2], 10) };
}

const WEEKDAYS: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

/**
 * 星期几（0 = 周日）
 *
 * 不用 `new Date(iso)`：那种只给日期的字符串按 UTC 解析，跨时区会整体偏一天，
 * 时间线上的星期就会错。这里用 Sakamoto 算法纯算术算，跟时区无关。
 */
function weekdayIndexOf(ymd: Ymd): number {
  let year: number = ymd.year;
  let month: number = ymd.month;
  if (month < 3) {
    month += 12;
    year -= 1;
  }
  const table: number[] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
  const sum: number = year + Math.floor(year / 4) - Math.floor(year / 100) + Math.floor(year / 400)
    + table[month - 1] + ymd.day;
  return sum % 7;
}

/** '2026-10-27' -> '2026年10月27日' */
export function fullDateOf(iso: string): string {
  const ymd: Ymd = ymdOf(iso);
  return `${ymd.year}年${ymd.month}月${ymd.day}日`;
}

/** '2026-10-27' -> '10月27日'（卡片副标题这种位置用，省掉年份） */
export function monthDayOf(iso: string): string {
  const ymd: Ymd = ymdOf(iso);
  return `${ymd.month}月${ymd.day}日`;
}

/** '2026-10-27' -> '周二' */
export function weekdayOf(iso: string): string {
  return WEEKDAYS[weekdayIndexOf(ymdOf(iso))];
}

/** 最近一次更新的日期（yyyy-MM-dd）；数据为空时退回空串 */
export function latestDateOf(): string {
  return CHANGELOG.length > 0 ? CHANGELOG[0].date : '';
}

/** 最近一次更新的「几月几号」，给入口卡片当副标题 */
export function latestMonthDayOf(): string {
  const date: string = latestDateOf();
  return date.length > 0 ? monthDayOf(date) : '';
}

/** 一共记了多少次更新 */
export function updateCount(): number {
  return CHANGELOG.length;
}
