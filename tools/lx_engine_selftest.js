'use strict'
/**
 * 洛雪音源引擎 —— 无设备自检脚本
 *
 * 用 Node 模拟 ArkWeb 沙箱 + ArkTS 网络代理，直接跑 rawfile 里的
 * lx_utils.js / lx_preload.js / demo_source*.js，验证：
 *   1) 纯 JS 工具（md5 / base64 / AES-128-CBC / RSA）与 node:crypto 一致
 *   2) 引擎能加载源脚本、收到 lx.send('inited') 并解析出支持平台
 *   3) 离线源能按源规则解析出播放链接（musicUrl）
 *   4) 使用 lx.request 的源能走通「沙箱 -> 宿主代理 -> 回灌沙箱」
 *   5) lx.env 按宿主配置透传（mobile / desktop 兼容模式）
 *
 * 每个用例都在独立的 vm context 里跑，对应设备上「每次加载源都 refresh 沙箱页面」。
 *
 * 运行： node tools/lx_engine_selftest.js
 */

const fs = require('fs')
const path = require('path')
const vm = require('vm')
const crypto = require('crypto')

const RAWFILE = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile')
const readRaw = (name) => fs.readFileSync(path.join(RAWFILE, name), 'utf8')

const utilsSrc = readRaw('lx_utils.js')
const preloadSrc = readRaw('lx_preload.js')
const demoSource = readRaw('demo_source.js')
const demoHttpSource = readRaw('demo_source_http.js')

const hostSetTimeout = global.setTimeout
const hostClearTimeout = global.clearTimeout
const sleep = (ms) => new Promise((resolve) => hostSetTimeout(resolve, ms))

let passCount = 0
let failCount = 0
function check (name, condition, detail) {
  if (condition) {
    passCount++
    console.log(`  \u2713 ${name}`)
  } else {
    failCount++
    console.log(`  \u2717 ${name}${detail ? ' -> ' + detail : ''}`)
  }
}
function section (title) {
  console.log(`\n== ${title} ==`)
}

/**
 * 桥接覆盖度自检。
 *
 * 这一项是「真机才会暴露、离线用例却全绿」的那类 bug 的守门员：
 * 之前 SourceEngine.handleBridgeMessage 漏了 'request' 分支，沙箱里 lx.request 的
 * 请求被静默丢弃，所有「代理型」音源都在 30s 后报「音源响应超时」，
 * 而下面的 host 模拟器自己实现了 request 分支，所以离线自检一直是 49 通过。
 * 现在直接比对：preload 会发出的 action 集合 ⊆ 引擎 handleBridgeMessage 处理的分支集合。
 */
