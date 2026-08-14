#!/usr/bin/env bash
# P5 WINDOWS GATE: does the SAME React tree become CORRECT pixels on Windows?
#
# Runs from WSL, drives the native Windows binary through cmd.exe.
#
# Usage:  bash tools/ci-win.sh [p2|p3|p4]      (default: p2)
#
# ⛔ THE ASSERTIONS COME FROM THE SAME FIXTURE **AND THE SAME ASSERTION CODE**
# THE LINUX GATE USES — tools/assert-fixture.js. The original version of this
# gate shared the fixture and hand-copied the sixty lines that read it, which is
# the same defect one level up: a tightened Linux assertion silently never
# reached Windows, and the copy had already drifted. Sharing the JSON is not
# sharing the contract; the code that interprets it is most of the contract.
#
# There is deliberately NO per-host expectation anywhere in that module. Where
# the platforms legitimately differ — Windows measures the P2 label 6px taller
# than Linux, a real DirectWrite-vs-FreeType line-metric delta — the RANGE lives
# in the fixture and both hosts are held to the same declared range. A per-host
# expectation is a bug waiver, and once one exists "Windows passes" stops
# meaning "Windows is correct".
#
# What this gate can prove that the Linux one cannot:
#   1. the engine LINKS, LOADS and RUNS as a native Windows binary
#   2. Hermes evaluates the bundle and Fabric commits a tree under MSVC
#   3. Impeller rasterises through ANGLE/D3D11 on real GPU hardware
#   4. the frame is NOT byte-identical to the Linux one (see § cross-wiring)
#
# ⛔ P3 AND P4 ARE NOT "MORE OF THE SAME" AS P2. P2 is a static tree of solid
# fills — the cheapest thing a renderer can get right, and it exercises none of
# the code most likely to be platform-specific. P3 drives the rasteriser's
# gradient/transform/AA paths and DirectWrite text measurement; P4 crosses the
# JS<->native seam, where Windows has genuinely different implementations
# (ShellExecuteW rather than exec) behind the same TurboModule interface. Those
# are the paths where a port breaks, and until this commit only P2 had ever run
# on Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PHASE="${1:-p2}"
case "$PHASE" in
  p2) FIXTURE_DIR="fixtures/p2-mount";      APP_NAME="P2Fixture"; LINUX_GATE="tools/ci-p2.sh" ;;
  p3) FIXTURE_DIR="fixtures/p3-conformance"; APP_NAME="P3Fixture"; LINUX_GATE="tools/ci-p3.sh" ;;
  p4) FIXTURE_DIR="fixtures/p4-modules";     APP_NAME="P4Fixture"; LINUX_GATE="tools/ci-p4.sh" ;;
  *) echo "usage: ci-win.sh [p2|p3|p4]" >&2; exit 2 ;;
esac
FIXTURE="$ROOT/$FIXTURE_DIR"

# Windows-side paths. WIN_* are what cmd.exe sees; the /mnt/c twins are the same
# bytes as WSL sees them. Keeping both spellings explicit beats converting in
# four places and getting one of them wrong. The workdir is PER-PHASE: a shared
# one lets a stale frame.ppm from another phase satisfy the screenshot check.
WIN_STAGE='C:\Devel\rni-win-build\stage\bin'
WIN_WORK="C:\\Devel\\rni-win-fixture\\$PHASE"
WSL_STAGE="/mnt/c/Devel/rni-win-build/stage/bin"
WSL_WORK="/mnt/c/Devel/rni-win-fixture/$PHASE"

fail() { echo "P5_WIN_FAIL[$PHASE]: $*" >&2; exit 1; }

command -v cmd.exe >/dev/null || fail "cmd.exe not on PATH — this gate must run from WSL"
[ -x "$WSL_STAGE/rn-impeller.exe" ] || fail "no staged Windows engine at $WSL_STAGE
  build it:  bash tools/win-sync.sh && cmd.exe /c C:\\Devel\\rni-win-scripts\\engine-build-win.bat"

