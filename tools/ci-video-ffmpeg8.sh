#!/usr/bin/env bash
# ffmpeg 8 video gate. The board image ships ffmpeg 8.0.1; the
# engine compiles its decoder once per ffmpeg release (8 required, 6 for dev
# hosts) and picks a copy at run time, newest first, refusing a copy whose
# loaded majors are not the ones it was compiled against.
#
#   bash tools/ci-video-ffmpeg8.sh --arch arm64|x64 [--arms "PKG F8 F0 FM"]
#
# Arms (default x64: PKG CFG F8 HW0 F6 F86 F0 FM; arm64: PKG F8 F0 FM):
#   PKG  tools/ffmpeg8-fetch.sh --check (five sonames), rn-impeller NEEDS no
#        libav*/libsw*, and the two copies' objects share no COMDAT that names an
#        ffmpeg type (one would silently use the other release's struct layout)
#   CFG  (x64) configure with no ffmpeg 8 headers FAILS and names the missing dir
#   F8   ONLY ffmpeg 8.0.1 (tools/ffmpeg8-fetch.sh libs bind-mounted into the
#        image's system lib dir, the way an image installs them; tools/video-ffmpeg-run.sh).
#        arm64: qemu-aarch64 in rni-arm64-tools:bookworm (Debian has ffmpeg 5.1
#        there, which is none of 8/7/6); x64: rni-x64-tools:noble with its 6.1
#        hidden. Doctor: dlopen.ffmpeg.resolved=8, video.ffmpeg_abi=8, video.status=ok.
#        Then the rn-core video route PLAYS: two RNViewShot captures (read back from
#        the engine) show frame numbers, read from their PIXELS, that differ.
#        Every play also needs ONE "VIDEO_DECODER source=1 codec=h264 hw=0
#        convert=sws" line and "hw decode off: no h264_rkmpp decoder in this
#        ffmpeg": no ffmpeg here has rkmpp, so the hardware path (rkmpp
#        step A) must fall back and say so. hw=1 is only provable on the board.
#   HW0  F8 with RNI_VIDEO_HW=0: still hw=0, and the reason is the env var
#   F6   (x64) the host's ffmpeg 6.1 only: resolved=6, abi=6, ok, plays
#   F86  (x64) host 6.1 + ffmpeg 8 on LD_LIBRARY_PATH: resolved=8, abi=8, plays on 8
#   F0   no ffmpeg 8/7/6: video.status=unusable naming libavutil.so.60; the
#        engine still starts and paints (rn-core image route pixel rules), and JS
#        gets the same error when it creates a player
#   FM   the 6 copy pointed at ffmpeg 8 libs (tools/ffmpeg_soname_swap.py: the 8
#        files under 6 sonames): the 6 sonames dlopen, the copy is REFUSED by its
#        runtime major check and video is unusable
# Mutants: tools/mutation-verify-video-ffmpeg8.sh. Engine: RNI_FF8_ENGINE_DIR
# (default packages-engine/engine-linux-<arch>/bin). Host load: run it nice'd.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH="" ARMS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arms) ARMS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  x64) DEFAULT="PKG CFG F8 HW0 F6 F86 F0 FM"; IDLE=4; EB="$ROOT/engine/build" ;;
  arm64) DEFAULT="PKG F8 F0 FM"; IDLE=45; EB="$ROOT/engine/build-linux-arm64/engine" ;;  # qemu: ~40 s to first present
  *) echo "--arch x64|arm64 is required" >&2; exit 2 ;;
