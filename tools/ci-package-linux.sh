#!/usr/bin/env bash
# linux matrix M7 gate: the engine-linux-arm64 TARBALL against the image contract
# (docs/IMAGE-REQUIREMENTS.md). qemu-aarch64 + Mesa llvmpipe only: everything
# that needs the board is UNVERIFIED-ON-HARDWARE.
#
#   bash tools/ci-package-linux.sh [--arms "P D M V W"]
#
# The requirements image is arm64 Debian bookworm with EXACTLY the packages
# listed between the "ci-package-linux: bookworm packages" markers in
# docs/IMAGE-REQUIREMENTS.md, nothing else (no Weston, no X, no ffmpeg).
#   P  the tarball: four binaries + BUILD-INFO and nothing else, all aarch64,
#      rn-impeller and rni-webhelper rpath $ORIGIN, the BUILD-INFO facts
#   D  the tarball unpacked INSIDE the requirements image (/opt/rn-impeller):
#      `rn-impeller --doctor` exits 0 with image.needed_status=ok,
#      image.missing=none, image.status=ok, headless EGL ok, GLFW's Wayland
#      libraries all ok, ffmpeg copies 8,6. Bookworm has no WPE 2.54, so the
#      doctor must REPORT the helper's missing library (webhelper.check=fail
#      naming it); arm W proves the helper where WPE 2.54 exists.
#   M  the M3 matrix (tools/ci-matrix-arm64.sh: rn-core screen arm64-vs-x64,
#      wl_touch taps, X11) from the unpacked tarball, in the requirements image
#      plus a test harness layer (Weston, Xvfb, rni-touch-inject). The harness
#      pulls libraries of its own, so minimality is arm D's job, not this one's.
#   V  the same harness image plus card 12's ffmpeg 8.0.1 arm64 libraries: the
#      F8 arm of tools/ci-video-ffmpeg8.sh from the unpacked tarball (doctor
#      video.ffmpeg_abi=8 + video.status=ok, and the rn-core video plays)
#   W  the unpacked tarball's rn-impeller + rni-webhelper in the M5 web view
#      image (rni-webview-arm64:sid, WPE 2.54.0): the doctor's
#      webhelper.check=ok, then tools/ci-webview-arm64.sh's default arms
#
# Env: RNI_PKG_TARBALL (default dist/engine-linux-arm64.tar.gz; built by
#      tools/package-engine-linux.sh when absent)
#      RNI_IMGREQ_DROP="pkg ..." mutation check only: leave packages out of the
#      requirements image (tools/mutation-verify-package-linux.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARM=setup
fail() { echo "PACKAGE_LINUX_FAIL[$ARM]: $*" >&2; exit 1; }
say() { echo "== $* =="; }
ARMS="P D M V W"
[ "${1:-}" = "--arms" ] && ARMS="${2:?--arms \"P D M V W\"}"
TGZ="${RNI_PKG_TARBALL:-$ROOT/dist/engine-linux-arm64.tar.gz}"
[ -f "$TGZ" ] || bash tools/package-engine-linux.sh --arch arm64 >/dev/null
[ -f "$TGZ" ] || fail "no tarball at $TGZ"
TGZ="$(readlink -f "$TGZ")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-pkg-linux.XXXXXX")"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/u" && tar -xzf "$TGZ" -C "$WORK/u"
E="$WORK/u/engine-linux-arm64"
echo "tarball: $(basename "$TGZ") sha256=$(sha256sum "$TGZ" | cut -c1-16) git=$(sed -n 's/^package_git=//p' "$E/BUILD-INFO")"

# The requirement list comes from the doc itself, so the two cannot drift.
DOC=docs/IMAGE-REQUIREMENTS.md
PKGS="$(sed -n '/ci-package-linux: bookworm packages begin/,/ci-package-linux: bookworm packages end/p' "$DOC" \
  | grep -v -e '^<!--' -e '^```' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')"
[ -n "$PKGS" ] || fail "no package list between the markers in $DOC"
for d in ${RNI_IMGREQ_DROP:-}; do
  echo " $PKGS " | grep -q " $d " || fail "RNI_IMGREQ_DROP=$d is not in the list (a vacuous drop)"
  PKGS="$(echo " $PKGS " | sed "s/ $d / /; s/^ //; s/ $//")"
done
TAG="$(printf '%s' "$PKGS" | sha256sum | cut -c1-12)"
REQIMG="rni-imagereq-arm64:$TAG"
echo "requirements: $PKGS"
[ -n "${RNI_IMGREQ_DROP:-}" ] && echo "MUTATION: dropped from the requirements image: $RNI_IMGREQ_DROP"
if ! docker image inspect "$REQIMG" >/dev/null 2>&1; then
  say "build $REQIMG (bookworm arm64 + the requirement list only)"
  printf 'FROM --platform=linux/arm64 debian:bookworm\nRUN apt-get -o Acquire::Retries=3 update \\\n && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s \\\n && rm -rf /var/lib/apt/lists/*\n' "$PKGS" \
    | docker build --platform linux/arm64 -t "$REQIMG" - > "$WORK/reqimg.log" 2>&1 \
    || { tail -20 "$WORK/reqimg.log" >&2; fail "docker build $REQIMG"; }