# ⛔ ASSERT THE STAGED DLLs, DO NOT ASSUME THEM. Windows has no RPATH: a missing
# impeller.dll or ANGLE DLL kills the process BEFORE main() with NO output and
# NO stderr — indistinguishable from an instant crash, and the single most
# expensive way to lose an hour on this port. Naming the missing file here
# converts that silence into a sentence.
for dll in impeller.dll libEGL.dll libGLESv2.dll; do
  [ -f "$WSL_STAGE/$dll" ] || fail "$dll is not beside the exe in $WSL_STAGE — the loader will kill the process before main() with no output"
done

# ---------------------------------------------------------------------------
# P4 ONLY: the seam checks that must run against the WINDOWS BINARY ITSELF.
#
# ⛔ THE PIXEL ASSERTIONS BELOW CANNOT COVER THESE, AND THAT IS NOT OBVIOUS.
# The P4 fixture's swatches are painted from a JS bundle that is byte-identical
# on both hosts, so they prove the seam works — but every module in it has ONE
# shared C++ implementation. The two things that are genuinely DIFFERENT CODE on
# Windows are exactly the two things a bundle cannot reach:
#
#   --test-openurl   POSIX exec passes a URL as argv[1] with no shell;
#                    ShellExecuteW RESOLVES it the way the shell would, so a
#                    one-for-one port launches a .bat or a UNC path. The
#                    predicate is shared so the LINUX gate exercises the Windows
#                    guard — but only running it on Windows proves the Windows
#                    CALLER consults it.
#   --list-modules   the registry is built at static-init time. MSVC and libstdc++
#                    do not order static initialisers the same way, so a module
#                    can register on Linux and silently miss on Windows.
#
# The manifest is diffed against the LINUX binary's rather than a checked-in
# baseline: a baseline file is a snapshot that goes stale the moment a module is
# added, and then asserts history instead of parity.
if [ "$PHASE" = "p4" ]; then
  echo "== 0. WINDOWS-NATIVE seam checks (no bundle involved) =="

  OPENURL="$( ( cd /mnt/c && cmd.exe /c "cd /d $WIN_STAGE && rn-impeller.exe --test-openurl" ) 2>&1 | sed 's/\r$//' | tr -d '\0' )" \
    || fail "the Windows openurl self-test exited non-zero: $OPENURL"
  case "$OPENURL" in
    *OPENURL_PASS*) echo "   $(printf '%s' "$OPENURL" | grep -o 'OPENURL_PASS.*')" ;;
    *) fail "the Windows openurl self-test did not pass: $OPENURL" ;;
  esac

  WIN_MANIFEST="$(mktemp)"; LIN_MANIFEST="$(mktemp)"
  ( cd /mnt/c && cmd.exe /c "cd /d $WIN_STAGE && rn-impeller.exe --list-modules" ) 2>/dev/null \
    | sed 's/\r$//' | sed 's/^\[js\] //' | grep -E '^module=|^MODULE_MANIFEST_END' > "$WIN_MANIFEST" || true
  # ⛔ ASSERT THE POSITIVE HALF FIRST. `grep -q` on empty input SUCCEEDS for an
  # absence check, so a run that produced nothing at all would otherwise sail
  # through the parity diff of two empty files and report a seam finding about a
  # process that never started.
  grep -q '^MODULE_MANIFEST_END$' "$WIN_MANIFEST" \
    || fail "the Windows engine did not finish enumerating modules — manifest is empty or truncated"

  LINUX_ENGINE="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
  if [ -x "$LINUX_ENGINE" ]; then
    "$LINUX_ENGINE" --list-modules 2>/dev/null | sed 's/^\[js\] //' \
      | grep -E '^module=|^MODULE_MANIFEST_END' > "$LIN_MANIFEST" || true
    grep -q '^MODULE_MANIFEST_END$' "$LIN_MANIFEST" \
      || fail "the LINUX engine did not finish enumerating modules — cannot compare parity"
    if ! diff -u "$LIN_MANIFEST" "$WIN_MANIFEST" > /tmp/rni-manifest-diff.txt 2>&1; then
      sed 's/^/   /' /tmp/rni-manifest-diff.txt
      fail "the Windows module seam DIFFERS from the Linux one (- linux, + windows). Static-init ordering under MSVC is the usual cause; a module missing here is unreachable from every app on Windows."
    fi
    echo "   OK seam parity — $(grep -c '^module=' "$WIN_MANIFEST") modules, method-for-method identical to Linux"
  else
    fail "no Linux engine at $LINUX_ENGINE to compare against — build it: bash tools/engine-build.sh linux x64"
  fi
