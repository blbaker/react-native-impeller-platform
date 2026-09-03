#!/usr/bin/env bash
# Fetch + build GLFW as a static lib for the windowed host (P9-A).
#
# WHY SOURCE AND NOT apt
#
# libglfw3-dev needs root and this box has no non-interactive sudo. But every
# GLFW *dependency* header is already present (X11, xkbcommon, wayland-client),
# so a source build needs nothing but a compiler. That makes the windowed host
# reproducible on a fresh checkout and on CI, which apt-in-a-brief would not be.
#
# ⛔ X11-ONLY, DELIBERATELY.
#
# GLFW's Wayland backend requires wayland-protocols, and `pkg-config --exists
# wayland-protocols` is FALSE here. WSLg runs Xwayland (verified: a non-blocking
# connect to /tmp/.X11-unix/X0 succeeds), so the X11 backend reaches the same
# compositor with one less build dependency. If a later host has neither, the
# failure is a clean CMake configure error naming the missing package rather
# than a link error deep in the engine build.
set -euo pipefail

GLFW_VERSION="${GLFW_VERSION:-3.4}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/engine/third_party/glfw"
BUILD="$SRC/build"
PREFIX="$SRC/install"
SYSROOT="$ROOT/engine/third_party/x11-sysroot"

# ⛔ Xinerama is the ONE dependency whose -dev package is absent, and it is not
# optional: GLFW's X11 backend hard-errors at configure time without it
# ("Xinerama headers not found"). The runtime lib IS installed
# (libXinerama.so.1); only the header and the .so symlink are missing.
#
# This box has no non-interactive sudo, so `apt-get install` cannot run inside a
# build script. `apt-get download` needs NO root — it just fetches the .deb —
# and `dpkg-deb -x` unpacks it anywhere. We extract into a repo-local sysroot
# and point CMake at it. Nothing is installed system-wide, the build stays
# reproducible from a clean checkout, and a machine that already has the real
# package skips this entirely.
ensure_xinerama() {
  if pkg-config --exists xinerama 2>/dev/null; then
    echo "xinerama: system package present"
    return 0
  fi
  if [ -f "$SYSROOT/usr/include/X11/extensions/Xinerama.h" ]; then
    echo "xinerama: local sysroot present"
    return 0
  fi
  echo "=== [0/3] staging libxinerama-dev into a repo-local sysroot (no root) ==="
  local tmp; tmp="$(mktemp -d)"
  ( cd "$tmp" && apt-get download libxinerama-dev >/dev/null 2>&1 ) \
    || { echo "XINERAMA_FETCH_FAIL: apt-get download libxinerama-dev"; return 1; }
  mkdir -p "$SYSROOT"
  dpkg-deb -x "$tmp"/libxinerama-dev_*.deb "$SYSROOT"
  rm -rf "$tmp"
  # The -dev deb ships the .so symlink as a RELATIVE link into /usr/lib/...,
  # which dangles inside our sysroot. Repoint it at the real system library so
  # the linker resolves it.
  local real; real="$(ls /usr/lib/x86_64-linux-gnu/libXinerama.so.1 2>/dev/null || true)"
  if [ -n "$real" ]; then
    mkdir -p "$SYSROOT/usr/lib/x86_64-linux-gnu"
    ln -sf "$real" "$SYSROOT/usr/lib/x86_64-linux-gnu/libXinerama.so"
  fi
  test -f "$SYSROOT/usr/include/X11/extensions/Xinerama.h" \
    || { echo "XINERAMA_STAGE_FAIL: header missing after extract"; return 1; }
  echo "xinerama: staged at $SYSROOT"
}

if [ -f "$PREFIX/lib/libglfw3.a" ]; then
  echo "GLFW_ALREADY_BUILT $PREFIX/lib/libglfw3.a"
  exit 0
fi

