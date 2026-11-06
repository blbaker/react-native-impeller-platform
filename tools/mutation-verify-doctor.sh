#!/usr/bin/env bash
# Mutation check for tools/ci-doctor.sh (linux matrix M2): every mutant is a
# real source edit, rebuilt into the x64 package, and the gate must FAIL on the
# assertion written for it (the failure line is matched, not just the exit code).
#
#   M1 host/OptionalLibs.cpp      libX11 soname list -> libX11.so.66 (a bad list):
#                                 the loader AND the doctor lose libX11, the
#                                 ldconfig oracle still sees libX11.so.6     -> H0 [libX11]
#   M2 host/HeadlessEglRungs.cpp  RNI_EGL_PLATFORM ignored (no rung skipped)  -> H1
#   M3 host/HeadlessEglRungs.cpp  no DRM node reported as 'fail', not
#                                 UNVERIFIED-ON-HARDWARE                      -> H2 verdict
#   M4 host/Doctor.cpp            llvmpipe reported as hardware               -> H0 gpu.verdict
#   M5 host/DoctorWindow.cpp      window.platform = the hint, not what
#                                 glfwInit got                                -> WS
#   M6 host/HeadlessSurfaceGl.cpp RNI_EGL_FORCE_PBUFFER ignored               -> H4 egl.current
#   M7 host/Doctor.cpp            EACCES reported as error                    -> D2 dma_heap
#   M8 host/Doctor.cpp            system-uncached counted as a cma heap       -> D2 dma_heap
#   M9 host/Doctor.cpp            RNI_DOCTOR_DMA_HEAP_DIR ignored             -> D1 dma_heap.hint
#   M10 host/Doctor.cpp           eacces hint names the wrong group           -> D2 dma_heap.hint
# Control: the pristine tree, rebuilt after the last restore, must pass the gate.
#
# Usage: bash tools/mutation-verify-doctor.sh        ONLY=M1,M4 runs a subset
# Restores use cp + touch, never cp -p: an old mtime makes ninja keep the
# mutant's object file and every later gate tests a broken engine.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$HOME/.local/bin:$PATH"
BK="$(mktemp -d)"
LOG="$BK/logs"; mkdir -p "$LOG"
FILES=(engine/host/OptionalLibs.cpp engine/host/HeadlessEglRungs.cpp engine/host/Doctor.cpp
       engine/host/DoctorWindow.cpp engine/host/HeadlessSurfaceGl.cpp)
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp "$f" "$BK/$f"; done
restore() { for f in "${FILES[@]}"; do cp "$BK/$f" "$f"; touch "$f"; done; }
trap 'restore' EXIT
fails=0; ran=0
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
build() { bash tools/engine-build.sh linux x64 > "$LOG/build-$1.log" 2>&1; }

mutate() {  # $1 file, $2 old, $3 new  (old must occur exactly once)
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
n = s.count(old)
assert n == 1, f"anchor found {n}x in {p}: {old!r}"
open(p, 'w').write(s.replace(old, new))
PY
}

run_mutant() {  # $1 id, $2 ERE the gate's FAIL line must match, $3 file, $4 old, $5 new
  want "$1" || return 0
  ran=$((ran + 1))
  restore
  if ! mutate "$3" "$4" "$5"; then echo "   $1: STALE ANCHOR in $3"; fails=$((fails + 1)); return; fi
  if ! build "$1"; then echo "   $1: build failed (see $LOG/build-$1.log)"; fails=$((fails + 1)); return; fi
  local out; out="$(timeout 900 bash tools/ci-doctor.sh --arch x64 2>&1)"; local rc=$?
  local line; line="$(grep -m1 'X64_DOCTOR_FAIL' <<< "$out" || true)"
  if [ "$rc" -eq 0 ]; then echo "   $1: SURVIVED (gate passed a broken engine)"; fails=$((fails + 1))
  elif ! grep -qE "$2" <<< "$line"; then
    echo "   $1: killed, but not by the expected assertion /$2/: ${line:-$(tail -2 <<< "$out")}"; fails=$((fails + 1))
  else echo "   $1: killed (${line#X64_DOCTOR_FAIL: })"; fi
}

echo "== mutants (x64; each rebuilds the engine) =="
run_mutant M1 'H0 \[libX11\]: dlopen\.libX11\.resolved' engine/host/OptionalLibs.cpp \
  '{"libX11.so.6", nullptr}' '{"libX11.so.66", nullptr}'
run_mutant M2 'H1: egl\.rung\.' engine/host/HeadlessEglRungs.cpp \
  'if (!rep.forced.empty() && rep.forced != name) {' 'if (false) {'
run_mutant M3 'H2: egl\.rung\.gbm\.verdict' engine/host/HeadlessEglRungs.cpp \
  'r->verdict = kUnverified;' 'r->verdict = "fail";'
run_mutant M4 'H0: gpu\.verdict' engine/host/Doctor.cpp \
  'emit("gpu.verdict", std::strcmp(cls, "software") == 0 ? headlessegl::kUnverified : "hardware");' \
  'emit("gpu.verdict", "hardware");'
run_mutant M5 'WS: window\.platform' engine/host/DoctorWindow.cpp \
  'emit("window.platform", PlatformName(glfwGetPlatform()));' 'emit("window.platform", pc.name);'
run_mutant M6 'H4: egl\.current' engine/host/HeadlessSurfaceGl.cpp \
  'const bool tryNoSurface = !rni::headlessegl::ForcePbuffer();' 'const bool tryNoSurface = true;'
run_mutant M7 "D2: dma_heap is 'system:error" engine/host/Doctor.cpp \
  'err == EACCES ? "eacces" : "error";' '"error";'
run_mutant M8 "D2: dma_heap is 'system:eacces cma:present'" engine/host/Doctor.cpp \
  ' && n != "system-uncached") cma = true;' ') cma = true;'
run_mutant M9 'D1: dma_heap\.hint' engine/host/Doctor.cpp \
  'const std::string dir = env && *env ? env : "/dev/dma_heap";' \
  'const std::string dir = env && *env && false ? env : "/dev/dma_heap";'
run_mutant M10 'D2: dma_heap\.hint' engine/host/Doctor.cpp \
  'KERNEL==\"system\", GROUP=\"video\",' 'KERNEL==\"system\", GROUP=\"render\",'

echo "== control: pristine tree rebuilt, gate must pass =="
restore
trap - EXIT
if ! build control; then echo "   control: build failed"; fails=$((fails + 1))
elif timeout 900 bash tools/ci-doctor.sh --arch x64 > "$LOG/control.log" 2>&1; then echo "   control: $(tail -1 "$LOG/control.log" | cut -c1-60)"
else echo "   control: FAILED: $(grep -m1 X64_DOCTOR_FAIL "$LOG/control.log")"; fails=$((fails + 1)); fi
for f in "${FILES[@]}"; do cmp -s "$f" "$BK/$f" || { echo "   restore check: $f differs from its backup"; fails=$((fails + 1)); }; done
rm -rf "$BK"
if [ -n "${ONLY:-}" ]; then tag=DOCTOR_MUTATION_PARTIAL_PASS; else tag=DOCTOR_MUTATION_PASS; fi
if [ "$fails" -eq 0 ] && [ "$ran" -ge 1 ]; then echo "$tag ($ran mutants killed by their own assertions; control passes)"; exit 0; fi
echo "DOCTOR_MUTATION_FAIL ($fails wrong of $ran mutants + control)"; exit 1
