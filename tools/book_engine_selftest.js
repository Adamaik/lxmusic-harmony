/**
 * 书源引擎离线/联网自检（无设备）
 *
 * 用 jsdom 顶替 ArkWeb 沙箱：真正的 book_preload.js + lx_utils.js 照原样加载，
 * 宿主侧（网络代理 + 回放循环）用 Node 的 fetch 实现 —— 与设备上 ArkTS 的
 * BookEngine 是同一套契约（__book_run__ 返回 status:'net' 就去抓、抓到再重跑）。
 *
 * 用法：
 *   node tools/book_engine_selftest.js                      # 只跑离线夹具用例
 *   node tools/book_engine_selftest.js --live 六月 "诡秘之主"  # 联网跑通完整链路
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const RAW = path.join(ROOT, 'entry/src/main/resources/rawfile');
const SOURCE_DIR = path.resolve(ROOT, '..', '听书的源');
/**
 * jsdom 只用来顶替 ArkWeb 沙箱，所以不进工程的依赖，放在仓库外的探针目录里。
 * 没装的话给一条明确的安装命令，而不是抛一个看不懂的模块错误。
 */
const JSDOM_PATH = path.resolve(ROOT, '..', '.probe', 'booktest', 'node_modules', 'jsdom');

let JSDOM = null;
try {
  JSDOM = require(JSDOM_PATH).JSDOM;
} catch (e) {
  console.error('缺少 jsdom（本脚本用它顶替 ArkWeb 沙箱）。先装一下：');
  console.error('');
  console.error('  mkdir -p ../.probe/booktest && cd ../.probe/booktest');
  console.error('  npm init -y && npm install jsdom@24.1.3');
  console.error('');
  console.error(`（期望路径：${JSDOM_PATH}）`);
  process.exit(2);
}

// ------------------------------------------------------------ 沙箱

function createSandbox() {
  // 用 <script> 注入（而不是 window.eval）：这样 window / DOMParser 是真正的全局，
  // 与 ArkWeb 里 runJavaScript 注入 preload 的情形一致
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

// ------------------------------------------------------------ 宿主网络代理

const UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

async function fetchBody(spec) {
  const url = spec.url;
  if (/^data:/i.test(url)) {
    const comma = url.indexOf(',');
    const head = url.slice(0, comma);
    const payload = url.slice(comma + 1);
    if (/;base64/i.test(head)) return Buffer.from(payload, 'base64').toString('utf8');
    return decodeURIComponent(payload);
  }
  const headers = Object.assign({ 'User-Agent': UA, Accept: '*/*' }, spec.headers || {});
  const init = { method: spec.method || 'GET', headers, redirect: 'follow' };
  if (init.method !== 'GET' && init.method !== 'HEAD' && spec.body) init.body = spec.body;
  const resp = await fetch(url, init);
  const buf = Buffer.from(await resp.arrayBuffer());
  // 简单判定编码：GBK 站点（这批源没有，留个兜底）
  const ctype = resp.headers.get('content-type') || '';
  if (/gbk|gb2312/i.test(ctype)) {
    try {
      return new TextDecoder('gbk').decode(buf);
    } catch (e) { /* 环境不支持就按 utf-8 */ }
  }
  return buf.toString('utf8');
}

/** 与 BookEngine.runJob 同构的回放循环：host 抓回来的响应按引擎报的 key 塞回去 */
async function runJob(win, job, fetchImpl = fetchBody, maxRounds = 220) {
  const netCache = {};
  let lastLogs = [];
  for (let round = 0; round < maxRounds; round++) {
    const payload = Object.assign({}, job, { netCache });
    const raw = win.__book_run__(JSON.stringify(payload));
    const res = JSON.parse(raw);
    lastLogs = res.logs || [];
    if (res.status === 'net') {
      for (const spec of res.urls) {
        try {
          netCache[spec.key] = await fetchImpl(spec);
          if (process.env.BOOK_DEBUG) {
            console.error(`  [net] ${spec.method} ${spec.url} -> ${String(netCache[spec.key]).length} bytes`);
          }
        } catch (e) {
          netCache[spec.key] = '';
          console.error(`  [net] FAILED ${spec.url}: ${e.message}`);
        }
      }
      continue;
    }
    return { res, logs: lastLogs, rounds: round + 1 };
  }
  return { res: { status: 'error', message: `回放轮数超过上限（${maxRounds}）` }, logs: lastLogs, rounds: maxRounds };
}

/** 用「地址 -> 正文」的夹具充当宿主网络 */
function fixtureFetch(fixtures) {
  return async (spec) => {
    const hit = fixtures[spec.url];
    if (hit === undefined) {
      throw new Error(`夹具里没有这个地址：${spec.url}`);
    }
    return hit;
  };
}

// ------------------------------------------------------------ 测试用例

let pass = 0;
let fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.log(`  ✗ ${name}${detail ? '  —— ' + detail : ''}`); }
}

