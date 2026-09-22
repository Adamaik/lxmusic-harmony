import { SongItem } from '../player/PlaySession';

/**
 * 歌单 / 收藏的**非同步侧表**
 *
 * 背景见 docs/LOCAL_MUSIC.md 第 7 节：参与洛雪同步的那份数据（LxListData）要按
 * listData() 的 JSON 算 md5 与服务端比对，往里塞任何字段都会改掉 md5；而
 * `musicsOf()` 又会把 `isSyncable() === false` 的条目直接丢掉。所以「不属于在线歌
 * 的那部分歌单成员」只能另存一份 —— 这就是侧表。
 *
 * 现在有两张侧表，行为完全一致，只是持有的条目种类不同：
 *   - LocalMusic    —— 设备里导入进来的音频（source = 'local'）
 *   - WebDavLibrary —— 自己云服务器上的音频（source = 'webdav'）
 * 于是把公共面抽成这个接口，LocalLibrary 按一个数组统一读写 / 合并 / 计数，
 * 不必再为「第三种来源」改一遍所有合并点。
 */
export interface SongSideTable {
  /** 这张侧表持有的条目 source 标记（local / webdav），也用来认领一个 SongItem */
  source: string;
  /** 条目 id（`<source>_<key>`）-> key；不是本表的条目返回空串 */
  keyOfId(id: string): string;
  /** key 还在不在库里（界面按它隐藏音质 / 下载入口） */
  hasKey(key: string): boolean;
  /** 一批 key 对应的展示条目（按传入顺序，跳过已经不存在的） */
  songsByKeys(keys: string[]): SongItem[];
  /** 曲库总条数（设置页的规模统计用） */
  count(): number;
  listKeys(listId: string): string[];
  listCount(listId: string): number;
  setListKeys(listId: string, keys: string[]): void;
  /** 往歌单里加（新的排最前）；返回真正加进去的数量 */
  addToList(listId: string, keys: string[]): number;
  /** @returns 真正被摘掉的条数 */
  removeFromList(listId: string, keys: string[]): number;
  /** 歌单被删掉了：侧表一起清 */
  dropLists(listIds: string[]): void;
}
