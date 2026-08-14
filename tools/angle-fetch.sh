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

# WHICH PLATFORM'S ANGLE (P6, 2026-08-14)
# ---------------------------------------
# macOS needs ANGLE for the SAME reason Windows does, and the reason is not
# "no GPU API" — it is that the only offscreen surface constructor in the whole
# SDK is `ImpellerSurfaceCreateWrappedFBONew`, which takes a **GL framebuffer**.
# `ImpellerSurfaceCreateWrappedMetalDrawableNew` needs a CAMetalDrawable, i.e. a
# CAMetalLayer in a window — and over SSH `launchctl managername` is `Background`
# so Cocoa refuses to make one. Every headless frame therefore goes through
# GLES3, and macOS ships no GLES and no EGL at all (its system GL is a frozen
# desktop 2.1 compatibility profile). So: ANGLE, translating GLES3 onto Metal.
#
# Set explicitly rather than sniffed from `uname`: this script is run on Linux
# to STAGE another host's artifacts, so the build host is not the target.
ANGLE_PLATFORM="${ANGLE_PLATFORM:-win-x64}"

case "$ANGLE_PLATFORM" in
  win-x64)
    ASSET="win32-x64"
    EGL_NAME="libEGL.dll"; GLES_NAME="libGLESv2.dll"
    ZIP_EGL="libEGL.dll";  ZIP_GLES="libGLESv2.dll"
    # SHA256 as extracted from electron-${ELECTRON_VERSION}-win32-x64.zip.
    # A version tag alone is not integrity: GitHub release assets can be replaced.
    EXPECT_EGL="a3b40bb99acd821d955e4a26555b43efe12bd98056a8b7693be0e63b9ed53910"
    EXPECT_GLES="01eeec6f3451d5981ce883e9ec7a346c96173bb58854c5c3f3452e1637fb6d6f"
    DEFAULT_DEST="engine/third_party/angle-win-x64"
    ;;
  darwin-arm64)
    ASSET="darwin-arm64"
    EGL_NAME="libEGL.dylib"; GLES_NAME="libGLESv2.dylib"
    # Buried in the app bundle, unlike the flat win32 zip.
    ZIP_EGL="Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libEGL.dylib"
    ZIP_GLES="Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libGLESv2.dylib"
    EXPECT_EGL="1f528ff244242f20d87ada00b8ae0ef5e137a7f1e156535728d6fc487c246ebf"
    EXPECT_GLES="307e181f4e042b10109bf7182e5eb0f0e6ca46649ae0d03038aefb1b23b43cc4"
    DEFAULT_DEST="engine/third_party/angle-darwin-arm64"
    ;;
  *)
    echo "angle-fetch: FAIL — unknown ANGLE_PLATFORM '${ANGLE_PLATFORM}'" >&2; exit 1 ;;
esac

DEST="${1:-$DEFAULT_DEST}"

STAMP="${ELECTRON_VERSION}-${ANGLE_PLATFORM}-${EXPECT_EGL:0:12}"
if [ -f "${DEST}/.stamp" ] && [ "$(cat "${DEST}/.stamp")" = "${STAMP}" ]; then
  echo "angle-fetch: already present, up to date (${ELECTRON_VERSION} ${ANGLE_PLATFORM})"
  exit 0
fi


URL="https://github.com/electron/electron/releases/download/${ELECTRON_VERSION}/electron-${ELECTRON_VERSION}-${ASSET}.zip"
echo "angle-fetch: ${ELECTRON_VERSION} ${ANGLE_PLATFORM}"

code=$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")
[ "$code" = "200" ] || { echo "angle-fetch: FAIL — asset missing (HTTP ${code}) ${URL}" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/electron.zip" "$URL"

mkdir -p "$DEST"
# unzip is not installed on this box; python always is (same as sdk-fetch.sh).
python3 - "$tmp/electron.zip" "$DEST" \
  "$ZIP_EGL" "$EGL_NAME" "$EXPECT_EGL" \
  "$ZIP_GLES" "$GLES_NAME" "$EXPECT_GLES" <<'PY'
import hashlib, sys, zipfile
zip_path, dest = sys.argv[1:3]
rest = sys.argv[3:]
z = zipfile.ZipFile(zip_path)
names = set(z.namelist())
for zip_name, out_name, expected in zip(rest[0::3], rest[1::3], rest[2::3]):
    if zip_name not in names:
        # A path that moved inside the bundle must be loud, not a silent skip:
        # an absent library reads downstream as "the engine can't init GL".
        print(f"angle-fetch: FAIL — {zip_name} not in the asset", file=sys.stderr)
        sys.exit(1)
    data = z.read(zip_name)
    got = hashlib.sha256(data).hexdigest()
    if got != expected:
        # A mismatch means the pinned asset changed underneath us. Refuse rather
        # than silently shipping an unreviewed graphics driver.
        print(f"angle-fetch: FAIL — {out_name} sha256 {got} != pinned {expected}", file=sys.stderr)
        sys.exit(1)
    with open(f"{dest}/{out_name}", "wb") as f:
        f.write(data)
    print(f"angle-fetch: {out_name} {len(data)} bytes sha256 OK")
PY

# Electron's LICENSE covers the bundled Chromium/ANGLE binaries; ship it beside
# them so the engine package is redistributable without a licence audit.
curl -sL -o "${DEST}/LICENSE.electron" \
  "https://raw.githubusercontent.com/electron/electron/${ELECTRON_VERSION}/LICENSE"

# ⛔ THE DESTINATION MUST HOLD EXACTLY ONE PLATFORM'S ANGLE (P6, 2026-08-14)
# `mkdir -p` never clears, so pointing this script at a directory that already
# holds another platform's ANGLE leaves BOTH sets behind. Nothing downstream
# would complain — the engine loads the pair it names, and the extra files ride
# along into the npm package as dead weight that a licence audit then has to
# explain. Refuse instead: a mixed directory means a caller passed the wrong
# DEST, and continuing silently is how it ships.
_strays=""
for f in "${DEST}"/*; do
  b="$(basename "$f")"
  case "$b" in
    "$EGL_NAME"|"$GLES_NAME"|LICENSE.electron|.stamp) ;;
    *) _strays="${_strays} ${b}" ;;
  esac
done
if [ -n "$_strays" ]; then
  echo "angle-fetch: FAIL — ${DEST} holds files from another platform:${_strays}" >&2
  echo "angle-fetch:        one directory per ANGLE_PLATFORM; pass a distinct DEST" >&2
  exit 1
fi

echo "${STAMP}" > "${DEST}/.stamp"
echo "ANGLE_FETCH_OK ${DEST}"