/** 离线夹具：把「宿主抓回来的响应」按地址喂给回放循环，验证规则求值 + 回放本身 */
async function offlineCases(win) {
  console.log('\n== 离线夹具：规则求值（走完整回放循环）==');

  // 1) CSS + ## 净化（六月听书网的详情页取值）
  const fixture = `<html><body>
    <div class="stui-content__detail">
      <h3 class="title">诡秘之主</h3>
      <p class="data"><a href="/dushuyue/1-1.html">有声小说</a></p>
      <p class="data hidden-sm">更新：2024-05-01</p>
      <div class="detail-sketch">一本好书</div>
    </div>
    <ul class="stui-content__playlist">
      <li><a href="/play/1-1-1.html" title="第01集 序章">第01集 序章</a></li>
      <li><a href="/play/1-1-2.html" title="第02集 觉醒">第02集 觉醒</a></li>
    </ul>
    <div class="stui-player__iframe">&lt;script&gt;var now="https://cdn.example.com/a/b/001.mp3";&lt;/script&gt;</div>
  </body></html>`;

  const src = {
    bookSourceName: '夹具',
    bookSourceUrl: 'https://www.dushuyue.com',
    header: '{"Referer":"https://www.dushuyue.com/"}',
    ruleBookInfo: {
      name: '.stui-content__detail h3.title@text',
      kind: ".stui-content__detail p.data a[href*='/dushuyue/']@text",
      updateTime: '.stui-content__detail p.data.hidden-sm@text##^更新：',
      intro: '.stui-content__detail .detail-sketch@text',
    },
    ruleToc: {
      chapterList: 'ul.stui-content__playlist li',
      chapterName: 'a@title',
      chapterUrl: 'a@href',
    },
    ruleContent: {
      content: '.stui-player__iframe@html##[\\s\\S]*var now="([^"]+)"[\\s\\S]*##$1',
    },
  };

  const bookUrl = 'https://www.dushuyue.com/book/1.html';
  const playUrl = 'https://www.dushuyue.com/play/1-1-1.html';
  const fx = { [bookUrl]: fixture, [playUrl]: fixture };
  const ff = fixtureFetch(fx);

  let out = await runJob(win, { action: 'bookInfo', source: src, book: { bookUrl } }, ff);
  let r = out.res;
  check('bookInfo 动作成功', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('CSS 取书名', r.data.name === '诡秘之主', JSON.stringify(r.data.name));
    check('CSS + 属性选择器取分类', r.data.kind === '有声小说', JSON.stringify(r.data.kind));
    check('## 净化去掉「更新：」前缀', r.data.updateTime === '2024-05-01', JSON.stringify(r.data.updateTime));
    check('tocUrl 回退到书本地址', r.data.tocUrl === bookUrl, r.data.tocUrl);
  }

  out = await runJob(win, { action: 'toc', source: src, book: { bookUrl }, url: bookUrl }, ff);
  r = out.res;
  check('目录动作成功', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('目录取到 2 章', r.data.length === 2, JSON.stringify(r.data.length));
    check('章节名取 title 属性', r.data[0].name === '第01集 序章', JSON.stringify(r.data[0].name));
    check('章节地址转成绝对地址', r.data[0].url === playUrl, r.data[0].url);
  }

  out = await runJob(win, {
    action: 'content', source: src, book: { bookUrl }, chapter: { url: playUrl, name: '第01集' },
  }, ff);
  r = out.res;
  check('正文（音频）动作成功', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('## 正则 ### 抓出音频直链',
      r.data.url === 'https://cdn.example.com/a/b/001.mp3', JSON.stringify(r.data.url));
  }

  // 2) JSONPath + @js 取值（喜马拉雅风格）
  const jsonSrc = {
    bookSourceName: '夹具JSON',
    bookSourceUrl: 'https://www.ximalaya.com',
    exploreUrl: 'https://www.ximalaya.com/revision/search?core=album&kw={{key}}&page={{page}}',
    ruleExplore: {
      bookList: '$.data.result.response.docs[*]',
      name: '$.title',
      bookUrl: 'https://www.ximalaya.com/revision/album/v1/simple?albumId={{$.id}}',
      author: '$.nickname',
      kind: '$.category_title',
      status: "@js: var d=JSON.parse(src); d.is_finished==0?'连载':'完结';",
      wordCount: '$.tracks',
    },
  };
  const searchJson = JSON.stringify({
    data: {
      result: {
        response: {
          docs: [
            { id: 111, title: '凡人修仙传', nickname: '主播甲', category_title: '玄幻', is_finished: 0, tracks: 2000 },
            { id: 222, title: '三体', nickname: '主播乙', category_title: '科幻', is_finished: 1, tracks: 300 },
          ],
        },
      },
    },
  });
  const exploreUrl = 'https://www.ximalaya.com/revision/search?core=album&kw=%E7%8E%84%E5%B9%BB&page=1';
  out = await runJob(win, {
    action: 'explore', source: jsonSrc, key: '玄幻', page: 1,
  }, fixtureFetch({ [exploreUrl]: searchJson }));
  r = out.res;
  check('JSONPath 列表 + {{key}} 模板拼地址', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('JSONPath 取到 2 条', r.data.length === 2, JSON.stringify(r.data.length));
    check('JSONPath 取书名', r.data[0].name === '凡人修仙传', JSON.stringify(r.data[0].name));
    check('{{$.id}} 拼进 bookUrl',
      r.data[0].bookUrl === 'https://www.ximalaya.com/revision/album/v1/simple?albumId=111', r.data[0].bookUrl);
    check('@js 规则判连载/完结',
      r.data[0].status === '连载' && r.data[1].status === '完结',
      JSON.stringify([r.data[0].status, r.data[1].status]));
    check('数字字段不出现小数点', r.data[0].wordCount === '2000', JSON.stringify(r.data[0].wordCount));
  }

  // 3) `||` 回退 + 正则列表 `$['$0']`（播客 RSS）
  const rssSrc = {
    bookSourceName: '夹具RSS',
    bookSourceUrl: 'https://podcasts.apple.com',
    ruleBookInfo: { tocUrl: '{{bookUrl}}' },
    ruleToc: {
      chapterList: ':<item>([\\s\\S]*?)</item>',
      chapterName: "$['$0']##<title>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?<\\/title>##$1###",
      chapterUrl: "$['$0']##jt=(https:[^\"&]+)##$1###||$['$0']##<enclosure[^>]*\\burl=\"([^\"]+)##$1###",
    },
  };
  const feed = `<?xml version="1.0"?><rss><channel>
    <item><title>第一集</title><enclosure url="https://cdn.pod.example/1.mp3" type="audio/mpeg"/></item>
    <item><title>第二集</title><enclosure url="https://cdn.pod.example/2.mp3" type="audio/mpeg"/></item>
  </channel></rss>`;
  const feedUrl = 'https://pod.example/feed.xml';

  out = await runJob(win, {
    action: 'bookInfo', source: rssSrc, book: { bookUrl: feedUrl },
  }, fixtureFetch({ [feedUrl]: feed }));
  r = out.res;
  check('{{bookUrl}} 模板算出目录地址',
    r.status === 'ok' && r.data.tocUrl === feedUrl, JSON.stringify(r.status === 'ok' ? r.data.tocUrl : r.message));

  out = await runJob(win, { action: 'toc', source: rssSrc, book: { bookUrl: feedUrl }, url: feedUrl },
    fixtureFetch({ [feedUrl]: feed }));
  r = out.res;
  check('RSS 目录动作成功', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('正则列表 + $0 取到 2 章', r.data.length === 2, JSON.stringify(r.data.length));
    check('|| 回退命中 enclosure url',
      r.data[0].url === 'https://cdn.pod.example/1.mp3', JSON.stringify(r.data[0].url));
    check('章节名从 <title> 提取', r.data[0].name === '第一集', JSON.stringify(r.data[0].name));
  }

  // 4) `<js>` 全量搜索（悦听：返回 data: URL，内部还会 java.ajax 取多个分类页）
  const jsSrc = {
    bookSourceName: '夹具JS',
    bookSourceUrl: 'https://www.ytysxs.com',
    searchUrl: "<js>var html='<div id=\"x\"><article class=\"post-item-list\"><h2 class=\"entry-title\"><a href=\"https://www.ytysxs.com/9.html\">测试书名</a></h2></article></div>';'data:text/html;base64,'+java.base64EncodeToString(html);</js>",
    ruleSearch: {
      bookList: 'article.post-item-list',
      name: 'h2.entry-title a@text',
      bookUrl: 'h2.entry-title a@href',
    },
  };
  out = await runJob(win, { action: 'search', source: jsSrc, key: '测试', page: 1 }, fixtureFetch({}));
  r = out.res;
  check('<js> 搜索地址（data: URL）动作成功', r.status === 'ok', r.message || r.status);
  if (r.status === 'ok') {
    check('data: URL 解出 HTML 并解析出结果', r.data.length === 1, JSON.stringify(r.data.length));
    check('<js> 源的书名正确', r.data[0].name === '测试书名', JSON.stringify(r.data[0].name));
  }

  // 5) java.ajax / java.connect 回放 + 结果缓存
  const replaySrc = {
    bookSourceName: '夹具回放',
    bookSourceUrl: 'https://replay.example',
    ruleContent: {
      content: "@js:(function(){var r=java.ajax('https://replay.example/api?id=1');var d=JSON.parse(r);var c=java.connect('https://replay.example/c2');var d2=JSON.parse(c.body());return d.url+'?k='+d2.k;})()",
    },
  };
  const page = 'https://replay.example/play/1.html';
  const api = 'https://replay.example/api?id=1';
  const c2 = 'https://replay.example/c2';
  out = await runJob(win, { action: 'content', source: replaySrc, chapter: { url: page } },
    fixtureFetch({
      [page]: '<html></html>',
      [api]: JSON.stringify({ url: 'https://cdn.replay.example/x.mp3' }),
      [c2]: JSON.stringify({ k: 'v9' }),
    }));
  r = out.res;
  check('java.ajax + java.connect 回放后拿到结果',
    r.status === 'ok' && r.data.url === 'https://cdn.replay.example/x.mp3?k=v9',
    JSON.stringify(r.status === 'ok' ? r.data : r.message));
  check('回放轮数与并发缺失数一致', out.rounds <= 4, `rounds=${out.rounds}`);
}

