"""SC-11 strict rules: CSS colour-matrix filters. Slot (0,0) is the element's top-left, boxes 60x60."""


def _near(p, want, tol=6): return all(abs(p[k] - want[k]) <= tol for k in range(3))


def _filtered(want):
    def rule(ctl, feat):
        got = feat.px(30, 30)
        if not _near(got, want):
            return False, f"centre {got}, want {want}"
        for x, y in ((5, 5), (55, 55), (30, 5)):
            if not _near(feat.px(x, y), want):
                return False, f"{x},{y} is {feat.px(x, y)}, want {want}"
        for x, y in ((-6, 30), (66, 30), (30, -6), (30, 66)):
            if feat.px(x, y) != (255, 255, 255):
                return False, f"page outside the box changed at {x},{y}: {feat.px(x, y)}"
        return True, f"centre {got}"
    return rule


RULES = {
    'g2:filterInvert': _filtered((255, 255, 0)),            # invert(1) of blue
    'g2:filterHueRotate': _filtered((0, 109, 109)),         # hue-rotate(180deg) of red, CSS matrix
    'g2:filterOpacity': _filtered((179, 179, 255)),         # 0.3 blue over white
    'g2:filterSaturate': _filtered((54, 54, 54)),           # saturate(0) of red
    'g2:filterChain': _filtered((255, 255, 127)),           # brightness(.5) then invert(1); reversed gives (127,127,0)
}


def _nw_grayscale(ctl, feat):
    # grayscale(1) of Tailwind red-500 (251,44,54): 0.2126*251 + 0.7152*44 + 0.0722*54 = 88.8
    ok, why = _filtered((89, 89, 89))(ctl, feat)
    if not ok:
        return ok, why
    if not _near(ctl.px(30, 30), (89, 89, 89)):
        return False, f"control (style filter) centre {ctl.px(30, 30)}"
    return True, why


RULES['nw:grayscale'] = _nw_grayscale
