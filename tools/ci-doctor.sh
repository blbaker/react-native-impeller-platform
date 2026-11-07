#!/usr/bin/env bash
# `rn-impeller --doctor` gate (linux matrix M2). The doctor must NAME the path
# a run was forced onto, say why every other path was not taken, and report the
# optional libraries the way the engine's own loaders resolve them.
#
# Forced paths llvmpipe can run (each one asserted by name):
#   H0  no forcing                     -> surfaceless rung, llvmpipe, key=value only
#   H1  RNI_EGL_PLATFORM=surfaceless   -> surfaceless; gbm + default skipped
#   H3  RNI_EGL_PLATFORM=default       -> default display (EGL_PLATFORM=surfaceless
#                                         tells Mesa which platform that is)
#   H4  H3 + RNI_EGL_FORCE_PBUFFER=1   -> default display bound to a 1x1 pbuffer
#   W   RNI_GLFW_PLATFORM=wayland, headless Weston  -> glfwInit got wayland
#   WS  XDG_SESSION_TYPE=wayland, no forcing        -> wayland, reason says why
#   X   RNI_GLFW_PLATFORM=x11, Xvfb                 -> glfwInit got x11
#   XD  Xvfb, no forcing (DISPLAY set)              -> x11, reason DISPLAY_set...
#   XN  RNI_GLFW_PLATFORM=wayland, Xvfb only        -> glfwInit FAILS (forcing is
#                                                      real, no silent fallback)
# A path llvmpipe cannot run:
#   H2  RNI_EGL_PLATFORM=gbm with no DRM node -> rung verdict UNVERIFIED-ON-HARDWARE
#       (with a node present it must take gbm instead)
# dma_heap (RNI_DOCTOR_DMA_HEAP_DIR fixture dirs):
#   D1  dir missing                       -> system:enoent, hint names the path
#   D2  `system` mode 000 + system-uncached -> system:eacces cma:absent, hint = udev rule
#   D3  readable `system` + linux,cma      -> system:ok cma:present, no hint
#   D4  the dir is a plain file           -> system:error
#   H0 checks the real /dev/dma_heap against the gate's own test -e / -r.
# Every software-rendered arm must print gpu.verdict=UNVERIFIED-ON-HARDWARE.
# Library oracle, independent of the doctor: the gate's own soname table checked
# against `ldconfig -p` of the environment the engine ran in. A library the
# environment has must be reported resolved under that soname.
#
# Usage: bash tools/ci-doctor.sh [--arch x64|arm64]     (default x64)
#   x64:   headless arms run natively; window arms in rni-x64-tools:noble
#   arm64: everything under qemu-aarch64 in rni-arm64-tools:bookworm
# Env: RNI_X64_ENGINE_DIR / RNI_ARM64_ENGINE_DIR, RNI_X64_IMAGE / RNI_ARM64_IMAGE
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH=x64
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    *) echo "usage: $0 [--arch x64|arm64]" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  x64)   TAG=X64; BIN="${RNI_X64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-x64/bin}/rn-impeller"
         IMG="${RNI_X64_IMAGE:-rni-x64-tools:noble}"; PLAT=linux/amd64 ;;
  arm64) TAG=ARM64; BIN="${RNI_ARM64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-arm64/bin}/rn-impeller"
         IMG="${RNI_ARM64_IMAGE:-rni-arm64-tools:bookworm}"; PLAT=linux/arm64 ;;
  *) echo "usage: $0 [--arch x64|arm64]" >&2; exit 2 ;;
esac
fail() { echo "${TAG}_DOCTOR_FAIL: $*"; exit 1; }
[ -x "$BIN" ] || fail "no engine at $BIN"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "no $IMG image (see tools/arm64-testenv)"
# Nothing from the caller's shell may steer an arm.
unset RNI_GLFW_PLATFORM RNI_EGL_PLATFORM RNI_EGL_FORCE_PBUFFER RNI_DRM_RENDER_NODE RNI_WEBHELPER EGL_PLATFORM
WORK="$(mktemp -d)"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"' EXIT
export RNI_TEST_ARCH="$ARCH"

