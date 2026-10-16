#!/usr/bin/env bash
# FP-42 gate: external textures (Flutter TextureRegistry + TextureLayer).
# Model: flutter common/graphics/texture.cc, flow/layers/texture_layer.cc,
# shell/platform/embedder/embedder_external_texture_gl.cc (MarkNewFrameAvailable
# drops the cached image, Paint resolves the latest one).
#
# Fixture fixtures/fp42-external-texture: JS registers a native test producer
# (64x64, 30 fps, frame k: top-left quadrant blue, the rest R=(k%32)*8,
# G=(k/32%32)*8) through the ImpellerTextureRegistry TurboModule and mounts
# <ImpellerTextureView textureId> under clip (overflow hidden cuts its bottom
# 40 px) + rotate(90deg) + opacity 0.6 on white; unregisters it after
# UNREG_MS, the view stays mounted. RNI_TEST_EXT_TEXTURE_PROBE reads 9 points of
# every present before it is shown, with what RECORD drew (id:seq:marks).
#
# The producer stops after 75 frames, ~0.5 s before the unregister.
# Per present while registered (every arm):
#   1. right frame: the 5 data points decode to k == the seq RECORD drew, and
#      seq >= marks (the frame resolved is the latest one marked available)
#   2. mutators: the blue marker is at the top-RIGHT quadrant (rotated), the data
#      quadrants are blended at 0.6 over white (B == 102), the two points inside
#      the view's box but outside the clip and one outside it are white
#   3. no tearing: all 5 data points (top and bottom halves) carry ONE k
#   4. animated: seq never goes back; distinct seqs shown >= 60% (C: 40%) of the
#      frames the producer made (a stale texture shows one); the last one shown is 75
# After unregister: a present follows it (the unregister wakes a frame), from
# then on every present draws nothing (seq 0) and all 9 points are white, the
# producer stopped, `external_textures ... live=0`.
# ARMS: A threaded raster + partial repaint + RNI_TEST_PARTIAL_VERIFY,
#       B --raster-thread off, C threaded + 45 ms raster delay (frames queue at
#       depth 2, the producer outruns the presents).
# Node-free: committed bundle + staged binary (RNI_BIN overrides). Never rebuilds.
# Mutants: tools/mutation-verify-external-texture.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/own-procs.sh
BUNDLE="$ROOT/fixtures/fp42-external-texture/prebuilt/fp42-external-texture.bundle"
fail() { echo "EXTERNAL_TEXTURE_FAIL: $*" >&2; exit 1; }
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"
. tools/lib/host-window.sh
[ "$(rni_host)" != other ] || fail "linux (Xvfb) or darwin only"
BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
[ -x "$BIN" ] || fail "no engine binary at $BIN (run tools/engine-build.sh or set RNI_BIN)"
echo "engine: $BIN ($(shasum -a 256 "$BIN" | cut -c1-12)) host=$(rni_host)"

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# The producer stops after FRAMES (2.5 s at 30 fps), ~500 ms before the
# unregister: nothing but the unregister itself can wake the frame after it.
FRAMES="${EXT_TEXTURE_FRAMES:-75}"
UNREG_MS="${EXT_TEXTURE_UNREG_MS:-3017}"
# data TL, marker TR, data BL, data BR, clipped x2, outside, data TL corner, data BR corner
POINTS="100,80;180,80;100,140;180,140;100,185;180,185;30,30;70,50;210,150"
COMMON=(--window --scale 1 --width 400 --height 300 --supersample-rnsvg 0 --probe-banner off
        --app-name ExternalTexture --bundle "$BUNDLE"
        --initial-url "fp42://run?fps=30&frames=$FRAMES&unregisterMs=$UNREG_MS" --idle-run-sec 5)

