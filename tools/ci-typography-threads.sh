#!/usr/bin/env bash
# FP-12 gate: one ImpellerTypographyContext per thread, and measure == paint.
#
# impeller.h: typography contexts "must be created, used, and collected on a single thread".
# Measure runs on the JS thread (ImpellerTextLayoutManager), paint on the main thread
# (SceneGraph); each now uses its own context (engine/text/TypographyContexts.{h,cpp}), and every
# font (--font-dir app fonts and fontconfig fallback faces) is registered into every context.
#
#   A. MEASURE == PAINT (staged release binary, headless, fixtures/fp12-typography). Four rows,
#      regular / bold / custom font (Geist Mono via --font-dir) / fallback emoji, each bracketed by
#      U+2588 FULL BLOCK so ink fills the advance. Per row: the painted ink extent's left and right
#      edges are within 1 px of the measured node_frame box. The custom row must measure 19 Geist
#      Mono cells (228 px), so the custom face reached measure, not just paint.
#   B. TWO CONTEXTS, READ BACK: the run reports typography_contexts bound>=1 (the surface's, main)
#      and own>=1 (made on the JS thread at its first measure), and fonts>=2 (app font + fallback).
#   C. TSAN (engine/build-tsan via tools/ci-tsan.sh): the FP-04 churn fixture and this fixture,
#      windowed (xvfb) and headless, show zero race reports. A typography-context race is named
#      as such by tools/tsan_check.py.
# Every failing arm prints a TYPO_THREADS_FAIL line; the gate exits 1 after all arms ran.
# Env: RNI_BIN (arm A binary), SKIP_TSAN=1 (arms A+B only, e.g. on the Mac).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ENGINE="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="$ROOT/fixtures/fp12-typography/prebuilt/fp12-typography.bundle"
FONTS="$ROOT/fixtures/eng22-font-family/fonts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-typo.XXXX")"
trap '[ "${KEEP_WORKDIR:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
FAILS=0
fail() { echo "TYPO_THREADS_FAIL: $*"; FAILS=$((FAILS + 1)); }
[ -x "$ENGINE" ] || { echo "TYPO_THREADS_FAIL: no engine at $ENGINE"; exit 1; }
[ -s "$BUNDLE" ] || { echo "TYPO_THREADS_FAIL: no bundle at $BUNDLE"; exit 1; }

echo "== A. measure == paint (headless, $ENGINE)"
"$ENGINE" --headless --bundle "$BUNDLE" --app-name Fp12Typography --probe-banner off \
  --width 400 --height 300 --supersample-rnsvg 0 --frames 20 --font-dir "$FONTS" \
  --screenshot "$WORK/frame.ppm" > "$WORK/run.log" 2>&1
rc=$?
if [ "$rc" != 0 ] || ! grep -qE '^rn-impeller: scene_nodes=[1-9]' "$WORK/run.log"; then
  tail -15 "$WORK/run.log"
  fail "A: headless run rc=$rc or mounted nothing"
else
  python3 tools/typography_rows.py "$WORK/frame.ppm" "$WORK/run.log" \
    regular:10 bold:50 custom:90 emoji:130 > "$WORK/rows.txt"
  [ $? = 0 ] || fail "A: a row is missing from the node_frame report"
  sed 's/^/   /' "$WORK/rows.txt"
  while read -r _ name m i dl dr; do
    m="${m#measured=}" dl="${dl#dl=}" dr="${dr#dr=}" i="${i#ink=}"
    python3 -c "import sys; sys.exit(0 if abs(float('$dl')) <= 1 and abs(float('$dr')) <= 1 else 1)" 2>/dev/null \
      || fail "A: row $name measured ${m} px but painted ${i} px of ink (left $dl, right $dr px): measure and paint resolved different faces"
  done < "$WORK/rows.txt"
  CM="$(sed -n 's/^row custom measured=\([0-9.]*\) .*/\1/p' "$WORK/rows.txt")"
  python3 -c "import sys; sys.exit(0 if abs(float('${CM:-0}') - 228) <= 2 else 1)" \
    || fail "A: custom row measured ${CM:-none} px, not Geist Mono's 228 (19 cells x 12 px): the app font did not reach measure"
fi

echo "== B. one context per thread (read back)"
TC="$(grep -m1 '^rn-impeller: typography_contexts ' "$WORK/run.log")"
echo "   ${TC:-no typography_contexts line}"
B="$(sed -n 's/.* bound=\([0-9]*\) .*/\1/p' <<<"$TC")"; O="$(sed -n 's/.* own=\([0-9]*\) .*/\1/p' <<<"$TC")"
N="$(sed -n 's/.* fonts=\([0-9]*\)$/\1/p' <<<"$TC")"
[ "${B:-0}" -ge 1 ] && [ "${O:-0}" -ge 1 ] \
  || fail "B: typography_contexts bound=${B:-?} own=${O:-?}: measure did not get its own context (one context shared across threads)"
[ "${N:-0}" -ge 2 ] || fail "B: fonts=${N:-?} (< 2): the app font or the fallback face never joined the shared font list"

if [ "${SKIP_TSAN:-0}" = 1 ]; then
  echo "== C. SKIPPED (SKIP_TSAN=1)"
else
  echo "== C. TSan: churn + typography fixtures, windowed + headless"
  env -u RNI_BIN TSAN_RUNS="churn-window churn-headless fp12-window fp12-headless" \
    bash tools/ci-tsan.sh > "$WORK/tsan.log" 2>&1
  rc=$?
  grep -E '^(ok |run |known |  NEW|TSAN_)' "$WORK/tsan.log" | sed 's/^/   /'
  if [ "$rc" != 0 ] || ! grep -q '^TSAN_PASS' "$WORK/tsan.log"; then
    fail "C: $(grep -m1 '^TSAN_FAIL' "$WORK/tsan.log" | cut -c11-260)"
  fi
fi

[ "$FAILS" = 0 ] || { echo "TYPO_THREADS_GATE_FAIL ($FAILS arm failure(s))"; exit 1; }
echo "TYPO_THREADS_PASS (measure == paint on 4 rows within 1 px; contexts: $TC; TSan clean)"
