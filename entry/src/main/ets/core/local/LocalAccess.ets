import { abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, fileShare } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 本地音乐的「文件访问」层（引用式导入的地基）
 *
 * 为什么需要这一层：三方应用读设备里的音频只能走 Picker，而 Picker 给的 URI 只有
 * **临时**读权限（应用退出即失效）。想让「导入」变成「记住这个文件」而不是「复制一份」，
 * 必须把临时授权持久化，并在每次冷启动后把它重新激活。三步（官方《授权持久化》）：
 *
 *   1. 选完文件（临时权限还在时）→ `fileShare.persistPermission(uri)` 落库；
 *   2. 应用/设备重启后 → `fileShare.checkPersistentPermission` 看还在不在，
 *      再 `fileShare.activatePermission` 把它挂回当前进程；
 *   3. 之后 `fs.openSync(uri)` / AVPlayer `fdSrc` 直接读原文件。
 *
 * 关键事实（2026-10-20 在 PLR-AL30 / 鸿蒙7.0.0.109 / API 26 上实测）：
 *   - `canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')` = true，
 *     手机上有这个能力位；
 *   - `ohos.permission.FILE_ACCESS_PERSIST` 在 SDK 权限表里是 system_grant / normal，
 *     **不是受限 ACL**，`module.json5` 里声明即授予（实测 checkAccessToken = GRANTED）；
 *   - 真机全链路：persist OK → 杀进程 → checkPersistentPermission=[true] → activate OK →
 *     `fs.openSync(uri)` 读到原文件（4673028 字节），没有再弹选择器。
 * 之前 `docs/LOCAL_MUSIC.md` 与派音项目的注释都判断「手机上要受限 ACL、申请不下来」，
 * 那个结论是错的，本文与 docs 已更正。
 *
 * 能力位或权限缺失的设备（理论上只有非常老/受限的形态）：`supported()` 会返回 false，
 * 导入自动退回「复制进沙箱」，不会把功能弄成一半坏掉。
 */
const DOMAIN: number = 0x0001;
const TAG: string = 'LocalAccess';
const PERMISSION: Permissions = 'ohos.permission.FILE_ACCESS_PERSIST';
const SYS_CAP: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';

export class LocalAccess {
  /** 本进程内已经验证过可读的 URI（激活一次即可反复读，不必每次走系统接口） */
  private static ready: Set<string> = new Set<string>();
  private static supportedCache: boolean | undefined = undefined;
  private static grantedCache: boolean | undefined = undefined;

  /** 设备是否支持持久化授权（不支持就只能复制进沙箱） */
  static supported(): boolean {
    if (LocalAccess.supportedCache === undefined) {
      try {
        LocalAccess.supportedCache = canIUse(SYS_CAP);
      } catch (e) {
        LocalAccess.supportedCache = false;
      }
    }
    return LocalAccess.supportedCache;
  }

  /** `FILE_ACCESS_PERSIST` 是否被授予（system_grant：声明了就有） */
  static granted(): boolean {
    if (LocalAccess.grantedCache === undefined) {
      try {
        const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
        const status: abilityAccessCtrl.GrantStatus =
          manager.checkAccessTokenSync(info.appInfo.accessTokenId, PERMISSION);
        LocalAccess.grantedCache = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      } catch (e) {
        LocalAccess.grantedCache = false;
      }
    }
    return LocalAccess.grantedCache;
  }

  /** 这条 URI 在当前进程里是不是已经确认可读 */
  static isReady(uri: string): boolean {
    return LocalAccess.ready.has(uri);
  }

  /**
   * 选完文件后立刻持久化授权（失败返回 false，调用方退回复制式导入）
   *
   * **只能在还有临时权限时调用**：必须在 Picker 返回后紧接着做，否则会报 13900001。
   */
  static async persist(uri: string): Promise<boolean> {
    if (!LocalAccess.supported() || !LocalAccess.granted() || uri.length === 0) {
      return false;
    }
    try {
      await fileShare.persistPermission([{ uri: uri, operationMode: fileShare.OperationMode.READ_MODE }]);
      LocalAccess.ready.add(uri);
      hilog.info(DOMAIN, TAG, 'persist OK: %{public}s', LocalAccess.short(uri));
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'persist FAIL code=%{public}d msg=%{public}s uri=%{public}s',
        err.code, err.message, LocalAccess.short(uri));
      return false;
    }
  }

  /**
   * 使用前确保这条 URI 现在能读（幂等；已确认过的直接返回）
   *
   * 先直接开一次：冷启动后如果系统还没回收权限，可能不必激活；失败再走
   * checkPersistentPermission → activatePermission → 再开一次。
   */
  static async ensure(uri: string): Promise<boolean> {
    if (uri.length === 0) {
      return false;
    }
    if (LocalAccess.ready.has(uri)) {
      return true;
    }
    if (LocalAccess.tryOpen(uri)) {
      LocalAccess.ready.add(uri);
      return true;
    }
    if (!LocalAccess.supported()) {
      return false;
    }
    try {
      const policies: fileShare.PolicyInfo[] = [{ uri: uri, operationMode: fileShare.OperationMode.READ_MODE }];
      const checks: boolean[] = await fileShare.checkPersistentPermission(policies);
      if (checks.length > 0 && checks[0]) {
        await fileShare.activatePermission(policies);
        hilog.info(DOMAIN, TAG, 'activate OK: %{public}s', LocalAccess.short(uri));
      }
      if (LocalAccess.tryOpen(uri)) {
        LocalAccess.ready.add(uri);
        return true;
      }
      hilog.warn(DOMAIN, TAG, 'uri not readable after activate: %{public}s', LocalAccess.short(uri));
      return false;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ensure FAIL code=%{public}d msg=%{public}s uri=%{public}s',
        err.code, err.message, LocalAccess.short(uri));
      return false;
    }
  }

  /**
   * 冷启动批量预热（不阻塞启动）
   *
   * 只把 URI 标进「可读集合」，让第一次播放少一次系统调用；单条失败不算错 ——
   * 播放时会再走一次 `ensure`，那时才决定「文件是不是真没了」。
   */
  static async warmUp(uris: string[]): Promise<void> {
    if (uris.length === 0 || !LocalAccess.supported()) {
      return;
    }
    for (const uri of uris) {
      await LocalAccess.ensure(uri);
    }
    hilog.info(DOMAIN, TAG, 'warmUp done: %{public}d/%{public}d readable',
      LocalAccess.ready.size, uris.length);
  }

  private static tryOpen(uri: string): boolean {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      return true;
    } catch (e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  /** 日志里只留头尾，避免整条 URI 太长 */
  private static short(uri: string): string {
    if (uri.length <= 90) {
      return uri;
    }
    return `${uri.substring(0, 60)}...${uri.substring(uri.length - 24)}`;
  }
}
