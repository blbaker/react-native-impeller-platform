#!/usr/bin/env python3
"""Drive REAL X pointer button presses for tools/ci-mouse-buttons.sh (item 6).

Like tools/xclick.py, but any X button, optional held modifiers, and press
or release on their own (to hold one button while pressing another).

Argv: <window-title-substring> <step> [<step> ...]
  click:B@X,Y[+mod,mod]   press+release X button B (1 left, 2 middle,
                          3 right, 8 back, 9 forward) at window-relative X,Y
  press:B@X,Y / release:B@X,Y   one half only
mods: shift, ctrl, alt.
"""
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from xclick import find_window  # noqa: E402

MOD_KEYSYMS = {"shift": "Shift_L", "ctrl": "Control_L", "alt": "Alt_L"}


def main():
    needle = sys.argv[1]
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
        print("XBUTTON_FAIL no window matching %r" % needle)
        return 1
    pos = root.translate_coords(win, 0, 0)
    ox, oy = pos.x, pos.y
    for step in sys.argv[2:]:
        kind, _, rest = step.partition(":")
        spec, _, mods = rest.partition("+")
        b, _, xy = spec.partition("@")
        x, y = (float(v) for v in xy.split(","))
        b = int(b)
        codes = [d.keysym_to_keycode(XK.string_to_keysym(MOD_KEYSYMS[m]))
                 for m in mods.split(",") if m]
        xtest.fake_input(d, X.MotionNotify, x=int(ox + x), y=int(oy + y))
        d.sync()
        time.sleep(0.12)
        for c in codes:
            xtest.fake_input(d, X.KeyPress, c)
        d.sync()
        time.sleep(0.05)
        if kind in ("click", "press"):
            xtest.fake_input(d, X.ButtonPress, b)
            d.sync()
            time.sleep(0.06)
        if kind in ("click", "release"):
            xtest.fake_input(d, X.ButtonRelease, b)
            d.sync()
            time.sleep(0.06)
        for c in reversed(codes):
            xtest.fake_input(d, X.KeyRelease, c)
        d.sync()
        print("XBUTTON_SENT %s" % step)
        time.sleep(0.5)
    print("XBUTTON_OK steps=%d" % (len(sys.argv) - 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
