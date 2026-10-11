"""SC-27 strict rules for grid 1 (tools/style-audit-measure.py): ScrollView
contentOffset. The 60x60 ScrollView sits at x 30..89, y 31..90; the content is a
red band then a blue band, and the offset scrolls exactly past the red band.
The overlay indicator is a thin dark bar on the right (or bottom) edge only."""


def _is_blue(p): return p[2] > 200 and p[0] < 60 and p[1] < 60


def _is_red(p): return p[0] > 200 and p[1] < 60 and p[2] < 60


def _count(px, pred, x0, x1, y0, y1):
    return sum(1 for (x, y), v in px.items() if x0 <= x <= x1 and y0 <= y <= y1 and pred(v))


def _offset_ok(c, f, edge):
    # Control: red band still visible in the first 30 px on the scrolled axis.
    if _count(c, _is_red, 30, 89, 31, 90) < 800:
        return False
    # Feature: no red anywhere, blue covers the area clear of the indicator edge.
    if _count(f, _is_red, 30, 89, 31, 90) != 0:
        return False
    x1, y1 = (82, 90) if edge == "right" else (89, 83)
    area = (x1 - 30 + 1) * (y1 - 31 + 1)
    return _count(f, _is_blue, 30, x1, 31, y1) >= area * 0.98


def offset_y_ok(c, f, d): return _offset_ok(c, f, "right")


def offset_x_ok(c, f, d): return _offset_ok(c, f, "bottom")