fi

echo "== 1. bundle the $PHASE fixture (built on Linux; the bundle is platform-neutral) =="
BUNDLE="${WIN_BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
  # Reuse the matching Linux gate's packaging path rather than re-implementing
  # it: it already packs the tarballs into a pristine app and runs metro.
  # Keeping the workdir lets us lift the bundle — and the Linux frame — back out.
  LOG_LINUX="$(mktemp)"
  KEEP_WORKDIR=1 bash "$LINUX_GATE" > "$LOG_LINUX" 2>&1 || {
    tail -30 "$LOG_LINUX"; fail "the LINUX $PHASE gate failed — fix that before reading any Windows result"; }
  WORK="$(grep -oE 'workdir kept: .*' "$LOG_LINUX" | tail -1 | cut -d' ' -f3-)"
  [ -n "$WORK" ] || fail "the Linux gate did not report its workdir — cannot find the bundle"
  # Each gate names its app dir differently; there is exactly one bundle.
  BUNDLE="$(find "$WORK" -name index.impeller.bundle -type f | head -1)"
  LINUX_FRAME="$WORK/frame.ppm"
fi
[ -s "$BUNDLE" ] || fail "no bundle at ${BUNDLE:-<none found>}"

mkdir -p "$WSL_WORK"
cp "$BUNDLE" "$WSL_WORK/index.impeller.bundle"
# ⛔ DELETE THE OLD FRAME. Step 7 asserts a screenshot EXISTS; a leftover file
# from the previous run satisfies that check on a run that produced nothing.
rm -f "$WSL_WORK/frame.ppm"

echo "== 2. build the probe arguments FROM the fixture =="
# Same builder the Linux gate uses. One argument per line: probe values contain
# commas, so splitting on a separator that appears inside the data is how the
# arguments get silently mangled.
mapfile -t ARGS < <(node "$ROOT/tools/fixture-probe-args.js" "$FIXTURE/fixture.json" "$PHASE") \
  || fail "could not read probes out of the fixture"
[ "${#ARGS[@]}" -gt 0 ] || fail "the probe builder produced no arguments"
ARGS_STR="${ARGS[*]}"

echo "== 3. run the NATIVE WINDOWS engine on that bundle =="
LOG="$(mktemp)"
# `cd /d` FIRST: cmd.exe refuses a \\wsl.localhost working directory and
# silently falls back to C:\Windows, which would resolve the DLLs from the wrong
# directory. Running the gate itself from /mnt/c also suppresses that warning.
#
# ⛔ DO NOT CHECK THE EXIT CODE WITH `& echo EXIT=%errorlevel%`.
# cmd.exe expands %errorlevel% when it PARSES the line, before the engine has
# run, so that idiom prints EXIT=0 unconditionally — a check that can never
# fail. Measured: with impeller.dll removed, the exe dies before main() with no
# output, and the `& echo` form still reported EXIT=0. cmd.exe's OWN exit status
# does propagate to bash correctly (53 missing DLL, 2 bad args, 0 success), so
# that is what this reads.
set +e
( cd /mnt/c && cmd.exe /c "cd /d $WIN_STAGE && ${WIN_ENGINE_EXE:-rn-impeller.exe} --headless --probe-banner off --bundle $WIN_WORK\\index.impeller.bundle --app-name $APP_NAME --screenshot $WIN_WORK\\frame.ppm $ARGS_STR" ) > "$LOG" 2>&1
RC=$?
set -e
sed -i 's/\r$//' "$LOG"
# probe/node_frame lines are data for the assertion module, not reading material.
grep -vE '^W[0-9]{8} |WARNING: Logging' "$LOG" | grep -vE '^rn-impeller: (probe|node_frame)=' | sed 's/^/   /'

[ "$RC" -eq 0 ] || fail "the Windows engine exited $RC"
# The exit code alone is not enough: a process can exit 0 having rendered
# nothing. The engine prints this marker only after a frame is written.
grep -q 'RN_IMPELLER_RENDER_OK' "$LOG" || fail "engine exited 0 but never printed RN_IMPELLER_RENDER_OK — no frame was produced"