check_log() {  # log tag min_shown_ratio raster_delay_ms
  python3 - "$1" "$2" "$3" "$(( ${RNI_EXT_TEXTURE_SLACK_MS:-40} + 3 * $4 ))" "$FRAMES" <<'PY' || exit 1
import re, sys
log = open(sys.argv[1], errors="replace").read(); tag = sys.argv[2]; min_ratio = float(sys.argv[3]); slack_ms = float(sys.argv[4]); frames = int(sys.argv[5])
def bad(m): print("EXTERNAL_TEXTURE_FAIL: %s: %s" % (tag, m), file=sys.stderr); sys.exit(1)
reg = re.findall(r"^rn-impeller: ext_texture_register id=(\d+) t_us=(\d+)", log, re.M)
unreg = re.findall(r"^rn-impeller: ext_texture_unregister id=(\d+) t_us=(\d+)", log, re.M)
if len(reg) != 1 or len(unreg) != 1: bad("register/unregister lines %d/%d, wanted 1/1" % (len(reg), len(unreg)))
tid, t_reg, t_unreg = reg[0][0], int(reg[0][1]), int(unreg[0][1])
prod = [(int(s), int(t)) for s, t in re.findall(r"^rn-impeller: ext_texture_produce id=%s seq=(\d+) t_us=(\d+)" % tid, log, re.M)]
if [s for s, t in prod] != list(range(1, frames + 1)): bad("the producer made seqs %s.., wanted 1..%d" % ([s for s, t in prod][:5], frames))
if prod[-1][1] > t_unreg - 300_000: bad("the producer was still running 300 ms before unregister")
late = [s for s, t in prod if t > t_unreg + 50_000]
if late: bad("the producer kept running after unregister (seq %d)" % late[0])
fps = (len(prod) - 1) / max(1e-6, (prod[-1][1] - prod[0][1]) / 1e6)
if not 24 <= fps <= 36: bad("producer ran at %.1f fps, wanted ~30" % fps)
summ = re.search(r"^rn-impeller: external_textures registered=1 unregistered=1 live=0 ", log, re.M)
if not summ: bad("no `external_textures registered=1 unregistered=1 live=0` line")
pres = []
for m in re.finditer(r"^rn-impeller: ext_probe present=(\d+) frame=(\d+) t_us=(\d+) drawn=(\S+) px=(\S+)$", log, re.M):
    pts = [tuple(int(v) for v in p.split(",")) for p in m.group(5).split(";")]
    if len(pts) != 9: bad("probe line with %d points" % len(pts))
    drawn = [d.split(":") for d in m.group(4).split(",")] if m.group(4) != "-" else []
    drawn = [d for d in drawn if d[0] == tid]
    if len(drawn) != 1: bad("present %s drew texture %s %d times, wanted once" % (m.group(1), tid, len(drawn)))
    pres.append((int(m.group(1)), int(m.group(3)), int(drawn[0][1]), int(drawn[0][2]), pts))
if len(pres) < 20: bad("only %d probed presents" % len(pres))
WHITE = (255, 255, 255)
def near(a, b, tol): return all(abs(x - y) <= tol for x, y in zip(a, b))
def decode(p):  # data texel (R, G, 0) at 0.6 over white -> k
    if abs(p[2] - 102) > 4: return None
    r, g = (p[0] - 102) / 0.6 / 8, (p[1] - 102) / 0.6 / 8
    ri, gi = round(r), round(g)
    if abs(r - ri) > 0.35 or abs(g - gi) > 0.35 or not (0 <= ri < 32 and 0 <= gi < 32): return None
    return gi * 32 + ri
DATA = (0, 2, 3, 7, 8)
shown, last_seq, first_off = [], 0, None
for n, t, seq, marks, pts in pres:
    if seq == 0:
        if first_off is None: first_off, t_off = n, t
        for i, p in enumerate(pts):
            if not near(p, WHITE, 3): bad("present %d draws nothing but point %d is %s, wanted white" % (n, i, p))
        continue
    if first_off is not None: bad("present %d draws seq %d after an empty present %d" % (n, seq, first_off))
    if t > t_unreg + 200_000: bad("present %d still draws seq %d 200 ms after unregister" % (n, seq))
    if seq < marks: bad("present %d drew seq %d but %d frames were marked available (stale frame)" % (n, seq, marks))
    if seq < last_seq: bad("present %d went back from seq %d to %d" % (n, last_seq, seq))
    last_seq = seq
    if pts[0][2] > 200 and pts[1][2] < 200:
        bad("present %d: the blue marker is top-LEFT %s, wanted top-right (rotate not applied)" % (n, pts[0]))
    if near(pts[1], (0, 0, 255), 12):
        bad("present %d: marker %s is opaque, wanted 0.6 over white (opacity not applied)" % (n, pts[1]))
    if not near(pts[1], (102, 102, 255), 4):
        bad("present %d: top-right point %s is not the blue marker at 0.6 (rotate/opacity not applied)" % (n, pts[1]))
    for i in (4, 5, 6):
        if not near(pts[i], WHITE, 3): bad("present %d: point %d %s should be white (clip not applied)" % (n, i, pts[i]))
    ks = [decode(pts[i]) for i in DATA]
    if None in ks: bad("present %d: data points %s do not decode as frames at opacity 0.6 (mutators not applied)" % (n, [pts[i] for i in DATA]))
    if len(set(ks)) != 1: bad("present %d: torn frame, data points show frames %s" % (n, ks))
    if ks[0] != seq % 1024: bad("present %d shows frame %d, RECORD drew seq %d (wrong frame)" % (n, ks[0], seq))
    shown.append(seq)
if first_off is None: bad("no present after unregister (unregister did not repaint)")
# shell.cc: unregister/mark post to the raster thread and schedule a frame (C: up
# to 2 queued frames + its own carry the injected raster delay); the
# idle loop's own heartbeat must not be what shows it.
off_ms = (t_off - t_unreg) / 1000.0
if off_ms > 2 * 1000.0 / 60 + slack_ms:
    bad("first present after unregister %.1f ms later > 2 vsyncs + %.0f ms (unregister did not repaint)" % (off_ms, slack_ms))
if not shown: bad("no present drew the texture")
if shown[-1] != frames: bad("the last frame shown is seq %d, the producer's last is %d (stale frame)" % (shown[-1], frames))
made = [s for s, tp in prod if t_reg + 300_000 <= tp <= t_unreg - 100_000]
distinct = len(set(s for s in shown if s in set(made)))
if distinct < min_ratio * len(made): bad("only %d distinct frames shown of %d produced (stale texture)" % (distinct, len(made)))
pv = re.search(r"^rn-impeller: partial_verify frames=(\d+) mismatched_frames=(\d+)", log, re.M)
if pv and int(pv.group(2)) != 0: bad("partial repaint differs from a full repaint in %s frames" % pv.group(2))
print("%s: OK presents=%d drawn=%d distinct=%d/%d produced fps=%.1f last_seq=%d off_from_present=%d off_after=%.1fms%s"
      % (tag, len(pres), len(shown), distinct, len(made), fps, last_seq, first_off, off_ms,
         (" partial_verify=%s/0" % pv.group(1)) if pv else ""))
PY
}

