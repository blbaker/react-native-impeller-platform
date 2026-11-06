#!/usr/bin/env bash
# Fetch the ffmpeg HEADERS the linux video backend (engine/video/VideoPlayerFfmpeg.cpp,
# the video backend) compiles against, into engine/third_party/ffmpeg-dev-linux-x64.
#
# Headers only. The engine never links ffmpeg: it dlopen()s the system shared
# libs (libavcodec.so.60, libavformat.so.60, libavutil.so.58, libswscale.so.7)
# at the first VideoPlayer create, so the binary still starts on a box without
# them (video then reports an error; nothing else changes).
#
# No root: `apt-get download` fetches the -dev debs to the cwd and `dpkg-deb -x`
# unpacks them. The -dev versions are pinned to the INSTALLED runtime libs so the
# headers match the ABI that dlopen() will load. Without this dir, CMake builds
# engine/video/VideoPlayerNone.cpp (backend "none") and ci-rn-core's video arm
# fails on its "no ffmpeg ready line" check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/engine/third_party/ffmpeg-dev-linux-x64}"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"

if [ -f "$OUT/include/libavcodec/avcodec.h" ] && [ -z "${FORCE:-}" ]; then
  echo "ffmpeg-dev: already present at $OUT ($(head -1 "$OUT/README" 2>/dev/null)); FORCE=1 to refetch"
  exit 0
fi

ver="$(dpkg-query -W -f='${Version}' libavcodec60 2>/dev/null || true)"
[ -n "$ver" ] || { echo "ffmpeg-dev: libavcodec60 is not installed (apt install libavcodec60 libavformat60 libswscale7)" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-dev.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
apt-get download "libavcodec-dev=$ver" "libavformat-dev=$ver" "libavutil-dev=$ver" "libswscale-dev=$ver" > apt.log 2>&1 ||
  { cat apt.log >&2; echo "ffmpeg-dev: apt-get download failed (run apt-get update?)" >&2; exit 1; }
for deb in ./*.deb; do dpkg-deb -x "$deb" x; done

rm -rf "$OUT.new"
mkdir -p "$OUT.new/include"
for lib in libavcodec libavformat libavutil libswscale; do
  src="x/usr/include/$MULTIARCH/$lib"
  [ -d "$src" ] || src="x/usr/include/$lib"
  [ -d "$src" ] || { echo "ffmpeg-dev: no $lib headers in the debs" >&2; exit 1; }
  cp -r "$src" "$OUT.new/include/"
done
echo "ffmpeg $ver headers (libav*-dev debs, headers only); link the system .so.60" > "$OUT.new/README"
rm -rf "$OUT"
mv "$OUT.new" "$OUT"
echo "ffmpeg-dev: $ver headers -> $OUT ($(find "$OUT/include" -name '*.h' | wc -l) headers)"
