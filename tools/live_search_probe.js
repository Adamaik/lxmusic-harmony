'use strict'
/**
 * 真机联网前的「活体」验证：用 Node 复刻 ArkTS 里的 5 个平台搜索请求，直接打真实接口，
 * 确认签名 / 请求体 / 端点是否仍然有效。
 *
 * 与 entry/src/main/ets/core/music/MusicSearch.ets 的对应关系（常量与键顺序必须一致）：
 *   kw: GET search.kuwo.cn/r.s
 *   kg: GET songsearch.kugou.com/song_search_v2
 *   mg: GET jadeite.migu.cn/... (+ md5 签名头)
 *   tx: POST u.y.qq.com/cgi-bin/musics.fcg?sign=<zzcSign>
 *   wy: POST interface.music.163.com/eapi/batch (eapi 参数)
 *
 * 运行： node tools/live_search_probe.js 晴天
 * 注意：本脚本依赖外网；若本机需要代理，请自行设置（Node 的 fetch 默认不走 HTTP_PROXY）。
 */

const crypto = require('crypto')

const md5Hex = (s) => crypto.createHash('md5').update(s, 'utf8').digest('hex')
const sha1Hex = (s) => crypto.createHash('sha1').update(s, 'utf8').digest('hex')
const b64 = (bytes) => Buffer.from(bytes).toString('base64')

// ---------------------------------------------------------------- tx
const TX_PART_1_INDEXES = [23, 14, 6, 36, 16, 40, 7, 19]
const TX_PART_2_INDEXES = [16, 1, 32, 12, 19, 27, 8, 5]
const TX_SCRAMBLE_VALUES = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
]
const TX_UA = 'QQMusic 14090508(android 12)'

function stripB64Chars (input) {
  let out = ''
  for (const c of input) {
    if (c === '\\' || c === '/' || c === '+' || c === '=') continue
    out += c
  }
  return out
}

function createZzcSign (text) {
  const hash = sha1Hex(text)
  let part1 = ''
  for (const idx of TX_PART_1_INDEXES) part1 += idx < hash.length ? hash.charAt(idx) : ''
  let part2 = ''
  for (const idx of TX_PART_2_INDEXES) part2 += idx < hash.length ? hash.charAt(idx) : ''
  const part3 = []
  for (let i = 0; i < TX_SCRAMBLE_VALUES.length; i++) {
    const byte = parseInt(hash.substring(i * 2, i * 2 + 2), 16)
    part3.push(TX_SCRAMBLE_VALUES[i] ^ byte)
  }
  return `zzc${part1}${stripB64Chars(b64(part3))}${part2}`.toLowerCase()
}

function createTxSearchId () {
  let guid = ''
  for (let i = 0; i < 32; i++) guid += Math.floor(Math.random() * 16).toString(16)
  return guid.toUpperCase() + String(Math.floor(Math.random() * 100000)).padStart(5, '0')
}

function createTxRequestBody (keyword, page, limit) {
  const comm = {
    _channelid: '0', _os_version: '6.2.9200-2', ct: '19', cv: '2151',
    guid: '1F70E520B2EAA7D25E11760783C53CA9', patch: '118',
    psrf_access_token_expiresAt: 0, psrf_qqaccess_token: '', psrf_qqopenid: '',
    psrf_qqunionid: '', tmeAppID: 'qqmusic', tmeLoginType: 0, uin: '0',
    wid: '7223299733393904640',
  }
  const param = {
    grp: 1, num_per_page: limit, page_num: page, query: keyword,
    remoteplace: 'txt.newclient.top', search_type: 0, searchid: createTxSearchId(),
  }
  const method = { module: 'music.search.SearchCgiService', method: 'DoSearchForQQMusicDesktop', param }
  return JSON.stringify({ comm, 'music.search.SearchCgiService': method })
}

// ---------------------------------------------------------------- wy
const WY_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36'
const WY_EAPI_KEY = 'e82ckenh8dichen8'

function aes128EcbPkcs7HexUpper (keyBytes, dataBytes) {
  const cipher = crypto.createCipheriv('aes-128-ecb', keyBytes, null)
  cipher.setAutoPadding(true)
  return Buffer.concat([cipher.update(dataBytes), cipher.final()]).toString('hex').toUpperCase()
}

function createEapiParams (path, dataJson) {
  const digest = md5Hex(`nobody${path}use${dataJson}md5forencrypt`)
  const payload = `${path}-36cd479b6b5-${dataJson}-36cd479b6b5-${digest}`
  return aes128EcbPkcs7HexUpper(Buffer.from(WY_EAPI_KEY, 'utf8'), Buffer.from(payload, 'utf8'))
}

// ---------------------------------------------------------------- mg
const MG_DEVICE_ID = '963B7AA0D21511ED807EE5846EC87D20'
const MG_SIGNATURE_MD5 = '6cdc72a439cef99a3418d2a78aa28c73'
const MG_SIGNATURE_SALT = 'yyapp2d16148780a1dcc7408e06336b98cfd50'
const createMgSignature = (keyword, time) =>
  md5Hex(`${keyword}${MG_SIGNATURE_MD5}${MG_SIGNATURE_SALT}${MG_DEVICE_ID}${time}`)

// ---------------------------------------------------------------- 请求
const LIMIT = 10
const PAGE = 1

