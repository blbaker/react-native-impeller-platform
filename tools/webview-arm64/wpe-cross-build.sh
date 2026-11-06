#!/usr/bin/env bash
# Cross-build WPE WebKit 2.54.0 for linux-arm64, the same version and
# the same feature set as the x64 helper's WebKit (wpe-impeller-probe 10-01:
# WPEPlatform headless, ENABLE_ENCRYPTED_MEDIA + ENABLE_THUNDER against the
# OpenCDM shim). MiniBrowser is off (nothing here uses it).
#
#   bash tools/webview-arm64/wpe-cross-build.sh [sysroot|shim|webkit|install|all]
#
# Output (RNI_WPE_ARM64_DIR, default ~/.cache/rni/wpe-arm64):
#   sysroot/   arm64 Debian sid, exported from rni-webview-arm64:sid (the image the
#              gate RUNS in, so WebKit loads the libraries it was linked against)
#   prefix/    CMAKE_INSTALL_PREFIX=/opt/rni-wpe: libWPEWebKit-2.0.so,
#              libexec/wpe-webkit-2.0/WPE{Web,Network,GPU}Process, libocdm.so.1.
#              WebKit finds its processes by that compiled-in path, so every
#              container mounts prefix/ AT /opt/rni-wpe.
#   build-time.txt  wall-clock seconds per stage
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="${1:-all}"
W="${RNI_WPE_ARM64_DIR:-$HOME/.cache/rni/wpe-arm64}"
SRC_TAR="${RNI_WPE_SRC_TAR:-$HOME/projects/wpe-impeller-probe/src/wpewebkit-2.54.0.tar.xz}"
SHIM_SRC="${RNI_OCDM_SHIM_SRC:-$HOME/projects/wpe-impeller-probe/ocdm-shim}"
CDM_HEADERS="${RNI_CDM_HEADERS:-$HOME/projects/wv-cdm-probe/third_party}"
RT_IMG="${RNI_WPE_ARM64_IMAGE:-rni-webview-arm64:sid}"
X_IMG="${RNI_WPE_CROSS_IMAGE:-rni-wpe-cross:sid}"
JOBS="${JOBS:-20}"
fail() { echo "WPE_CROSS_FAIL: $*" >&2; exit 1; }
say() { echo "[wpe-cross $(date +%H:%M:%S)] $*"; }
timed() { local s=$1; shift; local t0; t0=$(date +%s); "$@"; echo "$s $(( $(date +%s) - t0 ))" >> "$W/build-time.txt"; }
mkdir -p "$W/prefix" "$W/ccache"
for img in "$RT_IMG" "$X_IMG"; do docker image inspect "$img" >/dev/null 2>&1 || fail "no image $img"; done

do_sysroot() {
  say "export sysroot from $RT_IMG"
  local tmp; tmp="$(mktemp -d "$W/.sysroot.XXXXXX")"
  local cid; cid="$(docker create --platform linux/arm64 "$RT_IMG" true)"
  docker export "$cid" | tar -x -C "$tmp" --wildcards \
    'usr/include/*' 'usr/lib/aarch64-linux-gnu/*' 'usr/lib/gcc/*' 'usr/lib/ld-linux-aarch64.so.1' \
    'usr/share/pkgconfig/*' 'usr/share/wayland-protocols/*' 'usr/share/wayland/*' 'lib' 'lib64' \
    'usr/lib/linux/*' 'etc/alternatives/*' 2>/dev/null || true
  # sid's linux-libc-dev ships usr/include/<triple>/asm/*.h as symlinks into
  # usr/lib/linux/uapi: without that tree every <linux/types.h> include fails.
  docker rm "$cid" >/dev/null
  # Absolute symlinks point at the HOST from inside a sysroot: make them relative.
  python3 - "$tmp" <<'PY'
import os, sys
root = os.path.abspath(sys.argv[1]); n = 0
for d, dirs, files in os.walk(root):
    for f in dirs + files:
        p = os.path.join(d, f)
        if os.path.islink(p) and os.readlink(p).startswith('/'):
            t = os.path.join(root, os.readlink(p).lstrip('/'))
            os.unlink(p); os.symlink(os.path.relpath(t, d), p); n += 1
print("[wpe-cross] relativised %d absolute symlinks" % n)
PY
  mkdir -p "$tmp/opt/rni-wpe"  # mount point: the prefix is part of the sysroot too
  for f in usr/lib/aarch64-linux-gnu/libc.so.6 usr/include/glib-2.0/glib.h usr/include/gstreamer-1.0/gst/gst.h \
           usr/include/libsoup-3.0/libsoup/soup.h usr/include/EGL/egl.h usr/lib/aarch64-linux-gnu/pkgconfig/icu-uc.pc \
           usr/include/aarch64-linux-gnu/asm/types.h; do
    [ -e "$tmp/$f" ] || fail "sysroot is missing $f"
  done
  rm -rf "$W/sysroot"; mv "$tmp" "$W/sysroot"
  echo "sid-arm64 $(docker image inspect -f '{{.Id}}' "$RT_IMG")" > "$W/sysroot/.stamp"
  say "sysroot ok ($(du -sh "$W/sysroot" | cut -f1))"
}

