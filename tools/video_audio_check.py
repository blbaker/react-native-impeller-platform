#!/usr/bin/env python3
"""Checks for tools/ci-video-audio.sh. PCM files are raw S16LE stereo 48 kHz.
Each subcommand prints `ok ...` lines and exits 0, or `FAIL <rule>` and exits 1.

  tone <pcm> --log <engine.log> --secs N     real alsa-lib (file plugin) capture: a
        440 Hz FFT peak, length ~N s (the fixture pauses at N), audioFrames agrees
  ref <pcm> --start-a A --start-v V -o <json> marker media decoded by the ffmpeg CLI:
        gap onsets as VIDEO media time (raw index 0 = audio pts A; media 0 = video pts V)
  sync <capture> --log <engine.log> --ref <json>  paced-device capture (frame k heard at
        t0 + k/48000, t0 in <capture>.t0): every gap heard while rate 1 lands within
        100 ms of the video clock; silent while rate != 1 and while paused; sound
        back after each
  noaudio <engine.log> --want <prefix> --secs N   stats.audio is the error string and
        the video kept its rate: ct ~ N, framesDropped <= 1%
"""
import argparse
import cmath
import json
import math
import re
import struct
import sys

RATE = 48000
WIN = 96  # 2 ms RMS windows
LOUD = 500.0  # the fixture tone's RMS is ~2900; AAC silence decodes to ~0


def fail(msg):
    print('FAIL ' + msg)
    sys.exit(1)


def left(path):
    data = open(path, 'rb').read()
    n = len(data) // 4
    return struct.unpack('<%dh' % (2 * n), data[:4 * n])[0::2]


def rms_windows(x):
    out = []
    for i in range(0, len(x) - WIN + 1, WIN):
        s = 0
        for v in x[i:i + WIN]:
            s += v * v
        out.append(math.sqrt(s / WIN))
    return out


def gaps(x):
    """[(onset sample, length s)] of silences 30-200 ms long with sound on both sides."""
    r = rms_windows(x)
    out, i = [], 0
    while i < len(r):
        if r[i] >= LOUD:
            i += 1
            continue
        j = i
        while j < len(r) and r[j] < LOUD:
            j += 1
        ln = (j - i) * WIN / RATE
        if i > 0 and j < len(r) and 0.03 <= ln <= 0.2:
            out.append((i * WIN, ln))
        i = j
    return out


