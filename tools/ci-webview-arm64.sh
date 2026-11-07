#!/usr/bin/env bash
# linux matrix M5 gate: react-native-webview's <WebView> on linux-arm64, qemu only.
#
# The arm64 rn-impeller and the arm64 rni-webhelper (WPE WebKit 2.54, cross-built
# by tools/webview-arm64/wpe-cross-build.sh) run under qemu-aarch64 in
# rni-webview-arm64:sid: headless Weston + kiosk-shell, Mesa llvmpipe, the
# engine as a Wayland client (tools/webview-arm64/session.sh). Node-free: the
# committed webview bundle (mode=main loads /a.html), served from
# fixtures/webview-arm64/pages.
#
#   pixels    the page draws into the ENGINE texture: exact page colours under the
#             RN bar in the engine's own readback (--screenshot-when-file, taken
#             once the page has loaded)
#   touch     wl_touch taps injected into Weston (rni-touch-inject): one on the RN
#             bar (must reach no page), one at window 100,145 (a page touchstart +
#             click at page 100,105 on #btn)
#   nohelper  NEGATIVE: with no helper (/bin/false), onError reaches JS and the
#             engine exits 0
#   (every run with the real helper) the HELPER exits cleanly too: each destroyed
#             view reached it, the engine reaped it with code 0, no abort line
#             (webview_check.py helper-exit). Runs keep no qemu core (--ulimit
#             core=0, cwd = the workdir), so the exit line is what sees a crash.
#   noseat    Weston WITHOUT rni-touch-inject, so no wl_seat global (a kiosk Weston
#             with require-input=false and nothing plugged in): the engine reaches
#             first present and exits 0 on SIGTERM. Stock GLFW 3.4 segfaults in
#             glfwInit here (exit 139; tools/glfw-patches/0001). The seat-less
#             precondition is read from libwayland's own WAYLAND_DEBUG registry trace.
#             Mutants: tools/mutation-verify-webview-noseat.sh
#   eme       (linux matrix M6, opt-in: network) the Shaka sintel-widevine asset, licence
#             from cwip-shaka-proxy, through WebKit EME -> the aarch64 OpenCDM shim ->
#             the Asahi-fixed lacros CDM 4.10.2662.3. Verdict PLAYING from a series of
#             8 ENGINE readbacks (--screenshot-series) of the player rect, plus
#             provenance: /proc/<pid>/maps of the helper's tree maps ONLY that file
#             (sha256 pinned). tools/webview_eme_check.py has the rules.
#   eme-nocdm / eme-skipdecrypt  NEGATIVES, same binaries: exactly NOT_PLAYING
#   eme-g3112 CONTROL: Google's component-updater 4.10.3112.0 as the CDM; the
#             provenance check must REJECT it (whatever it plays)
#
#   bash tools/ci-webview-arm64.sh            (ARMS="pixels touch nohelper noseat")
#   ARMS="eme eme-nocdm eme-skipdecrypt eme-g3112" bash tools/ci-webview-arm64.sh
# Env: RNI_ARM64_ENGINE_DIR, RNI_ARM64_WEBHELPER, RNI_WPE_ARM64_DIR,
#      RNI_ARM64_JIT=1|0 (0 = JSC_useJIT=0: the JIT is off, and the output says so),
#      RNI_ARM64_WIDEVINE_CDM / RNI_ARM64_G3112_CDM (the two CDM files; the pins are fixed)
# Mutants: tools/mutation-verify-webview-arm64.sh. qemu + llvmpipe is NOT the
# board: everything that needs libmali / a real panel is UNVERIFIED-ON-HARDWARE.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "WEBVIEW_ARM64_FAIL: $*" >&2; exit 1; }
W="${RNI_WPE_ARM64_DIR:-$HOME/.cache/rni/wpe-arm64}"
EDIR="${RNI_ARM64_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-arm64/bin}"
HELPER="${RNI_ARM64_WEBHELPER:-$ROOT/engine/build-webhelper-arm64/rni-webhelper}"
IMG="${RNI_WPE_ARM64_IMAGE:-rni-webview-arm64:sid}"
BUNDLE="$ROOT/fixtures/webview/prebuilt/webview.bundle"
PAGES="$ROOT/fixtures/webview-arm64/pages"
EPAGES="$ROOT/fixtures/webview/pages"   # eme.html + vendored Shaka, shared with x64
# The arm64 CDM (Mac decision 2026-10-18): the board BSP layer lacros arm64 file, Widevine
# 4.10.2662.3, after the Asahi glibc fixup (IMAGE-REQUIREMENTS.md). The pin is the
# provenance check: whatever path is passed, the MAPPED file must hash to it.
CDM_FIXED="${RNI_ARM64_WIDEVINE_CDM:-$HOME/projects/wv-arm64-ocdm-gate/work/cdm/asahi/libwidevinecdm.so}"
CDM_PIN=8cb3119cd4f319ea16546d3260b47fc8c81350e311cc053fc557ee3d994f693d
CDM_G3112="${RNI_ARM64_G3112_CDM:-$HOME/projects/wv-arm64-ocdm-gate/work/google-3112/libwidevinecdm.so}"
G3112_SHA=46a70f3a5e37423327c3fb2e3c2b468ddd89bf28470437158ffb51af4ea4da3c
ARMS="${ARMS:-pixels touch nohelper noseat}"
JIT="${RNI_ARM64_JIT:-1}"
for f in "$EDIR/rn-impeller" "$HELPER"; do
  [ -x "$f" ] || fail "missing $f"
  file -L "$f" | grep -q 'ARM aarch64' || fail "$f is not aarch64: $(file -L -b "$f" | cut -d, -f1-2)"
