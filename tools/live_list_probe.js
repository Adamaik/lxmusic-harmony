'use strict'
/**
 * 「导入歌单」链路的活体验证：用 Node 复刻 ArkTS 里的 5 个平台歌单请求，直接打真实接口。
 *
 * 与 entry/src/main/ets/core/music/MusicList.ets 的对应关系（URL / 请求头 / 判定字段必须一致）：
 *   kw: GET  nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=<id>
 *   kg: GET  www2.kugou.kugou.com/yueku/v9/special/single/<id>-5-9999.html（页面里的 global.data）
 *   mg: GET  app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?playlistId=<id>（+ 咪咕头）
 *   tx: GET  c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?disstid=<id>（+ Origin/Referer）
 *   wy: GET  music.163.com/api/v6/playlist/detail?id=<id>（+ 网易头）
 *
 * 每个平台先走一遍「歌单广场/推荐」，从里面取一张真实存在的歌单 id，再用这张 id 走详情接口 ——
 * 这样不需要事先知道任何 id，也能验证「解析链接 -> 取歌单歌曲」这一条链路真的通。
 *
 * 运行：
 *   node tools/live_list_probe.js             # 全部平台，各 1 轮
 *   node tools/live_list_probe.js kw wy       # 只跑指定平台
 *   node tools/live_list_probe.js --detail kw 2892110024   # 指定 id 直接验详情接口
 * 注意：本脚本依赖外网；若本机需要代理，请自行设置（Node 的 fetch 默认不走 HTTP_PROXY）。
 */

const UA_PC = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/69.0.3497.100 Safari/537.36'
const UA_IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1'
const UA_LINUX = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/60.0.3112.90 Safari/537.36'

const MG_HEADERS = { 'User-Agent': UA_IPHONE, 'Referer': 'https://m.music.migu.cn/' }
const WY_HEADERS = {
  'User-Agent': UA_LINUX,
  'Referer': 'https://music.163.com/',
  'Origin': 'https://music.163.com',
}
const TX_MUSICU = 'https://u.y.qq.com/cgi-bin/musicu.fcg' +
  '?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0' +
  '&platform=wk_v15.json&needNewCode=0'

const KW_SORTS = [{ name: '最新', id: 'new' }, { name: '最热', id: 'hot' }]

function short (text, n = 40) {
  const s = String(text ?? '')
  return s.length > n ? s.slice(0, n) + '…' : s
}

async function get (url, headers) {
  const res = await fetch(url, { headers: Object.assign({ 'User-Agent': UA_PC }, headers) })
  const text = await res.text()
  return { status: res.status, url: res.url, text }
}

async function postForm (url, form, headers) {
  const body = new URLSearchParams(form).toString()
  const res = await fetch(url, {
    method: 'POST',
    headers: Object.assign({
      'User-Agent': UA_PC,
      'Content-Type': 'application/x-www-form-urlencoded',
    }, headers),
    body,
  })
  const text = await res.text()
  return { status: res.status, url: res.url, text }
}

function jsonOf (text, label) {
  try {
    return JSON.parse(text)
  } catch (e) {
    throw new Error(`${label}: 响应不是 JSON（${short(text, 80)}）`)
  }
}

// ---------------------------------------------------------------- 歌单广场：拿一张真实歌单 id

async function kwFirstPlaylistId () {
  const url = 'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList' +
    `?loginUid=0&loginSid=0&appUid=76039576&pn=1&rn=36&order=${encodeURIComponent(KW_SORTS[1].id)}`
  const body = jsonOf((await get(url)).text, 'kw 歌单广场')
  if (Number(body.code) !== 200) throw new Error(`kw 歌单广场返回 code=${body.code}`)
  const list = body?.data?.data ?? []
  if (!list.length) throw new Error('kw 歌单广场没有返回歌单')
  return { id: String(list[0].id), name: list[0].name }
}

