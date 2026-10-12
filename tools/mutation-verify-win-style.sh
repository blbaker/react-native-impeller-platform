#!/usr/bin/env bash
# Mutation check for the SC-40 Windows style gates (ci-style-coverage.sh and
# ci-style-audit.sh through tools/win-run-engine.sh, headless). Each mutant
# breaks one SC-40 fix in the WINDOWS build; the gate must FAIL and name the
# tile. Runs from WSL; sources are restored and the win32 engine rebuilt on exit.
#   SC40a  WinGLSurface FBO without a stencil attachment -> g2:radiusUnevenWidth
#   SC40b  win32 font stack takes its first entry unchecked -> g2:fontStack
#   SC40c  underline drawn as line-through (win frame)    -> underline (grid 1)
#   SC40d  platform assertion: linux engine run with RNI_EXPECT_PLATFORM=win32,
#          and the win engine with RNI_EXPECT_PLATFORM=linux (no build)
#   ONLY=SC40a,SC40d bash tools/mutation-verify-win-style.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$PATH:/mnt/c/Windows/System32:/mnt/c/Windows"
WIN_BIN="$ROOT/tools/win-run-engine.sh"
FILES=(engine/host/WinGLSurface.cpp engine/text/FontFamily.cpp engine/text/TextStyle.h)
BAK="$(mktemp -d)"
for f in "${FILES[@]}"; do mkdir -p "$BAK/$(dirname "$f")"; cp "$f" "$BAK/$f"; done
put_back() { for f in "${FILES[@]}"; do cp "$BAK/$f" "$f"; done; }
restore() {
  put_back
  bash tools/engine-build.sh win32 x64 > /dev/null 2>&1 || echo "WARN: win32 rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "WIN_STYLE_MUTATION_FAIL: $*" >&2; exit 1; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }

cov() { RNI_EXPECT_PLATFORM=win32 RNI_SC_WINDOWED=0 RNI_BIN="$WIN_BIN" bash tools/ci-style-coverage.sh > "$1" 2>&1; }
aud() { RNI_EXPECT_PLATFORM=win32 RNI_BIN="$WIN_BIN" bash tools/ci-style-audit.sh > "$1" 2>&1; }

mutate() {  # FILE OLD NEW: exact replacement, anchor asserted present once
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found exactly once in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

build() { bash tools/engine-build.sh win32 x64 > "$BAK/$1.build.log" 2>&1 || { tail -5 "$BAK/$1.build.log" >&2; fail "$1 tree did not build"; }; }

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

echo "== control: unmutated win32 tree must PASS both gates =="
build control
cov "$BAK/control-cov.log" || { tail -8 "$BAK/control-cov.log" >&2; fail "control coverage FAILED"; }
aud "$BAK/control-aud.log" || { tail -8 "$BAK/control-aud.log" >&2; fail "control audit FAILED"; }
echo "   OK: control passes ($(tail -1 "$BAK/control-cov.log"); $(tail -1 "$BAK/control-aud.log"))"
N=0

if want SC40a; then
echo "== SC40a: FBO without a stencil attachment (every clip a no-op) =="
mutate engine/host/WinGLSurface.cpp "  gl_.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                              depthStencil_);" ""
check SC40a cov g2:radiusUnevenWidth; N=$((N + 1))
fi

if want SC40b; then
echo "== SC40b: win32 font stack takes its first entry unchecked =="
mutate engine/text/FontFamily.cpp "bool Exists(const std::string& name) {
  LOGFONTW lf = {};" "bool Exists(const std::string& name) {
  return true;
  LOGFONTW lf = {};"
check SC40b cov g2:fontStack; N=$((N + 1))
fi

if want SC40c; then
echo "== SC40c: underline drawn as line-through, judged on the win32 frame =="
mutate engine/text/TextStyle.h "  if (decoLine == 1 || decoLine == 3) types |= kImpellerTextDecorationTypeUnderline;" "  if (decoLine == 1 || decoLine == 3) types |= kImpellerTextDecorationTypeLineThrough;"
check SC40c aud underline; N=$((N + 1))
fi

if want SC40d; then
echo "== SC40d: the platform assertion rejects the wrong engine =="
LIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
[ -x "$LIN" ] || fail "SC40d needs the linux engine at $LIN"
if RNI_EXPECT_PLATFORM=win32 RNI_SC_WINDOWED=0 RNI_BIN="$LIN" bash tools/ci-style-coverage.sh > "$BAK/SC40d-1.log" 2>&1; then
  fail "SC40d SURVIVED: linux engine accepted as win32 (coverage)"; fi
grep -q 'want platform=win32, log says .platform=linux' "$BAK/SC40d-1.log" || fail "SC40d coverage failed for another reason: $(grep -m1 FAIL "$BAK/SC40d-1.log")"
if RNI_EXPECT_PLATFORM=win32 RNI_BIN="$LIN" bash tools/ci-style-audit.sh > "$BAK/SC40d-2.log" 2>&1; then
  fail "SC40d SURVIVED: linux engine accepted as win32 (audit)"; fi
grep -q 'want platform=win32, log says .platform=linux' "$BAK/SC40d-2.log" || fail "SC40d audit failed for another reason: $(grep -m1 FAIL "$BAK/SC40d-2.log")"
if RNI_EXPECT_PLATFORM=linux RNI_SC_WINDOWED=0 RNI_BIN="$WIN_BIN" bash tools/ci-style-coverage.sh > "$BAK/SC40d-3.log" 2>&1; then
  fail "SC40d SURVIVED: win32 engine accepted as linux"; fi
grep -q 'want platform=linux, log says .platform=win32' "$BAK/SC40d-3.log" || fail "SC40d reverse failed for another reason: $(grep -m1 FAIL "$BAK/SC40d-3.log")"
echo "   OK: SC40d killed (linux as win32 rejected by both gates, win32 as linux rejected)"
N=$((N + 1))
fi

if [ -n "${ONLY:-}" ]; then
  echo "WIN_STYLE_MUTATION_PARTIAL_PASS ($N mutant(s) of ONLY=$ONLY killed for their own tile)"
else
  echo "WIN_STYLE_MUTATION_PASS ($N mutants killed for their own tile)"
fi
