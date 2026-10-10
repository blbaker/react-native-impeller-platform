"""SC-18 strict rules: generic font families and stacks. Slot (0,0) is the element's
top-left. 'iiMM' in a monospace face has four equal advances, so the ink centres of
its four glyphs are evenly spaced; a proportional face puts 'i' at ~5 px and 'M' at
~17 px. 'Ag' in a serif face has slab feet that the default sans does not."""
from style_coverage_rules_sc14 import _ink


def _glyph_centres(pts):
    cols = sorted({x for x, _ in pts})
    runs, cur = [], None
    for x in cols:
        if cur and x == cur[1] + 1:
            cur[1] = x
        else:
            cur = [x, x]
            runs.append(cur)
    return [(a + b) / 2 for a, b in runs]


def _mono(ctl, feat, x1=90):
    pts = _ink(feat, -22, x1)
    if not pts:
        return False, "no ink"
    c = _glyph_centres(pts)
    if len(c) != 4:
        return False, f"{len(c)} glyph groups, want 4 (i i M M): {c}"
    gaps = [c[k + 1] - c[k] for k in range(3)]
    if max(gaps) - min(gaps) > 2:
        return False, f"glyph pitch not equal: {gaps} (proportional face?)"
    return True, f"pitch {gaps}"


def _nested_mono(ctl, feat):
    cw = _ink(ctl, -22, 90)
    fw = _ink(feat, -22, 90)
    if not cw or not fw:
        return False, "no ink"
    cwid = max(x for x, _ in cw) - min(x for x, _ in cw)
    fwid = max(x for x, _ in fw) - min(x for x, _ in fw)
    if fwid < cwid + 6:
        return False, f"mono span 'ii' not wider: control {cwid} px, feature {fwid} px"
    return True, f"control {cwid} px, feature {fwid} px"


def _foot_ink(slot):
    """Ink pixels in the bottom row of the first glyph ('A'): serif feet are slabs."""
    pts = _ink(slot, -22, 90)
    if not pts:
        return None
    cols = sorted({x for x, _ in pts})
    x0 = cols[0]
    end = x0
    for x in cols:
        if x > end + 1:
            break
        end = x
    a = [(x, y) for x, y in pts if x0 <= x <= end]
    base = max(y for _, y in a)
    return sum(1 for x, y in a if y >= base - 1), end - x0 + 1


def _serif(ctl, feat):
    c, f = _foot_ink(ctl), _foot_ink(feat)
    if c is None or f is None:
        return False, "no ink"
    if f[0] < c[0] + 4:
        return False, f"foot ink {f[0]} px vs control {c[0]}: no slab serifs"
    return True, f"foot ink feature {f[0]} vs control {c[0]}"


RULES = {
    'g2:fontMonospace': _mono,
    'g2:fontStack': _mono,
    'g2:tiMonospace': _mono,
    'nw:fontMono': _mono,
    'g2:nestedFamily': _nested_mono,
    'g2:fontSerif': _serif,
}
