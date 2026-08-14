#!/usr/bin/env bash
# P5-D WINDOWS CONSUMER GATE: can a real app INSTALL react-native-impeller on
# Windows, from tarballs, and get pixels?
#
# The P5-C gate (ci-win.sh) drives the STAGED BUILD at C:\Devel\rni-win-build —
# it proves the port runs, and nothing about whether it can be delivered. Every
# packaging bug in the skia-platform history was invisible to exactly that kind
# of gate, because the repo path and the consumer path are different code.
#
# Nothing below runs from the repo working tree except `npm pack`:
#
#   1. npm pack the win32-x64 engine package and the main package
#   2. copy a pristine stock RN app into a temp dir on the WINDOWS filesystem
#   3. npm install BOTH TARBALLS with WINDOWS npm (no link, no workspace)
#   4. resolve the engine through the CONSUMER's node_modules  (win32 triple)
#   5. npx react-native init-impeller                          (scaffold)
#   6. npx react-native bundle --platform impeller             (Windows metro)
#   7. assert the shim marker IS IN THE BUNDLE                 (layer 2)
#   8. run the INSTALLED engine binary on that bundle, headless
#   9. assert pixels: status swatch GREEN, distinct colours, rrect corner
#
# ⛔ EVERY npm/node STEP RUNS AS A WINDOWS PROCESS. Running metro from WSL
# against files on /mnt/c would produce a bundle with POSIX paths and prove
# nothing about the platform this gate exists to cover; and the engine is a
# native .exe that cannot be launched from bash without cmd.exe anyway.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PKG_DIR="packages-engine/engine-win32-x64"
BASE_APP_WSL="${WIN_BASE_APP:-/mnt/c/Devel/rni-consumer-base}"

fail() { echo "P5_WIN_CONSUMER_FAIL: $*" >&2; exit 1; }
# /mnt/c/x -> C:\x   (cmd.exe refuses \\wsl.localhost as a working directory)
win() { printf '%s' "$1" | sed 's|^/mnt/\([a-z]\)|\U\1:|; s|/|\\|g'; }
# Run a command line under cmd.exe from a Windows cwd, returning ITS exit code.
# ⛔ NEVER `& echo EXIT=%errorlevel%` — cmd.exe expands that at PARSE time, so it
# prints EXIT=0 before the program has run. cmd.exe's own status does propagate.
wincmd() { ( cd /mnt/c && cmd.exe /c "cd /d $1 && $2" ); }

command -v cmd.exe >/dev/null || fail "cmd.exe not on PATH — this gate must run from WSL"
[ -d "$BASE_APP_WSL/node_modules/react-native" ] \
  || fail "no Windows base RN app at $BASE_APP_WSL
  create it:  bash tools/win-consumer-base.sh"
[ -f "$PKG_DIR/bin/rn-impeller.exe" ] || bash tools/engine-build.sh win32 x64

# The workdir must live on the WINDOWS filesystem: npm on Windows cannot install
# into \\wsl.localhost, and node inside the app has to see native paths.
WORK_WSL="/mnt/c/Devel/rni-consumer-run"
rm -rf "$WORK_WSL"; mkdir -p "$WORK_WSL"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK_WSL" || rm -rf "$WORK_WSL"; }
trap cleanup EXIT

echo "== 1. pack (win32-x64 engine + main) =="
ENGINE_TGZ="$(cd "$PKG_DIR" && npm pack --silent --pack-destination "$WORK_WSL")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK_WSL")"
echo "   $ENGINE_TGZ $(du -h "$WORK_WSL/$ENGINE_TGZ" | cut -f1)"
echo "   $MAIN_TGZ $(du -h "$WORK_WSL/$MAIN_TGZ" | cut -f1)"

echo "== 2. layer 1: the engine tarball ships every DLL the loader needs =="
# On Linux this property is `ldd`. Here it is the file list: a DLL dropped from
# the tarball produces a process that dies before main() with NO output, which
# is the single most expensive failure mode on this platform to diagnose.
tar -tzf "$WORK_WSL/$ENGINE_TGZ" > "$WORK_WSL/engine-files.txt"
for required in \
    package/bin/rn-impeller.exe \
    package/bin/impeller.dll \
    package/bin/libEGL.dll \
    package/bin/libGLESv2.dll \
    package/bin/msvcp140.dll \
    package/bin/vcruntime140.dll \
    package/bin/vcruntime140_1.dll ; do
  grep -qx "$required" "$WORK_WSL/engine-files.txt" \
    || fail "engine tarball is missing $required — the consumer's process would die before main() with no output"
