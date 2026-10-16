#!/usr/bin/env bash
# FP-34 GATE: pipeline pre-warm tour (model: impeller/entity/contents/content_context.cc, the
# constructor's CreateDefault prewarm). Windowed on a private Xvfb, node-free: committed bundles + the
# staged binary (or RNI_BIN), never rebuilds. Arms:
#   coverage  the tour's own counters (counted where each draw is issued) match the painter: one blend
#             mode per ToImpellerBlend result in scenegraph/BlendGroup.cpp (17), every clip shape,
#             save-layer kind, blur kind, gradient type, text style class and texture draw
#   hidden    the tour draws nothing a user can see: a static fixture screenshots byte-identical with the
#             tour on and off
#   off       --prewarm off prints `prewarm skipped=off` and records prewarm_us=-1
#   cost      median over RUNS windowed runs of prewarm_us < 150 ms, and the value in the frame-timings
#             file equals the one the log printed
#   first-use fixtures/fp34-prewarm mounts every class in one commit (frame ~2-6), then repaints the same
#             scene much later. Frame S1 (first use) minus frame S2 (warm repeat of identical content) is
#             the first-use cost. With the tour its median is <= 15 ms and <= 65% of the --prewarm off
#             control's median, which must itself be >= 16 ms (the fixture can see the defect)
# The spec's "frame 30 within 1.5x of frame 29" is not measurable here: JS rAF ticks run hundreds of
# times per frame on this host, so the scene mounts within the first few frames, not at frame 30.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
FX="$ROOT/fixtures/fp34-prewarm/prebuilt/fp34-prewarm.bundle"
STATIC="$ROOT/fixtures/fp22-sdf-aa/prebuilt/fp22-sdf-aa.bundle"
H="$ROOT/tools/prewarm_gate.py"
RUNS="${RNI_PREWARM_RUNS:-7}"
fail() { echo "PREWARM_GATE_FAIL: $*" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || fail "linux only"
[ -x "$BIN" ] || fail "no engine binary at $BIN"
# FP-57: under tools/ci-sanitize.sh (sanitizer builds only) the two absolute time budgets (tour
# < 150 ms, first use <= 15 ms) are skipped; coverage, hidden, off, log == json, and the tour-vs-off
# control comparisons still run.
FUNCTIONAL="${RNI_BUDGETS_FUNCTIONAL_ONLY:-0}"
if [ "$FUNCTIONAL" = 1 ]; then
  "$BIN" --help 2>/dev/null | grep -q '^rn-impeller: sanitize_build=1 ' \
    || fail "RNI_BUDGETS_FUNCTIONAL_ONLY=1 needs a sanitizer build (no sanitize_build=1 from $BIN --help)"
fi
[ -s "$FX" ] && [ -s "$STATIC" ] || fail "missing prebuilt bundles"
command -v xvfb-run > /dev/null || fail "xvfb-run is required"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP_WORKDIR:-}" ] && echo "kept $WORK" >&2 || rm -rf "$WORK"' EXIT

# run <tag> <bundle> <app> <frames> [engine args]: log $WORK/<tag>.log, timings $WORK/<tag>.json
run() {
  local tag="$1" bundle="$2" app="$3" frames="$4"; shift 4
  local rc=0
  ( cd "$(dirname "$BIN")" && timeout 120 xvfb-run -a -s "-screen 0 1280x1024x24" "$BIN" --window --scale 1 \
      --width 400 --height 300 --probe-banner off --supersample-rnsvg 0 --bundle "$bundle" \
      --app-name "$app" --frames "$frames" --frame-timings-out "$WORK/$tag.json" "$@" ) \
      > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$tag.log" >&2; fail "$tag exited $rc"; }
}
field() { sed -n "s/.*rn-impeller: prewarm .*\b$2=\([0-9]*\).*/\1/p" "$WORK/$1.log" | head -1; }
median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

echo "== coverage =="
run cov0 "$FX" Fp34Prewarm 20 --prewarm on
grep -q 'rn-impeller: prewarm us=' "$WORK/cov0.log" || fail "coverage: the tour did not run: $(grep -a 'prewarm' "$WORK/cov0.log" | head -2)"
want_blend="$(grep -o 'return kImpellerBlendMode[A-Za-z]*' engine/scenegraph/BlendGroup.cpp | sort -u | wc -l)"
for spec in "blend_modes=$want_blend=eq" "clips=8=ge" "layers=24=ge" "blurs=9=ge" "gradients=4=ge" \
            "text_styles=7=ge" "textures=3=ge"; do
  IFS='=' read -r key want op <<< "${spec}"
  got="$(field cov0 "$key")"
  [ -n "$got" ] || fail "coverage: no $key in the prewarm line"
  if [ "$op" = eq ]; then [ "$got" -eq "$want" ] || fail "coverage: $key=$got, the painter emits $want (BlendGroup.cpp)"
  else [ "$got" -ge "$want" ] || fail "coverage: $key=$got < $want"; fi
