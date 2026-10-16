#!/usr/bin/env python3
"""FP-53 perf budget tooling (used by tools/ci-perf.sh).

  perf_compare.py parse <log> <json>            -> one-line JSON of metrics for a single run
  perf_compare.py compare <budgets.json> <runs-dir> [--record]

A run's metrics (microseconds, except startup_ms) come from the FrameTimings JSON
(engine/host/FrameTimings.*, FP-01): record = build_start..build_end (paint walk +
display list), raster = raster_start..raster_end, total = vsync..present, each at
nearest-rank p95/p99, plus first_present_ms from the log.

compare: per fixture and metric the MEDIAN of the runs is checked against
  limit = (budget * (1 + tolerance) + max(floor, 2 * baseline_spread)) * scale
  scale = clamp(run CPU control / baseline CPU control, 1, 1.75)
so one noisy run cannot move the median, and a metric whose baseline was itself
jittery gets proportionally more slack. --record rewrites the budgets from the runs.
"""
import json
import re
import statistics
import sys
from pathlib import Path

METRICS = ["record_p95_us", "record_p99_us", "raster_p95_us", "raster_p99_us",
           "total_p95_us", "total_p99_us", "startup_ms"]
FLOORS = {"record_p95_us": 400, "record_p99_us": 1500, "raster_p95_us": 400,
          "raster_p99_us": 1500, "total_p95_us": 500, "total_p99_us": 2000,
          "startup_ms": 400}
MAX_SCALE = 1.75  # a 5 ms regression on the heaviest fixture is still > +100%
STAMPS = ["vsync_us", "build_start_us", "build_end_us", "raster_start_us", "raster_end_us", "present_us"]


def pct(vals, p):
    v = sorted(vals)
    return v[max(1, (len(v) * p + 99) // 100) - 1]


def control_ms():
    """Same-run CPU control: best of 5 fixed busy loops. Contention on the box slows it the way it
    slows the frame loop, so compare() can scale limits by the observed slowdown."""
    import time
    best = 1e9
    for _ in range(5):
        t = time.perf_counter()
        x = 0
        for i in range(400000):
            x += i * i % 7
        best = min(best, (time.perf_counter() - t) * 1000)
    return best


def parse(log_path, json_path):
    log = open(log_path, errors="replace").read()
    m = re.search(r"^rn-impeller: first_present_ms=(\d+)$", log, re.M)
    if not m:
        sys.exit("PERF_FAIL: no first_present_ms in %s" % log_path)
    if not re.search(r"^rn-impeller: scene_nodes=[1-9]", log, re.M):
        sys.exit("PERF_FAIL: run mounted nothing (%s)" % log_path)
    recs = json.load(open(json_path))["frames"]
    if len(recs) < 20:
        sys.exit("PERF_FAIL: only %d frame records in %s" % (len(recs), json_path))
    rec, ras, tot = [], [], []
    for r in recs:
        t = [r[k] for k in STAMPS]
        if min(t) < 0 or t != sorted(t):
            sys.exit("PERF_FAIL: incomplete/non-monotonic record %s" % r)
        rec.append(t[2] - t[1]); ras.append(t[4] - t[3]); tot.append(t[5] - t[0])
    out = {"frames": len(recs), "startup_ms": int(m.group(1)), "control_ms": round(control_ms(), 2)}
    for name, v in (("record", rec), ("raster", ras), ("total", tot)):
        out[name + "_p95_us"] = pct(v, 95)
        out[name + "_p99_us"] = pct(v, 99)
    print(json.dumps(out))


def load_runs(runs_dir):
    runs = {}
    for f in sorted(Path(runs_dir).glob("*.run.json")):
        fx = f.name.split(".")[0]
        runs.setdefault(fx, []).append(json.loads(f.read_text()))
    return runs


def compare(budget_path, runs_dir, record, only=None):
    b = json.load(open(budget_path))
    runs = load_runs(runs_dir)
    tol = b.get("tolerance_pct", 10) / 100.0
    if record:
        for fx, rs in runs.items():
            ent = b["fixtures"].setdefault(fx, {})
            ent["baseline"] = {k: int(statistics.median(r[k] for r in rs)) for k in METRICS}
            ent["spread"] = {k: max(r[k] for r in rs) - min(r[k] for r in rs) for k in METRICS}
            ent["runs"] = len(rs)
            ent["control_ms"] = round(min(r["control_ms"] for r in rs), 2)
        json.dump(b, open(budget_path, "w"), indent=2, sort_keys=True)
        open(budget_path, "a").write("\n")
        print("PERF_RECORDED %s (%d fixtures)" % (budget_path, len(runs)))
        return 0
    bad = []
    print("%-14s %-14s %9s %9s %9s  %s" % ("fixture", "metric", "budget", "median", "limit", "runs"))
    over = []
    for fx, ent in sorted(b["fixtures"].items()):
        if only and fx not in only:
            continue
        rs = runs.get(fx)
        if not rs or "baseline" not in ent:
            bad.append("%s: no runs or no baseline" % fx)
            continue
        ctl = statistics.median(r["control_ms"] for r in rs)
        scale = min(MAX_SCALE, max(1.0, ctl / ent["control_ms"]))
        print("%s: control %.1f ms vs baseline %.1f ms, limits x%.2f" % (fx, ctl, ent["control_ms"], scale))
        for k in METRICS:
            med = int(statistics.median(r[k] for r in rs))
            base = ent["baseline"][k]
            slack = max(FLOORS[k], 2 * ent.get("spread", {}).get(k, 0))
            limit = int((base * (1 + tol) + slack) * scale)
            ok = med <= limit
            print("%-14s %-14s %9d %9d %9d  %s %s" % (fx, k, base, med, limit,
                  ",".join(str(r[k]) for r in rs), "ok" if ok else "OVER"))
            if not ok:
                if fx not in over:
                    over.append(fx)
                bad.append("%s %s median %d over limit %d (budget %d)" % (fx, k, med, limit, base))
    if bad:
        for x in bad:
            print("PERF_FAIL: " + x)
        print("PERF_OVER_FIXTURES: " + " ".join(over))
        return 1
    print("PERF_COMPARE_OK")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "parse":
        parse(a[1], a[2])
    elif a and a[0] == "compare":
        only = a[a.index("--only") + 1].split(",") if "--only" in a else None
        sys.exit(compare(a[1], a[2], "--record" in a, only))
    else:
        sys.exit(__doc__)
