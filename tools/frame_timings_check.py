#!/usr/bin/env python3
"""FP-01 checker for one rn-impeller run: frame_timings_check.py <arm> <log> <json> <min_n> <exact_n|-> <min_discarded>

Fails (exit 1, `FT_FAIL: <arm>: ...`) unless the summary line is present with
zero errors, n == presents == JSON records, every record has all six stamps in
non-decreasing order, frame numbers are unique, and the printed percentiles
equal nearest-rank percentiles recomputed from the JSON.
"""
import json
import re
import sys

STAMPS = ["vsync_us", "build_start_us", "build_end_us", "raster_start_us",
          "raster_end_us", "present_us"]
FIELDS = ["n", "build_p50", "build_p95", "build_p99", "raster_p50",
          "raster_p95", "raster_p99", "total_p95", "frame_timing_errors",
          "discarded"]


def fail(arm, msg):
    print("FT_FAIL: %s: %s" % (arm, msg))
    sys.exit(1)


def pct(vals, p):
    v = sorted(vals)
    rank = max(1, (len(v) * p + 99) // 100)
    return v[rank - 1]


def main():
    arm, log_path, json_path, min_n, exact_n, min_disc = sys.argv[1:7]
    log = open(log_path, errors="replace").read()
    m = re.search(r"^rn-impeller: frame_timings (n=.*)$", log, re.M)
    if not m:
        fail(arm, "no frame_timings summary line in the log")
    kv = dict(t.split("=", 1) for t in m.group(1).split())
    for f in FIELDS:
        if f not in kv or not re.fullmatch(r"-?\d+", kv[f]):
            fail(arm, "summary field %s missing or not an integer: %s" % (f, m.group(1)))
    s = {k: int(v) for k, v in kv.items() if k in FIELDS}
    if s["frame_timing_errors"] != 0:
        fail(arm, "frame_timing_errors=%d (out-of-order or incomplete stamps)" % s["frame_timing_errors"])
    pm = re.search(r"^rn-impeller: presents=(\d+)$", log, re.M)
    if not pm:
        fail(arm, "no presents= line in the log")
    presents = int(pm.group(1))
    if s["n"] != presents:
        fail(arm, "n=%d does not match presents=%d" % (s["n"], presents))
    if s["n"] < int(min_n):
        fail(arm, "n=%d below the expected minimum %s" % (s["n"], min_n))
    if exact_n != "-" and s["n"] != int(exact_n):
        fail(arm, "n=%d, expected exactly %s" % (s["n"], exact_n))
    if s["discarded"] < int(min_disc):
        fail(arm, "discarded=%d, expected >= %s idle-skip frames" % (s["discarded"], min_disc))

    try:
        recs = json.load(open(json_path))["frames"]
    except Exception as e:  # noqa: BLE001
        fail(arm, "cannot read %s: %s" % (json_path, e))
    if len(recs) != presents:
        fail(arm, "JSON has %d records, presents=%d" % (len(recs), presents))
    seen = set()
    build, raster, total = [], [], []
    for r in recs:
        fn = r.get("frame")
        if fn in seen:
            fail(arm, "duplicate frame number %s" % fn)
        seen.add(fn)
        ts = [r.get(k) for k in STAMPS]
        for k, t in zip(STAMPS, ts):
            if not isinstance(t, int) or t < 0:
                fail(arm, "frame %s incomplete: %s=%s" % (fn, k, t))
        for i in range(1, len(ts)):
            if ts[i] < ts[i - 1]:
                fail(arm, "frame %s not monotonic: %s=%d < %s=%d"
                     % (fn, STAMPS[i], ts[i], STAMPS[i - 1], ts[i - 1]))
        build.append(ts[2] - ts[1])
        raster.append(ts[4] - ts[3])
        total.append(ts[5] - ts[0])
    want = {
        "build_p50": pct(build, 50), "build_p95": pct(build, 95), "build_p99": pct(build, 99),
        "raster_p50": pct(raster, 50), "raster_p95": pct(raster, 95), "raster_p99": pct(raster, 99),
        "total_p95": pct(total, 95),
    }
    for k, v in want.items():
        if s[k] != v:
            fail(arm, "printed %s=%d but the JSON gives %d" % (k, s[k], v))
    if not (s["build_p50"] <= s["build_p95"] <= s["build_p99"]
            and s["raster_p50"] <= s["raster_p95"] <= s["raster_p99"]):
        fail(arm, "percentiles not ordered: %s" % m.group(1))
    if s["raster_p50"] <= 0:
        fail(arm, "raster_p50=%d: a GPU draw cannot take 0 us" % s["raster_p50"])
    if s["total_p95"] < max(s["build_p95"], s["raster_p95"]):
        fail(arm, "total_p95=%d below a phase p95" % s["total_p95"])
    if s["total_p95"] > 5_000_000:
        fail(arm, "total_p95=%d us is not a sane frame" % s["total_p95"])
    print("FT_ARM_OK %s n=%d presents=%d discarded=%d build_p95=%d raster_p95=%d total_p95=%d"
          % (arm, s["n"], presents, s["discarded"], s["build_p95"], s["raster_p95"], s["total_p95"]))


if __name__ == "__main__":
    main()
