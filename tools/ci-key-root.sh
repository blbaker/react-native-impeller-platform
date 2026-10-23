#!/usr/bin/env bash
# ENG-46 gate: a key event with NOTHING focused reaches the app's root
# onKeyDown/onKeyUp.
#
# THE BUG (npm 0.8.2). With no focused TextInput or View,
# FabricHost::dispatchKeyEvent fell back to the SURFACE ROOT (tag 1). The
# surface root is Fabric's RootShadowNode: it has no React instance, so the
# event went nowhere and every app-level hotkey (Cmd+K, Cmd+Shift+B) was dead
# until a text field had focus. The fix targets the root React component's top
# host view (the surface root's first mounted child), and the event bubbles
# from there like a focused event does.
#
#   A  no focus, Cmd/Meta+Shift+B   KEYROOT b true true + KEYROOT_UP, the
#                                   key_event tag is NOT the surface root (1)
#   B  negative control, no keys    no KEYROOT line, no key_event line
#   C  unfocused TextInput is the   FIELDROOT fires (bubbled), the field's
#      root's first host child      onKeyPress does NOT (it has no focus)
#   D  click into the TextInput     the focused-field path is unchanged:
#                                   key_event tag = the focused field,
#                                   TI_KEYPRESS fires, FIELDROOT bubbles
#
# Every run is windowed (the key hooks live in the window loop): xvfb on
# linux, and --window-hidden when the binary has that flag.
#
# NO-NPM MODE: committed prebuilt bundle + the staged binary. The Mac:
#   RNI_BIN=<darwin rn-impeller> bash tools/ci-key-root.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "KEY_ROOT_GATE_FAIL: $*" >&2; exit 1; }

if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
cd "$ROOT"
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
FIX="$ROOT/fixtures/eng46-key-root"
BUNDLE="${RNI_TEST_BUNDLE:-$FIX/prebuilt/eng46-key-root.bundle}"
if [ "${BUILD_BUNDLE:-0}" = "1" ] && [ -z "${RNI_TEST_BUNDLE:-}" ]; then
  bash "$ROOT/tools/build-fixture-bundle.sh" eng46-key-root KeyRootProbe \
    || fail "could not rebuild the bundle"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

WIN=()
[ "$(uname -s)" = Darwin ] || WIN=(xvfb-run -a -s "-screen 0 1280x1024x24")
FRAMES="${RNI_FRAMES:-240}"
# --window-hidden only where the binary knows it (an unknown flag is ignored,
# so passing it to an engine without it would still open a visible window).
WINDOW=(--window)
if grep -q -a -- '--window-hidden' "$BIN"; then WINDOW+=(--window-hidden); fi
COMMON=(--bundle "$BUNDLE" --probe-banner off --width 400 --height 300 --scale 1
        --supersample-rnsvg 0 "${WINDOW[@]}" --frames "$FRAMES")
echo "engine: $BIN (${WINDOW[*]})"

run() {  # log, app name, extra args...
  local log="$1" app="$2"; shift 2
  set +e
  ( cd "$(dirname "$BIN")" && ${WIN[@]+"${WIN[@]}"} "$BIN" "${COMMON[@]}" --app-name "$app" "$@" ) \
    > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$log" >&2; fail "$(basename "$log" .log): run exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$log" \
    || { tail -15 "$log" >&2; fail "$(basename "$log" .log): the fixture mounted nothing"; }
}
# console.log('X', a, b, c) prints through RN's console polyfill as
#   [js] 'X', 'b', true, true
# Normalise to "X b true true" so the asserts read like the Mac's PASS line.
js() {  # log, label -> normalised lines for that label
  sed -n "s/^\[js\] '\{0,1\}$2'\{0,1\}\(,\{0,1\} .*\)$/$2\1/p" "$1" | tr -d "',"
}
keytags() {  # log, phase -> the tag= of each key_event line of that phase
  sed -n "s/^rn-impeller: key_event type=$2 .* tag=\([0-9-]*\)$/\1/p" "$1"
}

echo "== A. nothing focused: Meta+Shift+B reaches the root onKeyDown/onKeyUp =="
run "$WORK/a.log" KeyRootProbe --key-after-frames "120:b:down:meta,shift;b:up:meta,shift"
grep '^rn-impeller: key_event' "$WORK/a.log" | sed 's/^/   /'
down_tag="$(keytags "$WORK/a.log" down | head -1)"
up_tag="$(keytags "$WORK/a.log" up | head -1)"
[ -n "$down_tag" ] || fail "A: no key_event type=down line: the synthetic key never reached the host"
[ -n "$up_tag" ] || fail "A: no key_event type=up line"
grep -q '^rn-impeller: key_event type=down key=b .*meta:1' "$WORK/a.log" \
  || fail "A: the key_event line does not carry key=b with meta:1"
