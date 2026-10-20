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
the drawable, `Present`, inside a `rni::gpu::Section`. Each frame also ticks
`LayoutAnimation` and flushes `requestAnimationFrame`: rAF is paced to the
display link (attached at boot), and pauses while the app is in the
background, like a browser's hidden tab. RECORD and RASTER both run on
the main thread; the desktop windowed pipeline's raster thread is later work. An app
links `librni_ios_all.a`, `libimpeller.a`, `-lc++abi` and `hermesvm.framework`
(embedded).

## Touch and keyboard

While attached, `RNIEngine` takes the view's input (`engine/ios/RNIInputIOS.mm`):

- **Touch.** A gesture recognizer on the view (it never cancels or delays UIKit's
  own touch delivery) forwards the first touch, in points, in the desktop
  windowed host's order: down is `beginTouchCapture` + `focusTextInputAt`, move
  is `dragTextSelection` or `dispatchCapturedMove`, up is `endTouchCapture` +
  `endTextSelectionDrag`.
- **Keyboard.** A hidden `UITextInput` view (`engine/ios/RNITextInputView.mm`)
  becomes first responder when a press focuses a `TextInput`, and resigns when
  focus leaves (checked every frame, so a JS `blur()` also closes it). The
  field's props configure the keyboard: `autoCapitalize`, `autoCorrect`,
  `spellCheck`, `keyboardType`, `returnKeyType`, `keyboardAppearance`,
  `enablesReturnKeyAutomatically` and `secureTextEntry`, mapped as RN's own
  iOS `TextInput` maps them.
- **Editing by range.** The view keeps a copy of the field's text and selection
  in UTF-16, which is how UIKit counts. That lets the keyboard read the text
  around the caret, and autocorrect, predictive text and marked text (IME
  composition) work. Every keyboard edit is applied to the copy and sent to the
  engine as one range replace (`FabricHost::replaceTextInputRange`), which fires
  `onChange` and `onSelectionChange` as a keystroke does. Text being composed
  is ordinary text in the engine's buffer until it's confirmed, so JS sees it
  as it's typed, as with RN's own iOS `TextInput`. Changes the engine makes on
  its own (a submit, a JS value update, focus moving to another field) come back
  to the copy each frame, and the keyboard is told. Never during a composition.
- **Return** goes to the engine as a key, so `submitBehavior` decides between
  submitting and a new line, as on desktop. While text is marked, Return
  confirms the composition instead.

- **Keyboard events.** UIKit's keyboard notifications become RN's `Keyboard`
  events (`keyboardWillShow`, `keyboardDidShow`, `keyboardWillHide`,
  `keyboardDidHide`, `keyboardWillChangeFrame`, `keyboardDidChangeFrame`;
  `engine/ios/RNIKeyboardEventsIOS.mm`). The payload has the shape RN's iOS
  `RCTKeyboardObserver` sends: `startCoordinates`, `endCoordinates`, `duration`
  in ms, `easing` and `isEventFromThisApp`. Coordinates are in the attached
  view's points. `Platform.OS` is `'impeller'`, so RN's `Keyboard` module listens
  on the device event emitter directly, and `KeyboardAvoidingView` takes its
  non-iOS path (`keyboardDidShow` / `keyboardDidHide`). The padding animates
  with `LayoutAnimation`, which RNIEngine's frame loop ticks once per frame, as
  the desktop frame loop does.

Not done yet: the composing text is not underlined, the keyboard gets no
selection rectangles (no loupe or selection handles), and the caret rectangle
the keyboard positions against is the field's box at the caret's x.

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
- ⛔ The staged `libimpeller.a` has no C++ exception runtime of its own.
  Flutter's archive bundles its libc++abi and a `libc++` `exception.o` built
  without exception support. Linked into an app, those copies won over the
  system's, and a JS error thrown in a task ended in `std::terminate` (a crash)
  instead of RN's error handler. `tools/impeller-sdk-ios-build.sh` drops those
  17 members and fails if any of the runtime is left. Apps link `-lc++abi`.
