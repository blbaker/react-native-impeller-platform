"""SC-12 strict rules: blur(), iOS shadow cast by content. Slot (0,0) is the element's top-left."""


def _dark(p): return max(p) < 120


def _ramp(slot, y=30):
    # Distinct colours crossing the left edge (x -14..14); a hard edge has ~2.
    return len({slot.px(x, y) for x in range(-14, 15)})


def _blue500(p): return abs(p[0] - 43) <= 8 and abs(p[1] - 127) <= 8 and abs(p[2] - 255) <= 8


def _nw_blur(ctl, feat):
    for name, s in (("feature", feat), ("control", ctl)):
        if not _blue500(s.px(30, 30)):
            return False, f"{name} centre {s.px(30, 30)} is not blue-500"
        if _ramp(s) < 6:
            return False, f"{name} edge ramp has {_ramp(s)} levels, want >= 6"
        if s.px(-2, 30) == (255, 255, 255):
            return False, f"{name} blur does not spill past the edge"
    return True, f"ramp {_ramp(feat)} levels"


def _shadow_no_bg(ctl, feat):
    # 60x60 frame, no background, red 30x30 child at (15,15); shadow offset (6,6).
    for x, y in ((48, 30), (30, 48), (46, 46)):
        if not _dark(feat.px(x, y)):
            return False, f"no shadow under the square at {x},{y}: {feat.px(x, y)}"
    for x, y in ((58, 58), (58, 10), (10, 58), (62, 62), (5, 5)):
        if feat.px(x, y) != (255, 255, 255):
            return False, f"shadow in the empty frame at {x},{y}: {feat.px(x, y)}"
    if feat.px(30, 30)[0] < 240 or ctl.px(48, 48) != (255, 255, 255):
        return False, f"square {feat.px(30, 30)} / control {ctl.px(48, 48)}"
    return True, "shadow follows the square"


RULES = {
    'nw:blur': _nw_blur,
    'g2:shadowNoBg': _shadow_no_bg,
}
