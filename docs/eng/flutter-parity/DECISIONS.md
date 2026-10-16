# Decisions log: Flutter-parity rendering engine

Baker's directives for this work (verbatim), the research and architecture decisions that
followed, the engineering calls made along the way, and the measured results. Decisions about
how the internal automation loop that did the work was run (branches, merges, parallel lanes,
triage policy) are not part of this public copy.

## Baker's directives

| When (CDT) | Directive (verbatim) |
|---|---|
| 2026-10-14 19:12 | "Use GitHub and open source to research Impeller and how Flutter utilizes Impeller for all aspects of the rendering engine. Make sure we follow that strictly but in a RN way. This needs to be an enterprise grade, bulletproof rendering engine for RN." |
| 2026-10-14 19:41 | "Go now, plan it all out and then get to work until it's done" |
| 2026-10-14 23:00 | "Make sure to save all of this for the PR and documentation" |
| 2026-10-14 23:09 | "Merge as needed to keep things going but always include this visual and written documentation in the PR and repo. I want this done ASAP without me" |

## Research decisions (2026-10-14)

1. **Primary sources only, pinned.** The study reads flutter/flutter at `114eb184d66d`, the exact commit
   our custom Impeller SDK is built from (`engine/IMPELLER_SHA`), from a full local checkout, and
   checks it against master `200fdfbd`. Every claim cites file:line. 335 citations were checked by
   `tools/flutter-parity-cite-audit.py`, and 22 load-bearing ones were re-read by hand (one 4-line drift fixed).
   Method: `research/METHOD.md`.
2. **"Strictly, the RN way" was read as:** copy Flutter's mechanisms (thread roles, frame pipeline,
   discard rules, backend choice per OS, caches, test layers) without breaking RN's contracts. Those
   contracts are: JS owns React, Fabric commits immutable revisions, mount happens on the platform
   thread, NativeAnimated runs off the JS thread, and RN's public JS APIs and module names stay the same.

## Architecture decisions (from SPEC.md; each cites Flutter source there)

1. **Threads:** platform (main), JS (= Flutter UI), raster, IO pool. The hand-off is an immutable
   frame item (ImpellerDisplayList + metadata) through a depth-2 pipeline modelled on
   `shell/common/pipeline.h`. Headless stays single-threaded, like `flutter_tester`.
2. **Backends follow Flutter per OS:**
   - Native Metal on macOS/iOS.
   - Vulkan with a GLES fallback and a known-bad-driver list on Android.
   - GLES on ANGLE-D3D11 on Windows, and GLES on Linux (both unchanged, because that is exactly what Flutter does).
   - Windows/Linux are deliberately NOT moved to Vulkan.
3. **Anti-aliasing policy:**
   - Metal and Vulkan use the surface's 4x MSAA.
   - GL keeps our supersample hooks, because Flutter's own desktop GL root is 1x too.
   - Analytic SDF AA is exposed through SDK patch 0003. It is opt-in until goldens agree.
4. **No raster cache.** Flutter disables it under Impeller.
5. **Partial repaint:** follows Flutter's 0.7 ratio rule.
6. **One typography context per thread.** impeller.h says typography contexts are single-thread, and we were
   sharing one between measure (JS thread) and paint (main thread).
7. **Goldens on every backend we ship.** This goes beyond Flutter, whose Impeller goldens are macOS/Metal only.

## Engineering calls made during the work

(Date, pass, what was chosen, why.)

- 2026-10-15 (FP-22): SDK patch 0003 uses a process-wide default (`ImpellerContextSetDefaultFlags`, read by every interop backend Create) plus a per-context readback (`ImpellerContextGetFlags`). One entry covers GLES, Metal and Vulkan, and no new Create variants are needed. `--sdf-aa` defaults to off until per-backend goldens agree.
- 2026-10-15 (FP-19): (a) superseded by FP-26 (Phase 1 proof with darwin ci-vsync limited to scheduler arms C/D) and FP-27 (Phase 2, darwin present pacing on Metal via CVDisplayLink + presentedTime, full ci-vsync). Why: A/B fail from ANGLE-Metal drawable waits on a shared Mac at load 37-122; Flutter macOS paces on Metal, so FP-21 is where pacing can be proven. Phase 1 had no free id, so FP-26 sits in the Phase 1 section with a Phase 2 number.
- 2026-10-15 (FP-21): the gate's "icon-edge AA metric at N=0 >= the ANGLE N=4 metric" was measured false and
  replaced by "Metal N=0 carries real AA, clearly better than ANGLE N=0" (N=4 numbers printed, not asserted). Why: Impeller's
  Metal drawable wrap is fixed 4x MSAA (swapchain_transients_mtl.mm), 3 intermediate levels vs 15 for a 4x4 supersample;
  chevron edge error vs an N=16 reference is 6.69 (Metal N=0) vs 2.71 (ANGLE N=4). Flutter ships exactly this 4x MSAA on
  macOS, so it is the parity target; supersampling on Metal would need an offscreen surface (patch 0004, FP-23).

