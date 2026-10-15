#!/usr/bin/env python3
"""FP-54: check a DevTools trace (tools/cdp-probe.js trace) against the app log.

usage: devtools_frames_check.py <trace.json> <app.log> <cdp.log>
Prints FAIL lines prefixed DEVTOOLS_FRAMES_FAIL and exits 1 on the first defect.
"""
import json
import re
import sys

trace_path, log_path, cdp_path = sys.argv[1:4]
events = json.load(open(trace_path))["traceEvents"]
log = open(log_path, errors="replace").read()


def fail(msg):
    print("DEVTOOLS_FRAMES_FAIL: " + msg)
    sys.exit(1)


def stats(what):
    m = re.search(r"devtools_trace %s commits=(\d+) emitted=(\d+) sessions=(\d+)" % what, log)
    if not m:
        fail("no 'devtools_trace %s' line: the host never saw the recording %s" % (what, what))
    return [int(x) for x in m.groups()]


begins = [e for e in events if e.get("name") == "BeginFrame"]
draws = [e for e in events if e.get("name") == "DrawFrame"]
print("   trace: %d events, BeginFrame=%d DrawFrame=%d" % (len(events), len(begins), len(draws)))
if not draws:
    fail("the trace has no frame events (BeginFrame/DrawFrame): DevTools shows no frames for this host")

start_commits, start_emitted, _ = stats("started")
stop_commits, stop_emitted, _ = stats("stopped")
m = re.search(r"devtools_frames sessions=(\d+) commits=(\d+) emitted=(\d+)", log)
if not m:
    fail("no 'devtools_frames' exit line")
sessions, exit_commits, exit_emitted = (int(x) for x in m.groups())
m = re.search(r"^rn-impeller: presents=(\d+)", log, re.M)
presents = int(m.group(1)) if m else -1

window = stop_commits - start_commits
after = exit_commits - stop_commits
print("   host: commits start=%d stop=%d exit=%d presents=%d emitted start=%d stop=%d exit=%d sessions=%d"
      % (start_commits, stop_commits, exit_commits, presents, start_emitted, stop_emitted,
         exit_emitted, sessions))
if exit_commits != presents:
    fail("frame commits %d != presents %d: the DevTools counter is not per present" % (exit_commits, presents))
if start_commits < 10:
    fail("only %d frames before Tracing.start: the not-recording arm is blind" % start_commits)
if window < 30:
    fail("only %d presents while recording: the animation did not run in the window" % window)
if after < 10:
    fail("only %d presents after Tracing.end: the after-stop arm is blind" % after)

# a/b: frame count
if start_emitted != 0:
    fail("emitted %d frames to DevTools before Tracing.start (frames sent while not recording)" % start_emitted)
if exit_emitted != len(draws):
    fail("host emitted %d frames to DevTools but the trace holds %d (frames sent while not recording)"
         % (exit_emitted, len(draws)))
if len(draws) != window:
    fail("trace has %d DrawFrame events, want %d (one per present while recording)" % (len(draws), window))
if len(begins) != len(draws):
    fail("BeginFrame %d != DrawFrame %d" % (len(begins), len(draws)))

# c: monotonic + paired
begin_by_seq = {e["args"]["frameSeqId"]: e["ts"] for e in begins}
last_ts = last_seq = -1
for e in draws:
    seq, ts = e["args"]["frameSeqId"], e["ts"]
    if seq not in begin_by_seq:
        fail("DrawFrame seq %s has no BeginFrame" % seq)
    if begin_by_seq[seq] > ts:
        fail("frame %s begins at %s after it draws at %s" % (seq, begin_by_seq[seq], ts))
    if ts <= last_ts or seq <= last_seq:
        fail("frame timestamps not monotonic: seq %s ts %s after seq %s ts %s" % (seq, ts, last_seq, last_ts))
    last_ts, last_seq = ts, seq


# c: clock base. Anchor = RN's own stamps: TracingStartedInPage (recording
# start) and the Fabric "layout" TimeStamps on track Renderer, which RN takes
# with HighResTimeStamp::now() for every commit of animation 2 (the app is idle
# around it, so they bracket the frames).
started = [e["ts"] for e in events if e.get("name") == "TracingStartedInPage"]
if not started:
    fail("no TracingStartedInPage event")
rn = sorted(e["args"]["data"]["start"] for e in events if e.get("name") == "TimeStamp"
            and e.get("args", {}).get("data", {}).get("track") == "Renderer"
            and isinstance(e["args"]["data"].get("start"), (int, float)))
if len(rn) < window:
    fail("only %d RN Renderer commits in the trace: no clock anchor" % len(rn))
lo, hi = max(started[0], rn[0] - 50_000), rn[-1] + 400_000
first_begin = min(begin_by_seq.values())
print("   clock: trace start=%d RN commits %+.1f..%+.1f ms, frames %+.1f..%+.1f ms"
      % (started[0], (rn[0] - started[0]) / 1e3, (rn[-1] - started[0]) / 1e3,
         (first_begin - started[0]) / 1e3, (last_ts - started[0]) / 1e3))
for e in begins + draws:
    if not lo <= e["ts"] <= hi:
        fail("%s seq %s at ts %d lies outside RN's commits [%d, %d] (wrong clock base: %+.1f ms off)"
             % (e["name"], e["args"]["frameSeqId"], e["ts"], lo, hi,
                (e["ts"] - (lo if e["ts"] < lo else hi)) / 1000.0))

# d: host spans
spans = [e for e in events if e.get("name") == "TimeStamp"
         and e.get("args", {}).get("data", {}).get("track") == "rn-impeller main"]
names = sorted({e["args"]["data"]["name"] for e in spans})
print("   host spans on rn-impeller main: %d (%s)" % (len(spans), ",".join(names)[:120]))
for want in ("Frame", "Present"):
    n = sum(1 for e in spans if e["args"]["data"]["name"] == want)
    if n < window:
        fail("only %d '%s' host spans for %d frames" % (n, want, window))
for e in spans:
    d = e["args"]["data"]
    if not (lo - 50_000 <= d["start"] <= d["end"] <= hi):
        fail("host span %s [%s, %s] outside the recording window" % (d["name"], d["start"], d["end"]))
print("   OK: %d frames == %d presents while recording, 0 outside, monotonic, on RN's clock" % (len(draws), window))
