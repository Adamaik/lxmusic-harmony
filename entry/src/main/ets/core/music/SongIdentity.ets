/**
 * 歌曲身份键（跨音源去重用的「同一首歌」判定）
 *
 * ## 口径
 * 用户定的规则：**歌名 + 作者一致就算同一首歌**，不管它来自哪个音源。
 * 这条规则专门用来避免「本机收藏是酷狗源的《X》，网易账号里已经有网易源的同名歌，
 * 平台同步还硬往账号里再写一遍」这种重复。
 *
 * ## 归一化做什么
 * 各音源给同一首歌的元数据写法不一样，直接字符串相等会漏判：
 *   - 歌名大小写、全半角括号、空白、常见标点（`（Live版）` / `(Live版)`）；
 *   - 作者列表的分隔符与顺序：`A、B` / `B & A` / `A/B`；
 *   - 后缀噪声：`feat.`、`- Remastered`、`【】` 之类。
 *
 * 所以这里做「尽量保守」的归一化：只削掉大小写差异、空白、括号与常见标点，
 * 并把作者拆成集合排序后比较。**宁可漏判（多写一次，平台侧幂等），不要误判**
 * （把两首不同的歌当成一首而漏推）。
 *
 * 注意：不做拼音/简体转换、不做翻译名匹配 —— 那些会带来误判。
 */

/** 作者分隔符：`、` `,` `，` `/` `&` `＆` `feat.` `ft.` `x`（前后带空格时才当分隔符） */
const SINGER_SEPARATORS: RegExp = /\s*(?:、|,|，|\/|&|＆|\+|\bfeat\.?\b|\bft\.?\b)\s*/g;

/** 需要整体删掉的标点（保留文字与数字；括号先当作分隔/噪声） */
const PUNCTUATION: RegExp = /[\s\u3000()（）\[\]【】{}<>《》"'“”‘’·•\-—–_~!！?？:：;；.。,，]/g;

/** 归一到「比较用的最小形态」：小写 + 去标点 + 全角空格也去 */
function normalizePart(text: string): string {
  if (text.length === 0) {
    return '';
  }
  return text.toLowerCase().replace(PUNCTUATION, '');
}

/**
 * 作者列表 -> 排序后的集合键
 *
 * 拆开、去空、去重、排序：`A、B` 与 `B & A` 得到同一结果。
 * 单个作者时结果就是归一化后的名字。
 */
function normalizeSingers(singer: string): string {
  const parts: string[] = singer.split(SINGER_SEPARATORS);
  const unique: string[] = [];
  for (const part of parts) {
    const normalized: string = normalizePart(part);
    if (normalized.length === 0) {
      continue;
    }
    if (unique.indexOf(normalized) < 0) {
      unique.push(normalized);
    }
  }
  if (unique.length === 0) {
    return '';
  }
  unique.sort();
  return unique.join('|');
}

/**
 * 生成身份键：`<归一化歌名>|<归一化作者集合>`
 *
 * 任一部分为空时仍然生成（只有歌名或只有作者也比完全不判强），但两者都空返回空串，
 * 调用方见到空串必须**跳过**这条判定（不能把「不知道」当成「同一首歌」）。
 */
export function songIdentityOf(name: string, singer: string): string {
  const title: string = normalizePart(name === undefined || name === null ? '' : name);
  const artists: string = normalizeSingers(singer === undefined || singer === null ? '' : singer);
  if (title.length === 0 && artists.length === 0) {
    return '';
  }
  return `${title}|${artists}`;
}
