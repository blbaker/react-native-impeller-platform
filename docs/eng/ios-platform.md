# iOS platform

Status: a React Native bundle renders on iOS. `RNIEngine` runs `EngineSession`
(`engine/runtime/EngineSession.h`) the way the desktop host does, on a
`CAMetalLayer`, and the M1 gate (`tools/ci-ios-sim.sh`) checks the pixels of
`fixtures/ios-smoke` in the iOS Simulator. Simulator only; no text input yet.

## Shape

iOS follows the desktop model, not RN's own iOS host: the engine boots its own
Hermes, Fabric host and scene graph from a bundle and paints with Impeller onto a
`CAMetalLayer` the app supplies. That is the shape of Flutter on iOS (a
`FlutterEngine` owns the VM and renderer; a `FlutterViewController` attaches a
view). Metal only: no GLES, no ANGLE, no GLFW.

The cost of that choice: text input, IME and VoiceOver have to be built here,
because the app is not a stock RN iOS app underneath. They are a later phase.

## What exists

| Piece | Files | Gate |
|---|---|---|
| Metal surface | `engine/host/MetalSurfaceIOS.h/.mm` (`RNIMetalLayerView`) | `tools/ci-metal-ios-sim.sh` |
| vsync | `engine/host/DisplayLinkIOS.h/.mm` (`CADisplayLink`) | `tools/ci-vsync-ios-sim.sh` |
| GPU off in background | `engine/host/GpuAvailabilityIOS.h/.mm` | `tools/ci-gpu-availability-ios.sh` |
| Accessibility settings | `engine/modules/AccessibilitySettingsIOS.mm` | `tools/ci-reduce-motion-ios.sh` |
| Light/dark | `engine/host/OsAppearanceIOS.mm` | `tools/ci-os-appearance-ios.sh` |
| Clipboard | `engine/modules/ClipboardIOS.h/.mm` (`UIPasteboard`) | `tools/ci-clipboard-ios.sh` |
| CMake | `engine/CMakeLists.txt` -> `engine/ios/RniIos.cmake` | `tools/ci-ios-cmake-configure.sh` |
| Engine + host API (M1) | `engine/ios/RNIEngine.h/.mm`, `engine/ios/RniIosEngine.cmake` | `tools/ci-ios-sim.sh` |

Every gate has a `tools/mutation-verify-*` script that breaks the code on
purpose and requires the gate to fail on the arm named for that break.

- `MetalSurfaceIOS` keeps `MetalSurface`'s frame contract (Draw -> ReadPixels ->
  Present). ReadPixels uses SDK patch 0005's `ImpellerSurfaceReadPixels`. The
  simulator SDK's `MTLDrawable` has no `addPresentedHandler`/`presentedTime`, so
  there `onDisplayed` reports 0.
- `GpuAvailabilityIOS` wires `UIApplicationDidEnterBackgroundNotification` /
  `WillEnterForegroundNotification` to the existing `rni::gpu::Set` (Flutter's
  `FlutterEngine.mm` does the same). iOS may kill an app that submits GPU work in
  the background (`docs/eng/flutter-parity/research/03-embedding-platform.md`,
  section 3).
- `OsAppearanceIOS` implements the three darwin hooks `OsAppearance.cpp` calls, so
  its watcher runs unchanged.
- An iOS configure (`-DCMAKE_SYSTEM_NAME=iOS`) builds the static library
  `rni_ios_platform` and returns before every desktop target. It exposes the Hermes
  xcframework as `rni_ios_hermes` for the host. A missing Impeller SDK or Hermes
  fails configure with its own named error.
- With `RNI_IOS_WITH_ENGINE` (default on), `engine/ios/RniIosEngine.cmake` builds
  the engine itself for iOS: ReactCommon (the same `cmake/ReactCommon*.cmake` and
  `cmake/RnSvg.cmake` lists as desktop) and the same runtime, Fabric, scene graph,
  text and module sources `rn-impeller` compiles, minus the desktop host and every
  GL translation unit. `engine/ios/GlAbsentIOS.cpp` answers "no GL" for the two GL
  entry points shared code names. Everything merges into one archive,
  `librni_ios_all.a` (`tools/engine-build-ios.sh`, Ninja). iOS builds without TLS
  for now (`NetworkingModule` refuses `https://`), as Android does.