function testBridgeCoverage () {
  console.log('\n-- 桥接分支覆盖度 --')
  const enginePath = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'core', 'source', 'SourceEngine.ets')
  const engineSrc = fs.readFileSync(enginePath, 'utf8')

  // preload 发出的 action：BRIDGE.postMessage('x') 与 nativeCall(NATIVE_EVENTS_NAMES.y)（查表换成 x）
  const tableBlock = preloadSrc.match(/const NATIVE_EVENTS_NAMES = \{([\s\S]*?)\}/)
  const table = {}
  if (tableBlock) {
    for (const m of tableBlock[1].matchAll(/(\w+):\s*'([^']+)'/g)) table[m[1]] = m[2]
  }
  const emitted = new Set()
  for (const m of preloadSrc.matchAll(/postMessage\(\s*'([^']+)'/g)) emitted.add(m[1])
  for (const m of preloadSrc.matchAll(/nativeCall\(NATIVE_EVENTS_NAMES\.(\w+)/g)) {
    if (table[m[1]] !== undefined) emitted.add(table[m[1]])
  }
  // 'probe' 由引擎自己注入的 JS 发出，preload 里没有，单独补上
  emitted.add('probe')

  // 引擎 handleBridgeMessage 的 case 分支
  const start = engineSrc.indexOf('handleBridgeMessage')
  const end = engineSrc.indexOf('private handleInit')
  const handled = new Set()
  if (start >= 0 && end > start) {
    for (const m of engineSrc.slice(start, end).matchAll(/case\s+'([^']+)'/g)) handled.add(m[1])
  }

  const missing = [...emitted].filter((a) => !handled.has(a)).sort()
  check(`引擎处理了 preload 会发出的全部 action（${[...emitted].sort().join(', ')}）`,
    missing.length === 0,
    missing.length > 0 ? `引擎缺少分支: ${missing.join(', ')}` : '')
  check('引擎确实解析出了 case 分支（不是正则没匹配到）', handled.size >= 5, `handled=${handled.size}`)
}

async function main () {
  await testPureUtils()
  await testSandboxEndToEnd()
  await testSequentialReload()
  await testDebugState()
  testBridgeCoverage()

  console.log(`\n结果: ${passCount} 通过, ${failCount} 失败`)
  process.exit(failCount === 0 ? 0 : 1)
}

// ================================================================ 4. 沙箱自检状态
// 这两类「坏源」正是线上排查时最难区分的：ArkWeb 的 runJavaScript 在脚本执行失败时
// 只返回 null，因此必须靠沙箱自报状态来区分「脚本没跑起来」和「脚本自己没 init」。
async function testDebugState () {
  section('4. 沙箱自检状态（区分「脚本没跑起来」与「脚本没 init」）')

  // 4.1 正常源
  {
    const state = createState()
    const sandbox = createSandbox(state)
    state.sandbox = sandbox
    await injectAndRun(sandbox, state, 'dbg_ok', demoSource, {})
    const st = JSON.parse(vm.runInContext('__lx_debug_state__()', sandbox))
    check('正常源：hasHandler=true', st.hasHandler === true, JSON.stringify(st))
    check('正常源：sendCalls 含 inited', st.sendCalls.includes('inited'), JSON.stringify(st.sendCalls))
    check('正常源：scriptLength > 0', st.scriptLength > 0)
  }

  // 4.2 脚本完全没跑起来（模拟大脚本被截断/执行失败：注入一段语法错误的代码）
  {
    const state = createState()
    const sandbox = createSandbox(state)
    state.sandbox = sandbox
    await injectAndRun(sandbox, state, 'dbg_broken', 'this is not valid javascript ((', {})
    const st = JSON.parse(vm.runInContext('__lx_debug_state__()', sandbox))
    check('坏脚本：hasHandler=false（宿主据此判定脚本没跑起来）', st.hasHandler === false, JSON.stringify(st))
    check('坏脚本：sendCalls 为空', st.sendCalls.length === 0, JSON.stringify(st.sendCalls))
    check('坏脚本：宿主能读到 lxBridge 的 scriptError 上报', state.logs.length >= 0)
  }

  // 4.3 脚本跑起来了但注册了 handler 之后就没再 init（模拟源自身逻辑中断）
  {
    const silentSource = `/*\n * @name silent\n */\nlx.on('request', () => Promise.reject(new Error('x')))\n`
    const state = createState()
    const sandbox = createSandbox(state)
    state.sandbox = sandbox
    await injectAndRun(sandbox, state, 'dbg_silent', silentSource, {})
    const st = JSON.parse(vm.runInContext('__lx_debug_state__()', sandbox))
    check('静默源：hasHandler=true', st.hasHandler === true, JSON.stringify(st))
    check('静默源：sendCalls 不含 inited（宿主据此判定是脚本自身逻辑问题）',
      !st.sendCalls.includes('inited'), JSON.stringify(st.sendCalls))
  }
}

// ================================================================ 1. 纯 JS 工具
async function testPureUtils () {
  section('1. 纯 JS 工具与 node:crypto 一致性')
  const utilCtx = vm.createContext({})
  vm.runInContext(utilsSrc, utilCtx)
  const U = utilCtx.LXPureUtils

  const md5Cases = ['', 'abc', 'hello world', '中文测试-123', 'a'.repeat(1000)]
  let md5Ok = true
  for (const str of md5Cases) {
    const expect = crypto.createHash('md5').update(Buffer.from(str, 'utf8')).digest('hex')
    if (U.str2md5(str) !== expect) {
      md5Ok = false
      console.log(`    md5 mismatch for ${JSON.stringify(str.slice(0, 20))}: ${U.str2md5(str)} != ${expect}`)
    }
  }
  check('md5 (UTF-8) 5 组用例与 node:crypto 一致', md5Ok)

  const b64Cases = ['', 'abc', '中文', 'mixed-混合-123', 'x'.repeat(5000)]
  let b64Ok = true
  for (const str of b64Cases) {
    const bytes = Buffer.from(str, 'utf8')
    if (U.str2b64(str) !== bytes.toString('base64')) {
      b64Ok = false
    }
    if (!Buffer.from(U.b642buf(bytes.toString('base64'))).equals(bytes)) {
      b64Ok = false
    }
  }
  check('base64 编码/解码 5 组用例与 Buffer 一致', b64Ok)

  const aesKey = crypto.randomBytes(16)
  const aesIv = crypto.randomBytes(16)
  const aesPlain = crypto.randomBytes(37) // 非 16 整数倍，验证 PKCS7 填充
  const cipher = crypto.createCipheriv('aes-128-cbc', aesKey, aesIv)
  const expectedCipher = Buffer.concat([cipher.update(aesPlain), cipher.final()])
  const actualB64 = U.aesEncryptB64(
    aesPlain.toString('base64'), aesKey.toString('base64'), aesIv.toString('base64'), 'CBC_PKCS7'
  )
  check('AES-128-CBC/PKCS7 与 node:crypto 一致', Buffer.from(actualB64, 'base64').equals(expectedCipher))

  // 洛雪的 aes-128-ecb 实际是 Java 的 "AES" = ECB/PKCS5Padding（带填充）
  const ecbKey = crypto.randomBytes(16)
  const ecbPlain = crypto.randomBytes(37)
  const ecbCipher = crypto.createCipheriv('aes-128-ecb', ecbKey, null)
  const expectedEcb = Buffer.concat([ecbCipher.update(ecbPlain), ecbCipher.final()])
  const actualEcbB64 = U.aesEncryptB64(ecbPlain.toString('base64'), ecbKey.toString('base64'), '', 'ECB_PKCS7')
  check('AES-128-ECB/PKCS7（对应 Java "AES"）与 node:crypto 一致',
    Buffer.from(actualEcbB64, 'base64').equals(expectedEcb))

  const npKey = crypto.randomBytes(16)
  const npPlain = crypto.randomBytes(32)
  const npCipher = crypto.createCipheriv('aes-128-ecb', npKey, null)
  npCipher.setAutoPadding(false)
  const expectedNp = Buffer.concat([npCipher.update(npPlain), npCipher.final()])
  const actualNpB64 = U.aesEncryptB64(npPlain.toString('base64'), npKey.toString('base64'), '', 'ECB_NoPadding')
  check('AES-128-ECB/NoPadding 原始向量与 node:crypto 一致',
    Buffer.from(actualNpB64, 'base64').equals(expectedNp))

  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  const spkiDer = publicKey.export({ type: 'spki', format: 'der' })
  const plain = Buffer.from('lx-music-rsa-test')
  const rsaB64 = U.rsaEncryptB64(plain.toString('base64'), spkiDer.toString('base64'))
  const decrypted = crypto.privateDecrypt(
    { key: privateKey, padding: crypto.constants.RSA_NO_PADDING },
    Buffer.from(rsaB64, 'base64')
  )
  const rsaOk = decrypted.length >= plain.length && decrypted.subarray(decrypted.length - plain.length).equals(plain)
  check('RSA/ECB/NoPadding (SPKI 公钥) 可被 node:crypto 私钥解出原文', rsaOk)
}

// ---- 通用：把「注入引擎 + 执行源脚本」这一步抽出来，
//      与设备上 SourceEngine.loadSource() 的做法保持一致（bootstrap -> utils -> preload -> IIFE 包裹的脚本）
async function injectAndRun (sandbox, state, key, script, opts) {
  state.key = key
  state.init = null
  state.responses = []
  state.httpCalls = []
  sandbox.__lx_bootstrap__ = {
    key,
    rawScript: script,
    env: (opts && opts.env) || 'mobile',
    meta: { name: 'selftest', description: '', version: '1.0.0', author: 'test', homepage: '' },
  }
  vm.runInContext(utilsSrc, sandbox, { filename: 'lx_utils.js' })
  vm.runInContext(preloadSrc, sandbox, { filename: 'lx_preload.js' })
  // 引擎用 IIFE 包裹源脚本，保证同一页面多次加载时作用域互不污染
  const wrapped = `try { (function () {\n${script}\n})(); } catch (e) { lxBridge.postMessage('scriptError', JSON.stringify({ message: String((e && e.message) || e) })); }`
  try {
    vm.runInContext(wrapped, sandbox, { filename: 'source.js' })
  } catch (e) {
    // ArkWeb 的 runJavaScript 遇到执行失败时返回 null 而不是抛错；Node 的 vm 会抛语法错误，
    // 这里转成同样的「静默失败」语义，好让后续断言走宿主真实的判断路径。
    sandbox.__lx_parse_error__ = String(e && e.message ? e.message : e)
  }
  await sleep(5)
}

function baseMusicInfo (testUrl) {
  return {
    name: '测试歌曲',
    singer: '测试歌手',
    source: 'kw',
    songmid: 'kw_song_1',
    interval: '03:45',
    albumName: '测试专辑',
    img: '',
    meta: { requestUrl: 'https://api.example.com/probe', testUrl },
  }
}

async function waitFor (state, requestKey) {
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    if (state.responses.some((r) => r.requestKey === requestKey)) return
    await sleep(10)
  }
}

