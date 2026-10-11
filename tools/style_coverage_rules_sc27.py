"""SC-27 strict rule: ScrollView indicator. A 60x60 grey ScrollView with a
200 px tall child. The control hides the indicator; the feature shows a thin dark
bar on the right edge, at the top (offset 0), about 60 * 60 / 200 = 18 px long."""
from style_coverage_rules import X0, X1, Y0, Y1


def _dark(p): return sum(p) / 3 < 160 and abs(p[0] - p[2]) < 30


def _indicator(ctl, feat):
    # Blue chip is at x 0..19, so only the right half can hold the bar.
    if ctl.points(_dark, 20, 60, 0, 60):
        return False, "control (indicator off) has dark ink in the viewport"
    pts = feat.points(_dark, 20, 60, 0, 60)
    if not pts:
        return False, "no dark indicator ink in the viewport"
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    if min(xs) < 50 or max(xs) > 59:
        return False, f"bar columns {min(xs)}..{max(xs)}, want the right edge (50..59)"
    if max(xs) - min(xs) + 1 > 5:
        return False, f"bar {max(xs) - min(xs) + 1} px wide, want a thin bar"
    if min(ys) > 6:
        return False, f"bar starts at y={min(ys)}, want the top at offset 0"
    length = max(ys) - min(ys) + 1
    if not 14 <= length <= 22:
        return False, f"bar {length} px long, want ~18 (viewport/content)"
    if feat.points(_dark, 0, 50, Y0, 0) or feat.points(_dark, 60, X1, Y0, Y1):
        return False, "dark ink outside the viewport"
    return True, f"bar x {min(xs)}..{max(xs)} y {min(ys)}..{max(ys)}, {length} px long"


RULES = {'g2:scrollIndicator': _indicator}