fi
for d in ${RNI_IMGREQ_DROP:-}; do
  if docker run --rm --platform linux/arm64 "$REQIMG" dpkg -s "$d" >/dev/null 2>&1; then
    fail "dropped package $d is installed anyway (a dependency pulls it in): the drop is vacuous"
  fi
done

want() {  # want <key> <ERE> <doctor output>
  local v; v="$(sed -n "s/^$1=//p" "$3" | head -1)"
  echo "$v" | grep -Eq "$2" || fail "$1='$v', want /$2/"
  echo "   $1=$(echo "$v" | cut -c1-150)"
}

for A in $ARMS; do
  ARM="$A"
  case "$A" in
  P)
    say "P: tarball layout, rpath, BUILD-INFO"
    LIST="$(tar -tzf "$TGZ" | sort | tr '\n' ' ')"
    [ "$LIST" = "engine-linux-arm64/ engine-linux-arm64/BUILD-INFO engine-linux-arm64/libhermesvm.so engine-linux-arm64/libimpeller.so engine-linux-arm64/rn-impeller engine-linux-arm64/rni-webhelper " ] \
      || fail "tarball holds: $LIST"
    for f in rn-impeller rni-webhelper libimpeller.so libhermesvm.so; do
      file -b "$E/$f" | grep -q 'ARM aarch64' || fail "$f is not aarch64"
    done
    for f in rn-impeller rni-webhelper; do
      rp="$(readelf -d "$E/$f" | sed -n 's/.*R\(UN\)\{0,1\}PATH.*\[\(.*\)\]/\2/p')"
      [ "$rp" = '$ORIGIN' ] || fail "$f rpath is '$rp', not \$ORIGIN"
      echo "   $f rpath=\$ORIGIN"
    done
    B="$E/BUILD-INFO"
    want package_git '^[0-9a-f]{7,}' "$B"
    want sdk 'sha=[0-9a-f]{40}' "$B"
    want sysroot 'sha256:[0-9a-f]{64}' "$B"
    want wpe_webkit_built_against '^2\.54\.' "$B"
    want wpe_runtime_bundled '^no ' "$B"
    want glibc_floor '^GLIBC_2\.[0-9]+ \(engine GLIBC_2\.[0-9]+, rni-webhelper GLIBC_2\.[0-9]+\)' "$B"
    want glibcxx_floor '^GLIBCXX_3\.4\.[0-9]+' "$B"
    want ffmpeg_abis_built '^8,6 ' "$B"
    want ffmpeg8_headers '^n8\.0\.1 ' "$B"
    ;;
  D)
    say "D: --doctor inside $REQIMG (tarball unpacked to /opt/rn-impeller)"
    set +e
    docker run --rm --platform linux/arm64 -e HOME=/root -e LIBGL_ALWAYS_SOFTWARE=1 -v "$TGZ:/pkg.tgz:ro" "$REQIMG" \
      sh -c 'mkdir -p /opt/rn-impeller && tar -xzf /pkg.tgz -C /opt/rn-impeller && /opt/rn-impeller/engine-linux-arm64/rn-impeller --doctor' \
      > "$WORK/doctor.out" 2> "$WORK/doctor.err"
    rc=$?; set -e
    [ "$rc" = 0 ] || fail "rn-impeller --doctor exit $rc: $(grep -m1 -E 'error|cannot' "$WORK/doctor.err" || tail -1 "$WORK/doctor.err")"
    O="$WORK/doctor.out"
    want doctor.done '^1$' "$O"
    want doctor.exe '^/opt/rn-impeller/engine-linux-arm64/rn-impeller$' "$O"
    want image.needed_status '^ok$' "$O"
    want image.missing '^none$' "$O"
    want image.status '^ok$' "$O"
    want egl.headless_init '^ok$' "$O"
    want window.glfw_needs.wayland '^libwayland-client\.so\.0:ok,libwayland-cursor\.so\.0:ok,libwayland-egl\.so\.1:ok,libxkbcommon\.so\.0:ok$' "$O"
    want dlopen.fontconfig.resolved '^libfontconfig\.so\.1$' "$O"
    want video.ffmpeg_abis_built '^8,6$' "$O"
    want video.status '^unusable:.*libavutil\.so\.60' "$O"
    want webhelper.web_view_in_build '^1$' "$O"
    want webhelper.resolved '^/opt/rn-impeller/engine-linux-arm64/rni-webhelper$' "$O"
    # bookworm has no WPE 2.54 and glibc 2.36: the doctor must NAME what is missing.
    want webhelper.check '^fail:exit 127: .*(\.so\.[0-9]+: cannot open|GLIBC_[0-9.]+. not found)' "$O"
    ;;
  M|V)
    HTAG="$TAG-$(sha256sum tools/arm64-testenv/rni-touch-inject.c | cut -c1-8)"
    HIMG="rni-imagereq-arm64-harness:$HTAG"
    if ! docker image inspect "$HIMG" >/dev/null 2>&1; then
      say "build $HIMG ($REQIMG + Weston, Xvfb, rni-touch-inject)"
      CTX="$WORK/hctx"; mkdir -p "$CTX"; cp tools/arm64-testenv/rni-touch-inject.c "$CTX/"
      cat > "$CTX/Dockerfile" <<EOF