# ---------------------------------------------------------------------------
# ⛔ EVERYTHING ABOVE THIS POINT IS LINUX/X11 AND CANNOT RUN ON DARWIN.
# ensure_xinerama shells `apt-get` and `dpkg-deb`, which do not exist on macOS;
# the X11 backend itself is meaningless there. macOS uses GLFW's Cocoa backend,
# which needs NO staged sysroot at all — its dependencies are system
# frameworks that every Mac already has.
#
# ⚠️ THE CLONE MUST BE COMPLETE, AND A PARTIAL ONE LOOKS FINE.
# GLFW's Cocoa backend lives entirely in .m files (cocoa_init.m, cocoa_window.m,
# cocoa_monitor.m, cocoa_joystick.m, nsgl_context.m). A tree missing them still
# has CMakeLists.txt and every header, so `cmake -S` gets a long way in before
# failing — on this repo it first surfaced as a missing CMake/glfw3.pc.in,
# which points at packaging rather than at the real cause. Verified explicitly
# below rather than trusted, because a hand-copied or rsync-filtered tree is
# exactly how this arrives broken.
# ---------------------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ]; then
  mkdir -p "$(dirname "$SRC")"
  if [ ! -f "$SRC/src/cocoa_init.m" ]; then
    echo "=== [1/3] fetching glfw $GLFW_VERSION (cocoa) ==="
    rm -rf "$SRC"
    git clone --depth 1 --branch "$GLFW_VERSION" https://github.com/glfw/glfw.git "$SRC"
  fi

  for f in src/cocoa_init.m src/cocoa_window.m src/cocoa_monitor.m \
           src/cocoa_joystick.m src/nsgl_context.m CMake/glfw3.pc.in; do
    test -f "$SRC/$f" || { echo "GLFW_SOURCE_INCOMPLETE: missing $f"; exit 1; }
  done

  echo "=== [2/3] configuring (cocoa) ==="
  # CMAKE_POLICY_VERSION_MINIMUM: CMake 4.x removed compatibility with
  # cmake_minimum_required(<3.5), which GLFW 3.4 and several vendored deps
  # still declare. Harmless on older CMake, required on 4.4+.
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DGLFW_BUILD_EXAMPLES=OFF \
    -DGLFW_BUILD_TESTS=OFF \
    -DGLFW_BUILD_DOCS=OFF \
    -DGLFW_BUILD_COCOA=ON

  echo "=== [3/3] building + installing ==="
  cmake --build "$BUILD" --parallel
  cmake --install "$BUILD"

  test -f "$PREFIX/lib/libglfw3.a" || { echo "GLFW_BUILD_FAIL: no static lib"; exit 1; }
  # Assert the Cocoa backend is actually IN the archive. A GLFW built with the
  # null backend also produces libglfw3.a and links clean, then returns NULL
  # from glfwCreateWindow at runtime.
  nm -a "$PREFIX/lib/libglfw3.a" 2>/dev/null | grep -q "cocoa_init" \
    || { echo "GLFW_BUILD_FAIL: libglfw3.a has no cocoa backend"; exit 1; }
  echo "GLFW_BUILD_PASS $PREFIX/lib/libglfw3.a"
  exit 0
fi

ensure_xinerama

mkdir -p "$(dirname "$SRC")"
if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "=== [1/3] fetching glfw $GLFW_VERSION ==="
  rm -rf "$SRC"
  git clone --depth 1 --branch "$GLFW_VERSION" https://github.com/glfw/glfw.git "$SRC"
fi

echo "=== [2/3] configuring (X11 on, Wayland off) ==="
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$SYSROOT/usr" \
  -DCMAKE_INCLUDE_PATH="$SYSROOT/usr/include" \
  -DCMAKE_LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu" \
  -DGLFW_BUILD_EXAMPLES=OFF \
  -DGLFW_BUILD_TESTS=OFF \
  -DGLFW_BUILD_DOCS=OFF \
  -DGLFW_BUILD_WAYLAND=OFF \
  -DGLFW_BUILD_X11=ON

echo "=== [3/3] building + installing ==="
cmake --build "$BUILD" --parallel
cmake --install "$BUILD"

test -f "$PREFIX/lib/libglfw3.a" || { echo "GLFW_BUILD_FAIL: no static lib"; exit 1; }
echo "GLFW_BUILD_PASS $PREFIX/lib/libglfw3.a"
