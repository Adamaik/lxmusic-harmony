import { describe, it, expect } from '@ohos/hypium';
import { buildSourceInfo, parseSourceMeta } from '../main/ets/core/source/LxMetadata';

/** 内置示例源，与 rawfile/demo_source.js 头部保持一致 */
const DEMO_SCRIPT: string = `/*!
 * @name 示例音源（离线自检）
 * @description 用于验证「导入源 -> 初始化 -> 解析播放链接」整条链路的示例音源。
 * @version 1.0.0
 * @author listen
 * @homepage https://example.com/lx-demo
 */
lx.on('request', (request) => {})
`;

export default function lxMetadataTest() {
  describe('lxMetadataTest', () => {
    it('parsesAllHeaderFields', 0, () => {
      const meta = parseSourceMeta(DEMO_SCRIPT);
      expect(meta.name).assertEqual('示例音源（离线自检）');
      expect(meta.version).assertEqual('1.0.0');
      expect(meta.author).assertEqual('listen');
      expect(meta.homepage).assertEqual('https://example.com/lx-demo');
      expect(meta.description.length > 10).assertTrue();
    });

    it('throwsWhenHeaderMissing', 0, () => {
      let thrown: boolean = false;
      try {
        parseSourceMeta('const a = 1');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertTrue();
    });

    it('buildsSourceInfoWithGeneratedId', 0, () => {
      const info = buildSourceInfo(DEMO_SCRIPT);
      expect(info.name).assertEqual('示例音源（离线自检）');
      expect(info.id.startsWith('user_api_')).assertTrue();
      expect(info.allowShowUpdateAlert).assertTrue();
      expect(info.importedAt > 0).assertTrue();
    });

    it('fallsBackToDefaultName', 0, () => {
      const info = buildSourceInfo('/*\n * @version 1.0.0\n */\n');
      expect(info.name.length > 0).assertTrue();
    });

    it('truncatesOverlongFields', 0, () => {
      const longName: string = 'x'.repeat(100);
      const info = buildSourceInfo(`/*\n * @name ${longName}\n */\n`);
      // 洛雪对 name 的限制是 24 个字符 + '...'
      expect(info.name.length).assertEqual(27);
    });
  });
}