## Results (FP-56, 2026-10-16)

Numbers come from commit bodies, `tools/perf/budgets.json` and the evidence files. "Before" is the
pre-pass binary of the pass named in the source column unless it says otherwise. The pre-loop base `840961d` had no frame
recorder (FP-01 added it), so no frame-time number exists for it. Where a number was never measured the cell says so.

| Metric | Before (pre-loop base 840961d or pre-pass) | After | Source (commit / gate / evidence file) |
|---|---|---|---|
| Frame time, linux windowed NativeRotate (xvfb, Mesa llvmpipe) | 840961d: not measured. First FP-01 baseline (400x300 NativeRotateProbe): build p50 ~18 us, raster p50 ~620 us, total p95 ~0.9-1.1 ms; p95/p99 of build and raster not recorded. | `native-rotate` 5-run medians: build p95 39 us / p99 66 us, raster p95 1368 us / p99 2029 us, total p95 4128 us / p99 15926 us. Total grew from ~1.3 ms to ~4 ms when the FP-15 raster thread merged. | FP-01 `8d25b0b` (baseline in the commit body); FP-53 `973fe4d` + FP-34 `7f1ef8b` re-record, `tools/perf/budgets.json`, `tools/ci-perf.sh` |
| Frame time, linux windowed style-g2 (xvfb, Mesa llvmpipe) | 840961d: not measured. First FP-53 baseline (lane B tree before FP-15 merged): build p95 4906 / p99 6185 us, raster p95 6472 / p99 10135 us, total p95 11928 / p99 33603 us. | build p95 3508 / p99 5051 us, raster p95 758 / p99 1050 us, total p95 4403 / p99 28711 us. Both are medians on a shared box; style-g2 build p95 was seen moving 3.4 to 5.7 ms under load with no code change. | `tools/perf/budgets.json` at `973fe4d` and at `7f1ef8b`, `tools/ci-perf.sh`, evidence/FP-53-perf-budgets.png |
| Frame time, darwin (Mac) | ANGLE-Metal on the shared Mac (load 37-122), ci-vsync fixture: raster p50 1.3 ms, raster p95 ~16.9 ms (drawable waits). Host app on 840961d: not measured. p99: not measured. | The host app (a production RN app, new engine swapped in) on native Metal: 491 nodes, frame p95 9.0 ms, raster p95 2.0 ms, first frame 973 ms. p99: not measured. Different fixture from the "before" column. | FP-19, FP-21; measured by hand on the Mac (the app screenshot is not included: it showed private data) |
| AA, chevron edge error vs an ANGLE N=16 reference (Mac) | ANGLE N=0: error 8.25, 0% partial edge px. ANGLE N=4 (the old darwin default): error 2.71, 46.6% partial. | Metal N=0 (4x MSAA, new default): error 6.69, 25.3% partial. The gate asserts better than ANGLE N=0, not equal to ANGLE N=4. | FP-21 `7d49e38`, `tools/ci-metal.sh` arm AA, evidence/FP-21-metal-aa.png |
| Supersample on darwin windowed (Mac) | ANGLE path, supersample 4 by default. | Metal, supersample 0 by default. Metal N=0 vs ANGLE N=4 over 7 fixtures: mean diff <= 1.0, worst is text at mean 0.74 and 1.53% of px off by more than 24. | FP-21 `7d49e38`, `tools/ci-metal.sh` arm P |
| SDF partial coverage, headless GL at supersample 0 (linux, Mesa llvmpipe) | `--sdf-aa off`: oval 0, rounded rect 0 partial-coverage px. | `--sdf-aa on`: oval 340, rounded rect 112, circle 260 partial px (circle edge changes on 284 px). Default stays off. The first SDF frame compiles uber_sdf: raster p50 631 ms vs 9 ms. | FP-22 `1c2741a`, `tools/ci-sdf-aa.sh`, evidence/FP-22-sdf-aa.png |
| JS-stall lag of a native-driver Animated.timing (50 ms JS stall every other frame) | linux xvfb: 49-53 frames (53.0 in the commit's pre-pass run). darwin: not measured. | linux xvfb: 0.0 frames (control 0.0). darwin ANGLE-Metal: 0.0 / 0.0, cadence 159/159. | FP-10 `98de570`, `tools/ci-native-anim-jsstall.sh` |
| Image RSS, 8000x6000 PNG in a 200x200 box (linux headless) | Peak RSS delta 365 MB over a 200x200 control. Upload size: not measured. | Peak RSS delta +0 MB; one upload of 341x256 (limit 2x box). | FP-16 `4c333ef`, `tools/ci-image-io.sh` arm big, evidence/FP-16-image-io.png |
| Image decode threads, 200 distinct images (linux headless) | One detached thread per image. 200 peak live decode threads, measured on mutant M1, which restores that code; the pre-pass binary stopped at the RSS arm first. | 4 peak live decodes (= pool size), 4 rni-image-io OS threads, peak process threads equal to a 1-image control. | FP-16 `4c333ef`, `tools/ci-image-io.sh` arm threads |
| Image memory budget, 500 distinct 256x256 images (linux headless) | Unbounded control: RSS 303560 KB. | 6 MB budget: cache peak 6291456 B, 476 evictions; RSS 182028 KB (250 images) vs 184688 KB (500 images), so it plateaus. Low-memory purge to floor 0 empties the cache. | FP-33 `e1db04c`, `tools/ci-memory-budget.sh`, evidence/FP-33-memory-budget.png |
| Raster p99 with 30 x 8 MB image uploads during an animation (linux windowed xvfb, llvmpipe, LP_NUM_THREADS=2) | 4357 us vs 1365 us for the preloaded control. | 1383 us vs 1229 us for the control (limit 1.2x). | FP-17 `1c2072c`, `tools/ci-image-upload.sh`, evidence/FP-17-image-upload-raster.png |
| Images on screen over the cache budget: 30 x 8 MB visible images, 100 MiB default budget (linux windowed xvfb, ci-image-upload arrive arm) | FP-33 tree (budget evicts on-screen bitmaps): 3613 decodes, 3582 reloads, 3613 IO uploads in 600 frames; raster p99 51.9 ms. FP-17 had measured 1.4 ms before FP-33 landed. | FP-56 keep-alive: 31 uploads, 0 reloads, raster p99 3.99 ms in the same single run; the gate's 7-rep medians are 2827 us arrive vs 3192 us control. ci-memory-budget arm `live` (8 visible images, 0.5 MB budget): 12 reloads, 903 with the keep-alive removed. | FP-56, `tools/ci-image-upload.sh`, `tools/ci-memory-budget.sh` arm live |
| Present pacing, linux windowed (xvfb) | The pre-pass binary has no vsync log; `--vsync off` reproduces its free-running loop at one present every ~0.9 ms. | Mean interval 16654-16671 us vs the 16666 us period; sd 0.4-0.6 ms on a quiet box, 2.0 ms at load 20+. | FP-11 `90b6482`, `tools/ci-vsync.sh`, evidence/FP-11-present-intervals.png |
| Present pacing, darwin windowed (Mac) | ANGLE-Metal (FP-19): median 16677 us, sd 5995 us, 30 of 360 intervals under half a period. | Metal + CVDisplayLink (FP-27): median 16680 us vs the 16680 us period, sd 1 us, 0 short intervals, displayed 1.00 period after the target vblank. | FP-19; FP-27 `e35d0b6`, `tools/ci-metal-pacing.sh`, `tools/ci-vsync.sh`, evidence/FP-27-metal-pacing.png |
| Partial repaint, spinner over 300 static tiles (linux windowed, llvmpipe 800x600) | Full repaint every frame: raster p50 8.2 ms, build p50 3.8 ms. p95: not measured. | Median 0.80% of the surface repainted (max 0.90%), raster p50 1.9 ms, build p50 4.9 ms; 0 of 300 partial frames differ from a full repaint. p95: not measured. | FP-18 `fc29cab`, `tools/ci-partial-repaint.sh`, evidence/FP-18-partial-repaint.png |
| Queued frame during a 50 ms main-thread stall (linux windowed xvfb) | `--raster-thread off`: 0 presents during the stall. | 2 presents during the stall, the first 12 ms in. darwin ANGLE-Metal: presents 32-33 ms into a ~55 ms stall. | FP-15 `9466013`, `tools/ci-raster-thread.sh`, evidence/FP-15-raster-thread-stall.png |
