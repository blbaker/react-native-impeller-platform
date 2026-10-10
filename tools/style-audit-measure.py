#!/usr/bin/env python3
"""Score the style-audit grid (fixtures/style-audit) from one screenshot.

Port of the macOS tester's engine-audit probe/measure.py (2026-10-04), with two
changes: it reads the PPM directly (no Pillow, so the Mac can run it over a
bare ssh) and it prints one machine-readable line per tile:

    TILE <n> <id> <PASS|FAIL|NOTE> diff=<d> ...

Each cell is 240x150 points at 1x. The CONTROL element sits at (cell+30,
cell+45), the FEATURE element at (cell+150, cell+45). A slot region is the half
cell x [0,120) or [120,240), y [14,150), so shadows that spill outside the
element still land inside the region. The RULES table is the Mac's, unchanged,
except tabularNums (the Mac measured it by hand), which is a real rule here.

Usage: style-audit-measure.py <grid.ppm> [<index.js>]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PPM = Path(sys.argv[1])
SRC = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "fixtures/style-audit/index.js"
IDS = re.findall(r"\{ id: '([A-Za-z]+)'", SRC.read_text())


def read_ppm(path):
    data = path.read_bytes()
    # P6 header: magic, width, height, maxval, each separated by whitespace.
    fields, i = [], 0
    while len(fields) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    i += 1
    assert fields[0] == b"P6", "not a P6 ppm"
    return int(fields[1]), int(fields[2]), data[i:]


W, H, RAW = read_ppm(PPM)
CW, CH, PER = 240, 150, 5


def px_at(x, y):
    o = (y * W + x) * 3
    return RAW[o], RAW[o + 1], RAW[o + 2]


def region(i, side):
    cx, cy = (i % PER) * CW, (i // PER) * CH
    x0 = cx + (0 if side == "c" else 120)
    return x0, cy + 14, x0 + 120, cy + CH


def pixels(i, side):
    x0, y0, x1, y1 = region(i, side)
    return {(x - x0, y - y0): px_at(x, y) for y in range(y0, y1) for x in range(x0, x1)}


def ink(p):
    return p != (255, 255, 255)


def cls(p):
    r, g, b = p
    if p == (255, 255, 255):
        return "white"
    if b > 200 and r < 60 and g < 60:
        return "blue"
    if r > 200 and g < 60 and b < 60:
        return "red"
    if g > 200 and r < 60 and b < 60:
        return "green"
    if r < 40 and g < 40 and b < 40:
        return "black"
    if abs(r - g) < 12 and abs(g - b) < 12:
        return "gray"
    return "mixed"


def stats(px):
    ink_pts = [k for k, v in px.items() if ink(v)]
    counts = {}
    for v in px.values():
        c = cls(v)
        counts[c] = counts.get(c, 0) + 1
    counts.pop("white", None)
    if not ink_pts:
        return {"bbox": None, "n": 0, "counts": counts, "colors": 0}
    xs = [p[0] for p in ink_pts]
    ys = [p[1] for p in ink_pts]
    return {"bbox": (min(xs), min(ys), max(xs), max(ys)), "n": len(ink_pts),
            "counts": counts, "colors": len({px[k] for k in ink_pts})}


def diff(a, b):
    return sum(1 for k in a if a[k] != b[k])


def outside(px, box=(30, 31, 89, 90)):
    x0, y0, x1, y1 = box
    return sum(1 for (x, y), v in px.items() if ink(v) and not (x0 <= x <= x1 and y0 <= y <= y1))


def at(px, x, y):
    return px[(x, y)]


def radial_grid1_ok(px):
    # SC-07: centre red-dominant, corners blue-dominant and symmetric within 6.
    # The 60x60 box spans x 30..89, y 31..90.
    mid = at(px, 60, 61)
    if not mid[0] > mid[2] + 100:
        return False
    cs = [at(px, x, y) for x, y in ((31, 32), (88, 32), (31, 89), (88, 89))]
    if any(not p[2] > p[0] + 100 for p in cs):
        return False
    return all(max(p[k] for p in cs) - min(p[k] for p in cs) <= 6 for k in range(3))


def edge_runs(px, y, x0=30, x1=89):
    vals = [ink(px[(x, y)]) and cls(px[(x, y)]) == "black" for x in range(x0, x1 + 1)]
    return sum(1 for a, b in zip(vals, vals[1:]) if a != b)


def line_widths(px):
    """Ink width of each horizontal ink band (one per text line)."""
    rows = sorted({y for (x, y), v in px.items() if ink(v) and cls(v) in ("black", "gray")})
    bands, cur = [], []
    for y in rows:
        if cur and y != cur[-1] + 1:
            bands.append(cur)
            cur = []
        cur.append(y)
    if cur:
        bands.append(cur)
    out = []
    for b in bands:
        xs = [x for (x, y), v in px.items() if y in b and ink(v) and cls(v) in ("black", "gray")]
        out.append(max(xs) - min(xs) + 1)
    return out


def tabular(c, f, d):
    wf = line_widths(f)
    return len(wf) == 2 and abs(wf[0] - wf[1]) <= 2


def outline_ok(px):
    # SC-09: box (30,31)-(89,90), outlineWidth 4 offset 4 red. The ring fills
    # 4 px starting 4 px outside each edge; the gap and the area beyond stay white.
    def col(xs, ys, want):
        return all(cls(at(px, x, y)) == want for x in xs for y in ys)
    mx, my = range(50, 70), range(50, 70)
    sides = (
        (mx, range(23, 27), mx, range(27, 31), mx, range(15, 23)),
        (mx, range(95, 99), mx, range(91, 95), mx, range(99, 107)),
        (range(22, 26), my, range(26, 30), my, range(14, 22), my),
        (range(94, 98), my, range(90, 94), my, range(98, 106), my),
    )
    for rx, ry, gx, gy, bx, by in sides:
        if not (col(rx, ry, "red") and col(gx, gy, "white") and col(bx, by, "white")):
            return False
    return cls(at(px, 22, 23)) == "red" and cls(at(px, 97, 98)) == "red"


def outside_split(px, box=(30, 31, 89, 90)):
    """(ink right/below the box, ink left/above it), corners counted once."""
    x0, y0, x1, y1 = box
    br = tl = 0
    for (x, y), v in px.items():
        if not ink(v) or (x0 <= x <= x1 and y0 <= y <= y1):
            continue
        if x > x1 or y > y1:
            br += 1
        else:
            tl += 1
    return br, tl


def outside_levels(px, box=(30, 31, 89, 90)):
    x0, y0, x1, y1 = box
    return len({v for (x, y), v in px.items() if ink(v) and not (x0 <= x <= x1 and y0 <= y <= y1)})


def cast_shadow(c, f, d):
    """A blurred shadow cast toward the bottom-right: more ink there than
    above/left, and a soft edge (many distinct levels), not a hard copy."""
    br, tl = outside_split(f)
    # The box paints OVER its own shadow: its interior stays pure blue.
    return br > 2 * tl and outside_levels(f) > 5 and at(f, 60, 60) == (0, 0, 255)


def blobs(px, dark=600):
    """Connected dark-ink components: [(x0, y0, x1, y1, n)], left to right."""
    pts = {k for k, v in px.items() if ink(v) and sum(v) < dark}
    seen, out = set(), []
    for p in sorted(pts):
        if p in seen:
            continue
        stack, comp = [p], []
        seen.add(p)
        while stack:
            q = stack.pop()
            comp.append(q)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    r = (q[0] + dx, q[1] + dy)
                    if r in pts and r not in seen:
                        seen.add(r)
                        stack.append(r)
        xs = [a for a, _ in comp]
        ys = [b for _, b in comp]
        out.append((min(xs), min(ys), max(xs), max(ys), len(comp)))
    return sorted(out)


def bullets(c, f, d):
    """secureTextEntry 'abc': exactly three dots, alike in size, on one band,
    each about as wide as tall, and none as tall as the control's 'b'.
    A FOCUSED field also paints its caret: one thin full-height bar (at most
    2 px wide, at least 8 px tall) is dropped before counting, and only when
    it sits right of every other blob, i.e. after the last bullet."""
    fb, cb = blobs(f), blobs(c)
    if fb:
        last = fb[-1]
        bar = last[2] - last[0] + 1 <= 2 and last[3] - last[1] + 1 >= 8
        if bar and all(b[2] < last[0] for b in fb[:-1]):
            fb = fb[:-1]
    if len(fb) != 3 or not cb:
        return False
    hs = [b[3] - b[1] + 1 for b in fb]
    ws = [b[2] - b[0] + 1 for b in fb]
    ctall = max(b[3] - b[1] + 1 for b in cb)
    same_band = max(b[1] for b in fb) - min(b[1] for b in fb) <= 1
    round_ = all(abs(w - h) <= 2 for w, h in zip(ws, hs))
    return same_band and round_ and max(hs) < ctall * 0.6 and max(hs) - min(hs) <= 1


def row_runs(px, y, x0, x1, want=lambda v: ink(v)):
    """Number of separate runs of `want` pixels along row y, x0..x1."""
    vals = [want(px[(x, y)]) for x in range(x0, x1 + 1)]
    return sum(1 for i, v in enumerate(vals) if v and (i == 0 or not vals[i - 1]))


def full_rule(px, y, x0, x1, want=lambda v: ink(v) and cls(v) == "black"):
    """Row y is one unbroken `want` line spanning the text width x0..x1."""
    return all(want(px[(x, y)]) for x in range(x0, x1 + 1))


def glyphs_same(c, f, y0, y1):
    """Feature rows y0..y1 are pixel-identical to the control (decoration
    must not restyle the glyphs themselves)."""
    return all(c[(x, y)] == f[(x, y)] for y in range(y0, y1 + 1) for x in range(120))


def underline_ok(c, f, d):
    """A solid black rule spanning the text, BELOW the control's glyph box,
    with the glyph rows untouched."""
    cb = stats(c)["bbox"]
    below = [y for y in range(cb[3] + 1, 136) if full_rule(f, y, cb[0], cb[2])]
    return bool(below) and glyphs_same(c, f, cb[1], cb[3])


def strike_ok(c, f, d):
    """A solid black rule spanning the text INSIDE the middle half of the glyph
    band, nothing painted below the glyphs, and no such rule in the control."""
    cb, fb = stats(c)["bbox"], stats(f)["bbox"]
    h = cb[3] - cb[1]
    mid = range(cb[1] + h // 4, cb[3] - h // 4 + 1)
    hit = [y for y in mid if full_rule(f, y, cb[0], cb[2])]
    return bool(hit) and fb[3] == cb[3] and not any(full_rule(c, y, cb[0], cb[2]) for y in mid)


def deco_color_ok(c, f, d):
    """textDecorationColor red + style dashed. The CONTROL is a plain black
    underline, so its rule rows say where the underline belongs: the red must
    sit on those rows (+-1), in at least 4 separate dashes along one row, and
    the glyphs above keep their own colour."""
    cb = stats(c)["bbox"]
    under = [y for y in range(cb[1], cb[3] + 1) if full_rule(c, y, cb[0], cb[2])]
    red = [(x, y) for (x, y), v in f.items() if cls(v) == "red"]
    if not under or not red:
        return False
    if not all(min(under) - 1 <= y <= max(under) + 1 for _, y in red):
        return False
    is_red = lambda v: cls(v) == "red"
    dashes = max(row_runs(f, y, cb[0], cb[2], is_red) for y in {y for _, y in red})
    return dashes >= 4 and glyphs_same(c, f, cb[1], min(under) - 2)


def weight_ok(c, f, d):
    """Heavier strokes AND still one line: weight must reach MEASURE too, or a
    bold 'Ab' measured in the regular face wraps the 'b' to a second line."""
    cb, fb = stats(c)["bbox"], stats(f)["bbox"]
    ck, fk = stats(c)["counts"].get("black", 0), stats(f)["counts"].get("black", 0)
    one_line = abs((fb[3] - fb[1]) - (cb[3] - cb[1])) <= 2
    return fk > ck * 1.3 and one_line and fb[2] >= cb[2]


def ios_dash_mask(on, width=4, box=(30, 31, 89, 90)):
    """Spec oracle for items 10/25, written from RN iOS's source, not from our
    C++: RCTBorderDrawing.m strokes ONE closed path along the centre line,
    clockwise from the top-left (RCTPathCreateWithRoundedRect), dash
    on = off = `on`, phase 0, butt caps, miter joins. Returns the set of slot
    pixels that path covers (1x, integer geometry)."""
    bx0, by0, bx1, by1 = box[0], box[1], box[2] + 1, box[3] + 1
    hw = width / 2
    x0, y0, x1, y1 = bx0 + hw, by0 + hw, bx1 - hw, by1 - hw
    period = 2 * on
    edges = [((x0, y0), (1, 0), x1 - x0), ((x1, y0), (0, 1), y1 - y0),
             ((x1, y1), (-1, 0), x1 - x0), ((x0, y1), (0, -1), y1 - y0)]
    rects, T = [], 0.0
    on_at = lambda t: (max(t, 0.0) % period) < on
    for e, ((sx, sy), (dx, dy), ln) in enumerate(edges):
        s = (T // period) * period
        while s < T + ln:
            a, b = max(s, T) - T, min(s + on, T + ln) - T
            if b > a:
                ax, ay, bx_, by_ = sx + dx * a, sy + dy * a, sx + dx * b, sy + dy * b
                if dy == 0:
                    rects.append((min(ax, bx_), ay - hw, max(ax, bx_), ay + hw))
                else:
                    rects.append((ax - hw, min(ay, by_), ax + hw, max(ay, by_)))
            s += period
        T += ln
        after = on_at(0.0) if e == 3 else on_at(T + 1e-3)
        if on_at(T - 1e-3) and after:
            nx, ny = edges[(e + 1) % 4][0]
            rects.append((nx - hw, ny - hw, nx + hw, ny + hw))
    return {(x, y) for (rx0, ry0, rx1, ry1) in rects
            for x in range(int(rx0), int(rx1)) for y in range(int(ry0), int(ry1))}


def dash_ok(on):
    """The painted border band matches the iOS dash oracle pixel for pixel.
    At most 2 px may differ (measured: 0 on linux at 1x). Dropping the corner
    miter joins (mutant M21) changes exactly 8 px here: the outer 2x2 of the
    top-left and top-right corners. A 1%-of-band tolerance (8 px) let it pass."""
    def rule(c, f, d):
        want = ios_dash_mask(on)
        band = {(x, y) for x in range(30, 90) for y in range(31, 91)
                if x < 34 or x > 85 or y < 35 or y > 86}
        got = {p for p in band if cls(f[p]) == "black"}
        return bool(want) and len(want ^ got) <= 2
    return rule


def align_ok(where):
    """Same glyphs (ink width within 1 px of the control) moved to the centre or
    right of the 80 pt box at slot x 30..109; still one line."""
    def rule(c, f, d):
        cb, fb = stats(c)["bbox"], stats(f)["bbox"]
        same_w = abs((fb[2] - fb[0]) - (cb[2] - cb[0])) <= 1
        one_line = fb[1] == cb[1] and fb[3] == cb[3]
        if where == "center":
            pos = abs((fb[0] + fb[2]) / 2 - 69.5) <= 2
        else:
            pos = 105 <= fb[2] <= 109
        return same_w and one_line and pos
    return rule


def _box_colours(px, box):
    x0, y0, x1, y1 = box[:4]
    return {cls(px[(x, y)]) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


def nested_color_ok(c, f, d):
    """Item 14, 'AA' + nested red 'BB'. The four glyph boxes match the
    control's within 1 px (one paragraph, so the inner run does not move),
    the first two glyphs have black ink and no red, and the last two have
    red and no black. Painting the whole paragraph in one colour fails either
    half."""
    cb, fb = blobs(c), blobs(f)
    if len(cb) != 4 or len(fb) != 4:
        return False
    same = all(abs(a[i] - b[i]) <= 1 for a, b in zip(cb, fb) for i in range(4))
    k = [_box_colours(f, b) for b in fb]
    outer = all("black" in s and "red" not in s for s in k[:2])
    inner = all("red" in s and "black" not in s for s in k[2:])
    return same and outer and inner


def nested_size_ok(c, f, d):
    """Item 14, 'AA' at 14 pt + nested 'AA' at 30 pt, on ONE line. The first
    two glyphs keep the control's 14 pt height (within 1 px), the last two are
    at least 1.8x taller, and all four bottoms sit on one baseline (within
    1 px). Painting every glyph at 30 pt (the old bug) fails the first part,
    and the wrap it causes fails the baseline."""
    cb, fb = blobs(c), blobs(f)
    if len(fb) != 4 or not cb:
        return False
    ch = cb[0][3] - cb[0][1] + 1
    hs = [b[3] - b[1] + 1 for b in fb]
    small = all(abs(h - ch) <= 1 for h in hs[:2])
    big = all(h >= 1.8 * ch for h in hs[2:])
    baseline = max(b[3] for b in fb) - min(b[3] for b in fb) <= 1
    return small and big and baseline


def text_bg_ok(c, f, d):
    """Item 14, 'A' + nested 'B' with green backgroundColor. Green fills
    behind 'B' only: the green box starts right of 'A''s glyph and encloses
    'B''s glyph box, and the 'A' glyph keeps black ink with no green. A
    background on the whole paragraph, or on none of it, fails."""
    cb = blobs(c)
    gs = [k for k, v in f.items() if cls(v) == "green"]
    if len(cb) != 2 or not gs:
        return False
    a, b = cb
    gx0, gx1 = min(x for x, _ in gs), max(x for x, _ in gs)
    gy0, gy1 = min(y for _, y in gs), max(y for _, y in gs)
    behind_b = a[2] < gx0 <= b[0] and gx1 >= b[2] and gy0 <= b[1] and gy1 >= b[3]
    ka = _box_colours(f, a)
    return behind_b and "black" in ka and "green" not in ka


# STRICT rules, ANDed with RULES. The Mac's RULES are kept verbatim so its
# measure.py and this one agree on every PASS it reports; these only add the
# properties a plausible-but-wrong implementation would miss (a shadow cast the
# wrong way, an unblurred one, an inset ring that leaks out of the box).
STRICT = {
    "shadowIOS": cast_shadow,
    "boxShadow": cast_shadow,
    "elevation": lambda c, f, d: outside_split(f)[0] > outside_split(f)[1] and outside_levels(f) > 5
    and at(f, 60, 60) == (0, 0, 255),
    "boxShadowInset": lambda c, f, d: outside(f) == 0 and cls(at(f, 60, 60)) == "blue"
    and cls(at(f, 31, 60)) == "red" and cls(at(f, 45, 60)) == "blue",
    "textInputSecure": bullets,
    # The rounded clip must cut the corner AND keep the child's full width
    # through the middle (a clip that drops the child entirely also leaves the
    # corner white).
    "overflowRounded": lambda c, f, d: cls(at(f, 60, 60)) == "red"
    and cls(at(f, 31, 60)) == "red" and 2700 < stats(f)["n"] < 3000,
    # Items 5, 7, 9: the Mac's rules are `d > 0`-shaped; these pin position,
    # style and measure-agreement.
    "underline": underline_ok,
    "lineThrough": strike_ok,
    "decorationColor": deco_color_ok,
    "fontWeight": weight_ok,
    "fontWeightBold": weight_ok,
    "textAlignCenter": align_ok("center"),
    "textAlignRight": align_ok("right"),
    # Items 10 + 25: pixel match against the RN iOS dash geometry (3w / 1w).
    "borderDashed": dash_ok(12),
    "borderDotted": dash_ok(4),
    # P1 item 14: nested runs keep their own colour / background, in place.
    "nestedText": nested_color_ok,
    "textBackground": text_bg_ok,
}

# Mac RULES that the RN source itself cannot meet, REPLACED (not ANDed) here
# and flagged `rule=corrected` on the TILE line so the override is never
# silent. Each entry names the source line that rules the Mac's value out.
#   borderDashed: the Mac asks for >= 6 ink/no-ink transitions on the top
#   edge. RN iOS dashes at on = off = 3 x width (RCTBorderDrawing.m:558), so a
#   60 pt box with a 4 pt border has a 56 pt top run and a 24 pt period: at
#   most 3 dashes, i.e. 4 transitions. Judged by the iOS-oracle STRICT rule.
#   nestedTextSize: the Mac asks for an ink height > 25 px. 'AA' at 14 pt +
#   'AA' at 30 pt fits ONE line, and the tallest ink is a 30 pt cap 'A':
#   cap height 0.70 em here (iOS SF: 0.705 em) = 21 px. > 25 is reachable only
#   when the line WRAPS, which is what the old all-30pt paint did (Mac
#   baseline bbox height 56). Kept: the Mac's "black < 450" half. Replaced:
#   the height half, by per-glyph heights on one baseline (nested_size_ok).
CORRECTED = {
    "borderDashed": lambda c, f, d: edge_runs(f, 32) >= 4,
    "nestedTextSize": lambda c, f, d: stats(f)["counts"].get("black", 0) < 450
    and nested_size_ok(c, f, d),
}


RULES = {
    "shadowIOS": lambda c, f, d: outside(f) > 50,
    "boxShadow": lambda c, f, d: outside(f) > 50,
    "boxShadowInset": lambda c, f, d: stats(f)["counts"].get("red", 0) > 500,
    "elevation": lambda c, f, d: outside(f) > 50,
    "textShadow": lambda c, f, d: stats(f)["counts"].get("blue", 0) > 50,
    "opacityGroup": lambda c, f, d: stats(f)["colors"] == 1 and stats(c)["colors"] == 2,
    "translate": lambda c, f, d: stats(f)["bbox"][:2] == (50, 41),
    "scale": lambda c, f, d: stats(f)["n"] == 400,
    "rotate": lambda c, f, d: stats(f)["bbox"][2] - stats(f)["bbox"][0] > 50,
    "skewX": lambda c, f, d: stats(f)["bbox"][2] - stats(f)["bbox"][0] > 50,
    "transformOrigin": lambda c, f, d: stats(f)["bbox"][:2] == (30, 31),
    "perspective": lambda c, f, d: stats(f)["bbox"][3] - stats(f)["bbox"][1] > 61,
    "backfaceHidden": lambda c, f, d: stats(c)["n"] > 3000 and stats(f)["n"] == 0,
    "radiusPerCorner": lambda c, f, d: not ink(at(f, 30, 31)) and ink(at(f, 89, 31)),
    "radiusPercent": lambda c, f, d: not ink(at(f, 30, 31)) and 2700 < stats(f)["n"] < 3000,
    "borderDashed": lambda c, f, d: edge_runs(f, 32) >= 6,
    "borderDotted": lambda c, f, d: edge_runs(f, 32) >= 10,
    "borderPerSide": lambda c, f, d: {"red", "green", "blue"} <= set(stats(f)["counts"]),
    "roundedMixedBorder": lambda c, f, d: not ink(at(f, 30, 31)) and cls(at(f, 60, 33)) == "red" and cls(at(f, 32, 61)) == "blue" and cls(at(f, 88, 61)) == "blue" and cls(at(f, 60, 88)) == "blue",
    "overflowRounded": lambda c, f, d: not ink(at(f, 30, 31)),
    "overflowRect": lambda c, f, d: stats(f)["n"] == 3600,
    "outline": lambda c, f, d: outline_ok(f),
    "gradientLinear": lambda c, f, d: stats(f)["colors"] > 20,
    "gradientRadial": lambda c, f, d: radial_grid1_ok(f),
    "filterBlur": lambda c, f, d: outside(f) > 50 or stats(f)["colors"] > 5,
    "filterBrightness": lambda c, f, d: at(f, 60, 60)[2] < 200,
    "filterGrayscale": lambda c, f, d: cls(at(f, 60, 60)) == "gray",
    "filterDropShadow": lambda c, f, d: outside(f) > 50,
    "mixBlendMode": lambda c, f, d: cls(at(f, 60, 60)) == "black",
    "isolation": lambda c, f, d: cls(at(f, 60, 60)) == "red" and cls(at(c, 60, 60)) == "black",
    "zIndex": lambda c, f, d: cls(at(f, 60, 60)) == "red" and cls(at(c, 60, 60)) == "blue",
    "absNegative": lambda c, f, d: stats(f)["bbox"][:2] == (15, 16),
    "aspectRatio": lambda c, f, d: stats(f)["bbox"][2] - stats(f)["bbox"][0] == 89,
    "gap": lambda c, f, d: stats(f)["bbox"][2] == 79,
    "rowColumnGap": lambda c, f, d: stats(f)["bbox"][2:] == (89, 76),
    "flexWrap": lambda c, f, d: stats(f)["bbox"][3] > stats(c)["bbox"][3],
    "letterSpacing": lambda c, f, d: stats(f)["bbox"][2] > stats(c)["bbox"][2] + 10,
    "lineHeight": lambda c, f, d: stats(f)["bbox"][3] - stats(f)["bbox"][1] > 40,
    "underline": lambda c, f, d: d > 0 and stats(f)["bbox"][3] > stats(c)["bbox"][3],
    "lineThrough": lambda c, f, d: d > 0,
    "decorationColor": lambda c, f, d: stats(f)["counts"].get("red", 0) > 0,
    "textTransform": lambda c, f, d: d == 0,
    "tabularNums": tabular,
    "fontWeight": lambda c, f, d: stats(f)["n"] > stats(c)["n"] * 1.2,
    "fontWeightBold": lambda c, f, d: stats(f)["n"] > stats(c)["n"] * 1.2,
    "italic": lambda c, f, d: d > 0,
    "numberOfLines": lambda c, f, d: stats(f)["bbox"][3] < stats(c)["bbox"][3],
    "ellipsizeHead": lambda c, f, d: d > 0,
    "ellipsizeMiddle": lambda c, f, d: d > 0,
    "writingDirection": lambda c, f, d: stats(f)["bbox"][0] > stats(c)["bbox"][0] + 20,
    "textAlignCenter": lambda c, f, d: stats(f)["bbox"][0] > stats(c)["bbox"][0] + 10,
    "textAlignRight": lambda c, f, d: stats(f)["bbox"][2] >= 105,
    "textAlignJustify": lambda c, f, d: d > 0,
    "nestedText": lambda c, f, d: stats(f)["counts"].get("red", 0) > 0 and stats(f)["counts"].get("black", 0) > 0,
    "nestedTextSize": lambda c, f, d: stats(f)["bbox"][3] - stats(f)["bbox"][1] > 25 and stats(f)["counts"].get("black", 0) < 450,
    "textBackground": lambda c, f, d: stats(f)["counts"].get("green", 0) > 0,
    "image": lambda c, f, d: stats(f)["counts"].get("red", 0) > 3000,
    "imageTint": lambda c, f, d: stats(f)["counts"].get("blue", 0) > 3000,
    "scrollContentOffset": lambda c, f, d: d > 0,
    "scrollHorizontal": lambda c, f, d: d > 0,
    "activityIndicator": lambda c, f, d: stats(f)["n"] > 20,
    "switch": lambda c, f, d: stats(f)["n"] > 20,
    "textInputMultiline": lambda c, f, d: stats(f)["bbox"][3] <= 91 and stats(f)["n"] > stats(c)["n"] * 2,
    "textInputSecure": lambda c, f, d: d > 0,
    "placeholderColor": lambda c, f, d: stats(f)["counts"].get("red", 0) > 0,
    "statusBar": lambda c, f, d: d == 0,
}


def main():
    bad = 0
    for i, t in enumerate(IDS):
        c, f = pixels(i, "c"), pixels(i, "f")
        d = diff(c, f)
        try:
            rule = CORRECTED.get(t) or RULES.get(t, lambda *a: None)
            r = rule(c, f, d)
            if r and t in STRICT:
                r = bool(STRICT[t](c, f, d))
        except TypeError:  # a None bbox (no ink at all) where the rule needs one
            r = False
        word = {True: "PASS", False: "FAIL", None: "NOTE"}[bool(r) if r is not None else None]
        bad += word == "FAIL"
        sf = stats(f)
        mark = " rule=corrected" if t in CORRECTED else ""
        print(f"TILE {i+1} {t} {word} diff={d} out={outside(f)} n={sf['n']} "
              f"bbox={sf['bbox']} counts={sf['counts']}{mark}")
    print(f"TILES_FAILING {bad}")


if __name__ == "__main__":
    main()
