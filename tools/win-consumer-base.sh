#!/usr/bin/env bash
# Create the Windows-side base React Native app the P5-D consumer gate installs
# into. Idempotent; safe to re-run.
#
# WHY IT LIVES ON C: AND NOT IN WSL
# ---------------------------------
# The gate installs tarballs with WINDOWS npm and runs Windows metro. npm on
# Windows cannot install into \\wsl.localhost, and a bundle produced by WSL node
# against /mnt/c files would carry POSIX paths — proving nothing about the
# platform the gate exists to cover. So the app has to sit on a real drive
# letter with node_modules installed by the Windows npm that will consume them.
#
# The SOURCES are copied from the Linux base app (~/.cache/rni/base) so both
# gates start from the same stock RN template; only node_modules differ.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${BASE_APP:-$HOME/.cache/rni/base}"
DEST="${WIN_BASE_APP:-/mnt/c/Devel/rni-consumer-base}"

fail() { echo "win-consumer-base: FAIL — $*" >&2; exit 1; }

command -v cmd.exe >/dev/null || fail "cmd.exe not on PATH — run this from WSL"
[ -d "$SRC" ] || fail "no Linux base app at $SRC (see docs/STATE.md)"

echo "win-consumer-base: copying sources $SRC -> $DEST"
mkdir -p "$DEST"
# node_modules is NOT copied: Windows npm must resolve and install its own tree
# (native postinstall steps, .cmd shims in .bin, and CRLF-agnostic paths).
rsync -a --delete --exclude node_modules --exclude .git "$SRC/" "$DEST/"

DEST_WIN="$(printf '%s' "$DEST" | sed 's|^/mnt/\([a-z]\)|\U\1:|; s|/|\\|g')"
echo "win-consumer-base: npm install (Windows npm, in $DEST_WIN)"
( cd /mnt/c && cmd.exe /c "cd /d $DEST_WIN && npm install --no-audit --no-fund" ) \
  | tr -d '\r' | tail -3

[ -d "$DEST/node_modules/react-native" ] || fail "npm install did not produce node_modules/react-native"
# The CLI is a hard requirement: RN 0.86 dropped the dependency and
# `npx react-native bundle` refuses to run without it.
[ -d "$DEST/node_modules/@react-native-community/cli" ] \
  || fail "@react-native-community/cli is missing — `npx react-native bundle` will refuse to run"

echo "win-consumer-base: ready at $DEST_WIN"
