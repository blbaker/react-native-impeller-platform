#!/usr/bin/env bash
# Runs INSIDE the arm64 test container (rni-arm64-tools:bookworm). Starts a
# headless Weston with kiosk-shell (the shell the board image runs) and the
# rni-touch-inject module, runs the engine as a Wayland client, and plays a
# touch script into the compositor while it runs.
#
#   wayland-session.sh OUTDIR WIDTH HEIGHT "TOUCH_SCRIPT" -- <engine> <args...>
#
# TOUCH_SCRIPT: ';'-separated "<ms after the engine's first present>:<fifo line>",
#   e.g. "2000:down 300 50;2150:up". The clock starts when the engine prints
#   `first_present_ms=` (under qemu, startup time is meaningless as an anchor).
# Writes OUTDIR/weston.log, OUTDIR/touch.log and OUTDIR/engine.out (the
# engine's merged output, also echoed to stdout); exit code is the engine's.
#
# Window-system selection knobs (the S arms of ci-arm64-wayland-touch.sh):
#   RNI_SESSION_X11=1            also run Xvfb and export DISPLAY to the engine
#                                (default: DISPLAY unset, as on the board)
#   RNI_SESSION_DEFAULT_SOCKET=1 Weston listens on wayland-0 and WAYLAND_DISPLAY
#                                is UNSET, so the engine reaches it only through
#                                libwayland's default socket (the WSLg layout)
#   RNI_SESSION_TYPE=<t>         export XDG_SESSION_TYPE=<t> to the engine
# No-seat knobs (the NS arm):
#   RNI_SESSION_NO_SEAT=1        Weston WITHOUT rni-touch-inject: no input module,
#                                so no wl_seat global (a kiosk Weston with
#                                require-input=false and nothing plugged in).
#                                TOUCH_SCRIPT must be empty.
#   RNI_SESSION_TERM_AFTER_MS=N  SIGTERM the engine N ms after its first present
#                                (run it with --quit-on-term); logged to touch.log
set -uo pipefail
OUT="$1"; W="$2"; H="$3"; SCRIPT="$4"; shift 4
[ "${1:-}" = "--" ] && shift
mkdir -p "$OUT"
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/rni-xdg.XXXXXX)"; chmod 700 "$XDG_RUNTIME_DIR"
export RNI_TOUCH_FIFO="$XDG_RUNTIME_DIR/rni-touch.fifo"
SOCK=wayland-rni; [ "${RNI_SESSION_DEFAULT_SOCKET:-0}" = 1 ] && SOCK=wayland-0
NOSEAT="${RNI_SESSION_NO_SEAT:-0}"
MODS=(--modules=/opt/rni-tools/rni-touch-inject.so)
[ "$NOSEAT" = 1 ] && MODS=()
weston --backend=headless-backend.so --shell=kiosk-shell.so --width="$W" --height="$H" \
  ${MODS[@]+"${MODS[@]}"} --socket="$SOCK" --idle-time=0 \
  > "$OUT/weston.log" 2>&1 &
WPID=$!
up() { [ -S "$XDG_RUNTIME_DIR/$SOCK" ] && { [ "$NOSEAT" = 1 ] || [ -p "$RNI_TOUCH_FIFO" ]; }; }
for _ in $(seq 1 300); do
  up && break
  sleep 0.1
done
if ! up; then
  echo "wayland-session: weston did not come up" >&2; tail -20 "$OUT/weston.log" >&2; kill $WPID 2>/dev/null; exit 90
fi
export WAYLAND_DISPLAY="$SOCK"
[ "${RNI_SESSION_DEFAULT_SOCKET:-0}" = 1 ] && unset WAYLAND_DISPLAY
unset DISPLAY
XPID=
if [ "${RNI_SESSION_X11:-0}" = 1 ]; then
  Xvfb :77 -screen 0 "${W}x${H}x24" -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
  XPID=$!
  for _ in $(seq 1 100); do [ -S /tmp/.X11-unix/X77 ] && break; sleep 0.1; done
  export DISPLAY=:77
fi
[ -n "${RNI_SESSION_TYPE:-}" ] && export XDG_SESSION_TYPE="$RNI_SESSION_TYPE"
: > "$OUT/engine.out"; : > "$OUT/touch.log"
(
  for _ in $(seq 1 3000); do grep -q 'first_present_ms=' "$OUT/engine.out" && break; sleep 0.1; done
  t0=$(date +%s%3N)
  echo "0ms first_present seen" >> "$OUT/touch.log"
  IFS=';' read -ra STEPS <<< "$SCRIPT"
  for s in "${STEPS[@]}"; do
    [ -z "$s" ] && continue
    at="${s%%:*}"; line="${s#*:}"
    now=$(( $(date +%s%3N) - t0 ))
    [ "$at" -gt "$now" ] && sleep "$(awk "BEGIN{print ($at-$now)/1000}")"
    echo "$line" > "$RNI_TOUCH_FIFO"
    echo "$(( $(date +%s%3N) - t0 ))ms $line" >> "$OUT/touch.log"
  done
  if [ -n "${RNI_SESSION_TERM_AFTER_MS:-}" ]; then
    now=$(( $(date +%s%3N) - t0 ))
    [ "$RNI_SESSION_TERM_AFTER_MS" -gt "$now" ] && sleep "$(awk "BEGIN{print ($RNI_SESSION_TERM_AFTER_MS-$now)/1000}")"
    # The pid the engine itself recorded (below): `pkill -x -P $$ rn-impeller`
    # matched nothing here, even on x64.
    EP="$(cat "$XDG_RUNTIME_DIR/engine.pid" 2>/dev/null)"
    if [ -n "$EP" ] && kill -TERM "$EP" 2>/dev/null; then
      echo "$(( $(date +%s%3N) - t0 ))ms TERM sent to pid $EP" >> "$OUT/touch.log"
    else
      echo "$(( $(date +%s%3N) - t0 ))ms TERM: engine pid '${EP}' not signalable" >> "$OUT/touch.log"
    fi
  fi
) &
TPID=$!
RUN=("$@")
# With the TERM knob the engine starts through a shell that records its pid and
# execs it (same pid, so the signal reaches the engine, under qemu too).
[ -n "${RNI_SESSION_TERM_AFTER_MS:-}" ] && RUN=(bash -c 'echo $$ > "$0"; exec "$@"' "$XDG_RUNTIME_DIR/engine.pid" "$@")
"${RUN[@]}" 2>&1 | tee -a "$OUT/engine.out"
RC=${PIPESTATUS[0]}
kill $TPID 2>/dev/null
[ -n "$XPID" ] && kill "$XPID" 2>/dev/null
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
rm -rf "$XDG_RUNTIME_DIR"
exit $RC