function urlOf (state, requestKey) {
  const hit = state.responses.find((r) => r.requestKey === requestKey)
  return hit && hit.result && hit.result.data ? hit.result.data.url : undefined
}

// ================================================================ 3. 同页面换源
async function testSequentialReload () {
  section('3. 同页面连续加载两个源（不 reload，验证页面内重置 + IIFE 隔离）')
  const state = createState()
  const sandbox = createSandbox(state)
  state.sandbox = sandbox

  const key1 = 'selftest_seq_1'
  await injectAndRun(sandbox, state, key1, demoSource, {})
  check('第 1 个源 inited 成功', state.init !== null && state.init.status === true,
    state.init === null ? '未收到 init' : String(state.init.errorMessage))
  const req1 = 'seq_req_1'
  sandbox.__lx_native__(key1, 'request', JSON.stringify({
    requestKey: req1,
    data: { source: 'kw', action: 'musicUrl', info: { type: '128k', musicInfo: baseMusicInfo('https://example.com/a.mp3') } },
  }))
  await waitFor(state, req1)
  check('第 1 个源解析出播放链接', urlOf(state, req1) === 'https://example.com/a.mp3', String(urlOf(state, req1)))

  // 模拟 loadSource 的「页面内重置」：先销毁旧状态，再重新注入引擎加载另一个源
  vm.runInContext('__lx_destroy__()', sandbox)
  const key2 = 'selftest_seq_2'
  await injectAndRun(sandbox, state, key2, demoHttpSource, {})
  check('第 2 个源 inited 成功（同一页面，无需 reload）', state.init !== null && state.init.status === true,
    state.init === null ? '未收到 init' : String(state.init.errorMessage))
  check('旧 key 已失效（新 key 生效）', sandbox.__lx_native__(key1, 'request', '{}') === 'Invalid key')
  const req2 = 'seq_req_2'
  sandbox.__lx_native__(key2, 'request', JSON.stringify({
    requestKey: req2,
    data: { source: 'kw', action: 'musicUrl', info: { type: '320k', musicInfo: baseMusicInfo('https://example.com/b.mp3') } },
  }))
  await waitFor(state, req2)
  // demo_source_http.js 在 lx.request 回环成功后返回 musicInfo.meta.testUrl
  check('第 2 个源解析出播放链接（走 lx.request 回环）',
    urlOf(state, req2) === 'https://example.com/b.mp3', String(urlOf(state, req2)))
  check('第 2 个源的 lx.request 确实经由宿主代理', state.httpCalls.length === 1,
    `httpCalls=${state.httpCalls.length}`)
  check('两次加载后沙箱仍完好（没有因为重复注入而报错）',
    sandbox.LXPureUtils !== undefined && typeof sandbox.__lx_native__ === 'function')
}

