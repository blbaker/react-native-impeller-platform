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


RULES = {
    # SC-03
    'g2:borderNoColor': _border_no_color,
    # SC-02
    'g2:tiPadding': _ti_padding,
    # SC-01
    'g2:textBoxStyle': _text_box_style,
    # SC-00 (harness example; already correct on bf7be0f)
    'g2:borderAlphaOverBg': _border_alpha_over_bg,
}