esac
ARMS="${ARMS:-$DEFAULT}"
PKG="${RNI_FF8_ENGINE_DIR:-$ROOT/packages-engine/engine-linux-$ARCH/bin}"
FF8="$ROOT/engine/third_party/ffmpeg8-linux-$ARCH/lib"
BUNDLE="$ROOT/fixtures/rn-core/prebuilt/rn-core.bundle"
MP4="$ROOT/fixtures/rn-core/route.mp4"
CHK="$ROOT/tools/rn_core_check.py"
V6="libavutil.so.58 libavcodec.so.60 libavformat.so.60 libswscale.so.7"  # OptionalLibs row 6
NM=/usr/lib/llvm-18/bin/llvm-nm; [ -x "$NM" ] || NM=nm
R=/usr/lib/llvm-18/bin/llvm-readelf; [ -x "$R" ] || R=readelf
fail() { echo "VIDEO_FF8_FAIL: $*" >&2; exit 1; }
ok() { echo "   ok  $*"; }
[ -x "$PKG/rn-impeller" ] || fail "no engine at $PKG"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-video-ffmpeg8.XXXXXX")"
cleanup() { if [ -n "${KEEP_WORKDIR:-}" ]; then echo "kept $WORK" >&2; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

# mkrun <tag> <native|container> <LD_LIBRARY_PATH> <libs to mount> <sonames to hide>
# writes $WORK/<tag>.run: the engine, with exactly that ffmpeg around it.
mkrun() {
  local r="$WORK/$1.run"
  { echo '#!/usr/bin/env bash'
    if [ "$2" = native ]; then
      if [ -n "$3" ]; then echo "export LD_LIBRARY_PATH=$(printf %q "$3")"; else echo "unset LD_LIBRARY_PATH"; fi
      echo "exec $(printf %q "$PKG/rn-impeller") \"\$@\""
    else
      echo "export FFRUN_ARCH=$ARCH FFRUN_ENGINE_DIR=$(printf %q "$PKG") FFRUN_LIBS=$(printf %q "$4") FFRUN_HIDE=$(printf %q "$5")"
      echo "exec bash $(printf %q "$ROOT/tools/video-ffmpeg-run.sh") \"\$@\""
    fi; } > "$r"
  chmod +x "$r"
}
val() { sed -n "s/^$1=//p" "$2" | head -1; }
doctor() {  # <arm>: $WORK/<arm>.doctor
  local rc=0
  (cd / && "$WORK/$1.run" --doctor) > "$WORK/$1.doctor" 2> "$WORK/$1.doctor.err" || rc=$?
  [ "$rc" -eq 0 ] && grep -q '^doctor.done=1$' "$WORK/$1.doctor" || { tail -5 "$WORK/$1.doctor.err" >&2; fail "$1: --doctor exited $rc"; }
  grep -E '^(dlopen\.ffmpeg\.[0-9a-z]+|video\.[a-z_]+)=' "$WORK/$1.doctor" | grep -v '^dlopen.ffmpeg.tried=' | cut -c1-330 | sed 's/^/   /'
}
want() {  # <arm> <key> <value>
  local got; got="$(val "$2" "$WORK/$1.doctor")"
  [ "$got" = "$3" ] || fail "$1: doctor $2='$got', want '$3'"
}
want_re() {  # <arm> <key> <ERE>
  local got; got="$(val "$2" "$WORK/$1.doctor")"
  grep -qE "$3" <<< "$got" || fail "$1: doctor $2='$got' does not match /$3/"
}

# play <arm> <abi>: one windowed run of the rn-core video route (rate 1, shots 500
# and 1500 ms after ready). The frame number is painted into every frame as 9
# bit blocks, so it is read from the capture PIXELS, not from the player.
play() {
  local tag="$1" abi="$2" rc=0 k A B ka kb
  mkdir -p "$WORK/$tag-tmp"
  ( cd / && TMPDIR="$WORK/$tag-tmp" RNI_VIDEO_LOG=1 xvfb-run -a -f "$WORK/$tag.xauth" -s "-screen 0 1280x1024x24" \
      "$WORK/$tag.run" --window --probe-banner off --prewarm off --bundle "$BUNDLE" --app-name RnCore \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --idle-skip --idle-run-sec "$IDLE" \
      --initial-url "rncore://video?src=$MP4&mode=play&rate=1&start=500&gap=1000" ) > "$WORK/$tag.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$tag.log" >&2; fail "$tag play: engine exited $rc"; }
  grep -E 'RNCORE_VIDEO (ready|error)|video id=1 (open|error)' "$WORK/$tag.log" | cut -c1-200 | sed 's/^/   /'
  grep -q 'RNCORE_VIDEO ready backend=ffmpeg w=320 h=180 duration=12.000' "$WORK/$tag.log" || fail "$tag play: no ready line"
  grep -q "video id=1 open 320x180 codec=h264 .* ffmpeg_abi=$abi\$" "$WORK/$tag.log" ||
    fail "$tag play: the decoder that opened the file is not the ffmpeg $abi copy"
  local dec="rn-impeller: VIDEO_DECODER source=1 codec=h264 hw=0 convert=sws" off="${PLAY_HW_OFF:-no h264_rkmpp decoder in this ffmpeg}"
  [ "$(grep -c 'VIDEO_DECODER ' "$WORK/$tag.log")" = 1 ] && grep -q "$dec\$" "$WORK/$tag.log" ||
    fail "$tag play: want exactly one '$dec', got: $(grep 'VIDEO_DECODER' "$WORK/$tag.log" | head -3 | tr '\n' '|')"
  grep -qF "rn-impeller: video id=1 hw decode off: $off" "$WORK/$tag.log" ||
    fail "$tag play: no 'hw decode off: $off' line, got: $(grep -m1 'hw decode off' "$WORK/$tag.log")"
  k="$(sed -n 's/.*video_frame id=1 seq=[0-9]* pts=\([0-9.]*\) .*/\1/p' "$WORK/$tag.log" | sort -u | wc -l)"
  [ "$k" -ge 2 ] || fail "$tag play: $k distinct decoded frame pts (want >= 2)"
  for t in A B; do
    local f; f="$(grep -m1 "RNCORE_VIDEO shot tag=$t " "$WORK/$tag.log" | sed -n 's/.* uri=file:\/\///p')"
    [ -s "$f" ] || fail "$tag play: no capture $t"
    eval "$t=\$f"
  done
  ka="$(python3 "$CHK" framenum "$A" 0 0)" || fail "$tag play: capture A frame number unreadable ($ka)"
  kb="$(python3 "$CHK" framenum "$B" 0 0)" || fail "$tag play: capture B frame number unreadable ($kb)"
  [ "$kb" -gt "$ka" ] || fail "$tag play: captured frames A=$ka B=$kb did not advance"
  ok "$tag plays on ffmpeg $abi: $k decoded frames, captures read back from the engine show frame $ka then $kb ($dec; $off)"
}

