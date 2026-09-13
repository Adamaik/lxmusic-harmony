import { SourceInfo, SourceMeta } from './LxTypes';

/**
 * 源脚本头部元信息解析
 *
 * 移植自 lx-music-mobile/src/utils/data.ts 的 INFO_NAMES + matchInfo + addUserApi。
 * 洛雪要求源脚本以 `/* ... *\/` 注释块开头，块内用 `@key value` 声明元信息：
 *
 *   /*!
 *    * @name 我的音源
 *    * @description 说明
 *    * @version 1.0.0
 *    * @author me
 *    * @homepage https://example.com
 *    *\/
 */

/** 各字段的最大长度，与洛雪保持一致（超出会被截断并追加 ...） */
const INFO_NAME_MAX_LENGTH: Record<string, number> = {
  'name': 24,
  'description': 36,
  'author': 56,
  'homepage': 1024,
  'version': 36,
};

const HEADER_START = '/*';
const HEADER_END = '*/';

/** 解析脚本头部的 `@key value` */
export function parseSourceMeta(script: string): SourceMeta {
  // 洛雪要求注释块在脚本最开头，这里手工解析，避免依赖 RegExpMatchArray
  const start: number = script.indexOf(HEADER_START);
  const end: number = start >= 0 ? script.indexOf(HEADER_END, start + HEADER_START.length) : -1;
  if (start !== 0 || end < 0) {
    throw new Error('源脚本格式错误：缺少开头的 /* ... */ 注释块');
  }
  const header: string = script.substring(0, end + HEADER_END.length);
  const infos: Record<string, string> = {};
  const lines: string[] = header.split(/\r?\n/);
  for (const rawLine of lines) {
    const line: string = rawLine.trim();
    if (line.length === 0 || !line.startsWith('*')) {
      continue;
    }
    let body: string = line.substring(1).trim();
    if (!body.startsWith('@')) {
      continue;
    }
    body = body.substring(1);
    const spaceIndex: number = body.search(/\s/);
    if (spaceIndex <= 0) {
      continue;
    }
    const key: string = body.substring(0, spaceIndex);
    const value: string = body.substring(spaceIndex + 1).trim();
    if (INFO_NAME_MAX_LENGTH[key] === undefined) {
      continue;
    }
    infos[key] = value;
  }

  const meta: SourceMeta = {
    name: infos['name'] !== undefined ? infos['name'] : '',
    description: infos['description'] !== undefined ? infos['description'] : '',
    version: infos['version'] !== undefined ? infos['version'] : '',
    author: infos['author'] !== undefined ? infos['author'] : '',
    homepage: infos['homepage'] !== undefined ? infos['homepage'] : '',
  };
  const keys: string[] = Object.keys(INFO_NAME_MAX_LENGTH);
  for (const key of keys) {
    const max: number = INFO_NAME_MAX_LENGTH[key];
    let value: string = infos[key] !== undefined ? infos[key] : '';
    if (value.length > max) {
      value = value.substring(0, max) + '...';
    }
    if (key === 'name') {
      meta.name = value;
    } else if (key === 'description') {
      meta.description = value;
    } else if (key === 'version') {
      meta.version = value;
    } else if (key === 'author') {
      meta.author = value;
    } else if (key === 'homepage') {
      meta.homepage = value;
    }
  }
  return meta;
}

/** 生成音源 id，规则与洛雪一致：user_api_<随机3位>_<时间戳> */
export function createSourceId(): string {
  return `user_api_${Math.random().toString().substring(2, 5)}_${Date.now()}`;
}

/**
 * 音源身份键：同一个「名字 + 版本 + 作者」视为同一个音源。
 *
 * 洛雪每次都生成新的 user_api id 并把导入的源追加进列表，同一个源导入两次就会
 * 出现两条一模一样的记录（截图里三份「六音音源 v1.2.1」就是这么来的）。
 * 去重时用这个键，重复导入同一份脚本就覆盖更新，而不是再堆一条。
 */
export function sourceMetaKey(info: SourceMeta): string {
  return `${info.name}\u0001${info.version}\u0001${info.author}`.toLowerCase();
}

/** 由脚本内容构造一个完整的 SourceInfo */
export function buildSourceInfo(script: string): SourceInfo {
  const meta: SourceMeta = parseSourceMeta(script);
  const info: SourceInfo = {
    id: createSourceId(),
    name: meta.name.length > 0 ? meta.name : `未命名音源 ${new Date().toLocaleString()}`,
    description: meta.description,
    version: meta.version,
    author: meta.author,
    homepage: meta.homepage,
    allowShowUpdateAlert: true,
    importedAt: Date.now(),
  };
  return info;
}

/** 脚本大小上限，与洛雪一致（约 9MB） */
export const MAX_SCRIPT_SIZE: number = 9000000;
