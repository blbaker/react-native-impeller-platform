#!/usr/bin/env node
// Assert an engine log against a fixture. ONE implementation, every host.
//
// ⛔ THIS FILE EXISTS BECAUSE THE WINDOWS GATE HAD ITS OWN COPY OF THE P2
// ASSERTIONS. ci-win.sh's header said the assertions must come from the same
// fixture the Linux gate uses "or it would be asserting the port against a
// snapshot of itself" — and then hand-copied 60 lines of assertion code, which
// had already drifted (the frame parser had dropped a field, the comments
// described different measurements). The FIXTURE was shared; the CODE READING
// it was not, so a tightened Linux assertion would silently never reach Windows.
//
// ⛔ THERE IS DELIBERATELY NO `--host` BRANCH IN ANY ASSERTION BELOW.
// A per-host expectation is a per-host BUG WAIVER, and the moment one exists,
// "Windows passes" stops meaning "Windows is correct". Where the platforms
// legitimately differ — Windows measured the P2 label at 140x37 against Linux's
// 140x31, a real CoreText/DirectWrite-vs-FreeType line-metric delta — the range
// lives in the FIXTURE and both hosts are held to the same declared range.
//
// Usage: node assert-fixture.js <p2|p3|p4> <fixture.json> <engine.log> <FAIL_TAG>
'use strict';
const fs = require('fs');
const path = require('path');

const [phase, fixturePath, logPath, failTag] = process.argv.slice(2);
if (!phase || !fixturePath || !logPath || !failTag) {
  console.error('usage: assert-fixture.js <p2|p3|p4> <fixture.json> <engine.log> <FAIL_TAG>');
  process.exit(2);
}
const g = require(path.resolve(fixturePath));
const log = fs.readFileSync(logPath, 'utf8');
const fails = [];

