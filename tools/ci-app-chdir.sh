#!/usr/bin/env bash
# ENG-49 gate: a windowed engine inside an .app keeps the caller's working
# directory, so a RELATIVE --screenshot lands in the cwd, not in the app.
#
# THE BUG (npm 0.8.5, darwin). GLFW's macOS default, GLFW_COCOA_CHDIR_RESOURCES,
# makes glfwInit chdir to <App>.app/Contents/Resources whenever the executable
# sits inside an .app. Only windowed runs call glfwInit, so `--headless` wrote a
# relative frame to the cwd and `--window` wrote the same path into the app's
# Contents/Resources (and broke the app's seal). The fix:
# glfwInitHint(GLFW_COCOA_CHDIR_RESOURCES, GLFW_FALSE) before glfwInit
# (engine/host/GlfwSurface.cpp, GlfwSurface::initWindow).
#
# METHOD (after the Mac's tools/app-chdir-probe.py, ENG-49-ASK-1). Copy the
# engine folder into a scratch Foo.app/Contents/MacOS (executable renamed Foo,
# minimal Info.plist, empty Contents/Resources). Each run gets its own cwd
# next to the app and passes --screenshot app-chdir-shot.ppm, a RELATIVE path:
# where it lands is the subject.
#
#   A  control  RNI_BIN --headless   frame in its cwd, nowhere else. Proves the
#                                    copy, the bundle, the capture and the
#                                    relative path all work.
#   B  subject  RNI_BIN --window     frame in its cwd, NOT in Contents/Resources.
#   C  control  RNI_CONTROL_BIN      frame in Contents/Resources. Proves this
#               --window             machine sees the scratch .app as an app,
#                                    so B can fail. Use an engine without the
#                                    fix (npm 0.8.5). Without RNI_CONTROL_BIN
#                                    the gate says so and B is unproven.
#
# macOS only: the hint acts only on Cocoa, so no other OS can tell the two
# engines apart. Elsewhere it exits 2 (not applicable), never a silent pass.
#
# NO-NPM MODE: committed prebuilt bundle + a staged binary. The Mac:
#   RNI_BIN=<darwin rn-impeller> RNI_CONTROL_BIN=<0.8.5 rn-impeller> \
#     bash tools/ci-app-chdir.sh
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "APP_CHDIR_GATE_FAIL: $*" >&2; exit 1; }

if [ "$(uname -s)" != Darwin ]; then
  echo "APP_CHDIR_GATE_NA: macOS only (GLFW_COCOA_CHDIR_RESOURCES acts only on Cocoa)"
  exit 2
fi

abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
BIN="$(abs "${RNI_BIN:-$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller}")"
CONTROL_BIN=""
[ -n "${RNI_CONTROL_BIN:-}" ] && CONTROL_BIN="$(abs "$RNI_CONTROL_BIN")"
cd "$ROOT"
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
[ -z "$CONTROL_BIN" ] || [ -x "$CONTROL_BIN" ] || fail "no control engine at $CONTROL_BIN"
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng49-app-chdir/prebuilt/eng49-app-chdir.bundle}"
BUNDLE="$(abs "$BUNDLE")"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

SHOT=app-chdir-shot.ppm
WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"   # /var -> /private/var, so paths compare
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { rni_kill_own; [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# make_app <engine binary> <run dir> -> prints the Foo executable's path
make_app() {
  local src="$1" run="$2" contents="$2/Foo.app/Contents"
  mkdir -p "$contents/Resources"
  ditto "$(dirname "$src")" "$contents/MacOS" || fail "ditto $(dirname "$src") failed"
  mv "$contents/MacOS/$(basename "$src")" "$contents/MacOS/Foo"
  cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Foo</string>
  <key>CFBundleIdentifier</key><string>dev.rni.app-chdir-gate</string>
  <key>CFBundleName</key><string>Foo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
  echo "$contents/MacOS/Foo"
}

# launch <log> <Foo> <cwd> <mode args...>
launch() {
  local log="$1" exe="$2" cwd="$3"; shift 3
  mkdir -p "$cwd"
  set +e
  ( cd "$cwd" && timeout 120 "$exe" --bundle "$BUNDLE" --app-name AppChdirProbe \
      --width 200 --height 120 --scale 1 --probe-banner off \
      --screenshot "$SHOT" "$@" ) > "$log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$log" >&2; fail "$(basename "$log" .log): run exited $rc"; }
}

# landed <run dir> -> every place the frame landed, one per line
landed() { find "$1" -name "$SHOT" -type f | sort; }

WINDOW=(--window --frames 20 --screenshot-after-frames 5)
echo "engine:  $BIN"
echo "control: ${CONTROL_BIN:-(none: set RNI_CONTROL_BIN to an engine without the fix)}"

echo "== A. control: headless inside Foo.app writes the relative frame to its cwd =="
RUN_A="$WORK/a"; EXE_A="$(make_app "$BIN" "$RUN_A")"
launch "$WORK/a.log" "$EXE_A" "$RUN_A/cwd" --headless
got="$(landed "$RUN_A")"; echo "   landed: ${got:-nowhere}"
[ "$got" = "$RUN_A/cwd/$SHOT" ] \
  || fail "A: a headless run must write $SHOT to its cwd only, got: ${got:-nowhere}"

echo "== B. subject: windowed inside Foo.app writes the relative frame to its cwd =="
RUN_B="$WORK/b"; EXE_B="$(make_app "$BIN" "$RUN_B")"
launch "$WORK/b.log" "$EXE_B" "$RUN_B/cwd" "${WINDOW[@]}"
got="$(landed "$RUN_B")"; echo "   landed: ${got:-nowhere}"
[ -n "$got" ] || { tail -15 "$WORK/b.log" >&2; fail "B: the windowed run wrote no frame anywhere"; }
[ "$got" != "$RUN_B/Foo.app/Contents/Resources/$SHOT" ] \
  || fail "B: the windowed engine chdir'd to Foo.app/Contents/Resources and wrote $SHOT there (ENG-49: glfwInitHint(GLFW_COCOA_CHDIR_RESOURCES, GLFW_FALSE) before glfwInit)"
[ "$got" = "$RUN_B/cwd/$SHOT" ] || fail "B: want $SHOT in the cwd only, got: $got"

if [ -n "$CONTROL_BIN" ]; then
  echo "== C. control: an engine without the fix writes it into Contents/Resources =="
  RUN_C="$WORK/c"; EXE_C="$(make_app "$CONTROL_BIN" "$RUN_C")"
  launch "$WORK/c.log" "$EXE_C" "$RUN_C/cwd" "${WINDOW[@]}"
  got="$(landed "$RUN_C")"; echo "   landed: ${got:-nowhere}"
  [ "$got" = "$RUN_C/Foo.app/Contents/Resources/$SHOT" ] \
    || fail "C: the control engine must write $SHOT to Contents/Resources (else this machine does not treat the scratch app as an app, and B proves nothing), got: ${got:-nowhere}"
else
  echo "   NOTE: no RNI_CONTROL_BIN, so nothing here shows B could fail"
fi

echo "APP_CHDIR_GATE_PASS"
