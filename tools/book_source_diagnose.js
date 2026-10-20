/**
 * 听书书源「全链路」诊断（无设备）
 *
 * 与 `book_engine_selftest.js` 的区别：那个脚本验的是**规则求值**，喂的是已经
 * 解析好的书源对象，而且宿主网络这一层很简陋（没有 Cookie 罐、POST 不带
 * Content-Type）。结果就是「测试比设备好」或「测试比设备差」，两头都骗人：
 *
 *   - 书音FM 的搜索是 POST，站点按 Content-Type 认表单；测试不带这个头，站点
 *     回一张提示页 → 测试报「0 条」，其实设备上（`BookHttp.bookRequest` 会兜底
 *     表单头）是好的。
 *   - 275听书 的站点每个响应都 `Set-Cookie: PHPSESSID=...`，播放接口必须带这个
 *     cookie 才认；测试没有 Cookie 罐 → 测试报「解析不出音频」，其实设备上
 *     （`BookCookieJar`）是好的。
 *   - 反过来，设备上拿到的「音频地址」也可能只是一张 HTML 播放页 —— 旧的自检
 *     只看 `^https?://` + HEAD<400，播放页当然也是 200，于是「假通过」。
 *
 * 所以这个脚本把宿主侧**照设备的样子**实现一遍（Cookie 罐、重定向跟随、
 * POST 表单兜底、ArkWeb 的二次 JSON 序列化），再对**每一段**做严格判定：
 *
 *   search → bookInfo → toc → content
 *
 * 音频那步是重点：必须拿到「看起来就是媒体」的地址（后缀 / Content-Type），
 * 拿回 HTML 页面一律算失败 —— 这正是用户说的「别的书源有各种各样的问题」里
 * 最容易被测试放过的一类。
 *
 * 用法：
 *   node tools/book_source_diagnose.js                        # 全部书源，默认关键词
 *   node tools/book_source_diagnose.js --source 275 --keyword 盗墓笔记
 *   node tools/book_source_diagnose.js --keyword 凡人修仙传 --dump .probe/dl
 *   node tools/book_source_diagnose.js --offline              # 只跑夹具（不联网）
 *
 * 退出码：有书源「硬失败」（引擎/规则出错）时为 1；仅在「站点没有这本书 / 需要登录」
 * 这类外部原因时为 0（那是站点的事，不是代码坏了）。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const RAW = path.join(ROOT, 'entry/src/main/resources/rawfile');
const SOURCE_DIRS = [
  path.resolve(ROOT, '..', '听书的源'),
  'C:/Users/Lenovo/Downloads',
];
const JSDOM_PATH = path.resolve(ROOT, '..', '.probe', 'booktest', 'node_modules', 'jsdom');

let JSDOM = null;
try {
  JSDOM = require(JSDOM_PATH).JSDOM;
} catch (e) {
  console.error('缺少 jsdom（本脚本用它顶替 ArkWeb 沙箱）。先装一下：');
  console.error('  mkdir -p ../.probe/booktest && cd ../.probe/booktest');
  console.error('  npm init -y && npm install jsdom@24.1.3');
  process.exit(2);
}

const UA =
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

// ------------------------------------------------------------ 沙箱

function createSandbox() {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', {
    url: 'https://sandbox.local/',
    runScripts: 'dangerously',
  });
  const win = dom.window;
  for (const file of ['lx_utils.js', 'book_preload.js']) {
    const el = win.document.createElement('script');
    el.textContent = fs.readFileSync(path.join(RAW, file), 'utf8');
    win.document.body.appendChild(el);
  }
  return win;
}

/** 还原 ArkWeb `runJavaScript` 对返回值的二次 JSON 序列化（与 BookEngine.unwrapJsonString 一致） */
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

// ------------------------------------------------------------ 宿主网络（照 BookHttp + BookCookieJar）

/** 与 BookHttp.BookCookieJar 同语义：按 host 存，吸收 Set-Cookie，请求时补 Cookie 头 */
class CookieJar {
  constructor() { this.jars = {}; }
  hostOf(url) {
    const m = String(url).match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^/?#]+)/);
    return m ? m[1].toLowerCase() : '';
  }
  headerFor(url) {
    const jar = this.jars[this.hostOf(url)];
    if (!jar) return '';
    return Object.keys(jar).map((k) => `${k}=${jar[k]}`).join('; ');
  }
  absorb(url, resp) {
    const host = this.hostOf(url);
    if (!host) return;
    let list = [];
    try {
      if (typeof resp.headers.getSetCookie === 'function') list = resp.headers.getSetCookie();
    } catch (e) { /* ignore */ }
    if (list.length === 0) {
      const raw = resp.headers.get('set-cookie');
      if (raw) list = [raw];
    }
    for (const line of list) {
      const pair = String(line).split(';')[0].trim();
      const eq = pair.indexOf('=');
      if (eq <= 0) continue;
      this.jars[host] = this.jars[host] || {};
      this.jars[host][pair.slice(0, eq).trim()] = pair.slice(eq + 1).trim();
    }
  }
}

function decodeDataUrl(url) {
  const comma = url.indexOf(',');
  if (comma < 0) return '';
  const head = url.slice(0, comma);
  const payload = url.slice(comma + 1);
  if (/;base64/i.test(head)) return Buffer.from(payload, 'base64').toString('utf8');
  try { return decodeURIComponent(payload); } catch (e) { return payload; }
}

function headerOf(headers, name) {
  const lower = name.toLowerCase();
  for (const k of Object.keys(headers)) if (k.toLowerCase() === lower) return headers[k];
  return '';
}

