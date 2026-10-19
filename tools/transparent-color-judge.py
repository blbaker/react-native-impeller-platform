#!/usr/bin/env python3
"""Judge a fixtures/transparent-color render, one probe per cell.

usage: transparent-color-judge.py <frame.ppm>

The fixture is laid out in 500x500 points; the PPM may be larger (a scaled
surface), so every probe scales by width / 500. Each line printed is
  <PASS|FAIL> <cell> <kind> <name>: <value> (want <expectation>)
where kind is `feature` (a colour set to transparent), `control` (the same
thing in a real colour, so a probe that reads nothing fails) or `keep`
(already right before the fix). The last line is
  TC_CELLS pass=<n> fail=<n> failed=<cells> features_failed=<cells> wedge=<r,g,b>
Exit status: 0 when every cell passes, 1 otherwise, 2 on a bad image.
"""
import sys

BG = (0x33, 0xCC, 0x66)
SIZE = 500


def read_ppm(path):
    data = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    if parts[0] != b'P6':
        raise ValueError('not a binary PPM')
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i + 1:i + 1 + w * h * 3]


class Frame:
    def __init__(self, path):
        self.w, self.h, self.d = read_ppm(path)
        self.s = self.w / SIZE

    def px(self, x, y):
        sx, sy = int(x * self.s), int(y * self.s)
        o = (sy * self.w + sx) * 3
        return tuple(self.d[o:o + 3])

    def region(self, x0, y0, x1, y1):
        """(non-background, red, blue) pixel counts over [x0,x1) x [y0,y1) points."""
        nb = red = blue = 0
        for y in range(int(y0 * self.s), int(y1 * self.s)):
            for x in range(int(x0 * self.s), int(x1 * self.s)):
                o = (y * self.w + x) * 3
                p = self.d[o:o + 3]
                if not near(p, BG, 6):
                    nb += 1
                    red += p[0] > 150 and p[1] < 120 and p[2] < 120
                    blue += p[2] > 150 and p[0] < 120 and p[1] < 150
        return nb, red, blue


def near(a, b, tol):
    return all(abs(p - q) <= tol for p, q in zip(a, b))


def is_red(p):
    return p[0] > 200 and p[1] < 60 and p[2] < 60


def is_white(p):
    return min(p) > 230


def cells(f):
    """(cell, kind, name, value, ok, want) for every cell of the fixture."""
    out = []

    def add(cell, kind, name, value, ok, want):
        out.append((cell, kind, name, value, ok, want))

    def blank(cell, kind, name, c, r):  # a text cell must paint nothing at all
        v = f.region(100 * c + 2, 100 * r + 2, 100 * c + 98, 100 * r + 98)
        add(cell, kind, name, v, v[0] == 0, 'no non-background pixels')

    def inked(cell, name, c, r, field, label):
        v = f.region(100 * c + 2, 100 * r + 2, 100 * c + 98, 100 * r + 98)
        add(cell, 'control', name, v, v[field] > 20, f'> 20 {label} pixels')

    a, a_red = f.px(60, 20), f.px(20, 60)
    add('A', 'feature', 'border edge @(60,20)', a, near(a, BG, 6) and is_red(a_red),
        f'background, with the red edge at (20,60) (reads {a_red})')
    b, b_box = f.px(124, 50), f.px(150, 50)
    add('B', 'feature', 'outlineColor @(124,50)', b, near(b, BG, 6) and is_white(b_box), 'background, white box inside')
    c = f.px(275, 75)
    add('C', 'feature', 'shadowColor @(275,75)', c, near(c, BG, 6) and is_white(f.px(230, 30)), 'background')
    d = f.px(375, 75)
    add('D', 'feature', 'boxShadow color @(375,75)', d, near(d, BG, 6) and is_white(f.px(330, 30)), 'background')
    r = f.px(475, 75)
    add('R', 'control', 'red boxShadow @(475,75)', r, is_red(r), 'red')

    blank('E', 'feature', 'Text color', 0, 1)
    blank('F', 'feature', 'Text color nested in red Text', 1, 1)
    blank('H', 'feature', 'textShadowColor (text in the background colour)', 2, 1)
    blank('K', 'feature', 'Text color red -> transparent after mount', 3, 1)
    inked('X', 'red Text', 4, 1, 1, 'red')

    blank('N', 'feature', 'textDecorationColor under blue spaces', 0, 2)
    inked('G', 'red underline under blue spaces', 1, 2, 1, 'red')
    i = f.px(275, 275)
    add('I', 'feature', 'dropShadow color @(275,275)', i, near(i, BG, 6) and is_white(f.px(230, 230)), 'background')
    s = f.px(375, 275)
    add('S', 'control', 'red dropShadow @(375,275)', s, is_red(s), 'red')
    q, q_l, q_r = f.px(450, 250), f.px(402, 250), f.px(498, 250)
    add('Q', 'feature', 'gradient stop `transparent 50%` @(450,250)', q,
        near(q, BG, 20) and q_l[0] > 200 and q_r[2] > 200, f'background, red at the left {q_l}, blue at the right {q_r}')

    t = f.px(50, 350)
    add('T', 'control', 'gradient stop `rgba(0,0,255,0) 50%` @(50,350)', t, near(t, BG, 20), 'background')
    m = f.px(162, 335)
    add('M', 'feature', 'Switch trackColor.false @(162,335)', m, near(m, BG, 6) and is_white(f.px(135, 335)),
        'background, white thumb at (135,335)')
    w = f.px(262, 335)
    add('W', 'control', 'Switch red trackColor.false @(262,335)', w, is_red(w), 'red')
    blank('O', 'feature', 'TextInput placeholderTextColor', 3, 3)
    inked('Y', 'TextInput red placeholder', 4, 3, 1, 'red')

    j_l, j_r = f.px(12, 450), f.px(87, 450)
    add('J', 'keep', 'gradient `red, transparent` end stop', (j_l, j_r),
        j_l[0] > 200 and j_l[1] < 80 and near(j_r, BG, 20), 'red at the left, background at the right')
    p = f.px(140, 440)
    add('P', 'control', 'red box @(140,440)', p, is_red(p), 'red')
    z = f.region(200, 400, 500, 500)
    add('Z', 'control', 'empty cells read as the background', z, z[0] == 0, 'no non-background pixels')
    return out


def main():
    try:
        f = Frame(sys.argv[1])
    except (OSError, ValueError, IndexError) as e:
        print(f'TC_JUDGE_ERROR {e}')
        return 2
    res = cells(f)
    for cell, kind, name, value, ok, want in res:
        print(f"{'PASS' if ok else 'FAIL'} {cell} {kind} {name}: {value} (want {want})")
    failed = [c for c, _, _, _, ok, _ in res if not ok]
    features = [c for c, k, _, _, ok, _ in res if k == 'feature' and not ok]
    wedge = ','.join(str(v) for v in f.px(60, 20))
    print(f"TC_CELLS pass={len(res) - len(failed)} fail={len(failed)} failed={','.join(failed) or '-'} "
          f"features_failed={','.join(features) or '-'} wedge={wedge}")
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
