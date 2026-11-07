#!/usr/bin/env bash
# rni-webhelper for linux-x64 on WSL against Debian sid's amd64 WPE WebKit 2.54: the
# same WebKit build the board tarball ships (tools/webview-arm64/debian-runtime), so
# the fast x64 loop runs the board's WebKit, not a private source build.
#
#   bash tools/webhelper-debian-x64.sh image   # docker image rni-wpe-debian:sid-x64 (~3 min)
#   bash tools/webhelper-debian-x64.sh build   # -> engine/build-webhelper-debian/rni-webhelper
#   eval "$(bash tools/webhelper-debian-x64.sh env)"   # RNI_WEBHELPER* for the gates
#
# Run time reuses tools/webhelper-docker.sh with this image. Debian's WebKit always
# sandboxes its web process with bubblewrap, which cannot run unprivileged in docker,
# so the image replaces /usr/bin/bwrap with rni-no-sandbox (its credentials handshake is
# explained in docs/eng/webview-wpe.md). The prefix mount is an EMPTY dir:
# webhelper-docker.sh puts /work/prefix/lib first on LD_LIBRARY_PATH, and the old
# source-built prefix there would shadow Debian's libWPEWebKit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${RNI_WPE_DEBIAN_IMAGE:-rni-wpe-debian:sid-x64}"
OUT="$ROOT/engine/build-webhelper-debian"
EMPTY="${RNI_WPE_DEBIAN_EMPTY_PREFIX:-$HOME/.cache/rni/wpe-debian-x64-empty-prefix}"
fail() { echo "WEBHELPER_DEBIAN_FAIL: $*" >&2; exit 1; }

case "${1:-}" in
  image)
    docker build --platform linux/amd64 -t "$IMAGE" -f - "$ROOT/tools/webview-arm64/debian-runtime" <<'EOF'
FROM debian:sid
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      libwpewebkit-2.0-dev glib-networking g++ gcc pkg-config ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY rni-no-sandbox.c /tmp/rni-no-sandbox.c
RUN gcc -O2 -Wall -o /usr/local/bin/rni-no-sandbox /tmp/rni-no-sandbox.c \
 && dpkg-divert --local --rename --add /usr/bin/bwrap \
 && ln -s /usr/local/bin/rni-no-sandbox /usr/bin/bwrap \
 && dpkg-query -W -f '${Package} ${Version}\n' libwpewebkit-2.0-1 > /DEBIAN-WEBKIT-VERSION
EOF
    docker run --rm "$IMAGE" cat /DEBIAN-WEBKIT-VERSION ;;
  build)
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "no image $IMAGE (bash $0 image)"
    mkdir -p "$OUT"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$ROOT/engine:$ROOT/engine" "$IMAGE" bash -c "
set -euo pipefail
H='$ROOT/engine/webview/helper'
g++ -std=c++17 -O2 -Wall -Wno-deprecated-declarations \$H/main.cpp \$H/view.cpp \$H/frames.cpp \$H/input.cpp \
  -o '$OUT/rni-webhelper' \
  \$(pkg-config --cflags --libs wpe-webkit-2.0 wpe-platform-2.0 wpe-platform-headless-2.0)
'$OUT/rni-webhelper' --version"
    ;;
  env)
    mkdir -p "$EMPTY"
    echo "export RNI_WEBHELPER='$ROOT/tools/webhelper-docker.sh' RNI_WPE_IMAGE='$IMAGE'" \
         "RNI_WEBHELPER_DIR='$OUT' RNI_WPE_PREFIX='$EMPTY'" ;;
  *) fail "usage: $0 image|build|env" ;;
esac
