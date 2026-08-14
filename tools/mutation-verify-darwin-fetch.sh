#!/usr/bin/env bash
# Mutation-verify the two DARWIN STAGING fetchers: tools/angle-fetch.sh's
# darwin-arm64 arm, and tools/sdk-fetch-darwin.sh's ABI parity check.
#
# WHY: this fetch is the only thing standing between the macOS engine and an
# unreviewed graphics driver. Both of its guards are the kind that pass
# trivially if written wrong — a sha256 compared against itself, or a
# `z.read()` on a path that silently returns nothing. P5-D shipped three bugs
# of exactly that shape, so the guards get mutated, not trusted.
#
# Runs on ANY host: it never executes darwin code, it exercises the fetcher.
set -uo pipefail
CI_TOOLS=$(cd "$(dirname "$0")" && pwd)
cd "$(cd "$(dirname "$0")/.." && pwd)"

SRC="tools/angle-fetch.sh"
ELECTRON_VERSION="$(tr -d ' \n' < engine/ANGLE_PIN)"
WORK="$(mktemp -d)"
# ⛔ MUTANTS MUST SIT DIRECTLY IN tools/, NOT IN $WORK AND NOT IN A SUBDIR.
# The script resolves the repo root as `cd "$(dirname "$0")/.."`, so a copy
# under /tmp resolves to `/` and dies at `engine/ANGLE_PIN: No such file or
# directory` — a non-zero exit for a reason unrelated to the mutation. The
# first draft of this suite scored 0/5 that way while reporting the mutants
# "not caught": the same reddens-for-the-wrong-reason trap P5-E's M7 hit. A
# subdirectory is wrong for the same reason (`..` would be tools/, not root).
MUTPFX="tools/.mut-angle-$$"
trap 'rm -rf "$WORK" "$MUTPFX"-*.sh' EXIT
CAUGHT=0
TOTAL=0

# Prove the UNMUTATED script passes first. A mutation suite whose baseline is
# already red credits every mutant for free.
DEST0="$WORK/base"
if ! ANGLE_PLATFORM=darwin-arm64 bash "$SRC" "$DEST0" >"$WORK/base.log" 2>&1; then
  echo "MUTATION_VERIFY_DARWIN_FETCH_FAIL (baseline is RED — suite proves nothing)"
  tail -5 "$WORK/base.log"
  exit 1
fi
grep -q "libEGL.dylib" "$WORK/base.log" || {
  echo "MUTATION_VERIFY_DARWIN_FETCH_FAIL (baseline produced no fetch lines)"; exit 1; }
[ -s "$DEST0/libEGL.dylib" ] && [ -s "$DEST0/libGLESv2.dylib" ] || {
  echo "MUTATION_VERIFY_DARWIN_FETCH_FAIL (baseline wrote no dylibs)"; exit 1; }
echo "baseline: GREEN (both dylibs written, sha256 verified)"

mutate() {  # name, sed-expr, expect-substring-in-stderr
  local name="$1" expr="$2" want="$3"
  TOTAL=$((TOTAL + 1))
  local m="${MUTPFX}-${TOTAL}.sh"
  sed "$expr" "$SRC" > "$m"
  bash -n "$m" 2>/dev/null || { echo "  M$TOTAL $name -> ❌ mutant does not parse"; return; }
  local out rc
  # Fresh DEST every time: a leftover .stamp short-circuits the fetch and the
  # mutant would "pass" without the mutated code ever running.
  out=$(ANGLE_PLATFORM=darwin-arm64 bash "$m" "$WORK/m$TOTAL" 2>&1); rc=$?
  # ASSERT THE POSITIVE HALF FIRST. A mutant that dies before the fetch is a
  # non-zero exit that says nothing about the guard under test.
  if ! grep -q "^angle-fetch: ${ELECTRON_VERSION} darwin-arm64" <<<"$out"; then
    echo "  M$TOTAL $name -> ❌ INCONCLUSIVE (mutant never reached the fetch)"
    echo "$out" | tail -3 | sed 's/^/      /'
    return
  fi
  if [ "$rc" -ne 0 ] && grep -q "$want" <<<"$out"; then
    echo "  M$TOTAL $name -> ✅ caught (rc=$rc)"
    CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL $name -> ❌ NOT caught (rc=$rc)"
    echo "$out" | tail -3 | sed 's/^/      /'
  fi
}

echo "mutating $SRC (darwin-arm64 arm):"

# M1: a corrupted pin must be refused, not written to disk.
mutate "EGL sha256 pin corrupted" \
  's/^    EXPECT_EGL="1f528ff/    EXPECT_EGL="0000000/' \
  "sha256"

# M2: same for the larger library — one pin checked and the other ignored is
# the classic half-guard.
mutate "GLESv2 sha256 pin corrupted" \
  's/^    EXPECT_GLES="307e181f/    EXPECT_GLES="00000000/' \
  "sha256"

# M3: Electron moves files inside the .app between majors. A path that no
# longer exists must be LOUD; a silent skip reads downstream as "the macOS
# engine cannot initialise GL" and costs a session in the wrong subsystem.
mutate "in-bundle dylib path moved" \
  's#Versions/A/Libraries/libEGL.dylib#Versions/A/Libraries/moved-libEGL.dylib#' \
  "not in the asset"

