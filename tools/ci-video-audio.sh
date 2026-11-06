#!/usr/bin/env bash
# ImpellerVideo sound (the board drop 2): AAC decoded, resampled to S16 stereo
# 48 kHz and written to ALSA (libasound.so.2 dlopen'd), following the video
# clock; muted while the rate is not 1; and when there is no sound (no
# libasound, no playback device, device lost mid-play) the error is in
# stats.audio and the VIDEO keeps playing at full rate.
# Windowed runs (xvfb) of fixtures/video-audio on the linux-x64 engine, ffmpeg
# 8.0.1 first on LD_LIBRARY_PATH, HLS H.264 + AAC from tools/video_net_server.py.
#
#   bash tools/ci-video-audio.sh [--arms "TONE SYNC LOST HANG HANGREL NODEV NOLIB"]
#
# WSL has no sound card and no snd-aloop, so two stand-ins for a card:
#   alsa-lib's own `file` plugin (ALSA_CONFIG_PATH: pcm.default = file -> raw,
#     slave null). The REAL libasound.so.2 runs; it keeps no clock (never blocks).
#   tools/alsa-paced/alsa_paced.c: a stand-in libasound.so.2 that plays like
#     hardware (a 200 ms ring drained at 48 kHz on a monotonic clock) and records
#     what is HEARD, silence included, so capture frame k = wall t0 + k/48000.
#
# Arms:
#   TONE  real alsa-lib, file plugin: ci-video-net's 440 Hz HLS (v360) plays 8 s.
#         The capture is 8 s long (-0.5/+0.3), its FFT peak is 440 Hz +-3,
#         audioFrames agrees, stats.audio "on"
#   SYNC  paced device, the marker HLS (440 Hz with a gap at each whole second;
#         the gap length codes the second mod 4): rate 1 to 6 s, 0.6 to 10 s,
#         1 to 13 s, paused 13-15 s, 1 to 18 s. Every gap heard at rate 1 is
#         within 100 ms of the video clock (gap times from the ffmpeg CLI's own
#         decode of the same media); silent while 0.6 and while paused, sound
#         back within 0.3 s after each; stats.audio "muted" at 0.6; no drops
#   LOST  paced device that fails every write from 5 s (ENODEV, an unplug):
#         stats.audio "error: ALSA write on default: No such device", and the
#         video plays the full 15 s (clock ~15, framesDropped <= 1%)
#   HANG  paced device that stops consuming at 5 s (a blocking write would sit
#         12 s, then -EIO, like the kernel's DMA timeout): the video never waits
#         on the sound queue (22 s, clock ~22, no drops), and the sink reports
#         "error: ALSA device 'default' took no samples for 4 s"
#   HANGREL the same device stops at 3 s; release() at 5 s returns in < 1 s
#         (the sound thread is joined there, on the JS thread)
#   NODEV real alsa-lib, pcm.default = hw card 7 (no such card): "error: ALSA
#         device 'default' does not open: No such file or directory"; 20 s of video
#   NOLIB libasound.so.2 hidden from the loader (a private mount namespace binds
#         /dev/null over it; a ctypes load in the same namespace must fail first):
#         "error: no ALSA library: libasound.so.2 does not load (...)"; 20 s of video
# Mutants: tools/mutation-verify-video-audio.sh. Engine: RNI_VAUD_ENGINE_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARMS="TONE SYNC LOST HANG HANGREL NODEV NOLIB"
while [ $# -gt 0 ]; do
  case "$1" in
    --arms) ARMS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
PKG="${RNI_VAUD_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-x64/bin}"
FF="$ROOT/engine/third_party/ffmpeg8-linux-x64-tls/lib"
BUNDLE="$ROOT/fixtures/video-audio/prebuilt/video-audio.bundle"
CHK=(python3 "$ROOT/tools/video_audio_check.py")
NETMEDIA="${RNI_VNET_MEDIA:-$HOME/.cache/rni/video-net/media}"
MARK="${RNI_VAUD_MEDIA:-$HOME/.cache/rni/video-audio/media}/mark"
fail() { echo "VIDEO_AUDIO_FAIL: $*" >&2; exit 1; }
ok() { echo "   ok  $*"; }
[ -x "$PKG/rn-impeller" ] || fail "no engine at $PKG"
[ -e "$FF/libswresample.so.6" ] || fail "no ffmpeg 8 (with libswresample) at $FF (bash tools/ffmpeg8-fetch.sh --arch x64 --tls)"
[ -s "$BUNDLE" ] || fail "no bundle $BUNDLE (bash tools/build-fixture-bundle.sh video-audio VideoAudio)"
command -v ffmpeg > /dev/null || fail "no ffmpeg CLI (the test media and the reference decode)"
LIBASOUND="$(readlink -f "$(ldconfig -p | awk '/libasound\.so\.2 .*x86-64/ {print $NF; exit}')")"
[ -f "$LIBASOUND" ] || fail "the host has no libasound.so.2 (apt install libasound2t64): TONE/NODEV need the real one"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-video-audio.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  if [ -n "${KEEP_WORKDIR:-}" ]; then echo "kept $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- media (cached) ---
media() {
  local v="$NETMEDIA/hls/v360"
  if [ ! -s "$v/vod.m3u8" ]; then  # the same command as ci-video-net.sh's media()
    echo "== media: ci-video-net HLS 640x360, H.264 + AAC 440 Hz, 80 s =="
    mkdir -p "$v"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30" -f lavfi -i sine=f=440:r=48000 \
      -t 80 -c:v libx264 -preset veryfast -bf 2 -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p \
      -c:a aac -b:a 96k -ac 2 -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
      -hls_segment_filename "$v/seg%05d.ts" "$v/vod.m3u8"
  fi
  if [ ! -s "$MARK/vod.m3u8" ]; then
    echo "== media: marker HLS 640x360, 440 Hz with a (50 + 25 * (s mod 4)) ms gap at each second s, 40 s =="
    mkdir -p "$MARK"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30" \
      -f lavfi -i "sine=f=440:r=48000:samples_per_frame=48,volume='if(lt(mod(t,1),0.05+0.025*mod(floor(t),4)),0,1)':eval=frame" \
      -t 40 -c:v libx264 -preset veryfast -bf 2 -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p \
      -c:a aac -b:a 96k -ac 2 -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
      -hls_segment_filename "$MARK/seg%05d.ts" "$MARK/vod.m3u8"
  fi
}

