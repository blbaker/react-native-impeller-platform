#!/usr/bin/env bash
# Kept so existing docs and habits still work: the linux-arm64 cross build now
# lives in the one linux build script, with the same window stack and NEEDED
# contract as linux-x64 (linux matrix M1). See tools/engine-build-linux.sh.
exec bash "$(dirname "$0")/engine-build-linux.sh" --arch arm64 "$@"
