'use strict'
/**
 * 真实音源「活体」联调：把 rawfile 里的 lx_utils.js / lx_preload.js 原样装进 Node vm，
 * 再把一个真实音源脚本跑起来，宿主侧用真实网络（node fetch，自动跟随重定向，与洛雪的
 * global.fetch 语义一致）代理 lx.request，最后调用 musicUrl 看能否解析出播放链接。
 *
 * 这与设备上的链路一一对应：
 *   源脚本 -> lx.request -> lxBridge.postMessage('request') -> 宿主代理 -> __lx_native__('response')
 *
 * 运行：
 *   node tools/live_source_probe.js <本地源文件路径或URL> [source] [keyword]
 * 例：
 *   node tools/live_source_probe.js ./.probe/qdy.js kw 听妈妈的话
 */

const fs = require('fs')
const path = require('path')
const vm = require('vm')
const crypto = require('crypto')

const RAWFILE = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile')
const utilsSrc = fs.readFileSync(path.join(RAWFILE, 'lx_utils.js'), 'utf8')
const preloadSrc = fs.readFileSync(path.join(RAWFILE, 'lx_preload.js'), 'utf8')

const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------- 宿主网络代理（对应 LxHttp.ets）
async function proxyRequest (state, requestKey, url, options) {
  const opt = options || {}
  const method = String(opt.method || 'get').toUpperCase()
  const headers = { Accept: 'application/json', 'User-Agent': DEFAULT_UA }
  Object.assign(headers, opt.headers || {})
  let contentType = ''
  for (const k of Object.keys(headers)) if (k.toLowerCase() === 'content-type') contentType = headers[k]

  let body
  if (method === 'POST' && !contentType) {
    if (opt.form) {
      contentType = 'application/x-www-form-urlencoded'
      body = new URLSearchParams(opt.form).toString()
    } else if (opt.formData) {
      const boundary = `----lxboundary${Date.now().toString(16)}`
      contentType = `multipart/form-data; boundary=${boundary}`
      body = Object.keys(opt.formData).map((k) => `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${opt.formData[k]}`).join('\r\n') + `\r\n--${boundary}--\r\n`
    } else {
      contentType = 'application/json'
      if (opt.body !== undefined) body = typeof opt.body === 'string' ? opt.body : JSON.stringify(opt.body)
    }
  } else if (contentType.toLowerCase() === 'application/json' && opt.body !== undefined) {
    body = JSON.stringify(opt.body)
  } else if (opt.body !== undefined) {
    body = typeof opt.body === 'string' ? opt.body : JSON.stringify(opt.body)
  }
  if (contentType) headers['Content-Type'] = contentType

  const timeout = (opt.timeout > 0) ? opt.timeout : 13000
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), timeout)
  const started = Date.now()
  const shortUrl = url.length > 120 ? url.slice(0, 120) + '…' : url
  try {
    const r = await fetch(url, { method, headers, body, signal: ac.signal, redirect: 'follow' })
    clearTimeout(timer)
    let text = await r.text()
    if (text.length > 1024 * 1024) text = text.slice(0, 1024 * 1024)
    let parsed
    try {
      parsed = JSON.parse(text)
      if (parsed === null || typeof parsed !== 'object') parsed = text
    } catch (e) { parsed = text }
    const hdrs = {}
    r.headers.forEach((v, k) => { hdrs[k] = v })
    console.log(`      <- ${r.status} ${shortUrl} (${text.length}B, ${Date.now() - started}ms)`)
    state.sandbox.__lx_native__(state.key, 'response', JSON.stringify({
      requestKey, error: null,
      response: { statusCode: r.status, statusMessage: r.statusText, headers: hdrs, body: parsed },
    }))
  } catch (e) {
    clearTimeout(timer)
    console.log(`      <- ERR ${shortUrl}: ${e.message}`)
    state.sandbox.__lx_native__(state.key, 'response', JSON.stringify({
      requestKey, error: String(e.message || e), response: null,
    }))
  }
}

function createSandbox (state) {
  const sandbox = vm.createContext({})
  sandbox.setTimeout = setTimeout
  sandbox.clearTimeout = clearTimeout
  sandbox.console = { log () {}, info () {}, warn () {}, error () {}, debug () {} }
  sandbox.lxBridge = { postMessage: (action, dataJson) => state.onMessage(action, dataJson) }
  return sandbox
}