// ------------------------------------------------------------ 联网：跑真实书源完整链路

async function liveCase(win, sourceName, keyword) {
  console.log(`\n== 联网：${sourceName} 「${keyword}」完整链路 ==`);
  const files = fs.readdirSync(SOURCE_DIR).filter((f) => f.endsWith('.json'));
  const file = files.find((f) => f.includes(sourceName));
  if (!file) {
    check(`找到书源文件 ${sourceName}`, false, files.join(', '));
    return;
  }
  const arr = JSON.parse(fs.readFileSync(path.join(SOURCE_DIR, file), 'utf8'));
  const source = Array.isArray(arr) ? arr[0] : arr;
  console.log(`  源：${source.bookSourceName} | ${source.bookSourceUrl}`);

  const t0 = Date.now();
  let out = await runJob(win, { action: 'search', source, key: keyword, page: 1 });
  if (out.res.status !== 'ok') {
    check('搜索', false, out.res.message);
    return;
  }
  const hits = out.res.data || [];
  check(`搜索返回 ${hits.length} 条`, hits.length > 0, JSON.stringify(hits[0] || null));
  if (hits.length === 0) return;
  const hit = hits[0];
  console.log(`  首条：${hit.name} / ${hit.author || '—'} / ${hit.bookUrl}`);

  out = await runJob(win, { action: 'bookInfo', source, book: { bookUrl: hit.bookUrl, name: hit.name } });
  if (out.res.status !== 'ok') { check('详情', false, out.res.message); return; }
  const info = out.res.data;
  console.log(`  详情：${info.name || hit.name} / tocUrl=${info.tocUrl}`);
  check('详情页拿到 tocUrl', String(info.tocUrl || '').length > 0, JSON.stringify(info));

  const book = Object.assign({}, hit, info, { bookUrl: hit.bookUrl });
  out = await runJob(win, { action: 'toc', source, book, url: info.tocUrl || hit.bookUrl });
  if (out.res.status !== 'ok') { check('目录', false, out.res.message); return; }
  const chapters = out.res.data || [];
  check(`目录返回 ${chapters.length} 章`, chapters.length > 0, JSON.stringify(chapters[0] || null));
  if (chapters.length === 0) return;
  console.log(`  首章：${chapters[0].name} -> ${chapters[0].url}`);

  out = await runJob(win, { action: 'content', source, book, chapter: chapters[0] });
  if (out.res.status !== 'ok') { check('音频解析', false, out.res.message); return; }
  const audio = out.res.data || {};
  console.log(`  音频：${audio.url}（来自 ${audio.from}）`);
  check('解析出音频直链', /^https?:\/\//i.test(String(audio.url || '')), JSON.stringify(audio));

  if (/^https?:\/\//i.test(String(audio.url || ''))) {
    try {
      const resp = await fetch(audio.url, {
        headers: Object.assign({ 'User-Agent': UA }, JSON.parse(source.header || '{}')), method: 'HEAD',
      });
      check(`音频地址可访问（HTTP ${resp.status}，${resp.headers.get('content-type') || '?'}）`, resp.status < 400);
    } catch (e) {
      check('音频地址可访问', false, e.message);
    }
  }
  console.log(`  用时 ${((Date.now() - t0) / 1000).toFixed(1)}s，网络轮数 ${out.rounds}`);
}

// ------------------------------------------------------------ main

(async () => {
  const args = process.argv.slice(2);
  const win = createSandbox();
  const ping = JSON.parse(win.__book_ping__());
  console.log('沙箱：', JSON.stringify(ping));
  check('沙箱可跑规则（DOMParser 可用）', ping.ok === true && ping.hasDom === true, JSON.stringify(ping));

  if (args[0] === '--live') {
    const name = args[1] || '六月';
    const kw = args[2] || '诡秘之主';
    await liveCase(win, name, kw);
  } else {
    await offlineCases(win);
    if (args.includes('--also-live')) {
      await liveCase(win, '六月', '诡秘之主');
    }
  }

  console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
  process.exit(fail > 0 ? 1 : 0);
})();
