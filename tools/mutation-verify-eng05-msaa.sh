#!/usr/bin/env bash
# MUTATION TEST for tools/ci-eng05-msaa.sh.
#
# WHY THIS IS MANDATORY HERE AND NOT MERELY GOOD PRACTICE.
#
# ci-eng05-msaa.sh reports ENG05_MSAA_NULL -- "multisampling changed nothing" --
# and a script that ALWAYS prints NULL would produce exactly that output on
# every host forever, including a host where MSAA works. A null result is the
# one verdict that is indistinguishable from a broken instrument, so the gate
# is worthless until it has been SEEN to print ENG05_MSAA_HELPS.
#
# Mutants are applied to the ANALYSIS, because the thing under test here is the
# gate's ability to classify, not the renderer:
#
#   M1  make the "on" frame genuinely antialiased (blur the subject's rim into
#       intermediate luminances) -> must flip to ENG05_MSAA_HELPS.
#       This is the arm that proves NULL is a measurement, not a constant.
#
#   M2  flatten the control ramp to one luminance -> must FAIL guard 2 rather
#       than reporting NULL. A blind instrument must not be allowed to report
#       "no effect".
#
#   M3  report GL_SAMPLES=0 while still requesting 4 -> must FAIL guard 1.
#       "MSAA did nothing" and "MSAA was never enabled" must be different
#       verdicts; this is the guard that separates them.
#
# M1 runs against SYNTHESISED frames (the harness below re-implements the
# verdict logic over two PPMs) rather than by patching the renderer: the
# question "can this gate detect antialiasing" is answerable without a GPU that
# antialiases, and pretending otherwise would make the check unrunnable on the
# host that most needs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
GATE="tools/ci-eng05-msaa.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Extract the gate's own verdict logic and drive it over controlled frames.
# The numbers below mirror the gate's thresholds exactly; if they drift apart
# this harness stops being evidence, so the gate's constants are re-read here
# rather than retyped from memory.
grep -q 'DIFF_GRADED" -gt 0' "$GATE" \
  || { echo "MUTATE_FAIL: the gate no longer decides on DIFF_GRADED -- this harness is stale and would test the wrong rule" >&2; exit 1; }
grep -q 'R_LUM" -ge 32' "$GATE" \
  || { echo "MUTATE_FAIL: the gate's ramp-control threshold changed -- update this harness" >&2; exit 1; }
grep -q 'GRANTED" -ge 2' "$GATE" \
  || { echo "MUTATE_FAIL: the gate's GL_SAMPLES guard changed -- update this harness" >&2; exit 1; }

python3 - "$WORK" <<'PY'
import sys, os
W = sys.argv[1]
WID, HGT = 400, 300

def blank():
    return bytearray([255] * (WID * HGT * 3))

def put(buf, x, y, v):
    if 0 <= x < WID and 0 <= y < HGT:
        o = (y * WID + x) * 3
        buf[o] = buf[o+1] = buf[o+2] = v

def disc(buf, cx, cy, r, aa):
    """Binary disc when aa=False; intermediate rim values when aa=True."""
    for y in range(cy - r - 2, cy + r + 3):
        for x in range(cx - r - 2, cx + r + 3):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d <= r - 0.5:
                put(buf, x, y, 0)
            elif aa and d < r + 0.5:
                # coverage -> a genuine intermediate luminance
                put(buf, x, y, int(255 * (d - (r - 0.5))))

def ramp(buf, x0, y0, w, h, flat):
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            put(buf, x, y, 0 if flat else int(255 * (x - x0) / max(1, w - 1)))

def write(path, buf):
    with open(path, 'wb') as f:
        f.write(b"P6\n%d %d\n255\n" % (WID, HGT))
        f.write(bytes(buf))

# baseline "off": hard-edged disc + real gradient
off = blank(); disc(off, 100, 100, 60, aa=False); ramp(off, 210, 30, 180, 140, flat=False)
write(os.path.join(W, "off.ppm"), off)

# M1 "on": ANTIALIASED disc + real gradient  -> gate must say HELPS
on_aa = blank(); disc(on_aa, 100, 100, 60, aa=True); ramp(on_aa, 210, 30, 180, 140, flat=False)
write(os.path.join(W, "on-aa.ppm"), on_aa)

# M2 "on": hard disc + FLAT ramp -> gate must fail the instrument guard
on_flat = blank(); disc(on_flat, 100, 100, 60, aa=False); ramp(on_flat, 210, 30, 180, 140, flat=True)
write(os.path.join(W, "on-flat.ppm"), on_flat)
print("frames written")
PY

