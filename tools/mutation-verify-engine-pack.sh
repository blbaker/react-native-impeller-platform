#!/usr/bin/env bash
# MUTATION-VERIFY tools/ci-engine-pack.sh against a REAL darwin engine package.
#
# Each mutant breaks a copy of the package the way a real release could break,
# and the gate must FAIL on the arm that owns that failure. The control (an
# unmodified copy) must PASS, so a gate that fails everything is caught too.
#
#   M0  control, unmodified ................................. PASS
#   M1  the 0.1.0 shape: Hermes as hermesvm.framework with
#       its symlinks, rn-impeller linked through @rpath ...... A fails
#                                                (macOS: D fails, "bundle format")
#   M2  libhermesvm.dylib not shipped ........................ C fails
#   M3  rn-impeller asks for @rpath/nested/libhermesvm.dylib . C fails
#   M4  package.json "files" leaves the dylibs out ........... B fails
#
# Usage: bash tools/mutation-verify-engine-pack.sh <staged darwin engine package dir>
# Needs install_name_tool (macOS) or llvm-install-name-tool (Linux). On Linux
# arm D is skipped by the gate, so M1 asserts arm A only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/ci-engine-pack.sh"
SRC="${1:?usage: mutation-verify-engine-pack.sh <darwin engine package dir>}"
[ -f "$SRC/bin/libhermesvm.dylib" ] && [ -f "$SRC/bin/rn-impeller" ] \
  || { echo "VERIFY_FAIL: $SRC is not a flat-Hermes darwin package (bin/libhermesvm.dylib + bin/rn-impeller)"; exit 1; }

INT="$(command -v install_name_tool || true)"
[ -n "$INT" ] || INT="$(compgen -c llvm-install-name-tool | sort -V | tail -1)"
[ -n "$INT" ] && command -v "$INT" >/dev/null \
  || { echo "VERIFY_FAIL: no install_name_tool or llvm-install-name-tool; cannot build the mutants"; exit 1; }
DARWIN=0; [ "$(uname -s)" = "Darwin" ] && DARWIN=1

W="$(mktemp -d "${TMPDIR:-/tmp}/engine-pack-mut-XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail() { echo "VERIFY_FAIL: $*"; exit 1; }
resign() { [ "$DARWIN" = 1 ] || return 0; codesign --force --sign - "$@" >/dev/null 2>&1 || fail "codesign $*"; }
fresh() { rm -rf "$W/p"; cp -R "$SRC" "$W/p"; }
OTOOL="$(command -v otool || compgen -c llvm-otool | sort -V | tail -1)"
[ -n "$OTOOL" ] || { echo "VERIFY_FAIL: no otool or llvm-otool"; exit 1; }
# rn-impeller's current Hermes load command.
HREF() { "$OTOOL" -L "$W/p/bin/rn-impeller" | awk '/hermesvm/{print $1}'; }

PASS=0
check() { # name, expected rc, regex the output must match
  local out rc
  out="$(bash "$GATE" "$W/p" 2>&1)"; rc=$?
  if [ "$rc" != "$2" ] || ! grep -qE "$3" <<<"$out"; then
    echo "  [$1] EXPECTED rc=$2 and /$3/, GOT rc=$rc:"; sed 's/^/      /' <<<"$out"; fail "$1"
  fi
  echo "  [$1] rc=$rc, matched /$3/ ... OK"; PASS=$((PASS+1))
}

echo "mutation-verify-engine-pack: $(basename "$SRC") (install_name_tool=$INT, darwin=$DARWIN)"

fresh
check "M0 control PASSES          " 0 'ENGINE_PACK_PASS'

fresh  # M1: put the framework back the way Hermes builds it and 0.1.0 staged it.
B="$W/p/bin"; OLD="$(HREF)"
mkdir -p "$B/hermesvm.framework/Versions/0/Resources"
mv "$B/libhermesvm.dylib" "$B/hermesvm.framework/Versions/0/hermesvm"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>hermesvm</string><key>CFBundleIdentifier</key><string>dev.hermesengine.hermesvm</string><key>CFBundlePackageType</key><string>FMWK</string></dict></plist>\n' \
  > "$B/hermesvm.framework/Versions/0/Resources/Info.plist"
(cd "$B/hermesvm.framework" && ln -s 0 Versions/Current && ln -s Versions/Current/hermesvm hermesvm \
  && ln -s Versions/Current/Resources Resources)
"$INT" -id @loader_path/hermesvm.framework/Versions/0/hermesvm "$B/hermesvm.framework/Versions/0/hermesvm" 2>/dev/null
"$INT" -change "$OLD" @rpath/hermesvm.framework/Versions/0/hermesvm "$B/rn-impeller" 2>/dev/null
resign "$B/rn-impeller" "$B/hermesvm.framework/Versions/0/hermesvm"
if [ "$DARWIN" = 1 ]; then
  check "M1 0.1.0 shape FAILS A     " 1 'arms: A D\)'
  out="$(bash "$GATE" "$W/p" 2>&1)"
  grep -q 'bundle format' <<<"$out" || { sed 's/^/      /' <<<"$out"; fail "M1: arm D failed, but not on the bundle format"; }
  echo "  [M1 arm D names the defect   ] /bundle format/ ... OK"
else
  check "M1 0.1.0 shape FAILS A     " 1 'arms: A\)'
fi

fresh
rm "$W/p/bin/libhermesvm.dylib"
check "M2 dylib not shipped FAILS C" 1 'libhermesvm\.dylib resolves to nothing'

fresh
"$INT" -change "$(HREF)" @rpath/nested/libhermesvm.dylib "$W/p/bin/rn-impeller" 2>/dev/null
resign "$W/p/bin/rn-impeller"
check "M3 bad @rpath ref FAILS C  " 1 '@rpath/nested/libhermesvm\.dylib resolves to nothing'

fresh
python3 - "$W/p/package.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["files"] = ["bin/rn-impeller", "README.md"]
json.dump(d, open(p, "w"), indent=2)
PY
check "M4 files filter FAILS B    " 1 'libhermesvm\.dylib is staged but not in the tarball'

echo "VERIFY_OK ${PASS}/5 cases behaved as specified."
