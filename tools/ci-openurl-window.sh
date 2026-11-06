#!/usr/bin/env bash
# ENG-38 / ENG-55 GATE: Linking.openURL from JS, on the WINDOWED path, with &
# and %HH escapes, on Linux, macOS and Windows.
#
# --test-openurl proves the predicate in isolation. This proves the whole
# chain a user hits: a JS call, the TurboModule, the predicate and the launch,
# in a windowed run.
#
#   A  JS opens 'https://example.com/?a=1&b=2' (literal in the fixture).
#   B  OAuth authorize URL (& plus %3A/%2F escapes), via --initial-url.
#   D  'https://example.com/?a=1&b=2%20c' (the ENG-55 acceptance URL).
#      A, B and D: stdout has `rn-impeller: openURL=<url>`, no REFUSED or
#      FAILED line, JS sees resolved=true, and the launcher got the URL whole.
#   C  CONTROL: 'https://example.com/?a=1&b=2|calc' must be REFUSED, with no
#      openURL= line, resolved=false and nothing launched. Without C, a
#      predicate stuck on "open" passes A, B and D.
#
# How "the launcher got the URL whole" is read, per OS:
#   Linux    xdg-open is a stub on PATH that records its argv (argc=1 and
#            argv[1] byte for byte). Nothing real launches. The gate refuses to
#            run if the stub does not win the PATH lookup.
#   macOS    /usr/bin/open runs by absolute path and cannot be stubbed: A, B
#            and D open the real browser, so they run only with
#            RNI_OPENURL_ALLOW_LAUNCH=1. Without it the verdict is PARTIAL.
#   Windows  ShellExecuteW hands the URL to the registered browser, which
#            cannot be stubbed either: same RNI_OPENURL_ALLOW_LAUNCH=1 rule.
#            With it, tools/win-browser-cmdline.ps1 finds the process the
#            launch started and requires the URL in its command line, byte for
#            byte, as one token. On CI the gate closes msedge between arms so
#            each arm's browser is a fresh, long-lived process.
#
# Windowed mode: Linux runs --window on a private Xvfb. Elsewhere --window
# would put a window on a real screen, so it is used only on CI (CI=true) or
# when RNI_OPENURL_WINDOW_FLAG=--window is set; otherwise the gate runs
# headless and prints OPENURL_HEADLESS_PASS, never OPENURL_WINDOW_PASS.
#
# Windows runs this under Git Bash (a CI runner), not from WSL.
# Node-free: prebuilt bundle + RNI_BIN.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  MINGW*|MSYS*|CYGWIN*) OS=win32 ;;
  *) echo "OPENURL_WINDOW_FAIL: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
