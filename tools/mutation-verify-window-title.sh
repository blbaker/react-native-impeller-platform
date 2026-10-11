#!/usr/bin/env bash
# Prove tools/ci-window-title.sh can FAIL: each mutant reverts one piece of the
# --title change, and the gate must die on THAT piece's own assertion.
#   M1 glfwCreateWindow ignores title_ (old hardcoded string). The engine still
#      LOGS window_title=HostApp, so only the X11 read can catch it.
#   M2 --title is no longer parsed (unknown flags are ignored, so it is silent).
#   M3 --help no longer lists --title.
#   M4 setTitle("") clobbers the default (no-flag launch gets an empty title).
# Linux only (the X11 arm is the oracle M1 needs). Rebuilds the staged
# linux engine per mutant and restores + rebuilds the clean tree on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN=engine/host/main.cpp; GS=engine/host/GlfwSurface.cpp; GH=engine/host/GlfwSurface.h
BAK="$(mktemp -d)"; cp "$MAIN" "$BAK/main.cpp"; cp "$GS" "$BAK/GlfwSurface.cpp"; cp "$GH" "$BAK/GlfwSurface.h"
put_back() { cp "$BAK/main.cpp" "$MAIN"; cp "$BAK/GlfwSurface.cpp" "$GS"; cp "$BAK/GlfwSurface.h" "$GH"; }
restore() {
  put_back
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || echo "WARN: rebuild of restored tree failed" >&2
  rm -rf "$BAK"
}
trap restore EXIT
fail() { echo "WT_MUTATION_FAIL: $*" >&2; exit 1; }

run_gate() { set +e; bash tools/ci-window-title.sh > "$1" 2>&1; local rc=$?; set -e; return $rc; }

mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor count {s.count(old)} != 1 in {p}: {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

check() {  # name, expected-failure-substring
  bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "$1 tree did not build"
  if run_gate "$BAK/$1.log"; then fail "$1 SURVIVED: gate passed with the fix reverted"; fi
  grep -qF -- "$2" "$BAK/$1.log" || { tail -8 "$BAK/$1.log" >&2; fail "$1 killed by the WRONG assertion (wanted: $2)"; }
  echo "   OK: $1 killed ($(grep -o 'WINDOW_TITLE_GATE_FAIL: .*' "$BAK/$1.log" | cut -c1-110))"
  put_back
}

echo "== control: unmutated tree must PASS =="
bash tools/engine-build.sh linux x64 > /dev/null 2>&1 || fail "control tree did not build"
run_gate "$BAK/control.log" || { tail -8 "$BAK/control.log" >&2; fail "control FAILED: nothing below means anything"; }
echo "   OK: control passes"

echo "== M1: glfwCreateWindow ignores the title =="
mutate "$GS" 'glfwCreateWindow(width, height, title_.c_str(),' 'glfwCreateWindow(width, height, "React Native (Impeller)",'
check M1 "window system title is 'React Native (Impeller)', expected 'HostApp'"

echo "== M2: --title not parsed =="
mutate "$MAIN" 'else if (a == "--title") gWindowTitle = next("--title");' ''
check M2 "engine did not log 'window_title=HostApp'"

echo "== M3: --help omits --title =="
mutate "$MAIN" '"                   [--title <string>]  (windowed) window title, also\n"' ''
check M3 "--help does not list"

echo "== M4: empty --title clobbers the default =="
mutate "$GH" 'if (!title.empty()) title_ = title;' 'title_ = title;'
check M4 "engine did not log 'window_title=React Native (Impeller)'"

echo "WT_MUTATION_PASS (4/4 mutants killed by their own assertion)"
