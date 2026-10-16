# FP-57: start a fixture server on a FIXED port (the committed bundles hardcode 18931/18932) and
# return only once THIS process is the port's listener. Lanes A and B and the merge job run gates
# at the same time; "a connect succeeds" then often meant ANOTHER job's server answered while ours
# had died on bind, and the engine's fetches landed in the wrong server (ci-image-net "/red.png
# requested 0 times", ci-record-raster's images case with no remote image, ci-trace's ImageDecode
# on main from a defaultSource-only frame).
#   rni_own_port PORT OUTFILE CMD...   sets OWN_PORT_PID, returns 1 after ~2 min without the port
rni_port_listener_is() {  # port pid (ss on linux, lsof on darwin)
  if command -v ss > /dev/null 2>&1; then
    ss -ltnpH "sport = :$1" 2> /dev/null | grep -q "pid=$2,"
  else
    lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2> /dev/null | grep -qx "$2"
  fi
}
rni_own_port() {
  local port="$1" out="$2"; shift 2
  local try i
  OWN_PORT_PID=""
  for try in $(seq 60); do
    "$@" > "$out" 2>&1 &
    OWN_PORT_PID=$!
    for i in $(seq 50); do
      kill -0 "$OWN_PORT_PID" 2> /dev/null || break
      rni_port_listener_is "$port" "$OWN_PORT_PID" && return 0
      sleep 0.1
    done
    kill "$OWN_PORT_PID" 2> /dev/null; wait "$OWN_PORT_PID" 2> /dev/null
    OWN_PORT_PID=""; sleep 1
  done
  return 1
}
