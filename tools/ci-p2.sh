#!/usr/bin/env bash
# P2 GATE: does a React tree become pixels, through the CONSUMER path?
#
# Same shape as the P1 gate (tarballs into a pristine app outside the repo), but
# it swaps the app's entry point for fixtures/p2-mount and asserts the geometry
# that fixture declares. Reusing the consumer path is deliberate: a renderer that
# only works when run from the repo is not shipped.
#
# The probes come from fixtures/p2-mount/fixture.json, which the fixture ALSO
# renders from — so the gate and the app cannot drift apart. Adding a box to the
# fixture automatically adds its probe here.
#
# --probe-banner off: the P1 packaging banner is NOT drawn, so every pixel in the
# frame came from React. With the banner on, a passing frame would prove nothing
# about the renderer.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p2-mount"

fail() { echo "P2_MOUNT_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (see docs/STATE.md)"
bash tools/engine-build.sh linux x64 > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd packages-engine/engine-linux-x64 && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/FixtureApp"
cp -r "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="fixtureapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P2Fixture"; a.displayName="P2 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P2 fixture as the app entry =="
cp "$FIXTURE/index.js" "$APP/index.js"
cp "$FIXTURE/fixture.json" "$APP/fixture.json"

npx --no-install react-native init-impeller 2>&1 | sed 's/^/   /' || fail "init-impeller failed"
RESOLVED="$(node node_modules/react-native-impeller/src/bin/engine-path.js)" || fail "engine resolver failed"

echo "== 3. bundle --platform impeller =="
npx --no-install react-native bundle --platform impeller --dev false \
    --entry-file index.js --bundle-output impeller/build/index.impeller.bundle \
    2>&1 | tail -3 | sed 's/^/   /'
BUNDLE="$APP/impeller/build/index.impeller.bundle"
[ -s "$BUNDLE" ] || fail "no bundle produced"

echo "== 4. build the probe arguments FROM the fixture =="
mapfile -t ARGS < <(node -e '
const g=require(process.argv[1]);
for (const b of g.boxes) {
  console.log("--probe"); console.log(b.probe.join(","));
  if (b.cornerProbe) { console.log("--probe"); console.log(b.cornerProbe.join(",")); }
}
console.log("--ink-band"); console.log(g.label.inkBand.join(","));
console.log("--width"); console.log(String(g.surface.width));
console.log("--height"); console.log(String(g.surface.height));
' "$FIXTURE/fixture.json")

echo "== 5. run the engine on the fixture bundle (NO packaging banner) =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P2Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 6. assert: React actually mounted =="
# A JS error means the bundle died before rendering. Fabric would then commit an
# empty tree and every colour probe would read background -- so check this FIRST
# and report the real cause instead of "wrong pixels".
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty (scene_nodes=${NODES:-none}) — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0 — the tree never reached the display list"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 7. assert: the pixels are the ones the fixture declares =="
node - "$FIXTURE/fixture.json" "$LOG" <<'NODE'
const fs = require('fs');
const g = require(process.argv[2]);
const log = fs.readFileSync(process.argv[3], 'utf8');

const probes = new Map();
for (const m of log.matchAll(/probe=(\d+),(\d+) rgb=(\d+),(\d+),(\d+)/g)) {
  probes.set(`${m[1]},${m[2]}`, [ +m[3], +m[4], +m[5] ]);
}
const fails = [];
const near = (a, b) => Math.abs(a - b) <= 2;  // llvmpipe rounds by a bit

const check = (label, xy, expect) => {
  const key = xy.join(',');
  const got = probes.get(key);
  if (!got) { fails.push(`${label}: engine never reported probe ${key}`); return; }
  if (!expect.every((e, i) => near(e, got[i]))) {
    fails.push(`${label}: probe ${key} expected rgb=${expect} got rgb=${got}`);
  } else {
    console.log(`   OK ${label} @${key} rgb=${got}`);
  }
};

for (const b of g.boxes) {
  check(`${b.id} fill`, b.probe, b.expect);
  if (b.cornerProbe) check(`${b.id} corner (must be background)`, b.cornerProbe, b.cornerExpect);
}

const ink = log.match(/ink_band=[\d,]+ ink=(\d+) of (\d+)/);
if (!ink) {
  fails.push('label: engine never reported the ink band');
} else {
  const [, got, total] = ink.map(Number);
  // A glyph run this size covers a few percent of the band. The floor only has
  // to separate "text rendered" from "nothing rendered"; a tight range would
  // fail on a legitimate font substitution.
  if (got < 40) fails.push(`label: only ${got}/${total} ink pixels — text did not render`);
  else console.log(`   OK label ink=${got}/${total}`);
}

// LAYOUT, which ink cannot prove. Mutation M4 made the TextLayoutManager return
// 0x0 — the RN platform/cxx stub's exact behaviour — and the ink band still
// passed, because glyphs are painted at the node origin regardless of the size
// Yoga gave the node. So the measured frame is asserted separately.
const frames = [];
for (const m of log.matchAll(/node_frame=([^,]+),(\d+),([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)/g)) {
  frames.push({name: m[1], tag: +m[2], x: +m[3], y: +m[4], w: +m[5], h: +m[6]});
}
const paragraph = frames.find(f => f.name === 'Paragraph');
if (!paragraph) {
  fails.push('label: no Paragraph node in the frame report — <Text> never mounted');
} else {
  const [minW, minH] = g.label.measuredMin;
  const [maxW, maxH] = g.label.measuredMax;
  if (paragraph.w < minW || paragraph.h < minH) {
    fails.push(
      `label: Paragraph measured ${paragraph.w}x${paragraph.h}, below the ` +
      `${minW}x${minH} floor — TextLayoutManager is returning stub sizes`);
  } else if (paragraph.w > maxW || paragraph.h > maxH) {
    fails.push(`label: Paragraph measured ${paragraph.w}x${paragraph.h}, above ${maxW}x${maxH}`);
  } else {
    console.log(`   OK label measured ${paragraph.w}x${paragraph.h}`);
  }
}

// The boxes' frames must match the fixture too, so a layout engine that paints
// the right colours in the right places by luck (e.g. absolute positions
// applied twice) still reddens.
for (const b of g.boxes) {
  const f = frames.find(fr => fr.x === b.x && fr.y === b.y);
  if (!f) {
    fails.push(`${b.id}: no node laid out at ${b.x},${b.y}`);
  } else if (f.w !== b.width || f.h !== b.height) {
    fails.push(`${b.id}: laid out ${f.w}x${f.h}, fixture says ${b.width}x${b.height}`);
  }
}

if (fails.length) {
  console.error('P2_MOUNT_FAIL:\n  ' + fails.join('\n  '));
  process.exit(1);
}
NODE

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P2_MOUNT_PASS (nodes=$NODES painted=$PAINTED)"
