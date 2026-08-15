#!/usr/bin/env bash
# P4 GATE: the TurboModule seam — can JS actually CALL native, and does the
# packaging ship a callable seam?
#
# P3 proved the renderer paints props correctly. It says nothing about the
# other half of a platform: the native modules an app talks to. This gate asks
# three questions that fail independently, which is why it is three layers
# rather than one assertion:
#
#   LAYER 1  file in tarball      — is the shim shipped at all?
#   LAYER 2  METHOD in shim       — is every native method reachable from the
#                                   SHIPPED JS? (a file-presence check passes
#                                   happily while half a module's methods are
#                                   uncallable — measured on a prior project:
#                                   4 of 11 methods unreachable, all gates green)
#   LAYER 3  consumer extraction  — does the installed copy match the tarball?
#
# ...plus the assertion the other three cannot make: PIXELS. Each module's
# result is painted as a swatch by the fixture, so a module that is absent,
# unreachable, or returning its default leaves BACKGROUND at a probe. Every
# expectation is a NON-DEFAULT value: asserting colorScheme === 'light' would
# pass with no Appearance module at all, because that is RN's fallback.
#
# Runs through the CONSUMER path like P1/P2/P3 — tarballs into a pristine app
# outside the repo — because a seam that only works from the repo is not
# shipped.
set -euo pipefail
# ⛔ RESOLVE tools/ BEFORE the cd. Sourcing via "$(dirname "$0")/..." AFTER it
# re-resolves a relative $0 against the repo root and silently looks for
# <repo>/ci-triple.sh — a miss that only shows when the gate is invoked from
# inside tools/.
CI_TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/.."
ROOT="$PWD"
# Host triple (RNI_PLATFORM / RNI_ARCH / RNI_TRIPLE / RNI_ENGINE_PKG). Replaces
# the hardcoded "linux x64" that made this gate unrunnable on any other host.
. "$CI_TOOLS/ci-triple.sh"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p4-modules"

fail() { echo "P4_MODULES_FAIL: $*" >&2; exit 1; }

# Provision the cached stock RN app rather than requiring a human to have
# made one. This precondition used to be satisfied by HISTORY on a dev box,
# which is why CI could not run this gate at all.
[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (tools/base-app.sh failed)"
bash tools/engine-build.sh "$RNI_PLATFORM" "$RNI_ARCH" > /dev/null || fail "engine build failed"
ENGINE_LOCAL="$ROOT/${RNI_ENGINE_PKG}/bin/rn-impeller"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== 1. the URL predicate self-test (no side effects, no browser) =="
# This runs FIRST and on its own because it is the one assertion protecting a
# platform this CI cannot build. POSIX exec passes the URL as argv[1] with no
# shell; Windows ShellExecuteW RESOLVES it the way the shell would, so a
# one-for-one port would launch a .bat or a UNC path. The predicate is shared
# code precisely so the Linux gate exercises the Windows guard.
OPENURL="$("$ENGINE_LOCAL" --test-openurl)" || fail "openurl self-test exited nonzero: $OPENURL"
echo "   $OPENURL"
case "$OPENURL" in
  OPENURL_PASS*) ;;
  *) fail "openurl self-test did not pass: $OPENURL" ;;
esac

# ---------------------------------------------------------------------------
echo "== 2. the module manifest, enumerated FROM JAVASCRIPT =="
# Not from C++. Reading methodMap_ in C++ answers "what did we register", which
# we already know; going through global.nativeModuleProxy answers "what can a
# bundle CALL". A module registered perfectly but unreachable through the
# binding is invisible to the first question.
MANIFEST="$WORK/manifest.txt"
"$ENGINE_LOCAL" --list-modules 2>/dev/null | sed 's/^\[js\] //' > "$MANIFEST" || fail "--list-modules failed"
grep -q '^MODULE_MANIFEST_END$' "$MANIFEST" || fail "manifest is truncated — the engine did not finish enumerating"
if grep -q 'UNREACHABLE FROM JS' "$MANIFEST"; then
  echo "--- manifest ---"; cat "$MANIFEST"
  fail "a registered module is not reachable through nativeModuleProxy: $(grep -c 'UNREACHABLE' "$MANIFEST") module(s)"
