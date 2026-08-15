#!/usr/bin/env bash
# Build the Windows engine with MSVC and stage it into
# packages-engine/engine-win32-x64/ as a real npm package.
#
# Runs from WSL and drives the native build through cmd.exe, exactly like the
# P5-C gate does. Reached via `bash tools/engine-build.sh win32 x64` so there is
# ONE entry point for "produce the gated binary" on both platforms.
#
# WHAT THIS ENFORCES THAT THE LINUX ARM CANNOT
# --------------------------------------------
# Windows has no RPATH and no ldd. The Linux arm proves the staged binary is
# $ORIGIN-relative with `ldd` + `readelf`; here the equivalent property is
# "every non-system import is physically beside the exe", and the only honest
# way to know is to read the PE import table with dumpbin and subtract the set
# of DLLs Windows itself provides.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

ARCH="${1:-x64}"
TRIPLE="win32-${ARCH}"
PKG="packages-engine/engine-${TRIPLE}"
VERSION="$(node -p "require('${ROOT}/package/package.json').version")"

WIN_BUILD='C:\Devel\rni-win-build'
WSL_STAGE="/mnt/c/Devel/rni-win-build/stage/bin"

fail() { echo "engine-build-win: FAIL — $*" >&2; exit 1; }

[ "$ARCH" = "x64" ] || fail "only x64 is supported on Windows (asked for $ARCH)"
command -v cmd.exe >/dev/null || fail "cmd.exe not on PATH — this must run from WSL"

echo "engine-build-win: syncing sources to the Windows side"
bash tools/win-sync.sh > /dev/null || fail "win-sync.sh failed"

echo "engine-build-win: configure + build + install (MSVC, via cmd.exe)"
BUILD_LOG="$(mktemp)"
set +e
( cd /mnt/c && cmd.exe /c 'C:\Devel\rni-win-scripts\engine-build-win.bat' ) > "$BUILD_LOG" 2>&1
RC=$?
set -e
sed -i 's/\r$//' "$BUILD_LOG"
if [ "$RC" -ne 0 ]; then
  tail -40 "$BUILD_LOG" >&2
  fail "the Windows build exited $RC"
fi
# The batch file's own markers, because a build can print errors and still exit 0
# through a chain of `call`s.
grep -q '^BUILD_EXIT=0' "$BUILD_LOG" || fail "engine-build-win.bat did not report BUILD_EXIT=0"
grep -q '^INSTALL_OK'   "$BUILD_LOG" || fail "engine-build-win.bat did not report INSTALL_OK"

[ -f "$WSL_STAGE/rn-impeller.exe" ] || fail "no rn-impeller.exe at $WSL_STAGE after install"

echo "engine-build-win: staging $PKG"
rm -rf "${PKG}/bin"
mkdir -p "${PKG}/bin"
# `cmake --install` already did the selection work (COMPONENT engine); copy what
# it staged rather than re-deciding the file list here, so the package and the
# runnable stage can never disagree.
cp -a "$WSL_STAGE/." "${PKG}/bin/"

# ---------------------------------------------------------------------------
# The package must contain the payload and NOTHING ELSE — same rule as Linux.
STRAY="$(cd "${PKG}" && ls -A | grep -vE '^(bin|package\.json|README\.md)$' || true)"
[ -z "$STRAY" ] || { echo "engine-build-win: FAIL — stray files staged into the package:"; echo "$STRAY"; exit 1; }

ALLOWED='^(rn-impeller\.exe|impeller\.dll|libEGL\.dll|libGLESv2\.dll|LICENSE\.electron|msvcp140\.dll|msvcp140_1\.dll|msvcp140_2\.dll|msvcp140_atomic_wait\.dll|msvcp140_codecvt_ids\.dll|vcruntime140\.dll|vcruntime140_1\.dll|concrt140\.dll)$'
STRAY_BIN="$(cd "${PKG}/bin" && ls -A | grep -viE "$ALLOWED" || true)"
[ -z "$STRAY_BIN" ] || { echo "engine-build-win: FAIL — stray files in bin/:"; echo "$STRAY_BIN"; exit 1; }

# ---------------------------------------------------------------------------
# ⛔ THE WINDOWS EQUIVALENT OF `ldd | grep 'not found'`.
#
# There is no loader query that answers "will this run elsewhere", so read the
# PE import table and require every import to be EITHER a Windows-provided DLL
# OR a file we ship in bin/. A dependency that is neither is one that happens to
# be on this machine — the class of bug that only appears on a consumer's box,
# as a process that dies before main() printing nothing at all.
#
# icuuc/icuin are on the system list deliberately: Hermes is built with
# -DUSE_WIN10_ICU and links the ICU that ships in Windows 10 1903+ (System32).
# That is a genuine minimum-OS requirement, recorded in the package README, not
# a missing file.
DUMPBIN="$(ls -d /mnt/c/Devel/VSBuildTools/VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$DUMPBIN" ] || fail "dumpbin.exe not found under the VS Build Tools — cannot verify the import table"
WIN_DUMPBIN="$(printf '%s' "$DUMPBIN" | sed 's|^/mnt/c|C:|; s|/|\\|g')"

