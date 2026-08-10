#!/usr/bin/env bash
# P3 GATE: conformance — do individual PROP FAMILIES render correctly?
#
# P2 asked one question: does a React tree become pixels. It could not tell a
# correct renderer from one that paints every View as a flat, axis-aligned,
# uniformly-bordered rectangle, because a fixture of plain boxes looks identical
# either way. This gate asks the follow-up question for each prop family P2
# either got wrong or skipped:
#
#   per-edge borders   — P2 used the LEFT edge's colour for all four
#   per-corner radii   — P2 collapsed the radii cascade to one `all` value
#   linear gradients   — not implemented, AND blocked by a Metro shim gap
#   transforms         — not implemented
#   text metrics       — numberOfLines was measured but not painted
#
# Every case carries at least one NEGATIVE probe: a pixel that must be
# BACKGROUND. That is what separates "the shape is right" from "something of
# roughly the right colour is in roughly the right place", and it is the class of
# assertion that a screenshot review cannot replace.
#
# Runs through the CONSUMER path (tarballs into a pristine app outside the repo)
# exactly like P1/P2, because a renderer that only works from the repo is not
# shipped.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BASE_APP="${BASE_APP:-$HOME/.cache/rni/base}"
FIXTURE="$ROOT/fixtures/p3-conformance"

fail() { echo "P3_CONFORMANCE_FAIL: $*" >&2; exit 1; }

[ -d "$BASE_APP/node_modules/react-native" ] || fail "no base RN app at $BASE_APP (see docs/STATE.md)"
bash tools/engine-build.sh linux x64 > /dev/null || fail "engine build failed"