function createState () {
  const state = { sandbox: null, key: '', init: null, responses: [], logs: [], errors: [] }
  state.onMessage = (action, dataJson) => {
    let data
    try { data = JSON.parse(dataJson) } catch (e) { return }
    switch (action) {
      case 'init': state.init = data; break
      case 'response': state.responses.push(data); break
      case 'request':
        console.log(`      -> ${String(data.options && data.options.method || 'get').toUpperCase()} ${data.url}`)
        proxyRequest(state, data.requestKey, data.url, data.options)
        break
      case 'log': state.logs.push(data); break
      case 'scriptError': state.errors.push(data.message); break
      default: break
    }
  }
  return state
}

async function loadScript (arg) {
  if (/^https?:\/\//.test(arg)) {
    const r = await fetch(arg, { redirect: 'follow' })
    return await r.text()
  }
  return fs.readFileSync(arg, 'utf8')
}

async function main () {
  const [src, wantSource, keyword, infoJson] = process.argv.slice(2)
  if (!src) { console.error('用法: node tools/live_source_probe.js <源文件或URL> [source] [keyword]'); process.exit(2) }

  const script = await loadScript(src)
  console.log(`源: ${src} (${script.length} 字节)\n`)

  const state = createState()
  const sandbox = createSandbox(state)
  state.sandbox = sandbox
  const key = `probe_${Math.random().toString(36).slice(2)}`
  state.key = key

  sandbox.__lx_bootstrap__ = {
    key,
    rawScript: script,
    env: 'mobile',
    meta: { name: 'probe', description: '', version: '1.0.0', author: 'probe', homepage: '' },
  }
  vm.runInContext(utilsSrc, sandbox, { filename: 'lx_utils.js' })
  vm.runInContext(preloadSrc, sandbox, { filename: 'lx_preload.js' })
  const wrapped = `try { (function () {\n${script}\n})(); } catch (e) { lxBridge.postMessage('scriptError', JSON.stringify({ message: String((e && e.message) || e) })); }`
  try {
    vm.runInContext(wrapped, sandbox, { filename: 'source.js' })
  } catch (e) {
    console.log(`脚本语法错误: ${e.message}`)
  }

  // 等 init（有些源初始化本身要联网）
  const deadline = Date.now() + 30000
  while (Date.now() < deadline && state.init === null) await sleep(50)

  if (state.init === null) {
    console.log('初始化：超时（没有收到 lx.send("inited")）')
    console.log('沙箱状态：', vm.runInContext('__lx_debug_state__()', sandbox))
    if (state.errors.length) console.log('脚本错误：', state.errors)
    process.exit(1)
  }
  console.log(`初始化：status=${state.init.status} ${state.init.errorMessage || ''}`)
  const sources = (state.init.info && state.init.info.sources) || {}
  console.log(`声明平台：${Object.keys(sources).join(', ')}`)
  for (const name of Object.keys(sources)) {
    console.log(`  - ${name}: actions=[${(sources[name].actions || []).join(',')}] qualitys=[${(sources[name].qualitys || []).join(',')}]`)
  }

  const source = wantSource && sources[wantSource] ? wantSource : Object.keys(sources)[0]
  if (!source) { console.log('没有可用平台'); process.exit(1) }

  const kw = keyword || '听妈妈的话'
  let musicInfo = {
    name: kw, singer: '周杰伦', source, songmid: '138243',
    albumName: '', albumId: '', interval: '04:25', img: '',
    types: [], _types: {}, typeUrl: {}, lrc: null, otherSource: null,
  }
  // 第 4 个参数可传 musicInfo 的覆盖字段（JSON），用来指定各平台真实 id：
  //   kw->songmid  kg->hash  tx->songmid  wy->songmid  mg->copyrightId
  if (infoJson) Object.assign(musicInfo, JSON.parse(infoJson))
  console.log(`\n解析播放链接：source=${source} musicInfo.songmid=${musicInfo.songmid}`)
  const requestKey = `mq_${Math.random().toString(36).slice(2)}`
  sandbox.__lx_native__(key, 'request', JSON.stringify({
    requestKey, data: { source, action: 'musicUrl', info: { type: (sources[source].qualitys || ['128k'])[0], musicInfo } },
  }))

  const dl = Date.now() + 40000
  while (Date.now() < dl) {
    const hit = state.responses.find((r) => r.requestKey === requestKey)
    if (hit) {
      console.log(`\n结果：status=${hit.status}`)
      if (hit.status) {
        console.log(`播放链接: ${hit.result && hit.result.data ? hit.result.data.url : JSON.stringify(hit.result)}`)
      } else {
        console.log(`错误: ${hit.errorMessage}`)
      }
      process.exit(hit.status ? 0 : 1)
    }
    await sleep(100)
  }
  console.log('\n结果：超时（源脚本没有回 response）')
  process.exit(1)
}

main().catch((e) => { console.error(e); process.exit(1) })
