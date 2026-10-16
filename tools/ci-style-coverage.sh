#!/usr/bin/env bash
# STYLE COVERAGE GATE (audit 2026-10-10).
# Renders the coverage probes with the STAGED engine and scores every tile
# with tools/style-coverage-measure.py (base control-vs-feature rule + the
# STRICT rules in tools/style_coverage_rules.py).
#
#   A. LANDED (tools/style-coverage-landed.txt): every tile a fix pass landed
#      must PASS.
#   B. KEEP (tools/style-coverage-keep.txt): every tile that passed on the
#      audit binary (095dcba) must still PASS.
#   Tiles in neither list are reported, not judged.
#
# Scenes: g2 + risky (fixtures/style-coverage), nw + variants (light, dark,
# 600 wide) (fixtures/nw-coverage), and the windowed NativeWind interaction
# scene (idle, hover, groupHover, active, focus) unless RNI_SC_WINDOWED=0.
# Node-free: bundles are committed, the measurer is pure python3, so the Mac
# runs RNI_BIN=<darwin rn-impeller> bash tools/ci-style-coverage.sh.
# Supersample is pinned (RNI_SUPERSAMPLE, default 0) and asserted per render.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SC_BUNDLE="${RNI_SC_BUNDLE:-$ROOT/fixtures/style-coverage/prebuilt/style-coverage.bundle}"
NW_BUNDLE="${RNI_NW_BUNDLE:-$ROOT/fixtures/nw-coverage/prebuilt/nw-coverage.bundle}"
SS="${RNI_SUPERSAMPLE:-0}"
fail() { echo "STYLE_COVERAGE_GATE_FAIL: $*" >&2; exit 1; }
# RNI_EXPECT_PLATFORM=win32|darwin|linux: every render log must prove that engine ran.
EXPECT="${RNI_EXPECT_PLATFORM:-}"
assert_platform() {  # log
  [ -n "$EXPECT" ] || return 0
  grep -qx "rn-impeller: platform=$EXPECT" "$1" \
    || fail "$(basename "$1"): want platform=$EXPECT, log says '$(grep -m1 -o 'platform=[a-z0-9]*' "$1" || echo none)'"
  [ "$EXPECT" != win32 ] || grep -q 'angle_backend=D3D11' "$1" || fail "$(basename "$1"): win32 run did not render through ANGLE D3D11"
}

OS="$(uname -s)"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || fail "no engine binary at $BIN"
for b in "$SC_BUNDLE" "$NW_BUNDLE"; do [ -s "$b" ] || fail "no bundle at $b"; done

WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT

render() {  # name bundle app scene w h [extra engine args...]
  local name="$1" bundle="$2" app="$3" scene="$4" w="$5" h="$6"; shift 6
  set +e
  ( cd "$(dirname "$BIN")" && "$BIN" --bundle "$bundle" --app-name "$app" --headless \
      --probe-banner off --width "$w" --height "$h" --initial-url "probe://$scene" \
      --supersample-rnsvg "$SS" "$@" --screenshot "$WORK/$name.ppm" ) > "$WORK/$name.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -12 "$WORK/$name.log" >&2; fail "render $name exited $rc"; }
  grep -qE 'scene_nodes=[1-9]' "$WORK/$name.log" || fail "render $name mounted nothing (app-name mismatch?)"
  grep -q "supersample_rnsvg=$SS\$" "$WORK/$name.log" || fail "render $name: supersample not pinned to $SS"
  [ -s "$WORK/$name.ppm" ] || fail "render $name wrote no screenshot"
  assert_platform "$WORK/$name.log"
}

echo "== render (headless, supersample $SS) =="
render g2 "$SC_BUNDLE" probe g2 1200 3600
render risky "$SC_BUNDLE" probe risky 1200 300
render nw "$NW_BUNDLE" Eng19NativeWind nw 1200 1800
render variants-light "$NW_BUNDLE" Eng19NativeWind variants 1200 600
render variants-dark "$NW_BUNDLE" Eng19NativeWind variants 1200 600 --color-scheme dark
render variants-600 "$NW_BUNDLE" Eng19NativeWind variants 600 900
ARGS=(g2="$WORK/g2.ppm" risky="$WORK/risky.ppm" nw="$WORK/nw.ppm"
      variants-light="$WORK/variants-light.ppm" variants-dark="$WORK/variants-dark.ppm"
      variants-600="$WORK/variants-600.ppm")
