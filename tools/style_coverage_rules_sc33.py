"""SC-33 strict rules: letterSpacing and fontVariant small-caps.
g2:smallCaps: 'Abc' 20 pt; the feature has fontVariant small-caps. 'A' stays the same,
'b' loses its ascender and 'c' grows past x-height (or, Roboto, keeps it
but changes shape), both to one small-cap height
below the cap height.
g2:tiLetterSpacing: an 80 x 40 TextInput holding 'ab' 16 pt; the feature adds
letterSpacing 8, so the second glyph moves 8 px further from the first.
nw:tracking: 'IIII' 20 pt, control letterSpacing 2, feature `text-[20px]
tracking-widest` (0.1em = 2 px); both must space the stems wider than bare 'I's."""
from style_coverage_rules_sc14 import _ink, bbox


def _groups(pts):
    """Column runs of ink: [(x0, x1, top_y), ...] left to right."""
    xs = sorted({p[0] for p in pts})
    runs = []
    for x in xs:
        if runs and x == runs[-1][1] + 1:
            runs[-1][1] = x
        else:
            runs.append([x, x])
    return [(a, b, min(p[1] for p in pts if a <= p[0] <= b)) for a, b in runs]


def _small_caps(ctl, feat):
    gc, gf = _groups(_ink(ctl, -22, 110)), _groups(_ink(feat, -22, 110))
    if len(gc) != 3 or len(gf) != 3:
        return False, f"want 3 glyphs, got ctl={len(gc)} feat={len(gf)}"
    (ca, cb, cc), (fa, fb, fc) = gc, gf
    if ca != fa:
        return False, f"'A' changed {fa} vs control {ca}"
    if fc[2] > cc[2]:
        return False, f"'c' top {fc[2]} below control's {cc[2]} (no small cap)"
    if fc[2] == cc[2]:
        # SC-41: Roboto's small-cap C has the x-height of 'c', so demand a new glyph shape.
        d = sum(1 for x in range(min(cc[0], fc[0]), max(cc[1], fc[1]) + 1) for y in range(0, 31)
                if abs(sum(ctl.px(x, y)[:3]) - sum(feat.px(x, y)[:3])) > 192)
        if d < 15:
            return False, f"'c' top {fc[2]} = control's and only {d} px changed (no small cap)"
    if fb[2] < cb[2] + 2:
        return False, f"'b' top {fb[2]} vs control {cb[2]}: ascender kept"
    if abs(fb[2] - fc[2]) > 1:
        return False, f"'b' top {fb[2]} and 'c' top {fc[2]} differ"
    if fc[2] <= fa[2]:
        return False, f"small caps reach the cap height ({fc[2]} vs 'A' {fa[2]})"
    return True, f"tops A={fa[2]} b={fb[2]} c={fc[2]} (control c={cc[2]})"


def _ti_letter_spacing(ctl, feat):
    gc, gf = _groups(_ink(ctl, -22, 110)), _groups(_ink(feat, -22, 110))
    if len(gc) != 2 or len(gf) != 2:
        return False, f"want 2 glyphs, got ctl={len(gc)} feat={len(gf)}"
    pc, pf = gc[1][0] - gc[0][0], gf[1][0] - gf[0][0]
    if abs(pf - (pc + 8)) > 1:
        return False, f"glyph pitch {pf} vs control {pc}, want +8 +/- 1"
    if any(abs((a[1] - a[0]) - (b[1] - b[0])) > 1 for a, b in zip(gc, gf)):
        return False, f"glyph widths changed {gf} vs {gc}"
    if not 0 <= gf[0][0] - gc[0][0] <= 5:
        return False, f"first glyph at {gf[0][0]} vs control {gc[0][0]}"
    return True, f"pitch {pf} vs {pc}"


def _tracking(ctl, feat):
    gc, gf = _groups(_ink(ctl, -22, 110)), _groups(_ink(feat, -22, 110))
    if len(gc) != 4 or len(gf) != 4:
        return False, f"want 4 stems, got ctl={len(gc)} feat={len(gf)}"
    pc, pf = (gc[3][0] - gc[0][0]) / 3, (gf[3][0] - gf[0][0]) / 3
    # A bare 20 pt 'I' advances ~5 px here; +2 px spacing gives ~7.
    if pc < 6.5:
        return False, f"control stem pitch {pc:.2f}: letterSpacing ignored"
    if abs(pf - pc) > 0.5:
        return False, f"stem pitch {pf:.2f} vs control {pc:.2f}"
    return True, f"stem pitch {pf:.2f} vs {pc:.2f}"


RULES = {
    'g2:smallCaps': _small_caps,
    'g2:tiLetterSpacing': _ti_letter_spacing,
    'nw:tracking': _tracking,
}