WORK="$(mktemp -d)"
KEEP="${KEEP_WORKDIR:-0}"
cleanup() { [ "$KEEP" = "1" ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. pack + install into a pristine app OUTSIDE the repo =="
ENGINE_TGZ="$(cd packages-engine/engine-linux-x64 && npm pack --silent --pack-destination "$WORK")"
MAIN_TGZ="$(cd package && npm pack --silent --pack-destination "$WORK")"
APP="$WORK/ConformanceApp"
cp -r "$BASE_APP" "$APP"
cd "$APP"
node -e '
const fs=require("fs");
const p=JSON.parse(fs.readFileSync("package.json","utf8"));
p.name="conformanceapp";
fs.writeFileSync("package.json", JSON.stringify(p,null,2));
const a=JSON.parse(fs.readFileSync("app.json","utf8"));
a.name="P3Fixture"; a.displayName="P3 Fixture";
fs.writeFileSync("app.json", JSON.stringify(a,null,2));
'
npm install --no-audit --no-fund --silent "$WORK/$ENGINE_TGZ" "$WORK/$MAIN_TGZ" \
  || fail "npm install of the tarballs failed"

echo "== 2. swap in the P3 fixture as the app entry =="
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
const g = require(process.argv[1]);
const p = xy => { console.log("--probe"); console.log(xy.join(",")); };
for (const side of ["top","right","bottom","left"]) p(g.edges[side].probe);
p(g.edges.centerProbe);
for (const c of ["cornerTL","cornerTR","cornerBL","cornerBR"]) p(g.corners[c].probe);
p(g.corners.centerProbe);
p(g.gradient.probeTop); p(g.gradient.probeMiddle); p(g.gradient.probeBottom);
p(g.transform.centerProbe); p(g.transform.cornerProbe);
console.log("--ink-band"); console.log(g.text.wrapped.inkBand.join(","));
console.log("--ink-band"); console.log(g.text.clamped.inkBand.join(","));
console.log("--width"); console.log(String(g.surface.width));
console.log("--height"); console.log(String(g.surface.height));
' "$FIXTURE/fixture.json")

echo "== 5. run the engine on the fixture bundle (NO packaging banner) =="
LOG="$WORK/engine.log"
set +e
"$RESOLVED" --headless --probe-banner off \
            --bundle "$BUNDLE" --app-name P3Fixture \
            --screenshot "$WORK/frame.ppm" \
            "${ARGS[@]}" > "$LOG" 2>&1
RC=$?
set -e
grep -vE '^W[0-9]{8} ' "$LOG" | grep -vE '^rn-impeller: (probe|node_frame)=' | sed 's/^/   /'
[ "$RC" -eq 0 ] || fail "engine exited $RC"

echo "== 6. assert: React actually mounted =="
if grep -q '\[js-exception\] (fatal' "$LOG"; then
  fail "the bundle threw a fatal JS exception (see log above)"
fi
NODES="$(grep -oE 'scene_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ -n "$NODES" ] && [ "$NODES" -gt 0 ] || fail "scene graph is empty — Fabric never mounted"
PAINTED="$(grep -oE 'painted_nodes=[0-9]+' "$LOG" | cut -d= -f2)"
[ "${PAINTED:-0}" -gt 0 ] || fail "scene graph has $NODES nodes but painted 0"
echo "   scene_nodes=$NODES painted_nodes=$PAINTED"

echo "== 7. assert conformance =="
node - "$FIXTURE/fixture.json" "$LOG" <<'NODE'
const fs = require('fs');
const g = require(process.argv[2]);
const log = fs.readFileSync(process.argv[3], 'utf8');

const probes = new Map();
for (const m of log.matchAll(/probe=(\d+),(\d+) rgb=(\d+),(\d+),(\d+)/g)) {
  probes.set(`${m[1]},${m[2]}`, [+m[3], +m[4], +m[5]]);
}
const fails = [];
const near = (a, b, tol = 3) => Math.abs(a - b) <= tol;

function get(label, xy) {
  const got = probes.get(xy.join(','));
  if (!got) { fails.push(`${label}: engine never reported probe ${xy.join(',')}`); return null; }
  return got;
}
function check(label, xy, expect, tol) {
  const got = get(label, xy);
  if (!got) return;
  if (!expect.every((e, i) => near(e, got[i], tol))) {
    fails.push(`${label}: probe ${xy.join(',')} expected rgb=${expect} got rgb=${got}`);
  } else {
    console.log(`   OK ${label} @${xy.join(',')} rgb=${got}`);
  }
}

// --- per-edge borders -------------------------------------------------------
// Four different colours. A renderer that resolves the cascade and reuses one
// edge fails exactly THREE of these and passes one — a signature that says
// "wrong edge" rather than "no borders", which a uniform-colour fixture cannot.
for (const side of ['top', 'right', 'bottom', 'left']) {
  check(`border ${side}`, g.edges[side].probe, g.edges[side].expect);
}
// ...and the middle must stay empty, so a renderer that FILLS the box with the
// border colour cannot pass the four edge probes by flooding.
check('border centre (must be background)', g.edges.centerProbe, g.edges.centerExpect);

// --- per-corner radii -------------------------------------------------------
check('radius TL rounded (must be background)', g.corners.cornerTL.probe, g.corners.cornerTL.expect);
for (const c of ['cornerTR', 'cornerBL', 'cornerBR']) {
  check(`radius ${c} square (must be fill)`, g.corners[c].probe, g.corners[c].expect);
}
check('radius centre', g.corners.centerProbe, g.corners.centerExpect);

// --- linear gradient --------------------------------------------------------
// Asserted as a DIRECTION, not as three exact colours: interpolation bytes are
// a renderer detail, monotonic red-down/blue-up is the contract. A flat fill —
// which is what you get when the prop is dropped somewhere in the chain — has
// zero slope and fails here while looking like "a coloured box" in a screenshot.
{
  const top = get('gradient top', g.gradient.probeTop);
  const mid = get('gradient middle', g.gradient.probeMiddle);
  const bot = get('gradient bottom', g.gradient.probeBottom);
  if (top && mid && bot) {
    const redFalls = top[0] > mid[0] && mid[0] > bot[0];
    const blueRises = top[2] < mid[2] && mid[2] < bot[2];
    if (!redFalls || !blueRises) {
      fails.push(
        `gradient: not monotonic top->bottom (red ${top[0]}->${mid[0]}->${bot[0]}, ` +
        `blue ${top[2]}->${mid[2]}->${bot[2]}) — a flat fill or a wrong axis`);
    } else if (top[0] - bot[0] < 100) {
      fails.push(`gradient: red only falls ${top[0] - bot[0]} over the whole box — barely a gradient`);
    } else if (top[0] < g.gradient.topMinRed || bot[2] < g.gradient.bottomMinBlue) {
      // Monotonicity alone is not enough. A gradient whose endpoints were left
      // in node-local coordinates is SHIFTED but still monotonic — mutant M4
      // proved it passed the direction check. These bounds pin WHERE the
      // gradient starts and ends, not just which way it runs.
      fails.push(
        `gradient: endpoints are off — top red ${top[0]} (need >=${g.gradient.topMinRed}), ` +
        `bottom blue ${bot[2]} (need >=${g.gradient.bottomMinBlue}). The ramp runs the ` +
        `right way but is not anchored to the node's box.`);
    } else {
      console.log(`   OK gradient red ${top[0]}->${mid[0]}->${bot[0]}, blue ${top[2]}->${mid[2]}->${bot[2]}`);
    }
  }
}

// --- transform --------------------------------------------------------------
// The corner probe is the whole test. It sits inside the UNROTATED bounds, so a
// renderer that ignores `transform` paints an axis-aligned square, keeps the
// centre probe correct, and is caught here and nowhere else.
check('transform centre', g.transform.centerProbe, g.transform.centerExpect);
check('transform corner (outside the rotated box)', g.transform.cornerProbe, g.transform.cornerExpect);

// --- text metrics -----------------------------------------------------------
const frames = [];
for (const m of log.matchAll(/node_frame=([^,]+),(\d+),([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)/g)) {
  frames.push({name: m[1], tag: +m[2], x: +m[3], y: +m[4], w: +m[5], h: +m[6]});
}
const paragraphs = frames.filter(f => f.name === 'Paragraph');
if (paragraphs.length !== 2) {
  fails.push(`text: expected 2 Paragraph nodes, frame report has ${paragraphs.length}`);
} else {
  // Identify by y position rather than by mount order, which is not contractual.
  const sorted = paragraphs.slice().sort((a, b) => a.y - b.y);
  const [wrapped, clamped] = sorted;
  const {minLineHeight, maxLineHeight, minWrappedLines, boxWidth} = g.text;

  if (clamped.h < minLineHeight || clamped.h > maxLineHeight) {
    fails.push(`text: clamped Paragraph is ${clamped.h}px tall, outside one line (${minLineHeight}..${maxLineHeight})`);
  } else {
    console.log(`   OK clamped Paragraph ${clamped.w}x${clamped.h} (one line)`);
  }
  // numberOfLines being IGNORED is the classic silent failure, and it makes the
  // two heights equal. Requiring a real multiple catches it.
  if (wrapped.h < clamped.h * minWrappedLines) {
    fails.push(
      `text: wrapped Paragraph is ${wrapped.h}px vs clamped ${clamped.h}px — ` +
      `expected at least ${minWrappedLines} lines. Either the text did not wrap ` +
      `at ${boxWidth}px, or numberOfLines was ignored and BOTH wrapped.`);
  } else {
    console.log(`   OK wrapped Paragraph ${wrapped.w}x${wrapped.h} (>= ${minWrappedLines} lines)`);
  }
  // The wrapped node must actually be constrained by its container: a
  // TextLayoutManager that ignores the width constraint reports one long line
  // that is WIDER than the box, and then the height check above passes for the
  // wrong reason.
  if (wrapped.w > boxWidth + 1) {
    fails.push(`text: wrapped Paragraph measured ${wrapped.w}px wide in a ${boxWidth}px box — width constraint ignored`);
  }
}

// Ink for both bands: equal-and-correct measurements are also what you get when
// neither paints, so measurement and paint are asserted separately.
const inks = [...log.matchAll(/ink_band=(\d+),(\d+),\d+,\d+ ink=(\d+) of (\d+)/g)]
  .map(m => ({x: +m[1], y: +m[2], ink: +m[3], total: +m[4]}));
for (const [name, band] of [['wrapped', g.text.wrapped], ['clamped', g.text.clamped]]) {
  const found = inks.find(i => i.x === band.inkBand[0] && i.y === band.inkBand[1]);
  if (!found) fails.push(`text ${name}: engine never reported the ink band`);
  else if (found.ink < 40) fails.push(`text ${name}: only ${found.ink}/${found.total} ink pixels — text did not render`);
  else console.log(`   OK text ${name} ink=${found.ink}/${found.total}`);
}

// A uniform frame must never pass by luck. The fixture contains a gradient and
// an anti-aliased rotated edge, so a correct frame has hundreds of colours.
const distinct = log.match(/distinct_colors=(\d+)/);
if (!distinct) fails.push('engine never reported distinct_colors');
else if (+distinct[1] < 50) fails.push(`only ${distinct[1]} distinct colours — the frame is close to uniform`);
else console.log(`   OK distinct_colors=${distinct[1]}`);

if (fails.length) {
  console.error('P3_CONFORMANCE_FAIL:\n  ' + fails.join('\n  '));
  process.exit(1);
}
NODE

if [ -n "${SCREENSHOT_OUT:-}" ]; then cp "$WORK/frame.ppm" "$SCREENSHOT_OUT"; echo "   screenshot -> $SCREENSHOT_OUT"; fi
echo "P3_CONFORMANCE_PASS (nodes=$NODES painted=$PAINTED)"
