#!/usr/bin/env python3
"""Checks for tools/ci-webview.sh. Stdlib only.

  webview_check.py main   <engine.log> <req.log> <shot-a.ppm> <shot-scrolled.ppm>
  webview_check.py cookie <engine.log> <expect: sess=abc123 | none>
  webview_check.py nohelper <engine.log>
  webview_check.py helper-exit <engine.log> [tag]   (every run with a real helper)
Prints WEBVIEW_FAIL: <arm>: <why> and exits 1 on the first broken rule.
"""
import re
import sys


def bad(arm, msg):
    print("WEBVIEW_FAIL: %s: %s" % (arm, msg), file=sys.stderr)
    sys.exit(1)


def ppm(path):
    d = open(path, "rb").read()
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def px(img, x, y):
    w, _, data = img
    i = (y * w + x) * 3
    return tuple(data[i:i + 3])


def near(c, want, tol=14):
    return all(abs(a - b) <= tol for a, b in zip(c, want))


def apps(log):
    """WVAPP lines -> list of (t_ms, text)."""
    return [(int(t), s) for t, s in re.findall(r"^\[js\] WVAPP t=(\d+) (.*)$", log, re.M)]


def first(lines, pattern, after=0, arm="nav"):
    rx = re.compile(pattern)
    for i, (t, s) in enumerate(lines):
        if i >= after and rx.search(s):
            return i, t, s
    bad(arm, "no WVAPP line matching /%s/ after line %d" % (pattern, after))


