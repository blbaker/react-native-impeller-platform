#!/usr/bin/env bash
# Fetch the pinned Impeller standalone SDK prebuilt for this host.
# No Flutter engine build, no depot_tools. Pinned SHA = deliberate, gated bumps.
set -euo pipefail
cd "$(dirname "$0")/.."
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk}"

# ⛔ THE PLATFORM IS THE **TARGET**, NOT ALWAYS THE HOST.
#
# Cross-compiling for Android means fetching android-arm64 from an x86_64
# Linux box, so the platform must be overridable. Verified: android-arm64 is
# published at this SHA (207 MB) and its include/impeller.h is BYTE-IDENTICAL
# to the linux-x64 one (md5 cde5d565420f5458a7b0acbf476b69a4) -- the C ABI is
# the same, which is what makes the engine portable without a source fork.
#
#   RNI_SDK_PLATFORM=android-arm64 tools/sdk-fetch.sh <dest>
#
if [ -n "${RNI_SDK_PLATFORM:-}" ]; then
  PLAT="$RNI_SDK_PLATFORM"
else
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  PLAT=linux-x64 ;;
  Linux-aarch64) PLAT=linux-arm64 ;;
  Darwin-arm64)  PLAT=darwin-arm64 ;;
  Darwin-x86_64) PLAT=darwin-x64 ;;
  MINGW*|MSYS*|CYGWIN*) PLAT=windows-x64 ;;
  *) echo "unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
fi

URL="https://storage.googleapis.com/flutter_infra_release/flutter/${SHA}/${PLAT}/impeller_sdk.zip"
echo "SHA=${SHA} PLAT=${PLAT}"

if [ -f "${DEST}/.stamp" ] && [ "$(cat "${DEST}/.stamp")" = "${SHA}-${PLAT}" ]; then
  echo "already present, up to date"; exit 0
fi

code=$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")
[ "$code" = "200" ] || { echo "prebuilt missing for ${SHA}/${PLAT} (HTTP ${code})" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/sdk.zip" "$URL"
rm -rf "$DEST"; mkdir -p "$DEST"
# unzip is not always installed (it is absent on this WSL box); python always is.
python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/sdk.zip" "$DEST"

# Upstream ships debug symbols; strip for size (README says to before deployment).
# ⚠️ Host `strip` cannot touch an ARM64 object. Use the NDK's llvm-strip when
# cross-fetching, and skip rather than risk a corrupted library.
STRIP_BIN=""
case "$PLAT" in
  android-*)
    NDK_STRIP="${ANDROID_HOME:-$HOME/android-toolchain/sdk}/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
    [ -x "$NDK_STRIP" ] && STRIP_BIN="$NDK_STRIP"
    ;;
  *)
    command -v strip >/dev/null && STRIP_BIN="strip"
    ;;
esac
if [ -f "${DEST}/lib/libimpeller.so" ] && [ -n "$STRIP_BIN" ]; then
  before=$(stat -c%s "${DEST}/lib/libimpeller.so")
  "$STRIP_BIN" --strip-unneeded "${DEST}/lib/libimpeller.so" || true
  echo "libimpeller.so ${before} -> $(stat -c%s "${DEST}/lib/libimpeller.so") bytes"
fi

echo "${SHA}-${PLAT}" > "${DEST}/.stamp"
echo "SDK_FETCH_OK ${DEST}"
