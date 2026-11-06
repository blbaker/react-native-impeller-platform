#!/usr/bin/env bash
# ci-textinput-inline-os — ENG-01d: <TextInput> mounts in a production Expo +
# NativeWind bundle built through withImpeller.
#
# The bug: babel-preset-expo (production) rewrites `Platform.OS` to 'impeller'
# inside RN's TextInput.js before the as-ios Platform from ENG-01a/01c is ever
# read, the iOS arm is constant-folded away, and every TextInput renders null.
# The fix (package/src/metro-shims/babel-transformer.js) keeps that read at
# runtime for the TextInput folder only.
#
# Node-free: renders the committed bundles in fixtures/textinput-inline-os/
# prebuilt (tools/build-textinput-inline-os-bundles.sh, which also runs the
# static scope checks), so the Mac runs it with RNI_BIN=<darwin binary>.
# TIIOS_BUNDLES=<dir> points it at freshly built bundles (mutation-verify).
#
#   A. The Mac's exact command (--type 170,220:Hi, 1920x1080): 3 TextInput
#      nodes, focus lands on field d, pixels: placeholder ink in a, red
#      placeholder in b, green value in d, nothing in an empty control box.
#      Field d is CONTROLLED (value="DDDD value", no onChangeText), so RN
#      itself puts the value back after each key: the gate wants the edit to
#      reach JS (a setTextAndSelection command) and the value to stay put.
#   B. --type 170,40:Hi on field a (uncontrolled): textinput_value len=2 v=Hi.
#      Platform.OS seen by app code at runtime is 'impeller', the inlined read
#      is 'impeller', and Platform.select picks the impeller key.
#   C. Same probe without NativeWind: mounts and types the same.
#   D. Negative: no withImpeller at all: no TextInput node.
#   E. Control: withImpeller as it was before ENG-01d (resolver shim only, no
#      babel-transformer wrapper): no TextInput node, type_focus=0. This is the
#      Mac's failure, and proves this gate can fail.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
PRE="${TIIOS_BUNDLES:-$ROOT/fixtures/textinput-inline-os/prebuilt}"
MEASURE="$ROOT/tools/textinput-inline-os-measure.py"
fail() { echo "TIIOS_GATE_FAIL: $*"; exit 1; }
OS="$(uname -s)"
for b in tiios-fix tiios-fix-nocss tiios-noimp tiios-prefix; do
  [ -s "$PRE/$b.bundle" ] || fail "no bundle $PRE/$b.bundle (tools/build-textinput-inline-os-bundles.sh)"
done
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (tools/engine-build.sh, or set RNI_BIN)"
echo "engine: $BIN"
echo "bundles: $PRE"

