#!/usr/bin/env python3
"""Read the X CLIPBOARD selection from OUTSIDE the rn-impeller process (item 5).

No `xclip` dependency: this is a minimal clipboard reader built directly on
python-xlib's ConvertSelection/SelectionNotify, acting as its OWN X client
with its own throwaway window -- a different client than the engine process,
so a successful read here is proof the content crossed a REAL X11 selection
boundary rather than being read back from the engine's own in-process cache.

Usage: xclip-read.py [timeout_seconds]
Prints the clipboard content on stdout, exit 0. On timeout/no-owner, prints
nothing to stdout and exits 1 (so the gate can tell "no owner" apart from "the
owner's string happens to be empty").
"""
import sys
import time

from Xlib import X, Xatom, display


def main():
    timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    d = display.Display()
    screen = d.screen()
    # A throwaway, never-mapped window: it only needs to be a valid requestor
    # for ConvertSelection and to receive the SelectionNotify event. It is
    # never shown and never interacts with the engine's window.
    win = screen.root.create_window(
        0, 0, 1, 1, 0, screen.root_depth,
        event_mask=X.NoEventMask,
    )

    CLIPBOARD = d.intern_atom("CLIPBOARD")
    UTF8_STRING = d.intern_atom("UTF8_STRING")
    XSEL_DATA = d.intern_atom("XCLIP_READ_PROP")

    if d.get_selection_owner(CLIPBOARD) == X.NONE:
        print("XCLIPREAD_NO_OWNER", file=sys.stderr)
        return 1

    win.convert_selection(CLIPBOARD, UTF8_STRING, XSEL_DATA, X.CurrentTime)
    d.flush()

    deadline = time.time() + timeout
    while time.time() < deadline:
        if d.pending_events() == 0:
            # Xlib has no fd-wait helper exposed simply here; poll cheaply.
            time.sleep(0.02)
            continue
        ev = d.next_event()
        if ev.type == X.SelectionNotify:
            if ev.property == X.NONE:
                print("XCLIPREAD_REFUSED", file=sys.stderr)
                return 1
            prop = win.get_full_property(XSEL_DATA, X.AnyPropertyType)
            if prop is None:
                print("XCLIPREAD_EMPTY_PROP", file=sys.stderr)
                return 1
            data = prop.value
            if isinstance(data, bytes):
                text = data.decode("utf-8", errors="replace")
            else:
                # python-xlib can hand back a str for 8-bit property types.
                text = data if isinstance(data, str) else str(data)
            sys.stdout.write(text)
            sys.stdout.flush()
            return 0
    print("XCLIPREAD_TIMEOUT", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
