#!/usr/bin/env python3
"""A fake org.freedesktop.Notifications server for tools/ci-notifications.sh.

    notify_bus_mock.py --address unix:path=... --log calls.jsonl --ready FILE

It owns the server name on a private session bus, records every call it gets
as one JSON line, and answers like a real server. After the first Notify with
replaces_id 0 it clicks that notification, in this order:

  1. spoof    ActionInvoked(id, "default") from a SECOND connection that does
              not own the server name. A client that trusts any sender would
              report a press.
  2. foreign  ActionInvoked(id + 1000, "default") from the server itself: a
              click on a notification some other app showed.
  3. real     ActionInvoked(id, "default") from the server.

The engine must report exactly one press, for the real click.
"""
import argparse
import json
import signal
import sys
import threading
import time

sys.dont_write_bytecode = True  # keep tools/ free of __pycache__
sys.path.insert(0, __import__('os').path.dirname(__file__))
import dbus_wire as w  # noqa: E402

NAME = 'org.freedesktop.Notifications'
PATH = '/org/freedesktop/Notifications'
GAP_S = 0.15


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--address', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--ready', required=True)
    ap.add_argument('--first-id', type=int, default=7001)
    opts = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    server = w.Connection(opts.address)
    spoofer = w.Connection(opts.address)
    owned = server.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                        'org.freedesktop.DBus', 'RequestName', 'su', (NAME, 4))
    if owned != [1]:
        sys.exit('could not become the primary owner of ' + NAME)
    log = open(opts.log, 'a', buffering=1)
    send_lock = threading.Lock()

    def record(entry):
        log.write(json.dumps(entry, sort_keys=True) + '\n')

    def emit(conn, label, nid, action):
        with send_lock:
            conn.send(w.SIGNAL, {'path': PATH, 'interface': NAME,
                                 'member': 'ActionInvoked'}, 'us', (nid, action))
        record({'event': 'signal', 'label': label, 'id': nid, 'action': action,
                'from': conn.name})

    def click(nid):
        for conn, label, target in ((spoofer, 'spoof', nid),
                                    (server, 'foreign', nid + 1000),
                                    (server, 'real', nid)):
            time.sleep(GAP_S)
            emit(conn, label, target, 'default')

    with open(opts.ready, 'w') as f:
        f.write(server.name + '\n')

    next_id = opts.first_id
    clicked = False
    while True:
        msg = server.recv()
        if msg is None:
            return
        if msg['type'] != w.METHOD_CALL or msg.get('interface') != NAME:
            continue
        member, args = msg['member'], msg['args']
        reply = {'reply_serial': msg['serial'], 'destination': msg['sender']}
        entry = {'event': 'call', 'member': member, 'sender': msg['sender']}
        if member == 'Notify':
            app, replaces, icon, summary, body, actions, hints, timeout = args
            nid = replaces if replaces else next_id
            if not replaces:
                next_id += 1
            entry.update(app_name=app, replaces_id=replaces, app_icon=icon,
                         summary=summary, body=body, actions=actions,
                         hints=sorted(hints), expire_timeout=timeout, assigned_id=nid)
            record(entry)
            with send_lock:
                server.send(w.METHOD_RETURN, reply, 'u', (nid,))
            if not replaces and not clicked:
                clicked = True
                threading.Thread(target=click, args=(nid,), daemon=True).start()
        elif member == 'GetCapabilities':
            record(entry)
            with send_lock:
                server.send(w.METHOD_RETURN, reply, 'as', (['actions', 'body'],))
        elif member == 'GetServerInformation':
            record(entry)
            with send_lock:
                server.send(w.METHOD_RETURN, reply, 'ssss',
                            ('rni-notify-mock', 'react-native-impeller', '1', '1.2'))
        else:
            entry['unknown'] = True
            record(entry)
            with send_lock:
                server.send(w.ERROR, dict(reply, error_name='org.freedesktop.DBus.Error.UnknownMethod'))


if __name__ == '__main__':
    main()
