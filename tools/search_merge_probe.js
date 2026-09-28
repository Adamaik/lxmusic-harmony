'use strict'
/**
 * 搜索「合并 → 去重 → 相关度排序 → 翻页」的活体验证（无设备）
 *
 * live_search_probe.js 管的是「五个平台的请求本身还能不能打」；这个脚本管另一个环节：
 * 拿到各平台结果之后怎么合。合并规则在
 * entry/src/main/ets/core/music/MusicSearch.ets（dedupeSongs / sortByRelevance），
 * 界面侧的翻页在 views/SearchView.ets —— 这里把两处的纯逻辑照原样复刻一遍，
 * 用真实酷我数据验证（对应 docs/DEFECTS.md D-008）：
 *
 *   1. 酷我报的 TOTAL 是几千首（说明「只取第一页」必然少一大堆），且第 2 页与第 1 页不重复；
 *   2. 五个平台各回一页、交错拼接时，同一首歌会连着出现五遍（改之前的观感）；
 *   3. 新的合并规则把 150 条合成 30 条，且留下的是先问的那个平台那一份；
 *   4. 排完序最像关键词的排在最前面。
 *
 * 运行： node tools/search_merge_probe.js [关键词]      （默认 周杰伦）
 * 注意：本脚本依赖外网；需要代理请自行设置（Node 的 fetch 默认不走 HTTP_PROXY）。
 */

const KEYWORD = process.argv[2] || '周杰伦'
const LIMIT = 30

const kwUrl = (kw, page, rn) =>
  `http://search.kuwo.cn/r.s?client=kt&all=${encodeURIComponent(kw)}&pn=${page - 1}&rn=${rn}` +
  '&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music' +
  '&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1'

let failed = 0
function check (label, ok, detail) {
  console.log(`${ok ? '  ok  ' : ' FAIL '} ${label}${detail === undefined ? '' : ` -> ${detail}`}`)
  if (!ok) failed++
}

// ---------------------------------------------------------------- 被验证的逻辑（照抄 .ets）

function formatPlayTime (seconds) {
  const m = Math.trunc(seconds / 60)
  const s = Math.trunc(seconds % 60)
  if (m === 0 && s === 0) return '--/--'
  return `${m < 10 ? '0' + m : m}:${s < 10 ? '0' + s : s}`
}

function decodeName (str) {
  return String(str == null ? '' : str)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&nbsp;/g, ' ')
}

/** parseKwResult 的极简版：只留排序 / 去重需要的字段 */
function parseKw (abslist) {
  const out = []
  for (const info of abslist) {
    const musicrid = String(info.MUSICRID || '')
    if (!musicrid || !info.N_MINFO) continue
    out.push({
      name: decodeName(info.SONGNAME),
      singer: decodeName(String(info.ARTIST || '').split('&').join('、')),
      source: 'kw',
      songmid: musicrid.split('MUSIC_').join(''),
      interval: formatPlayTime(Number.parseInt(info.DURATION, 10) || 0),
    })
  }
  return out
}

function similar (a, b) {
  if (!a.length || !b.length) return 0
  let s = a; let l = b
  if (s.length > l.length) { const t = s; s = l; l = t }
  const sl = s.length; const ll = l.length
  const mp = []
  for (let j = 0; j <= ll; j++) mp.push(j)
  for (let i = 1; i <= sl; i++) {
    const ai = s.charAt(i - 1)
    let lt = mp[0]
    mp[0] = mp[0] + 1
    for (let j = 1; j <= ll; j++) {
      const cost = ai === l.charAt(j - 1) ? 0 : 1
      const tmp = Math.min(mp[j] + 1, mp[j - 1] + 1, lt + cost)
      lt = mp[j]
      mp[j] = tmp
    }
  }
  return 1 - (mp[ll] / ll)
}

function sortInsert (arr, data) {
  const key = data.num
  let left = 0; let right = arr.length - 1
  while (left <= right) {
    const middle = Math.trunc((left + right) / 2)
    if (key === arr[middle].num) { left = middle; break }
    if (key < arr[middle].num) right = middle - 1
    else left = middle + 1
  }
  while (left > 0) {
    if (arr[left - 1].num !== key) break
    left--
  }
  arr.splice(left, 0, data)
}

function sortByRelevance (items, keyword) {
  const scored = []
  for (const item of items) sortInsert(scored, { num: similar(keyword, `${item.name} ${item.singer}`), data: item })
  const out = []
  for (let i = scored.length - 1; i >= 0; i--) out.push(scored[i].data)
  return out
}

const SINGER_SEPARATORS = /、|&|;|；|\/|,|，|\|/
const FILTER_CHARS = /\s|'|\.|,|，|&|"|、|\(|\)|（|）|`|~|-|<|>|\||\/|\]|\[|!|！/g
const norm = (t) => t.replace(FILTER_CHARS, '').toLowerCase()

function normSingers (singer) {
  if (!singer.length) return ''
  if (!SINGER_SEPARATORS.test(singer)) return norm(singer)
  return singer.split(SINGER_SEPARATORS).map(norm).filter((x) => x.length).sort().join('、')
}