done
echo "   $(grep -a -m1 'rn-impeller: prewarm us=' "$WORK/cov0.log" | cut -c14-)"

echo "== hidden =="
for m in on off; do
  run hid-$m "$STATIC" Fp22SdfAa 30 --prewarm $m --screenshot "$WORK/hid-$m.ppm" --screenshot-after-frames 20
  [ -s "$WORK/hid-$m.ppm" ] || fail "hidden: no screenshot for prewarm $m"
done
cmp -s "$WORK/hid-on.ppm" "$WORK/hid-off.ppm" || fail "hidden: the static fixture renders differently with the tour (tour left pixels)"
echo "   static fixture byte-identical on/off"

echo "== off =="
grep -q 'prewarm skipped=off' "$WORK/hid-off.log" || fail "off: no 'prewarm skipped=off' with --prewarm off"
[ "$(python3 "$H" prewarm "$WORK/hid-off.json")" = -1 ] || fail "off: prewarm_us is not -1 with the tour off"

echo "== cost + first-use ($RUNS runs per arm) =="
# A wait ceiling, scaled like every other (FP-06): unpaced frames on xvfb, 500 last ~1 s and the
# fixture repaints at 700 ms, which a loaded ASan run missed once (FP-57). Only S1/S2 are measured.
FX_FRAMES="$(awk -v s="${RNI_TIME_SCALE:-1}" 'BEGIN{n=int(500*s); print (n < 500 ? 500 : n)}')"
for i in $(seq 1 "$RUNS"); do
  for m in on off; do
    # A run whose frames lack the S1/S2 shape (first frame after the 700 ms repaint, or the repaint
    # after the last frame) measured nothing: a loaded ASan box did both (FP-57). Rerun it, at most 2x.
    for try in 1 2 3; do
      run "fx-$m-$i" "$FX" Fp34Prewarm "$FX_FRAMES" --prewarm "$m"
      python3 "$H" s1s2 "$WORK/fx-$m-$i.json" > /dev/null 2>&1 && break
      if [ "$try" -lt 3 ]; then
        echo "   fx-$m-$i: no S1/S2 frames ($(python3 "$H" s1s2 "$WORK/fx-$m-$i.json" 2>&1 | tail -1)), rerun $try" >&2
      fi
    done
  done
done
for i in $(seq 1 "$RUNS"); do
  log_us="$(field fx-on-$i us)"; json_us="$(python3 "$H" prewarm "$WORK/fx-on-$i.json")"
  [ -n "$log_us" ] || fail "cost: run $i printed no prewarm us="
  [ "$log_us" = "$json_us" ] || fail "cost: log says $log_us us, frame-timings file says $json_us"
  echo "$log_us"
done > "$WORK/us.txt"
med_us="$(median < "$WORK/us.txt")"
[ "$FUNCTIONAL" = 1 ] || [ "$med_us" -lt 150000 ] || fail "cost: median tour time $med_us us >= 150000 (runs: $(tr '\n' ' ' < "$WORK/us.txt"))"
echo "   tour median ${med_us} us (runs: $(tr '\n' ' ' < "$WORK/us.txt"))"
for m in on off; do
  for i in $(seq 1 "$RUNS"); do
    read -r s1 s2 r1 r2 < <(python3 "$H" s1s2 "$WORK/fx-$m-$i.json") || fail "first-use: $m run $i: cannot find the frames"
    awk -v a="$r1" -v b="$r2" 'BEGIN{printf "%.2f\n", a-b}'
  done > "$WORK/delta-$m.txt"
  # awk-sorted median of possibly negative values
  sort -g "$WORK/delta-$m.txt" | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}' > "$WORK/med-$m.txt"
  echo "   first-use minus repeat, tour $m: $(tr '\n' ' ' < "$WORK/delta-$m.txt")median $(cat "$WORK/med-$m.txt") ms"
done
on="$(cat "$WORK/med-on.txt")"; off="$(cat "$WORK/med-off.txt")"
awk -v o="$off" 'BEGIN{exit !(o >= 16)}' || fail "first-use: the --prewarm off control costs only $off ms over a warm repeat (< 16): the fixture cannot see the defect"
[ "$FUNCTIONAL" = 1 ] || awk -v o="$on" 'BEGIN{exit !(o <= 15)}' || fail "first-use: with the tour, first use still costs $on ms over a warm repeat (> 15)"
awk -v o="$on" -v f="$off" 'BEGIN{exit !(o <= 0.65 * f)}' || fail "first-use: tour median $on ms is not <= 65% of the off control $off ms"
echo "PREWARM_GATE_PASS$([ "$FUNCTIONAL" = 1 ] && echo " functional-only (sanitizer build: tour $med_us us, first use $on ms vs off $off ms; absolute budgets skipped)")"
