#!/usr/bin/env python3
"""Drive REAL X input into the web view gate's window (tools/ci-webview.sh).

XTEST moves the actual X pointer and presses actual buttons/keys, so every
event enters through GLFW's callbacks exactly as a human's would, then the
engine's web view router, the socket, and WPE's own event path. Each step
waits for the PAGE to report what it saw (WVPAGE console lines in the engine
log), so a step that silently does nothing fails at that step.

  webview_xdrive.py <engine-log> <outdir>
Writes <outdir>/shot-a.ppm (page loaded) and shot-scrolled.ppm (after wheel),
both read back from the X server: what a user would see on screen.
"""
import re
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

LOG, OUT = sys.argv[1], sys.argv[2]
TITLE = "React Native (Impeller)"


def fail(msg):
    print("DRIVE_FAIL " + msg, flush=True)
    sys.exit(1)


def wait_log(pattern, timeout, after=0):
    rx = re.compile(pattern, re.M)
    end = time.time() + timeout
    while time.time() < end:
        try:
            text = open(LOG, errors="replace").read()
        except OSError:
            text = ""
        m = rx.search(text, after)
        if m:
            return m
        time.sleep(0.1)
    fail("timeout waiting for /%s/" % pattern)


def log_len():
    try:
        return len(open(LOG, errors="replace").read())
    except OSError:
        return 0


def find_window(d):
    stack = [d.screen().root]
    while stack:
        w = stack.pop()
        try:
            name = w.get_wm_name()
            if name and TITLE in name and w.get_attributes().map_state == X.IsViewable:
                return w
            stack.extend(w.query_tree().children)
        except Exception:
            pass
    return None


d = display.Display()
win = None
for _ in range(200):
    win = find_window(d)
    if win:
        break
    time.sleep(0.1)
if not win:
    fail("no engine window")
geom = win.get_geometry()
org = d.screen().root.translate_coords(win, 0, 0)
OX, OY = org.x, org.y
print("DRIVE window %dx%d at %d,%d" % (geom.width, geom.height, OX, OY), flush=True)


def move(x, y):
    xtest.fake_input(d, X.MotionNotify, x=int(OX + x), y=int(OY + y))
    d.sync()
    time.sleep(0.05)


def button(b, down):
    xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, b)
    d.sync()
    time.sleep(0.05)


def click(x, y):
    move(x, y)
    time.sleep(0.1)
    button(1, True)
    time.sleep(0.06)
    button(1, False)


def key(name):
    code = d.keysym_to_keycode(XK.string_to_keysym(name))
    if not code:
        fail("no keycode for " + name)
    xtest.fake_input(d, X.KeyPress, code)
    d.sync()
    time.sleep(0.04)
    xtest.fake_input(d, X.KeyRelease, code)
    d.sync()
    time.sleep(0.08)


def grab(path):
    img = win.get_image(0, 0, geom.width, geom.height, X.ZPixmap, 0xFFFFFFFF)
    raw = img.data
    rgb = bytearray()
    for i in range(0, geom.width * geom.height * 4, 4):  # BGRX
        rgb += bytes((raw[i + 2], raw[i + 1], raw[i]))
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (geom.width, geom.height))
        f.write(rgb)
    print("DRIVE shot " + path, flush=True)


wait_log(r"WVAPP t=\d+ stage input-ready", 90)
time.sleep(1.0)
grab(OUT + "/shot-a.ppm")

# Window coords = page coords + 40 (the RN bar above the web view).
mark = log_len()
move(470, 145)  # purple hover box
wait_log(r"WVPAGE hover-enter", 8, mark)
move(300, 300)
wait_log(r"WVPAGE hover-leave", 8, mark)
print("DRIVE hover ok", flush=True)

mark = log_len()
click(100, 145)  # green button: a touch tap WebKit turns into a click
m = wait_log(r"WVPAGE click (-?\d+) (-?\d+)", 8, mark)
print("DRIVE click page=%s,%s" % (m.group(1), m.group(2)), flush=True)

mark = log_len()
click(300, 140)  # text input
time.sleep(0.4)
for k in ("a", "b", "c", "BackSpace"):
    key(k)
wait_log(r'WVPAGE value "ab"$', 8, mark)
print("DRIVE typing ok", flush=True)

mark = log_len()
move(60, 250)  # orange touch zone (touch-action: none, preventDefault)
button(1, True)
for i in range(1, 12):
    move(60 + i * 20, 250)
    time.sleep(0.03)
button(1, False)
m = wait_log(r"WVPAGE touchend moves=(\d+) dx=(-?\d+)", 8, mark)
print("DRIVE drag moves=%s dx=%s" % (m.group(1), m.group(2)), flush=True)

mark = log_len()
move(450, 360)
for _ in range(3):  # wheel DOWN = X button 5
    button(5, True)
    button(5, False)
    time.sleep(0.05)
m = wait_log(r"WVPAGE scrolly (\d+)", 8, mark)
print("DRIVE wheel scrollY=%s" % m.group(1), flush=True)
time.sleep(0.8)
grab(OUT + "/shot-scrolled.ppm")

mark = log_len()
click(460, 245)  # yellow target=_blank link: must open in THIS view
wait_log(r"WVPAGE b cookie=", 15, mark)
print("DRIVE link ok", flush=True)
wait_log(r"WVAPP t=\d+ done", 60, mark)
print("DRIVE_OK", flush=True)
