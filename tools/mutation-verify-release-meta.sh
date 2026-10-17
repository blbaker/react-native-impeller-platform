#!/usr/bin/env bash
# Mutation-verify tools/ci-release-meta.sh.
#
# A release gate that has only ever been seen GREEN is decoration. Every check
# in it exists because of a defect that would otherwise ship silently, so each
# one gets its defect re-injected and must redden for THAT reason.
#
# Mutations are applied to the package METADATA (a scratch copy of the repo),
# not to the gate — mutating the gate proves the gate can break, which is not
# the question. This is the inverse of the darwin-fetch suite and the right way
# round for a checker: break the WORLD, not the check.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO="$PWD"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CAUGHT=0
TOTAL=0

# Baseline first. A suite whose baseline is already red credits every mutant
# for free.
if ! bash tools/ci-release-meta.sh >"$WORK/base.log" 2>&1; then
  echo "MUTATION_VERIFY_RELEASE_META_FAIL (baseline is RED — suite proves nothing)"
  tail -5 "$WORK/base.log"
  exit 1
fi
grep -q "RELEASE_META_PASS" "$WORK/base.log" || {
  echo "MUTATION_VERIFY_RELEASE_META_FAIL (baseline printed no PASS)"; exit 1; }
echo "baseline: GREEN"
echo "mutating the package metadata:"

# Each mutant runs in a full scratch COPY of the repo, because the gate reads
# git state (`git ls-files`) as well as the filesystem. Copying only package/
# would make every tracked-file check vacuous.
mutate() {  # name, python-edit, expected-substring
  local name="$1" edit="$2" want="$3"
  TOTAL=$((TOTAL + 1))
  local dir="$WORK/m$TOTAL"
  rm -rf "$dir"
  # -a preserves the git dir; the gate shells out to git inside it.
  cp -a "$REPO" "$dir" 2>/dev/null
  ( cd "$dir" && python3 -c "$edit" ) || {
    echo "  M$TOTAL $name -> ❌ mutation script failed"; return; }
  local out rc
  out=$(cd "$dir" && bash tools/ci-release-meta.sh 2>&1); rc=$?
  # ASSERT THE POSITIVE HALF FIRST: a mutant that died before the checks ran is
  # a non-zero exit that says nothing about the check under test.
  if ! grep -q "^root: @*react-native-impeller" <<<"$out"; then
    echo "  M$TOTAL $name -> ❌ INCONCLUSIVE (gate never started)"
    echo "$out" | tail -3 | sed 's/^/      /'
    return
  fi
  if [ "$rc" -ne 0 ] && grep -q "$want" <<<"$out"; then
    echo "  M$TOTAL $name -> ✅ caught (rc=$rc)"
    CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL $name -> ❌ NOT caught (rc=$rc)"
    echo "$out" | tail -4 | sed 's/^/      /'
  fi
}

# M1: an engine package drifts off the root version. This is the defect the
# runtime lockstep check exists for; catching it BEFORE the tag is the point.
mutate "engine package version drifts from root" '
import json
p="packages-engine/engine-linux-x64/package.json"
d=json.load(open(p)); d["version"]="0.0.2"; json.dump(d,open(p,"w"),indent=2)
' "!= root"

# M2: an optionalDependency pinned with a CARET. npm would happily resolve a
# newer engine against an older host — a mismatched C ABI, which crashes at
# runtime rather than failing to install.
mutate "optionalDependency pinned with a caret range" '
import json
p="package/package.json"
d=json.load(open(p))
d["optionalDependencies"]["@blbaker/react-native-impeller-platform-engine-linux-x64"]="^0.0.1"
json.dump(d,open(p,"w"),indent=2)
' "must be exactly"

# M3: THE ORIGINAL FINDING. A declared engine package that was never built.
# npm skips it and exits 0, so nothing downstream complains until a user on
# that platform has a silent no-engine install.
mutate "optionalDependency declared for an unbuilt platform" '
import json
p="package/package.json"
d=json.load(open(p))
d["optionalDependencies"]["@blbaker/react-native-impeller-platform-engine-linux-arm64"]="0.0.1"
json.dump(d,open(p,"w"),indent=2)
' "no package exists in packages-engine"

# M4: the mirror image — resolve.js promising a triple with no package. Same
# user-visible failure, reached from the other direction, so it needs its own
# check and its own mutation.
mutate "resolve.js SUPPORTS a triple with no package" '
import re
p="package/src/resolve.js"
s=open(p).read()
s=s.replace("  '"'"'win32-x64'"'"',\n", "  '"'"'win32-x64'"'"',\n  '"'"'linux-arm64'"'"',\n")
open(p,"w").write(s)
' "SUPPORTED but"