headless() {  # <arm> <tag> <url>: 400x300, log + ppm
  local rc=0
  ( cd / && "$WORK/$1.run" --headless --probe-banner off --prewarm off --bundle "$BUNDLE" --app-name RnCore \
      --width 400 --height 300 --scale 1 --supersample-rnsvg 0 --initial-url "$3" --screenshot "$WORK/$2.ppm" ) \
      > "$WORK/$2.log" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { tail -8 "$WORK/$2.log" >&2; fail "$1: $2 exited $rc (the engine must start without ffmpeg)"; }
}

arm_pkg() {
  echo "== PKG: ffmpeg 8 libs, NEEDED, copy isolation =="
  bash "$ROOT/tools/ffmpeg8-fetch.sh" --arch "$ARCH" --check > "$WORK/fetch-check.log" 2>&1 ||
    { cat "$WORK/fetch-check.log" >&2; fail "PKG: tools/ffmpeg8-fetch.sh --arch $ARCH --check"; }
  ok "$(grep -c 'SONAME .* ok' "$WORK/fetch-check.log") sonames: $(sed -n 's/.*SONAME \(\S*\) ok.*/\1/p' "$WORK/fetch-check.log" | tr '\n' ' ')"
  local n; n="$($R -d "$PKG/rn-impeller" | grep -E 'NEEDED.*\[lib(av|sw)' || true)"
  [ -z "$n" ] || fail "PKG: rn-impeller links ffmpeg by name: $n"
  ok "rn-impeller NEEDS no libav*/libsw* (dlopen only)"
  if [ -n "${RNI_FF8_ENGINE_DIR:-}" ]; then echo "   (copy isolation skipped: RNI_FF8_ENGINE_DIR is not this tree's build)"; return 0; fi
  local src shared bad n_shared=0
  weak() { "$NM" --defined-only "$1" | awk '$2 ~ /^[WVu]$/ {print $3}' | sort -u; }
  for src in FfmpegCopy FfmpegCopyInput FfmpegCopyHw; do  # every per-copy source (engine/CMakeLists.txt)
    local o8="$EB/CMakeFiles/rni-video-ffmpeg8.dir/video/$src.cpp.o" o6="$EB/CMakeFiles/rni-video-ffmpeg6.dir/video/$src.cpp.o"
    [ -f "$o8" ] && [ -f "$o6" ] || fail "PKG: copy objects missing ($o8, $o6)"
    shared="$(comm -12 <(weak "$o8") <(weak "$o6"))"
    bad="$(c++filt <<< "$shared" | grep -E '\bAV[A-Z]|Sws|SwsContext|ffv::copy' || true)"
    [ -z "$bad" ] || fail "PKG: the ffmpeg 8 and 6 copies of $src share symbols that name ffmpeg types: $bad"
    n_shared=$((n_shared + $(grep -c . <<< "$shared" || true)))
  done
  ok "copies 8 and 6 (FfmpegCopy, FfmpegCopyInput, FfmpegCopyHw) share $n_shared weak symbols, none naming an ffmpeg type"
}

