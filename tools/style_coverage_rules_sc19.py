"""SC-19 strict rules: font fallback for emoji, CJK and Arabic on linux. The risky tile
`tofuRef` (index 5, two private-use codepoints) paints the engine's missing-glyph box;
each feature tile must paint glyph groups that are neither that box nor a hollow
rectangle. Slot (0,0) is the element's top-left."""
from style_coverage_rules_sc14 import _ink

TOFU_TILE = 5  # index of risky:tofuRef (fixtures/style-coverage/index.js, appended last)


def _groups(pts):
    cols = sorted({x for x, _ in pts})
    runs, cur = [], None
    for x in cols:
        if cur and x == cur[1] + 1:
            cur[1] = x
        else:
            cur = [x, x]
            runs.append(cur)
    out = []
    for a, b in runs:
        g = [p for p in pts if a <= p[0] <= b]
        ys = [y for _, y in g]
        out.append((a, min(ys), b, max(ys), set(g)))
    return out


def _mask(g):
    a, t, b, bt, pts = g
    return {(x - a, y - t) for x, y in pts}, b - a + 1, bt - t + 1


def _hollow(g):
    m, w, h = _mask(g)
    if w < 8 or h < 8:
        return False
    inner = sum(1 for x, y in m if 2 <= x < w - 2 and 2 <= y < h - 2)
    return inner < 0.03 * (w - 4) * (h - 4)


def _is_tofu(g, ref):
    m, w, h = _mask(g)
    rm, rw, rh = ref
    if abs(w - rw) > 2 or abs(h - rh) > 2:
        return False
    return len(m ^ rm) < 0.12 * rw * rh


def _glyphs(ctl, feat, want_min=1):
    ink = _ink(feat, -22, 90, thresh=200)
    gs = [g for g in _groups(ink) if len(g[4]) >= 20]
    if len(gs) < want_min:
        return None, f"{len(gs)} glyph groups with ink, want >= {want_min}"
    ref_pts = _ink(feat.f.slot(TOFU_TILE, 'f'), -22, 90, thresh=200)
    refg = _groups(ref_pts)
    if not refg:
        return None, "tofuRef tile has no ink (instrument missing)"
    ref = _mask(refg[0])
    for g in gs:
        if _hollow(g):
            return None, f"group at x={g[0]} is a hollow rectangle"
        if _is_tofu(g, ref):
            return None, f"group at x={g[0]} matches the tofuRef box ({ref[1]}x{ref[2]})"
    return gs, ""


def _colours(slot, a, b):
    """Distinct chromatic colour buckets (3 bits per channel) with >= 8 px."""
    seen = {}
    for y in range(-31, 105):
        for x in range(a, b + 1):
            p = slot.px(x, y)
            if max(p) - min(p) > 40:
                k = (p[0] >> 5, p[1] >> 5, p[2] >> 5)
                seen[k] = seen.get(k, 0) + 1
    return sorted(k for k, n in seen.items() if n >= 8)


def _emoji(ctl, feat):
    gs, why = _glyphs(ctl, feat, want_min=3)
    if gs is None:
        return False, why
    face = max(gs, key=lambda g: len(g[4]))
    cols = _colours(feat, face[0], face[2])
    if len(cols) < 2:
        return False, f"emoji face has {len(cols)} colour bucket(s), want >= 2 (monochrome face?)"
    return True, f"{len(gs)} groups, {len(cols)} colour buckets"


def _cjk(ctl, feat):
    gs, why = _glyphs(ctl, feat, want_min=2)
    if gs is None:
        return False, why
    return True, f"{len(gs)} glyph groups, none the tofu box"


def _arabic(ctl, feat):
    gs, why = _glyphs(ctl, feat, want_min=1)
    if gs is None:
        return False, why
    if len(gs) > 3:
        return False, f"{len(gs)} separate groups for 5 letters: not joined"
    pts = set().union(*[g[4] for g in gs])
    x0 = min(x for x, _ in pts)
    x1 = max(x for x, _ in pts)

    def extent(lo, hi):
        ys = [y for x, y in pts if lo <= x <= hi]
        return max(ys) - min(ys) + 1 if ys else 0

    left, right = extent(x0, x0 + 1), extent(x1 - 1, x1)
    # The final alef (a tall stem) is the last letter: leftmost when shaped RTL.
    if left < 10 or left <= right:
        return False, f"alef stem not at the left end (left {left} rows, right {right}): not RTL"
    return True, f"{len(gs)} joined group(s), alef at left ({left} rows vs {right})"


def _tofu(ctl, feat):
    if not _groups(_ink(feat, -22, 90, thresh=200)):
        return False, "no ink"
    return True, ""


RULES = {
    'risky:emoji': _emoji,
    'risky:cjk': _cjk,
    'risky:arabic': _arabic,
    'risky:tofuRef': _tofu,
}