// ---------------------------------------------------------------------------
// Shared readers over the engine's log format.
// ---------------------------------------------------------------------------
const probes = new Map();
for (const m of log.matchAll(/probe=(\d+),(\d+) rgb=(\d+),(\d+),(\d+)/g)) {
  probes.set(`${m[1]},${m[2]}`, [+m[3], +m[4], +m[5]]);
}
const frames = [];
for (const m of log.matchAll(/node_frame=([^,]+),(\d+),([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)/g)) {
  frames.push({name: m[1], tag: +m[2], x: +m[3], y: +m[4], w: +m[5], h: +m[6]});
}
const inkBands = [...log.matchAll(/ink_band=(\d+),(\d+),\d+,\d+ ink=(\d+) of (\d+)/g)]
  .map(m => ({x: +m[1], y: +m[2], ink: +m[3], total: +m[4]}));

// A different rasteriser on each host, so a tolerance — but the SAME tolerance
// on both. Widening it "because Windows" is how a real colour regression gets
// waved through; solid fills are solid on every backend, and the Windows P2 run
// measured all four probes EXACT.
const near = (a, b, tol) => Math.abs(a - b) <= tol;

function get(label, xy) {
  const got = probes.get(xy.join(','));
  if (!got) { fails.push(`${label}: engine never reported probe ${xy.join(',')}`); return null; }
  return got;
}
function check(label, xy, expect, tol, why) {
  const got = get(label, xy);
  if (!got) return;
  if (!expect.every((e, i) => near(e, got[i], tol))) {
    fails.push(`${label}: probe ${xy.join(',')} expected rgb=${expect} got rgb=${got}` +
               (why ? ` — ${why}` : ''));
  } else {
    console.log(`   OK ${label} @${xy.join(',')} rgb=${got}`);
  }
}
// Ink separates "text rendered" from "nothing rendered". The floor is loose on
// purpose: a tight range would redden on a legitimate font substitution, which
// is guaranteed the moment a second host runs this.
function checkInk(label, band) {
  const found = inkBands.find(i => i.x === band[0] && i.y === band[1]);
  if (!found) fails.push(`${label}: engine never reported the ink band`);
  else if (found.ink < 40) fails.push(`${label}: only ${found.ink}/${found.total} ink pixels — text did not render`);
  else console.log(`   OK ${label} ink=${found.ink}/${found.total}`);
}

// ---------------------------------------------------------------------------
const PHASES = {
  // P2: does a React tree become the pixels the fixture declares?
  p2() {
    const TOL = 2;
    for (const b of g.boxes) {
      check(`${b.id} fill`, b.probe, b.expect, TOL);
      if (b.cornerProbe) check(`${b.id} corner (must be background)`, b.cornerProbe, b.cornerExpect, TOL);
    }
    checkInk('label', g.label.inkBand);

    // LAYOUT, which ink cannot prove. Mutation M4 made TextLayoutManager return
    // 0x0 — the RN platform/cxx stub's exact behaviour — and the ink band still
    // passed, because glyphs paint at the node origin regardless of the size
    // Yoga gave the node.
    const p = frames.find(f => f.name === 'Paragraph');
    if (!p) fails.push('label: no Paragraph node in the frame report — <Text> never mounted');
    else {
      const [minW, minH] = g.label.measuredMin, [maxW, maxH] = g.label.measuredMax;
      if (p.w < minW || p.h < minH) {
        fails.push(`label: Paragraph measured ${p.w}x${p.h}, below the ${minW}x${minH} floor — TextLayoutManager is returning stub sizes`);
      } else if (p.w > maxW || p.h > maxH) {
        fails.push(`label: Paragraph measured ${p.w}x${p.h}, above ${maxW}x${maxH}`);
      } else {
        console.log(`   OK label measured ${p.w}x${p.h}`);
      }
    }
    // Boxes' frames too, so a layout engine that paints the right colours in the
    // right places by luck (absolute positions applied twice) still reddens.
    for (const b of g.boxes) {
      const f = frames.find(fr => fr.x === b.x && fr.y === b.y);
      if (!f) fails.push(`${b.id}: no node laid out at ${b.x},${b.y}`);
      else if (f.w !== b.width || f.h !== b.height) {
        fails.push(`${b.id}: laid out ${f.w}x${f.h}, fixture says ${b.width}x${b.height}`);
      }
    }
  },

  // P3: do individual PROP FAMILIES render correctly, not just at all?
  p3() {
    const TOL = 3;
    // --- per-edge borders. Four different colours: a renderer that resolves the
    // cascade and reuses one edge fails exactly THREE and passes one — a
    // signature saying "wrong edge" rather than "no borders".
    for (const side of ['top', 'right', 'bottom', 'left']) {
      check(`border ${side}`, g.edges[side].probe, g.edges[side].expect, TOL);
    }
    // ...and the middle must stay empty, so a renderer that FILLS the box with
    // the border colour cannot pass the four edge probes by flooding.
    check('border centre (must be background)', g.edges.centerProbe, g.edges.centerExpect, TOL);

    // --- per-corner radii
    check('radius TL rounded (must be background)', g.corners.cornerTL.probe, g.corners.cornerTL.expect, TOL);
    for (const c of ['cornerTR', 'cornerBL', 'cornerBR']) {
      check(`radius ${c} square (must be fill)`, g.corners[c].probe, g.corners[c].expect, TOL);
    }
    check('radius centre', g.corners.centerProbe, g.corners.centerExpect, TOL);

    // --- linear gradient, asserted as a DIRECTION rather than three exact
    // colours: interpolation bytes are a renderer detail, monotonic
    // red-down/blue-up is the contract. A flat fill — what you get when the prop
    // is dropped somewhere in the chain — has zero slope and fails here while
    // looking like "a coloured box" in a screenshot.
    const top = get('gradient top', g.gradient.probeTop);
    const mid = get('gradient middle', g.gradient.probeMiddle);
    const bot = get('gradient bottom', g.gradient.probeBottom);
    if (top && mid && bot) {
      const redFalls = top[0] > mid[0] && mid[0] > bot[0];
      const blueRises = top[2] < mid[2] && mid[2] < bot[2];
      if (!redFalls || !blueRises) {
        fails.push(`gradient: not monotonic top->bottom (red ${top[0]}->${mid[0]}->${bot[0]}, ` +
                   `blue ${top[2]}->${mid[2]}->${bot[2]}) — a flat fill or a wrong axis`);
      } else if (top[0] - bot[0] < 100) {
        fails.push(`gradient: red only falls ${top[0] - bot[0]} over the whole box — barely a gradient`);
      } else if (top[0] < g.gradient.topMinRed || bot[2] < g.gradient.bottomMinBlue) {
        // Monotonicity alone is not enough. A gradient whose endpoints were left
        // in node-local coordinates is SHIFTED but still monotonic — mutant M4
        // proved it passed the direction check.
        fails.push(`gradient: endpoints are off — top red ${top[0]} (need >=${g.gradient.topMinRed}), ` +
                   `bottom blue ${bot[2]} (need >=${g.gradient.bottomMinBlue}). The ramp runs the ` +
                   `right way but is not anchored to the node's box.`);
      } else {
        console.log(`   OK gradient red ${top[0]}->${mid[0]}->${bot[0]}, blue ${top[2]}->${mid[2]}->${bot[2]}`);
      }
    }

    // --- transform. The corner probe is the whole test: it sits inside the
    // UNROTATED bounds, so a renderer that ignores `transform` paints an
    // axis-aligned square, keeps the centre probe correct, and is caught here
    // and nowhere else.
    check('transform centre', g.transform.centerProbe, g.transform.centerExpect, TOL);
    check('transform corner (outside the rotated box)', g.transform.cornerProbe, g.transform.cornerExpect, TOL);

    // --- text metrics
    const paragraphs = frames.filter(f => f.name === 'Paragraph');
    if (paragraphs.length !== 2) {
      fails.push(`text: expected 2 Paragraph nodes, frame report has ${paragraphs.length}`);
    } else {
      // Identify by y position rather than mount order, which is not contractual.
      const [wrapped, clamped] = paragraphs.slice().sort((a, b) => a.y - b.y);
      const {minLineHeight, maxLineHeight, minWrappedLines, boxWidth} = g.text;
      if (clamped.h < minLineHeight || clamped.h > maxLineHeight) {
        fails.push(`text: clamped Paragraph is ${clamped.h}px tall, outside one line (${minLineHeight}..${maxLineHeight})`);
      } else {
        console.log(`   OK clamped Paragraph ${clamped.w}x${clamped.h} (one line)`);
      }
      // numberOfLines being IGNORED is the classic silent failure, and it makes
      // the two heights equal. Requiring a real multiple catches it.
      if (wrapped.h < clamped.h * minWrappedLines) {
        fails.push(`text: wrapped Paragraph is ${wrapped.h}px vs clamped ${clamped.h}px — ` +
                   `expected at least ${minWrappedLines} lines. Either the text did not wrap ` +
                   `at ${boxWidth}px, or numberOfLines was ignored and BOTH wrapped.`);
      } else {
        console.log(`   OK wrapped Paragraph ${wrapped.w}x${wrapped.h} (>= ${minWrappedLines} lines)`);
      }
      // The wrapped node must actually be constrained by its container: a
      // TextLayoutManager that ignores the width constraint reports one long
      // line WIDER than the box, and the height check above then passes for the
      // wrong reason.
      if (wrapped.w > boxWidth + 1) {
        fails.push(`text: wrapped Paragraph measured ${wrapped.w}px wide in a ${boxWidth}px box — width constraint ignored`);
      }
    }
    // Measurement and paint asserted separately: equal-and-correct measurements
    // are also what you get when neither paints.
    checkInk('text wrapped', g.text.wrapped.inkBand);
    checkInk('text clamped', g.text.clamped.inkBand);

    // A uniform frame must never pass by luck. The fixture contains a gradient
    // and an anti-aliased rotated edge, so a correct frame has hundreds of
    // colours.
    const distinct = log.match(/distinct_colors=(\d+)/);
    if (!distinct) fails.push('engine never reported distinct_colors');
    else if (+distinct[1] < 50) fails.push(`only ${distinct[1]} distinct colours — the frame is close to uniform`);
    else console.log(`   OK distinct_colors=${distinct[1]}`);
  },

  // P4: can JS actually CALL native? Each swatch paints ONLY if a TurboModule
  // returned the expected value, and every expectation is a NON-DEFAULT value —
  // asserting colorScheme === 'light' would pass with no Appearance module at
  // all, because that is RN's fallback.
  p4() {
    const TOL = 3;
    const c = (label, spec, why) => check(label, spec.probe, spec.expect, TOL, why);

    c('Appearance reports the engine-supplied scheme', g.appearance,
      `expected colorScheme='${g.appearance.expectScheme}'. RN falls back to 'light' with NO module at all, ` +
      `so a 'light' assertion would pass without Appearance existing`);
    c('StatusBarManager constants readable', g.statusBar,
      'NativeStatusBarManagerIOS.js getEnforcing()s this module — if it were absent the bundle would have thrown at import');
    c('Alert callback fired', g.alert,
      'a module that recorded the alert but never called back leaves the JS promise pending forever');
    c('Linking.canOpenURL both directions', g.linking,
      `${g.linking.okUrl} must be allowed AND ${g.linking.refuseUrl} refused — a predicate stuck on true fails here too`);
    c('Linking.getInitialURL round-trips', g.initialUrl,
      `expected the exact --initial-url the engine was launched with (${g.initialUrl.value})`);
    c('DevSettings callable', g.devSettings,
      'getEnforcing()d like StatusBarManager; a no-op method must not throw');
    c('DefaultTurboModules delegation (performance.now)', g.defaults,
      "performance is vended by RN's OWN DefaultTurboModules, not by our registry — this probe is the delegation assertion");
    c('Platform.constants come from the native module', g.platformConstants,
      `expected reactNativeVersion.minor === ${g.platformConstants.expectMinor}, which is the RN pin the ENGINE was compiled against — ` +
      `the shim returned {} for two phases while the module answered correctly`);

    // The alert must have reached NATIVE, not just resolved in JS. The pixel
    // proves JS got its callback; this proves the call crossed the seam. Both,
    // because a JS-side stub could satisfy either one alone.
    const alerts = log.match(/alerts_shown=(\d+)/);
    if (!alerts) fails.push('engine never reported alerts_shown');
    else if (+alerts[1] < 1) fails.push(`alerts_shown=${alerts[1]} — Alert.alert() never reached native (the JS shim may be self-resolving)`);
    else console.log(`   OK alerts_shown=${alerts[1]} (the call crossed into native)`);

    // Text ink: the frame must be human-readable too, so a reviewer can see
    // WHICH scheme was reported rather than only that a square is green.
    checkInk('colorScheme label', g.text.inkBand);
  },
};

const run = PHASES[phase];
if (!run) { console.error(`assert-fixture: unknown phase '${phase}'`); process.exit(2); }
run();

if (fails.length) {
  console.error(`${failTag}:\n  ` + fails.join('\n  '));
  process.exit(1);
}