done
[ -f "$W/prefix/lib/libWPEWebKit-2.0.so" ] || fail "no arm64 WPE prefix at $W/prefix"
docker image inspect "$IMG" >/dev/null 2>&1 || fail "no image $IMG (docker build --platform linux/arm64 -t $IMG tools/webview-arm64)"
echo "engine: $EDIR/rn-impeller ($(sha256sum "$EDIR/rn-impeller" | cut -c1-12)) helper: $HELPER ($(sha256sum "$HELPER" | cut -c1-12))"
# The WebKit under test must be the ENABLE_THUNDER build (it NEEDS the OpenCDM
# shim). RNI_ARM64_ALLOW_NO_THUNDER=1 admits a stock WebKit (debugging only).
THUNDER="$(readelf -d "$W/prefix/lib/libWPEWebKit-2.0.so" 2>/dev/null | grep -c 'NEEDED.*libocdm\.so\.1' || true)"
[ "$THUNDER" = 1 ] || [ "${RNI_ARM64_ALLOW_NO_THUNDER:-0}" = 1 ] \
  || fail "the WebKit at $W/prefix does not NEED libocdm.so.1: not the THUNDER/EME build"
echo "webkit: $(sha256sum "$W/prefix/lib/libWPEWebKit-2.0.so" | cut -c1-12) thunder=$([ "$THUNDER" = 1 ] && echo yes || echo NO) image: $(docker image inspect -f '{{.Id}}' "$IMG" | cut -c8-19) jit=$([ "$JIT" = 0 ] && echo 'OFF (JSC_useJIT=0)' || echo on)"

# rni-touch-inject built for THIS image's libweston (cached by source + image).
MODSRC="$ROOT/tools/arm64-testenv/rni-touch-inject.c"
MOD="$W/rni-touch-inject-$(cat "$MODSRC" <(docker image inspect -f '{{.Id}}' "$IMG") | sha256sum | cut -c1-12).so"
if [ ! -f "$MOD" ]; then
  docker run --rm --platform linux/arm64 --user "$(id -u):$(id -g)" -v "$ROOT:$ROOT:ro" -v "$W:$W" "$IMG" bash -c \
    "gcc -shared -fPIC -O2 -Wall -o '$MOD' '$MODSRC' \$(pkg-config --cflags --libs \$(pkg-config --list-package-names | grep -m1 '^libweston-[0-9]*$') wayland-server)" \
    || fail "rni-touch-inject did not build against the image's libweston"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-webview-arm64.XXXXXX")"