# M4: the asset name itself. win32-x64 has no dylibs at all, so a stale ASSET
# would fail — but on the "not in the asset" path, proving M3's check is what
# catches it rather than an HTTP error.
mutate "wrong release asset (win32 zip for darwin)" \
  's/^    ASSET="darwin-arm64"/    ASSET="win32-x64"/' \
  "not in the asset"

# M5: two platforms into ONE directory must be refused, not silently merged.
# `mkdir -p` never clears, so without the stray check the win DLLs and the
# darwin dylibs coexist and both ride into whatever package copies that dir.
#
# ⚠️ THE MUTATION THIS REPLACED WAS VACUOUS. It dropped ${ANGLE_PLATFORM} from
# the stamp expecting a false "up to date" — but the stamp also carries
# ${EXPECT_EGL:0:12}, which is already per-platform, so the two stamps still
# differed and the mutant behaved identically to the real script. It reported
# "inconclusive" rather than a false ✅ only because this suite asserts the
# mutant reached the fetch. A mutation that cannot change behaviour proves
# nothing about the guard it targets.
TOTAL=$((TOTAL + 1))
m5="${MUTPFX}-${TOTAL}.sh"
# Remove the stray-file check by neutering its trigger condition.
sed 's/^if \[ -n "\$_strays" \]; then/if false; then/' "$SRC" > "$m5"
d5="$WORK/m5mixed"
mix_ran=0
if bash -n "$m5" 2>/dev/null \
   && ANGLE_PLATFORM=win-x64 bash "$m5" "$d5" >/dev/null 2>&1 \
   && ANGLE_PLATFORM=darwin-arm64 bash "$m5" "$d5" >/dev/null 2>&1 \
   && [ -s "$d5/libEGL.dll" ] && [ -s "$d5/libEGL.dylib" ]; then
  mix_ran=1
fi
if [ "$mix_ran" -eq 1 ]; then
  # The mutant produced the mixed directory. The real script must refuse it.
  d5b="$WORK/m5real"
  ANGLE_PLATFORM=win-x64 bash "$SRC" "$d5b" >/dev/null 2>&1
  real_out=$(ANGLE_PLATFORM=darwin-arm64 bash "$SRC" "$d5b" 2>&1); real_rc=$?
  if [ "$real_rc" -ne 0 ] && grep -q "another platform" <<<"$real_out"; then
    echo "  M$TOTAL stray-file check removed -> ✅ caught (mutant mixed both platforms, real script refused rc=$real_rc)"
    CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL stray-file check removed -> ❌ NOT caught (real script ALSO merged, rc=$real_rc)"
  fi
else
  echo "  M$TOTAL stray-file check removed -> ❌ INCONCLUSIVE (mutant did not produce a mixed dir)"
fi

echo
echo "=== tools/sdk-fetch-darwin.sh: the ABI parity check ==="

# M6: the parity check must actually compare. A `diff -q "$f" "$f"` shape, or a
# check whose `readelf` produced nothing, passes trivially — and P5-D shipped
# three bugs of exactly that shape. Feed it a DOCTORED linux symbol list and
# require it to redden.
TOTAL=$((TOTAL + 1))
m6="${MUTPFX}-${TOTAL}.sh"
# Replace the linux side of the comparison with a list that is one symbol short.
sed 's#readelf --dyn-syms -W engine/third_party/impeller-sdk/lib/libimpeller.so \\#cat "$tmp/DOCTORED" \\#' \
    tools/sdk-fetch-darwin.sh > "$m6"
# Build the doctored list: the real linux exports minus one, simulating an
# upstream bump that dropped a symbol on one platform only.
readelf --dyn-syms -W engine/third_party/impeller-sdk/lib/libimpeller.so \
  | awk '$4=="FUNC" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u \
  | grep -v '^ImpellerContextCreateMetalNew$' > "$WORK/doctored.txt"
# The mutant reads $tmp/DOCTORED, which it creates itself; seed it via a wrapper.
sed -i "s#^tmp=\"\$(mktemp -d)\".*#tmp=\"\$(mktemp -d)\"; trap 'rm -rf \"\$tmp\"' EXIT; cp \"$WORK/doctored.txt\" \"\$tmp/DOCTORED\"#" "$m6"
if ! bash -n "$m6" 2>/dev/null; then
  echo "  M$TOTAL ABI parity fed a doctored linux list -> ❌ mutant does not parse"
else
  out6=$(bash "$m6" "$WORK/m6sdk" 2>&1); rc6=$?
  # Positive half first: the fetch must have happened at all.
  if ! grep -q "lib/libimpeller.dylib" <<<"$out6"; then
    echo "  M$TOTAL ABI parity fed a doctored linux list -> ❌ INCONCLUSIVE (mutant never fetched)"
    echo "$out6" | tail -3 | sed 's/^/      /'
  elif [ "$rc6" -ne 0 ] && grep -q "export sets differ" <<<"$out6"; then
    echo "  M$TOTAL ABI parity fed a doctored linux list -> ✅ caught (rc=$rc6, named the missing symbol)"
    CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL ABI parity fed a doctored linux list -> ❌ NOT caught (rc=$rc6 — the check is vacuous)"
    echo "$out6" | tail -3 | sed 's/^/      /'
  fi
fi

echo
if [ "$CAUGHT" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_DARWIN_FETCH_PASS ($CAUGHT/$TOTAL)"
  exit 0
fi
echo "MUTATION_VERIFY_DARWIN_FETCH_FAIL ($((TOTAL - CAUGHT)) of $TOTAL were NOT caught)"
exit 1
