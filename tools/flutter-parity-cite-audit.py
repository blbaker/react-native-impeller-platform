#!/usr/bin/env python3
"""Audit + linkify citations in the research sections.

[F:path:La-b] / [F:path#La-Lb]  -> flutter/flutter @ PIN (local: sc32 checkout, HEAD content)
[R:path:La]                     -> blbaker/react-native-impeller @ RSHA (local: rni-merge-main)
[RN:path:La-b]                  -> facebook/react-native v0.86.2 (local: node_modules/react-native/ReactCommon)
Usage: cite_audit.py audit <files...>      (prints stats + broken list, exit 1 if broken)
       cite_audit.py linkify <in> <out>
"""
import os, re, subprocess, sys, functools

PIN = "114eb184d66d7ca136d89eb8ec09f61aff265062"
RSHA = "c07048d6017838d858f826eb89b373343cd22f37"
FL = os.path.expanduser("~/projects/_ref/sc32/flutter")
RR = os.path.expanduser("a local worktree")
RNR = os.path.join(RR, "engine/rn/node_modules/react-native")

BR = re.compile(r"\[((?:F|R|RN):[^\]]+)\]")
ONE = re.compile(r"(F|R|RN):\s*([^\s;:#,\]()]+)(?:[:#]L?(\d+)(?:-L?(\d+))?((?:,L?\d+(?:-L?\d+)?)*))?")


@functools.lru_cache(maxsize=None)
def flutter_files():
    out = subprocess.run(["git", "-C", FL, "ls-files", "engine/src/flutter", "docs"],
                         capture_output=True, text=True).stdout.split("\n")
    return [p for p in out if p]


@functools.lru_cache(maxsize=None)
def flines(rel):
    r = subprocess.run(["git", "-C", FL, "show", f"HEAD:{rel}"], capture_output=True)
    return r.stdout.count(b"\n") + 1 if r.returncode == 0 else None


def resolve(kind, path):
    """Return (repo-relative path, line count) or (None, None)."""
    path = path.rstrip(".")
    if kind == "F":
        if "..." in path or "…" in path:
            suf = re.split(r"\.\.\.|…", path)[-1].lstrip("/")
            hits = [p for p in flutter_files() if p.endswith("/" + suf) or p == suf]
            if len(hits) == 1:
                return hits[0], flines(hits[0])
            return None, None
        for cand in (path, "engine/src/flutter/" + path, path.replace("engine/src/flutter/", "", 1)):
            n = flines(cand)
            if n:
                return cand, n
            d = cand.rstrip("/") + "/"
            if any(p.startswith(d) for p in flutter_files()) or subprocess.run(["git", "-C", FL, "cat-file", "-e", "HEAD:" + cand.rstrip("/")], capture_output=True).returncode == 0:
                return cand, 10**9
        return None, None
    root = RR if kind == "R" else RNR
    for cand in (path, "ReactCommon/" + path) if kind == "RN" else (path,):
        p = os.path.join(root, cand)
        if os.path.isfile(p):
            with open(p, "rb") as fh:
                return cand, fh.read().count(b"\n") + 1
    if kind == "R" and os.path.isdir(os.path.join(RR, path)):
        return path, 10**9
    if kind == "R":  # tolerate engine/ omitted
        p = os.path.join(RR, "engine", path)
        if os.path.isfile(p):
            with open(p, "rb") as fh:
                return "engine/" + path, fh.read().count(b"\n") + 1
    return None, None


def url(kind, rel, a, b):
    frag = f"#L{a}" + (f"-L{b}" if b and b != a else "") if a else ""
    if kind == "F":
        return f"https://github.com/flutter/flutter/blob/{PIN}/{rel}{frag}"
    if kind == "R":
        return f"https://github.com/blbaker/react-native-impeller-platform/blob/{RSHA}/{rel}{frag}"
    return f"https://github.com/facebook/react-native/blob/v0.86.2/packages/react-native/{rel}{frag}"


def check(text):
    ok, bad = 0, []
    for m in BR.finditer(text):
        for part in re.split(r";\s*", m.group(1)):
            mm = ONE.match(part.strip())
            if not mm:
                continue
            kind, path, a, b, extra = mm.groups()
            if " " in part.strip() and "(" in part:  # e.g. "(file listing)"
                path = path
            rel, n = resolve(kind, path)
            lines = [int(x) for x in re.findall(r"\d+", (a or "") + " " + (b or "") + " " + (extra or ""))]
            if rel is None:
                bad.append(f"MISSING {kind}:{path}")
            elif lines and max(lines) > n:
                bad.append(f"PAST_EOF {kind}:{rel} L{max(lines)} > {n}")
            else:
                ok += 1
    return ok, bad


def linkify(text):
    def rep(m):
        parts = re.split(r";\s*", m.group(1))
        outs = []
        for part in parts:
            mm = ONE.match(part.strip())
            if not mm:
                outs.append(part)
                continue
            kind, path, a, b, _ = mm.groups()
            rel, n = resolve(kind, path)
            label = part.strip()
            if rel:
                outs.append(f"[{label}]({url(kind, rel, a, b)})")
            else:
                outs.append(label)
        return "[" + "; ".join(outs) + "]"
    return BR.sub(rep, text)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "audit":
        tot_ok, tot_bad = 0, []
        for f in sys.argv[2:]:
            ok, bad = check(open(f).read())
            tot_ok += ok
            tot_bad += [f"{os.path.basename(f)}: {x}" for x in bad]
            print(f"{os.path.basename(f)}: ok={ok} bad={len(bad)}")
        for x in tot_bad:
            print("  ", x)
        print(f"TOTAL ok={tot_ok} bad={len(tot_bad)}")
        sys.exit(1 if tot_bad else 0)
    elif cmd == "linkify":
        open(sys.argv[3], "w").write(linkify(open(sys.argv[2]).read()))
