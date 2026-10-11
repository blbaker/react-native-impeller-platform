#!/usr/bin/env bash
# Build the react-native-impeller custom Impeller SDK (SC-32) for the HOST
# (linux-x64; darwin-arm64 on the Mac, SC-35):
# the pinned engine (engine/IMPELLER_SHA) plus engine/impeller-sdk-patches/*.patch
# (letter/word spacing, font features, paragraph placeholders), unpacked into
# engine/third_party/impeller-sdk-custom. The stock engine/third_party/impeller-sdk
# is never touched.
#   bash tools/impeller-sdk-custom-build.sh [dest]
# Env: RNI_SDK_TARGET host (default) or android-arm64
#      RNI_SDK_WORK  checkout dir (default ~/projects/_ref/sc32, ~10 GB)
#      RNI_SDK_PATCH apply this patch instead of the committed ones
#      RNI_SDK_POST_PATCH  shell command run in the patched interop dir (mutants)
# Measured 2026-10-10 on this box (22 cores): sync 57 s, checkout 9.9 GB.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk-custom}"
WORK="${RNI_SDK_WORK:-$HOME/projects/_ref/sc32}"
OUT=rni_host_debug
GN_EXTRA=()
ANDROID_DEPS=False
SYNC_KEY="$SHA"
if [ "${RNI_SDK_TARGET:-host}" = android-arm64 ]; then
  # Cross build on the linux box; the NDK comes from the android deps.
  GN_EXTRA=(--android --android-cpu arm64); OUT=rni_android_debug_arm64
  ANDROID_DEPS=True; SYNC_KEY="$SHA android"
fi
case "$(uname -s)" in
  # Apple silicon: flutter's gn defaults --mac-cpu to x64.
  Darwin) [ "$ANDROID_DEPS" = True ] || { GN_EXTRA=(--mac-cpu arm64); OUT=rni_host_debug_arm64; }
          export PATH="$PATH:/opt/homebrew/bin" ;;  # ninja only: brew python3.14 lacks expat
esac
say() { echo "[impeller-sdk-custom] $*"; }

mkdir -p "$(dirname "$DEST")"
DEST_ABS="$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"
STOCK="$(readlink -f engine/third_party/impeller-sdk || true)"
if [ -n "$STOCK" ] && [ "$(readlink -f "$DEST_ABS" 2>/dev/null || echo "$DEST_ABS")" = "$STOCK" ]; then
  echo "refusing to overwrite the shared stock SDK ($STOCK)" >&2; exit 1
fi
if [ -n "${RNI_SDK_PATCH:-}" ]; then PATCHES=("$RNI_SDK_PATCH"); else PATCHES=("$REPO"/engine/impeller-sdk-patches/*.patch); fi
PATCH_SUM="$(cat "${PATCHES[@]}" | sha256sum | cut -c1-64)"

mkdir -p "$WORK"
[ -d "$WORK/depot_tools" ] || git clone -q --depth 1 \
  https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
# depot_tools' vpython3/ninja wrappers need a bootstrap; plain python3 and the
# system ninja build the SDK fine.
mkdir -p "$WORK/shim"
printf '#!/bin/sh\nexec python3 "$@"\n' > "$WORK/shim/vpython3"; chmod +x "$WORK/shim/vpython3"
export PATH="$WORK/shim:$PATH:$WORK/depot_tools" DEPOT_TOOLS_UPDATE=0 GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

F="$WORK/flutter"
if [ ! -d "$F/.git" ]; then
  git init -q "$F"; git -C "$F" remote add origin https://github.com/flutter/flutter.git
fi
if [ "$(git -C "$F" rev-parse HEAD 2>/dev/null || true)" != "$SHA" ]; then
  say "fetch flutter@$SHA"
  git -C "$F" fetch -q --depth 1 origin "$SHA"
  git -C "$F" checkout -q --force FETCH_HEAD
  rm -f "$WORK/.synced"
fi
if [ "$(cat "$WORK/.synced" 2>/dev/null)" != "$SYNC_KEY" ]; then
  cat > "$F/.gclient" <<EOF
solutions = [{
  "name": ".", "url": "https://github.com/flutter/flutter.git", "deps_file": "DEPS",
  "managed": False, "custom_deps": {}, "safesync_url": "",
  "custom_vars": {"download_android_deps": $ANDROID_DEPS, "download_fuchsia_deps": False,
                  "download_jdk": False, "download_esbuild": False},
}]
EOF
  say "gclient sync"
  (cd "$F" && gclient sync --no-history -D -j 16 > "$WORK/sync.log" 2>&1) || { tail -15 "$WORK/sync.log"; exit 1; }
  echo "$SYNC_KEY" > "$WORK/.synced"
fi

INTEROP=engine/src/flutter/impeller/toolkit/interop
git -C "$F" checkout -q -- "$INTEROP"
for p in "${PATCHES[@]}"; do git -C "$F" apply "$p"; done
# Mutation hook: a command run in the interop dir after patching.
[ -z "${RNI_SDK_POST_PATCH:-}" ] || (cd "$F/$INTEROP" && eval "$RNI_SDK_POST_PATCH")

SRC="$F/engine/src"
[ -f "$SRC/out/$OUT/build.ninja" ] || (cd "$SRC" && ./flutter/tools/gn --target-dir "$OUT" \
  --runtime-mode debug --prebuilt-dart-sdk --no-lto --no-rbe --no-goma ${GN_EXTRA[@]+"${GN_EXTRA[@]}"} > "$WORK/gn.log" 2>&1) \
  || { tail -15 "$WORK/gn.log"; exit 1; }
say "ninja (log $WORK/build.log)"
t0=$(date +%s)
ninja -C "$SRC/out/$OUT" -j "$(getconf _NPROCESSORS_ONLN)" flutter/impeller/toolkit/interop:sdk > "$WORK/build.log" 2>&1 \
  || { grep -m5 -A5 FAILED "$WORK/build.log"; exit 1; }
secs=$(( $(date +%s) - t0 ))
ZIP="$(ls "$SRC/out/$OUT"/zip_archives/*/impeller_sdk.zip 2>/dev/null | head -1)"
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { echo "no SDK zip at $ZIP" >&2; exit 1; }

TMP="$(mktemp -d "$(dirname "$DEST_ABS")/.sdk-custom.XXXXXX")"
(cd "$TMP" && python3 -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall('.')" "$ZIP")
chmod +x "$TMP"/bin/* 2>/dev/null || true
printf 'sha=%s\npatch_sha256=%s\nbuild_seconds=%s\n' "$SHA" "$PATCH_SUM" "$secs" > "$TMP/.stamp"
chmod 755 "$TMP"; rm -rf "$DEST_ABS"; mv "$TMP" "$DEST_ABS"
say "built in ${secs}s -> $DEST"
