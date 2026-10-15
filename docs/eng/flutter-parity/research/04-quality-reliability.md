# 04. Quality, Reliability, and Observability

Pin: flutter/flutter `114eb184d66d7ca136d89eb8ec09f61aff265062` (2026-08-09), local checkout
`~/projects/_ref/sc32/flutter`. Our tree: `a local worktree`
(`feat/native-anim-transform`, c07048d), read-only.

## 4.1 Test pyramid: unit tests, Playground, goldens

**Flutter.** Impeller's unit tests are parameterized across backends by
`PlaygroundTest : ::testing::TestWithParam<PlaygroundBackend>`
[F:engine/src/flutter/impeller/playground/playground_test.h:L23-24], backend enum
`{kMetal, kMetalSDF, kOpenGLES, kOpenGLESSDF, kVulkan}`
[F:engine/src/flutter/impeller/playground/playground.h:L32-37]. The
`INSTANTIATE_PLAYGROUND_SUITE(x)` macro instantiates a `TEST_P` fixture over all
five values via `gtest`'s `INSTANTIATE_TEST_SUITE_P`
[F:engine/src/flutter/impeller/playground/playground_test.h:L79-89], so one written
test body runs on Metal, Metal+SDF-text, GLES, GLES+SDF, and Vulkan automatically.
Raw `TEST_P(` counts at the pin: `impeller/display_list` 465 across 18 files,
`impeller/entity` 116 across 10 files, `impeller/aiks` does not exist as a directory
(not found — `ls impeller/aiks` errors; aiks-named suites live under
`display_list/aiks_dl_*_unittests.cc`); whole-tree total 723 `TEST_P(` sites
(`grep -rc "TEST_P(" impeller --include=*.cc`).
`GoldenPlaygroundTest` [F:engine/src/flutter/impeller/golden_tests/golden_playground_test.h:L27-29]
extends the Playground pattern with `SaveScreenshot()`; `GoldenDigest` tracks each
golden's `max_diff_pixels_percent` and `max_color_delta` tolerance fields per entry
[F:engine/src/flutter/impeller/golden_tests/golden_digest.h:L34-40] and writes a
`digest.json` consumed by Skia Gold via `golden_tests_harvester`
[F:engine/src/flutter/impeller/golden_tests/README.md:L1-10]. The README states plainly:
**"Currently these tests are only supported on macOS and only test the Metal backend"**
[F:engine/src/flutter/impeller/golden_tests/README.md:L18-19] — goldens are a single-backend,
single-OS tripwire, not a cross-backend grid; cross-backend pixel coverage instead comes
from the non-golden `TEST_P` suites above, which assert programmatically (not via stored
baseline images) and so tolerate backend-specific AA/blend differences without per-pixel
diffing. `impeller/testing` supplies the shared `Screenshotter`/`GoldenDigestManager`
plumbing [F:engine/src/flutter/impeller/testing/screenshotter.h] used by both golden and
non-golden playground tests.

**RN-way.** RN core has no native-renderer pixel-testing concept at all — rendering is
delegated to the host platform (UIKit/Android views), so there is nothing in
`ReactCommon` playing GoldenPlaygroundTest's role (checked:
`grep -rli golden ReactCommon` — not found under the vendored RN tree). The nearest
RN-side analogue is Jest snapshot testing of the *shadow tree*/props, which proves
props were computed correctly, never that pixels are correct. This is a structural gap
RN leaves for any renderer that replaces the platform view layer — which is exactly our
situation.

**Our engine.** `tools/ci-*.sh`: 101 files; `tools/mutation-verify-*.sh`: 92 files
[R:tools (ls count)]. `tools/ci-all.sh` runs gates P0-P4 in one ordered script
[R:tools/ci-all.sh:L1-30], explicitly keeping mutation verification OUT of the hot path
("each mutant costs a full consumer install... belongs on a nightly or pre-release run")
[R:tools/ci-all.sh:L13-15]. `tools/ci-headless.sh` is the P0 substrate: compiles a spike
against the Impeller C SDK, requires a `IMPELLER_SPIKE_PASS` marker, a `GL_RENDERER=`
line, and **>=10 distinct colors** in the frame as an anti-false-positive guard
[R:tools/ci-headless.sh:L19-27]. There is no stored-baseline-image system anywhere in the
repo — the one "golden" reference in our docs means "a prior gate's own output"
(`grep -rn golden tools docs` → `tools/ci-window.sh:91`, `docs/tasks/P9-A-windowed-wsi.md:58`),
not a Skia-Gold-style asset. We run one backend at a time per host (GLES/ANGLE on
desktop, Mesa llvmpipe in CI); nothing instantiates a single test body across backends
the way `INSTANTIATE_PLAYGROUND_SUITE` does.

**Gaps (ranked by production risk).**
1. **Wrong pixels, undetected.** No cross-backend parameterized suite: a fix verified
   under llvmpipe GLES can silently regress ANGLE-Metal or ANGLE-D3D11, and nothing in
   CI would know (Mac is "measured by a peer" manually — see §4.6/4.10).
2. **No tolerance policy.** Flutter's goldens carry per-test `max_diff_pixels_percent`;
   our gates are bespoke pixel heuristics per fixture (distinct-color counts, probe
   pixels) with no shared tolerance model, so flakiness tuning is reinvented per gate.
