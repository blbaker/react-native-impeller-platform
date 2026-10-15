#!/usr/bin/env python3
"""ENG-31 gate helpers (stdlib only, so the Mac runs them with no pip).

  crypto_check.py ws-echo <port> <readyfile>
      RFC 6455 echo server on 127.0.0.1:<port>. Text and binary frames come
      back unchanged (unmasked, same opcode); ping -> pong; close -> close.
      Writes <readyfile> once listening, or 'BIND_FAIL <err>' if the port is
      taken. Logs one line per frame to stdout.
  crypto_check.py ppm <file>
      Counts exact rgb(0,255,0) and rgb(255,0,0) pixels in a binary P6 PPM:
      prints 'green=N red=N total=N'.
"""
import base64
import hashlib
import socket
import struct
import sys
import threading

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def send_frame(conn, opcode, payload):
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    conn.sendall(head + payload)


def serve_client(conn):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                return
            req += chunk
        key = None
        for line in req.split(b"\r\n"):
            if line.lower().startswith(b"sec-websocket-key:"):
                key = line.split(b":", 1)[1].strip()
        if key is None:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                     b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        print("ws-echo: open", flush=True)
        while True:
            b0, b1 = recv_exact(conn, 2)
            opcode = b0 & 0x0F
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", recv_exact(conn, 2))[0]
            elif n == 127:
                n = struct.unpack(">Q", recv_exact(conn, 8))[0]
            mask = recv_exact(conn, 4) if b1 & 0x80 else b"\0\0\0\0"
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(recv_exact(conn, n)))
            print("ws-echo: opcode=%d len=%d" % (opcode, n), flush=True)
            if opcode in (1, 2):
                send_frame(conn, opcode, data)
            elif opcode == 9:
                send_frame(conn, 10, data)
            elif opcode == 8:
                send_frame(conn, 8, data[:2])
                return
    except (EOFError, OSError):
        return
    finally:
        conn.close()


def ws_echo(port, ready):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # The server closes first, so the previous run's connections sit in
    # TIME_WAIT on 8797 for ~60 s; without this, back-to-back runs (the
    # mutation chain) die with EADDRINUSE. A LIVE listener still refuses.
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", port))
    except OSError as e:
        with open(ready, "w") as f:
            f.write("BIND_FAIL %s\n" % e)
        return 1
    srv.listen(8)
    with open(ready, "w") as f:
        f.write("LISTENING %d\n" % port)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve_client, args=(conn,), daemon=True).start()


def ppm(path):
    data = open(path, "rb").read()
    fields = []
    i = 0
    while len(fields) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    i += 1
    if fields[0] != b"P6" or int(fields[3]) != 255:
        raise SystemExit("not a P6/255 ppm: %r" % fields)
    w, h = int(fields[1]), int(fields[2])
    px = data[i:i + w * h * 3]
    green = red = 0
    for k in range(0, len(px), 3):
        r, g, b = px[k], px[k + 1], px[k + 2]
        if r == 0 and g == 255 and b == 0:
            green += 1
        elif r == 255 and g == 0 and b == 0:
            red += 1
    print("green=%d red=%d total=%d" % (green, red, w * h))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "ws-echo":
        sys.exit(ws_echo(int(sys.argv[2]), sys.argv[3]))
    if len(sys.argv) == 3 and sys.argv[1] == "ppm":
        ppm(sys.argv[2])
        sys.exit(0)
    sys.exit(__doc__)
