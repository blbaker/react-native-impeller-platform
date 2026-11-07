#!/usr/bin/env bash
# RNI_WEBHELPER launcher for linux-x64 on WSL: runs rni-webhelper inside the
# WPE container (WPE WebKit is not packaged for Ubuntu 24.04).
#
#   export RNI_WEBHELPER="$PWD/tools/webhelper-docker.sh"
#   rn-impeller --window ...        # the engine appends --socket <path> --data-dir <dir>
#
# The socket and data dirs are bind-mounted at the SAME paths, so the engine's
# paths work unchanged inside; the frame memfd crosses as an SCM_RIGHTS fd (one
# kernel, no shared /dev/shm needed). --network host: pages on 127.0.0.1 work.
#
# Optional:
#   RNI_WIDEVINE_CDM=/abs/libwidevinecdm.so   mounted ro, exported as OCDM_WIDEVINE_CDM
#                                             (the OpenCDM shim's CDM path). Unset = no CDM.
#   RNI_WEBHELPER_LOG=1, WEBKIT_DEBUG=EME, OCDM_SHIM_QUIET=1, OCDM_SHIM_TEST_SKIP_DECRYPT=1
#   RNI_WPE_PREFIX, RNI_WPE_IMAGE             (defaults: wpe-impeller-probe prefix, wpe-ocdm:sid)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="${RNI_WPE_PROBE:-$HOME/projects/wpe-impeller-probe}"
PREFIX="${RNI_WPE_PREFIX:-$PROBE/prefix}"
IMAGE="${RNI_WPE_IMAGE:-wpe-ocdm:sid}"
HELPER_DIR="${RNI_WEBHELPER_DIR:-$ROOT/engine/build-webhelper}"
SOCK="" DATA=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --socket) SOCK="${args[$((i + 1))]}" ;;
    --data-dir) DATA="${args[$((i + 1))]}" ;;
  esac
done
[ -n "$SOCK" ] && [ -n "$DATA" ] || { echo "webhelper-docker: needs --socket and --data-dir" >&2; exit 2; }
[ -x "$HELPER_DIR/rni-webhelper" ] || { echo "webhelper-docker: no $HELPER_DIR/rni-webhelper (tools/webhelper-build.sh)" >&2; exit 2; }
mkdir -p "$DATA"
XDGC="${RNI_WEBHELPER_XDG_CACHE:-$HOME/.cache/rni/webhelper-xdg}"  # GStreamer registry, reused
mkdir -p "$XDGC"
CDM_ARGS=()
if [ -n "${RNI_WIDEVINE_CDM:-}" ]; then
  CDM_ARGS=(-v "$(dirname "$RNI_WIDEVINE_CDM"):/opt/widevine:ro"
            -e "OCDM_WIDEVINE_CDM=/opt/widevine/$(basename "$RNI_WIDEVINE_CDM")")
fi
ENV_ARGS=()
for v in RNI_WEBHELPER_LOG WEBKIT_DEBUG OCDM_SHIM_QUIET OCDM_SHIM_TEST_SKIP_DECRYPT GST_DEBUG; do
  [ -n "${!v:-}" ] && ENV_ARGS+=(-e "$v=${!v}")
done
exec docker run --rm -i --init --name "rni-webhelper-$$" --network host \
  --user "$(id -u):$(id -g)" -e HOME=/tmp -e XDG_CACHE_HOME=/xdg-cache -e LD_LIBRARY_PATH=/work/prefix/lib \
  -v "$(dirname "$SOCK"):$(dirname "$SOCK")" -v "$DATA:$DATA" -v "$XDGC:/xdg-cache" \
  -v "$PREFIX:/work/prefix:ro" -v "$HELPER_DIR:/opt/rni-webhelper:ro" \
  ${CDM_ARGS[@]+"${CDM_ARGS[@]}"} ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  "$IMAGE" bash -c 'mkdir -p -m 700 /tmp/xdg && export XDG_RUNTIME_DIR=/tmp/xdg && exec /opt/rni-webhelper/rni-webhelper "$@"' \
  rni-webhelper "$@"
