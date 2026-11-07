"""Video half of tools/rn_core_check.py: the numbered test video
(tools/build-rn-core-video.sh) and the checks that read a frame number back
out of a screenshot. Run through rn_core_check.py; see its commands."""
import sys

from rn_core_check import Shot, luma

VW, VH, VFRAMES, VBITS = 320, 180, 360, 9


def video_frame(k):
    """Frame k of the rn-core test video: k in 9 bit blocks (MSB first), black/white
    on grey, 30 x 40 each at x = 10 + 34 i, y = 20..60; a moving bar below."""
    row_grey = bytes([128, 128, 128]) * VW
    rows = []
    for y in range(VH):
        if 20 <= y < 60:
            r = bytearray(row_grey)
            for i in range(VBITS):
                on = (k >> (VBITS - 1 - i)) & 1
                c = 255 if on else 0
                for x in range(10 + 34 * i, 40 + 34 * i):
                    r[3 * x:3 * x + 3] = bytes([c, c, c])
            rows.append(bytes(r))
        elif 120 <= y < 170:
            r = bytearray(row_grey)
            bx = (k * 4) % (VW - 8)
            for x in range(bx, bx + 8):
                r[3 * x:3 * x + 3] = b"\xff\xc8\x00"
            rows.append(bytes(r))
        else:
            rows.append(row_grey)
    return b"".join(rows)


def gen_video_frames(out):
    for k in range(VFRAMES):
        out.write(video_frame(k))


def frame_number(path, x0, y0):
    """Read the 9 bit blocks of a shot whose video top-left sits at (x0, y0) pt."""
    s = Shot(path)
    k, lum = 0, []
    for i in range(VBITS):
        v = luma(s.at(x0 + 25 + 34 * i, y0 + 40))
        lum.append(v)
        k = (k << 1) | (1 if v > 128 else 0)
    ambiguous = [v for v in lum if 60 < v < 196]
    return k, ambiguous


def video_check(args):
    """video <rate> <shotA> <shotB> <dt_ms> [x0 y0]: frames advance ~ rate * dt * 30."""
    rate, a, b, dt = float(args[0]), args[1], args[2], float(args[3])
    x0, y0 = (int(args[4]), int(args[5])) if len(args) >= 6 else (0, 0)
    ka, amb_a = frame_number(a, x0, y0)
    kb, amb_b = frame_number(b, x0, y0)
    want = rate * dt / 1000.0 * 30
    got = kb - ka
    print(f"  frame A={ka} B={kb} advanced={got} want~{want:.1f} (rate {rate}, {dt:.0f} ms apart)")
    if amb_a or amb_b:
        print(f"RNCORE_VIDEO_FAIL unreadable frame number blocks (luma {amb_a or amb_b})")
        return 1
    lo, hi = (0, 0) if rate == 0 else (want * 0.75 - 2, want * 1.25 + 2)
    if not (lo <= got <= hi):
        print(f"RNCORE_VIDEO_FAIL advanced {got} frames, want {lo:.1f}..{hi:.1f}")
        return 1
    print("RNCORE_VIDEO_OK")
    return 0


def video_seek_check(args):
    """videoseek <shot> <seconds> [x0 y0]: the painted frame is round(seconds * 30) +- 1.
    Reads PIXELS, so a seek that only moved the reported currentTime fails."""
    shot, secs = args[0], float(args[1])
    x0, y0 = (int(args[2]), int(args[3])) if len(args) >= 4 else (0, 0)
    k, amb = frame_number(shot, x0, y0)
    want = round(secs * 30)
    print(f"  seek {secs:.3f} s: painted frame {k}, want {want} +- 1")
    if amb:
        print(f"RNCORE_VIDEO_FAIL unreadable frame number blocks (luma {amb})")
        return 1
    if abs(k - want) > 1:
        print(f"RNCORE_VIDEO_FAIL seek painted frame {k}, want {want}")
        return 1
    print("RNCORE_VIDEO_OK")
    return 0
