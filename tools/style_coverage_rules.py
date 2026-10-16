"""STRICT rules for tools/style-coverage-measure.py, plus the pixel helpers they use.

A rule is `fn(ctl, feat) -> (ok: bool, why: str)`, registered in RULES under
"<scene>:<tile id>". `ctl` and `feat` are Slot objects whose (0,0) is the
element's top-left (cell + 30,45 / cell + 150,45); the scored region is
x in [-22, 90), y in [-31, 105) around it. Write each rule so the CONTROL
slot proves the instrument (e.g. the control has the property the feature must
NOT have), and so plausible-but-wrong code fails it: check position, colour
and shape, not just "something changed". Every rule needs a mutant in
tools/mutation-verify-style-coverage.sh that it kills.
"""

CELL_W, CELL_H, PER_ROW = 240, 150, 5
X0, X1, Y0, Y1 = -22, 90, -31, 105


class Frame:
    def __init__(self, path):
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
        assert parts[0] == b'P6', f"{path}: not a P6 ppm"
        self.w, self.h = int(parts[1]), int(parts[2])
        self.px = data[i + 1:]

    def at(self, x, y):
        if x < 0 or y < 0 or x >= self.w or y >= self.h:
            return (255, 255, 255)
        o = (y * self.w + x) * 3
        return (self.px[o], self.px[o + 1], self.px[o + 2])

    def slot(self, n, which):
        cx, cy = (n % PER_ROW) * CELL_W, (n // PER_ROW) * CELL_H
        return Slot(self, cx + (30 if which == 'c' else 150), cy + 45)


class Slot:
    def __init__(self, frame, ox, oy):
        self.f, self.ox, self.oy = frame, ox, oy

    def in_frame(self):
        return self.oy + Y1 <= self.f.h and self.ox + X1 <= self.f.w

    def px(self, x, y):
        return self.f.at(self.ox + x, self.oy + y)

    def points(self, pred, x0=X0, x1=X1, y0=Y0, y1=Y1):
        return [(x, y) for y in range(y0, y1) for x in range(x0, x1) if pred(self.px(x, y))]


def diff_count(a, b):
    d = 0
    for y in range(Y0, Y1):
        for x in range(X0, X1):
            p, q = a.px(x, y), b.px(x, y)
            if abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2]) > 30:
                d += 1
    return d


def bbox(pts):
    if not pts:
        return None
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


# Colour predicates (the fixtures use pure primaries on a white page).
def is_white(p): return p[0] > 235 and p[1] > 235 and p[2] > 235
def is_ink(p): return not is_white(p)
def is_red(p): return p[0] > 180 and p[1] < 90 and p[2] < 90
def is_blue(p): return p[2] > 180 and p[0] < 90 and p[1] < 90
def is_green(p): return p[1] > 180 and p[0] < 90 and p[2] < 90
def is_dark(p): return p[0] < 80 and p[1] < 80 and p[2] < 80
def near(p, rgb, tol=24): return all(abs(p[k] - rgb[k]) <= tol for k in range(3))


# ---------------------------------------------------------------------------
# RULES. Add one entry per landed tile, next to the pass id that landed it.
# ---------------------------------------------------------------------------
def _border_alpha_over_bg(ctl, feat):
    # 60x60 blue box, 10 pt border. Control: opaque red border. Feature:
    # rgba(255,0,0,0.5) over the blue fill -> mid-edge pixel is a red/blue mix.
    c, f = ctl.px(30, 4), feat.px(30, 4)
    if not is_red(c):
        return False, f"control border not red {c}"
    if not (110 < f[0] < 200 and 60 < f[2] < 200 and f[1] < 60):
        return False, f"feature border not a red-over-blue mix {f}"
    return True, f"mix={f}"


