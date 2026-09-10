#!/usr/bin/env python3
"""ENG-05b entry-point discriminator analysis.

Counts partial-coverage pixels on two curved edges painted through DIFFERENT
Impeller entry points (DrawRoundedRect vs DrawPath). Reports which lead the
measurement supports instead of just printing numbers.

Only edge-adjacent pixels matter, so each region is scanned for pixels that
are neither pure background nor pure ink.
"""
import sys

PURE_LO = 8
PURE_HI = 247


def read_ppm(path):
    d = open(path, 'rb').read()
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


# name: (left_pt, top_pt, w_pt, h_pt, entrypoint)
REGIONS = {
    "RRECT":  (20, 20, 165, 125, "ImpellerDisplayListBuilderDrawRoundedRect"),
    "SVGARC": (20, 170, 165, 125, "ImpellerDisplayListBuilderDrawPath"),
}


def analyse(path, scale):
    w, h, px = read_ppm(path)
    print("--- %dx  (image %dx%d) ---" % (scale, w, h))
    out = {}
    for name, (lx, ly, rw, rh, entry) in REGIONS.items():
        x0, y0 = int(lx * scale), int(ly * scale)
        sw, sh = int(rw * scale), int(rh * scale)
        if x0 >= w or y0 >= h:
            print("   %-7s OUT OF FRAME at %dx (origin %d,%d vs %dx%d)"
                  " -- probe geometry, not a paint result"
                  % (name, scale, x0, y0, w, h))
            continue
        ink = pure = partial = 0
        vals = set()
        for dy in range(sh):
            for dx in range(sw):
                x, y = x0 + dx, y0 + dy
                if x >= w or y >= h:
                    continue
                v = px[(y * w + x) * 3]
                if v >= PURE_HI:
                    continue  # background
                ink += 1
                vals.add(v)
                if v <= PURE_LO:
                    pure += 1
                else:
                    partial += 1
        if ink == 0:
            print("   %-7s PAINTED NOTHING (%s)" % (name, entry))
            out[name] = None
            continue
        pct = 100.0 * partial / ink
        out[name] = pct
        print("   %-7s %6d ink | %6d pure / %5d partial = %5.2f%% partial"
              % (name, ink, pure, partial, pct))
        print("           via %s" % entry)
        print("           distinct luminances: %d" % len(vals))
    return out


def verdict(results):
    rr = results.get("RRECT")
    sv = results.get("SVGARC")
    if rr is None or sv is None:
        return "INCONCLUSIVE: a region painted nothing; fix the fixture first."
    aa = 0.5  # a genuinely anti-aliased curved edge is far above this
    if rr < aa and sv < aa:
        return ("SURFACE-LEVEL: neither entry point anti-aliases. Consistent "
                "with the surface being created without multisample. "
                "GLFW_SAMPLES / EGL config is the right layer to try.")
    if rr >= aa and sv < aa:
        return ("DRAW-CALL-LEVEL: DrawRoundedRect anti-aliases and DrawPath "
                "does not. The surface is FINE -- GLFW_SAMPLES would be a "
                "no-op aimed at the wrong layer. Fix belongs in the path "
                "paint.")
    if rr < aa and sv >= aa:
        return ("DRAW-CALL-LEVEL (inverted): DrawPath anti-aliases and "
                "DrawRoundedRect does not. Still not a surface property.")
    return ("AA IS ON for both entry points. Whatever ENG-05b is chasing, it "
            "is not a global anti-aliasing outage.")


if __name__ == '__main__':
    merged = {}
    for arg, sc in ((sys.argv[1], 1), (sys.argv[2], 2)):
        r = analyse(arg, sc)
        for k, v in r.items():
            if merged.get(k) is None:
                merged[k] = v
    print("\nVERDICT: %s" % verdict(merged))
