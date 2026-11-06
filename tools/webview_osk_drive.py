#!/usr/bin/env python3
"""Drive REAL X taps into the web view OSK gate's window (tools/ci-webview-osk.sh).

XTEST presses the actual X pointer, so every tap enters through GLFW's mouse
callback, the engine's web view router (a left press = one touch sequence) and
WPE, exactly as a finger on the device does. The typing is the APP's (sendText /
sendKey from the fixture's onEditableFocus); this script only taps, then waits
for the app to report the stage it reached, so a step that silently does
nothing fails at that step.

  webview_osk_drive.py <engine-log>
"""
import re
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

LOG = sys.argv[1]
TITLE = "React Native (Impeller)"


def fail(msg):
    print("OSK_DRIVE_FAIL " + msg, flush=True)
    sys.exit(1)


def text():
    try:
        return open(LOG, errors="replace").read()
    except OSError:
        return ""


def wait_log(pattern, timeout, after=0):
    rx = re.compile(pattern, re.M)
    end = time.time() + timeout
    while time.time() < end:
        if rx.search(text(), after):
            return
        time.sleep(0.1)
    fail("timeout waiting for /%s/" % pattern)


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
org = d.screen().root.translate_coords(win, 0, 0)


def tap(name, x, y):
    print("OSK_DRIVE tap %s at %d,%d" % (name, x, y), flush=True)
    xtest.fake_input(d, X.MotionNotify, x=int(org.x + x), y=int(org.y + y))
    d.sync()
    time.sleep(0.1)
    xtest.fake_input(d, X.ButtonPress, 1)
    d.sync()
    time.sleep(0.06)
    xtest.fake_input(d, X.ButtonRelease, 1)
    d.sync()


def press_key(name, keysym):
    code = d.keysym_to_keycode(XK.string_to_keysym(keysym))
    if not code:
        fail("no keycode for " + keysym)
    print("OSK_DRIVE tap %s (X key %s)" % (name, keysym), flush=True)
    xtest.fake_input(d, X.KeyPress, code)
    d.sync()
    time.sleep(0.04)
    xtest.fake_input(d, X.KeyRelease, code)
    d.sync()


# Window coordinates = page coordinates + 40 (the RN bar above the web view).
# The app's keys Done/t/e/s are RN views IN that bar (x 360/420/480/540, 50 wide): a
# press there is outside the web view, as a key of the console's own keyboard is.
# After each Done the same field is tapped again and must report focus again (the
# console reopens its keyboard on that event); before the last tap a physical key
# must land in RN, not in the page the Done blurred. "key" steps press an X key.
TYPED = "ab\u00e9\u6f22"
CYCLES = []
for i in range(1, 6):
    CYCLES.append(("done-%d" % i, 385, 20, r"WVAPP stage tap-(refocus|physical)$"))
    if i == 5:
        CYCLES.append(("phys-key", "key", "x", r"^rn-impeller: key_event (type=up key=x |key=x webview=)"))
    CYCLES.append(("refocus-%d" % i, 150, 80, r"WVAPP stage tap-chrome$" if i == 5 else r"WVAPP stage tap-done$"))
STEPS = [
    ("text", 150, 80, r"WVAPP stage tap-password$"),
    ("password", 150, 150, r"WVAPP stage tap-blank$"),
    ("blank", 220, 300, r"WVAPP stage tap-text$"),
    ("text-again", 150, 80, r"WVAPP stage tap-keys$"),
    ("key-t", 445, 20, 'WVAPP title "read:%st"$' % TYPED),
    ("key-e", 505, 20, 'WVAPP title "read:%ste"$' % TYPED),
    ("key-s", 565, 20, 'WVAPP title "read:%stes"$' % TYPED),
    ("key-t2", 445, 20, r"WVAPP stage tap-done$"),
] + CYCLES + [
    ("rn-chrome", 300, 20, r"WVAPP stage done$"),
]
wait_log(r"WVAPP stage ready$", 90)
for name, x, y, until in STEPS:
    mark = len(text())
    if x == "key":
        press_key(name, y)
    else:
        tap(name, x, y)
    wait_log(until, 15, mark)
    print("OSK_DRIVE step %s ok" % name, flush=True)
print("OSK_DRIVE_OK", flush=True)
