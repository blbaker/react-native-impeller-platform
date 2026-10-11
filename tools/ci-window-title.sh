#!/usr/bin/env bash
# WINDOW-TITLE GATE: `--title <string>` sets the windowed rn-impeller title
# (title bar + macOS Window menu); with no flag the title stays
# "React Native (Impeller)" (Mac ask 2026-10-05, HostApp.app showed the default).
#
#   1. `--help` lists --title.
#   2. The binary carries the string (`strings | grep -c -- --title` > 0, the
#      Mac's own delivery check).
#   3. `--window --title HostApp`: the engine logs window_title=HostApp AND the window
#      system holds "HostApp" (linux: _NET_WM_NAME read over X11 by PID, from
#      OUTSIDE the engine -- the log line alone only proves what main.cpp
#      meant to pass, not what glfwCreateWindow got).
#   4. `--window` with no --title: both read "React Native (Impeller)".
#
# Node-free: renders the committed first-present bundle. Engine binary:
# RNI_BIN wins; else linux builds + uses its staged package, darwin uses
# packages-engine/engine-darwin-arm64 as staged. On darwin, arms 3-4 read the
# title with System Events; when ssh lacks Accessibility permission they print
# WINDOW_TITLE_DARWIN_SKIP and only the log line is checked.
#
# ⚠️ DISPLAY=:0 on linux; SDL_VIDEODRIVER unset (see ci-window.sh).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/own-procs.sh"
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE="$ROOT/fixtures/first-present/prebuilt/first-present.bundle"
DEFAULT_TITLE="React Native (Impeller)"

fail() { echo "WINDOW_TITLE_GATE_FAIL: $*" >&2; exit 1; }

unset SDL_VIDEODRIVER || true
OS="$(uname -s)"
[ "$OS" = Linux ] && export DISPLAY="${DISPLAY:-:0}"
[ -s "$BUNDLE" ] || fail "no committed bundle at $BUNDLE"

if [ -n "${RNI_BIN:-}" ]; then
  BIN="$RNI_BIN"
elif [ "$OS" = Darwin ]; then
  BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
elif [ "$OS" = Linux ]; then
  case "$(uname -m)" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; *) fail "unsupported arch $(uname -m)" ;; esac
  bash tools/engine-build.sh linux "$ARCH" > "${TMPDIR:-/tmp}/ci-window-title-build.log" 2>&1 \
    || { tail -20 "${TMPDIR:-/tmp}/ci-window-title-build.log" >&2; fail "engine build failed"; }
  BIN="$ROOT/packages-engine/engine-linux-$ARCH/bin/rn-impeller"
else
  fail "unsupported OS $OS"
fi
[ -x "$BIN" ] || fail "no engine binary at $BIN (set RNI_BIN)"

# python-xlib for the linux X11 read (same candidates as ci-mouse-buttons.sh).
PY=""
if [ "$OS" = Linux ]; then
  for cand in "${RNI_PYTHON:-}" python3 "$HOME/.cache/rni/xtest-venv/bin/python"; do
    [ -n "$cand" ] || continue
    "$cand" -c 'from Xlib import display; display.Display()' > /dev/null 2>&1 && { PY="$cand"; break; }
  done
  [ -n "$PY" ] || fail "no python with python-xlib + a reachable DISPLAY=$DISPLAY: the X11 title arm cannot run"
fi

WORK="$(mktemp -d)"
cleanup() { rni_kill_own; [ "${KEEP_WORKDIR:-0}" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. --help lists --title =="
set +e; "$BIN" --help > "$WORK/help.txt" 2>&1; set -e
grep -q -- '--title <string>' "$WORK/help.txt" || fail "--help does not list '--title <string>'"
grep -- '--title' "$WORK/help.txt" | sed 's/^/   /'
echo "   OK"

echo "== 2. the binary carries the flag string =="
if command -v strings > /dev/null 2>&1; then
  N_STR="$(strings "$BIN" | grep -c -- '--title' || true)"
else
  N_STR="$(grep -a -c -- '--title' "$BIN" || true)"
fi
[ "${N_STR:-0}" -gt 0 ] || fail "strings rn-impeller | grep -c -- --title = 0"
echo "   OK: $N_STR"

# run_title <name> <expected-title> [--title value]: windowed launch, read the
# title from the window system while the window is up, then let it exit.
run_title() {
  local name="$1" want="$2"; shift 2
  local log="$WORK/$name.log" got="" pid rc
  local args=(--window --bundle "$BUNDLE" --app-name FirstPresent
              --width 400 --height 300 --idle-skip --idle-run-sec 6 "$@")
  if [ "$OS" = Darwin ]; then
    ( cd "$(dirname "$BIN")" && "$BIN" "${args[@]}" ) > "$log" 2>&1 &
    pid=$!; rni_track "$pid"
    sleep 3
    set +e
    got="$(osascript -e 'tell application "System Events" to get name of windows of process "rn-impeller"' 2> "$WORK/$name.osa")"
    local orc=$?
    set -e
    if [ "$orc" -ne 0 ]; then
      echo "   WINDOW_TITLE_DARWIN_SKIP: System Events read failed ($(head -c 120 "$WORK/$name.osa")); log line only"
      got=""
    fi
  else
    "$BIN" "${args[@]}" > "$log" 2>&1 &
    pid=$!; rni_track "$pid"
    set +e
    got="$("$PY" tools/x11-window-title.py "$pid" 15 2> "$WORK/$name.x11" | sed -n 's/^x11_title=//p' | head -1)"
    set -e
  fi
  set +e; wait "$pid"; rc=$?; set -e
  grep -E 'window_title=|scene_nodes=' "$log" | sed 's/^/   /'
  [ "$rc" -eq 0 ] || { tail -15 "$log" >&2; fail "$name: windowed run exited $rc"; }
  grep -qxF "rn-impeller: window_title=$want" "$log" \
    || fail "$name: engine did not log 'window_title=$want' (got: $(grep -m1 window_title= "$log" || echo none))"
  if [ "$OS" = Linux ]; then
    [ -n "$got" ] || { cat "$WORK/$name.x11" >&2; fail "$name: no X11 window with _NET_WM_PID=$pid carried a title"; }
    [ "$got" = "$want" ] || fail "$name: window system title is '$got', expected '$want'"
    echo "   OK: X11 title '$got'"
  elif [ -n "$got" ]; then
    [ "$got" = "$want" ] || fail "$name: System Events window name is '$got', expected '$want'"
    echo "   OK: System Events window name '$got'"
  fi
}

echo "== 3. --title HostApp reaches the window =="
run_title titled "HostApp" --title HostApp

echo "== 4. no --title keeps the default =="
run_title default "$DEFAULT_TITLE"

echo "WINDOW_TITLE_PASS"