async function kgFirstPlaylistId () {
  const url = 'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=5&c=&p=1'
  const body = jsonOf((await get(url)).text, 'kg 歌单广场')
  if (Number(body.status) !== 1) throw new Error(`kg 歌单广场返回 status=${body.status}`)
  const list = body.special_db ?? []
  if (!list.length) throw new Error('kg 歌单广场没有返回歌单')
  return { id: String(list[0].specialid), name: list[0].specialname }
}

async function mgFirstPlaylistId () {
  const url = 'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0' +
    '?templateVersion=2&pageNo=1'
  const body = jsonOf((await get(url, MG_HEADERS)).text, 'mg 歌单广场')
  if (String(body.code) !== '000000') throw new Error(`mg 歌单广场返回 code=${body.code}`)
  // 广场响应是递归的排版节点（contents 里还套 contents），歌单 id 藏在 action 里：
  //   action: "mgmusic://song-list-info?id=234305486"
  const text = JSON.stringify(body)
  const ids = [...text.matchAll(/song-list-info\?id=(\d+)/g)].map(m => m[1])
  if (!ids.length) throw new Error('mg 歌单广场的响应里没找到 song-list-info?id=')
  return { id: ids[0], name: '' }
}

async function txFirstPlaylistId () {
  const payload = {
    comm: { cv: 1602, ct: 20 },
    playlist: {
      method: 'get_playlist_by_tag',
      param: { id: 10000000, sin: 0, size: 36, order: 5, cur_page: 1 },
      module: 'playlist.PlayListPlazaServer',
    },
  }
  const url = `${TX_MUSICU}&data=${encodeURIComponent(JSON.stringify(payload))}`
  const body = jsonOf((await get(url)).text, 'tx 歌单广场')
  if (Number(body.code) !== 0) throw new Error(`tx 歌单广场返回 code=${body.code}`)
  const list = body?.playlist?.data?.v_playlist ?? []
  if (!list.length) throw new Error('tx 歌单广场没有返回歌单')
  // 广场里歌单 id 的字段叫 tid（与 txFilterPlaylists 取的是同一个）
  return { id: String(list[0].tid), name: list[0].title }
}

async function wyFirstPlaylistId () {
  const url = 'https://music.163.com/api/playlist/list'
  const body = jsonOf((await postForm(url, {
    cat: '全部', order: 'hot', limit: '30', offset: '0', total: 'true',
  }, WY_HEADERS)).text, 'wy 歌单广场')
  if (Number(body.code) !== 200) throw new Error(`wy 歌单广场返回 code=${body.code}`)
  const list = body.playlists ?? []
  if (!list.length) throw new Error('wy 歌单广场没有返回歌单')
  return { id: String(list[0].id), name: list[0].name }
}

// ---------------------------------------------------------------- 歌单详情

