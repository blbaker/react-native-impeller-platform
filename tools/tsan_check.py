#!/usr/bin/env python3
"""FP-04: classify ThreadSanitizer reports written by tools/ci-tsan.sh.

usage: tsan_check.py <known.txt> <run-dir>...
Each run dir holds tsan.<pid> report files (TSAN_OPTIONS log_path). A report is
KNOWN only if it matches an entry of tools/sanitize/tsan_known.txt exactly (see
the matchers below); anything else is a FAIL. Each known entry must also be SEEN
at least once, so the list cannot keep a race that has been fixed.
Prints one line per run, then TSAN_CHECK_PASS or TSAN_CHECK_FAIL <reason>.
"""
import glob
import os
import re
import sys

SEP = "=================="
FRAME = re.compile(r"^\s+#(\d+) (\S+)")


def stacks(block):
    """Return {section header: [function names]} for the report's stacks."""
    out, cur = {}, None
    for line in block.splitlines():
        if re.match(r"^  \S", line):
            cur = line.strip()
            out[cur] = []
        elif cur is not None:
            m = FRAME.match(line)
            if m:
                out[cur].append(m.group(2))
    return out


def typography_context(block):
    """The single-thread typography context used from two threads (impeller.h).

    Both accesses must be the TsanAnnotate.h write, and the raced object must be
    the block ImpellerTypographyContextNew allocated."""
    st = stacks(block)
    access = [v for k, v in st.items() if re.match(r"(Previous )?(write|Write|read|Read) of size", k)]
    loc = [v for k, v in st.items() if k.startswith("Location is heap block")]
    return (len(access) == 2 and all(a and a[0].endswith("NoteExclusiveUse") for a in access)
            and len(loc) == 1 and any("ImpellerTypographyContextNew" in f for f in loc[0]))


MATCHERS = {"typography-context": typography_context}


def summary(block):
    """Kind + the first frame of the first stack that is not a TSan interceptor."""
    m = re.search(r"WARNING: ThreadSanitizer: ([a-z -]+)", block)
    kind = m.group(1).strip() if m else "report"
    if typography_context(block):
        # FP-12: name the defect, not the annotation frame both stacks start with.
        st = [v for k, v in stacks(block).items() if re.match(r"(Previous )?(write|Write|read|Read) of size", k)]
        callers = sorted({next((f for f in s[1:] if "NoteExclusiveUse" not in f), "?") for s in st})
        return f"typography-context race (one ImpellerTypographyContext used from two threads) in {' / '.join(callers)}"[:220]
    for line in block.splitlines():
        f = re.match(r"^\s+#\d+ (.*)", line)
        if f and not re.match(r"(__tsan_|__interceptor_|<null>|mem(set|cpy|move)|free|malloc|realloc|operator (new|delete))", f.group(1)):
            where = re.sub(r"\(BuildId[^)]*\)|\([^()]*\+0x[0-9a-f]+\)", "", f.group(1))
            return f"{kind} in {where.replace(os.getcwd() + '/', '').strip()}"[:220]
    return kind


def main():
    known_path, runs = sys.argv[1], sys.argv[2:]
    known = {}
    for line in open(known_path):
        line = line.split("#", 1)[0].split()
        if line:
            if line[0] not in MATCHERS:
                print(f"TSAN_CHECK_FAIL unknown entry '{line[0]}' in {known_path}")
                return 1
            known[line[0]] = line[1] if len(line) > 1 else "?"
    seen = {k: 0 for k in known}
    bad = []
    for run in runs:
        counts = {"known": 0, "new": 0}
        for f in sorted(glob.glob(os.path.join(run, "tsan.*"))):
            for block in open(f, errors="replace").read().split(SEP):
                if "WARNING: ThreadSanitizer" not in block:
                    continue
                hit = [k for k in known if MATCHERS[k](block)]
                if hit:
                    seen[hit[0]] += 1
                    counts["known"] += 1
                else:
                    counts["new"] += 1
                    bad.append((os.path.basename(run), summary(block), f))
        print(f"run {os.path.basename(run)}: new={counts['new']} known={counts['known']}")
    for k, n in seen.items():
        print(f"known {k} (fix owned by {known[k]}): seen={n}")
    if bad:
        for run, s, f in bad[:8]:
            print(f"  NEW [{run}] {s}  ({f})")
        print(f"TSAN_CHECK_FAIL {len(bad)} race report(s) outside tsan_known.txt; first: {bad[0][1]}")
        return 1
    stale = [k for k, n in seen.items() if n == 0]
    if stale:
        print(f"TSAN_CHECK_FAIL known race '{stale[0]}' was not seen: fixed? remove it from {known_path}")
        return 1
    print(f"TSAN_CHECK_PASS ({len(runs)} runs, 0 new reports)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
