#!/usr/bin/env bash
# Fetch the macOS (darwin-arm64) Impeller SDK from a Linux/WSL host.
#
# WHY THIS IS NOT tools/sdk-fetch.sh (same reason sdk-fetch-win.sh exists)
# ------------------------------------------------------------------------
# sdk-fetch.sh selects the platform from `uname`, which is right when a machine
# builds for itself and useless for a cross-OS stage: on WSL `uname` says Linux
# while the artifact needed is darwin-arm64. Same pinned SHA, same URL shape.
#
# WHY NOT extractall (measured, P6 2026-08-14)
# --------------------------------------------
# The darwin-arm64 zip is 248 MB and expands to over a GIGABYTE, because
# `lib/libimpeller.a` alone is **979,443,456 bytes** of static library with
# debug symbols. The engine links the dylib, exactly as the Linux build links
# the .so, so extracting the archive costs ~1 GB of staging per sync for a file
# nothing references. sdk-fetch-win.sh already learned this (its .lib is 400 MB);
# the Linux path is only tolerable because its .a is a comparatively small 60 MB.
#
# LAYOUT, which is load-bearing for CMake:
#   linux-x64   : lib/libimpeller.so     (link directly, rpath)
#   windows-x64 : lib/impeller.dll + .dll.lib (link the IMPORT lib, no rpath)
#   darwin-arm64: lib/libimpeller.dylib  (link directly; @rpath/install_name)
set -euo pipefail
cd "$(dirname "$0")/.."
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk-darwin}"
PLAT=darwin-arm64

if [ -f "${DEST}/.stamp" ] && [ "$(cat "${DEST}/.stamp")" = "${SHA}-${PLAT}" ]; then
  echo "sdk-fetch-darwin: already present, up to date"; exit 0
fi

URL="https://storage.googleapis.com/flutter_infra_release/flutter/${SHA}/${PLAT}/impeller_sdk.zip"
code=$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")
[ "$code" = "200" ] || { echo "sdk-fetch-darwin: FAIL — prebuilt missing (HTTP ${code})" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/sdk.zip" "$URL"
rm -rf "$DEST"; mkdir -p "$DEST"

python3 - "$tmp/sdk.zip" "$DEST" <<'PY'
import os, sys, zipfile
src, dest = sys.argv[1:3]
z = zipfile.ZipFile(src)
names = set(z.namelist())
want = ["include/impeller.h", "include/impeller.hpp", "lib/libimpeller.dylib"]
for name in want:
    if name not in names:
        # Upstream renaming a file must be loud. A missing header reads
        # downstream as a compile error in our own code.
        print(f"sdk-fetch-darwin: FAIL — {name} not in the SDK zip", file=sys.stderr)
        sys.exit(1)
    data = z.read(name)
    out = os.path.join(dest, name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(data)
    print(f"sdk-fetch-darwin: {name} {len(data)} bytes")
PY

# The ABI is IDENTICAL to the Linux .so — 188 exports, name-for-name, verified
# by walking both symbol tables (tools/macho-exports.py vs readelf). Assert it
# on every fetch rather than trusting that: an upstream bump that drops or adds
# a darwin symbol changes what the host can call, and finding that out at link
# time on a machine you can only reach over SSH costs a session.
if [ -f "engine/third_party/impeller-sdk/lib/libimpeller.so" ]; then
  python3 tools/macho-exports.py "${DEST}/lib/libimpeller.dylib" \
    | tail -n +2 | sed 's/^_//' | sort > "$tmp/darwin.syms"
  readelf --dyn-syms -W engine/third_party/impeller-sdk/lib/libimpeller.so \
    | awk '$4=="FUNC" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u > "$tmp/linux.syms"
  if ! diff -q "$tmp/linux.syms" "$tmp/darwin.syms" >/dev/null; then
    echo "sdk-fetch-darwin: FAIL — darwin/linux export sets differ:" >&2
    diff "$tmp/linux.syms" "$tmp/darwin.syms" | head -20 >&2
    exit 1
  fi
  echo "sdk-fetch-darwin: ABI parity OK ($(wc -l < "$tmp/darwin.syms") exports match linux-x64)"
else
  echo "sdk-fetch-darwin: NOTE — no linux SDK present, ABI parity NOT checked"
fi

echo "${SHA}-${PLAT}" > "${DEST}/.stamp"
echo "SDK_FETCH_DARWIN_OK ${DEST}"
