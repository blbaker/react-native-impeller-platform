#!/usr/bin/env python3
"""FP-11 checker for tools/ci-vsync.sh (arms A-D, see there).

usage: vsync_check.py <workdir>
  (reads spin-{1,2,3}.log, control-{1,2,3}.txt, idle.log, mutate.log)
VSYNC_ARMS (env, FP-26): subset of "A B C D tick", default "A B C D". `tick` is
B's exact per-run half (shared_tick=0, max_frames_per_tick=1); B implies it.
Without A or B no control-*.txt is read.
Prints one FAIL line per failed arm and exits 1, else a PASS summary.
"""
import os
import re
import statistics
import sys

PRESENT = re.compile(r'^rn-impeller: vsync_present n=(\d+) t_us=(\d+) swap_us=(\d+) '
                     r'interval_us=(\d+)(?: since_vsync_us=(\d+))? source=(\w+)')
REQUEST = re.compile(r'^rn-impeller: vsync_request reason=(\w+) t_us=(\d+)')
PERIOD = re.compile(r'^rn-impeller: vsync requested=\w+ swap_interval=\d+ period_us=(\d+)')
SUMMARY = re.compile(r'^rn-impeller: frame_scheduler source=(\w+) .*max_frames_per_tick=(\d+)')
WARMUP = 5      # presents skipped after the source decision
INTERVALS = 120


def parse(path):
    presents, requests, period, summary = [], [], None, None
    for line in open(path, errors='replace'):
        m = PRESENT.match(line)
        if m:
            # (n, t_us, source, tick_us): tick_us = the vsync this present served
            since = m.group(5)
            presents.append((int(m.group(1)), int(m.group(2)), m.group(6),
                             int(m.group(2)) - int(since) if since is not None else None))
            continue
        m = REQUEST.match(line)
        if m:
            requests.append((m.group(1), int(m.group(2))))
            continue
        m = PERIOD.match(line)
        if m:
            period = int(m.group(1))
        m = SUMMARY.match(line)
        if m:
            summary = (m.group(1), int(m.group(2)))
    return presents, requests, period, summary


def check_idle(work, fails):
    # C: a static scene presents nothing once settled (2 s window).
    presents, _, _, _ = parse(f'{work}/idle.log')
    if not presents:
        fails.append('C idle: no presents at all (nothing painted)')
    else:
        t0 = presents[0][1] + 500_000
        busy = [p for p in presents if t0 <= p[1] <= t0 + 2_000_000]
        print(f'  C: idle presents in the 2 s window={len(busy)} (total {len(presents)})')
        if busy:
            fails.append(f'C idle: a static scene presented {len(busy)} frames in 2 s (want 0)')


def check_mutation(work, fails):
    # D: a mutation ~1 s in presents within 2 periods, once.
    presents, requests, period_d, _ = parse(f'{work}/mutate.log')
    period_d = period_d or 16666
    if not presents:
        fails.append('D mutation: no presents at all')
    else:
        boot = presents[0][1]
        late = [r for r in requests if r[0] == 'damage' and r[1] > boot + 500_000]
        if not late:
            fails.append('D mutation: no damage request after boot (the 1 s setState never arrived)')
        else:
            req = late[0][1]
            quiet = [p for p in presents if boot + 300_000 <= p[1] < req]
            after = [p for p in presents if req <= p[1] <= req + 500_000]
            lat = (after[0][1] - req) if after else None
            print(f'  D: mutation at +{(req - boot) / 1e3:.0f}ms, latency='
                  f'{lat if lat is not None else "none"}us, presents for it={len(after)}, '
                  f'presents while idle before it={len(quiet)}')
            if quiet:
                fails.append(f'D mutation: {len(quiet)} presents while idle before the mutation')
            if lat is None or lat > 2 * period_d:
                fails.append(f'D mutation: first present {lat}us after the request (want <= 2 periods = {2 * period_d}us)')
            elif len(after) > 2:
                fails.append(f'D mutation: one commit presented {len(after)} frames (want 1-2)')


