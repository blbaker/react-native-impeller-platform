#!/usr/bin/env bash
# linux matrix M7: one tarball per linux arch, for the image recipe.
#
#   bash tools/package-engine-linux.sh --arch arm64|x64 [--out <dir>]
#     -> <out>/engine-linux-<arch>.tar.gz (+ .sha256), default out = dist/
#
# Contents (one top-level dir, engine-linux-<arch>/):
#   rn-impeller      the engine, RUNPATH $ORIGIN (finds the two libs below)
#   libimpeller.so   Impeller SDK (SC-32 text extensions)
#   libhermesvm.so   Hermes
#   rni-webhelper    the web view helper. Links the IMAGE's WPE WebKit; its
#                    build rpath (the cross build's WPE prefix) is rewritten to
#                    $ORIGIN here, so no build-machine path ships.
#   BUILD-INFO       git sha, SDK sha, sysroot sha, WPE version, glibc and
#                    GLIBCXX floors, ffmpeg copies built + header versions
# WPE WebKit, WPEPlatform, libwpe, libsoup, GLib and the OpenCDM library are NOT
# bundled: they come from the image (docs/IMAGE-REQUIREMENTS.md).
#
# Inputs: the staged package (bash tools/engine-build-linux.sh --arch <arch>)
# and the helper (bash tools/webhelper-build.sh [--arch arm64]). This script
# builds nothing. The tarball is reproducible: same inputs, same sha256.
# Env: RNI_PKG_WEBHELPER (helper path), RNI_PKG_ENGINE_DIR (staged bin dir).
# Gate: tools/ci-package-linux.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "PACKAGE_LINUX_FAIL: $*" >&2; exit 1; }
ARCH=""; OUT="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) fail "unknown argument $1" ;;
  esac
done
case "$ARCH" in
  arm64) WANT='ARM aarch64'; MULTI=aarch64-linux-gnu; HDEF="$ROOT/engine/build-webhelper-arm64/rni-webhelper" ;;
  x64) WANT='x86-64'; MULTI=x86_64-linux-gnu; HDEF="$ROOT/engine/build-webhelper/rni-webhelper" ;;
  *) fail "usage: package-engine-linux.sh --arch arm64|x64 [--out <dir>]" ;;
esac
NAME="engine-linux-$ARCH"
BIN="${RNI_PKG_ENGINE_DIR:-$ROOT/packages-engine/$NAME/bin}"
HELPER="${RNI_PKG_WEBHELPER:-$HDEF}"
R=readelf; command -v llvm-readelf >/dev/null && R=llvm-readelf
for f in rn-impeller libimpeller.so libhermesvm.so BUILD-INFO; do
  [ -f "$BIN/$f" ] || fail "no $BIN/$f (bash tools/engine-build-linux.sh --arch $ARCH)"
