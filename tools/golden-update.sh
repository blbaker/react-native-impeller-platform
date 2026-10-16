#!/usr/bin/env bash
# FP-51: regenerate tools/golden/<backend>/<case>.png for ONE backend, with a reviewable diff.
#   bash tools/golden-update.sh <backend> [case...]     run on a host that renders <backend>
#   bash tools/golden-update.sh --win                   win32-gles-angle through win-run-engine.sh
# Each case is rendered twice first; a render that differs from itself by more than the case's tolerance
# is refused (a golden that cannot reproduce is worthless). For a case whose golden exists, the new render
# is compared against the OLD golden and a 3-panel image (old | new | diff, off pixels red) is written to
# build/golden-diff/<backend>/<case>.update.png. Review those before committing the new PNGs.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
if [ "${1:-}" = --win ]; then set -- win32-gles-angle "${@:2}"; export RNI_BIN="$ROOT/tools/win-run-engine.sh"; fi
golden_backend="${1:?usage: golden-update.sh <linux-gles|darwin-metal|darwin-gles-angle|win32-gles-angle> [case...]}"; shift
. tools/lib/golden-render.sh
case "$golden_backend" in
  linux-gles) [ "$(uname -s)" = Linux ] || { echo "linux-gles renders on linux" >&2; exit 2; } ;;
  darwin-*) [ "$(uname -s)" = Darwin ] || { echo "$golden_backend renders on darwin: run tools/golden-update.sh $golden_backend on the Mac itself" >&2; exit 2; } ;;
  win32-gles-angle) [ -n "${RNI_BIN:-}" ] || { echo "use --win" >&2; exit 2; } ;;
  *) echo "unknown backend $golden_backend" >&2; exit 2 ;;
esac
if [ -n "${RNI_BIN:-}" ]; then BIN="$RNI_BIN"
elif [ "$(uname -s)" = Darwin ]; then BIN="$ROOT/packages-engine/engine-darwin-arm64/bin/rn-impeller"
else BIN="$ROOT/packages-engine/engine-linux-x64/bin/rn-impeller"; fi
[ -x "$BIN" ] || { echo "no engine binary at $BIN" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
GDIR="$ROOT/tools/golden/$golden_backend"; DIFF="$ROOT/build/golden-diff/$golden_backend"
mkdir -p "$GDIR" "$DIFF" "$WORK/a" "$WORK/b"
golden_render_all "$WORK/a" "$@" | grep -v '^GOLDEN_SKIP' ; [ "${PIPESTATUS[0]}" = 0 ] || { echo "render failed" >&2; exit 1; }
golden_render_all "$WORK/b" "$@" >/dev/null || { echo "second render failed" >&2; exit 1; }
rc=0 changed=0
while IFS='|' read -r name bundle app w h url ss pct delta; do
  [ $# -eq 0 ] || [[ " $* " == *" $name "* ]] || continue
  [ -s "$WORK/a/$name.ppm" ] || continue
  read -r pct delta < <(golden_tolerance "$name" "$pct" "$delta")
  python3 tools/golden_compare.py topng "$WORK/b/$name.ppm" "$WORK/b/$name.png"
  python3 tools/golden_compare.py compare "$WORK/a/$name.ppm" "$WORK/b/$name.png" --pct "$pct" --delta "$delta" \
    --name "$golden_backend/$name (render 1 vs 2)" >/dev/null \
    || { echo "REFUSED $name: two renders disagree beyond tolerance (not reproducible on this backend)"; rc=1; continue; }
  if [ -f "$GDIR/$name.png" ]; then
    if python3 tools/golden_compare.py compare "$WORK/a/$name.ppm" "$GDIR/$name.png" --pct 0 --delta 0 \
         --name "$name" --diff "$DIFF/$name.update.png" >/dev/null; then
      rm -f "$DIFF/$name.update.png"; echo "unchanged $name"; continue
    fi
    echo "changed   $name (review $DIFF/$name.update.png)"; changed=$((changed + 1))
  else
    echo "new       $name"
  fi
  python3 tools/golden_compare.py topng "$WORK/a/$name.ppm" "$GDIR/$name.png"
done < <(golden_cases)
echo "golden-update $golden_backend: $changed changed; git diff --stat tools/golden/$golden_backend, then view the update images"
exit $rc