run_arm() {  # tag delay_ms min_shown_ratio [extra args...]; ARM_ENV=VAR=value adds one env var
  local tag="$1" delay="$2" ratio="$3"; shift 3
  local log="$WORK/$tag.log" rc=0
  echo "== $tag =="
  (
    export RNI_EXT_TEXTURE_LOG=1 RNI_TEST_EXT_TEXTURE_PROBE="$POINTS" RNI_TEST_RASTER_DELAY_MS="$delay"
    [ -z "${ARM_ENV:-}" ] || export "${ARM_ENV?}"
    rni_xrun "$WORK/x$tag" timeout 120 "$BIN" "${COMMON[@]}" "$@"
  ) > "$log" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { tail -15 "$log" >&2; fail "$tag: exit $rc"; }
  grep -q '^RN_IMPELLER_WINDOW_OK' "$log" || fail "$tag: no RN_IMPELLER_WINDOW_OK"
  grep -q 'FP42 registered id=' "$log" || fail "$tag: JS never registered the producer"
  check_log "$log" "$tag" "$ratio" "$delay"
}

# C presents ~22 frames/s against a 30 fps producer, so ~74% is its ceiling.
ARM_ENV="RNI_TEST_PARTIAL_VERIFY=1" run_arm A 0 0.6
run_arm B 0 0.6 --raster-thread off
run_arm C 45 0.4
echo "EXTERNAL_TEXTURE_PASS"
