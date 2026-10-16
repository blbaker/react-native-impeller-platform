#!/usr/bin/env python3
"""FP-51 golden compare. Stdlib only (the Mac has no numpy/PIL).

  golden_compare.py compare ACTUAL.ppm GOLDEN.png --pct P --delta D [--diff OUT.png] [--name N]
  golden_compare.py topng IN.ppm OUT.png
  golden_compare.py mutate IN.png OUT.png (--add N | --shift-x N | --lsb)

Tolerance policy: a pixel is "off" when any channel differs by more than --delta levels. The
case passes when off pixels are at most --pct percent of all pixels. Different dimensions
always fail. Goldens are written here with PNG filter 0 so the reader stays a few lines.
"""
import argparse, struct, sys, zlib

def read_ppm(path):
    d = open(path, "rb").read()
    if d[:2] != b"P6":
        raise SystemExit(f"{path}: not a P6 ppm")
    toks, i = [], 2
    while len(toks) < 3:
        while d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b"#":
            i = d.index(b"\n", i)
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        toks.append(int(d[i:j])); i = j
    w, h, _ = toks
    body = d[i + 1:]
    if len(body) != w * h * 3:
        raise SystemExit(f"{path}: truncated ppm")
    return w, h, [body[y * w * 3:(y + 1) * w * 3] for y in range(h)]

def write_png(path, w, h, rows):
    raw = b"".join(b"\0" + r for r in rows)
    def ch(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + ch(b"IDAT", zlib.compress(raw, 9)) + ch(b"IEND", b""))

def read_png(path):
    d = open(path, "rb").read()
    if d[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a png")
    i, idat, hdr = 8, b"", None
    while i < len(d):
        n, t = struct.unpack(">I4s", d[i:i + 8])
        body = d[i + 8:i + 8 + n]
        if t == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif t == b"IDAT":
            idat += body
        i += 12 + n
    w, h, depth, ctype, _, _, inter = hdr
    if (depth, ctype, inter) != (8, 2, 0):
        raise SystemExit(f"{path}: need 8-bit RGB non-interlaced (made by golden_compare topng)")
    raw, stride = zlib.decompress(idat), w * 3
    rows = []
    for y in range(h):
        o = y * (stride + 1)
        if raw[o] != 0:
            raise SystemExit(f"{path}: PNG filter {raw[o]} (only filter 0 supported)")
        rows.append(raw[o + 1:o + 1 + stride])
    return w, h, rows

def compare(a, g, pct, delta, diff, name):
    (aw, ah, ar), (gw, gh, gr) = a, g
    if (aw, ah) != (gw, gh):
        print(f"GOLDEN_FAIL {name}: size {aw}x{ah} != golden {gw}x{gh}")
        return 1
    off = maxd = 0
    drows = []
    for y in range(ah):
        ra, rg = ar[y], gr[y]
        if ra == rg:
            drows.append(None)
            continue
        d = bytes(abs(p - q) for p, q in zip(ra, rg))
        m = max(d)
        maxd = max(maxd, m)
        if m > delta:
            off += sum(1 for x in range(aw) if max(d[x * 3:x * 3 + 3]) > delta)
        drows.append(d)
    total = aw * ah
    p = 100.0 * off / total
    ok = p <= pct
    print(f"GOLDEN_{'PASS' if ok else 'FAIL'} {name}: off_px={off} ({p:.4f}% of {total}, limit {pct}%) "
          f"max_channel_delta={maxd} (tolerated {delta})")
    if diff and (not ok or diff != "-"):
        rows = []
        for y in range(ah):
            d = drows[y]
            if d is None:
                mid = bytes([235, 235, 235]) * aw
            else:
                mid = bytearray()
                for x in range(aw):
                    m = max(d[x * 3:x * 3 + 3])
                    mid += bytes([255, 0, 0]) if m > delta else bytes([255 - min(255, m * 8)] * 3)
                mid = bytes(mid)
            rows.append(gr[y] + ar[y] + mid)
        write_png(diff, aw * 3, ah, rows)
    return 0 if ok else 1

def mutate(g, mode, n):
    w, h, rows = g
    if mode == "add":
        t = bytes(min(255, v + n) for v in range(256))
        return w, h, [r.translate(t) for r in rows]
    if mode == "lsb":  # +1, or -1 at 255, so every pixel moves exactly one level
        t = bytes(v + 1 if v < 255 else 254 for v in range(256))
        return w, h, [r.translate(t) for r in rows]
    out = []
    for r in rows:  # shift-x: edge-replicating horizontal shift by n pixels
        out.append(r[:3] * n + r[:len(r) - 3 * n] if n > 0 else r[3 * -n:] + r[-3:] * -n)
    return w, h, out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["compare", "topng", "mutate"])
    ap.add_argument("a"); ap.add_argument("b")
    ap.add_argument("--pct", type=float, default=0.0); ap.add_argument("--delta", type=int, default=0)
    ap.add_argument("--diff"); ap.add_argument("--name", default="case")
    ap.add_argument("--add", type=int); ap.add_argument("--shift-x", type=int, dest="shift"); ap.add_argument("--lsb", action="store_true")
    o = ap.parse_args()
    if o.cmd == "topng":
        w, h, rows = read_ppm(o.a); write_png(o.b, w, h, rows)
    elif o.cmd == "mutate":
        g = read_png(o.a)
        m = mutate(g, "lsb", 0) if o.lsb else mutate(g, "add", o.add) if o.add is not None else mutate(g, "shift", o.shift)
        write_png(o.b, *m)
    else:
        try:
            g = read_png(o.b)
        except FileNotFoundError:
            print(f"GOLDEN_FAIL {o.name}: missing golden {o.b}")
            return 1
        return compare(read_ppm(o.a), g, o.pct, o.delta, o.diff, o.name)
    return 0

sys.exit(main())
