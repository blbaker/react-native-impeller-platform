"""SC-30 strict rules for grid 1 (tools/style-audit-measure.py): <Image>.
The 60x60 slot (x 30..89, y 31..90) holds a 4x4 red PNG data: URI (cover).
image: control is a grey box; the feature is red (255,0,0) +/- 6 edge to edge
with nothing outside. imageTint: the control is that red image, the feature
adds tintColor blue, so every pixel becomes (0,0,255) +/- 6."""

BOX = (30, 31, 89, 90)


def _near(p, c, tol=6): return all(abs(a - b) <= tol for a, b in zip(p, c))


def _fills(px, colour):
    x0, y0, x1, y1 = BOX
    for (x, y), v in px.items():
        inside = x0 <= x <= x1 and y0 <= y <= y1
        if inside and not _near(v, colour):
            return False
        if not inside and v != (255, 255, 255):
            return False
    return True


def image_ok(c, f, d):
    return _near(c[(60, 60)], (200, 200, 200), 2) and _fills(f, (255, 0, 0))


def image_tint_ok(c, f, d):
    return _fills(c, (255, 0, 0)) and _fills(f, (0, 0, 255))