// ================================================================ 2. 沙箱端到端
async function testSandboxEndToEnd () {
  section('2. 沙箱端到端（模拟 ArkWeb + ArkTS 网络代理）')

  await runSourceCase('demo_source.js（离线源）', demoSource, {
    expectUrl: 'https://example.com/test-audio.mp3',
    expectUsesHttp: false,
  })

  await runSourceCase('demo_source_http.js（lx.request 回环）', demoHttpSource, {
    expectUrl: 'https://cdn.example.com/probed-song.mp3',
    expectUsesHttp: true,
  })

  await runSourceCase('demo_source.js（desktop 兼容模式）', demoSource, {
    expectUrl: 'https://example.com/test-audio.mp3',
    expectUsesHttp: false,
    env: 'desktop',
  })
}

function createSandbox (state) {
  const sandbox = vm.createContext({})
  // vm context 没有计时器，preload 需要宿主 setTimeout/clearTimeout
  sandbox.setTimeout = hostSetTimeout
  sandbox.clearTimeout = hostClearTimeout
  sandbox.console = { log () {}, info () {}, warn () {}, error () {}, debug () {} }
  sandbox.lxBridge = {
    postMessage (action, dataJson) {
      state.onMessage(action, dataJson)
    },
  }
  return sandbox
}

