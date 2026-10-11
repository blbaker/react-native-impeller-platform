"""SC-10 strict rules: backfaceVisibility hidden. Slot (0,0) is the element's top-left, boxes 60x60."""


def _blue(p): return p[2] > 200 and p[0] < 80 and p[1] < 160


def _backface(ctl, feat):
    # Both boxes are rotateY(180deg) about their centre, so a visible one is a
    # mirrored blue square on the same 60x60 area. Only the control may paint.
    pts = [(x, y) for x in range(-20, 80, 4) for y in range(-20, 80, 4)]
    if not (_blue(ctl.px(30, 30)) and _blue(ctl.px(5, 55)) and _blue(ctl.px(55, 5))):
        return False, f"control (no backfaceVisibility) is not painted: {ctl.px(30, 30)}"
    blue = [p for p in pts if _blue(feat.px(*p))]
    if blue:
        return False, f"hidden back face painted {len(blue)} blue samples, first {blue[0]}"
    return True, "back face skipped, control mirrored"


RULES = {
    'nw:backface': _backface,
}
