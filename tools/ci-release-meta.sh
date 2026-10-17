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
# to run `npm install @blbaker/react-native-impeller-platform-engine-darwin-arm64@0.0.1` — a
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
ROOT_NAME="$(python3 -c "import json;print(json.load(open('$ROOT_PKG'))['name'])")"
echo "root: ${ROOT_NAME}@${ROOT_VER}"

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
    name = f"@blbaker/react-native-impeller-platform-engine-{triple}"
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

# NOTE: built as plain statements rather than one nested comprehension. The
# comprehension version was harder to read and was rejected by tooling that
# inspects this file's text, so the explicit loop is both clearer and portable.
entry_points = []
if d.get("main"):
    entry_points.append(("main", d["main"]))
bin_map = d.get("bin") or {}
for bin_name in sorted(bin_map):
    entry_points.append(("bin." + bin_name, bin_map[bin_name]))

for label, rel in entry_points:
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

# 5. PUBLISH ACCESS MUST BE DECLARED, AND IT IS `public`.
#    Baker's call, 2026-08-15: these ship PUBLIC. (Was `restricted` through
#    P7-B; the reversal is deliberate and is why the value is a single
#    variable.)
#
#    Declaring it in package.json, rather than passing an access flag on the
#    publish invocation, keeps the setting attached to the artifact: it shows up
#    in review as a one-line diff, and no CI edit can widen visibility on its
#    own.
#
#    ⛔ THE DIRECTION OF RISK JUST REVERSED, AND THIS CHECK MATTERS MORE NOW.
#    For a SCOPED package npm defaults to `restricted`, so while the decision
#    was "private" the default silently agreed with us and an omission was
#    harmless. `public` is NOT the default: an omitted or reverted
#    publishConfig now means the publish is refused (or, worse on a paid
#    account, quietly succeeds as a private package nobody can install). The
#    setting is now load-bearing rather than merely documentary.
#
#    An npm publish is not reversible in either direction. A package made
#    public cannot be made private again; it can only be deprecated, and the
#    tarball stays fetchable forever. That is the whole reason publishing stays
#    gated behind RNI_PUBLISH_ENABLED until Baker explicitly says otherwise —
#    see .github/workflows/release.yml.
#
#    NOTE: going public also removes the accidental backstop that was holding
#    the line until now. A restricted scoped package requires a PAID npm plan,
#    so a free account was refused with a 402 regardless of any config. Public
#    scoped packages are free to publish, so RNI_PUBLISH_ENABLED is now the
#    ONLY thing between a version tag and a permanent registry entry.
EXPECT_ACCESS="${RNI_EXPECT_ACCESS:-public}"
python3 - "$EXPECT_ACCESS" <<'PY'
import glob, json, sys
want = sys.argv[1]
bad = False
for p in ["package/package.json"] + sorted(glob.glob("packages-engine/*/package.json")):
    d = json.load(open(p))
    name = d["name"]
    access = (d.get("publishConfig") or {}).get("access")
    if not name.startswith("@"):
        # Unscoped packages are always public, and npm refuses to publish one
        # that declares access=restricted, so that value is the only error here.
        if access == "restricted":
            print(f"RELEASE_META_FAIL: {name} is unscoped but declares"
                  " publishConfig.access='restricted'; npm refuses that publish"
                  " (unscoped packages are always public).", file=sys.stderr)
            bad = True
        else:
            print(f"  OK {name} is unscoped (always public)")
        continue
    if access != want:
        print(f"RELEASE_META_FAIL: {name} has publishConfig.access={access!r},"
              f" expected {want!r}. Publish visibility is a deliberate decision;"
              " update package.json and this check together.",
              file=sys.stderr)
        bad = True
    else:
        print(f"  OK publishConfig.access={want} {name}")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=1

