"""SC-28 strict rule for grid 1 (tools/style-audit-measure.py): ActivityIndicator.
A 60x60 slot holds a large (36 pt) red spinner; the control is an empty View. The
iOS spinner is 12 rounded spokes around the slot centre (59.5, 60.5), an empty hub,
the head spoke opaque and the others fading, so the ink is red at >= 4 alpha levels."""
import math

CX, CY = 59.5, 60.5


def _ink(v): return v != (255, 255, 255)


def _red_tint(v): return v[0] >= 250 and abs(v[1] - v[2]) <= 2


def _spoke_core(f, i, r=14.3):
    """Most saturated green value in the 3x3 around spoke i's mid point (30 deg steps from 12 o'clock)."""
    a = math.radians(30 * i)
    px, py = round(CX + r * math.sin(a)), round(CY - r * math.cos(a))
    return min(f[(px + dx, py + dy)][1] for dx in (-1, 0, 1) for dy in (-1, 0, 1))


def _spokes_fade(f):
    """All 12 spokes sit on the ring; their alpha takes >= 4 distinct levels (20-wide buckets)
    from an opaque head to a faint tail. Antialiased edges cannot fake this: only spoke cores count."""
    cores = [_spoke_core(f, i) for i in range(12)]
    return (max(cores) < 250 and min(cores) < 40 and max(cores) > 180
            and len({c // 20 for c in cores}) >= 4)


def spinner_ok(c, f, d):
    if any(_ink(v) for v in c.values()):
        return False
    pts = [(k, v) for k, v in f.items() if _ink(v)]
    if len(pts) < 100 or not all(_red_tint(v) for _, v in pts):
        return False
    if not _spokes_fade(f):
        return False
    dist = [math.hypot(x - CX, y - CY) for (x, y), _ in pts]
    if min(dist) < 8 or max(dist) > 19.5:
        return False
    xs, ys = [k[0] for k, _ in pts], [k[1] for k, _ in pts]
    if abs((min(xs) + max(xs)) / 2 - CX) > 2.5 or abs((min(ys) + max(ys)) / 2 - CY) > 2.5:
        return False
    quads = {(x > CX, y > CY) for (x, y), _ in pts}
    return len(quads) == 4
