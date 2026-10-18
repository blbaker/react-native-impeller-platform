#!/usr/bin/env bash
# Mutation check for engine/runtime/EngineSession.{h,cpp} -- the sequence it
# extracted from engine/host/main.cpp's RunWindowed() and headless path. Each
# mutant reintroduces ONE specific defect the extraction could have silently
# introduced, applied to a scratch backup of EngineSession.cpp; the baseline
# (unmutated) run must PASS first, each mutant must turn its own gate red for
# its own stated reason, and the source is restored (and rebuilt) on exit no
# matter what.
#
#   M1  WaitForJsQueueDrained stops actually draining (returns true without
#       waiting)      -> tools/ci-first-present.sh: first frame is BLACK
#       instead of the boot screen (the windowed boot wait this mutates is
#       exactly what keeps the first present from racing ahead of React's
#       first commit).
#   M2  PumpNativeAnimated becomes a no-op       -> tools/ci-eng06.sh: the
#       Animated value never moves (ENG-06's own acceptance gate).
#   M3  Boot() constructs FabricHost before ReactHost (reactHost_ is still
#       null, so FabricHost's ReactInstance& argument is a null
#       dereference)  -> tools/ci-p2.sh: the engine segfaults (exit 139)
#       instead of mounting.
#
# Each gate here already exists in the repo and is unmodified by this
# refactor; this script only proves EngineSession's OWN code is load-bearing
# for them, not that the gates themselves work (they are proven elsewhere).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=engine/runtime/EngineSession.cpp
BAK="$(mktemp -d)"
cp "$SRC" "$BAK/EngineSession.cpp.orig"
restore() {
  cp "$BAK/EngineSession.cpp.orig" "$SRC"
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 \
    || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "ENGINESESSION_MUTATION_FAIL: $*" >&2; exit 1; }

build() {
  bash tools/engine-build.sh linux x64 > "$BAK/build.log" 2>&1 \
    || { tail -30 "$BAK/build.log" >&2; fail "$1: tree did not build"; }
}