BUNDLE="${RNI_TEST_BUNDLE:-$ROOT/fixtures/eng38-openurl/prebuilt/eng38-openurl.bundle}"
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$OS" = darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
elif [ "$OS" = win32 ]; then BIN="$ROOT/packages-engine/engine-win32-x64/bin/rn-impeller.exe"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
# run() cds into the binary's directory, so a relative RNI_BIN must be made
# absolute first or the exec would resolve it against the wrong directory.
case "$BIN" in /*) ;; *) BIN="$ROOT/$BIN" ;; esac
fail() { echo "OPENURL_WINDOW_FAIL: $*" >&2; exit 1; }
[ -f "$BIN" ] || fail "no engine binary at $BIN"
[ -s "$BUNDLE" ] || fail "no bundle at $BUNDLE"

if [ -n "${RNI_OPENURL_WINDOW_FLAG+x}" ]; then MODE="$RNI_OPENURL_WINDOW_FLAG"
elif [ "$OS" = linux ] || [ "${CI:-}" = true ]; then MODE=--window
else MODE=""; fi
if [ "$OS" = linux ]; then FRAMES="${RNI_FRAMES:-2000}"; else FRAMES="${RNI_FRAMES:-400}"; fi
LAUNCH=1
if [ "$OS" != linux ] && [ "${RNI_OPENURL_ALLOW_LAUNCH:-0}" != 1 ]; then LAUNCH=0; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
URL_A='https://example.com/?a=1&b=2'
URL_B='https://auth.example.com/oauth/authorize?response_type=code&client_id=abc&redirect_uri=http%3A%2F%2F127.0.0.1%3A8791%2Fcb'
URL_C='https://example.com/?a=1&b=2|calc'
URL_D='https://example.com/?a=1&b=2%20c'

BUNDLE_ARG="$BUNDLE"
if [ "$OS" = win32 ]; then BUNDLE_ARG="$(cygpath -w "$BUNDLE")"; fi
COMMON=(--bundle "$BUNDLE_ARG" --app-name Eng38OpenUrl --probe-banner off --supersample-rnsvg 0
        --width 320 --height 240)

STUB="$WORK/stub"
if [ "$OS" = linux ]; then
  mkdir -p "$STUB"
  cat > "$STUB/xdg-open" <<'SH'
#!/bin/sh
# Records what the engine exec'd. Launches nothing.
{ echo "argc=$#"; for a in "$@"; do printf 'argv=%s\n' "$a"; done; } >> "$RNI_OPENURL_RECORD"
SH
  chmod +x "$STUB/xdg-open"
  [ "$(PATH="$STUB:$PATH" command -v xdg-open)" = "$STUB/xdg-open" ] \
    || fail "the xdg-open stub does not win the PATH lookup; refusing to risk a real launch"
fi
if [ "$OS" = win32 ] && [ "$LAUNCH" = 1 ]; then
  # Which handler ShellExecuteW will reach. Informational: the oracle below
  # reads the process that actually started, whatever it is.
  echo "   https handler: $(MSYS2_ARG_CONV_EXCL='*' reg.exe query \
    'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' \
    /v ProgId 2>/dev/null | tr -d '\r' | awk '/ProgId/ {print $3}' || true)"
fi

# run <name> [extra args]: stdout -> <name>.out, stderr -> <name>.err,
# stub record -> <name>.rec (linux).
run() {
  local name="$1"; shift
  local out="$WORK/$name.out" err="$WORK/$name.err" rec="$WORK/$name.rec"
  local cmd=("$BIN" "${COMMON[@]}" --frames "$FRAMES" "$@")
  [ -z "$MODE" ] || cmd+=("$MODE")
  local rc=0
  case "$OS" in
    linux)
      local q; q="$(printf '%q ' "${cmd[@]}")"
      RNI_OPENURL_RECORD="$rec" PATH="$STUB:$PATH" \
        xvfb-run -a -s "-screen 0 1280x800x24" bash -c "cd '$(dirname "$BIN")' && $q > '$out' 2> '$err'" \
        || rc=$? ;;
    win32)
      # MSYS2_ARG_CONV_EXCL: Git Bash must not rewrite any argument (the URLs
      # hold '/' and '='); the bundle path is already a Windows path.
      ( cd "$(dirname "$BIN")" && MSYS2_ARG_CONV_EXCL='*' exec "${cmd[@]}" ) > "$out" 2> "$err" || rc=$?
      sed -i 's/\r$//' "$out" "$err" ;;
    *)
      ( cd "$(dirname "$BIN")" && exec "${cmd[@]}" ) > "$out" 2> "$err" || rc=$? ;;
  esac
  [ "$rc" = 0 ] || { tail -8 "$err" >&2; fail "$name: engine exited $rc"; }
  grep -qE '^rn-impeller: scene_nodes=[1-9]' "$out" || fail "$name: the fixture mounted nothing"
  if [ -n "$MODE" ]; then
    grep -q '^RN_IMPELLER_WINDOW_OK' "$out" || { tail -8 "$out" >&2; fail "$name: no RN_IMPELLER_WINDOW_OK (not the windowed path?)"; }
  fi
  grep -q '^\[js\] ENG38 DONE' "$out" || { tail -8 "$out" >&2; fail "$name: the fixture never finished its openURL call"; }
}

close_ci_browser() {  # CI only: each arm's launch must start a fresh browser
  if [ "$OS" = win32 ] && [ "${CI:-}" = true ]; then
    MSYS2_ARG_CONV_EXCL='*' taskkill.exe /F /IM msedge.exe > /dev/null 2>&1 || true
    sleep 1
  fi
}

expect_open() {  # name url
  local name="$1" url="$2" out="$WORK/$1.out" err="$WORK/$1.err" rec="$WORK/$1.rec"
  grep -qxF "[js] ENG38 target=$url" "$out" || fail "$name: JS did not target $url"
  grep -qxF "rn-impeller: openURL=$url" "$out" || { grep -h openURL "$out" "$err" >&2 || true; fail "$name: no 'rn-impeller: openURL=$url' line on stdout"; }
  if grep -hE '(openURL REFUSED|openURL FAILED)' "$out" "$err"; then fail "$name: REFUSED/FAILED line present"; fi
  grep -qxF '[js] ENG38 resolved=true' "$out" || fail "$name: JS saw $(grep -h 'ENG38 resolved=' "$out")"
  echo "   stdout: rn-impeller: openURL=$url"
  echo "   js: $(grep -h 'ENG38 resolved=' "$out" | sed 's/^\[js\] //'); REFUSED/FAILED lines: 0"
  case "$OS" in
    linux)
      # xdg-open is not waited on; give the forked child a moment to write.
      local i=0; while [ ! -s "$rec" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
      [ -s "$rec" ] || fail "$name: the engine never exec'd xdg-open"
      [ "$(sed -n 1p "$rec")" = "argc=1" ] || fail "$name: xdg-open got $(sed -n 1p "$rec") (want argc=1)"
      [ "$(sed -n 2p "$rec")" = "argv=$url" ] || fail "$name: xdg-open argv[1] is '$(sed -n 2p "$rec")' (want '$url')"
      echo "   exec: xdg-open argc=1 argv[1]=$url" ;;
    win32)
      printf '%s' "$url" > "$WORK/$name.url"
      local o rc=0
      o="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ROOT/tools/win-browser-cmdline.ps1")" \
            -UrlFile "$(cygpath -w "$WORK/$name.url")" 2>&1 | tr -d '\r')" || rc=$?
      echo "$o" | sed 's/^/   /'
      [ "$rc" = 0 ] && echo "$o" | grep -q '^BROWSER_CMDLINE pid=' \
        || fail "$name: no browser process holds '$url' byte for byte in its command line" ;;
  esac
}

PARTIAL=0
if [ "$LAUNCH" = 0 ]; then
  echo "== A/B/D SKIPPED: on $OS they open example.com in the real browser (the launcher is not stubbable); set RNI_OPENURL_ALLOW_LAUNCH=1 =="
  PARTIAL=1
else
  echo "== A. JS Linking.openURL('$URL_A') ($OS, ${MODE:-headless}, frames=$FRAMES) =="
  close_ci_browser; run a
  expect_open a "$URL_A"
  echo "== B. OAuth authorize URL with & and %HH escapes =="
  close_ci_browser; run b --initial-url "$URL_B"
  expect_open b "$URL_B"
  echo "== D. ENG-55 acceptance URL '$URL_D' =="
  close_ci_browser; run d --initial-url "$URL_D"
  expect_open d "$URL_D"
  close_ci_browser
fi

echo "== C. CONTROL: '$URL_C' must be refused =="
run c --initial-url "$URL_C"
grep -qxF "[js] ENG38 target=$URL_C" "$WORK/c.out" || fail "C: JS did not target $URL_C"
grep -qxF "rn-impeller: openURL REFUSED (not an openable URL): $URL_C" "$WORK/c.err" \
  || { grep -h openURL "$WORK/c.out" "$WORK/c.err" >&2 || true; fail "C: no REFUSED line on stderr"; }
if grep -q '^rn-impeller: openURL=' "$WORK/c.out"; then fail "C: the hostile URL was launched"; fi
grep -qxF '[js] ENG38 resolved=false' "$WORK/c.out" || fail "C: JS saw $(grep -h 'ENG38 resolved=' "$WORK/c.out")"
if [ "$OS" = linux ]; then
  sleep 0.5
  [ ! -e "$WORK/c.rec" ] || fail "C: xdg-open was exec'd for a refused URL: $(cat "$WORK/c.rec")"
  echo "   exec: none"
fi
echo "   stderr: rn-impeller: openURL REFUSED (not an openable URL): $URL_C"
echo "   js: resolved=false"

if [ "$PARTIAL" = 1 ]; then
  echo "OPENURL_WINDOW_PARTIAL (control arm only; A/B/D need RNI_OPENURL_ALLOW_LAUNCH=1 on $OS)"
  exit 2
fi
if [ -z "$MODE" ]; then
  echo "OPENURL_HEADLESS_PASS ($OS, headless: & and %HH open from JS, hostile control refused)"
  exit 0
fi
echo "OPENURL_WINDOW_PASS ($OS, $MODE: & and %HH open from JS, hostile control refused)"
