"""Drive REAL X keyboard events into the rn-impeller window via XTEST.

Nothing here synthesises anything inside the app's process: it presses and
releases actual X keycodes via XTEST, so the event reaches GLFW exactly as a
human keypress would -- the same reason xclick.py exists for pointer clicks
(tools/ci-window-input.sh). That is what makes a run through this script
evidence that glfwSetKeyCallback is REGISTERED, which the in-process
--key-after-frames hook cannot be (see GlfwSurface::synthesiseKey's header).

Argv: <window-title-substring> <spec1> [<spec2> ...]
  spec := KEYNAME[+MOD[+MOD...]]
  KEYNAME is an X11 keysym name (a, Left, Tab, Escape, Delete, ...).
  MOD is one of: shift, ctrl, alt, super.
Modifier keys are pressed BEFORE the target key and released AFTER, in
mirror order, so the X server folds them into the target key event's state
mask (GLFW's translateState reads exactly that mask) -- pressing them
simultaneously-but-unordered would not guarantee the target keypress reports
the modifier bit.
"""
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

MOD_KEYSYMS = {
    "shift": "Shift_L",
    "ctrl": "Control_L",
    "alt": "Alt_L",
    "super": "Super_L",
}


def find_window(d, root, needle):
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


def keycode_for(d, keysym_name):
    ks = XK.string_to_keysym(keysym_name)
    if ks == 0:
        raise ValueError("unknown X11 keysym name: %r" % keysym_name)
    kc = d.keysym_to_keycode(ks)
    if kc == 0:
        raise ValueError("no keycode for keysym %r" % keysym_name)
    return kc


def main():
    needle = sys.argv[1]
    specs = sys.argv[2:]
    if not specs:
        print("XKEY_FAIL no key specs given")
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
        print("XKEY_FAIL no window matching %r" % needle)
        return 1

    # Raise + focus so the key events land on OUR window, not whatever else
    # is on screen -- XTEST delivers to the X server's current input focus,
    # not to a window we merely name.
    win.set_input_focus(X.RevertToParent, X.CurrentTime)
    win.configure(stack_mode=X.Above)
    d.sync()
    time.sleep(0.2)

    for spec in specs:
        parts = spec.split('+')
        key_name = parts[0]
        mods = parts[1:]
        mod_codes = [keycode_for(d, MOD_KEYSYMS[m]) for m in mods]
        key_code = keycode_for(d, key_name)

        for mc in mod_codes:
            xtest.fake_input(d, X.KeyPress, mc)
        d.sync()
        time.sleep(0.05)
        xtest.fake_input(d, X.KeyPress, key_code)
        d.sync()
        time.sleep(0.05)
        xtest.fake_input(d, X.KeyRelease, key_code)
        d.sync()
        time.sleep(0.05)
        for mc in reversed(mod_codes):
            xtest.fake_input(d, X.KeyRelease, mc)
        d.sync()
        print("XKEY_SENT spec=%s" % spec)
        time.sleep(0.3)

    print("XKEY_OK count=%d" % len(specs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
