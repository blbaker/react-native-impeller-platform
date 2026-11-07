#!/usr/bin/env bash
# ImpellerVideo over the network: http/https MP4 (byte-range seek, signed-URL
# query strings) and HLS (VOD master with variants, live), with TLS verified.
# Windowed runs (xvfb) of fixtures/video-net on the linux-x64 engine, with
# ffmpeg 8.0.1 + openssl (tools/ffmpeg8-fetch.sh --arch x64 --tls) put first
# on LD_LIBRARY_PATH, against tools/video_net_server.py on this host.
#
#   bash tools/ci-video-net.sh [--arms "VA HLS LIVE LAG SLOW THROTTLE E404 FILE TLS STALL"] [--secs N]
#
# Arms (--secs, default 60, is the VA play time; the others are short):
#   VA    http MP4 720p30 with a CloudFront-style query, N s: rate 1, 0.6 at 10 s,
#         1.25 at 20 s, 1 at 30 s, seek(150) at 40 s. framesDropped <= 1%; the
#         clock moves at each rate; the seek shows the decoded frame within 1 s
#         of 150; the server saw the query and a Range request past byte 0; the
#         query value never reaches the engine's log
#   HLS   VOD master with a 640x360 and a 320x180 variant: plays 12 s at 640x360,
#         and the 320x180 variant gets at most 2 segment requests (discard works)
#   LIVE  live playlist (window moves every 2 s, no ENDLIST): plays 16 s, reloads
#   LAG   HLS with 800 ms on every request: read-ahead hides it (clock at 1.0x)
#   SLOW  play() before a 1.5 s open: the clock starts at the first frame (no drops)
#   THROTTLE  the server sends below the bitrate: the clock waits, nothing dropped
#   E404  a 404 with a query: status error "...?<redacted>: Server returned 404 Not Found"
#   FILE  file:// of the same MP4 plays 8 s and seeks (the local path is unchanged)
#   TLS   curl control first; then https with RNI_VIDEO_CA_FILE: good cert plays;
#         a self-signed cert, a wrong-host cert, and an HLS playlist on the good
#         server whose SEGMENTS are on the self-signed server are all refused,
#         with the bad server logging a failed handshake and serving nothing
#   STALL release() of a player whose server never answers returns in < 1 s
# Mutants: tools/mutation-verify-video-net.sh. Engine: RNI_VNET_ENGINE_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARMS="VA HLS LIVE LAG SLOW THROTTLE E404 FILE TLS STALL" SECS=60
while [ $# -gt 0 ]; do
  case "$1" in
    --arms) ARMS="${2:-}"; shift 2 ;;
    --secs) SECS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
