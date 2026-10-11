#!/usr/bin/env python3
"""Selectable-<Text> highlight measurer for tools/ci-style-audit.sh arm D
(P1 item 15). Pure python3, so it runs on the Mac with no toolchain.

Argv: <control.ppm> <selected.ppm> <fx> <fy> <fw> <fh>
  control.ppm   probe://select-control, no drag: the oracle for glyph ink
  selected.ppm  probe://select after a drag
  fx fy fw fh   the paragraph's node_frame (layout points = pixels at
                --supersample-rnsvg 0 and scale 1)

Prints one line of KEY=VALUE:
  GLYPHS       inked glyph columns found in the CONTROL frame (a run of
               columns holding dark pixels, gaps of >= 1 empty column)
  SEGS         the glyph column runs, "x0-x1,x0-x1,..." (frame-absolute x)
  HL           highlight pixels inside the frame: differ from the control
               AND are blue-dominant (b > r + 40). Black glyphs and white
               ground are never blue-dominant.
  HL_OUT       the same, OUTSIDE the frame (a highlight spilling out)
  HL_X0 HL_X1  highlight column extent (-1 when HL == 0)
  HL_ROWS      rows inside the frame holding highlight pixels
  CORE         solid glyph-core pixels (control max channel < 40) inside the
               highlight's column extent
  CORE_TINT    of those, how many the selected frame tinted (blue rose by
               > 30). The highlight is translucent (alpha 0.35), so painted
               OVER the text it tints every core; UNDER the text, none.
The glyph segmentation comes from the UNSELECTED frame, so a defect that
moves both the highlight and the engine's own offset report cannot pass.
"""
import sys


def read_ppm(path):
    d = open(path, "rb").read()
    assert d[:2] == b"P6", "not a raw PPM (P6): %r" % d[:2]
    parts = d.split(b"\n", 3)
    w, h = (int(v) for v in parts[1].split())
    return w, h, parts[3]


def px(buf, w, x, y):
    i = 3 * (y * w + x)
    return buf[i], buf[i + 1], buf[i + 2]


def main():
    c_path, s_path = sys.argv[1], sys.argv[2]
    fx, fy, fw, fh = (int(round(float(v))) for v in sys.argv[3:7])
    wc, hc, c = read_ppm(c_path)
    ws, hs, s = read_ppm(s_path)
    assert (wc, hc) == (ws, hs), "frame sizes differ"
    w, h = wc, hc
    x0, x1 = max(fx, 0), min(fx + fw, w)
    y0, y1 = max(fy, 0), min(fy + fh, h)

    def dark(p):
        return max(p) < 96

    def blue(p):
        return p[2] > p[0] + 40

    # Glyph column runs in the control.
    inked = [any(dark(px(c, w, x, y)) for y in range(y0, y1)) for x in range(x0, x1)]
    segs, start = [], None
    for i, on in enumerate(inked + [False]):
        if on and start is None:
            start = i
        elif not on and start is not None:
            segs.append((x0 + start, x0 + i - 1))
            start = None

    hl = hl_out = 0
    hx0, hx1 = None, None
    rows = set()
    for y in range(h):
        for x in range(w):
            ps = px(s, w, x, y)
            pc = px(c, w, x, y)
            inside = x0 <= x < x1 and y0 <= y < y1
            if ps != pc and blue(ps):
                if inside:
                    hl += 1
                    rows.add(y)
                    hx0 = x if hx0 is None else min(hx0, x)
                    hx1 = x if hx1 is None else max(hx1, x)
                else:
                    hl_out += 1
    core = tint = 0
    if hx0 is not None and hx1 is not None:
        for y in range(y0, y1):
            for x in range(hx0, hx1 + 1):
                pc = px(c, w, x, y)
                if max(pc) < 40:
                    core += 1
                    if px(s, w, x, y)[2] - pc[2] > 30:
                        tint += 1
    print("GLYPHS=%d SEGS=%s HL=%d HL_OUT=%d HL_X0=%d HL_X1=%d HL_ROWS=%d CORE=%d CORE_TINT=%d" % (
        len(segs), ",".join("%d-%d" % sg for sg in segs), hl, hl_out,
        -1 if hx0 is None else hx0, -1 if hx1 is None else hx1, len(rows), core, tint))


if __name__ == "__main__":
    main()
