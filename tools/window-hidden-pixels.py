#!/usr/bin/env python3
"""Pixel checks for fixtures/window-hidden (tools/ci-window-hidden.sh).

usage: window-hidden-pixels.py <shot.ppm> <W> <H> [<other.ppm>]

Asserts the capture is exactly W x H, that the fixture painted where its
fixed layout says (red A, green B, blue C, grey root), and that the live-timer
bar has grown past x=200 (26+ ticks of a 50 ms setInterval: only a running JS
timer gets it there). With <other.ppm> it also counts pixels that differ by
more than 8 in any channel, outside the timer-bar rows (the bar's length
depends on the capture moment). Prints WH_PIXELS_OK ... or WH_PIXELS_FAIL ...
"""
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts, i = [], 0
    while len(parts) < 4:  # P6, W, H, maxval; '#' comments allowed
        while data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while data[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j : j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    if parts[0] != b"P6":
        raise ValueError(f"{path}: not P6")
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i : i + w * h * 3]


def px(img, x, y):
    w, _, d = img
    o = (y * w + x) * 3
    return d[o], d[o + 1], d[o + 2]


def near(c, want, tol=48):
    return all(abs(a - b) <= tol for a, b in zip(c, want))


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    img = read_ppm(sys.argv[1])
    want_w, want_h = int(sys.argv[2]), int(sys.argv[3])
    if (img[0], img[1]) != (want_w, want_h):
        print(f"WH_PIXELS_FAIL size={img[0]}x{img[1]} want={want_w}x{want_h}")
        return 1
    probes = [
        ("A_red", 70, 60, (255, 0, 0)),
        ("B_green", 330, 60, (0, 255, 0)),
        ("C_blue", 70, 220, (0, 0, 255)),
        ("root_grey", 200, 230, (128, 128, 128)),
        ("timer_bar", 200, 275, (255, 255, 0)),
    ]
    bad = []
    for name, x, y, want in probes:
        c = px(img, x, y)
        if not near(c, want):
            bad.append(f"{name}@{x},{y}={c} want~{want}")
    msg = f"size={img[0]}x{img[1]}"
    if len(sys.argv) > 4:
        other = read_ppm(sys.argv[4])
        if (other[0], other[1]) != (img[0], img[1]):
            bad.append(f"other size {other[0]}x{other[1]}")
        else:
            diff = 0
            for y in range(img[1]):
                if 268 <= y <= 282:
                    continue
                for x in range(img[0]):
                    a, b = px(img, x, y), px(other, x, y)
                    if any(abs(p - q) > 8 for p, q in zip(a, b)):
                        diff += 1
            msg += f" diff_px={diff}"
            if diff > 0.01 * img[0] * img[1]:
                bad.append(f"differs from {sys.argv[4]} in {diff} px")
    if bad:
        print("WH_PIXELS_FAIL " + msg + " " + "; ".join(bad))
        return 1
    print("WH_PIXELS_OK " + msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
