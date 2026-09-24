#!/usr/bin/env bash
# portable-timeout.sh — a `timeout` that works even where GNU `timeout` is absent.
#
# ⛔ WHY THIS EXISTS
#   Gates call `timeout N cmd ...` to bound a run. GNU coreutils `timeout` ships
#   on Linux but NOT on stock macOS (it is `gtimeout`, only if coreutils is
#   brew-installed). On an M1/M2 Mac a bare `timeout 500 ...` dies with
#   "timeout: command not found", the gate exits nonzero, and a green suite is
#   reported RED for a reason that has nothing to do with the engine.
#
# WHAT THIS DOES
#   Sourcing this file installs a `timeout` shell FUNCTION that dispatches, in
#   order, to the first available mechanism:
#       1. a real `timeout`  binary on PATH   (Linux, or coreutils on mac)
#       2. a real `gtimeout` binary on PATH   (brew coreutils on mac)
#       3. perl's alarm()                      (present on every stock macOS)
#       4. a pure-shell background sleep+kill  (last resort, no perl)
#   Exit semantics mirror GNU timeout: the inner command's exit code is passed
#   through on completion, and 124 is returned when the command is killed for
#   overrunning its DURATION.
#
#   The function resolves the real binaries with `type -P`, which searches only
#   PATH executables and IGNORES this same-named function — so there is no
#   recursion and PATH order is honoured.
#
# USAGE (in a gate)
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/portable-timeout.sh"
#   timeout 500 bash tools/ci-stroke.sh
#
# PORTABILITY: Linux + macOS. bash (uses `type -P`, `local`). DURATION is a
# whole number of seconds, optionally with a trailing `s` (e.g. 500 or 500s) —
# the only forms the gates use.

# --- perl alarm() backend -----------------------------------------------------
_pt_run_perl() {
  local dur="${1%s}"; shift
  perl - "$dur" "$@" <<'PERL'
    my $dur = shift;
    my $pid = fork();
    exit 127 unless defined $pid;          # fork failed
    if ($pid == 0) { exec @ARGV; exit 127; }   # child: become the command
    local $SIG{ALRM} = sub {
      kill('TERM', $pid);
      select(undef, undef, undef, 1.0);    # 1s grace
      kill('KILL', $pid);
      exit 124;                            # GNU timeout's "timed out" code
    };
    alarm $dur;
    waitpid($pid, 0);
    my $st = $?;
    alarm 0;
    # Preserve the child's real disposition: signalled -> 128+sig, else exit code.
    exit( ($st & 127) ? 128 + ($st & 127) : ($st >> 8) );
PERL
}

# --- pure-shell background sleep+kill backend (no perl) -----------------------
_pt_run_bg() {
  local dur="${1%s}"; shift
  local marker; marker="$(mktemp)"; rm -f "$marker"   # use path as a flag, unlinked
  "$@" &
  local cmdpid=$!
  (
    sleep "$dur"
    kill -0 "$cmdpid" 2>/dev/null || exit 0            # already finished, no kill
    : > "$marker"                                       # record: WE timed it out
    kill -TERM "$cmdpid" 2>/dev/null
    sleep 1
    kill -KILL "$cmdpid" 2>/dev/null
  ) &
  local watcher=$!
  wait "$cmdpid" 2>/dev/null
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  if [ -e "$marker" ]; then rc=124; fi                  # overran -> canonical 124
  rm -f "$marker"
  return "$rc"
}

# --- the portable `timeout` ---------------------------------------------------
timeout() {
  local dur="$1"; shift
  local bin
  bin="$(type -P timeout 2>/dev/null)"  || bin=""
  [ -n "$bin" ] || bin="$(type -P gtimeout 2>/dev/null)" || bin=""
  if [ -n "$bin" ]; then
    "$bin" "$dur" "$@"
    return $?
  fi
  if type -P perl >/dev/null 2>&1; then
    _pt_run_perl "$dur" "$@"
    return $?
  fi
  _pt_run_bg "$dur" "$@"
  return $?
}
