#!/usr/bin/env python3
"""EME check for tools/ci-webview.sh (x64) and tools/ci-webview-arm64.sh (stdlib only).

  webview_eme_check.py <run-dir> <PLAYING|NOT_PLAYING|ANY> <fixed|none|reject|off> <pin-sha256|-> [<reject-sha256>]

<run-dir> holds engine.out (the engine's log; its "screenshot=" lines name the
ENGINE's own --screenshot-series readbacks, glReadPixels before the swap) and,
for the arm64 provenance modes, session.sh's maps-loaded.txt, maps-after.txt, ps.txt.
EME_CHECK_TAG=WEBVIEW (x64) or WEBVIEW_ARM64 (default) prefixes every line.

Verdict (the x64 eme rule, tools/webview_check.py, on engine readbacks taken 2 s
apart instead of 400 ms): PLAYING needs ALL of a Widevine key system, a licence on
the page, >= 6 engine captures, the first capture at t >= 120 s (the page starts
mid-film, far past any clear lead), the page clock advancing >= 7 s from the first
capture to the last (7 gaps of 2 s = 14 s nominal), real detail in the player rect
(median luma stddev >= 10) and sustained motion (>= 60% of capture pairs with
>= 15% of the rect's pixels changing by > 8). Measured on qemu: real playback
25-85% per pair and 18 s of clock; skip-decrypt 1 pair of 7 and detail 5; a burst
of 8 captures (mutant S) at most 8% per pair and 2.1 s of clock.
Anything else is NOT_PLAYING; the arm asserts the EXACT verdict.

Provenance (/proc/<pid>/maps of every process in the container, dumped by
session.sh once the CDM is in use and again after the last capture):
  fixed   every libwidevinecdm mapping is ONE file, its inode matches, its sha256
          is <pin-sha256> (the Asahi-fixed lacros 4.10.2662.3), and the process
          mapping it descends from rni-webhelper; the shim logged that version
  none    no libwidevinecdm is mapped at all
  reject  a CDM IS mapped, its sha256 is <reject-sha256> (Google's 4.10.3112.0),
          and the fixed-file rule above REJECTS it
  off     x64: no maps (the helper runs in docker); the shim's version line is reported
With fixed/off, PLAYING also needs the shim's own "license update accepted" and
"decrypt ok" lines and no "decrypt FAIL".
Prints <TAG>_FAIL: eme: <why> and exits 1 on the first broken rule.
"""
import hashlib
import os
import re
import sys
from typing import NoReturn

RECT = (20, 112, 580, 348)  # player rect in the 600x420 window (RN bar 0..40)
MIN_CLOCK_S, MIN_PAIR_MOVE = 7.0, 0.15
FIXED_VERSION = "4.10.2662.3"
TAG = os.environ.get("EME_CHECK_TAG", "WEBVIEW_ARM64")


def bad(msg) -> NoReturn:
    print("%s_FAIL: eme: %s" % (TAG, msg), file=sys.stderr)
    sys.exit(1)


def luma_rect(path):
    d = open(path, "rb").read()
    parts = d.split(b"\n", 3)
    if parts[0] != b"P6":
        bad("%s is not a P6 ppm" % path)
    w, h = map(int, parts[1].split())
    if (w, h) != (600, 420):
        bad("engine readback %s is %dx%d, wanted 600x420" % (path, w, h))
    px = parts[3]
    x0, y0, x1, y1 = RECT
    out = bytearray()
    for y in range(y0, y1):
        row = px[(y * w + x0) * 3:(y * w + x1) * 3]
        out += bytes((row[i] * 77 + row[i + 1] * 150 + row[i + 2] * 29) >> 8 for i in range(0, len(row), 3))
    return out


def stddev(a):
    m = sum(a) / len(a)
    return (sum((v - m) ** 2 for v in a) / len(a)) ** 0.5


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def maps_rows(path):
    try:
        lines = open(path).read().split("\n")
    except OSError:
        return None
    rows = []
    for ln in lines:
        m = re.match(r"pid=(\d+) ppid=(\d*) comm=(.*) inode=(\d+) path=(\S+)$", ln)
        if m:
            rows.append(m.groups())
    return rows


def ancestry(pid, ps):
    chain, seen = [], set()
    while pid in ps and pid not in seen:
        seen.add(pid)
        ppid, comm = ps[pid]
        chain.append(comm)
        pid = ppid
    return chain


