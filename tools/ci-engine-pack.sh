#!/usr/bin/env bash
# ENGINE_PACK gate: what `npm pack` ships must be the engine that was staged.
#
# npm pack keeps regular files and directories. It drops symlinks without a
# warning. A macOS framework's Versions/Current, binary and Resources entries
# are all symlinks, so 0.1.0's hermesvm.framework arrived as a bare Versions/0
# tree. dyld still loaded it through @rpath, so every launch check passed, and
# codesign of any .app that embedded it failed:
#
#   bundle format unrecognized, invalid, or unsuitable
#   In subcomponent: .../Contents/MacOS/hermesvm.framework
#
# Checking the staged directory cannot see that. This gate packs the package
# for real, unpacks the tarball, and checks what came out.
#
# Usage: bash tools/ci-engine-pack.sh <engine package dir>
#   e.g. bash tools/ci-engine-pack.sh packages-engine/engine-darwin-arm64
#
# Arms:
#   A  the staged bin/ holds no symlinks (npm pack would drop them)
#   B  every regular file in the staged bin/ ships, with its size and exec bit
#   C  every dependency of every shipped binary resolves inside the shipped
#      bin/: Mach-O @loader_path/@rpath/@executable_path through otool (or
#      llvm-otool off a Mac), ELF through ldd on a Linux host
#   D  macOS host only: the shipped engine starts (--help, from /), and an .app
#      that embeds the shipped bin/ in Contents/MacOS signs and passes
#      `codesign --verify --deep --strict`, then starts from inside the .app
#   E  a standard .app layout loads with no install_name_tool: rn-impeller in
#      Contents/MacOS, its dylibs in Contents/Frameworks. Static (C's resolver
#      on that layout) on any host with otool/llvm-otool; on a macOS host the
#      .app is also signed, verified --deep --strict, and started
# Every arm runs, even after an earlier one fails, so one run names every
# problem. tools/mutation-verify-engine-pack.sh proves each arm can fail.
set -uo pipefail

PKG="${1:?usage: ci-engine-pack.sh <engine package dir>}"
PKG="$(cd "$PKG" && pwd)" || { echo "ENGINE_PACK_FAIL: no such dir: $1"; exit 1; }
[ -f "$PKG/package.json" ] && [ -d "$PKG/bin" ] \
  || { echo "ENGINE_PACK_FAIL: $PKG needs package.json and bin/"; exit 1; }
command -v npm >/dev/null || { echo "ENGINE_PACK_FAIL: npm not found; cannot pack"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/engine-pack-XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAILED=""
fail() { echo "  [$1] FAIL: $2"; case " $FAILED " in *" $1 "*) ;; *) FAILED="$FAILED $1" ;; esac; }

echo "engine-pack: $(basename "$PKG")"

# A. Symlinks. Name each one with its target, so the fix is obvious.
LINKS="$(cd "$PKG/bin" && find . -type l -exec sh -c 'printf "%s -> %s\n" "$1" "$(readlink "$1")"' _ {} \;)"
if [ -n "$LINKS" ]; then
  fail A "staged bin/ holds symlinks, and npm pack drops every one of them:"
  echo "$LINKS" | sed 's/^/        /'
else
  echo "  [A] no symlinks in staged bin/ ... OK"
fi

# Pack for real. --ignore-scripts: packing must not run package code.
TGZ="$(cd "$PKG" && npm pack --ignore-scripts --silent --pack-destination "$T" 2>"$T/pack.err" | tail -1)"
if [ -z "$TGZ" ] || [ ! -f "$T/$TGZ" ]; then
  echo "ENGINE_PACK_FAIL: npm pack produced no tarball: $(head -c 300 "$T/pack.err")"; exit 1
fi
mkdir "$T/x" && tar -xzf "$T/$TGZ" -C "$T/x" || { echo "ENGINE_PACK_FAIL: cannot unpack $TGZ"; exit 1; }
X="$T/x/package"

# B + C (and E, below) need parsing; python3 is on every runner and dev box
# this builds on. `check.py <staged> <shipped>` runs B and C;
# `check.py --layout <root>` runs only the dependency resolver, as arm E.
cat > "$T/check.py" <<'PY'
import os, shutil, stat, subprocess, sys
if sys.argv[1] == "--layout":
    staged, shipped, arm, where = None, sys.argv[2], "E", "the .app layout"
else:
    staged, shipped, arm, where = sys.argv[1], sys.argv[2], "C", "the shipped bin/"
bad = {"B": [], arm: []}

def files(root):
    out = {}
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            if os.path.isfile(p) and not os.path.islink(p):
                out[os.path.relpath(p, root)] = os.stat(p)
    return out

