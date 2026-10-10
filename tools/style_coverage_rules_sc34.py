"""SC-34 strict rule: an inline <View> inside <Text>.
risky:inlineView: control 'ABCD' 20 pt; the feature is 'AB' + a 14 x 14 red View
+ 'CD'. The red box must sit between the 'B' and 'C' ink with its bottom on the
glyph baseline, and 'CD' must move right by at least the box width. RN rounds an
attachment's measured size up after adding 0.01 (ParagraphShadowNode), so at
scale 1 the box is 15 px: 14 or 15 is accepted."""
from style_coverage_rules_sc14 import _ink
from style_coverage_rules_sc33 import _groups
from style_coverage_rules import bbox


def _red(p): return p[0] > 200 and p[1] < 70 and p[2] < 70


def _text(slot):
    return [q for q in _ink(slot, -22, 110) if not _red(slot.px(*q))]


def _inline_view(ctl, feat):
    if ctl.points(_red, -22, 110):
        return False, "control has red ink"
    gc, gf = _groups(_text(ctl)), _groups(_text(feat))
    if len(gc) != 4 or len(gf) != 4:
        return False, f"want 4 glyphs, got ctl={len(gc)} feat={len(gf)}"
    red = feat.points(_red, -22, 110)
    if not red:
        return False, "no red inline View painted"
    rx0, ry0, rx1, ry1 = bbox(red)
    w, h = rx1 - rx0 + 1, ry1 - ry0 + 1
    if not (14 <= w <= 15 and 14 <= h <= 15) or len(red) < (w - 1) * (h - 1):
        return False, f"red box {w}x{h} ({len(red)} px), want a solid 14-15 px square"
    if not (gf[1][1] < rx0 and rx1 < gf[2][0]):
        return False, f"red x {rx0}..{rx1} not between 'B' end {gf[1][1]} and 'C' start {gf[2][0]}"
    base = max(q[1] for q in _text(feat) if q[0] <= gf[1][1])
    if abs(ry1 - base) > 2:
        return False, f"red bottom {ry1} vs glyph baseline {base}"
    if abs(gf[0][0] - gc[0][0]) > 1:
        return False, f"'A' moved {gf[0][0]} vs control {gc[0][0]}"
    shift = gf[2][0] - gc[2][0]
    if shift < 14:
        return False, f"'CD' moved {shift} px right of the control, want >= 14"
    return True, f"red {w}x{h} at x {rx0}..{rx1} bottom {ry1} (baseline {base}), CD +{shift}"


RULES = {
    'risky:inlineView': _inline_view,
}
