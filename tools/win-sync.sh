#!/usr/bin/env bash
# Sync the engine sources to a native Windows path and configure/build with MSVC.
#
# ⚠️ C:\Devel\rni-win IS A BUILD ARTIFACT, NOT A SECOND CHECKOUT.
# It is rsync'd ONE WAY with --delete on every run. Editing anything there loses
# the edit on the next sync. Fix things in the repo.
#
# WSL cannot be built from directly on the Windows side: `\\wsl.localhost\...` is
# a UNC path that cmd.exe refuses as a working directory, so the sources have to
# be copied to a real drive letter.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
STAGE="/mnt/c/Devel/rni-win"
SCRIPTS="/mnt/c/Devel/rni-win-scripts"

[ -f "engine/third_party/angle-win-x64/libEGL.dll" ] || bash tools/angle-fetch.sh
[ -f "engine/third_party/impeller-sdk-win/lib/impeller.dll" ] || bash tools/sdk-fetch-win.sh

# ⛔ PATCH BEFORE STAGING, AND ALWAYS — never "only when the tree looks fresh".
# The patched files live under node_modules, which npm recreates without notice.
# An engine-only staleness check is blind to a staged tree holding an UNPATCHED
# vendor tree, and the Windows build then fails on an anchor that is already
# fixed in the repo. The script is idempotent and aborts on a missing anchor.
bash tools/apply-win-patches.sh

mkdir -p "$STAGE" "$SCRIPTS"

# -L dereferences symlinks: npm/pnpm store links do not survive the hop.
# The other platform's build dir is excluded — copying a configured CMake cache
# to another OS produces a configure that "succeeds" against foreign paths.
echo "sync: engine sources -> $STAGE"
rsync -aL --delete \
  --exclude 'build/' \
  --exclude 'third_party/hermes/' \
  --exclude 'third_party/hermes-build/' \
  --exclude 'third_party/impeller-sdk/' \
  "$ROOT/engine/" "$STAGE/engine/"

# Driver scripts live in their OWN sibling directory: if they sat inside the
# staged tree, the very rsync --delete that placed them would delete them on the
# next run (measured on skia-platform: "the system cannot find the path
# specified" for a script just copied).
cp "$ROOT/tools/win/"*.bat "$SCRIPTS/" 2>/dev/null || true

echo "SYNC_OK $STAGE"
