'use strict'
/**
 * 音源沙箱「音质白名单」自检：把 lx_preload.js + lx_utils.js 在一个假沙箱里跑起来，
 * 模拟一份音源声明（8 档音质），看 init 回调里还剩几档。
 *
 * 为什么需要它：handleInit 会拿「宿主能力白名单」与「音源声明的 qualitys」取交集，
 * 早先白名单只有 128k/320k/flac/flac24bit，音源即使声明了拓展档也会被整段过滤掉，
 * 表现为「设置里开了拓展音质，播放页永远没有拓展档可选」（见 docs/DEFECTS.md D-013）。
 *
 * 运行：node tools/preload_quality_probe.js
 */
const fs = require('fs')
const vm = require('vm')
const path = require('path')

const DIR = path.join(__dirname, '..', 'entry', 'src', 'main', 'resources', 'rawfile')
const MAIN = ['128k', '320k', 'flac', 'flac24bit']
const EXTEND = ['hires', 'atmos', 'atmos_plus', 'master']
const DECLARED = MAIN.concat(EXTEND)

const sandbox = { console }
sandbox.globalThis = sandbox
sandbox.setTimeout = setTimeout
sandbox.clearTimeout = clearTimeout
vm.createContext(sandbox)
vm.runInContext(fs.readFileSync(path.join(DIR, 'lx_utils.js'), 'utf8'), sandbox, { filename: 'lx_utils.js' })

let initPayload = null
sandbox.lxBridge = {
  postMessage: (action, json) => {
    if (action === 'init') initPayload = JSON.parse(json)
  },
}
sandbox.__lx_bootstrap__ = { key: 'probe', rawScript: '// probe', meta: { name: 'quality-probe' }, env: 'mobile' }
vm.runInContext(fs.readFileSync(path.join(DIR, 'lx_preload.js'), 'utf8'), sandbox, { filename: 'lx_preload.js' })

sandbox.lx.send('inited', {
  sources: {
    wy: { type: 'music', actions: ['musicUrl', 'lyric', 'pic'], qualitys: DECLARED },
    kw: { type: 'music', actions: ['musicUrl', 'lyric', 'pic'], qualitys: DECLARED },
    local: { type: 'music', actions: ['musicUrl'], qualitys: DECLARED },
  },
})

if (!initPayload) {
  console.error('❌ 没有拿到 init 回调（preload 初始化失败）')
  process.exit(1)
}

let bad = 0
console.log('status=' + initPayload.status)
const sources = initPayload.info ? (initPayload.info.sources || {}) : {}
for (const source of Object.keys(sources)) {
  const info = sources[source]
  console.log('  ' + source + '  actions=' + JSON.stringify(info.actions) + '  qualitys=' + JSON.stringify(info.qualitys))
  if (source === 'local') continue
  const missing = DECLARED.filter(q => !info.qualitys.includes(q))
  if (missing.length > 0) {
    bad++
    console.log('     ❌ 被白名单过滤掉：' + missing.join(','))
  }
}
const wy = (sources.wy && sources.wy.qualitys) || []
const keepExtend = EXTEND.every(q => wy.includes(q))
console.log(keepExtend ? '✅ 拓展档全部保留' : '❌ 拓展档被过滤（这就是「开了拓展音质也没有拓展档」的原因）')
process.exit(bad === 0 && keepExtend ? 0 : 1)