## The host API

```objc
RNIEngine* engine = [[RNIEngine alloc] initWithBundlePath:path appName:@"App"];
[engine attachToView:metalView];   // RNIMetalLayerView, or any CAMetalLayer-backed view
[engine detach];                   // stops frames; JS stays up; attach again any time
[engine destroy];
```

The first attach creates the Metal context and typography, boots `EngineSession`
(`setRenderContext`, `Boot`, `RunScript`, JS idle, `StartSurface`, JS idle; the
desktop headless order), installs the GPU-availability observers, then paints on
every `DisplayLinkIOS` tick: `PumpNativeAnimated`, `RecordFrame`, `RasterFrame` onto
the drawable, `Present`, inside a `rni::gpu::Section`. RECORD and RASTER both run on
the main thread; the desktop windowed pipeline's raster thread is later work. An app
links `librni_ios_all.a`, `libimpeller.a` and `hermesvm.framework` (embedded).

## Touch and keyboard

While attached, `RNIEngine` takes the view's input (`engine/ios/RNIInputIOS.mm`):

- **Touch.** A gesture recognizer on the view (it never cancels or delays UIKit's
  own touch delivery) forwards the first touch, in points, in the desktop
  windowed host's order: down is `beginTouchCapture` + `focusTextInputAt`, move
  is `dragTextSelection` or `dispatchCapturedMove`, up is `endTouchCapture` +
  `endTextSelectionDrag`.
- **Keyboard.** A hidden `UIView <UIKeyInput>` subview becomes first responder
  when a press focuses a `TextInput`, which brings up the system keyboard, and
  resigns when focus leaves (checked every frame, so a JS `blur()` also closes
  it). `insertText:` becomes `KeyAction::InsertChar` per Unicode scalar (`"\n"` is
  `Submit`), `deleteBackward` becomes `Backspace`. The engine's edit buffer is the
  only buffer.

Plain keys only, so far: no marked text (IME), autocorrect, autocapitalisation,
predictive text or selection UI. Those need `UITextInput`, and are switched off
on the proxy until then rather than half-working.

## Inputs

No prebuilt Impeller SDK exists for iOS: flutter_infra publishes none, and
`flutter/BUILD.gn` adds `interop:sdk` only for mac, linux, win, android and qnx.

- `tools/impeller-sdk-ios-build.sh` (on a Mac) builds the interop static library
  for the iOS Simulator from the pinned engine checkout that
  `tools/impeller-sdk-custom-build.sh` synced. A GN dotfile kept outside the
  checkout loads the interop `BUILD.gn` as the root, so the build graph needs no
  patch. Patch `engine/impeller-sdk-patches/ios/0006` adds the
  `IMPELLER_ENABLE_OPENGLES` / `_VULKAN` guards that iOS needs (it is the only
  target with both off); it changes nothing where they are on. The script resets
  the checkout and reapplies every patch on each run.
- `tools/sdk-fetch-ios.sh` runs that build on a Mac from linux and checks ABI
  parity: the 189 exported `Impeller*` functions match the linux SDK's.
- `tools/hermes-build-ios.sh` builds `hermesvm.xcframework` (device arm64,
  simulator arm64 + x86_64) at the tag RN pins, with Hermes's own Apple packaging
  (`utils/build-apple-framework.sh`), on a copy of the checkout.

## Running the gates

On a Mac with Xcode and an iOS Simulator runtime:

```bash
bash tools/impeller-sdk-ios-build.sh   # once; RNI_SDK_WORK=<synced engine checkout>
bash tools/hermes-build-ios.sh         # once; needs engine/rn npm install
bash tools/ci-metal-ios-sim.sh         # any gate
bash tools/ci-ios-sim.sh               # M1: builds the engine (librni_ios_all.a) first
bash tools/ci-ios-input.sh             # real UIKit taps and keyboard keys (XCUITest)
```

