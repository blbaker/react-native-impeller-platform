"""SC-16 strict rules for grid 1 (tools/style-audit-measure.py): ellipsizeMode head
and middle. 'ABCDEFGHIJKLMNOP' at 14 pt in an 80 pt box (x 30..109), one line.
Ink is split into glyph groups (runs of columns with ink)."""


def _ink(p): return p != (255, 255, 255)


def _groups(px):
    cols = {}
    for (x, y), v in px.items():
        if _ink(v):
            cols.setdefault(x, []).append(y)
    out, cur = [], None
    for x in sorted(cols):
        if cur and x == cur["x1"] + 1:
            cur["x1"] = x
            cur["ys"] += cols[x]
        else:
            cur = {"x0": x, "x1": x, "ys": list(cols[x])}
            out.append(cur)
    return out


def _is_dot(g, base):
    """A dot: at most 3 rows tall and sitting on the text baseline."""
    return max(g["ys"]) - min(g["ys"]) <= 3 and max(g["ys"]) >= base - 1


def _is_p(px, g):
    """'P': tall, a one-stem foot (<= 3 px wide on the last row), a bowl at the top."""
    y0, y1 = min(g["ys"]), max(g["ys"])
    if y1 - y0 < 8:
        return False
    def width(y):
        xs = [x for x in range(g["x0"], g["x1"] + 1) if _ink(px[(x, y)])]
        return (max(xs) - min(xs) + 1) if xs else 0
    return width(y1) <= 3 and width(y0 + 1) >= 5


def _layout(f):
    gs = _groups(f)
    if len(gs) < 5:
        return None
    base = max(max(g["ys"]) for g in gs)
    return gs, base


def head_ok(c, f, d):
    """First three groups are baseline dots, then a tall glyph; the last glyph is a
    'P' ending inside the box. The tail-truncated control starts with a tall 'A'."""
    lc, lf = _layout(c), _layout(f)
    if not lc or not lf:
        return False
    gs, base = lf
    if _is_dot(lc[0][0], lc[1]):
        return False
    dots = all(_is_dot(g, base) for g in gs[:3]) and not _is_dot(gs[3], base)
    last = gs[-1]
    return dots and _is_p(f, last) and 100 <= last["x1"] <= 109 and gs[0]["x0"] <= 36


def middle_ok(c, f, d):
    """Three baseline dots sit in the middle third of the ink, tall glyphs on both
    sides, and the string still ends in 'P'."""
    lf = _layout(f)
    if not lf:
        return False
    gs, base = lf
    dots = [i for i, g in enumerate(gs) if _is_dot(g, base)]
    if len(dots) < 3:
        return False
    for i in range(len(dots) - 2):
        a, b, e = dots[i], dots[i + 1], dots[i + 2]
        if b != a + 1 or e != b + 1 or a == 0 or e == len(gs) - 1:
            continue
        x0, x1 = gs[0]["x0"], gs[-1]["x1"]
        third = (x1 - x0) / 3
        mid = (gs[a]["x0"] + gs[e]["x1"]) / 2
        return x0 + third <= mid <= x1 - third and _is_p(f, gs[-1]) and 100 <= x1 <= 109 and x0 <= 36
    return False
