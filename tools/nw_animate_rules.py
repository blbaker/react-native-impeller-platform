#!/usr/bin/env python3
"""SC-26 rules for tools/ci-nw-animate.sh: read one capture of
fixtures/sc26-nw-animate and judge each tile against its control or against
the time read off the ref box. Prints `PASS <tile> ...` / `FAIL <tile> ...`
lines and exits 1 on any FAIL.   usage: nw_animate_rules.py <capture.ppm>
"""
import math
import sys


def load(path):
    d = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i + 1:]


W, H, PX = load(sys.argv[1])


def px(x, y):
    o = (y * W + x) * 3
    return tuple(PX[o:o + 3])


def ink(x0, y0, x1, y1):
    """Pixels in [x0,x1) x [y0,y1) that are not white."""
    return {(x, y) for y in range(y0, y1) for x in range(x0, x1) if min(px(x, y)) < 200}


fails = []


def verdict(tile, ok, msg):
    print(('PASS' if ok else 'FAIL') + f' {tile}: {msg}')
    if not ok:
        fails.append(tile)


RED = (251, 44, 54)
BLUE = (43, 127, 255)


def near(c, ref, tol):
    return max(abs(a - b) for a, b in zip(c, ref)) <= tol


# --- Row A: paused keyframes (deterministic) -------------------------------
ctl = ink(0, 0, 100, 100)
verdict('ctl', len(ctl) > 3000 and near(px(50, 50), RED, 6), f'control square ink={len(ctl)} centre={px(50, 50)}')

# spinPaused: a 60 px square turned 45 deg about (150,50) is a diamond with
# half-diagonal 42.4: its axis tips are ink, the unrotated corners are not.
tips = [(150, 10), (150, 90), (110, 50), (190, 50)]
corners = [(122, 22), (178, 22), (122, 78), (178, 78)]
t_ok = all(near(px(x, y), RED, 30) for x, y in tips)
c_ok = all(min(px(x, y)) > 240 for x, y in corners)
sp = ink(100, 0, 200, 100)
verdict('spinPaused', t_ok and c_ok and abs(len(sp) - len(ctl)) < 300,
        f'tips {[px(x, y) for x, y in tips]} corners {[px(x, y) for x, y in corners]} ink={len(sp)} vs ctl {len(ctl)}')

# pulsePaused: opacity 0.5 over white = halfway between red-500 and white.
half = tuple(round((c + 255) / 2) for c in RED)
pc = px(250, 50)
verdict('pulsePaused', near(pc, half, 8) and len(ink(200, 0, 300, 100)) == len(ctl),
        f'centre {pc}, want {half} (opacity 0.5)')

# --- Row C: the clock ------------------------------------------------------
def box_left(k):
    y = 230 + 22 * k + 8
    xs = [x for x in range(0, W) if px(x, y)[2] > 200 and px(x, y)[0] < 120]
    return (min(xs) - 20) if xs else None


ref = box_left(0)
E = None if ref is None else ref / 200 * 60000
verdict('ref', E is not None and 4000 <= E <= 56000, f'ref translateX={ref} -> elapsed {E and round(E)} ms (want 4..56 s, mid-flight)')
if E is None:
    print('ELAPSED unknown')
    sys.exit(1)
print(f'ELAPSED {round(E)} ms')


def expect(tile, k, want, tol=8):
    got = box_left(k)
    verdict(tile, got is not None and abs(got - want) <= tol, f'translateX={got}, want {want:.1f} +-{tol} at {round(E)} ms')


expect('seq', 1, 200 * (1 - (E - 1000) / 60000))
n, ph = divmod(E, 12000)
expect('repeat', 2, 200 * (1 - ph / 12000) if int(n) % 2 else 200 * ph / 12000, 10)
expect('delay', 3, 200 * max(0.0, E - 10000) / 60000)
w = math.sqrt(0.00704)
wt = w * E / 1000
expect('spring', 4, 200 * (1 - (1 + wt) * math.exp(-wt)))

op = 1 - 0.8 * E / 60000
want = round(255 * (1 - op))
got = px(50, 230 + 22 * 5 + 8)
verdict('inline', got[2] > 245 and abs(got[0] - want) <= 10, f'fade box {got}: red channel {got[0]}, want {want} (opacity {op:.2f})')

# --- Row B: transition-colors ---------------------------------------------
f = E / 60000
mixc = tuple(round(r + (b - r) * f) for r, b in zip(RED, BLUE))
tc = px(50, 150)
verdict('transitionColors', near(tc, mixc, 14) and not near(tc, BLUE, 30) and not near(tc, RED, 30),
        f'box {tc}, want {mixc} ({f:.2f} of red-500 -> blue-500)')

sys.exit(1 if fails else 0)
