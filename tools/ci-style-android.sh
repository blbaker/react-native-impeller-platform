#!/usr/bin/env bash
# SC-41 ANDROID STYLE GATE. Runs the staged android-arm64 engine
# (tools/engine-build-android.sh) headless on a real device through
# tools/android-run-engine.sh (adb shell from /data/local/tmp; the S21,
# SM-G991U1, unless RNI_ANDROID_SERIAL names an emulator) and scores the frames
# with the SAME gates and measurers as linux: ci-style-coverage.sh (g2, risky,
# nw, variants; the windowed interact scene is skipped, there is no window) and
# ci-style-audit.sh (grid 1, secure field, selectable text). Every render log
# must say platform=android.
# Also asserts the engine links the custom SDK's text extensions (letterSpacing,
# font features, placeholders), which the landed SC-33/SC-34 tiles exercise.
# Prints ANDROID_STYLE_PASS only when landed + keep tiles pass in both gates.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail() { echo "ANDROID_STYLE_FAIL: $*" >&2; exit 1; }
ENG="${RNI_ANDROID_ENGINE_DIR:-$ROOT/engine/build/android-stage/bin}"
[ -f "$ENG/rn-impeller" ] || fail "no staged android engine in $ENG (bash tools/engine-build-android.sh)"
for s in ImpellerParagraphStyleSetLetterSpacing ImpellerParagraphStyleSetFontFeature ImpellerParagraphBuilderAddPlaceholder; do
  grep -aq "$s" "$ENG/rn-impeller" || fail "rn-impeller does not import $s (built against the stock SDK?)"
  grep -aq "$s" "$ENG/libimpeller.so" || fail "staged libimpeller.so lacks $s (stock SDK staged?)"
done
echo "   text extensions linked: letterSpacing, font features, placeholders"

export RNI_BIN="$ROOT/tools/android-run-engine.sh" RNI_EXPECT_PLATFORM=android
LOG="$(mktemp -d)"
trap 'rm -rf "$LOG"' EXIT
echo "== coverage (g2, risky, nw, variants) on the device =="
RNI_SC_WINDOWED=0 bash tools/ci-style-coverage.sh > "$LOG/cov.log" 2>&1
rc=$?
grep -E 'keep-green|STYLE_COVERAGE' "$LOG/cov.log" | sed 's/^/   /'
[ "$rc" -eq 0 ] || { tail -12 "$LOG/cov.log" >&2; fail "coverage gate failed on android"; }
COV="$(grep -E "^STYLE_COVERAGE_GATE_(PASS|FAIL)" "$LOG/cov.log" | tail -1)"  # KEEP_WORKDIR appends a line after the verdict
echo "== audit (grid 1, secure field, selection) on the device =="
bash tools/ci-style-audit.sh > "$LOG/aud.log" 2>&1
rc=$?
grep -E 'keep-green|STYLE_AUDIT' "$LOG/aud.log" | sed 's/^/   /'
[ "$rc" -eq 0 ] || { tail -12 "$LOG/aud.log" >&2; fail "audit gate failed on android"; }
AUD="$(grep -E "^STYLE_AUDIT_GATE_(PASS|FAIL)" "$LOG/aud.log" | tail -1)"
case "$COV" in STYLE_COVERAGE_GATE_PASS*platform=android) ;; *) fail "coverage verdict: $COV" ;; esac
case "$AUD" in STYLE_AUDIT_GATE_PASS*platform=android) ;; *) fail "audit verdict: $AUD" ;; esac
echo "ANDROID_STYLE_PASS ${COV#STYLE_COVERAGE_GATE_PASS } | ${AUD#STYLE_AUDIT_GATE_PASS }"
