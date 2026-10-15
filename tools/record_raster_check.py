#!/usr/bin/env python3
"""FP-13 checks for tools/ci-record-raster.sh.

usage:
  record_raster_check.py diff A.ppm B.ppm A.log
      exit 0 when every pixel matches outside the wall-clock nodes A.log
      reports; prints `diff_pixels=N of M masked=K`.
  record_raster_check.py hash A.ppm A.log
      sha256 of the masked pixels (the golden-file key), plus `masked=K`.
  record_raster_check.py colors A.ppm
      exit 0 when the capture has >= 2 distinct colours (not a blank frame).
  record_raster_check.py frames RUN.log TRACE.json TIMINGS.json
      every Frame span holds one Record then one Raster (Record ends before
      Raster begins, same frame arg), Record holds PaintWalk + DisplayListBuild,
      Raster holds Draw; every timing record has build_end <= raster_start and
      all stamps; records == presents == pipeline produced == consumed.
"""
import hashlib
import json
import re
import sys

# Painted from the wall clock (SceneGraph.cpp, A20 spinner), so two renders of
# the same frame differ there. Every node_frame of these kinds is zeroed before
# a compare; the gate prints how many pixels each capture had masked.
WALL_CLOCK_KINDS = ("ActivityIndicatorView",)


def ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise SystemExit("RR_FAIL: %s is not a P6 ppm" % path)
    return int(m.group(1)), int(m.group(2)), data[m.end():]


def masks(log_path):
    rects = []
    for kind, x, y, w, h in re.findall(
            r"^rn-impeller: node_frame=(\w+),\d+,([\d.]+),([\d.]+),([\d.]+),([\d.]+)",
            open(log_path).read(), re.M):
        if kind in WALL_CLOCK_KINDS:
            rects.append(tuple(int(round(float(v))) for v in (x, y, w, h)))
    return rects


def masked(path, rects):
    w, h, px = ppm(path)
    px = bytearray(px)
    n = 0
    for x, y, rw, rh in rects:
        for yy in range(max(y, 0), min(y + rh, h)):
            lo, hi = max(x, 0), min(x + rw, w)
            if hi > lo:
                px[(yy * w + lo) * 3:(yy * w + hi) * 3] = bytes((hi - lo) * 3)
                n += hi - lo
    return w, h, bytes(px), n


def digest(path, log_path):
    w, h, px, n = masked(path, masks(log_path))
    print("%s masked=%d" % (hashlib.sha256(b"%dx%d:" % (w, h) + px).hexdigest(), n))
    return 0


def diff(a, b, log_path):
    rects = masks(log_path)
    wa, ha, pa, _ = masked(a, rects)
    wb, hb, pb, n = masked(b, rects)
    if (wa, ha) != (wb, hb):
        print("diff_pixels=size %dx%d vs %dx%d" % (wa, ha, wb, hb))
        return 1
    d = sum(1 for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3]) if pa != pb else 0
    print("diff_pixels=%d of %d masked=%d" % (d, wa * ha, n))
    return 1 if d else 0


def colors(path):
    _, _, px = ppm(path)
    n = len({px[i:i + 3] for i in range(0, len(px), 3)})
    print("colors=%d" % n)
    return 0 if n >= 2 else 1


def fail(msg):
    print("RR_FAIL frames: " + msg)
    sys.exit(1)


