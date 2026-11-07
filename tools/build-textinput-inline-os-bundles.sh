#!/usr/bin/env bash
# Build the ENG-01d TextInput bundles (fixtures/textinput-inline-os/prebuilt/).
#
# The fixture is a consumer app's probe screen in a copy of that app's Metro
# shape: Expo 57.0.27, RN 0.86.3, NativeWind 5.0.0-rc.0, and
# withNativewind(withImpeller(getDefaultConfig())). react-native-impeller-platform
# is packed from CORE_DIR (default: this tree's package/), so the bundles carry
# the shims this checkout ships. All bundles are --dev false, the mode where
# babel-preset-expo inlines Platform.OS.
#
#   tiios-fix.bundle        entry.tsx, the real config               (must mount)
#   tiios-fix-nocss.bundle  entry-nocss.tsx, no NativeWind           (must mount)
#   tiios-noimp.bundle      entry-nocss.tsx, no withImpeller at all  (must NOT)
#   tiios-prefix.bundle     entry.tsx, withImpeller minus the ENG-01d
#                           babel-transformer wrapper (the shim as it was
#                           before the fix; control arm)             (must NOT)
#
# Static checks run here too, because they need node: the renamed Platform
# binding must land in the TextInput folder only (tools/textinput-inline-os-
# scope.js), never in the control bundle, and a Metro cache warmed by the
# pre-fix shim must not hide the fix.
#
# Usage: build-textinput-inline-os-bundles.sh [OUT_DIR]
#   CORE_DIR=<dir>   package to pack (mutation-verify passes a mutated copy)
#   TIIOS_APP=<dir>  reuse an app this script installed before: only core's
#                    src/ is re-synced from CORE_DIR (saves the npm install)
# Prints TIIOS_BUILD_PASS, or TIIOS_BUILD_FAIL / TIIOS_SCOPE_FAIL and exits 1.
#
# Bundles are written OUTSIDE the app dir on purpose: Tailwind v4 scans the
# project for class names, and a bundle left in the app dir broke the next
# global.css compile ("failed to deserialize; expected ... Specifier").
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/fixtures/textinput-inline-os"
OUT="${1:-$FIX/prebuilt}"
CORE_DIR="${CORE_DIR:-$ROOT/package}"
fail() { echo "TIIOS_BUILD_FAIL: $*"; exit 1; }
command -v node >/dev/null || fail "no node on PATH"
command -v npm >/dev/null || fail "no npm on PATH"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if [ -n "${TIIOS_APP:-}" ] && [ -d "$TIIOS_APP/node_modules/react-native-impeller-platform" ]; then
  APP="$TIIOS_APP"
  rm -rf "$APP/node_modules/react-native-impeller-platform/src"
  cp -R "$CORE_DIR/src" "$APP/node_modules/react-native-impeller-platform/src"
  # fixture sources may have changed since the install (package.json stays)
  cp "$FIX"/{metro.config.js,babel.config.js,postcss.config.mjs,app.json,global.css,.watchmanconfig} "$APP/"
  cp "$FIX"/{probe.tsx,os-check.ts,entry.tsx,entry-nocss.tsx} "$APP/"
else
  APP="${TIIOS_APP:-$WORK/app}"
  mkdir -p "$APP" "$WORK/pack"
  TGZ="$(cd "$CORE_DIR" && npm pack --silent --pack-destination "$WORK/pack")"
  # core's optionalDependencies are the engine packages, which are not on npm.
  # Strip them and repack, so the install can keep optional deps ON: Tailwind's
  # oxide and lightningcss ship their native binaries as optional deps.
  tar -xzf "$WORK/pack/$TGZ" -C "$WORK/pack"
  node -e '
