#!/usr/bin/env bash
# Proves release-please-config.json's extra-files jsonpaths actually target
# the version fields they claim to, and that every targeted file currently
# agrees with the single version release-please tracks (the "." package).
#
# WHY THIS IS A GATE
# -------------------
# release-please-action is never run against this repo as part of CI or by
# this gate -- doing so would need a GitHub token and would create a real
# pull request. "Prove the bump wiring" is done the other way around: parse
# the same config file release-please would read, resolve each jsonpath by
# hand against the real files, and check the result matches what the
# manifest says the current version is. A path that resolves to nothing, or
# to a value already out of lockstep, would make a real release-please run
# silently miss a field -- exactly the ci-release-meta.sh class of defect,
# one stage earlier.
#
# This only understands the two jsonpath shapes release-please-config.json
# actually uses here ($.version and $.optionalDependencies['key']) -- it is
# not a general JSONPath implementation, on purpose (YAGNI).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
fail() { echo "RELEASE_PLEASE_CONFIG_FAIL: $*" >&2; FAIL=1; }

CONFIG="${1:-release-please-config.json}"
MANIFEST="${2:-.release-please-manifest.json}"

[ -f "$CONFIG" ] || { echo "RELEASE_PLEASE_CONFIG_FAIL: no such config: $CONFIG" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "RELEASE_PLEASE_CONFIG_FAIL: no such manifest: $MANIFEST" >&2; exit 1; }

python3 - "$CONFIG" "$MANIFEST" <<'PY'
import json, re, sys

config_path, manifest_path = sys.argv[1:3]
config = json.load(open(config_path))
manifest = json.load(open(manifest_path))

print(f"config: {config_path}")

bad = False

def jsonpath_get(doc, jsonpath):
    """Resolve exactly the two shapes this config uses. Returns (value, found)."""
    if jsonpath == "$.version":
        return doc.get("version"), "version" in doc
    m = re.fullmatch(r"\$\.optionalDependencies\['([^']+)'\]", jsonpath)
    if m:
        key = m.group(1)
        opt = doc.get("optionalDependencies", {})
        return opt.get(key), key in opt
    return None, False

# The manifest is keyed by package path; we only use the "." package.
if "." not in manifest:
    print("RELEASE_PLEASE_CONFIG_FAIL: manifest has no '.' entry", file=sys.stderr)
    sys.exit(1)
root_version = manifest["."]
print(f"  manifest version (.): {root_version}")

pkg_cfg = (config.get("packages") or {}).get(".")
if pkg_cfg is None:
    print("RELEASE_PLEASE_CONFIG_FAIL: config has no '.' package", file=sys.stderr)
    sys.exit(1)

extra_files = pkg_cfg.get("extra-files", [])
if not extra_files:
    print("RELEASE_PLEASE_CONFIG_FAIL: '.' package declares no extra-files -- the"
          " engine packages and the optionalDependencies pins would never be bumped",
          file=sys.stderr)
    sys.exit(1)

seen_paths = set()
for entry in extra_files:
    if not isinstance(entry, dict) or entry.get("type") != "json":
        continue  # a bare string or non-json entry is outside this gate's scope
    path = entry.get("path")
    jsonpath = entry.get("jsonpath")
    if not path or not jsonpath:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: json extra-file entry missing path/jsonpath: {entry}",
              file=sys.stderr)
        bad = True
        continue
    seen_paths.add(path)
    try:
        doc = json.load(open(path))
    except FileNotFoundError:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: {path} does not exist -- extra-files"
              f" entry for {jsonpath!r} targets a file release-please cannot find",
              file=sys.stderr)
        bad = True
        continue
    value, found = jsonpath_get(doc, jsonpath)
    if not found:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: {path}: jsonpath {jsonpath!r} does not"
              f" resolve to any field -- a real release-please run would silently"
              f" skip this bump", file=sys.stderr)
        bad = True
        continue
    if value != root_version:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: {path}: jsonpath {jsonpath!r} ="
              f" {value!r}, expected {root_version!r} (out of lockstep with the"
              f" manifest version BEFORE release-please has even run)", file=sys.stderr)
        bad = True
        continue
    print(f"  OK {path} {jsonpath} = {value}")

# Mirror of ci-release-meta.sh's own check: every optionalDependency pin and
# every packages-engine/*/package.json version must be covered by an
# extra-files entry, or a new engine package added later silently drifts.
root_pkg = json.load(open("package/package.json"))
for name, spec in sorted(root_pkg.get("optionalDependencies", {}).items()):
    jp = f"$.optionalDependencies['{name}']"
    covered = any(
        e.get("path") == "package/package.json" and e.get("jsonpath") == jp
        for e in extra_files if isinstance(e, dict)
    )
    if not covered:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: package/package.json optionalDependency"
              f" {name!r} has no extra-files entry -- it would never be bumped",
              file=sys.stderr)
        bad = True

import os
for entry in sorted(os.listdir("packages-engine")):
    p = f"packages-engine/{entry}/package.json"
    if not os.path.exists(p):
        continue
    covered = any(
        e.get("path") == p and e.get("jsonpath") == "$.version"
        for e in extra_files if isinstance(e, dict)
    )
    if not covered:
        print(f"RELEASE_PLEASE_CONFIG_FAIL: {p} has no extra-files $.version entry"
              f" -- this engine package would never be bumped", file=sys.stderr)
        bad = True

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=1

# Tag shape: release.yml only fires on bare v<version> tags and strips
# exactly one 'v' when comparing to package/package.json's version. That
# requires include-component-in-tag to stay false for the root package.
python3 - "$CONFIG" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
if config.get("include-component-in-tag", True) is not False:
    print("RELEASE_PLEASE_CONFIG_FAIL: include-component-in-tag must be false,"
          " or the tag release-please creates will not match release.yml's"
          " refs/tags/v* trigger", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
[ $? -eq 0 ] || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "RELEASE_PLEASE_CONFIG_FAIL"
  exit 1
fi
echo "RELEASE_PLEASE_CONFIG_PASS"