WORK="$(mktemp -d)"
cleanup() {
  rni_kill_own
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

run() {  # run <bundle-name> <log> <type-spec> [ppm]
  local _b="$1" _log="$2" _type="$3" _ppm="${4:-}"
  local _shot=(); [ -n "$_ppm" ] && _shot=(--screenshot "$_ppm")
  set +e
  "$BIN" --bundle "$PRE/$_b.bundle" --app-name Probe --probe-banner off \
    --width 1920 --height 1080 --headless ${_shot[@]+"${_shot[@]}"} --type "$_type" > "$_log" 2>&1
  local _rc=$?
  set -e
  echo "$_rc" > "$_log.rc"
}

textinputs() { grep -c '^rn-impeller: node_frame=TextInput,' "$1" || true; }
focus_tag() { sed -n 's/^rn-impeller: type_focus=\([0-9]*\) .*/\1/p' "$1" | tail -1; }
value_line() { grep '^rn-impeller: textinput_value ' "$1" | tail -1; }
os_line() { grep -m1 'PROBE_PLATFORM_OS' "$1" | sed 's/^.*PROBE_PLATFORM_OS //'; }

no_js_errors() {  # no_js_errors <log> <arm>
  if grep -qE '^\[js-(error|exception)\]' "$1"; then
    fail "$2: JS error: $(grep -m1 -E '^\[js-(error|exception)\]' "$1" | cut -c1-160)"
  fi
}

mounted_arm() {  # mounted_arm <log> <arm>
  local n; n="$(textinputs "$1")"
  echo "  $2: scene $(grep -m1 'scene_nodes=' "$1" | sed 's/^.*scene_nodes=/scene_nodes=/'), TextInput nodes=$n"
  [ "$n" = 3 ] || fail "$2: expected 3 TextInput nodes, got $n ($(grep -m1 scene_nodes "$1"))"
  no_js_errors "$1" "$2"
}

echo "== A. the Mac's command: --type 170,220:Hi, screenshot =="
run tiios-fix "$WORK/a.log" 170,220:Hi "$WORK/a.ppm"
mounted_arm "$WORK/a.log" A
TAG="$(focus_tag "$WORK/a.log")"
echo "  A: type_focus=$TAG  $(value_line "$WORK/a.log" | sed 's/^rn-impeller: //')"
[ -n "$TAG" ] && [ "$TAG" != 0 ] || fail "A: type_focus=0, the click at 170,220 found no field"
value_line "$WORK/a.log" | grep -q "tag=$TAG len=10 .*v=DDDD value$" \
  || fail "A: controlled field d should keep 'DDDD value', got: $(value_line "$WORK/a.log")"
grep -q "^rn-impeller: command tag=$TAG name=setTextAndSelection" "$WORK/a.log" \
  || fail "A: no setTextAndSelection on tag $TAG: the typed keys never reached TextInput.js"
python3 "$MEASURE" "$WORK/a.ppm" | tee "$WORK/a.px"
px() { sed -n "s/^box=$1 .*$2=\([0-9]*\).*/\1/p" "$WORK/a.px"; }
[ "$(px a grey)" -ge 100 ] || fail "A: no placeholder ink in box a (grey=$(px a grey))"
[ "$(px b red)" -ge 100 ] || fail "A: no red placeholder ink in box b (red=$(px b red))"
[ "$(px d green)" -ge 100 ] || fail "A: no green value ink in box d (green=$(px d green))"
[ "$(px gap ink)" = 0 ] || fail "A: ink in the empty control box (ink=$(px gap ink)): measurement is off"

echo "== B. --type 170,40:Hi into field a (uncontrolled) + Platform.OS =="
run tiios-fix "$WORK/b.log" 170,40:Hi
mounted_arm "$WORK/b.log" B
TAG="$(focus_tag "$WORK/b.log")"
echo "  B: type_focus=$TAG  $(value_line "$WORK/b.log" | sed 's/^rn-impeller: //')"
[ -n "$TAG" ] && [ "$TAG" != 0 ] || fail "B: type_focus=0"
value_line "$WORK/b.log" | grep -q "tag=$TAG len=2 .*v=Hi$" || fail "B: want len=2 v=Hi, got: $(value_line "$WORK/b.log")"
echo "  B: PROBE_PLATFORM_OS $(os_line "$WORK/b.log")"
[ "$(os_line "$WORK/b.log")" = "runtime=impeller inlined=impeller select=impeller" ] \
  || fail "B: Platform.OS must stay 'impeller' outside the TextInput folder, got: $(os_line "$WORK/b.log")"

echo "== C. same probe, no NativeWind =="
run tiios-fix-nocss "$WORK/c.log" 170,40:Hi
mounted_arm "$WORK/c.log" C
value_line "$WORK/c.log" | grep -q "len=2 .*v=Hi$" || fail "C: want len=2 v=Hi, got: $(value_line "$WORK/c.log")"
[ "$(os_line "$WORK/c.log")" = "runtime=impeller inlined=impeller select=impeller" ] \
  || fail "C: Platform.OS got: $(os_line "$WORK/c.log")"

echo "== D. negative: no withImpeller =="
run tiios-noimp "$WORK/d.log" 170,40:Hi
N="$(textinputs "$WORK/d.log")"
echo "  D: TextInput nodes=$N ($(grep -m1 -E '^\[js-exception\]' "$WORK/d.log" | cut -c1-100 || true))"
[ "$N" = 0 ] || fail "D: $N TextInput node(s) without withImpeller: the fix is not in the shim"

echo "== E. control: withImpeller without the ENG-01d transformer =="
run tiios-prefix "$WORK/e.log" 170,40:Hi
N="$(textinputs "$WORK/e.log")"
TAG="$(focus_tag "$WORK/e.log")"
echo "  E: TextInput nodes=$N type_focus=${TAG:-?}"
[ "$N" = 0 ] && [ "${TAG:-0}" = 0 ] || fail "E: the pre-fix control mounted $N TextInput(s): this gate cannot see the bug"

echo "TIIOS_GATE_PASS"
