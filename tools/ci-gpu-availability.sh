#!/usr/bin/env bash
# FP-31 gate: one GPU-availability switch (Flutter Shell::SetGpuAvailability).
# Model: shell/common/shell.cc SetGpuAvailability + FlutterEngine.mm
# flutterDidEnterBackground (setIsGpuDisabled:YES) and rasterizer.cc
# DrawToSurfaces (kGpuUnavailable: no draw, no present); ShellIOManager for the
# upload side.
#
# Fixture fixtures/fp31-gpu-availability: JS ticks every 100 ms for 25 ticks
# (tick -> the red channel of a centre box, tick*8) and mounts an image every 2nd
# tick, then goes idle. --gpu-availability-sequence 1000:off,6000:on flips the
# switch through the same handler the window-iconify callback uses (no window
# manager runs under Xvfb, so a real minimize cannot be driven there), which
# also sends RN AppState background/active to JS. RNI_TEST_GPU_AVAIL_PROBE=1
# reads the centre pixel of every frame before its present.
#
# The engine prints its call counters (records, draws, presents, uploads,
# snapshots) inside the switch's exclusive lock at each flip, so "zero calls
# while unavailable" is the difference between the two gpu_availability lines.
#
# ARMS: A threaded raster, B threaded + 150 ms raster delay so frames are queued
# when the switch flips, C --raster-thread off, D no images (the only damage is
# the box, so without the forced full repaint the restore frame would be a
# damage clip: images mount "untagged" damage, which is always full)
#   1. every counter equal at off and on; the window lasted >= 2 s; no gpu_probe
#      line inside it; frames/uploads WERE requested meanwhile (skipped_frames and
#      skipped_uploads grew), so the zeros are not an idle fixture
#   2. JS kept running: >= 5 ticks and the AppState background event inside the
#      window; the last tick was logged before the restore (JS idle at restore)
#   3. restore: the first present after it is a full repaint (all arms), shows the LATEST
#      tick (red == last tick * 8, not the pre-off red), and lands within 2 vsyncs
#      (+ RNI_GPU_AVAIL_SLACK_MS raster slack, default 40) of the restore
#   4. images uploaded after the restore (uploads grew), none lost (arms with images)
# Node-free: committed bundle + RNI_BIN. Mutants: tools/mutation-verify-gpu-availability.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
. tools/lib/wait-for.sh
BUNDLE="$ROOT/fixtures/fp31-gpu-availability/prebuilt/fp31-gpu-availability.bundle"
fail() { echo "GPU_AVAILABILITY_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (Xvfb) or darwin only"
if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
else
  bash tools/engine-build.sh linux x64 > "${TMPDIR:-/tmp}/ci-gpu-availability-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-gpu-availability-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
python3 - "$WORK" <<'PY'
import random, struct, sys, zlib
def png(path, w, h, seed):
    r = random.Random(seed)
    raw = b"".join(b"\0" + bytes(r.randrange(256) for _ in range(w * 3)) for _ in range(h))
    def ch(t, b):
        c = struct.pack(">I", len(b)) + t + b
        return c + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + ch(b"IDAT", zlib.compress(raw, 1)) + ch(b"IEND", b""))
for i in range(10): png("%s/img-%d.png" % (sys.argv[1], i), 300, 300, i)
PY
OFF_MS="${GPU_AVAIL_OFF_MS:-1000}"; ON_MS="${GPU_AVAIL_ON_MS:-6000}"
COMMON=(--window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 --probe-banner off
        --app-name GpuAvailability --bundle "$BUNDLE"
        --gpu-availability-sequence "$OFF_MS:off,$ON_MS:on" --idle-run-sec 9)