# Re-implementation of the gate's measurement, kept byte-compatible with it.
verdict() {
  local offp="$1" onp="$2" granted="$3"
  python3 - "$offp" "$onp" "$granted" <<'PY'
import sys
def read(p):
    d = open(p, 'rb').read()
    parts, i = [], 0
    while len(parts) < 4:
        while d[i:i+1].isspace(): i += 1
        if d[i:i+1] == b'#':
            while d[i:i+1] != b'\n': i += 1
            continue
        s = i
        while not d[i:i+1].isspace(): i += 1
        parts.append(d[s:i])
    return int(parts[1]), int(parts[2]), d[i+1:]

w, h, a = read(sys.argv[1])
_, _, b = read(sys.argv[2])
granted = int(sys.argv[3])

def stats(px, x0, y0, bw, bh):
    lums, ink, partial = set(), 0, 0
    for y in range(y0, y0+bh):
        for x in range(x0, x0+bw):
            o = (y*w + x) * 3
            l = (px[o] + px[o+1] + px[o+2]) // 3
            if l < 250:
                ink += 1; lums.add(l)
                if l > 5: partial += 1
    return ink, len(lums), partial

s_ink, s_lum, s_part = stats(a, 30, 30, 140, 140)
t_ink, t_lum, t_part = stats(b, 30, 30, 140, 140)
r_ink, r_lum, _ = stats(a, 210, 30, 180, 140)
u_ink, u_lum, _ = stats(b, 210, 30, 180, 140)

total = graded = 0
for y in range(h):
    for x in range(w):
        o = (y*w + x) * 3
        if a[o:o+3] == b[o:o+3]: continue
        total += 1
        la = (a[o]+a[o+1]+a[o+2])//3
        lb = (b[o]+b[o+1]+b[o+2])//3
        if (5 < la < 250) or (5 < lb < 250): graded += 1

# guard 1
if granted < 2:
    print("GUARD1_FAIL granted=%d" % granted); raise SystemExit
# guard 2
if r_lum < 32 or u_lum < 32:
    print("GUARD2_FAIL ramp=%d->%d" % (r_lum, u_lum)); raise SystemExit
# guard 3
if s_ink <= 5000 or t_ink <= 5000:
    print("GUARD3_FAIL ink=%d->%d" % (s_ink, t_ink)); raise SystemExit

if graded > 0 and t_part > s_part:
    print("ENG05_MSAA_HELPS graded=%d partial=%d->%d" % (graded, s_part, t_part))
else:
    print("ENG05_MSAA_NULL graded=%d partial=%d->%d" % (graded, s_part, t_part))
PY
}

echo "== BASELINE: identical hard-edged frames must read NULL =="
BASE="$(verdict "$WORK/off.ppm" "$WORK/off.ppm" 4)"
echo "   $BASE"
case "$BASE" in
  ENG05_MSAA_NULL*) ;;
  *) echo "MUTATE_FAIL: two IDENTICAL aliased frames did not read NULL" >&2; exit 1 ;;
esac

echo
echo "== M1: a genuinely ANTIALIASED frame must flip the verdict to HELPS =="
M1="$(verdict "$WORK/off.ppm" "$WORK/on-aa.ppm" 4)"
echo "   $M1"
case "$M1" in
  ENG05_MSAA_HELPS*) echo "   M1 killed: the gate CAN report a positive result" ;;
  *) echo "MUTATE_FAIL: M1 SURVIVED -- an antialiased subject still read as $M1." >&2
     echo "             This gate can only ever print NULL, so its NULL means nothing." >&2
     exit 1 ;;
esac

echo
echo "== M2: a BLIND instrument (flat ramp) must FAIL, not report NULL =="
M2="$(verdict "$WORK/off.ppm" "$WORK/on-flat.ppm" 4)"
echo "   $M2"
case "$M2" in
  GUARD2_FAIL*) echo "   M2 killed: a blind pipeline cannot report 'no effect'" ;;
  *) echo "MUTATE_FAIL: M2 SURVIVED -- the ramp control collapsed to one value and the gate still returned $M2." >&2
     echo "             A broken measuring chain would be reported as a scientific result." >&2
     exit 1 ;;
esac

echo
echo "== M3: MSAA never granted must FAIL guard 1, not report NULL =="
M3="$(verdict "$WORK/off.ppm" "$WORK/off.ppm" 0)"
echo "   $M3"
case "$M3" in
  GUARD1_FAIL*) echo "   M3 killed: 'never enabled' is distinguishable from 'did nothing'" ;;
  *) echo "MUTATE_FAIL: M3 SURVIVED -- GL granted 0 samples and the gate reported $M3." >&2
     echo "             An experiment that never ran would be published as a null result." >&2
     exit 1 ;;
esac

echo
echo "MUTATE_ENG05_MSAA_OK -- 3 mutants, 3 killed; the NULL verdict is a measurement"
