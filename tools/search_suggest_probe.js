'use strict'
/**
 * 搜索联想词 / 热门搜索的活体验证（无设备）
 *
 * entry/src/main/ets/core/music/MusicSuggest.ets 里的取词逻辑跑不了（ArkTS），
 * 这里把同一套 URL、请求头与字段路径照原样复刻一遍，直接打真实接口，确认：
 *
 *   1. 每个平台的联想词还能取到（打「晴天」应能看到不同歌手 / 不同版本的写法）；
 *   2. 每个平台的热搜词还能取到；
 *   3. 合并去重的结果与 App 里会显示的一行行一致。
 *
 * 与 live_search_probe.js（搜索本身的接口）配套：那个管「搜得到」，这个管「联想得到」。
 *
 * 运行： node tools/search_suggest_probe.js [关键词]        （默认 晴天）
 * 注意：本脚本依赖外网；需要代理请自行设置（Node 的 fetch 默认不走 HTTP_PROXY）。
 */

const KEYWORD = process.argv[2] || '晴天'

// 与 MusicSuggest.ets 里的上限保持一致
const PER_PLATFORM_SUGGEST = 6
const MAX_SUGGEST = 12
const PER_PLATFORM_HOT = 4
const MAX_HOT = 12

const KW_UA = 'Dalvik/2.1.0 (Linux; U; Android 9;)'

let failed = 0
function check (label, ok, detail) {
  console.log(`${ok ? '  ok  ' : ' FAIL '} ${label}${detail === undefined ? '' : ` -> ${detail}`}`)
  if (!ok) failed++
}

// ---------------------------------------------------------------- 与 .ets 同一套取词

function pushWord (out, seen, word, limit) {
  if (out.length >= limit) return
  const trimmed = typeof word === 'string' ? word.trim() : ''
  if (trimmed.length === 0) return
  const key = wordKey(trimmed)
  if (seen.has(key)) return
  seen.add(key)
  out.push(trimmed)
}

/** 去重键：忽略空格、连字符与大小写（「夜曲 DJ」与「夜曲-dj」是同一个词） */
function wordKey (word) {
  return word.replace(/[\s\-—–/／]/g, '').toLowerCase()
}

/** 各平台轮流取一条（与 MusicSuggest.mergeLists 同一套） */
function mergeLists (lists, limit) {
  const out = []
  const seen = new Set()
  let depth = 0
  let more = true
  while (more && out.length < limit) {
    more = false
    for (const list of lists) {
      if (depth >= list.length) continue
      more = true
      pushWord(out, seen, list[depth], limit)
    }
    depth++
  }
  return out
}

async function getJson (url, headers) {
  const res = await fetch(url, { headers })
  const text = await res.text()
  return JSON.parse(text)
}

async function suggestKw (str) {
  const url = 'https://tips.kuwo.cn/t.s?corp=kuwo&newver=3&p2p=1&notrace=0&c=mbox' +
    `&w=${encodeURIComponent(str)}&encoding=utf8&rformat=json`
  const body = await getJson(url, { Referer: 'http://www.kuwo.cn/' })
  const out = []
  const seen = new Set()
  for (const raw of (body.WORDITEMS || [])) pushWord(out, seen, raw.RELWORD, PER_PLATFORM_SUGGEST)
  return out
}

async function hotKw () {
  const url = 'http://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo&newver=2' +
    '&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1&notrace=0&uid=0' +
    '&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1'
  const body = await getJson(url, { 'User-Agent': KW_UA })
  const out = []
  const seen = new Set()
  for (const raw of (body.tagvalue || [])) pushWord(out, seen, raw.key, PER_PLATFORM_HOT)
  return out
}

async function suggestKg (str) {
  const url = `https://searchtip.kugou.com/getSearchTip?MusicTipCount=${PER_PLATFORM_SUGGEST}` +
    `&keyword=${encodeURIComponent(str)}`
  const body = await getJson(url, { referer: 'https://www.kugou.com/' })
  // { status, data: [{ RecordDatas: [{ HintInfo }] }] }
  const out = []
  const seen = new Set()
  const groups = body && Array.isArray(body.data) ? body.data : []
  if (groups.length > 0) {
    for (const raw of (groups[0].RecordDatas || [])) pushWord(out, seen, raw.HintInfo, PER_PLATFORM_SUGGEST)
  }
  return out
}

async function hotKg () {
  const url = 'http://gateway.kugou.com/api/v3/search/hot_tab?signature=ee44edb9d7155821412d220bcaf509dd' +
    '&appid=1005&clientver=10026&plat=0'
  const body = await getJson(url, {
    dfid: '1ssiv93oVqMp27cirf2CvoF1',
    mid: '156798703528610303473757548878786007104',
    clienttime: '1584257267',
    'x-router': 'msearch.kugou.com',
    'user-agent': 'Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi',
    'kg-rc': '1',
  })
  const out = []
  const seen = new Set()
  for (const group of (((body.data || {}).list) || [])) {
    for (const raw of (group.keywords || [])) {
      pushWord(out, seen, raw.keyword, PER_PLATFORM_HOT)
      if (out.length >= PER_PLATFORM_HOT) break
    }
    if (out.length >= PER_PLATFORM_HOT) break
  }
  return out
}