s, x = (files(staged) if staged else {}), files(shipped)
for rel, st in sorted(s.items()):
    if rel not in x:
        bad["B"].append(f"{rel} is staged but not in the tarball")
        continue
    if st.st_size != x[rel].st_size:
        bad["B"].append(f"{rel} is {st.st_size} bytes staged, {x[rel].st_size} shipped")
    if bool(st.st_mode & stat.S_IXUSR) != bool(x[rel].st_mode & stat.S_IXUSR):
        bad["B"].append(f"{rel} lost or gained its exec bit in the tarball")
summary = [f"B {len(s)} staged files checked against the tarball"] if staged else []

def kind(p):
    with open(p, "rb") as f:
        h = f.read(4)
    if h in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        return "macho"
    return "elf" if h == b"\x7fELF" else None

otool = shutil.which("otool") or next(
    (t for t in ["llvm-otool"] + [f"llvm-otool-{v}" for v in range(30, 13, -1)] if shutil.which(t)), None)
def run(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.splitlines()

engine_dir = os.path.join(shipped, os.path.dirname(next((r for r in x if os.path.basename(r) == "rn-impeller"), "rn-impeller")))
checked = 0
for rel in sorted(x):
    p = os.path.join(shipped, rel)
    k = kind(p)
    if k == "elf" and sys.platform.startswith("linux"):
        for line in subprocess.run(["ldd", p], capture_output=True, text=True, cwd="/").stdout.splitlines():
            if "not found" in line:
                bad[arm].append(f"{rel}: {line.strip()}")
        checked += 1
    if k != "macho":
        continue
    if not otool:
        bad[arm].append(f"{rel} is Mach-O and no otool/llvm-otool is on PATH; cannot check its dependencies")
        continue
    checked += 1
    here = os.path.dirname(p)
    ident = [l.strip() for l in run(otool, "-D", p)[1:] if l.strip()]
    lines = run(otool, "-l", p)
    rpaths = [lines[i + 2].split()[1] for i, l in enumerate(lines)
              if l.strip() == "cmd LC_RPATH" and i + 2 < len(lines)]
    def expand(path):
        return (path.replace("@loader_path", here).replace("@executable_path", engine_dir))
    for l in run(otool, "-L", p)[1:]:
        dep = l.strip().split(" (compatibility")[0]
        if not dep or dep in ident:
            continue
        if dep.startswith(("/usr/lib/", "/System/Library/")):
            continue
        if dep.startswith("@rpath/"):
            cands = [os.path.join(expand(r), dep[len("@rpath/"):]) for r in rpaths]
        elif dep.startswith(("@loader_path/", "@executable_path/")):
            cands = [expand(dep)]
        else:
            bad[arm].append(f"{rel} -> {dep} (not relocatable)")
            continue
        ok = [c for c in cands if os.path.isfile(c) and os.path.realpath(c).startswith(os.path.realpath(shipped))]
        if not ok:
            bad[arm].append(f"{rel} -> {dep} resolves to nothing in {where} (rpaths: {rpaths or 'none'})")
summary.append(f"{arm} {checked} shipped binaries checked (Mach-O: {otool or 'no otool'}, ELF: ldd)")
# Failures first, so the shell knows an arm failed before it reads the summary.
for a in bad:
    for msg in bad[a]:
        print(f"{a}! {msg}")
print("\n".join(summary))
PY
python3 "$T/check.py" "$PKG/bin" "$X/bin" > "$T/bc.out"
while IFS= read -r line; do
  case "$line" in
    B!*) fail B "${line#B! }" ;;
    C!*) fail C "${line#C! }" ;;
    B\ *) case " $FAILED " in *" B "*) ;; *) echo "  [B] ${line#B } ... OK" ;; esac ;;
    C\ *) case " $FAILED " in *" C "*) ;; *) echo "  [C] ${line#C } ... OK" ;; esac ;;
  esac
done < "$T/bc.out"
grep -q '^B ' "$T/bc.out" && grep -q '^C ' "$T/bc.out" || { echo "ENGINE_PACK_FAIL: the B/C checker did not run: $(head -3 "$T/bc.out")"; exit 1; }

# D. The consumer's view on a Mac: start it, then embed it in an .app and sign.
if [ "$(uname -s)" = "Darwin" ] && [ -f "$X/bin/rn-impeller" ]; then
  if (cd / && "$X/bin/rn-impeller" --help >/dev/null 2>"$T/help.err"); then
    echo "  [D] shipped engine starts (--help from /) ... OK"
  else
    fail D "shipped engine does not start: $(head -c 300 "$T/help.err")"
  fi
  APP="$T/PackProbe.app"
  mkdir -p "$APP/Contents/MacOS" && cp -R "$X/bin/." "$APP/Contents/MacOS/"
  cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>rn-impeller</string>
