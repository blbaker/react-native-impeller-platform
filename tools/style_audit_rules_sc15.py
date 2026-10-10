"""SC-15 strict rule for grid 1 (tools/style-audit-measure.py): textShadow."""
from style_rules_sc15 import shadow_ok


def text_shadow_ok(c, f, d):
    ok_c = not any(v[2] > 200 and v[0] < 100 for v in c.values())  # control has no blue
    return ok_c and shadow_ok(f, 4)[0]
