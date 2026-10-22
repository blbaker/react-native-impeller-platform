#!/usr/bin/env bash
# BLUR OVER MOVING CONTENT GATE: an expo-blur <BlurView> re-blurs what moves
# beneath it, with the windowed loop's partial repaint on.
#
# fixtures/blur-scroll: a ScrollView of colour tiles at (0,80)..(400,400) under
# a BlurView header (0,0)..(400,140). The header straddles the ScrollView's top
# edge: its top 80 px sit over a static background, but its blur (sigma ~35 px)
# reaches into the tiles. BlurScrollMotion scrolls 0 -> 100 in 5 px steps;
# BlurScrollStatic starts at 100.
#
# Instrument: RNI_TEST_PRESENTED_CAPTURE (host/PresentedCapture.h), what is ON
# SCREEN, captured without asking for a frame (a pending --screenshot would make
# the loop paint every frame in full and hide exactly the partial repaint this
# gate is about).
#
# Arms (each failure prints `BLUR_SCROLL FAIL <arm>: ...`):
#   M  moved: the header's pixels at offset 100 differ from offset 0, above the
#      ScrollView (0..80) and over it (80..140): the blur follows the content
#   S  not stale: after the scroll the screen equals the BlurScrollStatic
#      reference (the same scene painted at 100 from the start), header included
#   C  control: the same scroll with --partial-repaint off also equals the
#      reference, so S compares like with like (the instrument, the fixture and
#      the reference agree when nothing is partial)
#   V  the engine's own per-frame check (RNI_TEST_PARTIAL_VERIFY=1, host/
#      PartialRepaintGl.cpp): every partial frame of the tile run, redrawn in
#      full and compared, must match (partial_verify mismatched_frames=0)
#   P  the loop's damage log: the scroll repaints the whole window each step (a
#      scroll offset has no tag), the tile run repaints only part of it -- the
#      case where a blur straddling the repainted area could go stale
# Linux needs an X display: one private Xvfb is started when DISPLAY is unset.
#   RNI_BIN=<rn-impeller> bash tools/ci-blur-scroll.sh
# Mutants: tools/mutation-verify-blur-scroll.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RNI_BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="$ROOT/fixtures/blur-scroll/prebuilt/blur-scroll.bundle"
fail() { echo "BLUR_SCROLL FAIL $*"; FAILS=$((FAILS + 1)); }
FAILS=0
[ -x "$RNI_BIN" ] || { echo "BLUR_SCROLL FAIL setup: no engine at $RNI_BIN"; exit 1; }
[ -f "$BUNDLE" ] || { echo "BLUR_SCROLL FAIL setup: no bundle $BUNDLE"; exit 1; }

OUT="$(mktemp -d "${TMPDIR:-/tmp}/blurscroll.XXXXXX")"
XPID=""
cleanup() { [ -n "$XPID" ] && kill "$XPID" 2> /dev/null; [ -n "${KEEP_WORKDIR:-}" ] || rm -rf "$OUT"; }
trap cleanup EXIT
if [ "$(uname -s)" != Darwin ] && [ -z "${DISPLAY:-}" ]; then
  for n in 97 98 99 96; do [ -e "/tmp/.X11-unix/X$n" ] || { DNUM=$n; break; }; done
  Xvfb ":$DNUM" -screen 0 1280x1024x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
  XPID=$!
  export DISPLAY=":$DNUM"
  for _ in $(seq 1 40); do [ -e "/tmp/.X11-unix/X$DNUM" ] && break; sleep 0.1; done
fi
WINDOW_FLAG="${BLUR_SCROLL_WINDOW_FLAG:---window}"

# run <tag> <app> <partial on|off> <shots: "ready:<ms>" and/or "done:<ms>">
run() {
  local tag="$1" app="$2" partial="$3"
  shift 3
  mkdir -p "$OUT/$tag/cap"
  RNI_DAMAGE_LOG=1 RNI_TEST_PRESENTED_CAPTURE="$OUT/$tag/cap" env ${RUN_ENV:-} "$RNI_BIN" "$WINDOW_FLAG" --probe-banner off \
    --bundle "$BUNDLE" --app-name "$app" --idle-skip --idle-log --partial-repaint "$partial" \
    --idle-run-sec 12 --width 400 --height 400 ${BLUR_SCROLL_EXTRA_FLAGS:-} > "$OUT/$tag/run.log" 2>&1 &
  local pid=$!
  python3 - "$OUT/$tag" "$pid" "$@" << 'PY'
import os, re, sys, time
d, pid, shots = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
log = os.path.join(d, "run.log")
def alive():
    try: os.kill(pid, 0); return True
    except OSError: return False
def wait_line(pat, t):
    end = time.time() + t
    while time.time() < end:
        if os.path.exists(log) and re.search(pat, open(log, errors="replace").read()): return True
        if not alive(): return False
        time.sleep(0.05)
    return False
for k, s in enumerate(shots, start=1):  # PresentedCapture serves req-1, req-2, ... in order
    what, ms = s.split(":")
    pat = r"BLURSCROLL ready" if what == "ready" else r"BLURSCROLL done"
    if not wait_line(pat, 20): print(f"no '{pat}' line"); sys.exit(1)
    time.sleep(int(ms) / 1000)
    open(os.path.join(d, "cap", f"req-{k}"), "w").close()
    end = time.time() + 5
    while time.time() < end and not os.path.exists(os.path.join(d, "cap", f"shot-{k}.done")): time.sleep(0.02)
    if not os.path.exists(os.path.join(d, "cap", f"shot-{k}.done")): print(f"capture {k} timed out"); sys.exit(1)
PY
  local prc=$?
  # RUN_WAIT_EXIT=1: let --idle-run-sec end the run; summary lines
  # (partial_verify, partial_repaint) print only on a clean exit.
  [ "${RUN_WAIT_EXIT:-0}" = 1 ] || kill "$pid" 2> /dev/null
  wait "$pid" 2> /dev/null
  return $prc
}