fi
MODULE_COUNT="$(grep -c '^module=' "$MANIFEST")"
echo "   $MODULE_COUNT modules reachable from JS"

# The D7 set must be present BY NAME. A manifest that merely has "some
# modules" would go green if the platform set silently vanished and only the
# boot-path modules remained.
for required in PlatformConstants SourceCode ExceptionsManager AppState DeviceInfo \
                Appearance AlertManager StatusBarManager DevSettings LinkingManager; do
  grep -q "^module=$required " "$MANIFEST" \
    || fail "module '$required' is missing from the seam manifest"
done
echo "   D7 set present: Appearance AlertManager StatusBarManager DevSettings LinkingManager"

# ---------------------------------------------------------------------------
echo "== 3. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "${RNI_ENGINE_PKG}" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/ModuleSeamApp"
cp -r "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="moduleseamapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P4Fixture"; a.displayName="P4 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

# ---------------------------------------------------------------------------
echo "== 4. LAYER 1+2+3: the three-layer packaging guard =="
node - "$ROOT" "$WORK/$MAIN_TGZ" "$APP" "$MANIFEST" <<'NODE'
const fs = require('path') && require('fs');
const path = require('path');
const {execFileSync} = require('child_process');
const [root, tgz, app, manifestPath] = process.argv.slice(2);
const fails = [];

