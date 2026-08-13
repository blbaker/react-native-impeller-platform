#!/usr/bin/env bash
# MUTATION-VERIFY the Windows gate: prove tools/ci-win.sh can go RED.
#
# A gate that has only ever passed is decoration. Each mutation below breaks ONE
# thing and asserts the gate fails FOR THAT REASON — not merely that it failed,
# which a typo in the script would also produce.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WSL_STAGE="/mnt/c/Devel/rni-win-build/stage/bin"
FIXTURE="$ROOT/fixtures/p2-mount/fixture.json"
PASS=0; FAILED=0

# The gate re-runs the Linux P2 gate to produce a bundle. Do that ONCE here and
# hand every mutation the same bundle via WIN_BUNDLE — otherwise this script
# costs four full metro bundles.
echo "== preparing a bundle once =="
LOG_P2="$(mktemp)"
KEEP_WORKDIR=1 bash tools/ci-p2.sh > "$LOG_P2" 2>&1 || { tail -20 "$LOG_P2"; echo "MUTATION_SETUP_FAIL: the Linux P2 gate failed"; exit 1; }
WORK="$(grep -oE 'workdir kept: .*' "$LOG_P2" | tail -1 | cut -d' ' -f3-)"
export WIN_BUNDLE="$WORK/FixtureApp/impeller/build/index.impeller.bundle"
trap 'rm -rf "$WORK"' EXIT
echo "   bundle: $WIN_BUNDLE"

check() { # name expected-substring logfile
  if grep -q "$2" "$3"; then echo "   ✅ $1 — reddened with: $2"; PASS=$((PASS+1));
  else echo "   ❌ $1 — did NOT report '$2'"; tail -15 "$3" | sed 's/^/      /'; FAILED=$((FAILED+1)); fi
}

echo
echo "== M1: a WRONG COLOUR must redden (green box declared blue) =="
cp "$FIXTURE" "$FIXTURE.bak"
node -e '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
const b=g.boxes.find(b=>b.id==="nested"); b.expect=[0,0,255];
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "$FIXTURE"
L="$(mktemp)"; bash tools/ci-win.sh > "$L" 2>&1
check "M1 wrong colour" "nested fill: probe 60,200 expected rgb=0,0,255" "$L"
mv "$FIXTURE.bak" "$FIXTURE"

echo
echo "== M2: a WRONG LAYOUT must redden (box declared 999 wide) =="
cp "$FIXTURE" "$FIXTURE.bak"
node -e '
const fs=require("fs"), p=process.argv[1];
const g=JSON.parse(fs.readFileSync(p,"utf8"));
g.boxes.find(b=>b.id==="plain").width=999;
fs.writeFileSync(p, JSON.stringify(g,null,2));
' "$FIXTURE"
L="$(mktemp)"; bash tools/ci-win.sh > "$L" 2>&1
check "M2 wrong layout" "fixture says 999x" "$L"
mv "$FIXTURE.bak" "$FIXTURE"

echo
echo "== M3: a MISSING DLL must be NAMED, not silently crash =="
# This also VERIFIES THE CLAIM the gate's comment makes: with impeller.dll gone
# the process dies before main() with no output at all. Proven here, not assumed.
mv "$WSL_STAGE/impeller.dll" "$WSL_STAGE/impeller.dll.hidden"
RAW="$(mktemp)"
# NOTE the exit code is read from cmd.exe's OWN status, not from
# `& echo EXIT=%errorlevel%` — that expands at parse time and always says 0.
( cd /mnt/c && cmd.exe /c "cd /d C:\Devel\rni-win-build\stage\bin && rn-impeller.exe --list-modules" ) > "$RAW" 2>&1
RAW_RC=$?
sed -i 's/\r$//' "$RAW"
if grep -qE '^rn-impeller:|^\[js\]' "$RAW"; then
  echo "   ⚠️  the exe still produced output without impeller.dll — the gate comment overstates it"
else
  echo "   ✅ confirmed: no output at all, rc=$RAW_RC — silent pre-main death"
fi
L="$(mktemp)"; bash tools/ci-win.sh > "$L" 2>&1
check "M3 missing DLL" "impeller.dll is not beside the exe" "$L"
mv "$WSL_STAGE/impeller.dll.hidden" "$WSL_STAGE/impeller.dll"

echo
echo "== M4: a CRASHING/NON-ZERO ENGINE must redden via the EXIT CODE =="
# ⛔ THIS MUTATION EXISTS BECAUSE THE FIRST VERSION OF THE GATE COULD NOT CATCH IT.
# The gate originally read the exit code as `& echo EXIT=%errorlevel%`, which
# cmd.exe expands at PARSE time — it printed EXIT=0 even when the exe died
# before main(). M1/M2 still passed, because a broken assertion elsewhere hides
# behind working assertions. Corrupting the bundle makes the engine exit
# non-zero while the log stays otherwise plausible, so ONLY the exit-code check
# can redden here.
CORRUPT="$(mktemp -d)/corrupt.bundle"
printf 'this is not a hermes bytecode bundle' > "$CORRUPT"
L="$(mktemp)"; WIN_BUNDLE="$CORRUPT" bash tools/ci-win.sh > "$L" 2>&1
check "M4 non-zero exit" "P5_WIN_FAIL" "$L"
if grep -q "the Windows engine exited" "$L"; then
  echo "      (caught by the EXIT CODE, which is the point of this mutation)"
else
  echo "      ⚠️  reddened, but NOT via the exit code — re-read step 3 of the gate"
fi

echo
echo "== control: the gate is GREEN again after every mutation is reverted =="
L="$(mktemp)"; bash tools/ci-win.sh > "$L" 2>&1
check "control" "P5_WIN_PASS" "$L"

echo
[ "$FAILED" -eq 0 ] && echo "MUTATION_VERIFY_WIN_PASS ($PASS/5)" || { echo "MUTATION_VERIFY_WIN_FAIL ($FAILED of 5 mutations were NOT caught)"; exit 1; }
