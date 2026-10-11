"""SC-09 strict rules: outlineWidth/Color/Style/Offset. Slot (0,0) is the element's top-left, boxes 60x60."""


def _red(p): return p[0] > 200 and p[1] < 80 and p[2] < 80
def _same(a, b): return all(abs(a[k] - b[k]) <= 6 for k in range(3))


def _dashed(ctl, feat):
    # outlineWidth 3, offset 0, dashed: the ring fills y -3..-1 above the box
    # (and x -3..-1, 60..62, y 60..62) with gaps along it. The control has none.
    if not _same(feat.px(30, 30), ctl.px(30, 30)):
        return False, "box interior changed"
    for name, pts in (("top", [(x, -2) for x in range(0, 60)]), ("bottom", [(x, 61) for x in range(0, 60)]),
                      ("left", [(-2, y) for y in range(0, 60)]), ("right", [(61, y) for y in range(0, 60)])):
        row = [_red(feat.px(x, y)) for x, y in pts]
        runs = sum(1 for i in range(1, len(row)) if row[i] and not row[i - 1]) + (1 if row[0] else 0)
        if runs < 2 or all(row) or not any(row):
            return False, f"{name} edge has {runs} dashes, red {sum(row)}/60"
    for x, y in ((30, -4), (30, 64), (-4, 30), (64, 30)):
        if not _same(feat.px(x, y), ctl.px(x, y)):
            return False, f"outside the band at {x},{y} changed: {feat.px(x, y)} vs {ctl.px(x, y)}"
    return True, "dashed ring"


def _nw_outline(ctl, feat):
    # outline-2 outline-offset-2 outline-red-500 (251,44,54): ring at 2..4 px outside.
    def near(p): return abs(p[0] - 251) < 25 and abs(p[1] - 44) < 40 and abs(p[2] - 54) < 40
    for x, y in ((30, -3), (30, 62), (-3, 30), (62, 30)):
        if not near(feat.px(x, y)):
            return False, f"band at {x},{y} not red-500: {feat.px(x, y)}"
        if not near(ctl.px(x, y)):
            return False, f"control band at {x},{y} not red: {ctl.px(x, y)}"
    for x, y in ((30, -1), (30, 60), (-1, 30), (60, 30), (30, -5), (30, 64), (-5, 30), (64, 30)):
        if near(feat.px(x, y)):
            return False, f"red outside the band at {x},{y}"
        if not _same(feat.px(x, y), ctl.px(x, y)):
            return False, f"differs from control at {x},{y}: {feat.px(x, y)} vs {ctl.px(x, y)}"
    return True, "ring in band"


RULES = {
    'g2:outlineDashed': _dashed,
    'nw:outline': _nw_outline,
}