arm_cfg() {
  echo "== CFG: no ffmpeg 8 headers must fail at configure =="
  grep -q 'video backend ffmpeg (dlopen), copies: 8;6' "$ROOT/engine/build-linux-x64/engine.cfg.log" ||
    fail "CFG: the staged x64 build's configure did not build copies 8;6"
  local rc=0 missing="$WORK/no-ffmpeg8"
  cmake -S "$ROOT/engine" -B "$WORK/cfg" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DRNI_WITH_WINDOW=ON -DRNI_X11_DLOPEN=ON -DRNI_WITH_WAYLAND=ON -DGLFW_DIR="$ROOT/engine/build-linux-x64/glfw-install" \
    -DRNI_FFMPEG8_DIR="$missing" > "$WORK/cfg.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "CFG: configure with no ffmpeg 8 headers SUCCEEDED (it would build a video-less linux package)"
  tr -s ' \n' ' ' < "$WORK/cfg.log" | grep -qF "ffmpeg 8 headers missing: $missing/include" ||
    { tail -8 "$WORK/cfg.log" >&2; fail "CFG: configure failed, but not naming $missing/include"; }
  ok "configure exited $rc: ffmpeg 8 headers missing: $missing/include"
}

arm_f8() {
  echo "== F8: only ffmpeg 8.0.1 ($ARCH) =="
  if [ "$ARCH" = arm64 ]; then mkrun F8 container "" "$FF8" ""; else mkrun F8 container "" "$FF8" "$V6"; fi
  doctor F8
  want F8 dlopen.ffmpeg.8 ok
  want_re F8 dlopen.ffmpeg.6 '^missing:'
  want F8 dlopen.ffmpeg.resolved 8
  want F8 video.ffmpeg_abi 8
  want F8 video.ffmpeg_abis_built 8,6
  want F8 video.status ok
  play F8 8
}

arm_hw0() {
  echo "== HW0: RNI_VIDEO_HW=0 forces the software decoder ($ARCH) =="
  if [ "$ARCH" = arm64 ]; then mkrun HW0 container "" "$FF8" ""; else mkrun HW0 container "" "$FF8" "$V6"; fi
  RNI_VIDEO_HW=0 PLAY_HW_OFF="RNI_VIDEO_HW=0" play HW0 8
}

