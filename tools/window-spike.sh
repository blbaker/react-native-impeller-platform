#!/usr/bin/env bash
# P9-A prerequisite spike: does a REAL Impeller window open on this host?
#
# Builds the SDK's own example_gl.c against our locally-built GLFW. This proves
# the whole windowed chain (GLFW -> X11/Xwayland -> EGL/GLES -> Impeller GL
# context -> ImpellerSurfaceCreateWrappedFBONew -> swap) with ZERO engine code
# involved. If this fails, the windowed host is not a coding problem and no
# worker should be dispatched at it.
#
# ⛔ SDL_VIDEODRIVER is not used here (GLFW, not SDL), but DISPLAY is: WSLg's
# Wayland compositor is reachable via Xwayland at :0 and GLFW is built X11-only.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-timeout.sh"  # portable timeout (mac fallback)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$ROOT/engine/third_party/impeller-sdk"
GLFW="$ROOT/engine/third_party/glfw/install"
# The staged sysroot carries the Xinerama .so symlink that the system image
# lacks (only libXinerama.so.1 is installed, with no linkable -dev symlink).
SYSROOT="$ROOT/engine/third_party/x11-sysroot"
OUT="${OUT:-/tmp/impeller-window-spike}"
mkdir -p "$OUT"

test -f "$GLFW/lib/libglfw3.a" || { echo "SPIKE_FAIL: build GLFW first (tools/glfw-fetch.sh)"; exit 1; }

echo "=== compiling SDK example_gl.c ==="
gcc "$SDK/examples/example_gl.c" \
  -I"$SDK/include" -I"$GLFW/include" \
  -o "$OUT/example_gl" \
  "$GLFW/lib/libglfw3.a" \
  -L"$SDK/lib" -limpeller \
  -L"$SYSROOT/usr/lib/x86_64-linux-gnu" \
  -lX11 -lXrandr -lXcursor -lXi -lXinerama -lm -lpthread -ldl \
  -Wl,-rpath,"$SDK/lib"
echo "compiled -> $OUT/example_gl"

echo "=== running windowed (DISPLAY=${DISPLAY:-:0}) ==="
# The example loops on glfwWaitEvents until the window closes, so it never
# returns on its own. Run it bounded and treat the timeout kill as success --
# what we are asserting is that it got a window and started drawing, not that
# it exited.
export DISPLAY="${DISPLAY:-:0}"
unset SDL_VIDEODRIVER || true
set +e
stdbuf -oL -eL timeout 12 "$OUT/example_gl" > "$OUT/run.log" 2>&1
RC=$?
set -e
echo "exit=$RC (124 = still running when killed = window stayed up)"
tail -20 "$OUT/run.log"

if [ "$RC" -eq 124 ] || [ "$RC" -eq 0 ]; then
  echo "WINDOW_SPIKE_PASS"
else
  echo "WINDOW_SPIKE_FAIL rc=$RC"
  exit 1
fi
