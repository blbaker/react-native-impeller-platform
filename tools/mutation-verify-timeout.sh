#!/usr/bin/env bash
# Mutation verification for tools/lib/portable-timeout.sh.
#
# ⛔ THE POINT: a `timeout` shim is only trustworthy if it (a) KILLS an overrun
#   at the deadline and (b) PASSES THROUGH the inner exit code otherwise. A
#   broken shim that just runs the command and never times out would let every
#   gate hang forever on a wedged engine — and would look perfectly green here
#   unless we test the timeout path explicitly.
#
#   Critically, the whole suite runs with PATH STRIPPED OF `timeout`/`gtimeout`,
#   so we exercise the perl and background-sleep FALLBACKS — the code paths that
#   actually run on a stock M1/M2 Mac. If we tested with GNU timeout on PATH we
#   would only be re-testing coreutils, never our shim.
#
# Each mutant breaks the shim in a plausible way; a mutant the assertions do not
# catch is a hole in the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIB="tools/lib/portable-timeout.sh"
BACKUP="$(mktemp -d)"
cp "$LIB" "$BACKUP/portable-timeout.sh"
trap 'cp "$BACKUP/portable-timeout.sh" "$LIB"; rm -rf "$BACKUP"' EXIT

# --- the harness --------------------------------------------------------------
# We run the shim with PATH pointed at a SANDBOX bin dir that symlinks every
# ordinary tool the shim and its test commands need — but deliberately OMITS
# `timeout` and `gtimeout`. Dropping whole PATH dirs is wrong: /usr/bin holds
# timeout AND bash/sleep/perl, so scrubbing the dir would remove the shell too.
# Symlinking a curated set instead removes ONLY timeout/gtimeout, forcing the
# perl and bg fallbacks — exactly the M1/M2 Mac code paths.
SANDBOX="$BACKUP/bin"
mkdir -p "$SANDBOX"
for t in bash sh env perl python3 sleep true cp rm mktemp cat sed awk grep head tail ps kill dirname; do
  src="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$src" ] && ln -sf "$src" "$SANDBOX/$t"
done
# Assert we did NOT accidentally drag timeout/gtimeout in via a symlink name.
rm -f "$SANDBOX/timeout" "$SANDBOX/gtimeout"
PATH_NOTO="$SANDBOX"

# assert_backend_absent: prove the scrub actually removed timeout/gtimeout.
if PATH="$PATH_NOTO" command -v timeout >/dev/null 2>&1 || \
   PATH="$PATH_NOTO" command -v gtimeout >/dev/null 2>&1; then
  echo "HARNESS BROKEN: timeout/gtimeout still on scrubbed PATH -- cannot test fallbacks"
  exit 1
fi

# run_shim BACKEND DURATION -- cmd...  -> prints exit code, honours the backend.
#   BACKEND = perl | bg   (bg additionally hides perl so the sleep+kill path runs)
run_shim() {
  local backend="$1" dur="$2"; shift 2
  local extra=""
  [ "$backend" = "bg" ] && extra='timeout(){ _pt_run_bg "$@"; };'  # force bg path
  PATH="$PATH_NOTO" bash -c '
    source tools/lib/portable-timeout.sh
    '"$extra"'
    timeout "$@"
    echo "RC=$?"
  ' _ "$dur" "$@" 2>/dev/null | sed -n 's/^RC=//p'
}

PASS=0; TOTAL=0
# For a MUTANT, "caught" means the shim's output DIFFERS from the healthy value
# the baseline just proved — i.e. a real gate assertion (rc==EXPECTED) would now
# fail. An escaped mutant produces the healthy value anyway = a hole in the gate.
caught() {  # caught LABEL HEALTHY ACTUAL
  TOTAL=$((TOTAL + 1))
  if [ "$2" != "$3" ]; then
    echo "  caught: $1 (rc=$3, healthy was $2)"; PASS=$((PASS + 1))
  else
    echo "  ⛔ NOT CAUGHT: $1 -- mutant still produced healthy rc=$2"
  fi
}
check() {  # check LABEL EXPECTED ACTUAL  (baseline only)
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok: $1 (rc=$3)"; PASS=$((PASS + 1))
  else
    echo "  ⛔ FAIL: $1 -- expected rc=$2, got rc=$3"
  fi
}

echo "MUTATION_VERIFY_TIMEOUT_START"
echo "scrubbed PATH has no timeout/gtimeout: OK"

# ---- baseline: the UNMUTATED shim must behave, on BOTH fallbacks -------------
echo "--- baseline (unmutated) ---"
for be in perl bg; do
  check "$be: fast cmd passes rc through (0)"   0   "$(run_shim "$be" 5 true)"
  check "$be: fast cmd passes rc through (7)"   7   "$(run_shim "$be" 5 bash -c 'exit 7')"
  check "$be: overrun killed -> 124"          124   "$(run_shim "$be" 1 sleep 10)"
