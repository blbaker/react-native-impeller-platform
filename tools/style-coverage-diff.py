#!/usr/bin/env python3
"""Per-tile control-vs-feature diff for the style coverage grids.
usage: grid-diff.py frame.ppm fixture.js scene  -> one line per tile:
  TILE <n> <id> <expect> diffpx=<n> verdict=<SAME|DIFF> ok=<yes|no>
A tile is 'ok' when expect=diff and the slots differ, or expect=same and they
match. ok=no on an expect=diff tile means the feature changed NOTHING."""
import re, sys

def read_ppm(path):
    data = open(path, 'rb').read()
    parts = []
    i = 0
    while len(parts) < 4:
        while data[i:i+1].isspace():
            i += 1
        if data[i:i+1] == b'#':
            while data[i:i+1] != b'\n':
                i += 1
            continue
        j = i
        while not data[j:j+1].isspace():
            j += 1
        parts.append(data[i:j]); i = j
    i += 1
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i:]

def main():
    ppm, fixture, scene = sys.argv[1], sys.argv[2], sys.argv[3]
    src = open(fixture).read()
    split = src.find('const RISKY'); split = len(src) if split < 0 else split
    block = src[split:] if scene == 'risky' else src[:split]
    tiles = re.findall(r"\{ ?id: '([A-Za-z0-9]+)', e: '(diff|same)'", block)
    w, h, px = read_ppm(ppm)
    def at(x, y):
        o = (y * w + x) * 3
        return px[o], px[o+1], px[o+2]
    bad = 0
    for n, (tid, exp) in enumerate(tiles):
        cx, cy = (n % 5) * 240, (n // 5) * 150
        if cy + 150 > h:
            print(f"TILE {n+1} {tid} {exp} OFFFRAME"); bad += 1; continue
        d = 0
        for y in range(cy + 14, cy + 150):
            for x in range(cx + 8, cx + 120):
                a = at(x, y); b = at(x + 120, y)
                if abs(a[0]-b[0]) + abs(a[1]-b[1]) + abs(a[2]-b[2]) > 30:
                    d += 1
        verdict = 'DIFF' if d > 8 else 'SAME'
        ok = (verdict == 'DIFF') == (exp == 'diff')
        bad += 0 if ok else 1
        print(f"TILE {n+1} {tid} {exp} diffpx={d} verdict={verdict} ok={'yes' if ok else 'no'}")
    print(f"TILES={len(tiles)} NOT_OK={bad}")

main()