[ "$down_tag" != 1 ] && [ "$down_tag" != 0 ] \
  || fail "A: keyDown went to tag=$down_tag (1 = the surface root, which has no React instance; 0 = dropped)"
[ "$up_tag" = "$down_tag" ] || fail "A: keyUp went to tag=$up_tag, keyDown to tag=$down_tag"
echo "   js: $(js "$WORK/a.log" KEYROOT | tr '\n' '|') $(js "$WORK/a.log" KEYROOT_UP | tr '\n' '|')"
[ "$(js "$WORK/a.log" KEYROOT)" = "KEYROOT b true true" ] \
  || fail "A: want exactly one 'KEYROOT b true true', got '$(js "$WORK/a.log" KEYROOT | tr '\n' '|')' (no line = the root onKeyDown never fired)"
[ "$(js "$WORK/a.log" KEYROOT_UP)" = "KEYROOT_UP b true true" ] \
  || fail "A: want exactly one 'KEYROOT_UP b true true', got '$(js "$WORK/a.log" KEYROOT_UP | tr '\n' '|')'"

echo "== B. negative control: no key, no KEYROOT =="
run "$WORK/b.log" KeyRootProbe
n_b="$(grep -c '^\[js\] .*KEYROOT' "$WORK/b.log" || true)"
k_b="$(grep -c '^rn-impeller: key_event' "$WORK/b.log" || true)"
echo "   KEYROOT lines=$n_b key_event lines=$k_b"
[ "$n_b" = 0 ] && [ "$k_b" = 0 ] || fail "B: a run with no key printed $n_b KEYROOT / $k_b key_event lines"

echo "== C. unfocused TextInput first: the key bubbles to the root, onKeyPress stays silent =="
run "$WORK/c.log" KeyRootField --key-after-frames "120:b:down;b:up"
c_tag="$(keytags "$WORK/c.log" down | head -1)"
echo "   key_event down tag=${c_tag:-none} js: $(js "$WORK/c.log" FIELDROOT | tr '\n' '|') $(js "$WORK/c.log" TI_KEYPRESS | tr '\n' '|')"
grep -q '^rn-impeller: textinput_focus=[1-9]' "$WORK/c.log" && fail "C: a TextInput took focus with no click"
[ -n "$c_tag" ] && [ "$c_tag" != 1 ] && [ "$c_tag" != 0 ] || fail "C: keyDown went to tag=${c_tag:-none}"
[ "$(js "$WORK/c.log" FIELDROOT)" = "FIELDROOT b false false" ] \
  || fail "C: want exactly one 'FIELDROOT b false false', got '$(js "$WORK/c.log" FIELDROOT | tr '\n' '|')'"
[ -z "$(js "$WORK/c.log" TI_KEYPRESS)" ] \
  || fail "C: the UNFOCUSED field's onKeyPress fired ($(js "$WORK/c.log" TI_KEYPRESS | tr '\n' '|')): a key with no focus must not type into a field"

echo "== D. focused TextInput: path unchanged =="
run "$WORK/d.log" KeyRootField --click-after-frames 60:40,30 --key-after-frames "120:b:down;b:up"
focus_tag="$(sed -n 's/^rn-impeller: textinput_focus=\([0-9]*\).*/\1/p' "$WORK/d.log" | grep -v '^0$' | head -1)"
d_tag="$(keytags "$WORK/d.log" down | head -1)"
echo "   textinput_focus=${focus_tag:-none} key_event down tag=${d_tag:-none} js: $(js "$WORK/d.log" TI_KEYPRESS | tr '\n' '|') $(js "$WORK/d.log" FIELDROOT | tr '\n' '|')"
[ -n "$focus_tag" ] || { tail -20 "$WORK/d.log" >&2; fail "D: the click did not focus the TextInput"; }
[ "$d_tag" = "$focus_tag" ] || fail "D: keyDown went to tag=$d_tag, the focused field is tag=$focus_tag"
[ "$(js "$WORK/d.log" TI_KEYPRESS)" = "TI_KEYPRESS b" ] \
  || fail "D: want exactly one 'TI_KEYPRESS b', got '$(js "$WORK/d.log" TI_KEYPRESS | tr '\n' '|')'"
[ "$(js "$WORK/d.log" FIELDROOT)" = "FIELDROOT b false false" ] \
  || fail "D: want exactly one bubbled 'FIELDROOT b false false', got '$(js "$WORK/d.log" FIELDROOT | tr '\n' '|')'"

echo "KEY_ROOT_GATE_PASS"
