#!/usr/bin/env bash
# Mutation check for tools/ci-crypto.sh (ENG-31). Each mutant breaks ONE part
# of engine/modules/CryptoGlobal.cpp (or its install); the gate must FAIL on
# each, and on the assertion aimed at it (a mutant killed by the wrong
# assertion proves nothing).
#   M1  OS bytes replaced by zeros                -> u8-32-nonzero-differ
#   M2  fixed-seed xorshift instead of the OS     -> C: two processes repeat
#   M3  view byteOffset ignored                   -> offset-respected
#   M4  quota counts ELEMENTS, not bytes          -> quota-counts-bytes
#   M5  crypto never installed                    -> bare-read
#   M6  float arrays accepted                     -> float-rejected
#   M7  buffer/offset/length read as properties   -> intrinsics-captured
#   M8  JS quota check dropped                    -> quota-65537-throws
# Not claimed: the native range re-check in nativeFill. The JS half only ever
# passes intrinsic values, so no fixture can reach it (defence in depth).
# Linux branch only (getrandom); the darwin arc4random_buf line is proven by
# running ci-crypto.sh on the Mac. Sources are restored on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
CRY=engine/modules/CryptoGlobal.cpp; RH=engine/runtime/ReactHost.cpp
BAK="$(mktemp -d)"; cp "$CRY" "$BAK/CryptoGlobal.cpp"; cp "$RH" "$BAK/ReactHost.cpp"
build() { bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1; }
restore() {
  cp "$BAK/CryptoGlobal.cpp" "$CRY"; cp "$BAK/ReactHost.cpp" "$RH"
  build || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "CRYPTO_MUTATION_FAIL: $*" >&2; exit 1; }
run_gate() { set +e; RNI_BIN= bash tools/ci-crypto.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }

mutate() {  # mutate FILE OLD NEW: exactly one occurrence, asserted
  python3 "$BAK/mut.py" "$1" "$2" "$3"
}
cat > "$BAK/mut.py" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
n = s.count(old)
assert n == 1, f"mutation anchor found {n}x in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY

check() {  # name, expected-failure-substring
  build || { tail -15 "$BAK/build.log" >&2; fail "$1 tree did not build"; }
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: gate passed with the mutant in"; fi
  grep -qF "$2" "$BAK/$1.log" || { grep CRYPTO_GATE_FAIL "$BAK/$1.log" >&2; fail "$1 killed by the WRONG assertion (wanted: $2)"; }
  echo "   OK: $1 killed ($(grep -o 'CRYPTO_GATE_FAIL: .*' "$BAK/$1.log" | cut -c1-100))"
  cp "$BAK/CryptoGlobal.cpp" "$CRY"; cp "$BAK/ReactHost.cpp" "$RH"
}

echo "== control: unmutated tree must PASS =="
build || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

GR='const ssize_t got = getrandom(out, len, 0);'
echo "== M1: zeros instead of OS bytes =="
mutate "$CRY" "$GR" 'for (size_t z = 0; z < len; ++z) out[z] = 0; const ssize_t got = static_cast<ssize_t>(len);'
check M1 "check 'u8-32-nonzero-differ' did not PASS"

echo "== M2: fixed-seed xorshift instead of OS bytes =="
mutate "$CRY" "$GR" 'static uint64_t s = 0x9E3779B97F4A7C15ull; for (size_t z = 0; z < len; ++z) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; out[z] = static_cast<uint8_t>(s >> 56); } const ssize_t got = static_cast<ssize_t>(len);'
check M2 "two processes drew the same first 32 bytes"

echo "== M3: byteOffset ignored =="
mutate "$CRY" 'if (!fillRandomBytes(data + o, n)) {' 'if (!fillRandomBytes(data, n)) {'
check M3 "check 'offset-respected' did not PASS"

echo "== M4: quota counts elements =="
mutate "$CRY" 'var len = apply(getLength, array, []);' 'var len = array.length;'
check M4 "check 'quota-counts-bytes' did not PASS"

echo "== M5: crypto never installed =="
mutate "$RH" 'installCryptoGlobal(runtime);  // ENG-31' '/* installCryptoGlobal(runtime); */  // ENG-31'
check M5 "check 'bare-read' did not PASS"

echo "== M6: float arrays accepted =="
mutate "$CRY" 'if (INTEGER[tag] !== true) {' 'if (false) {'
check M6 "check 'float-rejected' did not PASS"

echo "== M7: buffer/byteOffset/byteLength read as plain properties =="
mutate "$CRY" 'var len = apply(getLength, array, []);' 'var len = array.byteLength;'
mutate "$CRY" 'fill(apply(getBuffer, array, []), apply(getOffset, array, []), len);' 'fill(array.buffer, array.byteOffset, len);'
check M7 "check 'intrinsics-captured' did not PASS"

echo "== M8: JS quota check dropped =="
mutate "$CRY" 'if (len > QUOTA) {' 'if (false) {'
check M8 "check 'quota-65537-throws' did not PASS"

echo "CRYPTO_MUTATION_PASS (8/8 mutants killed by their own assertion)"
