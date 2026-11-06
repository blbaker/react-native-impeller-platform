#!/usr/bin/env bash
# Mutation check for tools/ci-video-audio.sh. Every mutant is a real source edit,
# rebuilt into the staged x64 package, and the arm written for it must FAIL with
# its own assertion (the FAIL line is matched, not just the exit code):
#
#   A1 VideoPlayerAudio.cpp   the device write is skipped (counted, never written) -> TONE
#   A2 VideoPlayerAudio.cpp   rate ignored for mute: sound keeps going at 0.6      -> SYNC
#   A3 VideoPlayerAudio.cpp   a device that does not open is not reported          -> NODEV
#   A4 VideoPlayerAudio.cpp   sync ignores the device delay (heard 200 ms late)    -> SYNC
#   A5 AudioSinkAlsa.cpp      no libasound is not reported (open returns quietly)  -> NOLIB
#   A6 AudioSinkAlsa.cpp      the PCM opened blocking (release waits on the device) -> HANGREL
#   A7 AudioSinkAlsa.cpp      no stall timeout: a stuck device reads "on" forever  -> HANG
#   A8 VideoPlayerAudio.cpp   a failed write is not reported                       -> LOST
# Not claimed: FfmpegCopyInput's "the audio queue never gates the reader". With
# the 4 s stall timeout a stuck device is dropped long before the 10 s video
# read-ahead runs dry, so no arm can see a reader gated on the audio queue.
# Control: the pristine tree, rebuilt after the last restore, passes the WHOLE
# gate and reproduces the staged rn-impeller byte for byte.
#
#   bash tools/mutation-verify-video-audio.sh        ONLY=A1,A4 runs a subset
# Restores use cp + touch, never cp -p: an old mtime makes ninja keep the
# mutant's object file and every later gate tests a broken engine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
export JOBS="${JOBS:-10}"
BK="$(mktemp -d "${TMPDIR:-/tmp}/mv-video-audio.XXXXXX")"
LOG="$BK/logs"; mkdir -p "$LOG"
FILES=(engine/video/VideoPlayerAudio.cpp engine/video/AudioSinkAlsa.cpp)
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp "$f" "$BK/$f"; done
restore() { for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { cp "$BK/$f" "$f"; touch "$f"; }; done; }
trap 'restore' EXIT
fails=0; ran=0
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY,"  == *",$1,"* ]]; }
STAGED_SHA="$(sha256sum packages-engine/engine-linux-x64/bin/rn-impeller | cut -d' ' -f1)"

build() { nice -n 10 bash tools/engine-build-linux.sh --arch x64 > "$LOG/build-$1.log" 2>&1; }
gate() { nice -n 10 bash tools/ci-video-audio.sh --arms "$2" > "$LOG/gate-$1.log" 2>&1; }

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
  line="$(grep -m1 'VIDEO_AUDIO_FAIL' "$LOG/gate-$1.log" || true)"
  if [ "$rc" -eq 0 ]; then echo "   $1: SURVIVED (arm $2 passed a broken engine)"; fails=$((fails + 1))
  elif ! grep -qE "$3" <<< "$line"; then
    echo "   $1: killed, but not by the expected assertion /$3/: ${line:-$(tail -2 "$LOG/gate-$1.log")}"; fails=$((fails + 1))
  else echo "   $1: killed by $2 (${line#VIDEO_AUDIO_FAIL: })" | cut -c1-260; fi
}

A=engine/video/VideoPlayerAudio.cpp
S=engine/video/AudioSinkAlsa.cpp
echo "== mutation-verify-video-audio (x64), logs $LOG =="
run_mutant A1 TONE 'captured nothing|captured [0-9.]+ s of sound|FFT peak' \
  "$A" '    const int n = sink->Write(c.pcm.data() + (size_t)off * kAudioChannels,
                              std::min(kWriteFrames, c.frames - off), &err);' \
  '    const int n = std::min(kWriteFrames, c.frames - off);  // MUTANT A1: counted, never written'
run_mutant A2 SYNC 'rate 0\.6: sound heard' \
  "$A" '    if (rate != 1.0) {' '    if (false) {  // MUTANT A2'
run_mutant A3 NODEV "stats\.audio .*want \"error: ALSA device" \
  "$A" '  if (!sink) {
    dec_->DisableAudio();
    return AudioFail(err);
  }' '  if (!sink) {
    dec_->DisableAudio();
    return;  // MUTANT A3
  }'
run_mutant A4 SYNC 'A/V offset' \
  "$A" '    const double diff = at - (media + sink->Delay());' '    const double diff = at - media;  // MUTANT A4'
run_mutant A5 NOLIB "stats\.audio .*want \"error: no ALSA library" \
  "$S" '  if (!a.error.empty()) {
    *error = a.error;
    return nullptr;' '  if (!a.error.empty()) {
    *error = "";  // MUTANT A5
    return nullptr;'
run_mutant A6 HANGREL 'HANGREL' \
  "$S" 'constexpr int kNonBlock = 1;' 'constexpr int kNonBlock = 0;  // MUTANT A6'
run_mutant A7 HANG "stats\.audio .*want \"error: ALSA device 'default' took no samples" \
  "$S" '    } else if (std::chrono::duration<double>(now - stallSince_).count() >= kStallSec) {' \
  '    } else if (std::chrono::duration<double>(now - stallSince_).count() >= 1e9) {  // MUTANT A7'
run_mutant A8 LOST "stats\.audio .*want \"error: ALSA write on default" \
  "$A" '    if (n < 0) {
      dec_->DisableAudio();
      return AudioFail(err);
    }' '    if (n < 0) {
      dec_->DisableAudio();
      return;  // MUTANT A8
    }'

echo "== control: pristine tree, rebuilt, whole gate =="
restore
for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { echo "   control: $f not restored"; fails=$((fails + 1)); }; done
for f in "${FILES[@]}"; do [ "$(grep -c MUTANT "$f")" -eq 0 ] || { echo "   control: MUTANT left in $f"; fails=$((fails + 1)); }; done
if ! build control; then echo "   control: build failed"; fails=$((fails + 1))
else
  got="$(sha256sum packages-engine/engine-linux-x64/bin/rn-impeller | cut -d' ' -f1)"
  [ "$got" = "$STAGED_SHA" ] && echo "   control rn-impeller == the package before the run (${got:0:16})" ||
    { echo "   control rn-impeller ${got:0:16} != ${STAGED_SHA:0:16} before the run"; fails=$((fails + 1)); }
  if gate control "TONE SYNC LOST HANG HANGREL NODEV NOLIB"; then
    echo "   control: $(tail -1 "$LOG/gate-control.log" | cut -c1-160)"
  else echo "   control: gate FAILED on the pristine tree: $(grep -m1 VIDEO_AUDIO_FAIL "$LOG/gate-control.log")"; fails=$((fails + 1)); fi
fi
trap - EXIT
if [ "$fails" -eq 0 ]; then echo "VIDEO_AUDIO_MUTATION_PASS ($ran mutants killed by their own arm, control green)"; exit 0; fi
echo "VIDEO_AUDIO_MUTATION_FAIL ($fails problem(s); logs kept in $LOG)"; exit 1