def frames(log_path, trace_path, timings_path):
    log = open(log_path).read()
    presents = int(re.findall(r"^rn-impeller: presents=(\d+)", log, re.M)[-1])
    m = re.search(r"^rn-impeller: pipeline depth=(\d+) produced=(\d+) consumed=(\d+) "
                  r"abandoned=(\d+) refused=(\d+) max_inflight=(\d+)", log, re.M)
    if not m:
        fail("no `pipeline` summary line (the frame never went through the Pipeline)")
    depth, produced, consumed, abandoned, refused, inflight = map(int, m.groups())
    # FP-15: a windowed run with a raster thread is depth 2 (animator.cc) and
    # its Raster spans live on the "raster" thread, matched to Record by frame.
    threaded = re.search(r"^rn-impeller: raster_thread threaded=1", log, re.M) is not None
    if threaded:
        if depth != 2 or not 1 <= inflight <= 2:
            fail("raster-thread pipeline must be depth 2, max_inflight 1..2 (got %d, %d)" % (depth, inflight))
    elif depth != 1 or inflight != 1:
        fail("single-thread pipeline must be depth 1, max_inflight 1 (got %d, %d)" % (depth, inflight))
    if not (produced == consumed == presents) or refused:
        fail("produced=%d consumed=%d presents=%d refused=%d" % (produced, consumed, presents, refused))

    events = json.load(open(trace_path))["traceEvents"]
    tname = {e["tid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e.get("name") == "thread_name"}
    spans = sorted((e for e in events if e.get("ph") in ("B", "E")), key=lambda e: e["ts"])
    stacks, done, rasters = {}, [], {}
    for e in spans:
        stack = stacks.setdefault(e["tid"], [])
        if e["ph"] == "B":
            e["kids"] = []
            if stack:
                stack[-1]["kids"].append(e)
            stack.append(e)
        else:
            b = stack.pop()
            b["end"] = e["ts"]
            if b["name"] == "Frame":
                done.append(b)
            elif b["name"] == "Raster" and not any(x["name"] == "Frame" for x in stack):
                rasters.setdefault(b.get("args", {}).get("frame"), []).append(b)
    frames_seen = []
    for f in done:
        rec = [k for k in f["kids"] if k["name"] == "Record"]
        ras = [k for k in f["kids"] if k["name"] == "Raster"]
        if threaded:
            if ras:
                fail("a Frame on %s holds a Raster span: raster ran on the platform thread" % tname.get(f["tid"]))
            if len(rec) == 1:
                ras = rasters.get(rec[0].get("args", {}).get("frame"), [])
                if any(tname.get(x["tid"]) != "raster" for x in ras):
                    fail("Raster span for frame %s is not on the raster thread" % rec[0].get("args", {}).get("frame"))
        if len(rec) != 1 or len(ras) != 1:
            fail("a Frame holds %d Record and %d Raster spans (want 1 and 1)" % (len(rec), len(ras)))
        r, s = rec[0], ras[0]
        if r["end"] > s["ts"]:
            fail("Record (end %d) overlaps Raster (begin %d)" % (r["end"], s["ts"]))
        rf, sf = r.get("args", {}).get("frame"), s.get("args", {}).get("frame")
        if rf is None or rf != sf:
            fail("Raster drew frame %s but Record built frame %s" % (sf, rf))
        names = {k["name"] for k in r["kids"]}
        if not {"PaintWalk", "DisplayListBuild"} <= names:
            fail("Record lacks PaintWalk/DisplayListBuild: %s" % sorted(names))
        if "Draw" not in {k["name"] for k in s["kids"]}:
            fail("Raster lacks Draw")
        frames_seen.append(rf)
    if len(frames_seen) != presents:
        fail("%d traced frames vs presents=%d" % (len(frames_seen), presents))

    recs = json.load(open(timings_path))["frames"]
    if len(recs) != presents:
        fail("%d timing records vs presents=%d" % (len(recs), presents))
    keys = ["vsync_us", "build_start_us", "build_end_us", "raster_start_us", "raster_end_us", "present_us"]
    for t in recs:
        missing = [k for k in keys if t.get(k) is None]
        if missing:
            fail("frame %s misses stamps %s" % (t["frame"], missing))
        if t["build_end_us"] > t["raster_start_us"]:
            fail("frame %s: build_end %d after raster_start %d" % (t["frame"], t["build_end_us"], t["raster_start_us"]))
    if sorted(t["frame"] for t in recs) != sorted(frames_seen):
        fail("timing frame numbers differ from the traced Record/Raster frames")
    print("frames ok n=%d pipeline produced=%d consumed=%d depth=%d threaded=%d"
          % (presents, produced, consumed, depth, int(threaded)))


def main():
    a = sys.argv[1:]
    if a and a[0] == "diff" and len(a) == 4:
        sys.exit(diff(a[1], a[2], a[3]))
    if a and a[0] == "hash" and len(a) == 3:
        sys.exit(digest(a[1], a[2]))
    if a and a[0] == "colors" and len(a) == 2:
        sys.exit(colors(a[1]))
    if a and a[0] == "frames" and len(a) == 4:
        frames(a[1], a[2], a[3])
        return
    raise SystemExit(__doc__)


main()
