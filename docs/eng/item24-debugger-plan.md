# Item 24: React Native DevTools (Hermes debugger) over Metro

STATUS: LANDED 8640d19 (feat/desktop-input). What changed vs the plan below:
- Executor is a DEDICATED inspector thread, not the GLFW main thread
  (main is blocked in waitForJsIdle while ReactInstance waits for
  registerInstance on the executor: deadlock).
- The blocker was HERMES_ENABLE_DEBUGGER, not wiring: without it RN builds
  the Fallback delegate (every *.enable ok, Runtime.evaluate -32601).
- Gate arm f (quit with DevTools attached) is what kills the teardown-order
  mutant; "skip unregister only" is not observable in release builds.
- Metro's proxy rejects a foreign Origin with 401 (cdp-probe sends Metro's).

# Original plan

Scope: `j` in Metro (or `/open-debugger`) opens React Native DevTools against
a running impeller app, with breakpoints, console, and the Components tab.
Same wiring as RN's own iOS host, built from RN's own C++ (no new deps).

## What exists today
- `REACT_NATIVE_DEBUGGER_ENABLED=1` is already set for `reactcommon_core`
  (ReactCommonCore.cmake:132), and Hermes is built `HERMES_ENABLE_DEBUGGER=ON`.
  So `jsinspector-modern` compiles with its real CDP handlers.
- Nothing creates a `HostTarget`, registers a page, or connects to Metro. The
  `ReactInstance` is constructed with `parentInspectorTarget = nullptr`.
- WebSocket client (item 12, Boost.Beast) exists and can carry the device
  socket.

## Pieces (iOS reference: RCTHost.mm:384-410, RCTInspectorDevServerHelper.mm,
## RCTCxxInspectorPackagerConnection.mm)
1. `HostTargetDelegate` (engine/runtime/InspectorHost.{h,cpp}):
   `getMetadata()` (appIdentifier, deviceName = hostname, platform
   "impeller", reactNativeVersion), `onReload()` -> the item 14 re-exec,
   `onSetPausedInDebuggerMessage()` -> log line for now (overlay later).
2. `HostTarget::create(delegate, executor)` before the ReactInstance; the
   executor posts to the GLFW main thread (glfwPostEmptyEvent + a queue
   drained per frame, same pattern as ClipboardBridge).
3. Pass the HostTarget to `ReactInstance(..., parentInspectorTarget)`;
   `unregisterFromInspector()` in ~ReactHost BEFORE the runtime goes.
4. `getInspectorInstance().addPage("React Native Bridgeless", "", connectFn,
   {.nativePageReloads = true})`; `removePage` on quit.
5. `InspectorPackagerConnection(url, deviceName, appName, delegate)` where
   url = `ws://host:port/inspector/device?name=..&app=..&device=..` from the
   bundle URL; `InspectorPackagerConnectionDelegate::connectWebSocket` wraps
   the item 12 Beast socket as an `IWebSocket`; `scheduleCallback` runs on
   the main-thread queue.
6. Only when the bundle came from http(s):// (same switch as HMR).

## Gate (ci-debugger.sh)
- start `react-native start`; run the app from the Metro URL.
- `GET /json/list` lists a page for the app (device registered).
- open the page's `webSocketDebuggerUrl` from a node `ws` client and send CDP:
  `Runtime.evaluate {expression:"1+2"}` -> 3; `Runtime.evaluate` of a
  fixture global -> the app's value (proves the REAL runtime, not a stub).
- `Debugger.enable` + `Debugger.pause` -> `Debugger.paused` arrives;
  `Debugger.resume` -> the app keeps rendering (frame counter advances).
- `console.log` in the app -> `Runtime.consoleAPICalled` on the CDP socket.
Mutants: no HostTarget passed to ReactInstance (Runtime.evaluate never
answers); page never added (/json/list empty); executor never drains (CDP
hangs); unregister skipped (exit crash under the exit-race probe pattern).

## Risks
- Threading: CDP messages arrive on the Beast thread; the HostTarget
  executor must hop to main, and runtime work goes via the JS thread
  (RuntimeTarget does that itself through the ReactInstance executor).
- Exit order: inspector teardown vs ~Scheduler/~ReactInstance (see the
  exit-race fix in FabricHost: drain before free).
- Size: ~400-600 lines + gate. Estimate 3-5 h including the Mac check.
