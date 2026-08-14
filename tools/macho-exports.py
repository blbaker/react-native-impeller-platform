#!/usr/bin/env python3
"""Read a Mach-O dylib's LC_DYLD_INFO(_ONLY)/LC_DYLD_EXPORTS_TRIE export trie.

Linux binutils cannot parse Mach-O at all ("file format not recognized"), and a
`strings` hit only proves the bytes appear somewhere in the file -- not that the
symbol is EXPORTED. This walks the real export trie.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_SEGMENT_64 = 0x19


def uleb(buf, i):
    r = 0
    s = 0
    while True:
        b = buf[i]
        i += 1
        r |= (b & 0x7F) << s
        if not b & 0x80:
            return r, i
        s += 7


def walk(buf, off, prefix, out):
    term_size, i = uleb(buf, off)
    if term_size:
        flags, j = uleb(buf, i)
        out.append((prefix, flags))
    i += term_size
    nchild = buf[i]
    i += 1
    for _ in range(nchild):
        end = buf.index(b"\x00", i)
        name = buf[i:end].decode()
        i = end + 1
        child, i = uleb(buf, i)
        walk(buf, child, prefix + name, out)


def main(path):
    d = open(path, "rb").read()
    magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", d, 0)
    if magic != MH_MAGIC_64:
        sys.exit(f"not a 64-bit Mach-O (magic={magic:#x})")
    arch = {0x0100000C: "arm64", 0x01000007: "x86_64"}.get(cputype, str(cputype))
    o = 32
    trie_off = trie_size = 0
    linkedit_off = linkedit_vmoff = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, o)
        if cmd == LC_SEGMENT_64:
            segname = d[o + 8:o + 24].rstrip(b"\x00").decode()
            if segname == "__LINKEDIT":
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, o + 24)
                linkedit_off, linkedit_vmoff = fileoff, vmaddr
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            trie_off, trie_size = struct.unpack_from("<II", d, o + 40)
        elif cmd == LC_DYLD_EXPORTS_TRIE:
            trie_off, trie_size = struct.unpack_from("<II", d, o + 8)
        o += size
    if not trie_size:
        sys.exit("no export trie found")
    buf = d[trie_off:trie_off + trie_size]
    out = []
    walk(buf, 0, "", out)
    print(f"ARCH={arch} EXPORTS={len(out)} trie_off={trie_off} trie_size={trie_size}")
    return out


if __name__ == "__main__":
    syms = main(sys.argv[1])
    names = {n for n, _ in syms}
    if len(sys.argv) > 2:
        for want in sys.argv[2:]:
            for cand in (want, "_" + want):
                if cand in names:
                    print(f"EXPORTED   {want}")
                    break
            else:
                print(f"ABSENT     {want}")
    else:
        for n, f in sorted(syms):
            print(n)
