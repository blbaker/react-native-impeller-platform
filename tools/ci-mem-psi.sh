#!/usr/bin/env bash
# Linux low-memory purge gate (host/MemoryPressure.cpp): a PSI trigger on /proc/pressure/memory
# runs the same purge as macOS/Windows/Android (image cache to the floor + malloc_trim).
# Windowed linux-x64 under a private Xvfb, fixtures/fp33-memory-budget showing 8 images, so the cache
# holds real bytes when a purge comes. Arms, in order:
#   fire     a memory hog in its own systemd --user scope (MemoryHigh=16M, no swap, allocating 128 MB
#            over and over) stalls on memory;
#            the engine armed the default trigger, no linux-psi purge before the hog, at least one after
#            it, the first one freed image bytes down to the floor (0), and a mem_trim naming
#            low_memory follows. The hog's own stall is measured, so a quiet hog fails the harness
#   control  the same run with no hog: no linux-psi purge. The host's own memory stall is read at both
#            ends of the run; if it reached the trigger threshold the arm is INCONCLUSIVE, not a pass.
#            Kernel events logged action=skip are allowed: an unprivileged trigger fires on the first
#            tiny stalls after arming (stale window start in psi_trigger_create), and the engine
#            must skip them
#   off      the hog again with RNI_MEM_PSI=off: armed=0 reason=RNI_MEM_PSI=off, no linux-psi purge
#   bad      RNI_MEM_PSI="some 0 2000000" (threshold 0, which every kernel refuses): armed=0 with the
#            failing step and errno, never silent, and no psi-poll fallback (that is for EPERM only)
#   nocap    the hog again, with no CAP_SYS_RESOURCE: tools/psi-eperm-shim.c (LD_PRELOAD) fails the
#            write-mode open with EPERM as psi_open does before 6.5. The trigger logs armed=0 step=open
#            errno=1, the poll logs psi-poll armed=1 once, and the poll purges under the hog exactly as
#            the fire arm does (no purge before it, image bytes to the floor, mem_trim low_memory); no
#            poll purge below the threshold
#   off-nocap the hog, no capability and RNI_MEM_PSI=off: off line, the trigger is not even opened,
#            no psi-poll line, no purge (off turns off both paths)
#   ARMS="fire control off bad nocap off-nocap" bash tools/ci-mem-psi.sh
# Without the shim the trigger is unprivileged here, so fire/control need Linux 6.5+ (2 s windows);
# before 6.5 they need CAP_SYS_RESOURCE. Mutants: tools/mutation-verify-mem-psi.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/host-window.sh
fail() { echo "MEM_PSI_FAIL: $*" >&2; exit 1; }
[ "$(rni_host)" = linux ] || fail "linux only (PSI)"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="$ROOT/fixtures/fp33-memory-budget/prebuilt/fp33-memory-budget.bundle"
ARMS="${ARMS:-fire control off bad nocap off-nocap}"
THRESHOLD_US=100000 WINDOW_S=2
[ -x "$BIN" ] || fail "no engine at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"
[ -r /proc/pressure/memory ] || fail "harness: no /proc/pressure/memory (kernel without PSI)"
python3 -c 'import numpy, PIL' 2>/dev/null || fail "harness: python3 with numpy + PIL is required"
U="$(id -u)"
grep -qw memory "/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/cgroup.controllers" 2>/dev/null \
  || fail "harness: the memory controller is not delegated to systemd --user (the hog needs MemoryHigh)"