val() { grep -m1 "^${1//./\\.}=" "$2" | cut -d= -f2- || true; }
want() {  # $1 arm, $2 file, $3 key, $4 expected value (exact)
  local got; got="$(val "$3" "$2")"
  [ "$got" = "$4" ] || fail "$1: $3 is '${got:-<missing>}', expected '$4'"
}
want_re() {  # $1 arm, $2 file, $3 key, $4 ERE the value must match
  local got; got="$(val "$3" "$2")"
  grep -qE "$4" <<< "$got" || fail "$1: $3 is '${got:-<missing>}', expected /$4/"
}
want_has() {  # $1 arm, $2 file, $3 key, $4 text the value must contain (fixed string)
  local got; got="$(val "$3" "$2")"
  grep -qF -- "$4" <<< "$got" || fail "$1: $3 is '${got:-<missing>}', expected it to contain '$4'"
}

# One headless doctor run: stdout and stderr kept apart, env = "K=V ..." args.
headless() {  # $1 arm, then K=V...
  local arm="$1"; shift
  local rc=0
  if [ "$ARCH" = x64 ]; then
    env -i HOME="$HOME" PATH="$PATH" LIBGL_ALWAYS_SOFTWARE=1 "$@" "$BIN" --doctor \
      > "$WORK/$arm.out" 2> "$WORK/$arm.err" || rc=$?
  else
    env -u DISPLAY -u XAUTHORITY "$@" timeout 300 bash tools/arm64-run-engine.sh --doctor \
      > "$WORK/$arm.out" 2> "$WORK/$arm.err" || rc=$?
  fi
  [ "$rc" -eq 0 ] || { tail -5 "$WORK/$arm.err"; fail "$arm: --doctor exited $rc"; }
  local bad; bad="$(grep -cvE '^[A-Za-z0-9_.]+=' "$WORK/$arm.out" || true)"
  [ "$bad" -eq 0 ] || fail "$arm: $bad stdout lines are not key=value: $(grep -vE '^[A-Za-z0-9_.]+=' "$WORK/$arm.out" | head -2)"
  local dup; dup="$(cut -d= -f1 "$WORK/$arm.out" | sort | uniq -d | head -3 | tr '\n' ' ')"
  [ -z "$dup" ] || fail "$arm: keys printed twice: $dup"
  want "$arm" "$WORK/$arm.out" doctor.done 1
}

# One windowed-session doctor run in the arch's container (merged output).
session() {  # $1 arm, $2 wayland|x11, then K=V...
  local arm="$1" kind="$2"; shift 2
  local rc=0
  env "$@" RNI_SESSION="$kind" timeout 300 bash tools/arm64-wayland-run.sh "$WORK/$arm" 320 240 "" -- --doctor \
    > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$arm/engine.out" 2>/dev/null; fail "$arm: --doctor exited $rc"; }
  want "$arm" "$WORK/$arm/engine.out" doctor.done 1
}

software_verdict() {  # $1 arm, $2 file, $3 key prefix (gpu | window.gpu)
  want "$1" "$2" "$3.class" software
  want "$1" "$2" "$3.verdict" UNVERIFIED-ON-HARDWARE
}

# ---- library oracle: the gate's own table, NOT the doctor's ----
if [ "$ARCH" = x64 ]; then /sbin/ldconfig -p > "$WORK/ldcache"
else docker run --rm --platform "$PLAT" "$IMG" /sbin/ldconfig -p > "$WORK/ldcache"; fi
have() { grep -qE "^[[:space:]]+${1//./\\.} " "$WORK/ldcache"; }
check_libs() {  # $1 arm, $2 file
  local key so
  while read -r key so; do
    if have "$so"; then want "$1 [$key]" "$2" "dlopen.$key.resolved" "$so"
    else want "$1 [$key]" "$2" "dlopen.$key.resolved" none
         want_re "$1 [$key]" "$2" "dlopen.$key.error" '.'; fi
  done <<'EOF'
libX11 libX11.so.6
libXext libXext.so.6
fontconfig libfontconfig.so.1
gbm libgbm.so.1
EOF
  local rel libs expect=none
  while read -r rel libs; do
    local all=1 s; for s in $libs; do have "$s" || all=0; done
    [ "$all" = 1 ] && [ "$expect" = none ] && expect="$rel"
    if [ "$all" = 1 ]; then want "$1 [ffmpeg$rel]" "$2" "dlopen.ffmpeg.$rel" ok
    else want_re "$1 [ffmpeg$rel]" "$2" "dlopen.ffmpeg.$rel" '^missing:'; fi
  done <<'EOF'
8 libavutil.so.60 libavcodec.so.62 libavformat.so.62 libswscale.so.9
7 libavutil.so.59 libavcodec.so.61 libavformat.so.61 libswscale.so.8
6 libavutil.so.58 libavcodec.so.60 libavformat.so.60 libswscale.so.7
EOF
  want "$1 [ffmpeg]" "$2" dlopen.ffmpeg.resolved "$expect"
  local abi; abi="$(val video.ffmpeg_abi "$2")"
  if [ "$abi" = none ]; then want "$1 [video]" "$2" video.backend none
  elif [ "$(val "dlopen.ffmpeg.$abi" "$2")" = ok ]; then want "$1 [video]" "$2" video.status ok
  else want_re "$1 [video]" "$2" video.status '^unusable:'; fi
  # Second instrument: GLFW's own probe of libX11 (its literal, not the table).
  if grep -q '^window.glfw_needs.x11=libX11.so.6:ok$' "$2"; then
    want "$1 [libX11 vs GLFW]" "$2" dlopen.libX11.resolved libX11.so.6
  fi
}

