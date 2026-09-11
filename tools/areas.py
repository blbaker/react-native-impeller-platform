"""Per-shape painted-area dump from a PPM screenshot. Green ink on black."""
import sys


def read(p):
    d = open(p, 'rb').read()
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


w, h, px = read(sys.argv[1])
print("   surface %dx%d" % (w, h))


def at(x, y):
    o = (y * w + x) * 3
    return (px[o], px[o + 1], px[o + 2])


lit = [(x, y) for y in range(h) for x in range(w)
       if at(x, y)[1] > 120 and at(x, y)[0] < 120]
if not lit:
    print("   NOTHING PAINTED")
    sys.exit(0)
xs = sorted(set(x for x, y in lit))
groups = []
cur = [xs[0]]
for x in xs[1:]:
    if x - cur[-1] <= 1:
        cur.append(x)
    else:
        groups.append(cur)
        cur = [x]
groups.append(cur)
print("   shapes: %d" % len(groups))
for i, g in enumerate(groups):
    sel = [(x, y) for x, y in lit if g[0] <= x <= g[-1]]
    ys = [y for x, y in sel]
    print("   shape%d x=[%d..%d] w=%d h=%d area=%d"
          % (i, g[0], g[-1], g[-1] - g[0] + 1,
             max(ys) - min(ys) + 1, len(sel)))