async function suggestTx (str) {
  const url = 'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json' +
    `&key=${encodeURIComponent(str)}&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8` +
    '&notice=0&platform=yqq&needNewCode=0'
  const body = await getJson(url, { Referer: 'https://y.qq.com/portal/player.html' })
  if (String(body.code) !== '0') throw new Error(`code ${body.code}`)
  const out = []
  const seen = new Set()
  for (const item of (((body.data || {}).song || {}).itemlist || [])) {
    const name = String(item.name == null ? '' : item.name)
    const singer = String(item.singer == null ? '' : item.singer)
    pushWord(out, seen, singer.length > 0 ? `${name} - ${singer}` : name, PER_PLATFORM_SUGGEST)
  }
  return out
}

async function hotTx () {
  const body = {
    comm: {
      ct: '19', cv: '1803', guid: '0', patch: '118',
      psrf_access_token_expiresAt: 0, psrf_qqaccess_token: '', psrf_qqopenid: '',
      psrf_qqunionid: '', tmeAppID: 'qqmusic', tmeLoginType: 0, uin: '0', wid: '0',
    },
    hotkey: {
      method: 'GetHotkeyForQQMusicPC',
      module: 'tencent_musicsoso_hotkey.HotkeyService',
      param: { search_id: '', uin: 0 },
    },
  }
  const res = await fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST',
    headers: { Referer: 'https://y.qq.com/portal/player.html', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const resp = JSON.parse(await res.text())
  if (String(resp.code) !== '0') throw new Error(`code ${resp.code}`)
  const out = []
  const seen = new Set()
  for (const raw of (((resp.hotkey || {}).data || {}).vec_hotkey || [])) {
    pushWord(out, seen, raw.query, PER_PLATFORM_HOT)
  }
  return out
}

// ---------------------------------------------------------------- 跑

async function collect (label, task, limit, perPlatform) {
  try {
    const list = await task
    check(label, list.length > 0, `${list.length} 条：${list.join(' | ')}`)
    if (list.length > perPlatform) {
      check(`${label} 不超过每平台上限`, false, `${list.length} > ${perPlatform}`)
    }
    if (list.length > limit) {
      check(`${label} 不超过总数上限`, false, `${list.length} > ${limit}`)
    }
    return list
  } catch (e) {
    check(label, false, e.message)
    return []
  }
}

async function main () {
  console.log(`关键词「${KEYWORD}」\n`)

  console.log('1) 联想词（各平台）：')
  const kw = await collect('酷我联想', suggestKw(KEYWORD), MAX_SUGGEST, PER_PLATFORM_SUGGEST)
  const kg = await collect('酷狗联想', suggestKg(KEYWORD), MAX_SUGGEST, PER_PLATFORM_SUGGEST)
  const tx = await collect('QQ联想', suggestTx(KEYWORD), MAX_SUGGEST, PER_PLATFORM_SUGGEST)

  console.log('\n2) 合并去重后（App 里就是这样一行行显示）：')
  const out = mergeLists([kw, kg, tx], MAX_SUGGEST)
  check('合并后还有内容', out.length > 0, `${out.length} 条`)
  for (const w of out) console.log(`     ${w}`)

  const versions = out.filter((w) => / - |伴奏|live|现场|版|dj|remix/i.test(w))
  check('能看到「不同歌手 / 不同版本」的写法', versions.length > 0,
    `${versions.length} 条，例如 ${versions.slice(0, 3).join(' / ')}`)
  check('「歌名 - 歌手」没有被挤到列表末尾', out.slice(0, 6).some((w) => w.includes(' - ')),
    `前 6 条里 ${out.slice(0, 6).filter((w) => w.includes(' - ')).length} 条是「歌名 - 歌手」`)

  console.log('\n3) 热门搜索（各平台）：')
  const hotKwList = await collect('酷我热搜', hotKw(), MAX_HOT, PER_PLATFORM_HOT)
  const hotKgList = await collect('酷狗热搜', hotKg(), MAX_HOT, PER_PLATFORM_HOT)
  const hotTxList = await collect('QQ热搜', hotTx(), MAX_HOT, PER_PLATFORM_HOT)

  console.log('\n4) 热搜合并去重后：')
  const hots = mergeLists([hotKwList, hotKgList, hotTxList], MAX_HOT)
  check('热搜合并后还有内容', hots.length > 0, `${hots.length} 条`)
  for (const w of hots) console.log(`     ${w}`)

  console.log(`\n${failed === 0 ? '全部通过' : `${failed} 项失败`}`)
  process.exitCode = failed === 0 ? 0 : 1
}

main().catch((e) => { console.error(e); process.exitCode = 1 })
