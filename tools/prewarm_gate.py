#!/usr/bin/env python3
"""FP-34 gate helper: reads --frame-timings-out JSON files from fixtures/fp34-prewarm.

  s1s2 <json>   prints "S1 S2 raster_s1_ms raster_s2_ms" for one run. S1 is the first frame whose node
                count jumps (the feature scene mounts: first use of every class), S2 the first frame with
                one more node than S1 (the root colour changed and a node mounted: a full repaint of the
                same scene). S1 - S2 is what first use costs over a warm repeat of identical content.
  prewarm <json>  prints the prewarm_us recorded with the frames.
"""
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def s1s2(path):
    frames = load(path)["frames"]
    raster = [(x["raster_end_us"] - x["raster_start_us"]) / 1000.0 for x in frames]
    nodes = [x["nodes"] for x in frames]
    base = nodes[0]
    s1 = next((i for i, v in enumerate(nodes) if v > base + 10), None)
    if s1 is None:
        sys.exit("no frame mounted the feature scene (nodes never rose above %d)" % base)
    s2 = next((i for i, v in enumerate(nodes) if i > s1 and v > nodes[s1]), None)
    if s2 is None:
        sys.exit("no later full repaint (node count stayed %d after frame %d)" % (nodes[s1], s1))
    print(s1, s2, "%.2f" % raster[s1], "%.2f" % raster[s2])


if __name__ == "__main__":
    if sys.argv[1] == "s1s2":
        s1s2(sys.argv[2])
    elif sys.argv[1] == "prewarm":
        print(load(sys.argv[2])["prewarm_us"])