echo "engine: $BIN ($(sha256sum "$BIN" | cut -c1-12))"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-mem-psi.XXXXXX")"
cleanup() { [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/img"
python3 tools/memory_budget_gate.py gen "$WORK/img" 8 256
SHIM="$WORK/psi-eperm-shim.so"
case " $ARMS " in *" nocap "*|*" off-nocap "*)
  command -v cc > /dev/null || fail "harness: no C compiler for tools/psi-eperm-shim.c"
  cc -shared -fPIC -O2 -o "$SHIM" tools/psi-eperm-shim.c -ldl || fail "harness: the EPERM shim did not build" ;;
esac

# Do NOT poll /proc/pressure/memory here: reading it runs the system group's 2 s average update
# without the trigger check (psi_show), so a frequent reader starves unprivileged triggers. The
# hog reports its own cgroup's stall; the control arm reads the system total once at each end.
sys_total() { sed -n 's/^some .*total=\([0-9]*\)$/\1/p' /proc/pressure/memory; }

hog() {  # seconds: allocates 128 MB over and over in a 16 MB memory.high, so the kernel throttles every
  # allocation (a one-shot allocation stalls only until it is charged). Prints its own memory.high and,
  # every 0.5 s, its cgroup's `some` stall total (never more than the system's).
  timeout "$1" systemd-run --user --scope --quiet -p MemoryHigh=16M -p MemorySwapMax=0 -p MemoryMax=512M \
    python3 -c '
import os, time
cg = "/sys/fs/cgroup" + open("/proc/self/cgroup").read().strip().split("::")[-1]
print("hog memory.high=" + open(cg + "/memory.high").read().strip(), flush=True)
parent = os.getpid()
if os.fork() == 0:  # a process, not a thread: the throttled allocator holds the GIL inside the kernel
    while os.getppid() == parent:
        for l in open(cg + "/memory.pressure"):
            if l.startswith("some "): print("hog t=%.3f some_total=%s" % (time.time(), l.split("total=")[1].strip()), flush=True)
        time.sleep(0.5)
    os._exit(0)
while True:
    b = bytearray(128 << 20)
    for i in range(0, len(b), 4096): b[i] = 1
    del b
' > "$WORK/$2.hog" 2>&1 || true
}

run() {  # tag hog|none [ENV=V ...]
  local tag="$1" load="$2"; shift 2
  sys_total > "$WORK/$tag.sys0"
  ( cd / && for kv in "$@"; do export "${kv?}"; done && rni_xrun "$WORK/x$tag" timeout 60 "$BIN" --window \
      --probe-banner off --bundle "$BUNDLE" --app-name Fp33MemoryBudget --width 1536 --height 192 --scale 1 \
      --supersample-rnsvg 0 --initial-url "fp33://cycle?dir=$WORK/img&count=8&per=8&box=192" \
      --idle-run-sec 26 ) > "$WORK/$tag.log" 2>&1 &
  local eng=$!
  for _ in $(seq 1 150); do
    grep -q "FP33 cycled" "$WORK/$tag.log" && grep -q "memory_pressure source=psi" "$WORK/$tag.log" && break
    kill -0 "$eng" 2>/dev/null || break
    sleep 0.1
  done
  grep -q "FP33 cycled" "$WORK/$tag.log" || { tail -5 "$WORK/$tag.log" >&2; fail "$tag: the fixture never showed its images"; }
  wc -c < "$WORK/$tag.log" > "$WORK/$tag.offset"
  if [ "$load" = hog ]; then hog 10 "$tag"; else sleep 10; fi
  sleep 3
  sys_total > "$WORK/$tag.sys1"
  wait "$eng" || fail "$tag: engine exited $? ($(tail -3 "$WORK/$tag.log" | tr '\n' ' '))"
}

check() {  # tag kind
  python3 - "$WORK" "$1" "$2" "$THRESHOLD_US" "$WINDOW_S" <<'PY'
import re, sys
work, tag, kind, thr, win = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
log = open(f"{work}/{tag}.log", errors="replace").read()
off = int(open(f"{work}/{tag}.offset").read())
run_stall = int(open(f"{work}/{tag}.sys1").read()) - int(open(f"{work}/{tag}.sys0").read())
def bad(m): print(f"MEM_PSI_FAIL: {tag}: {m}", file=sys.stderr); sys.exit(1)
purge = re.compile(r"^rn-impeller: low_memory source=linux-psi purge=(\d+) image_cache_bytes_before=(\d+) "
                   r"image_cache_bytes_after=(\d+) freed=(-?\d+)$", re.M)
before, after = list(purge.finditer(log[:off])), list(purge.finditer(log, off))
event = re.compile(r"^rn-impeller: memory_pressure source=psi event=\d+ stall_us=(-?\d+) threshold_us=(\d+) action=(purge|skip)$", re.M)
events = list(event.finditer(log))
skips = [e for e in events if e.group(3) == "skip"]
armed = re.search(r"^rn-impeller: memory_pressure source=psi armed=(\d) (.*)$", log, re.M)
if not armed: bad("no `memory_pressure source=psi armed=` line at start")
polls = re.findall(r"^rn-impeller: memory_pressure source=psi-poll .*$", log, re.M)
poll_armed = [p for p in polls if " armed=" in p]
pev = re.compile(r"^rn-impeller: memory_pressure source=psi-poll event=\d+ stall_us=(-?\d+) threshold_us=(\d+) action=purge$", re.M)
poll_events = list(pev.finditer(log))
shim = re.findall(r"^psi-eperm-shim: open\(/proc/pressure/memory, flags=0x[0-9a-f]+\) -> EPERM$", log, re.M)
if kind in ("fire", "control", "off", "bad") and polls:
    bad(f"the psi-poll fallback ran without an EPERM: {polls[0]}")
if kind in ("fire", "control"):
    if armed.group(0) != 'rn-impeller: memory_pressure source=psi armed=1 trigger="some 100000 2000000" path=/proc/pressure/memory':
        bad(f"default trigger not armed: {armed.group(0)}")
if kind == "nocap":
    if len(shim) != 1: bad(f"harness: the EPERM shim refused {len(shim)} write-mode opens (want 1); the run had its capability")
    if armed.group(0) != ('rn-impeller: memory_pressure source=psi armed=0 trigger="some 100000 2000000" step=open '
                          'errno=1 (Operation not permitted)'):
        bad(f"the trigger did not log armed=0 with EPERM: {armed.group(0)}")
    want = "rn-impeller: memory_pressure source=psi-poll armed=1 interval_ms=2000 kind=some threshold_us=100000 path=/proc/pressure/memory"
    if poll_armed != [want]: bad(f"want exactly one `{want}`, got {poll_armed}")
    if events: bad(f"a kernel trigger event with no trigger armed: {events[0].group(0)}")
    low = [e for e in poll_events if int(e.group(1)) < thr]
    if low: bad(f"a poll purge below the threshold: {low[0].group(0)}")
if kind in ("fire", "off", "nocap", "off-nocap"):
    hog = open(f"{work}/{tag}.hog").read()
    if "hog memory.high=16777216" not in hog: bad(f"harness: the hog ran without its 16M memory.high ({hog.strip()[:120]})")
    hs = [(float(t), int(v)) for t, v in re.findall(r"^hog t=([\d.]+) some_total=(\d+)$", hog, re.M)]
    stall = max((b[1] - a[1] for i, a in enumerate(hs) for b in hs[i:] if b[0] - a[0] <= win + 0.25), default=0)
    if stall < thr: bad(f"harness: the hog stalled only {stall} us in {win:g} s (need {thr}); it made no pressure")
if kind in ("fire", "nocap"):
    if before: bad(f"a linux-psi purge came BEFORE the hog started: {before[0].group(0)}")
    if not after: bad(f"no `low_memory source=linux-psi` after the hog ({stall} us stalled in {win:g} s; events: "
                      f"{[e.group(0).split('event=')[1] for e in events]})")
    first = after[0]
    if kind == "fire":
        ev = [e for e in events if e.start() < first.start()]
        if not ev or ev[-1].group(3) != "purge" or int(ev[-1].group(1)) < thr:
            bad("the linux-psi purge has no `event=N stall_us>=threshold action=purge` line before it")
    else:
        ev = [e for e in poll_events if e.start() < first.start()]
        if not ev: bad("the linux-psi purge has no `source=psi-poll event=N ... action=purge` line before it")
    if int(first.group(2)) <= 0: bad("the first linux-psi purge found an empty cache (the fixture's images were not cached)")
    if int(first.group(3)) != 0: bad(f"the purge left {first.group(3)} bytes with floor 0")
    trim = re.search(r"^rn-impeller: mem_trim why=\S*low_memory\S* ", log[first.end():], re.M)
    if not trim: bad("no mem_trim naming low_memory after the linux-psi purge")
    print(f"MEM_PSI {kind} ok: {len(after)} purge(s) after the hog, none before; first freed "
          f"{first.group(4)} bytes at stall_us={ev[-1].group(1)}; hog stalled {stall} us in {win:g} s; "
          + (f"{len(skips)} kernel event(s) skipped" if kind == "fire" else
             f"trigger armed=0 errno=1 (shim), poll armed=1, {len(poll_events)} poll purge(s), none below {thr}"))
elif kind == "control":
    if run_stall >= thr:
        print(f"MEM_PSI_INCONCLUSIVE: {tag}: the host itself stalled {run_stall} us over the run "
              f"(threshold {thr}); rerun on a quiet host", file=sys.stderr); sys.exit(2)
    if before or after: bad(f"a linux-psi purge with no hog ({run_stall} us stalled): {(before + after)[0].group(0)}")
    if any(e.group(3) == "purge" for e in events): bad("an event was acted on with no hog")
    print(f"MEM_PSI control ok: no purge; host stalled {run_stall} us over the run (threshold {thr}); "
          f"{len(skips)} kernel event(s) below the threshold skipped")
elif kind == "off":
    if armed.group(0) != "rn-impeller: memory_pressure source=psi armed=0 reason=RNI_MEM_PSI=off": bad(f"not off: {armed.group(0)}")
    if before or after or events: bad(f"a linux-psi event or purge with RNI_MEM_PSI=off")
    print(f"MEM_PSI off ok: armed=0, no purge under a hog that stalled {stall} us")
elif kind == "off-nocap":
    if armed.group(0) != "rn-impeller: memory_pressure source=psi armed=0 reason=RNI_MEM_PSI=off": bad(f"not off: {armed.group(0)}")
    if shim: bad("RNI_MEM_PSI=off still opened the trigger for writing")
    if polls: bad(f"RNI_MEM_PSI=off did not turn off the poll: {polls[0]}")
    if before or after or events: bad("a linux-psi event or purge with RNI_MEM_PSI=off and no capability")
    print(f"MEM_PSI off-nocap ok: armed=0, trigger never opened, no psi-poll, no purge under a hog that stalled {stall} us")
elif kind == "bad":
    if not re.fullmatch(r'0 trigger="some 0 2000000" step=write errno=22 \(Invalid argument\)', armed.group(1) + " " + armed.group(2)):
        bad(f"the refused trigger was not reported: {armed.group(0)}")
    print(f"MEM_PSI bad ok: {armed.group(0).split(': ', 1)[1]}")
PY
}

for arm in $ARMS; do
  case "$arm" in
    fire) run fire hog; check fire fire ;;
    control) run control none; check control control ;;
    off) run off hog RNI_MEM_PSI=off; check off off ;;
    bad) run bad none "RNI_MEM_PSI=some 0 2000000"; check bad bad ;;
    nocap) run nocap hog "LD_PRELOAD=$SHIM"; check nocap nocap ;;
    off-nocap) run off-nocap hog "LD_PRELOAD=$SHIM" RNI_MEM_PSI=off; check off-nocap off-nocap ;;
    *) fail "unknown arm $arm" ;;
  esac
done
echo "MEM_PSI_GATE_PASS arms=\"$ARMS\""
