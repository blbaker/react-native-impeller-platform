#!/usr/bin/env bash
# Mutation check for tools/ci-impeller-sdk-custom.sh (SC-32). Each SDK mutant
# patches the interop sources on top of engine/impeller-sdk-patches, builds
# the SDK into a temp dir (tools/impeller-sdk-custom-build.sh, incremental,
# never the real impeller-sdk-custom) and the gate must FAIL naming the rule.
#   ONLY=SC32a,SC32g bash tools/mutation-verify-impeller-sdk-custom.sh
#   SC32a  letter spacing never reaches the text style -> letterSpacing
#   SC32b  word spacing stored as letter spacing        -> wordSpacing
#   SC32c  font features never reach the text style     -> fontFeature
#   SC32d  ClearFontFeatures is a no-op                 -> fontFeature
#   SC32e  top placeholder alignment mapped to baseline -> placeholderAlign
#   SC32f  placeholder rects lose their x origin        -> placeholder
#   SC32g  CMake keeps the stock SDK on linux           -> cmake
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
CML=engine/CMakeLists.txt
cp "$CML" "$WORK/CMakeLists.txt"
restore() {
  if ! cmp -s "$WORK/CMakeLists.txt" "$CML"; then
    cp "$WORK/CMakeLists.txt" "$CML"
    cmake -S engine -B engine/build > /dev/null 2>&1 || echo "WARN: reconfigure failed" >&2
  fi
  rm -rf "$WORK"
}
trap restore EXIT
fail() { echo "IMPELLER_SDK_CUSTOM_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

cat > "$WORK/mutate.py" <<'PY'
import os
p, old, new = os.environ["MUT_FILE"], os.environ["MUT_OLD"], os.environ["MUT_NEW"]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY

gate_must_fail() {  # name rule [env...]
  local name="$1" rule="$2"; shift 2
  if env "$@" bash tools/ci-impeller-sdk-custom.sh > "$WORK/$name.log" 2>&1; then
    tail -4 "$WORK/$name.log" >&2; fail "$name SURVIVED: gate passed with the mutant in"
  fi
  local line; line="$(grep -oE 'IMPELLER_SDK_CUSTOM_GATE_FAIL: .*' "$WORK/$name.log" | head -1 || true)"
  [[ "$line" == "IMPELLER_SDK_CUSTOM_GATE_FAIL: $rule:"* ]] \
    || { tail -4 "$WORK/$name.log" >&2; fail "$name killed, but not for $rule: $line"; }
  echo "   OK: $name killed ($line)"
}

sdk_mutant() {  # name rule file old new
  echo "== $1: SDK mutant in $3 =="
  MUT_FILE="$3" MUT_OLD="$4" MUT_NEW="$5" RNI_SDK_POST_PATCH="python3 '$WORK/mutate.py'" \
    bash tools/impeller-sdk-custom-build.sh "$WORK/sdk-$1" > "$WORK/$1.build.log" 2>&1 \
    || { tail -8 "$WORK/$1.build.log" >&2; fail "$1 SDK did not build"; }
  gate_must_fail "$1" "$2" RNI_IMPELLER_SDK_DIR="$WORK/sdk-$1"
}

echo "== control: the real custom SDK must PASS =="
bash tools/ci-impeller-sdk-custom.sh > "$WORK/control.log" 2>&1 \
  || { tail -6 "$WORK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

if want SC32a; then
sdk_mutant SC32a letterSpacing paragraph_style.cc "  style.letter_spacing = letter_spacing_;
" ""
fi
if want SC32b; then
sdk_mutant SC32b wordSpacing paragraph_style.cc "  word_spacing_ = spacing;" "  letter_spacing_ = spacing;"
fi
if want SC32c; then
sdk_mutant SC32c fontFeature paragraph_style.cc "  style.font_features = font_features_;
" ""
fi
if want SC32d; then
sdk_mutant SC32d fontFeature paragraph_style.cc "  font_features_ = {};" ""
fi
if want SC32e; then
sdk_mutant SC32e placeholderAlign impeller.cc "    case kImpellerPlaceholderAlignmentTop:
      return txt::PlaceholderAlignment::kTop;" "    case kImpellerPlaceholderAlignmentTop:
      return txt::PlaceholderAlignment::kBaseline;"
fi
if want SC32f; then
sdk_mutant SC32f placeholder impeller.cc "ImpellerRect{r.left(), r.top()," "ImpellerRect{0, r.top(),"
fi
if want SC32g; then
echo "== SC32g: CMake keeps the stock SDK on linux =="
MUT_FILE="$CML" MUT_OLD='    set(IMPELLER_SDK "${_impeller_sdk_custom}" CACHE PATH "" FORCE)' \
  MUT_NEW='    set(IMPELLER_SDK "${_impeller_sdk_default}" CACHE PATH "" FORCE)' python3 "$WORK/mutate.py"
cmake -S engine -B engine/build > "$WORK/SC32g.cmake.log" 2>&1 || { tail -5 "$WORK/SC32g.cmake.log" >&2; fail "SC32g configure failed"; }
gate_must_fail SC32g cmake
cp "$WORK/CMakeLists.txt" "$CML"
cmake -S engine -B engine/build > /dev/null 2>&1 || fail "SC32g restore configure failed"
fi
echo "IMPELLER_SDK_CUSTOM_MUTATION_PASS"
