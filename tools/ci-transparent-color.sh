#!/usr/bin/env bash
# Gate: `transparent` is a real colour, not "no colour set".
#
# THE BUG. React Native's cxx platform stores a colour as an int32 and uses 0
# for "unset". JS processColor('transparent') is also 0, and the cxx
# hostPlatformColorFromComponents packs rgba(0,0,0,0) back to 0, so by the time
# the painter read the props a transparent colour was indistinguishable from an
# unset one. Every fallback fired: black borders, outlines and shadows, black or
# inherited text, grey switch tracks and placeholders, gradient stops read as
# colour hints. The fix is engine/fabric/platform/impeller/react/renderer/
# graphics/HostPlatformColor.h, which never packs a real colour to 0.
#
#   0. include order (only with this checkout's build tree): no object in
#      engine/build depends on React Native's cxx HostPlatformColor.h, and some
#      do depend on the engine's copy. A positive control proves the grep sees
#      cxx headers at all.
#   A. --supersample-rnsvg 0 and B. --supersample-rnsvg 4 (the darwin and
#      Windows default): fixtures/transparent-color renders, every feature cell
#      shows the background where its transparent colour is, and every control
#      cell paints its real colour (tools/transparent-color-judge.py). A blank
#      or black frame fails the controls and the scene_nodes guard.
#
# Control: the published 0.1.0 linux-x64 engine fails 13 of 13 feature cells.
#
# NO-NPM MODE: renders the committed prebuilt bundle with the staged binary.
# The Mac runs: RNI_BIN=<darwin rn-impeller> bash tools/ci-transparent-color.sh
# BUILD_BUNDLE=1 rebuilds the bundle first (needs node and npm).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "TRANSPARENT_COLOR_GATE_FAIL: $*" >&2; exit 1; }

if [ -n "${RNI_BIN:-}" ]; then
  ENGINE="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then
  ENGINE="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else
  ENGINE="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$ENGINE" ] || fail "no engine binary at $ENGINE (set RNI_BIN)"
FIX="$ROOT/fixtures/transparent-color"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/transparent-color.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" transparent-color TransparentColor \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 0. the engine's HostPlatformColor.h wins the include order =="
BUILD="$ROOT/engine/build"
if [ -n "${RNI_BIN:-}" ] || [ ! -f "$BUILD/.ninja_deps" ] || ! command -v ninja > /dev/null; then
  echo "   SKIP: no engine/build deps log for this binary (RNI_BIN set, or no build tree)"
else
  ninja -C "$BUILD" -t deps > "$WORK/deps.txt" 2>&1 || fail "ninja -t deps failed"
  hdr=react/renderer/graphics/HostPlatformColor.h
  cxx="$(grep -c "graphics/platform/cxx/react/renderer/graphics/Float.h" "$WORK/deps.txt" || true)"
  stock="$(grep -c "graphics/platform/cxx/$hdr" "$WORK/deps.txt" || true)"
  ours="$(grep -c "fabric/platform/impeller/$hdr" "$WORK/deps.txt" || true)"
  [ "$cxx" -gt 0 ] || fail "0: the deps log names no graphics/platform/cxx header at all, so this check is blind"
  [ "$stock" -eq 0 ] || fail "0: $stock objects include React Native's cxx HostPlatformColor.h (transparent == unset there)"
  [ "$ours" -gt 0 ] || fail "0: no object includes engine/fabric/platform/impeller/$hdr"
  echo "   OK 0: $ours objects include the engine's copy, 0 include the cxx copy ($cxx include cxx Float.h)"
fi

render() {  # $1 supersample N
  local n="$1" rc nodes
  set +e
  ( cd "$WORK" && "$ENGINE" --bundle "$BUNDLE" --app-name TransparentColor --probe-banner off \
      --headless --width 500 --height 500 --supersample-rnsvg "$n" --frames 10 \
      --screenshot "$WORK/n$n.ppm" ) > "$WORK/n$n.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -20 "$WORK/n$n.log" >&2; fail "N=$n: headless render exited $rc"; }
  grep -q "^rn-impeller: supersample_rnsvg=$n\$" "$WORK/n$n.log" \
    || fail "N=$n: engine did not report supersample_rnsvg=$n (flag dropped?)"
  nodes="$(sed -n 's/^rn-impeller: scene_nodes=\([0-9]*\)$/\1/p' "$WORK/n$n.log" | tail -1)"
  [ -n "$nodes" ] && [ "$nodes" -gt 0 ] || { tail -20 "$WORK/n$n.log" >&2; fail "N=$n: scene_nodes=${nodes:-none}: fixture did not mount"; }
  grep -q 'TC stale-text color=transparent$' "$WORK/n$n.log" \
    || fail "N=$n: cell K never re-rendered to transparent before the screenshot"
  [ -s "$WORK/n$n.ppm" ] || fail "N=$n: no screenshot"
}

judge() {  # $1 arm letter  $2 supersample N
  local rc out
  set +e
  out="$(python3 "$ROOT/tools/transparent-color-judge.py" "$WORK/n$2.ppm")"
  rc=$?
  set -e
  printf '%s\n' "$out" | sed 's/^/   /'
  [ "$rc" -ne 2 ] || fail "$1: the judge could not read the screenshot"
  printf '%s\n' "$out" | grep -q '^FAIL [A-Z] control ' \
    && fail "$1: a CONTROL cell failed, so the frame or the probes are wrong: $(printf '%s\n' "$out" | tail -1)"
  [ "$rc" -eq 0 ] || fail "$1: transparent cells painted a fallback colour: $(printf '%s\n' "$out" | tail -1)"
  echo "   OK $1: $(printf '%s\n' "$out" | tail -1)"
}

for arm in A:0 B:4; do
  echo "== ${arm%%:*}. render at --supersample-rnsvg ${arm#*:} =="
  render "${arm#*:}"
  judge "${arm%%:*}" "${arm#*:}"
done

echo "TRANSPARENT_COLOR_GATE_PASS (transparent paints nothing in 13 colour families, controls paint, at N=0 and N=4)"
