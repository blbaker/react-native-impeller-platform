#!/usr/bin/env bash
# Mutation check for tools/ci-video-ffmpeg8.sh. Every mutant is
# a real source edit, rebuilt, and the gate arm written for it must FAIL with
# its own assertion (the FAIL line is matched, not just the exit code):
#
#   M1 engine/CMakeLists.txt        the ffmpeg 8 copy dropped from RNI_FFMPEG_COPIES  -> F8
#   M2 engine/host/OptionalLibs.cpp row 8 lists libswscale.so.10, not .9            -> F8
#   M3 engine/video/FfmpegSelect.cpp copies tried oldest first (6 before 8)          -> F86
#   M4 engine/video/FfmpegCopy.cpp  runtime major check off                         -> FM
#                                   (FM points the 6 copy at ffmpeg 8 libs)
#   M5 engine/video/VideoPlayerFfmpeg.cpp  VIDEO_DECODER says hw=1 on the
#                                   software fallback                               -> F8
#   M6 engine/video/FfmpegCopyHw.cpp  RNI_VIDEO_HW=0 ignored                        -> HW0
# Not mutated: the EAGAIN resend and the DRM_PRIME copy-out. No ffmpeg on this
# host has a decoder that returns EAGAIN from send or hands out hardware frames,
# so no gate here can see them; only the board run (a board check) can.
# Control: the pristine tree, rebuilt after the last restore, passes the WHOLE
# gate and reproduces the staged rn-impeller byte for byte.
#
#   bash tools/mutation-verify-video-ffmpeg8.sh [--arch x64|arm64]   ONLY=M1,M4 runs a subset
# x64 rebuilds the staged x64 package for each mutant (tools/engine-build.sh).
# arm64 builds each mutant into a scratch package (tools/lib/arm64-scratch-stage.sh)
# and never touches the staged one; M3 is x64 only (no aarch64 ffmpeg 6 to put
# next to 8, so there is no F86 arm on arm64).
# Restores use cp + touch, never cp -p: an old mtime makes ninja keep the
# mutant's object file and every later gate tests a broken engine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
ARCH=x64
[ "${1:-}" = "--arch" ] && ARCH="${2:-x64}"
case "$ARCH" in x64|arm64) ;; *) echo "--arch x64|arm64" >&2; exit 2 ;; esac
export JOBS="${JOBS:-10}"
BK="$(mktemp -d "${TMPDIR:-/tmp}/mv-video-ff8.XXXXXX")"
LOG="$BK/logs"; mkdir -p "$LOG"
FILES=(engine/CMakeLists.txt engine/host/OptionalLibs.cpp engine/video/FfmpegSelect.cpp engine/video/FfmpegCopy.cpp
       engine/video/VideoPlayerFfmpeg.cpp engine/video/FfmpegCopyHw.cpp)
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp "$f" "$BK/$f"; done
restore() { for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { cp "$BK/$f" "$f"; touch "$f"; }; done; }
trap 'restore' EXIT
fails=0; ran=0
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
. "$ROOT/tools/lib/arm64-scratch-stage.sh"
STAGED_SHA="$(sha256sum "packages-engine/engine-linux-$ARCH/bin/rn-impeller" | cut -d' ' -f1)"

build() {  # $1 tag -> 0 ok; sets ENGINE_DIR for the gate
  if [ "$ARCH" = x64 ]; then
    ENGINE_DIR=""
    nice -n 10 bash tools/engine-build.sh linux x64 > "$LOG/build-$1.log" 2>&1
  else
    ENGINE_DIR="$BK/pkg-$1"
    arm64_stage "$ENGINE_DIR" "$LOG/build-$1.log" && ENGINE_DIR="$ENGINE_DIR/bin"
  fi
}
gate() {  # $1 tag, $2 arms
  RNI_FF8_ENGINE_DIR="$ENGINE_DIR" nice -n 10 bash tools/ci-video-ffmpeg8.sh --arch "$ARCH" --arms "$2" > "$LOG/gate-$1.log" 2>&1
}
[ "$ARCH" = x64 ] || [ -f "$ARM64_EB/build.ninja" ] || { echo "no arm64 build tree (bash tools/engine-build.sh linux arm64)"; exit 1; }

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
  if [ "$ARCH" = arm64 ] && [ "$2" = F86 ]; then echo "   $1: x64 only (no F86 arm on arm64)"; return 0; fi
  ran=$((ran + 1))
  restore
  if ! mutate "$4" "$5" "$6"; then echo "   $1: STALE ANCHOR in $4"; fails=$((fails + 1)); return; fi
  if ! build "$1"; then echo "   $1: build failed (see $LOG/build-$1.log)"; fails=$((fails + 1)); return; fi
  local rc=0 line; gate "$1" "$2" || rc=$?
  line="$(grep -m1 'VIDEO_FF8_FAIL' "$LOG/gate-$1.log" || true)"
  if [ "$rc" -eq 0 ]; then echo "   $1: SURVIVED (arm $2 passed a broken engine)"; fails=$((fails + 1))
  elif ! grep -qE "$3" <<< "$line"; then
    echo "   $1: killed, but not by the expected assertion /$3/: ${line:-$(tail -2 "$LOG/gate-$1.log")}"; fails=$((fails + 1))
  else echo "   $1: killed by $2 (${line#VIDEO_FF8_FAIL: })" | cut -c1-260; fi
}

