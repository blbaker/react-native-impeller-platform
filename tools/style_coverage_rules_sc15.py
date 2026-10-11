"""SC-15 strict rule for grid 2: textShadow (red 'AB', blue shadow at +3,+3, radius 4)."""
from style_rules_sc15 import shadow_ok


def _pixels(slot):
    return {(x, y): tuple(slot.px(x, y)) for y in range(-31, 105) for x in range(-22, 90)}


def _nested(ctl, feat):
    if any(v[2] > 200 and v[0] < 100 for v in _pixels(ctl).values()):
        return False, "control already has blue ink"
    return shadow_ok(_pixels(feat), 4, max_peak=225)  # radius 4 thin strokes never reach solid


RULES = {'g2:textShadowNested': _nested}