check_log() {  # log tag raster_delay_ms images (the slack allows the injected raster delay)
  python3 - "$1" "$2" "$(( ${RNI_GPU_AVAIL_SLACK_MS:-40} + $3 ))" "$4" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read(); tag = sys.argv[2]; slack_ms = float(sys.argv[3]); images = int(sys.argv[4])
def bad(m): print("GPU_AVAILABILITY_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
KEYS = ("records", "draws", "presents", "uploads", "snapshots", "skipped_frames", "skipped_uploads")
av = re.findall(r"^rn-impeller: gpu_availability state=(\w+) reason=(\w+) t_us=(\d+) (.*)$", log, re.M)
if [a[0] for a in av] != ["unavailable", "available"]: bad("flips %s, wanted unavailable then available" % [a[0] for a in av])
def counters(s): return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", s)}
off, on = counters(av[0][3]), counters(av[1][3])
t_off, t_on = int(av[0][2]), int(av[1][2])
if (t_on - t_off) < 2_000_000: bad("unavailable window %.2f s < 2 s" % ((t_on - t_off) / 1e6))
for k in ("records", "draws", "presents", "uploads", "snapshots"):
    if on[k] != off[k]: bad("%s advanced %d -> %d while the GPU was unavailable" % (k, off[k], on[k]))
if on["skipped_frames"] <= off["skipped_frames"]: bad("no frame was requested while unavailable (fixture idle)")
if images and on["skipped_uploads"] <= off["skipped_uploads"]: bad("no upload was requested while unavailable (fixture cannot see an upload leak)")
lines = log.splitlines()
i_off = next(i for i, l in enumerate(lines) if "gpu_availability state=unavailable" in l)
i_on = next(i for i, l in enumerate(lines) if "gpu_availability state=available" in l)
inside = lines[i_off:i_on]
if any("gpu_probe" in l for l in inside): bad("a frame was read back / presented while unavailable")
ticks = [int(m.group(1)) for l in inside for m in [re.search(r"FP31 tick=(\d+)", l)] if m]
if len(ticks) < 5: bad("only %d JS ticks while unavailable: JS did not keep running" % len(ticks))
if not any("FP31 appstate=background" in l for l in inside): bad("JS never saw AppState background")
all_ticks = [int(m.group(1)) for m in re.finditer(r"FP31 tick=(\d+)", "\n".join(lines[:i_on]))]
if not all_ticks or all_ticks[-1] != 25:
    bad("JS was still ticking at the restore (last tick %s): widen GPU_AVAIL_ON_MS" % (all_ticks[-1:] or None))
if any("FP31 tick=" in l for l in lines[i_on:]): bad("a tick after the restore: the repaint would be hidden by JS damage")
pre = [l for l in lines[:i_off] if "gpu_probe" in l]
if not pre: bad("no frame before the switch")
pre_r = int(re.search(r" r=(\d+) ", pre[-1]).group(1))
post = [l for l in lines[i_on:] if "gpu_probe" in l]
if not post: bad("no frame after the restore (restore did not repaint)")
post_r = int(re.search(r" r=(\d+) ", post[0]).group(1))
if post_r != all_ticks[-1] * 8: bad("first frame after restore shows red %d, latest state is %d" % (post_r, all_ticks[-1] * 8))
if post_r == pre_r: bad("first frame after restore equals the pre-off frame (stale)")
rp = re.search(r"^rn-impeller: gpu_restore_present present=(\d+) full=(\d+) t_us=\d+ since_restore_us=(\d+)", log, re.M)
if not rp: bad("no gpu_restore_present line")
if rp.group(2) != "1": bad("restore frame was a damage-clipped partial repaint")
period_ms = 1000.0 / 60.0
lat = int(rp.group(3)) / 1000.0
if lat > 2 * period_ms + slack_ms: bad("first frame %.1f ms after restore > 2 vsyncs (%.1f) + %.0f ms slack" % (lat, 2 * period_ms, slack_ms))
summ = re.search(r"^rn-impeller: gpu_availability_summary flips=2 .*uploads=(\d+) ", log, re.M)
if images and (not summ or int(summ.group(1)) <= on["uploads"]): bad("no image uploaded after the restore")
print("%s: OK window=%.2fs ticks_inside=%d skipped_frames=%d skipped_uploads=%d counters_equal records=%d draws=%d "
      "presents=%d uploads=%d | restore: red %d->%d full=1 first_frame=%.1fms uploads_after=%d"
      % (tag, (t_on - t_off) / 1e6, len(ticks), on["skipped_frames"] - off["skipped_frames"],
         on["skipped_uploads"] - off["skipped_uploads"], on["records"], on["draws"], on["presents"],
         on["uploads"], pre_r, post_r, lat, int(summ.group(1)) - on["uploads"]))
PY
}

run_arm() {  # tag delay_ms images [extra args...]
  local tag="$1" delay="$2" images="$3"; shift 3
  local log="$WORK/$tag.log" rc=0
  echo "== $tag =="
  RNI_TEST_GPU_AVAIL_PROBE=1 RNI_TEST_RASTER_DELAY_MS="$delay" rni_xrun "$WORK/x$tag" timeout 120 "$BIN" "${COMMON[@]}" \
    --initial-url "fp31://run?dir=$WORK&ticks=25&intervalMs=100&images=$images" "$@" \
    > "$log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "$tag: exit $rc"; }
  grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  check_log "$log" "$tag" "$delay" "$images"
}

run_arm A 0 10
run_arm B 150 10
run_arm C 0 10 --raster-thread off
run_arm D 0 0
echo "GPU_AVAILABILITY_PASS"
