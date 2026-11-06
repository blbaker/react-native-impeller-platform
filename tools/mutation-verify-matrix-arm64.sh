#!/usr/bin/env bash
# MUTATION TEST for tools/ci-matrix-arm64.sh (M3). One engine mutant per arm,
# each built ONLY into a scratch arm64 package (packages-engine/engine-linux-arm64
# and the x64 reference are never touched) and run against its own arm:
#   MA  ImagePaint.cpp: cover/contain/center drawn 2 pt low (arm64 only)
#       -> arm a must FAIL on the arm64-vs-x64 compare (the fixture's absolute
#          sample points still pass: only the differential sees it)
#   MB  WaylandTouch.cpp: TouchDown swaps x and y
#       -> arm b must FAIL: the tap at (300,50) no longer hits tap-b's tag
#   MC  GlfwPlatformSelect.h: RNI_GLFW_PLATFORM=x11 ignored
#       -> arm c must FAIL: Weston + XDG_SESSION_TYPE=wayland then picks wayland
# Control: the pristine source, staged the same scratch way, must reproduce the
# staged package's rn-impeller byte for byte and pass arms a b c. After the
# mutants the restored source must reproduce it again.
# Restore = cp + touch, never cp -p (an older mtime lets ninja keep the mutant).
# Usage: bash tools/mutation-verify-matrix-arm64.sh [MA MB MC]   (default all)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
. tools/lib/arm64-scratch-stage.sh
PKGBIN="$ARM64_PKGBIN"
WANT="${*:-MA MB MC}"
fail() { echo "MATRIX_ARM64_MUTATION_FAIL: $*"; exit 1; }
[ -f "$ARM64_EB/build.ninja" ] || fail "no arm64 build tree at $ARM64_EB (bash tools/engine-build.sh linux arm64)"
[ -x "$PKGBIN/rn-impeller" ] || fail "no staged arm64 package at $PKGBIN"
W="$(mktemp -d "${TMPDIR:-/tmp}/mv-matrix-arm64.XXXXXX")"
BACKUPS=()
restore_all() {
  local b
  for b in ${BACKUPS[@]+"${BACKUPS[@]}"}; do cp "$W/bak/${b//\//_}" "$b" && touch "$b"; done
  BACKUPS=()
}
trap 'restore_all; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $W" || rm -rf "$W"' EXIT
mkdir -p "$W/bak"

stage() { arm64_stage "$1" "$W/build-$(basename "$1").log" || fail "build for $1"; }
same_as_staged() { arm64_same_as_staged "$1"; }
mutate() {  # file old new
  local f="$1"
  python3 - "$f" "$2" "$3" <<'PY' || fail "mutant anchor not found exactly once in $1"
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit(f"{p}: anchor found {s.count(a)}x")
open(p, "w").write(s.replace(a, b))
PY
  touch "$f"
}
gate() {  # <pkgdir> <arms> <log>: rc of the matrix gate on that package
  local rc=0
  RNI_ARM64_ENGINE_DIR="$1/bin" bash tools/ci-matrix-arm64.sh --arms "$2" > "$3" 2>&1 || rc=$?
  return "$rc"
}

echo "== control: pristine source through the scratch staging =="
stage "$W/control"
same_as_staged "$W/control" || fail "control: the scratch staging does not reproduce the staged package (sha $(sha256sum "$W/control/bin/rn-impeller" | cut -c1-16) vs $(sha256sum "$PKGBIN/rn-impeller" | cut -c1-16)); rebuild with engine-build.sh first"
echo "   control rn-impeller == staged package ($(sha256sum "$PKGBIN/rn-impeller" | cut -c1-16))"
gate "$W/control" "a b c" "$W/control.log" || { tail -5 "$W/control.log"; fail "control: the pristine package fails the gate"; }
echo "   control: $(grep ARM64_MATRIX_PASS "$W/control.log" | cut -c1-60)"

KILLED=0
run_mutant() {  # name file old new arm expected-ERE
  local name="$1" file="$2" old="$3" new="$4" arm="$5" ere="$6" line
  case " $WANT " in *" $name "*) ;; *) return 0 ;; esac
  echo "== $name: $file -> arm $arm =="
  cp "$file" "$W/bak/${file//\//_}"; BACKUPS+=("$file")
  mutate "$file" "$old" "$new"
  stage "$W/$name"
  restore_all  # the source tree is mutated only for the build
  same_as_staged "$W/$name" && fail "$name: the mutant built a binary identical to the staged one (mutant not compiled in)"
  if gate "$W/$name" "$arm" "$W/$name.log"; then
    tail -5 "$W/$name.log"; fail "$name SURVIVED arm $arm"
  fi
  line="$(grep -m1 'ARM64_MATRIX_FAIL' "$W/$name.log" || true)"
  grep -qE "$ere" <<< "$line" || fail "$name: killed, but not by the expected assertion: ${line:-<no FAIL line>}"
  echo "   killed: ${line:0:200}"
  KILLED=$((KILLED + 1))
}

run_mutant MA engine/scenegraph/ImagePaint.cpp \
  'dst = {x + (w - dw) * 0.5f, y + (h - dh) * 0.5f, dw, dh};' \
  'dst = {x + (w - dw) * 0.5f, y + (h - dh) * 0.5f + 2.0f, dw, dh};  // MUTANT MA' \
  a 'a: arm64 render differs from x64 beyond the stated thresholds:.*B_cover_box'
run_mutant MB engine/host/WaylandTouch.cpp \
  $'  g.lastX = wl_fixed_to_double(fx);\n  g.lastY = wl_fixed_to_double(fy);\n  ++g.downs;' \
  $'  g.lastX = wl_fixed_to_double(fy);  // MUTANT MB\n  g.lastY = wl_fixed_to_double(fx);\n  ++g.downs;' \
  b "b: the tap at \(300,50\) did not hit tap-b's tag"
run_mutant MC engine/host/GlfwPlatformSelect.h \
  'if (std::strcmp(p, "x11") == 0) return {x11Id, "x11", "RNI_GLFW_PLATFORM"};' \
  'if (std::strcmp(p, "x11-MUTANT-MC") == 0) return {x11Id, "x11", "RNI_GLFW_PLATFORM"};' \
  c 'c: expected glfw_platform=x11, got glfw_platform=wayland'

echo "== restored: the source rebuilt again must reproduce the staged package =="
stage "$W/restored"
same_as_staged "$W/restored" || fail "restored: the rebuilt source differs from the staged package (restore failed?)"
echo "   restored rn-impeller == staged package"
echo "MATRIX_ARM64_MUTATION_PASS (killed $KILLED: $WANT; control passes a b c; restored source reproduces the staged package)"
