#!/usr/bin/env bash
# FP-24 gate: the Android Vulkan swapchain follows its ANativeWindow through 20
# rotations (each one resizes the SAME window: the probe declares configChanges),
# and every cycle presents a correct, non-black frame.
# Model: impeller/renderer/backend/vulkan/swapchain/khr/khr_swapchain_vk.cc
# L48-L116 (recreate on out-of-date / size mismatch, bounded retries) and
# shell/platform/android/android_surface_vk_impeller.cc OnScreenSurfaceResize
# (Android pushes the window size out of band).
#   1. builds + installs the probe APK (tools/android-swapchain-probe-build.sh),
#      a NativeActivity around the real engine/host/AndroidVkSurface.cpp
#   2. per cycle: KEYCODE_SPACE -> the probe calls setRequestedOrientation; the
#      gate waits for `probe_ready cycle=N` whose window has the new orientation
#      AND whose drawable (ImpellerSurfaceGetSize, read back) equals the window
#   3. screencap: the frame is this cycle's background colour (a frozen frame
#      shows the previous one) with a 300x300 px white square (a swapchain left at
#      a stale size is scaled by the compositor and the square is not 300x300)
# Device: RNI_ANDROID_SERIAL, else the attached SM-G991U1 (S21) or an emulator.
# Only the probe app is touched (it rotates itself; no OS setting is changed).
# Env: RNI_FP24_CYCLES (20), RNI_FP24_EVIDENCE=<dir> keeps a portrait + landscape png.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PKG=com.reactnativeimpeller.fp24probe
CYCLES="${RNI_FP24_CYCLES:-20}"
WANT_MODEL="${RNI_ANDROID_MODEL:-SM-G991U1}"
fail() { echo "ANDROID_SWAPCHAIN_FAIL: $*" >&2; exit 1; }
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

W="$(mktemp -d)"
cleanup() { A shell am force-stop "$PKG" >/dev/null 2>&1; A uninstall "$PKG" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT

echo "== 1. build + install the probe =="
bash tools/android-swapchain-probe-build.sh "$W/probe.apk" > "$W/build.log" 2>&1 \
  || { tail -8 "$W/build.log" >&2; fail "probe APK did not build"; }
tail -1 "$W/build.log" | sed 's/^/   /'
A install -r -t "$W/probe.apk" > "$W/install.log" 2>&1 || { tail -3 "$W/install.log" >&2; fail "install"; }
[ "$(A shell dumpsys power | grep -o 'mWakefulness=[A-Za-z]*' | head -1)" = "mWakefulness=Awake" ] \
  || A shell input keyevent KEYCODE_WAKEUP
A shell am force-stop "$PKG"
A shell am start -W -n "$PKG/android.app.NativeActivity" > /dev/null || fail "am start"
PID=""
for _ in $(seq 20); do PID="$(A shell pidof "$PKG" | tr -d '\r')"; [ -n "$PID" ] && break; sleep 0.5; done
[ -n "$PID" ] || fail "probe process did not start"

log() { A logcat -d --pid="$PID" -s rn-impeller:I 2>/dev/null | tr -d '\r'; }
# wait_ready N orientation -> echoes the matching probe_ready line
wait_ready() {
  local n="$1" want="$2" line="" w h
  for _ in $(seq 40); do
    while read -r line; do
      [[ "$line" =~ win=([0-9]+)x([0-9]+)\ drawable=([0-9]+)x([0-9]+) ]] || continue
      w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
      [ "${BASH_REMATCH[3]}x${BASH_REMATCH[4]}" = "${w}x${h}" ] || continue
      if { [ "$want" = landscape ] && [ "$w" -gt "$h" ]; } || { [ "$want" = portrait ] && [ "$h" -gt "$w" ]; }; then
        echo "${line#*probe_ready }"; return 0
      fi
    done < <(log | grep "probe_ready cycle=$n ")
    sleep 0.5
  done
  return 1
}
# check_frame png cycle orientation -> "square=WxH bg=r,g,b" or a FAIL reason, rc
check_frame() {
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
    print(f"screen centre is {px[cx, cy]}, not the white square (black/frozen/stale frame)"); sys.exit(1)
def run(x, y, dx, dy):
    k = 0
    while 0 <= x + dx * (k + 1) < W and 0 <= y + dy * (k + 1) < H and white(px[x + dx * (k + 1), y + dy * (k + 1)]): k += 1
    return k
sw = run(cx, cy, -1, 0) + run(cx, cy, 1, 0) + 1
sh = run(cx, cy, 0, -1) + run(cx, cy, 0, 1) + 1
if abs(sw - 300) > 4 or abs(sh - 300) > 4:
    print(f"white square is {sw}x{sh} on screen, expected 300x300 (swapchain size != window size)"); sys.exit(1)
bx = cx - sw // 2 - 60
bg = px[bx, cy]
dist = lambda a, b: max(abs(i - j) for i, j in zip(a, b))
want_bg = PALETTE[n % len(PALETTE)]
if max(bg) < 40:
    print(f"background {bg} is black"); sys.exit(1)
if dist(bg, want_bg) > 40:
    print(f"background {bg} is not cycle {n}'s {want_bg} (prev {PALETTE[(n - 1) % len(PALETTE)]}): frame not updated"); sys.exit(1)
print(f"square={sw}x{sh} bg={bg[0]},{bg[1]},{bg[2]}")
PY
}

echo "== 2. $CYCLES rotations of one live window =="
R0="$(wait_ready 0 portrait)" || fail "cycle 0: no probe_ready in portrait; last: $(log | grep -E 'probe_(ready|stuck)|swapchain' | tail -2 | tr '\n' ' ')"
echo "   cycle 0 portrait $R0"
LAST=""
for n in $(seq 1 "$CYCLES"); do
  orient=portrait; [ $((n % 2)) = 1 ] && orient=landscape
  A shell input keyevent 62
  R="$(wait_ready "$n" "$orient")" \
    || fail "cycle $n ($orient): no presented frame whose drawable matches the window; last: $(log | grep -E "probe_(ready|stuck) cycle=$n |swapchain_" | tail -2 | tr '\n' ' ')"
  ok=""
  for try in 1 2 3; do  # the system rotation animation can still be on screen
    sleep 1
    A exec-out screencap -p > "$W/c$n.png" 2>/dev/null
    V="$(check_frame "$W/c$n.png" "$n" "$orient")" && { ok=1; break; }
  done
  [ -n "$ok" ] || fail "cycle $n ($orient): $V"
  echo "   cycle $n $orient ${R%% presents=*} $V"
  LAST="$R"
  if [ -n "${RNI_FP24_EVIDENCE:-}" ]; then mkdir -p "$RNI_FP24_EVIDENCE"; cp "$W/c$n.png" "$RNI_FP24_EVIDENCE/cycle-$orient.png"; fi
done

[[ "$LAST" =~ resizes=([0-9]+)\ recreates=([0-9]+)\ failures=([0-9]+) ]] || fail "unparsable stats: $LAST"
RES="${BASH_REMATCH[1]}"; REC="${BASH_REMATCH[2]}"; FAILS="${BASH_REMATCH[3]}"
[ "$RES" -ge "$CYCLES" ] || fail "only $RES swapchain resizes for $CYCLES rotations"
[ "$FAILS" = 0 ] || fail "$FAILS acquire failures"
echo "ANDROID_SWAPCHAIN_PASS cycles=$CYCLES resizes=$RES recreates=$REC acquire_failures=$FAILS device=$MODEL"
