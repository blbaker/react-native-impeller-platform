#!/usr/bin/env bash
# IDLE COMMIT PAINT GATE: a JS commit that replaces the whole screen after the
# windowed loop has gone idle must be ON SCREEN 300 ms later.
#
# Mac report against 0.6.0 (darwin windowed, default idle-skip): Jim's "Open
# ticket" committed the new screen (the cursor already hit-tested the new
# controls) but the window kept showing the old screen, at 0% CPU, until a
# resize. A resize asks for a frame directly; a commit asks through the scene
# graph's damage wake, so a commit whose frame never reaches the screen sits
# there until something else asks.
#
# Fixture fixtures/idle-commit-paint: screen 0, idle, then 4 whole-tree swaps
# (new key: every node deleted and re-created), 2 s after mount and then every
# 1.5 s, each a distinct full-window colour, each logged as ICP_SWAP.
#
# Instrument: RNI_TEST_PRESENTED_CAPTURE (host/PresentedCapture.h). The raster
# thread keeps a copy of every present; on a request file the engine dumps the
# LAST PRESENTED frame. It never requests a frame. --screenshot cannot be used:
# a pending --screenshot is a test hand and makes the loop paint every frame,
# which is exactly the repaint this gate must not hand the engine for free.
#
# Per swap n (ICP_SWAP n= ... rgb=R,G,B):
#   wait ICP_CAPTURE_DELAY_MS (300) -> request capture n -> the presented frame
#   must be >= 50% the new colour and < 5% the previous screen's colour.
# Also asserted: the loop was parked (a clean idle-skip iteration) between
# ICP_READY and the first swap, so swap 1 really lands on an idle loop; every
# capture served a real present (ok=1).
#
# The idle park is ICP_IDLE_BUDGET_MS (1000) on purpose: longer than the
# capture delay, so a commit that did not wake the loop cannot be rescued by
# the park timing out.
#
# ICP_LOSE_FRAMES=N (the arm that fails on 0.6.0's loop): each swap's own
# frame is lost after its request was consumed (see the MODE block below).
# tools/mutation-verify-idle-commit-paint.sh runs it against M4/M5/M6.
#
# Node-free: the bundle is committed. Mac (no npm):
#   RNI_BIN=<darwin rn-impeller> bash tools/ci-idle-commit-paint.sh
# Darwin uses --window unless ICP_WINDOW_FLAG=--window-hidden.
# Linux needs an X display (a private Xvfb is fine: DISPLAY=:95).
# On linux with ICP_X11_CROSSCHECK=1 each capture is also compared with an
# X11 grab of the window's screen area (proves the instrument = the screen).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RNI_BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
BUNDLE="${ICP_BUNDLE:-$ROOT/fixtures/idle-commit-paint/prebuilt/idle-commit-paint.bundle}"
APP_NAME="IdleCommitPaint"
DELAY_MS="${ICP_CAPTURE_DELAY_MS:-300}"
BUDGET_MS="${ICP_IDLE_BUDGET_MS:-1000}"
WINDOW_FLAG="${ICP_WINDOW_FLAG:---window}"
SWAPS=4

fail() { echo "IDLE_COMMIT_PAINT FAIL: $*" >&2; exit 1; }

[ -x "$RNI_BIN" ] || fail "no engine at $RNI_BIN"
[ -f "$BUNDLE" ] || fail "no bundle $BUNDLE"
command -v python3 >/dev/null || fail "python3 required"

if [ "$(uname -s)" != "Darwin" ]; then
  if [ -z "${DISPLAY:-}" ] && [ ! -S /tmp/.X11-unix/X0 ]; then
    echo "IDLE_COMMIT_PAINT SKIP (no X display; the idle-skip loop only runs windowed)"
    exit 0
  fi
  export DISPLAY="${DISPLAY:-:0}"
fi

OUT="$(mktemp -d "${TMPDIR:-/tmp}/icp.XXXXXX")"
[ -n "${KEEP_WORKDIR:-}" ] || trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/cap"

DIAG_FLAGS=""
if [ "${ICP_DIAG:-0}" = "1" ]; then  # where a lost frame went: requests, presents
  DIAG_FLAGS="--vsync-log"
  export RNI_TEST_RASTER_LOG=1
