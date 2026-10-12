#!/usr/bin/env python3
"""Helpers for tools/ci-expo-host.sh. Standard library only (the Mac has no Pillow).

  ppm <file>                 -> bg_frac=<f> yellow=<n> green_center=<0|1>
  md5file <file>             -> hex
  md5str <string>            -> hex
  uuid5dns <name>            -> RFC 4122 v5 in the DNS namespace (Python's uuid)
  serve <dir> <portfile>     -> HTTP on 127.0.0.1:<free port>, port written to portfile
"""
import hashlib
import http.server
import os
import socketserver
import sys
import uuid


def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    # P6\n<w> <h>\n<max>\n<raw>
    parts = []
    i = 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b'#':
            while data[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    i += 1
    assert parts[0] == b'P6', parts[0]
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[i:i + w * h * 3]


def cmd_ppm(path):
    w, h, px = read_ppm(path)
    n = w * h
    bg = yellow = 0
    for k in range(0, n * 3, 3):
        r, g, b = px[k], px[k + 1], px[k + 2]
        if abs(r - 0x12) <= 6 and abs(g - 0x12) <= 6 and abs(b - 0x13) <= 6:
            bg += 1
        elif r > 200 and 150 < g < 235 and b < 110:  # #FFCB27 glyph cores
            yellow += 1
    c = ((h // 2) * w + w // 2) * 3
    r, g, b = px[c], px[c + 1], px[c + 2]
    # contract screen: #1f8a3a when every check passed, #a01818 otherwise.
    green = 1 if (abs(r - 0x1f) <= 8 and abs(g - 0x8a) <= 8 and abs(b - 0x3a) <= 8) else 0
    # sample a corner too (the centre may hold text)
    k = (5 * w + 5) * 3
    r2, g2, b2 = px[k], px[k + 1], px[k + 2]
    green_corner = 1 if (abs(r2 - 0x1f) <= 8 and abs(g2 - 0x8a) <= 8 and abs(b2 - 0x3a) <= 8) else 0
    print('bg_frac=%.4f yellow=%d green_center=%d green_corner=%d' % (bg / n, yellow, green, green_corner))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 (stdlib signature)
        pass


def cmd_serve(directory, portfile):
    os.chdir(directory)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(('127.0.0.1', 0), Quiet) as httpd:
        with open(portfile + '.tmp', 'w') as f:
            f.write(str(httpd.server_address[1]))
        os.replace(portfile + '.tmp', portfile)
        httpd.serve_forever()


def main():
    cmd = sys.argv[1]
    if cmd == 'ppm':
        cmd_ppm(sys.argv[2])
    elif cmd == 'md5file':
        with open(sys.argv[2], 'rb') as f:
            print(hashlib.md5(f.read()).hexdigest())
    elif cmd == 'md5str':
        print(hashlib.md5(sys.argv[2].encode('utf-8')).hexdigest())
    elif cmd == 'uuid5dns':
        print(uuid.uuid5(uuid.NAMESPACE_DNS, sys.argv[2]))
    elif cmd == 'serve':
        cmd_serve(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit('unknown command ' + cmd)


if __name__ == '__main__':
    main()