def fft(a):
    n = len(a)
    if n == 1:
        return a
    ev, od = fft(a[0::2]), fft(a[1::2])
    t = [cmath.exp(-2j * math.pi * k / n) * od[k] for k in range(n // 2)]
    return [ev[k] + t[k] for k in range(n // 2)] + [ev[k] - t[k] for k in range(n // 2)]


def peak_hz(x):
    n = 8192
    seg = x[len(x) // 2 - n // 2:len(x) // 2 + n // 2]
    w = [seg[i] * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) for i in range(n)]
    m = [abs(c) for c in fft([complex(v) for v in w])[:n // 2]]
    k = max(range(1, n // 2 - 1), key=lambda i: m[i])
    a, b, c = m[k - 1], m[k], m[k + 1]
    d = 0.5 * (a - c) / (a - 2 * b + c) if (a - 2 * b + c) != 0 else 0
    med = sorted(m)[len(m) // 2] or 1e-9
    return (k + d) * RATE / n, b / med


def samples(log):
    out = []
    for line in open(log, errors='replace'):
        m = re.search(r'VAUD s wall=(\d+) ct=([\d.]+) rate=([\d.]+) playing=(\w+) audio=("[^"]*") af=(\d+) '
                      r'shown=(\d+) dropped=(\d+)', line)
        if m:
            out.append({'wall': int(m.group(1)), 'ct': float(m.group(2)), 'rate': float(m.group(3)),
                        'playing': m.group(4) == 'true', 'audio': json.loads(m.group(5)), 'af': int(m.group(6)),
                        'shown': int(m.group(7)), 'dropped': int(m.group(8))})
    return out


def events(log, kind):
    return [int(m.group(1)) for m in re.finditer(r'VAUD %s at=\S+ (?:to=\S+ )?wall=(\d+)' % kind,
                                                 open(log, errors='replace').read())]


def done(log):
    m = re.search(r'VAUD done shown=(\d+) dropped=(\d+) ct=([\d.]+) af=(\d+) audio=("[^"]*")',
                  open(log, errors='replace').read())
    if not m:
        text = open(log, errors='replace').read()
        err = re.search(r'VAUD (create_error|error) (.*)', text)
        fail('no done line' + (': ' + err.group(2)[:200] if err else ''))
    return {'shown': int(m.group(1)), 'dropped': int(m.group(2)), 'ct': float(m.group(3)), 'af': int(m.group(4)),
            'audio': json.loads(m.group(5))}


def cmd_tone(a):
    d = done(a.log)
    x = left(a.pcm)
    sec = len(x) / RATE
    if not a.secs - 0.5 <= sec <= a.secs + 0.3:
        fail('captured %.2f s of sound, want %d s (-0.5/+0.3)' % (sec, a.secs))
    hz, ratio = peak_hz(x)
    if abs(hz - 440) > 3 or ratio < 1000:
        fail('FFT peak %.1f Hz (peak/median %.0f), want 440 Hz (+-3) standing out (>= 1000)' % (hz, ratio))
    if abs(d['af'] / RATE - sec) > 0.3:
        fail('audioFrames %d (%.2f s) disagrees with the %.2f s the device got' % (d['af'], d['af'] / RATE, sec))
    if d['audio'] != 'on':
        fail('stats.audio %r at the end, want "on"' % d['audio'])
    print('ok tone: %.2f s captured through alsa-lib, FFT peak %.1f Hz (peak/median %.0f), audioFrames %.2f s'
          % (sec, hz, ratio, d['af'] / RATE))


def cmd_ref(a):
    x = left(a.pcm)
    out = [{'media': a.start_a + i / RATE - a.start_v, 'len': ln} for i, ln in gaps(x)]
    if len(out) < 10:
        fail('reference decode has %d marker gaps' % len(out))
    json.dump(out, open(a.o, 'w'))
    print('ok ref: %d marker gaps, first at media %.3f' % (len(out), out[0]['media']))


def ct_at(ss, wall):
    """The video clock at `wall`, interpolated between samples that share a rate and play state."""
    for p, q in zip(ss, ss[1:]):
        if p['wall'] <= wall <= q['wall'] and p['playing'] and q['playing'] and p['rate'] == q['rate'] == 1:
            if q['wall'] - p['wall'] > 400:
                return None
            return p['ct'] + (q['ct'] - p['ct']) * (wall - p['wall']) / max(1, q['wall'] - p['wall'])
    return None


def loud_frac(x, t0, w0, w1):
    a, b = int((w0 - t0) / 1000 * RATE), int((w1 - t0) / 1000 * RATE)
    r = rms_windows(x[max(0, a):max(0, b)])
    return (sum(1 for v in r if v >= LOUD) / len(r)) if r else 0.0, (max(r) if r else 0.0)


def cmd_sync(a):
    ss, d = samples(a.log), done(a.log)
    ref = json.load(open(a.ref))
    t0 = float(open(a.capture + '.t0').read())
    x = left(a.capture)
    offs = []
    for i, ln in gaps(x):
        wall = t0 + i * 1000 / RATE
        ct = ct_at(ss, wall)
        if ct is None:
            continue
        k = round((ln - 0.05) / 0.025) % 4  # the gap's length codes its second mod 4
        cand = [r for r in ref if round((r['len'] - 0.05) / 0.025) % 4 == k]
        if not cand:
            continue
        r = min(cand, key=lambda r: abs(r['media'] - ct))
        offs.append(ct - r['media'])
    if len(offs) < a.min_gaps:
        fail('only %d marker gaps heard while playing at rate 1, want >= %d' % (len(offs), a.min_gaps))
    worst = max(offs, key=abs)
    if abs(worst) > 0.1:
        fail('A/V offset %+.0f ms on a marker (want within 100 ms of the video clock); all: %s'
             % (worst * 1000, ' '.join('%+.0f' % (o * 1000) for o in offs)))
    print('ok sync: %d markers, A/V offset median %+.0f ms, worst %+.0f ms'
          % (len(offs), sorted(offs)[len(offs) // 2] * 1000, worst * 1000))
    rates, pause, play = events(a.log, 'rate'), events(a.log, 'pause'), events(a.log, 'play')
    if len(rates) != 2 or len(pause) != 1 or len(play) != 1:
        fail('scenario lines: %d rate, %d pause, %d play (want 2/1/1)' % (len(rates), len(pause), len(play)))
    for name, w0, w1 in (('rate 0.6', rates[0], rates[1]), ('paused', pause[0], play[0])):
        # 250 ms for the change to reach the sound thread; 50 ms before the end
        # because the device's 5 ms ticks stamp a frame up to one tick early.
        frac, peak = loud_frac(x, t0, w0 + 250, w1 - 50)
        if peak >= LOUD:
            fail('%s: sound heard (peak RMS %.0f, %.0f%% of 2 ms windows loud), want silence' % (name, peak, frac * 100))
        frac, _ = loud_frac(x, t0, w1 + 300, w1 + 900)
        if frac < 0.5:
            fail('%s: sound not back within 0.3 s after it ended (%.0f%% loud)' % (name, frac * 100))
        print('ok %s: silent for %.1f s, sound back after it' % (name, (w1 - w0 - 250) / 1000))
    muted = [s for s in ss if s['wall'] > rates[0] + 200 and s['wall'] < rates[1]]
    if not muted or any(s['audio'] != 'muted' for s in muted):
        fail('stats.audio while rate 0.6: %s, want "muted"' % sorted({s['audio'] for s in muted}))
    if d['shown'] and d['dropped'] > 0.01 * (d['shown'] + d['dropped']):
        fail('framesDropped %d of %d' % (d['dropped'], d['shown'] + d['dropped']))
    print('ok status: "muted" while rate 0.6, framesDropped %d' % d['dropped'])


def cmd_noaudio(a):
    ss, d = samples(a.log), done(a.log)
    if not d['audio'].startswith('error: ' + a.want):
        fail('stats.audio %r, want "error: %s..."' % (d['audio'], a.want))
    if not a.secs - 0.6 <= d['ct'] <= a.secs + 0.2:
        fail('video clock %.3f after %d s at rate 1 (the video stalled or ran fast)' % (d['ct'], a.secs))
    if d['dropped'] > 0.01 * (d['shown'] + d['dropped']):
        fail('framesDropped %d of %d with no sound device' % (d['dropped'], d['shown'] + d['dropped']))
    if d['shown'] < 29 * a.secs * a.fps / 30:
        fail('framesShown %d in %d s, want ~%d' % (d['shown'], a.secs, a.secs * a.fps))
    late = [s for s in ss if s['playing'] and not s['audio'].startswith('error: ')]
    if a.was_on and sum(1 for s in late if s['audio'] == 'on') < a.was_on:
        fail('only %d samples with stats.audio "on" before the error, want >= %d (sound never ran?)'
             % (sum(1 for s in late if s['audio'] == 'on'), a.was_on))
    print('ok noaudio: %r; ct %.3f after %d s, shown %d dropped %d (%d samples before the error showed)'
          % (d['audio'], d['ct'], a.secs, d['shown'], d['dropped'], len(late)))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('tone'); p.add_argument('pcm'); p.add_argument('--log', required=True)
    p.add_argument('--secs', type=int, required=True)
    p = sub.add_parser('ref'); p.add_argument('pcm'); p.add_argument('--start-a', type=float, required=True)
    p.add_argument('--start-v', type=float, required=True); p.add_argument('-o', required=True)
    p = sub.add_parser('sync'); p.add_argument('capture'); p.add_argument('--log', required=True)
    p.add_argument('--ref', required=True); p.add_argument('--min-gaps', type=int, default=8)
    p = sub.add_parser('noaudio'); p.add_argument('log'); p.add_argument('--want', required=True)
    p.add_argument('--secs', type=int, required=True); p.add_argument('--fps', type=int, default=30)
    p.add_argument('--was-on', type=int, default=0)
    a = ap.parse_args()
    {'tone': cmd_tone, 'ref': cmd_ref, 'sync': cmd_sync, 'noaudio': cmd_noaudio}[a.cmd](a)


if __name__ == '__main__':
    main()
