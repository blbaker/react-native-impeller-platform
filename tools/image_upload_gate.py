#!/usr/bin/env python3
"""Helpers for tools/ci-image-upload.sh (FP-17).

  gen <dir> <count> <size>       img-<i>.png solid colours (never magenta) + warm.png
  p99 <lo_us> <hi_us> <json...>  raster time (raster_end - raster_start) p99/p50 over the
                                 frames of ALL given FP-01 records whose raster_start_us is in
                                 [lo, hi), pooled: prints `p99=<us> p50=<us> n=<frames>`
  tiles <ppm> <dir> <count>      tile i's centre pixel must be img-<i>'s colour (+-6)
"""
import colorsys
import json
import sys


def colour(i):
    h = (i * 0.6180339887) % 1.0
    if 0.75 < h < 0.92:  # keep clear of the magenta poison
        h = (h + 0.3) % 1.0
    return tuple(int(x * 255) for x in colorsys.hsv_to_rgb(h, 0.8, 0.9))


def gen(d, count, size):
    from PIL import Image
    for i in range(count):
        Image.new('RGB', (size, size), colour(i)).save(f'{d}/img-{i}.png')
    Image.new('RGB', (24, 24), (200, 200, 200)).save(f'{d}/warm.png')  # NPOT like the tiles: llvmpipe keys shader variants on it


def p99(lo, hi, paths):
    v = []
    for p in paths:
        for f in json.load(open(p))['frames']:
            if lo <= f['raster_start_us'] < hi:
                v.append(f['raster_end_us'] - f['raster_start_us'])
    if not v:
        print('p99=0 p50=0 n=0')
        return
    v.sort()
    k = max(0, -(-99 * len(v) // 100) - 1)  # nearest rank, like FrameTimings
    print(f'p99={v[k]} p50={v[len(v) // 2]} n={len(v)}')


def read_ppm(path):
    data = open(path, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i + 1:]


def tiles(ppm, d, count):
    w, h, px = read_ppm(ppm)
    bad = []
    for i in range(count):
        x, y = (i % 6) * 100 + 50, (i // 6) * 100 + 50
        o = (y * w + x) * 3
        got = tuple(px[o:o + 3])
        want = colour(i)
        if max(abs(a - b) for a, b in zip(got, want)) > 6:
            bad.append(f'img-{i} at {x},{y}: got {got} want {want}')
    print(f'tiles_ok={count - len(bad)}/{count}')
    for b in bad[:5]:
        print('  ' + b)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'gen':
        gen(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    elif cmd == 'p99':
        p99(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
    elif cmd == 'tiles':
        tiles(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        sys.exit(f'unknown command {cmd}')