# --- server, devices ---
WWW="$WORK/www"; mkdir -p "$WWW"
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
serve() {
  local i
  P="$(port)"
  ln -s "$MARK" "$WWW/mark"
  python3 "$ROOT/tools/video_net_server.py" --root "$WWW" --port "$P" --log "$WORK/srv.jsonl" --live "$NETMEDIA/hls" \
    > "$WORK/srv.out" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 50); do grep -q '^READY' "$WORK/srv.out" && break; sleep 0.1; done
  grep -q "^READY port=$P" "$WORK/srv.out" || { cat "$WORK/srv.out" >&2; fail "server did not start"; }
}
PACED="$WORK/paced"
paced_lib() {
  mkdir -p "$PACED"
  cc -shared -fPIC -O2 -Wl,-soname,libasound.so.2 -o "$PACED/libasound.so.2" "$ROOT/tools/alsa-paced/alsa_paced.c" \
    -lpthread || fail "could not build the paced test device"
}
alsa_conf() {  # <name> <pcm.default body>
  printf 'pcm.!default {\n%s\n}\n' "$2" > "$WORK/$1.conf"
  echo "$WORK/$1.conf"
}

# run <tag> <src uri> <extra query> <idle sec> <lib path> [prefix cmd...] -- [env...]
run() {
  local tag="$1" src="$2" extra="$3" idle="$4" lib="$5" rc=0 url pre=()
  shift 5
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do pre+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  url="vaud://play?src=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$src")$extra"
  ( cd / && ${pre[@]+"${pre[@]}"} env LD_LIBRARY_PATH="$lib" RNI_VIDEO_LOG=0 "$@" \
      xvfb-run -a -f "$WORK/$tag.xauth" -s "-screen 0 1280x1024x24" \
      "$PKG/rn-impeller" --window --probe-banner off --prewarm off --bundle "$BUNDLE" --app-name VideoAudio \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --idle-skip --idle-run-sec "$idle" \
      --initial-url "$url" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -E 'VAUD (ready|error|create_error|done|rate|pause|play)|video id=[0-9]+ (open|error|audio)' "$WORK/$tag.log" \
    | cut -c1-200 | sed 's/^/     /'
}
check() { "${CHK[@]}" "$@" | sed 's/^ok /   ok  /' || fail "$(tail -1 <<< "$("${CHK[@]}" "$@" 2>&1)")"; }

arm_tone() {
  echo "== TONE: real alsa-lib, pcm.default = file plugin; ci-video-net's 440 Hz HLS, 8 s =="
  local conf; conf="$(alsa_conf tone "  type file
  slave.pcm { type null }
  file \"$WORK/tone.raw\"
  format \"raw\"")"
  run tone "http://127.0.0.1:$P/live/v360/vod.m3u8" "&secs=8" 11 "$FF" -- ALSA_CONFIG_PATH="$conf"
  grep -q 'video id=1 audio open aac 48000 Hz 2 ch device=default' "$WORK/tone.log" || fail "TONE: no 'audio open aac' line"
  [ -s "$WORK/tone.raw" ] || fail "TONE: alsa-lib's file plugin captured nothing"
  check tone "$WORK/tone.raw" --log "$WORK/tone.log" --secs 8
}