def main_arm(log_path, req_path, shot_a, shot_s):
    log = open(log_path, errors="replace").read()
    # The first page's events come first: a missing one is the root cause of
    # any later stall (the fixture's own steps hang off them), so name it.
    L0 = apps(log)
    i0, _, _ = first(L0, r"^ev=loadStart url=\S+/a\.html loading=true back=false")
    first(L0, r'^ev=load url=\S+/a\.html loading=false .*title="WV-A"', i0)
    if "DRIVE_OK" not in log:
        drive = re.findall(r"^DRIVE.*$", log, re.M)
        bad("input", "driver did not finish: %s" % (drive[-1] if drive else "no DRIVE lines"))
    # Pixels as the X server shows them (window coords; the web view starts at y=40).
    a = ppm(shot_a)
    for name, (x, y), want in [("rn-bar", (300, 20), (255, 0, 0)), ("page-header", (300, 70), (30, 136, 229)),
                               ("hover-box", (470, 145), (142, 36, 170)), ("touch-zone", (100, 250), (251, 140, 0)),
                               ("link", (460, 245), (253, 216, 53)), ("page-bg", (580, 400), (38, 50, 56))]:
        if not near(px(a, x, y), want):
            bad("pixels", "%s at %d,%d is %s, wanted %s" % (name, x, y, px(a, x, y), want))
    s = ppm(shot_s)
    if near(px(s, 300, 70), (30, 136, 229)):
        bad("pixels", "page header still at the top after the wheel: the page did not move on screen")
    if not near(px(s, 470, 145), (142, 36, 170)):
        bad("pixels", "fixed hover box gone after scrolling: %s" % (px(s, 470, 145),))
    # Input, as the PAGE saw it.
    m = re.search(r"WVPAGE click (-?\d+) (-?\d+)", log)
    if not m or abs(int(m.group(1)) - 100) > 2 or abs(int(m.group(2)) - 105) > 2:
        bad("input", "click landed at page %s, wanted 100,105 (window 100,145; the 40 px RN bar shifts y only)" % (m.groups() if m else None,))
    if not re.search(r'^.*WVPAGE value "ab"$', log, re.M):
        bad("input", 'typed a b c Backspace, the input never read "ab"')
    m = re.search(r"WVPAGE touchend moves=(\d+) dx=(-?\d+)", log)
    if not m or int(m.group(1)) < 5 or not 200 <= int(m.group(2)) <= 230:
        bad("input", "drag was not ONE touch sequence of >=5 moves and dx~220: %s" % (m.groups() if m else None,))
    m = re.search(r"WVPAGE scrolly (\d+)", log)
    if not m or int(m.group(1)) <= 0:
        bad("input", "wheel down did not scroll the page down (scrollY %s)" % (m.group(1) if m else None))
    if not re.search(r"WVPAGE hover-enter", log) or not re.search(r"WVPAGE hover-leave", log):
        bad("input", "hover enter/leave missing")
    # Scripts.
    if "WVPAGE early 1" not in log:
        bad("scripts", "injectedJavaScriptBeforeContentLoaded did not run before the page's own script")
    # goBack restores a.html from the back/forward cache: no re-run there (as
    # in WKWebView). Initial load + reload = 2 runs on a, 1 on b.
    if len(re.findall(r"WVPAGE injected /a\.html", log)) != 2 or "WVPAGE injected /b.html" not in log:
        bad("scripts", "injectedJavaScript did not run after every loaded page (a x2, b x1)")
    # Headers: top-level request only.
    req = open(req_path).read().splitlines()
    if not req or req[0] != "REQ /a.html gate=token-123":
        bad("headers", "first request %r, wanted the header on /a.html" % (req[:1],))
    for path in ("/a.css", "/b.html", "/slow"):
        line = [r for r in req if r.startswith("REQ %s " % path)]
        if not line or not line[0].endswith("gate=-"):
            bad("headers", "%s: %r (the header must ride on the top-level request only)" % (path, line[:1]))
    # Events + nav methods, in order, as JS received them.
    L = apps(log)
    i, _, _ = first(L, r"^ev=loadStart url=\S+/a\.html loading=true back=false")
    i, _, _ = first(L, r'^ev=load url=\S+/a\.html loading=false .*title="WV-A"', i)
    i, _, _ = first(L, r"^ev=loadEnd url=\S+/a\.html", i)
    first(L, r'^ev=nav url=\S+/a\.html .*title="WV-A"', 0)
    i, _, _ = first(L, r"^ev=loadStart url=\S+/b\.html", i)  # target=_blank opened in THIS view
    i, _, _ = first(L, r"^ev=load url=\S+/b\.html .*back=true", i)
    if "WVPAGE b cookie=sess=abc123" not in log:
        bad("cookies", "cookie set on a.html is not visible on b.html (page change)")
    i, _, _ = first(L, r"^call goBack", i)
    i, _, _ = first(L, r"^ev=load url=\S+/a\.html .*fwd=true", i)
    i, _, _ = first(L, r"^call reload", i)
    i, _, _ = first(L, r"^ev=loadStart url=\S+/a\.html", i)
    i, _, _ = first(L, r"^ev=load url=\S+/a\.html", i)
    i, t_stop, _ = first(L, r"^call stopLoading", i)
    j, t_end, _ = first(L, r"^ev=loadEnd ", i)
    if t_end - t_stop > 2000:
        bad("nav", "stopLoading took %d ms to end the load (server answers after 8000)" % (t_end - t_stop))
    if any(re.search(r"^ev=load url=\S+/slow", s) for _, s in L):
        bad("nav", "the stopped page still fired onLoad")
    if any(s.startswith("ev=error") for _, s in L[i:j]):
        bad("nav", "stopLoading reported onError (a cancel is not an error)")
    i, _, s = first(L, r"^ev=error url=\S+/unreachable ", j, arm="error")
    if not re.search(r"code=-?\d+", s) or "code=0" in s:
        bad("error", "onError without a code: %s" % s)
    if any(re.search(r"^ev=load url=\S+/unreachable", x) for _, x in L):
        bad("error", "a failed load also fired onLoad (WebKit's error page leaked through)")
    first(L, r"^ev=loadEnd ", i, arm="error")  # url = the committed page, as after a stop
    first(L, r"^done", i)
    frames = re.findall(r"webview_destroy id=\d+ frames=(\d+)", log)
    if not frames or int(frames[0]) < 3:
        bad("frames", "web view painted %s frames" % (frames,))
    print("WEBVIEW main ok: pixels, hover, click@100,105, typing, drag-as-touch, wheel, "
          "early+end scripts, top-level headers, events, window.open same view, goBack, reload, "
          "stopLoading (%d ms), onError, %s frames" % (t_end - t_stop, frames[0]))