arm_f6() {
  echo "== F6: the host's ffmpeg 6.1 only =="
  /sbin/ldconfig -p | grep -q 'libavcodec\.so\.60 ' || fail "F6: this host has no ffmpeg 6.1 (libavcodec.so.60)"
  mkrun F6 native "" "" ""
  doctor F6
  want_re F6 dlopen.ffmpeg.8 '^missing:'
  want F6 dlopen.ffmpeg.6 ok
  want F6 dlopen.ffmpeg.resolved 6
  want F6 video.ffmpeg_abi 6
  want F6 video.status ok
  play F6 6
}

arm_f86() {
  echo "== F86: ffmpeg 8 and 6 both present =="
  mkrun F86 native "$FF8" "" ""
  doctor F86
  want F86 dlopen.ffmpeg.8 ok
  want F86 dlopen.ffmpeg.6 ok
  want F86 dlopen.ffmpeg.resolved 8
  want F86 video.ffmpeg_abi 8
  want F86 video.status ok
  play F86 8
}

arm_f0() {
  echo "== F0: no ffmpeg =="
  if [ "$ARCH" = arm64 ]; then mkrun F0 container "" "" ""; else mkrun F0 container "" "" "$V6"; fi
  doctor F0
  want_re F0 dlopen.ffmpeg.8 '^missing:'
  want_re F0 dlopen.ffmpeg.6 '^missing:'
  want F0 dlopen.ffmpeg.resolved none
  want F0 video.ffmpeg_abi 8
  want F0 video.ffmpeg_abis_built 8,6
  want_re F0 video.status '^unusable:.*libavutil\.so\.60'
  headless F0 f0-image "rncore://image?mode=cover"
  [ "$(grep -c 'RNCORE_IMAGE onLoad' "$WORK/f0-image.log" || true)" -eq 3 ] || fail "F0: the image screen did not load its 3 images"
  python3 "$CHK" image "$WORK/f0-image.ppm" cover > "$WORK/f0-image.check" 2>&1 ||
    { cat "$WORK/f0-image.check" >&2; fail "F0: with no ffmpeg the engine did not paint the image screen"; }
  ok "engine starts and paints the board image screen with no ffmpeg (pixel rules pass)"
  headless F0 f0-video "rncore://video?src=$MP4&mode=play"
  grep -q 'ImpellerVideo.create: video needs ffmpeg 8, 6 .*libavutil\.so\.60' "$WORK/f0-video.log" ||
    fail "F0: creating a player did not hand JS the selector's error"
  ok "creating a player rejects with: $(grep -m1 -o 'ImpellerVideo.create: [^]]*' "$WORK/f0-video.log" | cut -c1-120)..."
}

arm_fm() {
  echo "== FM: the ffmpeg 6 copy pointed at ffmpeg 8 libs =="
  python3 "$ROOT/tools/ffmpeg_soname_swap.py" "$FF8" "$WORK/fake6" | sed 's/^/ /'
  if [ "$ARCH" = arm64 ]; then mkrun FM container "" "$WORK/fake6" ""; else mkrun FM native "$WORK/fake6" "" ""; fi
  doctor FM
  want_re FM dlopen.ffmpeg.8 '^missing:'
  want FM dlopen.ffmpeg.6 ok
  want_re FM video.status '^unusable:.*ffmpeg 6 refused: libavutil\.so\.58 reports major 60 \(compiled against 58\)'
  ok "the 6 sonames load, and the copy refuses them: majors 60/62/62/9 are not 58/60/60/7"
}

for a in $ARMS; do
  case "$a" in
    PKG) arm_pkg ;; CFG) arm_cfg ;; F8) arm_f8 ;; HW0) arm_hw0 ;; F6) arm_f6 ;; F86) arm_f86 ;; F0) arm_f0 ;; FM) arm_fm ;;
    *) fail "unknown arm $a" ;;
  esac
done
echo "VIDEO_FF8_PASS arch=$ARCH arms=\"$ARMS\" engine=$(sha256sum "$PKG/rn-impeller" | cut -c1-16)$([ "$ARCH" = arm64 ] && echo ' (qemu-aarch64 + llvmpipe; A76 software decode time UNVERIFIED-ON-HARDWARE)')"
