#!/usr/bin/env bash
# FP-25 gate: the Android host picks Vulkan on a good device and falls back to
# GLES on a known-bad driver or a failed Vulkan init, and the GLES fallback
# really renders (and follows rotation).
# Model: shell/platform/android/android_context_dynamic_impeller.cc (selection
# + kBadSocs), impeller/renderer/backend/vulkan/driver_info_vk.cc L377-L409
# (IsKnownBadDriver), android_surface_dynamic_impeller.cc (one surface API).
#   0. host unit test: every Flutter deny-list entry rejects Vulkan, its good
#      neighbour does not (tools/android-backend-unit.cpp, no device)
#   1. normal launch     -> android_backend=vulkan reason=ok, frame correct
#   2. RNI_FORCE_BAD_DRIVER=1 (intent extra; the probe exports it) ->
#      forced_bad_driver=1 read back, android_backend=gles
#      reason=known_bad_driver:..., then the probe fixture (per-cycle
#      background + 300x300 px white square) is correct on screen in portrait
#      and through RNI_FP25_CYCLES rotations, every probe_ready says backend=gles
#   3. RNI_FORCE_VULKAN_INIT_FAIL=1 -> forced_init_fail=1, android_backend=gles
#      reason=vulkan_init_failed, frame correct
# Device: RNI_ANDROID_SERIAL, else the attached SM-G991U1 (S21) or an emulator
# (an emulator is deny-listed, so arm 1 needs real hardware). Only the probe app
# is touched; hooks travel as intent extras, no OS setting changes.
# Env: RNI_FP25_CYCLES (4), RNI_FP25_EVIDENCE=<dir> keeps one png per arm.
set -uo pipefail
cd "$(dirname "$0")/.."
PKG=com.reactnativeimpeller.fp24probe
CYCLES="${RNI_FP25_CYCLES:-4}"
WANT_MODEL="${RNI_ANDROID_MODEL:-SM-G991U1}"
fail() { echo "ANDROID_BACKEND_FAIL: $*" >&2; exit 1; }
W="$(mktemp -d)"

echo "== 0. deny-list unit test (host) =="
c++ -std=c++20 -Wall -Iengine tools/android-backend-unit.cpp engine/host/AndroidDriverInfo.cpp \
  -o "$W/unit" > "$W/unit.build" 2>&1 || { tail -5 "$W/unit.build" >&2; fail "unit test did not build"; }
"$W/unit" > "$W/unit.log"; urc=$?
grep -E 'UNIT_FAIL' "$W/unit.log" | head -5 >&2
[ "$urc" = 0 ] || fail "deny list: $(tail -1 "$W/unit.log")"
echo "   $(tail -1 "$W/unit.log")"

