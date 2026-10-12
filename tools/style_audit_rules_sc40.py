"""SC-40 helpers for grid 1 (tools/style-audit-measure.py): rules that hold for
every platform face, not only the linux/darwin ones they were written on.

Windows' Segoe UI draws a 20 pt underline/strike ~1.3 px thick at a
fractional y, so no single row is solid black (rows of lum 64 + 191). A
decoration line is therefore judged on COVERAGE: across a 2-row window every
column must carry >= 0.9 px of ink of the wanted colour. A missing, partial,
misplaced or wrong-colour line still fails; a 2 px solid line covers 2.0.
Segoe UI also kerns 'AA' until the antialiased fringes touch, so blob rules
retry with a darker ink threshold (glyph cores only) before failing."""

WHITE = (255, 255, 255)


def black_cover(p):
    """Fraction of a pixel covered by black ink over white (0 for colour)."""
    r, g, b = p
    if max(r, g, b) - min(r, g, b) > 40:
        return 0.0
    return (255 - max(r, g, b)) / 255


def red_cover(p):
    """Fraction of a pixel covered by pure red over white."""
    r, g, b = p
    return (255 - max(g, b)) / 255 if r >= 200 else 0.0


def is_reddish(p):
    return red_cover(p) >= 0.15 and p[0] - max(p[1], p[2]) >= 40


def line_at(px, y, x0, x1, cover=black_cover):
    """Rows y..y+1 together hold an unbroken line spanning x0..x1. The two end
    columns are the glyphs' antialiased fringe: they need half coverage."""
    def col(x):
        return cover(px[(x, y)]) + cover(px.get((x, y + 1), WHITE))
    return all(col(x) >= (0.4 if x in (x0, x1) else 0.9) for x in range(x0, x1 + 1))


def any_dark(rule, blobs_fn, darks=(600, 450)):
    """rule(blobs_fn bound to one ink threshold) passes at any threshold.
    Both slots use the same threshold inside one evaluation."""
    return any(rule(lambda px, d=d: blobs_fn(px, d)) for d in darks)
