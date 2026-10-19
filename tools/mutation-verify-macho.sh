#!/usr/bin/env bash
# MUTATION-VERIFY the darwin Mach-O relocatability gate in tools/engine-build.sh.
#
# A gate that has only ever passed is decoration. This one CANNOT be exercised
# by running engine-build.sh on Linux -- it needs otool/codesign and a darwin
# package -- so it is verified against stubs instead, using the gate body
# EXTRACTED LIVE from engine-build.sh by marker. Never copy-paste the body: a
# copy drifts from the shipped file and then this script verifies fiction.
# (Proven: reverting the gate to its old binary-only form makes this exit 1.)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
# tools/engine-build.sh by marker, never copy-pasted. A copy can drift from the
# shipped file and then this script verifies fiction.
set -uo pipefail


SRC="$REPO/tools/engine-build.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermes-verify-macho-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "VERIFY_FAIL: $*"; exit 1; }

# ---------------------------------------------------------------- 0. syntax
bash -n "$SRC" || fail "tools/engine-build.sh does not parse"
echo "[0] bash -n tools/engine-build.sh ....... OK"

# ------------------------------------------------- 1. extract the gate body
# From the "CHECK EVERY MACH-O" marker up to (not including) the rpath check.
START=$(grep -n 'CHECK EVERY MACH-O WE SHIP' "$SRC" | cut -d: -f1)
END=$(grep -n 'And the rpath itself must be' "$SRC" | cut -d: -f1)
[ -n "$START" ] && [ -n "$END" ] || fail "gate markers not found -- did the block get renamed?"
BODY="$WORK/gate-body.sh"
sed -n "${START},$((END-1))p" "$SRC" > "$BODY"
grep -q 'otool -D' "$BODY" || fail "extracted body has no otool -D check"
grep -q 'codesign --verify' "$BODY" || fail "extracted body has no signature check"
echo "[1] extracted gate body lines ${START}-$((END-1)) ..... OK ($(wc -l < "$BODY") lines)"

# ------------------------------------------------------------- 2. stub tools
mkdir -p "$WORK/stubs"
cat > "$WORK/stubs/otool" <<'STUB'
#!/usr/bin/env bash
# good    -> @loader_path everywhere (a `cmake --install` package)
# badname -> raw `cmake --build` output: ./libX.dylib (the macOS tester's build)
# badsig  -> names correct, signatures stripped
flag="$1"; f="$2"; base="$(basename "$f")"
case "$flag" in
  -D) echo "$f:"
      case "$STUB_MODE" in
        badname) case "$base" in *.dylib) echo "./$base" ;; esac ;;
        *)       case "$base" in *.dylib) echo "@loader_path/$base" ;; esac ;;
      esac ;;
  -L) echo "$f:"
      if [ "$STUB_MODE" = badname ]; then
        case "$base" in
          rn-impeller)     printf '\t./libimpeller.dylib (compatibility version 0.0.0)\n\t./libEGL.dylib (compatibility version 0.0.0)\n' ;;
          libGLESv2.dylib) printf '\t./libEGL.dylib (compatibility version 0.0.0)\n' ;;
        esac
      else
        case "$base" in
          rn-impeller)     printf '\t@loader_path/libimpeller.dylib (compatibility version 0.0.0)\n\t@loader_path/libhermesvm.dylib (compatibility version 0.0.0)\n' ;;
          libGLESv2.dylib) printf '\t@loader_path/libEGL.dylib (compatibility version 0.0.0)\n' ;;
        esac
      fi
      printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
      printf '\t/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (compatibility version 300.0.0)\n' ;;
esac
exit 0
STUB
cat > "$WORK/stubs/codesign" <<'STUB'
#!/usr/bin/env bash
f="${2:-}"; base="$(basename "$f")"
if [ "$STUB_MODE" = badsig ]; then
  case "$base" in
    libEGL.dylib|libimpeller.dylib)
      echo "$f: code object is not signed at all" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
chmod +x "$WORK/stubs"/*
echo "[2] stub otool + codesign staged ........ OK"

# --------------------------------------------------------- 3. fake package
PKG="$WORK/pkg"
mkdir -p "$PKG/bin"
for f in libEGL.dylib libGLESv2.dylib libimpeller.dylib libhermesvm.dylib rn-impeller; do
  echo x > "$PKG/bin/$f"
done

# ------------------------------------------------------------- 4. run cases
run_case() {
  ( set -uo pipefail
    export STUB_MODE="$1" PKG="$PKG"
    export PATH="$WORK/stubs:$PATH"
    source "$BODY" && echo "MACHO_GATE_PASS" ) 2>&1
}

echo
PASS=0
check() { # name, mode, expected_rc, must_match
  local out rc
  out="$(run_case "$2")"; rc=$?
  if [ "$rc" != "$3" ]; then
    echo "  [$1] EXPECTED rc=$3 GOT rc=$rc"; echo "$out" | sed 's/^/      /'; return 1
  fi
  if ! grep -q "$4" <<<"$out"; then
    echo "  [$1] output missing /$4/"; echo "$out" | sed 's/^/      /'; return 1
  fi
  echo "  [$1] rc=$rc, matched /$4/ ... OK"
  PASS=$((PASS+1))
}

echo "[4] mutation cases (a gate never seen to FAIL is not a gate):"
check "good package PASSES        " good    0 'MACHO_GATE_PASS'      || fail "control case"
check "relative install names FAIL" badname 1 'non-relocatable'      || fail "install-name mutant survived"
check "stripped signatures FAIL   " badsig  1 'invalid/absent signature' || fail "signature mutant survived"

# The badname case must flag the libGLESv2 -> libEGL edge, not just the exe.
#
# ⛔ CAPTURE, DO NOT `run_case badname | grep -q`. grep -q exits on first match,
# run_case is still writing, it takes SIGPIPE, and `set -o pipefail` reports the
# PIPELINE as failed -- so a gate that DID flag the edge looks like one that
# did not. Measured here: the assertion failed while the gate output plainly
# contained libGLESv2. Same trap tools/glfw-fetch.sh documents for `nm | grep -q`.
BADNAME_OUT="$(run_case badname)"
grep -q 'libGLESv2.dylib' <<<"$BADNAME_OUT" \
  || fail "badname case did not flag the inter-dylib reference"
echo "  [inter-dylib edge flagged  ] ... OK"

echo
echo "VERIFY_OK ${PASS}/3 mutation cases behaved as specified, plus inter-dylib edge."
