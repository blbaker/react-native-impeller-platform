#!/usr/bin/env bash
# All gates through P4, in the order a CI job should run them.
#   1. P0 headless pixel gate (the substrate every later gate reuses)
#   2. engine package build + R3 size budget
#   3. P1 pack-and-consume: the consumer path, end to end
#   4. P2 mount: a React tree becomes pixels, through that same consumer path
#   5. P3 conformance: individual prop families render CORRECTLY, not just at all
#   6. P4 module seam: JS can actually CALL native, and the packaging ships a
#      callable seam (three-layer guard + per-module pixel probes)
#
# Mutation verification (tools/mutation-verify-*.sh) is deliberately NOT here:
# each mutant costs a full consumer install, so it belongs on a nightly or
# pre-release run. Windows phase coverage is verified by
# tools/mutation-verify-win-phases.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "### gate 1/6: headless pixels"
bash tools/ci-headless.sh | tail -3

echo "### gate 2/6: engine package"
bash tools/engine-build.sh linux x64 | tail -2

echo "### gate 3/6: pack and consume (P1)"
bash tools/pack-and-consume.sh | tail -4

echo "### gate 4/6: RN mount (P2)"
bash tools/ci-p2.sh | tail -10

echo "### gate 5/6: conformance (P3)"
bash tools/ci-p3.sh | tail -22

echo "### gate 6/6: module seam (P4)"
bash tools/ci-p4.sh | tail -16

# ⛔ THE WINDOWS GATE IS OPT-IN, AND SILENCE IS NOT A PASS.
# It needs a staged native build (tools/win-sync.sh + engine-build-win.bat), so
# it cannot be unconditional on a Linux CI box. But a gate that skips quietly is
# one nobody notices has stopped running — so a skip is ANNOUNCED with its
# reason, and RNI_REQUIRE_WIN=1 turns the skip itself into a failure for the
# machine that is supposed to have it.
echo "### gate 7: Windows (opt-in)"
if [ -x "/mnt/c/Devel/rni-win-build/stage/bin/rn-impeller.exe" ] && command -v cmd.exe >/dev/null 2>&1; then
  # ⛔ ALL THREE PHASES, NOT JUST P2. Through P5-D only the P2 fixture had ever
  # run on Windows — a static tree of solid fills, the cheapest thing a renderer
  # can get right. P3 drives the gradient/transform/AA paths and DirectWrite text
  # measurement; P4 crosses the JS<->native seam, where Windows has genuinely
  # different implementations (ShellExecuteW rather than exec) behind the same
  # TurboModule interface. Running P2 alone and calling the port "verified on
  # Windows" is the same shape of gap as running one Windows gate and calling
  # delivery covered.
  for phase in p2 p3 p4; do
    echo "###   phase $phase"
    bash tools/ci-win.sh "$phase" | tail -12
  done
  # ⛔ TWO WINDOWS GATES, AND THE SECOND IS NOT A DUPLICATE OF THE FIRST.
  # ci-win.sh drives the STAGED BUILD; it proves the port runs. ci-win-consumer.sh
  # drives an engine INSTALLED FROM A TARBALL into an app outside the repo; it
  # proves the port can be DELIVERED. Mutation M1 measures the difference: with a
  # runtime DLL dropped from the npm package, ci-win.sh stays green and only the
  # consumer gate reddens. Running one and calling Windows covered is how the
  # skia-platform packaging bugs survived nine phases.
  echo "### gate 8: Windows consumer (opt-in)"
  bash tools/ci-win-consumer.sh | tail -8
elif [ "${RNI_REQUIRE_WIN:-0}" = "1" ]; then
  echo "WINDOWS_GATE_MISSING: RNI_REQUIRE_WIN=1 but no staged Windows engine" >&2
  exit 1
else
  echo "   SKIPPED — no staged Windows engine (build: tools/win-sync.sh then"
  echo "   cmd.exe /c C:\\Devel\\rni-win-scripts\\engine-build-win.bat). Set"
  echo "   RNI_REQUIRE_WIN=1 to make this skip a failure."
fi

# ⛔ THE DARWIN STAGING FETCHERS RUN ON EVERY HOST, ON PURPOSE.
# They stage macOS artifacts and are therefore easy to leave broken for weeks
# while every green run says nothing about them — nobody notices a fetcher rot
# until the one session that needs it. They are pure downloads with no macOS
# code, so any host can run them: cheap, and it keeps the pins honest (a
# replaced Electron asset or a moved SDK path reddens HERE, on the box that can
# actually fix it, rather than on a Mac reachable only over SSH).
echo "### gate 9: darwin staging fetchers"
bash tools/sdk-fetch-darwin.sh | tail -2
ANGLE_PLATFORM=darwin-arm64 bash tools/angle-fetch.sh | tail -1

# ⛔ THE RELEASE GATE RUNS ON EVERY HOST, LIKE THE DARWIN FETCHERS.
# It reads package metadata and touches no engine, so any box can run it — and
# a version-lockstep or shipped-files defect found here is free, while the same
# defect found after `npm publish` is a version burned forever.
echo "### gate 10: release metadata"
bash tools/ci-release-meta.sh | tail -2

echo "### gate 11: package selftest (what a user's npm test runs)"
(cd package && node src/selftest.js | tail -2)

# ⛔ THE WORKFLOW POLICY GATE RUNS EVERYWHERE, LIKE THE RELEASE GATE.
# It reads the workflow FILES and touches nothing, so any host can run it — and
# it is the only gate whose subject is what a push is allowed to CAUSE. Every
# other gate here asserts something about the artifact; a defect they all miss
# is a pipeline that publishes from a branch. Free to catch on this box, and
# permanent if it reaches the registry.
echo "### gate 12: workflow policy"
bash tools/ci-workflows.sh | tail -2

