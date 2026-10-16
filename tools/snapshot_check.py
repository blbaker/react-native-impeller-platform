#!/usr/bin/env python3
"""FP-43 checker for tools/ci-snapshot.sh. Node-free, stdlib only (PIL optional for the jpg arm).

  snapshot_check.py <run.log> <screenshot.ppm> <scale> <tag> [render_thread]

The capture of the target view (fixtures/fp43-snapshot: (40,30) 240x180 pt) must
equal the on-screen crop of the same box within 2 levels per channel, upright,
at the device scale; the other view-shot results must agree with it.
"""
import base64, os, re, struct, sys, zlib

TARGET = (40, 30, 240, 180)  # pt
MARKER = (186, 146, 40, 24)  # pt, inside the target: red, bottom-right
TOL = 2


def bad(tag, msg):
    print("SNAPSHOT_FAIL: %s: %s" % (tag, msg), file=sys.stderr)
    sys.exit(1)


def read_ppm(path):
    data = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    w, h = int(parts[1]), int(parts[2])
    px = data[i:i + w * h * 3]
    return w, h, [tuple(px[k:k + 3]) for k in range(0, len(px), 3)]


def read_png(path):
    """8-bit RGB/RGBA, non-interlaced: returns w, h, [(r,g,b,a)] row-major."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    i, idat, w = 8, b"", 0
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        t, body = data[i + 4:i + 8], data[i + 8:i + 8 + n]
        if t == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError("unsupported PNG depth=%d type=%d" % (depth, ctype))
            bpp = 4 if ctype == 6 else 3
        elif t == b"IDAT":
            idat += body
        i += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line
        prev = line
    if bpp == 3:
        return w, h, [tuple(out[k:k + 3]) + (255,) for k in range(0, len(out), 3)]
    return w, h, [tuple(out[k:k + 4]) for k in range(0, len(out), 4)]


def crop(w, px, x0, y0, cw, ch):
    return [px[(y0 + y) * w + x0 + x] for y in range(ch) for x in range(cw)]


def diff(a, b):
    """max channel diff and count of pixels over TOL."""
    worst, over = 0, 0
    for p, q in zip(a, b):
        d = max(abs(p[0] - q[0]), abs(p[1] - q[1]), abs(p[2] - q[2]))
        worst = max(worst, d)
        over += d > TOL
    return worst, over


def flip(px, w, h):
    return [px[(h - 1 - y) * w + x] for y in range(h) for x in range(w)]


def jpeg_size(path):
    data = open(path, "rb").read()
    if data[:2] != b"\xff\xd8" or data[-2:] != b"\xff\xd9":
        raise SystemExit("SNAPSHOT_FAIL: %s is not a JPEG" % path)
    i = 2
    while i < len(data):
        marker, n = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + n
    raise SystemExit("SNAPSHOT_FAIL: %s has no SOF" % path)


def path_of(uri):
    return uri[len("file://"):] if uri.startswith("file://") else uri


def main():
    log_path, ppm_path, scale, tag = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    render_thread = sys.argv[5] if len(sys.argv) > 5 else "raster"
    log = open(log_path, errors="replace").read()

    def js(key):
        m = re.search(r"^\[js\] FP43 %s (.*)$" % key, log, re.M)
        if not m:
            bad(tag, "no `FP43 %s` line from JS (capture never resolved?)" % key)
        return m.group(1)

    if not re.search(r"^\[js\] FP43 done$", log, re.M):
        err = re.search(r"^\[js\] FP43 error (.*)$", log, re.M)
        bad(tag, "JS did not finish: %s" % (err.group(1) if err else "no `FP43 done` line"))

    # Threads: requested on JS, recorded on main, rendered off JS, encoded on the
    # encoder thread, settled on JS.
    for kind, want in (("request", "js"), ("record", "main"), ("render", render_thread),
                       ("done", "snapshot"), ("resolve", "js")):
        threads = re.findall(r"^rn-impeller: snapshot_%s id=\d+ .*thread=(\S+)" % kind, log, re.M)
        if not threads:
            bad(tag, "no snapshot_%s lines" % kind)
        if sys.platform.startswith("linux") and set(threads) != {want}:
            bad(tag, "snapshot_%s ran on %s, wanted %s" % (kind, sorted(set(threads)), want))

    sw, sh, screen = read_ppm(ppm_path)
    x0, y0, cw, ch = (v * scale for v in TARGET)
    if x0 + cw > sw or y0 + ch > sh:
        bad(tag, "screenshot %dx%d does not contain the target box" % (sw, sh))
    on_screen = crop(sw, screen, x0, y0, cw, ch)

    png = path_of(js("png uri=([^ ]+)").split()[0])
    if not os.path.exists(png):
        bad(tag, "png tmpfile %s does not exist" % png)
    pw, ph, cap = read_png(png)
    if (pw, ph) != (cw, ch):
        bad(tag, "capture is %dx%d px, wanted %dx%d (the view at scale %d)" % (pw, ph, cw, ch, scale))
    if any(p[3] != 255 for p in cap):
        bad(tag, "capture has non-opaque pixels over an opaque view")
    worst, over = diff(cap, on_screen)
    if over:
        # Name the likely defect: whichever wrong reading the capture matches best.
        fo = diff(cap, flip(on_screen, cw, ch))[1]
        wo = diff(cap, crop(sw, screen, 0, 0, cw, ch))[1]
        if fo < over and fo <= wo:
            bad(tag, "capture is upside down: %d px off the on-screen crop, %d off its Y-flip (Y-flipped readback)" % (over, fo))
        if wo < over:
            bad(tag, "capture shows the window from (0,0), not the view: %d px off the crop, %d off the window corner (whole window captured)" % (over, wo))
        bad(tag, "capture differs from the on-screen crop: %d px over %d levels (max %d)" % (over, TOL, worst))
    mx, my = (MARKER[0] + MARKER[2] // 2) * scale, (MARKER[1] + MARKER[3] // 2) * scale
    p = cap[my * pw + mx]
    if not (p[0] > 200 and p[1] < 60 and p[2] < 60):
        bad(tag, "the red marker is not at the capture's bottom-right (%s)" % (p[:3],))

    raw = open(png, "rb").read()
    want_b64 = base64.b64encode(raw).decode()
    m = re.match(r"len=(\d+) head=(\S+)$", js("b64"))
    if not m or int(m.group(1)) != len(want_b64) or m.group(2) != want_b64[:64]:
        bad(tag, "result base64 is not the png's base64 (%s)" % js("b64")[:80])
    m = re.match(r"head=(\S+) len=(\d+)$", js("datauri"))
    if not m or m.group(1) != "data:image/png;base64,iVBORw0K" or int(m.group(2)) != len(want_b64) + 22:
        bad(tag, "result data-uri is wrong (%s)" % js("datauri")[:80])

    jpg = path_of(js("jpg uri=([^ ]+)").split()[0])
    jw, jh = jpeg_size(jpg)
    if (jw, jh) != (cw, ch):
        bad(tag, "jpg is %dx%d, wanted %dx%d" % (jw, jh, cw, ch))
    jpg_note = ""
    try:
        from PIL import Image
        jb = Image.open(jpg).convert("RGB").tobytes()
        jpx = [tuple(jb[k:k + 3]) for k in range(0, len(jb), 3)]
        mean = sum(abs(a - b) for p, q in zip(jpx, on_screen) for a, b in zip(p, q)) / (3.0 * len(jpx))
        if mean > 6:
            bad(tag, "jpg (quality 0.9) is %.1f levels off the on-screen crop on average" % mean)
        jpg_note = " jpg_mean_diff=%.2f" % mean
    except ImportError:
        jpg_note = " jpg=size-only"
    rel = path_of(js("released uri=([^ ]+)").split()[0])
    if "/fp43-release-" not in rel:
        bad(tag, "fileName prefix not used: %s" % rel)
    if os.path.exists(rel):
        bad(tag, "releaseCapture did not delete %s" % rel)

    sized = path_of(js("sized uri=([^ ]+)").split()[0])
    zw, zh, zpx = read_png(sized)
    if (zw, zh) != (120, 90):
        bad(tag, "width/height 120x90 gave %dx%d" % (zw, zh))
    p = zpx[int(my * 90 / ch) * zw + int(mx * 120 / cw)]
    if not (p[0] > 180 and p[1] < 90 and p[2] < 90):
        bad(tag, "sized capture: no red marker at its bottom-right (%s)" % (p[:3],))

    whole = path_of(js("screen uri=([^ ]+)").split()[0])
    ww_, wh_, wpx = read_png(whole)
    if (ww_, wh_) != (sw, sh):
        bad(tag, "captureScreen is %dx%d, the window is %dx%d" % (ww_, wh_, sw, sh))
    worst_s, over_s = diff(wpx, screen)
    if over_s:
        bad(tag, "captureScreen differs from the window: %d px over %d levels (max %d)" % (over_s, TOL, worst_s))

    if "No view found with reactTag: 987654" not in js("reject"):
        bad(tag, "captureRef on a missing tag: %s" % js("reject"))
    summ = re.search(r"^rn-impeller: snapshots requested=8 rendered=7 encoded=7 failed=1 requeued=\d+ released=1$", log, re.M)
    if not summ:
        bad(tag, "summary line wrong: %s" % re.findall(r"^rn-impeller: snapshots .*$", log, re.M))
    print("%s: OK scale=%d capture=%dx%d max_diff=%d screen_max_diff=%d bytes=%d%s" % (
        tag, scale, pw, ph, worst, worst_s, len(raw), jpg_note))


if __name__ == "__main__":
    main()