command -v adb >/dev/null || fail "adb not on PATH"
model_of() { timeout 15 adb -s "$1" shell getprop ro.product.model 2>/dev/null | tr -d '\r'; }
emu_of() { timeout 15 adb -s "$1" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r'; }
SERIAL="${RNI_ANDROID_SERIAL:-}"
if [ -z "$SERIAL" ]; then
  for s in $(timeout 15 adb devices | awk 'NR>1 && $2=="device" {print $1}'); do
    if [ "$(model_of "$s")" = "$WANT_MODEL" ] || [ "$(emu_of "$s")" = 1 ]; then SERIAL="$s"; break; fi
  done
  if [ -z "$SERIAL" ]; then  # wireless debugging drops on idle: reconnect via mDNS
    for ep in $(timeout 15 adb mdns services 2>/dev/null | awk '$2 ~ /^_adb-tls-connect\._tcp/ {print $3}'); do
      timeout 20 adb connect "$ep" >/dev/null 2>&1 || continue
      [ "$(model_of "$ep")" = "$WANT_MODEL" ] && { SERIAL="$ep"; break; }
    done
  fi
fi
[ -n "$SERIAL" ] || fail "no attached $WANT_MODEL or emulator (adb devices)"
MODEL="$(model_of "$SERIAL")"
[ "$MODEL" = "$WANT_MODEL" ] || [ "$(emu_of "$SERIAL")" = 1 ] || fail "$SERIAL is a '$MODEL': refusing"
A() { timeout "${ADB_TO:-60}" adb -s "$SERIAL" "$@"; }
echo "   device $SERIAL ($MODEL)"
cleanup() { A shell am force-stop "$PKG" >/dev/null 2>&1; A uninstall "$PKG" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT

echo "== build + install the probe =="
bash tools/android-swapchain-probe-build.sh "$W/probe.apk" > "$W/build.log" 2>&1 \
  || { tail -8 "$W/build.log" >&2; fail "probe APK did not build"; }
A install -r -t "$W/probe.apk" > "$W/install.log" 2>&1 || { tail -3 "$W/install.log" >&2; fail "install"; }
[ "$(A shell dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1)" = "mWakefulness=Awake" ] \
  || A shell input keyevent KEYCODE_WAKEUP

PID=""
launch() {  # extra args for am start
  A shell am force-stop "$PKG"; PID=""
  A shell am start -W -n "$PKG/android.app.NativeActivity" "$@" > /dev/null || fail "am start $*"
  for _ in $(seq 20); do PID="$(A shell pidof "$PKG" | tr -d '\r')"; [ -n "$PID" ] && return 0; sleep 0.5; done
  fail "probe process did not start ($*)"
}
log() { A logcat -d --pid="$PID" -s rn-impeller:I 2>/dev/null | tr -d '\r'; }
decision() {  # echoes the android_backend line
  local line
  for _ in $(seq 30); do
    line="$(log | grep -o 'android_backend=.*' | tail -1)"; [ -n "$line" ] && { echo "$line"; return 0; }
    [ -n "$(A shell pidof "$PKG" | tr -d '\r')" ] || { echo "probe process died"; return 1; }
    sleep 0.5
  done
  echo "no android_backend line"; return 1
}
wait_ready() {  # cycle orientation backend -> echoes the probe_ready line
  local n="$1" want="$2" be="$3" line w h
  for _ in $(seq 40); do
    while read -r line; do
      [[ "$line" =~ win=([0-9]+)x([0-9]+)\ drawable=([0-9]+)x([0-9]+).*backend=([a-z]+) ]] || continue
      w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
      [ "${BASH_REMATCH[3]}x${BASH_REMATCH[4]}" = "${w}x${h}" ] || continue
      [ "${BASH_REMATCH[5]}" = "$be" ] || { echo "backend=${BASH_REMATCH[5]}"; return 1; }
      if { [ "$want" = landscape ] && [ "$w" -gt "$h" ]; } || { [ "$want" = portrait ] && [ "$h" -gt "$w" ]; }; then
        echo "${line#*probe_ready }"; return 0
      fi
    done < <(log | grep "probe_ready cycle=$n ")
    sleep 0.5
  done
  echo "no probe_ready"; return 1
}
check_frame() {  # png cycle orientation (same fixture as ci-android-swapchain.sh)
  python3 - "$@" <<'PY'
import sys
from PIL import Image
PALETTE = [(204,26,26),(26,179,38),(26,64,217),(217,191,26),(153,38,191),(26,179,191)]
path, n, want = sys.argv[1], int(sys.argv[2]), sys.argv[3]
im = Image.open(path).convert("RGB"); W, H = im.size; px = im.load()
if (W > H) != (want == "landscape"):
    print(f"screen is {W}x{H}, expected {want}"); sys.exit(1)
white = lambda p: min(p) >= 235
cx, cy = W // 2, H // 2
if not white(px[cx, cy]):
    print(f"screen centre is {px[cx, cy]}, not the white square (nothing rendered)"); sys.exit(1)
def run(x, y, dx, dy):
    k = 0
    while 0 <= x + dx * (k + 1) < W and 0 <= y + dy * (k + 1) < H and white(px[x + dx * (k + 1), y + dy * (k + 1)]): k += 1
    return k
sw = run(cx, cy, -1, 0) + run(cx, cy, 1, 0) + 1
sh = run(cx, cy, 0, -1) + run(cx, cy, 0, 1) + 1
if abs(sw - 300) > 4 or abs(sh - 300) > 4:
    print(f"white square is {sw}x{sh} on screen, expected 300x300 (surface size != window size)"); sys.exit(1)
bg = px[cx - sw // 2 - 60, cy]
want_bg = PALETTE[n % len(PALETTE)]
if max(abs(i - j) for i, j in zip(bg, want_bg)) > 40:
    print(f"background {bg} is not cycle {n}'s {want_bg}: frame not updated"); sys.exit(1)
print(f"square={sw}x{sh} bg={bg[0]},{bg[1]},{bg[2]}")
PY
}
frame_ok() {  # arm cycle orientation backend
  local arm="$1" n="$2" o="$3" be="$4" R V ok=""
  R="$(wait_ready "$n" "$o" "$be")" || fail "$arm cycle $n ($o): $R, expected a $be frame whose drawable matches the window"
  for _ in 1 2 3; do  # the system rotation animation can still be on screen
    sleep 1
    A exec-out screencap -p > "$W/$arm-$n.png" 2>/dev/null
    V="$(check_frame "$W/$arm-$n.png" "$n" "$o")" && { ok=1; break; }
  done
  [ -n "$ok" ] || fail "$arm cycle $n ($o, $be): $V"
  echo "   $arm cycle $n $o $be ${R%% presents=*} $V"
  if [ -n "${RNI_FP25_EVIDENCE:-}" ]; then mkdir -p "$RNI_FP25_EVIDENCE"; cp "$W/$arm-$n.png" "$RNI_FP25_EVIDENCE/$arm-$o.png"; fi
}
field() { [[ "$1" =~ $2=([^ ]*) ]] && echo "${BASH_REMATCH[1]}"; }

echo "== 1. normal launch -> vulkan =="
launch
D="$(decision)" || fail "normal: $D"
echo "   $D"
[ "$(field "$D" android_backend)" = vulkan ] || fail "normal device: $(field "$D" android_backend) reason=$(field "$D" reason), expected vulkan"
[ "$(field "$D" reason)" = ok ] || fail "normal device: reason=$(field "$D" reason)"
frame_ok normal 0 portrait vulkan

echo "== 2. RNI_FORCE_BAD_DRIVER=1 -> gles, still renders =="
launch --es RNI_FORCE_BAD_DRIVER 1
D="$(decision)" || fail "bad driver: $D"
echo "   $D"
[ "$(field "$D" forced_bad_driver)" = 1 ] || fail "hook RNI_FORCE_BAD_DRIVER not honoured (forced_bad_driver=$(field "$D" forced_bad_driver))"
[ "$(field "$D" android_backend)" = gles ] \
  || fail "forced bad driver: android_backend=$(field "$D" android_backend) reason=$(field "$D" reason), expected gles (no fallback)"
case "$(field "$D" reason)" in known_bad_driver:*) ;; *) fail "forced bad driver: reason=$(field "$D" reason), expected known_bad_driver:*" ;; esac
frame_ok baddriver 0 portrait gles
for n in $(seq 1 "$CYCLES"); do
  o=portrait; [ $((n % 2)) = 1 ] && o=landscape
  A shell input keyevent 62
  frame_ok baddriver "$n" "$o" gles
done

echo "== 3. RNI_FORCE_VULKAN_INIT_FAIL=1 -> gles =="
launch --es RNI_FORCE_VULKAN_INIT_FAIL 1
D="$(decision)" || fail "init failure: $D"
echo "   $D"
[ "$(field "$D" forced_init_fail)" = 1 ] || fail "hook RNI_FORCE_VULKAN_INIT_FAIL not honoured (forced_init_fail=$(field "$D" forced_init_fail))"
[ "$(field "$D" android_backend)" = gles ] \
  || fail "forced Vulkan init failure: android_backend=$(field "$D" android_backend) reason=$(field "$D" reason), expected gles"
[ "$(field "$D" reason)" = vulkan_init_failed ] || fail "forced Vulkan init failure: reason=$(field "$D" reason)"
frame_ok initfail 0 portrait gles

echo "ANDROID_BACKEND_PASS normal=vulkan bad_driver=gles(+$CYCLES rotations) init_fail=gles $(tail -1 "$W/unit.log" | sed 's/ANDROID_BACKEND_UNIT_PASS //') device=$MODEL"
