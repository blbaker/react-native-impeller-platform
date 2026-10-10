"""SC-07 strict rules: background layers, colour under gradient, colour hints, radial gradients."""
# Slot (0,0) is the element's top-left; the fixture boxes are 60x60.


def _green(p): return p[1] > 180 and p[0] < 90 and p[2] < 90


def _over_bg_color(ctl, feat):
    # Control: plain green. Feature: red->transparent over green, so the right
    # edge shows the green background and the left edge is red.
    if not _green(ctl.px(30, 30)):
        return False, f"control not green {ctl.px(30, 30)}"
    r, l = feat.px(57, 30), feat.px(2, 30)
    if not _green(r):
        return False, f"right edge not green (bg under the gradient missing) {r}"
    if not (l[0] > 180 and l[1] < 90):
        return False, f"left edge not red {l}"
    return True, f"right={r} left={l}"


def _layers(ctl, feat):
    # Feature: a dark-to-clear top layer over red->blue, so the top row is
    # darker than the bottom row at the same x. The control has no vertical change.
    for x in (10, 30, 50):
        c_top, c_bot = sum(ctl.px(x, 3)), sum(ctl.px(x, 56))
        if abs(c_top - c_bot) > 30:
            return False, f"control varies vertically at x={x}"
        t, b = sum(feat.px(x, 3)), sum(feat.px(x, 56))
        if t > b - 150:
            return False, f"top row not darker than bottom at x={x}: {feat.px(x, 3)} vs {feat.px(x, 56)}"
    return True, f"top={feat.px(30, 3)} bottom={feat.px(30, 56)}"


def _color_hint(ctl, feat):
    # Hint at 15%: the midpoint is already blue-dominant, and no colour in the
    # box is a washed-out near-white (a hint read as a transparent stop gives that).
    c, m = ctl.px(30, 30), feat.px(30, 30)
    if abs(c[0] - c[2]) > 60:
        return False, f"control midpoint not a red/blue mix {c}"
    if m[2] < m[0] + 80:
        return False, f"feature midpoint not blue-dominant {m}"
    for y in range(0, 60):
        for x in range(0, 60):
            p = feat.px(x, y)
            if p[0] > 200 and p[1] > 200 and p[2] > 200:
                return False, f"near-white pixel at {x},{y}: {p}"
    return True, f"mid={m}"


def radial_ok(slot, size=60):
    c = size // 2
    mid = slot.px(c, c)
    if not (mid[0] > mid[2] + 100):
        return False, f"centre not red-dominant {mid}"
    corners = [slot.px(x, y) for x, y in ((1, 1), (size - 2, 1), (1, size - 2), (size - 2, size - 2))]
    for p in corners:
        if not (p[2] > p[0] + 100):
            return False, f"corner not blue-dominant {p}"
    for k in range(3):
        vals = [p[k] for p in corners]
        if max(vals) - min(vals) > 6:
            return False, f"corners not symmetric (channel {k}): {corners}"
    return True, f"centre={mid} corner={corners[0]}"


def _radial_nw(ctl, feat):
    ok, why = radial_ok(ctl)
    if not ok:
        return False, f"control: {why}"
    return radial_ok(feat)


RULES = {
    'g2:gradientOverBgColor': _over_bg_color,
    'g2:gradientLayers': _layers,
    'g2:gradientColorHint': _color_hint,
    'nw:gradientRadial': _radial_nw,
}
