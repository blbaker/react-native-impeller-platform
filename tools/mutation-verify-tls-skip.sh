#!/usr/bin/env bash
# MUTATION-VERIFY the TLS skip-detection guard in tools/ci-p10.sh.
#
# WHY THIS EXISTS. The guard's whole job is to redden on a run that CANNOT be
# produced on a box with working egress: one where both certificate arms print
# "SKIP (no network)". Running ci-p10.sh here always has internet, so the happy
# path is the only path that ever executes and the guard is never observed
# doing its job. That is the same false-green shape the guard was written to
# prevent, one level up.
#
# ⛔ IT DOES NOT SHELL OUT TO THE NETWORK, AND IT DOES NOT BUILD THE ENGINE.
# ci-p10.sh's step 1 is extracted verbatim from the real file (so an edit to the
# gate that drops the guard is CAUGHT rather than silently diverging from a
# retyped copy) and run against three scripted --test-http logs. Everything is
# offline: no badssl.com, no ninja, no consumer install.
set -euo pipefail
cd "$(dirname "$0")/.."

GATE="tools/ci-p10.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

note() { printf '%s\n' "$*"; }
bad()  { printf 'MUTATION-VERIFY FAIL: %s\n' "$*" >&2; FAILED=1; }

# --- extract the guard from the REAL gate, never a retyped copy --------------
# From the HTTPRAW assignment through the closing fi of the skip block.
awk '/^HTTPRAW=/{f=1} f{print} f && /^fi$/{exit}' "$GATE" > "$WORK/guard.sh"
grep -q 'SKIP (no network)' "$WORK/guard.sh" \
  || { echo "extraction failed: no skip check in the extracted body" >&2; exit 1; }
grep -q 'RNI_REQUIRE_TLS' "$WORK/guard.sh" \
  || { echo "extraction failed: no RNI_REQUIRE_TLS in the extracted body" >&2; exit 1; }
note "extracted $(wc -l < "$WORK/guard.sh") lines of guard from $GATE"

# --- scripted engine logs ----------------------------------------------------
mkstub() { # $1=dest  $2=logfile
  cat > "$1" <<STUB
#!/usr/bin/env bash
cat "$2"
exit 0
STUB
  chmod +x "$1"
}

cat > "$WORK/log-ran.txt" <<'EOF'
  a bad certificate is REJECTED, not accepted    ok
  the bad-cert error names the certificate, not the network ok
  a cert for the WRONG HOSTNAME is rejected      ok
http-selftest: PASS (0 failures)
EOF

cat > "$WORK/log-skipped.txt" <<'EOF'
  SKIP (no network): bad-cert arm — Connection refused
  SKIP (no network): wrong-host arm — Connection refused
http-selftest: PASS (0 failures)
EOF

# The nastiest case: the arms neither ran nor skipped. A deleted assertion, a
# renamed check, or a build with RNI_WITH_TLS off all produce this — and the
# final PASS line is IDENTICAL to a healthy run.
cat > "$WORK/log-absent.txt" <<'EOF'
  connection to a closed port reports an error   ok
http-selftest: PASS (0 failures)
EOF

# ⛔ THE DRIVER IS A REAL FILE, NOT AN INLINE `bash -c '...'` INSIDE `$( )`.
# A multi-line single-quoted script nested in a command substitution is a
# quoting minefield: the first attempt here died with "syntax error near
# unexpected token `('" pointing at a line 15 lines away from the actual fault,
# which is exactly the kind of harness bug that scores as a real failure.
cat > "$WORK/drive.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
WORK="$PWD"
ENGINE_LOCAL="$PWD/engine"
fail() { printf 'FAILED: %s\n' "$*"; exit 1; }
source ./guard.sh
DRIVER
chmod +x "$WORK/drive.sh"

run_guard() { # $1=logfile  $2=RNI_REQUIRE_TLS  -> prints output, returns rc
  local rc=0 out
  mkstub "$WORK/engine" "$1"
  out="$(env RNI_REQUIRE_TLS="$2" bash "$WORK/drive.sh" 2>&1)" || rc=$?
  printf '%s' "$out"
  return $rc
}

# --- case 1: arms RAN, guard must pass and say so ---------------------------
note ""
note "case 1: both certificate arms ran (the only case a networked box produces)"
if OUT="$(run_guard "$WORK/log-ran.txt" 0)"; then
  printf '%s\n' "$OUT" | grep -q "TLS negative controls RAN" \
    || bad "case 1 passed but did not report that the arms ran"
  note "   PASS, reported: $(printf '%s' "$OUT" | grep 'TLS negative controls RAN')"