# mutate OLD NEW: exact single replacement in $SRC, asserted unique.
mutate() {
  python3 - "$SRC" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found/ambiguous in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

# mutate_from_files OLD_FILE NEW_FILE: same, but reads the (possibly
# multi-line) old/new text from files instead of argv -- a heredoc nested
# inside a $(...) command substitution does not parse in bash, so the M3
# multi-line block below is written to real files first.
mutate_from_files() {
  python3 - "$SRC" "$1" "$2" <<'PY'
import sys
p, old_f, new_f = sys.argv[1:]
old = open(old_f).read()
new = open(new_f).read()
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not found/ambiguous in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

echo "== control: unmutated tree must PASS =="
build control
DISPLAY=:94 bash tools/ci-first-present.sh > "$BAK/control-fp.log" 2>&1 \
  || { tail -15 "$BAK/control-fp.log" >&2; fail "control: ci-first-present.sh failed on the unmutated tree"; }
bash tools/ci-p2.sh > "$BAK/control-p2.log" 2>&1 \
  || { tail -15 "$BAK/control-p2.log" >&2; fail "control: ci-p2.sh failed on the unmutated tree"; }
echo "   OK: control passes (ci-first-present.sh, ci-p2.sh)"
# ci-eng06.sh is the slowest gate (packs + installs a throwaway app); its own
# control run is folded into M2's "revert and confirm green" step below
# instead of running it twice.

echo "== M1: WaitForJsQueueDrained stops actually draining =="
mutate \
  $'bool EngineSession::WaitForJsQueueDrained(int timeoutMs) {\n  return reactHost_->waitForJsQueueDrained(timeoutMs);\n}' \
  $'bool EngineSession::WaitForJsQueueDrained(int timeoutMs) {\n  (void)timeoutMs;\n  return true;  // MUTANT M1: drop the drain\n}'
build M1
if DISPLAY=:94 bash tools/ci-first-present.sh > "$BAK/M1.log" 2>&1; then
  fail "M1 SURVIVED: ci-first-present.sh passed with the drain dropped"
fi
grep -q "first frame is BLACK" "$BAK/M1.log" \
  || { tail -15 "$BAK/M1.log" >&2; fail "M1 killed by the WRONG assertion (wanted: first frame is BLACK)"; }
echo "   OK: M1 killed ($(grep -o 'FIRST_PRESENT_GATE_FAIL: .*' "$BAK/M1.log"))"
cp "$BAK/EngineSession.cpp.orig" "$SRC"

echo "== M2: PumpNativeAnimated becomes a no-op =="
mutate \
  'void EngineSession::PumpNativeAnimated() { reactHost_->pumpNativeAnimated(); }' \
  'void EngineSession::PumpNativeAnimated() { /* MUTANT M2: dropped the pump */ }'
build M2
if bash tools/ci-eng06.sh > "$BAK/M2.log" 2>&1; then
  fail "M2 SURVIVED: ci-eng06.sh passed with the pump dropped"
fi
grep -q "ENG06_FAIL" "$BAK/M2.log" \
  || { tail -15 "$BAK/M2.log" >&2; fail "M2 killed by the WRONG assertion (wanted: ENG06_FAIL)"; }
echo "   OK: M2 killed ($(grep -o 'ENG06_FAIL: .*' "$BAK/M2.log"))"
cp "$BAK/EngineSession.cpp.orig" "$SRC"

echo "== M3: Boot() constructs FabricHost before ReactHost =="
cat > "$BAK/m3-old.txt" <<'OLD'
  // parity item 24: a Metro-served bundle is debuggable.
  reactHost_ = std::make_unique<ReactHost>(options.withInspector);
  reactHost_->setKnownComponents(FabricHost::knownComponentNames());

  // ENG-09/FP-42/FP-43: the SAME stores the TurboModules write into.
  sceneGraph_->setWorldRasterStore(reactHost_->worldRasterStore());
  sceneGraph_->setTextureRegistry(reactHost_->textureRegistry());
  sceneGraph_->setSnapshotController(reactHost_->snapshots());
  sceneGraph_->setPlatformViewsEmbedded(options.platformViewsEmbedded);

  // Seed platform-module state BEFORE the bundle evaluates (Appearance.js
  // reads this at module scope).
  reactHost_->displayMetrics()->set((float)pxWidth / pointScale,
                                    (float)pxHeight / pointScale, pointScale);
  reactHost_->appearance()->set(options.colorScheme);
  *reactHost_->initialUrl() = options.initialUrl;

  // THE FABRIC MUST BE UP BEFORE THE BUNDLE EVALUATES.
  // The Scheduler installs UIManagerBinding through the unbuffered executor,
  // and ReactFabric reads global.nativeFabricUIManager the moment it
  // initialises -- so RunScript (called after Boot returns) must never run
  // before fabricHost_ exists. This is the order
  // tools/mutation-verify-enginesession.sh reorders to prove it is load-
  // bearing.
  fabricHost_ = std::make_unique<FabricHost>(
      reactHost_->instance(), sceneGraph_.get(), typography_,
      options.logMutations, reactHost_->displayMetrics());
OLD
cat > "$BAK/m3-new.txt" <<'NEW'
  // MUTANT M3: FabricHost constructed BEFORE ReactHost -- reactHost_ is
  // still a null unique_ptr here, so reactHost_->instance() is a null
  // dereference.
  fabricHost_ = std::make_unique<FabricHost>(
      reactHost_->instance(), sceneGraph_.get(), typography_,
      options.logMutations, nullptr);

  // parity item 24: a Metro-served bundle is debuggable.
  reactHost_ = std::make_unique<ReactHost>(options.withInspector);
  reactHost_->setKnownComponents(FabricHost::knownComponentNames());

  // ENG-09/FP-42/FP-43: the SAME stores the TurboModules write into.
  sceneGraph_->setWorldRasterStore(reactHost_->worldRasterStore());
  sceneGraph_->setTextureRegistry(reactHost_->textureRegistry());
  sceneGraph_->setSnapshotController(reactHost_->snapshots());
  sceneGraph_->setPlatformViewsEmbedded(options.platformViewsEmbedded);

  // Seed platform-module state BEFORE the bundle evaluates (Appearance.js
  // reads this at module scope).
  reactHost_->displayMetrics()->set((float)pxWidth / pointScale,
                                    (float)pxHeight / pointScale, pointScale);
  reactHost_->appearance()->set(options.colorScheme);
  *reactHost_->initialUrl() = options.initialUrl;
NEW
mutate_from_files "$BAK/m3-old.txt" "$BAK/m3-new.txt"
build M3
if bash tools/ci-p2.sh > "$BAK/M3.log" 2>&1; then
  fail "M3 SURVIVED: ci-p2.sh passed with FabricHost built before ReactHost"
fi
grep -qE "exited 139|Segmentation fault|P2_MOUNT_FAIL" "$BAK/M3.log" \
  || { tail -15 "$BAK/M3.log" >&2; fail "M3 killed by the WRONG assertion (wanted: a crash / P2_MOUNT_FAIL)"; }
echo "   OK: M3 killed ($(grep -o 'P2_MOUNT_FAIL: .*' "$BAK/M3.log" || true))"
cp "$BAK/EngineSession.cpp.orig" "$SRC"

echo "== confirm green again after reverting every mutant =="
build revert
DISPLAY=:94 bash tools/ci-first-present.sh > "$BAK/revert-fp.log" 2>&1 \
  || { tail -15 "$BAK/revert-fp.log" >&2; fail "reverted tree failed ci-first-present.sh"; }
bash tools/ci-p2.sh > "$BAK/revert-p2.log" 2>&1 \
  || { tail -15 "$BAK/revert-p2.log" >&2; fail "reverted tree failed ci-p2.sh"; }
bash tools/ci-eng06.sh > "$BAK/revert-eng06.log" 2>&1 \
  || { tail -15 "$BAK/revert-eng06.log" >&2; fail "reverted tree failed ci-eng06.sh"; }
echo "   OK: green again (ci-first-present.sh, ci-p2.sh, ci-eng06.sh)"

echo "ENGINESESSION_MUTATION_PASS (3/3 mutants killed by their own assertion)"
