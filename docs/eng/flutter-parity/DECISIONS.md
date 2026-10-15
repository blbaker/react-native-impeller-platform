# Decisions log: Flutter-parity rendering engine

Every directive from Baker (verbatim, with the Discord message time) and every design or process
decision made on his behalf, newest last. A decision made on his behalf says so and says how to
reverse it. The PR description links here; keep it current.

## Baker's directives

| When (CDT) | Directive (verbatim) | Discord message |
|---|---|---|
| 2026-10-14 19:12 | "Use GitHub and open source to research Impeller and how Flutter utilizes Impeller for all aspects of the rendering engine. Make sure we follow that strictly but in a RN way. This needs to be an enterprise grade, bulletproof rendering engine for RN." | <discord-id> (thread <discord-id>) |
| 2026-10-14 19:41 | "Go now, plan it all out and then get to work until it's done" | <discord-id> |
| 2026-10-14 23:00 | "Make sure to save all of this for the PR and documentation" | <discord-id> |
| 2026-10-14 23:09 | "Merge as needed to keep things going but always include this visual and written documentation in the PR and repo. I want this done ASAP without me" | <discord-id> |

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

## Process decisions made on Baker's behalf (reverse any of them by saying so)

1. **Execution model:** a pass loop (`tools/parity-loop.sh`, systemd unit `rni-parity`) runs one agent
   session per pass, and each pass is one commit. It is modelled on the style-fix loop that shipped SC-01..SC-45.
   Supervision: a watchdog timer every 20 min handles restart, hang stop (over 7 h) and a 2 h heartbeat.
2. **Branch:** `feat/flutter-parity`, based on `c07048d` (what the Mac runs; it contains main). FP-00
   merged `feat/win-window-on-7111345` into it. The PR therefore targets `feat/native-anim-transform`
   until that branch lands on main.
3. **Merging (superseded 23:09, see below).** Until 23:09 nothing merged without Baker's ✅. His 23:09
   order made verified merges standing policy.
4. **Visual evidence:** passes that change pixels post before/after evidence to the thread and save it under
   `evidence/`. They commit to the feature branch without waiting for a per-pass ✅, because Baker
   asked for run-to-done. His review gate is the merge.
5. **Mac isolation:** the loop builds darwin in its own Mac tree (`a local worktree`). The Mac
   agent's tree and its staged binary are never touched.
6. **Shared SDK dirs are never overwritten.** Rebuilt SDKs go to `impeller-sdk-custom-parity*`.
7. **Blocked passes:** they get an immediate triage session. It either queues a different approach or asks
   Baker in the thread with numbered options. Device-dependent passes (Android) ask rather than fake a result.
8. **Documentation is part of done:**
   - Every pass's session summary, the loop log, evidence images and the PR body are committed under
     `docs/eng/flutter-parity/`.
   - `PROGRESS.md` and `PR.md` are regenerated every 20 min by `tools/parity-record-progress.sh`.
   - The draft PR body is synced from `PR.md`.

## Process decisions after the 23:09 order ("merge as needed ... ASAP without me")

9. **Verified merges into main, no per-merge approval.** `tools/parity-merge.sh` (started by the watchdog as unit
   `rni-parity-merge`) merges a lane when another lane needs its work, when a phase finishes, when the lane is done, or
   when 3+ passes have waited 4 h. It first proves the lane tip merged with main: fresh linux build, the 16 core gates and
   every linux gate of the passes being merged. It then opens a PR into main whose body is the generated PR doc (status,
   the passes, embedded evidence images, Mermaid diagrams, links to every doc) and merges it over the REST API pinned to
   the verified SHA. To stop merges: `systemctl --user stop rni-parity-watchdog.timer` (also stops restarts and
   heartbeats) or delete `tools/parity-merge.sh`'s executable bit in lane A's worktree.
10. **Two lanes for speed.** Lane B (`PASSES-B.md`, branch `feat/flutter-parity-b`) runs FP-16, FP-22, FP-52, FP-24 and
    FP-25 in parallel with lane A at a lower CPU weight, so timing gates in lane A keep priority. Lanes exchange work
    through main. Lane A passes that need lane B work (FP-17, FP-23, FP-33) wait for the merge.
11. **Triage decides instead of asking.** A blocked pass's triage session now picks the next approach itself, records the
    call below, and posts an FYI. It asks Baker only when nothing can move without his hands, money or credentials.
12. **Visual docs in the repo and every PR:** `DIAGRAMS.md` (thread model, backend per OS, how a change lands; Mermaid,
    rendered by GitHub), evidence PNGs under `evidence/`, and the research PDF. Each merge PR embeds the first two
    diagrams and the evidence of every pass it carries.

## Calls made by triage

(Appended by triage sessions: date, pass, what was chosen, why.)
