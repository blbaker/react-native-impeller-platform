#!/usr/bin/env python3
"""RN-core gate helper (tools/ci-rn-core.sh). Stdlib only, so the Mac runs it.

  gen-card <out.png>                 the fixture's 120x168 card: red/green/blue bands
  image <shot.ppm> <mode>            row 2 pixel rules for one resizeMode run
  differ <a.ppm> <b.ppm>             box B crops of two runs must differ (cover vs contain)
  anim <shot0> <shot1> <shot2>       row 6: box opacity strictly increases across the shots
  blurfilter <on.ppm> <off.ppm>      row 5: filter blur softens the hard edge, interiors stay flat
"""
import struct
import sys
import zlib

W, H = 120, 168
BANDS = [(255, 0, 0), (0, 200, 0), (0, 0, 255)]
GREY = (128, 128, 128)


def gen_card(path):
    rows = []
    for y in range(H):
        c = BANDS[min(2, y // 56)]
        rows.append(b"\x00" + bytes(c) * W)
    raw = b"".join(rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def read_ppm(path):
    data = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    assert parts[0] == b"P6", "not a P6 ppm"
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i:i + w * h * 3]


def read_png(path):
    """8-bit RGB/RGBA non-interlaced PNG -> (w, h, rgb bytes). Stdlib only."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    i, idat, w, h, bpp = 8, b"", 0, 0, 3
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        tag, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, f"unsupported png {depth}/{ctype}/{interlace}"
            bpp = 3 if ctype == 2 else 4
        elif tag == b"IDAT":
            idat += body
        i += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    out, prev = bytearray(), bytearray(stride)
    p = 0
    for _ in range(h):
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        for x in range(0, stride, bpp):
            out += line[x:x + 3]
        prev = line
    return w, h, bytes(out)


class Shot:
    def __init__(self, path):
        self.w, self.h, self.px = read_png(path) if path.endswith(".png") else read_ppm(path)
        # One PPM pixel per point at --scale 1; derive the scale if not.
        self.s = self.w / 400.0

    def at(self, x, y):
        xi, yi = int(x * self.s), int(y * self.s)
        o = (yi * self.w + xi) * 3
        return tuple(self.px[o:o + 3])


def near(c, ref, tol=24):
    return all(abs(a - b) <= tol for a, b in zip(c, ref))


def name(c):
    for n, ref in (("red", BANDS[0]), ("green", BANDS[1]), ("blue", BANDS[2]), ("grey", GREY), ("white", (255, 255, 255))):
        if near(c, ref):
            return n
    return "other%s" % (c,)


def check_image(path, mode):
    s = Shot(path)
    fails = []

    def want(x, y, ref_name, why):
        got = name(s.at(x, y))
        ok = got == ref_name
        print(f"  {'ok ' if ok else 'BAD'} ({x},{y}) {why}: want {ref_name} got {got}")
        if not ok:
            fails.append(why)

    # A: natural size, every band paints its colour (centre column).
    want(70, 38, "red", "A natural top band")
    want(70, 94, "green", "A natural middle band")
    want(70, 150, "blue", "A natural bottom band")
    want(135, 94, "white", "A ends at x=130 (natural width 120)")
    # C: the playing-card-back shape, stretch at width/height '100%' in a 60x84 card at (150, 120).
    want(180, 130, "red", "C percent-size card: top band")
    want(180, 162, "green", "C percent-size card: middle band")
    want(180, 195, "blue", "C percent-size card: bottom band")
    want(215, 162, "white", "C ends at x=210 (card width 60)")
    # B: 200x100 box at (150, 10).
    if mode == "stretch":
        want(155, 26, "red", "stretch: top third red at the left edge")
        want(345, 60, "green", "stretch: middle third green at the right edge")
        want(250, 94, "blue", "stretch: bottom third blue")
    elif mode == "cover":
        want(155, 60, "green", "cover: fills to the left edge (no letterbox)")
        want(345, 60, "green", "cover: fills to the right edge")
        want(250, 30, "green", "cover: centre crop, top of box is the middle band")
        want(250, 90, "green", "cover: centre crop, bottom of box is the middle band")
    elif mode == "contain":
        want(160, 60, "grey", "contain: letterbox bar on the left")
        want(340, 60, "grey", "contain: letterbox bar on the right")
        want(250, 20, "red", "contain: whole image, top band visible")
        want(250, 60, "green", "contain: middle band")
        want(250, 100, "blue", "contain: whole image, bottom band visible")
    else:
        fails.append("unknown mode " + mode)
    if fails:
        print(f"RNCORE_IMAGE_FAIL mode={mode}: " + "; ".join(fails))
        return 1
    print(f"RNCORE_IMAGE_OK mode={mode}")
    return 0


def crop_b(s):
    return [s.at(x, y) for y in range(12, 108, 2) for x in range(152, 348, 2)]


def differ(a, b):
    ca, cb = crop_b(Shot(a)), crop_b(Shot(b))
    diff = sum(1 for p, q in zip(ca, cb) if not near(p, q, 8))
    frac = diff / float(len(ca))
    print(f"  box B samples differing: {diff}/{len(ca)} ({frac:.2%})")
    if frac < 0.2:
        print("RNCORE_IMAGE_FAIL cover and contain crops are (nearly) the same")
        return 1
    print("RNCORE_IMAGE_DIFFER_OK")
    return 0


def box_level(path):
    s = Shot(path)
    vals = [s.at(x, y)[1] for y in range(30, 111, 10) for x in range(30, 111, 10)]
    return sum(vals) / float(len(vals))


def box_x(path):
    """Left edge of the translateX box (white, 60 wide, row y=190), or -1."""
    s = Shot(path)
    for x in range(0, 399):
        if near(s.at(x, 190), (255, 255, 255), 40):
            return x
    return -1


def anim(paths):
    levels = [box_level(p) for p in paths]
    xs = [box_x(p) for p in paths]
    print("  opacity box green level per shot: " + " ".join(f"{v:.1f}" for v in levels))
    print("  translateX box left edge per shot: " + " ".join(str(x) for x in xs))
    ok = all(b > a + 10 for a, b in zip(levels, levels[1:]))
    okx = all(x >= 0 for x in xs) and all(b > a + 10 for a, b in zip(xs, xs[1:]))
    if ok and okx:
        print("RNCORE_ANIM_OK")
        return 0
    why = [] if ok else ["opacity did not strictly increase"]
    why += [] if okx else ["translateX did not strictly increase"]
    print("RNCORE_ANIM_FAIL " + "; ".join(why))
    return 1


def luma(c):
    return int(round(0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]))


def blur_filter(on, off):
    """Row 5, filter style: across the hard black|white edge at x=140 (rows 60..120)."""
    def stats(path):
        s = Shot(path)
        levels, steps, widths = set(), [], []
        for y in range(60, 121, 4):
            row = [luma(s.at(x, y)) for x in range(100, 181)]
            levels.update(row)
            steps.append(max(abs(b - a) for a, b in zip(row, row[1:])))
            widths.append(sum(1 for v in row if 20 < v < 235))
        return len(levels), max(steps), min(widths), s
    lf, sf, wf, soff = stats(off)
    lo, so, wo, son = stats(on)
    print(f"  blur OFF: distinct luma across the edge={lf} max adjacent step={sf} transition px={wf}")
    print(f"  blur ON : distinct luma across the edge={lo} max adjacent step={so} transition px={wo}")
    fails = []
    if not (lf <= 3 and sf >= 200):
        fails.append("OFF control is not a hard edge (instrument)")
    if not (so * 4 <= sf and wo >= 6 and lo >= 10):
        fails.append("ON edge is still hard")
    # Far from the edge the blur must leave the flat colours alone.
    far = [luma(son.at(60, 90)), luma(son.at(220, 90))]
    print(f"  blur ON : flat interiors luma {far[0]} (black side) {far[1]} (white side)")
    if not (far[0] <= 20 and far[1] >= 235):
        fails.append("blur smeared the flat interiors (radius wrong or whole box washed)")
    if fails:
        print("RNCORE_BLUR_FILTER_FAIL " + "; ".join(fails))
        return 1
    print("RNCORE_BLUR_FILTER_OK")
    return 0


if __name__ == "__main__":
    from rn_core_video import frame_number, gen_video_frames, video_check, video_seek_check
    cmd = sys.argv[1]
    if cmd == "gen-video-frames":
        gen_video_frames(sys.stdout.buffer)
        sys.exit(0)
    if cmd == "framenum":
        k, amb = frame_number(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        print(f"{k}{' AMBIGUOUS' if amb else ''}")
        sys.exit(1 if amb else 0)
    if cmd == "video":
        sys.exit(video_check(sys.argv[2:]))
    if cmd == "videoseek":
        sys.exit(video_seek_check(sys.argv[2:]))
    if cmd == "blurfilter":
        sys.exit(blur_filter(sys.argv[2], sys.argv[3]))
    if cmd == "gen-card":
        gen_card(sys.argv[2])
        sys.exit(0)
    if cmd == "image":
        sys.exit(check_image(sys.argv[2], sys.argv[3]))
    if cmd == "differ":
        sys.exit(differ(sys.argv[2], sys.argv[3]))
    if cmd == "anim":
        sys.exit(anim(sys.argv[2:]))
    sys.exit("unknown command " + cmd)
