"""SC-14 strict rules for grid 1 (tools/style-audit-measure.py). Each takes the
control and feature pixel dicts; (x, y) are tile-local, the 80 pt box is x 30..109."""


def _ink(p): return p != (255, 255, 255)


def _pts(px): return [k for k, v in px.items() if _ink(v)]


def _mean(v): return sum(v) / len(v)


def italic_ok(c, f, d):
    """'IIII': ink centroid of the top third is >= 2 px right of the bottom third's;
    the upright control is within 1 px."""
    def lean(px):
        pts = _pts(px)
        if not pts:
            return None
        y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
        h = y1 - y0 + 1
        top = [p[0] for p in pts if p[1] < y0 + h / 3]
        bot = [p[0] for p in pts if p[1] > y1 - h / 3]
        return _mean(top) - _mean(bot)
    cl, fl = lean(c), lean(f)
    return cl is not None and fl is not None and abs(cl) <= 1.0 and fl >= 2.0


def rtl_ok(c, f, d):
    """'AB' in rtl: same ink width, right-aligned in the box (right edge ~109),
    while the control starts at the box's left edge."""
    cp, fp = _pts(c), _pts(f)
    if not cp or not fp:
        return False
    cx0, cx1 = min(p[0] for p in cp), max(p[0] for p in cp)
    fx0, fx1 = min(p[0] for p in fp), max(p[0] for p in fp)
    same_w = abs((fx1 - fx0) - (cx1 - cx0)) <= 1
    return same_w and cx0 <= 34 and 105 <= fx1 <= 111


def justify_ok(c, f, d):
    """The first wrapped line's ink spans the box (x 30..109 +/- 2); in the control
    it does not; the last line is not stretched."""
    def line(px, n):
        pts = _pts(px)
        if not pts:
            return None
        ys = sorted({p[1] for p in pts})
        y0 = ys[0]
        gaps = [b for a, b in zip(ys, ys[1:]) if b - a > 1]
        y1 = (gaps[0] - 1) if gaps else ys[-1]
        sel = [p[0] for p in pts if (p[1] <= y1 if n == 0 else p[1] > y1)]
        return (min(sel), max(sel)) if sel else None
    c0, f0, f1 = line(c, 0), line(f, 0), line(f, 1)
    if None in (c0, f0, f1):
        return False
    return f0[0] <= 32 and f0[1] >= 107 and c0[1] <= 100 and f1[1] <= 100
