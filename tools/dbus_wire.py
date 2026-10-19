"""Minimal D-Bus wire protocol for the notifications gate's bus mock.

Standard library only, so the gate needs nothing but dbus-daemon. Covers what
tools/notify_bus_mock.py speaks: EXTERNAL auth, little-endian marshalling of
the basic types, arrays, structs, dict entries and variants, and whole-message
framing. It is deliberately independent of sd-bus, which the engine uses, so a
bug in one cannot hide a bug in the other.
"""
import os
import socket
import struct

ALIGN = {'y': 1, 'g': 1, 'v': 1, 'n': 2, 'q': 2, 'b': 4, 'i': 4, 'u': 4,
         's': 4, 'o': 4, 'a': 4, 'x': 8, 't': 8, 'd': 8, '(': 8, '{': 8}
FIXED = {'y': 'B', 'n': 'h', 'q': 'H', 'b': 'I', 'i': 'i', 'u': 'I',
         'x': 'q', 't': 'Q', 'd': 'd'}
METHOD_CALL, METHOD_RETURN, ERROR, SIGNAL = 1, 2, 3, 4
FIELD = {1: 'path', 2: 'interface', 3: 'member', 4: 'error_name',
         5: 'reply_serial', 6: 'destination', 7: 'sender', 8: 'signature'}
FIELD_SIG = {'path': 'o', 'interface': 's', 'member': 's', 'error_name': 's',
             'reply_serial': 'u', 'destination': 's', 'signature': 'g'}


def split_types(sig):
    """'susa{sv}' -> ['s', 'u', 's', 'a{sv}']"""
    out, i = [], 0
    while i < len(sig):
        j = i
        while sig[j] == 'a':
            j += 1
        if sig[j] in '({':
            depth, k = 0, j
            while True:
                depth += sig[k] in '({'
                depth -= sig[k] in ')}'
                k += 1
                if depth == 0:
                    break
            j = k
        else:
            j += 1
        out.append(sig[i:j])
        i = j
    return out


class Writer:
    def __init__(self):
        self.buf = bytearray()

    def pad(self, n):
        while len(self.buf) % n:
            self.buf.append(0)

    def put(self, t, v):
        c = t[0]
        self.pad(ALIGN[c])
        if c in FIXED:
            self.buf += struct.pack('<' + FIXED[c], v)
        elif c in 'so':
            raw = v.encode()
            self.buf += struct.pack('<I', len(raw)) + raw + b'\0'
        elif c == 'g':
            raw = v.encode()
            self.buf += bytes([len(raw)]) + raw + b'\0'
        elif c == 'v':
            sig, inner = v
            self.put('g', sig)
            self.put(sig, inner)
        elif c == '(':
            for st, sv in zip(split_types(t[1:-1]), v):
                self.put(st, sv)
        elif c == 'a':
            elem = t[1:]
            self.buf += b'\0\0\0\0'
            at = len(self.buf)
            self.pad(ALIGN[elem[0]])
            start = len(self.buf)
            items = v.items() if elem[0] == '{' else v
            for item in items:
                if elem[0] == '{':
                    kt, vt = split_types(elem[1:-1])
                    self.pad(8)
                    self.put(kt, item[0])
                    self.put(vt, item[1])
                else:
                    self.put(elem, item)
            struct.pack_into('<I', self.buf, at - 4, len(self.buf) - start)
        else:
            raise ValueError('cannot marshal ' + t)