async function fetchBody(spec, jar, log) {
  const url = spec.url;
  if (/^data:/i.test(url)) return { body: decodeDataUrl(url), headers: {} };

  const headers = Object.assign({ 'User-Agent': UA, Accept: '*/*' }, spec.headers || {});
  if (headerOf(headers, 'accept').length === 0) headers['Accept'] = '*/*';
  const method = (spec.method || 'GET').toUpperCase();
  if (method === 'POST' && headerOf(headers, 'content-type').length === 0) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  const cookie = jar.headerFor(url);
  if (cookie.length > 0 && headerOf(headers, 'cookie').length === 0) headers['Cookie'] = cookie;

  const init = { method, headers, redirect: 'follow', signal: AbortSignal.timeout(25000) };
  if (method !== 'GET' && method !== 'HEAD' && spec.body) init.body = spec.body;

  const resp = await fetch(url, init);
  jar.absorb(url, resp);
  const buf = Buffer.from(await resp.arrayBuffer());
  const ctype = resp.headers.get('content-type') || '';
  if (log) log(`[net] ${method} ${url} -> ${resp.status} ${buf.length}B ${ctype}`);
  const headerRecord = {};
  try {
    for (const [k, v] of resp.headers.entries()) headerRecord[k] = v;
  } catch (e) { /* ignore */ }
  let body;
  if (/gbk|gb2312/i.test(ctype)) {
    try { body = new TextDecoder('gbk').decode(buf); } catch (e) { body = buf.toString('utf8'); }
  } else {
    body = buf.toString('utf8');
  }
  return { body, headers: headerRecord };
}

/** 与 BookEngine.run 同构的回放循环 */
async function runJob(win, job, jar, log, maxRounds = 220) {
  const netCache = {};
  const netHeaders = {};
  const netFails = [];
  for (let round = 0; round < maxRounds; round++) {
    const payload = Object.assign({}, job, { netCache, netHeaders });
    const res = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify(payload)))));
    if (log && res.logs && res.logs.length) for (const line of res.logs) log(`[sandbox] ${line}`);
    if (res.status === 'net') {
      for (const spec of res.urls) {
        try {
          const got = await fetchBody(spec, jar, log);
          netCache[spec.key] = got.body;
          netHeaders[spec.key] = JSON.stringify(got.headers);
        } catch (e) {
          netCache[spec.key] = '';
          netHeaders[spec.key] = '{}';
          netFails.push(`${spec.method} ${spec.url}（${(e.cause && e.cause.code) || e.message}）`);
        }
      }
      continue;
    }
    return { res, rounds: round + 1, netFails };
  }
  return { res: { status: 'error', message: `回放轮数超过上限（${maxRounds}）` }, rounds: maxRounds, netFails };
}

// ------------------------------------------------------------ 严格判定

