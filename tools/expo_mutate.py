#!/usr/bin/env python3
"""expo_mutate.py <file> <old> <new> — replace exactly one occurrence (mutation-verify-expo-host.sh)."""
import sys

path, old, new = sys.argv[1:4]
dry = '--dry' in sys.argv[4:]
with open(path) as f:
    src = f.read()
n = src.count(old)
if n != 1:
    sys.stderr.write('anchor found %dx in %s: %r\n' % (n, path, old[:120]))
    sys.exit(1)
if dry:
    sys.exit(0)
with open(path, 'w') as f:
    f.write(src.replace(old, new))
