#!/usr/bin/env python3
"""Print the X11 title of the top-level window(s) owned by a PID.

usage: x11-window-title.py <pid> [timeout_sec]

Walks the whole window tree (a WM may reparent the client under a frame) and
matches _NET_WM_PID == pid, which GLFW sets on every window it creates. For
each match it prints one line:
    x11_title=<_NET_WM_NAME, else WM_NAME>
and exits 0. Exits 3 if no titled window for the PID appears before the
timeout, 2 on a bad call. Needs python-xlib and DISPLAY (ci-window-title.sh
picks the interpreter).

This is the title the WINDOW SYSTEM holds, read from outside the engine. The
engine's own `window_title=` log line only says what main.cpp meant to pass;
a glfwCreateWindow call that ignores it still logs the requested string.
"""
import sys
import time

from Xlib import X, Xatom, display, error


def titles_for(d, pid):
    root = d.screen().root
    a_pid = d.intern_atom("_NET_WM_PID")
    a_name = d.intern_atom("_NET_WM_NAME")
    a_utf8 = d.intern_atom("UTF8_STRING")
    found = []
    stack = [root]
    while stack:
        w = stack.pop()
        try:
            p = w.get_full_property(a_pid, Xatom.CARDINAL)
            if p is not None and len(p.value) and int(p.value[0]) == pid:
                n = w.get_full_property(a_name, a_utf8)
                if n is not None and n.value:
                    v = n.value
                    title = v.decode("utf-8", "replace") if isinstance(v, bytes) else str(v)
                else:
                    wm = w.get_wm_name()
                    title = wm.decode("latin-1") if isinstance(wm, bytes) else wm
                if title:
                    found.append(title)
            stack.extend(w.query_tree().children)
        except error.BadWindow:
            continue  # window vanished mid-walk
    return found


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    pid = int(sys.argv[1])
    timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    d = display.Display()
    deadline = time.time() + timeout
    while time.time() < deadline:
        t = titles_for(d, pid)
        if t:
            for s in t:
                print(f"x11_title={s}")
            return 0
        time.sleep(0.1)
    print(f"x11_title_timeout pid={pid} after {timeout}s", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