fi
# ICP_MODE: light (default) | heavy (~250-node screens) | click (one swap, made
# by a Pressable's onPress). The click is a REAL X11 pointer click (XTest) on
# linux when python-xlib is importable, after the loop has parked; elsewhere
# the synthetic --click-after-frames hook (weaker: that hook waits for JS idle
# inside the loop, so it cannot see a lost wake, only a lost frame).
MODE="${ICP_MODE:-light}"
MODE_FLAGS=""
XTEST_CLICK=0
# ICP_LOSE_FRAMES=N: the engine loses the first N frames drawn after >= 500 ms
# of raster idleness (RNI_TEST_LOSE_FRAME_AFTER_IDLE_MS), so each swap's own
# frame never reaches the screen, the way a nil Metal drawable or a failed
# draw loses it. Each lost frame is held ICP_LOSE_HOLD_MS (default 100 / N)
# first, as nextDrawable does before it gives up, so the loop is parked when
# the loss lands. The swap must STILL be on screen 300 ms later: the loop has
# to notice the lost frame and ask for another (host/UnpresentedDamage.h).
# 0.6.0's loop never asks again: tools/mutation-verify-idle-commit-paint.sh.
LOSE="${ICP_LOSE_FRAMES:-0}"
if [ "$LOSE" -gt 0 ]; then
  HOLD="${ICP_LOSE_HOLD_MS:-$((100 / LOSE))}"
  export RNI_TEST_LOSE_FRAME_AFTER_IDLE_MS="500:$LOSE:$HOLD"
fi
case "$MODE" in
  light) MODE_FLAGS="--initial-url icp://swap" ;;
  heavy) MODE_FLAGS="--initial-url icp://swap?heavy=1" ;;
  click)
    SWAPS=1
    MODE_FLAGS="--initial-url icp://swap?click=1"
    if [ "$(uname -s)" != "Darwin" ] && python3 -c 'import Xlib.ext.xtest' 2>/dev/null; then
      XTEST_CLICK=1
    else
      MODE_FLAGS="$MODE_FLAGS --click-after-frames 150:200,150"
    fi ;;
  *) fail "ICP_MODE must be light|heavy|click (got $MODE)" ;;
esac
echo "  mode=$MODE delay_ms=$DELAY_MS idle_budget_ms=$BUDGET_MS xtest_click=$XTEST_CLICK lose=${RNI_TEST_LOSE_FRAME_AFTER_IDLE_MS:-off}"

RNI_TEST_PRESENTED_CAPTURE="$OUT/cap" "$RNI_BIN" "$WINDOW_FLAG" --probe-banner off \
  --bundle "$BUNDLE" --app-name "$APP_NAME" ${ICP_EXTRA_FLAGS:-} $DIAG_FLAGS $MODE_FLAGS \
  --idle-skip --idle-budget-ms "$BUDGET_MS" --idle-log --idle-run-sec 30 \
  --width "${ICP_WIDTH:-400}" --height "${ICP_HEIGHT:-300}" > "$OUT/run.log" 2>&1 &
PID=$!

set +e
(ICP_XTEST="$XTEST_CLICK" python3 - "$OUT" "$PID" "$DELAY_MS" "$SWAPS" "${ICP_X11_CROSSCHECK:-0}" "$MODE" "$LOSE" <<'PY'
import os, re, sys, time
out, pid, delay_ms, swaps, x11 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "1"
mode = sys.argv[6]
lose = int(sys.argv[7])
log_path, cap = os.path.join(out, "run.log"), os.path.join(out, "cap")
SCREEN0 = (30, 79, 216)

def alive():
    try:
        os.kill(pid, 0); return True
    except OSError:
        return False

def read_ppm(path):
    data = open(path, "rb").read()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i+1].isspace(): i += 1
        j = i
        while not data[j:j+1].isspace(): j += 1
        parts.append(data[i:j]); i = j
    i += 1
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i:i + w * h * 3]

def frac(px, rgb, tol=14):
    n = len(px) // 3
    if n == 0: return 0.0
    hit = 0
    r0, g0, b0 = rgb
    for k in range(0, len(px), 3 * 7):  # every 7th pixel is plenty
        if abs(px[k]-r0) <= tol and abs(px[k+1]-g0) <= tol and abs(px[k+2]-b0) <= tol: hit += 1
    return hit / ((n + 6) // 7)

def x11_grab(rgb, prev):
    # The window's colours on the real X screen, for the instrument cross-check.
    from Xlib import display, X
    d = display.Display(); root = d.screen().root
    g = root.get_geometry()
    raw = root.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xffffffff).data
    px = bytearray()
    for k in range(0, len(raw), 4): px += bytes((raw[k+2], raw[k+1], raw[k]))
    return frac(px, rgb), frac(px, prev)

