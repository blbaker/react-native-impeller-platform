#!/usr/bin/env bash
# Drop-in RNI_BIN for the style gates (SC-41): runs the staged android-arm64
# engine (engine/build/android-stage/bin, tools/engine-build-android.sh)
# headless on a device through `adb shell`, from /data/local/tmp. No APK is
# installed and no other app is touched.
#   RNI_BIN=$PWD/tools/android-run-engine.sh bash tools/ci-style-coverage.sh
# Absolute-path inputs are pushed under $RDIR/cache (by hash), --screenshot is
# written on the device and pulled back, RNI_* env vars are forwarded.
# Device: RNI_ANDROID_SERIAL, else the attached SM-G991U1 (the S21 dev phone).
# A physical device of any other model is refused (so a personal phone that happens to be attached is never driven).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENG_DIR="${RNI_ANDROID_ENGINE_DIR:-$ROOT/engine/build/android-stage/bin}"
RDIR="${RNI_ANDROID_DIR:-/data/local/tmp/rni-style}"
WANT_MODEL="${RNI_ANDROID_MODEL:-SM-G991U1}"
die() { echo "android-run-engine: $*" >&2; exit 127; }
[ -f "$ENG_DIR/rn-impeller" ] || die "no engine in $ENG_DIR (bash tools/engine-build-android.sh)"
command -v adb >/dev/null || die "adb not on PATH"

model_of() { timeout 15 adb -s "$1" shell getprop ro.product.model 2>/dev/null | tr -d '\r'; }
SERIAL="${RNI_ANDROID_SERIAL:-}"
if [ -z "$SERIAL" ]; then
  for s in $(timeout 15 adb devices | awk 'NR>1 && $2=="device" {print $1}'); do
    [ "$(model_of "$s")" = "$WANT_MODEL" ] && { SERIAL="$s"; break; }
  done
  # Wireless debugging drops the adb transport on idle (SC-43): reconnect via the phone's mDNS advert.
  if [ -z "$SERIAL" ]; then
    for ep in $(timeout 15 adb mdns services 2>/dev/null | awk '$2 ~ /^_adb-tls-connect\._tcp/ {print $3}'); do
      timeout 20 adb connect "$ep" >/dev/null 2>&1 || continue
      if [ "$(model_of "$ep")" = "$WANT_MODEL" ]; then SERIAL="$ep"; break; fi
      timeout 10 adb disconnect "$ep" >/dev/null 2>&1
    done
  fi
  [ -n "$SERIAL" ] || die "no attached $WANT_MODEL (check adb devices)"
fi
M="$(model_of "$SERIAL")"
[ "$M" = "$WANT_MODEL" ] || [ "$(timeout 15 adb -s "$SERIAL" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')" = 1 ] \
  || die "$SERIAL is a '$M', not $WANT_MODEL or an emulator: refusing"
A() { timeout "${ADB_TO:-120}" adb -s "$SERIAL" "$@"; }

# Re-push the engine only when the staged files changed.
sum="$(cat "$ENG_DIR"/* | sha256sum | cut -c1-16)"
if [ "$(A shell cat "$RDIR/engine/.stamp" 2>/dev/null | tr -d '\r')" != "$sum" ]; then
  A shell "rm -rf $RDIR/engine && mkdir -p $RDIR/engine $RDIR/cache" >/dev/null || die "mkdir on $SERIAL failed"
  ADB_TO=600 A push "$ENG_DIR/." "$RDIR/engine/" >/dev/null || die "push engine failed"
  A shell "chmod 755 $RDIR/engine/rn-impeller && echo $sum > $RDIR/engine/.stamp" >/dev/null
fi

stage_in() {  # absolute host path -> device path of a cached copy
  local p="$1" h dst
  if [ -d "$p" ]; then h="$(cd "$p" && find . -type f -exec sha256sum {} + | sort | sha256sum | cut -c1-16)"
  else h="$(sha256sum "$p" | cut -c1-16)"; fi
  dst="$RDIR/cache/$h-$(basename "$p")"
  if [ "$(A shell "[ -e '$dst' ] && echo y" | tr -d '\r')" != y ]; then
    ADB_TO=600 A push "$p" "$dst.tmp" >/dev/null && A shell "mv '$dst.tmp' '$dst'" >/dev/null \
      || die "push $p failed"
  fi
  printf '%s' "$dst"
}

RUN="$RDIR/run.$$.$RANDOM"
ARGS=(); SHOT_OUT=""; prev=""
for a in "$@"; do
  if [ "$prev" = --screenshot ]; then SHOT_OUT="$a"; ARGS+=("$RUN/shot.ppm")
  elif [ "${a#/}" != "$a" ] && [ -e "$a" ]; then ARGS+=("$(stage_in "$a")")
  else ARGS+=("$a"); fi
  prev="$a"
done

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
CMD="mkdir -p $RUN && cd $RDIR/engine && export LD_LIBRARY_PATH=$RDIR/engine"
while IFS='=' read -r k v; do
  case "$k" in RNI_BIN|RNI_ANDROID_*|RNI_EXPECT_PLATFORM) continue ;; esac
  CMD="$CMD && export $k=$(sq "$v")"
done < <(env | grep -E '^RNI_[A-Z0-9_]*=' || true)
CMD="$CMD && ./rn-impeller"
for a in "${ARGS[@]}"; do CMD="$CMD $(sq "$a")"; done

ADB_TO="${RNI_ANDROID_TIMEOUT:-300}" A shell "$CMD" 2>&1 | tr -d '\r'
rc=${PIPESTATUS[0]}
if [ -n "$SHOT_OUT" ]; then A pull "$RUN/shot.ppm" "$SHOT_OUT" >/dev/null 2>&1 || true; fi
A shell "rm -rf $RUN" >/dev/null 2>&1
exit "$rc"
