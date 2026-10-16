#!/usr/bin/env bash
# host-window.sh: run a windowed engine the way this host can (FP-19).
#   rni_xrun <authfile> cmd...   linux: under a private xvfb-run; darwin: directly on the
#                                login session's window server (from a launchd job, wrap it in
#                                tools/darwin-run-interactive.sh to lift the QoS clamp)
#   rni_host                     prints linux | darwin | other
# Sources portable-timeout.sh too, so `timeout N cmd` works on stock macOS.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-timeout.sh"

rni_host() {
  case "$(uname -s)" in Linux) echo linux ;; Darwin) echo darwin ;; *) echo other ;; esac
}

rni_xrun() {
  local auth="$1"; shift
  if [ "$(rni_host)" = linux ]; then
    xvfb-run -a -f "$auth" -s "-screen 0 1280x1024x24" "$@"
  else
    "$@"
  fi
}
