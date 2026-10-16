#!/usr/bin/env bash
# FP-26 GATE: the FrameScheduler's scheduler arms of tools/ci-vsync.sh only.
#   tick  every spin run reads back shared_tick=0 (no two presents serve one vsync
#         tick) and frame_scheduler max_frames_per_tick=1
#   C     idle: a static scene presents 0 frames in a 2 s window once settled
#   D     mutation: one damage request presents within 2 periods, 1-2 presents
# Arms A (present-interval pacing) and B's short-interval count are left out
# because they time eglSwapBuffers returns. On darwin ANGLE-Metal that call returns
# in ~20 us and the CAMetalLayer drawable wait lands inside the draw, so the
# interval measures drawable starvation on a shared Mac, not the scheduler. That is
# not the path Flutter ships on macOS (Metal + FlutterVSyncWaiter, see
# engine/src/flutter/shell/platform/darwin/macos/framework/Source/
# FlutterVSyncWaiter.mm); FP-27 proves
# pacing on the Metal backend. Linux and every other caller keep `ci-vsync.sh`'s
# full A-D (it is in tools/parity-core-gates.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
VSYNC_ARMS="tick C D" exec bash tools/ci-vsync.sh "$@"
