#!/usr/bin/env bash
# cpu-hog.sh: saturate the box while a gate runs (FP-06 load-proof gates).
#   . tools/lib/cpu-hog.sh; hog_start [workers]; ...; hog_stop
# stress-ng --cpu when installed, else one busy python3 loop per worker. Workers default to
# nproc (RNI_HOG_WORKERS overrides). hog_alive fails once any worker died, so a gate can prove
# the hog really ran for its whole measurement.
HOG_PIDS=""
hog_start() {
  local n="${1:-${RNI_HOG_WORKERS:-$(nproc)}}" i
  if command -v stress-ng > /dev/null 2>&1; then
    stress-ng --cpu "$n" --timeout 4h --quiet > /dev/null 2>&1 &
    HOG_PIDS="$!"
    HOG_KIND="stress-ng --cpu $n"
  else
    for ((i = 0; i < n; i++)); do
      python3 -c 'while True: pass' > /dev/null 2>&1 &
      HOG_PIDS="$HOG_PIDS $!"
    done
    HOG_KIND="$n python3 busy loops"
  fi
  HOG_WORKERS="$n"
}
hog_alive() {
  local p
  [ -n "$HOG_PIDS" ] || return 1
  for p in $HOG_PIDS; do kill -0 "$p" 2> /dev/null || return 1; done
}
hog_stop() {
  local p
  for p in $HOG_PIDS; do kill "$p" 2> /dev/null; done
  for p in $HOG_PIDS; do wait "$p" 2> /dev/null || true; done
  HOG_PIDS=""
  return 0
}
