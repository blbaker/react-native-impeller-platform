#!/usr/bin/env python3
"""FP-16 helper for tools/ci-image-io.sh. Subcommands:
  gen-many DIR N          N distinct 64x64 PNGs img-<i>.png, prints nothing
  gen-big DIR             big.png 8000x6000 (1-px checker, 20 colour bands) + small.png 200x200
  gen-formats DIR         fmt-*.png 300x200, one per PNG colour type / bit depth / tRNS case,
                          rows cycling filter types 0..4, + fmt-*.expect.npy (stb-equivalent RGBA8)
  run OUT.json -- CMD...  runs CMD, samples /proc/<pid> every 1 ms: peak threads, pool threads, VmHWM
  cmp-big DIR DUMPDIR     max |engine - PIL BOX(big.png)| over the dumped decode, prints it
  cmp-formats DIR DUMPDIR prints one 'fmt <name> <w>x<h> maxdiff=<d>' line per format
  tiles PPM N BOX GAP COLS  checks the centre pixel of every grid tile against gen-many's colours
"""
import json, os, struct, subprocess, sys, time, zlib

import numpy as np
from PIL import Image


def many_color(i):
    return ((i * 37) % 256, (i * 91) % 256, (i * 13 + 50) % 256)


def gen_many(d, n):
    for i in range(n):
        Image.new("RGB", (64, 64), many_color(i)).save(os.path.join(d, "img-%d.png" % i))


def gen_big(d):
    W, H = 8000, 6000
    rows = []
    for y in range(H):
        segs = []
        for s in range(20):
            a = (int(255 * y / H), (s * 13) % 256, 200 - (s * 7) % 120)
            b = (255 - a[0], 255 - a[1], (a[2] + 90) % 256)
            if y & 1:
                a, b = b, a
            segs.append((bytes(a) + bytes(b)) * 200)
        rows.append(b"".join(segs))
    Image.frombytes("RGB", (W, H), b"".join(rows)).save(os.path.join(d, "big.png"), compress_level=6)
    Image.new("RGB", (200, 200), (10, 20, 30)).save(os.path.join(d, "small.png"))


# ---- a PNG writer covering what PIL cannot emit (16-bit RGB, low-depth grey, every filter type) ----
def chunk(t, data):
    return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xFFFFFFFF)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = np.abs(p - a), np.abs(p - b), np.abs(p - c)
    return np.where((pa <= pb) & (pa <= pc), a, np.where(pb <= pc, b, c))


