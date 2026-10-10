#!/usr/bin/env bash
# SC-21 GATE: every RN cursor value resolves to the right GLFW standard shape.
# Windowed (private xvfb-run display), node-free: prebuilt bundle + RNI_BIN.
# Reads back the shape the host APPLIED (cursor_applied=), not just the
# scene-graph kind (cursor=), for each of 25 rows of fixtures/cursor-set.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="${RNI_CURSOR_BUNDLE:-$ROOT/fixtures/cursor-set/prebuilt/cursor-set.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
fail() { echo "CURSOR_SET_GATE_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

# Row order = fixtures/cursor-set/index.js ROWS; consecutive rows differ in
# shape except where noted, so every row yields one cursor_applied line.
EXPECT=(hand ibeam crosshair resize-ew resize-ns resize-nwse resize-nesw resize-all
  not-allowed resize-nesw resize-ew resize-ns crosshair resize-nwse resize-ew resize-ns
  resize-nwse resize-nesw resize-ew resize-ns resize-all not-allowed hand arrow hand)
N=${#EXPECT[@]}
SEQ=""; for ((i = 0; i < N; i++)); do SEQ+="100,$((i * 20 + 10));"; done
SEQ="${SEQ%;}"

# X11 GLFW loads diagonal/all/not-allowed shapes only from an Xcursor theme.
[ "$(uname -s)" = Linux ] && export XCURSOR_THEME="${XCURSOR_THEME:-Adwaita}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/run.log"
RUN=("$BIN" --window --probe-banner off --bundle "$BUNDLE" --app-name probe
     --width 200 --height $((N * 20)) --scale 1 --supersample-rnsvg 0
     --frames $((N + 14)) --hover-after-frames "5:$SEQ")
set +e
# Private X server when available: a real pointer over a shared display adds stray hover events.
if ! command -v xvfb-run > /dev/null && [ -n "${DISPLAY:-}" ]; then ( cd "$(dirname "$BIN")" && "${RUN[@]}" ) > "$LOG" 2>&1
else ( cd "$(dirname "$BIN")" && xvfb-run -a -s "-screen 0 1280x1024x24" "${RUN[@]}" ) > "$LOG" 2>&1; fi
rc=$?
set -e
[ "$rc" -eq 0 ] || { tail -15 "$LOG" >&2; fail "windowed run exited $rc"; }

mapfile -t GOT < <(sed -n 's/.*rn-impeller: cursor_applied=//p' "$LOG")
mapfile -t KIND < <(sed -n 's/.*rn-impeller: cursor=//p' "$LOG")
[ "${#GOT[@]}" -ge "$N" ] || { printf '%s\n' "${GOT[@]}" >&2; fail "expected $N applied shapes, got ${#GOT[@]}"; }
for ((i = 0; i < N; i++)); do
  [ "${GOT[$i]}" = "${EXPECT[$i]}" ] || fail "row $i applied '${GOT[$i]}', expected '${EXPECT[$i]}'"
  [ "${KIND[$i]}" = "${EXPECT[$i]}" ] || fail "row $i resolved kind '${KIND[$i]}', expected '${EXPECT[$i]}'"
done
echo "CURSOR_SET_GATE_PASS ($N rows, shapes: $(printf '%s\n' "${GOT[@]:0:$N}" | sort -u | paste -sd, -))"