PKG="${RNI_VNET_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-x64/bin}"
FF="$ROOT/engine/third_party/ffmpeg8-linux-x64-tls/lib"
BUNDLE="$ROOT/fixtures/video-net/prebuilt/video-net.bundle"
CHK=(python3 "$ROOT/tools/video_net_check.py")
MEDIA="${RNI_VNET_MEDIA:-$HOME/.cache/rni/video-net/media}"
SIG='Kq7~xR-2_vZ'  # the fake signature: it must never show up in an engine log
fail() { echo "VIDEO_NET_FAIL: $*" >&2; exit 1; }
ok() { echo "   ok  $*"; }
[ -x "$PKG/rn-impeller" ] || fail "no engine at $PKG"
[ -e "$FF/libavformat.so.62" ] || fail "no TLS ffmpeg 8 at $FF (bash tools/ffmpeg8-fetch.sh --arch x64 --tls)"
readelf -d "$FF/libavformat.so.62" | grep -q 'libssl.so' || fail "$FF/libavformat.so.62 has no openssl"
command -v ffmpeg > /dev/null || [ -s "$MEDIA/va720.mp4" ] || fail "no ffmpeg CLI to make the test media"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-video-net.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  if [ -n "${KEEP_WORKDIR:-}" ]; then echo "kept $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- media (cached; regenerated when missing) ---
media() {
  mkdir -p "$MEDIA/hls/v360" "$MEDIA/hls/v180"
  if [ ! -s "$MEDIA/va720.mp4" ]; then
    echo "== media: 300 s 720p30 H.264 MP4 (faststart, B-frames, 2 s GOP) =="
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=1280x720:r=30 -t 300 -c:v libx264 \
      -preset veryfast -crf 23 -bf 2 -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p -an \
      -movflags +faststart "$MEDIA/va720.tmp.mp4" && mv "$MEDIA/va720.tmp.mp4" "$MEDIA/va720.mp4"
  fi
  local v h w
  for v in 360:640 180:320; do
    h=${v%%:*}; w=${v##*:}
    [ -s "$MEDIA/hls/v$h/vod.m3u8" ] && continue
    echo "== media: HLS ${w}x$h, H.264 + AAC 440 Hz, 2 s segments, 80 s =="
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=${w}x$h:r=30" -f lavfi -i sine=f=440:r=48000 \
      -t 80 -c:v libx264 -preset veryfast -bf 2 -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p \
      -c:a aac -b:a 96k -ac 2 -f hls -hls_time 2 -hls_list_size 0 -hls_playlist_type vod \
      -hls_segment_filename "$MEDIA/hls/v$h/seg%05d.ts" "$MEDIA/hls/v$h/vod.m3u8"
  done
}

# --- servers ---
WWW="$WORK/www"
mkdir -p "$WWW/NItalyR" "$WWW/mixed"
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
serve() {  # <name> [cert key]: starts a server on a free port; sets P_<name>
  local name="$1" p log="$WORK/srv-$1.jsonl" tls=() i
  [ $# -ge 3 ] && tls=(--cert "$2" --key "$3")
  p="$(port)"
  python3 "$ROOT/tools/video_net_server.py" --root "$WWW" --port "$p" --log "$log" --live "$MEDIA/hls" \
    "${tls[@]}" > "$WORK/srv-$name.out" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 50); do grep -q '^READY' "$WORK/srv-$name.out" && break; sleep 0.1; done
  grep -q "^READY port=$p" "$WORK/srv-$name.out" || { cat "$WORK/srv-$name.out" >&2; fail "server $name did not start"; }
  : > "$log"
  printf -v "P_$name" '%s' "$p"
}

# run <tag> <src uri> <extra query> <idle sec> [env...]: one windowed engine run
run() {
  local tag="$1" src="$2" extra="$3" idle="$4" rc=0 url
  shift 4
  url="vnet://play?src=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$src")$extra"
  ( cd / && env LD_LIBRARY_PATH="$FF" RNI_VIDEO_LOG=0 "$@" xvfb-run -a -f "$WORK/$tag.xauth" -s "-screen 0 1280x1024x24" \
      "$PKG/rn-impeller" --window --probe-banner off --prewarm off --bundle "$BUNDLE" --app-name VideoNet \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --idle-skip --idle-run-sec "$idle" \
      --initial-url "$url" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$tag.log" >&2; fail "$tag: engine exited $rc"; }
  grep -E 'VNET (ready|error|create_error|done|released)|video id=[0-9]+ (open|error|seek)' "$WORK/$tag.log" | cut -c1-220 | sed 's/^/     /'
}
check() { "${CHK[@]}" "$@" | sed 's/^ok /   ok  /' || fail "$(tail -1 <<< "$("${CHK[@]}" "$@" 2>&1)")"; }
no_secret() {  # <tag>: the signed query's value never reaches the engine's own output
  local hits
  hits="$(grep -v 'initial_url' "$WORK/$1.log" | grep -cF "$SIG" || true)"
  [ "$hits" -eq 0 ] || { grep -F "$SIG" "$WORK/$1.log" | head -3 >&2; fail "$1: the signed query value is in the engine log ($hits lines)"; }
  ok "$1: the query value appears in no engine log line"
}

arm_va() {
  echo "== VA: http MP4, signed-style query, ${SECS} s, rates 0.6/1.25, seek(150) =="
  ln -sf "$MEDIA/va720.mp4" "$WWW/NItalyR/JHRN0119.mp4"
  local src="http://127.0.0.1:$P_plain/NItalyR/JHRN0119.mp4?Expires=1793500000&Signature=$SIG&Key-Pair-Id=K2TESTKEY"
  run va "$src" "&secs=$SECS&rates=0.6@10,1.25@20,1@30&seekAt=40&seekTo=150" $((SECS + 8))
  grep -q 'VNET ready .* w=1280 h=720 duration=300' "$WORK/va.log" || fail "VA: not ready as 1280x720, 300 s"
  check play "$WORK/va.log" --secs "$SECS" --max-drop-pct 1 --rates "0.6@10,1.25@20,1@30" --seek-at 40
  check seek "$WORK/va.log" --to 150 --tol 1
  check served "$WORK/srv-plain.jsonl" --path-re '^/NItalyR/JHRN0119\.mp4$' --query --min 1
  check served "$WORK/srv-plain.jsonl" --path-re '^/NItalyR/JHRN0119\.mp4$' --range-past0 --min 1
  no_secret va
}

arm_hls() {
  echo "== HLS: VOD master, 2 variants =="
  printf '%s\n' '#EXTM3U' '#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=640x360' '/live/v360/vod.m3u8' \
    '#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180' '/live/v180/vod.m3u8' > "$WWW/master.m3u8"
  run hls "http://127.0.0.1:$P_plain/master.m3u8" "&secs=12" 18
  grep -q 'VNET ready .* w=640 h=360' "$WORK/hls.log" || fail "HLS: did not pick the 640x360 variant"
  check play "$WORK/hls.log" --secs 12 --max-drop-pct 1
  check served "$WORK/srv-plain.jsonl" --path-re '^/live/v360/seg[0-9]+\.ts$' --status ok --min 6
  check served "$WORK/srv-plain.jsonl" --path-re '^/live/v180/seg[0-9]+\.ts$' --max 2
}

arm_live() {
  echo "== LIVE: sliding playlist, no ENDLIST =="
  run live "http://127.0.0.1:$P_plain/live/v360/index.m3u8" "&secs=16" 22
  grep -q 'VNET ready .* w=640 h=360 duration=0.000' "$WORK/live.log" || fail "LIVE: not ready as a live (duration 0) 640x360 stream"
  check play "$WORK/live.log" --secs 16 --max-drop-pct 1
  check served "$WORK/srv-plain.jsonl" --path-re '^/live/v360/index\.m3u8$' --status ok --min 4
}

arm_e404() {
  echo "== E404: missing file =="
  run e404 "http://127.0.0.1:$P_plain/NItalyR/missing.mp4?Signature=$SIG" "&secs=2" 4
  check error "$WORK/e404.log" --want "could not open http://127.0.0.1:$P_plain/NItalyR/missing.mp4?<redacted>: Server returned 404 Not Found"
  no_secret e404
}

arm_file() {
  echo "== FILE: file:// is unchanged =="
  run file "file://$MEDIA/va720.mp4" "&secs=8&seekAt=4&seekTo=150" 12
  check play "$WORK/file.log" --secs 8 --max-drop-pct 1 --seek-at 4
  check seek "$WORK/file.log" --to 150 --tol 1
  grep -q 'video id=1 source' "$WORK/file.log" && fail "FILE: a local file was treated as a network source"
  ok "FILE: no network source line"
}

certs() {
  local c="$WORK/certs"
  mkdir -p "$c"
  ( cd "$c"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=rni-test-ca" 2>/dev/null
    leaf() {  # <name> <san>: a CA-signed leaf
      openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
      printf 'subjectAltName=%s\n' "$2" > "$1.ext"
      openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -out "$1.pem" -days 2 -extfile "$1.ext" 2>/dev/null
    }
    leaf good "DNS:localhost"
    leaf wrong "DNS:wrong.example"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.pem -days 2 -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost" 2>/dev/null )
}

arm_tls() {
  echo "== TLS: verification is ON for every request =="
  certs
  local c="$WORK/certs" rc
  serve good "$c/good.pem" "$c/good.key"; serve self "$c/self.pem" "$c/self.key"; serve wrong "$c/wrong.pem" "$c/wrong.key"
  ln -sf "$MEDIA/va720.mp4" "$WWW/NItalyR/JHRN0119.mp4"
  # The instrument first: curl (a known-good client) must tell the servers apart.
  curl -sf -o /dev/null --cacert "$c/ca.pem" "https://localhost:$P_good/NItalyR/JHRN0119.mp4" -r 0-99 || fail "TLS control: curl refused the good server"
  for s in self wrong; do
    rc=0; curl -sf -o /dev/null --cacert "$c/ca.pem" "https://localhost:$(eval echo "\$P_$s")/NItalyR/JHRN0119.mp4" -r 0-99 || rc=$?
    [ "$rc" -eq 60 ] || fail "TLS control: curl on the $s server exited $rc, want 60 (cert rejected)"
  done
  ok "control: curl accepts the good server and rejects self/wrong (exit 60)"
  : > "$WORK/srv-good.jsonl"; : > "$WORK/srv-self.jsonl"; : > "$WORK/srv-wrong.jsonl"
  run tls-good "https://localhost:$P_good/NItalyR/JHRN0119.mp4" "&secs=5" 8 RNI_VIDEO_CA_FILE="$c/ca.pem"
  check play "$WORK/tls-good.log" --secs 5 --max-drop-pct 1
  check served "$WORK/srv-good.jsonl" --path-re 'JHRN0119' --min 1
  run tls-self "https://localhost:$P_self/NItalyR/JHRN0119.mp4" "&secs=2" 4 RNI_VIDEO_CA_FILE="$c/ca.pem"
  check error "$WORK/tls-self.log" --want "could not open https://localhost:$P_self/NItalyR/JHRN0119.mp4"
  run tls-wrong "https://localhost:$P_wrong/NItalyR/JHRN0119.mp4" "&secs=2" 4 RNI_VIDEO_CA_FILE="$c/ca.pem"
  check error "$WORK/tls-wrong.log" --want "could not open https://localhost:$P_wrong/NItalyR/JHRN0119.mp4"
  for s in self wrong; do  # refused by certificate verification, not by some other failure
    grep -q 'certificate verify failed' "$WORK/tls-$s.log" || fail "TLS $s: no 'certificate verify failed' from ffmpeg"
    grep -q '"tls_handshake_failed"' "$WORK/srv-$s.jsonl" || fail "TLS $s: the server saw no refused handshake"
    check served "$WORK/srv-$s.jsonl" --path-re '.' --max 0
  done
  # HLS: the playlist is on the GOOD server, its segments on the SELF-SIGNED one.
  # ffmpeg's hls demuxer does not pass tls_verify to segment requests, so this
  # is the arm that fails if only the top-level request were verified.
  local segs; segs="$(sed -n 's/^\(seg[0-9]*\.ts\)$/\1/p' "$MEDIA/hls/v180/vod.m3u8" | head -6)"
  mkplay() {  # <server port> -> playlist text with absolute segment URLs
    echo '#EXTM3U'; echo '#EXT-X-VERSION:3'; echo '#EXT-X-TARGETDURATION:2'; echo '#EXT-X-MEDIA-SEQUENCE:0'
    for s in $segs; do echo '#EXTINF:2.000,'; echo "https://localhost:$1/live/v180/$s"; done
    echo '#EXT-X-ENDLIST'
  }
  mkplay "$P_good" > "$WWW/mixed/good-segs.m3u8"
  mkplay "$P_self" > "$WWW/mixed/bad-segs.m3u8"
  run tls-hls-good "https://localhost:$P_good/mixed/good-segs.m3u8" "&secs=4" 7 RNI_VIDEO_CA_FILE="$c/ca.pem"
  check play "$WORK/tls-hls-good.log" --secs 4 --max-drop-pct 2
  : > "$WORK/srv-self.jsonl"
  run tls-hls-bad "https://localhost:$P_good/mixed/bad-segs.m3u8" "&secs=3" 6 RNI_VIDEO_CA_FILE="$c/ca.pem"
  grep -q 'VNET ready' "$WORK/tls-hls-bad.log" && fail "TLS: an HLS playlist whose segments are on an untrusted server PLAYED"
  check error "$WORK/tls-hls-bad.log" --want "https://localhost:$P_good/mixed/bad-segs.m3u8"
  check served "$WORK/srv-self.jsonl" --path-re '.' --max 0
  grep -q '"tls_handshake_failed"' "$WORK/srv-self.jsonl" || fail "TLS: the self-signed server saw no failed handshake (the segments were never tried?)"
  ok "TLS: the untrusted segment server saw $(grep -c tls_handshake_failed "$WORK/srv-self.jsonl") refused handshakes and served nothing"
}

arm_stall() {
  echo "== STALL: release() while the server never answers =="
  run stall "http://127.0.0.1:$P_plain/stall/x.mp4" "&secs=1&releaseAt=2" 5
  local took; took="$(sed -n 's/.*VNET released after=[0-9]* took=\([0-9]*\).*/\1/p' "$WORK/stall.log" | head -1)"
  [ -n "$took" ] || fail "STALL: no released line"
  [ "$took" -lt 1000 ] || fail "STALL: release() took $took ms with the server hung (want < 1000)"
  grep -q 'video id=1 error' "$WORK/stall.log" && fail "STALL: the release was reported as a player error"
  check served "$WORK/srv-plain.jsonl" --path-re '^/stall/' --status stall --min 1
  ok "STALL: release() returned in $took ms while the request hung, no error reported"
}

arm_slow() {
  echo "== SLOW: play() before a source that takes 1.5 s to answer =="
  ln -sf "$MEDIA/va720.mp4" "$WWW/NItalyR/JHRN0119.mp4"
  run slow "http://127.0.0.1:$P_plain/slow/NItalyR/JHRN0119.mp4" "&secs=6&playEarly=1" 12
  grep -qE 'VNET ready after=(1[5-9][0-9]{2}|[2-9][0-9]{3}|[0-9]{5,}) ' "$WORK/slow.log" ||
    fail "SLOW: ready came sooner than the server's 1.5 s delay (the arm did not delay the open)"
  check play "$WORK/slow.log" --secs 6 --max-drop-pct 1
}

arm_throttle() {
  echo "== THROTTLE: the server sends slower than the video's bitrate =="
  ln -sf "$MEDIA/va720.mp4" "$WWW/NItalyR/JHRN0119.mp4"
  run throttle "http://127.0.0.1:$P_plain/throttle/NItalyR/JHRN0119.mp4" "&secs=12" 16
  # Starved for real (the clock must lag the wall), and still no frame skipped.
  check play "$WORK/throttle.log" --secs 12 --max-drop-pct 1 --min-fps 5 --max-ct 10.8
}

arm_lag() {
  echo "== LAG: HLS with 800 ms latency on every request (2 s segments) =="
  run lag "http://127.0.0.1:$P_plain/lag/live/v360/vod.m3u8" "&secs=12" 18
  # Without read-ahead every segment boundary would starve the decoder for
  # 0.8 s (the clock would end near 8.6 s); the queue must hide it.
  check play "$WORK/lag.log" --secs 12 --max-drop-pct 1
}

media
serve plain
for a in $ARMS; do
  case "$a" in
    VA) arm_va ;; HLS) arm_hls ;; LIVE) arm_live ;; E404) arm_e404 ;; FILE) arm_file ;; TLS) arm_tls ;; STALL) arm_stall ;;
    SLOW) arm_slow ;; THROTTLE) arm_throttle ;; LAG) arm_lag ;;
    *) fail "unknown arm $a" ;;
  esac
done
echo "VIDEO_NET_PASS arms=\"$ARMS\" secs=$SECS engine=$(sha256sum "$PKG/rn-impeller" | cut -c1-16) ffmpeg=$(cut -d' ' -f1-3 "$FF/../BUILD-INFO" | head -1)"
