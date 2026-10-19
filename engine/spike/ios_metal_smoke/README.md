# ios_metal_smoke (iOS Phase 0, Task 0.3)

Throwaway spike, same role as `../headless_gles.cpp`: proves Impeller can draw to a
`CAMetalLayer` on iOS with no React Native, Hermes or scene graph involved.

- `main.mm`: one UIKit app. A `CAMetalLayer`-backed view; every `CADisplayLink` tick it
  wraps `nextDrawable` with `ImpellerSurfaceCreateWrappedMetalDrawableNew`, draws an
  orange fill plus a green middle-third rect, and calls `ImpellerSurfacePresent`.
  `--mode=nopresent` skips the present (the mutant).
- `Info.plist`: scene-based app, launch screen set (otherwise iOS letterboxes the app).
- `smoke.sh`: runs on a Mac. Links against the iOS Simulator `libimpeller.a`
  (`tools/sdk-fetch-ios.sh`), builds and ad-hoc signs the `.app` with `xcrun clang++` (no Xcode
  project file), boots a fresh iPhone 16 / iOS 26.3 simulator, installs, launches both
  arms, screenshots with `simctl io`, checks colors, deletes the simulator.
- `check_png.py`: stdlib-only PNG check (the Mac's system Python has no Pillow).

Run on a Mac: `bash smoke.sh`. Pass line: `IOS_METAL_SMOKE_GATE_PASS`, which needs
the present arm to pass the color check and the nopresent arm to fail it.

Input: `RNI_IOS_SDK`, the staged iOS Simulator SDK (default
`engine/third_party/impeller-sdk-ios-simulator-arm64`). The repeatable version of
this check, on the engine's own surface class, is `tools/ci-metal-ios-sim.sh`.
