#!/usr/bin/env python3
"""Checks the D-Bus side of tools/ci-notifications.sh arm B.

    notify_gate_check.py calls.jsonl monitor.log

calls.jsonl is what tools/notify_bus_mock.py decoded; monitor.log is
dbus-monitor's view of the same calls. Both must show what the fixture asked
for, and they must agree with each other, so a decoding bug in the mock cannot
pass for a correct engine.
"""
import json
import re
import sys

APP = 'Notify Fixture'
FIRST = ('Edition ready', 'Tuesday: 3 stories')
SECOND = ('Edition ready (updated)', 'Tuesday: 4 stories')

errors = []


def check(cond, message):
    if not cond:
        errors.append(message)
    return cond


def monitor_notifies(text):
    """Each Notify call dbus-monitor printed, as (strings, first uint32)."""
    out = []
    for block in re.split(r'\n(?=\S)', text):
        if 'member=Notify' not in block.split('\n', 1)[0]:
            continue
        strings = re.findall(r'^\s+string "(.*)"$', block, re.M)
        uints = re.findall(r'^\s+uint32 (\d+)$', block, re.M)
        out.append((strings, int(uints[0]) if uints else None))
    return out


def main(calls_path, monitor_path):
    entries = [json.loads(line) for line in open(calls_path) if line.strip()]
    notifies = [e for e in entries if e.get('member') == 'Notify']
    caps = [e for e in entries if e.get('member') == 'GetCapabilities']
    signals = {e['label']: e for e in entries if e.get('event') == 'signal'}

    check(len(caps) == 1, f'expected 1 GetCapabilities (requestPermission), got {len(caps)}')
    if check(len(notifies) == 2, f'expected 2 Notify calls (show + replace), got {len(notifies)}'):
        first, second = notifies
        check(first['app_name'] == APP, f"app_name {first['app_name']!r}, want {APP!r} (RNI_APP_NAME)")
        check((first['summary'], first['body']) == FIRST, f'first Notify carried {first["summary"]!r}/{first["body"]!r}')
        check(first['replaces_id'] == 0, f"first Notify replaces_id {first['replaces_id']}, want 0")
        check(first['actions'] == ['default', 'Open'], f"actions {first['actions']!r}, want ['default', 'Open']")
        check(first['expire_timeout'] == -1, f"expire_timeout {first['expire_timeout']}, want -1")
        check((second['summary'], second['body']) == SECOND, f'second Notify carried {second["summary"]!r}/{second["body"]!r}')
        check(second['replaces_id'] == first['assigned_id'],
              f"replace sent replaces_id {second['replaces_id']}, want {first['assigned_id']}")
        check(first['sender'] == second['sender'], 'the two Notify calls came from different connections')

        # The hostile clicks must really have been sent, or "exactly one press"
        # proves nothing about the filters.
        for label in ('spoof', 'foreign', 'real'):
            check(label in signals, f'the mock never sent the {label} click')
        if 'spoof' in signals and 'real' in signals:
            check(signals['spoof']['from'] != signals['real']['from'],
                  'the spoofed click came from the server connection itself')
            check(signals['spoof']['id'] == first['assigned_id'], 'the spoof did not target our notification')

        seen = monitor_notifies(open(monitor_path).read())
        if check(len(seen) == 2, f'dbus-monitor saw {len(seen)} Notify calls, want 2'):
            for got, mock in zip(seen, notifies):
                want = [mock['app_name'], mock['app_icon'], mock['summary'], mock['body'], *mock['actions']]
                check(got == (want, mock['replaces_id']),
                      f'dbus-monitor and the mock disagree: {got} vs {(want, mock["replaces_id"])}')

    if errors:
        for e in errors:
            print('   BUS: ' + e, file=sys.stderr)
        return 1
    print(f'   OK BUS: 2 Notify calls ({FIRST[0]!r}, then replaces_id={notifies[1]["replaces_id"]}), '
          '1 GetCapabilities, spoof/foreign/real clicks sent; dbus-monitor agrees')
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:3]))