3. **No unit layer under the gates.** Flutter has 723 `TEST_P` fast, in-process unit
   tests below the golden layer; we only have full-process, full-bundle `ci-*.sh`
   scripts — there is no fast "build a `DisplayListBuilder` from a scene snapshot and
   assert draw-call shape" layer at all.

**Work items.**
- **W1 — DisplayList-builder unit tests from a scene snapshot.** Model:
  `aiks_dl_*_unittests.cc` (programmatic assertions on a `DisplayList`, not screenshots)
  [F:engine/src/flutter/impeller/display_list/aiks_dl_basic_unittests.cc]. Build: feed a
  serialized `SceneGraph` snapshot into `paintFrame`'s builder path in-process (no window,
  no GPU) and assert draw-call counts/types/transforms on the resulting
  `ImpellerDisplayListBuilder`. *Acceptance gate*: a new `ci-dl-unit.sh` that runs in
  <2s and asserts exact draw-call count for 5 fixed fixtures. *Mutant*: drop one `Entity`'s
  paint call in `SceneGraph::paint()` — the draw-call count for that fixture must change;
  a gate that still reports the old count fails the mutation test.
- **W2 — Per-backend golden images with a tolerance policy.** Model:
  `GoldenDigest`'s `max_diff_pixels_percent`/`max_color_delta` fields
  [F:engine/src/flutter/impeller/golden_tests/golden_digest.h:L34-40]. Build: store
  reference PNGs per (fixture, backend) under `tools/goldens/`, diff with a percent+delta
  threshold, keep our existing `ci-*.sh`/`mutation-verify-*.sh` pair culture (gate script
  + a script proving the gate can fail) instead of replacing it. *Acceptance gate*: new
  fixture renders within 0.5% pixels / 4 color-delta of its stored golden on GLES, ANGLE-Metal,
  ANGLE-D3D11. *Mutant*: shift a fill color by 1 LSB — must stay PASS (tolerance works);
  shift by 32 — must FAIL (tolerance isn't a rubber stamp).

## 4.2 Fuzzing

**Flutter.** No Impeller- or `display_list`-specific fuzz harness exists at this pin:
`grep -rli fuzz impeller display_list` only matches comments/identifiers — enum values
documenting blur edge behavior (`kNormal, //!< fuzzy inside and outside`)
[F:engine/src/flutter/display_list/effects/dl_mask_filter.h:L25-28] and a
`fuzzy_compare_components`/`fuzzyCompare` pixel-tolerance helper in the DisplayList
rendering test harness [F:engine/src/flutter/display_list/testing/dl_rendering_unittests.cc:L607-630,L1981-1997] —
none are libFuzzer entry points. `grep -rl LLVMFuzzerTestOneInput .` (excluding
`buildtools`/`third_party`) returns nothing; the only `FuzzedDataProvider.h` present is
the vendored clang toolchain header, unused by impeller
[F:engine/src/flutter/buildtools/linux-x64/clang/lib/clang/23/include/fuzzer/FuzzedDataProvider.h]
(not confirmed to be wired to any impeller target — checked
`grep -rn FuzzedDataProvider impeller display_list`, zero hits). So: libFuzzer
infrastructure exists in the toolchain, but Impeller does not use it.

**RN-way.** (not confirmed) — no fuzz harness found under the vendored
`react-native/ReactCommon` tree either (`grep -rli fuzz ReactCommon` → no hits outside
unrelated identifier noise). Hermes itself fuzzes its bytecode/parser upstream, but that
is outside our pinned RN checkout and out of scope for this citation.

**Our engine.** No fuzzing anywhere (same negative grep, `a local worktree`).

**Gaps.** Medium-high, by attack surface: a malformed/malicious RN bundle, SVG asset,
font, or downloaded image is attacker-reachable content our engine parses natively in
C++, with no fuzz coverage proving memory safety under garbage input.
- Fabric props: `FabricHost`/`SceneGraph` apply arbitrary JS-sourced prop dictionaries
  into native state every commit [R:engine/scenegraph/SceneGraph.cpp (mutation path, per WORKER-BRIEF)].
- SVG path parser / stroke-AA path (feeds `tools/ci-svg*.sh`, `ci-path-aa.sh`): untrusted
  path data from bundled SVG assets.
- `ImageStore` decode: `stb_image` on a detached thread per image
  [R:engine/fabric/ImageStore.cpp:L20 (comment: "A failed URI maps to null...")] — stb_image
  is a classic, historically CVE-bearing fuzz target; our *integration* of it (buffer
  handling, thread lifetime) is unfuzzed even though upstream stb_image has public corpora.
- DisplayList builder: the tree-walk-to-draw-calls path that runs on every frame.

**Work items.**
- **W3 — libFuzzer harness for the SVG path parser.** Model: wire a libFuzzer
  `LLVMFuzzerTestOneInput` the way `boost_url_fuzz` does in vendored deps
  [R:engine/build/_deps/boost_src-src/libs/url/test/fuzz/CMakeLists.txt:L70-71] (confirms
  `-fsanitize=fuzzer,address,undefined` is a known-working flag combo in our toolchain,
  just never applied to our own code) against the path-token parser feeding
  `ci-path-aa.sh`/`ci-svg-dash.sh`. *Acceptance gate*: 1-hour corpus run, zero crashes,
  checked into CI as a bounded nightly job. *Mutant*: remove a bounds check on path
  command argument count — fuzzer must find a crash within the hour budget.
- **W4 — `ImageStore::Decode` fuzz target.** Build: feed arbitrary bytes to the same
  `Decode()` entry point used in production [R:engine/fabric/ImageStore.cpp (Decode(bytes))].
  *Acceptance gate*: ASan-clean on a 10-minute corpus. *Mutant*: skip the `w<=0||h<=0`
  guard [R:engine/fabric/ImageStore.cpp:L85] — fuzzer must crash immediately.

## 4.3 Sanitizers

**Flutter.** `docs/engine/Using-Sanitizers-with-the-Flutter-Engine.md` documents five
sanitizers (LSan, ASan, UBSan, TSan, MSan-Linux-only), enabled via `gn` flags
(`--lsan`, `--asan`, `--ubsan`, `--tsan`, `--msan`), explicitly **not enabled by default
on presubmits** because of toolchain/platform support gaps, driven instead by
`source ./flutter/testing/sanitizer_suppressions.sh` plus per-sanitizer suppression files
[W: synthesized from local doc content, not a URL — file is
`docs/engine/Using-Sanitizers-with-the-Flutter-Engine.md:L1-9,L45-60` in the pinned repo].
So even upstream Flutter treats sanitizers as an opt-in, suppression-managed diagnostic
tool, not an unconditional CI gate — but the tooling and suppressions files exist and are
exercised by engineers chasing specific bug classes.

**RN-way.** (not confirmed) — not checked against our pinned RN source; out of scope for
a citation here, flagging as unverified rather than asserting it.

**Our engine.** Only two first-party CMake files exist: `engine/CMakeLists.txt`,
`engine/android/CMakeLists.txt` (`find . -iname CMakeLists.txt -not -path "*/_deps/*"
-not -path "*/node_modules/*"`). Neither contains `-fsanitize`
(`grep -l fsanitize` on those two files → zero hits). Every `-fsanitize` hit in the repo
is inside vendored `_deps/folly`, `_deps/boost`, `_deps/fast_float` — those libraries'
own optional test-harness flags, never applied to our target
[R:engine/build/_deps/folly_src-src/CMake/folly-deps.cmake:L281-292]. Net: zero sanitizer
coverage of our own code, ever, in any configuration.

**Gaps.** High. The two most sanitizer-shaped risk zones in our architecture are exactly
the ones the brief calls out: (1) `SceneGraph` mutations applied under one mutex from the
JS thread while the paint thread walks the tree — a TSan target; (2) `ImageStore`'s
detached-thread decode handing a buffer to the paint thread — both a TSan and an ASan
target (lifetime of the decoded buffer across threads).

**Work items.**
- **W5 — ASan+UBSan build variant of the P0-P2 gates.** Model: Flutter's `--asan`
  unopt debug variant pattern [doc cited above]. Build: a `tools/engine-build-asan.sh`
  that configures `engine/CMakeLists.txt` with `-fsanitize=address,undefined
  -fno-sanitize-recover=all`, then runs `ci-headless.sh` and `ci-p2.sh` against that
  binary. *Acceptance gate*: both gates pass clean under ASan+UBSan. *Mutant*: introduce
  a 1-byte heap overflow in `ImageStore::Decode`'s buffer copy — the ASan gate must fail;
  the normal (non-sanitized) gate must still pass (proving ASan is adding real coverage,
  not just being stricter generally).
- **W6 — TSan variant targeting the SceneGraph mutex and the JS/paint handoff.**
  Build: a `tools/engine-build-tsan.sh` variant, run against `ci-animate.sh` /
  `ci-nw-animate.sh` (the gates that actually drive concurrent Fabric mutation + paint).
  *Acceptance gate*: clean TSan run across a 60-second animated fixture. *Mutant*: remove
  the lock around one `SceneGraph` mutation call site — TSan must report a data race;
  the non-TSan gate must still pass (same proof-of-added-value shape as W5).

## 4.4 Validation layers (Metal / Vulkan)

**Flutter.** Metal: command-line Metal API + shader validation is enabled purely via
environment variables — `MTL_DEBUG_LAYER=1`, `MTL_DEBUG_LAYER_ERROR_MODE=assert`,
`MTL_SHADER_VALIDATION=1` [F:docs/engine/impeller/docs/metal_validation.md:L9-19] (path
relative to flutter repo root, not `engine/src/flutter`). Vulkan on Android: validation
layers must be requested at `gn` time with `--enable-vulkan-validation-layers`, which
builds and injects the layers into the Flutter jar, then switched on per-app via an
`AndroidManifest.xml` `<meta-data android:name="io.flutter.embedding.android.EnableVulkanValidation">`
[F:docs/engine/impeller/docs/android_validation_layers.md:L3-24]. Both are developer-invoked
diagnostics, not an always-on CI gate (not found: no `.ci.yaml` job name containing
"validation" — checked `grep -n validation .ci.yaml engine/src/flutter/.ci.yaml`, no match).

**RN-way.** N/A — validation layers are below RN's abstraction level; RN has no concept
of a GPU API validation layer.

**Our engine.** `grep -rln "VK_LAYER_KHRONOS_validation\|MTL_DEBUG_LAYER\|enableValidation"
engine` returns zero hits anywhere in our C++ sources. We run ANGLE-over-Metal and
ANGLE-D3D11 on desktop [R:engine/host/WinGLSurface.cpp:L1,L12-18 (header comment: "ANGLE
(EGL→D3D11)")], and the Android AAR is Vulkan render-only per the brief — none of these
paths ever turn on the underlying API's own validation.

**Gaps.** Medium-high: GPU API misuse (wrong pipeline state, invalid resource binding)
is exactly the class of bug that is silent-until-corrupted-pixels on a driver that
"forgives" it, and loudly crashes/aborts on a stricter driver a user actually has — we
have no mechanism to catch this before it ships.

**Work items.**
- **W7 — Metal API validation in the Mac CI job.** Model: the env-var recipe in
  `metal_validation.md`. Build: set `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert
  MTL_SHADER_VALIDATION=1` in whatever Mac runner executes `ci-p3.sh`'s ANGLE-Metal path.
  *Acceptance gate*: `ci-p3.sh` passes with validation on, with zero validation-triggered
  aborts. *Mutant*: patch the shader call site to bind a texture one mip level short of
  what the pipeline descriptor expects — must abort under `MTL_DEBUG_LAYER_ERROR_MODE=assert`
  and must NOT abort with validation off (proving the layer is actually catching it, not
  masking an unrelated crash).
- **W8 — Vulkan validation layer in the Android AAR instrumentation test.** Model:
  the `--enable-vulkan-validation-layers` + manifest `meta-data` pattern. Build: a debug
  variant of the AAR test app with `EnableVulkanValidation=true` and
  `VK_LAYER_KHRONOS_validation` injected. *Acceptance gate*: the existing Android render
  smoke test passes with validation on, zero `VK_ERROR_VALIDATION_FAILED`-class messages
  in `adb logcat`. *Mutant*: pass a wrong `VkImageLayout` into a texture transition — must
  surface a validation error in logcat.

## 4.5 Driver workarounds and deny-lists

**Flutter.** `DriverInfoVK::IsKnownBadDriver()`
[F:engine/src/flutter/impeller/renderer/backend/vulkan/driver_info_vk.cc:L377-429] denies
or routes around specific GPU/driver combinations by vendor+version, each citing a live
GitHub issue:
- Adreno <= `kAdreno650` falls back to OpenGL ES entirely, citing flutter#178285 and
  flutter#178498 [F:...driver_info_vk.cc:L397-400].
- All Huawei (Maleoon series) GPUs are denied Vulkan, citing flutter#156623
  [F:...driver_info_vk.cc:L403-406].
- Samsung Xclipse is gated on reported Vulkan API version (`>=1.3.0`) rather than driver
  version, because the buggy GPU generation misreports its own driver version, citing
  flutter#161334 [F:...driver_info_vk.cc:L408-416].
- PowerVR below `PowerVRGPU::kBXE` is denied, citing four separate issues
  (flutter#161122, #160960, #160866, #160804, #160406) [F:...driver_info_vk.cc:L418-424].
- A Pixel 10-specific PowerVR driver-version floor (`kPixel10MinDriverVersion`, >=25.1)
  blocks Vulkan init below that version [F:...driver_info_vk.cc:L380-389].
Where Vulkan is still allowed, `GetWorkaroundsFromDriverInfo`
[F:engine/src/flutter/impeller/renderer/backend/vulkan/workarounds_vk.cc:L10-27] (30-line
file) sets four fine-grained flags —`slow_primitive_restart_performance`,
`broken_mipmap_generation`, `input_attachment_self_dependency_broken`,
`batch_submit_command_buffer_timeout`— keyed on `AdrenoGPU <= kAdreno630` or any PowerVR.

**RN-way.** N/A — below RN's abstraction level.

**Our engine.** `grep` for GPU-vendor branching (`AdrenoGPU|PowerVR|Vendor.*GPU` style
logic) in our C++ sources returns nothing — confirmed no per-device deny-list exists.
ANGLE absorbs most GPU/driver quirks on desktop (that is its entire purpose translating
GLES3 to Metal/D3D11), but the Android render-only AAR talks to real device GPUs
(Adreno/Mali/PowerVR/Xclipse) with no equivalent routing logic of our own.

**Gaps.** Medium: the AAR is the one path where we touch real mobile silicon directly,
and it is exactly the surface Flutter's deny-list exists to protect — without it we would
reproduce Flutter's multi-year bug history (Adreno framebuffer-fetch/primitive-restart,
Huawei Maleoon, Samsung Xclipse, PowerVR correctness bugs) one crash report at a time.

**Work items.**
- **W9 — Device/driver deny-list for the Android AAR.** Model:
  `DriverInfoVK::IsKnownBadDriver()`'s structure (vendor check → version-gated return).
  Build: a small `DriverPolicy` table in the AAR's init path keyed on
  `android.os.Build.HARDWARE`/GPU renderer string, falling back to a safer code path
  (lower sample count, no framebuffer-fetch-dependent blur) rather than denying outright,
  since we lack an OpenGL ES fallback on Android. *Acceptance gate*: the AAR's smoke test
  runs green on an emulated "known bad" device profile (spoofed renderer string) and takes
  the fallback path, verified by a log marker. *Mutant*: spoof a known-bad vendor string
  while deleting the policy table lookup — gate must fail (prove the table is consulted,
  not just present).

## 4.6 Benchmarks and perf budgets

**Flutter.** `impeller/geometry/BUILD.gn` defines a standalone `geometry_benchmarks`
executable from `geometry_benchmarks.cc`
[F:engine/src/flutter/impeller/geometry/BUILD.gn:L107-109]. Production perf tracking lives
in `docs/engine/impeller/docs/benchmarks.md`, which lists devicelab driver tests with live
Skia Perf dashboards: *New Gallery* transition_perf on Pixel 7 Pro (Vulkan and OpenGLES
separately, plus a Skia-vs-Impeller 90th/99th-percentile frame-rasterizer-time comparison
view), Samsung S10, Moto G4 (GLES), iPhone 11 (Metal); *Animated Blur Backdrop Filter* and
*Animated Advanced Blend* perf tests on the same device set; a dedicated *Backdrop Filter
Perf* isolate [F:docs/engine/impeller/docs/benchmarks.md:L1-27]. These map to concrete
devicelab task files — ~24 found under `dev/devicelab/bin/tasks/*impeller*.dart`, e.g.
`new_gallery_impeller__transition_perf.dart`,
`complex_layout_scroll_perf_impeller_gles__timeline_summary.dart`,
`hello_world_impeller_macos_sdfs.dart`, `platform_views_scroll_perf_impeller_ios__...`
[F:engine/src/flutter/dev/devicelab/bin/tasks/ (file listing)], wired into `.ci.yaml` under
device-pool task names like `Linux_pixel_7pro new_gallery_impeller__transition_perf`
[F:.ci.yaml:L3373-3390].

**RN-way.** `react/performance/timeline/PerformanceObserver.{h,cpp}` and
`PerformanceEntryReporter.{h,cpp}` expose User-Timing-style marks/measures to JS
[RN:ReactCommon/react/performance/timeline/PerformanceObserver.h]. This is an
instrumentation API for app authors, not a built-in regression-tracked benchmark
dashboard — RN core ships no Skia-Perf equivalent (not confirmed further; no dashboard
code found in the vendored tree, which is expected since that infra would be external).

**Our engine.** No frame-time budget gate exists: `ci-*.sh` scripts assert pixel
correctness/log markers, never a p95/p99 frame-build or raster time against a threshold
(checked by reading `ci-headless.sh`, `ci-eng05-msaa.sh`'s mutation-verify comments — both
are correctness-shaped, not latency-shaped). The one cross-backend performance datapoint
we have is manual: "Mac frame identical to WSL" measured 2026-08-28 by a peer
[R:docs/MAC-DELIVERY.md:L99,L106] — a one-time correctness-equivalence check, not a
tracked, repeated perf measurement.

**Gaps.** High: jank regressions have zero automated detection; our only real-GPU data
point is a single historical manual note, not a live series.

**Work items.**
- **W10 — Frame-build/raster p95/p99 budget gate.** Model: the devicelab
  `timeline_summary` perf tests' percentile reporting
  [F:docs/engine/impeller/docs/benchmarks.md:L7 ("90th_percentile_frame_rasterizer_time")].
  Build: instrument `RunWindowed`/`paintFrame` (brief: `engine/host/main.cpp` ~L620) to
  emit per-frame build+submit+present durations to a JSON log over N frames of a fixed
  animated fixture on `ci-headless.sh`'s llvmpipe backend; compute p95/p99; compare
  against a checked-in budget file; fail on regression beyond a tolerance (e.g. +15%).
  *Acceptance gate*: new `ci-perf-budget.sh` passes on the current binary, with budgets
  seeded from 10 historical runs. *Mutant*: revert `--idle-skip`'s version-counter check so
  every frame re-walks the tree needlessly on a static scene — p95 must regress past the
  threshold and the gate must fail; a no-op commit must not trip it (false-positive guard).
- **W11 — Perf history + regression alarm (local, no Skia-Perf dependency).**
  Build: append each CI run's p95/p99 to a flat JSON-lines history file per fixture;
  a small Python script flags >X% week-over-week drift. *Acceptance gate*: alarm fires on
  a seeded synthetic regression in the history file; stays silent across 20 synthetic
  flat/noisy runs (<5% variance). *Mutant*: a single artificially slow run must NOT by
  itself declare a trend (proves the alarm looks at trend, not one outlier).

## 4.7 Tracing and GPU-side instrumentation

**Flutter.** `fml/trace_event.h` supplies `TRACE_EVENT0`/`TRACE_EVENT1`-family macros;
across `impeller/` these appear in 21 files, 33 call sites total
(`grep -rc "TRACE_EVENT0\|TRACE_EVENT1\|TRACE_EVENT_\|TRACE_EVENT(" impeller --include=*.cc`).
`flow/frame_timings.h` layers a frame-number-tagged wrapper,
`TRACE_EVENT_WITH_FRAME_NUMBER`, on top of the base macro so every traced span can be
correlated back to a specific frame
[F:engine/src/flutter/flow/frame_timings.h:L17-21]. On top of CPU-side tracing, each GPU
backend has its own GPU-timestamp tracer: `GPUTracerVK`
[F:engine/src/flutter/impeller/renderer/backend/vulkan/gpu_tracer_vk.cc:L1-38],
`GPUTracerGLES`, `GPUTracerMTL` — the Vulkan one reads the physical device's
`timestampPeriod` and is compiled active only `#ifdef IMPELLER_DEBUG`
[F:...gpu_tracer_vk.cc:L32-37], i.e. disabled in release builds by construction, not by a
runtime flag.

**RN-way.** `ReactCommon/jsinspector-modern/tracing/` implements a DevTools-Protocol-
shaped tracing export independent of Impeller's `fml` tracing — `HostTargetTracing.cpp`,
`TraceEventGenerator.cpp`, `FrameTimingSequence.h`
[RN:ReactCommon/jsinspector-modern/tracing/FrameTimingSequence.h:L1-7 (Meta copyright),
L19-30 (struct `FrameTimingSequence{id, threadId, beginTimestamp, endTimestamp,
screenshot}`)] — RN's analogue instruments the JS/inspector side with optional
screenshots per sequence, not a native GPU timestamp query.

**Our engine.** Zero `TRACE_EVENT`/Tracy/Perfetto usage anywhere
(`grep -rln "TRACE_EVENT\|Tracy\|perfetto" engine` → no hits). The entire instrumentation
surface is `printf()`: 147 call sites in `engine/host/main.cpp`, 18 in
`engine/scenegraph/SceneGraph.cpp` [R:engine/host/main.cpp (147), R:engine/scenegraph/SceneGraph.cpp (18)].
No GPU timestamp queries anywhere; no structured, filterable, or exportable trace format.

**Gaps.** High: a reported jank or stutter today can only be chased by adding more
`printf` and re-running by hand — there is no flame graph, no GPU-vs-CPU time split, no
way to correlate a JS-thread event with the paint-thread frame it affected.

**Work items.**
- **W12 — Structured TRACE_EVENT-equivalent spans around build/submit/present.**
  Model: `TRACE_EVENT_WITH_FRAME_NUMBER`'s frame-tagging pattern
  [F:...flow/frame_timings.h:L17-21]. Build: a minimal `RNI_TRACE_SCOPE(name)` macro
  writing `{name, frame_number, start_ns, dur_ns}` records to a ring buffer, flushed to
  Chrome Trace Event JSON on exit or on a signal; instrument `paintFrame`'s build/submit/
  present phases. *Acceptance gate*: a `ci-trace.sh` fixture run produces a valid Chrome
  Trace JSON loadable in `chrome://tracing` with >=3 named spans per frame. *Mutant*:
  delete the present-phase span — the gate's span-count assertion must fail.
- **W13 — GPU timestamp tracer for the GLES/ANGLE path.** Model: `GPUTracerGLES`
  [F:engine/src/flutter/impeller/renderer/backend/gles/gpu_tracer_gles.cc]. Build: wrap
  our GLES submit calls with `GL_TIMESTAMP` queries, debug-build-only (mirroring
  Flutter's `#ifdef IMPELLER_DEBUG` gate so release builds pay zero cost). *Acceptance
  gate*: `ci-trace.sh` reports a non-zero GPU time distinct from CPU build time on a
  fixture with an expensive blur. *Mutant*: route the GPU query result into the CPU-time
  field — gate must detect the GPU/CPU split collapsing to a single number and fail.

## 4.8 FrameTiming API and jank measurement

**Flutter.** `FrameTimingsRecorder` is a strict state machine:
`kUninitialized -> kVsync -> kBuildStart -> kBuildEnd -> kRasterStart -> kRasterEnd`
[F:engine/src/flutter/flow/frame_timings.h:L35-41], created on vsync and destroyed after
rasterization, explicitly documented as thread-safe without extra synchronization
[F:...flow/frame_timings.h:L26-29]. `RecordRasterEnd()` produces a `FrameTiming` summary
sent to the framework [F:...flow/frame_timings.h:L97-99], surfaced through
`lib/ui/window/platform_configuration.h`'s frame-timings callback plumbing
[F:engine/src/flutter/lib/ui/window/platform_configuration.h:L540-542] up to Dart's
`SchedulerBinding.addTimingsCallback` — this is the exact mechanism Flutter uses to
measure jank (build time + raster time per frame, bucketed by the app).

**RN-way.** `jsinspector-modern/tracing/FrameTimingSequence.h`'s
`{id, threadId, beginTimestamp, endTimestamp, screenshot}` struct
[RN:ReactCommon/jsinspector-modern/tracing/FrameTimingSequence.h:L19-30] is RN's closest
analogue — it records begin/end per frame sequence with an optional screenshot for the
DevTools profiler, but instruments the JS/bridge side. RN's New Architecture has no
separate raster thread of its own by default (it hands committed trees to the host
platform's own compositor), so RN's frame-timing concept and Flutter's
build/raster-phase split are not a 1:1 match — ours is the renderer that must supply the
raster-phase half Flutter has and RN's own timing model doesn't need.

**Our engine.** No recorder exists at all. `RunWindowed`/`paintFrame`
(brief: `engine/host/main.cpp` ~L620) does event-poll + build + submit + present on one
thread with no timestamps captured anywhere in that path (checked: no `TimePoint`/
`FrameTiming`-shaped type found in `engine/host/` or `engine/scenegraph/`). The
`--idle-skip` flag skips *clean* frames via a scene-version counter but records no
duration for the frames it does not skip.

**Gaps.** High — identical to §4.7's observability gap but specifically blocking any
automated jank SLO: without build/raster timestamps there is no p95/p99 to alarm on (see
W10) and no way to tell a caller "your last commit cost 4ms more build time" the way
Flutter's `addTimingsCallback` can.

**Work items.**
- **W14 — Minimal FrameTimingsRecorder-equivalent.** Model:
  `FrameTimingsRecorder`'s state machine [F:...flow/frame_timings.h:L35-41]. Build: a
  `FrameTiming` struct capturing vsync/build-start/build-end/raster-start/raster-end for
  each `paintFrame` call, exposed via the same trace sink as W12. *Acceptance gate*:
  `ci-trace.sh` output includes all 5 timestamps, monotonically increasing, for every
  frame in a 60-frame run. *Mutant*: skip recording `raster-start` when `--idle-skip`
  short-circuits a frame — gate must detect a missing timestamp rather than silently
  reusing the previous frame's value.

## 4.9 Error handling, validation logging, and crash policy

**Flutter.** `VALIDATION_LOG` [F:engine/src/flutter/impeller/base/validation.h:L91]
streams into `ValidationLog`, whose documented behavior is three-tiered: completely
ignored in Flutter release mode; redirected to `INFO` logging in non-release modes; and
made fatal only if `ImpellerValidationErrorsSetFatal(true)` is set — "usually happens in
test environments" [F:...impeller/base/validation.h:L76-90]. So Flutter's own validation
failures *degrade gracefully in production* and are only made to crash deliberately
inside tests. Separately, 363 `FML_CHECK`/`FML_DCHECK` call sites across `impeller/`
enforce invariants (`grep -rc "FML_CHECK\|FML_DCHECK" impeller --include=*.cc
--include=*.h`, summed) — `FML_CHECK` aborts in all build modes, `FML_DCHECK` only in
debug, giving a deliberate two-tier "always fatal" vs "fatal only when developing" split.

**RN-way.** N/A as a direct 1:1 — Fabric/TurboModule errors on the JS side surface as
catchable JS exceptions through RN's `ErrorUtils`/redbox machinery; that is a different
layer than Impeller's native validation-log/CHECK split, and RN has no native-GPU
equivalent of its own to compare.

**Our engine.** No `FML_CHECK`-equivalent invariant macro exists:
`grep -n "abort()\|std::exit\|assert(\|FML_CHECK\|throw " engine/host/main.cpp` and the
same pattern against `engine/scenegraph/SceneGraph.cpp` both return **zero hits** — there
is no enforced-invariant culture at all in these two core files. Where failure handling
does exist, it degrades gracefully rather than crashing: `ImageStore` maps a failed
network fetch or decode to `nullptr` plus a human-readable `error` string rather than
aborting [R:engine/fabric/ImageStore.cpp:L20,L74,L85-87,L168-180] ("A failed URI maps to
null so the painter does not retry the decode each frame").

**Gaps.** Medium: the *known* failure paths (image decode, network fetch) degrade
cleanly, which is good — but the *absence* of any `CHECK`-equivalent means an unexpected
invariant violation elsewhere (e.g. a `SceneGraph` tag collision, a null surface) has no
defined behavior: it is whatever UB or native crash the surrounding C++ happens to
produce, with no validation log, no structured abort message, and no test-mode-only-fatal
knob to make CI catch it before a release build silently limps on.

**Work items.**
- **W15 — A validation-log macro with Flutter's three-tier behavior.** Model:
  `VALIDATION_LOG`/`ImpellerValidationErrorsSetFatal`
  [F:...impeller/base/validation.h:L46-54,L76-91]. Build: `RNI_VALIDATION_LOG`, release =
  drop (or log-and-continue), debug = log, CI/test mode = fatal via an env-var-settable
  flag the same shape as `ImpellerValidationErrorsSetFatal`. *Acceptance gate*: a seeded
  invariant violation in a debug build logs and continues; the same build with
  `RNI_VALIDATION_FATAL=1` (as `ci-*.sh` would set) aborts with a non-zero exit code.
  *Mutant*: remove the env-var check so it's always fatal — must break an existing
  release-mode gate that currently tolerates the same violation (proves the tiering is
  load-bearing, not decorative).

## 4.10 CI matrix and device coverage

**Flutter.** Two `.ci.yaml` files define the matrix: the repo-root one (7,737 lines) and
`engine/src/flutter/.ci.yaml` (627 lines). Builder pools: Linux (`os: Ubuntu`), Mac
(`os: Mac-15.7`), Windows (`os: Windows-10`)
[F:engine/src/flutter/.ci.yaml:L14-47]. Beyond builder smoke jobs
(`Linux hello_world_impeller_linux`, `Linux texture_impeller_linux`,
`Linux linux_desktop_impeller` [F:.ci.yaml:L1259-1305]), a real-device perf matrix runs
devicelab tasks tagged by device pool: `Linux_pixel_7pro hello_world_impeller`
[F:.ci.yaml:L2575-2582], `Linux_pixel_7pro new_gallery_impeller__transition_perf`
and its `_old_zoom` variant [F:.ci.yaml:L3373-3390], `Linux_galaxy_s24
new_gallery_impeller__transition_perf` [F:.ci.yaml:L3392-3400], `Linux_mokey
complex_layout_android__impeller_gles_start_up` [F:.ci.yaml:L2785-2793]. These map to
~24 devicelab task files under `dev/devicelab/bin/tasks/*impeller*.dart`, covering Linux,
macOS, Windows desktop, Android (Pixel 7 Pro, Galaxy S24, Mokey emulator), and iOS
(`hello_world_impeller_ios_sdfs.dart`) — i.e. every platform Impeller ships on gets at
least one devicelab entry, and the highest-traffic ones (new_gallery transition perf) get
multiple real devices per backend (Vulkan vs GLES on the same Pixel 7 Pro).

**RN-way.** N/A — CI topology, not an RN library concept.

**Our engine.** `ci-all.sh` runs P0-P4 unconditionally on whatever host executes it
(our evidence: `ci-headless.sh` targets Mesa llvmpipe, a CPU software rasterizer, as its
substrate [R:tools/ci-headless.sh:L7-9,L12]). The Windows gate is opt-in, gated behind a
staged native build and `RNI_REQUIRE_WIN=1` to prevent a silent skip from being mistaken
for a pass [R:tools/ci-all.sh:L29-44]. There is no Mac CI at all — the one cross-platform
pixel-equivalence check on record is manual, "measured 2026-08-28" by a peer
[R:docs/MAC-DELIVERY.md:L99,106]. There is no Android emulator/device CI despite shipping
a render-only AAR (`tools/android-build.sh`, `tools/android-probe-build.sh` exist but
nothing in `tools/ci-*.sh` names an Android device gate — checked `ls tools/ci-*android*`
→ only `ci-android-lib.sh`, which per its name builds the library, not a device-driven
pixel/perf test).

**Gaps.** Critical: the *only* automated signal in this program comes from a CPU software
rasterizer. The two backends real users actually hit — ANGLE-over-Metal and
ANGLE-D3D11 — are never exercised by anything that runs unattended; Android's real-GPU
path (Adreno/Mali/PowerVR via Vulkan) has zero automated coverage of any kind.

**Work items.**
- **W16 — Unconditional Mac CI running ANGLE-Metal.** Model: Flutter's `Mac-15.7`
  builder pool and its iPhone-11-Metal devicelab entries. Build: a macOS CI runner that
  executes `ci-p2.sh`/`ci-p3.sh` against the real ANGLE-over-Metal build, replacing the
  current manual "measured by a peer" step. *Acceptance gate*: same P0-P4 gates as Linux,
  running automatically on every PR touching `engine/`. *Mutant*: introduce an
  ANGLE-Metal-only regression (e.g. break the 4x supersample downsample path used only
  on darwin/Windows) — must fail on Mac CI and pass on Linux CI (proves Mac CI is adding
  backend-specific coverage, not duplicating Linux).
- **W17 — Android emulator/device CI for the render-only AAR.** Model: Flutter's
  Mokey-emulator and Pixel-7-Pro-device devicelab entries
  [F:.ci.yaml:L2785-2793,L3373-3380]. Build: an Android emulator job (swiftshader or a
  real-GPU device image) driving the AAR's smoke test headlessly. *Acceptance gate*: the
  AAR renders the same fixture pixel-equivalently (within the W2 tolerance policy) to the
  desktop build. *Mutant*: same supersample-downsample regression as W16, applied on the
  Android path — must be caught here even if W16's Mac job is green (proves per-platform
  independence of the gates, not a shared false sense of coverage).
- **W18 — Windows CI made unconditional, not opt-in.** Build: move `ci-win.sh`
  p2/p3/p4 off `RNI_REQUIRE_WIN` and onto an always-available Windows CI runner now that
  the staged build exists. *Acceptance gate*: Windows P2/P3/P4 run on every PR.
  *Mutant*: reintroduce the DLL-dropped-from-package bug `ci-all.sh`'s own M1 comment
  describes [R:tools/ci-all.sh:L29-36] — the always-on job must catch it; deleting the
  opt-in flag check itself must not silently disable the job (i.e., removing
  `RNI_REQUIRE_WIN` logic should make the gate run by default, not skip by default).

## 4.11 Public rollout story (context, not a gate model)

Flutter shipped Impeller with staged, reversible defaults and a per-platform escape
hatch: iOS is Impeller-only; Android defaults to Impeller on API 29+ with automatic
OpenGL fallback below that or without Vulkan, plus a manifest opt-out; macOS/Linux/
Windows went default-on at Flutter 3.47 with a `--no-enable-impeller` run-time flag,
explicitly temporary ("the ability to opt out... will be removed")
[W:https://docs.flutter.dev/perf/impeller]. Lesson for us: ship new backends (ANGLE-D3D11,
Android Vulkan AAR) behind a runtime kill switch with automatic fallback, removed only
once §4.5/§4.10's device matrix has run long enough in the wild to earn it. **W19**: add
`RNI_FORCE_GLES_FALLBACK`; gate = `ci-p2.sh` passes identically flag-on vs flag-off;
mutant = break the Vulkan/ANGLE path with the flag defaulted off — default-off gate must
fail (fallback isn't silently always-active).

---
**Keep, unchanged:** the `ci-*.sh` (101) + `mutation-verify-*.sh` (92) gate/mutant pairing
has no weakness identified above — it is scoped today to correctness-on-one-CPU-backend.
Every work item here extends that same pairing discipline to new axes (sanitizers,
fuzzing, validation layers, perf budgets, real backends/devices), not replace it.