<key>CFBundleIdentifier</key><string>dev.rnip.packprobe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>PackProbe</string>
</dict></plist>
PL
  if ! codesign --force --deep --sign - "$APP" >"$T/sign.out" 2>&1; then
    fail D "an .app embedding the shipped bin/ does not sign:"; sed 's/^/        /' "$T/sign.out" | tail -3
  elif ! codesign --verify --deep --strict "$APP" >"$T/verify.out" 2>&1; then
    fail D "the signed .app fails codesign --verify --deep --strict:"; sed 's/^/        /' "$T/verify.out" | tail -3
  elif ! (cd / && "$APP/Contents/MacOS/rn-impeller" --help >/dev/null 2>&1); then
    fail D "the engine does not start from inside the signed .app"
  else
    echo "  [D] .app embedding the shipped bin/ signs, verifies --deep --strict, starts ... OK"
  fi
else
  echo "  [D] SKIP: needs a macOS host and a darwin package (this is $(uname -s))"
fi

# E. The standard .app layout, untouched: rn-impeller in Contents/MacOS, its
# dylibs in Contents/Frameworks, other files in Contents/Resources. 0.1.0
# aborted here (rc=134): its references were @loader_path/libfoo.dylib, which
# only ever look beside the executable, so consumers ran install_name_tool on
# the binary. Darwin packages only; Linux and Windows have no such layout.
MAGIC="$(od -An -tx1 -N4 "$X/bin/rn-impeller" 2>/dev/null | tr -d ' \n')"
case "$MAGIC" in
  cffaedfe|cafebabe)
    FW="$T/FwProbe.app"
    mkdir -p "$FW/Contents/MacOS" "$FW/Contents/Frameworks" "$FW/Contents/Resources"
    for f in "$X/bin"/*; do
      n="$(basename "$f")"
      if [ "$n" = rn-impeller ]; then cp -p "$f" "$FW/Contents/MacOS/"
      elif [ "${n%.framework}" != "$n" ] \
        || [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = cffaedfe ]; then cp -R "$f" "$FW/Contents/Frameworks/"
      else cp -R "$f" "$FW/Contents/Resources/"
      fi
    done
    python3 "$T/check.py" --layout "$FW" > "$T/e.out"
    grep -q '^E ' "$T/e.out" || { echo "ENGINE_PACK_FAIL: the E checker did not run: $(head -3 "$T/e.out")"; exit 1; }
    while IFS= read -r line; do
      case "$line" in E!*) fail E "${line#E! }" ;; esac
    done < "$T/e.out"
    case " $FAILED " in
      *" E "*) ;;
      *) echo "  [E] MacOS + Frameworks layout: $(sed -n 's/^E //p' "$T/e.out" | head -1), all resolve ... OK" ;;
    esac
    if [ "$(uname -s)" = "Darwin" ]; then
      sed 's/PackProbe/FwProbe/g' "$T/PackProbe.app/Contents/Info.plist" > "$FW/Contents/Info.plist" 2>/dev/null \
        || fail E "no Info.plist to copy from arm D"
      if ! codesign --force --deep --sign - "$FW" >"$T/fwsign.out" 2>&1; then
        fail E "the MacOS + Frameworks .app does not sign:"; sed 's/^/        /' "$T/fwsign.out" | tail -3
      elif ! codesign --verify --deep --strict "$FW" >"$T/fwverify.out" 2>&1; then
        fail E "the MacOS + Frameworks .app fails codesign --verify --deep --strict:"; sed 's/^/        /' "$T/fwverify.out" | tail -3
      elif ! (cd / && "$FW/Contents/MacOS/rn-impeller" --help >/dev/null 2>"$T/fwhelp.err"); then
        fail E "the engine does not start from Contents/MacOS with its dylibs in Contents/Frameworks: $(head -c 300 "$T/fwhelp.err")"
      else
        echo "  [E] MacOS + Frameworks .app signs, verifies --deep --strict, starts ... OK"
      fi
    else
      echo "  [E] sign + start: SKIP (needs a macOS host; the static arm above ran)"
    fi
    ;;
  *) echo "  [E] SKIP: not a Mach-O package" ;;
esac

if [ -n "$FAILED" ]; then
  echo "ENGINE_PACK_FAIL (arms:$FAILED)"; exit 1
fi
echo "ENGINE_PACK_PASS ($TGZ)"
