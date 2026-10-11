#!/usr/bin/env python3
"""ENG-13 measurer for fixtures/eng13-svg-dash (see the fixture header).

usage: svg-dash-measure.py <frame.ppm> [ARMS]
  ARMS: comma list of A..L (default: all). Prints one OK/FAIL line per arm and
  exits 1 if any arm fails. Coordinates are layout points; the scale comes from
  the PPM width (400 = 1x, 800 = Retina 2x). Ink = luma < 128 (black on white).
Pillow-free on purpose: the Mac runs this with the system python3.
"""
import sys
from collections import deque

TOL = 1.5  # layout points; absorbs AA edges at --supersample-rnsvg 4


def load(path):
    d = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        parts.append(d[i:j])
        i = j
    i += 1
    assert parts[0] == b'P6', 'not a P6 ppm'
    return int(parts[1]), int(parts[2]), d[i:]


W, H, PIX = load(sys.argv[1])
S = W / 400.0


def ink_px(px, py):
    if px < 0 or py < 0 or px >= W or py >= H:
        return False
    o = (py * W + px) * 3
    r, g, b = PIX[o], PIX[o + 1], PIX[o + 2]
    return 0.299 * r + 0.587 * g + 0.114 * b < 128


def ink(x, y):
    return ink_px(int(x * S), int(y * S))


def runs(y, x0=10, x1=390):
    """Ink runs on layout row y between x0 and x1, as (start, end) in points."""
    py = int(y * S)
    out, start = [], None
    for px in range(int(x0 * S), int(x1 * S) + 1):
        on = ink_px(px, py)
        if on and start is None:
            start = px
        elif not on and start is not None:
            out.append((start / S, px / S))
            start = None
    if start is not None:
        out.append((start / S, (int(x1 * S) + 1) / S))
    return out


def components(x0, y0, x1, y1):
    seen, n = set(), 0
    for py in range(int(y0 * S), int(y1 * S)):
        for px in range(int(x0 * S), int(x1 * S)):
            if (px, py) in seen or not ink_px(px, py):
                continue
            n += 1
            q = deque([(px, py)])
            seen.add((px, py))
            while q:
                cx, cy = q.popleft()
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        p = (cx + dx, cy + dy)
                        if (p not in seen and x0 * S <= p[0] < x1 * S
                                and y0 * S <= p[1] < y1 * S and ink_px(*p)):
                            seen.add(p)
                            q.append(p)
    return n


def near(a, b):
    return abs(a - b) <= TOL


def fmt(rs, k=6):
    return ' '.join(f'{a:.1f}-{b:.1f}' for a, b in rs[:k])


def expect_runs(y, want):
    """want: list of (start, end); the first len(want) runs must match."""
    rs = runs(y)
    if len(rs) < len(want):
        return False, f'{len(rs)} runs, want >= {len(want)}: {fmt(rs)}'
    for (a, b), (wa, wb) in zip(rs, want):
        if not (near(a, wa) and near(b, wb)):
            return False, f'runs {fmt(rs)}; want {fmt(want)}'
    return True, fmt(rs, len(want))


def solid(y):
    rs = runs(y)
    ok = len(rs) == 1 and near(rs[0][0], 20) and near(rs[0][1], 380)
    return ok, f'{len(rs)} run(s): {fmt(rs)} (want one 20-380)'


def arm_A():
    return solid(20)


def arm_B():
    rs = runs(45)
    want = [(20 + 30 * i, 40 + 30 * i) for i in range(12)]
    if len(rs) != 12:
        return False, f'{len(rs)} dashes, want 12: {fmt(rs, 14)}'
    return expect_runs(45, want)


def arm_C():
    return expect_runs(70, [(20, 35), (45, 65), (75, 95)])


def arm_D():
    ok, msg = expect_runs(95, [(25, 45), (55, 75)])
    if ok and any(ink(x, 95) for x in (20, 21, 22, 23)):
        return False, 'ink at 20-23: the -5 offset did not wrap to 25'
    return ok, msg


def arm_E():
    return expect_runs(120, [(20, 35), (40, 45), (60, 65), (70, 85), (90, 95)])


def arm_F():
    rs = runs(150, 10, 390)
    if len(rs) != 31:
        return False, f'{len(rs)} dots, want 31: {fmt(rs, 8)}'
    for k, (a, b) in enumerate(rs):
        if not near((a + b) / 2, 20 + 12 * k):
            return False, f'dot {k} centred at {(a + b) / 2:.1f}, want {20 + 12 * k}'
    return True, f'31 dots, centres 20..380 every 12'


def arm_G():
    n = sum(1 for y in (173, 175, 177) for x in range(10, 391) if ink(x, y))
    return n == 0, f'{n} ink samples on the butt-cap zero-length row (want 0)'


def arm_H():
    return solid(200)


def arm_I():
    return solid(225)


def arm_J():
    n = components(42, 272, 158, 388)
    return n == 16, f'{n} dashes around the circle (want 16)'


def arm_K():
    n = components(214, 284, 376, 376)
    corner, ctrl = ink(219, 289), ink(371, 289)
    ok = n == 11 and corner and not ctrl
    return ok, (f'{n} dashes (want 11); joined top-left corner inked={corner} '
                f'(want True); butt-ended top-right corner inked={ctrl} (want False)')


def arm_L():
    left = runs(415, 22, 200)
    right = runs(415, 222, 398)
    ok = (len(left) == 8 and len(right) == 8 and near(left[0][0], 30)
          and near(right[0][0], 240))
    return ok, (f'offset 0: {len(left)} dashes from {left[0][0] if left else None} '
                f'(want 8 from 30); offset 10: {len(right)} from '
                f'{right[0][0] if right else None} (want 8 from 240)')


def ring_ink(x0):
    # Ring box: the row starts at y=440 (400 Svg + 30 row + 10 margin).
    return sum(1 for py in range(int(440 * S), int(500 * S))
               for px in range(int(x0 * S), int((x0 + 60) * S)) if ink_px(px, py))


def arm_M():
    full, q3, q1 = ring_ink(20), ring_ink(120), ring_ink(220)
    if full == 0:
        return False, 'offset-0 ring painted nothing'
    a, b = q3 / full, q1 / full
    ok = abs(a - 0.75) <= 0.05 and abs(b - 0.25) <= 0.05
    return ok, (f'ring ink full={full} offset C/4={q3} ({a:.2f}, want 0.75) '
                f'offset 3C/4={q1} ({b:.2f}, want 0.25)')


ARMS = {k: globals()['arm_' + k] for k in 'ABCDEFGHIJKLM'}
want = sys.argv[2].split(',') if len(sys.argv) > 2 else list(ARMS)
bad = 0
for k in want:
    ok, msg = ARMS[k]()
    print(f'{"OK" if ok else "FAIL"} {k}: {msg}')
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