def provenance(run, mode, pin, reject_sha):
    """-> (ok, text). ok is the FIXED-file rule's answer; mode decides what passes."""
    ps = {}
    ps_path = os.path.join(run, "ps.txt")
    for ln in (open(ps_path).read().split("\n") if os.path.exists(ps_path) else []):
        m = re.match(r"pid=(\d+) ppid=(\d*) comm=(.*)$", ln)
        if m:
            ps[m.group(1)] = (m.group(2), m.group(3))
    texts, verdicts = [], []
    for name in ("maps-loaded.txt", "maps-after.txt"):
        rows = maps_rows(os.path.join(run, name))
        if rows is None:
            bad("provenance: %s was never written (the sequencer did not reach it)" % name)
        files = sorted({(r[3], r[4]) for r in rows})
        if mode == "none":
            if rows:
                bad("provenance: no CDM was configured, yet %s maps %s" % (name, files))
            texts.append("%s: no libwidevinecdm mapped" % name)
            continue
        if not rows:
            bad("provenance: %s: no process maps a libwidevinecdm (the CDM never loaded)" % name)
        if len(files) != 1:
            bad("provenance: %s: %d distinct CDM files mapped: %s" % (name, len(files), files))
        inode, path = files[0]
        if not os.path.exists(path):
            bad("provenance: mapped path %s is not reachable from the host (mount it at the same path)" % path)
        got, ino = sha256(path), str(os.stat(path).st_ino)
        procs = sorted({"%s(%s)" % (r[2], r[0]) for r in rows})
        tree = [ancestry(r[0], ps) for r in rows]
        in_helper = all("rni-webhelper" in t for t in tree)
        ok = got == pin and ino == inode and in_helper
        verdicts.append(ok)
        texts.append("%s: %s inode %s sha %s mapped by %s (ancestry %s)%s" % (
            name, path, inode, got[:16], ",".join(procs), ">".join(tree[0][:4]),
            "" if ok else " -> REJECTED (%s)" % ", ".join(
                w for w, c in (("sha != pin %s" % pin[:16], got != pin), ("inode %s != %s" % (inode, ino), ino != inode),
                               ("not under rni-webhelper", not in_helper)) if c)))
        if mode == "reject" and got != reject_sha:
            bad("provenance: the reject arm must map Google's 3112 (sha %s), it mapped %s" % (reject_sha[:16], got[:16]))
    return (all(verdicts) if verdicts else False), "; ".join(texts)


def main():
    run, expect, mode, pin = sys.argv[1:5]
    reject_sha = sys.argv[5] if len(sys.argv) > 5 else ""
    log = open(os.path.join(run, "engine.out"), errors="replace").read()
    if "webview_create" not in log:
        bad("no web view was created")
    shots = [(m.start(), m.group(1)) for m in re.finditer(r"^rn-impeller: screenshot=(\S+) frame=", log, re.M)]
    ticks = [(m.start(), float(m.group(1))) for m in re.finditer(r"WVEME tick t=([\d.]+)", log)]

    def clock(off):
        before = [t for o, t in ticks if o < off]
        return before[-1] if before else 0.0
    ks = re.search(r"WVEME keysystem (\S+)", log)
    lic = re.findall(r"WVEME license (\d+)", log)
    fails = re.findall(r"WVEME (fail .*|keysystem-fail .*)$", log, re.M)
    lumas = [luma_rect(p) for _, p in shots]
    detail = [round(stddev(f), 1) for f in lumas]
    n = len(lumas[0]) if lumas else 1
    moving = [round(sum(1 for a, b in zip(p, q) if abs(a - b) > 8) / n, 3) for p, q in zip(lumas, lumas[1:])]
    det = sorted(detail)[len(detail) // 2] if detail else 0.0
    mov = sum(1 for x in moving if x >= MIN_PAIR_MOVE) / max(1, len(moving))
    t0 = clock(shots[0][0]) if shots else 0.0
    t1 = clock(shots[-1][0] + 1) if shots else 0.0  # the clock AT the last capture
    t_end = ticks[-1][1] if ticks else 0.0           # reported only, never judged
    playing = bool(ks and ks.group(1) == "com.widevine.alpha" and lic and len(shots) >= 6 and t0 >= 120
                   and t1 - t0 >= MIN_CLOCK_S and det >= 10 and mov >= 0.6)
    verdict = "PLAYING" if playing else "NOT_PLAYING"
    vers = sorted(set(re.findall(r"ocdm-shim: loaded Widevine CDM (\S+)", log)))
    dec_ok = [int(c) for c in re.findall(r"ocdm-shim: decrypt ok count=(\d+)", log)]
    dec_fail = len(re.findall(r"ocdm-shim: decrypt FAIL", log))
    accepted = len(re.findall(r"ocdm-shim: license update accepted", log))
    frames = re.findall(r"webview_frame id=\d+ n=(\d+)", log)
    summary = ("keysystem=%s licences=%d shim_licence_accepted=%d cdm=%s decrypt_ok>=%s decrypt_fail=%d "
               "captures=%d t=%.1f->%.1f(end %.1f) detail=%s moving=%s webview_frames>=%s fails=%s" % (
                   ks.group(1) if ks else None, len(lic), accepted, ",".join(vers) or "none",
                   max(dec_ok) if dec_ok else 0, dec_fail, len(shots), t0, t1, t_end, detail, moving,
                   frames[-1] if frames else 0, fails[:2]))
    print("%s eme measured: %s" % (TAG, summary))
    if expect != "ANY" and verdict != expect:
        bad("verdict %s, wanted %s: %s" % (verdict, expect, summary))
    if mode == "off":
        ok, prov = True, "not checked on this arch (the shim reports CDM %s)" % (",".join(vers) or "none")
    else:
        ok, prov = provenance(run, mode, pin, reject_sha)
    if mode == "fixed":
        if not ok:
            bad("provenance: the CDM in use is not the Asahi-fixed lacros file: " + prov)
        if vers != [FIXED_VERSION]:
            bad("provenance: the shim loaded CDM version %s, wanted exactly %s" % (vers, FIXED_VERSION))
    elif mode == "reject" and ok:
        bad("provenance ACCEPTED Google's 3112: " + prov)
    if mode in ("fixed", "off") and verdict == "PLAYING" and (not accepted or not dec_ok or dec_fail):
        bad("PLAYING without the shim's licence/decrypt lines (accepted=%d ok=%s fail=%d)" % (
            accepted, dec_ok[-1:], dec_fail))
    print("%s eme ok: %s, provenance %s: %s" % (
        TAG, verdict, {"fixed": "Asahi-fixed lacros " + FIXED_VERSION, "none": "no CDM",
                       "reject": "REJECTED as required", "off": "off"}[mode], prov))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        bad("usage: see the docstring")
    main()
