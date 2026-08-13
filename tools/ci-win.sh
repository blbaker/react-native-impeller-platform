#!/usr/bin/env bash
# P5 WINDOWS GATE: does the SAME React tree become CORRECT pixels on Windows?
#
# Runs from WSL, drives the native Windows binary through cmd.exe.
#
# ⛔ THE ASSERTIONS COME FROM fixtures/p2-mount/fixture.json — THE SAME FILE THE
# LINUX P2 GATE USES. That is the whole point. A Windows gate with its own
# hand-copied expectations would keep passing after the fixture changed, and
# would be asserting the port against a snapshot of itself rather than against
# the platform-independent contract.
#
# What this gate can prove that the Linux one cannot:
#   1. the engine LINKS, LOADS and RUNS as a native Windows binary
#   2. Hermes evaluates the bundle and Fabric commits a tree under MSVC
#   3. Impeller rasterises through ANGLE/D3D11 on real GPU hardware
#   4. the frame is NOT byte-identical to the Linux one (see § cross-wiring)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FIXTURE="$ROOT/fixtures/p2-mount"

# Windows-side paths. WIN_* are what cmd.exe sees; the /mnt/c twins are the same
# bytes as WSL sees them. Keeping both spellings explicit beats converting in
# four places and getting one of them wrong.
WIN_STAGE='C:\Devel\rni-win-build\stage\bin'
WIN_WORK='C:\Devel\rni-win-fixture'
WSL_STAGE="/mnt/c/Devel/rni-win-build/stage/bin"
WSL_WORK="/mnt/c/Devel/rni-win-fixture"

fail() { echo "P5_WIN_FAIL: $*" >&2; exit 1; }

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

echo "== 1. bundle the P2 fixture (built on Linux; the bundle is platform-neutral) =="
BUNDLE="${WIN_BUNDLE:-}"
if [ -z "$BUNDLE" ]; then
  # Reuse the Linux gate's packaging path rather than re-implementing it: it
  # already packs the tarballs into a pristine app and runs metro. Keeping the
  # workdir lets us lift the bundle back out.
  LOG_P2="$(mktemp)"
  KEEP_WORKDIR=1 bash tools/ci-p2.sh > "$LOG_P2" 2>&1 || {
    tail -30 "$LOG_P2"; fail "the LINUX P2 gate failed — fix that before reading any Windows result"; }
  WORK="$(grep -oE 'workdir kept: .*' "$LOG_P2" | tail -1 | cut -d' ' -f3-)"
  BUNDLE="$WORK/FixtureApp/impeller/build/index.impeller.bundle"
  LINUX_FRAME="$WORK/frame.ppm"
fi
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

mkdir -p "$WSL_WORK"
cp "$BUNDLE" "$WSL_WORK/index.impeller.bundle"
rm -f "$WSL_WORK/frame.ppm"

echo "== 2. build the probe arguments FROM the fixture =="
ARGS="$(node -e '
const g = require(process.argv[1]);
const a = [];
for (const b of g.boxes) {
  a.push("--probe", b.probe.join(","));
  if (b.cornerProbe) a.push("--probe", b.cornerProbe.join(","));
}
a.push("--ink-band", g.label.inkBand.join(","));
a.push("--width", String(g.surface.width), "--height", String(g.surface.height));
console.log(a.join(" "));
' "$FIXTURE/fixture.json")" || fail "could not read probes out of the fixture"

echo "== 3. run the NATIVE WINDOWS engine on that bundle =="
LOG="$(mktemp)"
# `cd /d` FIRST: cmd.exe refuses a \\wsl.localhost UNC working directory and
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
( cd /mnt/c && cmd.exe /c "cd /d $WIN_STAGE && rn-impeller.exe --headless --probe-banner off --bundle $WIN_WORK\\index.impeller.bundle --app-name P2Fixture --screenshot $WIN_WORK\\frame.ppm $ARGS" ) > "$LOG" 2>&1
RC=$?
set -e
sed -i 's/\r$//' "$LOG"
grep -vE '^W[0-9]{8} |WARNING: Logging' "$LOG" | sed 's/^/   /'

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
node - "$FIXTURE/fixture.json" "$LOG" <<'NODE'
const fs = require('fs');
const g = require(process.argv[2]);
const log = fs.readFileSync(process.argv[3], 'utf8');

