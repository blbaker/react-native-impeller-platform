#!/usr/bin/env python3
"""Drive a REAL X pointer click into the rn-impeller window.

Nothing in this file synthesises anything inside the app's process: it warps
the actual X pointer and presses the actual button via XTEST, so the event
reaches GLFW exactly as a human's click would. That is what makes it evidence
that glfwSetMouseButtonCallback is registered, which the in-process
--click-after-frames hook cannot be.

Argv: <window-title-substring> <x-in-window> <y-in-window> [more x y pairs...]
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
    coords = [(float(sys.argv[i]), float(sys.argv[i + 1]))
              for i in range(2, len(sys.argv), 2)]

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
        print("XCLICK_FAIL no window matching %r" % needle)
        return 1

    geom = win.get_geometry()
    abs_pos = root.translate_coords(win, 0, 0)
    ox, oy = abs_pos.x, abs_pos.y
    print("XCLICK_WINDOW id=0x%x origin=%d,%d size=%dx%d"
          % (win.id, ox, oy, geom.width, geom.height))

    for (cx, cy) in coords:
        sx, sy = int(ox + cx), int(oy + cy)
        xtest.fake_input(d, X.MotionNotify, x=sx, y=sy)
        d.sync()
        time.sleep(0.15)
        xtest.fake_input(d, X.ButtonPress, 1)
        d.sync()
        time.sleep(0.08)
        xtest.fake_input(d, X.ButtonRelease, 1)
        d.sync()
        print("XCLICK_SENT win=%.1f,%.1f screen=%d,%d" % (cx, cy, sx, sy))
        time.sleep(0.4)

    print("XCLICK_OK clicks=%d" % len(coords))
    return 0


if __name__ == "__main__":
    sys.exit(main())
