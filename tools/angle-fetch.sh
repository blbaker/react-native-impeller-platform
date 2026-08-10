#!/usr/bin/env bash
# Fetch the pinned ANGLE (libEGL.dll + libGLESv2.dll) used by the Windows engine.
#
# WHY THIS EXISTS AT ALL
# ----------------------
# The Impeller standalone SDK's only OFFSCREEN surface constructor is
# `ImpellerSurfaceCreateWrappedFBONew` — there is no Vulkan or D3D offscreen
# equivalent (`ImpellerContextCreateVulkanNew` exists, but the only other
# surface constructor wraps a CAMetalDrawable). So every headless frame this
# project renders, on every platform, goes through a GLES3 FBO. Linux gets that
# from Mesa's surfaceless EGL. Windows has no system EGL at all, so it needs
# ANGLE, which translates GLES3 onto D3D11. Verified on real hardware by
# engine/spike/headless_win_angle.cpp.
#
# WHY ELECTRON
# ------------
# ANGLE has no upstream binary release channel. The options were:
#   - build it (depot_tools + a multi-GB Chromium-shaped checkout: a phase, not a step)
#   - the `ANGLE.WindowsStore` nuget package: last published 2.1.14, ~a decade stale
#   - a CIPD package: `chromium/third_party/angle/windows-amd64` returns 405
#   - lift the DLLs from an app already on the box (VS Code, Edge)
# The last one is what the SPIKE did, and it is NOT shippable: an unpinned file
# from a directory that changes under us on every VS Code update. Electron's
# release assets are versioned, immutable, publicly downloadable and carry the
# same BSD-licensed ANGLE build Chromium ships. Pin the Electron version, pin
# the SHA256 of each DLL, verify on every fetch.
#
# Bumping the pin is a deliberate, gated commit — exactly like IMPELLER_SHA.
set -euo pipefail
cd "$(dirname "$0")/.."

ELECTRON_VERSION="$(tr -d ' \n' < engine/ANGLE_PIN)"
DEST="${1:-engine/third_party/angle-win-x64}"

# SHA256 of each DLL as extracted from electron-${ELECTRON_VERSION}-win32-x64.zip.
# A version tag alone is not integrity: GitHub release assets can be replaced.
EXPECT_EGL="a3b40bb99acd821d955e4a26555b43efe12bd98056a8b7693be0e63b9ed53910"
EXPECT_GLES="01eeec6f3451d5981ce883e9ec7a346c96173bb58854c5c3f3452e1637fb6d6f"

STAMP="${ELECTRON_VERSION}-${EXPECT_EGL:0:12}"
if [ -f "${DEST}/.stamp" ] && [ "$(cat "${DEST}/.stamp")" = "${STAMP}" ]; then
  echo "angle-fetch: already present, up to date (${ELECTRON_VERSION})"
  exit 0
fi

URL="https://github.com/electron/electron/releases/download/${ELECTRON_VERSION}/electron-${ELECTRON_VERSION}-win32-x64.zip"
echo "angle-fetch: ${ELECTRON_VERSION}"

code=$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")
[ "$code" = "200" ] || { echo "angle-fetch: FAIL — asset missing (HTTP ${code}) ${URL}" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/electron.zip" "$URL"

mkdir -p "$DEST"
# unzip is not installed on this box; python always is (same as sdk-fetch.sh).
python3 - "$tmp/electron.zip" "$DEST" "$EXPECT_EGL" "$EXPECT_GLES" <<'PY'
import hashlib, sys, zipfile
zip_path, dest, want_egl, want_gles = sys.argv[1:5]
want = {"libEGL.dll": want_egl, "libGLESv2.dll": want_gles}
z = zipfile.ZipFile(zip_path)
for name, expected in want.items():
    data = z.read(name)
    got = hashlib.sha256(data).hexdigest()
    if got != expected:
        # A mismatch means the pinned asset changed underneath us. Refuse rather
        # than silently shipping an unreviewed graphics driver.
        print(f"angle-fetch: FAIL — {name} sha256 {got} != pinned {expected}", file=sys.stderr)
        sys.exit(1)
    with open(f"{dest}/{name}", "wb") as f:
        f.write(data)
    print(f"angle-fetch: {name} {len(data)} bytes sha256 OK")
PY

# Electron's LICENSE covers the bundled Chromium/ANGLE binaries; ship it beside
# them so the engine package is redistributable without a licence audit.
curl -sL -o "${DEST}/LICENSE.electron" \
  "https://raw.githubusercontent.com/electron/electron/${ELECTRON_VERSION}/LICENSE"

echo "${STAMP}" > "${DEST}/.stamp"
echo "ANGLE_FETCH_OK ${DEST}"
