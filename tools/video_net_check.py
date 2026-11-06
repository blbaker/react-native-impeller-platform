#!/usr/bin/env python3
"""Log checks for tools/ci-video-net.sh. Each subcommand prints one summary
line and exits 0, or prints the failed rule and exits 1.

  video_net_check.py play <engine.log> --secs N [--max-drop-pct P] [--rates "0.6@10,1.25@20,1@30"]
  video_net_check.py seek <engine.log> --to T --tol S
  video_net_check.py error <engine.log> --want <substring>
  video_net_check.py served <server.jsonl> [--path-re RE] [--min N] [--max N] [--status S|ok]
                            [--range-past0] [--query]
"""
import argparse
import json
import re
import sys


def fail(msg):
    print('FAIL ' + msg)
    sys.exit(1)


def ticks(log):
    out = []
    for line in open(log, errors='replace'):
        m = re.search(r'VNET tick t=(\d+) status=(\S+) ct=([\d.]+) shown=(\d+) dropped=(\d+) rate=([\d.]+)', line)
        if m:
            out.append({'t': int(m.group(1)), 'status': m.group(2), 'ct': float(m.group(3)),
                        'shown': int(m.group(4)), 'dropped': int(m.group(5)), 'rate': float(m.group(6))})
    return out


def cmd_play(a):
    tk = ticks(a.log)
    text = open(a.log, errors='replace').read()
    if 'VNET ready ' not in text:
        err = re.search(r'VNET (create_error|error) (.*)', text)
        fail('never ready' + (': ' + err.group(2)[:200] if err else ''))
    if len(tk) < a.secs:
        fail('%d ticks, want %d (the run ended early?)' % (len(tk), a.secs))
    last = tk[a.secs - 1]
    if last['status'] != 'readyToPlay':
        fail('status at t=%d is %s' % (a.secs, last['status']))
    if a.max_ct is not None and last['ct'] > a.max_ct:
        fail('currentTime %.3f at t=%d > %.3f: the source was never starved' % (last['ct'], a.secs, a.max_ct))
    if last['shown'] < a.secs * a.min_fps:
        fail('%d frames shown in %d s (want >= %.0f)' % (last['shown'], a.secs, a.secs * a.min_fps))
    pct = 100.0 * last['dropped'] / max(1, last['shown'] + last['dropped'])
    if pct > a.max_drop_pct:
        fail('framesDropped %d of %d (%.2f%% > %.2f%%)' % (last['dropped'], last['shown'] + last['dropped'],
                                                          pct, a.max_drop_pct))
    # The media clock must advance at the rate in force: compare ct deltas over
    # whole seconds that lie inside one rate segment (skip the second a change lands in).
    # A starved run (--max-ct) is not rate-checked: its clock pauses by design.
    sched = [] if a.max_ct is not None else [(0, 1.0)]
    for r in filter(None, (a.rates or '').split(',')):
        rate, when = r.split('@')
        sched.append((int(when), float(rate)))
    seek_at = a.seek_at if a.seek_at is not None else -1
    by_t = {x['t']: x for x in tk}
    checked = []
    for i, (start, rate) in enumerate(sched):
        end = sched[i + 1][0] if i + 1 < len(sched) else a.secs
        lo, hi = start + 1, end - 1  # one-second margins on both sides of a change
        if seek_at >= 0 and lo <= seek_at + 1 and hi >= seek_at:
            if seek_at - lo >= hi - seek_at - 1:
                hi = seek_at - 1
            else:
                lo = seek_at + 2
        if hi - lo < 2 or lo not in by_t or hi not in by_t:
            continue
        got = (by_t[hi]['ct'] - by_t[lo]['ct']) / (hi - lo)
        if abs(got - rate) > 0.05 * rate + 0.02:
            fail('rate %.2f over t=%d..%d: currentTime moved %.3f s per s' % (rate, lo, hi, got))
        checked.append('%.2fx=%.3f' % (rate, got))
    print('ok played %d s: shown=%d dropped=%d (%.2f%%), clock %s' % (
        a.secs, last['shown'], last['dropped'], pct, ' '.join(checked) or 'not rate-checked'))


def cmd_seek(a):
    text = open(a.log, errors='replace').read()
    m = re.findall(r'video id=\d+ seek target=([\d.]+) shown_pts=([\d.]+)', text)
    hits = [(float(t), float(p)) for t, p in m if abs(float(t) - a.to) < 1e-3]
    if not hits:
        fail('no engine seek line for target %.3f (seen: %s)' % (a.to, m[:3]))
    t, p = hits[0]
    if abs(p - a.to) > a.tol:
        fail('seek to %.3f showed the frame at %.3f (|d| > %.2f)' % (a.to, p, a.tol))
    after = [x for x in ticks(a.log) if x['ct'] >= a.to - a.tol]
    if not after:
        fail('no tick after the seek reports currentTime >= %.3f' % (a.to - a.tol))
    print('ok seek(%.3f) showed the decoded frame at pts %.3f (d=%.3f s); next tick ct=%.3f' % (
        a.to, p, p - a.to, after[0]['ct']))


def cmd_error(a):
    text = open(a.log, errors='replace').read()
    m = re.search(r'VNET (error|create_error) (.*)', text)
    if not m:
        fail('no VNET error line (status never turned error)')
    if a.want not in m.group(2):
        fail('error is %r, want it to contain %r' % (m.group(2)[:200], a.want))
    print('ok error: %s' % m.group(2)[:200])


def cmd_served(a):
    recs = [json.loads(l) for l in open(a.log) if l.strip()]
    sel = [r for r in recs if r.get('path') and re.search(a.path_re, r['path'])]
    if a.status == 'ok':
        sel = [r for r in sel if r.get('status') in (200, 206)]
    elif a.status is not None:
        sel = [r for r in sel if str(r.get('status')) == a.status]
    if a.range_past0:
        sel = [r for r in sel if r.get('status') == 206 and r.get('start', 0) > 0]
    if a.query:
        sel = [r for r in sel if r.get('query')]
    n = len(sel)
    if a.min is not None and n < a.min:
        fail('%d requests match %s (status=%s range_past0=%s), want >= %d' % (
            n, a.path_re, a.status, a.range_past0, a.min))
    if a.max is not None and n > a.max:
        fail('%d requests match %s (status=%s), want <= %d' % (n, a.path_re, a.status, a.max))
    print('ok %d requests match %s%s' % (n, a.path_re, '' if a.status is None else ' status=' + a.status))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('play')
    s.add_argument('log')
    s.add_argument('--secs', type=int, required=True)
    s.add_argument('--max-drop-pct', type=float, default=1.0)
    s.add_argument('--min-fps', type=float, default=20.0)
    s.add_argument('--max-ct', type=float)
    s.add_argument('--rates')
    s.add_argument('--seek-at', type=int)
    s = sub.add_parser('seek')
    s.add_argument('log')
    s.add_argument('--to', type=float, required=True)
    s.add_argument('--tol', type=float, default=1.0)
    s = sub.add_parser('error')
    s.add_argument('log')
    s.add_argument('--want', required=True)
    s = sub.add_parser('served')
    s.add_argument('log')
    s.add_argument('--path-re', default='.')
    s.add_argument('--min', type=int)
    s.add_argument('--max', type=int)
    s.add_argument('--status')
    s.add_argument('--range-past0', action='store_true')
    s.add_argument('--query', action='store_true')
    a = p.parse_args()
    {'play': cmd_play, 'seek': cmd_seek, 'error': cmd_error, 'served': cmd_served}[a.cmd](a)


if __name__ == '__main__':
    main()
