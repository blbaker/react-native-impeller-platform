#!/usr/bin/env bash
# ONE build for both linux arches (linux matrix M1):
#
#   bash tools/engine-build-linux.sh --arch x64|arm64     (default: the host's)
#   bash tools/engine-build-linux.sh --check-needed <elf>  (the NEEDED assertion alone)
#
# Both arches get the same window stack, chosen at RUN time, not build time:
#   GLFW 3.4 static with GLFW_BUILD_WAYLAND=ON + GLFW_BUILD_X11=ON (GLFW dlopens
#   libwayland-*/libxkbcommon/libX11 itself), RNI_WITH_WAYLAND=ON (the engine's
#   own wl_touch listener, host/WaylandTouch.cpp: GLFW 3.4 has none) and
#   RNI_X11_DLOPEN=ON (platform-view Xlib calls go through host/X11Dl.h).
# so the same binary starts on a Wayland-only image (the board: Weston kiosk-shell,
# no Xwayland) and on an X11 server (Xvfb gates). GLFW tries Wayland, then X11;
# XDG_SESSION_TYPE reorders that and RNI_GLFW_PLATFORM=wayland|x11 forces one.
#
#   x64:   native, engine tree engine/build (the tree every x64 gate and tool
#          already reads), GLFW in engine/build-linux-x64/.
#   arm64: cross from an x86_64 host against engine/third_party/sysroot-linux-arm64
#          (tools/arm64-sysroot.sh) and impeller-sdk-custom-linux-arm64
#          (RNI_SDK_TARGET=linux-arm64 bash tools/impeller-sdk-custom-build.sh <dir>);
#          Hermes unicode-lite and GLFW in engine/build-linux-arm64/.
# Each stages packages-engine/engine-linux-<arch>/{bin,package.json,README.md}
# with bin/BUILD-INFO. darwin and win32 still go through tools/engine-build.sh,
# which execs this script for linux.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "engine-build-linux: FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }
R=/usr/lib/llvm-18/bin/llvm-readelf; [ -x "$R" ] || R=readelf   # reads both arches
NM=/usr/lib/llvm-18/bin/llvm-nm; [ -x "$NM" ] || NM=nm

# ⛔ THE PACKAGE CONTRACT (IMAGE-REQUIREMENTS.md): plain EGL + GLES 3 sonames only.
# libmali has no desktop libGL, a Wayland-only image has no Xlib, and a binary
# that NEEDs libmali starts on exactly one GPU stack. ffmpeg is dlopen'd too:
# a NEEDED libavcodec would pin one ffmpeg release and stop the engine starting
# on an image without it.
check_needed() {  # $1 = ELF; prints NEEDED, returns 1 on a contract break
  local f="$1" n bad=""
  n="$($R -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
  [ -n "$n" ] || { echo "   NEEDED: <none read from $f>"; return 1; }
  echo "   NEEDED: $n"
  for lib in $n; do
    case "$lib" in
      libX[A-Za-z0-9-]*.so*) bad="$bad $lib(Xlib: RNI_X11_DLOPEN)" ;;
      libGL.so*|libGLX*|libOpenGL*) bad="$bad $lib(desktop GL)" ;;
      libmali*) bad="$bad $lib(vendor blob)" ;;
      libav[a-z]*.so*|libsw[a-z]*.so*) bad="$bad $lib(ffmpeg by name: video dlopens it, video/FfmpegCopy.cpp)" ;;
    esac
  done
  case " $n " in *" libEGL.so.1 "*) ;; *) bad="$bad no-libEGL.so.1" ;; esac
  case " $n " in *" libGLESv2.so.2 "*) ;; *) bad="$bad no-libGLESv2.so.2" ;; esac
  [ -z "$bad" ] || { echo "   NEEDED contract broken:$bad"; return 1; }
}

ARCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --check-needed) check_needed "${2:?--check-needed <elf>}" && echo "NEEDED_OK" && exit 0; echo "NEEDED_FAIL"; exit 1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "${ARCH:-$(uname -m)}" in
  x64|x86_64|amd64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) fail "unsupported arch '${ARCH:-$(uname -m)}' (x64 or arm64)" ;;
esac
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] \
  || fail "this builds on a linux x86_64 host (x64 natively, arm64 cross); host is $(uname -s)-$(uname -m)"