FROM $REQIMG
RUN apt-get -o Acquire::Retries=3 update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      weston xvfb xauth libx11-6 libxcursor1 libxi6 libxrandr2 libxinerama1 libx11-xcb1 \\
      gcc libc6-dev libweston-10-dev libwayland-dev pkg-config file binutils python3 procps \\
    && rm -rf /var/lib/apt/lists/*
COPY rni-touch-inject.c /opt/rni-tools/
RUN gcc -shared -fPIC -O2 -Wall -o /opt/rni-tools/rni-touch-inject.so /opt/rni-tools/rni-touch-inject.c \\
      \$(pkg-config --cflags --libs libweston-10 wayland-server)
EOF
      docker build --platform linux/arm64 -t "$HIMG" "$CTX" > "$WORK/himg.log" 2>&1 \
        || { tail -20 "$WORK/himg.log" >&2; fail "docker build $HIMG"; }
    fi
    if [ "$A" = M ]; then
      say "M: tools/ci-matrix-arm64.sh from the unpacked tarball in $HIMG"
      RNI_ARM64_ENGINE_DIR="$E" RNI_ARM64_IMAGE="$HIMG" bash tools/ci-matrix-arm64.sh > "$WORK/matrix.log" 2>&1 \
        || { tail -15 "$WORK/matrix.log" >&2; fail "ci-matrix-arm64 from the tarball"; }
      grep -m1 'ARM64_MATRIX_PASS' "$WORK/matrix.log" | sed 's/^/   /'
    else
      say "V: ffmpeg 8.0.1 libs + the rn-core video route (ci-video-ffmpeg8 F8) in $HIMG"
      FFRUN_IMAGE="$HIMG" RNI_FF8_ENGINE_DIR="$E" bash tools/ci-video-ffmpeg8.sh --arch arm64 --arms F8 > "$WORK/video.log" 2>&1 \
        || { tail -15 "$WORK/video.log" >&2; fail "ci-video-ffmpeg8 F8 from the tarball"; }
      grep -E 'video\.ffmpeg_abi=|video\.status=|frames? .*(then|->)|VIDEO_FFMPEG8_PASS' "$WORK/video.log" | head -6 | sed 's/^/   /'
      grep -q 'video.ffmpeg_abi=8' "$WORK/video.log" && grep -q 'video.status=ok' "$WORK/video.log" \
        || fail "the video log does not show video.ffmpeg_abi=8 and video.status=ok"
    fi
    ;;
  W)
    WIMG="${RNI_WPE_ARM64_IMAGE:-rni-webview-arm64:sid}"
    WPE="${RNI_WPE_ARM64_DIR:-$HOME/.cache/rni/wpe-arm64}/prefix"
    say "W: doctor + ci-webview-arm64 with the tarball's engine and helper in $WIMG (WPE 2.54 at /opt/rni-wpe)"
    docker run --rm --platform linux/arm64 -e HOME=/tmp -e LIBGL_ALWAYS_SOFTWARE=1 -e LD_LIBRARY_PATH=/opt/rni-wpe/lib \
      -v "$WPE:/opt/rni-wpe:ro" -v "$E:/opt/rn-impeller:ro" "$WIMG" /opt/rn-impeller/rn-impeller --doctor \
      > "$WORK/doctor-w.out" 2> "$WORK/doctor-w.err" || fail "doctor in $WIMG: exit $?"
    want webhelper.check '^ok:webkit=2\.54\.[0-9]+ built=2\.54\.[0-9]+ eme=1$' "$WORK/doctor-w.out"
    want image.optional.webview '^ok$' "$WORK/doctor-w.out"
    want image.status '^ok$' "$WORK/doctor-w.out"
    RNI_ARM64_ENGINE_DIR="$E" RNI_ARM64_WEBHELPER="$E/rni-webhelper" bash tools/ci-webview-arm64.sh > "$WORK/webview.log" 2>&1 \
      || { tail -15 "$WORK/webview.log" >&2; fail "ci-webview-arm64 from the tarball"; }
    grep -E 'PASS' "$WORK/webview.log" | tail -3 | sed 's/^/   /'
    ;;
  *) fail "unknown arm $A" ;;
  esac
done
ARM=all
echo "PACKAGE_LINUX_PASS arms: $ARMS (qemu-aarch64 + llvmpipe; libmali/Panthor UNVERIFIED-ON-HARDWARE)"
