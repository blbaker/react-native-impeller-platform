#!/usr/bin/env bash
# MUTATION VERIFICATION for the openURL predicate (ENG-38) and the windowed
# Linking.openURL gate (ENG-55).
#
# `rn-impeller --test-openurl` is the only check on isOpenableUrl, which is
# the guard in front of execl/execlp/ShellExecuteW. Before ENG-38 its table had
# no benign URL with & or %, so a predicate that refused every OAuth link
# printed OPENURL_PASS. This proves the table can go RED in each direction:
#
#   M1  the ENG-38 bug itself: & and % refused on http(s) again
#   M2  the relaxation leaks to every scheme (mailto gets & and %)
#   M3  any % accepted, not only a well-formed %HH escape (MS07-061 shape)
#   M1w M1 again, caught by the windowed gate (tools/ci-openurl-window.sh)
#   M4w openURL skips the predicate; --test-openurl is blind to it, the
#       windowed gate's hostile control arm is not
#
# Each self-test mutant must make --test-openurl print OPENURL_FAIL with the
# expected MISMATCH line; each windowed mutant must fail the windowed gate with
# the expected reason. Then the tree is restored and both must PASS again.
# Restore is cp + touch, never cp -p: an old mtime makes ninja skip the rebuild
# and the mutant stays linked into every later gate.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"

PM="engine/modules/PlatformModules.cpp"
case "$(uname -s)" in
  Darwin) BIN="packages-engine/engine-darwin-arm64/bin/rn-impeller" ;;
  Linux)  BIN="packages-engine/engine-linux-x64/bin/rn-impeller" ;;
  *) echo "MUTATION_OPENURL_FAIL: Linux or macOS only (a Windows mutant would open the real browser)" >&2; exit 1 ;;
esac
BACKUP="$(mktemp -d)"
cp "$PM" "$BACKUP/PM.cpp"
restore() { cp "$BACKUP/PM.cpp" "$PM"; touch "$PM"; }
trap 'restore; rm -rf "$BACKUP"' EXIT

mutate() {
  python3 - "$PM" "$1" "$2" <<'PY'
import sys
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if find not in s:
    sys.stderr.write("MUTANT DID NOT APPLY - pattern not found:\n%s\n" % find)
    sys.exit(1)
open(path, "w").write(s.replace(find, repl, 1))
PY
}

build() {
  bash tools/engine-build.sh > "$BACKUP/build.log" 2>&1 \
    || { tail -20 "$BACKUP/build.log" >&2; echo "MUTATION_OPENURL_FAIL: build failed" >&2; exit 1; }
}

KILLED=0
SURVIVED=0
run_mutant() {  # name find replace expect-ERE
  local name="$1" find="$2" repl="$3" expect="$4"
  restore
  mutate "$find" "$repl"
  build
  local out rc=0
  out="$("$BIN" --test-openurl)" || rc=$?
  if [ "$rc" != 0 ] && echo "$out" | grep -q '^OPENURL_FAIL' && echo "$out" | grep -qE "$expect"; then
    echo "   $name KILLED: $(echo "$out" | grep -E "$expect" | head -1 | sed 's/^ *//')"
    KILLED=$((KILLED + 1))
  else
    echo "   $name SURVIVED (rc=$rc): $(echo "$out" | tail -3 | tr '\n' ' ')"
    SURVIVED=$((SURVIVED + 1))
  fi
}

WEB='const bool web = (scheme == "http" || scheme == "https");'
HEX='if (i + 2 >= url.size() || !std::isxdigit((unsigned char)url[i + 1]) ||
          !std::isxdigit((unsigned char)url[i + 2])) {'

echo "== M1: & and % refused on http(s) again (the ENG-38 bug) =="
run_mutant M1 "$WEB" 'const bool web = false;' \
  'MISMATCH https://example.com/a\?b=1&c=2 +expected=open got=refuse'
echo "== M2: the relaxation leaks to mailto =="
run_mutant M2 "$WEB" 'const bool web = true;' \
  'MISMATCH mailto:a@example.com\?subject=x&body=y +expected=refuse got=open'
echo "== M3: any % accepted, not only %HH =="
run_mutant M3 "$HEX" 'if (false) {' \
  'MISMATCH https://example.com/%zz +expected=refuse got=open'

# The windowed gate (ci-openurl-window.sh) must also go RED: M1 is the ENG-38
# bug end to end, and M4 bypasses the predicate inside openURL only, which the
# self-test cannot see at all (its table calls isOpenableUrl directly).
# Linux by default: on macOS a mutant that opens would launch the real browser
# (set RNI_OPENURL_ALLOW_LAUNCH=1 to accept that).
run_window_mutant() {  # name find replace expect-ERE
  local name="$1" find="$2" repl="$3" expect="$4"
  restore
  mutate "$find" "$repl"
  build
  local out rc=0
  out="$(bash tools/ci-openurl-window.sh 2>&1)" || rc=$?
  if [ "$rc" = 1 ] && echo "$out" | grep -qE "$expect"; then
    echo "   $name KILLED by ci-openurl-window: $(echo "$out" | grep -E "$expect" | head -1)"
    KILLED=$((KILLED + 1))
  else
    echo "   $name SURVIVED ci-openurl-window (rc=$rc): $(echo "$out" | tail -3 | tr '\n' ' ')"
    SURVIVED=$((SURVIVED + 1))
  fi
}
if [ "$(uname -s)" != Darwin ] || [ "${RNI_OPENURL_ALLOW_LAUNCH:-0}" = 1 ]; then
  echo "== M1w: the ENG-38 bug, seen from a windowed JS Linking.openURL =="
  run_window_mutant M1w "$WEB" 'const bool web = false;' \
    "OPENURL_WINDOW_FAIL: a: no 'rn-impeller: openURL=https://example.com/\?a=1&b=2' line on stdout"
  echo "== M4w: openURL skips the predicate (self-test blind to this) =="
  run_window_mutant M4w '  if (!isOpenableUrl(target)) {' '  if (false && !isOpenableUrl(target)) {' \
    'OPENURL_WINDOW_FAIL: C: (no REFUSED line on stderr|the hostile URL was launched)'
else
  echo "== M1w/M4w SKIPPED on macOS (a surviving mutant would open the real browser) =="
fi

echo "== restore: the real predicate must PASS again =="
restore
build
OUT="$("$BIN" --test-openurl)" || { echo "$OUT"; echo "MUTATION_OPENURL_FAIL: restored tree fails the self-test" >&2; exit 1; }
echo "   $OUT"
echo "$OUT" | grep -q '^OPENURL_PASS' || { echo "MUTATION_OPENURL_FAIL: restored tree did not print OPENURL_PASS" >&2; exit 1; }
if [ "$(uname -s)" != Darwin ] || [ "${RNI_OPENURL_ALLOW_LAUNCH:-0}" = 1 ]; then
  WOUT="$(bash tools/ci-openurl-window.sh 2>&1)" || { echo "$WOUT" | tail -5; echo "MUTATION_OPENURL_FAIL: restored tree fails ci-openurl-window" >&2; exit 1; }
  echo "   $(echo "$WOUT" | tail -1)"
fi

trap - EXIT
rm -rf "$BACKUP"
if [ "$SURVIVED" != 0 ]; then
  echo "MUTATION_OPENURL_FAIL ($KILLED killed, $SURVIVED survived)"
  exit 1
fi
echo "MUTATION_OPENURL_PASS ($KILLED/$KILLED mutants killed, restored tree passes)"