TRIPLE="linux-$ARCH"; PKG="$ROOT/packages-engine/engine-$TRIPLE"; JOBS="${JOBS:-$(nproc)}"
VERSION="$(node -p "require('$ROOT/package/package.json').version")" || fail "node not on PATH"

# Shared preconditions (order is load-bearing: the RN pin names the Hermes tag,
# and the arm64 Hermes cross build imports the x86_64 build's host hermesc).
[ -d engine/rn/node_modules/react-native ] || (cd engine/rn && npm install --ignore-scripts --no-audit --no-fund)
[ -f engine/third_party/hermes-build/lib/libhermesvm.so ] && [ -f engine/third_party/hermes/API/hermes/hermes.h ] \
  && [ -f engine/third_party/hermes-build/ImportHostCompilers.cmake ] || bash tools/hermes-build.sh
# Every build, not only the first: clones GLFW 3.4 if absent and applies
# tools/glfw-patches (the no-wl_seat segfault). Fails if the patch is not in.
bash tools/glfw-fetch.sh --source-only || fail "glfw source (tools/glfw-fetch.sh --source-only)"
# ffmpeg 8 headers: engine/CMakeLists.txt fails a linux configure without them.
[ -f "engine/third_party/ffmpeg8-linux-$ARCH/include/libavcodec/avcodec.h" ] \
  || bash tools/ffmpeg8-fetch.sh --arch "$ARCH" || fail "ffmpeg 8 (tools/ffmpeg8-fetch.sh --arch $ARCH)"
GLFW_FLAGS=(-DGLFW_BUILD_WAYLAND=ON -DGLFW_BUILD_X11=ON -DBUILD_SHARED_LIBS=OFF
            -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF)
WIN_FLAGS=(-DRNI_WITH_WINDOW=ON -DRNI_X11_DLOPEN=ON -DRNI_WITH_WAYLAND=ON)

if [ "$ARCH" = x64 ]; then
  B="$ROOT/engine/build-linux-x64"; EB="$ROOT/engine/build"
  COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
  [ -f engine/third_party/impeller-sdk/include/impeller.h ] || bash tools/sdk-fetch.sh engine/third_party/impeller-sdk
  # FP-22: a per-worktree parity SDK wins when present (same rule engine-build.sh had).
  # ⛔ A CHECKOUT WITHOUT IT FETCHES IT; IT NEVER FALLS BACK TO STOCK. The stock
  # SDK compiles and links, then paints no underline and no letter spacing, so
  # CI would publish a different engine from every developer build.
  # RNI_STOCK_IMPELLER_SDK=1 builds against the stock SDK on purpose.
  if [ -z "${RNI_IMPELLER_SDK_DIR:-}" ]; then
    PARITY_SDK=engine/third_party/impeller-sdk-custom-parity
    if [ ! -f "$PARITY_SDK/include/impeller.h" ]; then
      if [ "${RNI_STOCK_IMPELLER_SDK:-0}" = 1 ]; then
        echo "   RNI_STOCK_IMPELLER_SDK=1: building against the STOCK SDK (no text spacing, font features or decorations)"
      else
        bash tools/sdk-fetch-custom.sh linux-x64 "$PARITY_SDK" || fail "custom Impeller SDK (tools/sdk-fetch-custom.sh linux-x64)"
      fi
    fi
    [ ! -f "$PARITY_SDK/include/impeller.h" ] || export RNI_IMPELLER_SDK_DIR="$PARITY_SDK"
  fi
  # GLFW's X11 backend needs Xinerama.h at configure time; this box has the
  # runtime lib only, so glfw-fetch.sh stages the -dev deb into x11-sysroot.
  X11SR="$ROOT/engine/third_party/x11-sysroot"
  pkg-config --exists xinerama 2>/dev/null || [ -f "$X11SR/usr/include/X11/extensions/Xinerama.h" ] \
    || fail "no Xinerama header (bash tools/glfw-fetch.sh stages it into $X11SR)"
  GLFW_EXTRA=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_PREFIX_PATH="$X11SR/usr"
              -DCMAKE_INCLUDE_PATH="$X11SR/usr/include" -DCMAKE_LIBRARY_PATH="$X11SR/usr/lib/x86_64-linux-gnu")
  ENGINE_EXTRA=(-DCMAKE_INSTALL_PREFIX="$PKG")
  STRIP=strip; HB="$ROOT/engine/third_party/hermes-build"; SYSROOT_STAMP=host
