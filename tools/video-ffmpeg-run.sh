#!/usr/bin/env bash
# RNI_BIN-compatible wrapper for tools/ci-video-ffmpeg8.sh: run a linux
# package's rn-impeller in a container whose ffmpeg is EXACTLY what the arm
# under test says, installed the way an image installs it (system lib dir, no
# LD_LIBRARY_PATH).
#
#   FFRUN_ARCH=arm64  qemu-aarch64 in rni-arm64-tools:bookworm (Debian ships
#                     ffmpeg 5.1 there: libavcodec.so.59, none of 8/7/6)
#   FFRUN_ARCH=x64    rni-x64-tools:noble (Ubuntu ships ffmpeg 6.1: hide it
#                     with FFRUN_HIDE for an "8 only" or "no ffmpeg" arm)
#   FFRUN_ENGINE_DIR  package bin dir (default packages-engine/engine-linux-<arch>/bin)
#   FFRUN_LIBS=<dir>  every lib*.so.<N> (soname-shaped name) in it is bind-mounted
#                     read-only into the image's multiarch lib dir under that name
#   FFRUN_HIDE="..."  sonames covered with /dev/null: dlopen then fails
#                     ("file too short"), as if the package were not installed
# Same arguments, stdout/stderr and exit code as the binary. $HOME and /tmp are
# mounted at their host paths; DISPLAY, XAUTHORITY and RNI_* pass through (the
# windowed arms use the host's xvfb-run, like tools/arm64-run-engine.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${FFRUN_ARCH:?FFRUN_ARCH=arm64|x64}"
case "$ARCH" in
  arm64) IMG="${FFRUN_IMAGE:-rni-arm64-tools:bookworm}"; PLAT=linux/arm64; MA=aarch64-linux-gnu ;;
  x64) IMG="${FFRUN_IMAGE:-rni-x64-tools:noble}"; PLAT=linux/amd64; MA=x86_64-linux-gnu ;;
  *) echo "video-ffmpeg-run: FFRUN_ARCH must be arm64 or x64" >&2; exit 2 ;;
esac
BIN="${FFRUN_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-$ARCH/bin}"
[ -x "$BIN/rn-impeller" ] || { echo "video-ffmpeg-run: no engine at $BIN" >&2; exit 127; }
LIBDIR="/usr/lib/$MA"
MOUNTS=(-v "$HOME:$HOME" -v /tmp:/tmp)
[ "$ROOT" = "${ROOT#"$HOME"}" ] && MOUNTS+=(-v "$ROOT:$ROOT")
if [ -n "${FFRUN_LIBS:-}" ]; then
  n=0
  for f in "$FFRUN_LIBS"/lib*.so.*; do
    b="$(basename "$f")"
    [[ "$b" =~ ^lib[a-z0-9_]+\.so\.[0-9]+$ ]] || continue
    MOUNTS+=(-v "$(readlink -f "$f"):$LIBDIR/$b:ro"); n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "video-ffmpeg-run: no lib*.so.<N> in $FFRUN_LIBS" >&2; exit 2; }
fi
for so in ${FFRUN_HIDE:-}; do MOUNTS+=(-v "/dev/null:$LIBDIR/$so:ro"); done
ENVS=(-e HOME="$HOME" -e LIBGL_ALWAYS_SOFTWARE=1 -e TMPDIR="${TMPDIR:-/tmp}")
while IFS='=' read -r k _; do
  case "$k" in RNI_*|DISPLAY|XAUTHORITY|MESA_*|GALLIUM_*|LP_*|EGL_PLATFORM) ENVS+=(-e "$k") ;; esac
done < <(env)
exec docker run --rm -i --init --platform "$PLAT" --network host \
  --user "$(id -u):$(id -g)" "${MOUNTS[@]}" -w "$PWD" "${ENVS[@]}" \
  "$IMG" "$BIN/rn-impeller" "$@"