arm_sync() {
  echo "== SYNC: paced device, marker HLS; rate 0.6 at 6-10 s, paused 13-15 s, 18 s =="
  local sa sv
  sa="$(ffprobe -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$MARK/seg00000.ts" | head -1)"
  sv="$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$MARK/seg00000.ts" | head -1)"
  ffmpeg -hide_banner -loglevel error -y -i "$MARK/vod.m3u8" -vn -f s16le -ac 2 -ar 48000 "$WORK/ref.raw"
  check ref "$WORK/ref.raw" --start-a "$sa" --start-v "$sv" -o "$WORK/ref.json"
  run sync "http://127.0.0.1:$P/mark/vod.m3u8" "&secs=18&rates=0.6@6,1@10&pauseAt=13&playAt=15" 21 "$PACED:$FF" \
    -- RNI_PACED_OUT="$WORK/sync.pcm"
  [ -s "$WORK/sync.pcm.t0" ] || fail "SYNC: the paced device was never opened"
  check sync "$WORK/sync.pcm" --log "$WORK/sync.log" --ref "$WORK/ref.json"
}

arm_lost() {
  echo "== LOST: paced device fails every write from 5 s (ENODEV); 15 s of video =="
  run lost "http://127.0.0.1:$P/mark/vod.m3u8" "&secs=15" 18 "$PACED:$FF" \
    -- RNI_PACED_OUT="$WORK/lost.pcm" RNI_PACED_LOSE_SEC=5
  check noaudio "$WORK/lost.log" --want "ALSA write on default: No such device" --secs 15 --was-on 20
}

arm_hang() {
  echo "== HANG: paced device stops consuming at 5 s; 22 s of video =="
  run hang "http://127.0.0.1:$P/mark/vod.m3u8" "&secs=22" 25 "$PACED:$FF" \
    -- RNI_PACED_OUT="$WORK/hang.pcm" RNI_PACED_HANG_SEC=5 RNI_PACED_HANG_FOR=12
  check noaudio "$WORK/hang.log" --want "ALSA device 'default' took no samples for 4 s" --secs 22 --was-on 20
}

arm_hangrel() {
  echo "== HANGREL: paced device stops consuming at 3 s; release() at 5 s =="
  run hangrel "http://127.0.0.1:$P/mark/vod.m3u8" "&secs=8&releaseAt=5" 9 "$PACED:$FF" \
    -- RNI_PACED_OUT="$WORK/hangrel.pcm" RNI_PACED_HANG_SEC=3 RNI_PACED_HANG_FOR=12
  local took; took="$(sed -n 's/.*VAUD released at=5 took=\([0-9]*\).*/\1/p' "$WORK/hangrel.log" | head -1)"
  [ -n "$took" ] || fail "HANGREL: no released line"
  [ "$took" -lt 1000 ] || fail "HANGREL: release() took $took ms with the sound device stuck (want < 1000)"
  grep -q 'video id=1 audio open' "$WORK/hangrel.log" || fail "HANGREL: sound never opened (the arm proves nothing)"
  ok "HANGREL: release() returned in $took ms with the sound device stuck"
}

arm_nodev() {
  echo "== NODEV: real alsa-lib, pcm.default = hw card 7 (no such card); 20 s of video =="
  local conf; conf="$(alsa_conf nodev "  type hw
  card 7
  device 0")"
  run nodev "http://127.0.0.1:$P/live/v360/vod.m3u8" "&secs=20" 23 "$FF" -- ALSA_CONFIG_PATH="$conf"
  check noaudio "$WORK/nodev.log" --want "ALSA device 'default' does not open: No such file or directory" --secs 20
}

arm_nolib() {
  echo "== NOLIB: libasound.so.2 hidden from the loader ($LIBASOUND -> /dev/null, private mount namespace); 20 s =="
  local hide=(unshare -rm sh -c 'mount --bind /dev/null "$0" && exec "$@"' "$LIBASOUND")
  # The instrument first: in the same namespace, the loader must NOT find it.
  if "${hide[@]}" python3 -c 'import ctypes; ctypes.CDLL("libasound.so.2")' 2> /dev/null; then
    fail "NOLIB control: libasound.so.2 still loads inside the namespace"
  fi
  python3 -c 'import ctypes; ctypes.CDLL("libasound.so.2")' || fail "NOLIB control: libasound.so.2 does not load OUTSIDE the namespace"
  ok "control: libasound.so.2 loads outside the namespace and not inside it"
  run nolib "http://127.0.0.1:$P/live/v360/vod.m3u8" "&secs=20" 23 "$FF" "${hide[@]}" --
  check noaudio "$WORK/nolib.log" --want "no ALSA library: libasound.so.2 does not load" --secs 20
}

media
serve
paced_lib
for a in $ARMS; do
  case "$a" in
    TONE) arm_tone ;; SYNC) arm_sync ;; LOST) arm_lost ;; HANG) arm_hang ;; HANGREL) arm_hangrel ;; NODEV) arm_nodev ;; NOLIB) arm_nolib ;;
    *) fail "unknown arm $a" ;;
  esac
done
echo "VIDEO_AUDIO_PASS arms=\"$ARMS\" engine=$(sha256sum "$PKG/rn-impeller" | cut -c1-16) alsa-lib=$(basename "$LIBASOUND") ffmpeg=$(cut -d' ' -f1-3 "$FF/../BUILD-INFO" | head -1)"
