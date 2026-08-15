#!/usr/bin/env bash
# P7 release metadata gate: the version/dependency invariants that a publish
# would otherwise break SILENTLY.
#
# WHY THIS IS A GATE AND NOT A CHECKLIST
# --------------------------------------
# resolve.js enforces engine/host version lockstep AT RUNTIME with a good error
# message. That check only fires on a machine that already installed a mismatched
# pair — i.e. after publishing. Everything below is the same invariant checked
# BEFORE the tag, where it is still free to fix.
#
# ⛔ THE FINDING THAT MOTIVATED THIS (P7, 2026-08-14)
# package.json declares FIVE engine packages as optionalDependencies while only
# TWO exist. npm treats a missing optional dependency as success:
#
#     $ npm install     # optionalDependencies: engine-darwin-arm64@0.0.1
#     up to date in 795ms      <- exit 0, nothing installed, no warning
#
# So a macOS user would get a clean, quiet install and no engine at all. They
# would then hit resolve.js's "Missing engine package" error, which tells them
# to run `npm install @react-native-impeller/engine-darwin-arm64@0.0.1` — a
# command that CANNOT succeed, because that package does not exist. Good error
# message, impossible instruction. A declared-but-unbuildable target is worse
# than an undeclared one: it converts "unsupported platform" into "broken
# install".
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
fail() { echo "RELEASE_META_FAIL: $*" >&2; FAIL=1; }

ROOT_PKG="package/package.json"
ver() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$1"; }

ROOT_VER="$(ver "$ROOT_PKG")"
echo "root: react-native-impeller@${ROOT_VER}"

# 1. Every engine package that EXISTS carries the root version exactly.
#    The engine C ABI is versioned in lockstep; a mixed pair crashes at runtime,
#    so a range or a drifted literal is a defect, not a preference.
for p in packages-engine/*/; do
  name="$(python3 -c "import json;print(json.load(open('${p}package.json'))['name'])")"
  v="$(ver "${p}package.json")"
  if [ "$v" = "$ROOT_VER" ]; then
    echo "  OK ${name}@${v}"
  else
    fail "${name}@${v} != root ${ROOT_VER} (engine ABI is lockstep)"
  fi
done

# 2. Every optionalDependency must (a) be pinned to the root version EXACTLY —
#    not a range, since ^ or ~ would let npm resolve a mismatched ABI — and
#    (b) correspond to an engine package this repo can actually build.
#
#    (b) is the one npm will never tell you about. See the header.
python3 - "$ROOT_PKG" "$ROOT_VER" <<'PY'
import json, os, sys
root_pkg, root_ver = sys.argv[1:3]
d = json.load(open(root_pkg))
opt = d.get("optionalDependencies", {})
built = set()
for entry in sorted(os.listdir("packages-engine")):
    p = os.path.join("packages-engine", entry, "package.json")
    if os.path.exists(p):
        built.add(json.load(open(p))["name"])

bad = False
for name, spec in sorted(opt.items()):
    if spec != root_ver:
        print(f"RELEASE_META_FAIL: {name} is pinned '{spec}', must be exactly '{root_ver}'"
              " (a range can resolve a mismatched engine ABI)", file=sys.stderr)
        bad = True
    if name not in built:
        print(f"RELEASE_META_FAIL: {name} is declared as an optionalDependency but no"
              " package exists in packages-engine/.", file=sys.stderr)
        print("    npm SKIPS a missing optional dependency and exits 0, so a user on"
              " that platform gets a", file=sys.stderr)
        print("    silent no-engine install, then a resolve.js error telling them to"
              " install a package", file=sys.stderr)
        print("    that cannot be installed. Build it, or drop it from"
              " optionalDependencies AND from", file=sys.stderr)
        print("    SUPPORTED in package/src/resolve.js.", file=sys.stderr)
        bad = True
    if not bad:
        print(f"  OK optional {name}@{spec}")

# The mirror of the same defect: a triple resolve.js claims to SUPPORT but which
# has no package cannot produce anything except that impossible instruction.
sys.path.insert(0, "package/src")
import re
src = open("package/src/resolve.js").read()
m = re.search(r"const SUPPORTED = new Set\(\[(.*?)\]\)", src, re.S)
supported = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
for triple in sorted(supported):
    name = f"@react-native-impeller/engine-{triple}"
    if name not in built:
        print(f"RELEASE_META_FAIL: resolve.js lists '{triple}' as SUPPORTED but"
              f" {name} does not exist.", file=sys.stderr)
        bad = True
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=1

# 3. Files declared as shipping must exist. A repo that cannot reproduce the
#    artifact it publishes is worse than an unpublished one — and `npm pack`
#    happily ships a file that is in no commit (seen for real in skia-platform:
#    9 template files shipping while untracked).
python3 - "$ROOT_PKG" <<'PY'
import json, os, subprocess, sys
d = json.load(open(sys.argv[1]))
bad = False
for entry in d.get("files", []):
    p = os.path.join("package", entry)
    if not os.path.exists(p):
        print(f"RELEASE_META_FAIL: package.json 'files' lists {entry!r}, which does not exist",
              file=sys.stderr)
        bad = True
        continue
    # Shipping-but-untracked: git cannot describe it, so no sha can prove it shipped.
    r = subprocess.run(["git", "ls-files", "--error-unmatch", p],
                       capture_output=True, text=True)
    if r.returncode != 0 and os.path.isfile(p):
        print(f"RELEASE_META_FAIL: {entry!r} ships in npm pack but is UNTRACKED in git",
              file=sys.stderr)
        bad = True

# 4. Entry points declared in package.json must exist IN THE SHIPPED TREE.
#    `main`, `bin` and `scripts` naming a missing file is invisible until a user
#    runs it: `npm test` on the published package died with MODULE_NOT_FOUND on
#    src/selftest.js, a file that was never written. npm validates none of this.
def shipped(rel):
    """Is this path inside a directory/file listed in `files`?"""
    rel = rel.lstrip("./")
    return any(rel == f or rel.startswith(f.rstrip("/") + "/") for f in d.get("files", []))

for label, rel in (
    [("main", d["main"])] if d.get("main") else []
) + [(f"bin.{k}", v) for k, v in (d.get("bin") or {}).items()]:
    if not os.path.exists(os.path.join("package", rel)):
        print(f"RELEASE_META_FAIL: {label} points at {rel!r}, which does not exist",
              file=sys.stderr)
        bad = True
    elif not shipped(rel):
        print(f"RELEASE_META_FAIL: {label} points at {rel!r}, which is NOT covered by"
              " 'files' — it will be missing from the tarball", file=sys.stderr)
        bad = True

for name, cmd in (d.get("scripts") or {}).items():
    # Only the simple `node <path>` form is checkable without running anything.
    parts = cmd.split()
    if len(parts) == 2 and parts[0] == "node":
        rel = parts[1]
        if not os.path.exists(os.path.join("package", rel)):
            print(f"RELEASE_META_FAIL: scripts.{name} runs {rel!r}, which does not exist",
                  file=sys.stderr)
            bad = True

sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo "RELEASE_META_FAIL"
  exit 1
fi
echo "RELEASE_META_PASS (version=${ROOT_VER})"
