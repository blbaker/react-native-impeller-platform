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
d["optionalDependencies"]["@react-native-impeller/engine-linux-x64"]="^0.0.1"
json.dump(d,open(p,"w"),indent=2)
' "must be exactly"

# M3: THE ORIGINAL FINDING. A declared engine package that was never built.
# npm skips it and exits 0, so nothing downstream complains until a user on
# that platform has a silent no-engine install.
mutate "optionalDependency declared for an unbuilt platform" '
import json
p="package/package.json"
d=json.load(open(p))
d["optionalDependencies"]["@react-native-impeller/engine-darwin-arm64"]="0.0.1"
json.dump(d,open(p,"w"),indent=2)
' "no package exists in packages-engine"

# M4: the mirror image — resolve.js promising a triple with no package. Same
# user-visible failure, reached from the other direction, so it needs its own
# check and its own mutation.
mutate "resolve.js SUPPORTS a triple with no package" '
import re
p="package/src/resolve.js"
s=open(p).read()
s=s.replace("  '"'"'win32-x64'"'"',\n", "  '"'"'win32-x64'"'"',\n  '"'"'darwin-arm64'"'"',\n")
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

# M9: publish visibility drifts from the declared decision. These are PRIVATE
# by Baker's call; a workflow or a careless edit flipping them to public is
# unrecoverable — an npm publish cannot be taken back, only deprecated.
mutate "publish access flipped away from the declared value" '
import json
p="package/package.json"
d=json.load(open(p)); d["publishConfig"]={"access":"public"}; json.dump(d,open(p,"w"),indent=2)
' "expected 'restricted'"

# M10: publishConfig removed entirely. npm would DEFAULT a scoped package to
# restricted, so the artifact happens to be right — but "private on purpose"
# and "private because nobody said" must not share an exit status, since only
# the first survives someone adding --access public to a workflow.
mutate "publishConfig removed (right answer, no longer a decision)" '
import json
p="package/package.json"
d=json.load(open(p)); d.pop("publishConfig",None); json.dump(d,open(p,"w"),indent=2)
' "expected 'restricted'"

echo
if [ "$CAUGHT" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_RELEASE_META_PASS ($CAUGHT/$TOTAL)"
  exit 0
fi
echo "MUTATION_VERIFY_RELEASE_META_FAIL ($((TOTAL - CAUGHT)) of $TOTAL were NOT caught)"
exit 1
