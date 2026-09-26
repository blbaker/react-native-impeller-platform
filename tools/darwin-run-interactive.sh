#!/bin/zsh
# darwin-run-interactive.sh -- run a command OUTSIDE the caller's QoS clamp.
#
#   tools/darwin-run-interactive.sh <logfile> <timeout-sec> -- <cmd> [args...]
#
# WHY. The macOS tester runs inside a launchd job with no ProcessType
# (`launchctl print` -> "spawn type = daemon (3)"). launchd gives that class
# light resource limits: every child runs at scheduling priority 20 (the
# utility band, same as `taskpolicy -c utility`), and macOS coalesces its
# timer wakeups. A 16 ms JS setTimeout loop then fires every ~130 ms, so any
# frame-time number measured from that tree is the clamp, not the engine.
# Measured 2026-09-26, same binary + cadence fixture, windowed 1280x800:
#   ProcessType Interactive: pri 31, 21.0 ms/tick
#   ProcessType unset:       pri 20, 131.9 ms/tick
#
# HOW. Submits the command as a one-shot job in the user's gui launchd domain
# with ProcessType=Interactive, waits for it to exit (or the timeout), removes
# the job, and prints the log. No sudo; the job never outlives this script.
# Prints `interactive_pri=<n>` first so a caller can assert it was not clamped
# (31 = default band; 20 = still clamped).
set -u
if [ $# -lt 4 ] || [ "$3" != "--" ]; then
  echo "usage: $0 <logfile> <timeout-sec> -- <cmd> [args...]" >&2
  exit 2
fi
LOG=$1; TMO=$2; shift 3
[ "$(uname -s)" = Darwin ] || { echo "darwin only" >&2; exit 2; }

U=$(id -u)
LABEL="com.baker.rni-interactive.$$"
WORK=$(mktemp -d /tmp/rni-interactive.XXXXXX)
RUN="$WORK/run.sh"
DONE="$WORK/done"
{
  echo '#!/bin/zsh'
  echo 'echo "interactive_pri=$(ps -o pri= -p $$ | tr -d " ")"'
  printf 'perl -e %s' "'alarm $TMO; exec @ARGV'"
  for a in "$@"; do printf ' %q' "$a"; done
  echo
  echo "echo \"interactive_rc=\$?\""
  echo "touch $(printf '%q' "$DONE")"
} > "$RUN"

cat > "$WORK/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$RUN</string></array>
  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>$PWD</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF

: > "$LOG"
cleanup() { launchctl bootout "gui/$U/$LABEL" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
launchctl bootstrap "gui/$U" "$WORK/job.plist" || { echo "launchctl bootstrap failed" >&2; exit 1; }

deadline=$(( $(date +%s) + TMO + 15 ))
while [ ! -e "$DONE" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
[ -e "$DONE" ] || echo "interactive_timeout after ${TMO}s" >> "$LOG"
cat "$LOG"
grep -q '^interactive_rc=0$' "$LOG"
