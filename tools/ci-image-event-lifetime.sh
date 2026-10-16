#!/usr/bin/env bash
# FP-57 IMAGE-EVENT LIFETIME GATE: an <Image> load-start event dispatched by the mount layer
# must not race the teardown that disables its EventEmitter.
#
# Found by ci-sanitize (merge 2026-10-15 14:43 and 18:16, TSan report via ci-typography-threads):
#   read  EventEmitter::dispatchEvent (eventTarget_ copy) <- ImageEventEmitter::onLoadStart
#         <- rni::ImageEventBinding::update <- SceneGraph::applyMutations          (js thread)
#   write EventEmitter::setEnabled(false) (eventTarget_.reset) <- ShadowNode::setMounted
#         <- updateMountedFlag <- ShadowTree::commitEmptyTree <- SurfaceHandler::stop (main)
# RN resets eventTarget_ under EventEmitter::DispatchMutex() (ShadowTree::tryCommit) and
# documents that the mutex guards it (EventEmitter.h setEnabled, EventTarget.h enabled_);
# ImageEvents dispatched without it. A copy racing a reset is a use-after-free of the
# EventTarget control block, so this is a lifetime bug, not only a TSan finding.
#
# A random-timing repro is a flake, so the engine has a probe (RNI_TEST_IMAGE_EVENT_STALL_MS,
# scenegraph/ImageEvents.cpp): once the windowed loop runs, the first JS-thread mount asks the
# loop to quit and waits until main left it, then mounts; its onLoadStart parks (mount lock
# held, as in the report) until FabricHost::stopSurface has started the empty-tree commit,
# then dispatches.
#   A  TSan binary x3: probe resumed with surface_stopped=1, and ZERO TSan reports
#   B  RNI_BIN (the ASan binary under ci-sanitize, else the staged release binary) x2:
#      the same probe exits 0 with surface_stopped=1 (ASan sees any use-after-free)
# Node-free: prebuilt fixtures/fp33-memory-budget bundle, file:// PNGs.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-image-event-lifetime.XXXX")"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
fail() { echo "IMAGE_EVENT_LIFETIME_FAIL: $*"; exit 1; }
export RNI_TIME_SCALE="${RNI_TIME_SCALE:-4}"
BUNDLE="$ROOT/fixtures/fp33-memory-budget/prebuilt/fp33-memory-budget.bundle"
[ -f "$BUNDLE" ] || fail "no prebuilt bundle $BUNDLE"
command -v xvfb-run >/dev/null || fail "xvfb-run is required"
# A cap, not a duration: the probe resumes as soon as the teardown starts. The quit path
# waits up to ScaledMs(5000) for the parked JS thread first, so the probe runs at scale 1.
STALL_MS="${IMAGE_EVENT_STALL_MS:-30000}"

mkdir -p "$WORK/img"
python3 tools/image_upload_gate.py gen "$WORK/img" 6 50 > /dev/null || fail "could not write the test PNGs"
# One image at a time: img-<k+1> mounts when img-k reported onLoad, so mounts keep arriving
# after the loop started (the probe arms there). Nothing animates and --idle-skip paints only
# on damage, so the mount that follows a load is the probe's.
URL="fp33://cycle?dir=$WORK/img&count=6&per=1&box=50"

