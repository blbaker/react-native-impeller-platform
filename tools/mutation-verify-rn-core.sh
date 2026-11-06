#!/usr/bin/env bash
# MUTATION TEST for the row 3 video arm of tools/ci-rn-core.sh (ARMS=video).
# Each mutant edits ENGINE SOURCE (engine/video/FfmpegPlayer.h, the player's
# controls; card 12 moved them out of VideoPlayerFfmpeg.cpp), rebuilds
# linux-x64, and must turn the arm red for its OWN reason.
#
#   M1  playbackRate ignored: SetRate keeps rate 1 -> rate 2.0 advances ~30, not ~60
#   M2  pause that lies: Pause() keeps playing while getStatus says playing=false
#       -> only the PIXEL rule (frame A == frame B) can catch it
#   M3  seek that only moves the clock: currentTime reports 4.5 but the decoder
#       never seeks -> the painted frame is not 135 (pixels, not currentTime)
#
# Restores with cp + touch (never cp -p: an old mtime makes ninja skip the
# rebuild and the mutant stays linked in), rebuilds, and re-runs the arm GREEN.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
unset RNI_BIN
F=engine/video/FfmpegPlayer.h
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/mv-rn-core-video.XXXXXX")"
cp "$F" "$BACKUP/orig.cpp"
restore() { cp "$BACKUP/orig.cpp" "$F"; touch "$F"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh linux x64)" >&2' EXIT
build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { ARMS=video bash tools/ci-rn-core.sh > "$1" 2>&1; }
mutate() {  # old new
  python3 - "$F" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}
expect_killed() {  # name log ERE
  if grep -q 'RNCORE_VIDEO_PASS' "$2" || ! grep -q 'RN_CORE_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- the video arm stayed GREEN" >&2; tail -5 "$2" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 FAIL "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | cut -c1-220)"
}

echo "== M1: playbackRate ignored (rate stays 1.0) =="
mutate '    rate_ = std::min(16.0, std::max(1.0 / 16.0, std::isfinite(rate) ? rate : 1.0));' \
       '    rate_ = 1.0;  // MUTANT M1'
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'RN_CORE_FAIL: video rate 2.0: frames did not advance'
restore

echo "== M2: pause keeps playing, status says paused =="
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
reps = [
    ("""    playing_ = false;
    cv_.notify_all();
  }

  void Seek(double seconds) override {""",
     """    playing_ = true;  // MUTANT M2: keeps playing
    pausedCalled_ = true;
    cv_.notify_all();
  }

  void Seek(double seconds) override {"""),
    ("    s.playing = playing_;", "    s.playing = playing_ && !pausedCalled_;  // MUTANT M2: status lies"),
    ("  bool playing_ = false, loop_ = false,", "  bool pausedCalled_ = false;  // MUTANT M2\n  bool playing_ = false, loop_ = false,"),
]
for old, new in reps:
    n = s.count(old)
    assert n == 1, "anchor found %dx: %s" % (n, old[:50])
    s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'RN_CORE_FAIL: video pause: the picture kept moving'
restore

echo "== M3: seek moves currentTime only, the decoder never seeks =="
mutate '    seekTarget_ = t;
    seekPending_ = true;' '    seekTarget_ = t;
    seekPending_ = false;  // MUTANT M3'
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" 'RN_CORE_FAIL: video seek 4.5: wrong frame painted'
grep -q 'RNCORE_VIDEO shot tag=S t=4.500' "$BACKUP/m3.log" ||
  { echo "MUTATE_FAIL: M3 did not keep the reported currentTime at 4.5 (mutant is not the lying shape)" >&2; exit 1; }
echo "   M3 reported t=4.500 while painting another frame (currentTime alone would have passed)"
restore

echo "== restored source: rebuild, the arm must be GREEN again =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -8 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: arm red after restore" >&2; exit 1; }
grep -q 'RNCORE_VIDEO_PASS' "$BACKUP/final.log" || { echo "MUTATE_FAIL: no PASS after restore" >&2; exit 1; }
cmp -s "$BACKUP/orig.cpp" "$F" || { echo "MUTATE_FAIL: source differs from the original after restore" >&2; exit 1; }
trap - EXIT
rm -rf "$BACKUP"
echo "RNCORE_VIDEO_MUTATION_PASS (3/3 mutants killed, restored source green)"
