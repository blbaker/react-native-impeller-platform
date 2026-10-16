#!/usr/bin/env python3
"""FP-27 checker for tools/ci-metal-pacing.sh (arms in that script's header).

usage: metal_pacing_check.py <workdir>   (reads spin-{1,2,3}.log)
Prints one METAL_PACING FAIL line per failed arm and exits 1, else METAL_PACING CHECK OK.
"""
import re
import statistics
import sys

LINK = re.compile(r'^rn-impeller: display_link ok=(\d) display_id=(\d+) period_us=(\d+)')
REQUESTED = re.compile(r'^rn-impeller: vsync requested=(\w+) ')
SUMMARY = re.compile(r'^rn-impeller: display_link callbacks=(\d+) link_ticks=(\d+) '
                     r'fallback_ticks=(\d+) displayed=(\d+) dropped=(\d+)')
TICK = re.compile(r'^rn-impeller: display_link_tick n=(\d+) t_us=(\d+) target_us=(\d+)')
DISPLAYED = re.compile(r'^rn-impeller: vsync_displayed n=(\d+) presented_us=(\d+) encode_us=(\d+) '
                       r'tick_us=(\d+) target_us=(\d+)')
WARMUP = 5
INTERVALS = 120
PERIOD_TOL = 0.05            # median presented interval within 5% of the display period
EARLY_US = 1000              # a displayed time may not precede the frame's target vblank
MAX_LATENCY_PERIODS = 3      # displayed - target vblank (see vsync_check.py)


def parse(path):
    out = {'link': None, 'requested': None, 'summary': None, 'ticks': [], 'rows': []}
    for line in open(path, errors='replace'):
        m = DISPLAYED.match(line)
        if m:
            out['rows'].append(tuple(int(g) for g in m.groups()))
            continue
        m = TICK.match(line)
        if m:
            out['ticks'].append(int(m.group(2)))
            continue
        m = LINK.match(line)
        if m:
            out['link'] = (int(m.group(1)), int(m.group(3)))
        m = REQUESTED.match(line)
        if m:
            out['requested'] = m.group(1)
        m = SUMMARY.match(line)
        if m:
            out['summary'] = tuple(int(g) for g in m.groups())
    out['rows'].sort()
    return out


def run_stats(i, r, fails):
    tag = f'spin-{i}'
    if not r['link'] or r['link'][0] != 1 or r['link'][1] <= 0:
        fails.append(f'S source: {tag} has no working display link ({r["link"]})')
        return None
    period = r['link'][1]
    if r['requested'] != 'displaylink':
        fails.append(f'S source: {tag} paced on {r["requested"]}, not displaylink')
        return None
    if not r['summary']:
        fails.append(f'S source: {tag} printed no display_link summary')
        return None
    callbacks, link_ticks, fallback, displayed, dropped = r['summary']
    shown = [x for x in r['rows'] if x[1] > 0][WARMUP:WARMUP + INTERVALS + 1]
    if len(shown) < INTERVALS + 1:
        fails.append(f'P pacing: {tag} displayed only {len(shown)} frames after warm-up, need {INTERVALS + 1}')
        return None
    if fallback > 5 or link_ticks < INTERVALS:
        fails.append(f'S source: {tag} link_ticks={link_ticks} fallback_ticks={fallback}: the loop '
                     f'is not waiting on the link (want >= {INTERVALS} and <= 5)')
    t = [x[1] for x in shown]
    iv = [b - a for a, b in zip(t, t[1:])]
    short = sum(1 for x in iv if x < period / 2)
    # control: the same process's CVDisplayLink callbacks over the same span, as they arrived
    lo, hi = t[0], t[-1]
    ct = [x for x in r['ticks'] if lo <= x <= hi]
    civ = [b - a for a, b in zip(ct, ct[1:])]
    ctrl_short = sum(1 for x in civ if x < period / 2)
    early = [x for x in shown if x[1] < x[4] - EARLY_US]
    before_encode = [x for x in shown if x[1] <= x[2]]
    lat = statistics.median([x[1] - x[4] for x in shown])
    print(f'  {tag}: period={period}us median_interval={statistics.median(iv):.0f}us '
          f'sd={statistics.pstdev(iv):.0f}us short={short} control_ticks={len(ct)} '
          f'control_short={ctrl_short} display_latency={lat:.0f}us early={len(early)} '
          f'before_encode={len(before_encode)} callbacks={callbacks} link_ticks={link_ticks} '
          f'fallback_ticks={fallback} displayed={displayed} dropped={dropped}')
    if early or before_encode:
        x = (early or before_encode)[0]
        fails.append(f'T displayed time: {tag} has {len(early)} frames "displayed" more than '
                     f'{EARLY_US}us before their target vblank and {len(before_encode)} at or before '
                     f'their own encode (n={x[0]} presented={x[1]} encode={x[2]} target={x[4]}): '
                     f'the timestamp is not the drawable\'s presentedTime')
    if len(ct) < INTERVALS:
        fails.append(f'C control: {tag} logged only {len(ct)} display_link_tick lines in the span')
    return {'period': period, 'median': statistics.median(iv), 'short': short,
            'ctrl_short': ctrl_short, 'lat': lat}


def main():
    work = sys.argv[1]
    fails, runs = [], []
    for i in (1, 2, 3):
        s = run_stats(i, parse(f'{work}/spin-{i}.log'), fails)
        if s:
            runs.append(s)
    if len(runs) == 3:
        period = runs[0]['period']
        med = statistics.median(r['median'] for r in runs)
        short = sum(r['short'] for r in runs)
        ctrl = sum(r['ctrl_short'] for r in runs)
        allowed = 3 + 2 * ctrl  # ci-vsync's B limit
        lat = statistics.median(r['lat'] for r in runs)
        print(f'  P: median presented interval {med:.0f}us vs period {period}us '
              f'(tolerance {PERIOD_TOL * period:.0f}us)')
        print(f'  K: short intervals {short} in 3x{INTERVALS}, link control {ctrl}, allowed {allowed}')
        print(f'  L: median display latency {lat:.0f}us = {lat / period:.2f} periods (allowed {MAX_LATENCY_PERIODS})')
        if abs(med - period) > PERIOD_TOL * period:
            fails.append(f'P pacing: median presented interval {med:.0f}us is not within 5% of the '
                         f'{period}us display period')
        if short > allowed:
            fails.append(f'K short intervals: {short} presented intervals under half a period vs {ctrl} '
                         f'in the same-process CVDisplayLink control (allowed 3 + 2x = {allowed})')
        if lat > MAX_LATENCY_PERIODS * period:
            fails.append(f'L latency: frames displayed {lat / period:.1f} periods after their target '
                         f'vblank (allowed {MAX_LATENCY_PERIODS}): rendered ahead of the display')
    for f in fails:
        print(f'METAL_PACING FAIL {f}')
    if fails:
        sys.exit(1)
    print('METAL_PACING CHECK OK')


if __name__ == '__main__':
    main()