- ⛔ The engine takes jsi from Hermes on Apple platforms. `hermesvm.framework`
  (and macOS's `libhermesvm.dylib`) exports jsi's classes, and the engine used
  to compile RN's `jsi.cpp` as well. Under the two-level namespace an app kept
  both copies, so a `jsi::JSError` thrown inside Hermes didn't match the
  engine's `catch (jsi::JSError&)`, and every JS error reached RN as
  "Non-js exception: ..." with no JS stack. On Apple, `jsi.cpp` is now its own
  library (`reactcommon_jsi`, `engine/cmake/ReactCommonCore.cmake`), linked only
  by targets without Hermes.
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
bash tools/ci-ios-text-input.sh        # autocorrect and Japanese composition (XCUITest)
bash tools/ci-ios-keyboard.sh          # Keyboard events + KeyboardAvoidingView (XCUITest)
bash tools/ci-ios-raf.sh               # requestAnimationFrame paced to the display link
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

`tools/ci-ios-text-input.sh` uses the same machinery for edits the keyboard
makes by range (`fixtures/ios-text-input`). In a field with RN's default
autocorrect it types `teh `, and the keyboard's autocorrection must reach JS
as `the `. The same keys in an `autoCorrect={false}` field must stay `teh `,
which proves the field's props reach the keyboard. In a third field it switches
to the Japanese romaji keyboard, types `nihonn` and confirms. The engine must receive the marked text while composing,
JS must see kana before the confirm, and the final value must be `にほん`.

`tools/ci-ios-keyboard.sh` puts a `TextInput` and a green footer at the bottom
of RN's own `KeyboardAvoidingView` (`fixtures/ios-keyboard`), brings the
keyboard up, then takes it down. JS must get all four show and hide events with
a height, a duration and an easing. The footer's layout must end at or above
the keyboard's top while it's up, and back at the bottom after. The footer's
colour must be on screen where that layout says, in both screenshots. Layout
alone can't prove that: `onLayout` reports the new position before anything is
drawn there.

## Device builds (iPhone/iPad)

```bash
bash tools/sdk-fetch-ios.sh device     # once: Impeller for iphoneos arm64 (about 5 min, 3 GB of build files)
bash tools/engine-build-ios.sh device  # engine/build-ios-device/librni_ios_all.a
bash tools/ci-ios-device-build.sh      # builds, links and checks the test host for iphoneos
```

The device SDK is built from the same checkout and patches as the Simulator
one (`RNI_IOS_TARGET=device` in `tools/impeller-sdk-ios-build.sh`) and lands in
`engine/third_party/impeller-sdk-ios-arm64`, where `engine/ios/RniIos.cmake`
looks for it. Hermes's xcframework already has the device slice. The gate
checks that the app is an iPhone app (Mach-O platform `IOS`, arm64, minimum
iOS 15.1, `CFBundleSupportedPlatforms` iPhoneOS) and has one C++ exception
runtime and one jsi. The built app is kept as `RniTestHost-iphoneos.zip` in
the gate's artifacts. Shared test-host builds pick the platform with
`IOS_PLATFORM=simulator|device` (`tools/lib/ios-sim.sh`).

Running it needs one of:

- an iPhone or iPad connected to the Mac and trusted, signed with an iOS
  development provisioning profile that includes it; or
- an Apple-silicon Mac, which can run iOS apps: an iOS development profile
  that includes the Mac (Xcode makes one when an iOS app is run on "My Mac
  (Designed for iPad)" with automatic signing), the app signed with it and
  installed in the App Store wrapper layout (`X.app/Wrapper/X.app`).

### Running it with Xcode

```bash
bash tools/ios-xcode-project.sh          # engine/ios/testhost/xcode/RniTestHost.xcodeproj
bash tools/ios-xcode-project.sh --build  # also builds it for iphoneos and the Simulator, signing off
```

The script stages the fixture bundles and runs XcodeGen on
`engine/ios/testhost/xcode/project.yml`, so the engine test host becomes an
ordinary Xcode app with automatic signing. The team defaults to the one on the
keychain's Apple Development certificate (`RNI_IOS_TEAM` overrides it). Open
the project, pick a connected iPhone or "My Mac (Designed for iPad)", and run.
The first run makes Xcode create an iOS development profile ("iOS Team
Provisioning Profile: *"). Measured on an M3 Mac running macOS 26.1: the app ran
as Mach-O platform `IOS` arm64 from the App Store wrapper layout. It used real
Metal ("Apple M3"), not the Simulator's, in a 1024×1366-point iPad window, and
presented 293,580 frames in 81 minutes (60 fps).

Measured on this Mac without Xcode: a flat iOS bundle won't open ("incorrect executable
format"). The wrapper layout reaches macOS's installer, which rejects any
app whose signature it can't validate. `codesign` with an Apple Development
identity fails over SSH (`errSecInternalComponent`: the login keychain is
locked to a non-GUI session).

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
- Keyboards set with `defaults write -g AppleKeyboards` on a booted simulator
  never reach the keyboard. The text-input gate writes them, then reboots the
  simulator once.
- On a notch iPhone the globe ("Next keyboard") key sits in the strip under the
  keyboard, outside `app.keyboards` in XCUITest. Search `app.buttons`.
- Romaji: a single trailing `n` stays a Latin `n` when the composition is
  confirmed (`にほn`). `ん` at the end needs `nn`.

## Not done

- Running on a device. Device builds compile, link and sign (below), but no
  gate runs one: that needs an iPhone, or this Mac set up to run iOS apps.
- A raster thread for the iOS host (RECORD and RASTER share the main thread).
- `Linking.openURL`, TLS, and image upload on an IO thread (GL-only on desktop).
- Selection UI (loupe, handles, edit menu), an underline for composing text, a
  per-glyph caret rectangle, hardware keyboards (`pressesBegan`), multi-touch,
  VoiceOver.
- iOS 16+ shows a paste-consent alert when an app reads another app's
  pasteboard; the Clipboard module's `getString` will hit it,
  as RN's does.
- CI: the gates need a Mac with the iOS SDK built from a full engine checkout,
  which the GitHub macOS runners do not have cached.
