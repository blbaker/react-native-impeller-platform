"""SC-33 strict rules for grid 1 (tools/style-audit-measure.py): letterSpacing and
fontVariant tabular-nums. Slots are 120 x 136 dicts of (x, y) -> rgb, black 20 pt text.
letterSpacing: 'IIII' with letterSpacing 8. Skia adds the spacing after every glyph and
centres it (first glyph moves right by 4), so the ink span grows by 3 * 8.
tabularNums: rows '1111' and '0000'. The control is proportional-nums ('1' advances less
than '0'); the feature is tabular-nums. Ink spans differ by the last glyph's own ink
width even when advances match, so the rule compares the glyph pitch (left edge of
glyph 4 minus glyph 1, over 3)."""


def _dark(p): return sum(p) / 3 < 140


def _bands(px):
    """Rows of dark ink grouped into text lines: [(y0, y1), ...]."""
    rows = sorted({y for (x, y), v in px.items() if _dark(v)})
    out = []
    for y in rows:
        if out and y == out[-1][1] + 1:
            out[-1] = (out[-1][0], y)
        else:
            out.append((y, y))
    return out


def _glyphs(px, band):
    """Column runs of dark ink inside one band: [(x0, x1), ...] left to right."""
    y0, y1 = band
    cols = sorted({x for (x, y), v in px.items() if y0 <= y <= y1 and _dark(v)})
    out = []
    for x in cols:
        if out and x == out[-1][1] + 1:
            out[-1] = (out[-1][0], x)
        else:
            out.append((x, x))
    return out


def _span(gl): return gl[-1][1] - gl[0][0] + 1


def letter_spacing_ok(c, f, d):
    bc, bf = _bands(c), _bands(f)
    if len(bc) != 1 or len(bf) != 1:
        return False
    gc, gf = _glyphs(c, bc[0]), _glyphs(f, bf[0])
    if len(gc) != 4 or len(gf) != 4:
        return False
    if abs(_span(gf) - (_span(gc) + 3 * 8)) > 2:
        return False
    # Same glyphs (stem widths) and the first one no further right than half the spacing.
    if any(abs((a[1] - a[0]) - (b[1] - b[0])) > 1 for a, b in zip(gc, gf)):
        return False
    return 0 <= gf[0][0] - gc[0][0] <= 5


def _pitches(px):
    bands = _bands(px)
    if len(bands) != 2:
        return None
    out = []
    for b in bands:
        g = _glyphs(px, b)
        if len(g) != 4:
            return None
        out.append((g[3][0] - g[0][0]) / 3)
    return out


def tabular_ok(c, f, d):
    pc, pf = _pitches(c), _pitches(f)
    if pc is None or pf is None:
        return False
    # Control: proportional '1' advances visibly less than '0'.
    if pc[0] > pc[1] - 1.5:
        return False
    return abs(pf[0] - pf[1]) <= 1