const probes = new Map();
for (const m of log.matchAll(/probe=(\d+),(\d+) rgb=(\d+),(\d+),(\d+)/g)) {
  probes.set(`${m[1]},${m[2]}`, [ +m[3], +m[4], +m[5] ]);
}
const fails = [];
// A DIFFERENT RASTERISER, SO A TOLERANCE — but the same ±2 the Linux gate uses.
// Widening it "because Windows" would be exactly the move that lets a real
// colour regression through; solid fills are solid on both backends, and this
// run measured all four probes EXACT.
const near = (a, b) => Math.abs(a - b) <= 2;

const check = (label, xy, expect) => {
  const got = probes.get(xy.join(','));
  if (!got) { fails.push(`${label}: engine never reported probe ${xy}`); return; }
  if (!expect.every((e, i) => near(e, got[i]))) {
    fails.push(`${label}: probe ${xy} expected rgb=${expect} got rgb=${got}`);
  } else console.log(`   OK ${label} @${xy} rgb=${got}`);
};

for (const b of g.boxes) {
  check(`${b.id} fill`, b.probe, b.expect);
  if (b.cornerProbe) check(`${b.id} corner (must be background)`, b.cornerProbe, b.cornerExpect);
}

const ink = log.match(/ink_band=[\d,]+ ink=(\d+) of (\d+)/);
if (!ink) fails.push('label: engine never reported the ink band');
else if (+ink[1] < 40) fails.push(`label: only ${ink[1]}/${ink[2]} ink pixels — text did not render`);
else console.log(`   OK label ink=${ink[1]}/${ink[2]}`);

// LAYOUT, which ink cannot prove (a 0x0 text node still paints glyphs at the
// node origin). The fixture's measured range is deliberately wide enough to
// span a legitimate FONT SUBSTITUTION: this run measured 140x37 on Windows
// against 140x31 on Linux — same width, taller line box, both inside the range.
// That delta is a real platform difference, not a defect.
const frames = [];
for (const m of log.matchAll(/node_frame=([^,]+),(\d+),([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)/g)) {
  frames.push({name: m[1], x: +m[3], y: +m[4], w: +m[5], h: +m[6]});
}
const p = frames.find(f => f.name === 'Paragraph');
if (!p) fails.push('label: no Paragraph node — <Text> never mounted');
else {
  const [minW, minH] = g.label.measuredMin, [maxW, maxH] = g.label.measuredMax;
  if (p.w < minW || p.h < minH) fails.push(`label: Paragraph measured ${p.w}x${p.h}, below the ${minW}x${minH} floor — TextLayoutManager is returning stub sizes`);
  else if (p.w > maxW || p.h > maxH) fails.push(`label: Paragraph measured ${p.w}x${p.h}, above ${maxW}x${maxH}`);
  else console.log(`   OK label measured ${p.w}x${p.h}`);
}

for (const b of g.boxes) {
  const f = frames.find(fr => fr.x === b.x && fr.y === b.y);
  if (!f) fails.push(`${b.id}: no node laid out at ${b.x},${b.y}`);
  else if (f.w !== b.width || f.h !== b.height) fails.push(`${b.id}: laid out ${f.w}x${f.h}, fixture says ${b.width}x${b.height}`);
}

if (fails.length) { console.error('P5_WIN_FAIL:\n  ' + fails.join('\n  ')); process.exit(1); }
NODE

echo "== 7. CROSS-WIRING: the Windows frame must not BE the Linux frame =="
# ⛔ THIS GATE'S FAILURE MODE IS PASSING WITHOUT RUNNING ON WINDOWS. Every
# assertion above is satisfied by a Linux frame, so if the plumbing ever falls
# back — stale screenshot, wrong exe, a copied baseline — the gate goes green
# while proving nothing. Two independently-rasterised frames of the same scene
# are correct AND unequal (antialiasing and glyph rasterisation differ), so
# byte-equality is evidence of a wiring bug, not of quality.
[ -s "$WSL_WORK/frame.ppm" ] || fail "the engine reported a screenshot but $WSL_WORK/frame.ppm is missing"
if [ -n "${LINUX_FRAME:-}" ] && [ -s "$LINUX_FRAME" ]; then
  if cmp -s "$WSL_WORK/frame.ppm" "$LINUX_FRAME"; then
    fail "the Windows frame is BYTE-IDENTICAL to the Linux frame — two rasterisers cannot agree bit-for-bit, so this is a cross-wiring bug, not a pass"
  fi
  echo "   OK frames differ (same scene, different rasteriser)"
else
  echo "   SKIP no Linux frame in this run (WIN_BUNDLE was supplied)"
fi

echo "P5_WIN_PASS (nodes=$NODES painted=$PAINTED renderer=ANGLE/D3D11)"
