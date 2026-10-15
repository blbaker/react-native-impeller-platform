#!/usr/bin/env python3
"""Bright-pixel bounding box + centre luma of a P6 PPM. Stdlib only (the Mac
runs it with /usr/bin/python3, no Pillow).

  usage: ppm_bbox.py <file.ppm> [threshold=128] [layout_width]

Prints ONE line of key=value pairs, in LAYOUT points. The pixel-to-point scale
is the PPM width divided by `layout_width` (default: the PPM width, i.e. 1x),
so a 2x Retina capture reads the same as a 1x one.

  w h          surface size
  bw bh        bounding box of pixels with luma >= threshold (0 0 if none)
  cx cy        centre of that box
  lit          number of points >= threshold (pixels / scale^2)
  centre_luma  mean luma of a 6x4-point patch at the surface centre

luma = (r*299 + g*587 + b*114) // 1000. A pixel exactly on the threshold
counts as lit, so a 50%-covered anti-aliased edge pixel is inside the box.
"""
import sys


def read_ppm(path):
    data = open(path, 'rb').read()
    # Header: "P6\n<w> <h>\n255\n" (Pixel.cpp), but tolerate any whitespace.
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1
    if fields[0] != b'P6':
        raise SystemExit('ppm_bbox: not a P6 PPM: %s' % path)
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos:pos + w * h * 3]


def measure(path, thr=128, layout_w=None):
    w, h, px = read_ppm(path)
    scale = max(1, w // layout_w) if layout_w else 1
    x0, y0, x1, y1, lit = w, h, -1, -1, 0
    for y in range(h):
        row = y * w * 3
        for x in range(w):
            i = row + x * 3
            if (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000 >= thr:
                lit += 1
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
    if lit:
        bw, bh = (x1 - x0 + 1) / scale, (y1 - y0 + 1) / scale
        cx, cy = (x0 + x1 + 1) / 2 / scale, (y0 + y1 + 1) / 2 / scale
    else:
        bw = bh = cx = cy = 0.0
    # Centre patch, 6x4 points.
    pw, ph = 6 * scale, 4 * scale
    sx, sy = w // 2 - pw // 2, h // 2 - ph // 2
    tot = 0
    for y in range(sy, sy + ph):
        for x in range(sx, sx + pw):
            i = (y * w + x) * 3
            tot += (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) // 1000
    return {
        'w': w // scale, 'h': h // scale, 'scale': scale,
        'bw': bw, 'bh': bh, 'cx': cx, 'cy': cy,
        'lit': lit // (scale * scale), 'centre_luma': tot / (pw * ph),
    }


def fmt(m):
    return ('w=%d h=%d bw=%.0f bh=%.0f cx=%.1f cy=%.1f lit=%d centre_luma=%.0f'
            % (m['w'], m['h'], m['bw'], m['bh'], m['cx'], m['cy'], m['lit'],
               m['centre_luma']))


if __name__ == '__main__':
    thr = int(sys.argv[2]) if len(sys.argv) > 2 else 128
    lw = int(sys.argv[3]) if len(sys.argv) > 3 else None
    print(fmt(measure(sys.argv[1], thr, lw)))