def _text_box_style(ctl, feat):
    # Feature: border 2 + padding 6 around 'AB'. Glyph ink must start >= 7 px
    # inside the red border's outer edge, and no black ink may break the ring.
    # Control: bare text, so its ink starts at the element origin.
    ci = bbox(ctl.points(is_dark))
    if ci is None or ci[0] > 3 or ci[1] > 8:
        return False, f"control ink not at the origin {ci}"
    red = bbox(feat.points(is_red))
    if red is None:
        return False, "no red border"
    ink = bbox(feat.points(is_dark, red[0] - 2, red[2] + 3, red[1] - 2, red[3] + 3))
    if ink is None:
        return False, "no glyph ink"
    dx, dy = ink[0] - red[0], ink[1] - red[1]
    if dx < 7 or dy < 7:
        return False, f"ink starts {dx},{dy} inside the border (need >= 7) ink={ink} red={red}"
    for x in range(red[0] + 10, red[2] - 9):
        for y in (red[1], red[1] + 1, red[3] - 1, red[3]):
            if is_dark(feat.px(x, y)):
                return False, f"black ink on the top/bottom ring at {x},{y}"
    for y in range(red[1] + 10, red[3] - 9):
        for x in (red[0], red[0] + 1, red[2] - 1, red[2]):
            if is_dark(feat.px(x, y)):
                return False, f"black ink on the side ring at {x},{y}"
    return True, f"ink inset={dx},{dy}"


def _ti_padding(ctl, feat):
    # Feature: paddingLeft 30. Glyph ink starts 30 +/- 3 px right of the control's.
    ci, fi = bbox(ctl.points(is_dark)), bbox(feat.points(is_dark))
    if ci is None or fi is None:
        return False, f"no glyph ink ctl={ci} feat={fi}"
    dx = fi[0] - ci[0]
    if abs(dx - 30) > 3:
        return False, f"ink shifted {dx} px (need 30 +/- 3) ctl={ci} feat={fi}"
    return True, f"ink shift={dx}"


def _border_no_color(ctl, feat):
    # Feature: 60x60 white box, borderWidth 4, no colour. Control: same box, no border.
    # Every edge midpoint must be dark and the interior must stay white.
    for name, (x, y) in {'top': (30, 1), 'bottom': (30, 58), 'left': (1, 30), 'right': (58, 30)}.items():
        if not is_dark(feat.px(x, y)):
            return False, f"{name} edge not dark {feat.px(x, y)}"
        if not is_white(ctl.px(x, y)):
            return False, f"control {name} edge not white {ctl.px(x, y)}"
    if not is_white(feat.px(30, 30)):
        return False, f"interior not white {feat.px(30, 30)}"
    return True, f"top={feat.px(30, 1)}"


def _run(slot, x, y, dx, dy, pred, limit=40):
    n = 0
    while n < limit and pred(slot.px(x + dx * n, y + dy * n)):
        n += 1
    return n


def _rounded_edges(ctl, feat, top, left, right, bottom, top_w, left_w):
    # Outer corner pixels stay background in both slots (the radius survives),
    # each edge midpoint has its colour, and the top/left thickness matches.
    for name, s in (('control', ctl), ('feature', feat)):
        for cx, cy in ((0, 0), (59, 0), (0, 59), (59, 59)):
            if not is_white(s.px(cx, cy)):
                return False, f"{name} corner {cx},{cy} not background {s.px(cx, cy)}"
    for name, pred, pt in (('top', top, (30, 1)), ('left', left, (1, 30)),
                           ('right', right, (58, 30)), ('bottom', bottom, (30, 58))):
        if not pred(feat.px(*pt)):
            return False, f"{name} edge wrong colour {feat.px(*pt)} at {pt}"
    tw = _run(feat, 30, 0, 0, 1, top)
    lw = _run(feat, 0, 30, 1, 0, left)
    if abs(tw - top_w) > 1 or abs(lw - left_w) > 1:
        return False, f"thickness top={tw} (want {top_w}) left={lw} (want {left_w})"
    return True, f"top={tw} left={lw}"


def _radius_uneven_width(ctl, feat):
    # Control: uniform 4 blue. Feature: 2 all round, 12 on top, all blue.
    return _rounded_edges(ctl, feat, is_blue, is_blue, is_blue, is_blue, 12, 2)


def _rounded_per_side(ctl, feat):
    # Feature: top 8 red, left 4 green, right 4 black, bottom 4 blue.
    return _rounded_edges(ctl, feat, is_red, is_green, is_dark, is_blue, 8, 4)