echo "== $ARCH: headless EGL rungs ($BIN) =="
headless H0
O="$WORK/H0.out"
want H0 "$O" egl.forced unset
want H0 "$O" egl.platform surfaceless
want H0 "$O" egl.rung.surfaceless ok
want_re H0 "$O" egl.rung.gbm '^skipped:surfaceless already took'
want_re H0 "$O" egl.rung.default '^skipped:surfaceless already took'
want H0 "$O" egl.headless_init ok
want H0 "$O" egl.current surfaceless
for k in egl.vendor egl.version egl.extensions egl.client_extensions gl.renderer gl.version; do want_re H0 "$O" "$k" '.'; done
want_re H0 "$O" gl.renderer llvmpipe
software_verdict H0 "$O" gpu
want H0 "$O" window.platform none
want_re H0 "$O" window.glfw_init '^fail:'
check_libs H0 "$O"
want_re H0 "$O" webhelper.tried '^RNI_WEBHELPER,.*/rni-webhelper$'
# The real heap, as the gate sees it where the engine ran (tools/arm64-run-engine.sh
# passes no /dev/dma_heap into its container).
dh_sys=enoent; dh_cma=absent
if [ "$ARCH" = x64 ] && [ -e /dev/dma_heap/system ]; then
  if [ -r /dev/dma_heap/system ]; then dh_sys=ok; else dh_sys=eacces; fi
fi
if [ "$ARCH" = x64 ] && ls /dev/dma_heap 2>/dev/null | grep -qvxE 'system|system-uncached'; then dh_cma=present; fi
want H0 "$O" dma_heap "system:$dh_sys cma:$dh_cma"
[ "$dh_sys" = ok ] || want_has H0 "$O" dma_heap.hint "/dev/dma_heap/system"
echo "   H0 pass ($(val gl.renderer "$O" | cut -c1-40); ffmpeg=$(val dlopen.ffmpeg.resolved "$O"); libX11=$(val dlopen.libX11.resolved "$O"))"

headless H1 RNI_EGL_PLATFORM=surfaceless
want H1 "$WORK/H1.out" egl.forced surfaceless
want H1 "$WORK/H1.out" egl.platform surfaceless
want H1 "$WORK/H1.out" egl.rung.gbm skipped:RNI_EGL_PLATFORM=surfaceless
want H1 "$WORK/H1.out" egl.rung.default skipped:RNI_EGL_PLATFORM=surfaceless
echo "   H1 pass"

# H2: the gbm rung needs a DRM node. Check for one where the engine runs.
if [ "$ARCH" = x64 ]; then nodes="$(ls /dev/dri/renderD* /dev/dri/card* 2>/dev/null || true)"
else nodes=""; fi  # tools/arm64-run-engine.sh passes no devices into the container
headless H2 RNI_EGL_PLATFORM=gbm
O="$WORK/H2.out"
want H2 "$O" egl.rung.surfaceless skipped:RNI_EGL_PLATFORM=gbm
want H2 "$O" egl.rung.default skipped:RNI_EGL_PLATFORM=gbm
if [ -z "$nodes" ]; then
  want H2 "$O" egl.platform none
  want_re H2 "$O" egl.rung.gbm '^fail:no DRM node'
  want H2 "$O" egl.rung.gbm.verdict UNVERIFIED-ON-HARDWARE
  want_re H2 "$O" egl.headless_init '^fail:'
  echo "   H2 pass (no DRM node here: gbm is UNVERIFIED-ON-HARDWARE)"
else
  want H2 "$O" egl.platform gbm
  echo "   H2 pass (DRM node present: gbm taken)"
fi

