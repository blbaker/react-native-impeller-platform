"""SC-17 strict rule for grid 2: adjustsFontSizeToFit. 'ABCDEFGHIJ' at 24 pt in an
80 pt wide View, one line. Slot (0,0) is the View's top-left."""
from style_coverage_rules_sc14 import bbox, _ink


def _groups(pts):
    cols = {}
    for x, y in pts:
        cols.setdefault(x, []).append(y)
    out, cur = [], None
    for x in sorted(cols):
        if cur and x == cur["x1"] + 1:
            cur["x1"] = x
            cur["ys"] += cols[x]
        else:
            cur = {"x1": x, "ys": list(cols[x])}
            out.append(cur)
    return out


def _fit(ctl, feat):
    cb, fb = bbox(_ink(ctl, -22, 90)), bbox(_ink(feat, -22, 90))
    if cb is None or fb is None:
        return False, f"no ink: control {cb} feature {fb}"
    fw, fh, ch = fb[2] - fb[0] + 1, fb[3] - fb[1] + 1, cb[3] - cb[1] + 1
    if fw > 80:
        return False, f"feature ink {fw} px wide, want <= 80"
    if fw < 50:
        return False, f"feature ink only {fw} px wide: text shrank too far or vanished"
    if fh >= ch - 3:
        return False, f"feature ink {fh} px tall vs control {ch}: font not smaller"
    # An ellipsis is dots at most 3 rows tall; every glyph of the shrunk text is taller.
    short = [g for g in _groups(_ink(feat, -22, 90)) if max(g["ys"]) - min(g["ys"]) < 4]
    if short:
        return False, f"{len(short)} dot-sized ink group(s): text was ellipsized, not scaled"
    return True, f"feature {fw}x{fh} px, control height {ch}"


RULES = {'g2:adjustsFontSize': _fit}