const AUDIO_EXT = /\.(mp3|m4a|aac|wav|ogg|oga|flac|opus|m3u8|m4b|mp4|weba)(\?|#|$)/i;
const PAGE_EXT = /\.(html?|aspx?|jsp)(\?|#|$)/i;

/**
 * 音频地址必须「看起来就是媒体」。
 *
 * 后缀命中就放行；否则 HEAD 一次（跟随重定向）看 Content-Type：
 * 很多站给的是 `api.php?...&sign=...` 这种代理地址，它 302 到真媒体 —— 不能因为
 * 结尾是 `.php` 就判成网页。反过来，返回 `text/html` 的一定是播放页，判失败
 * （这正是「假通过」最多的一类）。
 */
async function checkAudio(url, headers) {
  if (!/^https?:/i.test(String(url || ''))) return { ok: false, why: '不是 http(s) 地址' };
  if (AUDIO_EXT.test(url)) return { ok: true, why: '后缀是音频' };
  try {
    const resp = await fetch(url, {
      method: 'HEAD',
      headers: Object.assign({ 'User-Agent': UA }, headers || {}),
      redirect: 'follow',
      signal: AbortSignal.timeout(25000),
    });
    const ctype = (resp.headers.get('content-type') || '').toLowerCase();
    if (/^audio\//.test(ctype) || /mpegurl|octet-stream/.test(ctype)) return { ok: true, why: `Content-Type=${ctype}` };
    if (/text\/html/.test(ctype)) return { ok: false, why: `Content-Type=${ctype}（是网页，不是音频）` };
    if (PAGE_EXT.test(url) && resp.status < 400 && ctype === '') {
      return { ok: false, why: '地址是网页且没有音频 Content-Type' };
    }
    return { ok: resp.status < 400, why: `Content-Type=${ctype || '?'} HTTP ${resp.status}` };
  } catch (e) {
    return { ok: false, why: `HEAD 失败：${e.message}` };
  }
}

function isHttp(u) { return /^https?:\/\//i.test(String(u || '')); }

/** 书源的 `header` 有的写成 JSON 字符串，有的直接是对象；两种都要吃下来 */
function parseHeaders(header) {
  if (!header) return {};
  if (typeof header === 'object') return header;
  try { return JSON.parse(header); } catch (e) { return {}; }
}

// ------------------------------------------------------------ 单个书源全链路

async function diagnoseSource(win, source, keyword, dumpDir, log, bookUrl) {
  const jar = new CookieJar();
  const stages = [];
  const dump = (name, text) => {
    if (!dumpDir) return;
    try { fs.mkdirSync(dumpDir, { recursive: true }); fs.writeFileSync(path.join(dumpDir, name), String(text)); } catch (e) { /* ignore */ }
  };
  const rec = (stage, ok, why, extra) => { stages.push({ stage, ok, why, extra: extra || '' }); };
  // 请求失败要说清楚：「0 条」既可能是站点改版/没有这本书，也可能是 DNS/连接挂了。
  // 不区分就会把「站点已经死了」误判成「规则坏了」。
  const netNote = (r) => (r && r.netFails && r.netFails.length > 0)
    ? `（${r.netFails.length} 次请求失败：${r.netFails[0]}）` : '';

  let out;
  let hit;
  if (bookUrl) {
    // 直接给一本书的地址，跳过搜索 —— 站点对搜索接口风控（bilibili 会 412）时，
    // 还能把「详情 / 目录 / 音频」这几段单独验掉。
    rec('搜索', true, '（已跳过，用 --book 指定了书）', bookUrl);
    hit = { name: '', author: '', bookUrl };
  } else {
    // 1) 搜索
    out = await runJob(win, { action: 'search', source, key: keyword, page: 1 }, jar, log);
    if (out.res.status !== 'ok') {
      rec('搜索', false, (out.res.message || out.res.status) + netNote(out));
      return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };
    }
    const hits = out.res.data || [];
    dump('search.json', JSON.stringify(hits, null, 1));
    const named = hits.filter((h) => String(h.name || '').trim().length > 0);
    const junk = hits.length - named.length;
    if (hits.length === 0) {
      const note = netNote(out);
      rec('搜索', false, note.length > 0 ? `0 条，且请求失败${note}` : '0 条（站点可能确实没有这个关键词，或站点改版/需登录）');
      // 请求全挂时是「站点不可达」，不是规则问题
      return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: out.netFails.length === 0 };
    }
    rec('搜索', true, `${hits.length} 条${junk > 0 ? `，其中 ${junk} 条没有书名` : ''}${netNote(out)}`, named[0] ? `${named[0].name} / ${named[0].author || '—'}` : '');
    hit = named[0] || hits[0];
    if (junk > 0) {
      rec('搜索质量', false, `bookList 选出 ${junk} 条空书名的条目（多半是选择器把「热门/导航」链接也框进来了）`);
    }
  }

  // 2) 详情
  out = await runJob(win, { action: 'bookInfo', source, book: { bookUrl: hit.bookUrl, name: hit.name } }, jar, log);
  if (out.res.status !== 'ok') {
    rec('详情', false, (out.res.message || out.res.status) + netNote(out));
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };
  }
  const info = out.res.data || {};
  dump('bookinfo.json', JSON.stringify(info, null, 1));
  const tocUrl = String(info.tocUrl || '');
  rec('详情', isHttp(tocUrl), isHttp(tocUrl) ? `${info.name || hit.name || '（无名）'}` : `没算出 tocUrl（得到「${tocUrl}」）${netNote(out)}`, `tocUrl=${tocUrl}`);
  if (!isHttp(tocUrl)) return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: out.netFails.length === 0 };

  // 3) 目录
  const book = Object.assign({}, hit, info, { bookUrl: hit.bookUrl });
  out = await runJob(win, { action: 'toc', source, book, url: tocUrl }, jar, log);
  if (out.res.status !== 'ok') {
    rec('目录', false, (out.res.message || out.res.status) + netNote(out));
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };
  }
  const chapters = out.res.data || [];
  dump('toc.json', JSON.stringify(chapters.slice(0, 50), null, 1));
  const chNamed = chapters.filter((c) => String(c.name || '').trim().length > 0 && isHttp(c.url));
  if (chapters.length === 0) {
    rec('目录', false, '0 章（规则没取到章节，或 tocUrl 算错了）' + netNote(out));
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: out.netFails.length === 0 };
  }
  rec('目录', true, `${chapters.length} 章`, chNamed[0] ? `${chNamed[0].name} -> ${chNamed[0].url}` : '');
  if (chNamed.length === 0) {
    rec('目录质量', false, '所有章节都没有名字或不是合法地址');
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };
  }
  // 4) 音频
  // 第一章常常是「预告 / 极速试听」这种没有音频的条目（275听书就是这么埋人的），
  // 所以第一章失败时，再用中间一章复测一次；任一章拿到真媒体就算通过。
  const tries = [chNamed[0]];
  const mid = chNamed[Math.floor(chNamed.length / 2)];
  if (mid && mid.url !== chNamed[0].url) tries.push(mid);

  let audio = {};
  let verdict = { ok: false, why: '没有可测的章节' };
  let lastExtra = '';
  for (let t = 0; t < tries.length; t++) {
    out = await runJob(win, { action: 'content', source, book, chapter: tries[t] }, jar, log);
    if (out.res.status !== 'ok') { verdict = { ok: false, why: (out.res.message || out.res.status) + netNote(out) }; break; }
    audio = out.res.data || {};
    lastExtra = `第 ${t + 1} 次尝试（${tries[t].name}）: from=${audio.from || '?'} url=${audio.url || '（空）'}${netNote(out)}`;
    if (String(audio.url || '').length > 0) {
      verdict = await checkAudio(audio.url, parseHeaders(source.header));
      lastExtra = `第 ${t + 1} 次尝试（${tries[t].name}）: from=${audio.from || '?'} url=${audio.url}`;
      if (verdict.ok) break;
    } else {
      verdict = { ok: false, why: '没解析出地址' };
    }
  }

  if (String(audio.url || '').length === 0) {
    // 需要登录的源，缺音频是「外部原因」；不需要登录却缺，就是规则坏了，要修
    const gated = !!source.loginUrl;
    const failed = out && out.netFails && out.netFails.length > 0;
    rec('音频', false, (gated ? '没解析出地址（该书源需要登录）' : '没解析出地址') + netNote(out), lastExtra);
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: !gated && !failed };
  }
  rec('音频', verdict.ok, verdict.why, lastExtra);
  return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: !verdict.ok };
}

