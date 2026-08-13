#!/usr/bin/env bash
# Fetch the WINDOWS Impeller SDK from a Linux/WSL host.
#
# tools/sdk-fetch.sh selects the platform from `uname`, which is correct when a
# machine builds for itself. It cannot serve a cross-OS build: on WSL `uname`
# says Linux while the artifact needed is windows-x64, and there is no Windows
# shell in the loop to run the original script. Same pinned SHA, same URL shape.
#
# The Windows SDK has a different FILE LAYOUT to the Linux one, and the
# difference is load-bearing for CMake:
#   linux-x64  : lib/libimpeller.so                (link the .so directly)
#   windows-x64: lib/impeller.dll + impeller.dll.lib  (link the IMPORT lib,
#                ship the DLL beside the exe — Windows has no rpath)
set -euo pipefail
cd "$(dirname "$0")/.."
SHA="$(tr -d ' \n' < engine/IMPELLER_SHA)"
DEST="${1:-engine/third_party/impeller-sdk-win}"
PLAT=windows-x64

if [ -f "${DEST}/.stamp" ] && [ "$(cat "${DEST}/.stamp")" = "${SHA}-${PLAT}" ]; then
  echo "sdk-fetch-win: already present, up to date"; exit 0
fi

URL="https://storage.googleapis.com/flutter_infra_release/flutter/${SHA}/${PLAT}/impeller_sdk.zip"
code=$(curl -sIL -o /dev/null -w '%{http_code}' "$URL")
[ "$code" = "200" ] || { echo "sdk-fetch-win: FAIL — prebuilt missing (HTTP ${code})" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -sL -o "$tmp/sdk.zip" "$URL"
rm -rf "$DEST"; mkdir -p "$DEST"

# Extract only what the build consumes. The full zip is 107 MB because
# `lib/impeller.lib` is a 400 MB STATIC library with debug symbols — we link the
# 52 KB import lib against the DLL instead, so pulling the static one would cost
# 400 MB of staging on every sync for a file nothing references.
python3 - "$tmp/sdk.zip" "$DEST" <<'PY'
import sys, zipfile
src, dest = sys.argv[1:3]
z = zipfile.ZipFile(src)
want = ["include/impeller.h", "include/impeller.hpp",
        "lib/impeller.dll", "lib/impeller.dll.lib"]
import os
for name in want:
    data = z.read(name)
    out = os.path.join(dest, name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(data)
    print(f"sdk-fetch-win: {name} {len(data)} bytes")
PY

echo "${SHA}-${PLAT}" > "${DEST}/.stamp"
echo "SDK_FETCH_WIN_OK ${DEST}"