done
[ -x "$HELPER" ] || fail "no web helper at $HELPER (bash tools/webhelper-build.sh${ARCH/x64/} ${ARCH/x64/})"
for f in "$BIN/rn-impeller" "$BIN/libimpeller.so" "$BIN/libhermesvm.so" "$HELPER"; do
  file -L -b "$f" | grep -q "$WANT" || fail "$f is not $ARCH: $(file -L -b "$f" | cut -d, -f1-2)"
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pkg-linux.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/$NAME"; mkdir -p "$D"
cp "$BIN/rn-impeller" "$BIN/libimpeller.so" "$BIN/libhermesvm.so" "$D/"
cp "$HELPER" "$D/rni-webhelper"
python3 tools/elf_set_rpath.py "$D/rni-webhelper" '$ORIGIN' >/dev/null
chmod 0755 "$D"/rn-impeller "$D"/rni-webhelper "$D"/*.so

# rpath contract: the engine finds its two libs next to it; nothing ships a
# build-machine path. The two libs NEED only the C/C++ runtime (no rpath needed).
rpath() { $R -d "$1" | sed -n 's/.*R\(UN\)\{0,1\}PATH.*\[\(.*\)\]/\2/p'; }
[ "$(rpath "$D/rn-impeller")" = '$ORIGIN' ] || fail "rn-impeller rpath is '$(rpath "$D/rn-impeller")', not \$ORIGIN"
[ "$(rpath "$D/rni-webhelper")" = '$ORIGIN' ] || fail "rni-webhelper rpath is '$(rpath "$D/rni-webhelper")', not \$ORIGIN"
for f in libimpeller.so libhermesvm.so; do
  [ -z "$(rpath "$D/$f")" ] || [ "$(rpath "$D/$f")" = '$ORIGIN' ] || fail "$f carries rpath $(rpath "$D/$f")"
done
needed() { $R -d "$1" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
ENEED="$(needed "$D/rn-impeller")"
for bad in 'libX[A-Za-z0-9-]*\.so' 'libGL\.so' 'libGLX' 'libOpenGL' 'libmali' 'libav[a-z]*\.so' 'libsw[a-z]*\.so' 'libWPE' 'libglib'; do
  echo " $ENEED " | grep -q " $bad" && fail "rn-impeller NEEDs a forbidden library ($bad): $ENEED"
done
for want in libEGL.so.1 libGLESv2.so.2 libhermesvm.so libimpeller.so; do
  echo " $ENEED " | grep -q " $want " || fail "rn-impeller does not NEED $want: $ENEED"
done
HNEED="$(needed "$D/rni-webhelper")"
echo " $HNEED " | grep -q ' libWPEWebKit-2.0.so.1 ' || fail "rni-webhelper does not NEED libWPEWebKit-2.0.so.1: $HNEED"
# No load path from the build machine: no dynamic-section string holds a '/'.
# (Source paths inside __PRETTY_FUNCTION__ strings are text, not load paths.)
for f in "$D"/rn-impeller "$D"/rni-webhelper "$D"/*.so; do
  $R -d "$f" | grep -E 'NEEDED|R(UN)?PATH|SONAME' | grep -q '/' && fail "$(basename "$f") has a path in its dynamic section"
done

vfloor() { local p="$1"; shift; $R -V "$@" 2>/dev/null | grep -o "${p}_[0-9.]*" | sort -uV | tail -1; }
E3=("$D/rn-impeller" "$D/libimpeller.so" "$D/libhermesvm.so")
ff_ver() { sed -n 's/^#define FFMPEG_VERSION "\(.*\)"/\1/p' "$1/include/libavutil/ffversion.h" 2>/dev/null || true; }
FF8="$ROOT/engine/third_party/ffmpeg8-linux-$ARCH"; FF6="$ROOT/engine/third_party/ffmpeg-dev-linux-x64"
# ffmpeg copies built: ask the packaged binary itself (its doctor), which also
# proves the staged copy starts. arm64 runs under qemu (tools/arm64-run-engine.sh).
if [ "$ARCH" = arm64 ]; then
  DOC="$(RNI_ARM64_ENGINE_DIR="$D" bash tools/arm64-run-engine.sh --doctor 2>/dev/null)" || fail "packaged rn-impeller --doctor failed under qemu"
else
  DOC="$("$D/rn-impeller" --doctor 2>/dev/null)" || fail "packaged rn-impeller --doctor failed"
fi
ABIS="$(echo "$DOC" | sed -n 's/^video.ffmpeg_abis_built=//p')"
[ -n "$ABIS" ] && [ "$ABIS" != none ] || fail "packaged doctor reports ffmpeg copies '$ABIS' (video built as none?)"
if [ "$ARCH" = arm64 ]; then WPEPC_DEF="${RNI_WPE_ARM64_DIR:-$HOME/.cache/rni/wpe-arm64}/prefix/lib/pkgconfig/wpe-webkit-2.0.pc"
else WPEPC_DEF="$HOME/projects/wpe-impeller-probe/prefix/lib/pkgconfig/wpe-webkit-2.0.pc"; fi
WPEPC="${RNI_PKG_WPE_PC:-$WPEPC_DEF}"
WPEV="$(sed -n 's/^Version: //p' "$WPEPC" 2>/dev/null || true)"
[ -n "$WPEV" ] || fail "could not read the WPE version the helper was built against ($WPEPC)"
GIT="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- engine tools || echo -dirty)"
{
  echo "package=$NAME"
  echo "package_git=$GIT"
  grep -E '^(git|version|sdk|sysroot|glfw|flags)=' "$BIN/BUILD-INFO" | sed -e 's/^git=/engine_git=/' -e 's|^sdk=[^ ]* |sdk=|'
  echo "engine_needed=$ENEED"
  echo "glibc_floor=$(vfloor GLIBC "${E3[@]}" "$D/rni-webhelper") (engine $(vfloor GLIBC "${E3[@]}"), rni-webhelper $(vfloor GLIBC "$D/rni-webhelper"))"
  echo "glibcxx_floor=$(vfloor GLIBCXX "${E3[@]}" "$D/rni-webhelper") (engine $(vfloor GLIBCXX "${E3[@]}"), rni-webhelper $(vfloor GLIBCXX "$D/rni-webhelper"))"
  echo "ffmpeg_abis_built=$ABIS (dlopen, newest first; doctor key video.ffmpeg_abis_built)"
  echo "ffmpeg8_headers=n$(ff_ver "$FF8") ($(head -2 "$FF8/BUILD-INFO" 2>/dev/null | sed -n 's/^tarball \(sha256 [0-9a-f]*\).*/\1/p'))"
  echo "ffmpeg6_headers=$(ff_ver "$FF6")"
  echo "ffmpeg_libs_bundled=no (the image's ffmpeg 8: libavutil.so.60 libavcodec.so.62 libavformat.so.62 libswscale.so.9 libswresample.so.6)"
  echo "wpe_webkit_built_against=$WPEV"
  echo "wpe_runtime_bundled=no (WPE WebKit 2.54 + WPEPlatform, libwpe, libsoup 3, GLib and libocdm.so.1 come from the image)"
  echo "webhelper_needed=$HNEED"
  echo "webhelper_rpath=\$ORIGIN (build rpath rewritten by tools/elf_set_rpath.py)"
  echo "multiarch=$MULTI"
} > "$D/BUILD-INFO"

mkdir -p "$OUT"
EPOCH="$(git log -1 --format=%ct HEAD)"
TGZ="$OUT/$NAME.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" -C "$STAGE" -cf - "$NAME" | gzip -n -9 > "$TGZ.tmp"
mv -f "$TGZ.tmp" "$TGZ"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
echo "== $TGZ"
tar -tzvf "$TGZ" | awk '{print "   " $1, $3, $6}'
sed 's/^/   /' "$D/BUILD-INFO"
echo "PACKAGE_LINUX_OK $TGZ sha256=$(cut -d' ' -f1 "$TGZ.sha256")"