done
echo "   all runtime files present in the tarball"

echo "== 3. install both tarballs into a pristine app with WINDOWS npm =="
APP_WSL="$WORK_WSL/ConsumerApp"
cp -r "$BASE_APP_WSL" "$APP_WSL"
node -e '
const fs=require("fs"), path=require("path"), root=process.argv[1];
const p=JSON.parse(fs.readFileSync(path.join(root,"package.json"),"utf8"));
p.name="consumerapp";
fs.writeFileSync(path.join(root,"package.json"), JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync(path.join(root,"app.json"),"utf8"));
a.name="ConsumerApp"; a.displayName="Consumer App";
fs.writeFileSync(path.join(root,"app.json"), JSON.stringify(a,null,2));
' "$APP_WSL"

APP_WIN="$(win "$APP_WSL")"
WORK_WIN="$(win "$WORK_WSL")"
# ⛔ NO INNER QUOTES AROUND THE TARBALL PATHS. `cmd.exe /c "npm install \"C:\x\"" `
# passes the quotes THROUGH as part of the argument, and npm then reports a
# package it cannot find (measured with dumpbin: LNK1104 on a filename that
# included the quote characters). These paths are under C:\Devel and have no
# spaces. Also: no --silent, or a failure here produces an empty log.
wincmd "$APP_WIN" "npm install --no-audit --no-fund $WORK_WIN\\$ENGINE_TGZ $WORK_WIN\\$MAIN_TGZ" \
  > "$WORK_WSL/npm.log" 2>&1 || { tr -d '\r' < "$WORK_WSL/npm.log" | tail -20; fail "npm install of the tarballs failed"; }
[ -d "$APP_WSL/node_modules/react-native-impeller" ] || fail "main package not installed"
[ -d "$APP_WSL/node_modules/@react-native-impeller/engine-win32-x64" ] \
  || fail "engine package not installed — check the \"os\"/\"cpu\" fields in its package.json"
echo "   installed both packages"

echo "== 4. the resolver finds the WINDOWS engine from the consumer's node_modules =="
# This is the assertion that a wrong triple ('windows-x64') fails: resolve.js
# computes the package name from process.platform at runtime, so a package
# published under any other name installs perfectly and is never found.
#
# ⛔ KEEP THE WHOLE RESOLVER OUTPUT. resolve.js deliberately writes MULTI-LINE
# errors that name the missing package and the exact npm command to fix it, and
# an earlier version of this gate did `| tail -1` — which reduced "Engine
# version mismatch: ...@0.0.2 is installed but ...@0.0.1 requires 0.0.1" to a
# bare `npm install ...` line. The gate still failed, but for an unreadable
# reason, and the mutation that proves version-lockstep works appeared NOT to be
# caught. Discarding a diagnostic is its own defect.
# ⛔ `|| true` IS LOAD-BEARING HERE, not sloppiness. Under `set -e` a command
# substitution that exits non-zero kills the script AT THE ASSIGNMENT — before
# the case/fail below can print anything. Measured: the version-mismatch mutation
# produced a gate that died silently after step 4 with no reason on screen.
RESOLVER_OUT="$(wincmd "$APP_WIN" "node node_modules\\react-native-impeller\\src\\bin\\engine-path.js" 2>&1 | tr -d '\r' || true)"
RESOLVED_WIN="$(printf '%s' "$RESOLVER_OUT" | tail -1)"
case "$RESOLVED_WIN" in
  "$APP_WIN"\\node_modules\\@react-native-impeller\\engine-win32-x64\\bin\\rn-impeller.exe) echo "   $RESOLVED_WIN" ;;
  *) printf '%s\n' "$RESOLVER_OUT" | sed 's/^/   /' >&2
     fail "the engine resolver did not return the installed Windows binary (full output above)" ;;
esac