From linux, point the same commands at a Mac over ssh:

```bash
export RNI_MAC_HOST=<ssh host>         # RNI_MAC_TREE defaults to rni-ios
bash tools/sdk-fetch-ios.sh
bash tools/hermes-build-ios.sh
bash tools/ci-metal-ios-sim.sh
bash tools/mutation-verify-metal-ios-sim.sh
```

`tools/mac-run.sh` copies the worktree to the Mac (hash-verified) and runs the
command there. Without `RNI_MAC_HOST`, a gate started on linux exits 2.

Each gate builds the test host (`engine/ios/testhost/`, one UIKit app that takes
`--test=metal|vsync|gpu|settings|clipboard|engine|textfield`) with `xcrun clang++`, boots a fresh
iPhone 16 simulator, runs, and deletes the simulator. The last run's log and
screenshots stay in `~/Library/Caches/rni-ios-ci/artifacts/<gate>/` on the Mac.

`tools/ci-ios-input.sh` needs input that a test cannot fake from inside the app,
so it drives the simulator with XCUITest, still without an Xcode project
(`tools/lib/ios-uitest.sh`): it copies Xcode's `XCTRunner.app` template, builds
`engine/ios/testhost/uitests/RniInputUITests.m` into its `PlugIns/` with clang,
writes a `.xctestrun` by hand (`man 5 xcodebuild.xctestrun`), and runs
`xcodebuild test-without-building`. The UI test taps a `Pressable`, taps a
`TextInput` and types on the software keyboard, key by key (`fixtures/ios-input`).
`IOS_INPUT_TEST=textfield` runs the same test against a plain `UITextField`,
which tells "the engine drops keys" apart from "the simulator delivers none".

## Simulator facts the gates depend on

- `simctl launch --stdout=<file>` stays empty when the file is under
  `/var/folders` (`$TMPDIR`); the gates write under `$HOME`.
- A fresh simulator posts first-boot banners over the foreground app; the harness
  waits 10 s before the first launch.
- A backgrounded app holding a background task runs a 16 ms loop at roughly
  13-25 iterations per second for about a second, then about once a second. The
  GPU gate samples that first second, where a leak shows (8-11 presents) and a
  zero means something.
- `simctl ui` sets appearance and Increase Contrast only. Reduce Motion is the
  `com.apple.Accessibility` `ReduceMotionEnabled` preference plus the
  `com.apple.accessibility.reduce.motion.status` notification.
- One grey shape under Impeller's 4x MSAA has exactly 5 colors (ink, background,
  three coverage levels), so the Metal gate asks for 5, not `ci-metal.sh`'s 10.
- The first keyboard on a fresh simulator shows a "Slide to Type" tutorial card
  over the keys. Taps on the keys then land on the card and nothing is typed;
  XCUITest reports the keys as not hittable (`Computed hit point {-1, -1}`). The
  UI test taps its "Continue" button. The `DidShowContinuousPathIntroduction`
  preference does not suppress it on iOS 26.3.

## Not done

- Device (`iphoneos`) builds: no device Impeller SDK yet; `engine-build-ios.sh
  device` says so by name.
- A raster thread for the iOS host (RECORD and RASTER share the main thread).
- `Linking.openURL`, TLS, and image upload on an IO thread (GL-only on desktop).
- `UITextInput` (IME and marked text, autocorrect, selection UI, the caret rect
  the keyboard positions against), hardware keyboards (`pressesBegan`), moving
  content above the keyboard, multi-touch, VoiceOver. iOS 16+ also shows a paste-consent alert when an app
  reads another app's pasteboard; the Clipboard module's `getString` will hit it,
  as RN's does.
- CI: the gates need a Mac with the iOS SDK built from a full engine checkout,
  which the GitHub macOS runners do not have cached.
