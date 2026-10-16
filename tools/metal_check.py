#!/usr/bin/env python3
"""FP-21 pixel checks for tools/ci-metal.sh (node-free, stdlib only).

  metal_check.py diff A.ppm B.ppm              per-pixel compare, prints one `diff ...` line
  metal_check.py aa N0.ppm REF.ppm X Y W H     icon-edge AA metric of N0 inside the box (device px)
  metal_check.py blank A.ppm                   prints `ink=<non-background px> distinct=<colours>`

AA metric (the chevron of fixtures/eng-supersample): the edge set is every pixel
where the N=16 reference is partial or a 4-neighbour of it differs. On it:
partial = share of edge pixels strictly between the stroke core (128) and the
background (255); err = mean |N0 - REF| over the edge (lower = closer to the
16x16-sample ground truth); levels = distinct intermediate greys.
"""
import sys


def read(path):
    d = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b"#":
            while d[i:i + 1] != b"\n":
                i += 1
            continue
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        parts.append(d[s:i])
    assert parts[0] == b"P6", path
    return int(parts[1]), int(parts[2]), d[i + 1:]


def diff(a, b):
    wa, ha, pa = read(a)
    wb, hb, pb = read(b)
    if (wa, ha) != (wb, hb):
        print(f"diff size_mismatch a={wa}x{ha} b={wb}x{hb}")
        return
    n = wa * ha
    total = bad = mx = 0
    for i in range(0, n * 3, 3):
        m = max(abs(pa[i] - pb[i]), abs(pa[i + 1] - pb[i + 1]), abs(pa[i + 2] - pb[i + 2]))
        total += m
        mx = max(mx, m)
        if m > 24:
            bad += 1
    print(f"diff size={wa}x{ha} mean={total / n:.4f} max={mx} over24={bad} over24_pct={100.0 * bad / n:.4f}")


def aa(n0, ref, x0, y0, w, h):
    W, H, p = read(n0)
    W2, H2, r = read(ref)
    assert (W, H) == (W2, H2), "size mismatch"

    def lum(px, x, y):
        return px[(y * W + x) * 3]

    edge = []
    for y in range(max(1, y0), min(H - 1, y0 + h)):
        for x in range(max(1, x0), min(W - 1, x0 + w)):
            v = lum(r, x, y)
            if 128 < v < 255 or any(lum(r, x + dx, y + dy) != v for dx, dy in ((1, 0), (0, 1), (-1, 0), (0, -1))):
                edge.append((x, y))
    if not edge:
        print("aa edge=0")
        return
    part = sum(1 for x, y in edge if 128 < lum(p, x, y) < 255)
    err = sum(abs(lum(p, x, y) - lum(r, x, y)) for x, y in edge) / len(edge)
    levels = len({lum(p, x, y) for x, y in edge if 128 < lum(p, x, y) < 255})
    ink = sum(1 for y in range(y0, min(H, y0 + h)) for x in range(x0, min(W, x0 + w)) if lum(p, x, y) != 255)
    print(f"aa edge={len(edge)} partial_pct={100.0 * part / len(edge):.1f} err={err:.2f} levels={levels} ink={ink}")


def blank(a):
    w, h, p = read(a)
    bg = p[0:3]
    ink = sum(1 for i in range(0, w * h * 3, 3) if p[i:i + 3] != bg)
    distinct = len({p[i:i + 3] for i in range(0, w * h * 3, 3 * 7)})
    print(f"blank size={w}x{h} ink={ink} distinct={distinct}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "diff":
        diff(sys.argv[2], sys.argv[3])
    elif cmd == "aa":
        aa(sys.argv[2], sys.argv[3], *map(int, sys.argv[4:8]))
    elif cmd == "blank":
        blank(sys.argv[2])
    else:
        sys.exit(f"unknown command {cmd}")
