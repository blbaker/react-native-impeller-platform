#!/usr/bin/env bash
# Self-test for tools/lib/own-procs.sh — proves the lineage kill is surgical.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Make a binary literally named rn-impeller that just sleeps, so `ps comm=`
# reports "rn-impeller" exactly like the real engine.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "$OUTSIDER" 2>/dev/null || true' EXIT
cp "$(command -v sleep)" "$TMP/rn-impeller"

# (1) An OUTSIDER — Baker's live HostApp window. Started here, NOT under any gate.
"$TMP/rn-impeller" 300 &
OUTSIDER=$!
sleep 0.3

fails=0

# (2) A gate, run as a REAL separate process (its own $$, exactly like a real
#     `bash tools/ci-foo.sh` invocation — NOT a `( )` subshell, which shares the
#     parent's $$ and would wrongly adopt the outsider). It sources the helper,
#     launches TWO engines (one tracked via $!, one via a wrapper grandchild),
#     and cleans up with rni_kill_own.
GATE_OUT="$TMP/gate.out"
cat > "$TMP/gate.sh" <<GATE
#!/usr/bin/env bash
set -euo pipefail
. "$ROOT/tools/lib/own-procs.sh"
"$TMP/rn-impeller" 300 &        # backgrounded, tracked
rni_track "\$!"
MINE_TRACKED=\$!
# A grandchild: a wrapper subshell that itself spawns the engine, proving the
# descendant sweep reaches deeper than direct children.
( "$TMP/rn-impeller" 300 & echo "\$!" > "$TMP/grandchild.pid"; wait ) &
sleep 0.4
echo "MINE_TRACKED=\$MINE_TRACKED" > "$GATE_OUT"
rni_kill_own
GATE
bash "$TMP/gate.sh"
GRANDCHILD="$(cat "$TMP/grandchild.pid" 2>/dev/null || echo '')"
MINE_TRACKED="$(sed -n 's/MINE_TRACKED=//p' "$GATE_OUT")"
sleep 0.5

# (3) The outsider MUST still be alive.
if kill -0 "$OUTSIDER" 2>/dev/null; then
  echo "PASS: outsider (Baker's HostApp window) survived — pid $OUTSIDER"
else
  echo "FAIL: outsider was killed — pid $OUTSIDER"; fails=$((fails+1))
fi

# (4) The gate's own tracked engine MUST be dead.
if [ -n "$MINE_TRACKED" ] && kill -0 "$MINE_TRACKED" 2>/dev/null; then
  echo "FAIL: gate's tracked engine survived — pid $MINE_TRACKED"; fails=$((fails+1))
else
  echo "PASS: gate's tracked engine was killed — pid $MINE_TRACKED"
fi

# (5) The gate's grandchild engine MUST be dead (descendant sweep).
if [ -n "$GRANDCHILD" ] && kill -0 "$GRANDCHILD" 2>/dev/null; then
  echo "FAIL: gate's grandchild engine survived — pid $GRANDCHILD"; fails=$((fails+1))
else
  echo "PASS: gate's grandchild engine was killed — pid $GRANDCHILD"
fi

if [ "$fails" -eq 0 ]; then echo "OWN_PROCS_SELFTEST_PASS"; else echo "OWN_PROCS_SELFTEST_FAIL ($fails)"; exit 1; fi
