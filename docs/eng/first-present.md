# First present inside a launch animation (D-156)

Mac report 2026-10-03, HostApp v5: the window showed its first frame about 1.5 s
after JS started, so the launch animation was never on screen. The first
frame shown was the Home screen.

## Cause (host side, `engine/host/main.cpp` RunWindowed)

Windowed boot called `waitForJsIdle(10000)` after `runScript` and again
after `startSurface`. `JsThread::isIdle` counts every pending one-shot timer
as work. RN core's `requestAnimationFrame` is `setTimeout(0)`
(`TimerManager.cpp`), so an app running a rAF or setTimeout boot clock is
never idle until that clock stops. The frame loop below the wait did not
start, and nothing was presented, until the animation had finished. The
cause was not window creation, shader warm-up, or GLFW.

## Fix

1. Windowed boot now calls `ReactHost::waitForJsQueueDrained`. It waits for
   queued JS tasks (bundle, runApplication, React's render and commit) but
   does not wait for timers. The headless path keeps `waitForJsIdle`, because
   its frames are deterministic snapshots.
2. The drain barrier is posted at RuntimeScheduler **IdlePriority**.
   `scheduleWork` is ImmediatePriority, and RuntimeScheduler orders tasks by
   priority, so an Immediate barrier ran before React's NormalPriority commit.
   The result was `scene_nodes=0` and a fully black first frame.
3. Host event `firstFramePresented` is emitted once, right after the first
   present returns. Payload: `{sinceLaunchMs}`, measured from process start
   to that present.

```js
import {DeviceEventEmitter} from 'react-native';
DeviceEventEmitter.addListener('firstFramePresented', ({sinceLaunchMs}) => {
  // start the launch-animation clock here
});
```

New log lines: `rn-impeller: boot_wait_ms=N drained=1/1` and
`rn-impeller: first_present_ms=N`.

## Measured

linux-x64 (llvmpipe, WSLg):
- Before: the first presented frame was 100% black (`scene_nodes=0`) with the
  Immediate-priority barrier. With the old `waitForJsIdle` boot it was HOME
  (blue).
- After, 3 of 3 runs: `first_present_ms` was 188 to 209. The first frame was
  BOOT (red) with the mark at +1 pt of its 200 pt travel. The JS listener
  fired 1 time.

darwin-arm64 (ANGLE-Metal, Retina 2x, Interactive QoS):
- Control, the agent's cached `rni-9947e02` engine with the same bundle: the
  first frame was HOME (`0000ff`), and the boot clock finished at JS 1540 ms.
  This reproduces D-156.
- After, 5 of 5 gate runs passed. JS heard the first frame at 72 to 78 ms
  after JS start. The mark was at +7 to +8 pt, about 55 ms into the
  animation.
- `first_present_ms` from process start was 312 to 379 ms on 7 of 9 launches
  and about 3.7 s on the 2 cold ones. That pre-JS time (window, GL, Hermes
  init) happens before JS starts and is not D-156. For that reason the gate
  times the frame on the JS clock. An app should start its clock from the
  `firstFramePresented` event rather than from module load.

## Gates

- `tools/ci-first-present.sh` runs the committed bundle and reads the first
  frame's pixels. It needs no node, so the Mac can run it with
  `RNI_BIN=<engine dir>/rn-impeller bash tools/ci-first-present.sh`.
- `tools/mutation-verify-first-present.sh` runs three mutants, and each one is
  killed by its own assertion. M1 restores the waitForJsIdle boot, giving
  HOME. M2 restores the Immediate barrier, giving BLACK. M3 deletes the emit,
  giving 0 emits.
- To rebuild the fixture bundle after editing `fixtures/first-present/index.js`,
  run `tools/build-first-present-bundle.sh`. It needs node.