class Reader:
    def __init__(self, buf, pos=0):
        self.buf, self.pos = buf, pos

    def align(self, n):
        self.pos += (-self.pos) % n

    def get(self, t):
        c = t[0]
        self.align(ALIGN[c])
        if c in FIXED:
            fmt = '<' + FIXED[c]
            (v,) = struct.unpack_from(fmt, self.buf, self.pos)
            self.pos += struct.calcsize(fmt)
            return v
        if c in 'so':
            (n,) = struct.unpack_from('<I', self.buf, self.pos)
            v = self.buf[self.pos + 4:self.pos + 4 + n].decode()
            self.pos += 5 + n
            return v
        if c == 'g':
            n = self.buf[self.pos]
            v = self.buf[self.pos + 1:self.pos + 1 + n].decode()
            self.pos += 2 + n
            return v
        if c == 'v':
            sig = self.get('g')
            return (sig, self.get(sig))
        if c == '(':
            return [self.get(st) for st in split_types(t[1:-1])]
        if c == 'a':
            (n,) = struct.unpack_from('<I', self.buf, self.pos)
            self.pos += 4
            elem = t[1:]
            self.align(ALIGN[elem[0]])
            end = self.pos + n
            if elem[0] == '{':
                kt, vt = split_types(elem[1:-1])
                out = {}
                while self.pos < end:
                    self.align(8)
                    k = self.get(kt)
                    out[k] = self.get(vt)
                return out
            out = []
            while self.pos < end:
                out.append(self.get(elem))
            return out
        raise ValueError('cannot unmarshal ' + t)


class Connection:
    """One authenticated client connection to a bus at unix:path=..."""

    def __init__(self, address):
        path = dict(kv.split('=', 1) for kv in address.split(':', 1)[1].split(','))['path']
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.sendall(b'\0AUTH EXTERNAL ' + str(os.getuid()).encode().hex().encode() + b'\r\n')
        if not self._line().startswith(b'OK'):
            raise RuntimeError('bus refused EXTERNAL auth')
        self.sock.sendall(b'BEGIN\r\n')
        self.serial, self.pending = 0, bytearray()
        self.name = self.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                              'org.freedesktop.DBus', 'Hello')[0]

    def _line(self):
        data = b''
        while not data.endswith(b'\r\n'):
            data += self.sock.recv(1)
        return data

    def send(self, kind, fields, sig='', args=()):
        body = Writer()
        for t, v in zip(split_types(sig), args):
            body.put(t, v)
        if sig:
            fields = dict(fields, signature=sig)
        self.serial += 1
        hdr = Writer()
        hdr.buf += struct.pack('<cBBBII', b'l', kind, 0, 1, len(body.buf), self.serial)
        codes = {v: k for k, v in FIELD.items()}
        hdr.put('a(yv)', [[codes[k], (FIELD_SIG[k], v)] for k, v in fields.items()])
        hdr.pad(8)
        self.sock.sendall(bytes(hdr.buf) + bytes(body.buf))
        return self.serial

    def recv(self):
        """Next message as a dict, or None when the bus closed the socket."""
        while True:
            if len(self.pending) >= 16:
                body_len, _, fields_len = struct.unpack_from('<III', self.pending, 4)
                hdr_end = 16 + fields_len + (-(16 + fields_len) % 8)
                if len(self.pending) >= hdr_end + body_len:
                    break
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.pending += chunk
        buf = bytes(self.pending[:hdr_end + body_len])
        del self.pending[:hdr_end + body_len]
        msg = {'type': buf[1], 'serial': struct.unpack_from('<I', buf, 8)[0]}
        for code, (_, value) in Reader(buf, 12).get('a(yv)'):
            if code in FIELD:
                msg[FIELD[code]] = value
        sig = msg.get('signature', '')
        r = Reader(buf[hdr_end:])
        msg['args'] = [r.get(t) for t in split_types(sig)]
        return msg

    def call(self, dest, path, iface, member, sig='', args=()):
        serial = self.send(METHOD_CALL, {'path': path, 'interface': iface,
                                         'member': member, 'destination': dest}, sig, args)
        while True:
            msg = self.recv()
            if msg is None:
                raise RuntimeError('bus closed during ' + member)
            if msg.get('reply_serial') == serial:
                if msg['type'] == ERROR:
                    raise RuntimeError(member + ' failed: ' + msg.get('error_name', '?'))
                return msg['args']
