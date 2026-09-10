#!/usr/bin/env python3
"""Drive a REAL X wheel scroll into the rn-impeller window.

Same role for ENG-02 that xclick.py plays for windowed input, and the same
argument: nothing here synthesises anything inside the app's process. It warps
the actual X pointer and presses the actual wheel buttons via XTEST, so the
event reaches GLFW exactly as a human's wheel would. That is what makes it
evidence that glfwSetScrollCallback is registered, which the in-process
--scroll-after-frames hook cannot be.

⛔ X11 HAS NO SCROLL AXIS -- THE WHEEL IS BUTTONS 4 AND 5.
Button 4 is wheel-up (GLFW yoffset POSITIVE), button 5 is wheel-down (GLFW
yoffset NEGATIVE). Sending a MotionNotify with a delta, or pressing button 1,
produces no scroll event at all and the gate would read a correctly registered
callback as absent. Each notch is a press AND a release: GLFW's X11 backend
reads the press, but an unreleased button leaves the server thinking a button
is held, which breaks every later event in the same session.

Argv: <window-title-substring> <x-in-window> <y-in-window> <notches>
      notches > 0 scrolls UP (button 4), < 0 scrolls DOWN (button 5).
"""
import sys
import time

from Xlib import X, display
from Xlib.ext import xtest


def find_window(d, root, needle):
    """Depth-first search for a mapped window whose name contains `needle`."""
    stack = [root]
    while stack:
        w = stack.pop()
        try:
            name = w.get_wm_name()
        except Exception:
            name = None
        if name and needle in name:
            try:
                if w.get_attributes().map_state == X.IsViewable:
                    return w
            except Exception:
                pass
        try:
            stack.extend(w.query_tree().children)
        except Exception:
            pass
    return None


def main():
    needle = sys.argv[1]
    cx, cy = float(sys.argv[2]), float(sys.argv[3])
    notches = int(sys.argv[4])
    if notches == 0:
        print("XSCROLL_FAIL notches=0 would prove nothing")
        return 1

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
        print("XSCROLL_FAIL no window matching %r" % needle)
        return 1

    geom = win.get_geometry()
    abs_pos = root.translate_coords(win, 0, 0)
    ox, oy = abs_pos.x, abs_pos.y
    print("XSCROLL_WINDOW id=0x%x origin=%d,%d size=%dx%d"
          % (win.id, ox, oy, geom.width, geom.height))

    button = 4 if notches > 0 else 5
    sx, sy = int(ox + cx), int(oy + cy)
    xtest.fake_input(d, X.MotionNotify, x=sx, y=sy)
    d.sync()
    time.sleep(0.15)
    for _ in range(abs(notches)):
        xtest.fake_input(d, X.ButtonPress, button)
        d.sync()
        time.sleep(0.05)
        xtest.fake_input(d, X.ButtonRelease, button)
        d.sync()
        time.sleep(0.1)
    print("XSCROLL_SENT win=%.1f,%.1f screen=%d,%d button=%d notches=%d"
          % (cx, cy, sx, sy, button, abs(notches)))
    time.sleep(0.5)

    print("XSCROLL_OK notches=%d" % abs(notches))
    return 0


if __name__ == "__main__":
    sys.exit(main())