else
  B="$ROOT/engine/build-linux-arm64"; EB="$B/engine"; HB="$B/hermes"
  SYSROOT="${RNI_ARM64_SYSROOT:-$ROOT/engine/third_party/sysroot-linux-arm64}"
  SDK="${RNI_ARM64_IMPELLER_SDK_DIR:-$ROOT/engine/third_party/impeller-sdk-custom-linux-arm64}"
  [ -f "$SYSROOT/usr/include/wayland-client.h" ] || fail "no sysroot at $SYSROOT (bash tools/arm64-sysroot.sh)"
  [ -f "$SDK/include/impeller.h" ] || bash tools/sdk-fetch-custom.sh linux-arm64 "$SDK" \
    || fail "no linux-arm64 Impeller SDK at $SDK (tools/sdk-fetch-custom.sh linux-arm64, or RNI_SDK_TARGET=linux-arm64 bash tools/impeller-sdk-custom-build.sh $SDK)"
  file -L "$SDK/lib/libimpeller.so" | grep -q 'ARM aarch64' || fail "$SDK/lib/libimpeller.so is not aarch64"
  export RNI_ARM64_SYSROOT="$SYSROOT"
  COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$ROOT/engine/cmake/toolchain-linux-arm64.cmake"
          -DRNI_ARM64_SYSROOT="$SYSROOT")
  GLFW_EXTRA=()
  ENGINE_EXTRA=(-DIMPELLER_SDK="$SDK" -DRNI_IMPELLER_SDK_DIR="$SDK" -DHERMES_BUILD="$HB")
  SYSROOT_STAMP="$(cat "$SYSROOT/.stamp" 2>/dev/null || echo unknown)"
  mkdir -p "$B"
  say "hermes (linux-arm64, unicode-lite: no ICU)"
  if [ ! -f "$HB/build.ninja" ]; then
    cmake -S engine/third_party/hermes -B "$HB" "${COMMON[@]}" \
      -DHERMES_ENABLE_DEBUGGER=ON -DHERMES_BUILD_SHARED_JSI=OFF -DHERMES_ENABLE_TEST_SUITE=OFF \
      -DHERMES_UNICODE_LITE=ON -DICU_FOUND=1 -DHERMES_ENABLE_INTL=OFF \
      -DIMPORT_HOST_COMPILERS="$ROOT/engine/third_party/hermes-build/ImportHostCompilers.cmake" \
      > "$HB.cfg.log" 2>&1 || { tail -20 "$HB.cfg.log" >&2; fail "hermes configure"; }
  fi
  cmake --build "$HB" -j"$JOBS" --target hermesvm > "$HB.log" 2>&1 \
    || { grep -E 'error|FAILED' "$HB.log" | head -20 >&2; fail "hermes build"; }
fi
GB="$B/glfw"; GI="$B/glfw-install"; mkdir -p "$B"

say "glfw 3.4 ($TRIPLE, wayland + x11, static)"
if [ ! -f "$GB/build.ninja" ]; then
  cmake -S engine/third_party/glfw -B "$GB" "${COMMON[@]}" "${GLFW_FLAGS[@]}" ${GLFW_EXTRA[@]+"${GLFW_EXTRA[@]}"} \
    -DCMAKE_INSTALL_PREFIX="$GI" > "$GB.cfg.log" 2>&1 || { tail -20 "$GB.cfg.log" >&2; fail "glfw configure"; }
fi
# Always build + install (a no-op when nothing changed): a patched source must
# reach the archive, and through it the rn-impeller link.
{ cmake --build "$GB" -j"$JOBS" && cmake --install "$GB"; } > "$GB.log" 2>&1 \
  || { grep -E 'error|FAILED' "$GB.log" | head -20 >&2; fail "glfw build"; }
