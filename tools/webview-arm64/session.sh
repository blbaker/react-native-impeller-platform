#!/usr/bin/env bash
# Runs INSIDE rni-webview-arm64:sid (linux/arm64 under qemu-user). Starts a
# headless Weston with kiosk-shell (the board image's shell) and the
# rni-touch-inject module, runs the arm64 engine as its Wayland client, and
# sequences the web view gate on what the engine LOGS, never on a wall clock
# (qemu makes every startup time meaningless):
#
#   session.sh OUTDIR WIDTH HEIGHT -- <engine> <args...>
#
# Env (all optional; empty = that step is skipped):
#   READY_RE      ERE on the engine log: the page is loaded. Then SETTLE_S seconds,
#                 then SHOT_FILE is created (the engine's --screenshot-when-file).
#   FRAME_RE      ERE of one delivered web view frame (engine run with
#                 RNI_WEBVIEW_LOG=1): after READY, wait for a NEWER frame and then
#                 QUIET_S (default 3) seconds with none before SETTLE_S.
#   TOUCH_SCRIPT  ';'-separated "<ms after the screenshot line>:<fifo line>",
#                 e.g. "500:down 300 20;650:up" (global = window coords in kiosk).
#   DONE_RE       ERE on the engine log after the touches: then SIGTERM the
#                 engine (it runs with --quit-on-term) after DONE_GRACE_S.
#   TOUCH_MODULE  path of rni-touch-inject.so built for this image's libweston.
#   STEP_TIMEOUT_S  per wait (default 240). TERM_ON_TIMEOUT=1: a timed-out wait SIGTERMs
#                 the engine instead of leaving it to --idle-run-sec.
#   QUIET_S=0     skip the quiet wait (a playing video never goes quiet).
#   SERIES        N: the engine runs with --screenshot-series N. After capture k the
#                 engine removes SHOT_FILE; SERIES_GAP_S (default 2) seconds later
#                 it is created again, until N captures are logged.
#   MAPS_RE       ERE: once it shows up, every process mapping a libwidevinecdm is
#                 written to OUTDIR/maps-loaded.txt (pid ppid comm inode path), and
#                 again to maps-after.txt after the last capture; ps.txt = pid ppid comm.
# Writes OUTDIR/{weston.log,engine.out,touch.log}; exit code = the engine's.
set -uo pipefail
OUT="$1"; W="$2"; H="$3"; shift 3
[ "${1:-}" = "--" ] && shift
mkdir -p "$OUT"
: > "$OUT/engine.out"; : > "$OUT/touch.log"
T="${STEP_TIMEOUT_S:-240}"
note() { echo "$(date +%s%3N) $*" >> "$OUT/touch.log"; }
waitlog() {  # waitlog ERE -> 0 when it shows up in engine.out, 1 on timeout
  local i
  for i in $(seq 1 $((T * 5))); do grep -Eq "$1" "$OUT/engine.out" && return 0; sleep 0.2; done
  return 1
}
waitcount() {  # waitcount ERE N -> 0 once engine.out has N matching lines
  local i
  for i in $(seq 1 $((T * 5))); do [ "$(grep -Ec "$1" "$OUT/engine.out")" -ge "$2" ] && return 0; sleep 0.2; done
  return 1
}
procline() {  # procline PID -> "pid=P ppid=PP comm=C"
  echo "pid=$1 ppid=$(awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null) comm=$(cat "/proc/$1/comm" 2>/dev/null)"
}
dumpmaps() {  # dumpmaps FILE: every libwidevinecdm mapping in this container, plus ps.txt
  local m p
  for m in /proc/[0-9]*/maps; do
    p="${m#/proc/}"; p="${p%/maps}"
    grep -h 'libwidevinecdm' "$m" 2>/dev/null | awk -v pl="$(procline "$p")" '{print pl " inode=" $5 " path=" $6}'
  done | sort -u > "$1"
  for m in /proc/[0-9]*; do procline "${m#/proc/}"; done > "$OUT/ps.txt"
  note "maps $(basename "$1"): $(wc -l < "$1") line(s)"
}
export XDG_RUNTIME_DIR="$(mktemp -d /tmp/rni-xdg.XXXXXX)"; chmod 700 "$XDG_RUNTIME_DIR"
export RNI_TOUCH_FIFO="$XDG_RUNTIME_DIR/rni-touch.fifo"
weston --backend=headless --shell=kiosk --width="$W" --height="$H" \
  ${TOUCH_MODULE:+--modules="$TOUCH_MODULE"} --socket=wayland-rni --idle-time=0 \
  > "$OUT/weston.log" 2>&1 &