def main():
    work = sys.argv[1]
    arms = set(os.environ.get('VSYNC_ARMS', 'A B C D').split())
    unknown = arms - {'A', 'B', 'C', 'D', 'tick'}
    if unknown or not arms:
        print(f'VSYNC FAIL bad VSYNC_ARMS {sorted(unknown) or "(empty)"}')
        sys.exit(1)
    if 'B' in arms:
        arms.add('tick')
    control = bool(arms & {'A', 'B'})
    print(f'  arms: {" ".join(sorted(arms))}')
    fails = []
    means, sds, ctrl_sds, ctrl_means, period = [], [], [], [], None
    short_total, ctrl_short_total = 0, 0
    for i in (1, 2, 3) if arms & {'A', 'B', 'tick'} else ():
        wakes = ([int(x) for x in open(f'{work}/control-{i}.txt').read().split()]
                 if control else [])
        civ = [b - a for a, b in zip(wakes, wakes[1:])][5:]
        ctrl_sds.append(statistics.pstdev(civ) if len(civ) > 10 else 0.0)
        ctrl_means.append(statistics.fmean(civ) if len(civ) > 10 else 0.0)
        presents, _, period, summary = parse(f'{work}/spin-{i}.log')
        if period is None or summary is None:
            fails.append(f'spin-{i}: no vsync/frame_scheduler lines (engine without FP-11?)')
            continue
        ctrl_doubles = sum(1 for x in civ[:INTERVALS] if x < period / 2)
        ctrl_short_total += ctrl_doubles
        paced = [p for p in presents if p[2] != 'auto'][WARMUP:]
        if len(paced) < INTERVALS + 1:
            fails.append(f'spin-{i}: only {len(paced)} paced presents, need {INTERVALS + 1}')
            continue
        window = paced[:INTERVALS + 1]
        t = [p[1] for p in window]
        iv = [b - a for a, b in zip(t, t[1:])]
        mean, sd = statistics.fmean(iv), statistics.pstdev(iv)
        means.append(mean)
        sds.append(sd)
        doubles = sum(1 for x in iv if x < period / 2)
        ticks = [p[3] for p in window]
        shared = (sum(1 for a, b in zip(ticks, ticks[1:]) if a == b)
                  if None not in ticks else None)
        ctrl = (f' control: mean={ctrl_means[-1]:.0f}us sd={ctrl_sds[-1]:.0f}us short={ctrl_doubles}'
                if control else '')
        print(f'  spin-{i}: source={paced[0][2]} mean={mean:.0f}us sd={sd:.0f}us '
              f'short={doubles} shared_tick={shared} max_frames_per_tick={summary[1]}{ctrl}')
        short_total += doubles
        # B: one frame per vsync, exact per run from the present stamps and the scheduler.
        if shared is None:
            fails.append(f'B double frames: spin-{i} presents carry no since_vsync_us')
        elif shared > 0 or summary[1] > 1:
            fails.append(f'B double frames: spin-{i} has {shared} presents serving an already '
                         f'presented vsync tick and {summary[1]} BeginFrames for one vsync')
    # B (load-relative): a late frame followed by an on-time one gives a short interval without
    # being a double. Short intervals are counts of rare events, so they are pooled over the 3
    # runs and judged against the control arms beside them: at most 3 + 2x the control's.
    if len(means) == 3 and 'B' in arms:
        allowed = 3 + 2 * ctrl_short_total
        print(f'  B: short intervals {short_total} in 3x{INTERVALS}, control {ctrl_short_total}, '
              f'allowed {allowed}')
        if short_total > allowed:
            fails.append(f'B double frames: {short_total} of {3 * INTERVALS} present intervals under '
                         f'half a period vs {ctrl_short_total} in the control arms beside them '
                         f'(allowed 3 + 2x = {allowed})')
    if len(means) == 3 and 'A' in arms:
        mean, sd = statistics.median(means), statistics.median(sds)
        floor = statistics.median(ctrl_sds)
        limit = 0.10 * period + 1.5 * floor
        drift = abs(statistics.median(ctrl_means) - period)
        mean_tol = 0.05 * period + drift
        print(f'  A: median mean={mean:.0f}us sd={sd:.0f}us period={period}us '
              f'control_sd={floor:.0f}us sd_limit={limit:.0f}us control_drift={drift:.0f}us '
              f'mean_tol={mean_tol:.0f}us')
        if abs(mean - period) > mean_tol or sd >= limit:
            fails.append(f'A pacing: median present interval {mean:.0f}us sd {sd:.0f}us vs the '
                         f'{period}us period (mean within 5% + control drift {drift:.0f}us = '
                         f'{mean_tol:.0f}us, sd under 10% + 1.5x control {floor:.0f}us = '
                         f'{limit:.0f}us): free-running or unpaced presents')

    if 'C' in arms:
        check_idle(work, fails)
    if 'D' in arms:
        check_mutation(work, fails)

    for f in fails:
        print(f'VSYNC FAIL {f}')
    if fails:
        sys.exit(1)
    print('VSYNC CHECK OK')


if __name__ == '__main__':
    main()
