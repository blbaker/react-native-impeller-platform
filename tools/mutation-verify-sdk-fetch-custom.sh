#!/usr/bin/env bash
# Mutation-verify tools/sdk-fetch-custom.sh: every way the fetched SDK could
# silently differ from this checkout's patches must stop it.
#
# Runs offline against a synthetic archive served over file://, in a scratch
# copy holding only what the fetch script reads. Break the WORLD (patches, pin,
# archive), never the script.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mv-sdk-fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
CAUGHT=0; TOTAL=0
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64 || shasum -a 256 "$1" | cut -c1-64; }

ENGINE_SHA="$(tr -d '[:space:]' < engine/IMPELLER_SHA)"
PATCH_SUM="$(cat engine/impeller-sdk-patches/*.patch | sha256sum | cut -c1-64)"

# world <dir> [stamp-patch-sum] [plat]: a scratch checkout + an archive served
# at file://<dir>/srv/<release>/, pinned correctly unless a mutant says
# otherwise. plat defaults to linux-x64; android-arm64 exercises the same
# path with no linux-specific behaviour (sdk-fetch-custom.sh is platform-
# agnostic beyond its case statement, so one real platform plus one cross
# platform is enough to show the pin/stamp logic isn't linux-only).
world() {
  local d="$1" stamp_patch="${2:-$PATCH_SUM}" plat="${3:-linux-x64}"
  mkdir -p "$d/tools" "$d/engine" "$d/sdk/include" "$d/srv/rel-test"
  cp tools/sdk-fetch-custom.sh "$d/tools/"
  cp engine/IMPELLER_SHA "$d/engine/"
  cp -r engine/impeller-sdk-patches "$d/engine/"
  echo '/* synthetic */' > "$d/sdk/include/impeller.h"
  printf 'sha=%s\npatch_sha256=%s\n' "$ENGINE_SHA" "$stamp_patch" > "$d/sdk/.stamp"
  tar -C "$d/sdk" -czf "$d/srv/rel-test/impeller-sdk-custom-$plat.tar.gz" .
  printf 'release=rel-test\npatch_sha256=%s\n%s=%s\n' "$PATCH_SUM" "$plat" \
    "$(sha "$d/srv/rel-test/impeller-sdk-custom-$plat.tar.gz")" > "$d/engine/IMPELLER_SDK_CUSTOM"
}
run() {  # dir [plat]
  (cd "$1" && RNI_SDK_CUSTOM_BASE_URL="file://$1/srv" bash tools/sdk-fetch-custom.sh "${2:-linux-x64}" out 2>&1)
}
check() {  # name, dir, expected-substring, [plat]
  TOTAL=$((TOTAL + 1))
  local out rc; out="$(run "$2" "${4:-linux-x64}")"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- "$3" <<<"$out"; then
    echo "  M$TOTAL $1 -> caught"; CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL $1 -> NOT caught (rc=$rc)"; echo "$out" | tail -3 | sed 's/^/      /'
  fi
}

# Positive control first: a correct world must fetch, or every mutant is free.
world "$WORK/control"
out="$(run "$WORK/control")"
if [ $? -ne 0 ] || [ ! -f "$WORK/control/out/include/impeller.h" ]; then
  echo "MUTATION_VERIFY_SDK_FETCH_CUSTOM_FAIL (control did not fetch — proves nothing)"
  echo "$out" | tail -3; exit 1
fi
out2="$(run "$WORK/control")"
grep -q "already matches" <<<"$out2" || { echo "MUTATION_VERIFY_SDK_FETCH_CUSTOM_FAIL (second run re-fetched)"; exit 1; }
echo "control: fetches, then reuses the matching copy"

# M1: a patch is edited and nobody rebuilt the SDK.
world "$WORK/m1"; echo '# edited' >> "$(ls "$WORK"/m1/engine/impeller-sdk-patches/*.patch | head -1)"
check "a patch changed, the pinned SDK did not" "$WORK/m1" "patches in engine/impeller-sdk-patches changed"

# M2: the downloaded archive is not the one that was pinned.
world "$WORK/m2"; sed -i.bak 's/^linux-x64=.*/linux-x64=0000000000000000000000000000000000000000000000000000000000000000/' "$WORK/m2/engine/IMPELLER_SDK_CUSTOM"
check "archive sha256 differs from the pin" "$WORK/m2" "sha256 mismatch"

# M3: an archive built from OTHER patches, pinned by its true sha (someone
# uploaded the wrong build and pinned it faithfully).
world "$WORK/m3" "1111111111111111111111111111111111111111111111111111111111111111"
check "archive built from different patches" "$WORK/m3" "does not match this checkout"

# M4: a stale SDK already on disk from an older patch set must be replaced,
# not reused because a directory with an impeller.h exists.
world "$WORK/m4"; mkdir -p "$WORK/m4/out/include"; echo stale > "$WORK/m4/out/include/impeller.h"
printf 'sha=%s\npatch_sha256=%s\n' "$ENGINE_SHA" "2222222222222222222222222222222222222222222222222222222222222222" > "$WORK/m4/out/.stamp"
TOTAL=$((TOTAL + 1)); out="$(run "$WORK/m4")"
if grep -q "downloading" <<<"$out" && grep -qx "patch_sha256=$PATCH_SUM" "$WORK/m4/out/.stamp"; then
  echo "  M$TOTAL stale SDK on disk is replaced -> caught"; CAUGHT=$((CAUGHT + 1))
else
  echo "  M$TOTAL stale SDK on disk is replaced -> NOT caught (it was reused)"
fi

# Positive control: android-arm64 fetches through the exact same path as
# linux-x64 — the platform cases differ only in their default dest, so one
# cross-platform run is enough to show the pin/stamp logic isn't linux-only.
world "$WORK/control-android" "$PATCH_SUM" android-arm64
out="$(run "$WORK/control-android" android-arm64)"
if [ $? -ne 0 ] || [ ! -f "$WORK/control-android/out/include/impeller.h" ]; then
  echo "MUTATION_VERIFY_SDK_FETCH_CUSTOM_FAIL (android-arm64 control did not fetch)"
  echo "$out" | tail -3; exit 1
fi
echo "control: android-arm64 fetches through the same path as linux-x64"

# M5: android-arm64 is requested but the pin file carries no archive line for
# it (the desktop platforms' lines were updated and android's forgotten).
world "$WORK/m5" "$PATCH_SUM" android-arm64
sed -i '/^android-arm64=/d' "$WORK/m5/engine/IMPELLER_SDK_CUSTOM"
check "android-arm64 requested, nothing pinned for it" "$WORK/m5" "pins no archive for android-arm64" android-arm64

echo
if [ "$CAUGHT" -eq "$TOTAL" ]; then echo "MUTATION_VERIFY_SDK_FETCH_CUSTOM_PASS ($CAUGHT/$TOTAL)"; exit 0; fi
echo "MUTATION_VERIFY_SDK_FETCH_CUSTOM_FAIL ($((TOTAL - CAUGHT)) of $TOTAL not caught)"; exit 1