# Both backends must be IN the archive: a GLFW configured without one still
# links clean and then fails glfwInit on that platform at run time.
GSYMS="$($NM "$GI/lib/libglfw3.a" 2>/dev/null || true)"
WL_SYMS="$(grep -c ' T _glfwConnectWayland$' <<< "$GSYMS" || true)"
X11_SYMS="$(grep -c ' T _glfwConnectX11$' <<< "$GSYMS" || true)"
[ "$WL_SYMS" -ge 1 ] && [ "$X11_SYMS" -ge 1 ] \
  || fail "$GI/lib/libglfw3.a lacks a backend (wayland=$WL_SYMS x11=$X11_SYMS)"

say "engine ($TRIPLE, $EB)"
cmake -S engine -B "$EB" "${COMMON[@]}" "${WIN_FLAGS[@]}" -DGLFW_DIR="$GI" "${ENGINE_EXTRA[@]}" \
  > "$B/engine.cfg.log" 2>&1 || { tail -30 "$B/engine.cfg.log" >&2; fail "engine configure"; }
grep -q '^RNI_X11_DLOPEN:BOOL=ON' "$EB/CMakeCache.txt" && grep -q '^RNI_WITH_WAYLAND:BOOL=ON' "$EB/CMakeCache.txt" \
  || fail "$EB/CMakeCache.txt did not take RNI_X11_DLOPEN/RNI_WITH_WAYLAND"
# A killed build leaves zero-filled objects newer than their inputs (SC-43).
find "$EB" \( -name '*.o' -o -name rn-impeller \) -type f 2>/dev/null | while read -r f; do
  [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = 177ELF ] || { echo "   removing non-ELF $f (interrupted build)"; rm -f "$f"; }
done
cmake --build "$EB" -j"$JOBS" --target rn-impeller > "$B/engine.log" 2>&1 \
  || { grep -E 'error:|FAILED:' "$B/engine.log" | head -30 >&2; fail "engine build (log: $B/engine.log)"; }

