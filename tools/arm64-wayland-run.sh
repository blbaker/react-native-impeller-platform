#!/usr/bin/env bash
# Run a linux engine package as a WAYLAND client of a headless Weston
# (kiosk-shell, the board image's shell) in its test container, with a touch
# script injected through Weston's own input path (rni-touch-inject).
#
#   arm64-wayland-run.sh OUTDIR WIDTH HEIGHT "TOUCH_SCRIPT" -- <rn-impeller args...>
#
# Same arguments as the engine after `--`; engine stdout/stderr -> stdout and
# OUTDIR/engine.out. See tools/arm64-testenv/wayland-session.sh for the
# TOUCH_SCRIPT format.
#
# Env: RNI_TEST_ARCH=arm64 (default; qemu-aarch64, rni-arm64-tools:bookworm,
#        packages-engine/engine-linux-arm64/bin, override RNI_ARM64_ENGINE_DIR /
#        RNI_ARM64_IMAGE)
#      RNI_TEST_ARCH=x64   (native, rni-x64-tools:noble from
#        tools/arm64-testenv/Dockerfile.x64, packages-engine/engine-linux-x64/bin,
#        override RNI_X64_ENGINE_DIR / RNI_X64_IMAGE)
#      RNI_SESSION=x11     same container, Xvfb instead of Weston and NO Wayland
#        socket: the engine must pick GLFW's X11 backend. TOUCH_SCRIPT is unused.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${RNI_TEST_ARCH:-arm64}" in
  arm64) BIN="${RNI_ARM64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-arm64/bin}"
         IMG="${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}"; PLAT=linux/arm64 ;;
  x64)   BIN="${RNI_X64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-x64/bin}"
         IMG="${RNI_X64_IMAGE:-rni-x64-tools:noble}"; PLAT=linux/amd64 ;;
  *) echo "arm64-wayland-run: RNI_TEST_ARCH must be arm64 or x64" >&2; exit 2 ;;
esac
OUT="$1"; W="$2"; H="$3"; SCRIPT="$4"; shift 4
[ "${1:-}" = "--" ] && shift
mkdir -p "$OUT"
ENVS=(-e HOME="$HOME" -e LIBGL_ALWAYS_SOFTWARE=1)
while IFS='=' read -r k _; do
  case "$k" in RNI_*|MESA_*|WAYLAND_DEBUG) ENVS+=(-e "$k") ;; esac
done < <(env)
MOUNTS=(-v "$HOME:$HOME")
[ "$ROOT" = "${ROOT#"$HOME"}" ] && MOUNTS+=(-v "$ROOT:$ROOT")
if [ "${RNI_SESSION:-wayland}" = x11 ]; then
  # Fixed display numbers, not -a: --network host shares the abstract X socket
  # namespace with the host, and -a only sees the container's own /tmp locks.
  ENTRY=(xvfb-run -n 78 -s "-screen 0 ${W}x${H}x24 -nolisten tcp"
         bash -c '"${@:2}" 2>&1 | tee "$1"; exit "${PIPESTATUS[0]}"' _ "$OUT/engine.out")
else
  ENTRY=("$ROOT/tools/arm64-testenv/wayland-session.sh" "$OUT" "$W" "$H" "$SCRIPT" --)
fi
# core=0: qemu-aarch64 writes a crashing guest's core into the cwd (the repo
# root); RNI_CORE_LIMIT=unlimited keeps them.
exec docker run --rm -i --init --platform "$PLAT" --network host --ulimit "core=${RNI_CORE_LIMIT:-0}" \
  --user "$(id -u):$(id -g)" "${MOUNTS[@]}" -w "$PWD" "${ENVS[@]}" \
  "$IMG" "${ENTRY[@]}" "$BIN/rn-impeller" "$@"
