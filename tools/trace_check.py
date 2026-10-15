#!/usr/bin/env python3
"""Validate a Chrome trace written by rn-impeller --trace-out (FP-02).

usage: trace_check.py FILE [--frames N] [--min-frames N] [--raster-thread] [--expect NAME@THREAD[:MIN]]...

--raster-thread (FP-15, windowed): the RASTER spans (Raster, Draw, Present,
RasterJobs, Offscreen) must sit on the "raster" thread and are counted there.

Checks, in order: valid JSON, every span name sits on its expected thread
(affinity), begin/end balanced per thread, frame spans contain >= 3 distinct
named child spans, per-frame span counts. Prints `spans_per_frame=` on success.
"""
import json
import sys
from collections import Counter, defaultdict

FRAME_CHILDREN = ["PaintWalk", "DisplayListBuild", "Draw", "Present"]
# Spans that may only ever appear on the named thread.
HOME = {"Frame": "main", "Record": "main", "Raster": "main", "PaintWalk": "main", "DisplayListBuild": "main", "Draw": "main",
        "Present": "main", "NativeAnimatedPump": "main", "NativeAnimatedTick": "main",
        "JsCommit": "js", "MountTransaction": "js", "TextMeasure": "js",
        "ImageFetch": "image-io", "ImageDecode": "image-io", "ImageUpload": "main",
        "RasterJobs": "main", "Offscreen": "main", "TextureUpload": "main"}
RASTER_SPANS = ["Raster", "Draw", "Present", "RasterJobs", "Offscreen"]


def fail(msg):
    print("TRACE_FAIL: " + msg)
    sys.exit(1)


def main():
    a = sys.argv[1:]
    path = a.pop(0)
    exact = minimum = None
    expects = []
    while a:
        k = a.pop(0)
        if k == "--frames": exact = int(a.pop(0))
        elif k == "--min-frames": minimum = int(a.pop(0))
        elif k == "--expect": expects.append(a.pop(0))
        elif k == "--raster-thread":
            for n in RASTER_SPANS: HOME[n] = "raster"
        else: fail("bad arg " + k)
    try:
        doc = json.load(open(path))
        events = doc["traceEvents"]
    except Exception as e:  # noqa: BLE001
        fail("not valid trace JSON: %s" % e)

    names = {e["tid"]: e["args"]["name"] for e in events if e["ph"] == "M" and e["name"] == "thread_name"}
    spans = [e for e in events if e["ph"] in "BE"]
    if not spans: fail("no span events")

    for e in events:
        if e["ph"] == "B":
            home = HOME.get(e["name"])
            on = names.get(e["tid"], "tid%d" % e["tid"])
            if home and on != home:
                fail("span %s recorded on thread %s, expected %s" % (e["name"], on, home))

    stacks = defaultdict(list)
    children = []  # distinct child names per closed Frame
    open_names = defaultdict(list)
    for e in sorted(spans, key=lambda x: x["ts"]):  # stable: B before E at equal ts
        t = e["tid"]
        if e["ph"] == "B":
            stacks[t].append(e)
            if e["name"] == "Frame": open_names[t].append(set())
            elif stacks[t][:-1] and any(s["name"] == "Frame" for s in stacks[t][:-1]):
                open_names[t][-1].add(e["name"])
        else:
            if not stacks[t]: fail("end event with no open span on thread %s" % names.get(t, t))
            b = stacks[t].pop()
            if e["ts"] < b["ts"]: fail("span %s ends before it begins" % b["name"])
            if b["name"] == "Frame": children.append(open_names[t].pop())
    left = [(names.get(t, t), s["name"]) for t, st in stacks.items() for s in st]
    if left: fail("unclosed spans: %s" % left[:3])

    per = Counter(names.get(e["tid"]) + ":" + e["name"] for e in events if e["ph"] == "B")
    for c in children:
        if len(c) < 3: fail("a frame has only %d named child spans: %s" % (len(c), sorted(c)))
    if exact is not None or minimum is not None:
        want = exact if exact is not None else minimum
        for n in ["Frame"] + FRAME_CHILDREN:
            got = per[HOME[n] + ":" + n]
            if (exact is not None and got != exact) or got < want:
                fail("%s count on %s = %d, expected %s%d" % (n, HOME[n], got, "" if exact is not None else ">= ", want))
    for x in expects:
        spec, _, mn = x.partition(":")
        name, _, thread = spec.partition("@")
        if per[thread + ":" + name] < int(mn or 1):
            fail("expected span %s on thread %s (>= %s), got %d" % (name, thread, mn or 1, per[thread + ":" + name]))
    nframes = max(per["main:Frame"], 1)
    total = sum(per.values())
    print("ok events=%d spans=%d frames=%d spans_per_frame=%.2f threads=%s"
          % (len(events), total, per["main:Frame"], total / nframes, ",".join(sorted(set(names.values())))))


main()