async function show (name, fn) {
  try {
    const r = await fn()
    const mark = r.count > 0 ? 'OK ' : 'EMPTY'
    console.log(`[${mark}] ${name}: count=${r.count} ${r.sample || ''}`)
    if (r.raw) console.log(`        raw: ${r.raw}`)
  } catch (e) {
    console.log(`[ERR] ${name}: ${e.message}`)
  }
}

async function searchKw (str) {
  const url = `http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(str)}&pn=${PAGE - 1}&rn=${LIMIT}` +
    '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music' +
    '&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1'
  const resp = await fetch(url)
  const text = await resp.text()
  let body
  try { body = JSON.parse(text) } catch (e) { return { count: 0, raw: text.slice(0, 200) } }
  const list = body.abslist || []
  return {
    count: list.length,
    sample: list[0] ? `${list[0].SONGNAME} / ${list[0].ARTIST} / ${list[0].MUSICRID}` : '',
    raw: `TOTAL=${body.TOTAL} SHOW=${body.SHOW}`,
  }
}

async function searchKg (str) {
  const url = `https://songsearch.kugou.com/song_search_v2?keyword=${encodeURIComponent(str)}&page=${PAGE}&pagesize=${LIMIT}` +
    '&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1'
  const text = await (await fetch(url)).text()
  let body
  try { body = JSON.parse(text) } catch (e) { return { count: 0, raw: text.slice(0, 200) } }
  const lists = (body.data && body.data.lists) || []
  return {
    count: lists.length,
    sample: lists[0] ? `${lists[0].SongName} / ${lists[0].Audioid} / hash=${lists[0].FileHash}` : '',
    raw: `error_code=${body.error_code}`,
  }
}

async function searchMg (str) {
  const time = Date.now().toString()
  const url = 'https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1' +
    '&searchSwitch=%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1' +
    '%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D' +
    `&pageSize=${LIMIT}&text=${encodeURIComponent(str)}&pageNo=${PAGE}&sort=0&sid=USS`
  const text = await (await fetch(url, {
    headers: {
      uiVersion: 'A_music_3.6.1', deviceId: MG_DEVICE_ID, timestamp: time,
      sign: createMgSignature(str, time), channel: '0146921', 'User-Agent': 'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
    },
  })).text()
  let body
  try { body = JSON.parse(text) } catch (e) { return { count: 0, raw: text.slice(0, 200) } }
  const srd = body.songResultData || {}
  // resultList 是「数组的数组」（按分组聚簇）；ArkTS 的 parseMgResult 里是两层循环
  const flat = []
  for (const group of (srd.resultList || [])) for (const song of (group || [])) flat.push(song)
  return {
    count: flat.length,
    sample: flat[0] ? `${flat[0].name} / ${flat[0].songId} / cid=${flat[0].copyrightId} / fmts=${(flat[0].audioFormats || []).map((f) => f.formatType).join(',')}` : '',
    raw: `code=${body.code} info=${body.info} groups=${(srd.resultList || []).length}`,
  }
}

async function searchTx (str) {
  const bodyStr = createTxRequestBody(str, PAGE, LIMIT)
  const sign = createZzcSign(bodyStr)
  const url = `https://u.y.qq.com/cgi-bin/musics.fcg?sign=${sign}`
  const text = await (await fetch(url, {
    method: 'POST', headers: { 'User-Agent': TX_UA, 'Content-Type': 'application/json' }, body: bodyStr,
  })).text()
  let resp
  try { resp = JSON.parse(text) } catch (e) { return { count: 0, raw: text.slice(0, 200) } }
  const service = resp['music.search.SearchCgiService'] || {}
  const req = service.code !== undefined ? service : (resp.req || {})
  const song = (((req.data || {}).body) || {}).song || {}
  const list = song.list || []
  return {
    count: list.length,
    sample: list[0] ? `${list[0].title} / ${list[0].mid} / media=${((list[0].file || {}).media_mid)}` : '',
    raw: `code=${resp.code} svcCode=${service.code} reqCode=${req.code} sign=${sign}`,
  }
}

async function searchWy (str) {
  const path = '/api/search/song/list/page'
  const params = { keyword: str, needCorrect: '1', channel: 'typing', offset: LIMIT * (PAGE - 1), scene: 'normal', total: PAGE === 1, limit: LIMIT }
  const dataJson = JSON.stringify(params)
  const form = new URLSearchParams({ params: createEapiParams(path, dataJson) })
  const text = await (await fetch('http://interface.music.163.com/eapi/batch', {
    method: 'POST',
    headers: { 'User-Agent': WY_UA, origin: 'https://music.163.com', 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  })).text()
  let body
  try { body = JSON.parse(text) } catch (e) { return { count: 0, raw: text.slice(0, 200) } }
  const list = ((body.data || {}).resources) || []
  const first = list[0] ? ((list[0].baseInfo || {}).simpleSongData) : null
  return {
    count: list.length,
    sample: first ? `${first.name} / ${first.id} / privilege.maxbr=${((first.privilege || {}).maxbr)}` : '',
    raw: `code=${body.code} msg=${body.message || body.msg}`,
  }
}

async function main () {
  const kw = process.argv[2] || '晴天'
  console.log(`关键词：${kw}\n`)
  await show('kw 酷我', () => searchKw(kw))
  await show('kg 酷狗', () => searchKg(kw))
  await show('mg 咪咕', () => searchMg(kw))
  await show('tx QQ ', () => searchTx(kw))
  await show('wy 网易', () => searchWy(kw))
}

main().catch((e) => { console.error(e); process.exit(1) })