say "stage $PKG/bin"
[ "$ARCH" = arm64 ] && STRIP="$(grep -E '^CMAKE_STRIP:' "$EB/CMakeCache.txt" | cut -d= -f2)"
STAGE="$(mktemp -d "$B/.stage.XXXXXX")"
DESTDIR= cmake --install "$EB" --component engine --prefix "$STAGE" > /dev/null
for f in "$STAGE"/bin/*; do "$STRIP" --strip-unneeded "$f"; done
chmod 755 "$STAGE"/bin/*
STRAY="$(cd "$STAGE/bin" && ls -A | grep -vE '^(rn-impeller|libimpeller\.so|libhermesvm\.so)$' || true)"
[ -z "$STRAY" ] || fail "stray files staged into bin/: $STRAY"
rm -rf "$PKG/bin"; mkdir -p "$PKG"; mv "$STAGE/bin" "$PKG/bin"; rm -rf "$STAGE"

# ⛔ PROVE THE PACKAGE, DON'T TRUST THE FLAGS.
case "$ARCH" in x64) WANT='ELF 64-bit.*x86-64' ;; arm64) WANT='ELF 64-bit.*aarch64' ;; esac
for f in rn-impeller libimpeller.so libhermesvm.so; do
  file -b "$PKG/bin/$f" | grep -qE "$WANT" || fail "staged $f is not $TRIPLE: $(file -b "$PKG/bin/$f")"
done
check_needed "$PKG/bin/rn-impeller" || fail "rn-impeller breaks the NEEDED contract"
NEEDED="$($R -d "$PKG/bin/rn-impeller" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
case " $NEEDED " in *" libwayland-client.so.0 "*) ;; *) fail "rn-impeller does not link libwayland-client (RNI_WITH_WAYLAND did not take)" ;; esac
[ "$ARCH" = arm64 ] && $R -d "$PKG/bin/libhermesvm.so" | grep -q 'libicu' && fail "libhermesvm.so links ICU (unicode-lite did not take)"
$R -d "$PKG/bin/rn-impeller" | grep -E 'R(UN)?PATH' | grep -q 'ORIGIN' || fail "rn-impeller has no \$ORIGIN rpath"
$R -d "$PKG/bin/rn-impeller" | grep -E 'R(UN)?PATH' | grep -q 'engine/build' && fail "rn-impeller has a build-tree rpath"
WLTOUCH="$(strings "$PKG/bin/rn-impeller" | grep -c 'wayland_touch' || true)"
[ "$WLTOUCH" -ge 1 ] || fail "rn-impeller has no WaylandTouch strings"
GLIBC_MAX="$($R -V "$PKG"/bin/* 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
CXX_MAX="$($R -V "$PKG"/bin/* 2>/dev/null | grep -o 'GLIBCXX_[0-9.]*' | sort -uV | tail -1)"
echo "   requires up to $GLIBC_MAX, $CXX_MAX"

# ⛔ AND IT MUST START: every check above inspects the file; only a launch
# proves the loader can satisfy it. Run from / so a build-tree path can't help.
if [ "$ARCH" = x64 ]; then
  MISSING="$(cd "$PKG/bin" && ldd ./rn-impeller | grep 'not found' || true)"
  [ -z "$MISSING" ] || fail "unresolved libs: $MISSING"
  LAUNCH=(bash -c "cd / && '$PKG/bin/rn-impeller' --help")
elif docker image inspect rni-arm64-testenv:bookworm > /dev/null 2>&1; then
  LAUNCH=(docker run --rm --platform linux/arm64 -v "$PKG/bin:/opt/rni:ro" rni-arm64-testenv:bookworm /opt/rni/rn-impeller --help)
else
  LAUNCH=(); echo "   launch check SKIPPED: no rni-arm64-testenv:bookworm image to run aarch64 under qemu"
fi
if [ ${#LAUNCH[@]} -gt 0 ]; then
  set +e; LOUT="$("${LAUNCH[@]}" 2>&1)"; LRC=$?; set -e
  [ "$LRC" -eq 0 ] || { echo "$LOUT" | tail -6 >&2; fail "staged rn-impeller exited $LRC on --help"; }
  echo "   launch check OK (--help rc=0$([ "$ARCH" = arm64 ] && echo ', qemu-aarch64 bookworm'))"
fi
KB=$(du -sk "$PKG/bin" | cut -f1); echo "   unpacked payload = $((KB / 1024)) MB"
[ "$KB" -le 61440 ] || fail "payload exceeds the 60 MB budget (R3)"

GIT_SHA="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- engine tools || echo -dirty)"
SDK_USED="$(grep -E '^IMPELLER_SDK:' "$EB/CMakeCache.txt" | cut -d= -f2)"
{
  echo "triple=$TRIPLE"
  echo "git=$GIT_SHA"
  echo "version=$VERSION"
  # Repo-relative: this file ships in the npm package, and an absolute path
  # would publish the build machine's home directory.
  echo "sdk=${SDK_USED#"$ROOT"/} $(grep -E '^(sha|patch_sha256)=' "$SDK_USED/.stamp" 2>/dev/null | tr '\n' ' ')"
  echo "sysroot=$SYSROOT_STAMP"
  echo "glfw=3.4 static backends=wayland,x11 (dlopened at run time) patches=$(cd tools/glfw-patches && ls *.patch | tr '\n' ' ')"
  echo "flags=RNI_WITH_WINDOW=ON RNI_WITH_WAYLAND=ON RNI_X11_DLOPEN=ON"
  echo "needed=$NEEDED"
  echo "requires=$GLIBC_MAX $CXX_MAX"
} > "$PKG/bin/BUILD-INFO"
# The committed package.json carries the npm metadata (repository, homepage)
# that provenance checks; only the version follows package/package.json.
[ -f "$PKG/package.json" ] || fail "no $PKG/package.json (commit one; this script sets only its version)"
PKG_JSON="$PKG/package.json" VERSION="$VERSION" TRIPLE="$TRIPLE" node -e '
  const fs = require("fs"); const p = process.env.PKG_JSON;
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  const want = "@blbaker/react-native-impeller-platform-engine-" + process.env.TRIPLE;
  if (j.name !== want) { console.error("package.json name " + j.name + " != " + want); process.exit(1); }
  j.version = process.env.VERSION;
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");' || fail "$PKG/package.json"
ls -la "$PKG/bin" | tail -n +2
# The same pack gate every other platform runs: npm pack for real, then no
# symlinks, every file ships, every dependency resolves inside the tarball.
bash tools/ci-engine-pack.sh "$PKG" || fail "tools/ci-engine-pack.sh $PKG"
echo "ENGINE_BUILD_LINUX_OK arch=$ARCH $PKG/bin"