echo "== runs =="
run motion BlurScrollMotion on ready:400 done:500 || fail "setup: motion run: $(tail -3 "$OUT/motion/run.log" | tr '\n' ' ')"
run static BlurScrollStatic on ready:400 || fail "setup: static run"
run control BlurScrollMotion off done:500 || fail "setup: control run"
run tile BlurTileChange on ready:400 done:500 || fail "setup: tile run: $(tail -3 "$OUT/tile/run.log" | tr '\n' ' ')"
run tilestatic BlurTileStatic on ready:400 || fail "setup: tile static run"
run tilecontrol BlurTileChange off done:500 || fail "setup: tile control run"
RUN_ENV="RNI_TEST_PARTIAL_VERIFY=1" RUN_WAIT_EXIT=1 run tileverify BlurTileChange on done:500 || fail "setup: tile verify run"
grep -E 'presented_capture' "$OUT"/*/run.log | sed "s#$OUT/##" | head -6

C="$OUT"
for k in motion/cap/shot-1 motion/cap/shot-2 static/cap/shot-1 control/cap/shot-1 tile/cap/shot-1 tile/cap/shot-2 \
  tilestatic/cap/shot-1 tilecontrol/cap/shot-1; do
  [ -s "$C/$k.ppm" ] || echo "FAIL setup: missing capture $k" >> "$OUT/verdict.txt"
done
if [ ! -s "$OUT/verdict.txt" ]; then
  python3 tools/blur_scroll_compare.py scroll 1 "$C/motion/cap/shot-1.ppm" "$C/motion/cap/shot-2.ppm" \
    "$C/static/cap/shot-1.ppm" "$C/control/cap/shot-1.ppm" >> "$OUT/verdict.txt"
  python3 tools/blur_scroll_compare.py tile 1 "$C/tile/cap/shot-1.ppm" "$C/tile/cap/shot-2.ppm" \
    "$C/tilestatic/cap/shot-1.ppm" "$C/tilecontrol/cap/shot-1.ppm" >> "$OUT/verdict.txt"
fi
cat "$OUT/verdict.txt"
while IFS= read -r l; do case "$l" in FAIL\ *) fail "${l#FAIL }" ;; esac; done < "$OUT/verdict.txt"

echo "== P: what the loop repainted =="
# RNI_DAMAGE_LOG=1: one `damage frame= ... mode=full|partial|none ... reason=` line
# per frame (host/PartialRepaintGl.cpp). A scroll offset has no tag, so a scroll
# repaints the whole window (that is why the scroll arms above cannot go stale);
# the tile run must have repainted only part of it, or its S arm proves nothing.
for tag in motion tile; do
  echo "$tag: $(grep -E 'rn-impeller: damage frame=' "$OUT/$tag/run.log" | sed -nE 's/.* mode=([a-z]+) .*reason=([a-z_]+).*/\1:\2/p' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
done
TP=$(grep -cE 'rn-impeller: damage frame=.* mode=partial' "$OUT/tile/run.log")
echo "== V: partial frames redrawn in full and compared =="
grep -E 'partial_verify(_first)? ' "$OUT/tileverify/run.log" | head -2
VLINE=$(grep -E 'rn-impeller: partial_verify frames=' "$OUT/tileverify/run.log" | tail -1)
VF=$(echo "$VLINE" | sed -nE 's/.* frames=([0-9]+).*/\1/p'); VM=$(echo "$VLINE" | sed -nE 's/.*mismatched_frames=([0-9]+).*/\1/p')
[ "${VF:-0}" -ge 4 ] || fail "V: only ${VF:-0} partial frames were verified (want >= 4)"
[ "${VM:-1}" = 0 ] || fail "V: $VM of $VF partial frames differ from the same frame drawn in full"
[ "$TP" -ge 4 ] || fail "P: the tile run repainted only $TP frames partially (want >= 4 of its 8 colour steps)"

[ "$FAILS" = 0 ] || { echo "BLUR_SCROLL_FAIL ($FAILS)"; exit 1; }
echo "BLUR_SCROLL_PASS"
