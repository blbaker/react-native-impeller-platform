"""SC-41 helpers for the audit rules. Roboto (android) kerns 'AA' into one
8-connected blob at every dark threshold, so glyph-box rules see three glyphs
in 'AABB'. split_kerned() splits a blob at least 1.6x as wide as the median of
the others at its thinnest column in the middle third (the kerning seam)."""


def split_kerned(blobs_fn, dark_of=lambda v: sum(v)):
    def fn(px, dark=600):
        out = blobs_fn(px, dark)
        if len(out) < 2:
            return out
        res = []
        for i, b in enumerate(out):
            others = sorted(o[2] - o[0] + 1 for j, o in enumerate(out) if j != i)
            med = others[len(others) // 2]
            x0, y0, x1, y1, n = b
            if x1 - x0 + 1 < 1.6 * med:
                res.append(b)
                continue
            w = x1 - x0 + 1
            cols = range(x0 + w // 3, x1 - w // 3 + 1)
            cnt = {x: sum(1 for y in range(y0, y1 + 1)
                          if (x, y) in px and px[(x, y)] != (255, 255, 255) and dark_of(px[(x, y)]) < dark)
                   for x in cols}
            s = min(cols, key=lambda x: (cnt[x], abs(x - (x0 + x1) / 2)))
            res += [(x0, y0, s - 1, y1, n), (s + 1, y0, x1, y1, n)]
        return sorted(res)
    return fn
