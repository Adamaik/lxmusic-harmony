/*!
 * @name 示例音源（网络请求自检）
 * @description 通过 lx.request 请求 musicInfo.meta.requestUrl，验证「沙箱 -> ArkTS 网络代理 -> 回灌沙箱」这条回环是否通畅。
 * @version 1.0.0
 * @author listen
 * @homepage https://example.com/lx-demo-http
 */

lx.on('request', (request) => {
  return new Promise((resolve, reject) => {
    if (request.action !== 'musicUrl') {
      return reject(new Error('action not supported: ' + request.action))
    }
    const musicInfo = request.info.musicInfo
    const meta = musicInfo.meta || {}
    const probeUrl = meta.requestUrl || 'https://example.com/'
    lx.request(probeUrl, { method: 'get', timeout: 15000 }, (err, resp) => {
      if (err) {
        return reject(new Error('probe request failed: ' + err.message))
      }
      if (meta.testUrl) {
        // 请求回环成功，返回一个合法播放地址
        return resolve(meta.testUrl)
      }
      reject(new Error('HTTP probe ok (status ' + resp.statusCode + ') but musicInfo.meta.testUrl is empty'))
    })
  })
})

lx.send('inited', {
  sources: {
    kw: {
      type: 'music',
      actions: ['musicUrl'],
      qualitys: ['128k', '320k'],
    },
  },
})
