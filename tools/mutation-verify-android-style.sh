#!/usr/bin/env bash
# Mutation check for the SC-41 android style gate (tools/ci-style-android.sh:
# ci-style-coverage.sh + ci-style-audit.sh run on the S21 through
# tools/android-run-engine.sh). Each mutant breaks one feature in the ANDROID
# build whose tile needed an SC-41 rule fix or rides on the custom SDK's text
# extensions; the gate must FAIL and name the tile. Sources are restored and
# the android engine rebuilt on exit.
#   SC41a  android generics never resolved (serif -> sans-serif) -> g2:fontSerif
#          (Noto Serif 'A'+'g' kern: the rule's A-component fallback)
#   SC41b  small-caps feature not set              -> g2:smallCaps (Roboto 'c' fallback)
#   SC41c  every run painted in the last run's colour -> nestedText (kerned 'AA' split)
#   SC41d  TextInput letterSpacing ignored         -> g2:tiLetterSpacing (SDK letterSpacing)
#   SC41e  paint skips the inline-View placeholder -> risky:inlineView (SDK placeholders)
#   SC41f  platform assertion: android engine run as linux, linux engine as android
#   ONLY=SC41a,SC41f bash tools/mutation-verify-android-style.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
AND_BIN="$ROOT/tools/android-run-engine.sh"
FILES=(engine/text/FontFamily.cpp engine/text/TextStyle.h engine/scenegraph/SceneGraph.cpp
       engine/scenegraph/TextInputStyle.cpp)
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cmp -s "$BAK/$f" "$f" || cp "$BAK/$f" "$f"; done; }
restore() {
  put_back
  bash tools/engine-build-android.sh > /dev/null 2>&1 || echo "WARN: android rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "ANDROID_STYLE_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

cov() { RNI_EXPECT_PLATFORM=android RNI_SC_WINDOWED=0 RNI_BIN="$AND_BIN" bash tools/ci-style-coverage.sh > "$1" 2>&1; }
aud() { RNI_EXPECT_PLATFORM=android RNI_BIN="$AND_BIN" bash tools/ci-style-audit.sh > "$1" 2>&1; }

mutate() {  # FILE OLD NEW: exact replacement, anchor asserted present once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

build() { bash tools/engine-build-android.sh > "$BAK/$1.build.log" 2>&1 || { tail -5 "$BAK/$1.build.log" >&2; fail "$1 tree did not build"; }; }

check() {  # name gate(cov|aud) tiles...: gate must fail naming every tile
  local name="$1" gate="$2"; shift 2
  build "$name"
  if "$gate" "$BAK/$name.log"; then fail "$name SURVIVED: gate passed with the mutant in"; fi
  local line; line="$(grep -oE 'STYLE_(COVERAGE|AUDIT)_GATE_FAIL: .*' "$BAK/$name.log" || true)"
  for t in "$@"; do
    echo "$line" | grep -qw -- "$t" || { tail -6 "$BAK/$name.log" >&2; fail "$name killed, but not for $t: $line"; }
  done
  echo "   OK: $name killed ($line)"
  put_back
}

echo "== control: unmutated android tree must PASS both gates =="
build control
cov "$BAK/control-cov.log" || { tail -8 "$BAK/control-cov.log" >&2; fail "control coverage FAILED"; }
aud "$BAK/control-aud.log" || { tail -8 "$BAK/control-aud.log" >&2; fail "control audit FAILED"; }
echo "   OK: control passes ($(tail -1 "$BAK/control-cov.log"); $(tail -1 "$BAK/control-aud.log"))"
N=0

if want SC41a; then
echo "== SC41a: android generics never resolved (serif becomes sans-serif) =="
mutate engine/text/FontFamily.cpp "  return f.empty() ? kind : f;" "  return f.empty() ? std::string(\"sans-serif\") : f;"
check SC41a cov g2:fontSerif; N=$((N + 1))
fi

if want SC41b; then
echo "== SC41b: small-caps feature not set =="
mutate engine/text/TextStyle.h "  if (variant & (1 << 1)) ImpellerParagraphStyleSetFontFeature(style, \"smcp\", 1);" ""
check SC41b cov g2:smallCaps; N=$((N + 1))
fi

if want SC41c; then
echo "== SC41c: every run painted in the last run's colour =="
mutate engine/scenegraph/SceneGraph.cpp "    ImpellerColor tc = impellerColor(run.color, OwnAlpha(node) * run.opacity);" "    ImpellerColor tc = impellerColor(node.textColor, OwnAlpha(node) * run.opacity);"
check SC41c aud nestedText; N=$((N + 1))
fi

if want SC41d; then
echo "== SC41d: TextInput letterSpacing ignored =="
mutate engine/scenegraph/TextInputStyle.cpp "  ApplyLetterSpacing(style, f.letterSpacing);  // SC-33" ""
check SC41d cov g2:tiLetterSpacing; N=$((N + 1))
fi

if want SC41e; then
echo "== SC41e: paint skips the inline-View placeholder =="
mutate engine/scenegraph/SceneGraph.cpp "      AddAttachmentPlaceholder(pb, run.attachW, run.attachH);  // SC-34, measured too" ""
check SC41e cov risky:inlineView; N=$((N + 1))
fi

if want SC41f; then
echo "== SC41f: the platform assertion rejects the wrong engine =="
LIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
[ -x "$LIN" ] || fail "SC41f needs the linux engine at $LIN"
if RNI_EXPECT_PLATFORM=android RNI_SC_WINDOWED=0 RNI_BIN="$LIN" bash tools/ci-style-coverage.sh > "$BAK/SC41f-1.log" 2>&1; then
  fail "SC41f SURVIVED: linux engine accepted as android (coverage)"; fi
grep -q 'want platform=android, log says .platform=linux' "$BAK/SC41f-1.log" || fail "SC41f coverage failed for another reason: $(grep -m1 FAIL "$BAK/SC41f-1.log")"
if RNI_EXPECT_PLATFORM=android RNI_BIN="$LIN" bash tools/ci-style-audit.sh > "$BAK/SC41f-2.log" 2>&1; then
  fail "SC41f SURVIVED: linux engine accepted as android (audit)"; fi
grep -q 'want platform=android, log says .platform=linux' "$BAK/SC41f-2.log" || fail "SC41f audit failed for another reason: $(grep -m1 FAIL "$BAK/SC41f-2.log")"
if RNI_EXPECT_PLATFORM=linux RNI_SC_WINDOWED=0 RNI_BIN="$AND_BIN" bash tools/ci-style-coverage.sh > "$BAK/SC41f-3.log" 2>&1; then
  fail "SC41f SURVIVED: android engine accepted as linux"; fi
grep -q 'want platform=linux, log says .platform=android' "$BAK/SC41f-3.log" || fail "SC41f reverse failed for another reason: $(grep -m1 FAIL "$BAK/SC41f-3.log")"
echo "   OK: SC41f killed (linux as android rejected by both gates, android as linux rejected)"
N=$((N + 1))
fi

if [ -n "${ONLY:-}" ]; then
  echo "ANDROID_STYLE_MUTATION_PARTIAL_PASS ($N mutant(s) of ONLY=$ONLY killed for their own tile)"
else
  echo "ANDROID_STYLE_MUTATION_PASS ($N mutants killed for their own tile)"
fi
