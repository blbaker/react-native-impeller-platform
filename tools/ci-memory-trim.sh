#!/usr/bin/env bash
# memory gate (rn-impeller side; the helper side is ci-webview-release.sh).
# Windowed linux-x64 runs under a private Xvfb. Arms, in order:
#   video    fixtures/video-net plays a generated 1280x720 h264 file for 12 s, release() at 14 s:
#            malloc_policy=engine ok=1; the player's destroyed line shows >= 300 frames shown
#            from <= 8 frame buffers (FrameRecycler); a mem_trim naming `video` follows the
#            destroy; RNI_MEM_STATS_SEC prints mem_stats lines with the malloc fields
#   control  same run with RNI_MALLOC_POLICY=off RNI_MEM_TRIM=0: policy=off, NO mem_trim line
#            (the instrument tells the two apart)
#   prune    fixtures/fp42-external-texture unmounts its <ImpellerTextureView> at 1.5 s with the
#            producer still registered: ext_texture_prune for that node, left=0
#   ARMS="video control prune" bash tools/ci-memory-trim.sh
# Mutants: tools/mutation-verify-memory-trim.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/host-window.sh
fail() { echo "MEMORY_TRIM_FAIL: $*" >&2; exit 1; }
[ "$(rni_host)" = linux ] || fail "linux only (glibc malloc policy)"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
FF="${RNI_FFMPEG8_LIB:-$ROOT/engine/third_party/ffmpeg8-linux-x64/lib}"
ARMS="${ARMS:-video control prune}"
[ -x "$BIN" ] || fail "no engine at $BIN"
[ -d "$FF" ] || fail "no ffmpeg 8 libs at $FF (tools/ffmpeg8-fetch.sh --arch x64)"
command -v ffmpeg >/dev/null || fail "no ffmpeg CLI (makes the test video)"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-memory-trim.XXXXXX")"
cleanup() { rni_kill_own 2>/dev/null || true; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

VID="$WORK/v720.mp4"
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 20 -c:v libx264 -preset veryfast -pix_fmt yuv420p "$VID" \
  || fail "harness: could not make the test video"

video_run() {  # tag [ENV=V ...]
  local tag="$1"; shift
  local url="vnet://play?src=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote("file://"+sys.argv[1],safe=""))' "$VID")&secs=12&releaseAt=14"
  ( cd / && for kv in "$@"; do export "${kv?}"; done && export LD_LIBRARY_PATH="$FF" RNI_MEM_STATS_SEC=2 \
      && rni_xrun "$WORK/x$tag" timeout 90 "$BIN" --window \
      --probe-banner off --prewarm off --bundle "$ROOT/fixtures/video-net/prebuilt/video-net.bundle" --app-name VideoNet \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --idle-skip --idle-run-sec 20 --initial-url "$url" ) \
      > "$WORK/$tag.log" 2>&1 || fail "$tag: engine exited $? ($(tail -3 "$WORK/$tag.log" | tr '\n' ' '))"
}

for arm in $ARMS; do
  case "$arm" in
    video)
      video_run video
      python3 - "$WORK/video.log" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read()
def bad(m): print("MEMORY_TRIM_FAIL: video: " + m, file=sys.stderr); sys.exit(1)
if not re.search(r"^rn-impeller: malloc_policy=engine arena_max=4 mmap_threshold=1048576 trim_threshold=4194304 ok=1$", log, re.M):
    bad("no `malloc_policy=engine ... ok=1` line")
d = re.search(r"^rn-impeller: video id=(\d+) destroyed frame_buffers=(\d+) frames_shown=(\d+)$", log, re.M)
if not d: bad("no `video id=N destroyed frame_buffers= frames_shown=` line (player never freed?)")
bufs, shown = int(d.group(2)), int(d.group(3))
if shown < 300: bad(f"only {shown} frames shown, wanted >= 300 (the video did not play)")
if bufs > 8: bad(f"{bufs} frame buffers for {shown} frames: frames are not recycled")
trims = [m for m in re.finditer(r"^rn-impeller: mem_trim why=(\S+) requests=\d+ rss_before_kb=\d+ rss_after_kb=\d+ freed_kb=-?\d+ ms=[\d.]+$", log, re.M)]
after = [m for m in trims if m.start() > d.start() and "video" in m.group(1).split(",")]
if not after: bad("no mem_trim naming `video` after the player was destroyed")
stats = re.findall(r"^rn-impeller: mem_stats when=\w+ rss_kb=\d+ anon_kb=\d+ malloc_used_kb=\d+ malloc_free_kb=\d+ malloc_mmap_kb=\d+ arenas=(\d+) trims=\d+ image_cache_kb=\d+$", log, re.M)
if len(stats) < 5: bad(f"{len(stats)} mem_stats lines in a 20 s run at RNI_MEM_STATS_SEC=2")
if max(int(a) for a in stats) > 5: bad(f"arenas={max(int(a) for a in stats)} with arena_max=4 (main + 4 at most)")
print(f"MEMORY_TRIM video ok: {shown} frames from {bufs} buffers; {after[0].group(0).split(': ',1)[1]}; arenas<={max(int(a) for a in stats)}")
PY
      ;;
    control)
      video_run control RNI_MALLOC_POLICY=off RNI_MEM_TRIM=0
      grep -q "^rn-impeller: malloc_policy=off source=RNI_MALLOC_POLICY$" "$WORK/control.log" || fail "control: no malloc_policy=off line"
      grep -q "^rn-impeller: mem_trim why=" "$WORK/control.log" && fail "control: mem_trim ran with RNI_MEM_TRIM=0"
      grep -q "^rn-impeller: video id=[0-9]* destroyed " "$WORK/control.log" || fail "control: the player was never destroyed"
      echo "MEMORY_TRIM control ok: policy off, no trim" ;;
    prune)
      ( cd / && rni_xrun "$WORK/xprune" timeout 60 "$BIN" --window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 \
          --probe-banner off --app-name ExternalTexture --bundle "$ROOT/fixtures/fp42-external-texture/prebuilt/fp42-external-texture.bundle" \
          --initial-url "fp42://run?fps=30&unmountMs=1500" --idle-run-sec 4 ) > "$WORK/prune.log" 2>&1 \
        || fail "prune: engine exited $?"
      python3 - "$WORK/prune.log" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read()
def bad(m): print("MEMORY_TRIM_FAIL: prune: " + m, file=sys.stderr); sys.exit(1)
u = re.search(r"FP42 unmounted id=(\d+)", log)
if not u: bad("the fixture never unmounted its texture view (old bundle?)")
if not re.search(r"^rn-impeller: ext_texture_register id=%s " % u.group(1), log, re.M): bad("no producer registered")
if re.search(r"^rn-impeller: ext_texture_unregister id=%s " % u.group(1), log[: u.start()], re.M):
    bad("the producer was unregistered before the unmount (not the case under test)")
p = re.findall(r"^rn-impeller: ext_texture_prune tag=(\d+) (\d+)x(\d+) left=(\d+)$", log[u.start():], re.M)
if not p: bad("no ext_texture_prune after the unmount: the node's GPU upload is kept")
if p[-1][3] != "0": bad(f"left={p[-1][3]} after the only texture view unmounted")
print(f"MEMORY_TRIM prune ok: tag {p[0][0]} {p[0][1]}x{p[0][2]} released, left=0")
PY
      ;;
    *) fail "unknown arm $arm" ;;
  esac
done
echo "MEMORY_TRIM_GATE_PASS arms=\"$ARMS\""
