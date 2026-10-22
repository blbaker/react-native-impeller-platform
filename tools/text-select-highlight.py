#!/usr/bin/env python3
"""ENG-43: count selection-highlight pixels inside named boxes of a PPM.

usage: text-select-highlight.py <ppm> name=x,y,w,h [name=x,y,w,h ...]
prints: <name>=<count> ... one line.

The fixture is white text on black. The default selection colour
(0.2, 0.565, 1.0) at alpha 0.35 over black reads about (18, 50, 89), so a
highlight pixel is one where blue clearly beats red. White glyphs and black
background both fail that test, so the count is the highlight alone.
No Pillow: the Mac runs this with the system python3.
"""
import sys


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b'#':
            while data[pos:pos + 1] not in (b'\n', b''):
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b'P6':
        raise SystemExit(f'{path}: not a binary PPM')
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos + 1:]


def main():
    w, h, px = read_ppm(sys.argv[1])
    out = []
    for spec in sys.argv[2:]:
        name, box = spec.split('=')
        bx, by, bw, bh = (int(round(float(v))) for v in box.split(','))
        n = 0
        for y in range(max(0, by), min(h, by + bh)):
            row = y * w * 3
            for x in range(max(0, bx), min(w, bx + bw)):
                i = row + x * 3
                r, b = px[i], px[i + 2]
                if b >= 60 and b - r >= 40:
                    n += 1
        out.append(f'{name}={n}')
    print(' '.join(out))


main()