def cookie_arm(log_path, expect):
    log = open(log_path, errors="replace").read()
    m = re.search(r"WVPAGE b cookie=(\S+)", log)
    if not m or m.group(1) != expect:
        bad("cookies", "b.html read cookie %r, wanted %r" % (m.group(1) if m else None, expect))
    if expect == "none" and not re.search(r"WVAPP t=\d+ cleared", log):
        bad("cookies", "clearWebsiteData never resolved")
    print("WEBVIEW cookie ok: %s" % expect)


def nohelper_arm(log_path):
    log = open(log_path, errors="replace").read()
    if not re.search(r'WVAPP t=\d+ ev=error .*desc="web helper', log):
        bad("nohelper", "a missing helper did not reach onError")
    if not re.search(r"ENGINE_RC=0", log):
        bad("nohelper", "engine did not exit cleanly without a helper")
    print("WEBVIEW nohelper ok: onError reached JS, clean exit")


# glibc heap / stack aborts, and qemu-user's line for a guest that died on a signal.
ABORT_RE = (r"^.*(double free or corruption|free\(\): invalid|malloc\(\): |corrupted size vs|"
            r"corrupted double-linked|munmap_chunk\(\)|malloc_consolidate\(\)|"
            r"\*\*\* stack smashing detected|uncaught target signal|^Aborted).*$")


def helper_exit_arm(log_path, tag):
    """The helper must END cleanly, not just the engine. Every view the engine
    destroyed was destroyed in the helper too, then the engine reaped it with
    exit code 0 (no signal, no timeout, no hang-up needed), and no glibc abort
    reached the log. Before this rule a helper that aborted in its own teardown
    (a double free at view destroy) left every gate green: only ENGINE_RC was read."""
    arm = "helper-exit(%s)" % tag
    log = open(log_path, errors="replace").read()
    m = re.search(ABORT_RE, log, re.M)
    if m:
        bad(arm, "abort in the run: %r" % m.group(0)[:160])
    ex = re.findall(r"^rn-impeller: webview_helper_exit (.*)$", log, re.M)
    if len(ex) != 1:
        bad(arm, "%d webview_helper_exit lines, wanted 1 (the engine did not reap its helper)" % len(ex))
    if not re.match(r"pid=\d+ code=0 ms=\d+$", ex[0]):
        bad(arm, "the web helper did not exit cleanly: webview_helper_exit %s" % ex[0])
    eng = sorted(re.findall(r"^rn-impeller: webview_destroy id=(\d+)", log, re.M))
    hlp = sorted(re.findall(r"^rni-webhelper: view (\d+) destroyed", log, re.M))
    if not eng or eng != hlp:
        bad(arm, "views destroyed: engine %s, helper %s (each must reach the helper before it exits)"
            % (eng, hlp))
    print("WEBVIEW helper-exit ok (%s): %d view(s) destroyed in the helper, %s"
          % (tag, len(hlp), ex[0]))


if __name__ == "__main__":
    arm = sys.argv[1]
    if arm == "main":
        main_arm(*sys.argv[2:6])
    elif arm == "cookie":
        cookie_arm(sys.argv[2], sys.argv[3])
    elif arm == "nohelper":
        nohelper_arm(sys.argv[2])
    elif arm == "helper-exit":
        helper_exit_arm(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "run")
    else:
        bad("usage", arm)
