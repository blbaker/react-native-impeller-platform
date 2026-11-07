#!/usr/bin/env bash
# Mutation check for the linux package NEEDED contract (linux matrix M1):
# tools/engine-build-linux.sh refuses a package whose rn-impeller NEEDs Xlib,
# desktop libGL or libmali, or lacks libEGL.so.1 / libGLESv2.so.2. The build
# runs the same check_needed function that `--check-needed <elf>` runs, so
# each mutant here goes through the code path the build uses.
#
# Mutants are the REAL staged binaries with one DT_NEEDED string rewritten in
# place in .dynstr (same offset, NUL-padded), so readelf reports exactly the
# library a regressed build would carry:
#   M1 libwayland-client.so.0 -> libX11.so.6     (Xlib hard-linked again)
#   M2 libwayland-client.so.0 -> libGL.so.1      (desktop GL)
#   M3 libwayland-client.so.0 -> libmali.so.1    (vendor blob linked by name)
#   M4 libEGL.so.1            -> libEGX.so.1     (EGL soname missing)
#   M5 libwayland-client.so.0 -> libavcodec.so.62 (ffmpeg linked by name)
# plus, when PRE_M1_BIN points at one, the pre-M1 x64 rn-impeller, a real
# build without RNI_X11_DLOPEN that NEEDs libX11.so.6.
# Control: each pristine package must pass. Every mutant must FAIL, and fail
# for its own reason (the reason text is matched, not just the exit code).
#
# Usage: bash tools/mutation-verify-linux-needed.sh   [PRE_M1_BIN=<old rn-impeller>]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
check() { bash tools/engine-build-linux.sh --check-needed "$1" 2>&1; }
expect_ok() {  # $1 label, $2 elf
  local out; out="$(check "$2")"; ran=$((ran + 1))
  if grep -q '^NEEDED_OK$' <<< "$out"; then echo "   control $1: NEEDED_OK"
  else echo "   control $1: WRONG, a pristine package failed"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1)); fi
}
expect_killed() {  # $1 label, $2 elf, $3 ERE the failure must name
  local out; out="$(check "$2")"; ran=$((ran + 1))
  if ! grep -q '^NEEDED_FAIL$' <<< "$out"; then
    echo "   $1: SURVIVED (check passed a broken package)"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1))
  elif ! grep -qE "$3" <<< "$out"; then
    echo "   $1: killed, but not for the expected reason /$3/"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1))
  else echo "   $1: killed ($(grep -o 'contract broken:.*' <<< "$out"))"; fi
}
mutate() {  # $1 src, $2 dst, $3 old soname, $4 new soname (len(new) <= len(old))
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3].encode(), sys.argv[4].encode()
data = bytearray(open(src, 'rb').read())
assert data[:4] == b'\x7fELF' and data[4] == 2 and data[5] == 1, 'not a 64-bit LE ELF'
# Only .dynstr: the same sonames also sit in .rodata as dlopen() names (GLFW
# loads libwayland-client.so.0 / libEGL.so.1 itself), and those must not move.
shoff, = struct.unpack_from('<Q', data, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
def sh(i):
    name, _, _, _, off, size = struct.unpack_from('<IIQQQQ', data, shoff + i * shentsize)
    return name, off, size
_, stroff, _ = sh(shstrndx)
lo = hi = None
for i in range(shnum):
    name, off, size = sh(i)
    if data[stroff + name:stroff + name + 8] == b'.dynstr\x00':
        lo, hi = off, off + size
assert lo is not None, 'no .dynstr section'
needle = b'\x00' + old + b'\x00'
n = data.count(needle, lo, hi)
assert n == 1, f'{old!r} appears {n}x in .dynstr of {src}'
assert len(new) <= len(old)
i = data.index(needle, lo, hi) + 1
data[i:i + len(old)] = new + b'\x00' * (len(old) - len(new))
open(dst, 'wb').write(bytes(data))
PY
}

for arch in x64 arm64; do
  BIN="$ROOT/packages-engine/engine-linux-$arch/bin/rn-impeller"
  [ -f "$BIN" ] || { echo "== linux-$arch: no package at $BIN (skipped)"; continue; }
  echo "== linux-$arch ($BIN)"
  expect_ok "$arch" "$BIN"
  mutate "$BIN" "$W/$arch-m1" libwayland-client.so.0 libX11.so.6 && expect_killed "M1 $arch libX11" "$W/$arch-m1" 'libX11\.so\.6\(Xlib'
  mutate "$BIN" "$W/$arch-m2" libwayland-client.so.0 libGL.so.1 && expect_killed "M2 $arch libGL" "$W/$arch-m2" 'libGL\.so\.1\(desktop GL'
  mutate "$BIN" "$W/$arch-m3" libwayland-client.so.0 libmali.so.1 && expect_killed "M3 $arch libmali" "$W/$arch-m3" 'libmali\.so\.1\(vendor blob'
  mutate "$BIN" "$W/$arch-m4" libEGL.so.1 libEGX.so.1 && expect_killed "M4 $arch no EGL" "$W/$arch-m4" 'no-libEGL\.so\.1'
  mutate "$BIN" "$W/$arch-m5" libwayland-client.so.0 libavcodec.so.62 && expect_killed "M5 $arch libavcodec" "$W/$arch-m5" 'libavcodec\.so\.62\(ffmpeg by name'
done
if [ -n "${PRE_M1_BIN:-}" ]; then
  echo "== pre-M1 x64 binary ($PRE_M1_BIN)"
  expect_killed "M5 pre-M1 x64" "$PRE_M1_BIN" 'libX11\.so\.6\(Xlib'
fi
[ "$ran" -ge 5 ] || { echo "LINUX_NEEDED_MUTATION_FAIL: only $ran checks ran (no packages staged?)"; exit 1; }
if [ "$fails" -eq 0 ]; then echo "LINUX_NEEDED_MUTATION_PASS ($ran checks: controls pass, every mutant killed for its own reason)"; exit 0; fi
echo "LINUX_NEEDED_MUTATION_FAIL ($fails of $ran wrong)"; exit 1