# M5: a file listed in `files` that does not exist. npm pack ships whatever it
# finds and says nothing about what it did not — a package with no README
# renders as a blank page on npmjs.com.
mutate "package.json ships a file that does not exist" '
import json
p="package/package.json"
d=json.load(open(p)); d["files"].append("CHANGELOG.md"); json.dump(d,open(p,"w"),indent=2)
' "does not exist"

# M6: shipping-but-untracked. The repo then cannot reproduce the artifact it
# publishes, and no commit sha can describe the shipped file. Seen for real in
# skia-platform: 9 template files shipped in every npm pack while untracked.
TOTAL=$((TOTAL + 1))
dir="$WORK/m$TOTAL"
rm -rf "$dir"; cp -a "$REPO" "$dir" 2>/dev/null
(
  cd "$dir"
  printf 'shipped but never committed\n' > package/UNTRACKED.md
  python3 -c "
import json
p='package/package.json'
d=json.load(open(p)); d['files'].append('UNTRACKED.md'); json.dump(d,open(p,'w'),indent=2)
"
)
out6=$(cd "$dir" && bash tools/ci-release-meta.sh 2>&1); rc6=$?
if [ "$rc6" -ne 0 ] && grep -q "UNTRACKED in git" <<<"$out6"; then
  echo "  M$TOTAL file ships in npm pack but is untracked -> ✅ caught (rc=$rc6)"
  CAUGHT=$((CAUGHT + 1))
else
  echo "  M$TOTAL file ships in npm pack but is untracked -> ❌ NOT caught (rc=$rc6)"
  echo "$out6" | tail -4 | sed 's/^/      /'
fi

# M7: a declared entry point that does not exist. Invisible until a user runs
# it — `npm test` on the published package died with MODULE_NOT_FOUND on
# src/selftest.js, a file that had never been written, for six phases.
mutate "scripts.test runs a file that does not exist" '
import json
p="package/package.json"
d=json.load(open(p)); d["scripts"]["test"]="node src/nope.js"; json.dump(d,open(p,"w"),indent=2)
' "which does not exist"

# M8: an entry point that exists but is NOT covered by `files`. It works in the
# repo and is absent from the tarball — the failure appears only for installed
# users, which is the worst place to find it.
mutate "bin entry point is not covered by files" '
import json
p="package/package.json"
d=json.load(open(p)); d["files"]=[f for f in d["files"] if f!="src"]
json.dump(d,open(p,"w"),indent=2)
' "NOT covered by"

# M9: publish visibility drifts from the declared decision. These are PUBLIC by
# Baker's call (2026-08-15, reversing the P7-B private decision). A workflow or
# careless edit flipping them BACK to restricted is not merely wrong-by-policy:
# a restricted scoped package needs a paid plan, so it fails the publish or
# ships something nobody can install. The mutation flips to the opposite of
# whatever is declared, so this stays honest if the decision moves again.
mutate "publish access flipped away from the declared value" '
import json
p="packages-engine/engine-linux-x64/package.json"
d=json.load(open(p)); d["publishConfig"]={"access":"restricted"}; json.dump(d,open(p,"w"),indent=2)
' "expected 'public'"

# M10: publishConfig removed entirely.
#
# ⛔ THIS MUTATION CHANGED MEANING WHEN THE DECISION FLIPPED, AND IT IS NOW
# STRONGER. While the answer was "private" npm's default for a scoped package
# AGREED, so the artifact was still correct and this only defended the decision
# being RECORDED. Public is NOT the default — removing publishConfig now
# produces a genuinely wrong artifact (refused, or silently private). Same
# assertion, and it went from documentary to load-bearing.
mutate "publishConfig removed (now a genuinely wrong artifact)" '
import json
p="packages-engine/engine-linux-x64/package.json"
d=json.load(open(p)); d.pop("publishConfig",None); json.dump(d,open(p,"w"),indent=2)
' "expected 'public'"

# M11: the main package is unscoped. npm refuses to publish an unscoped package
# that declares access=restricted, so the gate must fail it rather than skip it.
mutate "unscoped main package declares restricted access" '
import json
p="package/package.json"
d=json.load(open(p)); d["publishConfig"]={"access":"restricted"}; json.dump(d,open(p,"w"),indent=2)
' "is unscoped but declares"

