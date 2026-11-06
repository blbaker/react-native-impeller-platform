#!/usr/bin/env bash
# ffmpeg 8.0.1 shared libraries + headers for the linux video backend's ffmpeg 8
# copy. The board image ships ffmpeg 8.0.1, so both linux
# packages compile engine/video/FfmpegCopy.cpp once against these headers.
#
#   bash tools/ffmpeg8-fetch.sh --arch x64|arm64     download, verify, build, link
#   bash tools/ffmpeg8-fetch.sh --arch arm64 --check  only re-check an existing install
#   bash tools/ffmpeg8-fetch.sh --arch x64 --tls      the same plus --enable-openssl, in its
#        own prefix (linux-x64-tls, linked as ffmpeg8-linux-x64-tls) for tools/ci-video-net.sh.
#        It mirrors the image change the board needs for https (docs/eng/video-net.md).
#        OpenSSL headers come from `apt-get download libssl-dev` (no root), and the
#        libs are the host's libssl.so.3, whose version must equal the -dev package's.
#
# - Downloads ffmpeg-8.0.1.tar.xz from ffmpeg.org into ~/.cache/rni/ffmpeg8 and
#   refuses it unless its sha256 is the one oe-core pins for ffmpeg_8.0.1.bb
#   (openembedded-core 22241fd, the recipe the board image builds from). The
#   measured sum is written next to the tarball.
# - Builds the five shared libs the image has: avutil 60, avcodec 62, avformat 62,
#   swscale 9, swresample 6 (libavcodec NEEDs swresample: the opus decoder).
#   arm64 is a cross build with clang + lld against engine/third_party/sysroot-linux-arm64.
# - Links engine/third_party/ffmpeg8-linux-<arch> -> the install ({include,lib}).
#
# Configure mirrors oe-core's EXTRA_OECONF (--enable-shared --enable-pic
# --enable-pthreads --disable-stripping, every built-in software decoder,
# demuxer and parser) minus external libraries. oe-core's PACKAGECONFIG adds
# alsa bzlib lzma theora zlib (+ xv xcb with x11), and the board BSP layer adds libdrm
# + rkmpp + --enable-version3. None of those touch the software h264/mp4 path
# the engine runs; this is NOT the image's binary (docs/IMAGE-REQUIREMENTS.md).
# avdevice/avfilter are off (the engine loads neither), and so are programs/docs.
# x64 also gets --disable-x86asm: this host has no nasm (oe-core uses nasm-native).
#
# Host load: nice 10, JOBS <= 10.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER=8.0.1
SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
URL="https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
CACHE="${RNI_FFMPEG8_CACHE:-$HOME/.cache/rni/ffmpeg8}"
JOBS="${JOBS:-10}"; [ "$JOBS" -le 10 ] || JOBS=10
fail() { echo "ffmpeg8-fetch: FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }

ARCH="" CHECK_ONLY=0 TLS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --tls) TLS=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
case "$ARCH" in x64|arm64) ;; *) fail "--arch x64|arm64 is required" ;; esac
SUFFIX=""
if [ "$TLS" = 1 ]; then
  [ "$ARCH" = x64 ] || fail "--tls is x64 only (the board's TLS comes from the image's ffmpeg)"
  SUFFIX="-tls"
fi
PREFIX="$CACHE/linux-$ARCH$SUFFIX"
BUILD="$CACHE/build-linux-$ARCH$SUFFIX"
LINK="$ROOT/engine/third_party/ffmpeg8-linux-$ARCH$SUFFIX"
R=/usr/lib/llvm-18/bin/llvm-readelf; [ -x "$R" ] || R=readelf

# The five sonames the image's ffmpeg 8.0.1 has (libav*/version_major.h at n8.0.1).
WANT="libavutil.so.60 libavcodec.so.62 libavformat.so.62 libswscale.so.9 libswresample.so.6"
check_install() {  # $1 prefix: every lib is a shared object of the right arch with the right SONAME
  local p="$1" so lib got arch=x86-64
  [ "$ARCH" = arm64 ] && arch=aarch64
  [ -f "$p/include/libavcodec/avcodec.h" ] || { echo "   no headers in $p/include"; return 1; }
  grep -q "^#define LIBAVCODEC_VERSION_MAJOR  *62" "$p/include/libavcodec/version_major.h" \
    || { echo "   headers are not avcodec 62"; return 1; }
  for so in $WANT; do
    lib="$p/lib/$so"
    [ -e "$lib" ] || { echo "   missing $lib"; return 1; }
    file -L -b "$lib" | grep -q "ELF 64-bit.*shared object.*$arch" \
      || { echo "   $so is not a $arch shared object: $(file -L -b "$lib")"; return 1; }
    got="$($R -d "$lib" | sed -n 's/.*Library soname: \[\(.*\)\]/\1/p')"
    [ "$got" = "$so" ] || { echo "   $lib SONAME is '$got', want $so"; return 1; }
    echo "   SONAME $so ok ($(readlink "$lib" || echo file))"
  done
}

