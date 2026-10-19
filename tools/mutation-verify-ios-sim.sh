#!/usr/bin/env bash
# iOS host phase / Task 3.4 mutants for tools/ci-ios-sim.sh (the M1 gate), run
# on linux with RNI_MAC_HOST set; each mutated tree is synced by the gate. The
# Phase 1 primitives keep their own scripts (tools/mutation-verify-*-ios*.sh).
#   M1  the oracle disagrees with the bundle (geometry.js's plain box turns green,
#       the committed bundle still paints red) -> P: box_rgb_match=0
#   M2  the screenshot is taken as soon as the app is up, without waiting for
#       the engine's idle marker (IOS_SIM_SHOT_EARLY=1) -> P
#   M3  RNIEngine lays out in pixels (scale 1) instead of points -> P
#   M4  RNIEngine never starts the surface -> B: no first frame
#   M5  detach tears the session down, so re-attach boots a second one -> L
# Then the restored tree must pass.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ios-mutants.sh"
GATE=tools/ci-ios-sim.sh
GEOM=fixtures/ios-smoke/geometry.js
ENG=engine/ios/RNIEngine.mm
mut_backup "$GEOM" "$ENG"

mut_apply "$GEOM" '"id": "plain", "x": 40, "y": 200, "width": 120, "height": 80, "color": "#ff0000"' \
  '"id": "plain", "x": 40, "y": 200, "width": 120, "height": 80, "color": "#00ff00"'
mut_expect M1 "$GATE" 'IOS_SIM_GATE FAIL P: .*box_rgb_match=0'

export IOS_SIM_SHOT_EARLY=1
mut_expect M2 "$GATE" 'IOS_SIM_GATE FAIL P: '
unset IOS_SIM_SHOT_EARLY

mut_apply "$ENG" '  s.scale = (float)view.layer.contentsScale;' '  s.scale = 1.0f;  // MUTANT M3'
mut_expect M3 "$GATE" 'IOS_SIM_GATE FAIL P: '

mut_apply "$ENG" '  s.session->StartSurface(s.appName, s.width, s.height, s.scale);' \
  '  // MUTANT M4: the surface is never started'
mut_expect M4 "$GATE" 'IOS_SIM_GATE FAIL B: no first frame'

mut_apply "$ENG" '  _s->link.reset();
  _s->surface.Release();' '  _s->link.reset();
  _s->surface.Release();
  _s->session.reset();  // MUTANT M5'
mut_expect M5 "$GATE" 'IOS_SIM_GATE FAIL L: '

mut_restore
mut_clean "$GATE" '^IOS_SIM_PASS '
mut_summary MUTATION_VERIFY_IOS_SIM
