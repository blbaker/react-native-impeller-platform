#!/usr/bin/env bash
# Produce engine/third_party/sysroot-linux-arm64: a Debian bookworm aarch64
# sysroot for cross-building the engine on an x86_64 linux host.
#
# Why bookworm (glibc 2.36, libstdc++ from gcc 12, OpenSSL 3.0): the target
# image is Yocto wrynose (glibc and libstdc++ are NEWER there), and glibc /
# libstdc++ are backward compatible, so a binary linked against bookworm loads
# on wrynose. The reverse is not true. Flutter's bullseye arm64 sysroot was the
# other candidate; its libstdc++ (gcc 10) predates std::bit_cast and other C++20
# pieces ReactCommon uses.
#
# Source of truth is a docker image (tools/arm64-testenv/Dockerfile.sysroot);
# arm64 images need binfmt qemu-aarch64 registered on the host:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#
# Usage: bash tools/arm64-sysroot.sh [dest]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-engine/third_party/sysroot-linux-arm64}"
IMG_RT=rni-arm64-testenv:bookworm
IMG=rni-arm64-sysroot:bookworm
say() { echo "[arm64-sysroot] $*"; }

[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
  echo "binfmt qemu-aarch64 is not registered; run: docker run --privileged --rm tonistiigi/binfmt --install arm64" >&2; exit 1; }
docker image inspect "$IMG_RT" >/dev/null 2>&1 || {
  say "building $IMG_RT"; docker build --platform linux/arm64 -t "$IMG_RT" tools/arm64-testenv; }
docker image inspect "$IMG" >/dev/null 2>&1 || {
  say "building $IMG"; docker build --platform linux/arm64 -t "$IMG" -f tools/arm64-testenv/Dockerfile.sysroot tools/arm64-testenv; }

TMP="$(mktemp -d "$(dirname "$DEST")/.sysroot.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CID="$(docker create --platform linux/arm64 "$IMG" true)"
say "exporting usr/include, usr/lib, usr/share/{pkgconfig,wayland-protocols,wayland}"
docker export "$CID" | tar -x -C "$TMP" --wildcards \
  'usr/include/*' 'usr/lib/aarch64-linux-gnu/*' 'usr/lib/gcc/*' 'usr/lib/ld-linux-aarch64.so.1' \
  'usr/share/pkgconfig/*' 'usr/share/wayland-protocols/*' 'usr/share/wayland/*' \
  'lib' 'lib64' 2>/dev/null || true
docker rm "$CID" >/dev/null

# Absolute symlinks (e.g. libz.so -> /lib/aarch64-linux-gnu/libz.so.1.2.13)
# point at the HOST's filesystem from inside a sysroot; make them relative.
python3 - "$TMP" <<'PY'
import os, sys
root = os.path.abspath(sys.argv[1]); fixed = 0
for d, dirs, files in os.walk(root):
    for n in dirs + files:
        p = os.path.join(d, n)
        if os.path.islink(p):
            t = os.readlink(p)
            if t.startswith('/'):
                tgt = os.path.join(root, t.lstrip('/'))
                os.unlink(p); os.symlink(os.path.relpath(tgt, d), p); fixed += 1
print(f"[arm64-sysroot] relativised {fixed} absolute symlinks")
PY
for f in usr/lib/aarch64-linux-gnu/libc.so.6 usr/include/wayland-client.h usr/include/xkbcommon/xkbcommon.h \
         usr/include/EGL/egl.h usr/include/GLES3/gl3.h usr/include/openssl/ssl.h usr/include/X11/Xlib.h \
         usr/lib/aarch64-linux-gnu/libssl.a usr/lib/aarch64-linux-gnu/libcrypto.a; do
  [ -e "$TMP/$f" ] || { echo "sysroot is missing $f" >&2; exit 1; }
done
rm -rf "$DEST"; mv "$TMP" "$DEST"; trap - EXIT
echo "bookworm-arm64 $(docker image inspect -f '{{.Id}}' "$IMG")" > "$DEST/.stamp"
say "OK -> $DEST ($(du -sh "$DEST" | cut -f1))"
