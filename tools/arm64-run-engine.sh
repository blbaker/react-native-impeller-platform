#!/usr/bin/env bash
# RNI_BIN-compatible wrapper: run the linux-arm64 rn-impeller on this x86_64
# box, under qemu-aarch64, inside the Debian bookworm arm64 test container
# (Mesa llvmpipe, Weston 10, Xvfb). Any node-free gate takes it as its engine:
#
#   RNI_BIN=$PWD/tools/arm64-run-engine.sh bash tools/ci-<name>.sh
#
# It is the same arguments, the same stdout/stderr and the same exit code as
# the binary; paths are identical inside the container because $HOME and the
# repo are mounted at their host paths. Windowed (--window) runs reach the
# host's X server through /tmp/.X11-unix (DISPLAY passes through).
#
# ⛔ THIS IS NOT THE BOARD. Mesa llvmpipe under qemu proves the aarch64 build,
# its packaging and its behaviour; it says nothing about libmali. Board runs go
# through tools/arm64-board-run.sh.
#
# Env: RNI_ARM64_ENGINE_DIR (default packages-engine/engine-linux-arm64/bin)
#      RNI_ARM64_IMAGE      (default rni-arm64-tools:bookworm)
#      RNI_ARM64_HOST_FONTS=1 mounts the host fonts (pixel parity with x86_64)
#      every RNI_* variable, DISPLAY, XAUTHORITY and EGL_PLATFORM (Mesa's
#      platform for eglGetDisplay(EGL_DEFAULT_DISPLAY); ci-doctor H3) pass through.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${RNI_ARM64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-arm64/bin}"
IMG="${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}"
[ -x "$BIN/rn-impeller" ] || { echo "arm64-run-engine: no engine at $BIN (bash tools/engine-build-linux-arm64.sh)" >&2; exit 127; }
ENVS=(-e HOME="$HOME" -e LIBGL_ALWAYS_SOFTWARE=1 -e TMPDIR="${TMPDIR:-/tmp}")
while IFS='=' read -r k _; do
  case "$k" in RNI_*|DISPLAY|XAUTHORITY|MESA_*|GALLIUM_*|LP_*|EGL_PLATFORM) ENVS+=(-e "$k") ;; esac
done < <(env)
# The host's WAYLAND_DISPLAY (WSLg) is NOT passed: its socket is not mounted,
# and the x86_64 gates this wrapper serves drive X11 (xvfb-run). Wayland runs
# go through tools/arm64-wayland-run.sh, which brings its own Weston.
MOUNTS=(-v "$HOME:$HOME" -v /tmp:/tmp)
[ "$ROOT" = "${ROOT#"$HOME"}" ] && MOUNTS+=(-v "$ROOT:$ROOT")
# RNI_ARM64_HOST_FONTS=1: use THIS host's fonts + fontconfig inside the
# container, so a pixel comparison against the x86_64 build measures the
# engine and not two different font sets (the container has 6 fonts).
if [ "${RNI_ARM64_HOST_FONTS:-0}" = 1 ]; then
  MOUNTS+=(-v /usr/share/fonts:/usr/share/fonts:ro -v /etc/fonts:/etc/fonts:ro)
  [ -d /usr/local/share/fonts ] && MOUNTS+=(-v /usr/local/share/fonts:/usr/local/share/fonts:ro)
fi
exec docker run --rm -i --init --platform linux/arm64 --network host \
  --user "$(id -u):$(id -g)" "${MOUNTS[@]}" -w "$PWD" "${ENVS[@]}" \
  "$IMG" "$BIN/rn-impeller" "$@"
