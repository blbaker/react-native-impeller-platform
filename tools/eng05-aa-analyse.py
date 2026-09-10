#!/usr/bin/env python3
"""Coverage histogram for the ENG-05 anti-aliasing probe.

Reports, per region, how many painted pixels are PURE ink vs INTERMEDIATE
(partial coverage). Intermediate pixels are the signature of anti-aliasing:
with AA off, a hard-edged shape has only pure-ink and pure-background pixels.
"""
import sys


def read_ppm(path):
    d = open(path, 'rb').read()
    parts = []
    i = 0
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


REGIONS = {
    # name: (left_pt, top_pt, side_pt) — generous boxes around each circle
    "FILL_disc":   (30, 30, 140),
    "STROKE_ring": (210, 30, 140),
}


def analyse(path, scale):
    w, h, px = read_ppm(path)
    print("--- %dx  (image %dx%d) ---" % (scale, w, h))
    for name, (lx, ly, side) in REGIONS.items():
        x0, y0, span = int(lx * scale), int(ly * scale), int(side * scale)
        # ⛔ --scale does NOT enlarge the framebuffer -- it scales CONTENT into
        # the same --width/--height canvas. So at 2x a region whose origin is
        # 210pt starts at device pixel 420 on a 400px image and reads as zero
        # ink. That is OFF-CANVAS, not "the renderer painted nothing", and
        # reporting it as the latter invents an engine defect out of my own
        # probe geometry. Say which one it is.
        if x0 >= w or y0 >= h:
            print("   %-12s OUT OF FRAME at %dx (origin %d,%d vs image %dx%d)"
                  " -- not a paint result" % (name, scale, x0, y0, w, h))
            continue
        ink = []
        for dy in range(span):
            for dx in range(span):
                x, y = x0 + dx, y0 + dy
                if x >= w or y >= h:
                    continue
                o = (y * w + x) * 3
                r, g, b = px[o], px[o + 1], px[o + 2]
                if (r, g, b) != (255, 255, 255):
                    ink.append(r)
        if not ink:
            print("   %-12s PAINTED NOTHING" % name)
            continue
        pure = sum(1 for v in ink if v <= 8)
        partial = sum(1 for v in ink if 8 < v < 247)
        vals = sorted(set(ink))
        print("   %-12s %5d px | %5d pure / %5d partial = %5.1f%% partial"
              % (name, len(ink), pure, partial, 100.0 * partial / len(ink)))
        print("                distinct luminance values: %d  %s"
              % (len(vals), vals[:12]))


if __name__ == '__main__':
    for arg, sc in ((sys.argv[1], 1), (sys.argv[2], 2)):
        analyse(arg, sc)
