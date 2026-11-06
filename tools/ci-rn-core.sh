#!/usr/bin/env bash
# RN-core gate.
# Node-free: committed prebuilt bundle fixtures/rn-core (+ its prebuilt/assets),
# RNI_BIN = engine binary, so the Mac runs it as-is. Stdlib python3 only.
#
#   ARMS=image  row 2: a require()d PNG paints. Natural 120x168 box, the rn-core
#               card-back shape (stretch, width/height '100%'), and a 200x100
#               box at resizeMode stretch / cover / contain, each checked by
#               fixed sample points (tools/rn_core_check.py image). cover vs
#               contain crops must differ. NEGATIVE: the same bundle with its
#               assets/ dir absent must fire onError and FAIL the pixel rules.
#   ARMS=ws     row 4: global WebSocket open -> send -> onmessage echo -> close
#               against tools/ws_echo_server.py on 127.0.0.1. NEGATIVE: no server
#               -> close code 1006, no message.
#   ARMS=anim   row 6: Animated.timing opacity 0 -> 1 over 300 ms, JS driver.
#               Windowed (frames advance on the wall clock); shots at 0/150/300 ms
#               after first present must show strictly increasing box opacity.
#   ARMS=blur   row 5, filter style: filter: [{blur: 6}] over a hard black|white edge,
#               at supersample 0 and 4: the edge softens (max step / 4, >= 6 px ramp,
#               >= 10 levels) while the flat interiors stay put. The OFF run must be a
#               hard edge (instrument check). expo-blur BlurView: tools/ci-backdrop.sh.
#   ARMS=video  row 3: a local H.264 MP4 in <VideoView> (package/src/video). Rate
#               1.0 and 2.0 advance ~30 and ~60 frames in 1 s (and 2.0 ~ 2x 1.0);
#               pause holds the frame; a paused seek to 4.5 s / 9.0 s paints frames
#               135 / 270. Frame numbers are read from capture PIXELS. NEGATIVES: a
#               frozen picture fails the rate rule, the wrong seek frame fails, and
#               a missing file errors. linux only until the darwin backend (slice 2).
# Default ARMS="image ws anim blur", plus video on linux.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FIX="$ROOT/fixtures/rn-core/prebuilt"
BUNDLE="$FIX/rn-core.bundle"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
CHK="$ROOT/tools/rn_core_check.py"
FF8="${RNI_FFMPEG8_LIB:-$ROOT/engine/third_party/ffmpeg8-linux-x64/lib}"  # video row on a dev host; the board has ffmpeg 8 system-wide (as ci-memory-trim.sh)
. "$ROOT/tools/lib/qemu-timing.sh"
DEFAULT_ARMS="image ws anim blur"
[ "$(uname -s)" = Linux ] && DEFAULT_ARMS="$DEFAULT_ARMS video"
ARMS="${ARMS:-$DEFAULT_ARMS}"
fail() { echo "RN_CORE_FAIL: $*" >&2; exit 1; }
[ -x "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
[ -s "$FIX/assets/card.png" ] || fail "no prebuilt asset $FIX/assets/card.png"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rn-core.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  if [ -n "${KEEP_WORKDIR:-}" ]; then echo "kept $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# headless <tag> <bundle> <url>: 400x300 @1x, log + ppm in $WORK. EXTRA=(...) appends flags.
EXTRA=()
headless() {
  local tag="$1" bundle="$2" url="$3"
  set +e
  ( cd "$(dirname "$BIN")" && "$BIN" --headless --probe-banner off --bundle "$bundle" \
      --app-name RnCore --width 400 --height 300 --scale 1 --supersample-rnsvg "${SS:-0}" \
      --initial-url "$url" --screenshot "$WORK/$tag.ppm" ${EXTRA[@]+"${EXTRA[@]}"} ) > "$WORK/$tag.log" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -q 'scene_nodes=[1-9]' "$WORK/$tag.log" || fail "$tag: nothing mounted (scene_nodes=0)"
  grep -q "supersample_rnsvg=${SS:-0}" "$WORK/$tag.log" || fail "$tag: supersample flag not applied"
  return 0
}

# win_run <tag> <url> [extra engine args...]: one windowed run (frames advance on
# the wall clock), log in $WORK/<tag>.log, RNViewShot captures in $WORK/<tag>-tmp.
# linux: private xvfb. darwin: --window-hidden (never on screen) outside the
# launchd QoS clamp (darwin-run-interactive.sh), no --screenshot flag.
win_run() {
  local tag="$1" url="$2" rc=0; shift 2
  mkdir -p "$WORK/$tag-tmp"
  local args=(--probe-banner off --bundle "$BUNDLE" --app-name RnCore --width 400 --height 300
              --scale 1 --supersample-rnsvg 0 --idle-skip --idle-run-sec "${IDLE_SEC:-3}" --initial-url "$url" "$@")
  if [ "$(uname -s)" = Darwin ]; then
    ( cd "$(dirname "$BIN")" && TMPDIR="$WORK/$tag-tmp" /bin/zsh "$ROOT/tools/darwin-run-interactive.sh" \
        "$WORK/$tag.log" 40 -- "$BIN" --window-hidden "${args[@]}" ) > "$WORK/$tag.outer" 2>&1 || rc=$?
  else
    ( cd "$(dirname "$BIN")" && TMPDIR="$WORK/$tag-tmp" LD_LIBRARY_PATH="$FF8${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" xvfb-run -a -f "$WORK/$tag.xauth" \
        -s "-screen 0 1280x1024x24" "$BIN" --window "${args[@]}" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  fi
  [ "$rc" -eq 0 ] || { tail -15 "$WORK/$tag.log" "$WORK/$tag.outer" 2>/dev/null >&2; fail "$tag: engine exited $rc"; }
  grep -q 'supersample_rnsvg=0' "$WORK/$tag.log" || fail "$tag: supersample flag not applied"
}

arm_image() {
  echo "== row 2: require()d PNG =="
  for m in stretch cover contain; do
    headless "img-$m" "$BUNDLE" "rncore://image?mode=$m"
    grep -m1 'RNCORE_IMAGE source' "$WORK/img-$m.log" || true
    local loads; loads="$(grep -c 'RNCORE_IMAGE onLoad' "$WORK/img-$m.log" || true)"
    [ "$loads" -eq 3 ] || { grep 'RNCORE_IMAGE' "$WORK/img-$m.log" >&2; fail "image $m: want 3 onLoad (natural, $m, percent), got $loads"; }
    python3 "$CHK" image "$WORK/img-$m.ppm" "$m" || fail "image $m: pixel rules"
  done
  python3 "$CHK" differ "$WORK/img-cover.ppm" "$WORK/img-contain.ppm" || fail "cover == contain"
  echo "-- negative: same bundle, no assets/ beside it --"
  mkdir -p "$WORK/noassets"
  cp "$BUNDLE" "$WORK/noassets/rn-core.bundle"
  headless img-noassets "$WORK/noassets/rn-core.bundle" "rncore://image?mode=cover"
  grep -q 'RNCORE_IMAGE onError' "$WORK/img-noassets.log" || fail "negative: missing asset fired no onError"
  grep -m1 'RNCORE_IMAGE onError' "$WORK/img-noassets.log"
  if python3 "$CHK" image "$WORK/img-noassets.ppm" cover > "$WORK/img-noassets.check" 2>&1; then
    fail "negative: pixel rules PASSED with the PNG missing (instrument is blind)"
  fi
  echo "  ok  missing PNG fails the pixel rules ($(grep -c BAD "$WORK/img-noassets.check") bad samples)"
  echo "RNCORE_IMAGE_PASS"
}

arm_ws() {
  echo "== row 4: global WebSocket echo =="
  rm -f "$WORK/port"
  python3 "$ROOT/tools/ws_echo_server.py" "$WORK/port" > "$WORK/ws-server.log" 2>&1 &
  SERVER_PID=$!
  local i=0
  while [ ! -s "$WORK/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$WORK/port" ] || fail "ws: echo server did not start"
  local port; port="$(cat "$WORK/port")"
  # A headless run ends once JS is idle, and frames in flight on a socket are not
  # JS work, so step 3000 frames (~1.5 s) to let the burst's echoes come back.
  EXTRA=(--frames 3000)
  headless ws "$BUNDLE" "rncore://ws?port=$port&text=hello-rncore&burst=20"
  grep -E 'RNCORE_WS|websocket' "$WORK/ws.log" | sed 's/^/  /'
  grep -q 'RNCORE_WS typeof=function' "$WORK/ws.log" || fail "ws: global WebSocket is not a function"
  grep -q 'RNCORE_WS open readyState=1' "$WORK/ws.log" || fail "ws: onopen never fired"
  grep -q 'RNCORE_WS message data=hello-rncore$' "$WORK/ws.log" || fail "ws: echo of hello-rncore never reached onmessage"
  grep -q 'RNCORE_WS burst received=20 inOrder=true' "$WORK/ws.log" || fail "ws: 20-frame burst not received in order"
  grep -q 'RNCORE_WS close code=1000' "$WORK/ws.log" || fail "ws: onclose code=1000 never fired"
  # The server side: it saw the client's masked text frame and the 1000 close.
  grep -q 'WS_ECHO recv opcode=1 masked=1 data=hello-rncore' "$WORK/ws-server.log" || fail "ws: server never got the masked text frame"
  grep -q 'WS_ECHO close code=1000' "$WORK/ws-server.log" || fail "ws: server never got close 1000"
  kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
  echo "-- negative: same port, no server --"
  headless ws-noserver "$BUNDLE" "rncore://ws?port=$port&text=hello-rncore"
  grep -E 'RNCORE_WS (open|message|close|error)' "$WORK/ws-noserver.log" | sed 's/^/  /'
  if grep -q 'RNCORE_WS message' "$WORK/ws-noserver.log"; then fail "negative: a message arrived with no server"; fi
  grep -q 'RNCORE_WS close code=1006' "$WORK/ws-noserver.log" || fail "negative: no close 1006 with no server"
  EXTRA=()
  echo "RNCORE_WS_PASS"
}

arm_anim() {
  echo "== row 6: Animated.timing, JS driver =="
  # Windowed (win_run): headless frames wait for JS idle, so a JS-driven
  # animation runs to the end inside one frame there. Shots come from
  # RNViewShot.captureScreen at 0/150/300 ms on the animation's own clock.
  # darwin: RNViewShot needs a GL backend, so the capture runs use --backend gles
  # (ANGLE); a third run on the default Metal backend proves the same animation
  # ticks and finishes there (no capture possible on Metal yet).
  shot_file() {  # tag at -> png path from the shot line's uri
    grep -m1 "RNCORE_ANIM shot at=$2 " "$WORK/$1.log" | sed -n 's/.* uri=file:\/\///p'
  }
  local gl=()
  [ "$(uname -s)" = Darwin ] && gl=(--backend gles)
  # qemu-aarch64 (M3 triage, docs/IMAGE-REQUIREMENTS.md): the first present lands after
  # a 500 ms-delayed 300 ms animation, and the main loop runs ~4 frames/s, so
  # start after the first present and scale the animation + shots by K. Rules unchanged.
  local am=300 ash="0,150,300" q="" idle_saved="${IDLE_SEC:-}"
  if rni_is_qemu; then
    local k="${RNI_QEMU_CLOCK_SCALE:-20}"
    am=$((300 * k)); ash="0,$((150 * k)),$((300 * k))"
    q="&delay=${RNI_QEMU_ANIM_DELAY_MS:-6000}"; IDLE_SEC="${RNI_QEMU_ANIM_IDLE_SEC:-$(( (am + 6000) / 1000 + 20 ))}"
    rni_qemu_relax "rn-core anim x$k: ${am} ms with shots at $ash, started ${RNI_QEMU_ANIM_DELAY_MS:-6000} ms after mount (after the first present); idle-run ${IDLE_SEC} s"
  fi
  win_run anim "rncore://anim?ms=$am&shots=$ash$q" ${gl[@]+"${gl[@]}"}
  grep -E 'RNCORE_ANIM (start|shot|done)' "$WORK/anim.log" | sed 's/^/  /'
  if rni_is_qemu; then
    local lp ls  # the relaxation only counts if the animation started after the first present
    lp="$(grep -n -m1 'first_present_ms=' "$WORK/anim.log" | cut -d: -f1)"
    ls="$(grep -n -m1 'RNCORE_ANIM start' "$WORK/anim.log" | cut -d: -f1)"
    [ -n "$lp" ] && [ -n "$ls" ] && [ "$lp" -lt "$ls" ] ||
      fail "anim (qemu): the animation started before the first present (log lines ${ls:-none} vs ${lp:-none}); raise RNI_QEMU_ANIM_DELAY_MS"
  fi
  if grep -q 'RNCORE_ANIM shot .*ERROR' "$WORK/anim.log"; then fail "anim: a capture failed"; fi
  grep -q 'RNCORE_ANIM done finished=true' "$WORK/anim.log" || fail "anim: timing never finished"
  local ticks; ticks="$(grep -c 'RNCORE_ANIM tick' "$WORK/anim.log" || true)"
  echo "  Animated value updates during the 300 ms: $ticks"
  [ "$ticks" -ge 10 ] || fail "anim: only $ticks value updates (not frame by frame)"
  local a b c
  a="$(shot_file anim "${ash%%,*}")"; b="$(shot_file anim "$(cut -d, -f2 <<< "$ash")")"; c="$(shot_file anim "${ash##*,}")"
  [ -s "$a" ] && [ -s "$b" ] && [ -s "$c" ] || fail "anim: missing capture file(s): '$a' '$b' '$c'"
  python3 "$CHK" anim "$a" "$b" "$c" || fail "anim: opacity/translateX not increasing across 0/150/300 ms"
  IDLE_SEC="$idle_saved"
  echo "-- negative: three captures all at 0 ms must FAIL the increasing rule --"
  win_run anim-flat "rncore://anim?ms=300&shots=0" ${gl[@]+"${gl[@]}"}
  local f; f="$(shot_file anim-flat 0)"
  [ -s "$f" ] || fail "negative: no capture"
  if python3 "$CHK" anim "$f" "$f" "$f" > "$WORK/anim-flat.check" 2>&1; then
    fail "negative: identical frames PASSED the increasing rule (instrument is blind)"
  fi
  echo "  ok  identical frames fail: $(tail -1 "$WORK/anim-flat.check")"
  if [ "$(uname -s)" = Darwin ]; then
    echo "-- darwin default backend (Metal): same animation, no capture --"
    win_run anim-metal "rncore://anim?ms=300&shots=0"
    grep -q 'RNCORE_ANIM done finished=true' "$WORK/anim-metal.log" || fail "metal: timing never finished"
    local mt; mt="$(grep -c 'RNCORE_ANIM tick' "$WORK/anim-metal.log" || true)"
    echo "  metal: Animated value updates $mt, $(grep -m1 -o 'backend_select backend=[a-z]*' "$WORK/anim-metal.log" || echo 'backend line absent')"
    [ "$mt" -ge 10 ] || fail "metal: only $mt value updates"
  fi
  echo "RNCORE_ANIM_PASS"
}

arm_blur() {
  echo "== row 5: blur =="
  echo "-- filter style: filter: [{blur: 6}] over a hard black|white edge --"
  local ss
  for ss in 0 4; do
    EXTRA=(); SS=$ss
    headless "blur-off-$ss" "$BUNDLE" "rncore://blur?on=0"
    headless "blur-on-$ss" "$BUNDLE" "rncore://blur?on=1"
    echo "  supersample $ss:"
    python3 "$CHK" blurfilter "$WORK/blur-on-$ss.ppm" "$WORK/blur-off-$ss.ppm" || fail "blur filter (supersample $ss)"
  done
  # Negative: an engine that ignored `filter` would paint ON == OFF; that must fail.
  if python3 "$CHK" blurfilter "$WORK/blur-off-0.ppm" "$WORK/blur-off-0.ppm" > "$WORK/blur-neg.check" 2>&1; then
    fail "negative: an unblurred frame PASSED as blurred (instrument is blind)"
  fi
  echo "  ok  unblurred frame as ON fails: $(tail -1 "$WORK/blur-neg.check")"
  SS=0
  echo "RNCORE_BLUR_PASS (filter style; expo-blur BlurView = tools/ci-backdrop.sh)"
}

arm_video() {
  echo "== row 3: video, local H.264 MP4 (fixtures/rn-core/route.mp4) =="
  # Frame k of route.mp4 paints k as 9 bit blocks (tools/build-rn-core-video.sh), so
  # every check reads the frame number from the PIXELS of an RNViewShot capture,
  # never from the player's reported currentTime.
  if [ "$(uname -s)" = Darwin ]; then
    fail "video: the darwin backend (AVFoundation, slice 2) is not written yet; this build has backend none"
  fi
  local src="$ROOT/fixtures/rn-core/route.mp4"
  [ -s "$src" ] || fail "video: no test video at $src (tools/build-rn-core-video.sh)"
  vshot() {  # run-tag shot-tag -> png path from the shot line's uri
    grep -m1 "RNCORE_VIDEO shot tag=$2 " "$WORK/$1.log" | sed -n 's/.* uri=file:\/\///p'
  }
  vrun() {  # tag query: one windowed run of rncore://video, then sanity on its log
    win_run "$1" "rncore://video?src=$src&$2"
    grep -E 'RNCORE_VIDEO|video id=' "$WORK/$1.log" | sed 's/^/  /' || true  # none: the ready-line check below says why
    if grep -qE 'RNCORE_VIDEO (.*ERROR|error)' "$WORK/$1.log"; then fail "video $1: player or capture error"; fi
    grep -q 'RNCORE_VIDEO ready backend=ffmpeg w=320 h=180 duration=12.000' "$WORK/$1.log" ||
      fail "video $1: no ffmpeg ready line (no ffmpeg 8 at $FF8 and no ffmpeg 6 copy from tools/ffmpeg-dev-fetch.sh?)"
  }
  vcheck() {  # name check-args...: run one pixel check, keep + print its output
    local out="$WORK/$1.check" rc=0; shift
    python3 "$CHK" "$@" > "$out" 2>&1 || rc=$?
    cat "$out"
    return "$rc"
  }
  local adv1 adv2
  echo "-- play at rate 1.0 and 2.0: shots 1000 ms apart --"
  vrun vid-r1 "mode=play&rate=1&start=500&gap=1000"
  vcheck vid-r1 video 1 "$(vshot vid-r1 A)" "$(vshot vid-r1 B)" 1000 || fail "video rate 1.0: frames did not advance ~30 in 1 s"
  vrun vid-r2 "mode=play&rate=2&start=500&gap=1000"
  vcheck vid-r2 video 2 "$(vshot vid-r2 A)" "$(vshot vid-r2 B)" 1000 || fail "video rate 2.0: frames did not advance ~60 in 1 s"
  adv1="$(sed -n 's/.*advanced=\([0-9-]*\).*/\1/p' "$WORK/vid-r1.check")"
  adv2="$(sed -n 's/.*advanced=\([0-9-]*\).*/\1/p' "$WORK/vid-r2.check")"
  echo "  rate 2.0 / rate 1.0 advance: $adv2 / $adv1"
  [ "$adv1" -gt 0 ] && [ $((adv2 * 10)) -ge $((adv1 * 16)) ] && [ $((adv2 * 10)) -le $((adv1 * 24)) ] ||
    fail "video: rate 2.0 advanced $adv2 vs $adv1 at 1.0 (want 1.6x..2.4x)"
  echo "-- pause: play, pause 50 ms before shot A, shot B 800 ms later must be the same frame --"
  vrun vid-pause "mode=pause&rate=1&start=600&gap=800"
  grep -q 'RNCORE_VIDEO shot tag=B .* playing=false' "$WORK/vid-pause.log" || fail "video pause: player still reports playing"
  vcheck vid-pause video 0 "$(vshot vid-pause A)" "$(vshot vid-pause B)" 800 || fail "video pause: the picture kept moving"
  local ka; ka="$(sed -n 's/.*frame A=\([0-9]*\).*/\1/p' "$WORK/vid-pause.check")"
  [ "$ka" -ge 10 ] || fail "video pause: shot A is frame $ka, so it never played before the pause"
  echo "-- seek (paused): currentTime = 4.5 and 9.0 must PAINT frames 135 and 270 --"
  local s
  for s in 4.5 9.0; do
    vrun "vid-seek-$s" "mode=seek&seek=$s"
    vcheck "vid-seek-$s" videoseek "$(vshot "vid-seek-$s" S)" "$s" || fail "video seek $s: wrong frame painted"
  done
  echo "-- negatives --"
  if python3 "$CHK" video 1 "$(vshot vid-r1 A)" "$(vshot vid-r1 A)" 1000 > "$WORK/vid-neg1.check" 2>&1; then
    fail "negative: a frozen picture PASSED the rate 1.0 rule (instrument is blind)"
  fi
  echo "  ok  frozen picture fails rate 1.0: $(tail -1 "$WORK/vid-neg1.check")"
  if python3 "$CHK" videoseek "$(vshot vid-seek-4.5 S)" 9.0 > "$WORK/vid-neg2.check" 2>&1; then
    fail "negative: the 4.5 s frame PASSED as the 9.0 s seek (instrument is blind)"
  fi
  echo "  ok  wrong seek frame fails: $(tail -1 "$WORK/vid-neg2.check")"
  win_run vid-missing "rncore://video?src=$WORK/no-such.mp4&mode=play"
  grep -q 'RNCORE_VIDEO error could not open' "$WORK/vid-missing.log" || fail "negative: a missing file gave no error"
  if grep -qE 'RNCORE_VIDEO (ready|shot)' "$WORK/vid-missing.log"; then fail "negative: a missing file became ready"; fi
  echo "  ok  missing file: $(grep -m1 -o 'RNCORE_VIDEO error.*' "$WORK/vid-missing.log")"
  echo "RNCORE_VIDEO_PASS"
}

for a in $ARMS; do
  case "$a" in
    image) arm_image ;;
    ws) arm_ws ;;
    anim) arm_anim ;;
    blur) arm_blur ;;
    video) arm_video ;;
    *) fail "unknown arm $a" ;;
  esac
done
echo "RN_CORE_PASS arms=\"$ARMS\" bin=$BIN"