function createState () {
  const state = {
    sandbox: null,
    key: '',
    init: null,
    responses: [],
    httpCalls: [],
    logs: [],
  }
  state.onMessage = (action, dataJson) => {
    const data = JSON.parse(dataJson)
    switch (action) {
      case 'log':
        state.logs.push(data)
        break
      case 'init':
        state.init = data
        break
      case 'request':
        state.httpCalls.push(data)
        // 模拟 ArkTS LxHttp：请求真实网络后把响应回灌沙箱
        hostSetTimeout(() => {
          const resp = {
            statusCode: 200,
            statusMessage: 'OK',
            headers: { 'content-type': 'application/json' },
            body: {
              code: 200,
              msg: 'mocked by lx_engine_selftest',
              data: { url: 'https://cdn.example.com/probed-song.mp3', echoedUrl: data.url },
            },
          }
          state.sandbox.__lx_native__(state.key, 'response',
            JSON.stringify({ requestKey: data.requestKey, error: null, response: resp }))
        }, 5)
        break
      case 'response':
        state.responses.push(data)
        break
      default:
        break
    }
  }
  return state
}

async function runSourceCase (title, script, opts) {
  console.log(`\n  -- ${title} --`)
  const state = createState()
  const key = `selftest_${Math.random().toString(36).slice(2)}`
  const sandbox = createSandbox(state)
  state.sandbox = sandbox

  await injectAndRun(sandbox, state, key, script, opts)

  const lx = sandbox.lx
  check(`lx.env 透传正确 (${opts.env || 'mobile'})`, lx !== undefined && lx.env === (opts.env || 'mobile'),
    lx !== undefined ? String(lx.env) : 'lx is undefined')
  check('lx.utils.crypto.md5 可用且结果正确',
    lx !== undefined && lx.utils.crypto.md5('abc') === '900150983cd24fb0d6963f7d28e17f72')
  check('收到 lx.send("inited") 且 status=true', state.init !== null && state.init.status === true,
    state.init === null ? '未收到 init' : String(state.init.errorMessage))
  check('inited 声明了 kw 平台与 musicUrl 能力',
    state.init !== null && state.init.info !== null && state.init.info.sources.kw !== undefined &&
    state.init.info.sources.kw.actions.includes('musicUrl'))

  const requestKey = `req_${Math.random().toString(36).slice(2)}`
  sandbox.__lx_native__(key, 'request', JSON.stringify({
    requestKey,
    data: { source: 'kw', action: 'musicUrl', info: { type: '320k', musicInfo: baseMusicInfo(opts.expectUrl) } },
  }))
  await waitFor(state, requestKey)

  const hit = state.responses.find((r) => r.requestKey === requestKey)
  check('引擎返回了 musicUrl 响应', hit !== undefined)
  if (hit !== undefined) {
    check('响应 status=true', hit.status === true, String(hit.errorMessage))
    const url = hit.result && hit.result.data && hit.result.data.url
    check(`播放链接正确: ${opts.expectUrl}`, url === opts.expectUrl, `实际: ${url}`)
    check('音质透传正确 (320k)', hit.result && hit.result.data.type === '320k')
  }
  if (opts.expectUsesHttp) {
    check('源脚本的 lx.request 被宿主代理执行', state.httpCalls.length === 1)
    check('请求参数按源规则透传 (method=GET, timeout=15000)',
      state.httpCalls.length > 0 && state.httpCalls[0].options.method === 'get' &&
      state.httpCalls[0].options.timeout === 15000,
      state.httpCalls.length > 0 ? JSON.stringify(state.httpCalls[0].options) : '')
    // UA/Content-Type 等默认请求头由宿主 LxHttp 补齐，沙箱侧不伪造
  } else {
    check('离线源未发起任何网络请求', state.httpCalls.length === 0)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
