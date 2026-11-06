#!/usr/bin/env bash
# Build rni-webhelper (engine/webview/helper) against a WPE WebKit 2.54 prefix.
#
#   tools/webhelper-build.sh                -> engine/build-webhelper/rni-webhelper        (x64)
#   tools/webhelper-build.sh --arch arm64   -> engine/build-webhelper-arm64/rni-webhelper  (aarch64)
#
# Linux x64 on WSL: WPE is not packaged for Ubuntu 24.04, so the helper is built
# and RUN inside the wpe-ocdm:sid image from ~/projects/wpe-impeller-probe (the
# 10-01 WPE + OpenCDM-shim build: ENABLE_ENCRYPTED_MEDIA + ENABLE_THUNDER against
# that repo's libocdm.so). RNI_WPE_PREFIX / RNI_WPE_IMAGE override. The engine
# never links WebKit; tools/webhelper-docker.sh is the RNI_WEBHELPER launcher.
#
# Linux arm64: cross-compiled in rni-wpe-cross:sid against the arm64
# sid sysroot + the aarch64 WPE prefix that tools/webview-arm64/wpe-cross-build.sh
# produces (RNI_WPE_ARM64_DIR, default ~/.cache/rni/wpe-arm64). The prefix is
# /opt/rni-wpe at run time (WebKit's compiled-in path), hence the rpath.
#
# On the device the same sources build in Yocto against meta-webkit's
# wpewebkit (PACKAGECONFIG thunder + encryptedmedia; see docs/eng/webview-wpe.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=x64
[ "${1:-}" = "--arch" ] && { ARCH="${2:?--arch x64|arm64}"; shift 2; }
fail() { echo "WEBHELPER_BUILD_FAIL: $*" >&2; exit 1; }
SRCS="'$ROOT/engine/webview/helper/main.cpp' '$ROOT/engine/webview/helper/view.cpp' \
  '$ROOT/engine/webview/helper/frames.cpp' '$ROOT/engine/webview/helper/input.cpp'"
PCS="wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0"

if [ "$ARCH" = arm64 ]; then
  W="${RNI_WPE_ARM64_DIR:-$HOME/.cache/rni/wpe-arm64}"
  IMAGE="${RNI_WPE_CROSS_IMAGE:-rni-wpe-cross:sid}"
  OUT="$ROOT/engine/build-webhelper-arm64"
  [ -f "$W/prefix/lib/libWPEWebKit-2.0.so" ] || fail "no arm64 WPE prefix at $W/prefix (bash tools/webview-arm64/wpe-cross-build.sh)"
  [ -f "$W/sysroot/.stamp" ] || fail "no arm64 sysroot at $W/sysroot"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "no docker image $IMAGE"
  mkdir -p "$OUT"
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$W/sysroot:/sysroot:ro" -v "$W/prefix:/sysroot/opt/rni-wpe:ro" \
    -v "$ROOT/engine:$ROOT/engine" "$IMAGE" bash -c "
set -euo pipefail
export PKG_CONFIG_DIR= PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=/sysroot
export PKG_CONFIG_LIBDIR=/sysroot/opt/rni-wpe/lib/pkgconfig:/sysroot/usr/lib/aarch64-linux-gnu/pkgconfig:/sysroot/usr/share/pkgconfig
EME=
if aarch64-linux-gnu-readelf -d /sysroot/opt/rni-wpe/lib/libWPEWebKit-2.0.so | grep -q 'libocdm'; then EME=-DRNI_WEBHELPER_EME; fi
clang++ --target=aarch64-linux-gnu --sysroot=/sysroot -march=armv8-a -fuse-ld=lld \
  -std=c++17 -O2 -Wall -Wno-deprecated-declarations \$EME $SRCS -o '$OUT/rni-webhelper' \
  -Wl,-rpath-link,/sysroot/opt/rni-wpe/lib -Wl,-rpath-link,/sysroot/usr/lib/aarch64-linux-gnu \
  -Wl,--disable-new-dtags -Wl,-rpath,/opt/rni-wpe/lib \
  \$(pkg-config --cflags --libs $PCS)
file -b '$OUT/rni-webhelper' | cut -d, -f1-2
echo \"webhelper: built arm64 eme=\${EME:+1}\"
"
  ls -la "$OUT/rni-webhelper" | awk '{print "webhelper: " $5 " bytes " $9}'
  exit 0
fi

PROBE="${RNI_WPE_PROBE:-$HOME/projects/wpe-impeller-probe}"
PREFIX="${RNI_WPE_PREFIX:-$PROBE/prefix}"
IMAGE="${RNI_WPE_IMAGE:-wpe-ocdm:sid}"
OUT="$ROOT/engine/build-webhelper"
[ -f "$PREFIX/lib/libWPEWebKit-2.0.so" ] || fail "no WPE prefix at $PREFIX"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "no docker image $IMAGE"
mkdir -p "$OUT"
# The prefix was configured with CMAKE_INSTALL_PREFIX=/work/prefix: WebKit finds
# WPEWebProcess/WPENetworkProcess by that compiled-in path, so mount it THERE.
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PREFIX:/work/prefix:ro" -v "$ROOT/engine:$ROOT/engine" "$IMAGE" bash -c "
set -euo pipefail
export PKG_CONFIG_PATH=/work/prefix/lib/pkgconfig
EME=
if readelf -d /work/prefix/lib/libWPEWebKit-2.0.so | grep -q 'libocdm'; then EME=-DRNI_WEBHELPER_EME; fi
clang++ -std=c++17 -O2 -Wall -Wno-deprecated-declarations \$EME $SRCS \
  -o '$OUT/rni-webhelper' -Wl,-rpath-link,/work/prefix/lib -Wl,--disable-new-dtags -Wl,-rpath,/work/prefix/lib \
  \$(pkg-config --cflags --libs $PCS)
echo \"webhelper: built eme=\${EME:+1}\"
"
ls -la "$OUT/rni-webhelper" | awk '{print "webhelper: " $5 " bytes " $9}'
