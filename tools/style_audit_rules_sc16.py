"""SC-16 strict rules for grid 1 (tools/style-audit-measure.py): ellipsizeMode head
and middle. 'ABCDEFGHIJKLMNOP' at 14 pt in an 80 pt box (x 30..109), one line.
Ink is split into glyph groups (8-connected components)."""


# Not just non-white: darwin AA leaves 251-254 fringes that bridge the ellipsis dots.
def _ink(p): return sum(p) < 3 * 240


def _groups(px):
    """8-connected ink components, left to right (column runs merge a glyph whose
    bowl overhangs the next dot's columns, as darwin's 'D' does)."""
    todo = {k for k, v in px.items() if _ink(v)}
    out = []
    while todo:
        stack = [todo.pop()]
        comp = []
        while stack:
            x, y = stack.pop()
            comp.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if q in todo:
                        todo.remove(q)
                        stack.append(q)
        xs = [x for x, _ in comp]
        out.append({"x0": min(xs), "x1": max(xs), "ys": [y for _, y in comp]})
    return sorted(out, key=lambda g: g["x0"])


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
