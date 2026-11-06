#!/usr/bin/env python3
"""Make a "6-named" copy of the ffmpeg 8 libraries (tools/ci-video-ffmpeg8.sh, arm FM).

    ffmpeg_soname_swap.py <ffmpeg8 lib dir> <out dir>

Each of the five ffmpeg 8.0.1 libraries is copied to <out dir> under its ffmpeg
6.1 soname (libavutil.so.58, libavcodec.so.60, libavformat.so.60,
libswscale.so.7; libswresample keeps .so.6), and every 8 soname string in its
.dynstr (DT_SONAME, DT_NEEDED and the version-need file names) is rewritten in
place to the 6 one. The names have the same length, so nothing moves. The code
inside is untouched: avcodec_version() still reports major 62.

That is exactly "the ffmpeg 6 copy pointed at ffmpeg 8 libraries": the 6 copy's
dlopen succeeds and only the runtime major check can refuse it.
"""
import os
import struct
import sys

SWAP = {
    b"libavutil.so.60": b"libavutil.so.58",
    b"libavcodec.so.62": b"libavcodec.so.60",
    b"libavformat.so.62": b"libavformat.so.60",
    b"libswscale.so.9": b"libswscale.so.7",
}
FILES = {"libavutil.so.60": "libavutil.so.58", "libavcodec.so.62": "libavcodec.so.60",
         "libavformat.so.62": "libavformat.so.60", "libswscale.so.9": "libswscale.so.7",
         "libswresample.so.6": "libswresample.so.6"}


def dynstr_range(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a little-endian ELF64 file")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    def sec(i):
        name, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize)
        return name, typ, off, size
    _, _, stroff, _ = sec(shstrndx)
    for i in range(shnum):
        name, _, off, size = sec(i)
        end = data.index(b"\0", stroff + name)
        if data[stroff + name:end] == b".dynstr":
            return off, size
    raise SystemExit("no .dynstr section")


def swap(src, dst):
    data = bytearray(open(src, "rb").read())
    off, size = dynstr_range(data)
    table = bytes(data[off:off + size])
    count = 0
    for old, new in SWAP.items():
        assert len(old) == len(new)
        needle = b"\0" + old + b"\0"
        i = table.find(needle)
        while i >= 0:
            data[off + i + 1:off + i + 1 + len(new)] = new
            count += 1
            i = table.find(needle, i + 1)
    with open(dst, "wb") as f:
        f.write(data)
    os.chmod(dst, 0o755)
    return count


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    for src_name, dst_name in FILES.items():
        n = swap(os.path.realpath(os.path.join(src_dir, src_name)), os.path.join(out_dir, dst_name))
        if n == 0:
            raise SystemExit(f"{src_name}: no ffmpeg 8 soname found in .dynstr")
        print(f"  {src_name} -> {dst_name}: {n} soname string(s) rewritten")


if __name__ == "__main__":
    main()
