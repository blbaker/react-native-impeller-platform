#!/usr/bin/env bash
# Stage the iOS Simulator Impeller SDK from a linux host (iOS Task 1.6).
#
# Same role as tools/sdk-fetch-darwin.sh, but no prebuilt exists for iOS
# (flutter_infra publishes no ios impeller_sdk.zip at any SHA, and
# flutter/BUILD.gn builds the SDK only for mac/linux/win/android/qnx), so the
# "fetch" is a build ON A MAC: tools/impeller-sdk-ios-build.sh in this
# worktree's copy there (tools/mac-run.sh). The SDK stays on the Mac, where the
# iOS gates link it.
#   RNI_MAC_HOST=<ssh host> bash tools/sdk-fetch-ios.sh
# Env: RNI_MAC_TREE (default rni-ios), RNI_SDK_WORK (forwarded), RNI_ABI_REF.
#
# ABI parity, like sdk-fetch-darwin.sh: the iOS archive's exported Impeller*
# functions must equal the linux custom SDK's built from the same patches
# (RNI_ABI_REF, default engine/third_party/impeller-sdk-custom/lib/libimpeller.so).
# iOS compiles the GLES/Vulkan entry points too (ios/0006 guards bodies, not
# declarations), so the sets are expected to match exactly.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${RNI_MAC_HOST:?RNI_MAC_HOST=<ssh host of a Mac> is required}"
export RNI_MAC_TREE="${RNI_MAC_TREE:-rni-ios}" RNI_MAC_ENV="RNI_SDK_WORK"
DEST=engine/third_party/impeller-sdk-ios-simulator-arm64
REF="${RNI_ABI_REF:-engine/third_party/impeller-sdk-custom/lib/libimpeller.so}"
say() { echo "[sdk-fetch-ios] $*"; }

bash tools/mac-run.sh bash tools/impeller-sdk-ios-build.sh "$DEST" | tee /dev/stderr | grep -q '^IMPELLER_SDK_IOS_OK ' \
  || { say "FAIL: the Mac build did not finish"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ssh -o BatchMode=yes "$HOST" "cat ~/$RNI_MAC_TREE/$DEST/lib/exports.txt" > "$tmp/ios.syms"
ssh -o BatchMode=yes "$HOST" "cat ~/$RNI_MAC_TREE/$DEST/.stamp" > "$tmp/stamp"
if [ -f "$REF" ]; then
  readelf --dyn-syms -W "$REF" | awk '$4=="FUNC" && $7!="UND" {print $8}' | sed 's/@.*//' \
    | grep '^Impeller' | sort -u > "$tmp/linux.syms"
  if ! diff -q "$tmp/linux.syms" "$tmp/ios.syms" > /dev/null; then
    say "FAIL: ios-simulator/linux export sets differ:"
    diff "$tmp/linux.syms" "$tmp/ios.syms" | head -20
    exit 1
  fi
  say "ABI parity OK ($(wc -l < "$tmp/ios.syms") exports match $REF)"
else
  say "NOTE: no $REF, ABI parity NOT checked ($(wc -l < "$tmp/ios.syms") iOS exports)"
fi
say "stamp: $(tr '\n' ' ' < "$tmp/stamp")"
echo "SDK_FETCH_IOS_OK $HOST:~/$RNI_MAC_TREE/$DEST"