echo "== 4. assert: it ran as a WINDOWS GPU process, not something else =="
# The port's top risk was that headless GL is unavailable on Windows. Asserting
# the renderer string means a future regression to a software path (or to the
# Linux binary being run by mistake) reddens instead of quietly passing.
grep -q 'GL_RENDERER=ANGLE' "$LOG" || fail "not rendering through ANGLE — GL_RENDERER line: $(grep -oE 'GL_RENDERER=.*' "$LOG" || echo missing)"
grep -q 'angle_backend=D3D11' "$LOG" || fail "ANGLE did not select the D3D11 backend"
echo "   $(grep -oE 'GL_RENDERER=.*' "$LOG")"

echo "== 5. assert: React actually mounted =="
grep -q '\[js-exception\] (fatal' "$LOG" && fail "the bundle threw a fatal JS exception (see log above)"
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty (scene_nodes=${NODES:-none}) — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "$NODES nodes but painted 0 — the tree never reached the display list"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 6. assert: the pixels are the ones the FIXTURE declares =="
node "$ROOT/tools/assert-fixture.js" "$PHASE" "$FIXTURE/fixture.json" "$LOG" "P5_WIN_FAIL[$PHASE]"

echo "== 7. CROSS-WIRING: the Windows frame must not BE the Linux frame =="
# ⛔ THIS GATE'S FAILURE MODE IS PASSING WITHOUT RUNNING ON WINDOWS. Every
# assertion above is satisfied by a Linux frame, so if the plumbing ever falls
# back — stale screenshot, wrong exe, a copied baseline — the gate goes green
# while proving nothing. Two independently-rasterised frames of the same scene
# are correct AND unequal (antialiasing and glyph rasterisation differ), so
# byte-equality is evidence of a wiring bug, not of quality.
#
# ⛔ AND THIS CHECK USED TO TURN ITSELF OFF. When WIN_BUNDLE was supplied there
# was no Linux frame to compare against, so it printed "SKIP" and the gate still
# reported P5_WIN_PASS. Measured, not theorised: a stand-in binary that replayed
# a real Windows log and wrote the LINUX frame as its screenshot passed EVERY
# assertion in this file — probes, layout, text, distinct colours — and the gate
# went green on a run that never rendered a single Windows pixel. Worse, the
# WIN_BUNDLE path is exactly what tools/mutation-verify-win*.sh use for every
# mutant, so the one assertion protecting against cross-wiring was disabled for
# the whole suite that is supposed to be proving these gates work.
#
# A skip is now a FAILURE unless the caller supplies the frame to compare
# against (WIN_LINUX_FRAME) or explicitly accepts the hole. "Cannot check" and
# "checked and fine" must never print the same exit status.
[ -s "$WSL_WORK/frame.ppm" ] || fail "the engine reported a screenshot but $WSL_WORK/frame.ppm is missing"
CROSS_FRAME="${LINUX_FRAME:-${WIN_LINUX_FRAME:-}}"
if [ -n "$CROSS_FRAME" ] && [ -s "$CROSS_FRAME" ]; then
  if cmp -s "$WSL_WORK/frame.ppm" "$CROSS_FRAME"; then
    fail "the Windows frame is BYTE-IDENTICAL to the Linux frame — two rasterisers cannot agree bit-for-bit, so this is a cross-wiring bug, not a pass"
  fi
  echo "   OK frames differ (same scene, different rasteriser)"
elif [ "${RNI_ALLOW_NO_CROSSCHECK:-0}" = "1" ]; then
  echo "   ⚠️  CROSS-WIRING CHECK DISABLED by RNI_ALLOW_NO_CROSSCHECK=1 — this run cannot prove it rendered on Windows"
else
  fail "no Linux frame to compare against, so the cross-wiring check could not run.
  Every other assertion in this gate is satisfied by a LINUX frame, so passing here would prove nothing about Windows.
  Supply WIN_LINUX_FRAME=/path/to/linux/frame.ppm alongside WIN_BUNDLE, or set RNI_ALLOW_NO_CROSSCHECK=1 to accept the hole deliberately."
fi

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WSL_WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P5_WIN_PASS[$PHASE] (nodes=$NODES painted=$PAINTED renderer=ANGLE/D3D11)"
