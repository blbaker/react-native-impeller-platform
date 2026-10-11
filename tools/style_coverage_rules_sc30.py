"""SC-30 strict rules: <Image> with local data: sources.
Tiles 109..113 use an 8x4 PNG (columns 0-1 green, 2-5 red, 6-7 blue) in a 60x60
Image; every control stretches it, so the control proves the instrument (green
left, red middle, blue right, full height). imageBackground is a red 4x4 PNG
under black 'Hi'; its control is a grey box."""
from style_coverage_rules import X0, X1, Y0, Y1

WHITE = (255, 255, 255)


def _near(p, c, tol=6): return all(abs(a - b) <= tol for a, b in zip(p, c))


def _green(p): return p[1] > 200 and p[0] < 60 and p[2] < 60


def _red(p): return _near(p, (255, 0, 0))


def _blue(p): return p[2] > 200 and p[0] < 60 and p[1] < 60


def _ink(p): return p != WHITE


def _outside(slot, x0=0, x1=60, y0=0, y1=60):
    return [(x, y) for y in range(Y0, Y1) for x in range(X0, X1)
            if not (x0 <= x < x1 and y0 <= y < y1) and _ink(slot.px(x, y))]


def _stretch_control(ctl):
    for (x, y), want, name in (((1, 30), _green, 'green'), ((30, 30), _red, 'red'),
                               ((58, 30), _blue, 'blue'), ((1, 1), _green, 'green'),
                               ((58, 58), _blue, 'blue')):
        if not want(ctl.px(x, y)):
            return f"control (stretch) at {x},{y} is {ctl.px(x, y)}, want {name}"
    return None


def _contain(ctl, feat):
    bad = _stretch_control(ctl)
    if bad:
        return False, bad
    # 2:1 image in a 60x60 box: 60x30 at y 15..44, white bands above and below.
    band = [(x, y) for y in list(range(0, 14)) + list(range(47, 60)) for x in range(60)
            if _ink(feat.px(x, y))]
    if band:
        return False, f"{len(band)} ink px in the letterbox bands, first {band[0]}"
    for y in (17, 30, 42):
        for x, want, name in ((1, _green, 'green'), (30, _red, 'red'), (58, _blue, 'blue')):
            if not want(feat.px(x, y)):
                return False, f"{x},{y} is {feat.px(x, y)}, want {name} (image spans the full width)"
    if _outside(feat):
        return False, "ink outside the 60x60 box"
    return True, "60x30 letterboxed, full width"


def _cover(ctl, feat):
    bad = _stretch_control(ctl)
    if bad:
        return False, bad
    # Scaled 15x to 120x60 and centred: image columns 2..6 show, so no pure green.
    blank = [(x, y) for y in range(60) for x in range(60) if not _ink(feat.px(x, y))]
    if blank:
        return False, f"{len(blank)} white px inside the box (not covered), first {blank[0]}"
    if feat.points(_green, 0, 60, 0, 60):
        return False, "pure green inside: the image was not cropped"
    for y in (1, 30, 58):
        if not _red(feat.px(30, y)):
            return False, f"30,{y} is {feat.px(30, y)}, want red"
        if feat.px(0, y)[1] < 40 or feat.px(59, y)[2] < 40:
            return False, f"row {y} edges {feat.px(0, y)} / {feat.px(59, y)}: want green / blue blend"
    out = _outside(feat)
    if out:
        return False, f"{len(out)} ink px outside the box (not clipped), first {out[0]}"
    return True, "covers the box, cropped and clipped"


def _center(ctl, feat):
    bad = _stretch_control(ctl)
    if bad:
        return False, bad
    # Natural 8x4 (scale 1) centred: x 26..33, y 28..31.
    pts = feat.points(_ink)
    if not pts:
        return False, "no image ink"
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    if min(xs) < 25 or max(xs) > 34 or min(ys) < 27 or max(ys) > 32:
        return False, f"ink bbox x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}, want 26..33 x 28..31"
    for x, want, name in ((26, _green, 'green'), (29, _red, 'red'), (33, _blue, 'blue')):
        if not want(feat.px(x, 29)):
            return False, f"{x},29 is {feat.px(x, 29)}, want {name}"
    return True, f"natural size at x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}"


def _repeat(ctl, feat):
    bad = _stretch_control(ctl)
    if bad:
        return False, bad
    # Natural-size tiles from the top-left: column x shows image column x % 8.
    want = {0: _green, 1: _green, 2: _red, 3: _red, 4: _red, 5: _red, 6: _blue, 7: _blue}
    for y in (0, 2, 30, 59):
        for x in range(60):
            if not want[x % 8](feat.px(x, y)):
                return False, f"{x},{y} is {feat.px(x, y)}, want image column {x % 8}"
    if _outside(feat):
        return False, "ink outside the box"
    return True, "8 px tiles across the full box"


def _radius(ctl, feat):
    if not _ink(ctl.px(0, 0)) or not _ink(ctl.px(59, 59)):
        return False, "control (square cover) has blank corners"
    for x, y in ((2, 2), (57, 2), (2, 57), (57, 57), (5, 5)):
        if _ink(feat.px(x, y)):
            return False, f"corner {x},{y} is {feat.px(x, y)}, want white (clipped to radius 30)"
    for x, y in ((30, 30), (30, 1), (30, 58)):
        if not _red(feat.px(x, y)):
            return False, f"{x},{y} is {feat.px(x, y)}, want red inside the circle"
    if _outside(feat):
        return False, "ink outside the box"
    return True, "image clipped to the circle"


def _dark_on_red(p): return p[1] <= 6 and p[2] <= 6 and p[0] < 249


def _image_background(ctl, feat):
    if not _near(ctl.px(30, 30), (200, 200, 200), 2):
        return False, f"control centre {ctl.px(30, 30)}, want grey"
    bad = [(x, y) for y in range(60) for x in range(60)
           if not (_red(feat.px(x, y)) or _dark_on_red(feat.px(x, y)))]
    if bad:
        return False, f"{len(bad)} px neither red nor text-on-red, first {bad[0]} {feat.px(*bad[0])}"
    lower = [(x, y) for y in range(32, 60) for x in range(60) if not _red(feat.px(x, y))]
    if lower:
        return False, f"lower half not pure red at {lower[0]} {feat.px(*lower[0])}"
    text = feat.points(lambda p: p[0] < 100 and p[1] < 40 and p[2] < 40, 0, 30, 0, 30)
    if len(text) < 15:
        return False, f"only {len(text)} dark text px in the top-left, want 'Hi' over the image"
    if _outside(feat):
        return False, "ink outside the box"
    return True, f"red image edge to edge, {len(text)} text px on top"


RULES = {
    'g2:imageBackground': _image_background,
    'g2:imageContain': _contain,
    'g2:imageCover': _cover,
    'g2:imageCenter': _center,
    'g2:imageRepeat': _repeat,
    'g2:imageRadius': _radius,
}
