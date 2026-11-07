#!/usr/bin/env python3
"""Watch the X11 windows a PID owns and report whether any was ever VIEWABLE.

usage: x11-viewable-windows.py <pid> <seconds>

Polls every 50 ms for <seconds> (or until the PID exits), walking the whole
window tree and matching _NET_WM_PID == pid (GLFW sets it on every window it
creates, mapped or not). Prints one line:
    x11_windows pid=<pid> found=<max windows seen> max_viewable=<max mapped+viewable> samples=<n>
and exits 0. found=0 means the oracle never saw the engine's window at all, so
a viewable=0 next to it proves nothing; the gate checks both.

This reads the window system from OUTSIDE the engine. The engine's own
`window_hidden ... visible_frames=0` line is a readback of GLFW's attribute;
this is what the X server says. Needs python-xlib and DISPLAY.
"""
import os
import sys
import time

from Xlib import X, display, error


def scan(d, pid, a_pid):
    found = viewable = 0
    stack = [d.screen().root]
    while stack:
        w = stack.pop()
        try:
            p = w.get_full_property(a_pid, X.AnyPropertyType)
            if p is not None and len(p.value) and int(p.value[0]) == pid:
                found += 1
                if w.get_attributes().map_state == X.IsViewable:
                    viewable += 1
            stack.extend(w.query_tree().children)
        except error.BadWindow:
            continue  # window vanished mid-walk
    return found, viewable


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    pid = int(sys.argv[1])
    secs = float(sys.argv[2])
    d = display.Display()
    a_pid = d.intern_atom("_NET_WM_PID")
    deadline = time.time() + secs
    max_found = max_view = samples = 0
    while time.time() < deadline and alive(pid):
        f, v = scan(d, pid, a_pid)
        max_found, max_view = max(max_found, f), max(max_view, v)
        samples += 1
        time.sleep(0.05)
    print(f"x11_windows pid={pid} found={max_found} max_viewable={max_view} samples={samples}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