headless H3 RNI_EGL_PLATFORM=default EGL_PLATFORM=surfaceless
O="$WORK/H3.out"
want H3 "$O" egl.platform default
want H3 "$O" egl.rung.default ok
want H3 "$O" egl.rung.surfaceless skipped:RNI_EGL_PLATFORM=default
want H3 "$O" egl.current surfaceless
want_re H3 "$O" gl.renderer llvmpipe
software_verdict H3 "$O" gpu
echo "   H3 pass"

headless H4 RNI_EGL_PLATFORM=default EGL_PLATFORM=surfaceless RNI_EGL_FORCE_PBUFFER=1
want H4 "$WORK/H4.out" egl.platform default
want H4 "$WORK/H4.out" egl.current pbuffer
want H4 "$WORK/H4.out" egl.headless_init ok
echo "   H4 pass (default display + 1x1 pbuffer)"

echo "== $ARCH: dma_heap (RNI_DOCTOR_DMA_HEAP_DIR fixtures) =="
UDEV='SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="video", MODE="0660"'
DH="$WORK/dma_heap"
mkdir -p "$DH/eacces" "$DH/ok"
: > "$DH/eacces/system"; : > "$DH/eacces/system-uncached"; chmod 000 "$DH/eacces/system"
: > "$DH/ok/system"; : > "$DH/ok/system-uncached"; : > "$DH/ok/linux,cma"
: > "$DH/plainfile"
[ -r "$DH/eacces/system" ] && fail "D2: a mode-000 file is readable here (root?), so EACCES cannot be produced"
dh() {  # $1 arm, $2 dir, $3 expected dma_heap value
  headless "$1" RNI_DOCTOR_DMA_HEAP_DIR="$2"
  want "$1" "$WORK/$1.out" dma_heap "$3"
}
dh D1 "$DH/missing" "system:enoent cma:absent"
want_has D1 "$WORK/D1.out" dma_heap.hint "$DH/missing/system is missing"
dh D2 "$DH/eacces" "system:eacces cma:absent"
want_has D2 "$WORK/D2.out" dma_heap.hint "$DH/eacces/system exists but this user cannot open it"
want_has D2 "$WORK/D2.out" dma_heap.hint "$UDEV"
dh D3 "$DH/ok" "system:ok cma:present"
! grep -q '^dma_heap\.hint=' "$WORK/D3.out" || fail "D3: dma_heap.hint printed for an openable heap: $(val dma_heap.hint "$WORK/D3.out")"
dh D4 "$DH/plainfile" "system:error cma:absent"
want_has D4 "$WORK/D4.out" dma_heap.hint "$DH/plainfile/system: Not a directory"
echo "   D1-D4 pass (enoent, eacces + udev rule, ok + cma, error; real heap here: system:$dh_sys cma:$dh_cma)"

echo "== $ARCH: window system ($IMG) =="
win() {  # $1 arm, $2 file, $3 choice, $4 reason, $5 platform
  want "$1" "$2" window.choice "$3"
  want "$1" "$2" window.reason "$4"
  want "$1" "$2" window.glfw_init ok
  want "$1" "$2" window.platform "$5"
  want "$1" "$2" window.egl ok
  want_re "$1" "$2" window.gl.renderer llvmpipe
  software_verdict "$1" "$2" window.gpu
  echo "   $1 pass ($5, $4, $(val window.gl.renderer "$2" | cut -c1-30))"
}
session W wayland RNI_GLFW_PLATFORM=wayland
win W "$WORK/W/engine.out" wayland RNI_GLFW_PLATFORM wayland
session WS wayland RNI_SESSION_TYPE=wayland
win WS "$WORK/WS/engine.out" any XDG_SESSION_TYPE=wayland wayland
session X x11 RNI_GLFW_PLATFORM=x11
win X "$WORK/X/engine.out" x11 RNI_GLFW_PLATFORM x11
want X "$WORK/X/engine.out" dlopen.libX11.resolved libX11.so.6
session XD x11
win XD "$WORK/XD/engine.out" x11 DISPLAY_set_session_not_wayland x11
session XN x11 RNI_GLFW_PLATFORM=wayland
O="$WORK/XN/engine.out"
want XN "$O" window.choice wayland
want_re XN "$O" window.glfw_init '^fail:'
want XN "$O" window.platform none
echo "   XN pass (forced wayland with no compositor: glfwInit refused, no fallback)"

echo "${TAG}_DOCTOR_PASS (EGL rungs surfaceless/default/pbuffer named when forced, gbm UNVERIFIED-ON-HARDWARE; wayland + x11 forced and selected; libraries match ldconfig; dma_heap enoent/eacces/ok/error)"
