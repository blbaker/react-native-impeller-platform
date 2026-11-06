#!/usr/bin/env python3
"""Rewrite an ELF64 file's DT_RPATH / DT_RUNPATH string in place.

    elf_set_rpath.py <elf file> <new path>      e.g. '$ORIGIN'

Used by tools/package-engine-linux.sh: rni-webhelper is linked with
the cross build's WPE prefix (/opt/rni-wpe/lib) as its rpath, and the package
ships it with $ORIGIN instead, so no build-machine path reaches the image. The
new string must not be longer than the old one; the rest of the old string is
zeroed, so nothing in the file moves. No patchelf on this host. Exit 1 when the
file has no rpath, the new one is too long, or the file is not ELF64 LE.
"""
import struct
import sys

DT_NULL, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 5, 15, 29


def main(path, new):
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        sys.exit(f"elf_set_rpath: {path} is not ELF64 little-endian")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    sections = []
    for i in range(shnum):
        o = shoff + i * shentsize
        _name, stype, _flags, addr, off, size, link = struct.unpack_from("<IIQQQQI", data, o)
        sections.append((stype, addr, off, size, link))
    dyn = [s for s in sections if s[0] == 6]  # SHT_DYNAMIC
    if len(dyn) != 1:
        sys.exit(f"elf_set_rpath: {path}: {len(dyn)} dynamic sections")
    _t, _a, doff, dsize, dlink = dyn[0]
    strtab_off = sections[dlink][2]
    hits = []
    for o in range(doff, doff + dsize, 16):
        tag, val = struct.unpack_from("<qQ", data, o)
        if tag == DT_NULL:
            break
        if tag in (DT_RPATH, DT_RUNPATH):
            hits.append((tag, val))
    if not hits:
        sys.exit(f"elf_set_rpath: {path} has no DT_RPATH/DT_RUNPATH")
    enc = new.encode()
    for tag, val in hits:
        start = strtab_off + val
        end = data.index(b"\0", start)
        old = bytes(data[start:end])
        if len(enc) > len(old):
            sys.exit(f"elf_set_rpath: '{new}' is longer than the old rpath '{old.decode()}'")
        data[start:end] = enc + b"\0" * (len(old) - len(enc))
        print(f"elf_set_rpath: {path}: {'RUNPATH' if tag == DT_RUNPATH else 'RPATH'} "
              f"'{old.decode()}' -> '{new}'")
    open(path, "wb").write(data)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
