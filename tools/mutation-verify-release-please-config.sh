#!/usr/bin/env bash
# Mutation-verify tools/ci-release-please-config.sh. Same pattern as
# mutation-verify-release-meta.sh: mutate the METADATA in a scratch copy of
# the repo, never the gate itself, and require each mutation to redden the
# gate for the specific reason it exists to catch.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
REPO="$PWD"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CAUGHT=0
TOTAL=0

if ! bash tools/ci-release-please-config.sh >"$WORK/base.log" 2>&1; then
  echo "MUTATION_VERIFY_RELEASE_PLEASE_CONFIG_FAIL (baseline is RED)"
  tail -8 "$WORK/base.log"
  exit 1
fi
grep -q "RELEASE_PLEASE_CONFIG_PASS" "$WORK/base.log" || {
  echo "MUTATION_VERIFY_RELEASE_PLEASE_CONFIG_FAIL (baseline printed no PASS)"; exit 1; }
echo "baseline: GREEN"

mutate() {  # name, python-edit, expected-substring
  local name="$1" edit="$2" want="$3"
  TOTAL=$((TOTAL + 1))
  local dir="$WORK/m$TOTAL"
  rm -rf "$dir"
  cp -a "$REPO" "$dir" 2>/dev/null
  ( cd "$dir" && python3 -c "$edit" ) || {
    echo "  M$TOTAL $name -> ❌ mutation script failed"; return; }
  local out rc
  out=$(cd "$dir" && bash tools/ci-release-please-config.sh 2>&1); rc=$?
  if ! grep -q "^config: " <<<"$out"; then
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

# M1: an extra-files jsonpath drifts to point at a field that doesn't exist.
mutate "extra-files jsonpath targets a dropped field" '
import json
p = "release-please-config.json"
d = json.load(open(p))
fs = d["packages"]["."]["extra-files"]
for e in fs:
    if e.get("path") == "packages-engine/engine-darwin-arm64/package.json":
        e["jsonpath"] = "$.versionTypo"
json.dump(d, open(p, "w"), indent=2)
' "does not resolve to any field"

# M2: an engine package.json drifts out of lockstep with the manifest BEFORE
# release-please has even run (so the gate catches a hand-edited drift, not
# just a missing wire-up).
mutate "engine package.json already out of lockstep with the manifest" '
import json
p = "packages-engine/engine-linux-x64/package.json"
d = json.load(open(p))
d["version"] = "0.0.2"
json.dump(d, open(p, "w"), indent=2)
' "out of lockstep"

# M3: a new engine package added with no extra-files entry for it -- the
# mirror of ci-release-meta.sh's "declared but unbuilt" defect, one stage
# earlier: this one is BUILT but never wired into the release bump.
mutate "a new engine package ships with no extra-files entry" '
import json, os
src = "packages-engine/engine-linux-x64"
dst = "packages-engine/engine-linux-arm64"
os.makedirs(dst, exist_ok=True)
d = json.load(open(f"{src}/package.json"))
d["name"] = "@blbaker/react-native-impeller-platform-engine-linux-arm64"
d["cpu"] = ["arm64"]
json.dump(d, open(f"{dst}/package.json", "w"), indent=2)
' "has no extra-files"

# M4: optionalDependencies pin added to package/package.json with no
# matching extra-files entry -- it would never get bumped and would drift
# the moment the FIRST release happens.
mutate "a new optionalDependency has no extra-files entry" '
import json
p = "package/package.json"
d = json.load(open(p))
d["optionalDependencies"]["@blbaker/react-native-impeller-platform-engine-linux-arm64"] = "0.0.1"
json.dump(d, open(p, "w"), indent=2)
' "has no extra-files entry"

# M5: include-component-in-tag flipped (or removed) -- the resulting tag
# would carry a component prefix and release.yml would never fire.
mutate "include-component-in-tag flips away from false" '
import json
p = "release-please-config.json"
d = json.load(open(p))
d["include-component-in-tag"] = True
json.dump(d, open(p, "w"), indent=2)
' "include-component-in-tag must be false"

echo
if [ "$CAUGHT" -eq "$TOTAL" ]; then
  echo "MUTATION_VERIFY_RELEASE_PLEASE_CONFIG_PASS ($CAUGHT/$TOTAL)"
  exit 0
fi
echo "MUTATION_VERIFY_RELEASE_PLEASE_CONFIG_FAIL ($((TOTAL - CAUGHT)) of $TOTAL were NOT caught)"
exit 1
