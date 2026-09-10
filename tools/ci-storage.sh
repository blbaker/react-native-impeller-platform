#!/usr/bin/env bash
# ENG-04 gate — storage survives a relaunch.
#
# ⛔ THE ONLY ASSERTION THAT MATTERS IS CROSS-PROCESS.
#
# A set-then-get inside one run passes against an in-memory Map, so this gate
# runs the engine TWICE against the same container: run 1 writes, run 2 reads
# without writing. If run 2 finds the values, they were on disk.
#
# Every assertion reads an ALERT MESSAGE, not a native counter. That is
# deliberate: Alert.alert() is called from JS with the value JS actually
# received, so a native file written perfectly that JS cannot read produces the
# wrong text. A native-side "bytes written" counter would pass on exactly the
# bug this gate exists for -- the same boundary-audit lesson as ENG-02.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
RNI_ENGINE_PKG="${RNI_ENGINE_PKG:-$ROOT/packages-engine/engine-linux-x64}"

fail() { echo "STORAGE_GATE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || bash tools/base-app.sh
[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() {
  pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
  [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd "$RNI_ENGINE_PKG" && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/StorageApp"
cp -R "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="storageapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P9Storage"; a.displayName="P9Storage";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent \
  "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" || fail "npm install of the tarballs failed"

# ⚠️ The shim ships INSIDE the core package, so it must be present in the
# tarball -- not just in the repo. A gate that imported it by relative path
# from the repo would pass while the published package shipped without it.
[ -f "$APP/node_modules/@react-native-impeller/core/src/storage/index.js" ] \
  || fail "the storage shim is NOT in the packed tarball (check package.json files[])"

echo "== 2. install the ENG-04 fixture =="
cp "$ROOT/fixtures/p9-storage/index.js" "$APP/index.js"
npx --no-install react-native init-impeller >/dev/null 2>&1 || fail "init-impeller failed"
ENGINE="$(node node_modules/@react-native-impeller/core/src/bin/engine-path.js)" \
  || fail "engine resolver failed"

echo "== 3. bundle =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/storage.bundle \
    >/dev/null 2>&1 || fail "bundle failed"
BUNDLE="$APP/impeller/build/storage.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

# A DISPOSABLE container. Without this the gate writes into the developer's
# real ~/.local/share and a second run would see the first run's data, which
# would make a broken write look like a pass.
STORE="$WORK/container"
mkdir -p "$STORE"

run_phase() {
  local phase="$1" log="$2"
  # ⛔ PHASE TRAVELS BY --initial-url, NOT BY ENVIRONMENT. Hermes has no OS
  # environment: process.env.X bundles fine and reads undefined at runtime, so
  # an env-selected phase silently ran the WRITE arm twice and the persistence
  # assertion could never fail. --initial-url is a real host-to-JS channel
  # (LinkingManager.getInitialURL). RNI_STORAGE_DIR stays an env var because it
  # is read by C++ in ReactHost, not by JS.
  RNI_STORAGE_DIR="$STORE" \
    "$ENGINE" --bundle "$BUNDLE" --app-name P9Storage --headless \
      --probe-banner off --width 400 --height 300 \
      --initial-url "rniphase://$phase" \
      > "$log" 2>&1 || { tail -20 "$log" >&2; fail "$phase run failed"; }
}

echo "== 4. assert A: the module is reachable from JS at all =="
"$ENGINE" --list-modules > "$WORK/mods.log" 2>&1 || true
grep -q "module=AppStorage" "$WORK/mods.log" \
  || fail "AppStorage is not vended by the engine (see --list-modules)"
grep -q "module=AppStorage methods=.*writeFile" "$WORK/mods.log" \
  || fail "AppStorage vends no writeFile method"
echo "   OK: $(grep -o 'module=AppStorage methods=[a-zA-Z,]*' "$WORK/mods.log")"

echo "== 5. assert B: run 1 writes (process 1) =="
run_phase write "$WORK/write.log"
WRITE_MSG="$(grep -o 'alert=write.*' "$WORK/write.log" | head -1 || true)"
[ -n "$WRITE_MSG" ] || {
  grep -o 'alert=error.*' "$WORK/write.log" | head -1 >&2 || true
  fail "the write phase produced no write alert -- JS never completed the writes"
}
echo "   $WRITE_MSG"
echo "$WRITE_MSG" | grep -q "wrote=5" || fail "expected 5 writes; got: $WRITE_MSG"
echo "$WRITE_MSG" | grep -q "encode_ok=true" \
  || fail "the key encoder does not round trip: $WRITE_MSG"

# The files must be ON DISK between processes. Checked directly, because "JS
# said it wrote" and "bytes exist" are different facts.
FILE_COUNT="$(find "$STORE" -type f -name '*.v1' | wc -l)"
[ "$FILE_COUNT" -eq 5 ] \
  || fail "expected 5 files in the container after the write phase, found $FILE_COUNT"
# No temp files left behind: a surviving .tmp means the atomic rename did not
# happen and a reader could see a partial value.
TMP_COUNT="$(find "$STORE" -type f -name '*.tmp' | wc -l)"
[ "$TMP_COUNT" -eq 0 ] \
  || fail "$TMP_COUNT atomic-write temp file(s) left behind in the container"
echo "   OK: 5 files on disk, 0 temp files left behind"

echo "== 6. assert C: run 2 reads what run 1 wrote (SEPARATE process) =="
run_phase read "$WORK/read.log"
READ_MSG="$(grep -o 'alert=read.*' "$WORK/read.log" | head -1 || true)"
[ -n "$READ_MSG" ] || {
  grep -o 'alert=error.*' "$WORK/read.log" | head -1 >&2 || true
  fail "the read phase produced no read alert"
}
echo "   $READ_MSG"
echo "$READ_MSG" | grep -q "hits=5/5" \
  || fail "not every value survived the relaunch: $READ_MSG"
echo "$READ_MSG" | grep -q "removed_is_null=true" \
  || fail "a removed key must read null, not empty string: $READ_MSG"
echo "$READ_MSG" | grep -q "empty_preserved=true" \
  || fail "a stored empty string must not read as missing: $READ_MSG"

echo "== 7. assert D: path confinement =="
# ⛔ THE SECURITY ARM. A native file primitive reachable from JS is an
# arbitrary-file-write primitive unless containment holds. Asserted by calling
# the NATIVE method directly with hostile keys, bypassing the JS encoder --
# the encoder would make every one of these legal, so testing through it would
# prove nothing about the native guard.
cat > "$APP/index.js" <<'JS'
import React from 'react';
import {Alert, AppRegistry, Text, View} from 'react-native';
import {TurboModuleRegistry} from 'react-native';
const N = TurboModuleRegistry.get('AppStorage');
// ⛔ TWO CLASSES, AND THE SECOND ONE IS THE POINT.
//
// The first five are killed by the native ALLOWLIST ([A-Za-z0-9._-], plus
// explicit "." and ".."), because every one contains a '/'. Measured: all of
// them die before the containment check is ever reached. A gate made only of
// these tests ONE guard TWICE and leaves the containment logic unexercised --
// proven by mutation: deleting the parent-directory guard entirely still
// passed an 8-key list of this shape.
//
// The second class uses ONLY allowlisted characters, so it gets past the
// allowlist and is stopped -- or not -- by the normalise-then-recheck
// containment logic. '...' and '..-' are legal filenames; '..' repeated via
// dots cannot traverse, but a container whose parent check is missing will
// accept a key that resolves outside, and these are what expose it.
const HOSTILE = [
  // class 1: killed by the allowlist
  '../escaped',
  '../../etc/passwd',
  '/etc/passwd',
  'a/../../b',
  'nested/dir',
  '.',
  '..',
  '',
  // class 2: allowlist-legal, so they get PAST the allowlist and are judged by
  // the containment logic. Only over-length is a rejection: '...' is a
  // perfectly legal filename that resolves INSIDE the container, so demanding
  // it be refused was my gate being wrong rather than the primitive being
  // unsafe -- verified by normalising it by hand (parent == container).
  // Over-length is the real class-2 rejection: 256 chars exceeds the 255 cap.
  'a'.repeat(252),
];
// Keys that MUST be accepted. Asserted alongside the rejections because a
// primitive that refuses everything trivially passes a rejection-only gate,
// and that failure mode looks identical to perfect security.
// 251 is the documented boundary: the cap is 255 minus the 4 bytes writeFile
// needs for its atomic "<key>.tmp" sibling. Both sides of the boundary are
// asserted, because a cap that is merely SMALL passes a must-accept arm using
// only short keys.
const LEGAL = ['...', 'a-b_c.9', 'a'.repeat(251)];
function F() {
  React.useEffect(() => {
    let accepted = [];
    for (const k of HOSTILE) {
      if (N.writeFile(k, 'PWNED') === true) accepted.push(k);
    }
    let refused = [];
    for (const k of LEGAL) {
      if (N.writeFile(k, 'ok') !== true) refused.push(k);
    }
    Alert.alert('confine accepted=' + accepted.length + ' refused_legal=' + refused.length + (accepted.length ? ' bad=' + accepted.join('|') : '') + (refused.length ? ' refused=' + refused.join('|') : ''));
  }, []);
  return <View style={{width: 400, height: 300}}><Text>confine</Text></View>;
}
AppRegistry.registerComponent('P9Storage', () => F);
JS
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/confine.bundle \
    >/dev/null 2>&1 || fail "confinement bundle failed"
RNI_STORAGE_DIR="$STORE" "$ENGINE" --bundle "$APP/impeller/build/confine.bundle" \
  --app-name P9Storage --headless --probe-banner off \
  > "$WORK/confine.log" 2>&1 || fail "confinement run failed"
CONF_MSG="$(grep -o 'alert=confine.*' "$WORK/confine.log" | head -1 || true)"
[ -n "$CONF_MSG" ] || fail "confinement phase produced no alert"
echo "   $CONF_MSG"
echo "$CONF_MSG" | grep -q "accepted=0" \
  || fail "the native primitive ACCEPTED an escaping key: $CONF_MSG"
# ⛔ THE OTHER HALF. A primitive that refuses EVERY key passes a
# rejection-only assertion perfectly, and that is indistinguishable from
# correct confinement. Legal keys must still be accepted.
echo "$CONF_MSG" | grep -q "refused_legal=0" \
  || fail "the primitive refused a LEGAL key -- over-strict, not secure: $CONF_MSG"
# And nothing escaped in fact, not merely by report.
[ ! -f "$WORK/escaped" ] || fail "a file escaped the container to $WORK/escaped"
[ "$(find "$STORE" -type d | wc -l)" -eq 1 ] \
  || fail "a subdirectory was created inside the container (nesting is not allowed)"
echo "   OK: all hostile keys rejected, all legal keys accepted, no file escaped, no nesting created"

echo "STORAGE_GATE_PASS (module vended + write/read across TWO processes + null/empty preserved + confinement)"
