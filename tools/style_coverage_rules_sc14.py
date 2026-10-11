"""SC-14 strict rules: italic, nested italic / opacity, vertical text alignment.
Slot (0,0) is the element's top-left; helpers here work on dark-ink points only."""


def bbox(pts):
    if not pts:
        return None
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def _lum(p): return (p[0] + p[1] + p[2]) / 3


def _ink(slot, x0, x1, y0=-31, y1=105, thresh=140):
    return [(x, y) for y in range(y0, y1) for x in range(x0, x1) if _lum(slot.px(x, y)) < thresh]


def _slant(pts, lo=0.0, hi=1.0):
    """Mean x of the top third minus mean x of the bottom third of the ink in
    columns [lo, hi) of its bbox. Upright glyphs give ~0, italic > 1."""
    bb = bbox(pts)
    if bb is None:
        return None
    w = bb[2] - bb[0] + 1
    sel = [p for p in pts if bb[0] + lo * w <= p[0] < bb[0] + hi * w + 1]
    sb = bbox(sel)
    if sb is None:
        return None
    h = sb[3] - sb[1] + 1
    top = [p[0] for p in sel if p[1] < sb[1] + h / 3]
    bot = [p[0] for p in sel if p[1] >= sb[3] - h / 3 + 1]
    if not top or not bot:
        return None
    return sum(top) / len(top) - sum(bot) / len(bot)


def _stem_lean(pts, lo=0.45):
    """Left ink edge of the top quarter of rows minus that of the bottom quarter,
    over the right part of the bbox (the 'b' of 'Ab'). Upright stem ~0."""
    bb = bbox(pts)
    sel = [p for p in pts if p[0] >= bb[0] + lo * (bb[2] - bb[0] + 1)]
    sb = bbox(sel)
    h = sb[3] - sb[1] + 1
    top = [p[0] for p in sel if p[1] < sb[1] + h / 4]
    bot = [p[0] for p in sel if p[1] > sb[3] - h / 4]
    return min(top) - min(bot) if top and bot else None


def _ab_split(ctl):
    """First column of 'BB' in the control's 'AABB': the middle of the gap
    between the 2nd and 3rd ink column runs. A fixed fraction of the ink width
    lands inside the 2nd 'A' on faces with a wide 'A' (Segoe UI, SC-40)."""
    cols = sorted({x for x, _ in _ink(ctl, -22, 90)})
    runs = []
    for x in cols:
        if runs and x == runs[-1][1] + 1:
            runs[-1][1] = x
        else:
            runs.append([x, x])
    if len(runs) == 4:
        return (runs[1][1] + runs[2][0] + 1) // 2
    return cols[0] + int((cols[-1] - cols[0]) * 0.52)


def _nested_italic(ctl, feat):
    # 'AA' upright then 'BB' italic. The split is 52% of the control's ink.
    split = _ab_split(ctl)
    cr = _slant(_ink(ctl, split, 90))
    fr = _slant(_ink(feat, split, 90))
    fl = _slant(_ink(feat, -22, split))
    if None in (cr, fr, fl):
        return False, f"no ink: control {cr} feature-right {fr} feature-left {fl}"
    if abs(cr) > 0.7:
        return False, f"control 'BB' already slanted {cr:.2f}"
    if fr - cr < 1.2:
        return False, f"'BB' slant {fr:.2f} vs control {cr:.2f}, want >= 1.2 more"
    if abs(fl) > 1.0:
        return False, f"'AA' slanted too ({fl:.2f})"
    return True, f"BB slant {fr:.2f} (control {cr:.2f}), AA {fl:.2f}"


def _nested_opacity(ctl, feat):
    # 'AA' stays black, 'BB' (opacity 0.2) lands on a light grey, still visible.
    split = _ab_split(ctl)

    def darkest(s, x0, x1):
        return min(_lum(s.px(x, y)) for y in range(-31, 105) for x in range(x0, x1))
    ca, cbb = darkest(ctl, -22, split), darkest(ctl, split, 90)
    fa, fb = darkest(feat, -22, split), darkest(feat, split, 90)
    if ca > 60 or cbb > 60:
        return False, f"control not black: AA {ca:.0f} BB {cbb:.0f}"
    if fa > 60:
        return False, f"AA dimmed to {fa:.0f}"
    if not 150 <= fb <= 235:
        return False, f"BB darkest {fb:.0f}, want a light grey 150..235 (alpha 0.2 gives ~204)"
    return True, f"AA {fa:.0f} BB {fb:.0f}"


def _v_centre(ctl, feat):
    # 60x60 grey box with 'AB'. The control sits at the top; the feature's ink
    # centre is within 4 px of the box centre (30).
    def centre(s):
        pts = [(x, y) for y in range(0, 60) for x in range(0, 60) if _lum(s.px(x, y)) < 90]
        bb = bbox(pts)
        return None if bb is None else (bb[1] + bb[3]) / 2
    cc, fc = centre(ctl), centre(feat)
    if cc is None or fc is None:
        return False, f"no text ink: control {cc} feature {fc}"
    if cc > 22:
        return False, f"control ink centre {cc:.1f} is not at the top"
    if abs(fc - 30) > 4:
        return False, f"feature ink centre {fc:.1f}, want 30 +/- 4"
    return True, f"ink centre {fc:.1f} (control {cc:.1f})"


def _nw_italic(ctl, feat):
    # 'Ab': the 'b' stem is the left edge of the second glyph; an italic stem
    # leans right going up. Both the control and the NativeWind tile must lean.
    out = []
    for name, s in (("control", ctl), ("feature", feat)):
        pts = _ink(s, -22, 90)
        v = _stem_lean(pts)
        if v is None or v < 1.5:
            return False, f"{name} 'b' stem lean {v}, want >= 1.5"
        out.append(v)
    return True, f"slant {out[0]:.2f}/{out[1]:.2f}"


RULES = {
    'g2:nestedItalic': _nested_italic,
    'g2:nestedOpacity': _nested_opacity,
    'g2:textAlignVertical': _v_centre,
    'g2:verticalAlign': _v_centre,
    'nw:italic': _nw_italic,
}