function intervalSeconds (interval) {
  if (!interval || interval === '--/--') return 0
  const parts = interval.split(':')
  let total = 0; let unit = 1
  for (let i = parts.length - 1; i >= 0; i--) { total += (Number.parseInt(parts[i], 10) || 0) * unit; unit *= 60 }
  return total
}

function sameInterval (a, b) {
  const one = intervalSeconds(a); const other = intervalSeconds(b)
  if (one === 0 || other === 0) return true
  return Math.abs(one - other) <= 5
}

const searchIdOf = (x) => `${x.source}_${x.songmid}`
const songKeyOf = (x) => { const n = norm(x.name); return n.length ? `${n}\u0001${normSingers(x.singer)}` : '' }

function dedupeSongs (items) {
  const ids = new Set(); const songs = new Map(); const out = []
  for (const item of items) {
    const id = searchIdOf(item)
    if (ids.has(id)) continue
    ids.add(id)
    const key = songKeyOf(item)
    if (!key.length) { out.push(item); continue }
    const kept = songs.get(key)
    if (kept === undefined) { songs.set(key, [item]); out.push(item); continue }
    let dup = false
    for (const other of kept) if (sameInterval(other.interval, item.interval)) { dup = true; break }
    if (dup) continue
    kept.push(item)
    out.push(item)
  }
  return out
}

// ---------------------------------------------------------------- 跑真实接口

async function fetchKwPage (kw, page) {
  const res = await fetch(kwUrl(kw, page, LIMIT))
  const body = await res.json()
  return { total: Number.parseInt(body.TOTAL, 10) || 0, list: parseKw(body.abslist) }
}

async function main () {
  console.log(`关键词「${KEYWORD}」\n`)

  const p1 = await fetchKwPage(KEYWORD, 1)
  const p2 = await fetchKwPage(KEYWORD, 2)
  console.log('1) 翻页：')
  check('接口报出总数与总页数', p1.total > LIMIT,
    `TOTAL=${p1.total} allPage=${Math.ceil(p1.total / LIMIT)}`)
  check('第 2 页与第 1 页不重合', p2.list.length > 0 &&
    p2.list.filter((x) => p1.list.some((y) => y.songmid === x.songmid)).length === 0,
    `page1=${p1.list.length} 条, page2=${p2.list.length} 条`)

  console.log('\n2) 改之前的「交错合并且不去重」：')
  const interleaved = []
  for (let d = 0; d < LIMIT; d++) for (let i = 0; i < 5; i++) if (d < p1.list.length) interleaved.push(p1.list[d])
  const headNames = interleaved.slice(0, 5).map((x) => x.name)
  check('同一首歌连着占满前几行（这就是「重复一大堆」）',
    headNames.length === 5 && headNames.every((n) => n === headNames[0]), headNames.join(' | '))

  console.log('\n3) 新的「合并 + 去重」：')
  const flat = []
  const sources = ['kw', 'kg', 'mg', 'tx', 'wy']
  for (const source of sources) for (const item of p1.list) flat.push({ ...item, source })
  const deduped = dedupeSongs(flat)
  check('150 条聚合后不再有跨平台重复', deduped.length < flat.length && deduped.length <= p1.list.length,
    `${flat.length} -> ${deduped.length}`)
  check('留下的是先问的平台那一份（kw）',
    deduped.every((x) => x.source === 'kw'),
    `非 kw 的条数=${deduped.filter((x) => x.source !== 'kw').length}`)
  if (deduped.length < p1.list.length) {
    // 平台自己也会重复返回同一首歌（不同 songmid），合并掉是对的，把并掉的打出来看一眼
    const dropped = p1.list.filter((x) => !deduped.some((y) => y.songmid === x.songmid))
    console.log(`   顺带并掉了平台自己重复返回的 ${dropped.length} 条：`)
    for (const d of dropped) console.log(`     ${d.name} - ${d.singer} [${d.interval}] mid=${d.songmid}`)
  }

  console.log('\n4) 相关度排序：')
  const ranked = sortByRelevance(deduped, KEYWORD)
  const scores = ranked.map((x) => similar(KEYWORD, `${x.name} ${x.singer}`))
  let monotonic = true
  for (let i = 1; i < scores.length; i++) if (scores[i] > scores[i - 1]) monotonic = false
  check('相似度单调不升', monotonic)
  check('最像的排在最前面', scores[0] >= scores[scores.length - 1], scores[0].toFixed(3))
  console.log('   前 8 条：')
  for (const t of ranked.slice(0, 8)) {
    console.log(`     ${similar(KEYWORD, `${t.name} ${t.singer}`).toFixed(3)}  ${t.name} - ${t.singer} [${t.interval}]`)
  }

  console.log(`\n${failed === 0 ? '全部通过' : `${failed} 项失败`}`)
  process.exitCode = failed === 0 ? 0 : 1
}

main().catch((e) => { console.error(e); process.exitCode = 1 })