if [ "$CHECK_ONLY" = 1 ]; then
  check_install "$PREFIX" || fail "install at $PREFIX does not match ffmpeg $VER"
  [ "$(readlink -f "$LINK")" = "$(readlink -f "$PREFIX")" ] || fail "$LINK does not point at $PREFIX"
  echo "FFMPEG8_OK arch=$ARCH $PREFIX"; exit 0
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/ffmpeg-$VER.tar.xz"
if [ ! -s "$TARBALL" ]; then
  say "download $URL"
  curl -fsSL --retry 3 -o "$TARBALL.part" "$URL" || fail "download $URL"
  mv "$TARBALL.part" "$TARBALL"
fi
GOT_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
[ "$GOT_SHA" = "$SHA256" ] || fail "$TARBALL sha256 $GOT_SHA != $SHA256 (oe-core ffmpeg_8.0.1.bb)"
echo "$GOT_SHA  ffmpeg-$VER.tar.xz  (from $URL; matches oe-core ffmpeg_8.0.1.bb SRC_URI[sha256sum])" > "$TARBALL.sha256"
echo "   sha256 $GOT_SHA ok"

SRC="$CACHE/src-$VER"
if [ ! -f "$SRC/.extracted" ]; then
  say "extract"
  rm -rf "$SRC.new"; mkdir -p "$SRC.new"
  tar -xJf "$TARBALL" -C "$SRC.new" --strip-components=1
  touch "$SRC.new/.extracted"; rm -rf "$SRC"; mv "$SRC.new" "$SRC"
fi

FLAGS=(--prefix="$PREFIX" --libdir="$PREFIX/lib" --shlibdir="$PREFIX/lib" --incdir="$PREFIX/include"
       --enable-shared --disable-static --enable-pic --enable-pthreads --disable-stripping
       --disable-programs --disable-doc --disable-avdevice --disable-avfilter
       --enable-avcodec --enable-avformat --enable-swresample --enable-swscale
       --disable-autodetect)
if [ "$ARCH" = x64 ]; then
  [ "$(uname -m)" = x86_64 ] || fail "x64 builds natively on an x86_64 host"
  FLAGS+=(--disable-x86asm)
  if [ "$TLS" = 1 ]; then
    OSSL="$CACHE/openssl-dev"
    HOSTV="$(dpkg-query -W -f '${Version}' libssl3t64 2>/dev/null || dpkg-query -W -f '${Version}' libssl3)"
    [ -n "$HOSTV" ] || fail "--tls: the host has no libssl3 runtime package"
    if [ "$(cat "$OSSL/.version" 2>/dev/null || true)" != "$HOSTV" ]; then
      say "libssl-dev $HOSTV headers (apt-get download, no root)"
      rm -rf "$OSSL"; mkdir -p "$OSSL/lib"
      (cd "$OSSL" && apt-get download "libssl-dev=$HOSTV" > download.log 2>&1) || fail "--tls: apt-get download libssl-dev=$HOSTV"
      dpkg-deb -x "$OSSL"/libssl-dev_*.deb "$OSSL/x"
      # The -dev .so links are relative to a lib dir that only the runtime package fills.
      for l in ssl crypto; do ln -sfn "/usr/lib/x86_64-linux-gnu/lib$l.so.3" "$OSSL/lib/lib$l.so"; done
      echo "$HOSTV" > "$OSSL/.version"
    fi
    # configure asks pkg-config for openssl twice (https; the whip muxer), so
    # point it at the extracted headers instead of passing raw flags.
    mkdir -p "$OSSL/pkgconfig"
    printf '%s\n' "Name: OpenSSL" "Description: libssl-dev $HOSTV, extracted" "Version: ${HOSTV%%-*}" \
      "Libs: -L$OSSL/lib -lssl -lcrypto" \
      "Cflags: -I$OSSL/x/usr/include -I$OSSL/x/usr/include/x86_64-linux-gnu" > "$OSSL/pkgconfig/openssl.pc"
    export PKG_CONFIG_PATH="$OSSL/pkgconfig"
    FLAGS+=(--enable-openssl)
  fi