def _ring(w, h, r, inset):
    # Integer points along the centre line of a w x h rounded rect, clockwise.
    x0, y0, x1, y1, c = inset, inset, w - 1 - inset, h - 1 - inset, max(r - inset, 0)
    import math
    pts = [(x, y0) for x in range(x0 + c, x1 - c + 1)]
    n = max(int(math.pi / 2 * c), 1) if c else 0
    arcs = ((x1 - c, y0 + c, -90), (x1 - c, y1 - c, 0), (x0 + c, y1 - c, 90), (x0 + c, y0 + c, 180))
    sides = (((x1, y) for y in range(y0 + c, y1 - c + 1)), ((x, y1) for x in range(x1 - c, x0 + c - 1, -1)),
             ((x0, y) for y in range(y1 - c, y0 + c - 1, -1)), iter(()))
    for (cx, cy, a0), side in zip(arcs, sides):
        pts += [(round(cx + c * math.cos(math.radians(a0 + 90 * i / n))),
                 round(cy + c * math.sin(math.radians(a0 + 90 * i / n)))) for i in range(1, n)] if n else []
        pts += list(side)
    return pts


def _runs(slot, pts, pred):
    # Lengths of the consecutive runs of ring points whose pixel satisfies pred.
    runs, cur = [], 0
    for x, y in pts:
        if pred(slot.px(x, y)):
            cur += 1
        elif cur:
            runs.append(cur); cur = 0
    if cur:
        runs.append(cur)
    return [n for n in runs if n >= 3]


def _dashed_ring(ctl, feat, r, top_pred, top_label, ctl_solid=True):
    ring = _ring(60, 60, r, 2)
    if ctl_solid and _runs(ctl, ring, is_white):
        return False, f"control ring has a gap {_runs(ctl, ring, is_white)}"
    if not ctl_solid and top_pred(ctl.px(30, 2)):
        return False, f"control top edge already {top_label}"
    gaps, inks = _runs(feat, ring, is_white), _runs(feat, ring, is_ink)
    if len(gaps) < 6 or len(inks) < 6:
        return False, f"ring gaps={len(gaps)} dashes={len(inks)} (need >= 6 each)"
    for name, s in (('control', ctl), ('feature', feat)):
        for cx, cy in (((0, 0), (59, 0), (0, 59), (59, 59)) if r else ()):
            if not is_white(s.px(cx, cy)):
                return False, f"{name} corner {cx},{cy} not background {s.px(cx, cy)}"
    row = [(x, 2) for x in range(r, 60 - r)]
    if not _runs(feat, row, is_white):
        return False, "top edge has no gap"
    if not _runs(feat, row, top_pred):
        return False, f"top edge dashes are not {top_label}"
    return True, f"gaps={len(gaps)} dashes={len(inks)}"


def _dashed_rounded(ctl, feat):
    # Feature: dashed black 4 px border, radius 16. Control: the same border solid.
    return _dashed_ring(ctl, feat, 16, is_dark, 'black')


def _dashed_per_side_color(ctl, feat):
    # Feature: square dashed border, black except a red top. Control: all black dashed.
    ok, why = _dashed_ring(ctl, feat, 0, is_red, 'red', ctl_solid=False)
    if not ok:
        return ok, why
    col = [(57, y) for y in range(6, 54)]
    if not _runs(feat, col, is_dark) or _runs(feat, col, is_red):
        return False, "right edge dashes are not black"
    return True, why


def _elliptical_radius(ctl, feat):
    # 90x45 blue box. Control: square. Feature: borderRadius '50%' = a 45 x 22.5 ellipse.
    import math
    if not is_blue(ctl.px(0, 0)) or not is_blue(ctl.px(89, 44)):
        return False, "control is not a square box"
    for cx, cy in ((0, 0), (89, 0), (0, 44), (89, 44)):
        if not is_white(feat.px(cx, cy)):
            return False, f"bbox corner {cx},{cy} not background {feat.px(cx, cy)}"
    for deg in range(0, 360, 15):
        a = math.radians(deg)
        x, y = round(44.5 + 44 * math.cos(a)), round(22 + 21 * math.sin(a))
        if not is_blue(feat.px(x, y)):
            return False, f"ellipse point {x},{y} (deg {deg}) not blue {feat.px(x, y)}"
    # A capsule (both radii clamped to 22.5) passes the inside checks, so also demand
    # background just outside the ellipse where the capsule would still be filled.
    for deg in (30, 45, 60, 120, 135, 150, 210, 225, 240, 300, 315, 330):
        a = math.radians(deg)
        x, y = round(44.5 + 48 * math.cos(a)), round(22 + 23 * math.sin(a))
        if 0 <= x < 90 and 0 <= y < 45 and not is_white(feat.px(x, y)):
            return False, f"point {x},{y} outside the ellipse (deg {deg}) is painted {feat.px(x, y)}"
    for x in (0, 89):
        if not is_blue(feat.px(x, 22)):
            return False, f"extreme {x},22 not blue: ellipse does not reach the box side"
        for y in (6, 38):
            if is_blue(feat.px(x, y)):
                return False, f"{x},{y} blue: radii are not elliptical"
    return True, "ellipse ok"


