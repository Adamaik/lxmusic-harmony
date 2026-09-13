'use strict';

/**
 * 洛雪音乐自定义音源执行引擎（HarmonyOS / ArkWeb 移植版）
 *
 * 移植自 lx-music-mobile:
 *   android/app/src/main/assets/script/user-api-preload.js
 *
 * 原版运行在 QuickJS 沙箱内，由原生注入 __lx_native_call__* 同步函数；
 * 本移植版运行在 ArkWeb 沙箱内，差异只有两点：
 *   1) 同步工具函数（md5/base64/aes/rsa/buffer）改由 lx_utils.js 纯 JS 实现；
 *   2) 与原生交互的 nativeCall 改走 javaScriptProxy 注入的 lxBridge.postMessage。
 *
 * 与原生侧（ArkTS SourceEngine）的契约：
 *   注入前设置 window.__lx_bootstrap__ = { key, rawScript, meta:{name,...} }（注入后即删除）
 *   ArkTS -> JS: window.__lx_native__(key, action, dataJson)
 *   JS -> ArkTS: lxBridge.postMessage(action, dataJson)
 */
(function (global) {
  const U = global.LXPureUtils
  const BRIDGE = global.lxBridge
  const hostSetTimeout = global.setTimeout.bind(global)
  const hostClearTimeout = global.clearTimeout.bind(global)

  if (!U) throw new Error('LXPureUtils is not loaded')
  if (!BRIDGE) throw new Error('lxBridge is not injected')

  const BOOT = global.__lx_bootstrap__
  if (!BOOT) throw new Error('__lx_bootstrap__ is missing')
  try { delete global.__lx_bootstrap__ } catch (e) { /* ignore */ }

  const key = BOOT.key
  const meta = BOOT.meta || {}
  const name = meta.name || 'Unknown'
  const rawScript = BOOT.rawScript || ''
  const sandboxEnv = BOOT.env || 'mobile'

  // 沙箱内的异步错误（Promise 未捕获、运行时异常）统一回报宿主，
  // 否则脚本里 inited 之前抛错只会表现为「初始化超时」，无从排查。
  const reportError = (message) => {
    try {
      BRIDGE.postMessage('scriptError', JSON.stringify({ message: String(message).substring(0, 2000) }))
    } catch (e) { /* ignore */ }
  }
  if (typeof global.addEventListener === 'function') {
    global.addEventListener('error', (event) => {
      reportError(event && event.message ? event.message : 'unknown error')
    })
    global.addEventListener('unhandledrejection', (event) => {
      const reason = event ? event.reason : null
      reportError(reason && reason.message ? reason.message : String(reason))
    })
  }

  const checkLength = (str, length = 1048576) => {
    if (typeof str === 'string' && str.length > length) throw new Error('Input too long')
    return str
  }

  const nativeCall = (action, data) => {
    const json = JSON.stringify(data)
    checkLength(json, 2097152)
    BRIDGE.postMessage(String(action), json)
  }

  // ------------------------------------------------------------------ console -> native log
  // 引擎会在同一个页面里被重复注入（换源时页面内重置），所以原始 console 只捕获一次，
  // 否则每次注入都会再包一层，日志会成倍重复。
  const rawConsole = global.__lx_raw_console__ || global.console || {}
  global.__lx_raw_console__ = rawConsole
  const forwardLog = (type, args) => {
    try {
      const text = args.map(a => {
        if (typeof a === 'string') return a
        try { return JSON.stringify(a) } catch (e) { return String(a) }
      }).join(' ')
      BRIDGE.postMessage('log', JSON.stringify({ type, log: text.substring(0, 4096) }))
    } catch (e) { /* ignore */ }
  }
  global.console = {
    log: (...args) => { if (rawConsole.log) rawConsole.log(...args); forwardLog('log', args) },
    info: (...args) => { if (rawConsole.info) rawConsole.info(...args); forwardLog('info', args) },
    warn: (...args) => { if (rawConsole.warn) rawConsole.warn(...args); forwardLog('warn', args) },
    error: (...args) => { if (rawConsole.error) rawConsole.error(...args); forwardLog('error', args) },
    debug: (...args) => { if (rawConsole.debug) rawConsole.debug(...args); forwardLog('log', args) },
  }

  // ------------------------------------------------------------------ 计时器
  const callbacks = new Map()
  const callbackTimers = new Map()
  let timeoutId = 0
  const _setTimeout = (callback, timeout = 0, ...params) => {
    if (typeof callback !== 'function') throw new Error('callback required a function')
    if (typeof timeout !== 'number' || timeout < 0) throw new Error('timeout required a number')
    if (timeoutId > 90000000000) throw new Error('max timeout')
    const id = timeoutId++
    callbacks.set(id, { callback, params })
    callbackTimers.set(id, hostSetTimeout(() => handleSetTimeout(id), parseInt(timeout)))
    return id
  }
  const _clearTimeout = (id) => {
    callbacks.delete(id)
    const timer = callbackTimers.get(id)
    if (timer !== undefined) {
      hostClearTimeout(timer)
      callbackTimers.delete(id)
    }
  }
  const handleSetTimeout = (id) => {
    const target = callbacks.get(id)
    callbackTimers.delete(id)
    if (!target) return
    callbacks.delete(id)
    target.callback(...target.params)
  }

  // ------------------------------------------------------------------ 自检状态
  // 给宿主用来判断「脚本到底跑到哪一步」：没注册 handler / 没 send('inited') /
  // 发起了多少次 lx.request。脚本执行失败被 ArkWeb 静默吞掉时，这是唯一的线索。
  const sendCalls = []
  let requestCount = 0
  global.__lx_debug_state__ = () => JSON.stringify({
    hasHandler: events.request !== null,
    inited: isInitedApi,
    sendCalls: sendCalls,
    requestCount: requestCount,
    scriptLength: rawScript.length,
    env: sandboxEnv,
    version: '2.0.0',
  })

  // ------------------------------------------------------------------ 事件名
  const NATIVE_EVENTS_NAMES = {
    init: 'init',
    showUpdateAlert: 'showUpdateAlert',
    request: 'request',
    cancelRequest: 'cancelRequest',
    response: 'response',
  }
  const EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
  }
  const eventNames = Object.values(EVENT_NAMES)
  const events = { request: null }

  const allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local']
  const supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: [],
  }
  // 官方 preload 只给平台源 musicUrl，等于把源自带的 lyric/pic 能力过滤掉了
  // （洛雪自己不用源的歌词，它走内置平台 SDK）。本工程把源当作「能给就给」的一路：
  // 源声明了 lyric/pic 就允许透传，拿不到再由宿主的内置平台歌词 / 封面接口兜底。
  const supportActions = {
    kw: ['musicUrl', 'lyric', 'pic'],
    kg: ['musicUrl', 'lyric', 'pic'],
    tx: ['musicUrl', 'lyric', 'pic'],
    wy: ['musicUrl', 'lyric', 'pic'],
    mg: ['musicUrl', 'lyric', 'pic'],
    xm: ['musicUrl', 'lyric', 'pic'],
    local: ['musicUrl', 'lyric', 'pic'],
  }

  const verifyLyricInfo = (info) => {
    if (typeof info !== 'object' || info === null || typeof info.lyric !== 'string') throw new Error('failed')
    if (info.lyric.length > 51200) throw new Error('failed')
    return {
      lyric: info.lyric,
      tlyric: (typeof info.tlyric === 'string' && info.tlyric.length < 5120) ? info.tlyric : null,
      rlyric: (typeof info.rlyric === 'string' && info.rlyric.length < 5120) ? info.rlyric : null,
      lxlyric: (typeof info.lxlyric === 'string' && info.lxlyric.length < 8192) ? info.lxlyric : null,
    }
  }

  // ------------------------------------------------------------------ 网络请求
  const requestQueue = new Map()
  let isInitedApi = false
  let isShowedUpdateAlert = false

  const sendNativeRequest = (url, options, callback) => {
    const requestKey = Math.random().toString()
    const requestInfo = {
      aborted: false,
      abort: () => {
        nativeCall(NATIVE_EVENTS_NAMES.cancelRequest, requestKey)
      },
    }
    requestQueue.set(requestKey, { callback, requestInfo })
    nativeCall(NATIVE_EVENTS_NAMES.request, { requestKey, url, options })
    return requestInfo
  }
  const handleNativeResponse = ({ requestKey, error, response }) => {
    const targetRequest = requestQueue.get(requestKey)
    if (!targetRequest) return
    requestQueue.delete(requestKey)
    targetRequest.requestInfo.aborted = true
    if (error == null) targetRequest.callback(null, response)
    else targetRequest.callback(new Error(error), null)
  }

  const handleRequest = ({ requestKey, data }) => {
    if (!events.request) {
      nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: false, errorMessage: 'Request event is not defined' })
      return
    }
    try {
      // 源脚本注册的 request 处理器返回 Promise<string|object>
      Promise.resolve(events.request.call(global.lx, {
        source: data.source,
        action: data.action,
        info: data.info,
      })).then(response => {
        let result
        switch (data.action) {
          case 'musicUrl':
            if (typeof response !== 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
            result = {
              source: data.source,
              action: data.action,
              data: { type: data.info.type, url: response },
            }
            break
          case 'lyric':
            result = { source: data.source, action: data.action, data: verifyLyricInfo(response) }
            break
          case 'pic':
            if (typeof response !== 'string' || response.length > 2048 || !/^https?:/.test(response)) throw new Error('failed')
            result = { source: data.source, action: data.action, data: response }
            break
          default:
            throw new Error('The action is not supported: ' + data.action)
        }
        nativeCall(NATIVE_EVENTS_NAMES.response, { requestKey, status: true, result })
      }).catch(err => {
        nativeCall(NATIVE_EVENTS_NAMES.response, {
          requestKey,
          status: false,
          errorMessage: err && err.message ? err.message : String(err),
        })
      })
    } catch (err) {
      nativeCall(NATIVE_EVENTS_NAMES.response, {
        requestKey,
        status: false,
        errorMessage: err && err.message ? err.message : String(err),
      })
    }
  }

  const jsCall = (action, data) => {
    switch (action) {
      case '__run_error__':
        if (!isInitedApi) isInitedApi = true
        return
      case '__set_timeout__':
        handleSetTimeout(data)
        return
      case 'request':
        handleRequest(data)
        return
      case 'response':
        handleNativeResponse(data)
        return
      default:
        return 'Unknown action: ' + action
    }
  }

  Object.defineProperty(global, '__lx_native__', {
    enumerable: false,
    configurable: true,
    writable: true,
    value: (_key, action, data) => {
      if (key !== _key) return 'Invalid key'
      return data == null ? jsCall(action) : jsCall(action, JSON.parse(data))
    },
  })

  // ------------------------------------------------------------------ init
  const handleInit = (info) => {
    if (!info) {
      nativeCall(NATIVE_EVENTS_NAMES.init, { info: null, status: false, errorMessage: 'Missing required parameter init info' })
      return
    }
    const sourceInfo = { sources: {} }
    try {
      for (const source of allSources) {
        const userSource = info.sources[source]
        if (!userSource || userSource.type !== 'music') continue
        const qualitys = supportQualitys[source]
        const actions = supportActions[source]
        sourceInfo.sources[source] = {
          type: 'music',
          actions: actions.filter(a => userSource.actions.includes(a)),
          qualitys: qualitys.filter(q => userSource.qualitys.includes(q)),
        }
      }
    } catch (error) {
      nativeCall(NATIVE_EVENTS_NAMES.init, { info: null, status: false, errorMessage: error.message })
      return
    }
    nativeCall(NATIVE_EVENTS_NAMES.init, { info: sourceInfo, status: true })
  }

  const handleShowUpdateAlert = (data, resolve, reject) => {
    if (!data || typeof data !== 'object') return reject(new Error('parameter format error.'))
    if (!data.log || typeof data.log !== 'string') return reject(new Error('log is required.'))
    if (data.updateUrl && !/^https?:\/\/[^\s$.?#].[^\s]*$/.test(data.updateUrl) && data.updateUrl.length > 1024) delete data.updateUrl
    if (data.log.length > 1024) data.log = data.log.substring(0, 1024) + '...'
    nativeCall(NATIVE_EVENTS_NAMES.showUpdateAlert, { log: data.log, updateUrl: data.updateUrl, name })
    resolve()
  }

  // ------------------------------------------------------------------ utils
  const dataToB64 = (data) => {
    if (typeof data === 'string') return U.str2b64(data)
    if (Array.isArray(data) || ArrayBuffer.isView(data)) return U.str2b64(U.bytesToString(Array.from(data)))
    throw new Error('data type error: ' + typeof data + ' raw data: ' + data)
  }

  const utils = {
    crypto: {
      aesEncrypt (buffer, mode, key, iv) {
        switch (mode) {
          case 'aes-128-cbc':
            return utils.buffer.from(U.aesEncryptB64(dataToB64(buffer), dataToB64(key), dataToB64(iv), 'CBC_PKCS7'), 'base64')
          case 'aes-128-ecb':
            return utils.buffer.from(U.aesEncryptB64(dataToB64(buffer), dataToB64(key), '', 'ECB_PKCS7'), 'base64')
          default:
            throw new Error('Binary encoding is not supported for input strings')
        }
      },
      rsaEncrypt (buffer, keyStr) {
        if (typeof keyStr !== 'string') throw new Error('Invalid RSA key')
        const cleaned = keyStr
          .replace('-----BEGIN PUBLIC KEY-----', '')
          .replace('-----END PUBLIC KEY-----', '')
        return utils.buffer.from(U.rsaEncryptB64(dataToB64(buffer), cleaned), 'base64')
      },
      randomBytes (size) {
        const byteArray = new Uint8Array(size)
        for (let i = 0; i < size; i++) byteArray[i] = Math.floor(Math.random() * 256)
        return byteArray
      },
      md5 (str) {
        if (typeof str !== 'string') throw new Error('param required a string')
        return U.str2md5(str)
      },
    },
    buffer: {
      from (input, encoding) {
        if (typeof input === 'string') {
          switch (encoding) {
            case 'binary':
              throw new Error('Binary encoding is not supported for input strings')
            case 'base64':
              return new Uint8Array(U.b642buf(input))
            case 'hex':
              return new Uint8Array(input.match(/.{1,2}/g).map(byte => parseInt(byte, 16)))
            default:
              return new Uint8Array(U.stringToBytes(input))
          }
        } else if (Array.isArray(input)) {
          return new Uint8Array(input)
        }
        throw new Error('Unsupported input type: ' + input + ' encoding: ' + encoding)
      },
      bufToString (buf, format) {
        if (Array.isArray(buf) || ArrayBuffer.isView(buf)) {
          const bytes = Array.from(buf)
          switch (format) {
            case 'binary':
              return bytes
            case 'hex':
              return bytes.reduce((str, byte) => str + byte.toString(16).padStart(2, '0'), '')
            case 'base64':
              return U.str2b64(U.bytesToString(bytes))
            case 'utf8':
            case 'utf-8':
            default:
              return U.bytesToString(bytes)
          }
        }
        throw new Error('Input is not a valid buffer: ' + buf + ' format: ' + format)
      },
    },
  }

  // ------------------------------------------------------------------ 沙箱加固
  // 移除脚本可直接使用的原生网络/存储能力，强制网络访问走 lx.request（由 ArkTS 代理）
  const FORBIDDEN_GLOBALS = ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'Worker', 'SharedWorker', 'indexedDB', 'localStorage', 'sessionStorage']
  for (const gname of FORBIDDEN_GLOBALS) {
    try {
      Object.defineProperty(global, gname, { value: undefined, writable: false, configurable: false })
    } catch (e) { /* ignore */ }
  }
  try { global.eval = function () { throw new Error('eval is not available') } } catch (e) { /* ignore */ }

  // ------------------------------------------------------------------ lx 对象
  global.lx = {
    EVENT_NAMES,
    request (url, { method = 'get', timeout, headers, body, form, formData, binary }, callback) {
      requestCount++
      const options = { headers, binary: binary === true }
      if (timeout && typeof timeout === 'number' && timeout > 0) options.timeout = Math.min(timeout, 60000)
      let request = sendNativeRequest(url, { method, body, form, formData, ...options }, (err, resp) => {
        if (err) {
          callback(err, null, null)
        } else {
          callback(err, {
            statusCode: resp.statusCode,
            statusMessage: resp.statusMessage,
            headers: resp.headers,
            body: resp.body,
          }, resp.body)
        }
      })
      return () => {
        if (!request.aborted) request.abort()
        request = null
      }
    },
    send (eventName, data) {
      if (sendCalls.length < 50) sendCalls.push(String(eventName))
      return new Promise((resolve, reject) => {
        if (!eventNames.includes(eventName)) return reject(new Error('The event is not supported: ' + eventName))
        switch (eventName) {
          case EVENT_NAMES.inited:
            if (isInitedApi) return reject(new Error('Script is inited'))
            isInitedApi = true
            handleInit(data)
            resolve()
            break
          case EVENT_NAMES.updateAlert:
            if (isShowedUpdateAlert) return reject(new Error('The update alert can only be called once.'))
            isShowedUpdateAlert = true
            handleShowUpdateAlert(data, resolve, reject)
            break
          default:
            reject(new Error('Unknown event name: ' + eventName))
        }
      })
    },
    on (eventName, handler) {
      if (!eventNames.includes(eventName)) return Promise.reject(new Error('The event is not supported: ' + eventName))
      switch (eventName) {
        case EVENT_NAMES.request:
          events.request = handler
          break
        default:
          return Promise.reject(new Error('The event is not supported: ' + eventName))
      }
      return Promise.resolve()
    },
    utils,
    currentScriptInfo: {
      name,
      description: meta.description || '',
      version: meta.version || '',
      author: meta.author || '',
      homepage: meta.homepage || '',
      rawScript,
    },
    version: '2.0.0',
    env: sandboxEnv,
  }

  global.setTimeout = _setTimeout
  global.clearTimeout = _clearTimeout

  const freezeObject = (obj) => {
    if (typeof obj !== 'object' || obj === null) return
    try { Object.freeze(obj) } catch (e) { return }
    for (const subObj of Object.values(obj)) freezeObject(subObj)
  }
  try { freezeObject(global.lx) } catch (e) { /* ignore */ }

  global.__lx_destroy__ = () => {
    requestQueue.clear()
    callbacks.clear()
    for (const timer of callbackTimers.values()) hostClearTimeout(timer)
    callbackTimers.clear()
    events.request = null
  }

  console.log('Preload finished.')
})(typeof globalThis !== 'undefined' ? globalThis : this)
