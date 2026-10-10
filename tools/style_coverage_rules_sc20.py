"""SC-20 strict rules: TextInput text attributes. Every tile is an 80 x 40 field holding
'ab' (16 pt, black). Slot (0,0) is the field's top-left, so x 40 is its centre; the field
insets its text by 4 pt on each side."""
from style_coverage_rules_sc14 import _ink, _slant, bbox

FIELD_W = 80


def _pair(ctl, feat):
    ci, fi = _ink(ctl, -22, 110), _ink(feat, -22, 110)
    return ci, fi, bbox(ci), bbox(fi)


def _align_center(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if cb is None or fb is None:
        return False, f"no ink ctl={cb} feat={fb}"
    if cb[0] > 10:
        return False, f"control not left aligned {cb}"
    mid = (fb[0] + fb[2]) / 2
    if abs(mid - FIELD_W / 2) > 4:
        return False, f"ink centre {mid:.1f}, want {FIELD_W / 2} +/- 4 (ink {fb})"
    if abs((fb[2] - fb[0]) - (cb[2] - cb[0])) > 3:
        return False, f"ink width changed {fb} vs control {cb}"
    return True, f"ink centre {mid:.1f}"


def _align_right(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if cb is None or fb is None:
        return False, f"no ink ctl={cb} feat={fb}"
    if cb[0] > 10:
        return False, f"control not left aligned {cb}"
    if not 70 <= fb[2] <= 78 or fb[0] < 50:
        return False, f"ink {fb} not against the right inset (want right edge 70..78)"
    return True, f"ink right edge {fb[2]}"


def _bold(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if not ci or not fi:
        return False, "no ink"
    if len(fi) <= 1.3 * len(ci):
        return False, f"ink {len(fi)} px vs control {len(ci)}, want > 1.3x"
    if abs(fb[0] - cb[0]) > 3:
        return False, f"ink moved {fb} vs control {cb}"
    return True, f"ink {len(fi)} px vs control {len(ci)}"


def _italic(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if not ci or not fi:
        return False, "no ink"
    cs, fs = _slant(ci, 0.4, 1.0), _slant(fi, 0.4, 1.0)
    if cs is None or fs is None:
        return False, f"no slant ctl={cs} feat={fs}"
    if fs - cs < 1.0:
        return False, f"'b' slant {fs:.2f} vs control {cs:.2f}, want >= 1.0 more"
    if abs(fb[0] - cb[0]) > 4:
        return False, f"ink moved {fb} vs control {cb}"
    return True, f"slant {fs:.2f} (control {cs:.2f})"


def _decoration(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if not ci or not fi:
        return False, "no ink"
    rows = {}
    for x, y in fi:
        rows.setdefault(y, []).append(x)
    width = cb[2] - cb[0] + 1
    for y in sorted(rows):
        if y <= cb[3]:
            continue
        xs = rows[y]
        if max(xs) - min(xs) + 1 >= width and len(xs) >= width - 1:
            return True, f"underline row y={y} spans {min(xs)}..{max(xs)} (text {width} px wide)"
    return False, f"no full-width ink row below the glyphs (control bottom {cb[3]}, rows {sorted(rows)[-3:]})"


def _first_glyph_height(pts):
    bb = bbox(pts)
    ys = [y for x, y in pts if x <= bb[0] + 6]
    return max(ys) - min(ys) + 1


def _transform(ctl, feat):
    ci, fi, cb, fb = _pair(ctl, feat)
    if not ci or not fi:
        return False, "no ink"
    if set(ci) == set(fi):
        return False, "ink identical to the control"
    ch, fh = _first_glyph_height(ci), _first_glyph_height(fi)
    if fh < ch + 2:
        return False, f"first glyph {fh} px tall vs control {ch}, want >= 2 taller (cap vs x-height)"
    return True, f"first glyph {fh} px vs {ch}"


RULES = {
    'g2:tiAlignCenter': _align_center,
    'g2:tiAlignRight': _align_right,
    'g2:tiBold': _bold,
    'g2:tiItalic': _italic,
    'g2:tiDecoration': _decoration,
    'g2:tiTextTransform': _transform,
}
