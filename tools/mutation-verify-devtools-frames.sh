#!/usr/bin/env bash
# MUTATION TEST for tools/ci-devtools-frames.sh (FP-54). Each mutant edits engine
# source, rebuilds, and must turn the gate red for its own reason; the source is
# restored and the clean engine re-gated at the end.
#
#   M1  StopRecording leaves the sink installed -> frames sent while not recording
#   M2  frame stamps converted without the recorder origin -> wrong clock base
#   M3  spans never handed to DevTools -> no host events on rn-impeller main
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DF="engine/base/DevToolsFrames.cpp"
FT="engine/host/FrameTimings.cpp"
DT="engine/runtime/DevToolsTracing.cpp"
BACKUP="$(mktemp -d)"
cp "$DF" "$BACKUP/DevToolsFrames.cpp"; cp "$FT" "$BACKUP/FrameTimings.cpp"; cp "$DT" "$BACKUP/DevToolsTracing.cpp"
restore() { cp "$BACKUP/DevToolsFrames.cpp" "$DF"; cp "$BACKUP/FrameTimings.cpp" "$FT"; cp "$BACKUP/DevToolsTracing.cpp" "$DT"; }
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

build() { bash tools/engine-build.sh linux x64 > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { bash tools/ci-devtools-frames.sh > "$1" 2>&1; }

mutate() {  # file old new
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
n = s.count(old)
assert n == 1, "anchor found %dx in %s" % (n, p)
open(p, "w").write(s.replace(old, new, 1))
PY
}

expect_killed() {  # name log ERE
  if ! grep -q 'DEVTOOLS_FRAMES_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-devtools-frames stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-200)"
}

echo "== M1: sink left installed after Tracing.end =="
mutate "$DF" "  gRecording.store(false);
  gSink.reset();
  return GetStats();" "  return GetStats();  // MUTANT M1"
build "$BACKUP/m1-build.log"; gate "$BACKUP/m1.log" || true
expect_killed M1 "$BACKUP/m1.log" 'DEVTOOLS_FRAMES_FAIL: host emitted [0-9]+ frames to DevTools but the trace holds [0-9]+ \(frames sent while not recording\)'
restore

echo "== M2: recorder-relative stamps used as absolute steady_clock times =="
mutate "$FT" "devtools::OnFrameCommitted({r.frame, kOrigin + std::chrono::microseconds(beginUs),
                              kOrigin + std::chrono::microseconds(r.us[5])});" \
  "devtools::OnFrameCommitted({r.frame, Clock::time_point() + std::chrono::microseconds(beginUs),
                              Clock::time_point() + std::chrono::microseconds(r.us[5])});  // MUTANT M2"
build "$BACKUP/m2-build.log"; gate "$BACKUP/m2.log" || true
expect_killed M2 "$BACKUP/m2.log" 'DEVTOOLS_FRAMES_FAIL: (Begin|Draw)Frame seq [0-9]+ at ts [0-9]+ lies outside RN.s commits .* \(wrong clock base'
restore

echo "== M3: spans not forwarded to DevTools =="
mutate "$DT" "  trace::SetSpanSink(&ReportSpan);" "  // MUTANT M3: trace::SetSpanSink(&ReportSpan);"
build "$BACKUP/m3-build.log"; gate "$BACKUP/m3.log" || true
expect_killed M3 "$BACKUP/m3.log" "DEVTOOLS_FRAMES_FAIL: only 0 'Frame' host spans"
restore

echo "== RESTORE: clean engine must be GREEN =="
build "$BACKUP/final-build.log"
gate "$BACKUP/final.log" || { tail -15 "$BACKUP/final.log" >&2; echo "MUTATE_FAIL: gate RED after restore" >&2; exit 1; }
echo "   $(grep -o 'DEVTOOLS_FRAMES_PASS.*' "$BACKUP/final.log" | cut -c1-120)"
trap - EXIT
rm -rf "$BACKUP"
echo "MUTATE_DEVTOOLS_FRAMES_OK -- 3 mutants, 3 killed, engine restored and green"