SRV="" ESRV=""
cleanup() {
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; }
  [ -n "$ESRV" ] && { kill "$ESRV" 2>/dev/null || true; wait "$ESRV" 2>/dev/null || true; }
  [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 tools/webview_server.py "$PORT" "$PAGES" "$WORK/req.log" &
SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/a.html" && break; sleep 0.1; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/a.html" || fail "harness: fixture server not reachable"

# arm64 <tag> <helper> [session env...]: one engine run in the arm64 container.
# A_URL / A_SERIES (globals) override the initial URL / add --screenshot-series.
arm64() {
  local tag="$1" helper="$2"; shift 2
  local url="${A_URL:-webview://run?base=http://127.0.0.1:$PORT&mode=main&closed=1}"
  local series=(); [ -n "${A_SERIES:-}" ] && series=(--screenshot-series "$A_SERIES")
  # LD_LIBRARY_PATH: WebKit's installed WPE{Web,Network,GPU}Process carry no RUNPATH
  # to the prefix (cmake strips the build rpath), as on x64 (tools/webhelper-docker.sh).
  # The engine links nothing from /opt/rni-wpe. On the device the libs are in /usr/lib.
  local envs=(-e HOME="$HOME" -e TMPDIR=/tmp -e LIBGL_ALWAYS_SOFTWARE=1 -e RNI_WEBHELPER="$helper"
              -e LD_LIBRARY_PATH=/opt/rni-wpe/lib
              -e RNI_WEBVIEW_DATA_DIR="$WORK/$tag-data" -e RNI_WEBHELPER_CONNECT_MS=180000
              -e RNI_WEBHELPER_EXIT_MS="${RNI_WEBHELPER_EXIT_MS:-60000}" -e RNI_WEBVIEW_LOG=1)
  # No qemu cores (each was ~500 MB, written to the container's cwd): a crash is
  # read from ENGINE_RC and, for the helper, from the engine's webview_helper_exit
  # line (webview_check.py helper-exit). The cwd is the workdir, not the repo.
  local dock=(--ulimit core=0)
  # A_NOSEAT=1: no touch module, so Weston has no wl_seat.
  [ "${A_NOSEAT:-0}" = 1 ] || envs+=(-e TOUCH_MODULE="$MOD")
  [ "$JIT" = 0 ] && envs+=(-e JSC_useJIT=0)
  local v; for v in RNI_WEBHELPER_LOG WEBKIT_DEBUG GST_DEBUG WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS OCDM_SHIM_QUIET; do
    [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}")   # debugging pass-through only
  done
  local e; for e in "$@"; do envs+=(-e "$e"); done
  : > "$WORK/$tag.start"
  set +e
  timeout 900 docker run --rm --init --platform linux/arm64 --network host --user "$(id -u):$(id -g)" "${dock[@]}" \
    -v "$HOME:$HOME" -v "$WORK:$WORK" -v "$W/prefix:/opt/rni-wpe:ro" -w "$WORK" "${envs[@]}" "$IMG" \
    "$ROOT/tools/webview-arm64/session.sh" "$WORK/$tag" 600 420 -- \
    "$EDIR/rn-impeller" --window --scale 1 --width 600 --height 420 --probe-banner off --prewarm off \
    --supersample-rnsvg 0 --app-name WebViewGate --bundle "$BUNDLE" --quit-on-term \
    --initial-url "$url" ${series[@]+"${series[@]}"} \
    --idle-skip --idle-run-sec 600 --screenshot "$WORK/$tag/shot.ppm" --screenshot-when-file "$WORK/$tag/shot.go" \
    > "$WORK/$tag.docker.log" 2>&1
  local rc=$?
  set -e
  grep -q 'ENGINE_RC=' "$WORK/$tag/engine.out" 2>/dev/null || { tail -20 "$WORK/$tag.docker.log" >&2; fail "$tag: engine run did not finish (rc $rc)"; }
  ! grep -q 'ENGINE_RC=139' "$WORK/$tag/engine.out" || fail "$tag: engine exited 139 (SIGSEGV)$([ "${A_NOSEAT:-0}" = 1 ] \
    && echo ' with no wl_seat: GLFW 3.4 wl_seat_get_version(NULL) in _glfwInitWayland; is tools/glfw-patches/0001 in the build?')"
  grep -q 'glfw_platform=wayland' "$WORK/$tag/engine.out" || fail "$tag: GLFW did not run on Wayland"
  # A real helper must END cleanly too: code 0 when the engine reaps it, no abort.
  if [ "$helper" != /bin/false ]; then
    python3 tools/webview_check.py helper-exit "$WORK/$tag/engine.out" "$tag" \
      || fail "$tag: the web helper did not exit cleanly (rule above)"
  fi
  local cores
  cores="$(find "$WORK" "$ROOT" -maxdepth 2 -name 'qemu_*.core' -newer "$WORK/$tag.start" 2>/dev/null | head -3 | tr '\n' ' ')"
  [ -z "$cores" ] || fail "$tag: qemu core(s) written: $cores(the docker run lost --ulimit core=0?)"
  echo "   $tag: $(grep -c . "$WORK/$tag/engine.out") log lines, $(tr '\n' ' ' < "$WORK/$tag/touch.log" | cut -c1-200)"
}

case " $ARMS " in *" pixels "*|*" touch "*)
  echo "== page run (pixels + touch) =="
  arm64 page "$HELPER" \
    "READY_RE=WVAPP t=[0-9]+ ev=load url=http://127.0.0.1:$PORT/a.html" "FRAME_RE=rn-impeller: webview_frame id=" \
    "QUIET_S=3" "SETTLE_S=1" "SHOT_FILE=$WORK/page/shot.go" \
    "TOUCH_SCRIPT=1500:down 300 20;1650:up;5000:down 100 145;5150:up" \
    "DONE_RE=WVPAGE click " "DONE_GRACE_S=3"
  P="$WORK/page/engine.out"
  grep -q 'wayland_touch attached seat=1 touch=1' "$P" || fail "touch: the engine did not bind wl_touch"
  grep -iE 'crash|terminated|helper_down' "$P" | head -5 >&2 || true
  grep -q 'webview_helper_ready' "$P" || fail "page: helper never came up: $(grep -m3 -E 'webview_helper|ERROR|error' "$P" | tr '\n' '|')"
  ! grep -q 'error while loading shared libraries' "$P" \
    || fail "page: a WebKit process could not load its libraries: $(grep -m1 'error while loading shared libraries' "$P")"
  case " $ARMS " in *" pixels "*) python3 tools/webview_arm64_check.py pixels "$P" "$WORK/page/shot.ppm" ;; esac
  case " $ARMS " in *" touch "*) python3 tools/webview_arm64_check.py touch "$P" "$WORK/page/weston.log" ;; esac
  grep -q 'ENGINE_RC=0' "$P" || fail "page: engine exit $(grep -o 'ENGINE_RC=[0-9]*' "$P") after SIGTERM"
