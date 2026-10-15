#!/usr/bin/env python3
"""Assertions for tools/ci-native-transform.sh. Reads <app>-<frames>.{ppm,log}
from the gate's workdir and checks each arm against an ANALYTIC oracle (the
animation curve the fixture asks for), not against a previous run.

  usage: native_transform_check.py <workdir>

Frame model: the headless loop advances the animation clock one 60 fps
interval (16.667 ms) per --frames step, and a driver latches its start time
on the first tick, so the run with --frames k shows the animation at
elapsed = (k - 1) * 16.667 ms. Every expected value below derives from that.
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm_bbox import measure  # noqa: E402

LAYOUT_W = 400
FRAME_MS = 1000.0 / 60.0
SIZE_TOL = 4.0    # points, bounding-box width/height
CENTRE_TOL = 2.0  # points, bounding-box centre
LUMA_TOL = 8.0    # 0..255
FRAMES = (1, 11, 21, 31)

WORK = sys.argv[1]
failures = []


def fail(msg):
    failures.append(msg)
    print('   FAIL: ' + msg)


def run(app, k):
    base = os.path.join(WORK, '%s-%d' % (app, k))
    log = open(base + '.log', errors='replace').read()
    if not re.search(r'scene_nodes=[1-9]', log):
        raise SystemExit('NT_FAIL: %s --frames %d mounted nothing (scene_nodes=0): '
                         'wrong --app-name or a JS error' % (app, k))
    m = measure(base + '.ppm', 128, LAYOUT_W)
    counters = dict((a, float(b)) for a, b in re.findall(
        r'\b(nativeanimated_ticks|directprop_updates|js_timers|mount_tx|tick_us_avg)=([0-9.]+)', log))
    # the frameloop line repeats nativeanimated_ticks; the LAST match wins,
    # and both equal the frame count for a run that animates from frame 1.
    m.update(counters)
    print('   %s --frames %-2d bbox %3.0fx%-3.0f centre (%5.1f,%5.1f) luma %3.0f  '
          'ticks=%d props=%d js_timers=%d mount_tx=%d'
          % (app, k, m['bw'], m['bh'], m['cx'], m['cy'], m['centre_luma'],
             m.get('nativeanimated_ticks', -1), m.get('directprop_updates', -1),
             m.get('js_timers', -1), m.get('mount_tx', -1)))
    return m


def elapsed(k):
    return (k - 1) * FRAME_MS


def near(got, want, tol):
    return abs(got - want) <= tol


print('== A. rotate, useNativeDriver: true (the peer\'s probe) ==')
seen = []
for k in FRAMES:
    m = run('NativeRotateProbe', k)
    th = 2 * math.pi * elapsed(k) / 700.0
    want_w = 100 * abs(math.cos(th)) + 20 * abs(math.sin(th))
    want_h = 100 * abs(math.sin(th)) + 20 * abs(math.cos(th))
    if not (near(m['bw'], want_w, SIZE_TOL) and near(m['bh'], want_h, SIZE_TOL)):
        fail('rotate frame %d: bbox %.0fx%.0f, want %.0fx%.0f (%.1f deg)'
             % (k, m['bw'], m['bh'], want_w, want_h, math.degrees(th)))
    if not (near(m['cx'], 200, CENTRE_TOL) and near(m['cy'], 150, CENTRE_TOL)):
        fail('rotate frame %d: pivot moved, bbox centre (%.1f,%.1f) not (200,150)'
             % (k, m['cx'], m['cy']))
    if m.get('directprop_updates', 0) < k:
        fail('rotate frame %d: directprop_updates=%d < %d, props not applied'
             % (k, m.get('directprop_updates', 0), k))
    seen.append((round(m['bw']), round(m['bh'])))
if len(set(seen)) != len(seen):
    fail('rotate frozen: bounding boxes over frames %s are %s, not all different'
         % (list(FRAMES), seen))

print('== B. negative arm: the same tree, loop never started ==')
for k in (1, 31):
    m = run('NativeRotateIdle', k)
    if not (near(m['bw'], 100, 1) and near(m['bh'], 20, 1)):
        fail('idle bar moved: frame %d bbox %.0fx%.0f, want 100x20' % (k, m['bw'], m['bh']))

print('== C. opacity pulse 1 -> 0.2 -> 1, useNativeDriver: true ==')
lumas = []
for k in FRAMES:
    m = run('NativeOpacityPulse', k)
    p = elapsed(k) / 1400.0
    a = 1 - 1.6 * p if p <= 0.5 else 0.2 + 1.6 * (p - 0.5)
    if not near(m['centre_luma'], 255 * a, LUMA_TOL):
        fail('opacity frame %d: centre luma %.0f, want %.0f (opacity %.3f)'
             % (k, m['centre_luma'], 255 * a, a))
    lumas.append(round(m['centre_luma']))
if len(set(lumas)) != len(lumas):
    fail('opacity frozen: centre luma over frames %s is %s' % (list(FRAMES), lumas))

print('== D. translateX/translateY/scale, useNativeDriver: true ==')
for k in FRAMES:
    m = run('NativeTranslateScale', k)
    p = elapsed(k) / 700.0
    wx, wy, s = 200 + 70 * p, 150 + 40 * p, 1 + p
    if not (near(m['cx'], wx, CENTRE_TOL) and near(m['cy'], wy, CENTRE_TOL)):
        fail('translate frame %d: centre (%.1f,%.1f), want (%.1f,%.1f)'
             % (k, m['cx'], m['cy'], wx, wy))
    if not (near(m['bw'], 100 * s, SIZE_TOL) and near(m['bh'], 20 * s, SIZE_TOL)):
        fail('scale frame %d: bbox %.0fx%.0f, want %.0fx%.0f'
             % (k, m['bw'], m['bh'], 100 * s, 20 * s))

print('== E. cost: no per-frame JS work in a native-driven loop ==')
ticks_us = []
for app in ('NativeRotateProbe', 'NativeOpacityPulse', 'NativeTranslateScale'):
    m = run(app, 31)
    if 'js_timers' not in m or 'mount_tx' not in m:
        fail('%s: no frameloop js_timers/mount_tx line (engine predates the instrument)' % app)
        continue
    if m['js_timers'] != 0 or m['mount_tx'] != 0:
        fail('native loop did JS work: %s js_timers=%d mount_tx=%d over 31 frames'
             % (app, m['js_timers'], m['mount_tx']))
    ticks_us.append(m.get('tick_us_avg', 0))
m = run('JsRotateProbe', 1)
# CONTROL. The JS driver re-arms requestAnimationFrame every frame and commits
# through React, so both counters MUST be non-zero here, or they are blind and
# the zeros above prove nothing.
if m.get('js_timers', 0) <= 0:
    fail('cost instrument blind: JS-driven control shows js_timers=0')
if m.get('mount_tx', 0) <= 0:
    fail('cost instrument blind: JS-driven control shows mount_tx=0')

if failures:
    print('NT_FAIL: %d check(s) failed; first: %s' % (len(failures), failures[0]))
    sys.exit(1)
print('NATIVE_TRANSFORM_PASS (rotate %s, opacity luma %s, native tick avg %s us on the frame-loop thread, '
      'JS control js_timers=%d mount_tx=%d)'
      % (seen, lumas, '/'.join('%.1f' % t for t in ticks_us), m['js_timers'], m['mount_tx']))
