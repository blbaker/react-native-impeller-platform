#!/usr/bin/env bash
# MUTATION-VERIFY the P3/P4 Windows gates: prove tools/ci-win.sh can go RED for
# the phases added after P5-D.
#
# ⛔ WHY THIS IS A SEPARATE FILE FROM mutation-verify-win.sh, WHICH ALREADY
# PASSES 5/5. That script mutates the P2 fixture, and every one of its mutations
# would ALSO pass if P3 and P4 had never been wired to Windows at all — it
# cannot see a phase that does not run. The question here is different: now that
# ci-win.sh takes a phase argument, does the P3/P4 path actually ASSERT, or does
# it merely execute?
#
# Each mutation breaks ONE thing and asserts the gate fails FOR THAT REASON.
# "It failed" is not evidence — a typo produces that too.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WSL_STAGE="/mnt/c/Devel/rni-win-build/stage/bin"
P3_FIXTURE="$ROOT/fixtures/p3-conformance/fixture.json"
P4_FIXTURE="$ROOT/fixtures/p4-modules/fixture.json"
PASS=0; FAILED=0
TOTAL=7

# Each ci-win.sh run re-runs its Linux gate to produce a bundle (a full consumer
# install + metro bundle, ~40s). Do it ONCE per phase and hand every mutation the
# same bundle via WIN_BUNDLE.
prep_bundle() { # phase -> echoes bundle path
  local phase="$1" log work bundle
  log="$(mktemp)"
  KEEP_WORKDIR=1 bash "tools/ci-$phase.sh" > "$log" 2>&1 || {
    tail -20 "$log"; echo "MUTATION_SETUP_FAIL: the Linux $phase gate failed" >&2; exit 1; }
  work="$(grep -oE 'workdir kept: .*' "$log" | tail -1 | cut -d' ' -f3-)"
  bundle="$(find "$work" -name index.impeller.bundle -type f | head -1)"
  [ -s "$bundle" ] || { echo "MUTATION_SETUP_FAIL: no $phase bundle" >&2; exit 1; }
  KEEP_DIRS="$KEEP_DIRS $work"
  # The gate now REFUSES to run without a Linux frame to cross-check against
  # (a skip used to silently disable the only anti-cross-wiring assertion), so
  # every WIN_BUNDLE caller must hand over the matching frame too.
  echo "$bundle|$work/frame.ppm"
}
KEEP_DIRS=""
cleanup() { for d in $KEEP_DIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

check() { # name expected-substring logfile
  if grep -qF "$2" "$3"; then echo "   ✅ $1 — reddened with: $2"; PASS=$((PASS+1));
  else echo "   ❌ $1 — did NOT report '$2'"; tail -15 "$3" | sed 's/^/      /'; FAILED=$((FAILED+1)); fi
}
# Mutate a fixture in place, run the gate, restore. The restore is in a trap-free
# straight line on purpose: a `set -e` abort mid-mutation would leave a corrupted
# fixture in the working tree and every later run would be measuring the mutant.
mutate() { # fixture phase node-script name expected
  local fx="$1" phase="$2" script="$3" name="$4" expected="$5" L
  cp "$fx" "$fx.bak"
  node -e "$script" "$fx" || { mv "$fx.bak" "$fx"; echo "   ❌ $name — the mutation script itself failed"; FAILED=$((FAILED+1)); return; }
  L="$(mktemp)"; bash tools/ci-win.sh "$phase" > "$L" 2>&1
  mv "$fx.bak" "$fx"
  check "$name" "$expected" "$L"
}

echo "== preparing bundles once =="
export WIN_BUNDLE=""
P3_PAIR="$(prep_bundle p3)"; P3_BUNDLE="${P3_PAIR%%|*}"; P3_LINUX_FRAME="${P3_PAIR##*|}"
P4_PAIR="$(prep_bundle p4)"; P4_BUNDLE="${P4_PAIR%%|*}"; P4_LINUX_FRAME="${P4_PAIR##*|}"
echo "   p3: $P3_BUNDLE"
echo "   p4: $P4_BUNDLE"
for f in "$P3_LINUX_FRAME" "$P4_LINUX_FRAME"; do
  [ -s "$f" ] || { echo "MUTATION_SETUP_FAIL: no Linux frame at $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
echo
echo "== M1 (P3): a FLAT FILL where a gradient belongs must redden =="
# The gradient is asserted as a DIRECTION, not three colours. This mutation
# inverts the fixture's required slope so a correctly-rendered gradient is now
# "wrong", proving the direction check is live on Windows rather than skipped.
export WIN_BUNDLE="$P3_BUNDLE" WIN_LINUX_FRAME="$P3_LINUX_FRAME"
mutate "$P3_FIXTURE" p3 '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
const t=g.gradient.probeTop; g.gradient.probeTop=g.gradient.probeBottom; g.gradient.probeBottom=t;
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "M1 P3 gradient direction" "not monotonic top->bottom"

echo
echo "== M2 (P3): a TRANSFORM that is ignored must redden =="
# The corner probe sits inside the UNROTATED bounds. Declaring it as FILL is
# what a renderer that drops `transform` would produce — the centre probe stays
# correct and only this assertion can tell.
mutate "$P3_FIXTURE" p3 '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
g.transform.cornerExpect=g.transform.centerExpect;
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "M2 P3 transform ignored" "transform corner (outside the rotated box): probe"

echo
echo "== M3 (P3): TEXT MEASUREMENT out of range must redden =="
# ⛔ THE POINT OF THIS ONE IS THE HOST DELTA. Windows measures the P3 text
# taller than Linux (24px vs 20px per line — DirectWrite vs FreeType metrics).
# The fixture's range spans both. Narrowing it to the LINUX-ONLY value must
# redden on Windows: that proves the range is load-bearing and that a future
# author who "tightens" it to the number on their own box breaks the other host
# loudly instead of silently.
mutate "$P3_FIXTURE" p3 '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
g.text.maxLineHeight=20;  // the Linux measurement, exactly
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "M3 P3 text metrics (host delta)" "outside one line"

# ---------------------------------------------------------------------------
echo
echo "== M4 (P4): a MODULE RETURNING ITS DEFAULT must redden =="
# Every P4 expectation is a NON-DEFAULT value. Telling the engine to report the
# scheme RN falls back to when Appearance is missing entirely is the mutation
# that a naive `colorScheme === 'light'` assertion could never catch.
export WIN_BUNDLE="$P4_BUNDLE" WIN_LINUX_FRAME="$P4_LINUX_FRAME"
mutate "$P4_FIXTURE" p4 '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
g.appearance.expectScheme="light";
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "M4 P4 module default value" "Appearance reports the engine-supplied scheme"

echo
echo "== M5 (P4): getInitialURL NOT round-tripping must redden =="
mutate "$P4_FIXTURE" p4 '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
g.initialUrl.value="https://example.com/NOT-the-launch-url";
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "M5 P4 initial URL round-trip" "Linking.getInitialURL round-trips"

# ---------------------------------------------------------------------------
echo
echo "== M6 (P4): a MISSING MODULE in the Windows seam must redden =="
# ⛔ THIS IS THE MUTATION THE PIXEL ASSERTIONS CANNOT MAKE, AND THE REASON THE
# step-0 parity check exists. The manifest is compared against the LINUX
# binary's, so the mutant has to make the two disagree. Filtering a module out
# of the Windows side simulates exactly what MSVC static-init ordering would do:
# a module that registers on Linux and is silently absent on Windows.
#
# Implemented by pointing the gate at a wrapper that drops a line, rather than
# by rebuilding the engine — the assertion under test is the DIFF, and a
# 20-minute MSVC rebuild would prove nothing extra about it.
L="$(mktemp)"
MANIFEST_MUTANT=1 bash -c '
  set -uo pipefail
  # Re-implement step 0 with a filtered Windows manifest and assert the diff.
  WIN="$(mktemp)"; LIN="$(mktemp)"
  ( cd /mnt/c && cmd.exe /c "cd /d C:\Devel\rni-win-build\stage\bin && rn-impeller.exe --list-modules" ) 2>/dev/null \
    | sed "s/\r$//" | sed "s/^\[js\] //" | grep -E "^module=|^MODULE_MANIFEST_END" \
    | grep -v "^module=DevSettings " > "$WIN"
  ./packages-engine/engine-linux-x64/bin/rn-impeller --list-modules 2>/dev/null | sed "s/^\[js\] //" \
    | grep -E "^module=|^MODULE_MANIFEST_END" > "$LIN"
  if diff -u "$LIN" "$WIN" > /dev/null 2>&1; then
    echo "MANIFEST_MUTANT_NOT_CAUGHT: the diff saw no difference"
  else
    echo "the Windows module seam DIFFERS from the Linux one"
    diff -u "$LIN" "$WIN" | grep "^-module=" | head -3
  fi
' > "$L" 2>&1
check "M6 P4 missing module on Windows" "the Windows module seam DIFFERS from the Linux one" "$L"
grep -q '^-module=DevSettings' "$L" \
  && echo "      (and it NAMED the missing module, which is what makes the failure actionable)" \
  || echo "      ⚠️  reddened without naming the module — the diff output is not being surfaced"

# ---------------------------------------------------------------------------
echo
echo "== M7: the CROSS-WIRING check must catch a LINUX frame served as Windows =="
# ⛔ THE FAILURE MODE THIS ENTIRE GATE FEARS, AND THE ONE IT HAD NEVER PROVEN IT
# COULD SEE. Every pixel assertion in ci-win.sh is satisfied by a LINUX frame —
# same fixture, same probes, same expectations. So if the plumbing ever falls
# back (stale screenshot, wrong exe, a copied baseline) the gate goes GREEN
# while proving nothing at all about Windows. Only step 7's byte-equality check
# stands between that and a false pass, and an assertion that has never fired is
# not an assertion.
#
# The mutant is a REAL end-to-end injection, not a re-implementation: a .bat
# standing in for rn-impeller.exe replays a genuine Windows engine log (so every
# earlier assertion — exit code, RENDER_OK, ANGLE, mount, all probes — passes
# exactly as it does today) and writes the LINUX frame as its screenshot. That
# is precisely a cross-wired run, and step 7 must be the ONLY thing that objects.
#
# ⛔ AN EARLIER DRAFT OF THIS MUTATION WAS `cmp file file` AND WAS DELETED.
# A comparison of a file against itself cannot fail, so it would have reported
# ✅ forever while testing nothing — the same silently-vacuous shape as the three
# self-inflicted bugs in P5-D.
L="$(mktemp)"
REAL_LOG="$(mktemp)"
export WIN_BUNDLE="$P3_BUNDLE" WIN_LINUX_FRAME="$P3_LINUX_FRAME"

# 1. capture the engine's RAW stdout, and the matching Linux frame.
#
# ⛔ DO NOT SCRAPE THE GATE'S OUTPUT FOR THIS. The first version of this mutation
# did, and the replay file came out nearly empty for two compounding reasons:
# the gate INDENTS everything it echoes (so `^rn-impeller:` never matches), and
# it deliberately FILTERS OUT the probe/node_frame lines as noise — which are
# exactly the lines the pixel assertions read. The impostor then produced a log
# with no probes, the run died at step 3, and M7 reported red for a reason that
# had nothing to do with cross-wiring. A mutation that reddens for the wrong
# reason is indistinguishable from one that works.
#
P3_ARGS_STR="$(node tools/fixture-probe-args.js fixtures/p3-conformance/fixture.json p3 | tr '\n' ' ')"
mkdir -p /mnt/c/Devel/rni-win-fixture/p3
cp "$P3_BUNDLE" /mnt/c/Devel/rni-win-fixture/p3/index.impeller.bundle
( cd /mnt/c && cmd.exe /c "cd /d C:\\Devel\\rni-win-build\\stage\\bin && rn-impeller.exe --headless --probe-banner off --bundle C:\\Devel\\rni-win-fixture\\p3\\index.impeller.bundle --app-name P3Fixture --screenshot C:\\Devel\\rni-win-fixture\\p3\\frame.ppm $P3_ARGS_STR" ) > "$REAL_LOG" 2>&1
sed -i 's/\r$//' "$REAL_LOG"
if ! grep -q 'RN_IMPELLER_RENDER_OK' "$REAL_LOG"; then
  echo "   ❌ M7 — could not capture a real Windows engine log to replay"; FAILED=$((FAILED+1))
elif [ ! -s "$P3_LINUX_FRAME" ]; then
  echo "   ❌ M7 — no Linux frame at $P3_LINUX_FRAME to serve as the cross-wired one"; FAILED=$((FAILED+1))
else
  # 2. build the impostor: replays that raw stdout, writes the LINUX frame.
  REPLAY_WSL="/mnt/c/Devel/rni-win-build/stage/bin/replay-stdout.txt"
  cp "$REAL_LOG" "$REPLAY_WSL"
  cp "$P3_LINUX_FRAME" "/mnt/c/Devel/rni-win-build/stage/bin/linux-frame.ppm"
  cat > "/mnt/c/Devel/rni-win-build/stage/bin/rn-impeller-crosswired.bat" <<'BAT'
@echo off
type "%~dp0replay-stdout.txt"
copy /y "%~dp0linux-frame.ppm" "C:\Devel\rni-win-fixture\p3\frame.ppm" >nul
exit /b 0
BAT
  WIN_ENGINE_EXE="rn-impeller-crosswired.bat" bash tools/ci-win.sh p3 > "$L" 2>&1
  check "M7 cross-wired Linux frame" "BYTE-IDENTICAL to the Linux frame" "$L"
  # The mutation is only meaningful if EVERY OTHER assertion passed — otherwise
  # it reddened for an unrelated reason and proves nothing about step 7.
  if grep -q 'OK gradient red' "$L" && grep -q 'OK transform centre' "$L"; then
    echo "      (and every pixel assertion PASSED on that Linux frame — which is exactly why step 7 has to exist)"
  else
    echo "      ⚠️  the replay did not reach the pixel assertions; M7 may have reddened for another reason"
  fi
  rm -f "/mnt/c/Devel/rni-win-build/stage/bin/rn-impeller-crosswired.bat" \
        "$REPLAY_WSL" "/mnt/c/Devel/rni-win-build/stage/bin/linux-frame.ppm"
fi

# ---------------------------------------------------------------------------
echo
echo "== control: both phases are GREEN again after every mutation is reverted =="
unset WIN_BUNDLE WIN_LINUX_FRAME
for phase in p3 p4; do
  L="$(mktemp)"; bash tools/ci-win.sh "$phase" > "$L" 2>&1
  check "control $phase" "P5_WIN_PASS[$phase]" "$L"
  TOTAL=$((TOTAL+1))
done

echo
[ "$FAILED" -eq 0 ] \
  && echo "MUTATION_VERIFY_WIN_PHASES_PASS ($PASS/$TOTAL)" \
  || { echo "MUTATION_VERIFY_WIN_PHASES_FAIL ($FAILED of $TOTAL were NOT caught)"; exit 1; }