# One probe run. name bin [env...]
probe() {
  local name="$1" bin="$2"; shift 2
  local dir="$WORK/$name" rc; mkdir -p "$dir"
  ( cd "$(dirname "$bin")" && env "$@" RNI_TIME_SCALE=1 RNI_TEST_IMAGE_EVENT_STALL_MS="$STALL_MS" timeout -k 10 300 \
      xvfb-run -a -f "$dir/xauth" -s "-screen 0 1280x1024x24" "$bin" --window --scale 1 \
      --bundle "$BUNDLE" --app-name Fp33MemoryBudget --initial-url "$URL" --width 200 --height 150 \
      --probe-banner off --supersample-rnsvg 0 --frames 100000 --idle-skip --quit-on-term ) > "$dir/run.log" 2>&1
  rc=$?
  [ "$rc" = 0 ] || { tail -12 "$dir/run.log"; fail "$name exited rc=$rc"; }
  grep -q '^rn-impeller: image_event_probe mount_after_quit loop_exited=1' "$dir/run.log" \
    || fail "$name: no JS-thread mount after the quit request left the loop ($(grep -m1 'mount_after_quit' "$dir/run.log"))"
  grep -q '^rn-impeller: image_event_probe parked' "$dir/run.log" \
    || fail "$name: the probe never parked (no onLoadStart dispatched: image not mounted?)"
  grep -q '^rn-impeller: image_event_probe resumed surface_stopped=1' "$dir/run.log" \
    || fail "$name: the probe resumed before the teardown commit ($(grep -m1 'image_event_probe resumed' "$dir/run.log")): the window the race needs never opened"
}

echo "== A. TSan binary"
if [ "${SKIP_TSAN:-0}" = 1 ]; then
  echo "SKIPPED (SKIP_TSAN=1)"
else
  # ci-tsan.sh builds engine/build-tsan; its env hygiene keeps an outer ASan/UBSan suite's
  # log_path from swallowing these reports.
  env -u RNI_BIN bash tools/ci-tsan.sh --build-only > "$WORK/tsan-build.log" 2>&1 \
    || { tail -15 "$WORK/tsan-build.log"; fail "TSan build failed"; }
  TBIN="$ROOT/engine/build-tsan/stage/bin/rn-impeller"
  SYMBOLIZER="$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer-* 2>/dev/null | sort -V | tail -1)"
  for i in 1 2 3; do
    d="$WORK/tsan-$i"; mkdir -p "$d"
    probe "tsan-$i" "$TBIN" -u ASAN_OPTIONS -u UBSAN_OPTIONS -u LSAN_OPTIONS -u RNI_SANITIZE_STAMP_DIR \
      TSAN_OPTIONS="log_path=$d/tsan exitcode=0 halt_on_error=0 history_size=4 external_symbolizer_path=$SYMBOLIZER suppressions=$ROOT/tools/sanitize/tsan_suppressions.txt"
    n="$(find "$d" -maxdepth 1 -name 'tsan.*' -type f | wc -l)"
    if [ "$n" -gt 0 ]; then
      f="$(ls "$d"/tsan.* | head -1)"
      grep -m1 -E '^(WARNING|ERROR): ThreadSanitizer' "$f"
      grep -E '^    #[0-9]+ ' "$f" | grep -m6 -E 'ImageEvent|EventEmitter|setMounted|commitEmptyTree' | cut -c1-160
      kind="$(grep -h -m1 -oE 'ThreadSanitizer: [a-z -]+[a-z]' "$d"/tsan.* | head -1)"
      read_side=no; write_side=no
      grep -q 'rni::ImageEventBinding::update' "$f" && read_side=yes
      grep -q 'EventEmitter::setEnabled' "$f" && write_side=yes
      fail "tsan-$i: $n TSan report file(s), first: $kind (dispatch in ImageEventBinding::update=$read_side vs EventEmitter::setEnabled in teardown=$write_side): onLoadStart dispatched without EventEmitter::DispatchMutex while the teardown commit disabled the emitter"
    fi
    echo "ok tsan-$i surface_stopped=1 reports=0"
  done
fi

echo "== B. RNI_BIN arm"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "no engine binary at $BIN (run tools/engine-build.sh linux x64)"
for i in 1 2; do
  probe "bin-$i" "$BIN"
  echo "ok bin-$i surface_stopped=1 exit=0"
done
echo "IMAGE_EVENT_LIFETIME_PASS (TSan x3 + $(basename "$(dirname "$(dirname "$BIN")")") x2: onLoadStart parked across the teardown commit, 0 reports)"
