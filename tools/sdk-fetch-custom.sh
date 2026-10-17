#!/usr/bin/env bash
# Fetch the prebuilt custom Impeller SDK for one platform: the pinned Flutter
# engine (engine/IMPELLER_SHA) plus engine/impeller-sdk-patches/*.patch.
#
#   bash tools/sdk-fetch-custom.sh <linux-x64|darwin-arm64|win32-x64> [dest]
#
# WHY PREBUILT
# The patches add what the stock SDK lacks and the engine relies on: letter and
# word spacing, font features, text decorations, paragraph placeholders, the
# GLES blur fix, context flags. Building that SDK means a ~10 GB Flutter
# checkout (tools/impeller-sdk-custom-build.sh, -build-win.sh), which no CI run
# should repeat. Each patch set is built once and uploaded to a GitHub release
# named in engine/IMPELLER_SDK_CUSTOM, with every archive pinned by sha256.
#
# WHY IT IS NOT OPTIONAL
# Without it, a fresh checkout or a CI runner fell back to the stock SDK
# without a word. That build compiles and links, then paints no underline and
# no letter spacing, and the engine published to npm would have been missing
# features every local build had. ci-style-audit.sh caught it on the first CI
# run that got far enough. engine-build.sh now fetches this SDK instead, and
# fails loudly when it can't.
#
# ⛔ THE BINARY MUST MATCH THE PATCHES IN THIS COMMIT.
# The archive's .stamp records the engine sha and the sha256 of the patches it
# was built from. Both must equal this checkout's. Edit a patch without
# uploading a new SDK and this script fails, naming the step to take, rather
# than building an engine against binaries made from different source.
set -euo pipefail
cd "$(dirname "$0")/.."

PLAT="${1:?usage: sdk-fetch-custom.sh <linux-x64|darwin-arm64|win32-x64> [dest]}"
case "$PLAT" in
  linux-x64)    DEFAULT_DEST="engine/third_party/impeller-sdk-custom-parity" ;;
  darwin-arm64) DEFAULT_DEST="engine/third_party/impeller-sdk-custom-parity-darwin" ;;
  win32-x64)    DEFAULT_DEST="engine/third_party/impeller-sdk-custom-parity-win" ;;
  *) echo "sdk-fetch-custom: FAIL — unknown platform '$PLAT'" >&2; exit 1 ;;
esac
DEST="${2:-$DEFAULT_DEST}"
PIN="engine/IMPELLER_SDK_CUSTOM"
BASE="${RNI_SDK_CUSTOM_BASE_URL:-https://github.com/blbaker/react-native-impeller-platform/releases/download}"

fail() { echo "sdk-fetch-custom: FAIL — $*" >&2; exit 1; }
pin() { sed -n "s/^$1=//p" "$PIN" | tr -d '\r' | head -1; }
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64
  else shasum -a 256 "$1" | cut -c1-64; fi
}

[ -f "$PIN" ] || fail "$PIN is missing"
RELEASE="$(pin release)"
WANT_PATCH="$(pin patch_sha256)"
WANT_ARCHIVE="$(pin "$PLAT")"
ENGINE_SHA="$(tr -d '[:space:]' < engine/IMPELLER_SHA)"
[ -n "$RELEASE" ] && [ -n "$WANT_PATCH" ] || fail "$PIN has no release= or patch_sha256= line"
[ -n "$WANT_ARCHIVE" ] || fail "$PIN pins no archive for $PLAT"

HAVE_PATCH="$(cat engine/impeller-sdk-patches/*.patch | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-64)"
if [ "$HAVE_PATCH" != "$WANT_PATCH" ]; then
  echo "sdk-fetch-custom: FAIL — the patches in engine/impeller-sdk-patches changed, and" >&2
  echo "  the pinned SDK was built from different ones." >&2
  echo "    patches in this checkout: $HAVE_PATCH" >&2
  echo "    pinned SDK was built from: $WANT_PATCH" >&2
  echo "  Rebuild the SDK for each platform (tools/impeller-sdk-custom-build.sh," >&2
  echo "  tools/impeller-sdk-custom-build-win.sh), upload it to a new release, and" >&2
  echo "  update $PIN. RNI_STOCK_IMPELLER_SDK=1 builds against the stock SDK on" >&2
  echo "  purpose, without the patched features." >&2
  exit 1
fi

stamp_ok() {  # dir
  [ -f "$1/include/impeller.h" ] && [ -f "$1/.stamp" ] \
    && grep -qx "sha=$ENGINE_SHA" "$1/.stamp" \
    && grep -qx "patch_sha256=$WANT_PATCH" "$1/.stamp"
}
if stamp_ok "$DEST"; then
  echo "sdk-fetch-custom: $DEST already matches ($PLAT, patches ${WANT_PATCH:0:12})"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdk-fetch-custom.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
URL="$BASE/$RELEASE/impeller-sdk-custom-$PLAT.tar.gz"
echo "sdk-fetch-custom: downloading $URL"
curl -fsSL --retry 3 -o "$TMP/sdk.tar.gz" "$URL" || fail "download failed: $URL"
GOT="$(sha256 "$TMP/sdk.tar.gz")"
[ "$GOT" = "$WANT_ARCHIVE" ] || fail "sha256 mismatch for $PLAT: got $GOT, pinned $WANT_ARCHIVE"

mkdir -p "$TMP/x"
tar -xzf "$TMP/sdk.tar.gz" -C "$TMP/x"
stamp_ok "$TMP/x" || fail "the archive's .stamp does not match this checkout (engine $ENGINE_SHA, patches $WANT_PATCH): $(tr '\n' ' ' < "$TMP/x/.stamp" 2>/dev/null)"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/x" "$DEST"
echo "sdk-fetch-custom: OK $PLAT -> $DEST (patches ${WANT_PATCH:0:12})"