else
  SR="${RNI_ARM64_SYSROOT:-$ROOT/engine/third_party/sysroot-linux-arm64}"
  [ -f "$SR/usr/include/stdio.h" ] || fail "no arm64 sysroot at $SR (bash tools/arm64-sysroot.sh)"
  SR="$(readlink -f "$SR")"
  L=/usr/lib/llvm-18/bin
  XF="--target=aarch64-linux-gnu --sysroot=$SR --gcc-toolchain=$SR/usr"
  FLAGS+=(--enable-cross-compile --arch=aarch64 --target-os=linux --cc=clang --cxx=clang++
          --ar="$L/llvm-ar" --ranlib="$L/llvm-ranlib" --nm="$L/llvm-nm" --strip="$L/llvm-strip"
          --pkg-config=false --extra-cflags="$XF -march=armv8-a" --extra-ldflags="$XF -fuse-ld=lld")
fi
# The cache is shared by every worktree: key it on the sysroot's CONTENT stamp,
# not its path, so a second worktree links the same build instead of redoing it.
if [ "$ARCH" = arm64 ]; then
  KEYFLAGS=("${FLAGS[@]//$SR/<sysroot>}"); KEYSR="$(cat "$SR/.stamp" 2>/dev/null || echo unknown)"
else
  KEYFLAGS=("${FLAGS[@]}"); KEYSR=host
fi
CFG_KEY="$(printf '%s\n' "$VER" "$KEYSR" "${KEYFLAGS[@]}" | sha256sum | cut -c1-16)"

if [ "$(cat "$PREFIX/.stamp" 2>/dev/null || true)" = "$CFG_KEY" ] && check_install "$PREFIX" > /dev/null; then
  echo "   $PREFIX already built with this configure ($CFG_KEY)"
else
  say "configure ffmpeg $VER (linux-$ARCH)"
  rm -rf "$BUILD" "$PREFIX"; mkdir -p "$BUILD"
  (cd "$BUILD" && nice -n 10 "$SRC/configure" "${FLAGS[@]}") > "$BUILD/configure.out" 2>&1 \
    || { tail -25 "$BUILD/configure.out" >&2; tail -25 "$BUILD/ffbuild/config.log" >&2 || true; fail "configure"; }
  for c in H264_DECODER MOV_DEMUXER H264_PARSER HLS_DEMUXER HTTP_PROTOCOL $([ "$TLS" = 1 ] && echo HTTPS_PROTOCOL TLS_PROTOCOL); do
    grep -q "^#define CONFIG_$c 1" "$BUILD/config_components.h" || fail "configure did not enable $c"
  done
  say "build (JOBS=$JOBS, nice 10)"
  (cd "$BUILD" && nice -n 10 make -j"$JOBS" && make install) > "$BUILD/build.log" 2>&1 \
    || { grep -E 'error|Error' "$BUILD/build.log" | head -20 >&2; fail "build (log: $BUILD/build.log)"; }
  echo "$CFG_KEY" > "$PREFIX/.stamp"
fi

say "check $PREFIX"
check_install "$PREFIX" || fail "the build at $PREFIX does not have the ffmpeg $VER sonames"
NEEDED_AVCODEC="$($R -d "$PREFIX/lib/libavcodec.so.62" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
{
  echo "ffmpeg $VER linux-$ARCH, built by tools/ffmpeg8-fetch.sh (configure key $CFG_KEY)"
  echo "tarball sha256 $GOT_SHA ($URL)"
  echo "sonames: $WANT"
  echo "libavcodec.so.62 NEEDED: $NEEDED_AVCODEC"
  echo "configure: ${FLAGS[*]}"
} > "$PREFIX/BUILD-INFO"
mkdir -p "$(dirname "$LINK")"
ln -sfn "$PREFIX" "$LINK"
echo "   libavcodec.so.62 NEEDED: $NEEDED_AVCODEC"
echo "   linked $LINK -> $PREFIX"
echo "FFMPEG8_OK arch=$ARCH $PREFIX"
