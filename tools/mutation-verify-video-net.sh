#!/usr/bin/env bash
# Mutation check for tools/ci-video-net.sh. Every mutant is a real source edit,
# rebuilt into the staged x64 package, and the arm written for it must FAIL
# with its own assertion (the FAIL line is matched, not just the exit code):
#
#   N1 FfmpegCopyInput.cpp  tls_verify only on the top-level request (the
#                           naive fix: nested HLS opens keep ffmpeg's verify=0) -> TLS
#   N2 FfmpegCopyInput.cpp  tls_verify=0 everywhere (ffmpeg 8's default)       -> TLS
#   N3 FfmpegCopyInput.cpp  other streams not discarded (HLS fetches every variant) -> HLS
#   N4 FfmpegCopyInput.cpp  the interrupt callback never fires (release waits) -> STALL
#   N5 FfmpegSelect.cpp     RedactUri returns the URI as is                    -> E404
#   N6 VideoPlayerFfmpeg.cpp no clock re-anchor at the first frame             -> SLOW
#   N7 FfmpegPlayer.h       network waits not credited to the clock            -> THROTTLE
#   N8 FfmpegCopyInput.cpp  no read-ahead (the queue holds one packet)         -> LAG
#   N9 FfmpegSelect.cpp     http(s) URIs refused (today's file-only engine)    -> E404
# Control: the pristine tree, rebuilt after the last restore, passes the WHOLE
# gate and reproduces the staged rn-impeller byte for byte.
#
#   bash tools/mutation-verify-video-net.sh        ONLY=N1,N4 runs a subset
# Restores use cp + touch, never cp -p: an old mtime makes ninja keep the
# mutant's object file and every later gate tests a broken engine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
export JOBS="${JOBS:-10}"
BK="$(mktemp -d "${TMPDIR:-/tmp}/mv-video-net.XXXXXX")"
LOG="$BK/logs"; mkdir -p "$LOG"
FILES=(engine/video/FfmpegCopyInput.cpp engine/video/FfmpegSelect.cpp engine/video/VideoPlayerFfmpeg.cpp
       engine/video/FfmpegPlayer.h)
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp "$f" "$BK/$f"; done
restore() { for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { cp "$BK/$f" "$f"; touch "$f"; }; done; }
trap 'restore' EXIT
fails=0; ran=0
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY,"  == *",$1,"* ]]; }
STAGED_SHA="$(sha256sum packages-engine/engine-linux-x64/bin/rn-impeller | cut -d' ' -f1)"

build() { nice -n 10 bash tools/engine-build-linux.sh --arch x64 > "$LOG/build-$1.log" 2>&1; }
gate() { nice -n 10 bash tools/ci-video-net.sh --arms "$2" --secs "${3:-60}" > "$LOG/gate-$1.log" 2>&1; }

mutate() {  # $1 file, $2 old, $3 new  (old must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old!r}"
open(p, 'w').write(s.replace(old, new))
PY
}

run_mutant() {  # $1 id, $2 arm, $3 ERE the FAIL line must match, $4 file, $5 old, $6 new
  want "$1" || return 0
  ran=$((ran + 1))
  restore
  if ! mutate "$4" "$5" "$6"; then echo "   $1: STALE ANCHOR in $4"; fails=$((fails + 1)); return; fi
  if ! build "$1"; then echo "   $1: build failed (see $LOG/build-$1.log)"; fails=$((fails + 1)); return; fi
  local rc=0 line; gate "$1" "$2" || rc=$?
  line="$(grep -m1 'VIDEO_NET_FAIL' "$LOG/gate-$1.log" || true)"
  if [ "$rc" -eq 0 ]; then echo "   $1: SURVIVED (arm $2 passed a broken engine)"; fails=$((fails + 1))
  elif ! grep -qE "$3" <<< "$line"; then
    echo "   $1: killed, but not by the expected assertion /$3/: ${line:-$(tail -2 "$LOG/gate-$1.log")}"; fails=$((fails + 1))
  else echo "   $1: killed by $2 (${line#VIDEO_NET_FAIL: })" | cut -c1-260; fi
}