echo "== mutation-verify-video-ffmpeg8 ($ARCH), logs $LOG =="
run_mutant M1 F8 '^VIDEO_FF8_FAIL: F8: doctor video\.ffmpeg_abi=.6., want .8.' \
  engine/CMakeLists.txt 'set(RNI_FFMPEG_COPIES 8 6)' 'set(RNI_FFMPEG_COPIES 6)  # MUTANT M1'
run_mutant M2 F8 "^VIDEO_FF8_FAIL: F8: doctor dlopen\.ffmpeg\.8='missing:libswscale\.so\.10'" \
  engine/host/OptionalLibs.cpp \
  '{8, 62, {"libavutil.so.60", "libavcodec.so.62", "libavformat.so.62", "libswscale.so.9"}},' \
  '{8, 62, {"libavutil.so.60", "libavcodec.so.62", "libavformat.so.62", "libswscale.so.10"}},  // MUTANT M2'
run_mutant M3 F86 "^VIDEO_FF8_FAIL: F86: doctor video\.ffmpeg_abi='6', want '8'" \
  engine/video/FfmpegSelect.cpp 'return a->release > b->release;' 'return a->release < b->release; /* MUTANT M3 */'
run_mutant M4 FM "^VIDEO_FF8_FAIL: FM: doctor video\.status='ok' does not match" \
  engine/video/FfmpegCopy.cpp '    if (!refused.empty()) return fail(' '    if (/* MUTANT M4 */ false && !refused.empty()) return fail('
run_mutant M5 F8 "^VIDEO_FF8_FAIL: F8 play: want exactly one 'rn-impeller: VIDEO_DECODER source=1 codec=h264 hw=0 convert=sws'" \
  engine/video/VideoPlayerFfmpeg.cpp 'info.codec.c_str(), info.hw ? 1 : 0);' 'info.codec.c_str(), 1 /* MUTANT M5 */);'
run_mutant M6 HW0 "^VIDEO_FF8_FAIL: HW0 play: no 'hw decode off: RNI_VIDEO_HW=0' line" \
  engine/video/FfmpegCopyHw.cpp 'return v != nullptr && std::strcmp(v, "0") == 0;' 'return false && v; /* MUTANT M6 */'

echo "== control: pristine tree, rebuilt, whole gate =="
restore
for f in "${FILES[@]}"; do cmp -s "$BK/$f" "$f" || { echo "   control: $f not restored"; fails=$((fails + 1)); }; done
if ! build control; then echo "   control: build failed"; fails=$((fails + 1))
else
  if [ "$ARCH" = arm64 ]; then
    arm64_same_as_staged "$BK/pkg-control" && echo "   control rn-impeller == staged package (byte for byte)" ||
      { echo "   control rn-impeller differs from the staged package"; fails=$((fails + 1)); }
    ENGINE_DIR=""  # the gate's own default: the staged package, with the PKG copy-isolation check
  else
    got="$(sha256sum packages-engine/engine-linux-x64/bin/rn-impeller | cut -d' ' -f1)"
    [ "$got" = "$STAGED_SHA" ] && echo "   control rn-impeller == the package before the run (${got:0:16})" ||
      { echo "   control rn-impeller ${got:0:16} != ${STAGED_SHA:0:16} before the run"; fails=$((fails + 1)); }
  fi
  if gate control "$( [ "$ARCH" = x64 ] && echo 'PKG CFG F8 HW0 F6 F86 F0 FM' || echo 'PKG F8 F0 FM')"; then
    echo "   control: $(tail -1 "$LOG/gate-control.log" | cut -c1-160)"
  else echo "   control: gate FAILED on the pristine tree: $(grep -m1 VIDEO_FF8_FAIL "$LOG/gate-control.log")"; fails=$((fails + 1)); fi
fi
trap - EXIT
if [ "$fails" -eq 0 ]; then echo "VIDEO_FF8_MUTATION_PASS arch=$ARCH ($ran mutants killed by their own arm, control green)"; exit 0; fi
echo "VIDEO_FF8_MUTATION_FAIL arch=$ARCH ($fails problem(s); logs kept in $LOG)"; exit 1