# ⛔ GATE 13 IS THE ONLY ONE THAT TESTS npm's SELECTION MECHANISM.
# Every other consumer gate installs the tarballs BY PATH, which hand-places
# both packages and therefore proves nothing about `optionalDependencies` +
# `os`/`cpu` — the mechanism that decides whether a real user gets an engine at
# all. npm skips an optional dependency it cannot use AND EXITS 0, so every
# failure mode there is silent: a wrong os field, a typo'd triple, a version
# skew all yield a clean install with no engine.
#
# It runs a real private registry (verdaccio) on loopback, publishes with the
# real `npm publish`, and installs BY NAME. Nothing leaves the machine: the
# script refuses to run unless the target URL resolves to loopback, and it uses
# a throwaway .npmrc so the developer's npmjs credentials are never read.
#
# Last, because it is the slowest and depends on staged engines existing.
#
# ⛔ DO NOT `| tail -N` THIS ONE. The first CI run showed only the final three
# lines, which meant the two assertions that justify the gate's existence —
# "installed engine-<triple> via optionalDependencies" and "no foreign-platform
# engines installed (N checked)" — were invisible in the log. A green gate whose
# evidence you cannot read is a gate you have to trust rather than verify, and
# this repo has already been bitten twice by checks that passed while examining
# nothing. grep keeps the output short AND keeps the proof.
echo "### gate 13: install from a real registry (by name)"
bash tools/ci-registry.sh | grep -E "registry up|published |installed engine|foreign-platform|selftest passed|REGISTRY_GATE_PASS"

# ⛔ GATE 14 IS THE ONLY ONE THAT WOULD NOTICE A ZOOM PRETENDING TO BE RETINA.
# Every other pixel gate renders at exactly one scale, so a change that made
# --scale multiply LAYOUT instead of RESOLUTION would leave all of them green:
# the fixture would still paint, still hit its probes, still count its nodes.
# This one renders the SAME bundle twice and asserts both halves of the claim —
# identical geometry in points, strictly more colour detail in pixels. An
# upscale fails the second half; a zoom fails the first.
echo "### gate 14: retina (points vs pixels)"
bash tools/retina-check.sh | grep -E "^\[fabric\]|distinct colours|RETINA_OK"

# ---------------------------------------------------------------------------
# P9 gates. All three assert on PIXELS, never on clean logs — this phase's
# governing failure mode is silent by construction: an unregistered Fabric
# component mounts, counts as painted, and draws nothing.
#
# ⚠️ These need a display (DISPLAY=:0) and must NOT have SDL_VIDEODRIVER set.
# Skipped rather than failed where there is none, so a headless CI box reports
# honestly instead of going red for a missing X server.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ]; then
  echo "### gate 15: windowed WSI (a real window, N frames, valid capture)"
  bash tools/ci-window.sh | grep -E "WINDOW_GATE_PASS|OK:"

  # ⛔ NOT redundant with gate 15. That one passes on an engine that paints
  # frame 0 and redraws IDENTICAL pixels forever — indistinguishable from the
  # old one-shot for anyone watching a loading animation. Only two captures
  # from ONE run, compared as pixels, can tell them apart.
  echo "### gate 16: repaint loop draws NEW content (matched pair)"
  bash tools/ci-animate.sh | grep -E "ANIMATE_GATE_PASS|px changed"
else
  echo "### gates 15-16: SKIPPED (no DISPLAY; windowed gates need an X server)"
fi

# Headless, so it always runs. Matched TRIPLE: solid paints, fillOpacity=0
# paints nothing, and two paths differing ONLY in opacity differ from each
# other. The third is the one that catches a renderer that treats fill-opacity
# as all-or-nothing.
echo "### gate 17: SVG paths paint, with PER-PATH fill-opacity"
bash tools/ci-svg.sh | grep -E "SVG_GATE_PASS|solid="

# The product-shaped acceptance: 17 filled paths in one <Svg> inside a <G>,
# one colour, differing only by fill-opacity — the HostApp mark's structure. The
# assertion is a COUNT of distinct alpha levels, because "did it paint" and
# "is it grey" both pass on the flat disc a global-opacity renderer produces.
echo "### gate 18: the HostApp mark's structure (17 even grey levels)"
bash tools/ci-mark.sh | grep -E "MARK_GATE_PASS|distinct grey levels"

# Guards a bug that SHIPPED on skia-platform: RNSVGGroupProps::matrix exists
# and is never read, so <G transform> is silently dropped and art renders at
# the wrong size. Asserts POSITION, not presence — a renderer ignoring the
# transform still paints a perfectly good square, just in the wrong place.
echo "### gate 19: <G transform> moves its children (translate/scale/rotate)"
bash tools/ci-gtransform.sh | grep -E "GTRANSFORM_GATE_PASS|->"

# Fill and stroke are INDEPENDENT in SVG (own colours, own opacities), so a
# single StrokeAndFill paint would draw the outline in the fill's colour --
# invisible on any shape whose two colours match. Probes a stroke-only shape
# (fill="none"), differing colours, width, and strokeOpacity.
echo "### gate 20: stroke (independent colour, width, opacity)"
bash tools/ci-stroke.sh | grep -E "STROKE_GATE_PASS|edge="

# Rect/Circle/Ellipse/Line are converted to path data and painted by the SAME
# code as <Path>. Each probe pairs an INK point with an EMPTY point, because a
# wrong conversion (square corners, a circle drawn for an ellipse) still paints
# something in roughly the right place.
echo "### gate 21: basic shapes (rect, circle, ellipse, line)"
bash tools/ci-shapes.sh | grep -E "SHAPES_GATE_PASS|ink\("

echo "ALL_GATES_PASS"