async function kwDetail (id) {
  const url = 'http://nplserver.kuwo.cn/pl.svc?op=getlistinfo' +
    `&pid=${encodeURIComponent(id)}&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo` +
    '&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1'
  const body = jsonOf((await get(url)).text, 'kw 歌单详情')
  if (String(body.result) !== 'ok') throw new Error(`kw 歌单详情返回 result=${body.result}`)
  const songs = body.musiclist ?? []
  return {
    name: body.title,
    total: Number(body.total) || songs.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name} - ${s.artist}`),
  }
}

async function kgDetail (id) {
  const url = `http://www2.kugou.kugou.com/yueku/v9/special/single/${encodeURIComponent(id)}-5-9999.html`
  const { text } = await get(url)
  const listMatch = text.match(/global\.data = (\[.+\]);/)
  if (!listMatch) throw new Error('kg 歌单详情：页面里没找到 global.data（页面结构可能已变）')
  const hashes = JSON.parse(listMatch[1])
  const infoMatch = text.match(/global = {[\s\S]+?name: "(.+)"[\s\S]+?pic: "(.+)"[\s\S]+?};/)
  // 页面上只有 hash，还要再用 gateway 换歌曲信息（对应 kgSongsByHash），
  // 不换的话这里看到的就永远是一串 hash，看不出 App 里到底会不会有歌名
  const songs = await kgSongsByHash(hashes.map(h => h.hash).filter(Boolean))
  return {
    name: infoMatch ? infoMatch[1] : '',
    total: hashes.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name} - ${s.singer}`),
  }
}

const KG_GATEWAY_KEY = 'OIlwieks28dk2k092lksi2UIkp'

async function kgSongsByHash (hashes) {
  const out = []
  for (let offset = 0; offset < hashes.length; offset += 100) {
    const batch = hashes.slice(offset, offset + 100).map(hash => ({ hash }))
    const body = {
      data: batch,
      area_code: '1',
      show_privilege: 1,
      show_album_info: '1',
      is_publish: '',
      appid: 1005,
      clientver: 11451,
      mid: '1',
      dfid: '-',
      clienttime: Date.now(),
      key: KG_GATEWAY_KEY,
      fields: 'album_info,author_name,audio_info,ori_audio_name,base,songname',
    }
    const res = await fetch('http://gateway.kugou.com/v2/album_audio/audio', {
      method: 'POST',
      headers: {
        'KG-THash': '13a3164',
        'KG-RC': '1',
        'KG-Fake': '0',
        'KG-RF': '00869891',
        'User-Agent': 'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
        'x-router': 'kmr.service.kugou.com',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    })
    const parsed = jsonOf(await res.text(), 'kg 歌曲信息')
    for (const group of parsed.data ?? []) {
      if (Array.isArray(group) && group.length) {
        const s = group[0]
        out.push({ name: s.songname ?? s.audio_name, singer: s.author_name ?? '' })
      }
    }
  }
  return out
}

async function mgDetail (id) {
  const listUrl = 'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0' +
    `?pageNo=1&pageSize=30&playlistId=${encodeURIComponent(id)}`
  const body = jsonOf((await get(listUrl, MG_HEADERS)).text, 'mg 歌单详情')
  if (String(body.code) !== '000000') throw new Error(`mg 歌单详情返回 code=${body.code}`)
  const data = body.data ?? {}
  const songs = data.songList ?? []
  return {
    name: '',
    total: Number(data.totalCount) || songs.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name ?? s.songName} - ${s.singer ?? ''}`),
  }
}

async function txDetail (id) {
  // 新版 musicu 优先，老接口兜底（与 entry 里 txPlaylistDetail 的顺序一致）
  try {
    return await txDetailMusicu(id)
  } catch (err) {
    const legacy = await txDetailLegacy(id)
    legacy.note = `新版失败（${err.message}），老接口可用`
    return legacy
  }
}