done

# ---- mutants -----------------------------------------------------------------
mutate() { cp "$BACKUP/portable-timeout.sh" "$LIB"; python3 - "$@"; }

# M1: perl backend never arms the alarm -> overrun is NEVER killed (hangs to
# completion, returns the command's own rc). Under a real deadline this wedges
# the gate. Expect: WITHOUT the mutant rc=124; with it the sleep finishes rc=0.
echo "--- mutant M1: perl alarm disarmed (overrun not killed) ---"
mutate <<'PY'
p="tools/lib/portable-timeout.sh"; s=open(p).read()
s=s.replace("    alarm $dur;", "    alarm 0;  # MUTANT M1: never fires", 1)
open(p,"w").write(s)
PY
rc="$(run_shim perl 1 sleep 3)"
# healthy overrun -> 124; disarmed alarm lets sleep finish -> 0.
caught "M1 (perl overrun no longer killed)" 124 "$rc"

# M2: perl backend swallows the child's real exit code, always returns 0.
# A gate would treat a FAILING inner ci-*.sh as PASS. Expect rc=7 lost -> 0.
echo "--- mutant M2: perl backend hardcodes exit 0 ---"
mutate <<'PY'
p="tools/lib/portable-timeout.sh"; s=open(p).read()
s=s.replace("    exit( ($st & 127) ? 128 + ($st & 127) : ($st >> 8) );",
            "    exit 0;  # MUTANT M2: swallow child rc", 1)
open(p,"w").write(s)
PY
rc="$(run_shim perl 5 bash -c 'exit 7')"
caught "M2 (perl child rc swallowed)" 7 "$rc"

# M3: bg backend never records the timeout marker -> an overrun returns the
# racy kill rc instead of the canonical 124, so callers cannot detect a timeout.
echo "--- mutant M3: bg backend drops the 124 marker ---"
mutate <<'PY'
p="tools/lib/portable-timeout.sh"; s=open(p).read()
s=s.replace('  if [ -e "$marker" ]; then rc=124; fi',
            '  : # MUTANT M3: never set rc=124', 1)
open(p,"w").write(s)
PY
rc="$(run_shim bg 1 sleep 10)"
# healthy bg overrun -> canonical 124; without the marker the kill leaks a
# non-124 rc (e.g. 143), so a caller checking ==124 can no longer detect timeout.
caught "M3 (bg overrun no longer reports 124)" 124 "$rc"

# M4: bg backend never actually kills the overrun -> the child LEAKS past the
# deadline. rc can still read 124 via the marker, so rc alone is blind here;
# we assert on process liveness with a unique sentinel arg.
echo "--- mutant M4: bg backend does not kill on deadline ---"
mutate <<'PY'
p="tools/lib/portable-timeout.sh"; s=open(p).read()
s=s.replace('    kill -TERM "$cmdpid" 2>/dev/null',
            '    : # MUTANT M4: no TERM', 1)
s=s.replace('    kill -KILL "$cmdpid" 2>/dev/null',
            '    : # MUTANT M4: no KILL', 1)
open(p,"w").write(s)
PY
SENTINEL="pt_m4_$$_$RANDOM"
# Run the shim in the BACKGROUND: the mutant never kills the child, so the
# shim's own `wait` would otherwise block until the child exits on its own.
( run_shim bg 1 bash -c "exec -a $SENTINEL sleep 20" ) >/dev/null 2>&1 &
shim_bg=$!
sleep 2                                   # well past the 1s deadline
# set -e safe: grep -c exits 1 on zero matches, so guard with || true.
LEAK="$(ps -Ao args= 2>/dev/null | grep -c "[${SENTINEL:0:1}]${SENTINEL:1}" || true)"
TOTAL=$((TOTAL + 1))
if [ "${LEAK:-0}" -gt 0 ]; then
  echo "  caught: M4 (bg deadline leaked a live child: $LEAK proc)"; PASS=$((PASS + 1))
else
  echo "  ⛔ NOT CAUGHT: M4 -- no leaked child found, mutant escaped"
fi
# Clean up the leak we deliberately created and the backgrounded shim.
pkill -f "$SENTINEL" 2>/dev/null || true
kill "$shim_bg" 2>/dev/null || true
wait "$shim_bg" 2>/dev/null || true

# restore before summary (trap also does this)
cp "$BACKUP/portable-timeout.sh" "$LIB"

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_TIMEOUT_PASS ($PASS/$TOTAL)"
else
  echo "MUTATION_VERIFY_TIMEOUT_FAIL ($PASS/$TOTAL)"
  exit 1
fi
