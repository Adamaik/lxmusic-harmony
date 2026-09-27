/**
 * 书源导入自检（无设备）
 *
 * `book_engine_selftest.js` 验证的是**规则求值**（沙箱 + 回放循环），它把书源当成
 * 已经解析好的 JS 对象喂进去，所以覆盖不到「应用是怎么把一份 JSON 文件变成
 * 一条能搜的书源」这一段。这个脚本补的正是那一段：
 *
 *   1. 把 `BookEngine.importSources / importOne` 与 `BookSourceStore` 的索引语义
 *      **照原样搬过来**（ArkTS 跑不了，但算法是一比一复刻）；
 *   2. 对「听书的源」目录里的每个文件跑一遍导入，校验抽出来的元信息；
 *   3. 复刻 `BookEngine.buildJob` 的**字符串拼接**（不是 JSON.stringify 整个对象），
 *      确认拼出来的作业 JSON 仍然合法、书源字段一个没丢 —— 这一段是宿主与沙箱的
 *      接口，接错了就是「导入进去解析不了」；
 *   4. 静态守卫：`importFromUri` 不能再把 Picker 的 URI 直接丢给 `readTextSync`。
 *
 * 用法：
 *   node tools/book_import_test.js                 # 只跑导入（离线）
 *   node tools/book_import_test.js --live 诡秘之主   # 再联网跑一遍搜索
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ENGINE = path.join(ROOT, 'entry/src/main/ets/core/book/BookEngine.ets');
const BOOK_HTTP = path.join(ROOT, 'entry/src/main/ets/core/book/BookHttp.ets');
const DOWNLOAD_MANAGER = path.join(ROOT, 'entry/src/main/ets/core/download/DownloadManager.ets');
const PLAY_SESSION = path.join(ROOT, 'entry/src/main/ets/core/player/PlaySession.ets');
const BOOK_DETAIL = path.join(ROOT, 'entry/src/main/ets/views/BookDetailView.ets');
const MEDIA_CACHE = path.join(ROOT, 'entry/src/main/ets/core/music/MediaCache.ets');
const SOURCE_DIRS = [
  path.resolve(ROOT, '..', '听书的源'),
  'C:/Users/Lenovo/Downloads',
];

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.log(`  ✗ ${name}${detail ? '  —— ' + detail : ''}`); }
}

// ------------------------------------------------------------ 应用侧算法的复刻

/** BookSourceStore.sourceText：只认这几个 key，非字符串一律 String() 化 */
function sourceText(source, key) {
  const KEYS = ['bookSourceName', 'bookSourceUrl', 'bookSourceGroup', 'bookSourceComment', 'searchUrl', 'exploreUrl'];
  if (!KEYS.includes(key)) { return ''; }
  const value = source[key];
  if (value === undefined || value === null) { return ''; }
  return typeof value === 'string' ? value : String(value);
}

/** BookEngine.importOne（去掉落盘，返回索引条目） */
function importOne(source, store) {
  const name = sourceText(source, 'bookSourceName');
  const url = sourceText(source, 'bookSourceUrl');
  if (name.length === 0 && url.length === 0) { return null; }
  const searchUrl = sourceText(source, 'searchUrl');
  const exploreUrl = sourceText(source, 'exploreUrl');
  const loginUrl = source.loginUrl !== undefined && source.loginUrl !== null ? source.loginUrl : '';
  const candidate = {
    id: '',
    name: name.length > 0 ? name : url,
    group: sourceText(source, 'bookSourceGroup'),
    url,
    comment: sourceText(source, 'bookSourceComment'),
    type: source.bookSourceType !== undefined ? source.bookSourceType : 1,
    canSearch: searchUrl.length > 0,
    canExplore: exploreUrl.length > 0,
    needLogin: loginUrl.length > 0,
    importedAt: Date.now(),
    raw: JSON.stringify(source),
  };
  for (const existing of store) {
    if (existing.name === candidate.name && existing.url === candidate.url) {
      Object.assign(existing, candidate, { id: existing.id });
      return existing;
    }
  }
  candidate.id = `book_${Date.now().toString(36)}_${Math.floor(Math.random() * 100000).toString(36)}`;
  store.push(candidate);
  return candidate;
}