# ⛔ dumpbin CANNOT READ THE PACKAGE IN PLACE. The repo lives in WSL, and a
# \\wsl.localhost path is not something cmd.exe will accept — the first version
# of this check fed dumpbin a mangled path, got an empty import list, and would
# have "passed" had the emptiness not been asserted. So: copy the packaged exe
# to a real drive letter and TIE THE COPY TO THE PACKAGE BY HASH, so the check
# can never drift onto a stale binary from an earlier build.
PROBE_WSL="/mnt/c/Devel/rni-win-probe"
rm -rf "$PROBE_WSL"; mkdir -p "$PROBE_WSL"
cp "${PKG}/bin/rn-impeller.exe" "$PROBE_WSL/rn-impeller.exe"
PKG_SHA="$(sha256sum "${PKG}/bin/rn-impeller.exe" | cut -d' ' -f1)"
PROBE_SHA="$(sha256sum "$PROBE_WSL/rn-impeller.exe" | cut -d' ' -f1)"
[ "$PKG_SHA" = "$PROBE_SHA" ] || fail "the probe copy does not match the packaged binary"
WIN_PROBE='C:\Devel\rni-win-probe'

# The path is deliberately quote-free: `cmd.exe /c "prog ... \"arg\""` passes the
# inner quotes THROUGH as part of the filename (measured: LNK1104 cannot open
# file '"C:\...\rn-impeller.exe"'), and C:\Devel\rni-win-probe has no spaces.
IMPORTS="$( cd /mnt/c && cmd.exe /c "$WIN_DUMPBIN /nologo /dependents $WIN_PROBE\\rn-impeller.exe" 2>/dev/null \
            | tr -d '\r' | sed -n '/following dependencies/,/Summary/p' \
            | grep -oiE '[A-Za-z0-9_.-]+\.dll' | tr 'A-Z' 'a-z' | sort -u )"
rm -rf "$PROBE_WSL"
[ -n "$IMPORTS" ] || fail "dumpbin returned no imports — the check would silently pass"

# Provided by Windows itself (System32). api-ms-win-* are the UCRT/API-set
# forwarders present since Windows 10.
SYSTEM_DLLS='^(kernel32|kernelbase|user32|gdi32|shell32|shlwapi|advapi32|ole32|oleaut32|winmm|ws2_32|dbghelp|version|crypt32|bcrypt|ntdll|ucrtbase|icuuc|icuin|d3d11|dxgi|d3dcompiler_47|setupapi|imm32|api-ms-win-.*)\.dll$'
MISSING=""
for dll in $IMPORTS; do
  echo "$dll" | grep -qE "$SYSTEM_DLLS" && continue
  [ -f "${PKG}/bin/$dll" ] || MISSING="$MISSING $dll"
done
if [ -n "$MISSING" ]; then
  echo "engine-build-win: FAIL — imports that are neither system DLLs nor shipped in bin/:" >&2
  for d in $MISSING; do echo "    $d" >&2; done
  echo "  These resolve on THIS machine and will kill the process before main() on a consumer's." >&2
  exit 1
fi
echo "engine-build-win: import table clean ($(echo "$IMPORTS" | wc -l) imports, all system or shipped)"

# R3 size budget: <60 MB unpacked per platform, same as Linux.
UNPACKED_KB=$(du -sk "${PKG}/bin" | cut -f1)
echo "engine-build-win: unpacked payload = $((UNPACKED_KB / 1024)) MB"
[ "${UNPACKED_KB}" -le 61440 ] || fail "payload exceeds the 60 MB budget (R3)"

cat > "${PKG}/package.json" <<JSON
{
  "name": "@react-native-impeller/engine-${TRIPLE}",
  "version": "${VERSION}",
  "description": "Prebuilt Impeller engine host for ${TRIPLE} (installed automatically by @react-native-impeller/core)",
  "license": "MIT",
  "files": ["bin", "README.md"],
  "publishConfig": {
    "access": "public"
  },
  "os": ["win32"],
  "cpu": ["${ARCH}"]
}
JSON

cat > "${PKG}/README.md" <<MD
# @react-native-impeller/engine-${TRIPLE}

Prebuilt engine binary for \`react-native-impeller\` on Windows ${ARCH}.

Installed automatically as an optional dependency — do not depend on it directly.
Version is locked in step with \`react-native-impeller\`; the resolver refuses a
mismatch because the engine C ABI is not stable across versions.

## Runtime requirements

- **Windows 10 version 1903 or later.** Hermes is built against the ICU that
  ships in System32 from that release (\`icuuc.dll\`, \`icuin.dll\`). Earlier
  Windows has no system ICU and the engine will not load.
- **A GPU with a D3D11 driver.** Rendering goes through ANGLE's D3D11 backend;
  \`libEGL.dll\` and \`libGLESv2.dll\` ship in this package.
- **No Visual C++ redistributable install is required** — the MSVC runtime DLLs
  are shipped app-local beside the executable.

Impeller SDK pin: \`$(cat engine/IMPELLER_SHA)\`
ANGLE pin: \`$(cat engine/ANGLE_PIN 2>/dev/null || echo unknown)\`
React Native (ReactCommon) pin: \`$(node -p "require('${ROOT}/engine/rn/node_modules/react-native/package.json').version")\`
MD

echo "engine-build-win: staged ${PKG} @ ${VERSION}"