PROPS_ERR="$(cat "$WORK"/*.log | grep -c 'Error while converting prop' || true)"
echo "   prop-conversion errors across renders: $PROPS_ERR"
[ "$PROPS_ERR" = 0 ] || { grep -h 'Error while converting prop' "$WORK"/*.log | sort | uniq -c | head -5 >&2; fail "$PROPS_ERR prop-conversion error(s) in the render logs"; }

WINDOWED="${RNI_SC_WINDOWED:-1}"
if [ "$WINDOWED" = 1 ]; then
  echo "== render windowed probe://interact =="
  if [ "$OS" = Darwin ]; then WRAP=(); elif command -v xvfb-run >/dev/null; then
    WRAP=(xvfb-run -a -f "$WORK/xvfb.auth" -s "-screen 0 1280x1024x24"); else WRAP=(); export DISPLAY="${DISPLAY:-:0}"; fi
  # Hooks fire at frame 200: ~0.2 s on xvfb, ~3.3 s on a 60 Hz vsynced darwin window.
  if [ "$OS" = Darwin ]; then SHOT_MS=6000; else SHOT_MS=2500; fi
  # macOS ships no timeout(1); perl's alarm survives exec.
  run_to() { if command -v timeout >/dev/null; then timeout "$@"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi; }
  wrun() {  # case [input hook args...]
    local c="$1"; shift
    set +e
    ( cd "$(dirname "$BIN")" && run_to 120 ${WRAP[@]+"${WRAP[@]}"} "$BIN" --bundle "$NW_BUNDLE" \
        --app-name Eng19NativeWind --window --scale 1 --width 400 --height 300 \
        --initial-url probe://interact --supersample-rnsvg "$SS" --frames 4000 \
        --screenshot-after "$SHOT_MS" "$@" --screenshot "$WORK/i-$c.ppm" ) > "$WORK/i-$c.log" 2>&1
    local rc=$?
    set -e
    [ "$rc" -eq 0 ] && [ -s "$WORK/i-$c.ppm" ] || { tail -8 "$WORK/i-$c.log" >&2; fail "windowed $c rc=$rc / no screenshot"; }
    assert_platform "$WORK/i-$c.log"
    ARGS+=(interact-"$c"="$WORK/i-$c.ppm")
  }
  wrun idle
  # Input hooks take SCREEN coords; at --scale 1 a Retina backing store maps them x2, so divide.
  BS="$(sed -n 's/.*backing_scale=\([0-9.]*\).*/\1/p' "$WORK/i-idle.log" | head -1)"
  BS="${BS:-1}"
  at() { awk -v s="$BS" -v p="$1" 'BEGIN { n = split(p, a, /[:,@]/); printf "%s:%g,%g", a[1], a[n-1] / s, a[n] / s }'; }
  [ "$BS" = "1.00" ] || [ "$BS" = 1 ] || echo "   backing scale $BS: input points divided by it"
  wrun hover --hover-after-frames "$(at 200:60,60)"
  wrun groupHover --hover-after-frames "$(at 200:260,60)"
  A="$(at 200:160,60)"
  wrun active --mouse-after-frames "${A%%:*}:down@${A#*:}"
  wrun focus --click-after-frames "$(at 200:100,140)"
fi

python3 "$ROOT/tools/style-coverage-measure.py" "${ARGS[@]}" > "$WORK/tiles.txt"
verdict() { awk -v k="$1" '$1=="TILE" && ($2":"$4)==k {print $5}' "$WORK/tiles.txt"; }
line() { awk -v k="$1" '$1=="TILE" && ($2":"$4)==k' "$WORK/tiles.txt" | cut -c1-200; }

echo "== A. landed tiles must PASS =="
bad=""; nl=0
while read -r key pass _; do
  [ -z "$key" ] || [ "${key#\#}" != "$key" ] && continue
  if [ "$WINDOWED" != 1 ] && [ "${key%%:*}" = interact ]; then echo "   $pass: $key skipped (RNI_SC_WINDOWED=0)"; continue; fi
  nl=$((nl + 1)); v="$(verdict "$key")"
  echo "   $pass: $(line "$key")"
  [ "$v" = PASS ] || bad="$bad $key"
done < "$ROOT/tools/style-coverage-landed.txt"
[ -z "$bad" ] || fail "A: landed tile(s) do not pass:$bad"

echo "== B. keep-green tiles must still PASS =="
nk=0
while read -r key _; do
  [ -z "$key" ] || [ "${key#\#}" != "$key" ] && continue
  if [ "$WINDOWED" != 1 ] && [ "${key%%:*}" = interact ]; then continue; fi
  nk=$((nk + 1)); v="$(verdict "$key")"
  [ -n "$v" ] || fail "B: tile $key missing from the measurer output"
  [ "$v" = PASS ] || { echo "   $(line "$key")" >&2; bad="$bad $key"; }
done < "$ROOT/tools/style-coverage-keep.txt"
[ -z "$bad" ] || fail "B: tile(s) that passed on the audit binary regressed:$bad"
echo "   $nk keep-green tiles PASS"

echo "== open tiles (reported, not judged) =="
awk '$1=="TILE" && $5!="PASS" {printf "   %s:%s %s\n", $2, $4, $5}' "$WORK/tiles.txt"
grep TILES_FAILING "$WORK/tiles.txt" | sed 's/^/   /'
echo "STYLE_COVERAGE_GATE_PASS landed=$nl keep=$nk${EXPECT:+ platform=$EXPECT}"
