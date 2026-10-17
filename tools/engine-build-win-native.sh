#!/usr/bin/env bash
# Build the Windows engine NATIVELY: Git Bash on a Windows host with the MSVC
# environment already loaded (vcvars64.bat; ilammy/msvc-dev-cmd on a GitHub
# runner). Then stage it with the same checks as the WSL path.
#
#   bash tools/engine-build.sh win32 x64      (dispatches here under Git Bash)
#
# WHY A SECOND WINDOWS PATH
# tools/engine-build-win-stage.sh drives one specific machine from WSL through
# cmd.exe: fixed C:\Devel paths, a Hermes built by hand outside the repo. No
# runner has any of that, so until this script the Windows engine could not
# be built anywhere else, and a release could not include it. This path
# fetches every input itself, the way engine-build.sh does on Linux and macOS:
# the custom Impeller SDK, ANGLE, GLFW's source, Hermes at the tag React Native
# pins. Staging and the import-table check are shared with the WSL path, so
# the two can never disagree about what the package must contain.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="${1:-x64}"
fail() { echo "engine-build-win-native: FAIL — $*" >&2; exit 1; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) fail "run this from Git Bash on Windows (from WSL, engine-build.sh uses engine-build-win-stage.sh)" ;;
esac
[ "$ARCH" = "x64" ] || fail "only x64 is supported on Windows (asked for $ARCH)"
for t in cl cmake ninja dumpbin git curl node npm; do
  command -v "$t" >/dev/null 2>&1 || fail "'$t' is not on PATH. Load the MSVC environment first (vcvars64.bat)."
done

# Our scripts call python3. A Windows Python is usually only `python`, and the
# `python3` on PATH can be the Microsoft Store stub, which exits 9009 and
# prints nothing useful. A sh shim is enough: only bash calls python3 here.
if ! python3 -c 'import sys' >/dev/null 2>&1; then
  command -v python >/dev/null 2>&1 || fail "no python or python3 on PATH"
  SHIM="$PWD/engine/build-win-shim"
  mkdir -p "$SHIM"
  printf '#!/bin/sh\nexec python "$@"\n' > "$SHIM/python3"
  chmod +x "$SHIM/python3"
  export PATH="$SHIM:$PATH"
  python3 -c 'import sys; print("python3 shim ->", sys.version.split()[0])'
fi

echo "engine-build-win-native: inputs"
[ -d engine/rn/node_modules/react-native ] \
  || (cd engine/rn && npm install --ignore-scripts --no-audit --no-fund)
bash tools/apply-win-patches.sh

# The custom SDK, exactly as on Linux and macOS (see engine-build.sh): fetched,
# never a silent fallback to stock.
if [ -z "${RNI_IMPELLER_SDK_DIR:-}" ]; then
  if [ "${RNI_STOCK_IMPELLER_SDK:-0}" = "1" ]; then
    echo "engine-build-win-native: RNI_STOCK_IMPELLER_SDK=1 — building against the STOCK SDK"
    bash tools/sdk-fetch-win.sh
  else
    bash tools/sdk-fetch-custom.sh win32-x64 engine/third_party/impeller-sdk-custom-parity-win
    export RNI_IMPELLER_SDK_DIR=engine/third_party/impeller-sdk-custom-parity-win
  fi
fi
echo "engine-build-win-native: Impeller SDK = ${RNI_IMPELLER_SDK_DIR:-stock}"

[ -f engine/third_party/angle-win-x64/libEGL.dll ] || ANGLE_PLATFORM=win-x64 bash tools/angle-fetch.sh

# GLFW: CMake compiles the Windows backend from source in this same configure
# (see the GLFW block in engine/CMakeLists.txt), so only the source is needed.
GLFW_VERSION="${GLFW_VERSION:-3.4}"
[ -f engine/third_party/glfw/src/win32_init.c ] || {
  rm -rf engine/third_party/glfw
  git clone -q --depth 1 --branch "$GLFW_VERSION" https://github.com/glfw/glfw.git engine/third_party/glfw
}

# Hermes at the tag React Native pins. hermesvm is a STATIC library under MSVC,
# so the guard looks for the .lib, not a DLL.
if [ -z "$(find engine/third_party/hermes-build -name 'hermesvm.lib' 2>/dev/null | head -1)" ] \
   || [ ! -f engine/third_party/hermes/API/hermes/hermes.h ]; then
  bash tools/hermes-build.sh
fi

B="${RNI_WIN_BUILD_DIR:-engine/build-win}"
mkdir -p "$B"
B_WIN="$(cd "$B" && pwd -W)"
echo "engine-build-win-native: configure + build + install ($B_WIN)"
cmake -S engine -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DRNI_WITH_WINDOW=ON \
      -DCMAKE_INSTALL_PREFIX="$B_WIN/stage"
cmake --build "$B" --target rn-impeller
cmake --install "$B" --component engine

RNI_WIN_STAGE_DIR="$B/stage/bin" exec bash tools/engine-build-win-stage.sh "$ARCH"
