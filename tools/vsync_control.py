#!/usr/bin/env python3
"""FP-11 control arm for tools/ci-vsync.sh: a 60 Hz sleep-to-grid ticker run
alongside each engine run. Each tick does WORK_US of CPU work and stamps its
"present" after it, so a loaded box preempts it the way it preempts the engine's
frame. Its interval stddev and its short intervals are the box's scheduling noise
at that moment. FP-06: WORK_US is the engine's own measured frame cost on the
same binary under the same load (ci-vsync's calibration run), so an ASan binary
on a hogged box gets a control that is exposed to preemption as long as its frames.

usage: vsync_control.py <seconds> <out> [work_us]   (one present time in us per line)
"""
import sys
import time

secs, out = float(sys.argv[1]), sys.argv[2]
period = 1_000_000_000 // 60
WORK_NS = int(sys.argv[3]) * 1000 if len(sys.argv) > 3 else 1_000_000
start = time.perf_counter_ns()
target = start + period
wakes = []
while target - start < secs * 1e9:
    rem = target - time.perf_counter_ns()
    if rem > 0:
        time.sleep(rem / 1e9)
    now = time.perf_counter_ns()
    while time.perf_counter_ns() - now < WORK_NS:
        pass
    wakes.append(time.perf_counter_ns() // 1000)
    while target <= now:  # snap to the next grid tick, like SnapToNextTick
        target += period
with open(out, 'w') as f:
    f.write('\n'.join(str(w) for w in wakes) + '\n')
