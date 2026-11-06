#!/usr/bin/env python3
"""Per-box ink counts for the ENG-01d TextInput probe (fixtures/textinput-inline-os).

Usage: textinput-inline-os-measure.py <frame.ppm>
Prints one line per box: name, ink pixels (differ from the #121213 page by
more than 24 levels on any channel), red-dominant pixels, green-dominant
pixels, grey (placeholder-like) pixels. Boxes are the probe's layout boxes in
layout points; the PPM's own size sets the scale (1x headless, 2x Retina).
Pillow-free on purpose: the Mac runs this over ssh with stock python3.
"""
import sys

BG = (0x12, 0x12, 0x13)
# name -> (left, top, width, height) in layout points, from probe.tsx
BOXES = {
    "a": (20, 20, 300, 40),
    "b": (20, 80, 300, 40),
    "d": (20, 200, 300, 40),
    "gap": (20, 140, 300, 40),  # control: nothing is drawn here
}
LAYOUT_W = 1920


def read_ppm(path):
    data = open(path, "rb").read()
    parts = []
    i = 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    if parts[0] != b"P6" or parts[3] != b"255":
        raise SystemExit("not a P6/255 ppm: %r" % parts)
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i:i + w * h * 3]


def main():
    w, h, px = read_ppm(sys.argv[1])
    scale = w / LAYOUT_W
    print("ppm=%dx%d scale=%.2f" % (w, h, scale))
    for name, (l, t, bw, bh) in BOXES.items():
        x0, y0 = int(l * scale), int(t * scale)
        x1, y1 = int((l + bw) * scale), int((t + bh) * scale)
        ink = red = green = grey = 0
        for y in range(y0, min(y1, h)):
            row = y * w * 3
            for x in range(x0, min(x1, w)):
                o = row + x * 3
                r, g, b = px[o], px[o + 1], px[o + 2]
                if max(abs(r - BG[0]), abs(g - BG[1]), abs(b - BG[2])) <= 24:
                    continue
                ink += 1
                if r > 120 and g < 90 and b < 90 and r > 2 * max(g, b, 1):
                    red += 1
                elif g > 120 and r < 110 and b < 110 and g > 1.6 * max(r, b, 1):
                    green += 1
                elif abs(r - g) < 24 and abs(g - b) < 24:
                    grey += 1
        print("box=%s ink=%d red=%d green=%d grey=%d" % (name, ink, red, green, grey))


if __name__ == "__main__":
    main()