# ── Check 6 (RNI_REQUIRE_ENGINE_BINARIES=1): every engine package carries a
# real binary for its own triple. These mutants start from a world where all
# three engines are present, using minimal synthetic headers (the check reads
# headers, and no host has all three real builds), then break one thing.
fake_engines() {  # dir — give every engine package a well-formed binary
  python3 - "$1" <<'PY'
import os, struct, sys
root = sys.argv[1]
def elf(machine):
    h = bytearray(64); h[:4] = b"\x7fELF"; h[4] = 2; h[5] = 1
    struct.pack_into("<H", h, 18, machine); return bytes(h)
def macho(cpu):
    return struct.pack("<IIII", 0xFEEDFACF, cpu, 0, 2) + bytes(48)
def pe(machine):
    h = bytearray(0x80); h[:2] = b"MZ"; struct.pack_into("<I", h, 0x3C, 0x40)
    h[0x40:0x44] = b"PE\0\0"; struct.pack_into("<H", h, 0x44, machine); return bytes(h)
want = {"linux-x64": ("rn-impeller", elf(0x3E)),
        "darwin-arm64": ("rn-impeller", macho(0x0100000C)),
        "win32-x64": ("rn-impeller.exe", pe(0x8664))}
for triple, (exe, data) in want.items():
    d = os.path.join(root, "packages-engine", f"engine-{triple}", "bin")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, exe)
    with open(p, "wb") as f:
        f.write(data)
    os.chmod(p, 0o755)
PY
}
mutate_bin() {  # name, shell-edit (runs in the scratch copy), expected-substring
  local name="$1" edit="$2" want="$3"
  TOTAL=$((TOTAL + 1))
  local dir="$WORK/m$TOTAL"
  rm -rf "$dir"; cp -a "$REPO" "$dir" 2>/dev/null
  fake_engines "$dir"
  ( cd "$dir" && eval "$edit" ) || { echo "  M$TOTAL $name -> ❌ mutation script failed"; return; }
  local out rc
  out=$(cd "$dir" && RNI_REQUIRE_ENGINE_BINARIES=1 bash tools/ci-release-meta.sh 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- "$want" <<<"$out"; then
    echo "  M$TOTAL $name -> ✅ caught (rc=$rc)"
    CAUGHT=$((CAUGHT + 1))
  else
    echo "  M$TOTAL $name -> ❌ NOT caught (rc=$rc)"
    echo "$out" | grep -E 'FAIL|OK ' | tail -4 | sed 's/^/      /'
  fi
}

# Positive control. Without it, a check that fails EVERY tree would score
# every mutant below as caught.
dir="$WORK/control"; rm -rf "$dir"; cp -a "$REPO" "$dir" 2>/dev/null; fake_engines "$dir"
outc=$(cd "$dir" && RNI_REQUIRE_ENGINE_BINARIES=1 bash tools/ci-release-meta.sh 2>&1); rcc=$?
if [ "$rcc" -eq 0 ] && [ "$(grep -c 'OK .* ships bin/' <<<"$outc")" -eq 3 ]; then
  echo "  control: all three engines present -> passes, 3 engines checked"
else
  echo "  control: all three engines present -> ❌ did NOT pass (rc=$rcc); check 6 proves nothing"
  echo "$outc" | grep -E 'FAIL' | tail -4 | sed 's/^/      /'
  TOTAL=$((TOTAL + 1))
fi

# M12: the release job forgot to unpack one platform's build.
mutate_bin "an engine package has no binary" \
  'rm -rf packages-engine/engine-darwin-arm64/bin' "has no engine binary"
# M13: an artifact unpacked into the wrong folder (the linux build under darwin).
mutate_bin "an engine package holds another platform's binary" \
  'cp packages-engine/engine-linux-x64/bin/rn-impeller packages-engine/engine-darwin-arm64/bin/rn-impeller' \
  "expected Mach-O arm64"
# M14: the exec bit was lost (upload-artifact drops file modes).
mutate_bin "the engine binary is not executable" \
  'chmod -x packages-engine/engine-linux-x64/bin/rn-impeller' "is not executable"
# M15: the binary is on disk but the tarball would leave it out.
mutate_bin "npm pack would not ship the binary" \
  'python3 -c "import json; p=\"packages-engine/engine-win32-x64/package.json\"; d=json.load(open(p)); d[\"files\"]=[\"README.md\"]; json.dump(d,open(p,\"w\"),indent=2)"' \
  "would not ship it"

echo
if [ "$CAUGHT" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_RELEASE_META_PASS ($CAUGHT/$TOTAL)"
  exit 0
fi
echo "MUTATION_VERIFY_RELEASE_META_FAIL ($((TOTAL - CAUGHT)) of $TOTAL were NOT caught)"
exit 1
