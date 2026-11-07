#!/usr/bin/env python3
"""Checks for tools/ci-webview-arm64.sh (stdlib only).

  webview_arm64_check.py pixels <engine.out> <shot.ppm>
  webview_arm64_check.py touch  <engine.out> <weston.log>

pixels: the frame the ENGINE read back (--screenshot, glReadPixels before the
  swap) holds the page's flat colours EXACTLY (tolerance 0) under the 40 px RN
  bar, at the page's own blocks (fixtures/webview-arm64/pages/a.html).
touch: wl_touch taps injected into Weston reach the page through the engine
  (WaylandTouch -> WebViewInput -> rni-webhelper -> WPE touch): the tap on the
  RN bar reaches NO page; the tap at window 100,145 is a page touchstart AND a
  click at page 100,105 on #btn (the bar shifts y by 40, x not at all).
Prints WEBVIEW_ARM64_FAIL: <arm>: <why> and exits 1 on the first broken rule.
"""
import re
import sys

# window coords (600x420, RN bar 0..40) -> exact RGB
POINTS = [
    ("rn-bar", (300, 20), (255, 0, 0)),
    ("page-header", (300, 70), (30, 136, 229)),     # #hdr  page y 0..60
    ("btn", (100, 145), (67, 160, 71)),             # #btn  page 20..180 x 80..130
    ("hov", (470, 145), (142, 36, 170)),            # #hov
    ("touch-zone", (100, 250), (251, 140, 0)),      # #tz
    ("link", (460, 245), (253, 216, 53)),           # #lnk
    ("page-bg", (580, 400), (38, 50, 56)),          # body
]


def bad(arm, msg):
    print("WEBVIEW_ARM64_FAIL: %s: %s" % (arm, msg), file=sys.stderr)
    sys.exit(1)


def ppm(path):
    d = open(path, "rb").read()
    parts = d.split(b"\n", 3)
    if parts[0] != b"P6":
        bad("pixels", "%s is not a P6 ppm" % path)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def px(img, x, y):
    w, _, data = img
    i = (y * w + x) * 3
    return tuple(data[i:i + 3])


def pixels(log_path, shot):
    log = open(log_path, errors="replace").read()
    m = re.search(r"^rn-impeller: screenshot=(\S+)", log, re.M)
    if not m:
        bad("pixels", "the engine never wrote its --screenshot (no 'screenshot=' line)")
    if "webview_create" not in log:
        bad("pixels", "no web view was created")
    try:
        img = ppm(shot)
    except OSError as e:
        bad("pixels", "cannot read the engine readback %s: %s" % (shot, e))
        return
    if img[:2] != (600, 420):
        bad("pixels", "readback is %dx%d, wanted 600x420" % img[:2])
    for name, (x, y), want in POINTS:
        got = px(img, x, y)
        if got != want:
            bad("pixels", "%s at %d,%d is %s, wanted exactly %s" % (name, x, y, got, want))
    frames = re.findall(r"webview_frame id=\d+ n=(\d+)", log)
    print("WEBVIEW_ARM64 pixels ok: %d points exact in the engine readback (rn bar + 6 page blocks), "
          "%s web view frames logged" % (len(POINTS), frames[-1] if frames else "?"))


def touch(log_path, weston_path):
    log = open(log_path, errors="replace").read()
    wlog = open(weston_path, errors="replace").read()
    nd = len(re.findall(r"rni-touch-inject: down ", wlog))
    nu = len(re.findall(r"rni-touch-inject: up", wlog))
    if (nd, nu) != (2, 2):
        bad("touch", "Weston injected %d down + %d up, wanted 2 + 2 (instrument broken)" % (nd, nu))
    downs = re.findall(r"wl_touch down id=\d+ x=([\d.]+) y=([\d.]+)", log)
    if len(downs) != 2:
        bad("touch", "the engine saw %d wl_touch downs, wanted 2 (%s)" % (len(downs), downs))
    wv = re.findall(r"webview_input touch_down id=\d+ at=([\d.-]+),([\d.-]+)", log)
    if len(wv) != 1:
        bad("touch", "%d taps were routed to the web view, wanted 1 (the RN-bar tap must not be): %s" % (len(wv), wv))
    starts = re.findall(r"WVPAGE touchstart (-?\d+) (-?\d+) (\S+)", log)
    clicks = re.findall(r"WVPAGE click (-?\d+) (-?\d+) (\S+)", log)
    if len(starts) != 1 or len(clicks) != 1:
        bad("touch", "page saw touchstart %s and click %s, wanted exactly one of each" % (starts, clicks))
    for kind, (x, y, tgt) in (("touchstart", starts[0]), ("click", clicks[0])):
        if abs(int(x) - 100) > 1 or abs(int(y) - 105) > 1 or tgt != "btn":
            bad("touch", "%s landed at page %s,%s on %s, wanted 100,105 on btn "
                "(window 100,145; the 40 px RN bar shifts y only)" % (kind, x, y, tgt))
    print("WEBVIEW_ARM64 touch ok: RN-bar tap stayed out of the page; tap at window 100,145 = page "
          "touchstart + click at %s,%s on #btn" % clicks[0][:2])


if __name__ == "__main__":
    arm = sys.argv[1]
    if arm == "pixels":
        pixels(sys.argv[2], sys.argv[3])
    elif arm == "touch":
        touch(sys.argv[2], sys.argv[3])
    else:
        bad("usage", arm)
