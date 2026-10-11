"""SC-22 strict rule: PlatformColor('systemBlue', ...) must paint iOS systemBlue
(0,122,255) in light mode. Control is a grey box; slot (0,0) is the box top-left."""


def _platform_blue(ctl, feat):
    got = feat.px(30, 30)
    want = (0, 122, 255)
    if any(abs(a - b) > 4 for a, b in zip(got[:3], want)):
        return False, f"feature centre {tuple(got[:3])}, want {want} +/- 4"
    if tuple(got[:3]) == tuple(ctl.px(30, 30)[:3]):
        return False, "feature equals the control grey"
    return True, f"feature centre {tuple(got[:3])}"


RULES = {'risky:platformColor': _platform_blue}
