#!/usr/bin/env bash
# Gate: the engine resolver must work through a SYMLINKED package (pnpm link:/
# file:/npm link), and must NOT change what a normally-installed consumer
# resolves.
#
# Why this gate exists (P10, 2026-09-02):
# resolve.js resolved the engine package from `__dirname` only, with a comment
# claiming "link, install and tarball must all work". The link case was never
# TESTED -- no gate had ever run the resolver through a symlink -- so the claim
# was true in a comment and false in fact. A downstream app (hostapp-v5) linking the
# checkout got "Missing engine package" with the engine correctly installed,
# because resolution starts from the symlink TARGET (inside this checkout, which
# has no node_modules) rather than from the app.
#
# The fix is an ORDERED candidate list, and the order is the whole safety
# argument. So this gate asserts BOTH halves:
#   PASS 1  linked consumer resolves at all              (the bug)
#   PASS 2  installed consumer still resolves from __dirname, and a DECOY
#           engine sitting in the CWD does NOT outrank it (the regression)
# Half 2 is the one that matters long-term: it is what stops someone "fixing"
# a future resolver bug by putting CWD first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIPLE="$(node -e 'process.stdout.write(process.platform+"-"+process.arch)')"
PKG="@react-native-impeller/engine-${TRIPLE}"
ENGDIR="${ROOT}/packages-engine/engine-${TRIPLE}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "${ENGDIR}/package.json" ]]; then
  echo "LINKRESOLVE_SKIP: no built engine at ${ENGDIR} (run tools/engine-build.sh)"
  exit 0
fi

# resolveEngine() also verifies the binary exists, so make sure one is staged.
if [[ ! -x "${ENGDIR}/bin/rn-impeller" && ! -f "${ENGDIR}/bin/rn-impeller.exe" ]]; then
  echo "LINKRESOLVE_SKIP: engine package present but binary not built"
  exit 0
fi

# Ask the resolver, from a given cwd/INIT_CWD, using a given core copy.
# Prints "<source> <binary>" or "THREW <first line>".
ask() { # $1=core dir  $2=cwd  $3=INIT_CWD(optional)
  ( cd "$2" && INIT_CWD="${3:-}" node -e '
      const {resolveEngine} = require(process.argv[1] + "/src/resolve.js");
      try { const r = resolveEngine(); console.log(r.source, r.binary); }
      catch (e) { console.log("THREW", e.message.split("\n")[0]); }
    ' "$1" )
}

fail() { echo "LINKRESOLVE_FAIL: $*"; exit 1; }

# ---------------------------------------------------------------- PASS 1: link
LAPP="${WORK}/linked/apps/hostapp"
mkdir -p "${LAPP}/node_modules/@react-native-impeller"
printf '{"name":"hostapp","version":"1.0.0"}' > "${LAPP}/package.json"
ln -s "${ROOT}/package" "${LAPP}/node_modules/@react-native-impeller/core"
ln -s "${ENGDIR}"       "${LAPP}/node_modules/@react-native-impeller/engine-${TRIPLE}"
LCORE="${LAPP}/node_modules/@react-native-impeller/core"

echo "== 1. linked consumer, cwd = the app =="
r="$(ask "$LCORE" "$LAPP")"; echo "   $r"
[[ "$r" == THREW* ]] && fail "linked consumer (cwd=app) still throws: $r"

echo "== 2. linked consumer, cwd elsewhere, INIT_CWD = the app (npm script) =="
r="$(ask "$LCORE" "$WORK" "$LAPP")"; echo "   $r"
[[ "$r" == THREW* ]] && fail "linked consumer (INIT_CWD=app) still throws: $r"

echo "== 3. linked checkout, no consumer anchor at all =="
r="$(ask "$LCORE" "$WORK")"; echo "   $r"
[[ "$r" == THREW* ]] && fail "linked checkout fallback throws: $r"
[[ "$r" == linked-checkout* ]] || fail "expected linked-checkout fallback, got: $r"

# ------------------------------------------------------------- PASS 2: install
IAPP="${WORK}/installed/app"
mkdir -p "${IAPP}/node_modules/@react-native-impeller"
printf '{"name":"installed","version":"1.0.0"}' > "${IAPP}/package.json"
cp -r "${ROOT}/package" "${IAPP}/node_modules/@react-native-impeller/core"
cp -r "${ENGDIR}"       "${IAPP}/node_modules/@react-native-impeller/engine-${TRIPLE}"
ICORE="${IAPP}/node_modules/@react-native-impeller/core"
IEXPECT="${IAPP}/node_modules/@react-native-impeller/engine-${TRIPLE}"

echo "== 4. installed consumer resolves from __dirname =="
r="$(ask "$ICORE" "$IAPP")"; echo "   $r"
[[ "$r" == package\ ${IEXPECT}/* ]] || fail "installed consumer did not resolve from its own package: $r"

# A decoy engine in the CWD. If candidate order ever gets inverted, an installed
# app run from the wrong directory silently picks up a foreign engine binary --
# an ABI mismatch that presents as a renderer bug. This assertion is the reason
# __dirname is index 0.
echo "== 5. decoy engine in CWD must NOT outrank the installed one =="
DECOY="${WORK}/decoy"
mkdir -p "${DECOY}/node_modules/@react-native-impeller/engine-${TRIPLE}/bin"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({name:process.argv[2],version:require(process.argv[3]).version}))' \
  "${DECOY}/node_modules/@react-native-impeller/engine-${TRIPLE}/package.json" "$PKG" "${ROOT}/package/package.json"
cp "${ENGDIR}/bin/rn-impeller"* "${DECOY}/node_modules/@react-native-impeller/engine-${TRIPLE}/bin/" 2>/dev/null || true
r="$(ask "$ICORE" "$DECOY" "$DECOY")"; echo "   $r"
[[ "$r" == package\ ${IEXPECT}/* ]] || fail "CWD decoy outranked the installed engine -- candidate order is inverted: $r"

echo "LINKRESOLVE_PASS (triple=${TRIPLE}: linked resolves, installed unchanged, decoy rejected)"
