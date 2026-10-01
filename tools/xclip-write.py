#!/usr/bin/env python3
"""Own the X CLIPBOARD selection from OUTSIDE the rn-impeller process (item 5,
the "other direction" arm: an external owner sets CLIPBOARD, then the engine's
Ctrl+V pastes it).

Becomes the CLIPBOARD owner for the given text and answers SelectionRequest
events (the real ICCCM exchange any clipboard owner must do) for up to
`hold_seconds`, then exits -- releasing ownership. No `xclip` dependency.

Usage: xclip-write.py TEXT [hold_seconds]
Prints XCLIPWRITE_OWNER once ownership is acquired (so a caller launching this
in the background knows it is safe to proceed), then XCLIPWRITE_DONE on exit.
"""
import sys
import time

from Xlib import X, Xatom, display
from Xlib.protocol import event as xevent


def main():
    text = sys.argv[1]
    hold_seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
    data = text.encode("utf-8")

    d = display.Display()
    screen = d.screen()
    win = screen.root.create_window(
        0, 0, 1, 1, 0, screen.root_depth,
        event_mask=X.NoEventMask,
    )

    CLIPBOARD = d.intern_atom("CLIPBOARD")
    UTF8_STRING = d.intern_atom("UTF8_STRING")
    TARGETS = d.intern_atom("TARGETS")

    win.set_selection_owner(CLIPBOARD, X.CurrentTime)
    d.flush()
    if d.get_selection_owner(CLIPBOARD) != win.id:
        print("XCLIPWRITE_FAIL could not become selection owner", file=sys.stderr)
        return 1
    print("XCLIPWRITE_OWNER")
    sys.stdout.flush()

    deadline = time.time() + hold_seconds
    while time.time() < deadline:
        if d.pending_events() == 0:
            time.sleep(0.02)
            continue
        ev = d.next_event()
        if ev.type == X.SelectionRequest:
            req = ev
            prop = req.property if req.property != X.NONE else req.target
            if req.target == UTF8_STRING:
                req.requestor.change_property(prop, UTF8_STRING, 8, data)
            elif req.target == TARGETS:
                req.requestor.change_property(
                    prop, Xatom.ATOM, 32, [UTF8_STRING, TARGETS])
            else:
                # Unsupported target: refuse per ICCCM (property = None).
                prop = X.NONE
            notify = xevent.SelectionNotify(
                time=req.time,
                requestor=req.requestor,
                selection=req.selection,
                target=req.target,
                property=prop,
            )
            req.requestor.send_event(notify, event_mask=0)
            d.flush()
    print("XCLIPWRITE_DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
