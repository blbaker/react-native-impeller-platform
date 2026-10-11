"""SC-15 strict rules for textShadow, shared by grid 1 (dict of pixels) and grid 2 (Slot).
Red glyphs, blue shadow: the shadow must sit at +offset only and be blurred."""


def _is_red(p): return p[0] > 200 and p[1] < 80 and p[2] < 80


def _blue_amount(p): return p[2] - p[0] if p[2] > 200 and p[2] - p[1] > 40 and abs(p[0] - p[1]) < 12 else 0


def shadow_ok(pts, min_levels, glyph_x0=None, max_peak=None):
    """pts: {(x, y): (r, g, b)}. Offset is +x,+y. glyph_x0 limits the red reference to
    x >= glyph_x0 (nested tile: only the second span has a shadow)."""
    red = [k for k, v in pts.items() if _is_red(v)]
    blue = {k: _blue_amount(v) for k, v in pts.items()
            if _blue_amount(v) > 40 and not _is_red(v)}
    if not red:
        return False, "no red glyph ink"
    if glyph_x0 is not None:
        red = [k for k in red if k[0] >= glyph_x0]
        blue = {k: v for k, v in blue.items() if k[0] >= glyph_x0 - 1}
    if len(blue) < 30:
        return False, f"only {len(blue)} blue px"
    rx0, rx1 = min(p[0] for p in red), max(p[0] for p in red)
    ry0, ry1 = min(p[1] for p in red), max(p[1] for p in red)
    bx0, bx1 = min(p[0] for p in blue), max(p[0] for p in blue)
    by0, by1 = min(p[1] for p in blue), max(p[1] for p in blue)
    if bx1 < rx1 + 2 or by1 < ry1 + 2:
        return False, f"blue ends x{bx1} y{by1}, glyph ends x{rx1} y{ry1}: not offset +x,+y"
    if bx0 < rx0 - 1 or by0 < ry0 - 1:
        return False, f"blue starts x{bx0} y{by0} before glyph x{rx0} y{ry0}: also at -offset"
    levels = len(set(blue.values()))
    if levels < min_levels:
        return False, f"{levels} blue levels, want >= {min_levels} (blurred)"
    if max_peak is not None and max(blue.values()) > max_peak:
        return False, f"blue peak {max(blue.values())} > {max_peak}: shadow edge is not blurred"
    return True, f"blue x{bx0}..{bx1} y{by0}..{by1} vs glyph x{rx0}..{rx1} y{ry0}..{ry1}, {levels} levels"