/** BookEngine.importSources */
function importSources(text, store) {
  const trimmed = String(text).trim();
  if (trimmed.length === 0) { throw new Error('书源内容为空'); }
  let parsed;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    throw new Error('不是合法的 JSON，阅读书源应该是 JSON 文件');
  }
  const list = Array.isArray(parsed) ? parsed : [parsed];
  const imported = [];
  for (const source of list) {
    const info = importOne(source, store);
    if (info !== null) { imported.push(info); }
  }
  if (imported.length === 0) {
    throw new Error('书源里没有可用的条目（缺 bookSourceName / bookSourceUrl？）');
  }
  return imported;
}

/**
 * BookEngine.buildJob 的复刻：源正文**原样字符串拼接**进作业，不是嵌套对象。
 * 这里最容易出事 —— 拼坏了就是「沙箱收到一个残缺的书源」。
 */
function buildJob(action, sourceRaw, params, netCache) {
  const parts = [
    `"action":${JSON.stringify(action)}`,
    `"source":${sourceRaw}`,
    `"netCache":${JSON.stringify(netCache)}`,
  ];
  parts.push(`"bookSourceName":""`);
  for (const key of Object.keys(params)) {
    parts.push(`${JSON.stringify(key)}:${JSON.stringify(params[key])}`);
  }
  return `{${parts.join(',')}}`;
}

// ------------------------------------------------------------ 1. 离线：导入 + 作业拼装