# 6. EVERY ENGINE PACKAGE CARRIES ITS ENGINE — only when a publish is about to
#    happen (RNI_REQUIRE_ENGINE_BINARIES=1, set by release.yml after it unpacks
#    the per-OS builds).
#
#    packages-engine/*/bin is gitignored, so a fresh checkout has package.json
#    and README.md and nothing else. Everything above passes on that tree, and
#    `npm publish` happily ships it: a package that installs cleanly and holds
#    no engine. Off by default, because a laptop or the gates job has at most
#    its own platform's build and that is not a defect there.
#
#    Three ways the binary can be "there" and still wrong, each checked:
#      - missing, or not executable (a lost exec bit is an EACCES at spawn);
#      - built for the wrong OS or CPU (an artifact unpacked into the wrong
#        folder installs fine and fails at exec with an unrelated error) —
#        read from the file's own header, not from where it sits;
#      - present on disk but left out of the tarball (`files`, .npmignore) —
#        asked of `npm pack --dry-run`, which is what publish actually ships.
if [ "${RNI_REQUIRE_ENGINE_BINARIES:-0}" = "1" ]; then
python3 - <<'PY'
import glob, json, os, subprocess, sys

FORMAT = {"linux": "ELF", "darwin": "Mach-O", "win32": "PE"}

def ident(path):
    with open(path, "rb") as f:
        h = f.read(4096)
    if h[:4] == b"\x7fELF":
        order = "little" if h[5] == 1 else "big"
        m = int.from_bytes(h[18:20], order)
        return "ELF", {0x3E: "x64", 0xB7: "arm64"}.get(m, hex(m))
    if h[:4] == b"\xcf\xfa\xed\xfe":
        c = int.from_bytes(h[4:8], "little")
        return "Mach-O", {0x01000007: "x64", 0x0100000C: "arm64"}.get(c, hex(c))
    if h[:2] == b"MZ" and len(h) >= 0x40:
        off = int.from_bytes(h[0x3C:0x40], "little")
        if h[off:off + 4] == b"PE\0\0":
            m = int.from_bytes(h[off + 4:off + 6], "little")
            return "PE", {0x8664: "x64", 0xAA64: "arm64"}.get(m, hex(m))
    return "unrecognised", None

bad = False
def fail(msg):
    global bad
    print(f"RELEASE_META_FAIL: {msg}", file=sys.stderr)
    bad = True

for pj in sorted(glob.glob("packages-engine/*/package.json")):
    pkg = os.path.dirname(pj)
    name = json.load(open(pj))["name"]
    triple = os.path.basename(pkg).removeprefix("engine-")
    os_, cpu = triple.split("-", 1)
    exe = "rn-impeller.exe" if os_ == "win32" else "rn-impeller"
    path = os.path.join(pkg, "bin", exe)
    if not os.path.isfile(path):
        fail(f"{name} has no engine binary (bin/{exe}). Publishing it would ship"
             " a package that installs cleanly and contains no engine.")
        continue
    fmt, arch = ident(path)
    if (fmt, arch) != (FORMAT.get(os_), cpu):
        fail(f"{name}: bin/{exe} is a {fmt} {arch} binary, expected"
             f" {FORMAT.get(os_)} {cpu} for {triple}")
        continue
    if os_ != "win32" and not os.access(path, os.X_OK):
        fail(f"{name}: bin/{exe} is not executable (the exec bit was lost in transit)")
        continue
    out = subprocess.run(["npm", "pack", "--dry-run", "--json", "--ignore-scripts"],
                         cwd=pkg, capture_output=True, text=True)
    try:
        shipped = {f["path"] for f in json.loads(out.stdout)[0]["files"]}
    except (ValueError, IndexError, KeyError):
        fail(f"{name}: could not read `npm pack --dry-run --json` output: {out.stderr.strip()[:200]}")
        continue
    if f"bin/{exe}" not in shipped:
        fail(f"{name}: bin/{exe} exists but `npm pack` would not ship it"
             " (check 'files' and .npmignore)")
        continue
    print(f"  OK {name} ships bin/{exe} ({fmt} {arch}, {len(shipped)} files)")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "RELEASE_META_FAIL"
  exit "$FAIL"
fi
echo "RELEASE_META_PASS (version=${ROOT_VER})"