I=engine/video/FfmpegCopyInput.cpp
echo "== mutation-verify-video-net (x64), logs $LOG =="
run_mutant N1 TLS 'an HLS playlist whose segments are on an untrusted server PLAYED' \
  "$I" '  auto* self = static_cast<Input*>(s->opaque);' \
  '  auto* self = static_cast<Input*>(s->opaque);
  if (s->pb) return self->defaultIo_(s, pb, url, flags, options);  // MUTANT N1'
run_mutant N2 TLS 'TLS (self|wrong)|no VNET error line' \
  "$I" 'av.av_dict_set(o, "tls_verify", "1", 0);' 'av.av_dict_set(o, "tls_verify", "0", 0);  // MUTANT N2'
run_mutant N3 HLS 'v180/seg.*want <= 2' \
  "$I" '    fmt_->streams[i]->discard = (int)i == si_ || (int)i == ai_ ? AVDISCARD_DEFAULT : AVDISCARD_ALL;' \
  '    fmt_->streams[i]->discard = AVDISCARD_DEFAULT;  // MUTANT N3'
run_mutant N4 STALL 'STALL: (release\(\) took|no released line)' \
  "$I" 'return static_cast<Input*>(self)->abort_.load() ? 1 : 0;' 'return self ? 0 : 1; /* MUTANT N4 */'
run_mutant N5 E404 'E404|error is' \
  engine/video/FfmpegSelect.cpp '  if (scheme == std::string::npos) return uri;  // a path' \
  '  if (true) return uri;  // MUTANT N5'
run_mutant N6 SLOW 'framesDropped' \
  engine/video/VideoPlayerFfmpeg.cpp '      if (!seekPending_) ReanchorLocked(nextPts_);' '      // MUTANT N6'
run_mutant N7 THROTTLE 'framesDropped|never starved' \
  engine/video/FfmpegPlayer.h '    if (w <= 0 || !firstShown_) return;' '    if (true) return;  // MUTANT N7'
run_mutant N8 LAG 'rate 1\.00 over|framesDropped' \
  "$I" '  return queuedBytes_ >= kReadAheadBytes || SpanAtLeast(queue_, fmt_->streams[si_]->time_base, kReadAheadSec);' \
  '  return !queue_.empty();  // MUTANT N8'
run_mutant N9 E404 'error is .*unsupported source' \
  engine/video/FfmpegSelect.cpp '  if (uri.rfind("http://", 0) == 0 || uri.rfind("https://", 0) == 0) return uri;' \
  '  // MUTANT N9'

echo "== control: pristine tree, rebuilt, whole gate =="
restore
for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { echo "   control: $f not restored"; fails=$((fails + 1)); }; done
for f in "${FILES[@]}"; do [ "$(grep -c MUTANT "$f")" -eq 0 ] || { echo "   control: MUTANT left in $f"; fails=$((fails + 1)); }; done
if ! build control; then echo "   control: build failed"; fails=$((fails + 1))
else
  got="$(sha256sum packages-engine/engine-linux-x64/bin/rn-impeller | cut -d' ' -f1)"
  [ "$got" = "$STAGED_SHA" ] && echo "   control rn-impeller == the package before the run (${got:0:16})" ||
    { echo "   control rn-impeller ${got:0:16} != ${STAGED_SHA:0:16} before the run"; fails=$((fails + 1)); }
  if gate control "VA HLS LIVE LAG SLOW THROTTLE E404 FILE TLS STALL" 60; then
    echo "   control: $(tail -1 "$LOG/gate-control.log" | cut -c1-160)"
  else echo "   control: gate FAILED on the pristine tree: $(grep -m1 VIDEO_NET_FAIL "$LOG/gate-control.log")"; fails=$((fails + 1)); fi
fi
trap - EXIT
if [ "$fails" -eq 0 ]; then echo "VIDEO_NET_MUTATION_PASS ($ran mutants killed by their own arm, control green)"; exit 0; fi
echo "VIDEO_NET_MUTATION_FAIL ($fails problem(s); logs kept in $LOG)"; exit 1