// ------------------------------------------------------------ 发现（explore）链路

/**
 * ruleExplore 空不空 —— 空了发现页要靠**退回搜索规则**（阅读 BookList.kt 的行为）
 *
 * 导出的书源里这很常见：有的写成空对象，有的干脆是空数组（`"ruleExplore": []`）。
 * 不退回就是「分类列得出来、点进去一本没有」，还不报错。
 */
function exploreRuleNote(source) {
  const ex = source.ruleExplore;
  const list = ex && !Array.isArray(ex) ? ex.bookList : null;
  const usable = list !== null && list !== undefined && String(list).trim().length > 0;
  if (usable) return '';
  const hasSearch = source.ruleSearch && String(source.ruleSearch.bookList || '').trim().length > 0;
  return hasSearch ? '（ruleExplore 为空，已回退搜索规则）' : '（ruleExplore 与 ruleSearch 都为空）';
}

/**
 * 发现链路诊断：exploreUrl → 分类表 → 分类列表 → 翻页
 *
 * 与搜索是两条路（exploreUrl + ruleExplore，见 docs/BOOK_SOURCE_ENGINE.md），所以单独一段。
 * 这里验的三件事都是真实书源踩过的坑：
 *   1. 分类表里**空地址的条目是分组标题**，不该当成能点的分类（听友FM、「小说，漫画，听书」）；
 *   2. `ruleExplore` 为空要**退回搜索规则**（幻听网、懒人听书这一批都是这样）；
 *   3. 地址里的可选段 `<,_{{page}}>` 要按页解析（幻听网、恋听、56听书…第一页才不是 404）。
 */
async function diagnoseExplore(win, source, log) {
  const jar = new CookieJar();
  const stages = [];
  const rec = (stage, ok, why, extra) => stages.push({ stage, ok, why, extra: extra || '' });

  const listRes = await runJob(win, { action: 'exploreList', source }, jar, log);
  if (listRes.res.status !== 'ok') {
    rec('分类表', false, listRes.res.message || listRes.res.status);
    return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };
  }
  const all = listRes.res.data || [];
  // 与 BookEngine.exploreCategories 同一口径：空地址的是分组标题，扔掉
  const cats = all.filter((c) =>
    String(c.title || '').trim().length > 0 && String(c.url || '').trim().length > 0);
  const headers = all.length - cats.length;
  rec('分类表', cats.length > 0,
    `${cats.length} 个分类${headers > 0 ? `（另有 ${headers} 条是空地址的分组标题，已跳过）` : ''}${exploreRuleNote(source)}`,
    cats.length > 0 ? `${cats[0].title} -> ${cats[0].url}` : '');
  if (cats.length === 0) return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: true };

  // 前两个分类各拉第 1 页
  for (let i = 0; i < Math.min(2, cats.length); i++) {
    const cat = cats[i];
    const out = await runJob(win, { action: 'explore', source, exploreUrl: cat.url, key: '', page: 1 }, jar, log);
    const note = (out.netFails && out.netFails.length > 0) ? `（${out.netFails.length} 次请求失败：${out.netFails[0]}）` : '';
    if (out.res.status !== 'ok') {
      rec(`分类第 ${i + 1} 页「${cat.title}」`, false, (out.res.message || out.res.status) + note);
      continue;
    }
    const hits = out.res.data || [];
    const good = hits.filter((h) => String(h.name || '').trim().length > 0 && isHttp(h.bookUrl));
    rec(`分类「${cat.title}」第 1 页`, good.length > 0,
      `${hits.length} 条${good.length !== hits.length ? `（其中 ${hits.length - good.length} 条缺书名/地址）` : ''}${note}`,
      good[0] ? `${good[0].name} -> ${good[0].bookUrl}` : '');
  }

  // 翻页：地址带 {{page}} 的才试第 2 页，第 2 页必须给出跟第 1 页不一样的书才算通
  const paged = cats.find((c) => String(c.url).indexOf('{{page}}') >= 0);
  if (paged) {
    const p1 = await runJob(win, { action: 'explore', source, exploreUrl: paged.url, key: '', page: 1 }, jar, log);
    const p2 = await runJob(win, { action: 'explore', source, exploreUrl: paged.url, key: '', page: 2 }, jar, log);
    const a = (p1.res.data || []).map((h) => String(h.bookUrl)).join('|');
    const b = (p2.res.data || []).map((h) => String(h.bookUrl)).join('|');
    const n2 = (p2.res.data || []).length;
    rec('翻页第 2 页', n2 > 0 && b !== a,
      n2 === 0 ? `0 条${(p2.netFails && p2.netFails.length > 0) ? `（${p2.netFails[0]}）` : ''}`
        : (b === a ? '与第 1 页完全一样（{{page}} 没生效）' : `${n2} 条`),
      `「${paged.title}」`);
  }

  return { name: source.bookSourceName, url: source.bookSourceUrl, stages, hardFail: stages.some((s) => !s.ok) };
}

// ------------------------------------------------------------ 离线夹具

