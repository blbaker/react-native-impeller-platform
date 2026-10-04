#!/usr/bin/env python3
"""ENG-21: compare a <world> region of a P6 PPM against CPU composites.

usage: world-nearest-diff.py <ppm> <layout_w> <layout_h> <name>:<x0>:<y0>
  Each region is one eng21-world-nearest world: a 20x8 texel terrain at K=12
  (240x96 pt) with a 4x4 checker sprite over texels (2..5, 2..5). The script
  rebuilds that scene on the CPU twice, NEAREST and BILINEAR, at the capture's
  own pixel scale, and prints per region:
    <name> diff_nearest=<mean abs RGB> diff_bilinear=<..> offpalette=<share>
  offpalette = share of pixels whose colour is not one of the 6 the scene can
  produce under nearest (4 terrain + black + white), within 6 levels: blend
  colours that only a linear filter makes. Same measures as ROOM-1 claim 11.
  Pixels within 1 device px of the region's outer edge are skipped (the edge
  of the textured rect itself is antialiased against the page in both modes).
"""
import sys

TW, TH, K = 20, 8, 12
PALETTE = [(220, 40, 40), (40, 180, 60), (40, 60, 220), (240, 220, 40)]
SPR = (2, 2, 4)  # sprite texel origin x, y and size, in terrain texels


def read_ppm(path):
    d = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        s = i
        while not d[i:i + 1].isspace():
            i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i + 1:]


def terrain_texel(x, y):
    return PALETTE[(x + 2 * y) % 4]


def sprite_texel(x, y):
    v = 0 if (x + y) % 2 == 0 else 255
    return (v, v, v)


def sample(texel, tw, th, u, v, nearest):
    """u, v in texel units (0..tw, 0..th), pixel-centre sampled."""
    if nearest:
        return texel(min(tw - 1, max(0, int(u))), min(th - 1, max(0, int(v))))
    fx, fy = u - 0.5, v - 0.5
    x0, y0 = int(fx // 1), int(fy // 1)
    ax, ay = fx - x0, fy - y0
    out = [0.0, 0.0, 0.0]
    for dx, wx in ((0, 1 - ax), (1, ax)):
        for dy, wy in ((0, 1 - ay), (1, ay)):
            c = texel(min(tw - 1, max(0, x0 + dx)), min(th - 1, max(0, y0 + dy)))
            for k in range(3):
                out[k] += c[k] * wx * wy
    return tuple(out)


def reference(px_per_pt, nearest):
    W, H = int(round(TW * K * px_per_pt)), int(round(TH * K * px_per_pt))
    sx, sy = TW / W, TH / H
    sox, soy, ss = SPR
    img = []
    for py in range(H):
        row = []
        v = (py + 0.5) * sy
        for qx in range(W):
            u = (qx + 0.5) * sx
            if sox <= u < sox + ss and soy <= v < soy + ss:
                c = sample(sprite_texel, ss, ss, u - sox, v - soy, nearest)
            else:
                c = sample(terrain_texel, TW, TH, u, v, nearest)
            row.append(c)
        img.append(row)
    return W, H, img


def main():
    path, lw, lh = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    w, h, px = read_ppm(path)
    scale = w / lw
    if abs(h / lh - scale) > 1e-6:
        sys.exit(f"non-uniform capture scale {w}/{lw} vs {h}/{lh}")
    refs = {m: reference(scale, m) for m in (True, False)}
    allowed = PALETTE + [(0, 0, 0), (255, 255, 255)]
    for spec in sys.argv[4:]:
        name, x0, y0 = spec.split(':')
        X0, Y0 = int(round(float(x0) * scale)), int(round(float(y0) * scale))
        W, H, _ = refs[True]
        dn = dl = 0.0
        off = n = 0
        for y in range(1, H - 1):
            for x in range(1, W - 1):
                o = ((Y0 + y) * w + (X0 + x)) * 3
                c = (px[o], px[o + 1], px[o + 2])
                rn, rl = refs[True][2][y][x], refs[False][2][y][x]
                dn += sum(abs(c[k] - rn[k]) for k in range(3)) / 3
                dl += sum(abs(c[k] - rl[k]) for k in range(3)) / 3
                if not any(all(abs(c[k] - a[k]) <= 6 for k in range(3)) for a in allowed):
                    off += 1
                n += 1
        print(f"{name} diff_nearest={dn / n:.3f} diff_bilinear={dl / n:.3f} "
              f"offpalette={off / n:.4f} px={n} scale={scale:g}")


main()