def xtest_click(x, y):
    # A REAL pointer click through the X server: GLFW's own button callback
    # runs, exactly as for a person's mouse. The window is the engine's mapped
    # top-level; (x, y) is window-relative.
    from Xlib import display, X
    from Xlib.ext import xtest
    d = display.Display(); root = d.screen().root
    best = None
    for w in root.query_tree().children:
        try:
            a = w.get_attributes(); g = w.get_geometry()
        except Exception:
            continue
        if a.map_state == X.IsViewable and g.width >= 200 and g.height >= 150:
            best = w
    if best is None: return False
    t = best.translate_coords(root, 0, 0)
    ax, ay = -t.x + x, -t.y + y
    xtest.fake_input(d, X.MotionNotify, x=ax, y=ay); d.sync(); time.sleep(0.05)
    xtest.fake_input(d, X.ButtonPress, 1); d.sync(); time.sleep(0.06)
    xtest.fake_input(d, X.ButtonRelease, 1); d.sync()
    return True

seen, pending, results, idle_before_first, ready = set(), [], [], False, False
xtest_mode, clicked, ready_at = (mode == "click" and os.environ.get("ICP_XTEST") == "1"), False, None
prev_rgb, deadline = SCREEN0, time.time() + 40
pos = 0
buf = ""
while time.time() < deadline:
    with open(log_path, "r", errors="replace") as f:
        f.seek(pos); chunk = f.read(); pos = f.tell()
    buf += chunk
    lines, buf = buf.split("\n")[:-1], buf.split("\n")[-1]
    for line in lines:
        if "ICP_READY" in line:
            ready = True; ready_at = time.time()
        m = re.search(r"\[idle\] frame=\d+ dirty=0 painted=0 slept_ms=(\d+)", line)
        if m and ready and not seen and int(m.group(1)) > 0: idle_before_first = True
        m = re.search(r"ICP_SWAP n=(\d+) screen=(\w+) rgb=(\d+),(\d+),(\d+)", line)
        if m and int(m.group(1)) not in seen:
            n = int(m.group(1)); seen.add(n)
            rgb = tuple(int(m.group(k)) for k in (3, 4, 5))
            pending.append((time.time() + delay_ms / 1000.0, n, m.group(2), rgb, prev_rgb))
            prev_rgb = rgb
    # The "Open ticket" click: 2 s after mount, once the loop has parked.
    if xtest_mode and not clicked and idle_before_first and time.time() - ready_at >= 2.0:
        clicked = True
        print("  xtest click: %s" % ("sent" if xtest_click(200, 150) else "NO WINDOW FOUND"))
    for item in list(pending):
        due, n, name, rgb, prev = item
        if time.time() < due: continue
        pending.remove(item)
        open(os.path.join(cap, "req-%d" % n), "w").close()
        x11r = x11_grab(rgb, prev) if x11 else None
        done = os.path.join(cap, "shot-%d.done" % n)
        t_req = time.time()
        while not os.path.exists(done) and time.time() - t_req < 5: time.sleep(0.005)
        shot = os.path.join(cap, "shot-%d.ppm" % n)
        if not os.path.exists(shot):
            results.append((n, name, False, "no capture served (no present yet?)")); continue
        w, h, px = read_ppm(shot)
        fn, fp = frac(px, rgb), frac(px, prev)
        ok = fn >= 0.5 and fp < 0.05
        note = "new=%.0f%% prev=%.0f%% (%dx%d)" % (100 * fn, 100 * fp, w, h)
        if x11r is not None:
            note += " x11: new=%.0f%% prev=%.0f%%" % (100 * x11r[0], 100 * x11r[1])
        results.append((n, name, ok, note))
    if len(results) == swaps or not alive(): break
    time.sleep(0.01)

for n, name, ok, note in sorted(results):
    print("  swap %d -> %-9s %s  %s" % (n, name, "on screen" if ok else "NOT ON SCREEN", note))
