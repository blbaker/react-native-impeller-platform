#!/usr/bin/env bash
# MUTATION-VERIFY the Windows CONSUMER gate: prove tools/ci-win-consumer.sh can
# go RED, and go red for the RIGHT REASON.
#
# This gate's whole value is covering what ci-win.sh cannot: delivery. So the
# mutations here break DELIVERY, not rendering — a dropped DLL, a wrong package
# name, an inert shim — each of which leaves a perfectly working staged build
# behind and would be invisible to every other gate in the repo.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PKG="packages-engine/engine-win32-x64"
PASS=0; FAILED=0

check() { # name expected-substring logfile
  if grep -q "$2" "$3"; then echo "   ✅ $1 — reddened with: $2"; PASS=$((PASS+1));
  else echo "   ❌ $1 — did NOT report '$2'"; tail -15 "$3" | sed 's/^/      /'; FAILED=$((FAILED+1)); fi
}
# The control is the opposite assertion: it must PASS, not redden. Same grep,
# different sentence — reporting "control reddened with PASS" is nonsense that
# makes a green run read like a failure.
check_green() { # name expected-substring logfile
  if grep -q "$2" "$3"; then echo "   ✅ $1 — green: $2"; PASS=$((PASS+1));
  else echo "   ❌ $1 — did NOT report '$2'"; tail -15 "$3" | sed 's/^/      /'; FAILED=$((FAILED+1)); fi
}

restore_pkg() { bash tools/engine-build.sh win32 x64 > /dev/null 2>&1; }

echo "== M1: a DLL MISSING FROM THE PACKAGE must redden ==="
# ⛔ THE MUTATION THAT JUSTIFIES THIS GATE'S EXISTENCE. The staged build at
# C:\Devel\rni-win-build keeps every DLL, so ci-win.sh stays GREEN throughout
# this mutation — only the consumer's copy is broken. Delete vcruntime140_1.dll
# (not impeller.dll) because it is the one a human would never think to ship.
mv "$PKG/bin/vcruntime140_1.dll" /tmp/vcr140_1.hidden
L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
check "M1 missing runtime DLL" "engine tarball is missing package/bin/vcruntime140_1.dll" "$L"
# ...and prove the claim that this is INVISIBLE to the P5-C gate, rather than
# asserting it in a comment.
LC="$(mktemp)"; bash tools/ci-win.sh > "$LC" 2>&1
if grep -q "P5_WIN_PASS" "$LC"; then
  echo "   ✅ confirmed: ci-win.sh is still GREEN with a broken package — this gate is not redundant"
else
  echo "   ⚠️  ci-win.sh also reddened; the two gates overlap more than assumed"
fi
mv /tmp/vcr140_1.hidden "$PKG/bin/vcruntime140_1.dll"

echo
echo "== M2: the WRONG PACKAGE NAME must redden (windows-x64, not win32-x64) =="
# resolve.js computes the package name from process.platform at RUNTIME. A
# package published as 'engine-windows-x64' packs, installs and lints perfectly
# and can never be found — the failure appears only at a consumer's first run.
cp "$PKG/package.json" /tmp/pkgjson.bak
node -e '
const fs=require("fs"), p=process.argv[1];
const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.name="@react-native-impeller/engine-windows-x64";
fs.writeFileSync(p, JSON.stringify(j,null,2));
' "$PKG/package.json"
L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
check "M2 wrong package name" "engine package not installed" "$L"
cp /tmp/pkgjson.bak "$PKG/package.json"

echo
echo "== M3: a VERSION MISMATCH must redden, naming the packages =="
# The engine C ABI is versioned in lockstep. A drifting engine package installs
# fine and crashes at runtime in ways that read like renderer bugs.
cp "$PKG/package.json" /tmp/pkgjson.bak
node -e '
const fs=require("fs"), p=process.argv[1];
const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.version="0.0.2";
fs.writeFileSync(p, JSON.stringify(j,null,2));
' "$PKG/package.json"
L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
check "M3 version mismatch" "Engine version mismatch" "$L"
cp /tmp/pkgjson.bak "$PKG/package.json"

echo
echo "== M4: an INERT METRO SHIM must redden (layer 2, not layer 1) =="
# ⛔ THE SILENT ONE. Break the resolved-path matching so no shim ever fires: the
# tarball is complete, npm install succeeds, metro exits 0 and writes a valid
# bundle. Every file-level check passes. Only reading the BUNDLE CONTENT (and
# then the pixels) can catch it. This is the historical skia-platform bug.
SHIMS="package/src/metro-shims/index.js"
cp "$SHIMS" /tmp/shims.bak
node -e '
const fs=require("fs"), p=process.argv[1];
let s=fs.readFileSync(p,"utf8");
// make every suffix comparison fail without changing the shape of the code
s=s.replace("if (posix.endsWith(suffix)) return path.join(SHIM_DIR, shim);",
            "if (posix.endsWith(suffix + \".never\")) return path.join(SHIM_DIR, shim);");
fs.writeFileSync(p, s);
' "$SHIMS"
L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
check "M4 inert shim" "shim marker absent from the bundle" "$L"
cp /tmp/shims.bak "$SHIMS"

echo
echo "== M5: a PIXEL-ONLY regression must redden with packaging INTACT =="
# The counterpart to M4: leave delivery perfect and break only what reaches the
# framebuffer. Every grep-able assertion still passes — the tarball is complete,
# the marker is in the bundle, the engine exits 0 and prints RENDER_OK — so if
# this is not caught, the pixel assertions are decoration.
MAIN="engine/host/main.cpp"
cp "$MAIN" /tmp/main.bak
node -e '
const fs=require("fs"), p=process.argv[1];
let s=fs.readFileSync(p,"utf8");
// paint the status swatch in the SAME colour as the background: the packaging
// chain is untouched, only the pixel differs.
s=s.replace("ImpellerColor status = shimOk",
            "ImpellerColor status = true ? ImpellerColor{1.0f,1.0f,1.0f,1.0f,kImpellerColorSpaceSRGB} : shimOk");
fs.writeFileSync(p, s);
' "$MAIN"
bash tools/engine-build.sh win32 x64 > /tmp/m5-build.log 2>&1 \
  && { L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
       check "M5 pixel-only regression" "status swatch is not green" "$L"; } \
  || { echo "   ❌ M5 — the mutated engine did not build"; tail -10 /tmp/m5-build.log | sed 's/^/      /'; FAILED=$((FAILED+1)); }
cp /tmp/main.bak "$MAIN"
restore_pkg

echo
echo "== control: the gate is GREEN again after every mutation is reverted =="
L="$(mktemp)"; bash tools/ci-win-consumer.sh > "$L" 2>&1
check_green "control" "P5_WIN_CONSUMER_PASS" "$L"

echo
[ "$FAILED" -eq 0 ] && echo "MUTATION_VERIFY_WIN_CONSUMER_PASS ($PASS/6)" \
  || { echo "MUTATION_VERIFY_WIN_CONSUMER_FAIL ($FAILED of 6 were NOT caught)"; exit 1; }
