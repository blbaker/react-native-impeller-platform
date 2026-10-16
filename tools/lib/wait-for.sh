#!/usr/bin/env bash
# wait-for.sh: frame-synchronous waits for windowed / XTest gates (FP-06).
#   . tools/lib/wait-for.sh
#   rni_time_scale              RNI_TIME_SCALE (default 1); ci-sanitize / ci-tsan export 4
#   rni_scaled SEC              SEC * scale, for a ceiling or an engine stall window
#   rni_wait_line LOG ERE SEC [PID]
#       return 0 as soon as LOG has a line matching ERE (the engine's own report that the
#       event happened); 1 after SEC * scale seconds; 2 at once if PID exits first (the engine
#       died, so waiting longer cannot help). Never a fixed sleep: the ceiling only bounds a
#       broken run, a healthy one returns on the event.
#   rni_wait_exit PID SEC       wait for PID; kill it and return 124 after SEC * scale seconds
rni_time_scale() { echo "${RNI_TIME_SCALE:-1}"; }
rni_scaled() { awk -v s="$1" -v k="$(rni_time_scale)" 'BEGIN { printf "%g\n", s * (k < 1 ? 1 : k) }'; }
rni_wait_line() {
  local log="$1" ere="$2" ceil pid="${4:-}" end
  ceil="$(rni_scaled "$3")"
  end="$(awk -v c="$ceil" -v n="$(date +%s.%N)" 'BEGIN { printf "%.3f\n", n + c }')"
  while :; do
    grep -qE -- "$ere" "$log" 2> /dev/null && return 0
    if [ -n "$pid" ] && ! kill -0 "$pid" 2> /dev/null; then
      grep -qE -- "$ere" "$log" 2> /dev/null && return 0
      return 2
    fi
    awk -v e="$end" -v n="$(date +%s.%N)" 'BEGIN { exit !(n >= e) }' && return 1
    sleep 0.05
  done
}
rni_wait_exit() {
  local pid="$1" ceil t=0 rc
  ceil="$(rni_scaled "$2")"
  while kill -0 "$pid" 2> /dev/null; do
    if awk -v t="$t" -v c="$ceil" 'BEGIN { exit !(t >= c) }'; then
      kill -KILL "$pid" 2> /dev/null; wait "$pid" 2> /dev/null; return 124
    fi
    sleep 0.1; t="$(awk -v t="$t" 'BEGIN { print t + 0.1 }')"
  done
  wait "$pid"; rc=$?
  return "$rc"
}