WPID=$!
for _ in $(seq 1 600); do
  [ -S "$XDG_RUNTIME_DIR/wayland-rni" ] && { [ -z "${TOUCH_MODULE:-}" ] || [ -p "$RNI_TOUCH_FIFO" ]; } && break
  sleep 0.1
done
if ! [ -S "$XDG_RUNTIME_DIR/wayland-rni" ]; then
  echo "session: weston did not come up" >&2; tail -20 "$OUT/weston.log" >&2; kill $WPID 2>/dev/null; exit 90
fi
export WAYLAND_DISPLAY=wayland-rni XDG_SESSION_TYPE=wayland
unset DISPLAY

"$@" >> "$OUT/engine.out" 2>&1 &
EPID=$!
note "engine pid=$EPID"
bail() {  # a sequencer step timed out: note it; TERM_ON_TIMEOUT=1 also ends the engine run
  note "$1"; [ "${TERM_ON_TIMEOUT:-0}" = 1 ] && kill -TERM "$EPID" 2>/dev/null; exit 0
}
(
  if [ -n "${READY_RE:-}" ]; then
    waitlog "$READY_RE" || bail "TIMEOUT ready /$READY_RE/"
    note "ready seen"
    if [ -n "${FRAME_RE:-}" ]; then
      # Under qemu the first painted frame lands SECONDS after the load event:
      # wait for a frame newer than READY, then for QUIET_S seconds with none.
      n0=$(grep -Ec "$FRAME_RE" "$OUT/engine.out"); n=$n0; i=0
      while [ "$n" -le "$n0" ] && [ $i -lt $((T * 5)) ]; do sleep 0.2; i=$((i + 1)); n=$(grep -Ec "$FRAME_RE" "$OUT/engine.out"); done
      [ "$n" -gt "$n0" ] || bail "TIMEOUT no frame after ready /$FRAME_RE/"
      while [ "${QUIET_S:-3}" != 0 ]; do sleep "${QUIET_S:-3}"; m=$(grep -Ec "$FRAME_RE" "$OUT/engine.out"); [ "$m" = "$n" ] && break; n=$m; done
      note "frames settled: $((n - n0)) after ready"
    fi
    if [ -n "${MAPS_RE:-}" ]; then
      waitlog "$MAPS_RE" && dumpmaps "$OUT/maps-loaded.txt" || note "TIMEOUT maps /$MAPS_RE/"
    fi
    sleep "${SETTLE_S:-3}"
    [ -n "${SHOT_FILE:-}" ] && { : > "$SHOT_FILE"; note "shot file created"; }
    if [ "${SERIES:-0}" -gt 1 ] && [ -n "${SHOT_FILE:-}" ]; then
      for k in $(seq 1 $((SERIES - 1))); do
        waitcount 'rn-impeller: screenshot=' "$k" || bail "TIMEOUT capture $k"
        sleep "${SERIES_GAP_S:-2}"; : > "$SHOT_FILE"; note "shot file created ($k)"
      done
      waitcount 'rn-impeller: screenshot=' "$SERIES" && note "series done" || note "TIMEOUT capture $SERIES"
      [ -n "${MAPS_RE:-}" ] && dumpmaps "$OUT/maps-after.txt"
    fi
  fi
  if [ -n "${TOUCH_SCRIPT:-}" ]; then
    waitlog 'rn-impeller: screenshot=' || bail "TIMEOUT screenshot line"
    t0=$(date +%s%3N); note "screenshot seen"
    IFS=';' read -ra STEPS <<< "$TOUCH_SCRIPT"
    for s in "${STEPS[@]}"; do
      [ -z "$s" ] && continue
      at="${s%%:*}"; line="${s#*:}"; now=$(( $(date +%s%3N) - t0 ))
      [ "$at" -gt "$now" ] && sleep "$(awk "BEGIN{print ($at-$now)/1000}")"
      echo "$line" > "$RNI_TOUCH_FIFO"; note "touch $line"
    done
  fi
  if [ -n "${DONE_RE:-}" ]; then
    waitlog "$DONE_RE" && note "done seen" || note "TIMEOUT done /$DONE_RE/"
    sleep "${DONE_GRACE_S:-3}"; kill -TERM "$EPID" 2>/dev/null; note "sent SIGTERM"
  fi
) &
SEQ=$!
wait "$EPID"; RC=$?
echo "ENGINE_RC=$RC" >> "$OUT/engine.out"
kill $SEQ 2>/dev/null; wait $SEQ 2>/dev/null
kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
rm -rf "$XDG_RUNTIME_DIR"
exit $RC
