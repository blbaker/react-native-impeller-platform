"""SC-08 strict rules: backgroundSize, backgroundPosition, backgroundRepeat on gradient layers."""
# Slot (0,0) is the element's top-left; the fixture boxes are 60x60 and the
# red->blue ramp runs left to right.


def _red(p): return p[0] > 200 and p[1] < 60 and p[2] < 60
def _blue(p): return p[2] > 200 and p[0] < 60 and p[1] < 60
def _grey(p): return all(abs(p[k] - 200) <= 6 for k in range(3))


def _size_repeat(ctl, feat):
    # 20 px tiles repeat: the ramp restarts at x = 0, 20 and 40, and each tile
    # ends blue just before the next red column. The control ramps once.
    row = [feat.px(x, 30) for x in range(60)]
    starts = [x for x in range(60) if _red(row[x]) and (x == 0 or not _red(row[x - 1]) and row[x - 1][0] < 150)]
    if starts != [0, 20, 40]:
        return False, f"ramp restarts at {starts}, want [0, 20, 40]"
    for x in (19, 39, 59):
        if not _blue(row[x]):
            return False, f"tile does not end blue at x={x}: {row[x]}"
    crow = [ctl.px(x, 30) for x in range(60)]
    if not _red(crow[0]) or any(_red(p) for p in crow[16:]):
        return False, "control is not a single ramp"
    if feat.px(5, 3) != feat.px(5, 56):
        return False, f"tiles do not repeat vertically {feat.px(5, 3)} vs {feat.px(5, 56)}"
    return True, f"restarts={starts}"


def _position(ctl, feat):
    # 30x30 gradient centred (x, y in 15..45) over grey; the control is a full ramp.
    if _grey(ctl.px(3, 3)) or _grey(ctl.px(30, 30)):
        return False, "control is not a full-box gradient"
    for x, y in ((3, 3), (56, 3), (3, 56), (56, 56), (10, 30), (50, 30), (30, 10), (30, 50)):
        if not _grey(feat.px(x, y)):
            return False, f"outside the tile at {x},{y} not grey: {feat.px(x, y)}"
    left, right, top, bot = feat.px(17, 30), feat.px(43, 30), feat.px(30, 17), feat.px(30, 43)
    if not (left[0] > 200 and right[2] > 200):
        return False, f"gradient not spanning the centred tile: {left} .. {right}"
    if _grey(top) or _grey(bot):
        return False, f"tile does not reach y 17..43: {top} {bot}"
    return True, f"left={left} right={right}"


RULES = {
    'g2:backgroundSize': _size_repeat,
    'g2:backgroundPosition': _position,
}
