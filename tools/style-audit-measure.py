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
    "backfaceHidden": lambda c, f, d: stats(f)["n"] == 0,
    "radiusPerCorner": lambda c, f, d: not ink(at(f, 30, 31)) and ink(at(f, 89, 31)),
    "radiusPercent": lambda c, f, d: not ink(at(f, 30, 31)) and 2700 < stats(f)["n"] < 3000,
    "borderDashed": lambda c, f, d: edge_runs(f, 32) >= 6,
    "borderDotted": lambda c, f, d: edge_runs(f, 32) >= 10,
    "borderPerSide": lambda c, f, d: {"red", "green", "blue"} <= set(stats(f)["counts"]),
    "roundedMixedBorder": lambda c, f, d: not ink(at(f, 30, 31)) and stats(f)["counts"].get("red", 0) > 0,
    "overflowRounded": lambda c, f, d: not ink(at(f, 30, 31)),
    "overflowRect": lambda c, f, d: stats(f)["n"] == 3600,
    "outline": lambda c, f, d: outside(f) > 100,
    "gradientLinear": lambda c, f, d: stats(f)["colors"] > 20,
    "gradientRadial": lambda c, f, d: stats(f)["colors"] > 20,
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
            r = RULES.get(t, lambda *a: None)(c, f, d)
            if r and t in STRICT:
                r = bool(STRICT[t](c, f, d))
        except TypeError:  # a None bbox (no ink at all) where the rule needs one
            r = False
        word = {True: "PASS", False: "FAIL", None: "NOTE"}[bool(r) if r is not None else None]
        bad += word == "FAIL"
        sf = stats(f)
        print(f"TILE {i+1} {t} {word} diff={d} out={outside(f)} n={sf['n']} "
              f"bbox={sf['bbox']} counts={sf['counts']}")
    print(f"TILES_FAILING {bad}")


if __name__ == "__main__":
    main()