echo "== 5. init-impeller (scaffold, Windows) =="
wincmd "$APP_WIN" "npx --no-install react-native init-impeller" 2>&1 | tr -d '\r' | sed 's/^/   /' \
  || fail "init-impeller failed"
[ -f "$APP_WSL/impeller/impeller.config.json" ] || fail "scaffold did not write impeller/impeller.config.json"
grep -q '"appName": "ConsumerApp"' "$APP_WSL/impeller/impeller.config.json" \
  || fail "scaffold hardcoded an app name instead of reading app.json"
grep -q withImpeller "$APP_WSL/metro.config.js" || fail "metro.config.js was not wrapped"

echo "== 6. bundle for --platform impeller, with WINDOWS metro =="
wincmd "$APP_WIN" "npx --no-install react-native bundle --platform impeller --dev false --entry-file index.js --bundle-output impeller\\build\\index.impeller.bundle" \
  > "$WORK_WSL/bundle.log" 2>&1 || { tail -20 "$WORK_WSL/bundle.log"; fail "metro bundle failed on Windows"; }
BUNDLE_WSL="$APP_WSL/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE_WSL" ] || fail "no bundle produced"

echo "== 7. layer 2: the shim marker IS IN THE BUNDLE =="
# ⛔ The path-suffix matching in metro-shims/index.js normalises with path.sep,
# and on Windows metro reports resolved paths with BACKSLASHES. If that
# normalisation were wrong the shims would silently never match, the bundle
# would still build and exit 0, and only this grep would notice.
grep -q '__RN_IMPELLER_SHIM_V1__' "$BUNDLE_WSL" \
  || fail "shim marker absent from the bundle — Windows metro never resolved the impeller shim (path separator handling?)"
echo "   marker present ($(wc -c < "$BUNDLE_WSL") byte bundle)"

echo "== 8. layer 3: the INSTALLED engine runs the bundle =="
# Run from a NEUTRAL directory, not from beside the exe: DLL resolution must
# come from the executable's own directory, and running with cwd=bin/ would let
# a cwd-relative lookup pass by accident.
LOG="$WORK_WSL/engine.log"
set +e
wincmd "$WORK_WIN" "$RESOLVED_WIN --headless --bundle $APP_WIN\\impeller\\build\\index.impeller.bundle --app-name ConsumerApp --screenshot $WORK_WIN\\frame.ppm" > "$LOG" 2>&1
RC=$?
set -e
sed -i 's/\r$//' "$LOG"
grep -vE '^W[0-9]{8} |WARNING: Logging' "$LOG" | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "the installed engine exited $RC (53 = a DLL is missing beside the exe)"
grep -q "RN_IMPELLER_RENDER_OK app=ConsumerApp" "$LOG" \
  || fail "engine did not report render OK for the scaffolded app name"
grep -q "shim_marker=PRESENT" "$LOG" || fail "engine did not see the shim marker"
grep -q 'GL_RENDERER=ANGLE' "$LOG" \
  || fail "not rendering through ANGLE — the packaged libGLESv2.dll was not the one loaded"

echo "== 9. assert the pixels =="
SWATCH="$(grep -oE 'status_swatch_rgb=[0-9]+,[0-9]+,[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$SWATCH" ] || fail "engine never reported the status swatch"
[ "${SWATCH%%,*}" -le 8 ] || fail "status swatch is not green (rgb=$SWATCH) — packaging chain broken"
G="$(echo "$SWATCH" | cut -d, -f2)"
[ "$G" -ge 247 ] || fail "status swatch is not green (rgb=$SWATCH)"

COLORS="$(grep -oE 'distinct_colors=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${COLORS:-0}" -ge 10 ] || fail "frame too uniform ($COLORS colours) — the gate must not pass on a blank frame"

CORNER="$(grep -oE 'rrect_corner_rgb=[0-9]+,[0-9]+,[0-9]+' "$LOG" | cut -d= -f2)"
[ "$CORNER" = "255,255,255" ] || fail "rounded-rect corner is filled (rgb=$CORNER) — shape regression"

[ -s "$WORK_WSL/frame.ppm" ] || fail "engine reported a screenshot but no frame.ppm was written"
if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK_WSL/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi

echo "P5_WIN_CONSUMER_PASS (swatch=$SWATCH colors=$COLORS engine=installed-from-tarball)"
