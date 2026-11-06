#!/usr/bin/env bash
# Mutation check for tools/ci-package-linux.sh. Each mutant must
# make the gate FAIL, in the arm meant for it, with its own message:
#
#   control  arms P D on the real tarball and the real requirement list -> PASS
#   M1       the requirements image without libxkbcommon0 (a dlopen'ed
#            library: the loader cannot see it) -> arm D FAILS, and the DOCTOR
#            names it: image.missing=libxkbcommon.so.0
#   M2       the requirements image without libatomic1 (a DT_NEEDED library)
#            -> arm D FAILS: rn-impeller exits 127 and the loader names
#            libatomic.so.1
#   M3       a tarball whose rni-webhelper keeps the cross build's rpath
#            (package-engine-linux.sh without the elf_set_rpath step)
#            -> arm P FAILS on the helper's rpath
#
# The gate itself refuses a vacuous drop (a package another one pulls back in).
# Builds nothing in the worktree; M3's tarball goes to a scratch dir.
# Usage: bash tools/mutation-verify-package-linux.sh   (needs dist/engine-linux-arm64.tar.gz)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mv-pkg-linux.XXXXXX")"
MUT="$ROOT/tools/.mut-package-engine-linux.sh"
trap 'rm -rf "$WORK"; rm -f "$MUT"' EXIT
killed=0; survived=0; bad=0
expect_fail() {  # expect_fail <name> <ERE the failure must match> <cmd...>
  local name="$1" re="$2"; shift 2
  "$@" > "$WORK/$name.log" 2>&1
  local rc=$?
  local why; why="$(grep -m1 'PACKAGE_LINUX_FAIL' "$WORK/$name.log" || true)"
  if [ "$rc" = 0 ]; then
    echo "SURVIVED $name: the gate passed"; survived=$((survived + 1))
  elif echo "$why" | grep -Eq "$re"; then
    echo "KILLED $name: $why"; killed=$((killed + 1))
  else
    echo "WRONG-RULE $name (exit $rc): ${why:-$(tail -3 "$WORK/$name.log" | tr '\n' ' ')}"; bad=$((bad + 1))
  fi
}
[ -f dist/engine-linux-arm64.tar.gz ] || { echo "MUTATION_PACKAGE_LINUX_FAIL: no dist/engine-linux-arm64.tar.gz"; exit 1; }

echo "== control (arms P D)"
if bash tools/ci-package-linux.sh --arms "P D" > "$WORK/control.log" 2>&1; then
  grep PACKAGE_LINUX_PASS "$WORK/control.log"
else
  tail -5 "$WORK/control.log"; echo "MUTATION_PACKAGE_LINUX_FAIL: control does not pass"; exit 1
fi

echo "== M1 drop libxkbcommon0"
expect_fail M1 "^PACKAGE_LINUX_FAIL\[D\]: image\.missing='libxkbcommon\.so\.0'" \
  env RNI_IMGREQ_DROP=libxkbcommon0 bash tools/ci-package-linux.sh --arms D
echo "== M2 drop libatomic1"
expect_fail M2 '^PACKAGE_LINUX_FAIL\[D\]: rn-impeller --doctor exit 127: .*libatomic\.so\.1' \
  env RNI_IMGREQ_DROP=libatomic1 bash tools/ci-package-linux.sh --arms D

echo "== M3 helper keeps the build rpath"
grep -v 'tools/elf_set_rpath.py "$D/rni-webhelper"' tools/package-engine-linux.sh > "$MUT"
if cmp -s "$MUT" tools/package-engine-linux.sh; then
  echo "MUTATION_PACKAGE_LINUX_FAIL: M3 anchor not found"; exit 1
fi
# The package script refuses that helper twice itself (rpath, and any path in
# the dynamic section); drop both checks so the mutant tarball ships.
sed -i -e '/rni-webhelper rpath is/d' -e '/has a path in its dynamic section/s/&& fail .*/|| true/' "$MUT"
if bash "$MUT" --arch arm64 --out "$WORK/m3" > "$WORK/m3-pkg.log" 2>&1; then
  expect_fail M3 "^PACKAGE_LINUX_FAIL\[P\]: rni-webhelper rpath is '/opt/rni-wpe/lib'" \
    env RNI_PKG_TARBALL="$WORK/m3/engine-linux-arm64.tar.gz" bash tools/ci-package-linux.sh --arms P
else
  tail -3 "$WORK/m3-pkg.log"; echo "WRONG-RULE M3: the mutant package did not build"; bad=$((bad + 1))
fi

echo "killed=$killed survived=$survived wrong_rule=$bad"
[ "$killed" = 3 ] && [ "$survived" = 0 ] && [ "$bad" = 0 ] \
  && echo "MUTATION_PACKAGE_LINUX_PASS" || { echo "MUTATION_PACKAGE_LINUX_FAIL"; exit 1; }