async function offlineCases(win) {
  console.log('\n== 离线夹具：严格判定本身要能被验证 ==');
  let pass = 0, fail = 0;
  const check = (name, ok, detail) => {
    if (ok) { pass++; console.log(`  ✓ ${name}`); }
    else { fail++; console.log(`  ✗ ${name}${detail ? '  —— ' + detail : ''}`); }
  };

  // 媒体判定：HTML 页面必须被判失败
  check('HTML 播放页不算音频', (await checkAudio('https://x.test/play/1-2.html', {})).ok === false);
  check('mp3 直链算音频', (await checkAudio('https://x.test/a/1.mp3', {})).ok === true);
  check('m4a 直链算音频', (await checkAudio('https://x.test/a/1.m4a?sign=abc', {})).ok === true);
  check('空地址不算音频', (await checkAudio('', {})).ok === false);

  // 回放循环 + ArkWeb 二次序列化
  const fixture = `<html><body><ul class="list"><li><a href="/b/1.html" title="书一">书一</a></li></ul></body></html>`;
  const src = {
    bookSourceName: '夹具', bookSourceUrl: 'https://fix.test',
    searchUrl: 'https://fix.test/search?q={{key}}',
    ruleSearch: { bookList: 'ul.list li', name: 'a@title', bookUrl: 'a@href' },
  };
  const job = { action: 'search', source: src, key: 'x', page: 1 };
  const netCache = {};
  // 第一轮应当报告缺失
  const r1 = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify(Object.assign({}, job, { netCache }))))));
  check('第一轮报告缺网络', r1.status === 'net' && (r1.urls || []).length === 1, JSON.stringify(r1).slice(0, 160));
  netCache[r1.urls[0].key] = fixture;
  const r2 = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify(Object.assign({}, job, { netCache }))))));
  check('补上缓存后搜索成功', r2.status === 'ok' && r2.data.length === 1 && r2.data[0].bookUrl === 'https://fix.test/b/1.html', JSON.stringify(r2).slice(0, 160));

  // 引擎回归守卫 —— 这三条都是「规则写得对、引擎没接上」的坑，修过就别再退回去
  const bookInfoWith = (rule, bookUrl) => JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'bookInfo',
    source: { bookSourceName: 't', bookSourceUrl: 'https://x.test', ruleBookInfo: rule },
    book: { bookUrl: bookUrl || 'data:text/html,<h1>hi</h1>' },
    netCache: {},
  })))));

  // java.md5Encode：曾经恒为空串（PURE.md5 不存在），书音FM 的签名 token 因此全错
  const md5res = bookInfoWith({ name: "@js: java.md5Encode('abc')" });
  check('java.md5Encode 返回正确摘要', md5res.data && md5res.data.name === '900150983cd24fb0d6963f7d28e17f72', JSON.stringify(md5res.data && md5res.data.name));
  const md5_16 = bookInfoWith({ name: "@js: java.md5Encode16('abc')" });
  check('java.md5Encode16 返回 16 位', md5_16.data && md5_16.data.name === '3cd24fb0d6963f7d', JSON.stringify(md5_16.data && md5_16.data.name));

  // ruleBookInfo.init 写成 `@js:`：曾经只认 `<js>`，于是规则被原样当地址拼成 404
  const initJs = bookInfoWith({ init: "@js: 'data:text/html,<h1>hi</h1>'", name: 'h1@text' }, 'https://x.test/book/1');
  check('init 支持 @js: 写法', initJs.data && initJs.data.name === 'hi', JSON.stringify(initJs.data && initJs.data.name));

  // java.ajax(url, headers)：第二个参数里的请求头曾经被丢掉
  const ajaxHeader = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'content',
    source: { bookSourceName: 't', bookSourceUrl: 'https://x.test', ruleContent: { content: "@js: java.ajax('https://x.test/a', '{\"X-Test\":\"1\"}')" } },
    book: {}, chapter: { url: 'data:text/html,x' }, netCache: {},
  })))));
  check('java.ajax 带上了第二个参数里的请求头',
    ajaxHeader.status === 'net' && ajaxHeader.urls[0].headers['X-Test'] === '1',
    JSON.stringify(ajaxHeader.urls && ajaxHeader.urls[0] && ajaxHeader.urls[0].headers));

  // 登录动作：infoMap 绑定、putLoginInfo 回写、toast、startBrowser
  const runLogin = (rule, login) => JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'login',
    source: { bookSourceName: 't', bookSourceUrl: 'https://x.test' },
    login: login || {},
    rule: rule,
    netCache: {},
  })))));

  const lr = runLogin('@js: source.putLoginInfo(infoMap); java.toast("已保存"); "done"', { 'Cookie': 'abc' });
  check('login 动作：跑规则并带回登录信息 + toast',
    lr.status === 'ok' && lr.data.result === 'done' && lr.data.login['Cookie'] === 'abc' && lr.data.toasts[0] === '已保存',
    JSON.stringify(lr.data));

  const lr2 = runLogin('@js: source.putLoginInfo({"X":"1"}); infoMap.X', {});
  check('login 动作：putLoginInfo 写回的新键能取到',
    lr2.status === 'ok' && lr2.data.result === '1' && lr2.data.login['X'] === '1', JSON.stringify(lr2.data));

  const lr3 = runLogin('@js: startBrowser("https://x.test/login")', {});
  check('login 动作：startBrowser 的地址带回宿主',
    lr3.status === 'ok' && lr3.data.openUrl === 'https://x.test/login', JSON.stringify(lr3.data));

  // 阅读 API 兼容性（这一批旧书源用到的东西）
  const runContent = (rule, sourceExtra) => JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'content',
    source: Object.assign({ bookSourceName: 't', bookSourceUrl: 'https://x.test', ruleContent: { content: rule } }, sourceExtra || {}),
    book: {}, chapter: { url: 'data:text/html,x' }, netCache: {}, netHeaders: {},
  })))));

  const postOut = runContent("@js: java.post('https://x.test/a', 'b=1', '{\"X-Y\":\"2\"}').body()");
  check('java.post 按 POST + body + 头发出请求',
    postOut.status === 'net' && postOut.urls[0].method === 'POST' && postOut.urls[0].body === 'b=1'
      && postOut.urls[0].headers['X-Y'] === '2',
    JSON.stringify(postOut.urls && postOut.urls[0]));

  const looseOut = runContent("@js: java.ajax(\"https://x.test/b,{'method':'POST','body':'c=1'}\")");
  check('选项 JSON 允许单引号（宽松解析）',
    looseOut.status === 'net' && looseOut.urls[0].url === 'https://x.test/b'
      && looseOut.urls[0].method === 'POST' && looseOut.urls[0].body === 'c=1',
    JSON.stringify(looseOut.urls && looseOut.urls[0]));

  const putOut = bookInfoWith({ name: "@js: source.put('k', 'v'), source.get('k')" }, 'data:text/html,x');
  check('source.put / source.get 可用', putOut.data && putOut.data.name === 'v', JSON.stringify(putOut.data && putOut.data.name));

  const srcProp = bookInfoWith({ name: "@js: typeof source.bookSourceUrl + ':' + source.bookSourceUrl" }, 'data:text/html,x');
  check('source.bookSourceUrl 是字符串属性（不是函数）',
    srcProp.data && srcProp.data.name === 'string:https://x.test', JSON.stringify(srcProp.data && srcProp.data.name));

  const hexOut = bookInfoWith({ name: "@js: java.hexDecodeToString('e4bda0')" }, 'data:text/html,x');
  check('java.hexDecodeToString 解码 UTF-8', hexOut.data && hexOut.data.name === '你', JSON.stringify(hexOut.data && hexOut.data.name));

  const argsOut = bookInfoWith({ name: "@js: getArguments('server=http://s&x=1', 'server')" }, 'data:text/html,x');
  check('getArguments 从 key=value 串取值', argsOut.data && argsOut.data.name === 'http://s', JSON.stringify(argsOut.data && argsOut.data.name));

  // 网页登录抓来的 Cookie 要能被规则读到（喜马拉雅 / 哔哩哔哩的 loginCheckJs 都靠它）
  const cookieJob = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'bookInfo',
    source: {
      bookSourceName: 't', bookSourceUrl: 'https://x.test',
      ruleBookInfo: { name: "@js: java.getCookie('d','SESSDATA') + '|' + cookie.getCookie('d','u') + '|' + source.getLoginInfoMap()['Cookie']" },
    },
    book: { bookUrl: 'data:text/html,x' },
    login: { 'Cookie': 'SESSDATA=abc; u=1' },
    netCache: {}, netHeaders: {},
  })))));
  check('网页登录抓来的 Cookie 能被 java.getCookie / cookie.getCookie / infoMap 读到',
    cookieJob.data && cookieJob.data.name === 'abc|1|SESSDATA=abc; u=1', JSON.stringify(cookieJob.data && cookieJob.data.name));

  // ---------------------------------------------------------- 发现（explore）相关
  // 见 docs/BOOK_SOURCE_ENGINE.md §5.4 / §5.5：这几条都是真实书源踩过的坑

  const exploreListOf = (exploreUrl) => JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
    action: 'exploreList',
    source: { bookSourceName: 't', bookSourceUrl: 'https://x.test', exploreUrl },
    netCache: {}, netHeaders: {},
  })))));

  // 「标题::地址」的分隔符 `&&` 与换行都算（56听书的分类表整条都挤在一行里、用 && 串起来）
  const amp = exploreListOf('玄幻::http://a/1.html&&武侠::http://a/2.html');
  check('分类表认 `&&` 分隔', amp.status === 'ok' && amp.data.length === 2 && amp.data[1].title === '武侠',
    JSON.stringify(amp.data));
  const nl = exploreListOf('玄幻::http://a/1.html\n武侠::http://a/2.html');
  check('分类表认换行分隔', nl.status === 'ok' && nl.data.length === 2, JSON.stringify(nl.data));
  // url 为空的是分组标题（听友FM 的「有声小说 / 评书」那两条），不是能点的分类
  const hdr = exploreListOf('[{"title":"有声小说","url":""},{"title":"玄幻","url":"http://a/1.html"}]');
  check('分类表跳过空地址的分组标题', hdr.status === 'ok' && hdr.data.length === 1 && hdr.data[0].title === '玄幻',
    JSON.stringify(hdr.data));

  /**
   * 跑一次 explore，把缺失的地址补成同一个夹具页 —— 顺便把「实际请求的地址」带回来
   * （可选段那两条要断言地址本身，光看结果看不出来）
   */
  const exploreWithFixture = (source, exploreUrl, page, html, cache) => {
    const run = () => JSON.parse(unwrapJsonString(JSON.stringify(win.__book_run__(JSON.stringify({
      action: 'explore', source, exploreUrl, key: '', page, netCache: cache, netHeaders: {},
    })))));
    let r = run();
    const asked = (r.status === 'net' && r.urls) ? r.urls.map((u) => u.url) : [];
    if (r.status === 'net') {
      for (const u of r.urls) { cache[u.key] = html; }
      r = run();
    }
    return { res: r, asked };
  };

  const listHtml = '<html><body><ul class="clist"><li><a href="/b/9.html" title="书九"></a></li></ul></body></html>';

  // ruleExplore 空（空对象或空数组都算）要退回搜索规则 —— 阅读 BookList.kt 就是这么做的。
  // 不退回就是「分类列得出来、点进去一本没有」，还不报错。
  const fallbackSrc = {
    bookSourceName: 't', bookSourceUrl: 'https://x.test',
    exploreUrl: '玄幻::https://x.test/list/1.html',
    ruleExplore: [],
    ruleSearch: { bookList: 'ul.clist li', name: 'a@title', bookUrl: 'a@href' },
  };
  const fb = exploreWithFixture(fallbackSrc, 'https://x.test/list/1.html', 1, listHtml, {});
  check('ruleExplore 为空时回退搜索规则',
    fb.res.status === 'ok' && fb.res.data.length === 1 && fb.res.data[0].bookUrl === 'https://x.test/b/9.html',
    JSON.stringify(fb.res).slice(0, 200));

  // 地址可选段 `<,_{{page}}>`：第一页没有这一段，第二页起才有（幻听网、恋听、56听书都用它）。
  // 以前 `{{page}}` 照样被替换，地址里带着 `<,1>` 去请求 —— 第一页就 404。
  const optSrc = {
    bookSourceName: 't', bookSourceUrl: 'https://x.test',
    exploreUrl: '玄幻::/booklist/1<,_{{page}}>.html',
    ruleSearch: { bookList: 'ul.clist li', name: 'a@title', bookUrl: 'a@href' },
  };
  const optCache = {};
  const o1 = exploreWithFixture(optSrc, '/booklist/1<,_{{page}}>.html', 1, listHtml, optCache);
  check('可选段：第 1 页地址里没有这一段',
    o1.asked.length === 1 && o1.asked[0] === 'https://x.test/booklist/1.html', JSON.stringify(o1.asked));
  const o2 = exploreWithFixture(optSrc, '/booklist/1<,_{{page}}>.html', 2, listHtml, optCache);
  check('可选段：第 2 页带上 _2',
    o2.asked.length === 1 && o2.asked[0] === 'https://x.test/booklist/1_2.html', JSON.stringify(o2.asked));

  // Rhino 的 Java 互操作：听友FM 的 XChaCha20Poly1305、懒人听书本地源的 android.util.Base64 靠它。
  // 密文用 RFC 8439 §2.8.2 的官方向量 —— 手写的密码学最容易悄悄坏掉，必须有守卫。
  const aead = {
    key: '808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f',
    nonce: '070000004041424344454647',
    aad: '50515253c0c1c2c3c4c5c6c7',
    ct: 'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6'
      + '3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3'
      + '692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc'
      + '3ff4def08e4b7a9de576d26586cec64b6116',
    tag: '1ae10b594f09e26a7e902ecbd0600691',
  };
  const aeadJs = `@js:(function(){
    var h=function(s){var o=[];for(var i=0;i<s.length;i+=2){o.push(parseInt(s.substr(i,2),16));}return new Uint8Array(o);};
    var c=Packages.javax.crypto.Cipher.getInstance('ChaCha20-Poly1305');
    c.init(javax.crypto.Cipher.DECRYPT_MODE,
      new Packages.javax.crypto.spec.SecretKeySpec(h('${aead.key}'),'ChaCha20'),
      new Packages.javax.crypto.spec.GCMParameterSpec(128,h('${aead.nonce}')));
    c.updateAAD(h('${aead.aad}'));
    return new Packages.java.lang.String(c.doFinal(h('${aead.ct + aead.tag}')),'UTF-8');
  })()`;
  const aeadOut = bookInfoWith({ name: aeadJs }, 'data:text/html,x');
  const aeadText = String((aeadOut.data && aeadOut.data.name) || '');
  check('Java 互操作：ChaCha20-Poly1305 过 RFC 8439 §2.8.2 向量',
    aeadText.startsWith("Ladies and Gentlemen of the class of '99"), JSON.stringify(aeadText.slice(0, 60)));

  // 懒人听书本地源要的是 Android 的 Base64（flags 2 = 不折行）
  const b64Out = bookInfoWith({ name: "@js: Packages.android.util.Base64.encodeToString(new Uint8Array([228,189,160]), 2)" }, 'data:text/html,x');
  check('Java 互操作：android.util.Base64 不折行', String((b64Out.data && b64Out.data.name) || '') === '5L2g',
    JSON.stringify(b64Out.data && b64Out.data.name));

  console.log(`\n离线结果：${pass} 通过 / ${fail} 失败`);
  return fail;
}