def _border_curve(ctl, feat):
    # 60x60 radius 24. Control circular; feature continuous. They may differ only in the corner bands.
    def in_corner(x, y):
        return (x < 24 or x >= 36) and (y < 24 or y >= 36)
    out = [(x, y) for y in range(Y0, Y1) for x in range(X0, X1)
           if sum(abs(a - b) for a, b in zip(ctl.px(x, y), feat.px(x, y))) > 30 and not in_corner(x, y)]
    if out:
        return False, f"{len(out)} differing pixels outside the corner bands, first {out[0]}"
    if not is_white(ctl.px(0, 0)) or not is_white(feat.px(0, 0)):
        return False, "corner pixel 0,0 is not background"
    per = [sum(1 for y in range(ys, ys + 24) for x in range(xs, xs + 24)
               if sum(abs(a - b) for a, b in zip(ctl.px(x, y), feat.px(x, y))) > 30)
           for xs, ys in ((0, 0), (36, 0), (0, 36), (36, 36))]
    if min(per) < 6:
        return False, f"corner diffs {per}: every corner must differ from the circular control"
    if not (is_blue(feat.px(30, 1)) and is_blue(feat.px(1, 30)) and is_blue(feat.px(30, 58))):
        return False, "edge midpoints not blue"
    return True, f"corner diffs {per}"


RULES = {
    # SC-06
    'g2:ellipticalRadius': _elliptical_radius,
    'g2:borderCurve': _border_curve,
    # SC-05
    'g2:dashedRounded': _dashed_rounded,
    'g2:dashedPerSideColor': _dashed_per_side_color,
    # SC-04
    'g2:radiusUnevenWidth': _radius_uneven_width,
    'g2:roundedPerSideWidthColor': _rounded_per_side,
    # SC-03
    'g2:borderNoColor': _border_no_color,
    # SC-02
    'g2:tiPadding': _ti_padding,
    # SC-01
    'g2:textBoxStyle': _text_box_style,
    # SC-00 (harness example; already correct on 095dcba)
    'g2:borderAlphaOverBg': _border_alpha_over_bg,
}


import os as _os, sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from style_coverage_rules_sc07 import RULES as _SC07  # noqa: E402
RULES.update(_SC07)
from style_coverage_rules_sc08 import RULES as _SC08  # noqa: E402
RULES.update(_SC08)
from style_coverage_rules_sc09 import RULES as _SC09  # noqa: E402
RULES.update(_SC09)
from style_coverage_rules_sc10 import RULES as _SC10  # noqa: E402
RULES.update(_SC10)
from style_coverage_rules_sc11 import RULES as _SC11  # noqa: E402
RULES.update(_SC11)
from style_coverage_rules_sc12 import RULES as _SC12  # noqa: E402
RULES.update(_SC12)
from style_coverage_rules_sc14 import RULES as _SC14  # noqa: E402
RULES.update(_SC14)
from style_coverage_rules_sc15 import RULES as _SC15  # noqa: E402
RULES.update(_SC15)
from style_coverage_rules_sc17 import RULES as _SC17  # noqa: E402
RULES.update(_SC17)
from style_coverage_rules_sc18 import RULES as _SC18  # noqa: E402
RULES.update(_SC18)
from style_coverage_rules_sc19 import RULES as _SC19  # noqa: E402
RULES.update(_SC19)
from style_coverage_rules_sc20 import RULES as _SC20  # noqa: E402
RULES.update(_SC20)
from style_coverage_rules_sc22 import RULES as _SC22  # noqa: E402
RULES.update(_SC22)
from style_coverage_rules_sc24 import RULES as _SC24  # noqa: E402
RULES.update(_SC24)
from style_coverage_rules_sc27 import RULES as _SC27  # noqa: E402
RULES.update(_SC27)
from style_coverage_rules_sc30 import RULES as _SC30  # noqa: E402
RULES.update(_SC30)
from style_coverage_rules_sc33 import RULES as _SC33  # noqa: E402
RULES.update(_SC33)
from style_coverage_rules_sc34 import RULES as _SC34  # noqa: E402
RULES.update(_SC34)
