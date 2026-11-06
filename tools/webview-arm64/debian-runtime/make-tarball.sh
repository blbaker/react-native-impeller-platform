#!/usr/bin/env bash
# Build the self-contained linux-arm64 web helper drop for the board (Yocto board image):
# rni-webhelper from <engine-sha>:engine/webview/helper + Debian sid's arm64 WPE WebKit
# 2.54 + every library the image lacks. Output: one tarball that unpacks next to
# rn-impeller; install and acceptance are in README-tarball.txt.
#
#   bash tools/webview-arm64/debian-runtime/make-tarball.sh [engine-sha]   (default HEAD)
#
# Runs in an arm64 debian:sid container under qemu (needs binfmt, see
# docs/eng/webview-wpe.md). sid moves: the WebKit/glib versions a rebuild picks
# up are recorded in rni-wpe/share/DEBIAN-VERSIONS.txt inside the tarball.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SHA="$(git -C "$ROOT" rev-parse --short "${1:-HEAD}")"
W="${RNI_WPE_DEB_DIR:-$HOME/.cache/rni/wpe-arm64-debian}"
C="rni-wpe-sid-$$"
fail() { echo "MAKE_TARBALL_FAIL: $*" >&2; exit 1; }
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT

[ "$(docker run --rm --platform linux/arm64 debian:sid uname -m)" = aarch64 ] \
  || fail "no arm64 emulation (docker run --privileged --rm tonistiigi/binfmt --install arm64)"
rm -rf "$W/src" "$W/out"; mkdir -p "$W/src" "$W/out"
git -C "$ROOT" archive "$SHA" engine/webview | tar -x -C "$W/src"
cp "$HERE/rni-no-sandbox.c" "$W/src/"
docker run -d --name "$C" --platform linux/arm64 -v "$W/src:/src:ro" -v "$W/out:/out" debian:sid sleep infinity >/dev/null
docker cp "$HERE/stage.py" "$C:/stage.py"
docker exec "$C" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends libwpewebkit-2.0-dev glib-networking \
  g++ gcc pkg-config patchelf file binutils ca-certificates python3 >/dev/null
H=/src/engine/webview/helper
g++ -std=c++17 -O2 -Wall -Wno-deprecated-declarations $H/main.cpp $H/view.cpp $H/frames.cpp $H/input.cpp \
  -o /out/rni-webhelper $(pkg-config --cflags --libs wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0)
gcc -O2 -Wall -o /out/rni-no-sandbox /src/rni-no-sandbox.c
/out/rni-webhelper --version'
docker exec -e HOST_UID="$(id -u)" "$C" python3 /stage.py > "$W/stage.log" 2>&1 || { tail -20 "$W/stage.log"; fail "stage.py"; }
grep -E '^(PATCHED|KEPT_ON_IMAGE|BUNDLED)' "$W/stage.log"

S="$W/out/stage"
mkdir -p "$S/rni-wpe/share"
sed "s/@SHA@/$SHA/g" "$HERE/README-tarball.txt" > "$S/rni-wpe/share/README.txt"
docker exec "$C" sh -c 'dpkg-query -W -f "\${Package} \${Version}\n"' \
  | grep -E '^(libwpewebkit-2.0-1|libsoup-3.0-0|libglib2.0-0t64|glib-networking|libstdc\+\+6|libc6|libicu[0-9]+|libgnutls30t64|libgstreamer1.0-0) ' \
  > "$S/rni-wpe/share/DEBIAN-VERSIONS.txt"
WK="$(awk '$1=="libwpewebkit-2.0-1"{split($2,v,"-"); print v[1]}' "$S/rni-wpe/share/DEBIAN-VERSIONS.txt")"
[ -n "$WK" ] || fail "no libwpewebkit-2.0-1 version recorded"
( cd "$S" && find . -type f ! -name MANIFEST.sha256 | sort | xargs sha256sum > rni-wpe/share/MANIFEST.sha256 \
  && chmod -R u+rwX,go+rX,go-w . )
T="$W/rni-webhelper-linux-arm64-$SHA-wpe$WK.tar.gz"
tar --owner=0 --group=0 -C "$S" -czf "$T" bin rni-wpe
echo "TARBALL $T $(stat -c %s "$T") bytes sha256 $(sha256sum "$T" | cut -d' ' -f1)"
