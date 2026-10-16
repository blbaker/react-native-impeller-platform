#!/usr/bin/env bash
# FP-53 gate: frame-time budgets with regression alarms. Runs each fixture RUNS times (default 5) with
# the staged binary (or RNI_BIN; never rebuilds), takes the MEDIAN of each metric across runs and
# compares it with tools/perf/budgets.json (budgets-darwin.json on a Mac): record/raster/total p95 and
# p99 plus startup to first present, 10% tolerance plus a noise allowance (see perf_compare.py).
#
#   bash tools/ci-perf.sh            compare against the budgets
#   bash tools/ci-perf.sh --record   re-measure and rewrite the baselines of the budget file
#   bash tools/ci-perf.sh --mac      run on the Mac through tools/parity-mac.sh (darwin budgets)
# Node-free: committed prebuilt bundles. Model: Flutter's flutter/flow/frame_timings.h numbers fed to
# a CI budget; the recorder is FP-01's.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
RUNS="${RNI_PERF_RUNS:-5}"
RECORD=0
for a in "$@"; do case "$a" in
  --record) RECORD=1 ;;
  --mac) [ "$(uname -s)" = Darwin ] || { [ -x tools/parity-mac.sh ] \
           && exec bash tools/parity-mac.sh run tools/ci-perf.sh; echo "PERF_FAIL: --mac needs tools/parity-mac.sh (FP-19)" >&2; exit 2; } ;;
  *) echo "unknown flag $a" >&2; exit 64 ;; esac; done
fail() { echo "PERF_FAIL: $*" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ]; then BUDGETS=tools/perf/budgets-darwin.json
  BIN="${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}"
else BUDGETS=tools/perf/budgets.json
  BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"; fi
BUDGETS="${RNI_PERF_BUDGETS:-$BUDGETS}"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -f "$BUDGETS" ] || fail "no budget file $BUDGETS"
echo "engine: $BIN ($( (shasum -a 256 "$BIN" 2>/dev/null || sha256sum "$BIN") | cut -c1-12)), $RUNS runs per fixture"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
WIN=(); [ "$(uname -s)" = Linux ] && WIN=(xvfb-run -a -s "-screen 0 1280x1024x24")

# name|bundle|app|extra args   (all windowed, 400x300, 120 frames, supersample pinned)
FIXTURES=(
  "native-rotate|fixtures/native-transform/prebuilt/native-transform.bundle|NativeRotateProbe|"
  "style-g2|fixtures/style-coverage/prebuilt/style-coverage.bundle|probe|--initial-url probe://g2"
  "sdf-aa|fixtures/fp22-sdf-aa/prebuilt/fp22-sdf-aa.bundle|Fp22SdfAa|"
)
measure() {  # fixture name, batch dir
  local spec name bundle app extra i tag rc
  for spec in "${FIXTURES[@]}"; do
    IFS='|' read -r name bundle app extra <<< "$spec"
    [ "$name" = "$1" ] || continue
    [ -s "$bundle" ] || fail "no committed bundle $bundle"
    rm -f "$2/$name".*.run.json
    for i in $(seq 1 "$RUNS"); do
      tag="$name.$i"; rc=0
      ( cd "$(dirname "$BIN")" && timeout 300 "${WIN[@]}" "$BIN" --window --scale 1 --width 400 --height 300 \
          --probe-banner off --supersample-rnsvg 0 --bundle "$ROOT/$bundle" --app-name "$app" --frames 120 \
          $extra --frame-timings-out "$WORK/$tag.frames.json" ) > "$WORK/$tag.log" 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
      python3 tools/perf/perf_compare.py parse "$WORK/$tag.log" "$WORK/$tag.frames.json" > "$2/$name.$i.run.json"
    done
    echo "   $name: $(cat "$2/$name.1.run.json")"
  done
}
for spec in "${FIXTURES[@]}"; do measure "${spec%%|*}" "$WORK"; done

if [ "$RECORD" = 1 ]; then
  python3 tools/perf/perf_compare.py compare "$BUDGETS" "$WORK" --record
  exit 0
fi
# Noise-aware: a box shared with other jobs can slow a whole batch of 5 runs. A fixture over budget
# is re-measured (fresh batch) up to RETRIES times and must be over in EVERY batch to fail; a real
# regression is over every time, contention is not.
RETRIES="${RNI_PERF_RETRIES:-2}"
FAILED=()
python3 tools/perf/perf_compare.py compare "$BUDGETS" "$WORK" > "$WORK/table.txt" || true
cat "$WORK/table.txt"
over() { sed -n 's/^PERF_OVER_FIXTURES: //p' "$1"; }
cur="$(over "$WORK/table.txt")"
for try in $(seq 1 "$RETRIES"); do
  [ -n "$cur" ] || break
  echo "== retry $try: over budget in batch, re-measuring: $cur =="
  nxt=""
  for fx in $cur; do
    mkdir -p "$WORK/retry"; measure "$fx" "$WORK/retry" > /dev/null
    if python3 tools/perf/perf_compare.py compare "$BUDGETS" "$WORK/retry" --only "$fx" > "$WORK/retry.txt"; then
      echo "   $fx: within budget on retry $try (batch before was contention)"; sed 's/^/     /' "$WORK/retry.txt" | grep "$fx" | head -7
    else nxt="$nxt $fx"; sed 's/^/     /' "$WORK/retry.txt" | grep OVER; fi
  done
  cur="${nxt# }"
done
[ -z "$cur" ] || fail "over budget in every batch: $cur"
echo "PERF_GATE_PASS"