bad = [r for r in results if not r[2]]
# darwin + --vsync-log (ICP_DIAG=1): did Core Animation actually DISPLAY the
# present each capture served? presented_us=0 means the compositor dropped
# that drawable; the capture above reads the drawable BEFORE present, so only
# this line can see a compositor-level drop. VM runners report 0 for every
# present (no real display), so it is enforced only with ICP_REQUIRE_DISPLAYED=1.
text = open(log_path, errors="replace").read()
shown = {int(a): int(b) for a, b in re.findall(r"vsync_displayed n=(\d+) presented_us=(-?\d+)", text)}
served = {int(a): int(b) for a, b in re.findall(r"presented_capture k=(\d+) ok=1 present=(\d+)", text)}
undisplayed = []
# A swap back to an earlier colour (swap 4 returns to screen 0's) would pass a
# screen that never changed at all: each capture must also come from a NEWER
# present than the swap before it.
for n in sorted(served):
    if n - 1 in served and served[n] <= served[n - 1]:
        print("  swap %d: capture served present %d again (no present since swap %d)" % (n, served[n], n - 1))
        bad = [r for r in bad if r[0] != n] + [(n, "stale", False, "no new present")]
if shown:
    for n in sorted(served):
        p = served[n]
        state = "displayed" if shown.get(p, 0) > 0 else ("DROPPED by the compositor" if p in shown else "no report")
        print("  swap %d: present %d %s" % (n, p, state))
        if shown.get(p, 0) <= 0: undisplayed.append(n)
need_displayed = os.environ.get("ICP_REQUIRE_DISPLAYED") == "1"
# ICP_LOSE_FRAMES: prove the hook really lost each swap's frame (a gate whose
# loss never fired would pass on any engine), and show how the loop recovered.
lost = re.findall(r"test_lost_frame frame=(\d+) scene_rev=(\d+) idle_ms=(\d+) left=(\d+)", text)
bursts = sum(1 for f in lost if int(f[3]) == lose - 1)
retries = [int(m) for m in re.findall(r"unpresented_damage scene_rev=\d+ presented_rev=\d+ retry=\d+ since_lost_ms=(-?\d+)", text)]
# The raster thread wakes the parked loop when it loses a frame, so the re-ask
# follows the loss at once; without that wake it waits out the park budget.
max_reask = int(os.environ.get("ICP_MAX_REASK_MS", "100"))
if lose:
    print("  lost frames: %d in %d bursts of %d; loop re-asked %d times (since_lost_ms max %s)" % (
        len(lost), bursts, lose, len(retries), max(retries) if retries else "-"))
if not ready: print("VERDICT FAIL (ICP_READY never logged: the fixture did not mount)")
elif len(results) < swaps: print("VERDICT FAIL (only %d of %d swaps captured; engine alive=%d)" % (len(results), swaps, alive()))
elif not idle_before_first and mode != "click": print("VERDICT FAIL (the loop never parked before swap 1: not an idle-loop commit)")
elif bad: print("VERDICT FAIL (%d of %d whole-screen commits were not on screen %d ms later)" % (len(bad), swaps, delay_ms))
elif need_displayed and (not shown or undisplayed): print("VERDICT FAIL (presented but not displayed: swaps %s)" % (undisplayed or "all (no vsync_displayed lines; run with ICP_DIAG=1)"))
elif lose and bursts < swaps: print("VERDICT FAIL (the lose hook fired for %d of %d swaps: no lost frame was exercised)" % (bursts, swaps))
elif lose and (not retries or max(retries) > max_reask): print("VERDICT FAIL (the loop re-asked %s ms after a lost frame; bound %d ms: the loss did not wake it)" % (max(retries) if retries else "never", max_reask))
else: print("VERDICT PASS (%d of %d whole-screen commits on screen %d ms after an idle-loop commit%s)" % (
    swaps, swaps, delay_ms, ", each swap's own frame lost %d time(s)" % lose if lose else ""))
PY
) | tee "$OUT/verdict.txt"
PYRC=${PIPESTATUS[0]}
set -e
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
grep -E 'presented_capture|backend_select|\[idle\] enabled' "$OUT/run.log" | head -8 | sed 's/^/  /'
[ "$PYRC" -eq 0 ] || fail "watcher crashed (rc=$PYRC); log: $OUT/run.log"
if ! grep -q '^VERDICT PASS' "$OUT/verdict.txt" || [ "${ICP_DIAG:-0}" = "1" ]; then
  echo "  --- engine log (filtered, last 150) ---"
  grep -E 'ICP_|frame_discarded|frame_lost|test_lost_frame|unpresented|draw_failed|vsync_request|raster_present|vsync_displayed|painted=1|presented_capture|backend|metal_|FATAL|WARN' \
    "$OUT/run.log" | tail -150 | sed 's/^/  | /'
fi
grep -q '^VERDICT PASS' "$OUT/verdict.txt" || fail "$(grep '^VERDICT' "$OUT/verdict.txt" || echo 'no verdict')"
echo "IDLE_COMMIT_PAINT PASS"
exit 0