// ------------------------------------------------------------ 入口

function loadSources(filter, fileFilter, nameFilter) {
  const out = [];
  const seen = new Set();
  for (const dir of SOURCE_DIRS) {
    let files = [];
    try { files = fs.readdirSync(dir).filter((f) => f.endsWith('.json')); } catch (e) { continue; }
    for (const f of files) {
      if (filter && !f.includes(filter)) continue;
      if (fileFilter && !f.includes(fileFilter)) continue;
      const full = path.join(dir, f);
      let parsed;
      try {
        parsed = JSON.parse(fs.readFileSync(full, 'utf8'));
      } catch (e) { continue; }
      // 一个文件里可能是「单源」，也可能是几十个源的合集 —— 合集要把每一条都测到
      const list = Array.isArray(parsed) ? parsed : [parsed];
      for (const source of list) {
        if (!source || !source.bookSourceName) continue;
        if (nameFilter && !String(source.bookSourceName).includes(nameFilter)) continue;
        const key = source.bookSourceName + '|' + source.bookSourceUrl;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ file: full, source });
      }
    }
  }
  return out;
}

(async () => {
  const args = process.argv.slice(2);
  const opt = (name, def) => {
    const i = args.indexOf(name);
    return i >= 0 && args[i + 1] ? args[i + 1] : def;
  };
  const win = createSandbox();
  const ping = JSON.parse(unwrapJsonString(JSON.stringify(win.__book_ping__())));
  console.log('沙箱：', JSON.stringify(ping));

  let failed = 0;
  if (args.includes('--offline')) {
    failed += await offlineCases(win);
    console.log(`\n结果：${failed === 0 ? '全部通过' : failed + ' 项失败'}`);
    process.exit(failed > 0 ? 1 : 0);
  }

  const filter = opt('--source', '');
  const keyword = opt('--keyword', '盗墓笔记');
  const bookUrl = opt('--book', '');
  const fileFilter = opt('--file', '');
  const nameFilter = opt('--name', '');
  const dumpDir = opt('--dump', path.resolve(ROOT, '..', '.probe', 'bookdiag'));

  const sources = loadSources(filter, fileFilter, nameFilter);
  if (sources.length === 0) {
    console.error(`没找到书源（过滤「${filter}」）。查找目录：\n  ${SOURCE_DIRS.join('\n  ')}`);
    process.exit(2);
  }

  // 发现（explore）单独一条链路，按 --explore 走
  if (args.includes('--explore')) {
    const withExplore = sources.filter(({ source }) => String(source.exploreUrl || '').trim().length > 0);
    console.log(`\n== 发现（explore）诊断：${sources.length} 个源里有 ${withExplore.length} 个带 exploreUrl ==`);
    let badExp = 0;
    for (const { file, source } of withExplore) {
      console.log(`\n================ ${source.bookSourceName} 发现 ================`);
      console.log(`  文件：${file}\n  站址：${source.bookSourceUrl}`);
      const logExp = process.env.BOOK_DEBUG ? (l) => console.log('  ' + l) : null;
      let r;
      try {
        r = await Promise.race([
          diagnoseExplore(win, source, logExp),
          new Promise((resolve) => setTimeout(() => resolve({
            name: source.bookSourceName,
            stages: [{ stage: '超时', ok: false, why: '单个书源超过 90 秒还没跑完', extra: '' }],
            hardFail: true,
          }), 150000)),
        ]);
      } catch (e) {
        r = { name: source.bookSourceName, stages: [], hardFail: true, crash: (e && e.stack) ? e.stack : String(e) };
      }
      for (const s of r.stages) {
        console.log(`  ${s.ok ? '✓' : '✗'} ${s.stage}：${s.why}${s.extra ? '   [' + s.extra + ']' : ''}`);
      }
      if (r.crash) console.log(`  ✗ 脚本抛错：${r.crash}`);
      if (r.hardFail) badExp++;
    }
    console.log(`\n发现链路：${withExplore.length} 个源，硬失败 ${badExp} 个。`);
    process.exit(badExp > 0 ? 1 : 0);
  }

  const quiet = args.includes('--summary');
  const results = [];
  for (const { file, source } of sources) {
    if (!quiet) {
      console.log(`\n================ ${source.bookSourceName}  「${keyword}」 ================`);
      console.log(`  文件：${file}`);
      console.log(`  站址：${source.bookSourceUrl}${source.loginUrl ? '  [需要登录]' : ''}`);
    }
    if (process.env.BOOK_DEBUG) console.log('  （BOOK_DEBUG：打印每一次网络请求）');
    const log = process.env.BOOK_DEBUG ? (l) => console.log('  ' + l) : null;
    const sub = path.join(dumpDir, source.bookSourceName.replace(/[\\/:*?"<>|]/g, '_'));
    let r;
    try {
      r = await Promise.race([
        diagnoseSource(win, source, keyword, sub, log, bookUrl),
        new Promise((resolve) => setTimeout(() => resolve({
          name: source.bookSourceName,
          url: source.bookSourceUrl,
          stages: [{ stage: '超时', ok: false, why: '单个书源超过 90 秒还没跑完', extra: '' }],
          hardFail: true,
        }), 150000)),
      ]);
    } catch (e) {
      r = { name: source.bookSourceName, url: source.bookSourceUrl, stages: [], hardFail: true, crash: (e && e.stack) ? e.stack : String(e) };
    }
    if (!quiet) {
      for (const s of r.stages) {
        console.log(`  ${s.ok ? '✓' : '✗'} ${s.stage}：${s.why}${s.extra ? '   [' + s.extra + ']' : ''}`);
      }
      if (r.crash) console.log(`  ✗ 脚本抛错：${r.crash}`);
    }
    results.push(r);
    if (r.hardFail) failed++;
  }

  // 汇总表
  console.log('\n================ 汇总 ================');
  const tally = { '可用': 0, '站点不可达': 0, '需登录': 0, '有问题': 0, '不可用': 0 };
  for (const r of results) {
    const bad = r.stages.filter((s) => !s.ok);
    const netCaused = bad.some((s) => String(s.why).includes('请求失败') || String(s.why).includes('超时'));
    const gated = r.stages.some((s) => !s.ok && String(s.why).includes('需要登录'));
    let verdict;
    if (bad.length === 0) {
      verdict = '可用';
    } else if (gated) {
      verdict = '需登录';
    } else if (netCaused && bad.every((s) => String(s.why).includes('请求失败') || String(s.why).includes('超时'))) {
      verdict = '站点不可达';
    } else if (r.hardFail) {
      verdict = bad.some((s) => s.stage === '搜索' || s.stage === '详情' || s.stage === '目录') ? '不可用' : '有问题';
    } else {
      verdict = '有问题';
    }
    tally[verdict] = (tally[verdict] || 0) + 1;
    console.log(`${verdict.padEnd(6)} | ${r.name}`);
    for (const s of bad) console.log(`      ↳ ${s.stage}：${s.why}`);
  }
  console.log('\n---- 分类计数 ----');
  for (const key of Object.keys(tally)) {
    if (tally[key] > 0) console.log(`  ${key}：${tally[key]}`);
  }
  console.log(`\n书源 ${results.length} 个，其中硬失败（规则/引擎问题）${failed} 个。`);
  if (dumpDir) console.log(`（原始响应/中间结果已写入 ${dumpDir}）`);
  process.exit(failed > 0 ? 1 : 0);
})();
