#!/usr/bin/env python3
"""Mutation-verify the ENG-07 concave-fill gate (tools/ci-concave.sh).

CONCAVE_PASS on its own is also what a gate that cannot fail prints. This
proves four things that run could not:
  1. the gate's want/hull/bbox columns match the geometry ACTUALLY shipped in
     fixtures/concave-probe/index.js -- the original defect was a ledger value
     nobody recomputed (E's true area was 3100, the row said 3000)
  2. the verdict function is a classifier, not a constant: fed a pure hull
     reading and a pure bbox reading it must emit CONVEX-HULL and BOUNDING-BOX
  3. regression witness: the OLD E geometry is re-measured here and shown to
     grade TRUE-AREA on a pure hull fill, so the bug cannot silently return
  4. the clearance precondition trips on that old geometry and clears on the
     new one -- a working tripwire, not decoration

Drift guard: constants are parsed out of the real files and the verdict branch
text is asserted present, so editing either fails this loudly instead of
validating a stale copy of itself. Run after ANY edit to the fixture or gate.
"""
import re, sys, pathlib

ROOT = pathlib.Path.home() / "projects/react-native-impeller"
GATE = (ROOT / "tools/ci-concave.sh").read_text()
FIXT = (ROOT / "fixtures/concave-probe/index.js").read_text()
TOL, CLEAR = 0.08, 0.16
fails = []


def check(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}{'  ' + detail if detail else ''}")
    if not ok:
        fails.append(label)


# ---- geometry ------------------------------------------------------------
def pts(d):
    n = [float(x) for x in re.findall(r"-?\d+\.?\d*", d)]
    return list(zip(n[0::2], n[1::2]))


def area(p):
    return abs(sum(p[i][0] * p[(i + 1) % len(p)][1] - p[(i + 1) % len(p)][0] * p[i][1]
                   for i in range(len(p)))) / 2


def hull_area(p):
    q = sorted(set(p))
    def half(s):
        st = []
        for pt in s:
            while len(st) >= 2:
                (ax, ay), (bx, by) = st[-2], st[-1]
                if (bx - ax) * (pt[1] - ay) - (by - ay) * (pt[0] - ax) <= 0:
                    st.pop()
                else:
                    break
            st.append(pt)
        return st
    return area(half(q)[:-1] + half(q[::-1])[:-1])


def bbox_area(p):
    xs, ys = [x for x, _ in p], [y for _, y in p]
    return (max(xs) - min(xs)) * (max(ys) - min(ys))


# ---- 1. columns vs shipped geometry --------------------------------------
print("1. gate columns match the geometry the fixture actually ships")
ds = re.findall(r"'(M[^']+)'", FIXT)
check("fixture ships 5 paths", len(ds) == 5, f"got {len(ds)}")


def col(name):
    m = re.search(rf"^{name}=\[([\d,\s]+)\]", GATE, re.M)
    if not m:
        sys.exit(f"DRIFT: no '{name}=[...]' row in ci-concave.sh")
    return [int(x) for x in m.group(1).split(",")]


want, hull, bbox = col("want"), col("hull"), col("bbox")
for i, d in enumerate(ds):
    p = pts(d)
    check(f"arm {i} want", want[i] == area(p), f"gate={want[i]} shoelace={area(p):.0f}")
    check(f"arm {i} hull", hull[i] == hull_area(p), f"gate={hull[i]} computed={hull_area(p):.0f}")
    check(f"arm {i} bbox", bbox[i] == bbox_area(p), f"gate={bbox[i]} computed={bbox_area(p):.0f}")

# ---- 2. the verdict function can emit the failing labels -----------------
print("\n2. verdict function is a classifier, not a constant")
for frag in ('verdict="CONVEX-HULL"', 'verdict="BOUNDING-BOX"', 'verdict="NEITHER"'):
    check(f"branch present: {frag}", frag in GATE)


def verdict(a, i):
    if abs(100.0 * (a - want[i]) / want[i]) <= 8:
        return "TRUE-AREA"
    if abs(a - hull[i]) <= TOL * hull[i]:
        return "CONVEX-HULL"
    if abs(a - bbox[i]) <= TOL * bbox[i]:
        return "BOUNDING-BOX"
    return "NEITHER"


E = 4  # the repaired arm
for reading, expect in ((want[E], "TRUE-AREA"), (hull[E], "CONVEX-HULL"), (0, "NEITHER")):
    check(f"E reading {reading} -> {expect}", verdict(reading, E) == expect, verdict(reading, E))
# C is the only arm where hull and bbox differ, so it alone separates the two
C = 2
check(f"C reading {hull[C]} -> CONVEX-HULL", verdict(hull[C], C) == "CONVEX-HULL", verdict(hull[C], C))
check(f"C reading {bbox[C]} -> BOUNDING-BOX", verdict(bbox[C], C) == "BOUNDING-BOX", verdict(bbox[C], C))

# the original bug, restated as a test: old E could not fail
print("\n3. the old E arm really was un-failable (regression witness)")
old = pts("M10 50 L30 35 L50 10 L90 50 L50 90 Z")
ot, oh = area(old), hull_area(old)
check("old E true != ledger 3000", ot == 3100, f"shoelace={ot:.0f}")
check("old E hull within 8% of its true area", abs(oh - ot) <= TOL * ot, f"true={ot:.0f} hull={oh:.0f} gap={100*(oh/ot-1):.1f}%")
check("=> old E graded TRUE-AREA on a pure hull fill", abs(100.0 * (oh - 3000) / 3000) <= 8, f"err={100.0*(oh-3000)/3000:+.1f}%")

# ---- 4. the clearance tripwire -------------------------------------------
print("\n4. clearance precondition trips on old geometry, passes on new")
check("precondition shipped", "cannot distinguish true from hull" in GATE)


def clears(t, w):
    return w == t or abs(w - t) > CLEAR * t


check("old E fails clearance", not clears(ot, oh), f"gap={100*(oh/ot-1):.1f}% need >{CLEAR*100:.0f}%")
for i in (2, 3, 4):
    check(f"arm {i} clears hull", clears(want[i], hull[i]), f"{100*(hull[i]/want[i]-1):+.0f}%")
    check(f"arm {i} clears bbox", clears(want[i], bbox[i]), f"{100*(bbox[i]/want[i]-1):+.0f}%")

print("\n" + ("VERIFY_FAIL: " + ", ".join(fails) if fails else "VERIFY_OK: all checks passed"))
sys.exit(1 if fails else 0)
