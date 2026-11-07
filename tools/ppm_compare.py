#!/usr/bin/env python3
"""Compare two P6 PPMs pixel by pixel (stdlib only), and write PNGs.

  ppm_compare.py A.ppm B.ppm [--tol 8] [--crop X,Y,W,H] [--diff-png out.png] [--side-png out.png]
  ppm_compare.py --png in.ppm out.png

Prints one machine-readable line:
  PPM_COMPARE size=WxH differing=N frac=F max_delta=D bbox=x0,y0,x1,y1 tol=T
A pixel "differs" when any channel's absolute delta exceeds --tol.
--crop compares only that rectangle (frac and bbox are then relative to it, and
the line carries crop=X,Y,W,H); it must lie inside both images.
Exit 0 always for a successful comparison (the CALLER owns the threshold), 2 on
a size mismatch or unreadable input.
"""
import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens, i = [], 0
    while len(tokens) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        tokens.append(data[i:j])
        i = j
    if tokens[0] != b"P6":
        raise ValueError(f"{path}: not P6")
    w, h, mx = int(tokens[1]), int(tokens[2]), int(tokens[3])
    if mx != 255:
        raise ValueError(f"{path}: maxval {mx}")
    px = data[i + 1:i + 1 + w * h * 3]
    if len(px) != w * h * 3:
        raise ValueError(f"{path}: truncated")
    return w, h, px


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main(argv):
    if len(argv) >= 3 and argv[0] == "--png":
        w, h, px = read_ppm(argv[1])
        write_png(argv[2], w, h, px)
        print(f"PNG {argv[2]} {w}x{h}")
        return 0
    a, b = argv[0], argv[1]
    tol, diff_png, side_png, crop = 8, None, None, None
    rest = argv[2:]
    while rest:
        k = rest.pop(0)
        if k == "--tol":
            tol = int(rest.pop(0))
        elif k == "--diff-png":
            diff_png = rest.pop(0)
        elif k == "--side-png":
            side_png = rest.pop(0)
        elif k == "--crop":
            crop = tuple(int(v) for v in rest.pop(0).split(","))
    try:
        wa, ha, pa = read_ppm(a)
        wb, hb, pb = read_ppm(b)
    except (OSError, ValueError) as e:
        print(f"PPM_COMPARE error={e}")
        return 2
    if (wa, ha) != (wb, hb):
        print(f"PPM_COMPARE size_mismatch a={wa}x{ha} b={wb}x{hb}")
        return 2
    n = wa * ha
    cx, cy, cw, ch = crop if crop else (0, 0, wa, ha)
    if cw <= 0 or ch <= 0 or cx < 0 or cy < 0 or cx + cw > wa or cy + ch > ha:
        print(f"PPM_COMPARE error=crop {cx},{cy},{cw},{ch} outside {wa}x{ha}")
        return 2
    differing, max_d = 0, 0
    x0, y0, x1, y1 = wa, ha, -1, -1
    diff = bytearray(n * 3) if diff_png else None
    for p in range(n):
        o = p * 3
        if crop and not (cx <= p % wa < cx + cw and cy <= p // wa < cy + ch):
            continue
        d = max(abs(pa[o] - pb[o]), abs(pa[o + 1] - pb[o + 1]), abs(pa[o + 2] - pb[o + 2]))
        if d > max_d:
            max_d = d
        if d > tol:
            differing += 1
            x, y = p % wa, p // wa
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
            if diff is not None:
                diff[o] = 255
        elif diff is not None:
            g = pa[o] // 4
            diff[o] = diff[o + 1] = diff[o + 2] = g
    if diff_png:
        write_png(diff_png, wa, ha, bytes(diff))
    if side_png:
        row = bytearray()
        for y in range(ha):
            row += pa[y * wa * 3:(y + 1) * wa * 3] + b"\xff\x00\xff" * 4 + pb[y * wa * 3:(y + 1) * wa * 3]
        write_png(side_png, wa * 2 + 4, ha, bytes(row))
    bbox = f"{x0},{y0},{x1},{y1}" if differing else "none"
    where = f" crop={cx},{cy},{cw},{ch}" if crop else ""
    print(f"PPM_COMPARE size={wa}x{ha}{where} differing={differing} frac={differing / (cw * ch):.6f} "
          f"max_delta={max_d} bbox={bbox} tol={tol}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