function offlineCases() {
  console.log('\n== 导入：把「听书的源」里的文件当成粘贴的 JSON 走一遍应用算法 ==');

  let dir = null;
  for (const candidate of SOURCE_DIRS) {
    if (fs.existsSync(candidate)) { dir = candidate; break; }
  }
  if (dir === null) {
    check('找到书源目录', false, SOURCE_DIRS.join(' | '));
    return [];
  }
  console.log(`  书源目录：${dir}`);
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json'));
  check(`目录里有书源文件（${files.length} 个）`, files.length > 0, files.join(', '));

  const store = [];
  const imported = [];
  for (const file of files) {
    // 模拟「用户把文件内容粘贴/读出来」这一步：这里读的就是原始字节
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    let list = null;
    let error = null;
    try {
      list = importSources(text, store);
    } catch (e) {
      error = e.message;
    }
    if (error !== null) {
      check(`${file} 能导入`, false, error);
      continue;
    }
    const info = list[0];
    const detail = `${info.name} | ${info.url} | canSearch=${info.canSearch}`;
    check(`${file} → 导入成功`, info.name.length > 0 && info.url.length > 0, detail);
    console.log(`      ${detail} | canExplore=${info.canExplore} | 需登录=${info.needLogin}`);
    imported.push({ file, info });
  }

  // 每个源都必须「搜得到」：searchUrl 没被抽出来 = 导入后点了搜索没反应
  const noSearch = imported.filter((x) => !x.info.canSearch);
  check('每个源都识别出搜索能力', noSearch.length === 0,
    noSearch.map((x) => x.info.name).join(', '));

  // 导入的正文必须能原样还原（宿主存的是 JSON.stringify(source)，沙箱再 parse 回来）
  let roundTripOk = true;
  for (const { file, info } of imported) {
    let back = null;
    try { back = JSON.parse(info.raw); } catch (e) { back = null; }
    if (back === null || back.bookSourceName !== info.name) {
      roundTripOk = false;
      check(`${file} 正文可还原`, false, info.raw.slice(0, 80));
    }
    // 规则块一个都不能丢 —— 沙箱全靠它
    for (const rule of ['ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
      if (back !== null && back[rule] === undefined) {
        roundTripOk = false;
        check(`${file} 保留 ${rule}`, false, Object.keys(back).join(','));
      }
    }
  }
  check('导入的正文往返后规则块完整', roundTripOk);

  console.log('\n== 作业拼装：buildJob 的字符串拼接不能把书源弄坏 ==');
  let jobOk = true;
  for (const { file, info } of imported) {
    const job = buildJob('search', info.raw, { key: '测试关键词', page: 1 }, {});
    let parsed = null;
    try { parsed = JSON.parse(job); } catch (e) { parsed = null; }
    if (parsed === null) {
      jobOk = false;
      check(`${file} 作业 JSON 合法`, false, job.slice(0, 120));
      continue;
    }
    const same = parsed.source && parsed.source.bookSourceName === info.name
      && parsed.source.searchUrl === JSON.parse(info.raw).searchUrl;
    if (!same) {
      jobOk = false;
      check(`${file} 作业里的书源与导入时一致`, false, JSON.stringify(parsed.source || null).slice(0, 120));
    }
  }
  check('七个源的作业都能被 JSON.parse 且书源字段一致', jobOk);

  // 中文关键词不能被拼坏（拼错就变成乱码搜不到）
  const any = imported[0];
  if (any !== undefined) {
    const job = JSON.parse(buildJob('search', any.info.raw, { key: '凡人修仙传', page: 1 }, {}));
    check('中文关键词原样进作业', job.key === '凡人修仙传', JSON.stringify(job.key));
  }

  return imported;
}

// ------------------------------------------------------------ 2. 静态守卫：文件导入

/** 剥掉注释，免得守卫被说明文字里的示例代码骗到 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

function guardFileImport() {
  console.log('\n== 静态守卫：文件导入与书源请求头 ==');
  let engine = '';
  let http = '';
  try {
    engine = stripComments(fs.readFileSync(ENGINE, 'utf8'));
    http = stripComments(fs.readFileSync(BOOK_HTTP, 'utf8'));
  } catch (e) {
    check('读得到 book 目录的源文件', false, e.message);
    return;
  }
  // readTextSync(uri) / readTextSync(uris[0]) 这种把 URI 直接喂进去的写法会报
  // "No such file or directory"（readTextSync 只认沙箱路径）
  const bad = /readTextSync\s*\(\s*(uri|uris\[)/.test(engine);
  check('没有把 Picker URI 直接传给 readTextSync', !bad, bad ? '找到 readTextSync(uri...)' : '');
  const opens = /openSync\s*\(\s*uri\s*,\s*fs\.OpenMode\.READ_ONLY/.test(engine);
  check('importFromUri 用 openSync(uri, READ_ONLY) 打开再读', opens);

  // 书源请求头：Accept 兜底 */*、POST 兜底表单 Content-Type。
  // 少一个，音源那套 application/json 默认值就会串到书上（书音FM 的 POST 搜索即为此）。
  check('bookRequest 给 Accept 兜底 */*', /['"]Accept['"]\s*\]\s*=\s*['"]\*\/\*['"]/.test(http));
  check('bookRequest 给 POST 兜底表单 Content-Type',
    /application\/x-www-form-urlencoded/.test(http));

  // 设备上 runJavaScript 会把返回值再序列化一次；书源引擎的 ping 与 runInSandbox
  // 都必须还原，否则设备上「注入成功却报注入失败」「有结果却算成 0 条」。
  const uses = (engine.match(/unwrapJsonString\s*\(/g) || []).length;
  check('BookEngine 还原 runJavaScript 返回值（ping + 沙箱调用，至少 2 处）',
    uses >= 2, `找到 ${uses} 处`);
}

/**
 * 听书接进下载系统（2026-09-27 接入）
 *
 * 这一段没有可跑的逻辑（下载要设备：AVPlayer/网络/文件），所以两条腿走路：
 *   - 契约检查：按 BookDetailView 造一个章节条目，验证「下载键必须等于播放用的 id」
 *     以及载荷里有解析要用的字段 —— 这两条断了就是「下完了但播放找不到」；
 *   - 静态守卫：接线本身（书源分支、请求头、串行、离线优先）留在哪几处。
 */
function downloadCases() {
  console.log('\n== 契约：有声书条目的下载键与载荷 ==');

  // 与 core/music/MediaCache.ets 的 mediaKeyOf 同口径
  function mediaKeyOf(json) {
    if (json.length === 0) return '';
    try {
      const info = JSON.parse(json);
      const source = typeof info.source === 'string' ? info.source : '';
      const songmid = info.songmid !== undefined && info.songmid !== null ? String(info.songmid) : '';
      const hash = typeof info.hash === 'string' ? info.hash : '';
      if (source.length === 0 || songmid.length === 0) return '';
      return hash.length > 0 ? `${source}_${songmid}_${hash}` : `${source}_${songmid}`;
    } catch (e) {
      return '';
    }
  }
  // 与 core/download/DownloadManager.ets 的 downloadKeyOf 同口径
  function downloadKeyOf(song) {
    const media = mediaKeyOf(song.musicInfoJson);
    return media.length > 0 ? media : song.id;
  }

  // 照 BookDetailView.toSongItem 造一条（字段一个不多一个不少）
  const payload = {
    sourceId: 'book_x_1',
    bookName: '斗罗大陆之墨天归来',
    bookUrl: 'https://www.dushuyue.com/shu/16973.html',
    chapterIndex: 7,
    chapterName: '第二章：红乡学院',
    chapterUrl: 'https://www.dushuyue.com/play/16973-0-7.html',
    coverUrl: '',
  };
  const chapterSong = {
    id: 'book_book_x_1:https://www.dushuyue.com/shu/16973.html_7',
    name: payload.chapterName,
    singer: payload.bookName,
    coverUrl: payload.coverUrl,
    art: false,
    source: 'book',
    quality: 'book',
    interval: '--:--',
    musicInfoJson: JSON.stringify(payload),
  };

  check('书的载荷算不出 mediaKey（有意的，退回条目 id）', mediaKeyOf(chapterSong.musicInfoJson) === '');
  check('下载键 = 播放用的条目 id（否则 downloadedFile(item.id) 找不到）',
    downloadKeyOf(chapterSong) === chapterSong.id, downloadKeyOf(chapterSong));
  check('键非空且含集号（整本下载时一集一个键）',
    chapterSong.id.length > 0 && chapterSong.id.endsWith('_7'));

  // 载荷必须自带解析要用的一切：哪个源、哪本书、哪一集
  const parsed = JSON.parse(chapterSong.musicInfoJson);
  for (const field of ['sourceId', 'bookUrl', 'bookName', 'chapterUrl', 'chapterName', 'chapterIndex']) {
    check(`载荷带 ${field}`, parsed[field] !== undefined && parsed[field] !== '' && parsed[field] !== null);
  }
  check('载荷能过 parseBookPayload 的校验（有 sourceId）',
    parsed.sourceId !== undefined && parsed.sourceId !== null);

  console.log('\n== 静态守卫：接线留在哪几处 ==');
  let dl = '';
  let ps = '';
  let bd = '';
  try {
    dl = stripComments(fs.readFileSync(DOWNLOAD_MANAGER, 'utf8'));
    ps = stripComments(fs.readFileSync(PLAY_SESSION, 'utf8'));
    bd = stripComments(fs.readFileSync(BOOK_DETAIL, 'utf8'));
  } catch (e) {
    check('读得到下载 / 播放 / 详情页源码', false, e.message);
    return;
  }

  check('下载器 import 了书源引擎', /import \{ BookEngine \}/.test(dl));
  check('resolveUrl 里有书源分支', /resolveBookUrl/.test(dl) && /item\.source === BOOK_SOURCE/.test(dl));
  check('书源分支用的是同一套解析（resolveAudioOf）', /resolveAudioOf/.test(dl));
  check('解析结果带请求头（audioHeaders）', /audioHeaders/.test(dl));
  check('下载请求真的带上了请求头', /header:\s*resolved\.headers/.test(dl));
  check('有声书串行（同时只跑一集）', /bookBusy/.test(dl));
  check('有声书集间留间隔', /BOOK_TASK_GAP_MS/.test(dl));
  check('有声书不参与「缓存时自动下载」', /auto && song\.source === BOOK_SOURCE/.test(dl));
  check('有声书文件名按「书名-章节名」', /bookFileBase/.test(dl));
  check('有声书跳过音乐标签', /NO_TAGS/.test(dl));
  check('扩展名兜底认 m4a（书那个档位）', /'book':\s*'m4a'/.test(dl));

  const bookFn = ps.substring(ps.indexOf('private async playBookItem'), ps.indexOf('async playAt('));
  const atDownloaded = bookFn.indexOf('downloadedFile(item.id)');
  const atSourceCheck = bookFn.indexOf('getSource(payload.sourceId)');
  check('播放优先读已下载文件', atDownloaded >= 0);
  check('已下载优先于书源检查（书源删了也能听下载过的）',
    atDownloaded >= 0 && atSourceCheck >= 0 && atDownloaded < atSourceCheck,
    `downloaded@${atDownloaded} vs source@${atSourceCheck}`);

  check('详情页有「下载本集」', /downloadChapter/.test(bd));
  check('详情页有「下载整本」且先确认', /downloadAll/.test(bd) && /showAlertDialog/.test(bd));
}

// ------------------------------------------------------------ 3. 联网：逐源搜索

function loadSandbox() {
  const JSDOM_PATH = path.resolve(ROOT, '..', '.probe', 'booktest', 'node_modules', 'jsdom');
  let JSDOM = null;
  try {
    JSDOM = require(JSDOM_PATH).JSDOM;
  } catch (e) {
    console.error('缺少 jsdom，跳过联网部分。先装：npm install jsdom@24.1.3（见 book_engine_selftest.js）');
    return null;
  }
  const RAW = path.join(ROOT, 'entry/src/main/resources/rawfile');
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {
    url: 'https://sandbox.local/',
    runScripts: 'dangerously',
  });
  for (const file of ['lx_utils.js', 'book_preload.js']) {
    const el = dom.window.document.createElement('script');
    el.textContent = fs.readFileSync(path.join(RAW, file), 'utf8');
    dom.window.document.body.appendChild(el);
  }
  return dom.window;
}

const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

/**
 * 还原 ArkWeb `runJavaScript` 的返回值。
 *
 * 设备上 runJavaScript 会把脚本返回值**再做一次 JSON 序列化**：脚本返回字符串
 * `{"status":"ok"…}` 时宿主拿到的是 `"{\"status\":\"ok\"…}"`。jsdom 不会 ——
 * 不补这一层，自检就「比设备好」，设备上「多引号一层、JSON.parse 出字符串」的坑
 * 在自检里永远看不到（书源引擎就栽在这里，见 `docs/DEFECTS.md` D-007）。
 * 规则与 `core/source/SourceEngine.ets` 的 `unwrapJsonString` 一致。
 */
function unwrapJsonString(result) {
  if (result.length === 0 || result === 'null' || result === 'undefined') return '';
  try {
    const parsed = JSON.parse(result);
    if (typeof parsed === 'string') return parsed;
    if (parsed !== null && typeof parsed === 'object') return JSON.stringify(parsed);
    return result;
  } catch (e) {
    return result;
  }
}

async function fetchBody(spec) {
  const url = spec.url;
  if (/^data:/i.test(url)) {
    const comma = url.indexOf(',');
    const head = url.slice(0, comma);
    const payload = url.slice(comma + 1);
    if (/;base64/i.test(head)) return Buffer.from(payload, 'base64').toString('utf8');
    return decodeURIComponent(payload);
  }
  // 这一段必须和 entry/src/main/ets/core/book/BookHttp.ets 的 bookRequest 一致：
  //   Accept 默认 */*（不是音源的 application/json），POST 没写 Content-Type 时按表单发。
  // 两边不一致时，本脚本会「比设备好」，从而漏掉设备上的 0 条。
  const headers = Object.assign({ 'User-Agent': UA, Accept: '*/*' }, spec.headers || {});
  const init = { method: spec.method || 'GET', headers };
  if (init.method !== 'GET' && init.method !== 'HEAD') {
    const hasCt = Object.keys(headers).some((k) => k.toLowerCase() === 'content-type');
    if (!hasCt) { headers['Content-Type'] = 'application/x-www-form-urlencoded'; }
    if (spec.body) init.body = spec.body;
  }
  const resp = await fetch(url, init);
  return Buffer.from(await resp.arrayBuffer()).toString('utf8');
}

async function runJob(win, job, maxRounds = 220) {
  const netCache = {};
  const netFails = [];
  let netOk = 0;
  for (let round = 0; round < maxRounds; round++) {
    const res = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify(Object.assign({}, job, { netCache }))))));
    if (res.status !== 'net') return { res, rounds: round + 1, netOk, netFails };
    for (const spec of res.urls) {
      try {
        netCache[spec.key] = await fetchBody(spec);
        netOk++;
      } catch (e) {
        // 空串会让规则「算出空结果」而不是报错 —— 界面/自检上就表现为「没搜到」。
        // 所以这里必须把失败记下来，否则抓取失败会被误读成站点没有这个关键词。
        netCache[spec.key] = '';
        netFails.push(`${spec.method} ${spec.url}（${e.cause && e.cause.code || e.message}）`);
      }
    }
  }
  return { res: { status: 'error', message: `回放轮数超过上限（${maxRounds}）` }, rounds: maxRounds, netOk, netFails };
}