;; esac

case " $ARMS " in *" nohelper "*)
  echo "== no helper (negative) =="
  arm64 nohelper /bin/false "DONE_RE=WVAPP t=[0-9]+ ev=error " "DONE_GRACE_S=3" "STEP_TIMEOUT_S=120"
  N="$WORK/nohelper/engine.out"
  python3 tools/webview_check.py nohelper "$N" || fail "nohelper: see the rule above"
;; esac

case " $ARMS " in *" noseat "*)
  echo "== no wl_seat (Weston without the touch module; SIGTERM after first present) =="
  A_NOSEAT=1 arm64 noseat /bin/false "WAYLAND_DEBUG=client" \
    "DONE_RE=rn-impeller: first_present_ms=" "DONE_GRACE_S=3" "STEP_TIMEOUT_S=180"
  S="$WORK/noseat/engine.out"
  # The precondition comes from libwayland's own trace, not from the engine
  # (libwayland < 1.23 prints wl_registry@N, newer wl_registry#N).
  grep -qE 'wl_registry[@#][0-9]+\.global\([0-9]+, "wl_compositor"' "$S" \
    || fail "noseat: no wl_compositor global in the WAYLAND_DEBUG trace (instrument broken)"
  ! grep -qE 'wl_registry[@#][0-9]+\.global\([0-9]+, "wl_seat"' "$S" \
    || fail "noseat: the compositor advertised a wl_seat: this run is not seat-less"
  grep -q 'rn-impeller: first_present_ms=' "$S" || fail "noseat: no first present"
  grep -q 'wayland_touch attached seat=0 touch=0' "$S" || fail "noseat: the touch listener did not report seat=0 touch=0"
  grep -q 'sent SIGTERM' "$WORK/noseat/touch.log" || fail "noseat: the session did not SIGTERM the engine ($(tail -1 "$WORK/noseat/touch.log"))"
  grep -q 'quit_requested signal=15 ' "$S" || fail "noseat: the engine did not quit on SIGTERM (--quit-on-term)"
  grep -q 'ENGINE_RC=0' "$S" || fail "noseat: engine exit $(grep -o 'ENGINE_RC=[0-9]*' "$S") after SIGTERM"
  echo "   noseat pass (no wl_seat global, $(grep -o 'first_present_ms=[0-9]*' "$S" | head -1), exit 0 on SIGTERM)"
