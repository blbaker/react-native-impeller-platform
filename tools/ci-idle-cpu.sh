#!/usr/bin/env bash
# IDLE-CPU GATE (P12-01): an idle window must SLEEP, not busy-spin a core.
#
# Impeller's windowed loop repainted the retained SceneGraph EVERY frame
# regardless of change (RunWindowed's old `while(!shouldClose){ pollEvents();
# paintFrame(); }`). On an idle screen that pins a CPU core. --idle-skip makes a
# CLEAN frame (a) skip paintFrame() AND (b) block in glfwWaitEventsTimeout so
# the thread sleeps, while a damage wake (glfwPostEmptyEvent, fired by
# SceneGraph::bumpVersion from the JS thread's applyMutations / updateViewProps /
# text-input paths) shoves an empty event to wake it. This gate asserts BOTH
# halves:
#
#   A. IDLE CPU. After the app settles, %CPU over a 2s no-input window must sit
#      under a budget. This is the whole point and it is why the gate needs a
#      REAL display: under a headless/offscreen driver glfwSwapBuffers/present
#      never blocks, so the loop already busy-spins there and a %CPU number is
#      meaningless. No display => SKIP, loudly (mirrors ci-resize.sh's DISPLAY
#      requirement).
#
#   B. OFF-THREAD REPAINT PROMPTNESS. An idle window, then an OFF-THREAD scene
#      bump (--idle-offthread-after) must repaint WITHIN the wake latency, not
#      stall the full glfwWaitEventsTimeout budget. --idle-log prints slept_ms
#      per frame; the frame that observes the bump must have slept << budget.
#      This is the assertion M3 (never post the wake) fails; an input-driven
#      gate cannot see it, so it is written explicitly here.
#
# Mutants proven by tools/mutation-verify-idle-cpu.sh (runtime --idle-mutant,
# no source edit needed — the mutants are wired into the loop as flags):
#   M1 always-dirty           -> A fails (repaints every frame, CPU high)
#   M2 skip paint, keep poll  -> A fails (busy-spin: the swap/sleep-skip is the
#                                fix, not the paint-skip alone)
#   M3 never post the wake    -> B fails (off-thread bump stalls full budget)
#
# ⛔ MAC-RUNNABLE WITH NO TOOLCHAIN. This gate renders a COMMITTED prebuilt JS
# bundle with the staged engine binary and reads only stdout — no npm/metro. On
# the Mac (real Metal display) run: RNI_BIN=<darwin binary> bash tools/ci-idle-cpu.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The engine binary: RNI_BIN override (the Mac passes its darwin build) else the
# staged linux one, built on demand.
RNI_BIN="${RNI_BIN:-$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller}"
# A committed STATIC fixture bundle (no animation -> the scene truly goes idle).
BUNDLE="${IDLE_BUNDLE:-$ROOT/fixtures/eng-supersample-root/prebuilt/eng-supersample-root.bundle}"
APP_NAME="${IDLE_APP:-EngSupersampleRoot}"
BUDGET_CPU="${IDLE_CPU_BUDGET:-15}"   # percent of one core over the idle window
BUDGET_MS="${IDLE_BUDGET_MS:-200}"    # glfwWaitEventsTimeout bound
RUN_SEC="${IDLE_RUN_SEC:-4}"
# The mutant to run instead of HEAD (mutation-verify sets this). Empty = HEAD.
IDLE_MUTANT_FLAG=""
[ -n "${IDLE_MUTANT:-}" ] && IDLE_MUTANT_FLAG="--idle-mutant ${IDLE_MUTANT}"

fail() { echo "IDLE_CPU FAIL: $*" >&2; exit 1; }

# Build the linux engine on demand ONLY when using the staged default; a passed
# RNI_BIN (the Mac) is used as-is.
if [ "$RNI_BIN" = "$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller" ] && [ ! -x "$RNI_BIN" ]; then
  echo "== building engine =="
  export PATH="$HOME/.local/bin:$PATH"
  bash tools/engine-build.sh > /dev/null || fail "engine build failed"
fi
[ -x "$RNI_BIN" ] || fail "no engine at $RNI_BIN"
[ -f "$BUNDLE" ]  || fail "no bundle $BUNDLE"

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

# --- REAL DISPLAY REQUIRED (see header) -------------------------------------
# GLFW on Linux is X11 (WSLg). No SwapBuffers block off a real display, so a
# %CPU number would be a lie. Skip loudly, exactly like ci-resize.sh needs :0.
#
# Darwin is NOT X11: the GLFW window is a native Metal-backed NSWindow whose
# present blocks on vsync, so an idle window genuinely sleeps and %CPU IS
# measurable. There is no DISPLAY var and no /tmp/.X11-unix socket on macOS, so
# the X11 guard below would SKIP on the very platform that has the realest
# display we ship on. Gate the X11 requirement to Linux only.
unset SDL_VIDEODRIVER || true
if [ "$(uname -s)" != "Darwin" ]; then
  if [ -z "${DISPLAY:-}" ] && [ ! -S /tmp/.X11-unix/X0 ]; then
    echo "IDLE_CPU SKIP (no real display -- idle CPU is meaningless with no blocking"
    echo "  present; the loop busy-spins headless by construction. See this header.)"
    exit 0
  fi
  export DISPLAY="${DISPLAY:-:0}"