else
  bad "case 1: guard failed on a healthy log"
fi

# --- case 2: arms SKIPPED, default mode -> pass but LOUD --------------------
note ""
note "case 2: both arms skipped, RNI_REQUIRE_TLS unset -> pass, but must WARN"
if OUT="$(run_guard "$WORK/log-skipped.txt" 0)"; then
  printf '%s\n' "$OUT" | grep -q "NOT proven by this run" \
    || bad "case 2: a skipped run passed SILENTLY — this is the bug the guard exists to stop"
  printf '%s\n' "$OUT" | grep -q "bad-cert arm" \
    || bad "case 2: the warning did not name which arms skipped"
  note "   PASS with warning, as designed"
else
  bad "case 2: guard failed with RNI_REQUIRE_TLS unset (should warn, not fail)"
fi

# --- case 3: arms SKIPPED, RNI_REQUIRE_TLS=1 -> MUST FAIL -------------------
note ""
note "case 3: both arms skipped, RNI_REQUIRE_TLS=1 -> must FAIL"
if OUT="$(run_guard "$WORK/log-skipped.txt" 1)"; then
  bad "case 3: RNI_REQUIRE_TLS=1 did NOT fail on a skipped run"
else
  printf '%s\n' "$OUT" | grep -q "RNI_REQUIRE_TLS=1" \
    || bad "case 3 failed, but not for the stated reason"
  note "   FAILED as required: $(printf '%s' "$OUT" | grep FAILED)"
fi

# --- case 4: arms neither ran nor skipped -> MUST FAIL in every mode --------
# This is the one `tail -1` could never see: PASS on the last line, assertions
# gone from the body.
note ""
note "case 4: assertions ABSENT (neither ok nor skip) -> must FAIL even unset"
if OUT="$(run_guard "$WORK/log-absent.txt" 0)"; then
  bad "case 4: a log with NO certificate assertions at all passed the guard"
else
  printf '%s\n' "$OUT" | grep -qE "chain-trust arm|hostname-verification arm" \
    || bad "case 4 failed, but not for the stated reason"
  note "   FAILED as required: $(printf '%s' "$OUT" | grep FAILED)"
fi

# --- mutants: delete the guard, confirm the cases stop being caught ---------
# A guard that is never observed ABSENT proves nothing: if case 2/3/4 still
# behave with the block removed, they were being decided by something else.
note ""
note "mutants: remove the guard and confirm cases 2-4 stop being caught"

mutate() { # $1=sed-expr  $2=label
  local m="$WORK/mut.sh"
  sed "$1" "$WORK/guard.sh" > "$m"
  cmp -s "$m" "$WORK/guard.sh" && { bad "mutant '$2' changed nothing"; return; }
  bash -n "$m" 2>/dev/null || { bad "mutant '$2' is not valid bash — proves nothing"; return; }
  cp "$m" "$WORK/guard.sh.bak" >/dev/null 2>&1 || true
  local saved="$WORK/guard.orig.sh"
  [ -f "$saved" ] || cp "$WORK/guard.sh" "$saved"
  cp "$m" "$WORK/guard.sh"
  local rc=0
  run_guard "$WORK/log-skipped.txt" 1 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    note "   mutant '$2': skipped-run-with-REQUIRE_TLS now PASSES (guard was load-bearing) ✓"
  else
    bad "mutant '$2': still failed — case 3 is being decided by something other than this guard"
  fi
  cp "$saved" "$WORK/guard.sh"
}

# M1: delete the entire if/fi skip block.
mutate '/^if grep -q "SKIP (no network)"/,/^fi$/d' "delete the skip block"

# M2: keep the block but neuter the RNI_REQUIRE_TLS escalation.
mutate 's/^  if \[ "\${RNI_REQUIRE_TLS:-0}" = "1" \]; then$/  if false; then/' "neuter RNI_REQUIRE_TLS"

note ""
if [ "$FAILED" -eq 0 ]; then
  echo "TLS_SKIP_GUARD_MUTATION_VERIFIED (4 cases, 2 mutants, no network used)"
else
  echo "TLS_SKIP_GUARD_MUTATION_FAILED" >&2
  exit 1
fi