;; esac
# ── linux matrix M6: EME through the engine texture ──────────────────────────────────
EME_ARMS=""
for a in $ARMS; do case "$a" in eme*) EME_ARMS="$EME_ARMS $a" ;; esac; done
if [ -n "$EME_ARMS" ]; then
  EPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  python3 tools/webview_server.py "$EPORT" "$EPAGES" "$WORK/ereq.log" &
  ESRV=$!
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$EPORT/eme.html" && break; sleep 0.1; done
  curl -sf -o /dev/null "http://127.0.0.1:$EPORT/eme.html" || fail "harness: eme fixture server not reachable"
  for f in "$CDM_FIXED" "$CDM_G3112"; do
    [ -f "$f" ] || fail "no CDM at $f (tools/webview-arm64 docs: ~/projects/wv-arm64-ocdm-gate work/)"
    case "$f" in "$HOME"/*) ;; *) fail "CDM $f must live under \$HOME (mounted at the same path)" ;; esac
  done
  echo "cdm: fixed $(sha256sum "$CDM_FIXED" | cut -c1-16) (pin ${CDM_PIN:0:16}) g3112 $(sha256sum "$CDM_G3112" | cut -c1-16)"
fi
for arm in $EME_ARMS; do
  echo "== $arm =="
  cdm="" extra=() expect=NOT_PLAYING prov=fixed maps_re='ocdm-shim: (decrypt ok count=|license update accepted)'
  case "$arm" in
    eme) cdm="$CDM_FIXED"; expect=PLAYING ;;
    eme-nocdm) prov=none; maps_re='WVEME (fail |license )' ;;
    eme-skipdecrypt) cdm="$CDM_FIXED"; extra=("OCDM_SHIM_TEST_SKIP_DECRYPT=1") ;;
    eme-g3112) cdm="$CDM_G3112"; expect=ANY; prov=reject ;;
    *) fail "unknown arm $arm" ;;
  esac
  A_URL="webview://run?base=http://127.0.0.1:$EPORT&mode=eme" A_SERIES=8
  # READY = the page clock 1 s past its 120 s start (playing), or the player gave up.
  arm64 "$arm" "$HELPER" ${cdm:+"OCDM_WIDEVINE_CDM=$cdm"} ${extra[@]+"${extra[@]}"} \
    "READY_RE=WVEME (tick t=(12[1-9]|1[3-9][0-9]|[2-9][0-9][0-9])\.|fail )" "MAPS_RE=$maps_re" \
    "SETTLE_S=1" "SHOT_FILE=$WORK/$arm/shot.go" "SERIES=8" "SERIES_GAP_S=2" \
    "DONE_RE=rn-impeller: screenshot=" "DONE_GRACE_S=2" "TERM_ON_TIMEOUT=1" "STEP_TIMEOUT_S=${RNI_ARM64_EME_TIMEOUT_S:-480}"
  unset A_URL A_SERIES
  grep 'TIMEOUT' "$WORK/$arm/touch.log" | head -3 >&2 || true
  python3 tools/webview_eme_check.py "$WORK/$arm" "$expect" "$prov" "$CDM_PIN" "$G3112_SHA" \
    || { grep -E 'WVEME|ocdm-shim' "$WORK/$arm/engine.out" | tail -12 >&2; exit 1; }
done

echo "WEBVIEW_ARM64_GATE_PASS arms=\"$ARMS\" jit=$([ "$JIT" = 0 ] && echo off || echo on) thunder=$([ "$THUNDER" = 1 ] && echo yes || echo NO) (qemu-aarch64 + llvmpipe; UNVERIFIED-ON-HARDWARE)"
