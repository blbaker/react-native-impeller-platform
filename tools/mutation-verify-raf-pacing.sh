#!/usr/bin/env bash
# Mutation-verify tools/ci-raf-pacing.sh: each mutant breaks one property of
# runtime/AnimationFrameScheduler (or its wiring) and must turn the gate RED
# for the RIGHT reason. Restores and rebuilds at the end; the clean engine
# must be GREEN again.
#
# Not covered (said out loud): the at-most-one-flush-in-flight guard in
# beginFrame(). Removing it only adds EMPTY flushes when the JS thread lags a
# frame, which no arm here can see.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RAF="engine/runtime/AnimationFrameScheduler.cpp"
MAIN="engine/host/main.cpp"
BACKUP="$(mktemp -d)"
cp "$RAF" "$BACKUP/raf.cpp"
cp "$MAIN" "$BACKUP/main.cpp"
restore() {
  cp "$BACKUP/raf.cpp" "$RAF"; touch "$RAF"
  cp "$BACKUP/main.cpp" "$MAIN"; touch "$MAIN"
}
trap 'restore; echo "(engine source restored; rebuild with tools/engine-build.sh)" >&2' EXIT

case "$(uname -s)" in Darwin) PKG=engine-darwin-arm64 ;; *) PKG=engine-linux-x64 ;; esac
build() { bash tools/engine-build.sh > "$1" 2>&1 || { tail -20 "$1" >&2; echo "MUTATE_FAIL: build failed" >&2; exit 1; }; }
gate()  { RNI_BIN="$ROOT/packages-engine/$PKG/bin/rn-impeller" bash tools/ci-raf-pacing.sh > "$1" 2>&1; }

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
  if ! grep -q 'RAF_PACING_FAIL' "$2"; then
    echo "MUTATE_FAIL: $1 SURVIVED -- ci-raf-pacing stayed GREEN" >&2; exit 1
  fi
  grep -qE "$3" "$2" || { echo "MUTATE_FAIL: $1 killed for the WRONG reason:" >&2; grep -m3 'FAIL' "$2" >&2; exit 1; }
  echo "   $1 killed: $(grep -m1 -E "$3" "$2" | sed 's/^ *//' | cut -c1-160)"
}

run() {  # name file old new ERE
  echo "== $1 =="
  mutate "$2" "$3" "$4"
  build "$BACKUP/$1-build.log"; gate "$BACKUP/$1.log" || true
  expect_killed "$1" "$BACKUP/$1.log" "$5"
  restore
}

# M1 pacing never installed: RN's setTimeout(0) rAF stays.
run M1 "$RAF" '  if (!enabled_) return;
  std::weak_ptr<AnimationFrameScheduler> weak = weak_from_this();
  runtime.global()' '  return;  // MUTANT M1
  std::weak_ptr<AnimationFrameScheduler> weak = weak_from_this();
  runtime.global()' 'a-paced.log: rAF ran [0-9]+/s'
# M2 the windowed loop never begins an animation frame.
run M2 "$MAIN" '      host.beginAnimationFrame();
      // FP-40' '      // MUTANT M2
      // FP-40' 'a-paced.log: (rAF contract broken|no rafrate line)'
# M3 cancelAnimationFrame does nothing.
run M3 "$RAF" '  pending_.erase(id);
  running_.erase(id);' '  (void)id;  // MUTANT M3' 'rAF contract broken'
# M4 a rAF registered inside a callback runs in the SAME flush.
run M4 "$RAF" '  while (!running_.empty()) {' \
  '  while (!running_.empty() || (!pending_.empty() && (running_.swap(pending_), true))) {  // MUTANT M4' \
  'rAF contract broken'
# M5 a throwing callback is swallowed.
run M5 "$RAF" '  if (firstError) std::rethrow_exception(firstError);' '  (void)firstError;  // MUTANT M5' \
  'swallowed, not reported'
# M6 no timer cadence: without a frame loop rAF never fires.
run M6 "$RAF" '    jsThread_->scheduleTimer(kTimerId, kTimerCadenceMs, false);
  }
  return id;' '    // MUTANT M6
  }
  return id;' 'b-headless.log: (rAF contract broken|no rafrate line)'

echo "== RESTORE: clean engine must be GREEN =="
restore
build "$BACKUP/clean-build.log"
gate "$BACKUP/clean.log" || { tail -15 "$BACKUP/clean.log" >&2; echo "MUTATE_FAIL: clean engine is RED" >&2; exit 1; }
grep -q RAF_PACING_PASS "$BACKUP/clean.log" || { echo "MUTATE_FAIL: clean engine has no RAF_PACING_PASS" >&2; exit 1; }
echo "   clean engine GREEN"
echo "MUTATE_RAF_PACING_PASS (6/6 killed)"
