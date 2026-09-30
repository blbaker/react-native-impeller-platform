#!/usr/bin/env python3
"""Drive REAL X pointer gestures into the rn-impeller window (item 4b).

Like tools/xclick.py, this warps the actual X pointer and presses the actual
button via XTEST, so events reach GLFW's callbacks exactly as a human's would.
Adds what a text-selection gate needs and xclick.py cannot do: a DRAG (press,
several motions, release) and a DOUBLE click (two presses inside the
double-click interval, no sleep between them).

Argv: <window-title-substring> <gesture> [<gesture> ...]
  drag:X0,Y0:X1,Y1     press at X0,Y0, move in 6 steps to X1,Y1, release
  dbl:X,Y              two clicks 80 ms apart at X,Y
Coordinates are window-relative, like xclick.py.
"""
import sys
import time

from Xlib import X, display
from Xlib.ext import xtest

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from xclick import find_window  # noqa: E402


def move(d, x, y):
    xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y))
    d.sync()


def press(d, down):
    xtest.fake_input(d, X.ButtonPress if down else X.ButtonRelease, 1)
    d.sync()


def main():
    needle = sys.argv[1]
    gestures = sys.argv[2:]
    d = display.Display()
    root = d.screen().root
    win = None
    deadline = time.time() + 20
    while time.time() < deadline:
        win = find_window(d, root, needle)
        if win:
            break
        time.sleep(0.25)
    if not win:
        print("XDRAG_FAIL no window matching %r" % needle)
        return 1
    pos = root.translate_coords(win, 0, 0)
    ox, oy = pos.x, pos.y
    for g in gestures:
        kind, _, rest = g.partition(":")
        if kind == "drag":
            (x0, y0), (x1, y1) = [tuple(float(v) for v in p.split(",")) for p in rest.split(":")]
            move(d, ox + x0, oy + y0)
            time.sleep(0.15)
            press(d, True)
            time.sleep(0.1)
            for i in range(1, 7):
                move(d, ox + x0 + (x1 - x0) * i / 6.0, oy + y0 + (y1 - y0) * i / 6.0)
                time.sleep(0.06)
            time.sleep(0.1)
            press(d, False)
        elif kind == "dbl":
            x, y = (float(v) for v in rest.split(","))
            move(d, ox + x, oy + y)
            time.sleep(0.15)
            for _ in range(2):
                press(d, True)
                time.sleep(0.03)
                press(d, False)
                time.sleep(0.05)
        else:
            print("XDRAG_FAIL unknown gesture %r" % g)
            return 1
        print("XDRAG_SENT %s" % g)
        time.sleep(0.6)
    print("XDRAG_OK gestures=%d" % len(gestures))
    return 0


if __name__ == "__main__":
    sys.exit(main())
