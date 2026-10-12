#!/usr/bin/env bash
# Drop-in RNI_BIN for the style gates (SC-40): runs the staged Windows engine
# (packages-engine/engine-win32-x64/bin/rn-impeller.exe) from WSL, headless.
#   RNI_BIN=$PWD/tools/win-run-engine.sh bash tools/ci-style-coverage.sh
# cmd.exe refuses a UNC (\\wsl.localhost) cwd and the exe cannot read WSL
# paths, so absolute-path arguments are copied under the Windows temp dir
# (inputs, cached by hash) and --screenshot is written there and copied back.
# RNI_* env vars are forwarded through `set` lines in the generated .cmd.
# Prints the exe's own stdout/stderr (CRLF stripped); exits with its code.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$PATH:/mnt/c/Windows/System32"
EXE_DIR="${RNI_WIN_ENGINE_DIR:-$ROOT/packages-engine/engine-win32-x64/bin}"
TMPW="${RNI_WIN_TMP:-/mnt/c/Users/Public/AppData/Local/Temp/rni-style}"
[ -f "$EXE_DIR/rn-impeller.exe" ] || { echo "win-run-engine: no exe in $EXE_DIR (bash tools/engine-build.sh win32 x64)" >&2; exit 127; }
command -v cmd.exe >/dev/null || { echo "win-run-engine: cmd.exe not reachable" >&2; exit 127; }

mkdir -p "$TMPW/cache"
RUN="$(mktemp -d "$TMPW/run.XXXXXX")"
trap 'rm -rf "$RUN"' EXIT
# The exe and its DLLs must sit on a drive letter too (no RPATH; UNC cwd refused).
# Re-copy only when the staged exe changed.
ENG="$TMPW/engine"
sum="$(sha256sum "$EXE_DIR/rn-impeller.exe" "$EXE_DIR/impeller.dll" | sha256sum | cut -c1-16)"
if [ "$(cat "$ENG/.stamp" 2>/dev/null)" != "$sum" ]; then
  rm -rf "$ENG.new"; cp -r "$EXE_DIR" "$ENG.new" && echo "$sum" > "$ENG.new/.stamp" \
    && rm -rf "$ENG" && mv "$ENG.new" "$ENG"
fi

win() { wslpath -w "$1"; }
stage_in() {  # absolute WSL path -> Windows path of a cached copy
  local p="$1" h dst
  if [ -d "$p" ]; then
    h="$(cd "$p" && find . -type f -exec sha256sum {} + | sort | sha256sum | cut -c1-16)"
    dst="$TMPW/cache/$h-$(basename "$p")"
    [ -d "$dst" ] || { cp -r "$p" "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
  else
    h="$(sha256sum "$p" | cut -c1-16)"
    dst="$TMPW/cache/$h-$(basename "$p")"
    [ -f "$dst" ] || { cp "$p" "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
  fi
  win "$dst"
}

ARGS=(); SHOT_OUT=""; prev=""
for a in "$@"; do
  if [ "$prev" = --screenshot ]; then
    SHOT_OUT="$a"; ARGS+=("$(win "$RUN")\\shot.ppm")
  elif [ "${a#/}" != "$a" ] && [ -e "$a" ]; then
    ARGS+=("$(stage_in "$a")")
  else
    ARGS+=("$a")
  fi
  prev="$a"
done

q() { local s="${1//%/%%}"; printf '"%s"' "$s"; }  # .cmd quoting: % must be doubled
{
  printf '@echo off\r\n'
  while IFS='=' read -r k v; do
    case "$k" in RNI_BIN|RNI_WIN_*|RNI_EXPECT_PLATFORM) continue ;; esac
    printf 'set "%s=%s"\r\n' "$k" "${v//%/%%}"
  done < <(env | grep -E '^RNI_[A-Z0-9_]*=' || true)
  printf 'cd /d %s\r\n' "$(q "$(win "$ENG")")"
  printf 'rn-impeller.exe'
  for a in "${ARGS[@]}"; do printf ' %s' "$(q "$a")"; done
  printf '\r\nexit /b %%errorlevel%%\r\n'
} > "$RUN/run.cmd"

( cd /mnt/c && cmd.exe /c "$(win "$RUN/run.cmd")" ) 2>&1 | sed 's/\r$//' | tr -d '\0'
rc=${PIPESTATUS[0]}
if [ -n "$SHOT_OUT" ] && [ -f "$RUN/shot.ppm" ]; then cp "$RUN/shot.ppm" "$SHOT_OUT"; fi
exit "$rc"
