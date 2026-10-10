"""SC-24 strict rule: <Button color=red title="Go"> on impeller takes the iOS
look, red title ink and no filled block. The control is an empty 60x40 view."""
from style_coverage_rules import X0, X1, Y0, Y1


def _is_red(p):
    return p[0] > 180 and p[1] < 90 and p[2] < 90


def _solid_block(feat, w, h):
    rows = [[1 if _is_red(feat.px(x, y)) else 0 for x in range(X0, X1)] for y in range(Y0, Y1)]
    run = [0] * (X1 - X0)  # per column: consecutive red rows ending at this row
    for r in rows:
        run = [run[i] + 1 if v else 0 for i, v in enumerate(r)]
        streak = 0
        for n in run:
            streak = streak + 1 if n >= h else 0
            if streak >= w:
                return True
    return False


def _button_ios_look(ctl, feat):
    ink = len(feat.points(_is_red))
    if ink < 12:
        return False, f"only {ink} red text pixels (want the title in `color`)"
    if _solid_block(feat, 30, 20):
        return False, "30x20 solid red block present (android-style filled button)"
    return True, f"{ink} red ink pixels, no solid block"


RULES = {'g2:button': _button_ios_look}