// ---- LAYER 1: every file the package's own entry points require must be IN
// the tarball. `files` in package.json is an allowlist and dropping a
// directory from it is invisible until a consumer installs.
const listing = execFileSync('tar', ['tzf', tgz], {encoding: 'utf8'})
  .split('\n').filter(Boolean).map(l => l.replace(/^package\//, ''));
for (const required of [
  'src/index.js', 'src/resolve.js',
  'src/metro-shims/index.js',
  'src/metro-shims/shims/Platform.impeller.js',
  // P4. Dropping this from `files` would leave Alert.js branching itself out
  // of existence again — a silent no-op with no error anywhere.
  'src/metro-shims/shims/Alert.impeller.js',
  'src/cli/index.js',
]) {
  if (!listing.includes(required)) fails.push(`LAYER1: tarball is missing ${required}`);
}
console.log(`   LAYER1 ok — ${listing.length} files in the tarball`);

// ---- LAYER 2: the METHOD guard. The engine's manifest IS the definition of
// the seam, so diff against it — and diff against the PACKED/INSTALLED JS,
// asserting what SHIPS rather than what sits in package/src.
//
// For each module the engine vends, find the RN spec JS the consumer actually
// installed and require every native method to appear in its Spec. A native
// method with no JS declaration is unreachable from an app, which is exactly
// the failure a file-presence check cannot see.
const manifest = fs.readFileSync(manifestPath, 'utf8').split('\n')
  .filter(l => l.startsWith('module='))
  .map(l => {
    const m = l.match(/^module=(\S+) methods=(.*)$/);
    return {name: m[1], methods: m[2] ? m[2].split(',') : []};
  });

// module name -> the RN spec file that declares it, as INSTALLED in the app.
const SPEC_FOR = {
  PlatformConstants:  'src/private/specs_DEPRECATED/modules/NativePlatformConstantsIOS.js',
  SourceCode:         'src/private/specs_DEPRECATED/modules/NativeSourceCode.js',
  ExceptionsManager:  'src/private/specs_DEPRECATED/modules/NativeExceptionsManager.js',
  AppState:           'src/private/specs_DEPRECATED/modules/NativeAppState.js',
  DeviceInfo:         'src/private/specs_DEPRECATED/modules/NativeDeviceInfo.js',
  Appearance:         'src/private/specs_DEPRECATED/modules/NativeAppearance.js',
  AlertManager:       'src/private/specs_DEPRECATED/modules/NativeAlertManager.js',
  StatusBarManager:   'src/private/specs_DEPRECATED/modules/NativeStatusBarManagerIOS.js',
  DevSettings:        'src/private/specs_DEPRECATED/modules/NativeDevSettings.js',
  LinkingManager:     'src/private/specs_DEPRECATED/modules/NativeLinkingManager.js',
};
// Inherited from RN's TurboModule base, not declared per-spec.
const INHERITED = new Set(['addListener', 'removeListeners']);

let checked = 0;
for (const {name, methods} of manifest) {
  const rel = SPEC_FOR[name];
  if (!rel) { fails.push(`LAYER2: no spec mapping for module '${name}' — a new module was added without extending the guard`); continue; }
  const specPath = path.join(app, 'node_modules/react-native', rel);
  if (!fs.existsSync(specPath)) { fails.push(`LAYER2: installed app has no spec at ${rel}`); continue; }
  const spec = fs.readFileSync(specPath, 'utf8');
  for (const m of methods) {
    if (INHERITED.has(m)) continue;
    // Anchor on a declaration shape at the start of a line: a bare substring
    // match would hit comments and other methods' bodies, giving a guard that
    // can never fail.
    //
    // ⚠️ THE `?` IS NOT OPTIONAL IN THIS REGEX. RN declares OPTIONAL spec
    // members as `+onFastRefresh?: () => void`, and an anchor of
    // `^\s*\+?name\s*[(:]` misses them — which reported three perfectly
    // reachable DevSettings methods as unreachable on this gate's first run.
    // A guard's own false POSITIVE is the cheap failure; the same class of
    // error in the other direction is a guard that can never go red.
    const re = new RegExp(`^\\s*\\+?${m}\\??\\s*[(:]`, 'm');
    if (!re.test(spec)) {
      fails.push(`LAYER2: native method ${name}.${m}() is not declared in the SHIPPED spec ${rel} — unreachable from JS`);
    }
    checked++;
  }
}
console.log(`   LAYER2 ok — ${checked} native methods each declared in the installed spec`);

// ---- LAYER 3: the installed copy must be the tarball's copy. A correct
// tarball with a stale node_modules is a green gate over a broken install.
const installedShim = path.join(app, 'node_modules/@react-native-impeller/core/src/metro-shims/index.js');
if (!fs.existsSync(installedShim)) {
  fails.push('LAYER3: react-native-impeller is not installed in the consumer app');
} else {
  const installed = fs.readFileSync(installedShim, 'utf8');
  // The ios-stub redirects are the thing P4 added; if the consumer has an
  // older copy, Alert silently resolves to a self-referencing stub.
  for (const marker of ['Alert/RCTAlertManager.js', 'Network/RCTNetworking.js']) {
    if (!installed.includes(marker)) {
      fails.push(`LAYER3: installed shim is STALE — no redirect for ${marker}`);
    }
  }
  console.log('   LAYER3 ok — installed shim matches this build');
}

if (fails.length) {
  console.error('P4_MODULES_FAIL:\n  ' + fails.join('\n  '));
  process.exit(1);
}
NODE
[ $? -eq 0 ] || fail "the three-layer packaging guard failed"

# ---------------------------------------------------------------------------
echo "== 5. swap in the P4 fixture and bundle --platform impeller =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/fixture.json" "$APP/fixture.json"
npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" || fail "engine resolver failed"
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# ---------------------------------------------------------------------------
echo "== 6. build probe args FROM the fixture =="
mapfile -t ARGS < <(node "$ROOT/tools/fixture-probe-args.js" "$FIXTURE/fixture.json" p4)

echo "== 7. run the engine on the fixture bundle =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P4Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | grep -vE '^rn-impeller: (probe|node_frame)=' | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 8. assert: React actually mounted =="
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 9. assert the seam IN PIXELS =="
node "$ROOT/tools/assert-fixture.js" p4 "$FIXTURE/fixture.json" "$LOG" P4_MODULES_FAIL

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P4_MODULES_PASS (modules=$MODULE_COUNT nodes=$NODES painted=$PAINTED)"