async function txDetailMusicu (id) {
  const payload = {
    comm: {
      cv: 4747474, ct: 24, format: 'json', inCharset: 'utf-8', outCharset: 'utf-8',
      platform: 'yqq.json', needNewCode: 1, uin: 0,
    },
    req_1: {
      module: 'music.srfDissInfo.aiDissInfo',
      method: 'uniform_get_Dissinfo',
      param: {
        disstid: parseInt(id, 10), userinfo: 1, tag: 1, orderlist: 1,
        song_begin: 0, song_num: 1000, onlysonglist: 0, enc_host_uin: '',
      },
    },
  }
  const res = await fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST',
    headers: {
      Origin: 'https://y.qq.com',
      Referer: `https://y.qq.com/n/yqq/playsquare/${id}.html`,
      'Content-Type': 'application/json',
      'User-Agent': UA_PC,
    },
    body: JSON.stringify(payload),
  })
  const body = jsonOf(await res.text(), 'tx 歌单详情（新版）')
  if (Number(body.code) !== 0) throw new Error(`code=${body.code}`)
  const req = body.req_1 ?? {}
  const data = req.data ?? {}
  const songs = data.songlist ?? []
  if (Number(req.code) !== 0 || !songs.length) throw new Error(`req_1.code=${req.code} 且没有歌曲`)
  const dir = data.dirinfo ?? {}
  return {
    name: dir.title,
    total: Number(data.total_song_num) || songs.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name} - ${(s.singer ?? []).map(x => x.name).join('、')}`),
  }
}

async function txDetailLegacy (id) {
  const url = 'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg' +
    `?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=${encodeURIComponent(id)}` +
    '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0' +
    '&platform=yqq.json&needNewCode=0'
  const headers = {
    Origin: 'https://y.qq.com',
    Referer: `https://y.qq.com/n/yqq/playsquare/${id}.html`,
  }
  const body = jsonOf((await get(url, headers)).text, 'tx 歌单详情（老接口）')
  const cd = (body.cdlist ?? [])[0]
  if (Number(body.code) !== 0 || !cd) throw new Error(`code=${body.code}`)
  const songs = cd.songlist ?? []
  return {
    name: cd.dissname,
    total: songs.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name} - ${(s.singer ?? []).map(x => x.name).join('、')}`),
  }
}

async function wyDetail (id) {
  const url = `https://music.163.com/api/v6/playlist/detail?id=${encodeURIComponent(id)}&n=1000&s=8`
  const body = jsonOf((await get(url, WY_HEADERS)).text, 'wy 歌单详情')
  if (Number(body.code) !== 200) throw new Error(`wy 歌单详情返回 code=${body.code}`)
  const p = body.playlist ?? {}
  const songs = p.tracks ?? []
  return {
    name: p.name,
    total: (p.trackIds ?? []).length || songs.length,
    got: songs.length,
    sample: songs.slice(0, 3).map(s => `${s.name} - ${(s.ar ?? []).map(x => x.name).join('、')}`),
  }
}

// ---------------------------------------------------------------- 主流程

const PLATFORMS = {
  kw: { first: kwFirstPlaylistId, detail: kwDetail },
  kg: { first: kgFirstPlaylistId, detail: kgDetail },
  mg: { first: mgFirstPlaylistId, detail: mgDetail },
  tx: { first: txFirstPlaylistId, detail: txDetail },
  wy: { first: wyFirstPlaylistId, detail: wyDetail },
}

async function runOne (source, forcedId) {
  const impl = PLATFORMS[source]
  const started = Date.now()
  try {
    let id = forcedId
    let fromSquare = ''
    if (!id) {
      const picked = await impl.first()
      id = picked.id
      fromSquare = picked.name ? `（歌单广场：${short(picked.name, 24)}）` : ''
    }
    const detail = await impl.detail(id)
    const sample = detail.sample.filter(Boolean).map(s => short(s, 34)).join(' | ')
    console.log(`✅ ${source}  id=${id}${fromSquare}  「${short(detail.name, 26)}」 ` +
      `total=${detail.total} 取到=${detail.got}  ${Date.now() - started}ms`)
    if (sample) console.log(`     ${sample}`)
    if (detail.note) console.log(`     ℹ️ ${detail.note}`)
    if (detail.got === 0) console.log('     ⚠️ 详情接口通了但一首歌都没取到')
    return true
  } catch (err) {
    console.log(`❌ ${source}  ${err.message}  ${Date.now() - started}ms`)
    return false
  }
}

async function main () {
  const args = process.argv.slice(2)
  let targets = []
  let forced = null
  if (args[0] === '--detail') {
    forced = args[2]
    targets = [args[1]]
  } else {
    targets = args.filter(a => PLATFORMS[a])
    if (!targets.length) targets = Object.keys(PLATFORMS)
  }
  for (const source of targets) {
    if (!PLATFORMS[source]) {
      console.log(`⚠️ 跳过未知平台：${source}`)
      continue
    }
    await runOne(source, forced)
  }
}

main().catch(err => {
  console.error(err)
  process.exit(1)
})
