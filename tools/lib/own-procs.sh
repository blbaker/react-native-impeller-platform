#!/usr/bin/env bash
# own-procs.sh — kill ONLY the rn-impeller processes THIS gate launched.
#
# ⛔ WHY THIS EXISTS
#   Every ci-*.sh / probe-*.sh gate used to clean up with
#       pgrep -x rn-impeller > /dev/null 2>&1 && pkill -x rn-impeller || true
#   which kills EVERY rn-impeller on the machine by name. On 2026-04 at 01:52 a
#   gate's cleanup killed Baker's LIVE HostApp window and an engine embedded in HostApp's
#   app suite (the suite died with "Terminated: 15"). A CI gate must never reach
#   outside its own process tree. NEVER pkill/pgrep by name.
#
# WHAT THIS DOES INSTEAD
#   1. rni_track "$!"   — record a PID the gate just backgrounded.
#   2. rni_kill_own     — kill (a) every tracked PID and its descendants, and
#                         (b) any rn-impeller process whose ancestry traces back
#                         to THIS gate's shell ($$). A process Baker started, or
#                         a sibling gate started, has different ancestry and is
#                         left completely alone.
#
#   The ancestry sweep is the safety net that also catches engines launched in
#   the FOREGROUND without a saved $! (they are still children of $$), and grand-
#   children (a wrapper that itself spawns the engine). It replaces the by-name
#   pkill with a by-lineage one: same reach INSIDE the gate, zero reach outside.
#
# PORTABILITY: Linux + macOS. Uses only `ps -o pid=,ppid=` and POSIX shell.
# No /proc dependency, no pkill, no pgrep-by-name.

# Space-separated list of PIDs the gate explicitly launched.
RNI_OWN_PIDS="${RNI_OWN_PIDS:-}"

# Record a PID (typically "$!") as owned by this gate.
rni_track() {
  local p
  for p in "$@"; do
    [ -n "$p" ] || continue
    case " $RNI_OWN_PIDS " in *" $p "*) ;; *) RNI_OWN_PIDS="$RNI_OWN_PIDS $p" ;; esac
  done
}

# Print, one per line, every PID whose PPID is $1 (direct children only).
_rni_children_of() {
  ps -o pid=,ppid= 2>/dev/null | awk -v parent="$1" '$2==parent {print $1}'
}

# Print, one per line, $1 and all its transitive descendants.
_rni_tree() {
  local root="$1" queue="$1" pid kids k
  printf '%s\n' "$root"
  # Breadth-first walk. Bounded by the process table, which is tiny here.
  while [ -n "$queue" ]; do
    local next=""
    for pid in $queue; do
      kids="$(_rni_children_of "$pid")"
      for k in $kids; do
        printf '%s\n' "$k"
        next="$next $k"
      done
    done
    queue="$next"
  done
}

# True if $1 is (or descends from) this gate's shell $$. Walks the PPID chain
# up to pid 1, stopping the moment it reaches $$.
_rni_is_descendant_of_gate() {
  local pid="$1" gate="$$" guard=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    [ "$pid" = "$gate" ] && return 0
    # ps -o ppid= for a single pid; strip whitespace.
    local ppid
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] || return 1
    pid="$ppid"
    guard=$((guard + 1)); [ "$guard" -gt 64 ] && return 1
  done
  return 1
}

# Every rn-impeller PID currently alive, one per line. By name here ONLY to
# BUILD THE CANDIDATE SET — every candidate is then filtered by lineage before
# any signal is sent, so nothing outside this gate's tree is ever touched.
_rni_all_impeller_pids() {
  ps -o pid=,comm= 2>/dev/null | awk '{
    c=$2; n=split(c,a,"/"); base=a[n];
    if (base=="rn-impeller") print $1
  }'
}

# Print, one per line, the PIDs this gate owns and still alive: tracked PIDs
# (+ their descendants) and any rn-impeller descended from $$. This is the
# lineage filter — a process Baker started, or a sibling gate started, has
# different ancestry and never appears here.
rni_own_pids() {
  local victims="" p pid

  # (a) explicitly tracked PIDs and everything under them.
  for p in $RNI_OWN_PIDS; do
    for pid in $(_rni_tree "$p"); do victims="$victims $pid"; done
  done

  # (b) any rn-impeller whose lineage reaches this gate's shell.
  for pid in $(_rni_all_impeller_pids); do
    if _rni_is_descendant_of_gate "$pid"; then victims="$victims $pid"; fi
  done

  # Dedupe, drop the gate itself, pid<=1, and anything already dead.
  local uniq="" seen="" v
  for v in $victims; do
    [ "$v" = "$$" ] && continue
    [ "$v" -gt 1 ] 2>/dev/null || continue
    kill -0 "$v" 2>/dev/null || continue
    case " $seen " in *" $v "*) ;; *) seen="$seen $v"; uniq="$uniq $v" ;; esac
  done
  for v in $uniq; do printf '%s\n' "$v"; done
}

# True (exit 0) iff this gate still owns a live rn-impeller. Use this in an
# orphan-DETECTION check instead of `pgrep -x rn-impeller`, which would flag a
# rn-impeller Baker (or a sibling gate) is running as an orphan of THIS gate.
rni_have_own() {
  [ -n "$(rni_own_pids)" ]
}

# Kill only the PIDs this gate owns: tracked PIDs (+ their descendants) and any
# rn-impeller descended from $$. Signal is TERM, then a short grace, then KILL.
rni_kill_own() {
  local uniq v i
  uniq="$(rni_own_pids | tr '\n' ' ')"
  [ -n "$uniq" ] || return 0
  kill -TERM $uniq 2>/dev/null || true
  # Give them a moment, then hard-kill any that ignored TERM.
  for i in 1 2 3 4 5; do
    local alive=""
    for v in $uniq; do kill -0 "$v" 2>/dev/null && alive="$alive $v"; done
    [ -n "$alive" ] || return 0
    sleep 0.2
  done
  kill -KILL $uniq 2>/dev/null || true
  return 0
}