fi

# ==========================================================================
# A. IDLE CPU
# ==========================================================================
"$RNI_BIN" --window --probe-banner off \
  --bundle "$BUNDLE" --app-name "$APP_NAME" $IDLE_MUTANT_FLAG \
  --idle-skip --idle-run-sec "$RUN_SEC" --idle-budget-ms "$BUDGET_MS" --idle-log \
  --width 400 --height 400 > "$OUT/idle.log" 2>&1 &
PID=$!

# Settle, then sample /proc utime+stime jiffies across a 2s no-input window.
sleep 1.2
if ! [ -r /proc/$PID/stat ]; then
  echo "IDLE_CPU FAIL (engine exited before the CPU window; log:)"
  tail -20 "$OUT/idle.log"; wait $PID 2>/dev/null || true; exit 1
fi
read -r U1 S1 < <(awk '{print $14, $15}' /proc/$PID/stat)
T1=$(date +%s.%N)
sleep 2.0
read -r U2 S2 < <(awk '{print $14, $15}' /proc/$PID/stat 2>/dev/null || echo "$U1 $S1")
T2=$(date +%s.%N)
wait $PID 2>/dev/null || true

HZ=$(getconf CLK_TCK)
DJ=$(( (U2 + S2) - (U1 + S1) ))
DT=$(echo "$T2 - $T1" | bc -l)
PCT=$(echo "scale=1; 100.0 * ($DJ / $HZ) / $DT" | bc -l)

# The run must actually have skipped clean frames -- a run that painted every
# frame at a low count would read "cheap" without the skip ever engaging. Prove
# the mechanism ran: at least 3 clean-skip frames.
SLEPT=$(grep -c 'dirty=0 painted=0' "$OUT/idle.log" || true)
if [ "${SLEPT:-0}" -lt 3 ]; then
  echo "IDLE_CPU FAIL (idle-skip never engaged: only ${SLEPT:-0} clean-skip frames)"
  tail -20 "$OUT/idle.log"; exit 1
fi

echo "  idle window: cpu%=$PCT (budget ${BUDGET_CPU}%), clean-skip frames=$SLEPT"
if [ "$(echo "$PCT > $BUDGET_CPU" | bc -l)" = "1" ]; then
  echo "IDLE_CPU FAIL (idle CPU ${PCT}% exceeds ${BUDGET_CPU}% -- loop is spinning, not sleeping)"
  tail -8 "$OUT/idle.log"; exit 1
fi

# ==========================================================================
# B. OFF-THREAD REPAINT PROMPTNESS
# ==========================================================================
# Fire an off-thread scene bump at frame 6 with a generous budget; the frame
# that observes the new version must have slept far LESS than the budget (it was
# woken), and a repaint must follow. M3 (no wake) sleeps the whole budget.
WB_BUDGET=600
"$RNI_BIN" --window --probe-banner off \
  --bundle "$BUNDLE" --app-name "$APP_NAME" $IDLE_MUTANT_FLAG \
  --idle-skip --idle-run-sec 3 --idle-budget-ms "$WB_BUDGET" --idle-log \
  --idle-offthread-after 6 --width 400 --height 400 \
  > "$OUT/witness.log" 2>&1 || true

RESULT=$(python3 - "$OUT/witness.log" "$WB_BUDGET" <<'PY'
import sys, re
log, budget = sys.argv[1], int(sys.argv[2])
lines = open(log).read().splitlines()
fire = next((i for i, l in enumerate(lines) if 'offthread_fire' in l), None)
if fire is None:
    print("FAIL (off-thread bump never fired)"); sys.exit(0)
frames = []
for l in lines[fire:]:
    m = re.search(r'\[idle\] frame=(\d+) dirty=(\d) painted=(\d) slept_ms=(\d+)', l)
    if m:
        frames.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))))
if not frames:
    print("FAIL (no frame lines after the bump)"); sys.exit(0)
# The FIRST frame after the fire is the one whose sleep was (or wasn't) cut short.
_, _, _, first_slept = frames[0]
repainted = any(p == 1 for _, _, p, _ in frames[:4])
woke = first_slept < budget * 0.6
if not repainted:
    print("FAIL (off-thread bump produced no repaint within 4 frames)"); sys.exit(0)
if not woke:
    print("FAIL (off-thread bump stalled %dms of a %dms budget -- wake not posted)" % (first_slept, budget)); sys.exit(0)
print("OK (woken after %dms of a %dms budget, repainted)" % (first_slept, budget))
PY
)
echo "  off-thread witness: $RESULT"
case "$RESULT" in
  OK*) : ;;
  *) echo "IDLE_CPU FAIL (off-thread repaint witness: $RESULT)"; exit 1 ;;
esac

echo "IDLE_CPU PASS (idle ${PCT}% < ${BUDGET_CPU}%, off-thread repaint prompt)"