do_shim() {
  # Native aarch64 build under qemu (670 lines; no cross toolchain needed).
  say "OpenCDM shim (aarch64, $SHIM_SRC)"
  docker run --rm --platform linux/arm64 --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$SHIM_SRC:/src/ocdm-shim:ro" -v "$CDM_HEADERS:/cdmh:ro" -v "$W:/w" -v "$W/prefix:/opt/rni-wpe" "$RT_IMG" bash -c '
set -euo pipefail
cmake -S /src/ocdm-shim -B /w/build-shim -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/opt/rni-wpe -DCDM_HEADERS=/cdmh
cmake --build /w/build-shim && cmake --install /w/build-shim
file -L /opt/rni-wpe/lib/libocdm.so.1 | sed "s/, BuildID.*//"
nm -D --defined-only /opt/rni-wpe/lib/libocdm.so | grep -c " T opencdm_" | sed "s/^/SHIM_EXPORTS=/"'
}

do_webkit() {
  [ -f "$W/sysroot/.stamp" ] || fail "no sysroot (stage sysroot)"
  [ -f "$W/prefix/lib/libocdm.so" ] || fail "no aarch64 libocdm.so in the prefix (stage shim)"
  if [ ! -d "$W/src/wpewebkit-2.54.0" ]; then
    say "unpack $SRC_TAR"; mkdir -p "$W/src"; tar -xJf "$SRC_TAR" -C "$W/src"
  fi
  say "WebKit configure + build (jobs=$JOBS)"
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e CCACHE_DIR=/w/ccache \
    -v "$W/sysroot:/sysroot:ro" -v "$W/prefix:/opt/rni-wpe" -v "$W/prefix:/sysroot/opt/rni-wpe" \
    -v "$W:/w" -v "$HERE:/tc:ro" "$X_IMG" bash -c "
set -euo pipefail
cmake -S /w/src/wpewebkit-2.54.0 -B /w/build-wpe -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/tc/toolchain-wpe-arm64.cmake \
  -DPORT=WPE -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/rni-wpe \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DENABLE_ENCRYPTED_MEDIA=ON -DENABLE_THUNDER=ON \
  -DTHUNDER_INCLUDE_DIR=/opt/rni-wpe/include/opencdm -DTHUNDER_LIBRARY=/opt/rni-wpe/lib/libocdm.so \
  -DENABLE_DOCUMENTATION=OFF -DENABLE_INTROSPECTION=OFF -DENABLE_WEBDRIVER=OFF \
  -DENABLE_WPE_QT_API=OFF -DENABLE_BUBBLEWRAP_SANDBOX=OFF -DUSE_LIBBACKTRACE=OFF \
  -DENABLE_SPEECH_SYNTHESIS=OFF -DENABLE_MINIBROWSER=OFF -DENABLE_API_TESTS=OFF \
  -DENABLE_WPE_PLATFORM_DRM=OFF -DENABLE_WPE_PLATFORM_WAYLAND=OFF -DENABLE_WPE_PLATFORM_HEADLESS=ON \
  > /w/build-wpe.cfg.log 2>&1 || { tail -40 /w/build-wpe.cfg.log; exit 1; }
grep -E '^(ENABLE_THUNDER|ENABLE_ENCRYPTED_MEDIA|ENABLE_JIT|ENABLE_WPE_PLATFORM_HEADLESS|CMAKE_SYSTEM_PROCESSOR)' /w/build-wpe/CMakeCache.txt || true
ninja -C /w/build-wpe -j $JOBS > /w/build-wpe.log 2>&1 || { grep -E 'error:|FAILED:' /w/build-wpe.log | head -30; exit 1; }
# cmake --install: the build above is complete; copy it out without another ninja
# pass. (Before toolchain-wpe-arm64.cmake set --gcc-toolchain=/sysroot/usr, the
# merged-usr sysroot made ninja see every libstdc++ header as missing and a second
# pass rebuilt ~2700 objects. A build-wpe configured before that fix rebuilds in
# full once on its next run, then stays incremental.)
cmake --install /w/build-wpe > /w/build-wpe.install.log 2>&1 || { tail -20 /w/build-wpe.install.log; exit 1; }
"
  webkit_checks
}

# install: copy a COMPLETE build tree into the prefix again, then the checks.
do_install() {
  docker run --rm --user "$(id -u):$(id -g)" -v "$W/prefix:/opt/rni-wpe" -v "$W:/w" "$X_IMG" \
    bash -c 'cmake --install /w/build-wpe > /w/build-wpe.install.log 2>&1 || { tail -20 /w/build-wpe.install.log; exit 1; }'
  webkit_checks
}

webkit_checks() {
  local so="$W/prefix/lib/libWPEWebKit-2.0.so"
  file -L "$so" | grep -q 'ARM aarch64' || fail "$so is not aarch64: $(file -L -b "$so")"
  local n; n="$(docker run --rm -v "$W/prefix:/p:ro" "$X_IMG" bash -c 'aarch64-linux-gnu-readelf -d /p/lib/libWPEWebKit-2.0.so | grep -c "libocdm.so.1"')"
  [ "$n" = 1 ] || fail "libWPEWebKit-2.0.so does not NEED libocdm.so.1 (Thunder/EME off?)"
  say "WEBKIT_ARM64_OK $(file -L -b "$so" | cut -d, -f1-2)"
}

case "$STAGE" in
  sysroot) timed sysroot do_sysroot ;;
  shim) timed shim do_shim ;;
  webkit) timed webkit do_webkit ;;
  install) do_install ;;
  all) timed sysroot do_sysroot; timed shim do_shim; timed webkit do_webkit ;;
  *) fail "stage: sysroot|shim|webkit|install|all" ;;
esac
echo "WPE_CROSS_OK stage=$STAGE"; cat "$W/build-time.txt"
