#!/usr/bin/env bash
# FP-43 gate: view snapshots, react-native-view-shot's captureRef the Flutter way.
# Model: shell/common/snapshot_controller_impeller.cc (the subtree's display list
# rendered into a fresh offscreen on the raster thread) + image_encoding_impeller.cc
# (readback, encode off the raster thread, callback on the UI thread).
#
# Fixture fixtures/fp43-snapshot (windowed 400x300 pt): a target view (40,30)
# 240x180 pt with bold + regular text, a file:// image and a red marker at its
# bottom-right, plus content OUTSIDE it. After the image loaded JS calls the
# engine's RNViewShot module through package/src/viewshot: png tmpfile, base64,
# data-uri, jpg 0.9, width/height 120x90, captureScreen, a missing tag (must
# reject), and a capture deleted by releaseCapture. tools/snapshot_check.py:
#   * the png equals the on-screen crop of the target (--screenshot of the same
#     run) within 2 levels per channel, opaque, at the device scale, upright
#     (red marker bottom-right; a flipped or window-corner match is named)
#   * base64 / data-uri carry the same png; the jpg has the view's size (and,
#     with PIL, is <= 6 levels off on average); 120x90 is honoured; captureScreen
#     equals the whole window; the missing tag rejects "No view found with reactTag";
#     releaseCapture deleted its file; fileName is the tmpfile prefix
#   * threads: requested on js, recorded on main, rendered on raster (main with
#     --raster-thread off / headless), encoded on `snapshot`, resolved on js
#   * `snapshots requested=8 rendered=7 encoded=7 failed=1 ... released=1`
# ARMS: A scale 1, B scale 2, C scale 2 --raster-thread off, D scale 2 with the
#       root supersample (--supersample-rnsvg 4: the capture renders at 4x and
#       box-filters like the screen), H headless scale 2, M (darwin only)
#       headless scale 2 on --backend metal.
# ENG-47: every snapshot_record line names its readback. Darwin windows and
# arm M render on Metal (readback=metal, SnapshotReadbackMetal.mm); linux and
# darwin's default headless are GL (readback=gl). Before ENG-47 a Metal run
# rejected every capture: "snapshots need a GL render backend on this host".
# Node-free: committed bundle + staged binary (RNI_BIN overrides). Never rebuilds.
# Mutants: tools/mutation-verify-snapshot.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
BUNDLE="$ROOT/fixtures/fp43-snapshot/prebuilt/fp43-snapshot.bundle"
fail() { echo "SNAPSHOT_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (Xvfb) or darwin only"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "no engine binary at $BIN (run tools/engine-build.sh or set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"
if [ "$(rni_host)" = darwin ]; then ARMS="${SNAPSHOT_ARMS:-A B C D H M}"
else ARMS="${SNAPSHOT_ARMS:-A B C D H}"; fi

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
python3 - "$WORK/photo.png" <<'PY'
import struct, sys, zlib
w, h = 120, 80
raw = b"".join(b"\0" + bytes(v for x in range(w) for v in ((x * 255) // w, (y * 255) // h, ((x ^ y) & 31) * 8))
               for y in range(h))
def ch(t, b):
    c = struct.pack(">I", len(b)) + t + b
    return c + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY

run_arm() {  # tag scale ss render_thread mode(window|headless) [extra args...]
  local tag="$1" s="$2" ss="$3" thread="$4" mode="$5"; shift 5
  local dir="$WORK/$tag" rc=0
  mkdir -p "$dir/tmp"
  echo "== $tag: scale $s supersample $ss $mode $*"
  local common=(--scale "$s" --width $((400 * s)) --height $((300 * s)) --supersample-rnsvg "$ss"
                --probe-banner off --app-name Snapshot --bundle "$BUNDLE"
                --initial-url "fp43://run?dir=$WORK" --screenshot "$dir/screen.ppm")
  if [ "$mode" = window ]; then
    TMPDIR="$dir/tmp" rni_xrun "$dir/xauth" timeout 120 "$BIN" --window "${common[@]}" \
      --screenshot-after 2500 --idle-run-sec 4 "$@" > "$dir/run.log" 2>&1 || rc=$?
    [ "$rc" = 0 ] || { tail -15 "$dir/run.log" >&2; fail "$tag: exit $rc"; }
    grep -q '^RN_IMPELLER_WINDOW_OK' "$dir/run.log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  else
    TMPDIR="$dir/tmp" timeout 120 "$BIN" --headless "${common[@]}" --frames 400 "$@" \
      > "$dir/run.log" 2>&1 || rc=$?
    [ "$rc" = 0 ] || { tail -15 "$dir/run.log" >&2; fail "$tag: exit $rc"; }
  fi
  grep -q '^\[js\] FP43 image loaded' "$dir/run.log" || fail "$tag: the fixture's image never loaded"
  [ -s "$dir/screen.ppm" ] || fail "$tag: no screenshot"
  python3 tools/snapshot_check.py "$dir/run.log" "$dir/screen.ppm" "$s" "$tag" "$thread" || exit 1
  # ENG-47: the readback this backend must use (see the header).
  local want=gl
  if [ "$mode" = window ] && [ "$(rni_host)" = darwin ]; then want=metal; fi
  case " $* " in *" --backend metal "*) want=metal ;; esac
  local got
  got="$(sed -n 's/^rn-impeller: snapshot_record .* readback=\([a-z]*\) .*/\1/p' "$dir/run.log" | sort -u | tr '\n' ' ')"
  [ "$got" = "$want " ] || fail "$tag: snapshot readback '${got% }', want '$want'"
  echo "   readback=$want"
}

for arm in $ARMS; do
  case "$arm" in
    A) run_arm A 1 0 raster window ;;
    B) run_arm B 2 0 raster window ;;
    C) run_arm C 2 0 main window --raster-thread off ;;
    D) run_arm D 2 4 raster window ;;
    H) run_arm H 2 0 main headless ;;
    M) [ "$(rni_host)" = darwin ] || fail "arm M (headless --backend metal) is darwin-only"
       run_arm M 2 0 main headless --backend metal ;;
    *) fail "unknown arm $arm" ;;
  esac
done
echo "SNAPSHOT_PASS"
