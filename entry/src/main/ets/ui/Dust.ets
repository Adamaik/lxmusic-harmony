
/**
 * 删除时的粒子飘散
 *
 * 删除是破坏性操作，给一点「东西碎掉飘走」的反馈：在删除的位置撒一把粒子，
 * 粒子向外飞散、自旋，并逐渐缩小透明消失。
 *
 * 用 ArkUI 的 Particle 组件实现，做成**全局唯一的一层覆盖层**：
 * DustLayer 挂在 Index 最外层（与提示条同一层），任何页面删除时调
 * dustBus.spray(x, y) 就在对应位置撒一把，不用每个页面各画一遍。
 * 覆盖层不接收点击，飘散过程也不拦任何交互。
 *
 * 低版本系统上没有 Particle 能力位时自动不做这个效果（dustSupported）。
 */

/** 触发点（相对窗口的 vp 坐标） */
export interface DustPoint {
  x: number;
  y: number;
}

class DustBus {
  private listener: ((x: number, y: number) => void) | null = null;

  setListener(listener: ((x: number, y: number) => void) | null): void {
    this.listener = listener;
  }

  /** 在 (x, y) 撒一把粒子；没有覆盖层时静默忽略 */
  spray(x: number, y: number): void {
    const listener = this.listener;
    if (listener !== null) {
      listener(x, y);
    }
  }
}

export const dustBus: DustBus = new DustBus();

/** 粒子飘散可用性：Particle 组件从 API 10 起提供，能力位缺失时不做 */
export function dustSupported(): boolean {
  try {
    return canIUse('SystemCapability.ArkUI.ArkUI.Full');
  } catch (e) {
    return false;
  }
}

/**
 * 取一次触摸的触发点
 *
 * 用 window 坐标（覆盖层就在这个窗口里，且窗口可能不在屏幕左上角，
 * 比如分屏、自由窗口下 display 坐标会整体偏移）。
 */
export function dustPointOf(event: TouchEvent): DustPoint | null {
  const touches: TouchObject[] = event.touches.length > 0 ? event.touches : event.changedTouches;
  if (touches.length === 0) {
    return null;
  }
  const touch: TouchObject = touches[0];
  return { x: touch.windowX, y: touch.windowY };
}

/** 一次飘散的时长（粒子寿命 + 一点余量，到点就把覆盖层收掉） */
const DUST_MS: number = 760;

@Component
export struct DustLayer {
  @State posX: number = 0;
  @State posY: number = 0;
  @State emitting: boolean = false;
  private timer: number = 0;

  aboutToAppear(): void {
    dustBus.setListener((x: number, y: number) => {
      this.sprayAt(x, y);
    });
  }

  aboutToDisappear(): void {
    dustBus.setListener(null);
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timer !== 0) {
      clearTimeout(this.timer);
      this.timer = 0;
    }
  }

  private sprayAt(x: number, y: number): void {
    if (!dustSupported()) {
      return;
    }
    this.posX = x;
    this.posY = y;
    // 从 false 翻到 true 会把 Particle 重新挂上去，等于重新起一波；
    // 连续删除（上一波还没散完）只是改位置，剩下的存活期里粒子就改在新位置冒
    this.emitting = true;
    this.clearTimer();
    this.timer = setTimeout(() => {
      this.emitting = false;
      this.timer = 0;
    }, DUST_MS);
  }

  build() {
    if (this.emitting && dustSupported()) {
      Particle({
        particles: [
          {
            emitter: {
              particle: {
                type: ParticleType.POINT,
                config: { radius: 2.2 },
                count: 18,
                lifetime: 620,
                lifetimeRange: 180,
              },
              // 覆盖层只显示 760ms，emitRate 给足，看起来就是「撒了一把」而不是持续冒
              emitRate: 120,
              shape: ParticleEmitterShape.RECTANGLE,
              position: [this.posX, this.posY],
              size: [12, 12],
            },
            // 粒子色给字面量而不是主题 token：Particle 的颜色范围是渲染管线里的取值，
            // 拿不准它认不认资源色（认不出会落到默认色，粒子就不是红的了）；
            // 这两个色本身在深浅两种底色上都成立，不需要跟着模式变
            color: { range: ['#E33B3B', '#FFB08A'] },
            opacity: { range: [1.0, 0.0] },
            scale: { range: [1.0, 0.25] },
            velocity: { speed: [40, 220], angle: [0, 360] },
            spin: { range: [-120, 120] },
          },
        ],
      })
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
    }
  }
}