const fs = require("fs"); const f = process.argv[1];
const p = JSON.parse(fs.readFileSync(f, "utf8")); delete p.optionalDependencies;
fs.writeFileSync(f, JSON.stringify(p, null, 2));' "$WORK/pack/package/package.json"
  TGZ2="$(cd "$WORK/pack/package" && npm pack --silent --pack-destination "$WORK")"
  cp "$FIX"/{package.json,metro.config.js,babel.config.js,postcss.config.mjs,app.json,global.css,.watchmanconfig} "$APP/"
  cp "$FIX"/{probe.tsx,os-check.ts,entry.tsx,entry-nocss.tsx} "$APP/"
  # Keep the tarball beside the app: a reused app (TIIOS_APP) must not point
  # at a file that died with WORK.
  cp "$WORK/$TGZ2" "$APP/core.tgz"
  (cd "$APP" && node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
p.dependencies["react-native-impeller-platform"] = "file:./core.tgz";
fs.writeFileSync("package.json", JSON.stringify(p, null, 2));')
  (cd "$APP" && npm install --no-audit --no-fund > "$WORK/npm.log" 2>&1) \
    || { tail -20 "$WORK/npm.log"; fail "npm install"; }
fi
cd "$APP"
echo "expo=$(node -p 'require("./node_modules/expo/package.json").version') rn=$(node -p 'require("./node_modules/react-native/package.json").version') nativewind=$(node -p 'require("./node_modules/nativewind/package.json").version')"

mkdir -p "$OUT" "$WORK/b"
# bundle <name> <entry> <minify> <reset:yes|no> <cache-dir> [ENV=val...]
bundle() {
  local name="$1" entry="$2" minify="$3" reset="$4" cache="$5"; shift 5
  local resetflag=(); [ "$reset" = yes ] && resetflag=(--reset-cache)
  mkdir -p "$cache"
  env TMPDIR="$cache" "$@" npx --no-install react-native bundle --platform impeller --dev false \
      --minify "$minify" --entry-file "$entry" ${resetflag[@]+"${resetflag[@]}"} \
      --bundle-output "$WORK/b/$name.bundle" --sourcemap-output "$WORK/b/$name.map" \
      > "$WORK/$name.log" 2>&1 \
    || { grep -iE 'error|unable|cannot' "$WORK/$name.log" | head -8; fail "metro could not bundle $name"; }
}

# Committed (minified) bundles, each from a cold cache.
bundle tiios-fix          entry.tsx       true yes "$WORK/c1"
bundle tiios-fix-nocss    entry-nocss.tsx true yes "$WORK/c2" RNI_NO_NW=1
bundle tiios-noimp        entry-nocss.tsx true yes "$WORK/c3" RNI_NO_NW=1 RNI_NO_IMPELLER=1
bundle tiios-prefix       entry.tsx       true yes "$WORK/c4" RNI_NO_TRANSFORMER=1

# Scope checks need readable names: unminified twins.
bundle scope-fix          entry.tsx       false yes "$WORK/c5"
bundle scope-prefix       entry.tsx       false yes "$WORK/c6" RNI_NO_TRANSFORMER=1
# Warm cache: the pre-fix shim fills the cache, then the fixed config bundles
# against that SAME cache without --reset-cache. Stale transforms would show
# up as a missing rename. (An app updating core keeps its Metro cache.)
bundle warm-prefix        entry.tsx       false yes "$WORK/c7" RNI_NO_TRANSFORMER=1
bundle warm-fix           entry.tsx       false no  "$WORK/c7"

S="$ROOT/tools/textinput-inline-os-scope.js"
SCOPE_OK=1
echo "== scope: fixed config =="
node "$S" "$WORK/b/scope-fix.bundle" "$WORK/b/scope-fix.map" | sed 's/TIIOS_SCOPE_FAIL/TIIOS_SCOPE_FAIL(fix)/' | tee "$WORK/s1" || true
grep -q TIIOS_SCOPE_PASS "$WORK/s1" || SCOPE_OK=0
echo "== scope: control (resolver-only shim) must carry no rename =="
node "$S" "$WORK/b/scope-prefix.bundle" "$WORK/b/scope-prefix.map" --expect-none | tee "$WORK/s2" || true
grep -q TIIOS_SCOPE_PASS "$WORK/s2" || SCOPE_OK=0
echo "== scope: fixed config over a cache warmed by the pre-fix shim =="
node "$S" "$WORK/b/warm-fix.bundle" "$WORK/b/warm-fix.map" | sed 's/TIIOS_SCOPE_FAIL/TIIOS_SCOPE_FAIL(warm-cache)/' | tee "$WORK/s3" || true
grep -q TIIOS_SCOPE_PASS "$WORK/s3" || SCOPE_OK=0

for n in tiios-fix tiios-fix-nocss tiios-noimp tiios-prefix; do
  cp "$WORK/b/$n.bundle" "$OUT/$n.bundle"
  echo "wrote $OUT/$n.bundle ($(wc -c < "$OUT/$n.bundle") bytes)"
done
if [ "$SCOPE_OK" != 1 ]; then
  echo "TIIOS_SCOPE_FAILED (see TIIOS_SCOPE_FAIL lines above)"
  # mutation-verify wants the bundles anyway, to run the gate on them too
  [ "${TIIOS_SCOPE_SOFT:-0}" = 1 ] && exit 0
  exit 1
fi
echo "TIIOS_BUILD_PASS"
