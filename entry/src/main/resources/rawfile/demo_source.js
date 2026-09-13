/*!
 * @name 示例音源（离线自检）
 * @description 用于验证「导入源 -> 初始化 -> 解析播放链接」整条链路的示例音源。不访问网络，musicUrl 直接返回固定测试地址。
 * @version 1.0.0
 * @author listen
 * @homepage https://example.com/lx-demo
 */

// 源规则：洛雪自定义音源通过 lx.on('request', handler) 注册处理器。
// handler 收到 { source, action, info }，需要返回 Promise：
//   action === 'musicUrl' -> resolve 一个 http(s) 播放链接字符串
//   action === 'lyric'    -> resolve { lyric, tlyric? } 对象
//   action === 'pic'      -> resolve 一个 http(s) 图片链接字符串
const DEFAULT_TEST_URL = 'https://example.com/test-audio.mp3'

lx.on('request', (request) => {
  return new Promise((resolve, reject) => {
    switch (request.action) {
      case 'musicUrl': {
        const { musicInfo, type } = request.info
        if (!musicInfo) return reject(new Error('musicInfo is required'))
        // 允许通过 musicInfo.meta.testUrl 覆盖返回值，便于在测试页验证数据透传
        const url = (musicInfo.meta && musicInfo.meta.testUrl) || DEFAULT_TEST_URL
        console.log('demo source resolve musicUrl:', request.source, musicInfo.name, type, url)
        resolve(url)
        break
      }
      default:
        reject(new Error('action not supported: ' + request.action))
    }
  })
})

// 声明本音源支持的能力
lx.send('inited', {
  sources: {
    kw: {
      type: 'music',
      actions: ['musicUrl'],
      qualitys: ['128k', '320k', 'flac', 'flac24bit'],
    },
  },
})
