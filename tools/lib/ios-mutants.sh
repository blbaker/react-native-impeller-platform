# shellcheck shell=bash
# iOS Phase 1: shared mutant runner for the tools/mutation-verify-*-ios*.sh
# scripts. Runs on linux: each mutant is applied to this worktree, the gate is
# run (it re-execs on the Mac, which syncs the MUTATED tree), and the gate must
# fail on the arm written for that mutant. Sources are restored on exit, and a
# final clean run proves the restored tree passes.
#
#   mut_backup FILE...           originals saved; restored on EXIT
#   mut_apply FILE OLD NEW       OLD must occur exactly once in FILE; if not, the
#                                next mut_expect reports NOT APPLIED (a failure)
#                                instead of running the unmutated tree
#   mut_expect NAME GATE ERE     gate must exit non-zero AND print a line matching ERE
#   mut_restore                  put every original back
#   mut_clean GATE ERE           restored tree: gate must exit 0 and print ERE
#   mut_summary TAG              prints <TAG>_PASS / <TAG>_FAIL, sets the exit code
MUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MUT_BACKUP="$(mktemp -d)"
MUT_FILES=()
MUT_RESULTS=()
MUT_BAD=0
MUT_APPLIED=1

mut_restore() {
  local f
  for f in "${MUT_FILES[@]}"; do cp "$MUT_BACKUP/$(echo "$f" | tr / _)" "$MUT_ROOT/$f"; done
}
trap 'mut_restore; rm -rf "$MUT_BACKUP"' EXIT

mut_backup() {
  local f
  for f in "$@"; do
    MUT_FILES+=("$f")
    cp "$MUT_ROOT/$f" "$MUT_BACKUP/$(echo "$f" | tr / _)"
  done
}

mut_apply() {
  MUT_APPLIED=1
  python3 - "$MUT_ROOT/$1" "$2" "$3" << 'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "mutant anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
  [ $? = 0 ] || MUT_APPLIED=0
}

mut_expect() {
  local name="$1" gate="$2" ere="$3" log rc
  if [ "$MUT_APPLIED" != 1 ]; then
    MUT_APPLIED=1
    mut_restore
    MUT_RESULTS+=("$name NOT APPLIED: its anchor is not in the source (fix the mutant)")
    MUT_BAD=1
    echo "${MUT_RESULTS[-1]}"
    return
  fi
  log="$(mktemp)"
  (cd "$MUT_ROOT" && bash "$gate") > "$log" 2>&1
  rc=$?
  mut_restore
  if [ "$rc" != 0 ] && grep -qE "$ere" "$log"; then
    MUT_RESULTS+=("$name caught: $(grep -m1 -E "$ere" "$log")")
  else
    MUT_RESULTS+=("$name SURVIVED (rc=$rc): $(grep -E 'FAIL|PASS' "$log" | tail -2 | tr '\n' ' ')")
    MUT_BAD=1
  fi
  echo "${MUT_RESULTS[-1]}"
  rm -f "$log"
}

mut_clean() {
  local log rc
  log="$(mktemp)"
  (cd "$MUT_ROOT" && bash "$1") > "$log" 2>&1
  rc=$?
  if [ "$rc" = 0 ] && grep -qE "$2" "$log"; then
    MUT_RESULTS+=("clean tree passes: $(grep -m1 -E "$2" "$log")")
  else
    MUT_RESULTS+=("clean tree FAILED (rc=$rc): $(tail -3 "$log" | tr '\n' ' ')")
    MUT_BAD=1
  fi
  echo "${MUT_RESULTS[-1]}"
  rm -f "$log"
}

mut_summary() {
  echo "== $1 =="
  printf '  %s\n' "${MUT_RESULTS[@]}"
  if [ "$MUT_BAD" = 0 ]; then echo "${1}_PASS"; else echo "${1}_FAIL"; fi
  return "$MUT_BAD"
}
