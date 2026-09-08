#!/usr/bin/env node
// Turn a fixture.json into the engine's probe arguments, ONE PER LINE.
//
// ⛔ WHY THIS IS A FILE AND NOT FOUR INLINE `node -e` BLOCKS.
// Each gate used to build its own argument list. ci-win.sh's copy of the P2
// builder was already a HAND-COPY of ci-p2.sh's, which is the exact drift the
// Windows gate's own header warns about: probes that no longer match the
// fixture produce "engine never reported probe X" — a message that reads like
// an engine defect and is actually a stale gate.
//
// One line per argument, deliberately: probe values contain commas, so the
// caller reads them with `mapfile`/`for /f` rather than splitting on a
// separator that also appears inside the data.
//
// Usage: node fixture-probe-args.js <fixture.json> <p2|p3|p4|p10>
'use strict';
const path = require('path');

const [fixturePath, phase] = process.argv.slice(2);
if (!fixturePath || !phase) {
  console.error('usage: fixture-probe-args.js <fixture.json> <p2|p3|p4|p10>');
  process.exit(2);
}
const g = require(path.resolve(fixturePath));
const out = [];
const arg = (...xs) => out.push(...xs.map(String));
const probe = xy => arg('--probe', xy.join(','));

const BUILDERS = {
  p2() {
    for (const b of g.boxes) {
      probe(b.probe);
      if (b.cornerProbe) probe(b.cornerProbe);
    }
    arg('--ink-band', g.label.inkBand.join(','));
  },

  p3() {
    for (const side of ['top', 'right', 'bottom', 'left']) probe(g.edges[side].probe);
    probe(g.edges.centerProbe);
    for (const c of ['cornerTL', 'cornerTR', 'cornerBL', 'cornerBR']) probe(g.corners[c].probe);
    probe(g.corners.centerProbe);
    probe(g.gradient.probeTop);
    probe(g.gradient.probeMiddle);
    probe(g.gradient.probeBottom);
    probe(g.transform.centerProbe);
    probe(g.transform.cornerProbe);
    arg('--ink-band', g.text.wrapped.inkBand.join(','));
    arg('--ink-band', g.text.clamped.inkBand.join(','));
  },

  p4() {
    for (const k of ['appearance', 'statusBar', 'alert', 'linking', 'initialUrl',
                     'devSettings', 'defaults', 'platformConstants']) {
      probe(g[k].probe);
    }
    arg('--ink-band', g.text.inkBand.join(','));
  },

  p10() {
    // `control` is FIRST and is not a networking assertion: it proves the
    // engine booted and Fabric mounted, so a run where everything is
    // background is distinguishable from a run where networking failed.
    for (const k of ['control', 'nativeHalf', 'getRequest', 'getStatus',
                     'postRequest', 'responseHeaders', 'errorPath']) {
      probe(g[k].probe);
    }
    arg('--ink-band', g.text.inkBand.join(','));
  },
};

const build = BUILDERS[phase];
if (!build) {
  console.error(`fixture-probe-args: unknown phase '${phase}'`);
  process.exit(2);
}
build();

// Surface size is common to every phase; the per-phase builders never repeat it.
arg('--width', g.surface.width, '--height', g.surface.height);

// P4 alone needs the engine told what to REPORT, not just where to look. These
// are inputs the fixture asserts round-trip back out through a TurboModule.
if (phase === 'p4') {
  arg('--color-scheme', g.appearance.expectScheme);
  arg('--initial-url', g.initialUrl.value);
}

console.log(out.join('\n'));