async function liveCase(win, imported, keyword) {
  console.log(`\n== 联网：导入后的源逐个搜索「${keyword}」==`);
  console.log('  说明：0 条且「请求成功 0 次」= 本机网络没抓到（不代表规则不行）；');
  console.log('        「状态 error」才是引擎/规则的问题，那种才算失败。\n');
  for (const { info } of imported) {
    if (!info.canSearch) {
      check(`${info.name} 可搜索`, false, 'canSearch=false');
      continue;
    }
    // 直接复用应用拼出来的作业：走的是 buildJob，不是手搓对象
    const job = JSON.parse(buildJob('search', info.raw, { key: keyword, page: 1 }, {}));
    const out = await runJob(win, job);
    const head = `${info.name.padEnd(14)} | ${String(out.res.status).padEnd(6)} | 请求成功 ${out.netOk} 次`;
    if (out.res.status === 'ok') {
      const hits = out.res.data.length;
      const verdict = hits > 0 ? `搜索结果 ${hits} 条` : (out.netOk === 0 ? '（本机没抓到，结论不成立）' : '站点没有该关键词');
      console.log(`  · ${head} | ${verdict}`);
      if (hits > 0) {
        console.log(`      首条：${out.res.data[0].name}`);
      }
      pass++;
    } else {
      console.log(`  ✗ ${head} | ${out.res.message}`);
      fail++;
    }
    for (const f of out.netFails.slice(0, 2)) {
      console.log(`      [网络失败] ${f}`);
    }
    if (out.netFails.length > 2) {
      console.log(`      [网络失败] 另有 ${out.netFails.length - 2} 个`);
    }
  }
}

// ------------------------------------------------------------ main

(async () => {
  const imported = offlineCases();
  guardFileImport();
  downloadCases();

  const args = process.argv.slice(2);
  if (args.includes('--live') && imported.length > 0) {
    const win = loadSandbox();
    if (win !== null) {
      const kw = args[args.indexOf('--live') + 1] || '诡秘之主';
      await liveCase(win, imported, kw);
    }
  }

  console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
  process.exit(fail > 0 ? 1 : 0);
})();