def filter_row(ft, x, up, bpp):
    x = x.astype(np.int32)
    up = up.astype(np.int32)
    left = np.concatenate([np.zeros(bpp, np.int32), x[:-bpp]])
    upleft = np.concatenate([np.zeros(bpp, np.int32), up[:-bpp]])
    pred = [0, left, up, (left + up) // 2, paeth(left, up, upleft)][ft]
    return ((x - pred) & 255).astype(np.uint8)


def write_png(path, raw_rows, w, h, ctype, depth, extra=b""):
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bpp = max(1, ch * depth // 8)
    out, prev = [], np.zeros(len(raw_rows[0]), np.uint8)
    for y, row in enumerate(raw_rows):
        ft = y % 5
        out.append(bytes([ft]) + filter_row(ft, row, prev, bpp).tobytes())
        prev = row
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + extra
    data += chunk(b"IDAT", zlib.compress(b"".join(out), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)


def pack_bits(vals, depth):  # vals: (h, w) ints < 2**depth, MSB first
    h, w = vals.shape
    per = 8 // depth
    padded = np.zeros((h, (w + per - 1) // per * per), np.uint8)
    padded[:, :w] = vals
    padded = padded.reshape(h, -1, per)
    out = np.zeros(padded.shape[:2], np.uint8)
    for k in range(per):
        out |= (padded[:, :, k] << (8 - depth * (k + 1))).astype(np.uint8)
    return out


def gen_formats(d):
    w, h = 300, 200
    rng = np.random.default_rng(16)
    yy, xx = np.mgrid[0:h, 0:w]
    r = (xx * 255 // (w - 1)).astype(np.uint8)
    g = (yy * 255 // (h - 1)).astype(np.uint8)
    b = ((xx // 3 + yy // 2) * 7 % 256).astype(np.uint8) ^ rng.integers(0, 64, (h, w), dtype=np.uint8)
    a = (((xx + yy) % 50) * 5 + 10).astype(np.uint8)
    lo = rng.integers(0, 256, (h, w), dtype=np.uint8)  # low bytes of 16-bit samples (stb drops them)
    cases = {}

    def put(name, rows, ctype, depth, expect, extra=b""):
        write_png(os.path.join(d, "fmt-%s.png" % name), rows, w, h, ctype, depth, extra)
        np.save(os.path.join(d, "fmt-%s.expect.npy" % name), expect)
        cases[name] = 1

    full = np.full((h, w), 255, np.uint8)
    put("rgb8", list(np.dstack([r, g, b]).reshape(h, -1)), 2, 8, np.dstack([r, g, b, full]))
    put("rgba8", list(np.dstack([r, g, b, a]).reshape(h, -1)), 6, 8, np.dstack([r, g, b, a]))
    put("gray8", list(g), 0, 8, np.dstack([g, g, g, full]))
    put("graya8", list(np.dstack([r, a]).reshape(h, -1)), 4, 8, np.dstack([r, r, r, a]))
    for depth in (1, 2, 4):
        v = (b >> (8 - depth)).astype(np.uint8)
        e = (v.astype(np.int32) * 255 // ((1 << depth) - 1)).astype(np.uint8)
        put("gray%d" % depth, list(pack_bits(v, depth)), 0, depth, np.dstack([e, e, e, full]))
    for depth in (2, 4, 8):
        n = 1 << depth
        pal = rng.integers(0, 256, (n, 3), dtype=np.uint8)
        alpha = rng.integers(0, 256, n, dtype=np.uint8)
        idx = ((xx // 7 + yy // 5) % n).astype(np.uint8)
        rows = list(pack_bits(idx, depth)) if depth < 8 else list(idx)
        extra = chunk(b"PLTE", pal.tobytes()) + chunk(b"tRNS", alpha.tobytes())
        put("pal%d" % depth, rows, 3, depth, np.dstack([pal[idx], alpha[idx]]), extra)

    put("rgb16", list(np.stack([r, lo, g, lo, b, lo], axis=-1).reshape(h, -1)), 2, 16,
        np.dstack([r, g, b, full]))
    put("rgba16", list(np.stack([r, lo, g, lo, b, lo, a, lo], axis=-1).reshape(h, -1)), 6, 16,
        np.dstack([r, g, b, a]))
    # grey 16 with a tRNS key that some pixels hit exactly
    g16hi, g16lo = g, np.where(xx % 9 == 0, 0x5A, lo).astype(np.uint8)
    key = (int(g[0, 0]) << 8) | 0x5A
    hit = (g16hi.astype(np.int32) << 8 | g16lo) == key
    put("gray16key", list(np.stack([g16hi, g16lo], axis=-1).reshape(h, -1)), 0, 16,
        np.dstack([g, g, g, np.where(hit, 0, 255).astype(np.uint8)]),
        chunk(b"tRNS", struct.pack(">H", key)))
    # RGB 8 with a colour key
    kc = (int(r[0, 0]), int(g[0, 0]), int(b[0, 0]))
    hitc = (r == kc[0]) & (g == kc[1]) & (b == kc[2])
    put("rgb8key", list(np.dstack([r, g, b]).reshape(h, -1)), 2, 8,
        np.dstack([r, g, b, np.where(hitc, 0, 255).astype(np.uint8)]),
        chunk(b"tRNS", struct.pack(">HHH", *kc)))
    print(",".join("fmt-%s.png" % k for k in cases))


# ---- run + /proc sampling ----
def run(out, cmd):
    p = subprocess.Popen(cmd, stdout=sys.stdout, stderr=subprocess.STDOUT)
    peak, peak_io, hwm, task = 0, 0, 0, "/proc/%d/task" % p.pid
    while p.poll() is None:
        try:
            for line in open("/proc/%d/status" % p.pid):
                if line.startswith("VmHWM:"):
                    hwm = max(hwm, int(line.split()[1]))
        except (OSError, ValueError):
            pass
        try:
            tids = os.listdir(task)
        except OSError:
            break
        peak = max(peak, len(tids))
        io = 0
        for t in tids:
            try:
                if open("%s/%s/comm" % (task, t)).read().strip() == "rni-image-io":
                    io += 1
            except OSError:
                pass
        peak_io = max(peak_io, io)
        time.sleep(0.001)
    rc = p.wait()
    json.dump({"rc": rc, "peak_threads": peak, "peak_io_threads": peak_io, "rss_hwm_kb": hwm}, open(out, "w"))
    sys.exit(rc)


def read_pam(p):
    b = open(p, "rb").read()
    i = b.index(b"ENDHDR\n") + 7
    hdr = dict(l.split(" ", 1) for l in b[:i].decode().split("\n")[1:-2])
    return np.frombuffer(b[i:], np.uint8).reshape(int(hdr["HEIGHT"]), int(hdr["WIDTH"]), 4)


def dumps(dumpdir, base):
    return [f for f in sorted(os.listdir(dumpdir)) if ("-%s-" % base) in f]


def overlap(src, dst):  # (dst, src) exact length of [j, j+1) inside [o*s, (o+1)*s)
    s = src / dst
    lo = np.arange(dst)[:, None] * s
    j = np.arange(src)[None, :]
    return np.clip(np.minimum(j + 1, lo + s) - np.maximum(j, lo), 0, None)


def premultiply(rgba):
    a = rgba[..., 3:4].astype(np.int32)
    rgb = (rgba[..., :3].astype(np.int32) * a + 127) // 255
    return np.concatenate([rgb, a], axis=-1)


def area_ref(rgba, w, h):
    """Exact area average of the premultiplied image (an overlap-matrix product, row chunks)."""
    wx, wy = overlap(rgba.shape[1], w), overlap(rgba.shape[0], h)
    acc = np.zeros((h, rgba.shape[1], 4))
    for y0 in range(0, rgba.shape[0], 512):
        chunk = premultiply(rgba[y0:y0 + 512]).astype(np.float32)
        for c in range(4):
            acc[:, :, c] += wy[:, y0:y0 + 512] @ chunk[:, :, c]
    out = np.stack([acc[:, :, c] @ wx.T for c in range(4)], axis=-1)
    out /= wx.sum(1)[None, :, None] * wy.sum(1)[:, None, None]
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def pil_box_ref(rgba, w, h):  # PIL's BOX weighs pixels by centre; close to area only at large ratios
    return np.asarray(Image.fromarray(rgba, "RGBA").convert("RGBa").resize((w, h), Image.BOX))


def cmp_big(d, dumpdir):
    f = dumps(dumpdir, "big.png")
    if len(f) != 1:
        print("dumps=%d" % len(f))
        sys.exit(1)
    got = read_pam(os.path.join(dumpdir, f[0])).astype(int)
    src = np.asarray(Image.open(os.path.join(d, "big.png")).convert("RGBA"))
    w, h = got.shape[1], got.shape[0]
    area = np.abs(got - area_ref(src, w, h).astype(int)).max()
    pil = np.abs(got - pil_box_ref(src, w, h).astype(int)).max()
    print("maxdiff=%d pil_box_maxdiff=%d size=%dx%d" % (area, pil, w, h))


def cmp_formats(d, dumpdir):
    for name in sorted(x[4:-4] for x in os.listdir(d) if x.startswith("fmt-") and x.endswith(".png")):
        f = dumps(dumpdir, "fmt-%s.png" % name)
        if len(f) != 1:
            print("fmt %s missing dumps=%d" % (name, len(f)))
            continue
        got = read_pam(os.path.join(dumpdir, f[0]))
        exp = np.load(os.path.join(d, "fmt-%s.expect.npy" % name))
        ref = area_ref(np.ascontiguousarray(exp), got.shape[1], got.shape[0])
        print("fmt %s %dx%d maxdiff=%d" % (name, got.shape[1], got.shape[0],
                                           np.abs(got.astype(int) - ref.astype(int)).max()))


def tiles(ppm, n, box, gap, cols):
    im = np.asarray(Image.open(ppm).convert("RGB")).astype(int)
    bad = 0
    for i in range(n):
        x = (i % cols) * (box + gap) + box // 2
        y = (i // cols) * (box + gap) + box // 2
        if np.abs(im[y, x] - np.array(many_color(i))).max() > 3:
            bad += 1
    print("tiles_bad=%d of %d" % (bad, n))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "gen-many": gen_many(a[1], int(a[2]))
    elif a[0] == "gen-big": gen_big(a[1])
    elif a[0] == "gen-formats": gen_formats(a[1])
    elif a[0] == "run": run(a[1], a[3:])
    elif a[0] == "cmp-big": cmp_big(a[1], a[2])
    elif a[0] == "cmp-formats": cmp_formats(a[1], a[2])
    elif a[0] == "tiles": tiles(a[1], int(a[2]), int(a[3]), int(a[4]), int(a[5]))
    else: sys.exit("unknown subcommand " + a[0])
