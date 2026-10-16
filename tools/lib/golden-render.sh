#!/usr/bin/env bash
# golden-render.sh (FP-51): render every tools/golden/cases.txt case headless on one backend.
# Sourced by ci-golden.sh and golden-update.sh. Needs ROOT, BIN, and golden_backend set.
#   golden_backends_for_host   linux-gles | darwin-metal darwin-gles-angle
#   golden_render_all OUTDIR [case...]   writes OUTDIR/<case>.ppm; echoes SKIP lines; returns 1 on a failed run
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-timeout.sh"

golden_backends_for_host() {
  case "$(uname -s)" in Linux) echo linux-gles ;; Darwin) echo darwin-metal darwin-gles-angle ;; *) echo "" ;; esac
}

golden_cases() {  # case lines without comments
  grep -vE '^(#|$)' "$ROOT/tools/golden/cases.txt"
}

golden_write_input_png() {  # deterministic 120x80 PNG used by the images case
  python3 - "$1" <<'PY'
import struct, sys, zlib
w, h = 120, 80
raw = b"".join(b"\0" + bytes(v for x in range(w) for v in ((x * 255) // w, (y * 255) // h, ((x ^ y) & 31) * 8))
               for y in range(h))
def ch(t, b):
    c = struct.pack(">I", len(b)) + t + b
    return c + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY
}

golden_render_all() {
  local out="$1"; shift
  local want=" $* " rc=0 name bundle app w h url ss pct delta extra
  mkdir -p "$out/in"
  golden_write_input_png "$out/in/a.png"
  while IFS='|' read -r name bundle app w h url ss pct delta; do
    [ $# -eq 0 ] || [[ "$want" == *" $name "* ]] || continue
    url="${url//@WORK@/$out/in}"
    if [ "$golden_backend" = win32-gles-angle ] && [[ "$url" == *"$out/in"* ]]; then
      echo "GOLDEN_SKIP $name: file:// inputs are WSL paths the Windows exe cannot open"; continue
    fi
    extra=()
    [ -z "$url" ] || extra+=(--initial-url "$url")
    [ "$golden_backend" != darwin-metal ] || extra+=(--backend metal --frames 2)
    ( cd "$(dirname "$BIN")" && timeout 180 "$BIN" --headless --probe-banner off --supersample-rnsvg "$ss" \
        --bundle "$ROOT/$bundle" --app-name "$app" --width "$w" --height "$h" "${extra[@]}" \
        --screenshot "$out/$name.ppm" ) < /dev/null > "$out/$name.log" 2>&1 || { echo "GOLDEN_FAIL $name: engine exit $? ($(tail -1 "$out/$name.log"))"; rc=1; continue; }
    grep -qE '^rn-impeller: scene_nodes=[1-9]' "$out/$name.log" || { echo "GOLDEN_FAIL $name: nothing mounted"; rc=1; }
    [ -s "$out/$name.ppm" ] || { echo "GOLDEN_FAIL $name: no screenshot"; rc=1; }
  done < <(golden_cases)
  return $rc
}

golden_tolerance() {  # case default_pct default_delta -> "pct delta" honouring the backend override file
  local f="$ROOT/tools/golden/$golden_backend/tolerance.txt" line
  if [ -f "$f" ] && line="$(grep -E "^$1\|" "$f" | head -1)" && [ -n "$line" ]; then
    echo "$(echo "$line" | cut -d'|' -f2) $(echo "$line" | cut -d'|' -f3)"
  else
    echo "$2 $3"
  fi
}
